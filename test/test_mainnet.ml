(* Real Cardano mainnet transactions, checked against the ids the chain gave
   them.

   Everything else in this suite proves the encoder agrees with itself. These
   are the only vectors this repository did not produce, so they are the ones
   that prove it agrees with the ledger -- including about the spellings the
   ledger permits and our encoder would not have chosen.

   Provenance is in conformance/README.md. *)

module Tx = Cardano_transaction.Transaction
module W = Cardano_transaction.Witness
module B = Cardano_transaction.Body
module T = Cardano_types

let unhex s =
  String.init (String.length s / 2) (fun i ->
      Char.chr (int_of_string ("0x" ^ String.sub s (i * 2) 2)))

(* A deliberately small reader for a deliberately small file: the fixture is a
   flat array of two-string objects, and pulling in a JSON library for it would
   put a dependency in this package that nothing else here needs. *)
let string_field name s =
  let key = "\"" ^ name ^ "\"" in
  let klen = String.length key and slen = String.length s in
  let rec skip_ws p = if p < slen && (s.[p] = ' ' || s.[p] = ':' || s.[p] = '\n' || s.[p] = '\t') then skip_ws (p + 1) else p in
  let rec go acc p =
    if p + klen > slen then List.rev acc
    else if String.sub s p klen = key then
      let q = skip_ws (p + klen) in
      if q < slen && s.[q] = '"' then
        let stop = String.index_from s (q + 1) '"' in
        go (String.sub s (q + 1) (stop - q - 1) :: acc) (stop + 1)
      else go acc (p + 1)
    else go acc (p + 1)
  in
  go [] 0

let fixtures =
  let ic = open_in_bin "../conformance/fixtures/mainnet-txs.json" in
  let n = in_channel_length ic in
  let s = really_input_string ic n in
  close_in ic;
  List.combine (string_field "tx_hash" s) (string_field "cbor" s)

let ids_match_the_chain () =
  Alcotest.(check bool) "fixtures loaded" true (List.length fixtures >= 3);
  List.iter
    (fun (expected_hash, cbor_hex) ->
      let raw = unhex cbor_hex in
      match Tx.of_cbor raw with
      | Error m -> Alcotest.failf "%s: decode failed: %s" expected_hash m
      | Ok tx ->
          Alcotest.(check string)
            ("transaction id for " ^ String.sub expected_hash 0 12)
            expected_hash
            (T.Hash.Tx_id.to_hex (Tx.id tx));
          (* Byte-for-byte round trip of the whole transaction, not just the
             body: witness sets and auxiliary data are carried, not rebuilt. *)
          Alcotest.(check bool)
            ("round trips whole: " ^ String.sub expected_hash 0 12)
            true
            (String.equal raw (Tx.to_cbor tx));
          Alcotest.(check bool)
            ("body kept its bytes: " ^ String.sub expected_hash 0 12)
            true (B.is_verbatim tx.Tx.body))
    fixtures

let bodies_decode () =
  List.iter
    (fun (h, cbor_hex) ->
      match Tx.of_cbor (unhex cbor_hex) with
      | Error m -> Alcotest.failf "%s: %s" h m
      | Ok tx ->
          let b = tx.Tx.body in
          Alcotest.(check bool) ("has inputs: " ^ String.sub h 0 12) true
            (List.length b.B.inputs > 0);
          Alcotest.(check bool) ("has outputs: " ^ String.sub h 0 12) true
            (List.length b.B.outputs > 0);
          (* A real transaction pays a real fee. Zero would mean we read the
             wrong field. *)
          Alcotest.(check bool) ("pays a fee: " ^ String.sub h 0 12) true
            (T.Coin.compare b.B.fee T.Coin.zero > 0))
    fixtures

(* Re-encoding from the decoded fields is *not* expected to reproduce the
   original bytes, and that is exactly why the original bytes are kept. This
   test records the gap rather than hiding it. *)
let re_encoding_differs () =
  let differing =
    List.filter
      (fun (_, cbor_hex) ->
        match Tx.of_cbor (unhex cbor_hex) with
        | Ok tx ->
            let from_fields = B.to_cbor { (tx.Tx.body) with B.raw = None } in
            not (String.equal from_fields (B.to_cbor tx.Tx.body))
        | Error _ -> false)
      fixtures
  in
  Alcotest.(check bool)
    "at least one real transaction re-encodes differently from how it arrived"
    true
    (List.length differing > 0);
  Format.printf "@[<v>  %d of %d mainnet transactions do not re-encode to their@,\
                \  original bytes -- which is why Body keeps them.@]@."
    (List.length differing) (List.length fixtures)

(* The realistic co-signing path: take a transaction off the chain, drop the
   envelope bytes as adding a witness would, and re-encode. The body keeps its
   own bytes, so the id must not move -- and the witness set has to survive
   being rebuilt from the decoded fields, scripts and redeemers included. *)
let re_encoding_preserves_id_and_witnesses () =
  List.iter
    (fun (h, cbor_hex) ->
      match Tx.of_cbor (unhex cbor_hex) with
      | Error m -> Alcotest.failf "%s: %s" h m
      | Ok tx ->
          let reassembled = { tx with Tx.raw = None } in
          Alcotest.(check string)
            ("id survives reassembly: " ^ String.sub h 0 12)
            h
            (T.Hash.Tx_id.to_hex (Tx.id reassembled));
          let again = match Tx.of_cbor (Tx.to_cbor reassembled) with
            | Ok x -> x
            | Error m -> Alcotest.failf "%s: re-decode failed: %s" h m
          in
          Alcotest.(check string)
            ("and again after a full round trip: " ^ String.sub h 0 12)
            h (T.Hash.Tx_id.to_hex (Tx.id again));
          Alcotest.(check int)
            ("key witnesses survive: " ^ String.sub h 0 12)
            (List.length (Tx.witnesses tx))
            (List.length (Tx.witnesses again));
          Alcotest.(check int)
            ("uninterpreted witness fields survive: " ^ String.sub h 0 12)
            (List.length tx.Tx.witness_set.W.carried)
            (List.length again.Tx.witness_set.W.carried);
          Alcotest.(check bool)
            ("the witnesses still verify: " ^ String.sub h 0 12)
            true
            (List.for_all (fun w -> W.Vkey.verify w (Tx.id again))
               (Tx.witnesses again)))
    fixtures

let () =
  Alcotest.run "cardano-mainnet"
    [ ("conformance",
       [ Alcotest.test_case "ids match the chain" `Quick ids_match_the_chain;
         Alcotest.test_case "bodies decode" `Quick bodies_decode;
         Alcotest.test_case "re-encoding differs" `Quick re_encoding_differs;
         Alcotest.test_case "reassembly preserves id and witnesses" `Quick
           re_encoding_preserves_id_and_witnesses ]) ]
