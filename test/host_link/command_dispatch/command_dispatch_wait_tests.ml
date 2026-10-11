(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "command_dispatch_wait_tests.ml" *)
(* HL4c: [Command_dispatch]'s READ/VERIFY and ABORT completion waits.

   The contract cases use the stub's contract timing (control_port.ml items 5 and 6): a
   READBACK response two cycles after the offer, and ABORT cleanup visible one cycle after
   it. Tests named "robustness" delay, withhold, stage, or inject completions, which the
   current [Emulator_core] does not do; they probe the dispatcher's waits, not the core.
*)

open! Core
open! Hardcaml_protemu
open! Command_dispatch_testbench

let read ~tag address = Handoff.request ~tag (Read_word { address })

let word_response ~tag command word result =
  response ~tag command ~payload:(Word word) result
;;

let%test_unit "READ publishes the word in the response cycle and offers once" =
  let t = create "READ, contract" in
  let from = t.cycle in
  let h = handoff t (read ~tag:0x21 0x0033) in
  run t 100;
  let o = h + 1 in
  let r = o + Latency.readback_after_offer in
  expect_offers
    t
    ~since:from
    "READ"
    [ { cycle = o; request = Read { address = 0x033 }; accepted = true } ];
  expect_publications
    t
    ~from
    "READ"
    [ r, word_response ~tag:0x21 Read_word (t.stub.memory 0x33) Complete ];
  expect_busy t ~from "READ" [ o; o + 1; r ]
;;

let%test_unit "VERIFY reports a match as Complete and a mismatch with the actual word" =
  let t = create "VERIFY" in
  let actual = t.stub.memory 0x10 in
  List.iter
    [ 0x51, actual, Wire.Result_code.Complete
    ; 0x52, actual lxor 0x0001, Verification_mismatch
    ; 0x53, actual lxor 0x8000, Verification_mismatch
    ]
    ~f:(fun (tag, expected, result) ->
      let from = t.cycle in
      let h =
        handoff t (Handoff.request ~tag (Verify_word { address = 0x10; expected }))
      in
      run t 10;
      expect_publications
        t
        ~from
        (sprintf "VERIFY expecting %04x" expected)
        [ h + 3, word_response ~tag Verify_word actual result ])
;;

let%test_unit "robustness: READ ignores readback_response_match" =
  (* The match output is meaningless for READ; the stub drives it high here. *)
  let t = create "robustness: READ with match high" in
  t.stub.read_match <- true;
  let from = t.cycle in
  let h = handoff t (read ~tag:0x54 0x0011) in
  run t 10;
  expect_publications
    t
    ~from
    "READ"
    [ h + 3, word_response ~tag:0x54 Read_word (t.stub.memory 0x11) Complete ]
;;

let%test_unit "robustness: a delayed READ response is waited for, without a repeated \
               offer"
  =
  let t = create "robustness: delayed READ" in
  List.iter [ 1; 5; 100; 3000 ] ~f:(fun delay ->
    t.stub.readback_completion <- Delayed delay;
    let from = t.cycle in
    let h = handoff t (read ~tag:0x60 0x00fe) in
    run t (delay + 20);
    let o = h + 1 in
    let r = o + Latency.readback_after_offer + delay in
    let what = sprintf "delay %d" delay in
    expect_offers
      t
      ~since:from
      what
      [ { cycle = o; request = Read { address = 0x0fe }; accepted = true } ];
    expect_publications
      t
      ~from
      what
      [ r, word_response ~tag:0x60 Read_word (t.stub.memory 0xfe) Complete ];
    expect_busy t ~from what (List.range o (r + 1)))
;;

let%test_unit "robustness: a READ response that never arrives keeps the wait with one \
               offer; disable ends it and a later pulse is ignored"
  =
  let t = create "robustness: READ never completes" in
  t.stub.readback_completion <- Never;
  let from = t.cycle in
  let h = handoff t (read ~tag:0x61 0x0002) in
  run t 5000;
  expect_offers
    t
    ~since:from
    "unbounded wait"
    [ { cycle = h + 1; request = Read { address = 0x002 }; accepted = true } ];
  expect_publications t ~from "unbounded wait" [];
  expect_busy t ~from "unbounded wait" (List.range (h + 1) t.cycle);
  set t ~enable:false;
  let cancelled = t.cycle in
  run t 1;
  set t ~enable:true;
  Core_stub.inject_readback_response
    t.stub
    ~cycle:(t.cycle + 3)
    ~data:0x1111
    ~matches:false;
  run t 20;
  expect_quiet t ~from:(cancelled + 1) "after disable"
