(** Fees, minimum UTXO values, and collateral.

    The constants and the rounding here are cited in [docs/conway-spec-pin.md]
    against the ledger source. They are not derivable from the CDDL, which gives
    the parameter names and types but not the formulas, and every one of them is
    a plausible-but-wrong guess away from a rejected transaction. *)

(** {1 Minimum UTXO} *)

val min_utxo :
  Cardano_types.Protocol_params.t -> Body.Output.t -> (Cardano_types.Coin.t, string) result
(** [(160 + |CBOR(output)|) * coinsPerUTxOByte].

    The 160 is the ledger's approximation of the memory an entry costs beyond
    its own bytes -- the [TxIn] and the map entry holding it -- and is a
    constant in the implementation, not a parameter.

    Note the circularity this creates: the size depends on the value, and the
    minimum value depends on the size. A builder that sets an output's ada to
    exactly this may push it over a length boundary and need to ask again. *)

val meets_min_utxo :
  Cardano_types.Protocol_params.t -> Body.Output.t -> (bool, string) result

val settled_min_utxo :
  Cardano_types.Protocol_params.t -> Body.Output.t -> (Cardano_types.Coin.t, string) result
(** The least ada this output can hold and still satisfy {!min_utxo} {e once it
    is holding it}.

    {!min_utxo} alone is not that number. Raising an output's ada makes the
    output longer -- one lovelace encodes in a byte, a million takes five -- and
    a longer output has a higher minimum. Setting the value to [min_utxo] can
    therefore leave it just under the line.

    This iterates until the value stops moving, which takes two or three rounds
    because the length of a CBOR integer grows in steps. It errors rather than
    looping if it has not settled quickly, since a fixpoint that does not
    converge is a bug and not something to paper over with a bigger bound. *)

(** {1 Fees} *)

val tier_ref_script_fee :
  Cardano_types.Protocol_params.t -> int -> (Cardano_types.Coin.t, string) result
(** Conway's reference-script charge: the price per byte is constant within a
    25 600-byte tier and multiplied by 6/5 at each tier boundary.

    {b It rounds down.} The rest of the fee calculation rounds up, and copying
    that here overpays; the mirror-image mistake underpays, and an underpaid
    transaction is rejected rather than merely generous. The multiplier and the
    stride are ledger constants; only the base rate is a protocol parameter. *)

val script_fee :
  Cardano_types.Protocol_params.t ->
  Cardano_types.Protocol_params.ex_units ->
  (Cardano_types.Coin.t, string) result
(** [ceil(priceMem * mem + priceSteps * steps)]. Rounds up, unlike the
    reference-script charge. *)

val min_fee :
  Cardano_types.Protocol_params.t ->
  tx_size:int ->
  ?ex_units:Cardano_types.Protocol_params.ex_units ->
  ?ref_scripts_size:int ->
  unit ->
  (Cardano_types.Coin.t, string) result
(** [minFeeA * tx_size + minFeeB], plus the execution and reference-script
    charges.

    [tx_size] is the size of the {b fully serialized transaction, witnesses
    included} -- which is why a fee cannot be computed before the number of
    signatures is known, and why a builder has to iterate. *)

(** {1 Collateral} *)

val required_collateral :
  Cardano_types.Protocol_params.t -> Cardano_types.Coin.t -> (Cardano_types.Coin.t, string) result
(** [ceil(fee * collateralPercentage / 100)]. What must be put at risk to run a
    script, and what is forfeit if phase-2 validation fails. *)
