(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "input_events_timing_tests.ml" *)

open! Core
open! Input_events_timing_testbench

let transition = Transition.create

let directed_scenario =
  Scenario.create
    ~edges:12
    [ transition 0 (Reset true)
    ; transition 6 (Reset false)
    ; (* A two-tick pulse straddles the edge at t=15 and is captured. *)
      transition 14 (Pad 1)
    ; transition 16 (Pad 0)
    ; (* This eight-tick pulse lies wholly between edges and is missed. *)
      transition 36 (Pad 1)
    ; transition 44 (Pad 0)
    ; (* Controls at t=45 are ordered before that edge: set wins acknowledge. *)
      transition 45 (Event_set 1)
    ; transition 45 (Event_ack 1)
    ; transition 46 (Event_ack 0)
    ; transition 55 (Event_set 1)
    ; transition 56 (Event_set 0)
    ; transition 65 (Event_set 1)
    ; transition 65 (Event_ack 1)
    ; transition 66 (Event_set 0)
    ; transition 75 (Event_ack 1)
    ; transition 76 (Event_ack 0)
    ; (* Reset at the exact edge clears all state despite a high pad. *)
      transition 84 (Pad 1)
    ; transition 85 (Reset true)
    ; transition 86 (Reset false)
    ; transition 106 (Pad 0)
    ]
;;

let%expect_test "timestamped phase, pulse, reset, and event interactions" =
  let run = run Config.default directed_scenario in
  let outcome = Outcome.sexp_of_t run.outcome in
  [%test_result: bool] ~message:[%string "%{outcome#Sexp}"] (Run.passed run) ~expect:true;
  List.iter run.actual ~f:(fun sample -> print_endline (Sample.to_line sample));
  print_endline "activity at and between clock edges:";
  List.iter run.activity ~f:(fun activity ->
    if String.equal activity.signal "pin_in_i"
       || String.equal activity.signal "rising_o"
       || String.equal activity.signal "falling_o"
       || String.equal activity.signal "event_o"
       || String.equal activity.signal "overflow_o"
    then print_endline (Activity.to_line activity));
  [%expect
    {|
    edge 0 t=5 sample=6 pins=0 rise=0 fall=0 event=0 overflow=0
    edge 1 t=15 sample=16 pins=0 rise=0 fall=0 event=0 overflow=0
    edge 2 t=25 sample=26 pins=1 rise=1 fall=0 event=0 overflow=0
    edge 3 t=35 sample=36 pins=0 rise=0 fall=1 event=0 overflow=0
    edge 4 t=45 sample=46 pins=0 rise=0 fall=0 event=1 overflow=0
    edge 5 t=55 sample=56 pins=0 rise=0 fall=0 event=1 overflow=1
    edge 6 t=65 sample=66 pins=0 rise=0 fall=0 event=1 overflow=0
    edge 7 t=75 sample=76 pins=0 rise=0 fall=0 event=0 overflow=0
    edge 8 t=85 sample=86 pins=0 rise=0 fall=0 event=0 overflow=0
    edge 9 t=95 sample=96 pins=0 rise=0 fall=0 event=0 overflow=0
    edge 10 t=105 sample=106 pins=1 rise=1 fall=0 event=0 overflow=0
    edge 11 t=115 sample=116 pins=1 rise=0 fall=0 event=0 overflow=0
    activity at and between clock edges:
    t=14 pin_in_i=1
    t=16 pin_in_i=0
    t=25 rising_o=1
    t=35 rising_o=0
    t=35 falling_o=1
    t=36 pin_in_i=1
    t=44 pin_in_i=0
    t=45 event_o=1
    t=45 falling_o=0
    t=55 overflow_o=1
    t=65 overflow_o=0
    t=75 event_o=0
    t=84 pin_in_i=1
    t=105 rising_o=1
    t=106 pin_in_i=0
    t=115 rising_o=0
    |}]
;;

let first_rising_time run =
  List.find_map run.Run.actual ~f:(fun sample ->
    if sample.rising land 1 <> 0 then Some sample.time else None)
;;

let%test_unit "the deterministic digital phase sweep has a 10-to-19 tick capture latency" =
  let latencies =
    List.init period ~f:(fun phase ->
      let transition_time = 6 + phase in
      let scenario =
        Scenario.create
          ~edges:7
          [ transition 0 (Reset true)
          ; transition 6 (Reset false)
          ; transition transition_time (Pad 1)
          ; transition 46 (Pad 0)
          ]
      in
      let result = run Config.default scenario in
      let outcome = Outcome.sexp_of_t result.outcome in
      [%test_result: bool]
        ~message:[%string "phase %{phase#Int}: %{outcome#Sexp}"]
        (Run.passed result)
        ~expect:true;
      Option.value_exn (first_rising_time result) - transition_time)
  in
  [%test_result: int]
    (List.min_elt latencies ~compare:Int.compare |> Option.value_exn)
    ~expect:10;
  [%test_result: int]
    (List.max_elt latencies ~compare:Int.compare |> Option.value_exn)
    ~expect:19
