module C = Web3_codec_cbor
module T = Cardano_types
module H = T.Hash

let ( let* ) = Result.bind
let err fmt = Printf.ksprintf (fun s -> Error s) fmt

(* nonempty_list and nonempty_set both admit tag 258 or a bare array. *)
let list_tag = 258

let as_list = function
  | C.Array xs -> Ok xs
  | C.Tag (t, C.Array xs) when t = list_tag -> Ok xs
  | _ -> err "expected an array or a tagged list"

module Vkey = struct
  type t = { vkey : string; signature : string }

  let make ~vkey ~signature =
    if String.length vkey <> 32 then
      err "vkey witness: public key is %d bytes, expected 32"
        (String.length vkey)
    else if String.length signature <> 64 then
      err "vkey witness: signature is %d bytes, expected 64"
        (String.length signature)
    else Ok { vkey; signature }

  let key_hash t =
    match H.Addr_key_hash.of_bytes (T.blake2b224 t.vkey) with
    | Ok h -> h
    | Error m -> invalid_arg ("Witness.Vkey.key_hash: " ^ m)

  (* The signed message is the transaction id itself -- the 32-byte hash --
     rather than the body it was computed from. *)
  let verify t tx_id =
    Cardano_crypto.Key.verify_raw ~vkey:t.vkey ~signature:t.signature
      (H.Tx_id.to_bytes tx_id)

  let pp ppf t =
    Format.fprintf ppf "vkey %s" (H.Addr_key_hash.to_hex (key_hash t))

  let to_cbor t = C.Array [ C.Bytes t.vkey; C.Bytes t.signature ]

  let of_cbor = function
    | C.Array [ C.Bytes vkey; C.Bytes signature ] -> make ~vkey ~signature
    | _ -> err "vkeywitness is [vkey, signature]"
end

type t = {
  vkeys : Vkey.t list;
  carried : (int * C.t) list;
  raw : string option;
}

let empty = { vkeys = []; carried = []; raw = None }
let is_empty t = t.vkeys = [] && t.carried = []

let cbor t =
  let fields =
    (match t.vkeys with
      | [] -> []
      | vs ->
          [ (C.Uint 0L, C.Tag (list_tag, C.Array (List.map Vkey.to_cbor vs))) ])
    @ List.map (fun (k, v) -> (C.uint_of_int k, v)) t.carried
  in
  C.Map fields

let to_cbor t = match t.raw with Some b -> b | None -> C.encode (cbor t)

let of_value = function
  | C.Map fields ->
      let find k =
        List.find_map
          (fun (kk, vv) ->
            if kk = C.Uint (Int64.of_int k) then Some vv else None)
          fields
      in
      let* vkeys =
        match find 0 with
        | None -> Ok []
        | Some v ->
            let* items = as_list v in
            List.fold_left
              (fun acc it ->
                let* acc = acc in
                let* w = Vkey.of_cbor it in
                Ok (w :: acc))
              (Ok []) items
            |> Result.map List.rev
      in
      let carried =
        List.filter_map
          (fun (k, v) ->
            match k with
            | C.Uint n ->
                let n = Int64.to_int n in
                if n >= 1 && n <= 7 then Some (n, v) else None
            | _ -> None)
          fields
      in
      Ok { vkeys; carried; raw = None }
  | _ -> err "transaction_witness_set is a map"

let of_cbor s =
  let* v = C.of_octets s in
  let* t = of_value v in
  Ok { t with raw = Some s }

let add_vkey t w =
  if List.exists (fun x -> String.equal x.Vkey.vkey w.Vkey.vkey) t.vkeys then t
  else
    (* The set has changed, so any bytes we were preserving no longer describe
       it. Keeping them would re-encode the old set under the new one's name. *)
    { t with vkeys = t.vkeys @ [ w ]; raw = None }

let pp ppf t =
  Format.fprintf ppf "%d key witness(es)%s" (List.length t.vkeys)
    (if t.carried = [] then ""
     else Printf.sprintf ", %d uninterpreted field(s)" (List.length t.carried))
