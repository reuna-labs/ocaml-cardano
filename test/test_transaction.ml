module C = Web3_codec_cbor
module B = Cardano_transaction.Body
module T = Cardano_types
module A = Cardano_address.Address

let hex_of s =
  String.concat ""
    (List.map
       (fun c -> Printf.sprintf "%02x" (Char.code c))
       (List.init (String.length s) (String.get s)))

let get = function
  | Ok v -> v
  | Error m -> Alcotest.failf "unexpected error: %s" m

let tx_id b = get (T.Hash.Tx_id.of_bytes (String.make 32 b))

let addr () =
  get
    (Result.map_error
       (fun _ -> "addr")
       (A.of_bech32 "addr1vx2fxv2umyhttkxyxp8x0dlpdt3k6cwng5pxj3jhsydzers66hrl8"))

let sample () =
  {
    B.empty with
    B.inputs = [ get (B.Input.make (tx_id '\001') 0) ];
    B.outputs =
      [
        B.Output.make (addr ())
          (T.Value.of_coin
             (get
                (Result.map_error
                   (fun _ -> "coin")
                   (T.Coin.of_lovelace 2_000_000L))));
      ];
    B.fee =
      get (Result.map_error (fun _ -> "coin") (T.Coin.of_lovelace 170_000L));
  }

let round_trip () =
  let b = sample () in
  let enc = B.to_cbor b in
  let d = get (B.of_cbor enc) in
  Alcotest.(check string)
    "decode then encode is the identity" (hex_of enc)
    (hex_of (B.to_cbor d));
  Alcotest.(check string)
    "the id is stable across the round trip"
    (T.Hash.Tx_id.to_hex (B.id b))
    (T.Hash.Tx_id.to_hex (B.id d));
  Alcotest.(check bool)
    "a built body has no preserved bytes" false (B.is_verbatim b);
  Alcotest.(check bool) "a decoded one does" true (B.is_verbatim d);
  Alcotest.(check int) "inputs survive" 1 (List.length d.B.inputs);
  Alcotest.(check int) "outputs survive" 1 (List.length d.B.outputs);
  Alcotest.(check int64) "fee survives" 170_000L (T.Coin.to_lovelace d.B.fee)

