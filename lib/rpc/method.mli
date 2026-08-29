(** A typed remote method: its name, its parameters, and how to read its reply.

    Bundling the decoder with the name is what stops a caller from asking one
    question and parsing the answer as though it were another. *)

type 'a t

val make :
  name:string ->
  ?params:Yojson.Safe.t ->
  (Yojson.Safe.t -> ('a, string) result) ->
  'a t

val name : 'a t -> string
val params : 'a t -> Yojson.Safe.t option
val decode : 'a t -> Yojson.Safe.t -> ('a, Error.t) result
val map : ('a -> 'b) -> 'a t -> 'b t
