(* Conway transaction bodies, per spec/conway.cddl:

   transaction_body =
     {   0 : set<transaction_input>   ,   1 : [* transaction_output]
     ,   2 : coin ; fee
     , ? 3 : slot ; ttl               , ? 4 : certificates
     , ? 5 : withdrawals              , ? 7 : auxiliary_data_hash
     , ? 8 : slot ; validity start    , ? 9 : mint
     , ? 11: script_data_hash         , ? 13: nonempty_set<transaction_input>
     , ? 14: required_signers         , ? 15: network_id
     , ? 16: transaction_output       , ? 17: coin ; total collateral
     , ? 18: nonempty_set<transaction_input>
     , ? 19: voting_procedures        , ? 20: proposal_procedures
     , ? 21: coin                     , ? 22: positive_coin } *)

module C = Web3_codec_cbor
module T = Cardano_types
module H = T.Hash
module Addr = Cardano_address.Address

let ( let* ) = Result.bind
let err fmt = Printf.ksprintf (fun s -> Error s) fmt

(* A set may be written bare or wrapped in tag 258, and both mean the same
   thing. Decoding accepts either; encoding emits the tag, which is what
   current tooling produces. Since a decoded body re-encodes from its preserved
   bytes, this choice only reaches bodies we build ourselves. *)
let set_tag = 258

let as_list = function
  | C.Array xs -> Ok xs
  | C.Tag (t, C.Array xs) when t = set_tag -> Ok xs
  | _ -> err "expected an array or a tagged set"

let encode_set items = C.Tag (set_tag, C.Array items)

let uint_of = function
  | C.Uint n -> Ok n
  | C.Nint _ -> err "expected a non-negative integer"
  | _ -> err "expected an integer"

let int_of v =
  let* n = uint_of v in
  if Int64.unsigned_compare n (Int64.of_int max_int) <= 0 then Ok (Int64.to_int n)
  else err "integer does not fit in this runtime"

let bytes_of = function C.Bytes b -> Ok b | _ -> err "expected a byte string"

let coin_of v =
  let* n = uint_of v in
  Result.map_error
    (fun e -> Format.asprintf "%a" T.Coin.pp_error e)
    (T.Coin.of_lovelace n)

let coin_cbor c = C.Uint (T.Coin.to_lovelace c)

module Input = struct
  type t = { tx_id : H.Tx_id.t; index : int }

  let make tx_id index =
    if index < 0 || index > 0xffff then
      err "transaction input index %d is outside uint .size 2" index
    else Ok { tx_id; index }

  let compare a b =
    match H.Tx_id.compare a.tx_id b.tx_id with
    | 0 -> Int.compare a.index b.index
    | c -> c

  let equal a b = compare a b = 0
  let pp ppf t = Format.fprintf ppf "%s#%d" (H.Tx_id.to_hex t.tx_id) t.index

  let to_cbor t = C.Array [ C.Bytes (H.Tx_id.to_bytes t.tx_id); C.uint_of_int t.index ]

  let of_cbor = function
    | C.Array [ id; ix ] ->
        let* b = bytes_of id in
        let* tx_id = H.Tx_id.of_bytes b in
        let* index = int_of ix in
        make tx_id index
    | _ -> err "transaction_input is a two-element array"
end

module Datum = struct
  type t = Hash of H.Datum_hash.t | Inline of string
end

