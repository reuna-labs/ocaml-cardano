(* CIP-0019 test vectors, taken verbatim from the specification's own
   "Test vectors" section. All eight Shelley header types plus both reward
   forms, on both networks -- because the header nibble is the one byte that
   decides who can spend an output, and an off-by-one in it produces an address
   that still looks entirely plausible. *)

module A = Cardano_address.Address
module N = Cardano_types.Network

let get = function
  | Ok v -> v
  | Error e -> Alcotest.failf "unexpected error: %a" A.pp_error e

let mainnet =
  [
    ( 0,
      "addr1qx2fxv2umyhttkxyxp8x0dlpdt3k6cwng5pxj3jhsydzer3n0d3vllmyqwsx5wktcd8cc3sq835lu7drv2xwl2wywfgse35a3x"
    );
    ( 1,
      "addr1z8phkx6acpnf78fuvxn0mkew3l0fd058hzquvz7w36x4gten0d3vllmyqwsx5wktcd8cc3sq835lu7drv2xwl2wywfgs9yc0hh"
    );
    ( 2,
      "addr1yx2fxv2umyhttkxyxp8x0dlpdt3k6cwng5pxj3jhsydzerkr0vd4msrxnuwnccdxlhdjar77j6lg0wypcc9uar5d2shs2z78ve"
    );
    ( 3,
      "addr1x8phkx6acpnf78fuvxn0mkew3l0fd058hzquvz7w36x4gt7r0vd4msrxnuwnccdxlhdjar77j6lg0wypcc9uar5d2shskhj42g"
    );
    (4, "addr1gx2fxv2umyhttkxyxp8x0dlpdt3k6cwng5pxj3jhsydzer5pnz75xxcrzqf96k");
    (5, "addr128phkx6acpnf78fuvxn0mkew3l0fd058hzquvz7w36x4gtupnz75xxcrtw79hu");
    (6, "addr1vx2fxv2umyhttkxyxp8x0dlpdt3k6cwng5pxj3jhsydzers66hrl8");
    (7, "addr1w8phkx6acpnf78fuvxn0mkew3l0fd058hzquvz7w36x4gtcyjy7wx");
    (14, "stake1uyehkck0lajq8gr28t9uxnuvgcqrc6070x3k9r8048z8y5gh6ffgw");
    (15, "stake178phkx6acpnf78fuvxn0mkew3l0fd058hzquvz7w36x4gtcccycj5");
  ]

let testnet =
  [
    ( 0,
      "addr_test1qz2fxv2umyhttkxyxp8x0dlpdt3k6cwng5pxj3jhsydzer3n0d3vllmyqwsx5wktcd8cc3sq835lu7drv2xwl2wywfgs68faae"
    );
    ( 1,
      "addr_test1zrphkx6acpnf78fuvxn0mkew3l0fd058hzquvz7w36x4gten0d3vllmyqwsx5wktcd8cc3sq835lu7drv2xwl2wywfgsxj90mg"
    );
    ( 2,
      "addr_test1yz2fxv2umyhttkxyxp8x0dlpdt3k6cwng5pxj3jhsydzerkr0vd4msrxnuwnccdxlhdjar77j6lg0wypcc9uar5d2shsf5r8qx"
    );
    ( 3,
      "addr_test1xrphkx6acpnf78fuvxn0mkew3l0fd058hzquvz7w36x4gt7r0vd4msrxnuwnccdxlhdjar77j6lg0wypcc9uar5d2shs4p04xh"
    );
    ( 4,
      "addr_test1gz2fxv2umyhttkxyxp8x0dlpdt3k6cwng5pxj3jhsydzer5pnz75xxcrdw5vky"
    );
    ( 5,
      "addr_test12rphkx6acpnf78fuvxn0mkew3l0fd058hzquvz7w36x4gtupnz75xxcryqrvmw"
    );
    (6, "addr_test1vz2fxv2umyhttkxyxp8x0dlpdt3k6cwng5pxj3jhsydzerspjrlsz");
    (7, "addr_test1wrphkx6acpnf78fuvxn0mkew3l0fd058hzquvz7w36x4gtcl6szpr");
  ]

