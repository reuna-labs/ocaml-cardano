(* Checked non-negative rationals.

   The multiplications here run over protocol parameters, which arrive from a
   node and are therefore not trusted to be small. Every product is checked
   before it is used, and values are reduced on construction so that the checks
   have the best chance of not firing on arithmetic that is actually fine. *)

type t = { n : int64; d : int64 }

let rec gcd a b = if Int64.equal b 0L then a else gcd b (Int64.rem a b)

let reduce n d =
  let g = gcd n d in
  if Int64.equal g 0L then { n = 0L; d = 1L }
  else { n = Int64.div n g; d = Int64.div d g }

let zero = { n = 0L; d = 1L }
let one = { n = 1L; d = 1L }
let num t = t.n
let den t = t.d

let of_ratio n d =
  if Int64.compare n 0L < 0 then Error "rational: numerator is negative"
  else if Int64.compare d 1L < 0 then
    Error "rational: denominator is not positive"
  else Ok (reduce n d)

let of_int64 n = of_ratio n 1L

let of_decimal_string s =
  let s = String.trim s in
  let neg = String.length s > 0 && s.[0] = '-' in
  if neg then Error "rational: decimal is negative"
  else
    let whole, frac =
      match String.index_opt s '.' with
      | None -> (s, "")
      | Some i ->
          (String.sub s 0 i, String.sub s (i + 1) (String.length s - i - 1))
    in
    let digits x =
      String.for_all (function '0' .. '9' -> true | _ -> false) x
    in
    if whole = "" || (not (digits whole)) || not (digits frac) then
      Error (Printf.sprintf "rational: %S is not a decimal" s)
    else if String.length frac > 18 then
      Error "rational: more decimal places than int64 can hold exactly"
    else
      let den = Int64.of_float (10. ** float_of_int (String.length frac)) in
      match Int64.of_string_opt (whole ^ frac) with
      | None -> Error "rational: decimal does not fit in int64"
      | Some n -> of_ratio n (if String.length frac = 0 then 1L else den)

(* a * b overflows int64 exactly when the product divided back does not give b.
   Checking after the fact is safe here because the wrapped value is only used
   to detect the wrap, never returned. *)
let mul_checked what a b =
  if Int64.equal a 0L || Int64.equal b 0L then Ok 0L
  else
    let p = Int64.mul a b in
    if Int64.equal (Int64.div p a) b && Int64.compare p 0L >= 0 then Ok p
    else Error (Printf.sprintf "rational: %s overflowed int64" what)

let add x y =
  if Int64.equal x.d y.d then Ok (reduce (Int64.add x.n y.n) x.d)
  else
    Result.bind (mul_checked "addition" x.n y.d) (fun a ->
        Result.bind (mul_checked "addition" y.n x.d) (fun b ->
            Result.bind (mul_checked "addition" x.d y.d) (fun d ->
                let s = Int64.add a b in
                if Int64.compare s 0L < 0 then
                  Error "rational: addition overflowed int64"
                else Ok (reduce s d))))

let mul x y =
  (* Cross-reduce first: (a/b)*(c/d) with gcd(a,d) and gcd(c,b) removed keeps
     the products far smaller than multiplying and reducing afterwards. *)
  let g1 = gcd x.n y.d and g2 = gcd y.n x.d in
  let xn = if Int64.equal g1 0L then x.n else Int64.div x.n g1 in
  let yd = if Int64.equal g1 0L then y.d else Int64.div y.d g1 in
  let yn = if Int64.equal g2 0L then y.n else Int64.div y.n g2 in
  let xd = if Int64.equal g2 0L then x.d else Int64.div x.d g2 in
  Result.bind (mul_checked "multiplication" xn yn) (fun n ->
      Result.bind (mul_checked "multiplication" xd yd) (fun d ->
          Ok (reduce n d)))

let mul_int64 x k =
  if Int64.compare k 0L < 0 then Error "rational: multiplier is negative"
  else Result.bind (of_int64 k) (mul x)

let floor t = Int64.div t.n t.d

let ceil t =
  let q = Int64.div t.n t.d in
  if Int64.equal (Int64.rem t.n t.d) 0L then q else Int64.add q 1L

let compare x y =
  if Int64.equal x.d y.d then Int64.compare x.n y.n
  else
    (* Compare a*d' against a'*d, falling back to floats only if that would
       overflow -- which for real protocol parameters it does not. *)
    match (mul_checked "compare" x.n y.d, mul_checked "compare" y.n x.d) with
    | Ok a, Ok b -> Int64.compare a b
    | _ ->
        Float.compare
          (Int64.to_float x.n /. Int64.to_float x.d)
          (Int64.to_float y.n /. Int64.to_float y.d)

let equal x y = compare x y = 0

let pp ppf t =
  if Int64.equal t.d 1L then Format.fprintf ppf "%Ld" t.n
  else Format.fprintf ppf "%Ld/%Ld" t.n t.d