module Value_codec = struct
  (* value = coin / [coin, multiasset<positive_coin>]. A bundle with no assets
     is written as a bare coin, which is also how it must be read back for the
     bytes to match. *)
  let to_cbor (v : T.Value.t) =
    if T.Multi_asset.is_empty v.T.Value.assets then coin_cbor v.T.Value.coin
    else
      let by_policy = Hashtbl.create 8 in
      List.iter
        (fun ((a : T.asset), q) ->
          let cur = try Hashtbl.find by_policy a.T.policy with Not_found -> [] in
          Hashtbl.replace by_policy a.T.policy ((a.T.name, q) :: cur))
        (T.Multi_asset.to_list v.T.Value.assets);
      let policies =
        List.sort_uniq H.Script_hash.compare
          (Hashtbl.fold (fun k _ acc -> k :: acc) by_policy [])
      in
      C.Array
        [ coin_cbor v.T.Value.coin;
          C.Map
            (List.map
               (fun p ->
                 ( C.Bytes (H.Script_hash.to_bytes p),
                   C.Map
                     (List.map
                        (fun (n, q) ->
                          ( C.Bytes (T.Asset_name.to_bytes n),
                            C.Uint (T.Quantity.to_int64_unsigned q) ))
                        (List.rev (Hashtbl.find by_policy p))) ))
               policies) ]

  let of_cbor = function
    | (C.Uint _ | C.Nint _) as v ->
        let* c = coin_of v in
        Ok (T.Value.of_coin c)
    | C.Array [ c; C.Map policies ] ->
        let* coin = coin_of c in
        let* entries =
          List.fold_left
            (fun acc (pk, pv) ->
              let* acc = acc in
              let* pb = bytes_of pk in
              let* policy = H.Script_hash.of_bytes pb in
              match pv with
              | C.Map names ->
                  List.fold_left
                    (fun acc (nk, nv) ->
                      let* acc = acc in
                      let* nb = bytes_of nk in
                      let* name = T.Asset_name.of_bytes nb in
                      let* q = uint_of nv in
                      let* q = T.Quantity.of_int64_unsigned q in
                      Ok ((T.asset policy name, q) :: acc))
                    (Ok acc) names
              | _ -> err "multiasset policy must map to a map of asset names")
            (Ok []) policies
        in
        let* assets = T.Multi_asset.of_list (List.rev entries) in
        Ok (T.Value.make coin assets)
    | _ -> err "value is a coin or a [coin, multiasset] pair"
end

module Output = struct
  type t = {
    address : Addr.t;
    value : T.Value.t;
    datum : Datum.t option;
    script_ref : string option;
  }

  let make ?datum ?script_ref address value = { address; value; datum; script_ref }

  let pp ppf t =
    Format.fprintf ppf "%s -> %a"
      (match Addr.to_bech32 t.address with Ok s -> s | Error _ -> "<byron>")
      T.Value.pp t.value

  (* Babbage map form on the way out; Alonzo array form still accepted on the
     way in, since the CDDL calls the two "equally valid and interchangeable"
     and plenty of chain history uses the older one. *)
  let to_cbor t =
    let fields =
      [ (C.Uint 0L, C.Bytes (Addr.to_bytes t.address));
        (C.Uint 1L, Value_codec.to_cbor t.value) ]
      @ (match t.datum with
        | None -> []
        | Some (Datum.Hash h) ->
            [ (C.Uint 2L, C.Array [ C.Uint 0L; C.Bytes (H.Datum_hash.to_bytes h) ]) ]
        | Some (Datum.Inline b) ->
            [ (C.Uint 2L, C.Array [ C.Uint 1L; C.Tag (24, C.Bytes b) ]) ])
      @ match t.script_ref with
        | None -> []
        | Some s -> [ (C.Uint 3L, C.Tag (24, C.Bytes s)) ]
    in
    C.Map fields

  let datum_of = function
    | C.Array [ C.Uint 0L; h ] ->
        let* b = bytes_of h in
        let* h = H.Datum_hash.of_bytes b in
        Ok (Datum.Hash h)
    | C.Array [ C.Uint 1L; C.Tag (24, C.Bytes b) ] -> Ok (Datum.Inline b)
    | _ -> err "datum_option is [0, hash32] or [1, #6.24(bytes)]"

  let of_cbor = function
    | C.Map fields ->
        let find k =
          List.find_map (fun (kk, v) -> if kk = C.Uint k then Some v else None) fields
        in
        let* addr_b = match find 0L with Some v -> bytes_of v | None -> err "output has no address" in
        let* address = Result.map_error (fun e -> Format.asprintf "%a" Addr.pp_error e) (Addr.of_bytes addr_b) in
        let* value = match find 1L with Some v -> Value_codec.of_cbor v | None -> err "output has no value" in
        let* datum =
          match find 2L with None -> Ok None | Some v -> Result.map Option.some (datum_of v)
        in
        let* script_ref =
          match find 3L with
          | None -> Ok None
          | Some (C.Tag (24, C.Bytes b)) -> Ok (Some b)
          | Some _ -> err "script_ref is #6.24(bytes)"
        in
        Ok { address; value; datum; script_ref }
    | C.Array (addr :: v :: rest) ->
        let* addr_b = bytes_of addr in
        let* address = Result.map_error (fun e -> Format.asprintf "%a" Addr.pp_error e) (Addr.of_bytes addr_b) in
        let* value = Value_codec.of_cbor v in
        let* datum =
          match rest with
          | [] -> Ok None
          | [ h ] ->
              let* b = bytes_of h in
              let* h = H.Datum_hash.of_bytes b in
              Ok (Some (Datum.Hash h))
          | _ -> err "alonzo output has at most three fields"
        in
        Ok { address; value; datum; script_ref = None }
    | _ -> err "transaction_output is a map or an array"
