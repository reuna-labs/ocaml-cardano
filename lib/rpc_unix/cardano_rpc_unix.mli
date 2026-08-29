(** The Ogmios client over a Unix socket.

    This is {!Cardano_rpc_flow.Make} instantiated over [Mirage_flow_unix.Fd] and
    nothing more. The interesting property is what is {e absent}: there is no
    Unix-specific client code, so the Unix path and the unikernel path are the
    same implementation with a different flow underneath. Rehearsing an enclave
    workflow on Unix is then worth something.

    Dialling is the exception, and it lives here rather than one layer up on
    purpose: a unikernel's connection comes from a device it owns, and putting a
    [getaddrinfo] into [cardano-rpc-flow] would be a Unix dependency in the one
    layer that must not have one. *)

type t

val create :
  ?host:string ->
  ?path:string ->
  ?limits:Cardano_rpc_flow.Http.limits ->
  Lwt_unix.file_descr ->
  t
(** Wraps an already-connected descriptor. *)

val flow : t -> Lwt_unix.file_descr

val connect_tcp : ?host_header:string -> ?path:string -> string -> int -> t Lwt.t
val connect_unix : ?host_header:string -> ?path:string -> string -> t Lwt.t
(** Dials a Unix domain socket, which is how a vsock relay is reached from the
    host side. *)

val call : t -> 'a Cardano_rpc.Method.t -> ('a, Cardano_rpc.Error.t) result Lwt.t

module Provider :
  Cardano_rpc.Provider.S with type t = t and type 'a io = 'a Lwt.t
