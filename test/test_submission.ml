(* The submission state machine, driven through every path without a node.

   That this is possible at all is the point of making it pure: a rollback, an
   expired validity interval and a node that disagrees about the transaction id
   are all conditions that are painful to arrange against a real chain and
   trivial to arrange here. *)

module S = Cardano_rpc.Submission
module E = Cardano_rpc.Error
module T = Cardano_types
module Tx = Cardano_transaction

let get = function
  | Ok v -> v
  | Error m -> Alcotest.failf "unexpected error: %s" m

let cfg ?max_rebuilds ?max_confirmation_polls ?confirmations () =
  get (S.config ?max_rebuilds ?max_confirmation_polls ?confirmations ())

let tx_id b = get (T.Hash.Tx_id.of_bytes (String.make 32 b))
let input b = get (Tx.Body.Input.make (tx_id b) 0)

let prepared ?(ttl = Some 1000L) ?(has_scripts = false) ?(id = '\001') () =
  {
    S.cbor = "\132\160";
    S.tx_id = tx_id id;
    S.ttl;
    S.inputs = [ input '\002' ];
    S.has_scripts;
  }

let step st ev = get (S.advance st ev)

let outcome st =
  match S.action st with
  | S.Finished o -> o
  | a ->
      Alcotest.failf "expected a finished machine, got %s"
        (match a with
        | S.Fetch_tip -> "Fetch_tip"
        | S.Evaluate _ -> "Evaluate"
        | S.Rebuild _ -> "Rebuild"
        | S.Submit _ -> "Submit"
        | S.Check_inputs _ -> "Check_inputs"
        | S.Wait -> "Wait"
        | S.Finished _ -> "Finished")

(* The ordinary path, with no scripts: check validity, submit, see the inputs
   spent, then count depth. *)
let happy_path () =
  let st = S.start (cfg ~confirmations:2 ()) (prepared ()) in
  Alcotest.(check bool)
    "starts by asking for the tip" true
    (S.action st = S.Fetch_tip);
  let st = step st (S.Tip { slot = 10L; height = 100L }) in
  (* No scripts, so no evaluation round. *)
  Alcotest.(check bool)
    "goes straight to submitting" true
    (match S.action st with S.Submit _ -> true | _ -> false);
  let st = step st (S.Submitted (tx_id '\001')) in
  Alcotest.(check bool)
    "then watches the inputs" true
    (match S.action st with S.Check_inputs _ -> true | _ -> false);
  (* Still unspent: keep waiting. *)
  let st = step st (S.Unspent_inputs [ input '\002' ]) in
  Alcotest.(check bool)
    "an unspent input means keep waiting" true
    (match S.action st with S.Check_inputs _ -> true | _ -> false);
  (* Gone from the UTXO set: it is in a block. *)
  let st = step st (S.Unspent_inputs []) in
  Alcotest.(check bool)
    "then counts depth against the tip" true
    (S.action st = S.Fetch_tip);
  let st = step st (S.Tip { slot = 12L; height = 100L }) in
  Alcotest.(check bool)
    "one block deep is not two" true
    (match S.action st with S.Finished _ -> false | _ -> true);
  let st = step st (S.Tip { slot = 14L; height = 101L }) in
  match outcome st with
  | S.Accepted { depth; tx_id = id } ->
      Alcotest.(check int) "settles at the requested depth" 2 depth;
      Alcotest.(check string)
        "for the transaction we sent"
        (T.Hash.Tx_id.to_hex (tx_id '\001'))
        (T.Hash.Tx_id.to_hex id)
  | S.Failed f -> Alcotest.failf "unexpected failure: %a" S.pp_failure f

(* A transaction whose validity interval has already passed cannot be fixed by
   submitting it; the machine says so instead of trying. *)
let expired_validity_interval () =
  let st = S.start (cfg ()) (prepared ~ttl:(Some 50L) ()) in
  let st = step st (S.Tip { slot = 51L; height = 100L }) in
  (match outcome st with
  | S.Failed (S.Ttl_expired { ttl; tip }) ->
      Alcotest.(check int64) "reports the interval" 50L ttl;
      Alcotest.(check int64) "and the tip that passed it" 51L tip
  | o ->
      Alcotest.failf "expected expiry, got %s"
        (match o with
        | S.Accepted _ -> "acceptance"
        | S.Failed f -> Format.asprintf "%a" S.pp_failure f));
  (* Exactly at the boundary is still valid: the interval is inclusive. *)
  let st = S.start (cfg ()) (prepared ~ttl:(Some 50L) ()) in
  let st = step st (S.Tip { slot = 50L; height = 100L }) in
  Alcotest.(check bool)
    "the last valid slot is still valid" true
    (match S.action st with S.Submit _ -> true | _ -> false);
  (* No interval at all means no expiry to check. *)
  let st = S.start (cfg ()) (prepared ~ttl:None ()) in
  let st = step st (S.Tip { slot = 999_999L; height = 100L }) in
  Alcotest.(check bool)
    "an unbounded transaction never expires" true
    (match S.action st with S.Submit _ -> true | _ -> false)

