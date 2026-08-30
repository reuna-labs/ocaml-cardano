(** Native-asset quantities, and the ada-plus-assets bundle a UTXO holds.

    Two things here are easy to get subtly wrong, so they are made explicit in
    the types.

    {b Asset quantities are unsigned 64-bit, not [int64].} The ledger CDDL says
    [positive_coin = 1 .. max_word64], and a native asset has no supply cap the
    way ada does, so a quantity genuinely can exceed [Int64.max_int]. Treating
    the bit pattern as signed would turn a large balance into a negative one.

    {b Minting is not a value.} A mint field carries signed [nonzero_int64] --
    negative means burn -- while an output carries strictly positive quantities.
    They are separate types, so a burn cannot be added to an output by mistake.
*)

(** {1 Asset identity} *)

module Asset_name : sig
  type t

  val max_length : int

  (** [32]. *)

  val of_bytes : string -> (t, string) result
  (** Any byte string of 0..32 bytes. Not text: an asset name is opaque bytes
      and is frequently not valid UTF-8. *)

  val to_bytes : t -> string
  val to_hex : t -> string

  val to_display : t -> string
  (** A best-effort human rendering: the name as text when it is printable
      ASCII, and hex otherwise. For display only -- never for comparison, and
      never as an identifier. *)

  val empty : t
  val compare : t -> t -> int
  val equal : t -> t -> bool
  val pp : Format.formatter -> t -> unit
end

type policy_id = Hash.Script_hash.t
(** The hash of the minting policy script. *)

type asset = { policy : policy_id; name : Asset_name.t }

val asset : policy_id -> Asset_name.t -> asset

val compare_asset : asset -> asset -> int
(** {1 Unsigned quantities} *)

module Quantity : sig
  type t = private int64
  (** An {b unsigned} bit pattern covering [1 .. 2^64-1]. [-1L] as a bit pattern
      means [18446744073709551615]; the ordinary [Int64] comparisons are
      therefore wrong on it, and the ones below are not. *)

  val one : t

  val of_int64_unsigned : int64 -> (t, string) result
  (** Rejects zero: an entry of zero is not representable in the CDDL, and
      silently keeping one would produce a bundle that cannot be encoded. *)

  val of_int : int -> (t, string) result
  val to_int64_unsigned : t -> int64

  val to_string : t -> string
  (** Decimal, unsigned. *)

  val to_int : t -> int option
  (** [None] when it does not fit exactly. *)

  val add : t -> t -> (t, string) result

  val sub : t -> t -> (t, string) result
  (** Errors rather than reaching zero. *)

  val compare : t -> t -> int
  val equal : t -> t -> bool
  val pp : Format.formatter -> t -> unit
end

(** {1 Bundles} *)

module Multi_asset : sig
  type t
  (** A map from asset to a strictly positive quantity. Kept sorted and
      duplicate-free by construction, so two bundles holding the same assets
      compare equal regardless of how they were built. *)

  val empty : t
  val is_empty : t -> bool

  val of_list : (asset * Quantity.t) list -> (t, string) result
  (** Combines repeated assets by addition; errors if that overflows. *)

  val to_list : t -> (asset * Quantity.t) list

  (** Sorted by asset. *)

  val find : t -> asset -> Quantity.t option
  val add : t -> t -> (t, string) result
  val policies : t -> policy_id list

  val size : t -> int
  (** Number of distinct assets. *)

  val compare : t -> t -> int
  val equal : t -> t -> bool
  val pp : Format.formatter -> t -> unit
end

module Value : sig
  type t = { coin : Coin.t; assets : Multi_asset.t }
  (** What an output holds. [assets] is empty for a plain ada output, which is
      also what decides whether it encodes as a bare integer or as a pair. *)

  val zero : t
  val of_coin : Coin.t -> t
  val make : Coin.t -> Multi_asset.t -> t
  val is_ada_only : t -> bool
  val add : t -> t -> (t, string) result

  val sub : t -> t -> (t, string) result
  (** Errors if any component would go negative, rather than clamping: a
      shortfall the caller has not handled is not a zero. *)

  val contains : t -> t -> bool

  (** [contains a b] is whether [a] covers [b] in ada and in every asset. *)

  val compare : t -> t -> int
  val equal : t -> t -> bool
  val pp : Format.formatter -> t -> unit
end

module Mint : sig
  type t
  (** Signed asset deltas: positive mints, negative burns. Distinct from
      {!Multi_asset} so that the two cannot be confused at a call site.

      Quantities here are [nonzero_int64] -- genuinely signed, and genuinely
      excluding zero -- so this is not the unsigned {!Quantity}. *)

  val empty : t
  val is_empty : t -> bool

  val of_list : (asset * int64) list -> (t, string) result
  (** Rejects a zero delta, which the CDDL cannot represent. *)

  val to_list : t -> (asset * int64) list
  val size : t -> int
  val compare : t -> t -> int
  val equal : t -> t -> bool
  val pp : Format.formatter -> t -> unit
end
