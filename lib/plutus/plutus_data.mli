(** Plutus data -- the datums and redeemers a script sees.

    {v
    plutus_data = constr<plutus_data> / {* plutus_data => plutus_data}
                / [* plutus_data] / big_int / bounded_bytes
    v}

    {1 Two things the CDDL cannot say}

    {b Byte strings over 64 bytes must be chunked.} The grammar writes
    [bounded_bytes = bytes .size (0 .. 64)], and the comment beside it explains
    that the real rule is not expressible in CDDL: a {e definite}-length byte
    string is limited to 64 bytes, and anything longer has to be an
    indefinite-length string whose chunks are each at most 64. So a 65-byte
    datum has exactly one legal encoding and it is not the obvious one. Getting
    this wrong changes the datum hash, which changes the script-data hash, which
    has the transaction rejected.

    {b Integers are unbounded.} Plutus has no integer width. Values outside
    [int64] are carried as sign-and-magnitude bytes and never operated on, which
    is what keeps this library free of a bignum dependency. *)

type t =
  | Constr of { alternative : int; fields : t list }
      (** A constructor application. The alternative is encoded as a CBOR tag:
          0..6 as 121..127, 7..127 as 1280..1400, and anything else as tag 102
          carrying the number explicitly. *)
  | Map of (t * t) list
      (** Order is as it appeared. Plutus map keys are not sorted by the ledger,
          and sorting them here would change the datum hash. *)
  | List of t list
  | Int of int64
  | Big_int of { negative : bool; magnitude : string }
      (** Beyond [int64]. The value is [magnitude], or [-1 - magnitude] when
          [negative]. *)
  | Bytes of string

val of_int : int -> t
val max_definite_bytes : int
(** [64]. Past this, a byte string must be chunked. *)

val encode : t -> string
(** The canonical encoding, chunking byte strings over
    {!max_definite_bytes}. This is what gets hashed, so it is bytes rather than
    a CBOR value: the chunked form is not something the strict codec would
    emit. *)

val decode : string -> (t, string) result
(** Accepts both the chunked and, for short strings, the definite form.
    Rejects a definite string over 64 bytes, which the ledger does not permit. *)

val to_cbor : t -> Web3_codec_cbor.t
(** For embedding in a larger structure. {b Not equivalent to {!encode}} when a
    byte string exceeds 64 bytes: the codec emits definite lengths by design and
    cannot express the chunked form. Use {!encode} for anything that will be
    hashed. *)

val hash : t -> Cardano_types.Hash.Datum_hash.t
(** Blake2b-256 of {!encode}. *)

val equal : t -> t -> bool
val pp : Format.formatter -> t -> unit
