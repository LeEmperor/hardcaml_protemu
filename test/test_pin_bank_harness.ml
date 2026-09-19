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
  ; Item.write
      ~open_drain:true
      ~engine:false
      ~mask:0x03
      ~value:0x03
      ~output_enable:0x03
      ()
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
  [%expect
    {|
    (((observation ready) (reason Value) (expected (Defined 0))
      (actual (Defined 1))))
    |}];
  (* Where the contract says nothing, the two sides may differ. *)
  show ~required:[] ~model:[ "level", Unspecified ] ~dut:[ "level", Unspecified ];
  [%expect {| () |}];
  (* But they may not differ about whether the contract says anything. *)
  show ~required:[] ~model:[ "level", Unspecified ] ~dut:[ "level", Defined 1 ];
  [%expect
    {|
    (((observation level) (reason Validity) (expected Unspecified)
      (actual (Defined 1))))
    |}];
  (* An adapter that cannot expose something not under test: skipped, and only that one. *)
  show
    ~required:[ "ready" ]
    ~model:[ "reason", Defined 3; "ready", Defined 1 ]
    ~dut:[ "reason", Unavailable; "ready", Defined 1 ];
  [%expect {| () |}];
  (* The same hole in something the test declared it needs: an error, not a skip. *)
  show
    ~required:[ "reason" ]
    ~model:[ "reason", Defined 3 ]
    ~dut:[ "reason", Unavailable ];
  [%expect
    {|
    (((observation reason) (reason Required_unavailable) (expected (Defined 3))
      (actual Unavailable)))
    |}];
  show
    ~required:[ "reason" ]
    ~model:[ "reason", Unspecified ]
    ~dut:[ "reason", Defined 3 ];
  [%expect
    {|
    (((observation reason) (reason Required_unspecified) (expected Unspecified)
      (actual (Defined 3))))
    |}];
  (* A side that quietly stopped publishing an observation shrinks the comparison. *)
  show ~required:[] ~model:[ "a", Defined 1; "b", Defined 2 ] ~dut:[ "a", Defined 1 ];
  [%expect
    {|
    (((observation b) (reason Undeclared) (expected (Defined 2))
      (actual Unavailable)))
    |}]
;;

