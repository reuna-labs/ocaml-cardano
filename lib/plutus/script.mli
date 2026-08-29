(** Scripts, their hashes, and the script-data hash.

    {1 A script hash is not the hash of the script}

    It is the hash of the script {e prefixed with a language tag}. From the
    CDDL, beside [script_hash]:

    {v
    "\x00" for multisig/native scripts
    "\x01" for Plutus V1 scripts
    "\x02" for Plutus V2 scripts
    "\x03" for Plutus V3 scripts
    v}

    Hashing the bare bytes gives a plausible 28-byte value that matches nothing,
    and the same script under two languages must not share an address. *)

type language = Native | Plutus_v1 | Plutus_v2 | Plutus_v3

val language_tag : language -> char
val language_id : language -> int
(** [0], [1] and [2] for V1, V2 and V3 as they appear in a cost-model map.
    Native scripts have no id: they are not executed by the Plutus machine.
    @raise Invalid_argument on [Native]. *)

type t = { language : language; bytes : string }
(** [bytes] is the script as it appears on the wire -- the serialised Plutus
    program, or the CBOR of a native script. *)

val hash : t -> Cardano_types.Hash.Script_hash.t
(** Blake2b-224 of the language tag followed by the script. *)

(** {1 Script data hash}

    {v script_data_hash = blake2b256 (redeemers ‖ datums ‖ language_views) v}

    Every part of this is a trap, and all of them are documented in the CDDL
    rather than inferable from the grammar:

    - the {b language views} are encoded under RFC 7049 §3.9 -- keys sorted by
      {e length first}, then bytewise -- and not under the ordering used
      everywhere else;
    - for {b PlutusV1} the cost model is encoded as an indefinite-length list
      and then wrapped in a byte string, and the language id is written twice,
      once as an integer and once as a byte string, so that the key is [4100].
      The CDDL comment on this reads "(our apologies)";
    - {b V2 and V3} use a definite list and a plain integer key;
    - if there are {b no datums} the middle part is omitted entirely rather than
      being an empty map;
    - if there are {b datums but no redeemers} the whole thing is
      [A0 ‖ datums ‖ A0], which {e changed in Conway} when the default redeemer
      representation became a map. *)

type cost_models = (language * int64 list) list

val language_views : cost_models -> string
(** The encoded language-view map on its own, exposed because it is the part
    most likely to be wrong and the easiest to compare against another
    implementation. *)

val script_data_hash :
  redeemers:string option ->
  datums:string list ->
  cost_models:cost_models ->
  Cardano_types.Hash.Script_data_hash.t
(** [redeemers] is the encoded redeemers structure exactly as it sits in the
    witness set -- its bytes, not a re-encoding. [datums] are the encoded datums
    in witness-set order. *)
