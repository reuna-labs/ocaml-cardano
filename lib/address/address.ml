(* CIP-19 addresses.

   The header byte layout, from the comment in the Conway CDDL:

     bits 7-4  shape and credential kinds
     bits 3-0  network id

     0000 base:       keyhash28,    keyhash28
     0001 base:       scripthash28, keyhash28
     0010 base:       keyhash28,    scripthash28
     0011 base:       scripthash28, scripthash28
     0100 pointer:    keyhash28,    3 variable-length uints
     0101 pointer:    scripthash28, 3 variable-length uints
     0110 enterprise: keyhash28
     0111 enterprise: scripthash28
     1000 byron
     1110 reward:     keyhash28
     1111 reward:     scripthash28
     1001-1101 future formats

   Note bit 4 means "payment credential is a script" for the first eight, but
   for a reward address it means the *stake* credential is. Reading it
   positionally rather than per-shape is the mistake this file exists to avoid
   making. *)

module H = Cardano_types.Hash
module N = Cardano_types.Network

type error =
  [ `Invalid_length of int
  | `Unknown_header of int
  | `Invalid_network of int
  | `Invalid_pointer
  | `Trailing_bytes of int
  | `Bech32 of string
  | `Not_bech32
  | `Byron_unsupported ]

let pp_error ppf = function
  | `Invalid_length n -> Format.fprintf ppf "address: wrong length (%d bytes)" n
  | `Unknown_header h -> Format.fprintf ppf "address: unknown header type %d" (h lsr 4)
  | `Invalid_network n -> Format.fprintf ppf "address: bad network id %d" n
  | `Invalid_pointer -> Format.pp_print_string ppf "address: malformed pointer"
  | `Trailing_bytes n -> Format.fprintf ppf "address: %d trailing bytes" n
  | `Bech32 m -> Format.fprintf ppf "address: %s" m
  | `Not_bech32 ->
      Format.pp_print_string ppf
        "address: not bech32 (a Byron address is base58 and is not supported)"
  | `Byron_unsupported ->
      Format.pp_print_string ppf "address: Byron addresses are not constructed here"

module Credential = struct
  type t = Key of H.Addr_key_hash.t | Script of H.Script_hash.t

  let to_bytes = function
    | Key h -> H.Addr_key_hash.to_bytes h
    | Script h -> H.Script_hash.to_bytes h

  let is_script = function Script _ -> true | Key _ -> false
  let equal a b = is_script a = is_script b && String.equal (to_bytes a) (to_bytes b)

  let compare a b =
    match Bool.compare (is_script a) (is_script b) with
    | 0 -> String.compare (to_bytes a) (to_bytes b)
    | c -> c

  let pp ppf c =
    Format.fprintf ppf "%s:%s"
      (if is_script c then "script" else "key")
      (String.concat ""
         (List.map (fun ch -> Printf.sprintf "%02x" (Char.code ch))
            (List.init (String.length (to_bytes c)) (String.get (to_bytes c)))))

  let of_bytes ~script s =
    if script then Result.map (fun h -> Script h) (H.Script_hash.of_bytes s)
    else Result.map (fun h -> Key h) (H.Addr_key_hash.of_bytes s)
end

module Pointer = struct
  type t = { slot : int64; tx_index : int64; cert_index : int64 }

  let equal a b =
    Int64.equal a.slot b.slot
    && Int64.equal a.tx_index b.tx_index
    && Int64.equal a.cert_index b.cert_index

  let pp ppf p = Format.fprintf ppf "(%Ld,%Ld,%Ld)" p.slot p.tx_index p.cert_index

  (* Base-128, most significant group first, continuation bit set on every byte
     but the last. This is the ledger's own "variable length natural", not a
     CBOR integer and not LEB128 -- LEB128 puts the least significant group
     first, so getting them confused reverses the value. *)
  let encode_natural v =
    if Int64.equal v 0L then "\000"
    else
      let rec groups acc v =
        if Int64.equal v 0L then acc
        else
          groups
            (Int64.to_int (Int64.logand v 0x7fL) :: acc)
            (Int64.shift_right_logical v 7)
      in
      let gs = groups [] v in
      let n = List.length gs in
      String.init n (fun i ->
          let g = List.nth gs i in
          Char.chr (if i = n - 1 then g else g lor 0x80))

  let read_natural s pos =
    let len = String.length s in
    let rec go pos acc n =
      if pos >= len then Error `Invalid_pointer
      else if n > 10 then Error `Invalid_pointer
      else
        let b = Char.code s.[pos] in
        let acc = Int64.logor (Int64.shift_left acc 7) (Int64.of_int (b land 0x7f)) in
        if b land 0x80 = 0 then Ok (acc, pos + 1) else go (pos + 1) acc (n + 1)
    in
    go pos 0L 0
end

type t =
  | Base of { network : N.t; payment : Credential.t; stake : Credential.t }
  | Pointer of { network : N.t; payment : Credential.t; pointer : Pointer.t }
  | Enterprise of { network : N.t; payment : Credential.t }
  | Reward of { network : N.t; stake : Credential.t }
  | Byron of string

let network = function
  | Base { network; _ } | Pointer { network; _ } | Enterprise { network; _ }
  | Reward { network; _ } -> network
  | Byron _ -> N.mainnet

let payment_credential = function
  | Base { payment; _ } | Pointer { payment; _ } | Enterprise { payment; _ } ->
      Some payment
  | Reward _ | Byron _ -> None

