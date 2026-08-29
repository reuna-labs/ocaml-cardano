(* The RPC layer, exercised without a socket.

   Everything here is pure: the framing takes strings, the provider is a
   functor, and the transport in these tests is a table of canned replies. That
   is the same property that lets the client run inside a unikernel with no TCP
   stack, so testing it this way is not a shortcut. *)

module R = Cardano_rpc
module T = Cardano_types
module P = T.Protocol_params

let get = function
  | Ok v -> v
  | Error e -> Alcotest.failf "unexpected error: %a" R.Error.pp e

let read_file p =
  let ic = open_in_bin p in
  let n = in_channel_length ic in
  let s = really_input_string ic n in
  close_in ic;
  s

(* A provider whose "network" is one canned reply. *)
module Canned = R.Provider.Of_text (struct
  type t = string
  type 'a io = 'a

  let return x = x
  let bind x f = f x
  let exchange reply _request = Ok reply
end)

module Client = R.Provider.Make (Canned)

let request_framing () =
  let m = R.Ogmios.query_tip () in
  let s = R.Codec.request ~id:7 m in
  let j = Yojson.Safe.from_string s in
  let field k = match j with `Assoc kvs -> List.assoc_opt k kvs | _ -> None in
  Alcotest.(check (option string)) "jsonrpc version" (Some "2.0")
    (match field "jsonrpc" with Some (`String s) -> Some s | _ -> None);
  Alcotest.(check (option string)) "method name" (Some "queryLedgerState/tip")
    (match field "method" with Some (`String s) -> Some s | _ -> None);
  Alcotest.(check bool) "id is carried" true (field "id" = Some (`Int 7));
  (* A method with no parameters must not send an empty params object: Ogmios
     distinguishes absent from empty for some queries. *)
  Alcotest.(check bool) "no params field when there are none" true
    (field "params" = None);
  let with_params = R.Codec.request ~id:1 (R.Ogmios.query_utxo_by_address [ "addr1x" ]) in
  Alcotest.(check bool) "params present when there are some" true
    (String.length with_params > 0
     && (match Yojson.Safe.from_string with_params with
         | `Assoc kvs -> List.mem_assoc "params" kvs
         | _ -> false))

let protocol_parameters_from_ogmios_vector () =
  let body = read_file "../conformance/fixtures/ogmios-protocol-parameters.json" in
  let pp = get (Client.call body (R.Ogmios.query_protocol_parameters ())) in
  (* Values from the vector itself. They are deliberately implausible -- it is a
     schema vector, not a ledger state -- which is exactly why it exercises the
     range limits as well as the shapes. *)
  Alcotest.(check int64) "minFeeCoefficient" 76_399L pp.P.min_fee_a;
  Alcotest.(check int64) "minFeeConstant, unwrapped from ada.lovelace" 30L pp.P.min_fee_b;
  Alcotest.(check int) "maxTransactionSize, unwrapped from bytes" 14_285 pp.P.max_tx_size;
  Alcotest.(check int64) "minUtxoDepositCoefficient" 10_780_188L pp.P.coins_per_utxo_byte;
  Alcotest.(check int) "collateralPercentage" 29_529 pp.P.collateral_percentage;
  Alcotest.(check int) "maxCollateralInputs" 11_062 pp.P.max_collateral_inputs;
  (* An execution budget near 2^63. Reading these as anything narrower than
     int64 would wrap. *)
  Alcotest.(check int64) "maxExecutionUnits memory" 6_852_459_139_119_258_802L
    pp.P.max_tx_ex_units.P.mem;
  Alcotest.(check int64) "maxExecutionUnits cpu" 1_779_215_926_808_906_173L
    pp.P.max_tx_ex_units.P.steps;
  (* Exact ratio strings must stay exact -- these have 19-digit numerators, and
     a float would lose them entirely. *)
  Alcotest.(check string) "scriptExecutionPrices.memory stays exact"
    "1602135494687083999/2500"
    (Format.asprintf "%a" T.Rational.pp pp.P.price_mem);
  Alcotest.(check string) "scriptExecutionPrices.cpu stays exact"
    "2945388662683978413/5000000000000000"
    (Format.asprintf "%a" T.Rational.pp pp.P.price_steps);
  (* And the reference-script curve is read, not assumed. *)
  Alcotest.(check int) "reference-script range comes from the node" 25_600
    pp.P.ref_script_range;
  Alcotest.(check string) "and the multiplier too" "6/5"
    (Format.asprintf "%a" T.Rational.pp pp.P.ref_script_multiplier)

(* The base rate arrives as a JSON number that has already been through a
   double, so exactness is not recoverable. What we can insist on is that the
   recovery is the shortest decimal that round-trips, rather than a float
   smuggled into the fee calculation. *)
let float_valued_parameter () =
  let r = get (Result.map_error (fun m -> R.Error.Decode { method_ = "-"; reason = m })
                 (T.Rational.of_decimal_string "1.2")) in
  Alcotest.(check string) "1.2 is exactly 6/5" "6/5" (Format.asprintf "%a" T.Rational.pp r);
  let r = get (Result.map_error (fun m -> R.Error.Decode { method_ = "-"; reason = m })
                 (T.Rational.of_decimal_string "15")) in
  Alcotest.(check string) "an integer has denominator one" "15"
    (Format.asprintf "%a" T.Rational.pp r);
  let body = read_file "../conformance/fixtures/ogmios-protocol-parameters.json" in
  let pp = get (Client.call body (R.Ogmios.query_protocol_parameters ())) in
  (* Exactly the digits the node wrote -- 8262.760762845264 over 10^12,
     reduced. Not %.17g's 8262.7607628452643, whose final digit would be
     precision invented on the node's behalf. *)
  Alcotest.(check string) "the base rate recovers to the digits the node sent"
    "516422547677829/62500000000"
    (Format.asprintf "%a" T.Rational.pp pp.P.min_fee_ref_script_coins_per_byte);
  let r = pp.P.min_fee_ref_script_coins_per_byte in
  Alcotest.(check bool) "and it is the value the node meant" true
    (Float.abs
       (Int64.to_float (T.Rational.num r) /. Int64.to_float (T.Rational.den r)
        -. 8262.760762845264)
     < 1e-9)

let errors_are_typed () =
  (* An error object, as Ogmios returns for an era mismatch. *)
  let body =
    {|{"jsonrpc":"2.0","method":"queryLedgerState/protocolParameters",
       "error":{"code":2001,"message":"Era mismatch between query and ledger.",
                "data":{"ledgerEra":"shelley","queryEra":"byron"}},"id":null}|}
  in
  (match Client.call body (R.Ogmios.query_protocol_parameters ()) with
   | Error (R.Error.Rpc { code; message; data }) ->
       Alcotest.(check int) "code survives" 2001 code;
       Alcotest.(check bool) "message survives" true (String.length message > 0);
       (* The reason lives in `data`; flattening it into the message would lose
          the only machine-readable part. *)
       Alcotest.(check bool) "and so does the data" true (data <> None)
   | Error e -> Alcotest.failf "wrong error: %a" R.Error.pp e
   | Ok _ -> Alcotest.fail "an error object decoded as a result");
  (* A reply to somebody else's request must not be read as ours. *)
  let m = R.Ogmios.query_epoch () in
  (match R.Codec.response ~id:1 m {|{"jsonrpc":"2.0","method":"queryLedgerState/epoch","result":5,"id":2}|} with
   | Error (R.Error.Id_mismatch _) -> ()
   | _ -> Alcotest.fail "an id mismatch was not caught");
  (* Ogmios echoes the method; a reply for a different one is a correlation
     failure, not an answer. *)
  (match R.Codec.response ~id:1 m {|{"jsonrpc":"2.0","method":"queryLedgerState/tip","result":5,"id":1}|} with
   | Error (R.Error.Invalid_response _) -> ()
   | _ -> Alcotest.fail "a method mismatch was not caught");
  (match R.Codec.response ~id:1 m "not json at all" with
   | Error (R.Error.Malformed_json _) -> ()
   | _ -> Alcotest.fail "malformed JSON was not caught");
  (* Only transport failures are worth retrying. *)
  Alcotest.(check bool) "transport failures retry" true
    (R.Error.is_retryable (R.Error.Transport "reset"));
  Alcotest.(check bool) "ledger rejections do not" false
    (R.Error.is_retryable (R.Error.Rpc { code = 3005; message = "x"; data = None }))

let () =
  Alcotest.run "cardano-rpc"
    [ ("framing",
       [ Alcotest.test_case "request" `Quick request_framing;
         Alcotest.test_case "typed errors" `Quick errors_are_typed ]);
      ("ogmios",
       [ Alcotest.test_case "protocol parameters" `Quick protocol_parameters_from_ogmios_vector;
         Alcotest.test_case "float-valued parameter" `Quick float_valued_parameter ]) ]