end

type t = {
  inputs : Input.t list;
  outputs : Output.t list;
  fee : T.Coin.t;
  ttl : int64 option;
  validity_start : int64 option;
  mint : T.Mint.t option;
  network_id : T.Network.t option;
  collateral : Input.t list;
  reference_inputs : Input.t list;
  required_signers : H.Addr_key_hash.t list;
  collateral_return : Output.t option;
  total_collateral : T.Coin.t option;
  script_data_hash : H.Script_data_hash.t option;
  aux_data_hash : H.Aux_data_hash.t option;
  carried : (int * C.t) list;
  raw : string option;
}

let empty =
  {
    inputs = []; outputs = []; fee = T.Coin.zero; ttl = None;
    validity_start = None; mint = None; network_id = None; collateral = [];
    reference_inputs = []; required_signers = []; collateral_return = None;
    total_collateral = None; script_data_hash = None; aux_data_hash = None;
    carried = []; raw = None;
  }

let mint_cbor (m : T.Mint.t) =
  let by_policy = Hashtbl.create 8 in
  List.iter
    (fun ((a : T.asset), d) ->
      let cur = try Hashtbl.find by_policy a.T.policy with Not_found -> [] in
      Hashtbl.replace by_policy a.T.policy ((a.T.name, d) :: cur))
    (T.Mint.to_list m);
  let policies =
    List.sort_uniq H.Script_hash.compare
      (Hashtbl.fold (fun k _ acc -> k :: acc) by_policy [])
  in
  C.Map
    (List.map
       (fun p ->
         ( C.Bytes (H.Script_hash.to_bytes p),
           C.Map
             (List.map
                (fun (n, d) ->
                  ( C.Bytes (T.Asset_name.to_bytes n),
                    (* nonzero_int64: negative is a burn. *)
                    if Int64.compare d 0L >= 0 then C.Uint d
                    else C.Nint (Int64.sub (Int64.neg d) 1L) ))
                (List.rev (Hashtbl.find by_policy p))) ))
       policies)

let mint_of = function
  | C.Map policies ->
      let* entries =
        List.fold_left
          (fun acc (pk, pv) ->
            let* acc = acc in
            let* pb = bytes_of pk in
            let* policy = H.Script_hash.of_bytes pb in
            match pv with
            | C.Map names ->
                List.fold_left
                  (fun acc (nk, nv) ->
                    let* acc = acc in
                    let* nb = bytes_of nk in
                    let* name = T.Asset_name.of_bytes nb in
                    let* d =
                      match nv with
                      | C.Uint n -> Ok n
                      | C.Nint n -> Ok (Int64.neg (Int64.add n 1L))
                      | _ -> err "mint quantity must be an integer"
                    in
                    Ok ((T.asset policy name, d) :: acc))
                  (Ok acc) names
            | _ -> err "mint policy must map to a map of asset names")
          (Ok []) policies
      in
      T.Mint.of_list (List.rev entries)
  | _ -> err "mint is a map of policies"

