(** The Blake2b hashes Cardano identifies things by.

    Two widths, and they are not interchangeable: 224 bits identifies a key or a
    script, 256 bits identifies a transaction or a datum. Blake2b mixes the
    digest length into its parameter block, so the 224-bit function is not a
    truncation of the 256-bit one -- they are different functions that happen to
    share a name.

    Each is a distinct type so that a 28-byte credential cannot be passed where
    a 32-byte identifier belongs. *)

module type HASH = sig
  type t

  val size : int
  val of_bytes : string -> (t, string) result
  val to_bytes : t -> string
  val of_hex : string -> (t, string) result
  val to_hex : t -> string

  val digest : string -> t
  (** Blake2b of the given bytes at this width. *)

  val equal : t -> t -> bool
  val compare : t -> t -> int
  val pp : Format.formatter -> t -> unit
end

module Addr_key_hash : HASH
(** 28 bytes: Blake2b-224 of an Ed25519 public key. *)

module Script_hash : HASH
(** 28 bytes, over the script with its language tag prefixed. *)

module Pool_key_hash : HASH
(** 28 bytes. *)

module Tx_id : HASH
(** 32 bytes: Blake2b-256 over the exact bytes of the transaction body. *)

module Datum_hash : HASH
(** 32 bytes. *)

module Aux_data_hash : HASH
(** 32 bytes. *)

module Script_data_hash : HASH
(** 32 bytes. *)

val blake2b224 : string -> string
val blake2b256 : string -> string
