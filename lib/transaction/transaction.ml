module C = Web3_codec_cbor

let ( let* ) = Result.bind
let err fmt = Printf.ksprintf (fun s -> Error s) fmt

type t = {
  body : Body.t;
  witness_set : Witness.t;
  is_valid : bool;
  auxiliary_data : C.t option;
  raw : string option;
}

(* The body is element 0 of the outer array. Its bytes are lifted out of the
   input by span rather than re-encoded from the decoded value: the transaction
   id is the hash of those exact bytes, and the sender may well have chosen a
   spelling this library would not emit. *)
let body_span tx =
  if String.length tx = 0 then err "empty transaction"
  else
    let b = Char.code tx.[0] in
    let major = b lsr 5 and ai = b land 0x1f in
    if major <> 4 then err "transaction is a four-element array"
    else
      let* after_head =
        if ai < 24 then Ok 1
        else if ai = 24 then Ok 2
        else if ai = 25 then Ok 3
        else if ai = 26 then Ok 5
        else if ai = 27 then Ok 9
        else err "transaction array must have a definite length"
      in
      match C.read_span tx after_head with
      | _, { C.off; C.len }, _ -> Ok (off, len)
      | exception C.Error m -> err "%s" m

let of_cbor s =
  let* off, len = body_span s in
  let* body = Body.of_cbor (String.sub s off len) in
  let* v = C.of_octets s in
  match v with
  | C.Array [ _; ws; flag; aux ] ->
      let* witness_set = Witness.of_value ws in
      let* is_valid =
        match flag with
        | C.Bool b -> Ok b
        | _ -> err "the validity flag is a boolean"
      in
      let auxiliary_data = match aux with C.Null -> None | x -> Some x in
      Ok { body; witness_set; is_valid; auxiliary_data; raw = Some s }
  | C.Array xs -> err "transaction has %d elements, expected 4" (List.length xs)
  | _ -> err "transaction is an array"

let to_cbor t =
  match t.raw with
  | Some b -> b
  | None ->
      C.encode
        (C.Array
           [
             (match C.of_octets (Body.to_cbor t.body) with
             | Ok v -> v
             | Error m -> invalid_arg ("Transaction.to_cbor: " ^ m));
             Witness.cbor t.witness_set;
             C.Bool t.is_valid;
             (match t.auxiliary_data with None -> C.Null | Some a -> a);
           ])

let id t = Body.id t.body

(* The signed message is the transaction id -- the hash of the body -- not the
   body itself. *)
let signing_payload t = Cardano_types.Hash.Tx_id.to_bytes (id t)

(* Attaching a witness changes the envelope but not the body, so the body keeps
   its preserved bytes (and therefore its id) while the transaction loses
   its own. *)
let with_witnesses t witness_set = { t with witness_set; raw = None }

let sign t key =
  let pub = Cardano_crypto.Key.Xprv.public key in
  let vkey = Cardano_crypto.Key.Xpub.raw pub in
  let signature = Cardano_crypto.Key.Xprv.sign key (signing_payload t) in
  match Witness.Vkey.make ~vkey ~signature with
  | Ok w -> with_witnesses t (Witness.add_vkey t.witness_set w)
  | Error m -> invalid_arg ("Transaction.sign: " ^ m)

let add_signature t ~vkey ~signature =
  let* w = Witness.Vkey.make ~vkey ~signature in
  if not (Witness.Vkey.verify w (id t)) then
    err
      "signature does not verify against this transaction id (%s) -- it \
       was        made over different bytes, or by a different key"
      (Cardano_types.Hash.Tx_id.to_hex (id t))
  else Ok (with_witnesses t (Witness.add_vkey t.witness_set w))

let witnesses t = t.witness_set.Witness.vkeys
let signed_by t = List.map Witness.Vkey.key_hash (witnesses t)

let pp ppf t =
  Format.fprintf ppf "@[<v>%a@,%a%s@]" Body.pp t.body Witness.pp t.witness_set
    (if t.is_valid then "" else " [marked invalid]")
