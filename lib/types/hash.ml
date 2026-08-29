(* Blake2b at two widths, from digestif's functor. mirage-crypto-blockchain
   wraps exactly this, but it also carries secp256k1, BLS and Poseidon, and
   with them zarith -- so at this layer we take the four lines rather than the
   dependency. *)

module B224 = Digestif.Make_BLAKE2B (struct let digest_size = 28 end)
module B256 = Digestif.Make_BLAKE2B (struct let digest_size = 32 end)

let blake2b224 s = B224.(to_raw_string (digest_string s))
let blake2b256 s = B256.(to_raw_string (digest_string s))

module type HASH = sig
  type t

  val size : int
  val of_bytes : string -> (t, string) result
  val to_bytes : t -> string
  val of_hex : string -> (t, string) result
  val to_hex : t -> string
  val digest : string -> t
  val equal : t -> t -> bool
  val compare : t -> t -> int
  val pp : Format.formatter -> t -> unit
end

module Make_hash (P : sig
  val size : int
  val name : string
  val digest : string -> string
end) : HASH = struct
  type t = string

  let size = P.size

  let of_bytes s =
    if String.length s = size then Ok s
    else
      Error
        (Printf.sprintf "%s: expected %d bytes, got %d" P.name size
           (String.length s))

  let to_bytes t = t
  let digest s = P.digest s

  let to_hex t =
    String.concat ""
      (List.map (fun c -> Printf.sprintf "%02x" (Char.code c))
         (List.init (String.length t) (String.get t)))

  let of_hex h =
    let n = String.length h in
    if n <> size * 2 then
      Error (Printf.sprintf "%s: expected %d hex characters, got %d" P.name (size * 2) n)
    else
      let nib c =
        match c with
        | '0' .. '9' -> Some (Char.code c - 48)
        | 'a' .. 'f' -> Some (Char.code c - 87)
        | 'A' .. 'F' -> Some (Char.code c - 55)
        | _ -> None
      in
      let buf = Bytes.create size in
      let rec go i =
        if i = size then Ok (Bytes.unsafe_to_string buf)
        else
          match (nib h.[i * 2], nib h.[(i * 2) + 1]) with
          | Some hi, Some lo ->
              Bytes.set buf i (Char.chr ((hi lsl 4) lor lo));
              go (i + 1)
          | _ -> Error (Printf.sprintf "%s: not hexadecimal" P.name)
      in
      go 0

  let equal = String.equal
  let compare = String.compare
  let pp ppf t = Format.pp_print_string ppf (to_hex t)
end

module Addr_key_hash = Make_hash (struct
  let size = 28 and name = "addr_key_hash"
  let digest = blake2b224
end)

module Script_hash = Make_hash (struct
  let size = 28 and name = "script_hash"
  let digest = blake2b224
end)

module Pool_key_hash = Make_hash (struct
  let size = 28 and name = "pool_key_hash"
  let digest = blake2b224
end)

module Tx_id = Make_hash (struct
  let size = 32 and name = "tx_id"
  let digest = blake2b256
end)

module Datum_hash = Make_hash (struct
  let size = 32 and name = "datum_hash"
  let digest = blake2b256
end)

module Aux_data_hash = Make_hash (struct
  let size = 32 and name = "auxiliary_data_hash"
  let digest = blake2b256
end)

module Script_data_hash = Make_hash (struct
  let size = 32 and name = "script_data_hash"
  let digest = blake2b256
end)
