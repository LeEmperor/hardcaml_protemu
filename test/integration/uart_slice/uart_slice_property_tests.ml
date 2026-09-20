(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "uart_slice_property_tests.ml" *)
(* Bounded generated evidence for the P2.7 UART slice.

   Completed trials compare frame-relative traces: each producer's independent receiver
   finds its own start edge before the slots are compared. This intentionally says nothing
   about request-to-start latency. Interrupted trials instead check the slice's
   synchronous release contract at the edge after reset, disable, or abort.

   This property keeps the established replay settings and source/dependency identity, but
   has no shrinker or checker adapter. A scenario is already one minimal frame or
   interruption, and its full value is printed on failure.
*)

open! Core
open! Hardcaml
open! Uart_slice_testbench

module Interruption = struct
  type t =
    | Complete
    | Reset
    | Disable
    | Abort
  [@@deriving sexp_of]
end

module Scenario = struct
  type t =
    { byte : int
    ; pin : int
    ; half_period : int
    ; interruption : Interruption.t
    ; interrupt_cycle : int
    }
  [@@deriving sexp_of]
end

module Generator = struct
  module G = Base_quickcheck.Generator
  open G.Let_syntax

  let scenario =
    let%bind size = G.size in
    let maximum_half_period =
      Int.min generated_max_half_period (generated_min_half_period + size)
    in
    let%bind byte = G.int_uniform_inclusive 0 0xff
    and pin = G.int_uniform_inclusive 0 7
    and half_period =
      G.int_uniform_inclusive generated_min_half_period maximum_half_period
    and interruption =
      G.of_weighted_list [ 4., Interruption.Complete; 1., Reset; 1., Disable; 1., Abort ]
    in
    let%map interrupt_cycle = G.int_uniform_inclusive 0 (20 * half_period) in
    { Scenario.byte; pin; half_period; interruption; interrupt_cycle }
  ;;
end

let selected_mask pin = 1 lsl pin

let check_equal label expected actual =
  if Poly.equal expected actual then Ok () else Error label
;;

let check_complete (scenario : Scenario.t) =
  let mask = selected_mask scenario.pin in
  let saw_gap = ref false in
  let saw_claim = ref false in
  let done_count = ref 0 in
  let bank_clean = ref true in
  let other_pins_clean = ref true in
  let samples, o =
    slice_samples
      ~byte:scenario.byte
      ~half_period:scenario.half_period
      ~pin:scenario.pin
      ~f:(fun ~cycle:_ ~i:_ ~o ->
        saw_gap := !saw_gap || Bits.to_bool !(o.gap_busy_o);
        saw_claim := !saw_claim || Bits.to_int_trunc !(o.engine_claim_o) land mask <> 0;
        if Bits.to_bool !(o.frame_done_o) then Int.incr done_count;
        bank_clean
        := !bank_clean
           && not (Bits.to_bool !(o.bank_rejected_o) || Bits.to_bool !(o.bank_conflict_o));
        other_pins_clean
        := !other_pins_clean
           && Bits.to_int_trunc !(o.pins_o) land lnot mask = 0
           && Bits.to_int_trunc !(o.pin_oe_o) land lnot mask = 0)
      ()
  in
  let firmware =
    trace_of
      (firmware_samples
         ~byte:scenario.byte
         ~half_period:scenario.half_period
         ~pin:scenario.pin
         ())
      ~byte:scenario.byte
      ~half_period:scenario.half_period
      ~tx_pin:scenario.pin
  in
  let descriptor =
    trace_of
      (descriptor_samples
         ~byte:scenario.byte
         ~half_period:scenario.half_period
         ~pin:scenario.pin
         ())
      ~byte:scenario.byte
      ~half_period:scenario.half_period
      ~tx_pin:scenario.pin
  in
  let hardware =
    trace_of
      samples
      ~byte:scenario.byte
      ~half_period:scenario.half_period
      ~tx_pin:scenario.pin
  in
  let checks =
    [ check_equal "firmware/descriptor frame" firmware descriptor
    ; check_equal "firmware/Hardcaml frame" firmware hardware
    ; check_equal "timer activity" true !saw_gap
    ; check_equal "engine ownership" true !saw_claim
    ; check_equal "completion pulse count" 1 !done_count
    ; check_equal "bank status" true !bank_clean
    ; check_equal "unselected pins" true !other_pins_clean
    ; check_equal "released engine claim" 0 (Bits.to_int_trunc !(o.engine_claim_o))
    ; check_equal "software claim" 0 (Bits.to_int_trunc !(o.software_claim_o))
    ; check_equal "idle pin value" mask (Bits.to_int_trunc !(o.pins_o))
    ; check_equal "idle pin drive" mask (Bits.to_int_trunc !(o.pin_oe_o))
    ; check_equal "slice no longer busy" false (Bits.to_bool !(o.busy_o))
    ; check_equal "slice ready again" true (Bits.to_bool !(o.ready_o))
    ]
  in
  Result.all_unit checks
