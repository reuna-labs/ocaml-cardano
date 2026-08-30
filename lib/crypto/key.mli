(** Cardano signing keys.

    Cardano does not use plain RFC 8032 Ed25519 key derivation. It uses
    BIP32-Ed25519 (Khovratovich & Law), where the secret is a 64-byte
    {e extended} key -- a clamped scalar [kL] and a nonce prefix [kR] -- rather
    than a 32-byte seed that gets hashed into one. That is what makes
    non-hardened public derivation possible, and it is why these keys cannot be
    handed to an ordinary Ed25519 library's key generation.

    Signing is the ordinary Ed25519 equation over that extended key, so any RFC
    8032 verifier accepts the signatures.

    {b Not constant time.} Derivation does plain byte arithmetic on secret
    scalars and inherits variable-time point decoding. See [SECURITY.md]. *)

type error =
  [ `Invalid_length of int
  | `Invalid_format
  | `Invalid_derivation
  | `Hardened_from_public ]

val pp_error : Format.formatter -> [< error ] -> unit

(** {1 Extended keys} *)

module Xpub : sig
  type t
  (** [A ‖ chain code], 64 bytes. *)

  val of_bytes : string -> (t, error) result
  val to_bytes : t -> string

  val derive : t -> int32 -> (t, error) result
  (** Soft derivation only. A hardened index gives [`Hardened_from_public]: the
      whole point of hardening is that the public key is not enough. *)

  val derive_path : t -> Derivation_path.t -> (t, error) result

  val raw : t -> string
  (** The 32-byte Ed25519 public key, without the chain code. *)

  val hash : t -> Cardano_types.Hash.Addr_key_hash.t
  (** Blake2b-224 of {!raw} -- the credential that appears in an address. *)

  val verify : t -> signature:string -> string -> bool
end

module Xprv : sig
  type t
  (** [kL ‖ kR ‖ chain code], 96 bytes. *)

  val of_bytes : string -> (t, error) result
  val to_bytes : t -> string

  val derive : t -> int32 -> (t, error) result
  (** One level. An index at or above [2^31] derives hardened, below it soft;
      the index carries that choice, exactly as it does on the wire. *)

  val derive_path : t -> Derivation_path.t -> (t, error) result
  val public : t -> Xpub.t
  val sign : t -> string -> string
end

(** {1 Bare Ed25519}

    A witness carries a plain 32-byte public key, not an extended one. These
    take that form directly. BIP32-Ed25519 signing produces ordinary RFC 8032
    signatures -- the extended key changes how the scalar is derived, not what
    the signature equation is -- so any RFC 8032 verifier accepts them. *)

val verify_raw : vkey:string -> signature:string -> string -> bool
(** [false] rather than an error for a malformed key or signature: a witness
    that cannot be parsed has not verified, and the distinction is not one a
    caller can act on differently. *)

(** {1 Root keys}

    Two schemes reach a root key from a mnemonic, and they disagree. Which one a
    wallet used is not recoverable from the mnemonic, so it has to be known.
    Icarus is what Daedalus, Yoroi, Eternl and the hardware wallets use for
    Shelley-era accounts, and it is the only one implemented here. *)

module Icarus : sig
  val of_entropy : ?passphrase:string -> string -> (Xprv.t, error) result
  (** CIP-3 "Icarus" master key generation:
      [PBKDF2-HMAC-SHA512(password = passphrase, salt = entropy, c = 4096, dkLen
       = 96)], then the standard Ed25519 clamp on the first 32 bytes.

      Note which way round the two inputs go. The passphrase is the {e password}
      and the entropy is the {e salt} -- the opposite of BIP39's seed
      derivation, and a mistake that produces a perfectly valid key for a wallet
      nobody else can find. [passphrase] defaults to [""].

      [entropy] is the raw BIP39 entropy, 16 to 32 bytes, {b not} the 64-byte
      BIP39 seed. Passing a seed here is the other way to derive the wrong
      wallet. *)
end
