(* A stub, deliberately. See the .mli for why this package exists at all. *)

type term =
  | Var of int
  | Lam of term
  | App of term * term
  | Force of term
  | Delay of term
  | Constant of constant
  | Builtin of string
  | Error_term
  | Constr of { tag : int; args : term list }
  | Case of { scrutinee : term; branches : term list }

and constant =
  | Integer of Cardano_plutus.Plutus_data.t
  | Bytestring of string
  | Text of string
  | Unit
  | Bool of bool
  | Data of Cardano_plutus.Plutus_data.t
  | List_of of constant list
  | Pair of constant * constant

type program = { version : int * int * int; body : term }
type error = [ `Not_implemented ]

let pp_error ppf = function
  | `Not_implemented ->
      Format.pp_print_string ppf
        "local Plutus evaluation is not implemented; execution budgets come \
         from the node's evaluateTransaction"

let evaluate _program ~args:_ ~budget:_ = Result.Error `Not_implemented
let deserialise _ = Result.Error `Not_implemented
