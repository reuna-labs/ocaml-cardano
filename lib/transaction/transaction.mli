(** Whole Conway transactions.

    {v
transaction = [transaction_body, transaction_witness_set, bool, auxiliary_data / nil]
    v}

    {b Adding a witness does not change the transaction id.} The id is the hash
    of the body alone, so it is known before anything is signed -- which is what
    lets a caller check the id it is about to sign against the id it expects,
    and lets a submission tracker follow a transaction it has not yet assembled.
    The functions below preserve the body's bytes while replacing the
    envelope's. *)

type t = {
  body : Body.t;
  witness_set : Witness.t;
  is_valid : bool;
  auxiliary_data : Web3_codec_cbor.t option;
  raw : string option;
}

val of_cbor : string -> (t, string) result
(** Decodes a whole transaction. The body's own byte span is extracted from the
    input rather than re-encoded, which is what makes {!id} agree with the chain
    even when the sender used a spelling this library would not have. *)

val to_cbor : t -> string
val id : t -> Cardano_types.Hash.Tx_id.t
val pp : Format.formatter -> t -> unit

(** {1 Signing}

    What a witness signs is the {b transaction id} -- the 32-byte hash of the
    body -- and not the body's bytes. Signing the bytes produces a signature
    that verifies against nothing. *)

val signing_payload : t -> string
(** The exact 32 bytes an external signer must sign. Hand it these; do not hand
    it the body and ask it to hash. *)

val sign : t -> Cardano_crypto.Key.Xprv.t -> t
(** Signs with an extended key and attaches the witness. Signing twice with the
    same key adds one witness, not two. *)

val add_signature : t -> vkey:string -> signature:string -> (t, string) result
(** Attaches a signature produced elsewhere, after verifying it against
    {!signing_payload}. A signature that does not verify is rejected here rather
    than by the node: the caller still has the context to work out why, and a
    transaction that fails at submission has already cost a round trip.

    [vkey] is the bare 32-byte public key. *)

val witnesses : t -> Witness.Vkey.t list

val signed_by : t -> Cardano_types.Hash.Addr_key_hash.t list
(** The key hashes that have witnessed this transaction.

    Note what this is {b not}: the set of signatures the ledger will require.
    That depends on the addresses of the inputs being spent, which live in the
    UTXO set and not in the transaction, so no function here can compute it from
    [t] alone. Body field 14 ([required_signers]) is an additional demand, not
    the whole of it. *)

val body_span : string -> (int * int, string) result
(** [body_span tx] is the offset and length of the transaction body inside the
    encoded transaction [tx]. Exposed because a caller that wants only the id --
    a submission tracker, say -- should not have to decode the body to get it.
*)
