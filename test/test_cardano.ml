module T = Cardano_types

let hex_of s =
  String.concat ""
    (List.map
       (fun c -> Printf.sprintf "%02x" (Char.code c))
       (List.init (String.length s) (String.get s)))

let get = function
  | Ok v -> v
  | Error m -> Alcotest.failf "unexpected error: %s" m

let get_coin = function
  | Ok v -> v
  | Error e -> Alcotest.failf "unexpected error: %a" T.Coin.pp_error e

(* Blake2b mixes the digest length into its parameter block, so the 224-bit
   function is not a truncation of the 256-bit one. These four are cross-checked
   against Python's hashlib; a self-consistent pair of our own would prove
   nothing. *)
let blake2b_widths () =
  Alcotest.(check string)
    "blake2b-256 of empty"
    "0e5751c026e543b2e8ab2eb06099daa1d1e5df47778f7787faab45cdf12fe3a8"
    (hex_of (T.blake2b256 ""));
  Alcotest.(check string)
    "blake2b-224 of empty"
    "836cc68931c2e4e3e838602eca1902591d216837bafddfe6f0c8cb07"
    (hex_of (T.blake2b224 ""));
  Alcotest.(check string)
    "blake2b-256 of abc"
    "bddd813c634239723171ef3fee98579b94964e3bb1cb3e427262c8c068d52319"
    (hex_of (T.blake2b256 "abc"));
  Alcotest.(check string)
    "blake2b-224 of abc"
    "9bd237b02a29e43bdd6738afa5b53ff0eee178d6210b618e4511aec8"
    (hex_of (T.blake2b224 "abc"));
  Alcotest.(check bool)
    "the two widths are different functions" false
    (String.equal (T.blake2b224 "abc") (String.sub (T.blake2b256 "abc") 0 28))