(* The property the whole design rests on.

   The CDDL lets a set be written bare or wrapped in tag 258, and both are
   valid. A sender that chose the bare form produces a different byte string --
   and therefore a different transaction id -- from the one this library would
   emit. If decoding threw those bytes away, we would compute the wrong id for
   somebody else's transaction while looking entirely correct. *)
let non_canonical_input_preserved () =
  let b = sample () in
  (* Re-spell the body exactly as a sender using the bare-array form would. *)
  let ours = B.to_cbor b in
  let respelt =
    match get (C.of_octets ours) with
    | C.Map fields ->
        C.encode
          (C.Map
             (List.map
                (fun (k, v) ->
                  match (k, v) with
                  | C.Uint 0L, C.Tag (258, inner) -> (k, inner)
                  | _ -> (k, v))
                fields))
    | _ -> Alcotest.fail "body should be a map"
  in
  Alcotest.(check bool)
    "the two spellings really do differ" false
    (String.equal ours respelt);
  let d = get (B.of_cbor respelt) in
  Alcotest.(check string)
    "the sender's bytes are preserved verbatim" (hex_of respelt)
    (hex_of (B.to_cbor d));
  (* And therefore the id is the sender's id, not ours. *)
  let expected = hex_of (T.blake2b256 respelt) in
  Alcotest.(check string)
    "the id is over the bytes as received" expected
    (T.Hash.Tx_id.to_hex (B.id d));
  Alcotest.(check bool)
    "which is not the id we would have computed from fields" false
    (String.equal (T.Hash.Tx_id.to_hex (B.id d)) (hex_of (T.blake2b256 ours)));
  (* The decoded content is nonetheless the same transaction. *)
  Alcotest.(check int) "same inputs" 1 (List.length d.B.inputs)

(* Governance and certificates round-trip without being interpreted. Dropping
   them would change the id; claiming to understand them would be worse. *)
let carried_fields_survive () =
  let b = sample () in
  let with_gov =
    match get (C.of_octets (B.to_cbor b)) with
    | C.Map fields ->
        C.encode
          (C.Map
             (fields
             @ [
                 (C.Uint 19L, C.Map [ (C.Bytes "voter", C.Uint 1L) ]);
                 (C.Uint 22L, C.Uint 500L);
               ]))
    | _ -> Alcotest.fail "body should be a map"
  in
  let d = get (B.of_cbor with_gov) in
  Alcotest.(check int)
    "both uninterpreted fields are carried" 2 (List.length d.B.carried);
  Alcotest.(check bool)
    "voting procedures among them" true
    (List.mem_assoc 19 d.B.carried);
  Alcotest.(check bool)
    "donation among them" true
    (List.mem_assoc 22 d.B.carried);
  Alcotest.(check string)
    "and the body still re-encodes byte for byte" (hex_of with_gov)
    (hex_of (B.to_cbor d))

(* Conway removed the Babbage `update` field. A body still carrying one is not
   a Conway body, and signing it as though it were would mean signing a
   structure we have not modelled. *)
let update_field_refused () =
  let b = sample () in
  let with_update =
    match get (C.of_octets (B.to_cbor b)) with
    | C.Map fields -> C.encode (C.Map (fields @ [ (C.Uint 6L, C.Uint 0L) ]))
    | _ -> Alcotest.fail "body should be a map"
  in
  Alcotest.(check bool)
    "key 6 is refused, not ignored" true
    (match B.of_cbor with_update with Error _ -> true | Ok _ -> false)

let multi_asset_output () =
  let policy = get (T.Hash.Script_hash.of_bytes (String.make 28 '\007')) in
  let name = get (T.Asset_name.of_bytes "TOK") in
  let q = get (T.Quantity.of_int 1234) in
  let assets = get (T.Multi_asset.of_list [ (T.asset policy name, q) ]) in
  let v =
    T.Value.make
      (get (Result.map_error (fun _ -> "coin") (T.Coin.of_lovelace 3_000_000L)))
      assets
  in
  let b = { (sample ()) with B.outputs = [ B.Output.make (addr ()) v ] } in
  let d = get (B.of_cbor (B.to_cbor b)) in
  match d.B.outputs with
  | [ o ] ->
      Alcotest.(check bool)
        "the bundle survives" true
        (T.Value.equal o.B.Output.value v);
      Alcotest.(check bool)
        "and is not ada-only" false
        (T.Value.is_ada_only o.B.Output.value)
  | _ -> Alcotest.fail "expected one output"

(* An ada-only value is a bare integer, not a one-element pair. Encoding it the
   long way would still decode, and would still change the id. *)
let ada_only_is_a_bare_coin () =
  let b = sample () in
  match get (C.of_octets (B.to_cbor b)) with
  | C.Map fields -> (
      match List.assoc (C.Uint 1L) fields with
      | C.Array [ C.Map [ (_, _); (C.Uint 1L, C.Uint _) ] ] -> ()
      | C.Array [ C.Map fs ] -> (
          match List.assoc (C.Uint 1L) fs with
          | C.Uint _ -> ()
          | v ->
              Alcotest.failf "ada-only value should be a bare uint, got %s"
                (hex_of (C.encode v)))
      | _ -> Alcotest.fail "expected one map-form output")
  | _ -> Alcotest.fail "body should be a map"

(* ---- witnesses and signing ---- *)

module W = Cardano_transaction.Witness
module Tx = Cardano_transaction.Transaction
module K = Cardano_crypto.Key

let unhex s =
  String.init
    (String.length s / 2)
    (fun i -> Char.chr (int_of_string ("0x" ^ String.sub s (i * 2) 2)))

let key_from entropy =
  match K.Icarus.of_entropy entropy with
  | Ok k -> k
  | Error e -> Alcotest.failf "%a" K.pp_error e

let key () = key_from (unhex "46e62370a138a182a498b8e2885bc032379ddf38")

let unsigned () =
  {
    Tx.body = sample ();
    Tx.witness_set = W.empty;
    Tx.is_valid = true;
    Tx.auxiliary_data = None;
    Tx.raw = None;
  }

(* The property that makes an offline signer workable: the id is fixed before
   anything is signed, so a caller can check what it is about to authorise
   against what it expected, and a tracker can follow a transaction it has not
   finished assembling. *)
let id_is_stable_under_signing () =
  let t = unsigned () in
  let before = T.Hash.Tx_id.to_hex (Tx.id t) in
  let signed = Tx.sign t (key ()) in
  Alcotest.(check string)
    "signing does not move the id" before
    (T.Hash.Tx_id.to_hex (Tx.id signed));
  Alcotest.(check int)
    "one witness attached" 1
    (List.length (Tx.witnesses signed));
  let twice = Tx.sign signed (key ()) in
  Alcotest.(check int)
    "signing twice attaches one witness" 1
    (List.length (Tx.witnesses twice))

(* What gets signed is the transaction id, not the body's bytes. Signing the
   body instead yields a signature that verifies against nothing, so it is
   worth pinning rather than assuming. *)
let signs_the_id_not_the_body () =
  let t = unsigned () in
  Alcotest.(check int)
    "the payload is 32 bytes" 32
    (String.length (Tx.signing_payload t));
  Alcotest.(check string)
    "and it is the transaction id"
    (T.Hash.Tx_id.to_hex (Tx.id t))
    (hex_of (Tx.signing_payload t));
  let k = key () in
  let over_body = K.Xprv.sign k (B.to_cbor t.Tx.body) in
  let vkey = K.Xpub.raw (K.Xprv.public k) in
  Alcotest.(check bool)
    "a signature over the body is refused" true
    (match Tx.add_signature t ~vkey ~signature:over_body with
    | Error _ -> true
    | Ok _ -> false)

(* The external-signer path: hand out the payload, take back a signature, and
   verify it here rather than discovering the problem at submission. *)
let external_signer () =
  let t = unsigned () in
  let k = key () in
  let payload = Tx.signing_payload t in
  let signature = K.Xprv.sign k payload in
  let vkey = K.Xpub.raw (K.Xprv.public k) in
  let signed = get (Tx.add_signature t ~vkey ~signature) in
  Alcotest.(check int) "witness accepted" 1 (List.length (Tx.witnesses signed));
  Alcotest.(check bool)
    "and it verifies" true
    (W.Vkey.verify (List.hd (Tx.witnesses signed)) (Tx.id signed));
  Alcotest.(check string)
    "witness key hash matches the public key's"
    (T.Hash.Addr_key_hash.to_hex (K.Xpub.hash (K.Xprv.public k)))
    (T.Hash.Addr_key_hash.to_hex (List.hd (Tx.signed_by signed)));
  (* A signature by a different key, over the right payload, is still wrong for
     the vkey it is presented with. *)
  let bad = K.Xprv.sign (key_from (String.make 20 '\009')) payload in
  Alcotest.(check bool)
    "mismatched key and signature refused" true
    (match Tx.add_signature t ~vkey ~signature:bad with
    | Error _ -> true
    | Ok _ -> false)

let signed_transaction_round_trips () =
  let signed = Tx.sign (unsigned ()) (key ()) in
  let enc = Tx.to_cbor signed in
  let d = get (Tx.of_cbor enc) in
  Alcotest.(check string)
    "a signed transaction round-trips" (hex_of enc)
    (hex_of (Tx.to_cbor d));
  Alcotest.(check string)
    "with the same id"
    (T.Hash.Tx_id.to_hex (Tx.id signed))
    (T.Hash.Tx_id.to_hex (Tx.id d));
  Alcotest.(check int) "and the same witnesses" 1 (List.length (Tx.witnesses d));
  Alcotest.(check bool)
    "which still verify" true
    (W.Vkey.verify (List.hd (Tx.witnesses d)) (Tx.id d))

let () =
  Alcotest.run "cardano-transaction"
    [
      ( "body",
        [
          Alcotest.test_case "round trip" `Quick round_trip;
          Alcotest.test_case "multi-asset output" `Quick multi_asset_output;
          Alcotest.test_case "ada-only value shape" `Quick
            ada_only_is_a_bare_coin;
        ] );
      ( "byte preservation",
        [
          Alcotest.test_case "non-canonical set spelling" `Quick
            non_canonical_input_preserved;
          Alcotest.test_case "uninterpreted fields survive" `Quick
            carried_fields_survive;
        ] );
      ( "era",
        [
          Alcotest.test_case "conway rejects the update field" `Quick
            update_field_refused;
        ] );
      ( "signing",
        [
          Alcotest.test_case "id is stable under signing" `Quick
            id_is_stable_under_signing;
          Alcotest.test_case "signs the id, not the body" `Quick
            signs_the_id_not_the_body;
          Alcotest.test_case "external signer" `Quick external_signer;
          Alcotest.test_case "signed round trip" `Quick
            signed_transaction_round_trips;
        ] );
    ]
