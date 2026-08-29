(** Just enough HTTP/1.1 to carry JSON-RPC, as a pure parser.

    Not a general HTTP client. It sends one POST and reads one response, which
    is all Ogmios needs for the query and submission methods.

    The parser is separated from the socket for the same reason as everything
    else here: it can then be driven from a unikernel with no TCP stack, and
    tested by feeding it bytes a few at a time -- which is how a real socket
    delivers them, and where framing bugs actually live. *)

val request : host:string -> path:string -> body:string -> string
(** A complete POST, with [Content-Length] and [Connection: keep-alive]. *)

type limits = { max_headers : int; max_body : int }

val default_limits : limits
(** 64 KiB of headers and 16 MiB of body. The response is a remote peer's, so
    its declared length is a claim to be bounded rather than believed. *)

type state

val start : ?limits:limits -> unit -> state

type progress = Need_more of state | Done of string | Failed of string

val feed : state -> string -> progress
(** Feeds however many bytes arrived. Splitting a response anywhere -- mid
    header, mid chunk length, mid body -- must not change the result. *)

val status : state -> int option
(** The status line, once it has been read. A JSON-RPC error arrives as a 200
    with an [error] member, so a non-200 here means the request never reached
    the application. *)