(* Decoding and re-encoding must be the identity. This is the property the
   whole address layer rests on: a signer that renders an address differently
   from how it received it is showing the user something other than what it
   will sign. *)
let round_trip () =
  List.iter
    (fun (kind, s) ->
      let a = get (A.of_bech32 s) in
      Alcotest.(check string)
        (Printf.sprintf "mainnet type-%02d" kind)
        s
        (get (A.to_bech32 a));
      Alcotest.(check bool)
        (Printf.sprintf "mainnet type-%02d is mainnet" kind)
        true
        (N.equal (A.network a) N.mainnet))
    mainnet;
  List.iter
    (fun (kind, s) ->
      let a = get (A.of_bech32 s) in
      Alcotest.(check string)
        (Printf.sprintf "testnet type-%02d" kind)
        s
        (get (A.to_bech32 a));
      Alcotest.(check bool)
        (Printf.sprintf "testnet type-%02d is testnet" kind)
        false
        (N.equal (A.network a) N.mainnet))
    testnet

(* The header nibble decides the shape and which credentials are scripts. *)
let shapes () =
  let a k = get (A.of_bech32 (List.assoc k mainnet)) in
  (match a 0 with
  | A.Base { payment = A.Credential.Key _; stake = A.Credential.Key _; _ } -> ()
  | _ -> Alcotest.fail "type-00 should be base key/key");
  (match a 1 with
  | A.Base { payment = A.Credential.Script _; stake = A.Credential.Key _; _ } ->
      ()
  | _ -> Alcotest.fail "type-01 should be base script/key");
  (match a 2 with
  | A.Base { payment = A.Credential.Key _; stake = A.Credential.Script _; _ } ->
      ()
  | _ -> Alcotest.fail "type-02 should be base key/script");
  (match a 3 with
  | A.Base { payment = A.Credential.Script _; stake = A.Credential.Script _; _ }
    ->
      ()
  | _ -> Alcotest.fail "type-03 should be base script/script");
  (match a 4 with
  | A.Pointer _ -> ()
  | _ -> Alcotest.fail "type-04 should be pointer");
  (match a 6 with
  | A.Enterprise _ -> ()
  | _ -> Alcotest.fail "type-06 should be enterprise");
  (match a 14 with
  | A.Reward _ -> ()
  | _ -> Alcotest.fail "type-14 should be reward");
  (* For a reward address the credential bit describes the *stake* credential;
     there is no payment credential for it to describe. *)
  (match a 15 with
  | A.Reward { stake = A.Credential.Script _; _ } -> ()
  | _ -> Alcotest.fail "type-15 should be a script reward address");
  Alcotest.(check bool) "type-01 spends via a script" true (A.is_script (a 1));
  Alcotest.(check bool) "type-00 spends via a key" false (A.is_script (a 0));
  (* type-02 is a script *stake* credential with a key payment credential:
     reading bit 4 positionally would call this a script address. *)
  Alcotest.(check bool) "type-02 spends via a key" false (A.is_script (a 2))

let credentials () =
  let a k = get (A.of_bech32 (List.assoc k mainnet)) in
  Alcotest.(check bool)
    "base has both" true
    (A.payment_credential (a 0) <> None && A.stake_credential (a 0) <> None);
  Alcotest.(check bool)
    "enterprise has no stake credential" true
    (A.payment_credential (a 6) <> None && A.stake_credential (a 6) = None);
  (* A reward address cannot receive an output, and the type says so. *)
  Alcotest.(check bool)
    "reward has no payment credential" true
    (A.payment_credential (a 14) = None && A.stake_credential (a 14) <> None);
  Alcotest.(check bool)
    "pointer has no direct stake credential" true
    (A.stake_credential (a 4) = None)

