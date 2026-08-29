(** The boundary between "what to ask" and "how to send it".

    Everything above this line is pure: the method catalogue, the framing, and
    the submission state machine all work on strings and values. A transport
    supplies {!S} or the smaller {!TEXT}, and gets the typed client back.

    This is what lets the same client run over a Unix socket, a MirageOS
    [Mirage_flow.S], or a table of canned replies in a test. *)

module type S = sig
  type t
  type 'a io

  val return : 'a -> 'a io
  val bind : 'a io -> ('a -> 'b io) -> 'b io

  val request :
    t -> method_:string -> params:Yojson.Safe.t option -> id:int ->
    (Yojson.Safe.t, Error.t) result io
end

module type TEXT = sig
  type t
  type 'a io

  val return : 'a -> 'a io
  val bind : 'a io -> ('a -> 'b io) -> 'b io

  val exchange : t -> string -> (string, string) result io
  (** Send one request, return one reply. The transport does not need to know
      what either means. *)
end

module Make (P : S) : sig
  val call : P.t -> 'a Method.t -> ('a, Error.t) result P.io
end

module Of_text (X : TEXT) : S with type t = X.t and type 'a io = 'a X.io
(** Builds a provider from anything that can exchange a string for a string.

    Request ids are assigned per exchange and checked on the way back, so a
    transport that mixes up two in-flight replies is caught rather than
    believed. *)
