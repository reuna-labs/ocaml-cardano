(** Bech32 (BIP173) for CIP-19 addresses and CIP-5 identifiers.

    A deliberate fork of the module in [ocaml-web3-codec] rather than a
    dependency on it; see the header of [bech32.ml] for why, and for what to
    delete when the shared package is sliced.

    The SegWit layer is absent: Cardano has no witness version, so an address
    here is a human-readable part and a payload, nothing more. *)

type encoding = Bech32 | Bech32m

val default_max_length : int
(** [90], BIP173's cap. *)

val cardano_max_length : int
(** [256]. CIP-19 drops BIP173's cap, which a Cardano base address exceeds: two
    28-byte credentials plus a header is 57 bytes, or 92 data characters before
    the checksum. *)

val convertbits :
  ?pad:bool -> int list -> from:int -> into:int -> int list option
(** Regroups [from]-bit values into [into]-bit values, MSB first. [None] if a
    value is out of range, or if [~pad:false] and the leftover bits are not zero
    padding. *)

val encode :
  ?max_length:int -> encoding -> hrp:string -> data:int list -> string
(** [data] is 5-bit groups.
    @raise Invalid_argument
      if [hrp] is not 1..83 characters in ASCII 33..126, if any group is outside
      0..31, or if the result would exceed [max_length] (default
      {!default_max_length}). *)

val decode :
  ?max_length:int -> string -> (encoding * string * int list, string) result
(** [Ok (encoding, hrp, data)] with [data] as 5-bit groups, checksum removed.
    Never raises. *)

val encode_bytes :
  ?max_length:int -> encoding -> hrp:string -> string -> (string, string) result
(** As {!encode}, taking bytes and regrouping them. [max_length] defaults to
    {!cardano_max_length} here, since every caller in this library is encoding a
    Cardano payload. Never raises. *)

val decode_bytes :
  ?max_length:int -> string -> (encoding * string * string, string) result
(** As {!decode}, returning bytes. Rejects non-zero padding bits, so a payload
    has exactly one spelling. Never raises. *)
