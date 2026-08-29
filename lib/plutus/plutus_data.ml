(* Plutus data.

   The encoder here does not go through Web3_codec_cbor for byte strings,
   because the ledger requires a form that codec deliberately will not emit:
   anything over 64 bytes must be an indefinite-length string of <=64-byte
   chunks. The codec is strict and definite-only on purpose, so the chunked
   form is written out directly. Everything else is built from codec values. *)

module C = Web3_codec_cbor
module T = Cardano_types

let ( let* ) = Result.bind
let err fmt = Printf.ksprintf (fun s -> Error s) fmt

type t =
  | Constr of { alternative : int; fields : t list }
  | Map of (t * t) list
  | List of t list
  | Int of int64
  | Big_int of { negative : bool; magnitude : string }
  | Bytes of string

let of_int n = Int (Int64.of_int n)
let max_definite_bytes = 64

(* The alternative-to-tag mapping the Plutus tooling uses: a compact range for
   the first seven constructors, a second range for the next hundred-odd, and a
   general form for anything past that. *)
let tag_of_alternative a =
  if a >= 0 && a <= 6 then Some (121 + a)
  else if a >= 7 && a <= 127 then Some (1280 + (a - 7))
  else None

let alternative_of_tag t =
  if t >= 121 && t <= 127 then Some (t - 121)
  else if t >= 1280 && t <= 1400 then Some (t - 1280 + 7)
  else None

let rec to_cbor = function
  | Constr { alternative; fields } -> (
      let inner = C.Array (List.map to_cbor fields) in
      match tag_of_alternative alternative with
      | Some tag -> C.Tag (tag, inner)
      | None ->
          C.Tag (102, C.Array [ C.uint_of_int alternative; inner ]))
  | Map kvs -> C.Map (List.map (fun (k, v) -> (to_cbor k, to_cbor v)) kvs)
  | List xs -> C.Array (List.map to_cbor xs)
  | Int n ->
      if Int64.compare n 0L >= 0 then C.Uint n
      else C.Nint (Int64.sub (Int64.neg n) 1L)
  | Big_int { negative; magnitude } -> C.Big { negative; magnitude }
  | Bytes b -> C.Bytes b

(* CBOR heads, written directly. Deriving them by encoding a dummy container
   and slicing the result -- which is what an earlier version of this did -- is
   both obscure and fragile; a head is a major type and an argument, and saying
   so is shorter than working around not saying it. *)
let head major arg =
  let m = major lsl 5 in
  let b = Buffer.create 9 in
  if arg < 24 then Buffer.add_char b (Char.chr (m lor arg))
  else if arg < 0x100 then (
    Buffer.add_char b (Char.chr (m lor 24));
    Buffer.add_char b (Char.chr arg))
  else if arg < 0x10000 then (
    Buffer.add_char b (Char.chr (m lor 25));
    Buffer.add_uint16_be b arg)
  else (
    Buffer.add_char b (Char.chr (m lor 26));
    Buffer.add_int32_be b (Int32.of_int arg));
  Buffer.contents b

(* An indefinite-length byte string: 0x5f, definite chunks of at most 64, 0xff.
   This is the only legal encoding for a Plutus byte string over 64 bytes, and
   it is why this module encodes to bytes rather than to a codec value: the
   codec is definite-only by design and will not produce it. *)
let chunked_bytes b =
  let n = String.length b in
  let buf = Buffer.create (n + 8) in
  Buffer.add_char buf '\x5f';
  let rec go i =
    if i < n then (
      let k = min max_definite_bytes (n - i) in
      Buffer.add_string buf (head 2 k);
      Buffer.add_substring buf b i k;
      go (i + k))
  in
  go 0;
  Buffer.add_char buf '\xff';
  Buffer.contents buf

let rec encode = function
  | Bytes b when String.length b > max_definite_bytes -> chunked_bytes b
  | Constr { alternative; fields } -> (
      let body = head 4 (List.length fields) ^ encode_seq fields in
      match tag_of_alternative alternative with
      | Some tag -> head 6 tag ^ body
      | None ->
          head 6 102 ^ head 4 2
          ^ Web3_codec_cbor.encode (Web3_codec_cbor.uint_of_int alternative)
          ^ body)
  | Map kvs ->
      head 5 (List.length kvs)
      ^ String.concat "" (List.map (fun (k, v) -> encode k ^ encode v) kvs)
  | List xs -> head 4 (List.length xs) ^ encode_seq xs
  | other -> C.encode (to_cbor other)

and encode_seq xs = String.concat "" (List.map encode xs)

