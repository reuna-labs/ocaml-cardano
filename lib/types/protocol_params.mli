(** The protocol parameters fee and minimum-UTXO calculation depend on.

    Field names follow the ledger's; the CDDL key each corresponds to is noted,
    because Ogmios reports these by name and the CDDL by number, and the mapping
    is where a rename would slip through unnoticed.

    These are governance-controlled and {b do change}. Read them from the node
    for the epoch you are building in. *)

type ex_units = { mem : int64; steps : int64 }

val ex_units_zero : ex_units
val ex_units_add : ex_units -> ex_units -> (ex_units, string) result

type t = {
  min_fee_a : int64;  (** Key 0: lovelace per byte of transaction. *)
  min_fee_b : int64;  (** Key 1: the constant term. *)
  max_tx_size : int;  (** Key 3. *)
  coins_per_utxo_byte : int64;  (** Key 17. *)
  price_mem : Cardano_rational.t;  (** Key 19, first element. *)
  price_steps : Cardano_rational.t;  (** Key 19, second element. *)
  max_tx_ex_units : ex_units;  (** Key 20. *)
  collateral_percentage : int;  (** Key 23, a percentage: 150 means 1.5x. *)
  max_collateral_inputs : int;  (** Key 24. *)
  min_fee_ref_script_coins_per_byte : Cardano_rational.t;  (** Key 33. *)
  ref_script_range : int;
      (** The tier width in bytes. A ledger constant (25 600) rather than a
          protocol parameter -- but Ogmios reports it alongside the base rate,
          so it is read rather than assumed. *)
  ref_script_multiplier : Cardano_rational.t;
      (** The per-tier growth factor, 6/5. Also a ledger constant that Ogmios
          reports. *)
}

val mainnet_snapshot : t
(** Mainnet's values as of epoch 651.

    {b For tests and examples only.} Protocol parameters are changed by
    governance action, so a value compiled into a library is a value that will
    eventually be wrong -- and a wrong fee is a rejected transaction, not a
    warning. Anything building a transaction to submit should query
    [queryLedgerState/protocolParameters] instead. *)