let pointers () =
  (* Pointer fields are variable-length naturals, so the address has no fixed
     size and the three values must come back exactly as they went in. *)
  let a = get (A.of_bech32 (List.assoc 4 mainnet)) in
  match a with
  | A.Pointer { pointer; _ } ->
      Alcotest.(check string)
        "pointer round-trips"
        (Format.asprintf "%a" A.Pointer.pp pointer)
        (Format.asprintf "%a" A.Pointer.pp pointer);
      let re = get (A.of_bytes (A.to_bytes a)) in
      Alcotest.(check bool)
        "pointer bytes round-trip" true
        (String.equal (A.to_bytes a) (A.to_bytes re))
  | _ -> Alcotest.fail "expected a pointer address"

let rejections () =
  let good = List.assoc 0 mainnet in
  (* A single altered character must fail the checksum rather than decode to a
     different address. *)
  let flip s i =
    String.mapi (fun j c -> if j = i then if c = 'q' then 'p' else 'q' else c) s
  in
  Alcotest.(check bool)
    "single-character mutation is caught" true
    (match A.of_bech32 (flip good 20) with Error _ -> true | Ok _ -> false);
  (* An address whose human-readable part disagrees with its payload is two
     claims that contradict each other; neither is trustworthy. *)
  let stake_payload = A.to_bytes (get (A.of_bech32 (List.assoc 14 mainnet))) in
  let mislabelled =
    get
      (Result.map_error
         (fun m -> `Bech32 m)
         (Cardano_address.Bech32.encode_bytes Cardano_address.Bech32.Bech32
            ~hrp:"addr" stake_payload))
  in
  Alcotest.(check bool)
    "hrp/payload mismatch is refused" true
    (match A.of_bech32 mislabelled with Error _ -> true | Ok _ -> false);
  (* A mainnet payload under a testnet human-readable part, likewise. *)
  let main_payload = A.to_bytes (get (A.of_bech32 good)) in
  let wrong_net =
    get
      (Result.map_error
         (fun m -> `Bech32 m)
         (Cardano_address.Bech32.encode_bytes Cardano_address.Bech32.Bech32
            ~hrp:"addr_test" main_payload))
  in
  Alcotest.(check bool)
    "network mismatch is refused" true
    (match A.of_bech32 wrong_net with Error _ -> true | Ok _ -> false);
  Alcotest.(check bool)
    "empty input refused" true
    (match A.of_bytes "" with Error _ -> true | Ok _ -> false);
  Alcotest.(check bool)
    "short base address refused" true
    (match A.of_bytes (String.make 40 '\000') with
    | Error _ -> true
    | Ok _ -> false);
  (* Header types 1001-1101 are reserved for future formats. Guessing at one
     would mean signing something whose meaning is not yet defined. *)
  Alcotest.(check bool)
    "reserved header refused" true
    (match A.of_bytes (String.make 1 '\160' ^ String.make 28 '\000') with
    | Error (`Unknown_header _) -> true
    | _ -> false)

let byron () =
  (* Byron addresses are recognised so that a legacy address is not reported as
     a malformed Shelley one, but they are not constructed. *)
  let raw = String.make 1 '\130' ^ String.make 30 '\001' in
  match A.of_bytes raw with
  | Ok (A.Byron b) ->
      Alcotest.(check string) "carried verbatim" raw b;
      Alcotest.(check bool)
        "has no bech32 form" true
        (match A.to_bech32 (A.Byron b) with
        | Error `Byron_unsupported -> true
        | _ -> false)
  | _ -> Alcotest.fail "expected a Byron address"

let () =
  Alcotest.run "cardano-address"
    [
      ( "cip-19",
        [
          Alcotest.test_case "round trip" `Quick round_trip;
          Alcotest.test_case "shapes" `Quick shapes;
          Alcotest.test_case "credentials" `Quick credentials;
          Alcotest.test_case "pointers" `Quick pointers;
        ] );
      ( "rejection",
        [
          Alcotest.test_case "malformed input" `Quick rejections;
          Alcotest.test_case "byron" `Quick byron;
        ] );
    ]
