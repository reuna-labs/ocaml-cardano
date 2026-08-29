(* Plutus data and the script-data hash.

   The CDDL states two encodings literally, and both are pinned here: the
   PlutusV1 language view for an all-zero cost model, and the V2 one. They are
   the only self-checking values available for this calculation short of a real
   scripted transaction, and both are the sort of thing that would otherwise be
   wrong in a way that still looks like a hash. *)

module P = Cardano_plutus.Plutus_data
module S = Cardano_plutus.Script
module T = Cardano_types

let hex_of s =
  String.concat "" (List.map (fun c -> Printf.sprintf "%02x" (Char.code c))
    (List.init (String.length s) (String.get s)))

let get = function Ok v -> v | Error m -> Alcotest.failf "unexpected error: %s" m

let round_trip name d =
  let e = P.encode d in
  let d' = get (P.decode e) in
  Alcotest.(check bool) (name ^ " round-trips") true (P.equal d d');
  Alcotest.(check string) (name ^ " re-encodes identically") (hex_of e) (hex_of (P.encode d'))

let constructors () =
  (* 0..6 use tags 121..127. *)
  Alcotest.(check string) "Constr 0 with no fields" "d87980"
    (hex_of (P.encode (P.Constr { alternative = 0; fields = [] })));
  Alcotest.(check string) "Constr 6" "d87f80"
    (hex_of (P.encode (P.Constr { alternative = 6; fields = [] })));
  (* 7..127 move to the 1280 range. *)
  Alcotest.(check string) "Constr 7 starts the second range" "d9050080"
    (hex_of (P.encode (P.Constr { alternative = 7; fields = [] })));
  (* Past that, tag 102 carries the number explicitly. *)
  let big = P.encode (P.Constr { alternative = 1000; fields = [] }) in
  Alcotest.(check bool) "a large alternative uses tag 102" true
    (String.length big > 2 && hex_of (String.sub big 0 2) = "d866");
  List.iter (fun a -> round_trip (Printf.sprintf "Constr %d" a)
                        (P.Constr { alternative = a; fields = [ P.of_int 1; P.Bytes "x" ] }))
    [ 0; 6; 7; 127; 1000 ]

(* The rule the CDDL says it cannot express: a definite byte string is limited
   to 64 bytes, and anything longer must be chunked. *)
let long_bytes_are_chunked () =
  let short = String.make 64 'a' in
  let e = P.encode (P.Bytes short) in
  Alcotest.(check string) "64 bytes stays definite" "5840" (hex_of (String.sub e 0 2));
  let long = String.make 65 'a' in
  let e = P.encode (P.Bytes long) in
  Alcotest.(check string) "65 bytes becomes indefinite" "5f" (hex_of (String.sub e 0 1));
  Alcotest.(check string) "with a full first chunk" "5840"
    (hex_of (String.sub e 1 2));
  Alcotest.(check string) "then a one-byte chunk" "4161"
    (hex_of (String.sub e 67 2));
  Alcotest.(check string) "and a break" "ff"
    (hex_of (String.sub e (String.length e - 1) 1));
  round_trip "65 bytes" (P.Bytes long);
  round_trip "200 bytes" (P.Bytes (String.make 200 'z'));
  (* A chunked string nested inside a container must survive; encoding the
     container through the strict codec would flatten it back to definite. *)
  let nested = P.List [ P.of_int 1; P.Bytes long ] in
  let e = P.encode nested in
  Alcotest.(check bool) "a chunked child survives nesting" true
    (String.length e > 65 && String.contains e '\x5f');
  round_trip "nested chunked" nested;
  round_trip "chunked in a constr"
    (P.Constr { alternative = 1; fields = [ P.Bytes long ] })

let integers () =
  round_trip "zero" (P.of_int 0);
  round_trip "negative" (P.Int (-1L));
  round_trip "int64 min" (P.Int Int64.min_int);
  round_trip "int64 max" (P.Int Int64.max_int);
  (* Plutus integers are unbounded; past int64 they are carried as bytes and
     never operated on, which is what keeps a bignum out of the closure. *)
  round_trip "beyond int64"
    (P.Big_int { negative = false; magnitude = String.make 12 '\255' });
  round_trip "negative beyond int64"
    (P.Big_int { negative = true; magnitude = String.make 12 '\255' })

let maps_keep_their_order () =
  (* The ledger does not sort Plutus map keys, so sorting them here would
     change the datum hash. *)
  let d = P.Map [ (P.of_int 2, P.of_int 0); (P.of_int 1, P.of_int 0) ] in
  let e = P.encode d in
  Alcotest.(check string) "written in the order given" "a2020001 00"
    (String.concat " " [ hex_of (String.sub e 0 4); hex_of (String.sub e 4 1) ]);
  round_trip "unsorted map" d

let datum_hash_is_over_the_encoding () =
  let d = P.Constr { alternative = 0; fields = [ P.of_int 42 ] } in
  Alcotest.(check string) "hash matches blake2b-256 of the encoding"
    (hex_of (T.blake2b256 (P.encode d)))
    (T.Hash.Datum_hash.to_hex (P.hash d));
  Alcotest.(check int) "which is 32 bytes" 32
    (String.length (T.Hash.Datum_hash.to_bytes (P.hash d)))

(* A script hash is the hash of the language tag followed by the script, not of
   the script. The same bytes under two languages must not collide. *)
let script_hashes_are_language_tagged () =
  let bytes = "\x01\x02\x03" in
  let v1 = S.hash { S.language = S.Plutus_v1; bytes } in
  let v2 = S.hash { S.language = S.Plutus_v2; bytes } in
  let native = S.hash { S.language = S.Native; bytes } in
  Alcotest.(check bool) "V1 and V2 differ" false
    (T.Hash.Script_hash.equal v1 v2);
  Alcotest.(check bool) "and neither is the native hash" false
    (T.Hash.Script_hash.equal v1 native || T.Hash.Script_hash.equal v2 native);
  Alcotest.(check string) "V1 is blake2b-224 of 0x01 ++ script"
    (hex_of (T.blake2b224 ("\x01" ^ bytes)))
    (T.Hash.Script_hash.to_hex v1);
  Alcotest.(check bool) "and not of the script alone" false
    (String.equal (hex_of (T.blake2b224 bytes)) (T.Hash.Script_hash.to_hex v1))

(* The two encodings the CDDL states outright, for an all-zero cost model. *)
let language_views_match_the_cddl () =
  (* "the script_integrity_data corresponding to the all zero costmodel for V1
      would be encoded as (in hex): 58a89f00...00ff" -- 168 zero entries, as an
     indefinite list, wrapped in a byte string. *)
  let v1_zero = List.init 166 (fun _ -> 0L) in
  let views = S.language_views [ (S.Plutus_v1, v1_zero) ] in
  let h = hex_of views in
  (* A one-entry map, whose key is the doubly-encoded language id: 4100. *)
  Alcotest.(check string) "a one-entry map" "a1" (String.sub h 0 2);
  Alcotest.(check string) "with V1's doubly-encoded key, 4100" "4100"
    (String.sub h 2 4);
  Alcotest.(check string) "and an indefinite list inside a byte string" "58a89f"
    (String.sub h 6 6);
  Alcotest.(check string) "terminated by a break" "ff"
    (String.sub h (String.length h - 2) 2);
  (* "the language version for V2 is encoded as 01 in hex" -- a plain integer
     key, and a definite list. *)
  let v2_zero = List.init 175 (fun _ -> 0L) in
  let views = S.language_views [ (S.Plutus_v2, v2_zero) ] in
  let h = hex_of views in
  Alcotest.(check string) "V2's key is a plain 01" "a101" (String.sub h 0 4);
  Alcotest.(check string) "and its list is definite" "98af" (String.sub h 4 4)

(* Keys sort by length first here, not bytewise -- RFC 7049 §3.9 rather than
   the RFC 8949 ordering used everywhere else. V1's key is two bytes and V2's
   is one, so V2 comes first however the bytes compare. *)
let language_views_sort_by_length () =
  let views = S.language_views [ (S.Plutus_v1, [ 0L ]); (S.Plutus_v2, [ 0L ]) ] in
  let h = hex_of views in
  Alcotest.(check string) "two entries" "a2" (String.sub h 0 2);
  Alcotest.(check string) "the shorter key comes first" "01" (String.sub h 2 2);
  (* Bytewise ordering would have put 0x41.. before 0x01.. -- it does not. *)
  Alcotest.(check bool) "and the longer one follows" true
    (String.length h > 8)

let script_data_hash_shapes () =
  let models = [ (S.Plutus_v2, [ 0L ]) ] in
  let datum = P.encode (P.of_int 1) in
  let h ~redeemers ~datums = T.Hash.Script_data_hash.to_hex (S.script_data_hash ~redeemers ~datums ~cost_models:models) in
  (* Datums but no redeemers is A0 || datums || A0 -- the language views are
     not included at all in that case. *)
  let expected =
    hex_of (T.blake2b256 ("\xa0" ^ "\x81" ^ datum ^ "\xa0"))
  in
  Alcotest.(check string) "datums without redeemers" expected
    (h ~redeemers:None ~datums:[ datum ]);
  (* With redeemers, the language views are appended. *)
  let r = "\xa0" in
  let expected =
    hex_of (T.blake2b256 (r ^ "\x81" ^ datum ^ S.language_views models))
  in
  Alcotest.(check string) "redeemers and datums" expected
    (h ~redeemers:(Some r) ~datums:[ datum ]);
  (* No datums: the middle is omitted entirely, not an empty array. *)
  let expected = hex_of (T.blake2b256 (r ^ S.language_views models)) in
  Alcotest.(check string) "redeemers without datums" expected
    (h ~redeemers:(Some r) ~datums:[])

let () =
  Alcotest.run "cardano-plutus"
    [ ("plutus data",
       [ Alcotest.test_case "constructors" `Quick constructors;
         Alcotest.test_case "long bytes are chunked" `Quick long_bytes_are_chunked;
         Alcotest.test_case "integers" `Quick integers;
         Alcotest.test_case "map order" `Quick maps_keep_their_order;
         Alcotest.test_case "datum hash" `Quick datum_hash_is_over_the_encoding ]);
      ("scripts",
       [ Alcotest.test_case "language-tagged hashes" `Quick script_hashes_are_language_tagged ]);
      ("script data hash",
       [ Alcotest.test_case "language views match the CDDL" `Quick language_views_match_the_cddl;
         Alcotest.test_case "views sort by length" `Quick language_views_sort_by_length;
         Alcotest.test_case "preimage shapes" `Quick script_data_hash_shapes ]) ]
