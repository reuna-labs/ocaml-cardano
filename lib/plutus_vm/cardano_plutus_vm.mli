(** Untyped Plutus Core terms, and an evaluator that is not implemented.

    {b This package computes nothing.} Execution budgets come from the node's
    [evaluateTransaction]. What is here is the term type and the shape of the
    call, so that a real CEK machine can land later without the API around it
    having to move -- and so that a caller can see, in the types, that local
    evaluation is a thing this library does not do rather than a thing it does
    badly.

    Writing a Plutus evaluator means the CEK machine, every builtin, and the
    Conway cost models, and getting any of it subtly wrong yields a budget that
    looks reasonable and is not. Until that exists, the node is the authority
    and this package says so. *)

type term =
  | Var of int  (** de Bruijn index. *)
  | Lam of term
  | App of term * term
  | Force of term
  | Delay of term
  | Constant of constant
  | Builtin of string
  | Error_term  (** UPLC's [error], which aborts evaluation. *)
  | Constr of { tag : int; args : term list }  (** Since Plutus V3. *)
  | Case of { scrutinee : term; branches : term list }  (** Since Plutus V3. *)

and constant =
  | Integer of Cardano_plutus.Plutus_data.t
      (** Carried as {!Cardano_plutus.Plutus_data.Int} or [Big_int]; Plutus
          integers are unbounded and this library holds no bignum. *)
  | Bytestring of string
  | Text of string
  | Unit
  | Bool of bool
  | Data of Cardano_plutus.Plutus_data.t
  | List_of of constant list
  | Pair of constant * constant

type program = { version : int * int * int; body : term }
type error = [ `Not_implemented ]

val pp_error : Format.formatter -> [< error ] -> unit

val evaluate :
  program ->
  args:Cardano_plutus.Plutus_data.t list ->
  budget:Cardano_types.Protocol_params.ex_units ->
  (Cardano_types.Protocol_params.ex_units, error) result
(** Always [Error `Not_implemented].

    It is a [result] rather than an exception so that a caller wiring up a
    local-evaluation path gets a value to handle now and a working one later,
    without the call site changing. *)

val deserialise : string -> (program, error) result
(** Always [Error `Not_implemented]. Flat-encoded UPLC is a bit-level format,
    not CBOR, and decoding it is part of the same unwritten piece of work. *)
