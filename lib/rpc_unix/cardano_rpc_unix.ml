include Cardano_rpc_flow.Make (Mirage_flow_unix.Fd)

let ( let* ) = Lwt.bind

let connect ?(host_header = "localhost") ?path sockaddr domain =
  let fd = Lwt_unix.socket domain Unix.SOCK_STREAM 0 in
  let* () = Lwt_unix.connect fd sockaddr in
  Lwt.return (create ~host:host_header ?path fd)

let connect_tcp ?host_header ?path host port =
  let* addrs =
    Lwt_unix.getaddrinfo host (string_of_int port)
      [ Unix.AI_SOCKTYPE Unix.SOCK_STREAM ]
  in
  match addrs with
  | [] -> Lwt.fail_with (Printf.sprintf "cannot resolve %s:%d" host port)
  | a :: _ ->
      let host_header = Option.value host_header ~default:host in
      connect ~host_header ?path a.Unix.ai_addr a.Unix.ai_family

let connect_unix ?host_header ?path socket_path =
  connect ?host_header ?path (Unix.ADDR_UNIX socket_path) Unix.PF_UNIX
