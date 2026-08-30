(** The Ogmios methods this library uses.

    Names are as they appear in [CardanoSolutions/ogmios]
    [docs/content/mini-protocols/] at v7.0.0; the pinned version is recorded in
    [docs/conway-spec-pin.md]. They are values here rather than strings at call
    sites so that a rename is one edit and a typo is a compile error. *)

type tip = { slot : int64; id : string; height : int64 }

type utxo_entry = {
  input : Cardano_transaction.Body.Input.t;
  output : Cardano_transaction.Body.Output.t;
}

type evaluation = {
  validator : string;  (** Purpose and index, e.g. ["spend:0"]. *)
  budget : Cardano_types.Protocol_params.ex_units;
}

(** {1 Network} *)

val query_network_tip : unit -> tip Method.t
val query_network_start_time : unit -> string Method.t

val query_genesis_configuration : string -> Yojson.Safe.t Method.t
(** The era, as Ogmios names it: ["byron"], ["shelley"], ["alonzo"] or
    ["conway"]. Each era has its own genesis file and they are not
    interchangeable. *)

(** {1 Ledger state} *)

val query_tip : unit -> tip Method.t
val query_epoch : unit -> int64 Method.t
val query_protocol_parameters : unit -> Cardano_types.Protocol_params.t Method.t

val query_utxo_by_address : string list -> utxo_entry list Method.t
(** By bech32 address. An empty result means the addresses hold nothing, not
    that the query failed. *)

val query_utxo_by_input :
  Cardano_transaction.Body.Input.t list -> utxo_entry list Method.t
(** By outpoint. An input missing from the result has been spent, which is how
    confirmation is detected. *)

(** {1 Transactions} *)

val evaluate_transaction : string -> evaluation list Method.t
(** Takes the CBOR-encoded transaction, returns the execution budget each
    redeemer needs.

    This is not a preflight check. The budgets come back to be written {e into}
    the redeemers, which changes their bytes, which changes the script-data
    hash, the body, and the fee -- so it is a step in building, and it has to be
    followed by a rebuild. *)

val submit_transaction : string -> Cardano_types.Hash.Tx_id.t Method.t
(** Takes the CBOR-encoded transaction. The returned id is checked against the
    one computed locally: a node reporting a different id means one of us is
    wrong about what was submitted, which is not something to continue past. *)
