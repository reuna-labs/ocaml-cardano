(* Checked lovelace arithmetic. Modelled on ocaml-bitcoin's Amount for the same
   reason: the failure mode of an unchecked amount is not a wrong number on a
   screen, it is a transaction that moves the wrong quantity. *)

type t = int64

type error =
  [ `Overflow of string | `Invalid_range | `Invalid_format ]

let pp_error ppf = function
  | `Overflow op -> Format.fprintf ppf "coin: %s overflowed" op
  | `Invalid_range -> Format.pp_print_string ppf "coin: out of range"
  | `Invalid_format -> Format.pp_print_string ppf "coin: malformed decimal"

let lovelace_per_ada = 1_000_000L

(* 45e9 ada. Int64.max_int is about 9.2e18, so a sum of two valid coins cannot
   wrap before the range check sees it -- which is what makes `add` safe to
   write as "add, then check". *)
let max_supply_i64 = 45_000_000_000_000_000L
let zero = 0L
let max_supply = max_supply_i64

let in_range v = v >= 0L && v <= max_supply_i64
let of_lovelace v = if in_range v then Ok v else Error `Invalid_range
let to_lovelace t = t

let of_lovelace_exn v =
  if in_range v then v
  else invalid_arg "Coin.of_lovelace_exn: outside [0, max_supply]"

let add a b =
  let r = Int64.add a b in
  if r < a then Error (`Overflow "add") else if in_range r then Ok r else Error `Invalid_range

let sub a b = if b > a then Error (`Overflow "sub") else Ok (Int64.sub a b)

let mul a n =
  if n < 0 then Error `Invalid_range
  else if n = 0 then Ok 0L
  else
    let n64 = Int64.of_int n in
    (* Check before multiplying rather than after: after is too late, the
       product has already wrapped and the check would pass on garbage. *)
    if a > Int64.div max_supply_i64 n64 then Error (`Overflow "mul")
    else
      let r = Int64.mul a n64 in
      if in_range r then Ok r else Error `Invalid_range

let diff a b =
  if a = b then `Zero
  else if a > b then `Pos (Int64.sub a b)
  else `Neg (Int64.sub b a)

let sum xs =
  List.fold_left (fun acc x -> Result.bind acc (fun a -> add a x)) (Ok zero) xs

let compare = Int64.compare
let equal = Int64.equal
let min a b = if a <= b then a else b
let max a b = if a >= b then a else b

let to_ada_string t =
  let whole = Int64.div t lovelace_per_ada
  and frac = Int64.rem t lovelace_per_ada in
  if frac = 0L then Int64.to_string whole
  else
    let s = Printf.sprintf "%06Ld" frac in
    let last = ref (String.length s - 1) in
    while !last > 0 && s.[!last] = '0' do decr last done;
    Printf.sprintf "%Ld.%s" whole (String.sub s 0 (!last + 1))

let of_ada_string s =
  let n = String.length s in
  if n = 0 then Error `Invalid_format
  else
    let dot = String.index_opt s '.' in
    let whole_s, frac_s =
      match dot with
      | None -> (s, "")
      | Some i -> (String.sub s 0 i, String.sub s (i + 1) (n - i - 1))
    in
    let digits x = x <> "" && String.for_all (function '0' .. '9' -> true | _ -> false) x in
    if not (digits whole_s) then Error `Invalid_format
    else if String.length frac_s > 6 then Error `Invalid_format
    else if frac_s <> "" && not (digits frac_s) then Error `Invalid_format
    else
      (* Pad rather than parse-and-scale, so no intermediate ever loses a digit. *)
      let frac_s = frac_s ^ String.make (6 - String.length frac_s) '0' in
      match Int64.of_string_opt (whole_s ^ frac_s) with
      | None -> Error `Invalid_format
      | Some v -> if in_range v then Ok v else Error `Invalid_range

let pp ppf t = Format.fprintf ppf "%s ada" (to_ada_string t)
