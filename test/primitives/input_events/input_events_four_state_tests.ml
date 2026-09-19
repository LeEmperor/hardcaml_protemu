(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "input_events_four_state_tests.ml" *)
(* The one four-state property this suite claims, with its positive cases and two
   controlled negatives. The property, its injection site and its recovery bound are
   stated in input_events_four_state_testbench.ml. *)

open! Core
open! Input_events_four_state_testbench

let transition = Transition.create
let unknown_pad ~known ~unknown = Action.Pad_unknown { known; unknown }

(* One unknown pin, resolved; then a second unknown window that a reset clears instead.
   Event traffic runs through both, because the isolation half of the property is that
   neither window reaches it. *)
let directed_scenario =
  Scenario.create
    ~edges:13
    [ transition 0 (Reset true)
    ; transition 0 (Pad 0x00)
    ; transition 6 (Reset false)
    ; (* Pin 0 stops being driven before the edge at t=25 and is driven low again before
         the edge at t=45. Edges 2 and 3 sample an unknown pin. *)
      transition 24 (unknown_pad ~known:0x00 ~unknown:0x01)
    ; transition 44 (Pad 0x01)
    ; (* The event path runs while the pad is recovering. *)
      transition 64 (Event_set 0x01)
    ; transition 66 (Event_set 0x00)
    ; (* Pin 7 stops being driven before the edge at t=95, and a reset at t=105 clears the
         synchronizer rather than waiting for the pad. *)
      transition 94 (unknown_pad ~known:0x01 ~unknown:0x80)
    ; transition 105 (Reset true)
    ; transition 106 (Reset false)
    ; transition 106 (Pad 0x01)
    ]
;;

let%expect_test "an unknown pad sample is contained, isolated, and recovered" =
  let run = run Config.default directed_scenario in
  let outcome = Outcome.sexp_of_t run.outcome in
  [%test_result: bool] ~message:[%string "%{outcome#Sexp}"] (Run.passed run) ~expect:true;
  print_endline [%string "recovery edge: %{run.deadline#Int}"];
  List.iter run.actual ~f:(fun sample -> print_endline (Sample.to_line sample));
  [%expect
    {|
    recovery edge: 10
    edge 0 t=5 sample=6 snapshot_o=00000000 rising_o=00000000 falling_o=00000000 event_o=000000 overflow_o=000000
    edge 1 t=15 sample=16 snapshot_o=00000000 rising_o=00000000 falling_o=00000000 event_o=000000 overflow_o=000000
    edge 2 t=25 sample=26 snapshot_o=00000000 rising_o=00000000 falling_o=00000000 event_o=000000 overflow_o=000000
    edge 3 t=35 sample=36 snapshot_o=0000000X rising_o=0000000X falling_o=0000000X event_o=000000 overflow_o=000000
    edge 4 t=45 sample=46 snapshot_o=0000000X rising_o=0000000X falling_o=0000000X event_o=000000 overflow_o=000000
    edge 5 t=55 sample=56 snapshot_o=00000001 rising_o=0000000X falling_o=0000000X event_o=000000 overflow_o=000000
    edge 6 t=65 sample=66 snapshot_o=00000001 rising_o=00000000 falling_o=00000000 event_o=000001 overflow_o=000000
    edge 7 t=75 sample=76 snapshot_o=00000001 rising_o=00000000 falling_o=00000000 event_o=000001 overflow_o=000000
    edge 8 t=85 sample=86 snapshot_o=00000001 rising_o=00000000 falling_o=00000000 event_o=000001 overflow_o=000000
    edge 9 t=95 sample=96 snapshot_o=00000001 rising_o=00000000 falling_o=00000000 event_o=000001 overflow_o=000000
    edge 10 t=105 sample=106 snapshot_o=00000000 rising_o=00000000 falling_o=00000000 event_o=000000 overflow_o=000000
    edge 11 t=115 sample=116 snapshot_o=00000000 rising_o=00000000 falling_o=00000000 event_o=000000 overflow_o=000000
    edge 12 t=125 sample=126 snapshot_o=00000001 rising_o=00000001 falling_o=00000000 event_o=000000 overflow_o=000000
    |}]
;;

let%test_unit "the property is not vacuous: the directed case really does observe X" =
  let run = run Config.default directed_scenario in
  let unknown_samples =
    List.count run.actual ~f:(fun sample -> not (Sample.fully_known sample))
  in
  [%test_pred: int] (fun count -> count > 0) unknown_samples
;;