;;

let%test_unit "a short pulse crossing a sampling edge is captured and one between edges \
               is missed"
  =
  let captured =
    run
      Config.default
      (Scenario.create
         ~edges:5
         [ transition 0 (Reset true)
         ; transition 6 (Reset false)
         ; transition 14 (Pad 1)
         ; transition 16 (Pad 0)
         ])
  in
  let missed =
    run
      Config.default
      (Scenario.create
         ~edges:5
         [ transition 0 (Reset true)
         ; transition 6 (Reset false)
         ; transition 6 (Pad 1)
         ; transition 14 (Pad 0)
         ])
  in
  [%test_result: bool]
    (List.exists captured.actual ~f:(fun sample -> sample.rising = 1))
    ~expect:true;
  [%test_result: bool]
    (List.for_all missed.actual ~f:(fun sample -> sample.rising = 0))
    ~expect:true
;;

let regression_settings = Replay.Settings.create ~seed:20260919 ~trials:160 ~size:18

let%expect_test "generated timestamped scenarios agree with the independent sampler" =
  (match
     quickcheck
       ~here:[%here]
       ~test:"input_events_timed_agreement"
       ~config:Config.default
       ~generator:Generator.scenario
       ~settings:regression_settings
       ()
   with
   | None -> print_endline "agreed on every timed trial"
   | Some failure -> print_string (Failure.to_string_hum failure));
  [%expect {| agreed on every timed trial |}]
;;

let controlled_settings = Replay.Settings.create ~seed:20260919 ~trials:4 ~size:8

let controlled_failure () =
  quickcheck
    ~here:[%here]
    ~test:"input_events_controlled_timed_mismatch"
    ~config:(Config.with_defect Delay_pad_transitions_one_tick)
    ~generator:Generator.controlled_scenario
    ~settings:controlled_settings
    ~environment_overrides:false
    ~write_artifact:false
    ()
  |> Option.value_exn
;;

let%expect_test "a controlled timed mismatch shrinks and replays from its seed" =
  let first = controlled_failure () in
  let replayed = controlled_failure () in
  let first_report = Failure.to_string_hum ~redact_source:true first in
  let replayed_report = Failure.to_string_hum ~redact_source:true replayed in
  [%test_result: string] replayed_report ~expect:first_report;
  print_string first_report;
  [%expect
    {|
    input_events: timed f_model/two-state Evsim comparison failed

    reproduction:
      test:             input_events_controlled_timed_mismatch
      test file:        test/primitives/input_events/input_events_timing_tests.ml
      seed:             20260919
      trials:           4
      max size:         8
      failing trial:    0
      configuration:    ((max_edges 32)(max_transitions 96)(defect Delay_pad_transitions_one_tick))
      source identity:  <recorded; redacted in expect output>
      rerun:            PROTEMU_SEED=20260919 PROTEMU_TRIALS=4 PROTEMU_SIZE=8 dune runtest test/primitives/input_events --force
      time unit:        tick
      clock:            period=10, first rising=5
      coincidence:      stimulus settles before the clock transition

    first mismatch:
      time:             25 tick
      sample time:      26 tick
      edge:             2
      phase:            post_edge
      observation:      snapshot_o
      expected (model): 1
      actual (dut):     0

    failing scenario:
      edges: 6
      ((time 0)(action(Reset true)))
      ((time 6)(action(Reset false)))
      ((time 15)(action(Pad 1)))
      ((time 16)(action(Pad 0)))
      ((time 36)(action(Event_set 1)))
      ((time 37)(action(Event_set 0)))

    shrunk scenario:
      edges: 3
      ((time 0)(action(Reset true)))
      ((time 6)(action(Reset false)))
      ((time 15)(action(Pad 1)))
      ((time 16)(action(Pad 0)))

    nearby sampled context:
      edge 0 t=5 sample=6 pins=0 rise=0 fall=0 event=0 overflow=0
      edge 1 t=15 sample=16 pins=0 rise=0 fall=0 event=0 overflow=0
      edge 2 t=25 sample=26 pins=0 rise=0 fall=0 event=0 overflow=0
      edge 3 t=35 sample=36 pins=0 rise=0 fall=0 event=0 overflow=0
      edge 4 t=45 sample=46 pins=0 rise=0 fall=0 event=0 overflow=0

    between-edge activity:
      t=16 pin_in_i=1
      t=17 pin_in_i=0
    |}]
;;
