(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "observed_transfer.ml" *)
(* Synchronize pad data, start, pacing, and cancellation pins through the same two-stage
   front end before an armed lane consumes them. Selector configuration is latched with
   the arm request; edges and data are from one snapshot. *)

open! Core
open! Hardcaml
open! Signal

module I = struct
  type 'a t =
    { clock_i : 'a
    ; reset_i : 'a
    ; enable_i : 'a
    ; abort_i : 'a
    ; pin_async_i : 'a [@bits 8]
    ; arm_valid_i : 'a
    ; start_pin_i : 'a [@bits 3]
    ; start_edge_kind_i : 'a [@bits 2]
    ; pacing_pin_i : 'a [@bits 3]
    ; pacing_edge_kind_i : 'a [@bits 2]
    ; cancel_enable_i : 'a
    ; cancel_pin_i : 'a [@bits 3]
    ; cancel_edge_kind_i : 'a [@bits 2]
    ; bit_count_i : 'a [@bits 6]
    ; tx_value_i : 'a [@bits 32]
    ; tx_valid_i : 'a
    ; rx_ready_i : 'a
    ; tx_enable_i : 'a
    ; rx_enable_i : 'a
    ; lsb_first_i : 'a
    ; output_pin_i : 'a [@bits 3]
    ; input_pin_i : 'a [@bits 3]
    ; idle_output_i : 'a
    ; idle_clock_i : 'a
    ; launch_trailing_i : 'a
    ; sample_trailing_i : 'a
    ; occupied_i : 'a [@bits 8]
    }
  [@@deriving hardcaml]
end

module O = struct
  type 'a t =
    { snapshot_o : 'a [@bits 8]
    ; start_edge_o : 'a
    ; pacing_edge_o : 'a
    ; cancel_edge_o : 'a
    ; armed_o : 'a
    ; busy_o : 'a
    ; claim_mask_o : 'a [@bits 8]
    ; pin_value_o : 'a [@bits 8]
    ; pin_oe_o : 'a [@bits 8]
    ; done_o : 'a
    ; rx_valid_o : 'a
    ; rx_data_o : 'a [@bits 32]
    ; rejected_o : 'a
    ; underrun_o : 'a
    ; overrun_o : 'a
    }
  [@@deriving hardcaml]
end

module Config_regs = struct
  type 'a t =
    { start_pin : 'a [@bits 3]
    ; start_edge_kind : 'a [@bits 2]
    ; pacing_pin : 'a [@bits 3]
    ; pacing_edge_kind : 'a [@bits 2]
    ; cancel_enable : 'a
    ; cancel_pin : 'a [@bits 3]
    ; cancel_edge_kind : 'a [@bits 2]
    }
  [@@deriving hardcaml]
end

let edge_word rising falling kind =
  mux kind [ rising; falling; rising |: falling; zero 8 ]
;;