(* Scripts have to be priced, and pricing them changes the transaction -- so
   evaluation is followed by a rebuild and a fresh validity check, not by
   submission. *)
let script_evaluation_rebuilds () =
  let st = S.start (cfg ()) (prepared ~has_scripts:true ()) in
  let st = step st (S.Tip { slot = 10L; height = 100L }) in
  Alcotest.(check bool)
    "a scripted transaction is evaluated first" true
    (match S.action st with S.Evaluate _ -> true | _ -> false);
  let budgets =
    [
      {
        Cardano_rpc.Ogmios.validator = "spend:0";
        budget = { T.Protocol_params.mem = 1000L; steps = 2000L };
      };
    ]
  in
  let st = step st (S.Evaluated budgets) in
  (* The machine cannot patch the budgets itself: doing so changes the body and
     needs a signature, and it holds no keys. So it asks. *)
  (match S.action st with
  | S.Rebuild bs ->
      Alcotest.(check int)
        "and hands the budgets back to be applied" 1 (List.length bs)
  | _ -> Alcotest.fail "expected a rebuild request");
  (* The rebuild moved the id, because the redeemers moved. *)
  let rebuilt = prepared ~has_scripts:true ~id:'\007' () in
  let st = step st (S.Rebuilt rebuilt) in
  Alcotest.(check string)
    "the machine follows the new id"
    (T.Hash.Tx_id.to_hex (tx_id '\007'))
    (T.Hash.Tx_id.to_hex (S.tx_id st));
  Alcotest.(check int) "and counts the rebuild" 1 (S.rebuilds st);
  (* Re-checking validity after a rebuild, rather than assuming it still holds. *)
  Alcotest.(check bool)
    "validity is re-checked against the new transaction" true
    (S.action st = S.Fetch_tip);
  let st = step st (S.Tip { slot = 11L; height = 100L }) in
  (* Not submitted yet: the budgets were computed for the transaction as it was
     *before* they were written into it, so they are confirmed against the one
     that will actually be sent. *)
  Alcotest.(check bool)
    "and re-evaluated rather than submitted on trust" true
    (match S.action st with S.Evaluate _ -> true | _ -> false)

let budget v m s =
  {
    Cardano_rpc.Ogmios.validator = v;
    budget = { T.Protocol_params.mem = m; steps = s };
  }

(* The budgets are confirmed against the transaction that will actually be
   submitted, not against the one that was priced before they were written in.
   A node that returns the same answer twice ends the loop. *)
let evaluation_converges () =
  let st = ref (S.start (cfg ()) (prepared ~has_scripts:true ())) in
  st := step !st (S.Tip { slot = 1L; height = 1L });
  st := step !st (S.Evaluated [ budget "spend:0" 1000L 2000L ]);
  Alcotest.(check bool)
    "the first answer triggers a rebuild" true
    (match S.action !st with S.Rebuild _ -> true | _ -> false);
  st := step !st (S.Rebuilt (prepared ~has_scripts:true ~id:'\007' ()));
  st := step !st (S.Tip { slot = 1L; height = 1L });
  Alcotest.(check bool)
    "and the rebuilt transaction is evaluated again" true
    (match S.action !st with S.Evaluate _ -> true | _ -> false);
  st := step !st (S.Evaluated [ budget "spend:0" 1000L 2000L ]);
  Alcotest.(check bool)
    "the same answer twice means it is settled" true
    (match S.action !st with S.Submit _ -> true | _ -> false);
  Alcotest.(check int) "one rebuild was needed" 1 (S.rebuilds !st)

(* A node whose answer keeps moving is not converging, and the machine says so
   rather than trading round trips forever. *)
let rebuild_loop_is_bounded () =
  let st =
    ref (S.start (cfg ~max_rebuilds:2 ()) (prepared ~has_scripts:true ()))
  in
  let n = ref 0 in
  let rec spin guard =
    if guard > 12 then Alcotest.fail "the rebuild loop was not bounded"
    else
      match S.action !st with
      | S.Finished (S.Failed (S.Rebuilds_exhausted k)) ->
          Alcotest.(check int) "gives up at the configured bound" 2 k
      | S.Fetch_tip ->
          st := step !st (S.Tip { slot = 1L; height = 1L });
          spin (guard + 1)
      | S.Evaluate _ ->
          incr n;
          (* A different answer every time. *)
          st := step !st (S.Evaluated [ budget "spend:0" (Int64.of_int !n) 1L ]);
          spin (guard + 1)
      | S.Rebuild _ ->
          st := step !st (S.Rebuilt (prepared ~has_scripts:true ()));
          spin (guard + 1)
      | _ -> Alcotest.fail "unexpected action while rebuilding"
  in
  spin 0

(* The id is the hash of the body, so we know it before we send it. A node
   reporting a different one is not a warning. *)
