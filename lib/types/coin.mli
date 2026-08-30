(** Amounts of ada, in lovelace.

    Every operation is checked and returns a [result]. An amount that silently
    wraps [int64] -- a sum of outputs, say -- is a fund-loss bug rather than a
    rounding error, so the type refuses to let it happen quietly.

    Values are constrained to [[0, max_supply]]. Ada has no negative amounts;
    where a difference can go either way, compute it with {!diff}, which reports
    the sign separately rather than introducing a signed type. *)

type t = private int64

type error =
  [ `Overflow of string
    (** The named operation left the representable range. *)
  | `Invalid_range  (** Negative, or above {!max_supply}. *)
  | `Invalid_format  (** A decimal figure this type cannot represent exactly. *)
  ]

val pp_error : Format.formatter -> [< error ] -> unit
val zero : t

val max_supply : t
(** [45_000_000_000_000_000] lovelace: 45 billion ada, the protocol maximum, and
    therefore the largest amount any single output can hold. Well inside
    [Int64.max_int], which is what leaves room for a checked sum to overshoot
    and be caught rather than wrap. *)

val lovelace_per_ada : int64
(** [1_000_000]. *)

(** {1 Conversion} *)

val of_lovelace : int64 -> (t, error) result
val to_lovelace : t -> int64

val of_lovelace_exn : int64 -> t
(** @raise Invalid_argument if out of range. For literals only. *)

val of_ada_string : string -> (t, error) result
(** Parses a decimal figure in ada, such as ["1.234567"], with at most six
    decimal places. Rejects anything it cannot represent exactly rather than
    rounding: a silently rounded amount is a wrong amount. Deliberately does not
    go through [float]. *)

val to_ada_string : t -> string
(** The exact decimal figure in ada, trailing zeros trimmed. Round-trips through
    {!of_ada_string}. *)

(** {1 Arithmetic} *)

val add : t -> t -> (t, error) result
val sub : t -> t -> (t, error) result

val mul : t -> int -> (t, error) result
(** @raise nothing; a negative multiplier is [`Invalid_range]. *)

val diff : t -> t -> [ `Pos of t | `Neg of t | `Zero ]
(** The signed difference, with the sign reported separately so that callers
    handle it rather than a wrapped negative slipping through. *)

val sum : t list -> (t, error) result

(** {1 Comparison} *)

val compare : t -> t -> int
val equal : t -> t -> bool
val min : t -> t -> t
val max : t -> t -> t
val pp : Format.formatter -> t -> unit
