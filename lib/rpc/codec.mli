(** JSON-RPC 2.0 framing, as strings.

    Deliberately string-in, string-out: a transport only has to move bytes, so
    the same framing serves an HTTP POST, a WebSocket frame, and a test that
    never opens a socket. *)

val request : id:int -> 'a Method.t -> string
val request_json : id:int -> 'a Method.t -> Yojson.Safe.t

val response : id:int -> 'a Method.t -> string -> ('a, Error.t) result
(** Parses a reply, checks it corresponds to the request, and decodes it.

    Ogmios echoes the method name in its replies. That is checked: a reply
    carrying a different method name is a correlation failure, and reading it as
    though it answered this question is how a UTXO set gets mistaken for a
    protocol-parameter set. *)