let node_disagreeing_about_the_id () =
  let st = S.start (cfg ()) (prepared ()) in
  let st = step st (S.Tip { slot = 1L; height = 1L }) in
  let st = step st (S.Submitted (tx_id '\099')) in
  match outcome st with
  | S.Failed (S.Id_disagreement { expected; reported }) ->
      Alcotest.(check string)
        "reports what we sent"
        (T.Hash.Tx_id.to_hex (tx_id '\001'))
        (T.Hash.Tx_id.to_hex expected);
      Alcotest.(check string)
        "and what the node claimed"
        (T.Hash.Tx_id.to_hex (tx_id '\099'))
        (T.Hash.Tx_id.to_hex reported)
  | _ -> Alcotest.fail "an id disagreement was not treated as fatal"

(* Inputs that reappear after being spent mean the block was rolled back. The
   transaction is still valid and still has the same id, so it is resubmitted --
   but not forever. *)
let rollback_resubmits_then_gives_up () =
  let st = ref (S.start (cfg ~confirmations:5 ()) (prepared ())) in
  let to_awaiting_depth () =
    st := step !st (S.Tip { slot = 1L; height = 100L });
    st := step !st (S.Submitted (tx_id '\001'));
    st := step !st (S.Unspent_inputs [])
  in
  to_awaiting_depth ();
  st := step !st (S.Unspent_inputs [ input '\002' ]);
  Alcotest.(check bool)
    "a rollback resubmits" true
    (match S.action !st with S.Submit _ -> true | _ -> false);
  st := step !st (S.Submitted (tx_id '\001'));
  st := step !st (S.Unspent_inputs []);
  st := step !st (S.Unspent_inputs [ input '\002' ]);
  st := step !st (S.Submitted (tx_id '\001'));
  st := step !st (S.Unspent_inputs []);
  st := step !st (S.Unspent_inputs [ input '\002' ]);
  match outcome !st with
  | S.Failed (S.Rolled_back_repeatedly n) ->
      Alcotest.(check bool) "and eventually stops" true (n > 2)
  | o ->
      Alcotest.failf "expected a give-up, got %s"
        (match o with
        | S.Accepted _ -> "acceptance"
        | S.Failed f -> Format.asprintf "%a" S.pp_failure f)

(* A ledger rejection is final; a dropped connection is not. *)
let errors_are_classified () =
  let st = S.start (cfg ()) (prepared ()) in
  let st' =
    step st
      (S.Rpc_error
         (E.Rpc
            {
              code = 3005;
              message = "no";
              data = Some (Yojson.Safe.from_string {|"why"|});
            }))
  in
  (match outcome st' with
  | S.Failed (S.Rejected r) ->
      Alcotest.(check int) "the ledger's code survives" 3005 r.E.code;
      Alcotest.(check bool) "and its explanation" true (r.E.data <> None)
  | _ -> Alcotest.fail "a rejection was not final");
  let st'' = step st (S.Rpc_error (E.Transport "connection reset")) in
  Alcotest.(check bool)
    "a transport failure is retried, not fatal" true
    (match S.action st'' with S.Finished _ -> false | _ -> true)

let polling_is_bounded () =
  let st = ref (S.start (cfg ~max_confirmation_polls:3 ()) (prepared ())) in
  st := step !st (S.Tip { slot = 1L; height = 1L });
  st := step !st (S.Submitted (tx_id '\001'));
  let rec spin n =
    if n > 10 then Alcotest.fail "polling was not bounded"
    else
      match S.action !st with
      | S.Finished (S.Failed (S.Confirmation_timeout k)) ->
          Alcotest.(check bool)
            "gives up after the configured number" true (k >= 3)
      | _ ->
          st := step !st (S.Unspent_inputs [ input '\002' ]);
          spin (n + 1)
  in
  spin 0

let config_refuses_nonsense () =
  Alcotest.(check bool)
    "zero confirmations is not a policy" true
    (match S.config ~confirmations:0 () with Error _ -> true | Ok _ -> false);
  Alcotest.(check bool)
    "nor is zero polls" true
    (match S.config ~max_confirmation_polls:0 () with
    | Error _ -> true
    | Ok _ -> false);
  Alcotest.(check bool)
    "no rebuilds at all is a valid choice" true
    (match S.config ~max_rebuilds:0 () with Ok _ -> true | Error _ -> false)

let () =
  Alcotest.run "cardano-submission"
    [
      ( "happy path",
        [ Alcotest.test_case "submit and confirm" `Quick happy_path ] );
      ( "validity",
        [
          Alcotest.test_case "expired interval" `Quick expired_validity_interval;
        ] );
      ( "scripts",
        [
          Alcotest.test_case "evaluation triggers a rebuild" `Quick
            script_evaluation_rebuilds;
          Alcotest.test_case "evaluation converges" `Quick evaluation_converges;
          Alcotest.test_case "the rebuild loop is bounded" `Quick
            rebuild_loop_is_bounded;
        ] );
      ( "chain conditions",
        [
          Alcotest.test_case "node disagrees about the id" `Quick
            node_disagreeing_about_the_id;
          Alcotest.test_case "rollback" `Quick rollback_resubmits_then_gives_up;
          Alcotest.test_case "polling is bounded" `Quick polling_is_bounded;
        ] );
      ( "errors",
        [
          Alcotest.test_case "classification" `Quick errors_are_classified;
          Alcotest.test_case "config validation" `Quick config_refuses_nonsense;
        ] );
    ]
