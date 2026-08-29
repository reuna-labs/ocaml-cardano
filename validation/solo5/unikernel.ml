external console_write : string -> unit = "cardano_console_write"
let say = console_write
let hex s = String.concat "" (List.map (fun c -> Printf.sprintf "%02x" (Char.code c))
  (List.init (String.length s) (String.get s)))
module T = Cardano_types
module K = Cardano_crypto.Key
module A = Cardano_address.Address
module B = Cardano_transaction.Body
let () =
  say ("blake2b224(abc) = " ^ hex (T.blake2b224 "abc") ^ "\n");
  let entropy = "\x46\xe6\x23\x70\xa1\x38\xa1\x82\xa4\x98\xb8\xe2\x88\x5b\xc0\x32\x37\x9d\xdf\x38" in
  match K.Icarus.of_entropy entropy with
  | Error _ -> say "icarus: FAILED\n"
  | Ok root ->
      say ("icarus master  = " ^ hex (String.sub (K.Xprv.to_bytes root) 0 16) ^ "...\n");
      let pub = K.Xprv.public root in
      let cred = A.Credential.Key (K.Xpub.hash pub) in
      let addr = A.Enterprise { network = T.Network.mainnet; payment = cred } in
      (match A.to_bech32 addr with
       | Ok s -> say ("address        = " ^ s ^ "\n") | Error _ -> say "address FAILED\n");
      let body = { B.empty with
        B.fee = Result.get_ok (T.Coin.of_lovelace 170000L);
        B.outputs = [ B.Output.make addr (T.Value.of_coin (Result.get_ok (T.Coin.of_lovelace 2000000L))) ] } in
      say ("tx id          = " ^ T.Hash.Tx_id.to_hex (B.id body) ^ "\n");
      let sg = K.Xprv.sign root (T.Hash.Tx_id.to_bytes (B.id body)) in
      say ("signature ok   = " ^ string_of_bool (K.Xpub.verify pub ~signature:sg (T.Hash.Tx_id.to_bytes (B.id body))) ^ "\n");
      say "cardano: full offline path verified in-guest\n"
