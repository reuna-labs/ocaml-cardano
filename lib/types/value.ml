(* Multi-asset values.

   Quantities are unsigned 64-bit throughout. Int64 is the storage, not the
   semantics: every comparison and every overflow check below goes through
   Int64.unsigned_compare, because a native asset can legitimately hold more
   than Int64.max_int of itself and reading that as negative would be a
   catastrophic and entirely silent error. *)

module Asset_name = struct
  type t = string

  let max_length = 32

  let of_bytes s =
    if String.length s <= max_length then Ok s
    else
      Error
        (Printf.sprintf "asset_name: %d bytes exceeds the %d-byte maximum"
           (String.length s) max_length)

  let to_bytes t = t
  let empty = ""

  let to_hex t =
    String.concat ""
      (List.map (fun c -> Printf.sprintf "%02x" (Char.code c))
         (List.init (String.length t) (String.get t)))

  let printable t =
    t <> ""
    && String.for_all (fun c -> Char.code c >= 0x20 && Char.code c < 0x7f) t

  let to_display t = if printable t then t else to_hex t
  let compare = String.compare
  let equal = String.equal
  let pp ppf t = Format.pp_print_string ppf (to_display t)
end

type policy_id = Hash.Script_hash.t
type asset = { policy : policy_id; name : Asset_name.t }

let asset policy name = { policy; name }

let compare_asset a b =
  match Hash.Script_hash.compare a.policy b.policy with
  | 0 -> Asset_name.compare a.name b.name
  | c -> c

module Quantity = struct
  type t = int64

  let ucmp = Int64.unsigned_compare
  let one = 1L

  let of_int64_unsigned v =
    if v = 0L then Error "quantity: zero is not representable in a value" else Ok v

  let of_int n =
    if n <= 0 then Error "quantity: must be positive" else Ok (Int64.of_int n)

  let to_int64_unsigned t = t
  let to_string t = Printf.sprintf "%Lu" t

  let to_int t =
    if ucmp t (Int64.of_int max_int) <= 0 then Some (Int64.to_int t) else None

  let add a b =
    let r = Int64.add a b in
    (* Unsigned overflow shows up as a sum that is unsigned-less than either
       addend. Signed comparison would miss it above 2^63. *)
    if ucmp r a < 0 then Error "quantity: addition overflowed 2^64" else Ok r

  let sub a b =
    if ucmp a b <= 0 then Error "quantity: subtraction would reach zero or below"
    else Ok (Int64.sub a b)

  let compare = ucmp
  let equal = Int64.equal
  let pp ppf t = Format.pp_print_string ppf (to_string t)
end

module Amap = Map.Make (struct
  type t = asset

  let compare = compare_asset
end)

module Multi_asset = struct
  type t = Quantity.t Amap.t

  let empty = Amap.empty
  let is_empty = Amap.is_empty
  let size = Amap.cardinal
  let to_list t = Amap.bindings t
  let find t a = Amap.find_opt a t

  let of_list l =
    List.fold_left
      (fun acc (a, q) ->
        Result.bind acc (fun m ->
            match Amap.find_opt a m with
            | None -> Ok (Amap.add a q m)
            | Some existing ->
                Result.map (fun s -> Amap.add a s m) (Quantity.add existing q)))
      (Ok empty) l

  let add x y =
    Amap.fold
      (fun a q acc ->
        Result.bind acc (fun m ->
            match Amap.find_opt a m with
            | None -> Ok (Amap.add a q m)
            | Some e -> Result.map (fun s -> Amap.add a s m) (Quantity.add e q)))
      y (Ok x)

  let policies t =
    List.sort_uniq Hash.Script_hash.compare
      (List.map (fun (a, _) -> a.policy) (to_list t))

  let compare = Amap.compare Quantity.compare
  let equal = Amap.equal Quantity.equal

  let pp ppf t =
    Format.fprintf ppf "@[<hov>%a@]"
      (Format.pp_print_list
         ~pp_sep:(fun ppf () -> Format.fprintf ppf " +@ ")
         (fun ppf (a, q) ->
           Format.fprintf ppf "%a %s.%a" Quantity.pp q
             (Hash.Script_hash.to_hex a.policy)
             Asset_name.pp a.name))
      (to_list t)
end

module Value = struct
  type t = { coin : Coin.t; assets : Multi_asset.t }

  let zero = { coin = Coin.zero; assets = Multi_asset.empty }
  let of_coin coin = { coin; assets = Multi_asset.empty }
  let make coin assets = { coin; assets }
  let is_ada_only t = Multi_asset.is_empty t.assets

  let coin_err = function
    | Ok v -> Ok v
    | Error e -> Error (Format.asprintf "%a" Coin.pp_error e)

  let add a b =
    Result.bind (coin_err (Coin.add a.coin b.coin)) (fun coin ->
        Result.map
          (fun assets -> { coin; assets })
          (Multi_asset.add a.assets b.assets))

  let sub a b =
    Result.bind (coin_err (Coin.sub a.coin b.coin)) (fun coin ->
        let rec go acc = function
          | [] -> Ok acc
          | (asset, q) :: rest -> (
              match Multi_asset.find a.assets asset with
              | None ->
                  Error
                    (Printf.sprintf "value: does not hold %s.%s"
                       (Hash.Script_hash.to_hex asset.policy)
                       (Asset_name.to_display asset.name))
              | Some have ->
                  if Quantity.equal have q then go acc rest
                  else
                    Result.bind (Quantity.sub have q) (fun d ->
                        go ((asset, d) :: acc) rest))
        in
        let kept =
          List.filter
            (fun (asset, _) -> Multi_asset.find b.assets asset = None)
            (Multi_asset.to_list a.assets)
        in
        Result.bind (go kept (Multi_asset.to_list b.assets)) (fun l ->
            Result.map (fun assets -> { coin; assets }) (Multi_asset.of_list l)))

  let contains a b =
    Coin.compare a.coin b.coin >= 0
    && List.for_all
         (fun (asset, need) ->
           match Multi_asset.find a.assets asset with
           | None -> false
           | Some have -> Quantity.compare have need >= 0)
         (Multi_asset.to_list b.assets)

  let compare a b =
    match Coin.compare a.coin b.coin with
    | 0 -> Multi_asset.compare a.assets b.assets
    | c -> c

  let equal a b = compare a b = 0

  let pp ppf t =
    if is_ada_only t then Coin.pp ppf t.coin
    else Format.fprintf ppf "%a + %a" Coin.pp t.coin Multi_asset.pp t.assets
end

module Mint = struct
  type t = int64 Amap.t

  let empty = Amap.empty
  let is_empty = Amap.is_empty
  let size = Amap.cardinal
  let to_list t = Amap.bindings t

  let of_list l =
    List.fold_left
      (fun acc (a, d) ->
        Result.bind acc (fun m ->
            if d = 0L then
              Error "mint: a zero delta is not representable (nonzero_int64)"
            else if Amap.mem a m then Error "mint: duplicate asset"
            else Ok (Amap.add a d m)))
      (Ok empty) l

  let compare = Amap.compare Int64.compare
  let equal = Amap.equal Int64.equal

  let pp ppf t =
    Format.fprintf ppf "@[<hov>%a@]"
      (Format.pp_print_list
         ~pp_sep:(fun ppf () -> Format.fprintf ppf ",@ ")
         (fun ppf (a, d) ->
           Format.fprintf ppf "%+Ld %s.%a" d
             (Hash.Script_hash.to_hex a.policy)
             Asset_name.pp a.name))
      (to_list t)
end
