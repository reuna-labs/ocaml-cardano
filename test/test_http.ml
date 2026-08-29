(* The HTTP framing, fed the way a socket delivers it.

   A parser that only ever sees whole responses is untested where it matters. A
   flow hands over whatever happened to arrive, so every test here also runs the
   same input one byte at a time; if the split changes the answer, the state
   machine is wrong. *)

module H = Cardano_rpc_flow.Http

let drive ?(chunk = max_int) input =
  let n = String.length input in
  let rec go st i =
    if i >= n then `Incomplete
    else
      let k = min chunk (n - i) in
      match H.feed st (String.sub input i k) with
      | H.Done body -> `Done body
      | H.Failed m -> `Failed m
      | H.Need_more st -> go st (i + k)
  in
  go (H.start ()) 0

(* Whole, and then a byte at a time. Both must agree. *)
let both ?(name = "") input expected =
  List.iter
    (fun (label, chunk) ->
      match drive ~chunk input with
      | `Done body ->
          Alcotest.(check string) (name ^ " " ^ label) expected body
      | `Failed m -> Alcotest.failf "%s %s: %s" name label m
      | `Incomplete -> Alcotest.failf "%s %s: never completed" name label)
    [ ("whole", max_int); ("byte by byte", 1); ("in threes", 3) ]

let content_length () =
  both ~name:"content-length"
    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 13\r\n\r\n{\"result\":1}\n"
    "{\"result\":1}\n"

let chunked () =
  (* Ogmios may stream, and a chunk boundary can fall anywhere -- including in
     the middle of the length line. *)
  both ~name:"chunked"
    "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\n{\"a\":\r\n4\r\n1}\r\n\r\n0\r\n\r\n"
    "{\"a\":1}\r\n"

let chunk_extensions () =
  (* A chunk header may carry extensions after a semicolon. Reading the whole
     line as hex would fail on them. *)
  both ~name:"chunk extensions"
    "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n3;foo=bar\r\nabc\r\n0\r\n\r\n"
    "abc"

let header_case_is_ignored () =
  (* Servers send whichever case they like, and several send lowercase. *)
  both ~name:"lowercase headers"
    "HTTP/1.1 200 OK\r\ncontent-length: 2\r\n\r\nhi" "hi";
  both ~name:"mixed case chunked"
    "HTTP/1.1 200 OK\r\nTRANSFER-ENCODING: Chunked\r\n\r\n2\r\nhi\r\n0\r\n\r\n" "hi"

let status_is_reported () =
  let st = H.start () in
  match H.feed st "HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\n\r\n" with
  | H.Done _ | H.Need_more _ ->
      (* A JSON-RPC error arrives as a 200 with an error member, so a non-200
         means the request never reached the application at all. *)
      ()
  | H.Failed m -> Alcotest.failf "unexpected failure: %s" m

let close_delimited () =
  (* No length and no chunking: the body ends when the peer closes, which the
     driver signals by feeding the empty string. *)
  let st = H.start () in
  match H.feed st "HTTP/1.1 200 OK\r\n\r\npartial" with
  | H.Need_more st -> (
      match H.feed st "" with
      | H.Done body -> Alcotest.(check string) "body ends at close" "partial" body
      | _ -> Alcotest.fail "expected completion at end of stream")
  | _ -> Alcotest.fail "expected to need more"

(* A response cut short must be an error, not a short body handed on as though
   it were the whole thing. *)
let truncation_is_an_error () =
  let st = H.start () in
  (match H.feed st "HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\nshort" with
   | H.Need_more st -> (
       match H.feed st "" with
       | H.Failed _ -> ()
       | H.Done b -> Alcotest.failf "a truncated body was accepted: %S" b
       | H.Need_more _ -> Alcotest.fail "expected a failure at end of stream")
   | _ -> Alcotest.fail "expected to need more");
  (* A chunked stream that ends without its terminating zero chunk, likewise. *)
  let st = H.start () in
  match H.feed st "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n2\r\nhi\r\n" with
  | H.Need_more st -> (
      match H.feed st "" with
      | H.Failed _ -> ()
      | _ -> Alcotest.fail "an unterminated chunked body was accepted")
  | _ -> Alcotest.fail "expected to need more"

(* The declared length is a remote peer's claim. It is bounded before anything
   is allocated on the strength of it. *)
let limits_are_enforced () =
  let small = { H.max_headers = 64; max_body = 16 } in
  let st = H.start ~limits:small () in
  (match H.feed st "HTTP/1.1 200 OK\r\nContent-Length: 1000000\r\n\r\n" with
   | H.Failed _ -> ()
   | _ -> Alcotest.fail "an oversized declared length was accepted");
  let st = H.start ~limits:small () in
  let long_headers = "HTTP/1.1 200 OK\r\n" ^ String.concat "" (List.init 20 (fun i -> Printf.sprintf "X-Pad-%d: aaaaaaaa\r\n" i)) in
  (match H.feed st long_headers with
   | H.Failed _ -> ()
   | _ -> Alcotest.fail "oversized headers were accepted");
  (* Chunked bodies are bounded too, since no single length declares them. *)
  let st = H.start ~limits:small () in
  match H.feed st "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n20\r\n" with
  | H.Failed _ -> ()
  | _ -> Alcotest.fail "an oversized chunk was accepted"

let request_is_well_formed () =
  let body = {|{"jsonrpc":"2.0"}|} in
  let r = H.request ~host:"ogmios.local" ~path:"/" ~body in
  let has s = match String.index_opt r 'H' with _ ->
    let n = String.length r and m = String.length s in
    let rec go i = i + m <= n && (String.sub r i m = s || go (i + 1)) in go 0
  in
  Alcotest.(check bool) "is a POST" true (has "POST / HTTP/1.1\r\n");
  Alcotest.(check bool) "names the host" true (has "Host: ogmios.local\r\n");
  Alcotest.(check bool) "declares the body's actual length" true
    (has (Printf.sprintf "Content-Length: %d\r\n" (String.length body)));
  Alcotest.(check bool) "says it is JSON" true (has "Content-Type: application/json\r\n");
  Alcotest.(check bool) "ends the headers before the body" true
    (has "\r\n\r\n{\"jsonrpc\":\"2.0\"}")

let () =
  Alcotest.run "cardano-http"
    [ ("framing",
       [ Alcotest.test_case "content-length" `Quick content_length;
         Alcotest.test_case "chunked" `Quick chunked;
         Alcotest.test_case "chunk extensions" `Quick chunk_extensions;
         Alcotest.test_case "header case" `Quick header_case_is_ignored;
         Alcotest.test_case "close-delimited" `Quick close_delimited;
         Alcotest.test_case "status" `Quick status_is_reported ]);
      ("untrusted input",
       [ Alcotest.test_case "truncation" `Quick truncation_is_an_error;
         Alcotest.test_case "limits" `Quick limits_are_enforced ]);
      ("request", [ Alcotest.test_case "well formed" `Quick request_is_well_formed ]) ]
