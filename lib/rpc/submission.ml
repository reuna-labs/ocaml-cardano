(* The submission state machine.

   Pure: no clock, no randomness, no I/O. The tip arrives as an event because
   converting wall time to a Cardano slot needs era summaries from the node, so
   a library that read a clock here would be wrong even on Unix.

   The phases run in order, and each records what it needs from the tip rather
   than re-asking:

     Checking_ttl -> [Evaluating -> Rebuilding] -> Submitting
                  -> Awaiting_block -> Awaiting_depth -> done *)

module T = Cardano_types
module Tx = Cardano_transaction

type config = {
  max_rebuilds : int;
  max_confirmation_polls : int;
  confirmations : int;
}

let config ?(max_rebuilds = 3) ?(max_confirmation_polls = 100)
    ?(confirmations = 1) () =
  if max_rebuilds < 0 then Error "max_rebuilds is negative"
  else if max_confirmation_polls < 1 then
    Error "max_confirmation_polls is below one"
  else if confirmations < 1 then Error "confirmations is below one"
  else Ok { max_rebuilds; max_confirmation_polls; confirmations }

type prepared = {
  cbor : string;
  tx_id : T.Hash.Tx_id.t;
  ttl : int64 option;
  inputs : Tx.Body.Input.t list;
  has_scripts : bool;
}

type failure =
  | Rpc of Error.t
  | Rejected of Error.rpc
  | Ttl_expired of { ttl : int64; tip : int64 }
  | Rebuilds_exhausted of int
  | Confirmation_timeout of int
  | Id_disagreement of { expected : T.Hash.Tx_id.t; reported : T.Hash.Tx_id.t }
  | Rolled_back_repeatedly of int

type outcome =
  | Accepted of { tx_id : T.Hash.Tx_id.t; depth : int }
  | Failed of failure

let pp_failure ppf = function
  | Rpc e -> Format.fprintf ppf "%a" Error.pp e
  | Rejected { code; message; data } ->
      Format.fprintf ppf "the ledger rejected it (%d): %s%s" code message
        (match data with
        | None -> ""
        | Some d -> " -- " ^ Yojson.Safe.to_string d)
  | Ttl_expired { ttl; tip } ->
      Format.fprintf ppf
        "validity interval ended at slot %Ld and the tip is already at %Ld" ttl
        tip
  | Rebuilds_exhausted n ->
      Format.fprintf ppf
        "execution budgets still had not settled after %d rebuild(s)" n
  | Confirmation_timeout n ->
      Format.fprintf ppf "gave up waiting after %d poll(s)" n
  | Id_disagreement { expected; reported } ->
      Format.fprintf ppf "the node reports it accepted %s, but we submitted %s"
        (T.Hash.Tx_id.to_hex reported)
        (T.Hash.Tx_id.to_hex expected)
  | Rolled_back_repeatedly n ->
      Format.fprintf ppf "rolled back %d time(s); not resubmitting again" n

type action =
  | Fetch_tip
  | Evaluate of string
  | Rebuild of Ogmios.evaluation list
  | Submit of string
  | Check_inputs of Tx.Body.Input.t list
  | Wait
  | Finished of outcome

type event =
  | Tip of { slot : int64; height : int64 }
  | Evaluated of Ogmios.evaluation list
  | Rebuilt of prepared
  | Submitted of T.Hash.Tx_id.t
  | Unspent_inputs of Tx.Body.Input.t list
  | Waited
  | Rpc_error of Error.t

type phase =
  | Checking_ttl
  | Evaluating
  | Rebuilding of Ogmios.evaluation list
  | Submitting
  | Awaiting_block
  | Awaiting_depth of { accepted_at : int64 }
  | Done of outcome

type t = {
  cfg : config;
  tx : prepared;
  phase : phase;
  rebuilds : int;
  polls : int;
  rollbacks : int;
  tip_height : int64;
  last_budgets : Ogmios.evaluation list option;
}

let start cfg tx =
  {
    cfg;
    tx;
    phase = Checking_ttl;
    rebuilds = 0;
    polls = 0;
    rollbacks = 0;
    tip_height = 0L;
    last_budgets = None;
  }

let tx_id t = t.tx.tx_id
let rebuilds t = t.rebuilds
let polls t = t.polls

let action t =
  match t.phase with
  | Checking_ttl -> Fetch_tip
  | Evaluating -> Evaluate (Ogmios_hex.of_bytes t.tx.cbor)
  | Rebuilding budgets -> Rebuild budgets
  | Submitting -> Submit (Ogmios_hex.of_bytes t.tx.cbor)
  | Awaiting_block -> Check_inputs t.tx.inputs
  | Awaiting_depth _ -> Fetch_tip
  | Done o -> Finished o

let fail t f = Ok { t with phase = Done (Failed f) }

