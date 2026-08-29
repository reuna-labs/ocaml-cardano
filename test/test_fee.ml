(* Fee arithmetic. The constants and rounding are cited in
   docs/conway-spec-pin.md against the ledger source; these tests pin the
   arithmetic that implements them. *)

module T = Cardano_types
module P = T.Protocol_params
module F = Cardano_transaction.Fee
module B = Cardano_transaction.Body
module A = Cardano_address.Address

let get = function Ok v -> v | Error m -> Alcotest.failf "unexpected error: %s" m
let pp = P.mainnet_snapshot
let lov c = T.Coin.to_lovelace c

let addr () =
  get (Result.map_error (fun _ -> "addr")
    (A.of_bech32 "addr1vx2fxv2umyhttkxyxp8x0dlpdt3k6cwng5pxj3jhsydzers66hrl8"))

let base_address () =
  get (Result.map_error (fun _ -> "addr")
    (A.of_bech32
       "addr1qx2fxv2umyhttkxyxp8x0dlpdt3k6cwng5pxj3jhsydzer3n0d3vllmyqwsx5wktcd8cc3sq835lu7drv2xwl2wywfgse35a3x"))

(* The two figures the ledger source states in the comment beside
   babbageMinUTxOValue, at coinsPerUTxOByte = 4310:

     "the absolute minimum value will be 857690, because TxOut without staking
      address can't be less than 39 bytes"
     "A simple TxOut with staking and payment credentials with ADA only
      amount of 978370 lovelace"

   Both fall out of (160 + size) * 4310 and neither was fitted to: they are what
   this implementation produces for an enterprise and a base output. That is the
   check that the constant, the formula and the encoder all agree with the
   ledger at once. *)
let ledger_worked_example () =
  Alcotest.(check int64) "arithmetic behind the stated floor" 857_690L
    (Int64.mul (Int64.add 160L 39L) 4_310L);
  let one = T.Value.of_coin (get (Result.map_error (fun _ -> "c") (T.Coin.of_lovelace 1L))) in
  Alcotest.(check int64) "an enterprise output settles at the stated floor"
    857_690L
    (lov (get (F.settled_min_utxo pp (B.Output.make (addr ()) one))));
  Alcotest.(check int64) "a base output settles at the stated figure" 978_370L
    (lov (get (F.settled_min_utxo pp (B.Output.make (base_address ()) one))))

let min_utxo_shape () =
  let o = B.Output.make (addr ()) (T.Value.of_coin (get (Result.map_error (fun _ -> "c") (T.Coin.of_lovelace 1L)))) in
  let size = String.length (Web3_codec_cbor.encode (B.Output.to_cbor o)) in
  let need = get (F.min_utxo pp o) in
  Alcotest.(check int64) "min = (160 + size) * coinsPerUTxOByte"
    (Int64.mul (Int64.add 160L (Int64.of_int size)) 4_310L)
    (lov need);
  (* An enterprise output has one credential, so it sits near the ledger's
     stated floor rather than the base-address figure. *)
  Alcotest.(check bool) "a one-credential output is close to the stated floor"
    true (Int64.compare (lov need) 900_000L < 0);
  Alcotest.(check bool) "an output holding one lovelace does not meet it" false
    (get (F.meets_min_utxo pp o));
  (* And here is the circularity, made explicit rather than assumed away:
     putting `need` into the output makes the output longer, so `need` is no
     longer enough. This is why a builder needs a fixpoint. *)
  let funded = B.Output.make (addr ()) (T.Value.of_coin need) in
  Alcotest.(check bool)
    "holding exactly min_utxo is NOT yet enough -- the value made it longer"
    false (get (F.meets_min_utxo pp funded));
  let settled = get (F.settled_min_utxo pp o) in
  Alcotest.(check bool) "the settled value is larger" true
    (T.Coin.compare settled need > 0);
  let ok = B.Output.make (addr ()) (T.Value.of_coin settled) in
  Alcotest.(check bool) "and an output holding it does meet the minimum" true
    (get (F.meets_min_utxo pp ok));
  (* Settling is idempotent: the answer for a settled output is itself. *)
  Alcotest.(check int64) "settling is a fixpoint" (lov settled)
    (lov (get (F.settled_min_utxo pp ok)))

(* Reference scripts: constant price within a 25 600-byte tier, multiplied by
   6/5 at each boundary, and rounded DOWN at the end. *)
let reference_script_tiers () =
  let f n = lov (get (F.tier_ref_script_fee pp n)) in
  Alcotest.(check int64) "no reference scripts costs nothing" 0L (f 0);
  (* Inside the first tier the rate is flat at the base parameter, 15. *)
  Alcotest.(check int64) "1 byte" 15L (f 1);
  Alcotest.(check int64) "1000 bytes" 15_000L (f 1000);
  (* A transaction is capped near 16 KB, so in practice the tier loop never
     runs -- but it has to be right if a parameter ever changes. *)
  Alcotest.(check int64) "one full tier" (Int64.mul 25_600L 15L) (f 25_600);
  (* The next byte is priced at 15 * 6/5 = 18. *)
  Alcotest.(check int64) "one tier plus a byte"
    (Int64.add (Int64.mul 25_600L 15L) 18L) (f 25_601);
  (* Two full tiers: 25600*15 + 25600*18. *)
  Alcotest.(check int64) "two full tiers"
    (Int64.add (Int64.mul 25_600L 15L) (Int64.mul 25_600L 18L)) (f 51_200);
  (* Rounding down, not up. With a base rate of 15/2 a single byte costs 7.5,
     which must floor to 7. Rounding up here would overpay; the mirror-image
     mistake underpays, and an underpaid transaction is rejected. *)
  let half = { pp with P.min_fee_ref_script_coins_per_byte =
                        get (T.Rational.of_ratio 15L 2L) } in
  Alcotest.(check int64) "a fractional charge rounds down" 7L
    (lov (get (F.tier_ref_script_fee half 1)))