;;

let%test_unit "robustness: a READBACK response pulse is consumed only in the READ wait" =
  let t = create "robustness: stray READBACK responses" in
  (* While idle. *)
  let from = t.cycle in
  Core_stub.inject_readback_response
    t.stub
    ~cycle:(t.cycle + 2)
    ~data:0x2222
    ~matches:true;
  run t 10;
  expect_quiet t ~from "idle";
  (* In the dispatch cycle, before the wait exists; the real response follows. *)
  t.stub.readback_completion <- Delayed 3;
  let from = t.cycle in
  let h = handoff t (read ~tag:0x62 0x0004) in
  Core_stub.inject_readback_response t.stub ~cycle:(h + 1) ~data:0x3333 ~matches:false;
  run t 1;
  (* The stub replaced the stray pulse with the accepted READ's response. *)
  run t 20;
  expect_publications
    t
    ~from
    "a pulse in the dispatch cycle"
    [ h + 6, word_response ~tag:0x62 Read_word (t.stub.memory 4) Complete ];
  (* During an ABORT wait. *)
  t.stub.abort_completion <- Never;
  set_status t Status.running;
  let from = t.cycle in
  let h = handoff t (Handoff.request ~tag:0x63 Abort) in
  run t 3;
  Core_stub.inject_readback_response t.stub ~cycle:t.cycle ~data:0x4444 ~matches:true;
  run t 10;
  expect_publications t ~from "a pulse during an ABORT wait" [];
  expect_busy t ~from "a pulse during an ABORT wait" (List.range (h + 1) t.cycle);
  set_status t Status.halted_idle;
  run t 1;
  expect_publications
    t
    ~from
    "a pulse during an ABORT wait"
    [ t.cycle - 1, response ~tag:0x63 Abort Complete ];
  (* One cycle after a READ completed. *)
  t.stub.readback_completion <- Contract;
  let from = t.cycle in
  let h = handoff t (read ~tag:0x64 0x0005) in
  run t 3;
  Core_stub.inject_readback_response t.stub ~cycle:t.cycle ~data:0x5555 ~matches:false;
  run t 10;
  expect_publications
    t
    ~from
    "a pulse after completion"
    [ h + 3, word_response ~tag:0x64 Read_word (t.stub.memory 5) Complete ]
;;

let%test_unit "inputs the boundary contract leaves free do not disturb a wait's \
               correlation or result"
  =
  let t = create "irrelevant inputs during waits" in
  t.stub.readback_completion <- Delayed 20;
  let verify = Handoff.request ~tag:0x65 (Verify_word { address = 0x20; expected = 0 }) in
  let from = t.cycle in
  let h = handoff t verify in
  (* [result_i] and [echo_valid_i] are meaningful only with [frame_end_i]; status is not
     read by a READ wait.
  *)
  set t ~handoff:{ verify with result = 0x13; echo_valid = false };
  set_status t Status.running;
  run t 10;
  set t ~handoff:{ verify with result = 0x15 };
  set_status t { Status.halted_idle with pc = 0x55 };
  run t 30;
  expect_publications
    t
    ~from
    "VERIFY"
    [ ( h + 23
      , word_response ~tag:0x65 Verify_word (t.stub.memory 0x20) Verification_mismatch )
    ];
  (* The same during an ABORT wait: result and echo change, status stages toward clean. *)
  t.stub.abort_completion <- Never;
  set_status t Status.running;
  let abort = Handoff.request ~tag:0x66 Abort in
  let from = t.cycle in
  let h = handoff t abort in
  set t ~handoff:{ abort with result = 0x10; echo_valid = false };
  run t 10;
  set_status t (Status.cleaned Status.running);
  run t 5;
  expect_publications t ~from "ABORT" [ h + 11, response ~tag:0x66 Abort Complete ]
;;

let%test_unit "ABORT completes at the first wait cycle whose status shows cleanup" =
  let t = create "ABORT, contract" in
  (* From execution: cleanup is visible one cycle after the accepting edge. *)
  set_status t Status.running;
  let from = t.cycle in
  let h = handoff t (Handoff.request ~tag:0x70 Abort) in
  run t 20;
  let o = h + 1 in
  expect_offers t ~since:from "ABORT" [ { cycle = o; request = Abort; accepted = true } ];
  expect_publications
    t
    ~from
    "ABORT"
    [ o + Latency.abort_clean_after_offer, response ~tag:0x70 Abort Complete ];
  expect_busy t ~from "ABORT" [ o; o + 1 ];
  (* Already clean at the offer: the wait still starts at the offer's edge, so the
     response is in the first wait cycle, not the offer cycle.
  *)
  set_status t Status.halted_idle;
  let from = t.cycle in
  let h = handoff t (Handoff.request ~tag:0x71 Abort) in
  run t 20;
  expect_publications
    t
    ~from
    "ABORT when clean"
    [ h + 2, response ~tag:0x71 Abort Complete ];
  expect_busy t ~from "ABORT when clean" [ h + 1; h + 2 ]
;;

let%test_unit "each missing cleanup condition prevents ABORT completion" =
  let t = create "robustness: ABORT cleanup conditions" in
  t.stub.abort_completion <- Never;
  let clean = Status.cleaned Status.running in
  (* Only these five fields gate completion; others, such as a fault or a load in
     progress, do not.
  *)
  let missing : (string * Status.t) list =
    [ "not halted", { clean with halted = 0 }
    ; "engines active", { clean with engines_idle = 0 }
    ; "an output enable", { clean with pin_oe = 0x01 }
    ; "a software claim", { clean with software_claim = 0x80 }
    ; "an engine claim", { clean with engine_claim = 0x10 }
    ]
  in
  List.iteri missing ~f:(fun index (what, status) ->
    set_status t Status.running;
    let tag = 0x80 + index in
    let from = t.cycle in
    let h = handoff t (Handoff.request ~tag Abort) in
    set_status t status;
    run t 50;
    expect_publications t ~from what [];
    expect_busy t ~from what (List.range (h + 1) t.cycle);
    let unrelated =
      { clean with
        execution_fault = 1
      ; fault_kind = 3
      ; phase = 6
      ; load_active = 1
      ; image_valid = 1
      ; pc = 0x1_0000
      }
    in
    set_status t unrelated;
    let completed = t.cycle in
    run t 5;
    expect_publications
      t
      ~from
      (what ^ ", then clean")
      [ completed, response ~tag Abort Complete ];
    expect_busy t ~from (what ^ ", then clean") (List.range (h + 1) (completed + 1)))
;;

let%test_unit "robustness: staged and delayed ABORT cleanup completes in the cycle the \
               last condition is visible"
  =
  let t = create "robustness: staged ABORT cleanup" in
  t.stub.abort_completion <- Never;
  let running = { Status.running with software_claim = 0x04 } in
  set_status t running;
  let from = t.cycle in
  let h = handoff t (Handoff.request ~tag:0x90 Abort) in
  let stages =
    [ { running with halted = 1 }
    ; { running with halted = 1; engines_idle = 1 }
    ; { running with halted = 1; engines_idle = 1; pin_oe = 0 }
    ; { running with halted = 1; engines_idle = 1; pin_oe = 0; engine_claim = 0 }
    ]
  in
  List.iter stages ~f:(fun status ->
    run t 7;
    set_status t status);
  run t 7;
  expect_publications t ~from "staged, one condition left" [];
  set_status t (Status.cleaned running);
  let completed = t.cycle in
  run t 5;
  expect_publications t ~from "staged" [ completed, response ~tag:0x90 Abort Complete ];
  expect_busy t ~from "staged" (List.range (h + 1) (completed + 1));
  List.iter [ 1; 7 ] ~f:(fun delay ->
    t.stub.abort_completion <- Delayed delay;
    set_status t Status.running;
    let from = t.cycle in
    let h = handoff t (Handoff.request ~tag:0x91 Abort) in
    run t (delay + 10);
    expect_publications
      t
      ~from
      (sprintf "delay %d" delay)
      [ h + 2 + delay, response ~tag:0x91 Abort Complete ])
;;

let%test_unit "reset and disable cancel an ABORT wait; later cleanup publishes nothing" =
  let t = create "ABORT wait cancellation" in
  t.stub.abort_completion <- Never;
  List.iter [ `Reset; `Disable ] ~f:(fun cancel ->
    set_status t Status.running;
    let from = t.cycle in
    let h = handoff t (Handoff.request ~tag:0xa0 Abort) in
    run t 10;
    (match cancel with
     | `Reset -> set t ~reset:true
     | `Disable -> set t ~enable:false);
    let cancelled = t.cycle in
    run t 1;
    set t ~reset:false ~enable:true;
    set_status t Status.halted_idle;
    run t 20;
    let what =
      match cancel with
      | `Reset -> "reset"
      | `Disable -> "disable"
    in
    expect_publications t ~from what [];
    expect_busy t ~from what (List.range (h + 1) (cancelled + 1)))
;;
