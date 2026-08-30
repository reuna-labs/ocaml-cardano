(** Non-negative exact rationals over [int64], for protocol parameters.

    Cardano's [nonnegative_interval] is [#6.30([uint, positive_int])] -- a
    literal fraction, not a decimal. Execution prices and the reference-script
    rate are given this way, and the fee they feed into is rounded at a specific
    point. Going through [float] would round somewhere else, by an amount too
    small to notice and large enough to have a transaction rejected.

    Every operation is checked. Overflow is an error rather than a wrap, on the
    same reasoning as {!Coin}: a fee that silently wrapped is not a slightly
    wrong fee. *)

type t

val zero : t
val one : t

val of_ratio : int64 -> int64 -> (t, string) result
(** [of_ratio num den]. [num] must be non-negative and [den] strictly positive.
    Reduced on construction, so equal values compare equal and later arithmetic
    has the smallest numbers to work with. *)

val of_int64 : int64 -> (t, string) result

val of_decimal_string : string -> (t, string) result
(** Parses ["1.2"] as [6/5] -- exactly, with a power-of-ten denominator, never
    through a float. Accepts an integer with no point.

    This exists because Ogmios renders one protocol parameter
    ([minFeeReferenceScripts.base]) as a JSON number rather than the ratio
    string it uses elsewhere. A JSON number that has already been through a
    double has lost whatever exact rational the ledger holds; parsing its
    shortest round-tripping decimal is the closest recovery available, and the
    caller should supply the parameter directly if exactness matters. *)

val num : t -> int64
val den : t -> int64
val add : t -> t -> (t, string) result
val mul : t -> t -> (t, string) result

val mul_int64 : t -> int64 -> (t, string) result
(** Multiplication by a non-negative integer, such as a byte count or an
    execution-unit budget. *)

val floor : t -> int64
val ceil : t -> int64
val compare : t -> t -> int
val equal : t -> t -> bool
val pp : Format.formatter -> t -> unit
