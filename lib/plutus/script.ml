module C = Web3_codec_cbor
module T = Cardano_types

type language = Native | Plutus_v1 | Plutus_v2 | Plutus_v3

let language_tag = function
  | Native -> '\x00'
  | Plutus_v1 -> '\x01'
  | Plutus_v2 -> '\x02'
  | Plutus_v3 -> '\x03'

let language_id = function
  | Native ->
      invalid_arg "Script.language_id: native scripts have no language id"
  | Plutus_v1 -> 0
  | Plutus_v2 -> 1
  | Plutus_v3 -> 2

type t = { language : language; bytes : string }

(* The tag is not decoration: without it the same bytes under two languages
   would hash alike, and two different scripts would share an address. *)
let hash t =
  let tagged = String.make 1 (language_tag t.language) ^ t.bytes in
  match T.Hash.Script_hash.of_bytes (T.blake2b224 tagged) with
  | Ok h -> h
  | Error m -> invalid_arg ("Script.hash: " ^ m)

type cost_models = (language * int64 list) list

let cbor_int n =
  if Int64.compare n 0L >= 0 then C.Uint n
  else C.Nint (Int64.sub (Int64.neg n) 1L)

(* An indefinite-length array: 0x9f, items, 0xff. Only PlutusV1's cost model is
   encoded this way, and only inside the language views. *)
let indefinite_array items =
  let b = Buffer.create 256 in
  Buffer.add_char b '\x9f';
  List.iter (fun i -> Buffer.add_string b (C.encode (cbor_int i))) items;
  Buffer.add_char b '\xff';
  Buffer.contents b

let language_views models =
  (* Both halves of a V1 entry are doubly encoded, and neither is a mistake.
     The key is the language id written as an integer and then that integer's
     encoding wrapped in a byte string, which is why V1's key is 4100 -- a
     one-byte byte string containing 0x00. The value is the cost model as an
     indefinite list, wrapped in a byte string in turn. *)
  let entry (lang, costs) =
    match lang with
    | Native -> None
    | Plutus_v1 ->
        let key = C.encode (C.Bytes (C.encode (C.uint_of_int 0))) in
        let value = C.encode (C.Bytes (indefinite_array costs)) in
        Some (key, value)
    | (Plutus_v2 | Plutus_v3) as l ->
        let key = C.encode (C.uint_of_int (language_id l)) in
        let value = C.encode (C.Array (List.map cbor_int costs)) in
        Some (key, value)
  in
  let entries = List.filter_map entry models in
  (* RFC 7049 section 3.9: shorter keys sort first, then bytewise. Not the
     ordering used anywhere else in this library, and using the other one here
     produces a wrong hash rather than an error. *)
  let sorted =
    List.stable_sort
      (fun (a, _) (b, _) ->
        let la = String.length a and lb = String.length b in
        if la <> lb then compare la lb else String.compare a b)
      entries
  in
  let b = Buffer.create 512 in
  (* Map header, definite, written directly since the pieces are already
     encoded bytes. *)
  let n = List.length sorted in
  if n < 24 then Buffer.add_char b (Char.chr (0xa0 lor n))
  else (
    Buffer.add_char b (Char.chr (0xa0 lor 24));
    Buffer.add_char b (Char.chr n));
  List.iter
    (fun (k, v) ->
      Buffer.add_string b k;
      Buffer.add_string b v)
    sorted;
  Buffer.contents b

let empty_map = "\xa0"

let script_data_hash ~redeemers ~datums ~cost_models =
  let datums_bytes =
    match datums with
    | [] -> ""
    | ds ->
        (* Datums appear as an array, in witness-set order. *)
        let n = List.length ds in
        let hdr =
          if n < 24 then String.make 1 (Char.chr (0x80 lor n))
          else
            String.init 2 (fun i ->
                if i = 0 then Char.chr (0x80 lor 24) else Char.chr n)
        in
        hdr ^ String.concat "" ds
  in
  let preimage =
    match (redeemers, datums) with
    | None, [] -> language_views cost_models
    | None, _ ->
        (* Datums but no redeemers: A0 || datums || A0. This changed in Conway,
           when the default redeemer representation became a map -- the empty
           redeemers are now an empty map rather than an empty array. *)
        empty_map ^ datums_bytes ^ empty_map
    | Some r, [] -> r ^ language_views cost_models
    | Some r, _ -> r ^ datums_bytes ^ language_views cost_models
  in
  match T.Hash.Script_data_hash.of_bytes (T.blake2b256 preimage) with
  | Ok h -> h
  | Error m -> invalid_arg ("Script.script_data_hash: " ^ m)
