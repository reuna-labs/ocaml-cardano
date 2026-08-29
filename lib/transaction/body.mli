(** Conway transaction bodies.

    {1 Why a decoded body keeps its bytes}

    The transaction id is Blake2b-256 over the {e exact bytes} of the body as
    they appeared on the wire. The Conway CDDL deliberately admits several valid
    spellings of the same value:

    {v
    set<a0>            = #6.258([* a0]) / [* a0]
    transaction_output = alonzo_transaction_output / babbage_transaction_output
    redeemers          = [ + redeemer ] / { + [tag, index] => [data, ex_units] }
    v}

    so decoding and re-encoding changes the id whenever the sender chose a
    spelling this library would not have -- which [cardano-cli] and
    cardano-serialization-lib routinely do. A decoded body therefore carries the
    bytes it arrived in, and {!id} hashes those. A body built locally has none,
    and is hashed from its canonical encoding.

    {1 What is carried but not interpreted}

    Certificates, withdrawals, and the Conway governance fields round-trip
    byte-identically but are exposed as raw CBOR. This release builds none of
    them. That is a deliberate limit rather than an oversight: a signer that
    silently dropped a governance vote, or that claimed to understand one it did
    not, would be worse than one that says it is carrying something it cannot
    read. {!Intent} reports their presence. *)

module Input : sig
  type t = { tx_id : Cardano_types.Hash.Tx_id.t; index : int }

  val make : Cardano_types.Hash.Tx_id.t -> int -> (t, string) result
  (** [index] is a [uint .size 2], so at most 65535. *)

  val compare : t -> t -> int
  val equal : t -> t -> bool
  val pp : Format.formatter -> t -> unit
end

module Datum : sig
  type t =
    | Hash of Cardano_types.Hash.Datum_hash.t
    | Inline of string
        (** The datum's own CBOR bytes, as they appear inside the [#6.24] tag.
            Kept raw so that an output re-encodes exactly. *)
end

module Output : sig
  type t = {
    address : Cardano_address.Address.t;
    value : Cardano_types.Value.t;
    datum : Datum.t option;
    script_ref : string option;  (** Raw CBOR of the referenced script. *)
  }

  val make :
    ?datum:Datum.t ->
    ?script_ref:string ->
    Cardano_address.Address.t ->
    Cardano_types.Value.t ->
    t

  val to_cbor : t -> Web3_codec_cbor.t
  (** Exposed because the minimum-value calculation is defined over an output's
      encoded size, so a caller computing it has to be able to encode one. *)

  val of_cbor : Web3_codec_cbor.t -> (t, string) result

  val pp : Format.formatter -> t -> unit
end

type t = {
  inputs : Input.t list;
  outputs : Output.t list;
  fee : Cardano_types.Coin.t;
  ttl : int64 option;
  validity_start : int64 option;
  mint : Cardano_types.Mint.t option;
  network_id : Cardano_types.Network.t option;
  collateral : Input.t list;
  reference_inputs : Input.t list;
  required_signers : Cardano_types.Hash.Addr_key_hash.t list;
  collateral_return : Output.t option;
  total_collateral : Cardano_types.Coin.t option;
  script_data_hash : Cardano_types.Hash.Script_data_hash.t option;
  aux_data_hash : Cardano_types.Hash.Aux_data_hash.t option;
  carried : (int * Web3_codec_cbor.t) list;
      (** Body fields this release does not interpret, by their CDDL key:
          4 certificates, 5 withdrawals, 19 voting procedures, 20 proposal
          procedures, 21 current treasury value, 22 donation. Preserved so a
          body round-trips whole. *)
  raw : string option;
      (** The bytes this body was decoded from, if it was decoded. *)
}

val empty : t
(** No inputs, no outputs, zero fee, nothing carried. A starting point for a
    builder, never a valid transaction. *)

val of_cbor : string -> (t, string) result
(** Decodes a body and records the bytes it consumed. Rejects key 6 -- the
    Babbage-era [update] field, which Conway removed -- rather than ignoring it:
    a body carrying it is not a Conway body, and treating it as one would sign
    something whose meaning has not been modelled. *)

val to_cbor : t -> string
(** The decoded bytes when this body was decoded, and the canonical encoding
    otherwise. So {!id} is always the hash of what this returns. *)

val id : t -> Cardano_types.Hash.Tx_id.t

val is_verbatim : t -> bool
(** Whether {!to_cbor} will reproduce decoded bytes rather than re-encode. *)

val pp : Format.formatter -> t -> unit
