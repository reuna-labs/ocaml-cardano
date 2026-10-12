(* Signs a Conway payment for tools/preprod-check.sh, using only the published
   packages: a fresh CIP-1852 key and its preprod enterprise address, one real
   unspent input that belongs to someone else (PREPROD_INPUT, "<tx id>#<index>",
   holding PREPROD_INPUT_LOVELACE and nothing else), one output to that address
   carrying the input's value less the fee, the fee from Fee.min_fee over the
   fully signed size, and a TTL an hour past the tip.

   Signed by the fresh key only, so the ledger must refuse it for the owner's
   missing witness, and nothing moves. Every other rule it can check against
   real state: value conservation, the fee, the output's minimum, the witness
   that is there.

   Preprod's own parameters arrive in the environment (PREPROD_MIN_FEE_A,
   PREPROD_MIN_FEE_B, PREPROD_COINS_PER_UTXO_BYTE, PREPROD_SLOT), fetched
   moments before, so the fee is the one preprod would charge rather than
   mainnet's. Prints the address, the transaction id, the fee and the wire
   bytes as "wire <hex>". *)

module T = Cardano_types
module P = T.Protocol_params
module A = Cardano_address.Address
module B = Cardano_transaction.Body
module Tx = Cardano_transaction.Transaction
module W = Cardano_transaction.Witness
module F = Cardano_transaction.Fee
module K = Cardano_crypto.Key
module D = Cardano_crypto.Derivation_path

let die fmt = Printf.ksprintf (fun s -> prerr_endline s; exit 1) fmt
let ok what = function Ok v -> v | Error e -> die "%s: %s" what e
let okk what = function Ok v -> v | Error e -> die "%s: %s" what (Format.asprintf "%a" K.pp_error e)
let env name = match Sys.getenv_opt name with Some v -> Int64.of_string v | None -> die "%s is not set" name
let coin what n = ok what (Result.map_error (fun _ -> "out of range") (T.Coin.of_lovelace n))

let hex s = String.concat "" (List.init (String.length s) (fun i -> Printf.sprintf "%02x" (Char.code s.[i])))

let random n =
  let ic = open_in_bin "/dev/urandom" in
  let s = really_input_string ic n in
  close_in ic;
  s

let () =
  let params =
    { P.mainnet_snapshot with
      P.min_fee_a = env "PREPROD_MIN_FEE_A";
      P.min_fee_b = env "PREPROD_MIN_FEE_B";
      P.coins_per_utxo_byte = env "PREPROD_COINS_PER_UTXO_BYTE" }
  in
  let root = okk "master key" (K.Icarus.of_entropy (random 20)) in
  let path =
    okk "path"
      (Result.map_error (fun `Invalid_range -> `Invalid_derivation)
         (D.address ~account:0l ~role:D.External ~index:0l))
  in
  let key = okk "derive" (K.Xprv.derive_path root path) in
  let address =
    A.Enterprise
      { network = T.Network.Testnet { magic = 1l };
        payment = A.Credential.Key (K.Xpub.hash (K.Xprv.public key)) }
  in
  let input =
    match String.split_on_char '#' (Option.value (Sys.getenv_opt "PREPROD_INPUT") ~default:"") with
    | [ id; index ] -> ok "input" (B.Input.make (ok "tx id" (T.Hash.Tx_id.of_hex id)) (int_of_string index))
    | _ -> die "PREPROD_INPUT is not <tx id>#<index>"
  in
  let held = env "PREPROD_INPUT_LOVELACE" in
  let ttl = Int64.add (env "PREPROD_SLOT") 3600L in
  let build fee =
    let body =
      { B.empty with
        B.inputs = [ input ];
        B.outputs = [ B.Output.make address (T.Value.of_coin (coin "output" (Int64.sub held fee))) ];
        B.fee = coin "fee" fee;
        B.ttl = Some ttl }
    in
    Tx.sign { Tx.body; Tx.witness_set = W.empty; Tx.is_valid = true; Tx.auxiliary_data = None; Tx.raw = None } key
  in
  (* The fee depends on the signed size and the size on the fee's encoding:
     iterate until it stops moving, as a builder must. *)
  let rec settle fee n =
    let tx = build fee in
    let need = T.Coin.to_lovelace (ok "min fee" (F.min_fee params ~tx_size:(String.length (Tx.to_cbor tx)) ())) in
    if need = fee then tx
    else if n = 0 then die "the fee did not settle"
    else settle need (n - 1)
  in
  let tx = settle 0L 5 in
  Printf.printf "address %s\n" (ok "bech32" (Result.map_error (fun _ -> "bech32") (A.to_bech32 address)));
  Printf.printf "tx_id %s\n" (T.Hash.Tx_id.to_hex (Tx.id tx));
  Printf.printf "fee %Ld\n" (T.Coin.to_lovelace tx.Tx.body.B.fee);
  Printf.printf "ttl %Ld\n" ttl;
  Printf.printf "wire %s\n" (hex (Tx.to_cbor tx))
