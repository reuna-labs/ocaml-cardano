(* The public surface of cardano-types. Everything else in this directory is
   reached through here, so this index is also the list of what a consumer is
   allowed to depend on.

   The local alias matters: `module Value = V.Value` shadows the file-level
   Value module, so every reference to it has to be taken before that line. *)

module V = Value
module Hash = Hash
module Coin = Coin
module Network = Network
module Rational = Cardano_rational
module Protocol_params = Protocol_params
module Asset_name = V.Asset_name
module Quantity = V.Quantity
module Multi_asset = V.Multi_asset
module Mint = V.Mint
module Value = V.Value

type policy_id = Hash.Script_hash.t
type asset = V.asset = { policy : policy_id; name : Asset_name.t }

let asset = V.asset
let compare_asset = V.compare_asset
let blake2b224 = Hash.blake2b224
let blake2b256 = Hash.blake2b256