let hash_types () =
  Alcotest.(check int) "addr_key_hash is 28 bytes" 28 T.Hash.Addr_key_hash.size;
  Alcotest.(check int) "tx_id is 32 bytes" 32 T.Hash.Tx_id.size;
  Alcotest.(check bool)
    "wrong width refused" true
    (match T.Hash.Tx_id.of_bytes (String.make 28 '\000') with
    | Error _ -> true
    | Ok _ -> false);
  let h = T.Hash.Addr_key_hash.digest "abc" in
  Alcotest.(check string)
    "digest agrees with the raw function"
    (hex_of (T.blake2b224 "abc"))
    (T.Hash.Addr_key_hash.to_hex h);
  let h' = get (T.Hash.Addr_key_hash.of_hex (T.Hash.Addr_key_hash.to_hex h)) in
  Alcotest.(check bool) "hex round-trips" true (T.Hash.Addr_key_hash.equal h h')

let coin_arithmetic () =
  let c n = get_coin (T.Coin.of_lovelace n) in
  Alcotest.(check bool)
    "negative refused" true
    (match T.Coin.of_lovelace (-1L) with Error _ -> true | Ok _ -> false);
  Alcotest.(check bool)
    "above max supply refused" true
    (match T.Coin.of_lovelace 45_000_000_000_000_001L with
    | Error _ -> true
    | Ok _ -> false);
  Alcotest.(check bool)
    "max supply itself is fine" true
    (match T.Coin.of_lovelace 45_000_000_000_000_000L with
    | Ok _ -> true
    | Error _ -> false);
  (* The point of the type: a sum that would leave the range is an error, not a
     wrapped negative that later reads as a plausible amount. *)
  Alcotest.(check bool)
    "sum past max supply is an error" true
    (match T.Coin.add (c 45_000_000_000_000_000L) (c 1L) with
    | Error _ -> true
    | Ok _ -> false);
  Alcotest.(check bool)
    "underflow is an error" true
    (match T.Coin.sub (c 1L) (c 2L) with Error _ -> true | Ok _ -> false);
  Alcotest.(check bool)
    "mul overflow is an error" true
    (match T.Coin.mul (c 1_000_000_000_000L) 1_000_000 with
    | Error _ -> true
    | Ok _ -> false);
  Alcotest.(check int64)
    "sum adds up" 6L
    (T.Coin.to_lovelace (get_coin (T.Coin.sum [ c 1L; c 2L; c 3L ])));
  match T.Coin.diff (c 1L) (c 3L) with
  | `Neg d ->
      Alcotest.(check int64)
        "diff reports sign separately" 2L (T.Coin.to_lovelace d)
  | _ -> Alcotest.fail "diff sign wrong"

(* Decimal ada must be exact in both directions. Anything this type cannot
   represent exactly is rejected rather than rounded, because a silently
   rounded amount is a wrong amount. *)
let coin_decimal () =
  let round_trip s =
    let c = get_coin (T.Coin.of_ada_string s) in
    Alcotest.(check string) ("round-trips " ^ s) s (T.Coin.to_ada_string c)
  in
  List.iter round_trip
    [ "0"; "1"; "1.5"; "0.000001"; "1.234567"; "45000000000" ];
  Alcotest.(check int64)
    "1 ada is a million lovelace" 1_000_000L
    (T.Coin.to_lovelace (get_coin (T.Coin.of_ada_string "1")));
  Alcotest.(check int64)
    "partial fraction pads right" 1_200_000L
    (T.Coin.to_lovelace (get_coin (T.Coin.of_ada_string "1.2")));
  Alcotest.(check bool)
    "seven decimals refused, not rounded" true
    (match T.Coin.of_ada_string "1.2345678" with
    | Error _ -> true
    | Ok _ -> false);
  List.iter
    (fun s ->
      Alcotest.(check bool)
        ("refuses " ^ s) true
        (match T.Coin.of_ada_string s with Error _ -> true | Ok _ -> false))
    [ ""; "."; "-1"; "1.2.3"; "abc"; "1e6"; " 1" ]

(* The reason Quantity is not simply an int64: a native asset has no supply cap,
   so a legitimate quantity can exceed Int64.max_int, and reading that bit
   pattern as signed would turn a huge balance into a negative one. *)
let unsigned_quantities () =
  let big = get (T.Quantity.of_int64_unsigned (-1L)) in
  Alcotest.(check string)
    "2^64-1 prints unsigned" "18446744073709551615" (T.Quantity.to_string big);
  Alcotest.(check bool)
    "2^64-1 is greater than one" true
    (T.Quantity.compare big T.Quantity.one > 0);
  Alcotest.(check bool)
    "signed comparison would have said otherwise" true
    (Int64.compare (T.Quantity.to_int64_unsigned big) 1L < 0);
  Alcotest.(check bool)
    "2^64-1 does not fit an int" true
    (T.Quantity.to_int big = None);
  Alcotest.(check bool)
    "addition past 2^64 is an error" true
    (match T.Quantity.add big T.Quantity.one with
    | Error _ -> true
    | Ok _ -> false);
  Alcotest.(check bool)
    "zero is not a representable quantity" true
    (match T.Quantity.of_int64_unsigned 0L with
    | Error _ -> true
    | Ok _ -> false)

let multi_asset () =
  let pol n = get (T.Hash.Script_hash.of_bytes (String.make 28 n)) in
  let nm s = get (T.Asset_name.of_bytes s) in
  let q n = get (T.Quantity.of_int n) in
  let a1 = T.asset (pol '\001') (nm "tokenA") in
  let a2 = T.asset (pol '\001') (nm "tokenB") in
  Alcotest.(check bool)
    "33-byte asset name refused" true
    (match T.Asset_name.of_bytes (String.make 33 'x') with
    | Error _ -> true
    | Ok _ -> false);
  Alcotest.(check bool)
    "32-byte asset name allowed" true
    (match T.Asset_name.of_bytes (String.make 32 'x') with
    | Ok _ -> true
    | Error _ -> false);
  Alcotest.(check string)
    "empty asset name is legal" ""
    (T.Asset_name.to_bytes (nm ""));
  (* Repeats combine rather than shadowing, so a bundle built two ways is the
     same bundle. *)
  let m = get (T.Multi_asset.of_list [ (a1, q 5); (a2, q 7); (a1, q 3) ]) in
  Alcotest.(check int) "distinct assets" 2 (T.Multi_asset.size m);
  Alcotest.(check string)
    "repeats combined" "8"
    (T.Quantity.to_string (Option.get (T.Multi_asset.find m a1)));
  let m' = get (T.Multi_asset.of_list [ (a2, q 7); (a1, q 8) ]) in
  Alcotest.(check bool)
    "order of construction does not matter" true (T.Multi_asset.equal m m');
  Alcotest.(check int) "one policy" 1 (List.length (T.Multi_asset.policies m))

let values () =
  let pol n = get (T.Hash.Script_hash.of_bytes (String.make 28 n)) in
  let nm s = get (T.Asset_name.of_bytes s) in
  let q n = get (T.Quantity.of_int n) in
  let c n = get_coin (T.Coin.of_lovelace n) in
  let a1 = T.asset (pol '\001') (nm "A") in
  let v1 = T.Value.make (c 100L) (get (T.Multi_asset.of_list [ (a1, q 5) ])) in
  let v2 = T.Value.make (c 40L) (get (T.Multi_asset.of_list [ (a1, q 2) ])) in
  Alcotest.(check bool)
    "ada-only detected" true
    (T.Value.is_ada_only (T.Value.of_coin (c 1L)));
  Alcotest.(check bool) "bundle is not ada-only" false (T.Value.is_ada_only v1);
  let s = get (T.Value.add v1 v2) in
  Alcotest.(check int64) "ada adds" 140L (T.Coin.to_lovelace s.T.Value.coin);
  Alcotest.(check string)
    "assets add" "7"
    (T.Quantity.to_string (Option.get (T.Multi_asset.find s.T.Value.assets a1)));
  let d = get (T.Value.sub v1 v2) in
  Alcotest.(check int64) "ada subtracts" 60L (T.Coin.to_lovelace d.T.Value.coin);
  Alcotest.(check string)
    "assets subtract" "3"
    (T.Quantity.to_string (Option.get (T.Multi_asset.find d.T.Value.assets a1)));
  (* Subtracting all of an asset drops the entry rather than leaving a zero,
     which the CDDL cannot represent. *)
  let all =
    get
      (T.Value.sub v1
         (T.Value.make (c 0L) (get (T.Multi_asset.of_list [ (a1, q 5) ]))))
  in
  Alcotest.(check int)
    "exhausted asset is dropped" 0
    (T.Multi_asset.size all.T.Value.assets);
  Alcotest.(check bool)
    "shortfall is an error, not a clamp" true
    (match T.Value.sub v2 v1 with Error _ -> true | Ok _ -> false);
  Alcotest.(check bool)
    "missing asset is an error" true
    (match T.Value.sub (T.Value.of_coin (c 100L)) v2 with
    | Error _ -> true
    | Ok _ -> false);
  Alcotest.(check bool) "contains" true (T.Value.contains v1 v2);
  Alcotest.(check bool) "does not contain" false (T.Value.contains v2 v1)

(* A burn is a negative delta and an output quantity is strictly positive, so
   these are different types and cannot be mixed up at a call site. *)
let mint () =
  let pol n = get (T.Hash.Script_hash.of_bytes (String.make 28 n)) in
  let nm s = get (T.Asset_name.of_bytes s) in
  let a1 = T.asset (pol '\001') (nm "A") in
  let m = get (T.Mint.of_list [ (a1, -5L) ]) in
  Alcotest.(check int) "burn is representable" 1 (T.Mint.size m);
  Alcotest.(check bool)
    "zero delta refused" true
    (match T.Mint.of_list [ (a1, 0L) ] with Error _ -> true | Ok _ -> false);
  Alcotest.(check bool)
    "duplicate asset refused" true
    (match T.Mint.of_list [ (a1, 1L); (a1, 2L) ] with
    | Error _ -> true
    | Ok _ -> false)

(* ---- crypto ---- *)

module K = Cardano_crypto.Key
module P = Cardano_crypto.Derivation_path

let getk = function
  | Ok v -> v
  | Error e -> Alcotest.failf "unexpected error: %a" K.pp_error e

let getp = function Ok v -> v | Error _ -> Alcotest.fail "bad derivation path"

let unhex s =
  String.init
    (String.length s / 2)
    (fun i -> Char.chr (int_of_string ("0x" ^ String.sub s (i * 2) 2)))

(* CIP-0003 Icarus.md test vectors, for the recovery phrase
   "eight country switch draw meat scout mystery blade tip drift useless good
   keep usage title". The entropy below is that phrase's, checksum-verified
   against the BIP39 English wordlist.

   The passphrase is the PBKDF2 *password* and the entropy is the *salt* --
   the opposite of BIP39's own seed derivation. Swapping them produces a
   perfectly valid key for a wallet nobody can find, which is why both the
   with- and without-passphrase vectors are pinned here. *)
let icarus_entropy = unhex "46e62370a138a182a498b8e2885bc032379ddf38"

let icarus_master () =
  let k = getk (K.Icarus.of_entropy icarus_entropy) in
  Alcotest.(check string)
    "no passphrase"
    ("c065afd2832cd8b087c4d9ab7011f481ee1e0721e78ea5dd609f3ab3f156d245"
   ^ "d176bd8fd4ec60b4731c3918a2a72a0226c0cd119ec35b47e4d55884667f552a"
   ^ "23f7fdcd4a10c6cd2c7393ac61d877873e248f417634aa3d812af327ffe9d620")
    (hex_of (K.Xprv.to_bytes k));
  let k' = getk (K.Icarus.of_entropy ~passphrase:"foo" icarus_entropy) in
  Alcotest.(check string)
    "with passphrase"
    ("70531039904019351e1afb361cd1b312a4d0565d4ff9f8062d38acf4b15cce41"
   ^ "d7b5738d9c893feea55512a3004acb0d222c35d3e3d5cde943a15a9824cbac59"
   ^ "443cf67e589614076ba01e354b1a432e0e6db3b59e37fc56b5fb0222970a010e")
    (hex_of (K.Xprv.to_bytes k'));
  (* The clamp is not cosmetic: an unclamped kL breaks the additions that
     derivation performs. *)
  let b = K.Xprv.to_bytes k in
  Alcotest.(check int) "low three bits cleared" 0 (Char.code b.[0] land 0x07);
  Alcotest.(check int) "high bit cleared" 0 (Char.code b.[31] land 0x80);
  Alcotest.(check int) "third-highest bit cleared" 0 (Char.code b.[31] land 0x20);
  Alcotest.(check int) "second-highest bit set" 0x40 (Char.code b.[31] land 0x40);
  Alcotest.(check bool)
    "entropy under 16 bytes refused" true
    (match K.Icarus.of_entropy (String.make 15 '\000') with
    | Error _ -> true
    | Ok _ -> false);
  Alcotest.(check bool)
    "entropy over 32 bytes refused" true
    (match K.Icarus.of_entropy (String.make 33 '\000') with
    | Error _ -> true
    | Ok _ -> false)

(* Derivation vectors from BitBoxSwiss/rust-bip32-ed25519's table.json, by way
   of mirage-crypto-blockchain-core's own suite. Re-pinned here because this is
   the layer a Cardano wallet actually calls. *)
let derivation () =
  let root =
    getk
      (K.Xprv.of_bytes
         (unhex
            ("c8e9654cee5526f2a0ea31c7b05f57f5295135e46ded2c747191f34ab98f3d50"
           ^ "8757f37b66d61b1f102b00ffd4007c7660d4948c9ec809c847a84b15e60d89b7"
           ^ "59b469554385d460a79105f422421e2de565afa315a8defd37dbc3ab2b63546d"
            )))
  in
  let soft = getk (K.Xprv.derive root 0l) in
  Alcotest.(check string)
    "soft child"
    ("a0b23454924c145df960caba91f3a1ec65bc097b3e7f47849d614e19c08f3d50"
   ^ "1bac817a12e10402e991257cef4df7f8553bb33684315f70177be041f2c79b63"
   ^ "5bcc2e27c743f9d3302e8850ef27214d2b9fb000a901034008c323e6ccfd2f63")
    (hex_of (K.Xprv.to_bytes soft));
  let hard = getk (K.Xprv.derive root Int32.min_int) in
  Alcotest.(check string)
    "hardened child"
    ("800cdbee97b1151e0c241bacc25e88debb501e2c08356201c0871249bc8f3d50"
   ^ "ac0fb5dbfb854692498b502444e936d35642fde5ae4244905d0aef2743152e13"
   ^ "11b22d1d5a245253e0905fd7cbb9e131ebc60609774e5ca2712afb7f35427de5")
    (hex_of (K.Xprv.to_bytes hard));
  (* The property that makes watch-only wallets possible: soft derivation from
     the public key alone reaches the same point. *)
  let from_pub = getk (K.Xpub.derive (K.Xprv.public root) 0l) in
  Alcotest.(check string)
    "public-only soft derivation agrees"
    (hex_of (K.Xpub.to_bytes (K.Xprv.public soft)))
    (hex_of (K.Xpub.to_bytes from_pub));
  (* And the property that makes hardening worth having. *)
  Alcotest.(check bool)
    "hardened from public is refused" true
    (match K.Xpub.derive (K.Xprv.public root) Int32.min_int with
    | Error `Hardened_from_public -> true
    | _ -> false)

