(** CIP-19 Cardano addresses.

    An address is a header byte followed by a payload. The header's top four
    bits say which of six shapes follows and whether each credential is a key
    hash or a script hash; the bottom four are the network id.

    {b A payment credential and a stake credential are different things.} The
    first controls who may spend an output, the second who earns its staking
    rewards. A base address carries both, an enterprise address only the first,
    a reward address only the second. Confusing them is how funds end up
    spendable by the wrong key, so the accessors return [option] and are named
    for what they are rather than for their position. *)

type error =
  [ `Invalid_length of int
  | `Unknown_header of int
  | `Invalid_network of int
  | `Invalid_pointer
  | `Trailing_bytes of int
  | `Bech32 of string
  | `Not_bech32
  | `Byron_unsupported ]

val pp_error : Format.formatter -> [< error ] -> unit

(** {1 Credentials} *)

module Credential : sig
  type t =
    | Key of Cardano_types.Hash.Addr_key_hash.t
    | Script of Cardano_types.Hash.Script_hash.t

  val to_bytes : t -> string
  (** The 28-byte hash, without any tag: the tag lives in the address header. *)

  val is_script : t -> bool
  val equal : t -> t -> bool
  val compare : t -> t -> int
  val pp : Format.formatter -> t -> unit
end

(** {1 Pointers} *)

module Pointer : sig
  type t = { slot : int64; tx_index : int64; cert_index : int64 }
  (** Where on chain the stake registration certificate sits. Each field is a
      variable-length natural, so a pointer address has no fixed size.

      Pointer addresses are supported here because they exist on chain and must
      round-trip; they are not something new code should mint. *)

  val equal : t -> t -> bool
  val pp : Format.formatter -> t -> unit
end

(** {1 Addresses} *)

type t =
  | Base of {
      network : Cardano_types.Network.t;
      payment : Credential.t;
      stake : Credential.t;
    }  (** Header [0000]-[0011]. Spendable and staked. *)
  | Pointer of {
      network : Cardano_types.Network.t;
      payment : Credential.t;
      pointer : Pointer.t;
    }  (** Header [0100]-[0101]. *)
  | Enterprise of { network : Cardano_types.Network.t; payment : Credential.t }
      (** Header [0110]-[0111]. Spendable, earns no rewards. *)
  | Reward of { network : Cardano_types.Network.t; stake : Credential.t }
      (** Header [1110]-[1111]. A withdrawal target, never an output target. *)
  | Byron of string
      (** Header [1000]. Carried as opaque bytes: recognised so that a legacy
          address is not mistaken for a malformed Shelley one, but not
          interpreted, and never constructed. *)

val of_bytes : string -> (t, error) result
val to_bytes : t -> string
val network : t -> Cardano_types.Network.t

val payment_credential : t -> Credential.t option
(** [None] for a reward address, which cannot hold an output, and for Byron. *)

val stake_credential : t -> Credential.t option
(** [None] for enterprise and pointer addresses, whose stake is either absent or
    indirect, and for Byron. *)

val is_script : t -> bool
(** Whether spending requires running a script rather than presenting a
    signature. [false] for a reward address. *)

(** {1 Text form} *)

val hrp : t -> (string, error) result
(** The CIP-5 human-readable part: ["addr"], ["addr_test"], ["stake"] or
    ["stake_test"]. [`Byron_unsupported] for a Byron address, which is base58
    and has no human-readable part. *)

val to_bech32 : t -> (string, error) result
val of_bech32 : string -> (t, error) result

val to_string : t -> (string, error) result
(** {!to_bech32}, and [`Byron_unsupported] for Byron: encoding one needs base58
    and this library does not construct them. *)

val of_string : string -> (t, error) result
(** Accepts bech32. A Byron address is base58 and is reported as [`Not_bech32]
    rather than silently misparsed. *)