let to_cbor t =
  match t.raw with
  | Some b -> b
  | None ->
      let opt k f = function None -> [] | Some v -> [ (C.Uint k, f v) ] in
      let lst k f = function [] -> [] | xs -> [ (C.Uint k, encode_set (List.map f xs)) ] in
      let fields =
        [ (C.Uint 0L, encode_set (List.map Input.to_cbor t.inputs));
          (C.Uint 1L, C.Array (List.map Output.to_cbor t.outputs));
          (C.Uint 2L, coin_cbor t.fee) ]
        @ opt 3L (fun v -> C.Uint v) t.ttl
        @ opt 7L (fun h -> C.Bytes (H.Aux_data_hash.to_bytes h)) t.aux_data_hash
        @ opt 8L (fun v -> C.Uint v) t.validity_start
        @ opt 9L mint_cbor t.mint
        @ opt 11L (fun h -> C.Bytes (H.Script_data_hash.to_bytes h)) t.script_data_hash
        @ lst 13L Input.to_cbor t.collateral
        @ lst 14L (fun h -> C.Bytes (H.Addr_key_hash.to_bytes h)) t.required_signers
        @ opt 15L (fun n -> C.uint_of_int (T.Network.id n)) t.network_id
        @ opt 16L Output.to_cbor t.collateral_return
        @ opt 17L coin_cbor t.total_collateral
        @ lst 18L Input.to_cbor t.reference_inputs
        @ List.map (fun (k, v) -> (C.uint_of_int k, v)) t.carried
      in
      C.encode (C.Map fields)

let is_verbatim t = t.raw <> None

let of_cbor s =
  let* v = C.of_octets s in
  match v with
  | C.Map fields ->
      let find k =
        List.find_map (fun (kk, vv) -> if kk = C.Uint (Int64.of_int k) then Some vv else None) fields
      in
      (* Key 6 was Babbage's `update` field. Conway removed it. A body that
         carries one is not a Conway body, and quietly ignoring it would mean
         signing a structure whose meaning we have not modelled. *)
      if find 6 <> None then
        err "body carries key 6 (update), which Conway removed -- this is not a Conway body"
      else
        let opt k f = match find k with None -> Ok None | Some v -> Result.map Option.some (f v) in
        let lst k f =
          match find k with
          | None -> Ok []
          | Some v ->
              let* items = as_list v in
              List.fold_left
                (fun acc it -> let* acc = acc in let* x = f it in Ok (x :: acc))
                (Ok []) items
              |> Result.map List.rev
        in
        let* inputs = lst 0 Input.of_cbor in
        let* outputs =
          match find 1 with
          | Some (C.Array xs) ->
              List.fold_left
                (fun acc it -> let* acc = acc in let* x = Output.of_cbor it in Ok (x :: acc))
                (Ok []) xs
              |> Result.map List.rev
          | Some _ -> err "outputs must be an array"
          | None -> err "body has no outputs"
        in
        let* fee = match find 2 with Some v -> coin_of v | None -> err "body has no fee" in
        let* ttl = opt 3 uint_of in
        let* aux_data_hash = opt 7 (fun v -> let* b = bytes_of v in H.Aux_data_hash.of_bytes b) in
        let* validity_start = opt 8 uint_of in
        let* mint = opt 9 mint_of in
        let* script_data_hash =
          opt 11 (fun v -> let* b = bytes_of v in H.Script_data_hash.of_bytes b)
        in
        let* collateral = lst 13 Input.of_cbor in
        let* required_signers =
          lst 14 (fun v -> let* b = bytes_of v in H.Addr_key_hash.of_bytes b)
        in
        let* network_id =
          opt 15 (fun v ->
              let* n = int_of v in
              T.Network.of_id n)
        in
        let* collateral_return = opt 16 Output.of_cbor in
        let* total_collateral = opt 17 coin_of in
        let* reference_inputs = lst 18 Input.of_cbor in
        let carried =
          List.filter_map
            (fun (k, v) ->
              match k with
              | C.Uint n ->
                  let n = Int64.to_int n in
                  if List.mem n [ 4; 5; 19; 20; 21; 22 ] then Some (n, v) else None
              | _ -> None)
            fields
        in
        Ok
          { inputs; outputs; fee; ttl; validity_start; mint; network_id;
            collateral; reference_inputs; required_signers; collateral_return;
            total_collateral; script_data_hash; aux_data_hash; carried;
            raw = Some s }
  | _ -> err "transaction_body is a map"

let id t =
  match H.Tx_id.of_bytes (T.blake2b256 (to_cbor t)) with
  | Ok h -> h
  | Error m -> invalid_arg ("Body.id: " ^ m)

let pp ppf t =
  Format.fprintf ppf "@[<v>tx %s@,%d input(s), %d output(s), fee %a%s@]"
    (H.Tx_id.to_hex (id t))
    (List.length t.inputs) (List.length t.outputs) T.Coin.pp t.fee
    (if t.carried = [] then ""
     else Printf.sprintf ", %d uninterpreted field(s)" (List.length t.carried))