let rec of_value v =
  match v with
  | C.Tag (102, C.Array [ a; C.Array fields ]) ->
      let* alternative =
        match C.int_value a with
        | Some n when n >= 0 -> Ok n
        | _ -> err "constr alternative is not a non-negative integer"
      in
      let* fields = seq fields in
      Ok (Constr { alternative; fields })
  | C.Tag (t, C.Array fields) -> (
      match alternative_of_tag t with
      | Some alternative ->
          let* fields = seq fields in
          Ok (Constr { alternative; fields })
      | None -> err "tag %d is not a plutus_data constructor" t)
  | C.Map kvs ->
      List.fold_left
        (fun acc (k, v) ->
          let* acc = acc in
          let* k = of_value k in
          let* v = of_value v in
          Ok ((k, v) :: acc))
        (Ok []) kvs
      |> Result.map (fun l -> Map (List.rev l))
  | C.Array xs ->
      let* xs = seq xs in
      Ok (List xs)
  | C.Uint n ->
      if Int64.compare n 0L >= 0 then Ok (Int n)
      else Ok (Big_int { negative = false; magnitude = be_of_uint n })
  | C.Nint n ->
      if Int64.compare n 0L >= 0 then Ok (Int (Int64.sub (Int64.neg n) 1L))
      else Ok (Big_int { negative = true; magnitude = be_of_uint n })
  | C.Big { negative; magnitude } -> Ok (Big_int { negative; magnitude })
  | C.Bytes b -> Ok (Bytes b)
  | _ -> err "not plutus_data"

and seq xs =
  List.fold_left
    (fun acc x -> let* acc = acc in let* y = of_value x in Ok (y :: acc))
    (Ok []) xs
  |> Result.map List.rev

(* An unsigned 64-bit value above Int64.max_int does not fit the Int
   constructor, so it becomes a bignum rather than a negative number. *)
and be_of_uint n =
  let b = Bytes.create 8 in
  Bytes.set_int64_be b 0 n;
  let s = Bytes.unsafe_to_string b in
  let i = ref 0 in
  while !i < 7 && s.[!i] = '\000' do incr i done;
  String.sub s !i (8 - !i)

(* Permissive, in the same spirit as the codec: a definite byte string over 64
   bytes is not legal Plutus data, but a decoder that refused it would be
   refusing to read something a peer might send, and the ledger will not have
   accepted it on chain anyway. {!encode} always produces the legal form, so a
   value that came in the wrong shape leaves in the right one -- which is a
   change of bytes, and therefore of hash, and is why anything hash-bearing
   keeps its own bytes rather than round-tripping through this type. *)
let decode s =
  let* v = C.of_octets s in
  of_value v

let hash d =
  match T.Hash.Datum_hash.of_bytes (T.blake2b256 (encode d)) with
  | Ok h -> h
  | Error m -> invalid_arg ("Plutus_data.hash: " ^ m)

let rec equal a b =
  match (a, b) with
  | Constr x, Constr y ->
      x.alternative = y.alternative && List.equal equal x.fields y.fields
  | Map x, Map y -> List.equal (fun (a, b) (c, d) -> equal a c && equal b d) x y
  | List x, List y -> List.equal equal x y
  | Int x, Int y -> Int64.equal x y
  | Big_int x, Big_int y -> x.negative = y.negative && String.equal x.magnitude y.magnitude
  | Bytes x, Bytes y -> String.equal x y
  | _ -> false

let rec pp ppf = function
  | Constr { alternative; fields } ->
      Format.fprintf ppf "@[<hov 2>Constr %d [%a]@]" alternative
        (Format.pp_print_list ~pp_sep:(fun f () -> Format.fprintf f ",@ ") pp) fields
  | Map kvs ->
      Format.fprintf ppf "@[<hov 2>{%a}@]"
        (Format.pp_print_list ~pp_sep:(fun f () -> Format.fprintf f ",@ ")
           (fun f (k, v) -> Format.fprintf f "%a: %a" pp k pp v))
        kvs
  | List xs ->
      Format.fprintf ppf "@[<hov 2>[%a]@]"
        (Format.pp_print_list ~pp_sep:(fun f () -> Format.fprintf f ",@ ") pp) xs
  | Int n -> Format.fprintf ppf "%Ld" n
  | Big_int { negative; magnitude } ->
      Format.fprintf ppf "%sbignum(%d bytes)" (if negative then "-" else "")
        (String.length magnitude)
  | Bytes b -> Format.fprintf ppf "0x%s(%d bytes)"
                 (if String.length b > 4 then "..." else "") (String.length b)
