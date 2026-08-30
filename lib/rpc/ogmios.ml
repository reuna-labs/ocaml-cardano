(* Ogmios v7.0.0 method catalogue.

   Ogmios reports protocol parameters by name and the ledger CDDL by number.
   The mapping is written down in docs/conway-spec-pin.md, because it is where
   a rename upstream would otherwise slip through as a silently wrong fee. *)

module T = Cardano_types
module P = T.Protocol_params
module Tx = Cardano_transaction

let ( let* ) = Result.bind
let err fmt = Printf.ksprintf (fun s -> Error s) fmt
let member k = function `Assoc kvs -> List.assoc_opt k kvs | _ -> None

let req k j =
  match member k j with Some v -> Ok v | None -> err "no %S field" k

let as_int64 = function
  | `Int n -> Ok (Int64.of_int n)
  | `Intlit s -> (
      match Int64.of_string_opt s with
      | Some n -> Ok n
      | None -> err "integer out of range")
  | j -> err "expected an integer, got %s" (Yojson.Safe.to_string j)

let as_int j = Result.map Int64.to_int (as_int64 j)
let as_string = function `String s -> Ok s | _ -> err "expected a string"
let as_list = function `List l -> Ok l | _ -> err "expected an array"

let hex_to_bytes h =
  let n = String.length h in
  if n mod 2 <> 0 then err "odd-length hex"
  else
    try
      Ok
        (String.init (n / 2) (fun i ->
             Char.chr (int_of_string ("0x" ^ String.sub h (i * 2) 2))))
    with _ -> err "not hexadecimal"

let map_r f l =
  List.fold_left
    (fun acc x ->
      let* acc = acc in
      let* y = f x in
      Ok (y :: acc))
    (Ok []) l
  |> Result.map List.rev

(* ---- tip ---- *)

type tip = { slot : int64; id : string; height : int64 }

let ( >>= ) x f = Result.bind x f

let tip_of_json j =
  let* slot = req "slot" j >>= as_int64 in
  let* id = match member "id" j with Some v -> as_string v | None -> Ok "" in
  let* height =
    match member "height" j with Some v -> as_int64 v | None -> Ok 0L
  in
  Ok { slot; id; height }

let query_network_tip () = Method.make ~name:"queryNetwork/tip" tip_of_json
let query_tip () = Method.make ~name:"queryLedgerState/tip" tip_of_json

let query_network_start_time () =
  Method.make ~name:"queryNetwork/startTime" as_string

let query_genesis_configuration era =
  Method.make ~name:"queryNetwork/genesisConfiguration"
    ~params:(`Assoc [ ("era", `String era) ])
    (fun j -> Ok j)

let query_epoch () = Method.make ~name:"queryLedgerState/epoch" as_int64

(* ---- protocol parameters ---- *)

(* Ogmios writes most ratios as "num/den" strings, which parse exactly. One
   does not: minFeeReferenceScripts.base arrives as a JSON number, e.g.
   8262.760762845264. By then it has been through a double and whatever exact
   rational the ledger holds is gone, so the best available recovery is its
   shortest round-tripping decimal. Recorded here rather than hidden, because
   it means a reference-script fee computed from an Ogmios-supplied base rate
   is only as exact as Ogmios made it. *)
let number_as_ratio f =
  (* The shortest decimal that round-trips, found by widening precision until
     it does. %.17g would also round-trip, but it is not shortest: for
     8262.760762845264 it yields 8262.7607628452643, and that trailing digit is
     precision we would be inventing rather than recovering. *)
  let rec shortest p =
    if p > 17 then Printf.sprintf "%.17g" f
    else
      let s = Printf.sprintf "%.*g" p f in
      if float_of_string s = f then s else shortest (p + 1)
  in
  T.Rational.of_decimal_string (shortest 1)

let ratio_of_json j =
  match j with
  | `Float f -> number_as_ratio f
  | `Int n -> T.Rational.of_int64 (Int64.of_int n)
  | _ -> (
      let* s = as_string j in
      match String.index_opt s '/' with
      | None -> (
          match Int64.of_string_opt s with
          | Some n -> T.Rational.of_int64 n
          | None -> err "%S is not a ratio" s)
      | Some i -> (
          let n = String.sub s 0 i
          and d = String.sub s (i + 1) (String.length s - i - 1) in
          match (Int64.of_string_opt n, Int64.of_string_opt d) with
          | Some n, Some d -> T.Rational.of_ratio n d
          | _ -> err "%S is not a ratio" s))

let lovelace_of_json j =
  match member "ada" j with
  | Some a -> req "lovelace" a >>= as_int64
  | None -> as_int64 j

let ex_units_of_json j =
  let* mem = req "memory" j >>= as_int64 in
  let* steps = req "cpu" j >>= as_int64 in
  Ok { P.mem; P.steps }

let protocol_parameters_of_json j =
  let* min_fee_a = req "minFeeCoefficient" j >>= as_int64 in
  let* min_fee_b = req "minFeeConstant" j >>= lovelace_of_json in
  let* max_tx_size =
    match member "maxTransactionSize" j with
    | Some v -> req "bytes" v >>= as_int
    | None -> Ok 16384
  in
  let* coins_per_utxo_byte = req "minUtxoDepositCoefficient" j >>= as_int64 in
  let* prices = req "scriptExecutionPrices" j in
  let* price_mem = req "memory" prices >>= ratio_of_json in
  let* price_steps = req "cpu" prices >>= ratio_of_json in
  let* max_tx_ex_units =
    req "maxExecutionUnitsPerTransaction" j >>= ex_units_of_json
  in
  let* collateral_percentage = req "collateralPercentage" j >>= as_int in
  let* max_collateral_inputs = req "maxCollateralInputs" j >>= as_int in
  (* Ogmios reports the tier width and growth factor next to the base rate.
     They are ledger constants rather than protocol parameters, but reading
     them beats assuming them: if the ledger ever changes one, a node that
     knows will tell us. *)
  let* ( min_fee_ref_script_coins_per_byte,
         ref_script_range,
         ref_script_multiplier ) =
    match member "minFeeReferenceScripts" j with
    | None ->
        Ok (T.Rational.zero, 25_600, Result.get_ok (T.Rational.of_ratio 6L 5L))
    | Some v ->
        let* base = req "base" v >>= ratio_of_json in
        let* range =
          match member "range" v with Some r -> as_int r | None -> Ok 25_600
        in
        let* mult =
          match member "multiplier" v with
          | Some m -> ratio_of_json m
          | None -> T.Rational.of_ratio 6L 5L
        in
        Ok (base, range, mult)
  in
  Ok
    {
      P.min_fee_a;
      min_fee_b;
      max_tx_size;
      coins_per_utxo_byte;
      price_mem;
      price_steps;
      max_tx_ex_units;
      collateral_percentage;
      max_collateral_inputs;
      min_fee_ref_script_coins_per_byte;
      ref_script_range;
      ref_script_multiplier;
    }

let query_protocol_parameters () =
  Method.make ~name:"queryLedgerState/protocolParameters"
    protocol_parameters_of_json

(* ---- utxo ---- *)

type utxo_entry = { input : Tx.Body.Input.t; output : Tx.Body.Output.t }

let value_of_json j =
  let* coin = lovelace_of_json j in
  let* coin =
    Result.map_error
      (fun e -> Format.asprintf "%a" T.Coin.pp_error e)
      (T.Coin.of_lovelace coin)
  in
  let entries =
    match j with
    | `Assoc kvs -> List.filter (fun (k, _) -> k <> "ada") kvs
    | _ -> []
  in
  let* assets =
    List.fold_left
      (fun acc (policy_hex, names) ->
        let* acc = acc in
        let* pb = hex_to_bytes policy_hex in
        let* policy = T.Hash.Script_hash.of_bytes pb in
        match names with
        | `Assoc ns ->
            List.fold_left
              (fun acc (name_hex, q) ->
                let* acc = acc in
                let* nb = hex_to_bytes name_hex in
                let* name = T.Asset_name.of_bytes nb in
                let* q = as_int64 q in
                let* q = T.Quantity.of_int64_unsigned q in
                Ok ((T.asset policy name, q) :: acc))
              (Ok acc) ns
        | _ -> err "asset map expected")
      (Ok []) entries
  in
  let* assets = T.Multi_asset.of_list assets in
  Ok (T.Value.make coin assets)

let utxo_entry_of_json j =
  let* tx = req "transaction" j in
  let* id_hex = req "id" tx >>= as_string in
  let* id_b = hex_to_bytes id_hex in
  let* tx_id = T.Hash.Tx_id.of_bytes id_b in
  let* index = req "index" j >>= as_int in
  let* input = Tx.Body.Input.make tx_id index in
  let* addr_s = req "address" j >>= as_string in
  let* address =
    Result.map_error
      (fun e -> Format.asprintf "%a" Cardano_address.Address.pp_error e)
      (Cardano_address.Address.of_bech32 addr_s)
  in
  let* value = req "value" j >>= value_of_json in
  Ok { input; output = Tx.Body.Output.make address value }

let utxo_decoder j = as_list j >>= map_r utxo_entry_of_json

let query_utxo_by_address addresses =
  Method.make ~name:"queryLedgerState/utxo"
    ~params:
      (`Assoc [ ("addresses", `List (List.map (fun a -> `String a) addresses)) ])
    utxo_decoder

