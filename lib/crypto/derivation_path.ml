(* CIP-1852 paths. The model is ocaml-bitcoin's Derivation_path, which already
   had the awkward parts right: hardened indices are a range rather than a flag,
   and both spellings of the marker have to be accepted on input. *)

type hardened_marker = [ `Apostrophe | `H ]
type t = int32 list

let hardened_bit = 0x80000000l
let is_hardened i = Int32.compare i 0l < 0
let empty = []
let of_list l = l
let to_list t = t
let append t i = t @ [ i ]
let depth = List.length
let equal = List.equal Int32.equal

let parent = function
  | [] -> None
  | l -> Some (List.filteri (fun i _ -> i < List.length l - 1) l)

let child t n ~hardened =
  if n < 0 || n >= 0x80000000 then Error `Invalid_range
  else
    let i = Int32.of_int n in
    Ok (append t (if hardened then Int32.logor i hardened_bit else i))

let to_string ?(marker = `Apostrophe) t =
  let m = match marker with `Apostrophe -> "'" | `H -> "h" in
  let one i =
    if is_hardened i then
      Printf.sprintf "%lu%s" (Int32.logand i (Int32.lognot hardened_bit)) m
    else Printf.sprintf "%lu" i
  in
  String.concat "/" ("m" :: List.map one t)

let of_string s =
  let parts = String.split_on_char '/' s in
  let parts = match parts with ("m" | "M") :: rest -> rest | rest -> rest in
  let parse acc p =
    match acc with
    | Error _ as e -> e
    | Ok acc -> (
        let n = String.length p in
        if n = 0 then Error `Invalid_format
        else
          let hardened, digits =
            match p.[n - 1] with
            | '\'' | 'h' | 'H' -> (true, String.sub p 0 (n - 1))
            | _ -> (false, p)
          in
          if
            digits = ""
            || not
                 (String.for_all
                    (function '0' .. '9' -> true | _ -> false)
                    digits)
          then Error `Invalid_format
          else
            match Int32.of_string_opt digits with
            | None -> Error `Invalid_format
            | Some i ->
                (* An unmarked index at or above 2^31 would be read as hardened
                   while claiming not to be. Refuse it rather than guess. *)
                (* Int32.of_string accepts the full unsigned range and wraps,
                   so an out-of-range index arrives here as a negative. *)
                if Int32.compare i 0l < 0 then Error `Invalid_format
                else
                  Ok
                    ((if hardened then Int32.logor i hardened_bit else i) :: acc)
        )
  in
  match List.fold_left parse (Ok []) parts with
  | Ok l -> Ok (List.rev l)
  | Error _ as e -> e

let purpose = 1852l
let coin_type = 1815l

type role = External | Internal | Staking | Drep

let role_index = function
  | External -> 0l
  | Internal -> 1l
  | Staking -> 2l
  | Drep -> 3l

let harden i = Int32.logor i hardened_bit

(* An Int32 spans -2^31 .. 2^31-1, so "below 2^31" is exactly "not negative".
   Comparing against hardened_bit would compare against Int32.min_int and
   reject everything. *)
let in_soft_range i = Int32.compare i 0l >= 0

let account ~account =
  if not (in_soft_range account) then Error `Invalid_range
  else Ok [ harden purpose; harden coin_type; harden account ]

let address ~account:a ~role ~index =
  if not (in_soft_range index) then Error `Invalid_range
  else Result.map (fun p -> p @ [ role_index role; index ]) (account ~account:a)

let stake ~account:a = address ~account:a ~role:Staking ~index:0l