let%test_unit "an unknown pin does not make its neighbours unknown" =
  let scenario =
    Scenario.create
      ~edges:10
      [ transition 0 (Reset true)
      ; transition 0 (Pad 0x00)
      ; transition 6 (Reset false)
      ; (* Pin 3 is undriven; pins 0 and 1 keep being driven and keep toggling. *)
        transition 14 (unknown_pad ~known:0x01 ~unknown:0x08)
      ; transition 24 (unknown_pad ~known:0x02 ~unknown:0x08)
      ; transition 34 (Pad 0x03)
      ]
  in
  let run = run Config.default scenario in
  let outcome = Outcome.sexp_of_t run.outcome in
  [%test_result: bool] ~message:[%string "%{outcome#Sexp}"] (Run.passed run) ~expect:true;
  List.iter run.actual ~f:(fun sample ->
    let snapshot = Sample.find sample "snapshot_o" in
    [%test_result: int]
      ~message:[%string "edge %{sample.edge#Int}: %{Word.to_string snapshot}"]
      (Word.not_known snapshot land lnot 0x08)
      ~expect:0)
;;

let%test_unit "a synchronous reset clears an unknown synchronizer at that edge" =
  let scenario =
    Scenario.create
      ~edges:10
      [ transition 0 (Reset true)
      ; transition 0 (Pad 0x00)
      ; transition 6 (Reset false)
      ; transition 24 (unknown_pad ~known:0x00 ~unknown:0xff)
      ; transition 45 (Reset true)
      ; transition 46 (Reset false)
      ; transition 46 (Pad 0x00)
      ]
  in
  let run = run Config.default scenario in
  let outcome = Outcome.sexp_of_t run.outcome in
  [%test_result: bool] ~message:[%string "%{outcome#Sexp}"] (Run.passed run) ~expect:true;
  (* The reset edge is t=45, edge 4. Recovery is immediate there, not three edges later. *)
  [%test_result: int] run.deadline ~expect:4;
  List.iter run.actual ~f:(fun sample ->
    if sample.edge >= 4
    then
      [%test_result: bool]
        ~message:[%string "edge %{sample.edge#Int}: %{Sample.to_line sample}"]
        (Sample.fully_known sample)
        ~expect:true)
;;

let regression_settings = Replay.Settings.create ~seed:20260919 ~trials:120 ~size:16

let%expect_test "generated unknown-pad scenarios satisfy the property" =
  (match
     quickcheck
       ~here:[%here]
       ~test:"input_events_unknown_pad_recovery"
       ~config:Config.default
       ~generator:Generator.scenario
       ~settings:regression_settings
       ()
   with
   | None -> print_endline "the property held on every four-state trial"
   | Some failure -> print_string (Failure.to_string_hum failure));
  [%expect {| the property held on every four-state trial |}]
;;

let controlled_settings = Replay.Settings.create ~seed:20260919 ~trials:4 ~size:8

let controlled_failure ~test ~defect =
  quickcheck
    ~here:[%here]
    ~test
    ~config:(Config.with_defect defect)
    ~generator:Generator.controlled_scenario
    ~settings:controlled_settings
    ~environment_overrides:false
    ~write_artifact:false
    ()
  |> Option.value_exn
;;

(* Controlled negative one, on the design side: the pad is wired into the event set path,
   so an undriven pin makes the event status unknown. Isolation is what fails, and it
   fails at the edge the unknown is first captured, before any snapshot is affected. *)
let%expect_test "a pad leak into the event path fails the isolation check" =
  let test = "input_events_four_state_pad_leak" in
  let first = controlled_failure ~test ~defect:Leak_pad_into_events in
  let replayed = controlled_failure ~test ~defect:Leak_pad_into_events in
  let first_report = Failure.to_string_hum ~redact_source:true first in
  [%test_result: string]
    (Failure.to_string_hum ~redact_source:true replayed)
    ~expect:first_report;
  print_string first_report;
  [%expect
    {|
    input_events: four-state unknown-pad property failed

    reproduction:
      test:             input_events_four_state_pad_leak
      test file:        test/primitives/input_events/input_events_four_state_tests.ml
      seed:             20260919
      trials:           4
      max size:         8
      failing trial:    0
      configuration:    ((max_edges 32)(max_transitions 96)(defect Leak_pad_into_events))
      source identity:  <recorded; redacted in expect output>
      rerun:            PROTEMU_SEED=20260919 PROTEMU_TRIALS=4 PROTEMU_SIZE=8 dune runtest test/primitives/input_events --force
      time unit:        tick
      clock:            period=10, first rising=5
      coincidence:      stimulus settles before the clock transition
      injection:        X driven at pin_in_i only
      recovery bound:   3 edges after the last unknown sample
      recovery edge:    5

    first mismatch:
      time:             25 tick
      sample time:      26 tick
      edge:             2
      phase:            post_edge
      observation:      event_o
      reason:           Unexpected_unknown
      offending bits:   0x1
      expected:         000000
      actual (dut):     00000X

    failing scenario:
      edges: 9
      ((time 0)(action(Reset true)))
      ((time 6)(action(Reset false)))
      ((time 24)(action(Pad_unknown(known 0)(unknown 1))))
      ((time 34)(action(Pad 0)))

    shrunk scenario:
      edges: 5
      ((time 0)(action(Reset true)))
      ((time 6)(action(Reset false)))
      ((time 6)(action(Pad_unknown(known 0)(unknown 1))))
      ((time 16)(action(Pad 0)))

    nearby sampled context:
      edge 0 t=5 sample=6 snapshot_o=00000000 rising_o=00000000 falling_o=00000000 event_o=000000 overflow_o=000000
      edge 1 t=15 sample=16 snapshot_o=00000000 rising_o=00000000 falling_o=00000000 event_o=000000 overflow_o=000000
      edge 2 t=25 sample=26 snapshot_o=00000000 rising_o=00000000 falling_o=00000000 event_o=00000X overflow_o=00000X
      edge 3 t=35 sample=36 snapshot_o=0000000X rising_o=0000000X falling_o=0000000X event_o=00000X overflow_o=00000X
      edge 4 t=45 sample=46 snapshot_o=00000000 rising_o=0000000X falling_o=0000000X event_o=00000X overflow_o=00000X

    between-edge activity:
      t=24 pin_in_i=0000000X
      t=25 event_o=00000X
      t=25 overflow_o=00000X
      t=34 pin_in_i=00000000
      t=35 snapshot_o=0000000X
      t=35 rising_o=0000000X
      t=35 falling_o=0000000X
    |}]