let%expect_test "a directed pin-bank scenario, edge by edge" =
  let (_ : Run.t) = directed Config.default ~scenario:directed_scenario in
  [%expect
    {|
    edge 0  item ((reset)(enable true))
      before  held.pins=0 held.pin_oe=0 held.software_claim=0 held.engine_claim=0 held.rejected=0
              held.conflict=0
      after   pins=0 pin_oe=0 software_claim=0 engine_claim=0 rejected=0 conflict=0
              reject_reason=- bus0=? bus1=? bus2=? bus3=? bus4=? bus5=? bus6=? bus7=?
    edge 1  item ((enable true)(write((engine false)(mask 15)(value 5)(output_enable 15)(open_drain false))))
      before  held.pins=0 held.pin_oe=0 held.software_claim=0 held.engine_claim=0 held.rejected=0
              held.conflict=0
      after   pins=5 pin_oe=15 software_claim=0 engine_claim=0 rejected=0 conflict=0
              reject_reason=- bus0=1 bus1=0 bus2=1 bus3=0 bus4=? bus5=? bus6=? bus7=?
      item    @1 pins/Outbound/Complete ((driven 15)(high 5))
    edge 2  item ((enable true)(write((engine false)(mask 240)(value 160)(output_enable 80)(open_drain false))))
      before  held.pins=5 held.pin_oe=15 held.software_claim=0 held.engine_claim=0 held.rejected=0
              held.conflict=0
      after   pins=165 pin_oe=95 software_claim=0 engine_claim=0 rejected=0 conflict=0
              reject_reason=- bus0=1 bus1=0 bus2=1 bus3=0 bus4=0 bus5=? bus6=0 bus7=?
      item    @2 pins/Outbound/Complete ((driven 95)(high 5))
    edge 3  item ((enable true)(claim((engine true)(mask 32))))
      before  held.pins=165 held.pin_oe=95 held.software_claim=0 held.engine_claim=0
              held.rejected=0 held.conflict=0
      after   pins=165 pin_oe=95 software_claim=0 engine_claim=32 rejected=0 conflict=0
              reject_reason=- bus0=1 bus1=0 bus2=1 bus3=0 bus4=0 bus5=? bus6=0 bus7=?
      item    @3 ownership.engine/Outbound/Start (mask 32)
    edge 4  item ((enable true)(write((engine false)(mask 48)(value 48)(output_enable 48)(open_drain false))))
      before  held.pins=165 held.pin_oe=95 held.software_claim=0 held.engine_claim=32
              held.rejected=0 held.conflict=0
      after   pins=165 pin_oe=95 software_claim=0 engine_claim=32 rejected=1 conflict=1
              reject_reason=- bus0=1 bus1=0 bus2=1 bus3=0 bus4=0 bus5=? bus6=0 bus7=?
      item    @4 ownership/Outbound/Complete conflict error=a request touched a pin another owner holds
    edge 5  item ((enable true)(release((engine false)(mask 1))))
      before  held.pins=165 held.pin_oe=95 held.software_claim=0 held.engine_claim=32
              held.rejected=1 held.conflict=1
      after   pins=165 pin_oe=95 software_claim=0 engine_claim=32 rejected=1 conflict=1
              reject_reason=- bus0=1 bus1=0 bus2=1 bus3=0 bus4=0 bus5=? bus6=0 bus7=?
    edge 6  item ((enable true)(claim((engine false)(mask 1)))(write((engine false)(mask 1)(value 1)(output_enable 1)(open_drain false))))
      before  held.pins=165 held.pin_oe=95 held.software_claim=0 held.engine_claim=32
              held.rejected=1 held.conflict=1
      after   pins=165 pin_oe=95 software_claim=0 engine_claim=32 rejected=1 conflict=1
              reject_reason=- bus0=1 bus1=0 bus2=1 bus3=0 bus4=0 bus5=? bus6=0 bus7=?
    edge 7  item ((enable true)(write((engine false)(mask 3)(value 3)(output_enable 3)(open_drain true))))
      before  held.pins=165 held.pin_oe=95 held.software_claim=0 held.engine_claim=32
              held.rejected=1 held.conflict=1
      after   pins=164 pin_oe=95 software_claim=0 engine_claim=32 rejected=0 conflict=1
              reject_reason=- bus0=0 bus1=0 bus2=1 bus3=0 bus4=0 bus5=? bus6=0 bus7=?
      item    @7 pins/Outbound/Complete ((driven 95)(high 4))
    edge 8  item ((abort)(enable true))
      before  held.pins=164 held.pin_oe=95 held.software_claim=0 held.engine_claim=32
              held.rejected=0 held.conflict=1
      after   pins=0 pin_oe=0 software_claim=0 engine_claim=0 rejected=0 conflict=1
              reject_reason=- bus0=? bus1=? bus2=? bus3=? bus4=? bus5=? bus6=? bus7=?
      item    @8 ownership.engine/Outbound/End (mask 0)
      item    @8 pins/Outbound/Complete ((driven 0)(high 0))
    model and design agreed on all 9 edges
    |}]
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
        (* This test snapshots one seed's report, so it runs its recorded settings even
           during a PROTEMU_SEED sweep; an artifact path carries a process id and would
           not be reproducible either. *)
      ~environment_overrides:false
      ~settings:fixture_settings
      ()
  in
  (* Without the defect these settings find nothing, so what follows is the defect. *)
  print_s [%sexp (Option.is_none (run No_defect) : bool)];
  [%expect {| true |}];
  let first = Option.value_exn (run Ignore_open_drain) in
  let again = Option.value_exn (run Ignore_open_drain) in
  print_string (Failure.to_string_hum ~redact_source:true first);
  [%expect
    {|
    pin_bank: model/Hardcaml comparison failed

    reproduction:
      test:             pin_bank_open_drain_defect
      test file:        test/test_pin_bank_harness.ml
      seed:             20260919
      trials:           64
      max size:         12
      failing trial:    6
      configuration:    ((engine 0)(defect Ignore_open_drain))
      source identity:  <recorded; redacted in expect output>
      rerun:            PROTEMU_SEED=20260919 PROTEMU_TRIALS=64 PROTEMU_SIZE=12 dune runtest test --force

    first mismatch:
      edge:             1
      phase:            Post_edge
      item at edge:     ((enable true)(write((engine false)(mask 15)(value 50)(output_enable 48)(open_drain true))))
      observation:      pins
      reason:           Value
      expected (model): 2
      actual (dut):     0

    failing scenario (5 items):
      ((reset)(enable true))
      ((enable true)(write((engine false)(mask 15)(value 50)(output_enable 48)(open_drain true))))
      ((enable true)(write((engine true)(mask 1)(value 193)(output_enable 141)(open_drain true))))
      ((enable true)(write((engine false)(mask 0)(value 98)(output_enable 101)(open_drain false))))
      ((enable true)(release((engine true)(mask 22))))

    shrunk scenario (2 items):
      ((reset)(enable true))
      ((enable true)(write((engine true)(mask 1)(value 193)(output_enable 141)(open_drain true))))
    shrunk failure:
      edge:             1
      phase:            Post_edge
      item at edge:     ((enable true)(write((engine true)(mask 1)(value 193)(output_enable 141)(open_drain true))))
      observation:      pins
      reason:           Value
      expected (model): 1
      actual (dut):     0

    trace context:
    edge 0  item ((reset)(enable true))
      before  held.pins=0 held.pin_oe=0 held.software_claim=0 held.engine_claim=0 held.rejected=0
              held.conflict=0
      after   pins=0 pin_oe=0 software_claim=0 engine_claim=0 rejected=0 conflict=0
              reject_reason=- bus0=? bus1=? bus2=? bus3=? bus4=? bus5=? bus6=? bus7=?
    edge 1  item ((enable true)(write((engine false)(mask 15)(value 50)(output_enable 48)(open_drain true))))
      before  held.pins=0 held.pin_oe=0 held.software_claim=0 held.engine_claim=0 held.rejected=0
              held.conflict=0
      after   pins=0 pin_oe=0 software_claim=0 engine_claim=0 rejected=0 conflict=0
              reject_reason=- bus0=? bus1=? bus2=? bus3=? bus4=? bus5=? bus6=? bus7=?
    |}];
  (* Rerunning the recorded seed and settings finds the same first mismatch, at the same
     edge, in the same trial. *)
  print_s
    [%message
      ""
        ~same_first_mismatch:(Outcome.equal first.outcome again.outcome : bool)
        ~same_trial:(Option.equal Int.equal first.replay.trial again.replay.trial : bool)];
  [%expect {| ((same_first_mismatch true) (same_trial true)) |}]
;;
