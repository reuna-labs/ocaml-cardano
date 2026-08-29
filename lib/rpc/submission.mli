(** Getting a transaction on chain, as a state machine that performs no I/O.

    {1 Why a state machine}

    Submitting a Cardano transaction is not one request. It may need the tip
    (to know whether the validity interval has passed), an evaluation round (to
    learn what the scripts cost), a rebuild and re-sign after that, the
    submission itself, and then repeated polling to decide it has really
    happened. Each of those can fail in a way that changes what to do next.

    Writing that as a pure {!advance} from state and event to the next action
    means the sequence can be tested exhaustively without a node, replayed from
    a log, and driven from a unikernel that has no scheduler. It also keeps the
    signing keys out of it: when a rebuild is needed the machine {e asks} for
    one and waits.

    {1 What is different from a nonce-based chain}

    - {b The id is known before submission.} It is the hash of the body, so
      there is no step where the node tells us what we sent. If the node reports
      a different id, that disagreement is fatal rather than informational.
    - {b Expiry is a slot, not a blockhash.} The validity interval is compared
      against the tip. Nothing here reads a clock: converting wall time to a
      slot needs era summaries from the node, so the tip is an input.
    - {b Evaluation is part of building, and it converges.} The execution
      budgets come back to be written into the redeemers, which changes their
      bytes, the script-data hash, the body, the id, and the fee -- so the
      transaction about to be submitted is not the one that was priced. The
      machine evaluates the rebuilt transaction again and submits only when the
      budgets come back unchanged. Because execution cost does not depend on the
      fee, that is one extra round trip and not an open loop; it is bounded
      anyway.
    - {b Confirmation is the disappearance of inputs.} A transaction is on chain
      when the outputs it spends are no longer in the UTXO set. Depth is then
      counted against the tip, and inputs that come back mean a rollback. *)

type config

val config :
  ?max_rebuilds:int ->
  ?max_confirmation_polls:int ->
  ?confirmations:int ->
  unit ->
  (config, string) result
(** [confirmations] is the block depth at which this caller treats the
    transaction as settled. There is no correct value: Cardano's security
    parameter [k] is 2160 blocks, which is the point past which a rollback
    cannot happen at all, and most callers accept far less. Whatever is chosen
    is a policy decision and belongs to the caller, so there is no default that
    pretends otherwise -- [confirmations] defaults to 1, meaning "in a block",
    which is emphatically not "final". *)

type prepared = {
  cbor : string;  (** The fully signed transaction. *)
  tx_id : Cardano_types.Hash.Tx_id.t;
  ttl : int64 option;  (** Body field 3. [None] means no upper bound. *)
  inputs : Cardano_transaction.Body.Input.t list;
  has_scripts : bool;
      (** Whether the witness set carries redeemers. Only then is an evaluation
          round needed. *)
}

type failure =
  | Rpc of Error.t
  | Rejected of Error.rpc
      (** The node refused it. The ledger's reason is in the error's [data]. *)
  | Ttl_expired of { ttl : int64; tip : int64 }
  | Rebuilds_exhausted of int
  | Confirmation_timeout of int
  | Id_disagreement of {
      expected : Cardano_types.Hash.Tx_id.t;
      reported : Cardano_types.Hash.Tx_id.t;
    }  (** The node says it accepted something other than what we sent. *)
  | Rolled_back_repeatedly of int

type outcome =
  | Accepted of { tx_id : Cardano_types.Hash.Tx_id.t; depth : int }
  | Failed of failure

val pp_failure : Format.formatter -> failure -> unit

type action =
  | Fetch_tip
  | Evaluate of string  (** Hex CBOR, for [evaluateTransaction]. *)
  | Rebuild of Ogmios.evaluation list
      (** The caller must patch these budgets into the redeemers, recompute the
          script-data hash and the fee, re-sign, and report the result. The
          machine cannot do it: it holds no keys, by design. *)
  | Submit of string
  | Check_inputs of Cardano_transaction.Body.Input.t list
  | Wait  (** Nothing to do until the chain moves. The caller decides how long
              to pause; a unikernel with no clock can simply poll again. *)
  | Finished of outcome

type event =
  | Tip of { slot : int64; height : int64 }
  | Evaluated of Ogmios.evaluation list
  | Rebuilt of prepared
  | Submitted of Cardano_types.Hash.Tx_id.t
  | Unspent_inputs of Cardano_transaction.Body.Input.t list
      (** Which of our inputs the ledger still shows as unspent. Empty means the
          transaction is in a block. *)
  | Waited
  | Rpc_error of Error.t

type t

val start : config -> prepared -> t
val action : t -> action
val advance : t -> event -> (t, string) result
(** [Error] only for an event that makes no sense in the current state -- a
    driver bug, not a chain condition. Everything the chain can do is an
    {!outcome}. *)

val tx_id : t -> Cardano_types.Hash.Tx_id.t
val rebuilds : t -> int
val polls : t -> int
val pp : Format.formatter -> t -> unit
