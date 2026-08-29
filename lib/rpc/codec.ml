let request_json ~id m =
  `Assoc
    ([ ("jsonrpc", `String "2.0"); ("method", `String (Method.name m)) ]
    @ (match Method.params m with None -> [] | Some p -> [ ("params", p) ])
    @ [ ("id", `Int id) ])

let request ~id m = Yojson.Safe.to_string (request_json ~id m)

let member k = function
  | `Assoc kvs -> List.assoc_opt k kvs
  | _ -> None

let response ~id m body =
  match Yojson.Safe.from_string body with
  | exception Yojson.Json_error msg -> Error (Error.Malformed_json msg)
  | json -> (
      match member "error" json with
      | Some (`Assoc _ as e) ->
          let code = match member "code" e with Some (`Int c) -> c | _ -> 0 in
          let message =
            match member "message" e with Some (`String s) -> s | _ -> "(no message)"
          in
          Error (Error.Rpc { code; message; data = member "data" e })
      | Some other -> Error (Error.Invalid_response (Yojson.Safe.to_string other))
      | None -> (
          match member "id" json with
          | Some (`Int got) when got <> id ->
              Error (Error.Id_mismatch { expected = id; got = `Int got })
          | None -> Error (Error.Invalid_response "reply has no id")
          | Some _ -> (
              (* Ogmios echoes the method back. Checking it turns a broken
                 correlation into an error here rather than a plausible-looking
                 value of the wrong type further along. *)
              match member "method" json with
              | Some (`String got) when got <> Method.name m ->
                  Error
                    (Error.Invalid_response
                       (Printf.sprintf "reply is for %S, not %S" got (Method.name m)))
              | _ -> (
                  match member "result" json with
                  | Some result -> Method.decode m result
                  | None -> Error (Error.Invalid_response "reply has no result")))))
