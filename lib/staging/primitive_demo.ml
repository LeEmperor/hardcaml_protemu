(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "primitive_demo.ml" *)
(* A small independent timer/lane composition. It demonstrates that a core wait
   does not clock-gate a transfer already in progress. *)

open! Core
open! Hardcaml
open! Signal

module I = struct
  type 'a t =
    { clock_i : 'a
    ; reset_i : 'a
    ; enable_i : 'a
    ; abort_i : 'a
    ; wait_valid_i : 'a
    ; wait_delay_i : 'a [@bits 16]
    ; transfer_valid_i : 'a
    ; transfer_count_i : 'a [@bits 6]
    ; transfer_data_i : 'a [@bits 32]
    ; half_period_i : 'a [@bits 16]
    }
  [@@deriving hardcaml]
end

module O = struct
  type 'a t =
    { wait_busy_o : 'a
    ; wait_complete_o : 'a
    ; transfer_busy_o : 'a
    ; transfer_done_o : 'a
    ; pins_o : 'a [@bits 8]
    ; pin_oe_o : 'a [@bits 8]
    }
  [@@deriving hardcaml]
end

let create (scope : Scope.t) (i : _ I.t) : _ O.t =
  let timing =
    Timing.create
      (Scope.sub_scope scope "timing")
      { Timing.I.clock_i = i.clock_i
      ; reset_i = i.reset_i
      ; enable_i = i.enable_i
      ; abort_i = i.abort_i
      ; wait_valid_i = i.wait_valid_i
      ; wait_kind_i = zero 2
      ; wait_pin_i = zero 3
      ; wait_level_i = gnd
      ; wait_timeout_enable_i = gnd
      ; wait_delay_i = i.wait_delay_i
      ; snapshot_i = zero 8
      ; rising_i = zero 8
      ; falling_i = zero 8
      ; periodic_start_i = gnd
      ; periodic_stop_i = gnd
      ; periodic_period_i = zero 16
      ; phase_restart_i = gnd
      }
  in
  let lane =
    Shift_lane.create
      (Scope.sub_scope scope "lane")
      { Shift_lane.I.clock_i = i.clock_i
      ; reset_i = i.reset_i
      ; enable_i = i.enable_i
      ; abort_i = i.abort_i
      ; start_valid_i = i.transfer_valid_i
      ; arm_i = gnd
      ; start_event_i = gnd
      ; bit_count_i = i.transfer_count_i
      ; tx_value_i = i.transfer_data_i
      ; tx_valid_i = vdd
      ; rx_ready_i = vdd
      ; tx_enable_i = vdd
      ; rx_enable_i = gnd
      ; lsb_first_i = vdd
      ; output_pin_i = zero 3
      ; input_pin_i = zero 3
      ; clock_pin_i = zero 3
      ; clock_enable_i = gnd
      ; idle_output_i = gnd
      ; idle_clock_i = gnd
      ; initial_delay_i = zero 16
      ; half_period_i = i.half_period_i
      ; launch_trailing_i = vdd
      ; sample_trailing_i = gnd
      ; observed_i = gnd
      ; observed_edge_i = gnd
      ; pin_in_i = zero 8
      ; occupied_i = zero 8
      }
  in
  { O.wait_busy_o = timing.busy_o
  ; wait_complete_o = timing.complete_o
  ; transfer_busy_o = lane.busy_o
  ; transfer_done_o = lane.done_o
  ; pins_o = lane.pin_value_o
  ; pin_oe_o = lane.pin_oe_o
  }
;;
