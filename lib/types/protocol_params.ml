type ex_units = { mem : int64; steps : int64 }

let ex_units_zero = { mem = 0L; steps = 0L }

let ex_units_add a b =
  let add what x y =
    let s = Int64.add x y in
    if Int64.compare s 0L < 0 then
      Error (Printf.sprintf "ex_units: %s overflowed int64" what)
    else Ok s
  in
  Result.bind (add "mem" a.mem b.mem) (fun mem ->
      Result.map (fun steps -> { mem; steps }) (add "steps" a.steps b.steps))

type t = {
  min_fee_a : int64;
  min_fee_b : int64;
  max_tx_size : int;
  coins_per_utxo_byte : int64;
  price_mem : Cardano_rational.t;
  price_steps : Cardano_rational.t;
  max_tx_ex_units : ex_units;
  collateral_percentage : int;
  max_collateral_inputs : int;
  min_fee_ref_script_coins_per_byte : Cardano_rational.t;
  ref_script_range : int;
  ref_script_multiplier : Cardano_rational.t;
}

let ratio n d =
  match Cardano_rational.of_ratio n d with
  | Ok r -> r
  | Error m -> invalid_arg ("Protocol_params: " ^ m)

let mainnet_snapshot =
  {
    min_fee_a = 44L;
    min_fee_b = 155_381L;
    max_tx_size = 16_384;
    coins_per_utxo_byte = 4_310L;
    price_mem = ratio 577L 10_000L;
    price_steps = ratio 721L 10_000_000L;
    max_tx_ex_units = { mem = 14_000_000L; steps = 10_000_000_000L };
    collateral_percentage = 150;
    max_collateral_inputs = 3;
    min_fee_ref_script_coins_per_byte = ratio 15L 1L;
    ref_script_range = 25_600;
    ref_script_multiplier = ratio 6L 5L;
  }
