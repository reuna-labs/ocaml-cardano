(* Ogmios takes and returns transactions as hex, not base64 or raw bytes. *)

let of_bytes s =
  String.concat ""
    (List.map (fun c -> Printf.sprintf "%02x" (Char.code c))
       (List.init (String.length s) (String.get s)))

let to_bytes h =
  let n = String.length h in
  if n mod 2 <> 0 then Error "odd-length hex"
  else
    try
      Ok (String.init (n / 2) (fun i ->
              Char.chr (int_of_string ("0x" ^ String.sub h (i * 2) 2))))
    with _ -> Error "not hexadecimal"