;;

let check_interrupted (scenario : Scenario.t) =
  let mask = selected_mask scenario.pin in
  let released_after_edge = ref None in
  let done_count = ref 0 in
  let bank_clean = ref true in
  let other_pins_clean = ref true in
  let (_samples : Uart_frame_monitor.Sample.t array), o =
    slice_samples
      ~byte:scenario.byte
      ~half_period:scenario.half_period
      ~pin:scenario.pin
      ~extra_cycles:4
      ~f:(fun ~cycle ~i ~o ->
        if cycle = scenario.interrupt_cycle
        then (
          match scenario.interruption with
          | Complete -> assert false
          | Reset -> i.reset_i := Bits.vdd
          | Disable -> i.enable_i := Bits.gnd
          | Abort -> i.abort_i := Bits.vdd);
        if Bits.to_bool !(o.frame_done_o) then Int.incr done_count;
        bank_clean
        := !bank_clean
           && not (Bits.to_bool !(o.bank_rejected_o) || Bits.to_bool !(o.bank_conflict_o));
        other_pins_clean
        := !other_pins_clean
           && Bits.to_int_trunc !(o.pins_o) land lnot mask = 0
           && Bits.to_int_trunc !(o.pin_oe_o) land lnot mask = 0;
        if cycle = scenario.interrupt_cycle + 1
        then
          released_after_edge
          := Some
               ( Bits.to_int_trunc !(o.pins_o)
               , Bits.to_int_trunc !(o.pin_oe_o)
               , Bits.to_int_trunc !(o.engine_claim_o) ))
      ()
  in
  let checks =
    [ check_equal "next-edge release" (Some (0, 0, 0)) !released_after_edge
    ; check_equal "interrupted frame did not complete" 0 !done_count
    ; check_equal "bank status" true !bank_clean
    ; check_equal "unselected pins" true !other_pins_clean
    ; check_equal "software claim" 0 (Bits.to_int_trunc !(o.software_claim_o))
    ; check_equal "slice no longer busy" false (Bits.to_bool !(o.busy_o))
    ]
  in
  Result.all_unit checks
;;

let check_scenario scenario =
  match scenario.Scenario.interruption with
  | Complete -> check_complete scenario
  | Reset | Disable | Abort -> check_interrupted scenario
;;

let regression_settings = Replay.Settings.create ~seed:20260920 ~trials:96 ~size:16

let quickcheck ~(here : [%call_pos]) ~test ~settings () =
  let settings = Replay.Settings.override settings in
  let random = Splittable_random.of_int settings.seed in
  let rec search trial =
    if trial >= settings.trials
    then None
    else (
      let size = Replay.Settings.size_of_trial settings ~trial in
      let scenario =
        Base_quickcheck.Generator.generate Generator.scenario ~size ~random
      in
      match check_scenario scenario with
      | Ok () -> search (trial + 1)
      | Error reason ->
        let replay =
          Replay.create
            ~test
            ~source_file:here.pos_fname
            ~settings
            ~trial:(Some trial)
            ~config:[%sexp (scenario : Scenario.t)]
        in
        let report =
          let scenario = Sexp.to_string_hum [%sexp (scenario : Scenario.t)] in
          String.concat
            ~sep:"\n"
            ([ "uart_slice: generated slice property failed"; ""; "reproduction:" ]
             @ Replay.to_lines replay
             @ [ ""
               ; [%string "scenario: %{scenario}"]
               ; [%string "reason:   %{reason}"]
               ; ""
               ])
        in
        let artifact =
          Replay.Artifacts.write
            ~test
            ~settings
            ~trial
            ~contents:(report ^ Replay.artifact_appendix replay)
        in
        Some
          (match artifact with
           | None -> report
           | Some path -> report ^ [%string "artifact: %{path}\n"]))
  in
  search 0
;;

let%expect_test "bounded frames and interruptions preserve the slice contracts" =
  (match
     quickcheck
       ~here:[%here]
       ~test:"uart_slice_bounded_frames_and_interruptions"
       ~settings:regression_settings
       ()
   with
   | None -> print_endline "agreed on every generated UART-slice trial"
   | Some failure -> print_string failure);
  [%expect {| agreed on every generated UART-slice trial |}]
;;

let%expect_test "the generated property prints its executable reproduction command" =
  print_endline
    (Replay.rerun_command
       ~source_file:"test/integration/uart_slice/uart_slice_property_tests.ml"
       ~settings:regression_settings);
  [%expect
    {|
    PROTEMU_SEED=20260920 PROTEMU_TRIALS=96 PROTEMU_SIZE=16 dune runtest test/integration/uart_slice --force
    |}]
;;
