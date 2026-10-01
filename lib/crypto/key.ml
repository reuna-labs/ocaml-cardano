(* Native Cardano reference V2/Icarus backend; no RNG or host dependencies. *)

module B = Mirage_crypto_ed25519_bip32

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
  type t = B.extended_priv

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

let verify_raw ~vkey ~signature msg = B.verify_raw ~key:vkey signature ~msg

module Icarus = struct
  let of_entropy ?(passphrase = "") entropy =
    lift ~len:(String.length entropy)
      (B.icarus_key_of_entropy ~passphrase entropy)
end
