(** CIP-1852 derivation paths, as written [m/1852'/1815'/0'/0/0].

    Cardano's path shape is BIP44's, but neither coin type nor purpose is
    negotiable: 1852 is the Shelley multi-account purpose and 1815 is Ada's
    SLIP-44 coin type -- the year Ada Lovelace was born. *)

type hardened_marker =
  [ `Apostrophe  (** [1852'] -- BIP32's own notation. *)
  | `H  (** [1852h] -- safer in shells, where [\'] quotes. *) ]

type t

val empty : t
(** The master key's own path, [m]. *)

val of_list : int32 list -> t
(** From raw child numbers, where anything at or above [0x80000000] is hardened.
*)

val to_list : t -> int32 list

val of_string : string -> (t, [> `Invalid_format ]) result
(** Accepts a leading [m] or [M] and either hardened marker, mixed freely.
    Rejects an index at or above [2^31] written without a marker, since that
    would silently mean something other than what it says. *)

val to_string : ?marker:hardened_marker -> t -> string
(** [marker] defaults to [`Apostrophe]. *)

val append : t -> int32 -> t

val child : t -> int -> hardened:bool -> (t, [> `Invalid_range ]) result
(** [child p n ~hardened] appends index [n], which must be below [2^31]. *)

val parent : t -> t option
val depth : t -> int
val is_hardened : int32 -> bool
val equal : t -> t -> bool

(** {1 CIP-1852} *)

val purpose : int32
(** [1852], hardened. *)

val coin_type : int32
(** [1815], hardened. Ada's SLIP-44 registration. *)

(** The last-but-one path element, which says what an address is {e for}.
    Confusing external with internal is how change lands in someone else's
    wallet, so it is an enumeration rather than an [int]. *)
type role =
  | External  (** [0] -- addresses you hand out. *)
  | Internal  (** [1] -- change. *)
  | Staking  (** [2] -- the account's single stake key. *)
  | Drep  (** [3] -- CIP-105 delegate representative key. *)

val role_index : role -> int32

val account : account:int32 -> (t, [> `Invalid_range ]) result
(** [m/1852'/1815'/account'] -- the account-level extended key, which is the
    deepest node it is safe to export for watch-only use. *)

val address :
  account:int32 -> role:role -> index:int32 -> (t, [> `Invalid_range ]) result
(** [m/1852'/1815'/account'/role/index]. *)

val stake : account:int32 -> (t, [> `Invalid_range ]) result
(** [m/1852'/1815'/account'/2/0]. An account has exactly one stake key, so the
    index is fixed rather than offered. *)
