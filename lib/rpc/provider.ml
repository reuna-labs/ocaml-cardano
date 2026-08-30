module type S = sig
  type t
  type 'a io

  val return : 'a -> 'a io
  val bind : 'a io -> ('a -> 'b io) -> 'b io

  val request :
    t ->
    method_:string ->
    params:Yojson.Safe.t option ->
    id:int ->
    (Yojson.Safe.t, Error.t) result io
end

module type TEXT = sig
  type t
  type 'a io

  val return : 'a -> 'a io
  val bind : 'a io -> ('a -> 'b io) -> 'b io
  val exchange : t -> string -> (string, string) result io
end

(* A process-wide counter. Ids only have to be unique among the requests in
   flight on one connection; making them monotonic across all of them is the
   cheapest way to guarantee that without threading state through the caller. *)
let next_id =
  let n = ref 0 in
  fun () ->
    incr n;
    !n

module Make (P : S) = struct
  let call t m =
    P.bind
      (P.request t ~method_:(Method.name m) ~params:(Method.params m)
         ~id:(next_id ()))
      (fun r -> P.return (Result.bind r (Method.decode m)))
end

module Of_text (X : TEXT) = struct
  type t = X.t
  type 'a io = 'a X.io

  let return = X.return
  let bind = X.bind

  let request t ~method_ ~params ~id =
    let m = Method.make ~name:method_ ?params (fun j -> Ok j) in
    X.bind
      (X.exchange t (Codec.request ~id m))
      (fun r ->
        X.return
          (match r with
          | Error e -> Error (Error.Transport e)
          | Ok body -> Codec.response ~id m body))
end
