type rpc = { code : int; message : string; data : Yojson.Safe.t option }

type t =
  | Transport of string
  | Malformed_json of string
  | Invalid_response of string
  | Id_mismatch of { expected : int; got : Yojson.Safe.t }
  | Rpc of rpc
  | Decode of { method_ : string; reason : string }

let pp ppf = function
  | Transport m -> Format.fprintf ppf "transport: %s" m
  | Malformed_json m -> Format.fprintf ppf "malformed JSON: %s" m
  | Invalid_response m -> Format.fprintf ppf "not a JSON-RPC response: %s" m
  | Id_mismatch { expected; got } ->
      Format.fprintf ppf "reply to request %d arrived with id %s" expected
        (Yojson.Safe.to_string got)
  | Rpc { code; message; data } ->
      Format.fprintf ppf "node rejected the request (%d): %s%s" code message
        (match data with None -> "" | Some d -> " -- " ^ Yojson.Safe.to_string d)
  | Decode { method_; reason } ->
      Format.fprintf ppf "could not read the reply to %s: %s" method_ reason

let is_retryable = function Transport _ -> true | _ -> false
