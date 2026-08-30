(* BIP32-Ed25519 keys.

   The derivation itself comes from Mirage_crypto_blockchain_core, which
   implements DerivationScheme V2 cross-checked against rust-ed25519-bip32.
   What is added here is the Cardano-specific way in: the Icarus master key,
   which the paper's own scheme does not describe. *)

module B = Mirage_crypto_blockchain_core.Ed25519_bip32

type error =
  [ `Invalid_length of int
  | `Invalid_format
  | `Invalid_derivation
  | `Hardened_from_public ]

let pp_error ppf = function
  | `Invalid_length n -> Format.fprintf ppf "key: wrong length (%d bytes)" n
  | `Invalid_format -> Format.pp_print_string ppf "key: malformed"
  | `Invalid_derivation -> Format.pp_print_string ppf "key: derivation failed"
  | `Hardened_from_public ->
      Format.pp_print_string ppf
        "key: a hardened child cannot be derived from a public key"

let lift ~len = function
  | Ok v -> Ok v
  | Error `Invalid_length -> Error (`Invalid_length len)
  | Error `Invalid_format -> Error `Invalid_format
  | Error `Invalid_derivation -> Error `Invalid_derivation

let is_hardened i = Int32.compare i 0l < 0

module Xpub : sig
  type t

  val of_bytes : string -> (t, error) result
  val to_bytes : t -> string
  val derive : t -> int32 -> (t, error) result
  val derive_path : t -> Derivation_path.t -> (t, error) result
  val raw : t -> string
  val hash : t -> Cardano_types.Hash.Addr_key_hash.t
  val verify : t -> signature:string -> string -> bool
end = struct
  type t = B.extended_pub

  let of_bytes s = lift ~len:(String.length s) (B.extended_pub_of_octets s)
  let to_bytes = B.extended_pub_to_octets

  let derive t index =
    if is_hardened index then Error `Hardened_from_public
    else lift ~len:64 (B.derive_pub_normal t ~index)

  let derive_path t path =
    List.fold_left
      (fun acc i -> Result.bind acc (fun k -> derive k i))
      (Ok t)
      (Derivation_path.to_list path)

  let raw t = String.sub (to_bytes t) 0 32

  let hash t =
    match
      Cardano_types.Hash.Addr_key_hash.of_bytes
        (Cardano_types.blake2b224 (raw t))
    with
    | Ok h -> h
    | Error m -> invalid_arg ("Key.Xpub.hash: " ^ m)

  let verify t ~signature msg = B.verify ~key:t signature ~msg
end

module Xprv : sig
  type t

  val of_bytes : string -> (t, error) result
  val to_bytes : t -> string
  val derive : t -> int32 -> (t, error) result
  val derive_path : t -> Derivation_path.t -> (t, error) result
  val public : t -> Xpub.t
  val sign : t -> string -> string
end = struct
  type t = B.extended_priv

  let of_bytes s = lift ~len:(String.length s) (B.extended_priv_of_octets s)
  let to_bytes = B.extended_priv_to_octets

  let derive t index =
    lift ~len:96
      (if is_hardened index then B.derive_priv_hardened t ~index
       else B.derive_priv_normal t ~index)

  let derive_path t path =
    List.fold_left
      (fun acc i -> Result.bind acc (fun k -> derive k i))
      (Ok t)
      (Derivation_path.to_list path)

  let public t =
    match Xpub.of_bytes (B.extended_pub_to_octets (B.pub_of_priv t)) with
    | Ok p -> p
    | Error _ ->
        (* pub_of_priv produces a well-formed point by construction, so this
           branch is unreachable rather than merely unlikely. *)
        invalid_arg "Key.Xprv.public: derived public key failed validation"

  let sign t msg = B.sign ~key:t msg
end

let verify_raw ~vkey ~signature msg =
  String.length vkey = 32
  && String.length signature = 64
  &&
  match Mirage_crypto_ec.Ed25519.pub_of_octets vkey with
  | Error _ -> false
  | Ok key -> Mirage_crypto_ec.Ed25519.verify ~key signature ~msg

module Icarus = struct
  (* PBKDF2-HMAC-SHA512. Written here rather than pulled from the `pbkdf`
     package: it is fifteen lines over digestif's HMAC, and this library's
     offline closure is deliberately kept to digestif and mirage-crypto-ec so
     that a Solo5 duniverse stays small. *)
  let pbkdf2_hmac_sha512 ~password ~salt ~count ~dk_len =
    let hlen = 64 in
    let hmac ~key data =
      Digestif.SHA512.(to_raw_string (hmac_string ~key data))
    in
    let xor a b =
      String.init hlen (fun i ->
          Char.chr (Char.code a.[i] lxor Char.code b.[i]))
    in
    let block i =
      let be = Bytes.create 4 in
      Bytes.set_int32_be be 0 (Int32.of_int i);
      let u1 = hmac ~key:password (salt ^ Bytes.unsafe_to_string be) in
      let rec go n u acc =
        if n = 0 then acc
        else
          let u' = hmac ~key:password u in
          go (n - 1) u' (xor acc u')
      in
      go (count - 1) u1 u1
    in
    let n = (dk_len + hlen - 1) / hlen in
    let buf = Buffer.create (n * hlen) in
    for i = 1 to n do
      Buffer.add_string buf (block i)
    done;
    String.sub (Buffer.contents buf) 0 dk_len

  let of_entropy ?(passphrase = "") entropy =
    let n = String.length entropy in
    if n < 16 || n > 32 then Error (`Invalid_length n)
    else
      (* CIP-3: the passphrase is the password and the entropy is the salt.
         BIP39's seed function has them the other way round, and swapping them
         yields a valid key for a wallet nobody else will ever look in. *)
      let dk =
        pbkdf2_hmac_sha512 ~password:passphrase ~salt:entropy ~count:4096
          ~dk_len:96
      in
      let b = Bytes.of_string dk in
      (* The standard Ed25519 clamp: clear the low three bits of the first byte
         so the scalar is a multiple of the cofactor, and fix bits 6 and 7 of
         the last byte of kL so it stays in range under the additions that
         derivation performs. *)
      let set i v = Bytes.set b i (Char.chr v) in
      set 0 (Char.code (Bytes.get b 0) land 0xf8);
      set 31 (Char.code (Bytes.get b 31) land 0x1f lor 0x40);
      Xprv.of_bytes (Bytes.unsafe_to_string b)
end
