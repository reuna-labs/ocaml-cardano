(* Bech32 (BIP173), the base-32 checksummed encoding Cardano uses for CIP-19
   addresses and CIP-5 identifiers.

   A deliberate fork of ocaml-web3-codec/lib/bech32.ml at 13be69c, not a shared
   dependency. That module lives only in the fat web3-codec package, whose
   closure pulls evm-abi and a private digestif fork; taking the dependency to
   reach 190 lines of stdlib would drag both into a Cardano unikernel. The same
   reasoning ocaml-bitcoin records in its CONTRIBUTING.md for this very file.

   Two differences from upstream, both Cardano's doing:

   - max_length is a parameter. BIP173 caps an address at 90 characters, and a
     Cardano base address is about 103. CIP-19 drops the cap deliberately; the
     BCH code still detects up to 4 errors, it just stops being a guarantee.
   - encode_bytes/decode_bytes wrap the 8-to-5 bit regrouping, which is what
     every caller here actually wants.

   The SegWit half of upstream is not ported; Cardano has no witness version.

   When web3-codec is sliced into lean packages this file goes away and the
   ?max_length parameter goes upstream with it. *)
type encoding = Bech32 | Bech32m

let charset = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"

let inverse =
  let t = Array.make 256 (-1) in
  String.iteri (fun i c -> t.(Char.code c) <- i) charset;
  t

(* BIP173's 90-character cap is the default, not a constant: the BCH code's
   guarantee of detecting up to 4 character errors only holds within that
   length, so going past it downgrades the checksum from "detects typos" to
   "detects some typos". CIP-19 accepts that trade because a Cardano base
   address carries two 28-byte credentials and cannot fit in 90 characters. *)
let default_max_length = 90

(* Long enough for every CIP-19 form: a base address is 1 + 28 + 28 = 57 bytes,
   which is 92 data characters plus the checksum and the human-readable part. *)
let cardano_max_length = 256

(* BIP173: 1..83 characters, each in the printable ASCII range 33..126. *)
let max_hrp_length = 83
let valid_hrp hrp =
  let n = String.length hrp in
  n >= 1 && n <= max_hrp_length
  && String.for_all (fun c -> Char.code c >= 33 && Char.code c <= 126) hrp

let const = function Bech32 -> 1 | Bech32m -> 0x2bc830a3

let polymod values =
  let gen = [| 0x3b6a57b2; 0x26508e6d; 0x1ea119fa; 0x3d4233dd; 0x2a1462b3 |] in
  let chk = ref 1 in
  List.iter
    (fun v ->
      let top = !chk lsr 25 in
      chk := ((!chk land 0x1ffffff) lsl 5) lxor v;
      for i = 0 to 4 do
        if (top lsr i) land 1 <> 0 then chk := !chk lxor gen.(i)
      done)
    values;
  !chk

let hrp_expand hrp =
  let n = String.length hrp in
  List.init n (fun i -> Char.code hrp.[i] lsr 5)
  @ [ 0 ]
  @ List.init n (fun i -> Char.code hrp.[i] land 31)

let create_checksum enc hrp data =
  let values = hrp_expand hrp @ data @ [ 0; 0; 0; 0; 0; 0 ] in
  let m = polymod values lxor const enc in
  List.init 6 (fun i -> (m lsr (5 * (5 - i))) land 31)

let verify_checksum hrp data =
  match polymod (hrp_expand hrp @ data) with
  | 1 -> Some Bech32
  | 0x2bc830a3 -> Some Bech32m
  | _ -> None

(* [convertbits data from to pad] regroups a list of [from]-bit values
   into [to]-bit values (MSB first).

   [acc] is masked to [from + into] bits each step. Only the low
   [bits + into] bits are ever read back and [bits < into] holds at the top
   of the loop, so this preserves everything the extraction needs while
   keeping [acc] from running off the end of an OCaml int on long input. *)