(* Budgets settle when a fresh evaluation returns what we already wrote in.
   Compared as a set keyed by validator, since the order is the node's. *)
let same_budgets previous current =
  match previous with
  | None -> false
  | Some p ->
      let key (e : Ogmios.evaluation) =
        ( e.Ogmios.validator,
          e.Ogmios.budget.T.Protocol_params.mem,
          e.Ogmios.budget.T.Protocol_params.steps )
      in
      let sort l = List.sort compare (List.map key l) in
      List.length p = List.length current && sort p = sort current

let bad what = Error (Printf.sprintf "submission: %s" what)

(* A transport failure is worth another go; anything else means the answer will
   not improve by asking again. *)
let on_rpc_error t e =
  match e with
  | Error.Rpc r -> fail t (Rejected r)
  | e when Error.is_retryable e ->
      if t.polls >= t.cfg.max_confirmation_polls then
        fail t (Confirmation_timeout t.polls)
      else Ok { t with polls = t.polls + 1 }
  | e -> fail t (Rpc e)

let advance t ev =
  match (t.phase, ev) with
  | _, Rpc_error e -> on_rpc_error t e
  (* --- is the transaction still valid? --- *)
  | Checking_ttl, Tip { slot; height } -> (
      let t = { t with tip_height = height } in
      match t.tx.ttl with
      | Some ttl when Int64.compare slot ttl > 0 ->
          fail t (Ttl_expired { ttl; tip = slot })
      | _ ->
          (* Scripts have to be priced before the transaction is final, and
             pricing them changes it -- so evaluation happens once, and what
             comes back triggers a rebuild. *)
          if t.tx.has_scripts then Ok { t with phase = Evaluating }
          else Ok { t with phase = Submitting })
  | Evaluating, Evaluated budgets ->
      (* Converge rather than assume. Writing budgets into the redeemers changes
         the bytes those budgets were computed for, so the transaction we are
         about to submit is not the one that was priced. Evaluating again and
         requiring the same answer is what closes that gap; because execution
         cost does not depend on the fee, a well-behaved node agrees on the
         second pass and the loop stops there. *)
      if same_budgets t.last_budgets budgets then
        Ok { t with phase = Submitting }
      else if t.rebuilds >= t.cfg.max_rebuilds then
        fail t (Rebuilds_exhausted t.rebuilds)
      else Ok { t with phase = Rebuilding budgets; last_budgets = Some budgets }
  | Evaluating, Rebuilt tx ->
      (* A caller that already knew the budgets may hand back a rebuilt
         transaction directly. *)
      Ok { t with tx; phase = Checking_ttl }
  | Rebuilding _, Rebuilt tx ->
      (* The rebuild changed the redeemers, so the script-data hash, the body,
         the id and the fee all moved. Re-check the validity interval against
         the new transaction rather than assuming it still holds. *)
      Ok { t with tx; rebuilds = t.rebuilds + 1; phase = Checking_ttl }
  (* --- submission --- *)
  | Submitting, Submitted reported ->
      if not (T.Hash.Tx_id.equal reported t.tx.tx_id) then
        fail t (Id_disagreement { expected = t.tx.tx_id; reported })
      else Ok { t with phase = Awaiting_block; polls = 0 }
  (* --- waiting for a block --- *)
  | Awaiting_block, Unspent_inputs [] ->
      (* Every input we spend has left the UTXO set, so the transaction is in a
         block. Depth is counted from the tip we last saw. *)
      Ok
        {
          t with
          phase = Awaiting_depth { accepted_at = t.tip_height };
          polls = 0;
        }
  | Awaiting_block, Unspent_inputs _ ->
      if t.polls + 1 >= t.cfg.max_confirmation_polls then
        fail t (Confirmation_timeout (t.polls + 1))
      else Ok { t with polls = t.polls + 1 }
  (* --- waiting for depth --- *)
  | Awaiting_depth { accepted_at }, Tip { height; _ } ->
      let depth = Int64.to_int (Int64.sub height accepted_at) + 1 in
      if depth >= t.cfg.confirmations then
        Ok
          {
            t with
            tip_height = height;
            phase = Done (Accepted { tx_id = t.tx.tx_id; depth });
          }
      else if t.polls + 1 >= t.cfg.max_confirmation_polls then
        fail t (Confirmation_timeout (t.polls + 1))
      else Ok { t with tip_height = height; polls = t.polls + 1 }
  | Awaiting_depth _, Unspent_inputs (_ :: _) ->
      (* The inputs are unspent again: the block holding this transaction was
         rolled back. It can be resubmitted -- the id has not changed -- but not
         indefinitely. *)
      if t.rollbacks + 1 > 2 then
        fail t (Rolled_back_repeatedly (t.rollbacks + 1))
      else
        Ok { t with rollbacks = t.rollbacks + 1; phase = Submitting; polls = 0 }
  | Awaiting_depth _, Unspent_inputs [] -> Ok t
  | _, Waited -> Ok { t with polls = t.polls + 1 }
  | Done _, _ -> Ok t
  | Checking_ttl, _ -> bad "expected the tip"
  | Evaluating, _ -> bad "expected an evaluation"
  | Rebuilding _, _ -> bad "expected a rebuilt transaction"
  | Submitting, _ -> bad "expected a submission result"
  | Awaiting_block, _ -> bad "expected the unspent inputs"
  | Awaiting_depth _, _ -> bad "expected the tip"

let pp ppf t =
  Format.fprintf ppf "%s %s"
    (T.Hash.Tx_id.to_hex t.tx.tx_id)
    (match t.phase with
    | Checking_ttl -> "checking validity"
    | Evaluating -> "evaluating scripts"
    | Rebuilding _ -> "awaiting rebuild"
    | Submitting -> "submitting"
    | Awaiting_block -> "awaiting a block"
    | Awaiting_depth _ -> "awaiting depth"
    | Done (Accepted { depth; _ }) ->
        Printf.sprintf "accepted at depth %d" depth
    | Done (Failed f) -> Format.asprintf "failed: %a" pp_failure f)
