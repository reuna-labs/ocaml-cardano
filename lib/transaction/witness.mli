(** Conway transaction witness sets.

    {v
    transaction_witness_set =
      { ? 0 : nonempty_list<vkeywitness>   ? 1 : nonempty_list<native_script>
      , ? 2 : nonempty_list<bootstrap_witness>
      , ? 3 : nonempty_set<plutus_v1_script>
      , ? 4 : nonempty_list<plutus_data>   ? 5 : redeemers
      , ? 6 : nonempty_set<plutus_v2_script>
      , ? 7 : nonempty_set<plutus_v3_script> }
    v}

    {b What is signed is the transaction id, not the body.} A vkey witness
    carries an Ed25519 signature over the 32-byte Blake2b-256 hash of the
    transaction body -- not over the body's bytes. Signing the bytes instead
    produces a signature that verifies against nothing.

    This release models key witnesses. Scripts, datums and redeemers are carried
    as raw CBOR so a witness set round-trips whole; building them lands with
    script support. *)

module Vkey : sig
  type t = { vkey : string; signature : string }
  (** [vkey] is the 32-byte Ed25519 public key -- the raw key, not an extended
      one, and not its hash. [signature] is 64 bytes. *)

  val make : vkey:string -> signature:string -> (t, string) result
  val key_hash : t -> Cardano_types.Hash.Addr_key_hash.t
  val verify : t -> Cardano_types.Hash.Tx_id.t -> bool
  val pp : Format.formatter -> t -> unit
end

type t = {
  vkeys : Vkey.t list;
  carried : (int * Web3_codec_cbor.t) list;
      (** Witness-set fields this release does not interpret, by CDDL key:
          1 native scripts, 2 bootstrap witnesses, 3/6/7 Plutus scripts,
          4 datums, 5 redeemers. *)
  raw : string option;
}

val empty : t
val is_empty : t -> bool
val of_cbor : string -> (t, string) result
val to_cbor : t -> string

val add_vkey : t -> Vkey.t -> t
(** Appends a witness, discarding any preserved bytes: the set has changed, so
    re-encoding it from the old bytes would be a lie. Duplicates by public key
    are not added twice. *)

val cbor : t -> Web3_codec_cbor.t
val of_value : Web3_codec_cbor.t -> (t, string) result
val pp : Format.formatter -> t -> unit
