type 'a t = {
  name : string;
  params : Yojson.Safe.t option;
  decode : Yojson.Safe.t -> ('a, string) result;
}

let make ~name ?params decode = { name; params; decode }
let name t = t.name
let params t = t.params

let decode t json =
  match t.decode json with
  | Ok v -> Ok v
  | Error reason -> Error (Error.Decode { method_ = t.name; reason })

let map f t = { t with decode = (fun j -> Result.map f (t.decode j)) }
