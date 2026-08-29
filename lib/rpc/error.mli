(** What can go wrong between asking a node something and believing the answer.

    A closed variant rather than a string, because callers act differently on
    these: a transport failure is worth retrying, a decode failure never is, and
    a rejection from the ledger means the transaction has to change. *)

type rpc = { code : int; message : string; data : Yojson.Safe.t option }
(** A JSON-RPC error object as Ogmios sent it. [data] carries the ledger's own
    explanation for a rejected transaction and is the only place the reason
    appears, so it is kept rather than flattened into [message]. *)

type t =
  | Transport of string  (** The bytes never arrived, or never left. *)
  | Malformed_json of string
  | Invalid_response of string
      (** Well-formed JSON that is not a JSON-RPC response. *)
  | Id_mismatch of { expected : int; got : Yojson.Safe.t }
      (** A reply to a different request. On a multiplexed connection this means
          the correlation is broken, not that this request failed. *)
  | Rpc of rpc
  | Decode of { method_ : string; reason : string }
      (** The node answered and we could not read it. Distinct from
          {!Invalid_response} because it points at this library, not the node. *)

val pp : Format.formatter -> t -> unit
val is_retryable : t -> bool
(** True for transport failures only. A malformed or unreadable answer will be
    malformed again, and a ledger rejection will be rejected again. *)