;;

(* Controlled negative two, on the environment side: an observer that reads X as a level.
   This is the mistake a four-state property must not be able to pass through, so the
   check that fails here is the one requiring the contaminated bits to be unknown. *)
let%expect_test "an observer that reads X as zero fails the contamination check" =
  let test = "input_events_four_state_coerced_observer" in
  let first = controlled_failure ~test ~defect:Coerce_unknown_to_zero in
  let replayed = controlled_failure ~test ~defect:Coerce_unknown_to_zero in
  let first_report = Failure.to_string_hum ~redact_source:true first in
  [%test_result: string]
    (Failure.to_string_hum ~redact_source:true replayed)
    ~expect:first_report;
  print_string first_report;
  [%expect
    {|
    input_events: four-state unknown-pad property failed

    reproduction:
      test:             input_events_four_state_coerced_observer
      test file:        test/primitives/input_events/input_events_four_state_tests.ml
      seed:             20260919
      trials:           4
      max size:         8
      failing trial:    0
      configuration:    ((max_edges 32)(max_transitions 96)(defect Coerce_unknown_to_zero))
      source identity:  <recorded; redacted in expect output>
      rerun:            PROTEMU_SEED=20260919 PROTEMU_TRIALS=4 PROTEMU_SIZE=8 dune runtest test/primitives/input_events --force
      time unit:        tick
      clock:            period=10, first rising=5
      coincidence:      stimulus settles before the clock transition
      injection:        X driven at pin_in_i only
      recovery bound:   3 edges after the last unknown sample
      recovery edge:    5

    first mismatch:
      time:             35 tick
      sample time:      36 tick
      edge:             3
      phase:            post_edge
      observation:      snapshot_o
      reason:           Missing_unknown
      offending bits:   0x1
      expected:         0000000X
      actual (dut):     00000000

    failing scenario:
      edges: 9
      ((time 0)(action(Reset true)))
      ((time 6)(action(Reset false)))
      ((time 24)(action(Pad_unknown(known 0)(unknown 1))))
      ((time 34)(action(Pad 0)))

    shrunk scenario:
      edges: 5
      ((time 0)(action(Reset true)))
      ((time 6)(action(Reset false)))
      ((time 6)(action(Pad_unknown(known 0)(unknown 1))))
      ((time 16)(action(Pad 0)))

    nearby sampled context:
      edge 1 t=15 sample=16 snapshot_o=00000000 rising_o=00000000 falling_o=00000000 event_o=000000 overflow_o=000000
      edge 2 t=25 sample=26 snapshot_o=00000000 rising_o=00000000 falling_o=00000000 event_o=000000 overflow_o=000000
      edge 3 t=35 sample=36 snapshot_o=00000000 rising_o=00000000 falling_o=00000000 event_o=000000 overflow_o=000000
      edge 4 t=45 sample=46 snapshot_o=00000000 rising_o=00000000 falling_o=00000000 event_o=000000 overflow_o=000000
      edge 5 t=55 sample=56 snapshot_o=00000000 rising_o=00000000 falling_o=00000000 event_o=000000 overflow_o=000000

    between-edge activity:
      t=34 pin_in_i=00000000
      t=35 snapshot_o=00000000
      t=35 rising_o=00000000
      t=35 falling_o=00000000
      t=45 snapshot_o=00000000
      t=45 rising_o=00000000
      t=45 rising_o=00000000
    |}]
;;
