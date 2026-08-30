(** An Ogmios client over any {!Mirage_flow.S}.

    {b Why a flow and not an HTTP client library.} The confidential Solo5
    targets forbid [NET_BASIC] outright -- Mirage's own [validate_manifest]
    rejects it for [cca], [snp] and [tdx] -- and [sptmac] has no networking at
    all, with vsock emulated over a Unix socket. So on the targets this library
    exists for, there is no TCP stack for an HTTP client to sit on. What there
    is, is a flow: [mirage-vsock-solo5] exposes exactly {!Mirage_flow.S}.

    Instantiating this over that flow is the whole unikernel story. Over Unix it
    is the same code with a different flow, which is what makes the Unix path
    worth trusting as a rehearsal for the enclave one.

    TLS, where it is wanted, wraps the flow rather than living here: a TLS flow
    is a flow. *)

module Http = Http

(** What a transport has to provide, which is less than a whole
    {!Mirage_flow.S}: bytes in, bytes out, and a way to print a failure.

    Requiring only this is deliberate. It is exactly the operations this client
    performs -- no [close], no [shutdown], no [writev] -- so ownership of the
    connection stays with the caller, which is what a unikernel needs since the
    flow belongs to a device it configured. Any [Mirage_flow.S] satisfies it,
    including {!Mirage_vsock_solo5}'s and a TLS flow wrapping either. *)
module type FLOW = sig
  type flow
  type error
  type write_error

  val pp_error : error Fmt.t
  val pp_write_error : write_error Fmt.t
  val read : flow -> (Cstruct.t Mirage_flow.or_eof, error) result Lwt.t
  val write : flow -> Cstruct.t -> (unit, write_error) result Lwt.t
end

module Make (F : FLOW) : sig
  type t

  val create :
    ?host:string -> ?path:string -> ?limits:Http.limits -> F.flow -> t
  (** [host] fills the [Host] header, [path] the request target (default ["/"]).
      The flow must already be connected; this never dials, because on a
      unikernel dialling is the caller's business and needs a device it owns. *)

  val flow : t -> F.flow

  module Provider :
    Cardano_rpc.Provider.S with type t = t and type 'a io = 'a Lwt.t

  val call :
    t -> 'a Cardano_rpc.Method.t -> ('a, Cardano_rpc.Error.t) result Lwt.t
end
