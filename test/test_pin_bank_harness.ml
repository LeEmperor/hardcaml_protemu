(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "test_pin_bank_harness.ml" *)
(* P1.6's evidence: one existing primitive through the shared harness, both ways.

   The four tests below are the four claims phase_plan.md P1.6 asks to be shown.

   1. The checker keeps unavailable, unspecified and defined apart, and a required
      observation that an adapter cannot expose fails rather than being skipped.
   2. A directed scenario reads as a cycle-by-cycle transcript, with the model checked
      against the design on every edge of it.
   3. A bounded Quickcheck run drives the same environment from a recorded seed and finds
      no disagreement between [Hardcaml_protemu.Pin_bank] and [Protemu_model.Pin_bank].
   4. A controlled mismatch, injected into this environment's reference rather than into
      [lib/] or [model/], is found, shrunk, reported, and found again in the same place
      when the recorded seed and settings are rerun.

   Test 4 passes; nothing here is left intentionally failing. What it asserts is that the
   diagnostic path behaves as specified, which is the only way to know the reproduction
   record is worth anything before a real failure needs it.

   These tests cover P2.1 only. Converting the rest of the suite is not part of P1.6.
*)

open! Core
open! Pin_bank_env

(* A small, hand-written scenario: two masked commits, an engine claim, the write it
   refuses, a release of a pin nobody holds, two requests at one edge, an open-drain
   commit, and an abort. Every line of the transcript below is one rising edge. *)
let directed_scenario =
  [ Item.reset
  ; Item.write ~engine:false ~mask:0x0f ~value:0x05 ~output_enable:0x0f ()
  ; Item.write ~engine:false ~mask:0xf0 ~value:0xa0 ~output_enable:0x50 ()
  ; Item.claim ~engine:true ~mask:0x20
  ; Item.write ~engine:false ~mask:0x30 ~value:0x30 ~output_enable:0x30 ()
  ; Item.release ~engine:false ~mask:0x01
  ; Item.also_write
      ~engine:false
      ~mask:0x01
      ~value:0x01
      ~output_enable:0x01
      (Item.claim ~engine:false ~mask:0x01)
  ; Item.write ~open_drain:true ~engine:false ~mask:0x03 ~value:0x03 ~output_enable:0x03 ()
  ; Item.abort
  ]
;;

(* The settings the regression runs. They are written down rather than drawn from the
   clock so that every machine runs the same cases; PROTEMU_SEED and PROTEMU_TRIALS
   override them for a sweep without editing this file. *)
let regression_settings = Replay.Settings.create ~seed:20260919 ~trials:200 ~size:24

(* Smaller, because the injected defect is meant to be found immediately; a fixture that
   needed two hundred trials to trip would be testing the generator, not the report. *)
let fixture_settings = Replay.Settings.create ~seed:20260919 ~trials:64 ~size:12

let%expect_test "the checker keeps unavailable, unspecified and defined apart" =
  let show ~required ~model ~dut =
    print_s
      [%sexp
        (Observation.first_difference ~required ~model ~dut
         : Observation.Difference.t option)]
  in
  (* A defined zero is an ordinary value: agreeing on it is agreement. *)
  show ~required:[ "ready" ] ~model:[ "ready", Defined 0 ] ~dut:[ "ready", Defined 0 ];
  [%expect {| () |}];
  show ~required:[ "ready" ] ~model:[ "ready", Defined 0 ] ~dut:[ "ready", Defined 1 ];
  [%expect {| (((observation ready) (reason Value) (expected (Defined 0)) (actual (Defined 1)))) |}];
  (* Where the contract says nothing, the two sides may differ. *)
  show ~required:[] ~model:[ "level", Unspecified ] ~dut:[ "level", Unspecified ];
  [%expect {| () |}];
  (* But they may not differ about whether the contract says anything. *)
  show ~required:[] ~model:[ "level", Unspecified ] ~dut:[ "level", Defined 1 ];
  [%expect
    {| (((observation level) (reason Validity) (expected Unspecified) (actual (Defined 1)))) |}];
  (* An adapter that cannot expose something not under test: skipped, and only that one. *)
  show
    ~required:[ "ready" ]
    ~model:[ "reason", Defined 3; "ready", Defined 1 ]
    ~dut:[ "reason", Unavailable; "ready", Defined 1 ];
  [%expect {| () |}];
  (* The same hole in something the test declared it needs: an error, not a skip. *)
  show ~required:[ "reason" ] ~model:[ "reason", Defined 3 ] ~dut:[ "reason", Unavailable ];
  [%expect
    {| (((observation reason) (reason Required_unavailable) (expected (Defined 3)) (actual Unavailable))) |}];
  show ~required:[ "reason" ] ~model:[ "reason", Unspecified ] ~dut:[ "reason", Defined 3 ];
  [%expect
    {| (((observation reason) (reason Required_unspecified) (expected Unspecified) (actual (Defined 3)))) |}];
  (* A side that quietly stopped publishing an observation shrinks the comparison. *)
  show ~required:[] ~model:[ "a", Defined 1; "b", Defined 2 ] ~dut:[ "a", Defined 1 ];
  [%expect
    {| (((observation b) (reason Undeclared) (expected (Defined 2)) (actual Unavailable))) |}]
;;

let%expect_test "a directed pin-bank scenario, edge by edge" =
  let (_ : Run.t) = directed Config.default ~scenario:directed_scenario in
  [%expect {| |}]
;;

let%expect_test "bounded scenarios agree with the independent model" =
  (match
     quickcheck
       ~test:"pin_bank_agreement"
       ~config:Config.default
       ~generator:Generator.scenario
       ~prerequisite:Generator.begins_with_reset
       ~settings:regression_settings
       ()
   with
   | None -> print_endline "agreed on every trial"
   | Some failure -> print_string (Failure.to_string_hum failure));
  [%expect {| agreed on every trial |}]
;;

let%expect_test "a controlled mismatch is found, shrunk, and reproduced from its seed" =
  (* The same generator, the same seed, the same settings; only the environment's
     reference is wrong. No artifact is written: this run is expected and a regression
     should not leave files behind. *)
  let run defect =
    quickcheck
      ~test:"pin_bank_open_drain_defect"
      ~config:(Config.with_defect defect)
      ~generator:Generator.scenario
      ~prerequisite:Generator.begins_with_reset
      ~write_artifact:false
      ~settings:fixture_settings
      ()
  in
  (* Without the defect these settings find nothing, so what follows is the defect. *)
  print_s [%sexp (Option.is_none (run No_defect) : bool)];
  [%expect {| true |}];
  let first = Option.value_exn (run Ignore_open_drain) in
  let again = Option.value_exn (run Ignore_open_drain) in
  print_string (Failure.to_string_hum ~redact_source:true first);
  [%expect {| |}];
  (* Rerunning the recorded seed and settings finds the same first mismatch, at the same
     edge, in the same trial. *)
  print_s
    [%message
      ""
        ~same_first_mismatch:(Outcome.equal first.outcome again.outcome : bool)
        ~same_trial:(Option.equal Int.equal first.replay.trial again.replay.trial : bool)];
  [%expect {| |}]
;;
