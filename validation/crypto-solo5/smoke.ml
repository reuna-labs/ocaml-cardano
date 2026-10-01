module K = Cardano_crypto.Key
module P = Cardano_crypto.Derivation_path

let ok = function Ok x -> x | Error _ -> failwith "Cardano Solo5 operation"

let () =
  let root = ok (K.Icarus.of_entropy (String.make 20 '\042')) in
  let path = ok (P.address ~account:0l ~role:P.External ~index:7l) in
  let key = ok (K.Xprv.derive_path root path) in
  let pub = K.Xprv.public key in
  let msg = "Cardano full native pipeline in Solo5" in
  let signature = K.Xprv.sign key msg in
  assert (K.Xpub.verify pub ~signature msg);
  assert (K.verify_raw ~vkey:(K.Xpub.raw pub) ~signature msg);
  assert (
    String.length (Cardano_types.Hash.Addr_key_hash.to_bytes (K.Xpub.hash pub))
    = 28);
  let soft = ok (K.Xprv.derive key 1l) in
  let public_soft = ok (K.Xpub.derive pub 1l) in
  assert (K.Xpub.to_bytes (K.Xprv.public soft) = K.Xpub.to_bytes public_soft);
  print_endline
    "Cardano Icarus/CIP-1852/sign/verify/hash/public derivation passed in \
     Solo5 (no RNG)"