let signing () =
  let root = getk (K.Icarus.of_entropy icarus_entropy) in
  let path = getp (P.address ~account:0l ~role:P.External ~index:0l) in
  let k = getk (K.Xprv.derive_path root path) in
  let pub = K.Xprv.public k in
  let sg = K.Xprv.sign k "hello cardano" in
  Alcotest.(check int) "signature is 64 bytes" 64 (String.length sg);
  Alcotest.(check bool)
    "verifies" true
    (K.Xpub.verify pub ~signature:sg "hello cardano");
  Alcotest.(check bool)
    "does not verify a different message" false
    (K.Xpub.verify pub ~signature:sg "goodbye cardano");
  (* Deterministic by RFC 8032 -- no generator anywhere in this library. *)
  Alcotest.(check string)
    "signing is deterministic" (hex_of sg)
    (hex_of (K.Xprv.sign k "hello cardano"));
  Alcotest.(check int)
    "key hash is 28 bytes" 28
    (String.length
       (Cardano_types.Hash.Addr_key_hash.to_bytes (K.Xpub.hash pub)))

let paths () =
  let p = getp (P.address ~account:0l ~role:P.External ~index:5l) in
  Alcotest.(check string)
    "cip-1852 rendering" "m/1852'/1815'/0'/0/5" (P.to_string p);
  Alcotest.(check string)
    "shell-safe marker" "m/1852h/1815h/0h/0/5" (P.to_string ~marker:`H p);
  let parsed = getp (P.of_string "m/1852'/1815'/0'/0/5") in
  Alcotest.(check bool) "parses its own rendering" true (P.equal p parsed);
  Alcotest.(check bool)
    "accepts the h marker too" true
    (P.equal p (getp (P.of_string "m/1852h/1815h/0h/0/5")));
  let stake = getp (P.stake ~account:0l) in
  Alcotest.(check string)
    "stake path" "m/1852'/1815'/0'/2/0" (P.to_string stake);
  (* An index at or above 2^31 without a marker would silently mean hardened. *)
  Alcotest.(check bool)
    "unmarked hardened index refused" true
    (match P.of_string "m/2147483648" with Error _ -> true | Ok _ -> false);
  List.iter
    (fun s ->
      Alcotest.(check bool)
        ("refuses " ^ s) true
        (match P.of_string s with Error _ -> true | Ok _ -> false))
    [ "m/"; "m/x"; "m/1''"; "m/-1" ]

let () =
  Alcotest.run "cardano"
    [
      ( "hashes",
        [
          Alcotest.test_case "blake2b widths" `Quick blake2b_widths;
          Alcotest.test_case "hash types" `Quick hash_types;
        ] );
      ( "coin",
        [
          Alcotest.test_case "arithmetic" `Quick coin_arithmetic;
          Alcotest.test_case "decimal ada" `Quick coin_decimal;
        ] );
      ( "value",
        [
          Alcotest.test_case "unsigned quantities" `Quick unsigned_quantities;
          Alcotest.test_case "multi-asset" `Quick multi_asset;
          Alcotest.test_case "values" `Quick values;
          Alcotest.test_case "mint" `Quick mint;
        ] );
      ("icarus", [ Alcotest.test_case "master key" `Quick icarus_master ]);
      ( "bip32-ed25519",
        [
          Alcotest.test_case "derivation" `Quick derivation;
          Alcotest.test_case "signing" `Quick signing;
        ] );
      ("cip-1852", [ Alcotest.test_case "paths" `Quick paths ]);
    ]
