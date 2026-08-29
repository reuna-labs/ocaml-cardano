module Http = Http

(* Only the four operations this client actually performs. Asking for a whole
   Mirage_flow.S would also demand close and shutdown, which this code never
   calls and must not: on a unikernel the flow belongs to a device the caller
   configured, and closing it is the caller's decision. *)
module type FLOW = sig
  type flow
  type error
  type write_error

  val pp_error : error Fmt.t
  val pp_write_error : write_error Fmt.t
  val read : flow -> (Cstruct.t Mirage_flow.or_eof, error) result Lwt.t
  val write : flow -> Cstruct.t -> (unit, write_error) result Lwt.t
end

module Make (F : FLOW) = struct
  type t = {
    flow : F.flow;
    host : string;
    path : string;
    limits : Http.limits;
  }

  let create ?(host = "localhost") ?(path = "/") ?(limits = Http.default_limits) flow =
    { flow; host; path; limits }

  let flow t = t.flow

  let ( let* ) = Lwt.bind

  (* Read until the parser says the response is complete. A flow hands over
     whatever arrived, so the parser has to tolerate a split anywhere -- which
     is why it is a state machine rather than a function over a whole buffer. *)
  let exchange t body =
    let* w = F.write t.flow (Cstruct.of_string (Http.request ~host:t.host ~path:t.path ~body)) in
    match w with
    | Error e -> Lwt.return (Error (Fmt.str "write: %a" F.pp_write_error e))
    | Ok () ->
        let rec loop st =
          let* r = F.read t.flow in
          match r with
          | Error e -> Lwt.return (Error (Fmt.str "read: %a" F.pp_error e))
          | Ok `Eof -> (
              (* End of stream is meaningful to the parser: a close-delimited
                 body ends here, anything else is a truncated response. *)
              match Http.feed st "" with
              | Http.Done body -> Lwt.return (Ok body)
              | Http.Failed m -> Lwt.return (Error m)
              | Http.Need_more _ -> Lwt.return (Error "connection closed mid-response"))
          | Ok (`Data cs) -> (
              match Http.feed st (Cstruct.to_string cs) with
              | Http.Done body -> Lwt.return (Ok body)
              | Http.Failed m -> Lwt.return (Error m)
              | Http.Need_more st -> loop st)
        in
        loop (Http.start ~limits:t.limits ())

  module Text = struct
    type nonrec t = t
    type 'a io = 'a Lwt.t

    let return = Lwt.return
    let bind = Lwt.bind
    let exchange = exchange
  end

  module Provider = Cardano_rpc.Provider.Of_text (Text)
  module Client = Cardano_rpc.Provider.Make (Provider)

  let call = Client.call
end