let stake_credential = function
  | Base { stake; _ } -> Some stake
  | Reward { stake; _ } -> Some stake
  | Pointer _ | Enterprise _ | Byron _ -> None

let is_script a =
  match payment_credential a with Some c -> Credential.is_script c | None -> false

let header_of = function
  | Base { network; payment; stake } ->
      let t =
        (if Credential.is_script payment then 1 else 0)
        lor (if Credential.is_script stake then 2 else 0)
      in
      (t lsl 4) lor N.id network
  | Pointer { network; payment; _ } ->
      ((4 lor if Credential.is_script payment then 1 else 0) lsl 4) lor N.id network
  | Enterprise { network; payment } ->
      ((6 lor if Credential.is_script payment then 1 else 0) lsl 4) lor N.id network
  | Reward { network; stake } ->
      ((14 lor if Credential.is_script stake then 1 else 0) lsl 4) lor N.id network
  | Byron _ -> 0b1000_0000

let to_bytes a =
  match a with
  | Byron raw -> raw
  | Base { payment; stake; _ } ->
      String.make 1 (Char.chr (header_of a))
      ^ Credential.to_bytes payment ^ Credential.to_bytes stake
  | Pointer { payment; pointer; _ } ->
      String.make 1 (Char.chr (header_of a))
      ^ Credential.to_bytes payment
      ^ Pointer.encode_natural pointer.Pointer.slot
      ^ Pointer.encode_natural pointer.Pointer.tx_index
      ^ Pointer.encode_natural pointer.Pointer.cert_index
  | Enterprise { payment; _ } ->
      String.make 1 (Char.chr (header_of a)) ^ Credential.to_bytes payment
  | Reward { stake; _ } ->
      String.make 1 (Char.chr (header_of a)) ^ Credential.to_bytes stake

let ( let* ) = Result.bind
let cred ~script s = Result.map_error (fun _ -> `Invalid_length (String.length s))
    (Credential.of_bytes ~script s)

let of_bytes s =
  let len = String.length s in
  if len = 0 then Error (`Invalid_length 0)
  else
    let h = Char.code s.[0] in
    let kind = h lsr 4 in
    if kind = 0b1000 then Ok (Byron s)
    else
      let* network =
        Result.map_error (fun _ -> `Invalid_network (h land 0x0f)) (N.of_id (h land 0x0f))
      in
      let at i n =
        if i + n > len then Error (`Invalid_length len) else Ok (String.sub s i n)
      in
      match kind with
      | 0 | 1 | 2 | 3 ->
          if len <> 57 then Error (`Invalid_length len)
          else
            let* p = at 1 28 in
            let* q = at 29 28 in
            let* payment = cred ~script:(kind land 1 = 1) p in
            let* stake = cred ~script:(kind land 2 = 2) q in
            Ok (Base { network; payment; stake })
      | 4 | 5 ->
          let* p = at 1 28 in
          let* payment = cred ~script:(kind land 1 = 1) p in
          let* slot, i = Pointer.read_natural s 29 in
          let* tx_index, i = Pointer.read_natural s i in
          let* cert_index, i = Pointer.read_natural s i in
          if i <> len then Error (`Trailing_bytes (len - i))
          else
            Ok
              (Pointer
                 { network; payment; pointer = { Pointer.slot; tx_index; cert_index } })
      | 6 | 7 ->
          if len <> 29 then Error (`Invalid_length len)
          else
            let* p = at 1 28 in
            let* payment = cred ~script:(kind land 1 = 1) p in
            Ok (Enterprise { network; payment })
      | 14 | 15 ->
          if len <> 29 then Error (`Invalid_length len)
          else
            let* p = at 1 28 in
            (* For a reward address bit 4 describes the stake credential, not a
               payment one. There is no payment credential to describe. *)
            let* stake = cred ~script:(kind land 1 = 1) p in
            Ok (Reward { network; stake })
      | _ -> Error (`Unknown_header h)

let hrp = function
  | Byron _ -> Error `Byron_unsupported
  | Reward { network; _ } ->
      Ok (match network with N.Mainnet -> "stake" | N.Testnet _ -> "stake_test")
  | a ->
      Ok (match network a with N.Mainnet -> "addr" | N.Testnet _ -> "addr_test")

let to_bech32 a =
  let* hrp = hrp a in
  Result.map_error (fun m -> `Bech32 m)
    (Bech32.encode_bytes Bech32.Bech32 ~hrp (to_bytes a))

let of_bech32 s =
  (* Bound as [got_hrp] so it does not shadow the [hrp] function below. *)
  let* enc, got_hrp, payload =
    Result.map_error (fun m -> `Bech32 m) (Bech32.decode_bytes s)
  in
  if enc <> Bech32.Bech32 then Error (`Bech32 "bech32m checksum on a bech32 address")
  else
    let* a = of_bytes payload in
    (* The human-readable part is not decoration: it says which chain and which
       kind, and a mismatch means the two halves disagree about what this is. *)
    let* expected = hrp a in
    if String.equal expected got_hrp then Ok a
    else
      Error
        (`Bech32
           (Printf.sprintf
              "human-readable part %S does not match the payload (%S)" got_hrp
              expected))

let to_string = to_bech32

let of_string s =
  match String.index_opt s '1' with
  | None -> Error `Not_bech32
  | Some _ -> of_bech32 s