(* Execution units round UP, unlike reference scripts. Having both in one fee
   is exactly why each rounding point has to be pinned separately. *)
let execution_units_round_up () =
  let f m s = lov (get (F.script_fee pp { P.mem = m; P.steps = s })) in
  Alcotest.(check int64) "no scripts cost nothing" 0L (f 0L 0L);
  (* priceMem = 577/10000, so one memory unit costs 0.0577 and must ceil to 1. *)
  Alcotest.(check int64) "a fraction of a lovelace rounds up to one" 1L (f 1L 0L);
  (* 10000 mem * 577/10000 = 577 exactly, no rounding involved. *)
  Alcotest.(check int64) "an exact product does not round" 577L (f 10_000L 0L);
  (* priceSteps = 721/10^7. *)
  Alcotest.(check int64) "steps price exactly" 721L (f 0L 10_000_000L);
  (* The full mainnet execution budget must not overflow the checked
     arithmetic; a wrap here would be a fee off by billions. *)
  let max_units = pp.P.max_tx_ex_units in
  let full = f max_units.P.mem max_units.P.steps in
  Alcotest.(check bool) "the maximum budget computes without overflow" true
    (Int64.compare full 0L > 0);
  Alcotest.(check int64) "and equals ceil(577*14e6/1e4 + 721*1e10/1e7)"
    (Int64.add
       (Int64.div (Int64.mul 577L 14_000_000L) 10_000L)
       (Int64.div (Int64.mul 721L 10_000_000_000L) 10_000_000L))
    full

let base_fee () =
  (* minFeeA * size + minFeeB. *)
  Alcotest.(check int64) "an empty transaction is the constant term" 155_381L
    (lov (get (F.min_fee pp ~tx_size:0 ())));
  Alcotest.(check int64) "and each byte adds minFeeA"
    (Int64.add 155_381L (Int64.mul 44L 300L))
    (lov (get (F.min_fee pp ~tx_size:300 ())));
  (* A realistic simple transfer, for scale: ~300 bytes is about 0.17 ada. *)
  let simple = get (F.min_fee pp ~tx_size:300 ()) in
  Alcotest.(check string) "which reads as ada" "0.168581" (T.Coin.to_ada_string simple);
  Alcotest.(check bool) "a negative size is refused" true
    (match F.min_fee pp ~tx_size:(-1) () with Error _ -> true | Ok _ -> false)

let collateral () =
  let c f = lov (get (F.required_collateral pp (get (Result.map_error (fun _ -> "c") (T.Coin.of_lovelace f))))) in
  (* 150% of the fee, rounded up. *)
  Alcotest.(check int64) "150 percent" 300L (c 200L);
  Alcotest.(check int64) "and it rounds up" 2L (c 1L);
  Alcotest.(check int64) "a realistic fee" 300_000L (c 200_000L)

(* The rational layer is the thing that must not wrap, so it gets its own
   checks rather than only being exercised through the formulas. *)
let rational_is_exact () =
  let module R = T.Rational in
  let third = get (R.of_ratio 1L 3L) in
  Alcotest.(check int64) "1/3 floors to 0" 0L (R.floor third);
  Alcotest.(check int64) "1/3 ceils to 1" 1L (R.ceil third);
  let two_thirds = get (R.add third third) in
  Alcotest.(check bool) "1/3 + 1/3 = 2/3" true
    (R.equal two_thirds (get (R.of_ratio 2L 3L)));
  let one = get (R.add two_thirds third) in
  Alcotest.(check bool) "and three thirds are exactly one" true (R.equal one R.one);
  (* Reduced on construction, so equal values are equal. *)
  Alcotest.(check bool) "2/4 equals 1/2" true
    (R.equal (get (R.of_ratio 2L 4L)) (get (R.of_ratio 1L 2L)));
  (* Overflow is an error, not a wrap. *)
  Alcotest.(check bool) "overflow is refused" true
    (match R.mul_int64 (get (R.of_int64 Int64.max_int)) 2L with
     | Error _ -> true | Ok _ -> false);
  Alcotest.(check bool) "a negative denominator is refused" true
    (match R.of_ratio 1L 0L with Error _ -> true | Ok _ -> false)

let () =
  Alcotest.run "cardano-fee"
    [ ("minimum utxo",
       [ Alcotest.test_case "ledger worked example" `Quick ledger_worked_example;
         Alcotest.test_case "formula shape" `Quick min_utxo_shape ]);
      ("fees",
       [ Alcotest.test_case "base fee" `Quick base_fee;
         Alcotest.test_case "reference script tiers" `Quick reference_script_tiers;
         Alcotest.test_case "execution units round up" `Quick execution_units_round_up;
         Alcotest.test_case "collateral" `Quick collateral ]);
      ("arithmetic", [ Alcotest.test_case "rationals are exact" `Quick rational_is_exact ]) ]
