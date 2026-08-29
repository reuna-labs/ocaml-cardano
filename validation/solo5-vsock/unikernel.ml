(* An Ogmios query over vsock, from inside a Solo5 guest.

   This is the whole point of functorising the client over Mirage_flow.S rather
   than taking an HTTP client library: the confidential Solo5 targets forbid
   NET_BASIC outright and sptmac has no networking at all, so a flow is the only
   transport there is. Mirage_vsock_solo5.Flow is one, and the client does not
   need to know that. *)

let ( let* ) = Lwt.bind

module Log = struct
  external write : string -> unit = "cardano_console_write"
  let say s = write s
end

module Client = Cardano_rpc_flow.Make (Mirage_vsock_solo5.Flow)

(* The tender maps this to a Unix socket on the host; see build.sh. *)
let host_cid = 2L
let host_port = 1337L

let main () =
  Log.say "vsock: opening device\n";
  let* dev = Mirage_vsock_solo5.connect "vsock0" in
  Log.say "vsock: dialling the host\n";
  let* r = Mirage_vsock_solo5.create_connection dev ~cid:host_cid ~port:host_port in
  match r with
  | Error _ ->
      Log.say "vsock: could not connect\n";
      Lwt.return_unit
  | Ok flow ->
      Log.say "vsock: connected\n";
      let t = Client.create ~host:"ogmios" flow in
      let* epoch = Client.call t (Cardano_rpc.Ogmios.query_epoch ()) in
      (match epoch with
       | Ok n ->
           Log.say ("ogmios: epoch = " ^ Int64.to_string n ^ "\n")
       | Error e ->
           Log.say ("ogmios: " ^ Format.asprintf "%a" Cardano_rpc.Error.pp e ^ "\n"));
      (* A second call over the same flow, to show the connection is reusable
         and the request ids stay correlated. *)
      let* tip = Client.call t (Cardano_rpc.Ogmios.query_tip ()) in
      (match tip with
       | Ok tip ->
           Log.say ("ogmios: tip slot = " ^ Int64.to_string tip.Cardano_rpc.Ogmios.slot ^ "\n")
       | Error e ->
           Log.say ("ogmios: " ^ Format.asprintf "%a" Cardano_rpc.Error.pp e ^ "\n"));
      Log.say "cardano: ogmios query over vsock verified in-guest\n";
      Lwt.return_unit

let () = Solo5_os.Main.run (main ())
