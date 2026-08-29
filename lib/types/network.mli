(** Which chain an address or transaction belongs to.

    Cardano carries this in two different places with two different widths, and
    they are not the same thing:

    - the {b network id}, a four-bit field in an address header and an optional
      transaction-body field, which distinguishes only mainnet from "a
      testnet";
    - the {b network magic}, a 32-bit protocol parameter that distinguishes
      Preview from Preprod from any other testnet.

    An address therefore cannot tell you which testnet it is for. That is a
    property of the format, not an omission here, and it is why a signer should
    pin the genesis configuration rather than trust an address to identify the
    chain. *)

type t = Mainnet | Testnet of { magic : int32 }

val preview : t
val preprod : t
val mainnet : t

val id : t -> int
(** [1] for mainnet, [0] for any testnet: the four-bit field an address header
    carries. *)

val of_id : int -> (t, string) result
(** [0] yields {!preview}, since a bare network id cannot say which testnet was
    meant. Use {!with_magic} when the magic is known. *)

val with_magic : int32 -> t
val magic : t -> int32
val equal : t -> t -> bool
val pp : Format.formatter -> t -> unit
