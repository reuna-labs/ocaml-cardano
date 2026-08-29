type t = Mainnet | Testnet of { magic : int32 }

let mainnet = Mainnet
let preview = Testnet { magic = 2l }
let preprod = Testnet { magic = 1l }
let id = function Mainnet -> 1 | Testnet _ -> 0

(* A four-bit network id cannot name a testnet, so decoding one has to pick a
   representative. Preview is the launch target; callers who know better say so
   with with_magic. *)
let of_id = function
  | 1 -> Ok Mainnet
  | 0 -> Ok preview
  | n -> Error (Printf.sprintf "network: id %d is neither 0 nor 1" n)

let with_magic m = if m = 764824073l then Mainnet else Testnet { magic = m }
let magic = function Mainnet -> 764824073l | Testnet { magic } -> magic
let equal a b = Int32.equal (magic a) (magic b)

let pp ppf = function
  | Mainnet -> Format.pp_print_string ppf "mainnet"
  | Testnet { magic = 1l } -> Format.pp_print_string ppf "preprod"
  | Testnet { magic = 2l } -> Format.pp_print_string ppf "preview"
  | Testnet { magic } -> Format.fprintf ppf "testnet(magic %ld)" magic