let query_utxo_by_input inputs =
  Method.make ~name:"queryLedgerState/utxo"
    ~params:
      (`Assoc
         [
           ( "outputReferences",
             `List
               (List.map
                  (fun (i : Tx.Body.Input.t) ->
                    `Assoc
                      [
                        ( "transaction",
                          `Assoc
                            [
                              ( "id",
                                `String
                                  (T.Hash.Tx_id.to_hex i.Tx.Body.Input.tx_id) );
                            ] );
                        ("index", `Int i.Tx.Body.Input.index);
                      ])
                  inputs) );
         ])
    utxo_decoder

(* ---- evaluation and submission ---- *)

type evaluation = { validator : string; budget : P.ex_units }

let evaluation_of_json j =
  let* validator =
    match member "validator" j with
    | Some (`String s) -> Ok s
    | Some (`Assoc _ as v) ->
        let* purpose = req "purpose" v >>= as_string in
        let* index = req "index" v >>= as_int in
        Ok (Printf.sprintf "%s:%d" purpose index)
    | _ -> err "no validator field"
  in
  let* budget = req "budget" j >>= ex_units_of_json in
  Ok { validator; budget }

let evaluate_transaction cbor_hex =
  Method.make ~name:"evaluateTransaction"
    ~params:(`Assoc [ ("transaction", `Assoc [ ("cbor", `String cbor_hex) ]) ])
    (fun j -> as_list j >>= map_r evaluation_of_json)

let submit_transaction cbor_hex =
  Method.make ~name:"submitTransaction"
    ~params:(`Assoc [ ("transaction", `Assoc [ ("cbor", `String cbor_hex) ]) ])
    (fun j ->
      let* tx = req "transaction" j in
      let* id_hex = req "id" tx >>= as_string in
      let* b = hex_to_bytes id_hex in
      T.Hash.Tx_id.of_bytes b)