let convertbits ?(pad = true) data ~from ~into =
  let acc = ref 0 and bits = ref 0 and out = ref [] in
  let maxv = (1 lsl into) - 1 in
  let accmask = (1 lsl (from + into)) - 1 in
  let ok = ref true in
  List.iter
    (fun v ->
      if v < 0 || v lsr from <> 0 then ok := false;
      acc := ((!acc lsl from) lor v) land accmask;
      bits := !bits + from;
      while !bits >= into do
        bits := !bits - into;
        out := ((!acc lsr !bits) land maxv) :: !out
      done)
    data;
  if pad then begin
    if !bits > 0 then out := ((!acc lsl (into - !bits)) land maxv) :: !out
  end
  else if !bits >= from || (!acc lsl (into - !bits)) land maxv <> 0 then ok := false;
  if !ok then Some (List.rev !out) else None

(* [encode enc ~hrp ~data]: [data] are 5-bit groups (0..31). *)
let encode ?(max_length = default_max_length) enc ~hrp ~data =
  if not (valid_hrp hrp) then
    invalid_arg "Bech32.encode: human-readable part must be 1..83 chars in ASCII 33..126";
  if not (List.for_all (fun d -> d >= 0 && d <= 31) data) then
    invalid_arg "Bech32.encode: data groups must be 5-bit values (0..31)";
  if String.length hrp + 1 + List.length data + 6 > max_length then
    invalid_arg "Bech32.encode: result exceeds the permitted length";
  let combined = data @ create_checksum enc hrp data in
  hrp ^ "1" ^ String.concat "" (List.map (fun d -> String.make 1 charset.[d]) combined)

let decode ?(max_length = default_max_length) s =
  let n = String.length s in
  if n > max_length then Error "bech32: longer than the permitted length"
  else begin
    let has_lower = ref false and has_upper = ref false in
    String.iter
      (fun c ->
        if c >= 'a' && c <= 'z' then has_lower := true;
        if c >= 'A' && c <= 'Z' then has_upper := true)
      s;
    if !has_lower && !has_upper then Error "bech32: mixed case"
    else begin
      let s = String.lowercase_ascii s in
      match String.rindex_opt s '1' with
      | None -> Error "bech32: missing separator"
      | Some sep ->
        if sep < 1 || sep + 7 > n then Error "bech32: misplaced separator"
        else begin
          let hrp = String.sub s 0 sep in
          if not (valid_hrp hrp) then Error "bech32: invalid human-readable part"
          else begin
            let data_part = String.sub s (sep + 1) (n - sep - 1) in
            let exception Bad in
            match
              List.init (String.length data_part) (fun i ->
                  let d = inverse.(Char.code data_part.[i]) in
                  if d < 0 then raise Bad;
                  d)
            with
            | values -> (
              match verify_checksum hrp values with
              | None -> Error "bech32: bad checksum"
              | Some enc ->
                let keep = List.length values - 6 in
                let data = List.filteri (fun i _ -> i < keep) values in
                Ok (enc, hrp, data))
            | exception Bad -> Error "bech32: invalid character"
          end
        end
    end
  end


(* ---- byte-oriented wrappers ----

   Callers hold bytes, not 5-bit groups. Padding is required on the way in and
   must be zero on the way out; a decoder that ignored those bits would give one
   payload several spellings, and an address with several spellings is an
   address a checker and a signer can disagree about. *)

let encode_bytes ?(max_length = cardano_max_length) enc ~hrp payload =
  match
    convertbits
      (List.init (String.length payload) (fun i -> Char.code payload.[i]))
      ~from:8 ~into:5
  with
  | None -> Error "bech32: bit conversion failed"
  | Some data -> (
      match encode ~max_length enc ~hrp ~data with
      | s -> Ok s
      | exception Invalid_argument m -> Error m)

let decode_bytes ?(max_length = cardano_max_length) s =
  match decode ~max_length s with
  | Error _ as e -> e
  | Ok (enc, hrp, data) -> (
      match convertbits ~pad:false data ~from:5 ~into:8 with
      | None -> Error "bech32: non-zero padding bits"
      | Some bytes ->
          Ok
            ( enc,
              hrp,
              String.init (List.length bytes) (fun i -> Char.chr (List.nth bytes i))
            ))