let create (scope : Scope.t) (i : _ I.t) : _ O.t =
  let open Always in
  let spec = Reg_spec.create ~clock:i.clock_i ~clear:i.reset_i () in
  let config = Config_regs.Of_always.reg spec in
  Config_regs.Of_always.apply_names
    ~prefix:"config_"
    ~naming_op:(Scope.naming scope)
    config;
  let front =
    Input_events.create
      (Scope.sub_scope scope "front")
      { Input_events.I.clock_i = i.clock_i
      ; reset_i = i.reset_i
      ; pin_in_i = i.pin_async_i
      ; event_set_i = zero 6
      ; event_ack_i = zero 6
      }
  in
  let start_edge =
    Shift_lane.selected
      (edge_word front.rising_o front.falling_o config.start_edge_kind.value)
      config.start_pin.value
  in
  let pacing_edge =
    Shift_lane.selected
      (edge_word front.rising_o front.falling_o config.pacing_edge_kind.value)
      config.pacing_pin.value
  in
  let transfer_active = wire 1 in
  let cancel_edge =
    transfer_active
    &: config.cancel_enable.value
    &: Shift_lane.selected
         (edge_word front.rising_o front.falling_o config.cancel_edge_kind.value)
         config.cancel_pin.value
  in
  let selector_invalid =
    i.start_edge_kind_i
    ==:. 3
    |: (i.pacing_edge_kind_i ==:. 3)
    |: (i.cancel_enable_i &: (i.cancel_edge_kind_i ==:. 3))
  in
  let pacing_role_conflict =
    i.tx_enable_i
    &: (i.pacing_pin_i ==: i.output_pin_i)
    |: (i.rx_enable_i &: (i.pacing_pin_i ==: i.input_pin_i))
  in
  let arm_invalid =
    selector_invalid
    |: pacing_role_conflict
    |: (i.bit_count_i ==:. 0)
    |: (i.bit_count_i >:. 32)
    |: (log_shift ~f:srl i.tx_value_i ~by:i.bit_count_i <>:. 0)
    |: (i.launch_trailing_i ==: i.sample_trailing_i)
    |: (~:(i.tx_enable_i) &: ~:(i.rx_enable_i))
    |: (i.tx_enable_i &: ~:(i.tx_valid_i))
  in
  let lane =
    Shift_lane.create
      (Scope.sub_scope scope "lane")
      { Shift_lane.I.clock_i = i.clock_i
      ; reset_i = i.reset_i
      ; enable_i = i.enable_i
      ; abort_i = i.abort_i |: cancel_edge
      ; start_valid_i = i.arm_valid_i
      ; arm_i = vdd
      ; start_event_i = start_edge
      ; bit_count_i =
          mux2 (selector_invalid |: pacing_role_conflict) (zero 6) i.bit_count_i
      ; tx_value_i = i.tx_value_i
      ; tx_valid_i = i.tx_valid_i
      ; rx_ready_i = i.rx_ready_i
      ; tx_enable_i = i.tx_enable_i
      ; rx_enable_i = i.rx_enable_i
      ; lsb_first_i = i.lsb_first_i
      ; output_pin_i = i.output_pin_i
      ; input_pin_i = i.input_pin_i
      ; clock_pin_i = zero 3
      ; clock_enable_i = gnd
      ; idle_output_i = i.idle_output_i
      ; idle_clock_i = i.idle_clock_i
      ; initial_delay_i = zero 16
      ; half_period_i = of_int_trunc ~width:16 1
      ; launch_trailing_i = i.launch_trailing_i
      ; sample_trailing_i = i.sample_trailing_i
      ; observed_i = vdd
      ; observed_edge_i = pacing_edge
      ; pin_in_i = front.snapshot_o
      ; occupied_i = i.occupied_i
      }
  in
  assign transfer_active (lane.armed_o |: lane.busy_o);
  compile
    [ when_
        (i.arm_valid_i &: lane.ready_o &: ~:(i.abort_i) &: ~:arm_invalid)
        [ config.start_pin <-- i.start_pin_i
        ; config.start_edge_kind <-- i.start_edge_kind_i
        ; config.pacing_pin <-- i.pacing_pin_i
        ; config.pacing_edge_kind <-- i.pacing_edge_kind_i
        ; config.cancel_enable <-- i.cancel_enable_i
        ; config.cancel_pin <-- i.cancel_pin_i
        ; config.cancel_edge_kind <-- i.cancel_edge_kind_i
        ]
    ];
  { O.snapshot_o = front.snapshot_o
  ; start_edge_o = start_edge
  ; pacing_edge_o = pacing_edge
  ; cancel_edge_o = cancel_edge
  ; armed_o = lane.armed_o
  ; busy_o = lane.busy_o
  ; claim_mask_o = lane.claim_mask_o
  ; pin_value_o = lane.pin_value_o
  ; pin_oe_o = lane.pin_oe_o
  ; done_o = lane.done_o
  ; rx_valid_o = lane.rx_valid_o
  ; rx_data_o = lane.rx_data_o
  ; rejected_o = lane.rejected_o
  ; underrun_o = lane.underrun_o
  ; overrun_o = lane.overrun_o
  }
;;
