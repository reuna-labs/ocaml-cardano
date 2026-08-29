(* Fee arithmetic.

   Everything is exact rational over int64 and errors on overflow. Nothing here
   goes through float: the rounding points are specified, and a float would
   round somewhere else by an amount too small to see and large enough to have
   a transaction rejected. *)

module T = Cardano_types
module R = T.Rational
module P = T.Protocol_params

let ( let* ) = Result.bind

let coin v =
  Result.map_error
    (fun e -> Format.asprintf "%a" T.Coin.pp_error e)
    (T.Coin.of_lovelace v)

(* From eras/babbage/impl/src/Cardano/Ledger/Babbage/TxOut.hs:692 --
   an approximation of the TxIn plus the map entry holding it, 20 words of
   8 bytes. A constant in the implementation, not a protocol parameter. *)
let utxo_entry_overhead = 160L

let min_utxo (pp : P.t) (o : Body.Output.t) =
  let size = Int64.of_int (String.length (Web3_codec_cbor.encode (Body.Output.to_cbor o))) in
  let* r = R.of_int64 (Int64.add utxo_entry_overhead size) in
  let* r = R.mul_int64 r pp.P.coins_per_utxo_byte in
  coin (R.floor r)

let meets_min_utxo pp o =
  let* need = min_utxo pp o in
  Ok (T.Coin.compare o.Body.Output.value.T.Value.coin need >= 0)

(* Raising the ada lengthens the output, and a longer output needs more ada.
   The step is bounded -- a CBOR integer grows by whole bytes -- so this
   converges in a couple of rounds. Erroring rather than raising the bound: if
   it has not settled by now the model is wrong, and a larger loop would only
   hide that. *)
let settled_min_utxo pp o =
  let rec go n candidate =
    if n > 8 then Error "minimum-value fixpoint did not settle"
    else
      let probe = { o with Body.Output.value = { o.Body.Output.value with T.Value.coin = candidate } } in
      let* need = min_utxo pp probe in
      if T.Coin.compare need candidate <= 0 then Ok candidate
      else go (n + 1) need
  in
  let* start = min_utxo pp o in
  go 0 start

(* tierRefScriptFee, eras/conway/impl/src/Cardano/Ledger/Conway/Tx.hs:122-142.

     go !acc !curTierPrice !n
       | n < sizeIncrement = Coin $ floor (acc + toRational n * curTierPrice)
       | otherwise = go (acc + sizeIncrementRational * curTierPrice)
                        (multiplier * curTierPrice) (n - sizeIncrement)

   The stride and multiplier are ledger constants (ConwayPParams.hs:984-985),
   but Ogmios reports them next to the base rate, so they are read from the
   parameters rather than baked in here. With a 25 600-byte stride and
   transactions capped near 16 KB the loop body does not run in practice; it is
   implemented so that a change upstream does not quietly produce wrong fees. *)
let tier_ref_script_fee (pp : P.t) size =
  if size < 0 then Error "reference-script size is negative"
  else if pp.P.ref_script_range <= 0 then
    Error "reference-script tier width is not positive"
  else
    let stride = pp.P.ref_script_range in
    let stride_r = R.of_int64 (Int64.of_int stride) |> Result.get_ok in
    let rec go acc tier_price n =
      if n < stride then
        let* nr = R.of_int64 (Int64.of_int n) in
        let* term = R.mul nr tier_price in
        let* total = R.add acc term in
        (* floor, not ceil: see the .mli. *)
        coin (R.floor total)
      else
        let* whole = R.mul stride_r tier_price in
        let* acc = R.add acc whole in
        let* tier_price = R.mul pp.P.ref_script_multiplier tier_price in
        go acc tier_price (n - stride)
    in
    go R.zero pp.P.min_fee_ref_script_coins_per_byte size

let script_fee (pp : P.t) (u : P.ex_units) =
  let* m = R.mul_int64 pp.P.price_mem u.P.mem in
  let* s = R.mul_int64 pp.P.price_steps u.P.steps in
  let* total = R.add m s in
  coin (R.ceil total)

let min_fee (pp : P.t) ~tx_size ?(ex_units = P.ex_units_zero)
    ?(ref_scripts_size = 0) () =
  if tx_size < 0 then Error "transaction size is negative"
  else
    let* base = R.of_int64 pp.P.min_fee_a in
    let* base = R.mul_int64 base (Int64.of_int tx_size) in
    let* b = R.of_int64 pp.P.min_fee_b in
    let* base = R.add base b in
    let* base = coin (R.floor base) in
    let* scripts = script_fee pp ex_units in
    let* refs = tier_ref_script_fee pp ref_scripts_size in
    let* t = Result.map_error (fun e -> Format.asprintf "%a" T.Coin.pp_error e)
        (T.Coin.add base scripts) in
    Result.map_error (fun e -> Format.asprintf "%a" T.Coin.pp_error e)
      (T.Coin.add t refs)

let required_collateral (pp : P.t) fee =
  let* r = R.of_ratio (T.Coin.to_lovelace fee) 100L in
  let* r = R.mul_int64 r (Int64.of_int pp.P.collateral_percentage) in
  coin (R.ceil r)
