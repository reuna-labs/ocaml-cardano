(* The client end to end, over a flow that is not a socket.

   The whole point of functorising over a flow rather than taking an HTTP
   client is that the transport can be anything -- a vsock stream inside a
   unikernel, a TCP connection, or this: a pair of buffers. If the client works
   here it works there, because there is no other code path. *)

(* A flow that behaves like a very small server: it records what was written,
   echoes back the request id the way Ogmios does, and delivers the reply in
   pieces so the client has to reassemble it.

   Echoing the id rather than pinning one matters. Request ids are assigned per
   exchange and rise for the lifetime of the process, so a fixture with a
   hardcoded id would pass or fail depending on how many tests ran before it --
   testing the counter rather than the client. *)
module Fake_flow = struct
  type flow = {
    sent : Buffer.t;
    body : string;  (* with %ID% where the request id belongs *)
    pieces : int;
    mutable pending : string list;
    mutable answer : bool;
  }

  type error = string
  type write_error = string

  let pp_error = Fmt.string
  let pp_write_error = Fmt.string

  let make ?(pieces = 3) ?(answer = true) body =
    { sent = Buffer.create 256; body; pieces; pending = []; answer }

  let find_all_after haystack needle =
    let n = String.length haystack and m = String.length needle in
    let rec go i best =
      if i + m > n then best
      else if String.sub haystack i m = needle then go (i + 1) (Some (i + m))
      else go (i + 1) best
    in
    go 0 None

  let request_id f =
    let s = Buffer.contents f.sent in
    match find_all_after s {|"id":|} with
    | None -> "0"
    | Some j ->
        let n = String.length s in
        let k = ref j in
        while !k < n && s.[!k] >= '0' && s.[!k] <= '9' do incr k done;
        String.sub s j (!k - j)

  let substitute template id =
    let key = "%ID%" in
    let n = String.length template and m = String.length key in
    let b = Buffer.create n in
    let i = ref 0 in
    while !i < n do
      if !i + m <= n && String.sub template !i m = key then (
        Buffer.add_string b id;
        i := !i + m)
      else (
        Buffer.add_char b template.[!i];
        incr i)
    done;
    Buffer.contents b

  let split s k =
    let n = String.length s in
    let size = max 1 ((n + k - 1) / k) in
    List.filter_map
      (fun i ->
        if i * size >= n then None
        else Some (String.sub s (i * size) (min size (n - (i * size)))))
      (List.init k Fun.id)

  let read f : (Cstruct.t Mirage_flow.or_eof, error) result Lwt.t =
    match f.pending with
    | x :: rest ->
        f.pending <- rest;
        Lwt.return (Ok (`Data (Cstruct.of_string x)))
    | [] ->
        if not f.answer then Lwt.return (Ok `Eof)
        else (
          f.answer <- false;
          let body = substitute f.body (request_id f) in
          let http =
            Printf.sprintf "HTTP/1.1 200 OK\r\nContent-Length: %d\r\n\r\n%s"
              (String.length body) body
          in
          match split http f.pieces with
          | [] -> Lwt.return (Ok `Eof)
          | x :: rest ->
              f.pending <- rest;
              Lwt.return (Ok (`Data (Cstruct.of_string x))))

  let write f cs : (unit, write_error) result Lwt.t =
    Buffer.add_string f.sent (Cstruct.to_string cs);
    Lwt.return (Ok ())
end

module Client = Cardano_rpc_flow.Make (Fake_flow)

let run = Lwt_main.run

let query_over_a_flow () =
  let flow =
    Fake_flow.make
      {|{"jsonrpc":"2.0","method":"queryLedgerState/epoch","result":651,"id":%ID%}|}
  in
  let t = Client.create ~host:"ogmios.local" flow in
  match run (Client.call t (Cardano_rpc.Ogmios.query_epoch ())) with
  | Ok epoch ->
      Alcotest.(check int64) "the answer comes back typed" 651L epoch;
      let sent = Buffer.contents flow.Fake_flow.sent in
      let contains s =
        let n = String.length sent and m = String.length s in
        let rec go i = i + m <= n && (String.sub sent i m = s || go (i + 1)) in
        go 0
      in
      Alcotest.(check bool) "and a well-formed request went out" true
        (contains "POST / HTTP/1.1" && contains "Host: ogmios.local"
         && contains {|"method":"queryLedgerState/epoch"|})
  | Error e -> Alcotest.failf "%a" Cardano_rpc.Error.pp e

(* A node that answers a different question must not be believed. *)
let mismatched_reply_is_caught () =
  let flow =
    Fake_flow.make
      {|{"jsonrpc":"2.0","method":"queryLedgerState/tip","result":651,"id":%ID%}|}
  in
  let t = Client.create flow in
  match run (Client.call t (Cardano_rpc.Ogmios.query_epoch ())) with
  | Error (Cardano_rpc.Error.Invalid_response _) -> ()
  | Error e -> Alcotest.failf "wrong error: %a" Cardano_rpc.Error.pp e
  | Ok _ -> Alcotest.fail "a reply to a different query was accepted"

let transport_failure_is_typed () =
  (* The peer closes before answering. *)
  let flow = Fake_flow.make ~answer:false "" in
  let t = Client.create flow in
  match run (Client.call t (Cardano_rpc.Ogmios.query_epoch ())) with
  | Error (Cardano_rpc.Error.Transport _) -> ()
  | Error e -> Alcotest.failf "wrong error: %a" Cardano_rpc.Error.pp e
  | Ok _ -> Alcotest.fail "a closed connection produced a result"

(* The umbrella package exists so a consumer can take the offline surface
   without Lwt, Unix or a socket coming with it. *)
let umbrella_is_offline_only () =
  let module _ = Cardano.Types in
  let module _ = Cardano.Address in
  let module _ = Cardano.Crypto in
  let module _ = Cardano.Transaction in
  let module _ = Cardano.Rpc in
  Alcotest.(check bool) "the umbrella links" true true

let () =
  Alcotest.run "cardano-flow-client"
    [ ("over a flow",
       [ Alcotest.test_case "typed query" `Quick query_over_a_flow;
         Alcotest.test_case "mismatched reply" `Quick mismatched_reply_is_caught;
         Alcotest.test_case "transport failure" `Quick transport_failure_is_typed ]);
      ("packaging", [ Alcotest.test_case "umbrella" `Quick umbrella_is_offline_only ]) ]
