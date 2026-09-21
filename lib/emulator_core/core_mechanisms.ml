(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "core_mechanisms.ml" *)
(* P3.3 adapter from the retained execution command to the P2 mechanisms.

   One shared input front end supplies every snapshot and observed edge. Timing waits and
   blocking FIFO operations retain command ownership until completion. A transfer retires
   at lane acceptance and then progresses in the background through one central pin bank.
*)

open! Core
open! Hardcaml
open! Signal
open! Protemu_isa

module Reason = struct
  let width = Control_execution.Config.mechanism_reason_bits
  let none = 0
  let unavailable = 1
  let invalid_parameter = 2
  let pin_conflict = 3
  let fifo_full = 4
  let fifo_empty = 5
  let data_out_of_range = 6
  let cancelled = 7
  let primitive_failure = 8
end

module Bridge_state = struct
  let width = 2
  let idle = 0
  let active = 1
  let release = 2
end

module I = struct
  type 'a t =
    { clock_i : 'a
    ; reset_i : 'a
    ; en_i : 'a
    ; abort_i : 'a
    ; abort_event_i : 'a
    ; pin_async_i : 'a [@bits Pins.count]
    ; occupied_i : 'a [@bits Pins.count]
    ; mechanism_request_valid_i : 'a
    ; mechanism_kind_i : 'a [@bits Control_execution.Config.mechanism_kind_bits]
    ; mechanism_arg0_i : 'a [@bits Instruction.Register.width]
    ; mechanism_arg1_i : 'a [@bits Instruction.Register.width]
    ; mechanism_arg2_i : 'a [@bits Instruction.Register.width]
    ; mechanism_timeout_enable_i : 'a
    ; mechanism_descriptor_i : 'a [@bits Control_execution.Config.descriptor_bits]
    ; software_claim_valid_i : 'a
    ; software_claim_mask_i : 'a [@bits Pins.count]
    ; software_release_valid_i : 'a
    ; software_release_mask_i : 'a [@bits Pins.count]
    ; tx_ready_i : 'a
    ; rx_valid_i : 'a
    ; rx_data_i : 'a [@bits 8]
    ; transfer_rx_ready_i : 'a
    }
  [@@deriving hardcaml]
end

module O = struct
  type 'a t =
    { mechanism_accepted_o : 'a
    ; mechanism_refused_o : 'a
    ; mechanism_refusal_reason_o : 'a [@bits Reason.width]
    ; mechanism_completion_valid_o : 'a
    ; mechanism_completion_result_o : 'a [@bits Instruction.Register.width]
    ; mechanism_completion_fault_o : 'a
    ; mechanism_completion_reason_o : 'a [@bits Reason.width]
    ; engines_idle_o : 'a
    ; snapshot_o : 'a [@bits Pins.count]
    ; rising_o : 'a [@bits Pins.count]
    ; falling_o : 'a [@bits Pins.count]
    ; status_o : 'a [@bits Event_kind.count]
    ; status_overflow_o : 'a [@bits Event_kind.count]
    ; pins_o : 'a [@bits Pins.count]
    ; pin_oe_o : 'a [@bits Pins.count]
    ; software_claim_o : 'a [@bits Pins.count]
    ; engine_claim_o : 'a [@bits Pins.count]
    ; software_request_rejected_o : 'a
    ; bank_conflict_o : 'a
    ; timing_busy_o : 'a
    ; transfer_busy_o : 'a
    ; transfer_done_o : 'a
    ; transfer_fault_o : 'a
    ; transfer_rx_valid_o : 'a
    ; transfer_rx_data_o : 'a [@bits 32]
    ; tx_valid_o : 'a
    ; tx_data_o : 'a [@bits 8]
    ; rx_ready_o : 'a
    ; tx_count_o : 'a [@bits 5]
    ; rx_count_o : 'a [@bits 5]
    }
  [@@deriving hardcaml]
end

[@@@ocamlformat "disable"]

module I_Regs = struct
  type 'a t =
    { wait_pending       : 'a
    ; wait_is_delay      : 'a
    ; wait_either        : 'a
    ; fifo_pending       : 'a
    ; fifo_push          : 'a
    ; fifo_rx            : 'a
    ; fifo_data          : 'a [@bits 8]
    ; bridge_state       : 'a [@bits Bridge_state.width]
    ; bridge_claim       : 'a [@bits Pins.count]
    ; bridge_pacing_pin  : 'a [@bits 3]
    ; bridge_pacing_edge : 'a [@bits 2]
    ; fifo_faults        : 'a [@bits 4]
    }
  [@@deriving hardcaml]
end

let const ~width value = of_int_trunc ~width value
let is_kind kind value = kind ==:. value
let selected word pin = mux pin (List.init Pins.count ~f:(fun n -> bit word ~pos:n))

let create (scope : Scope.t) (i : _ I.t) : _ O.t =
  let open Always in
  let spec = Reg_spec.create ~clock:i.clock_i ~clear:i.reset_i () in
  let r = I_Regs.Of_always.reg spec in
  I_Regs.Of_always.apply_names ~prefix:"reg_" ~naming_op:(Scope.naming scope) r;

  let event_set = wire Event_kind.count in
  let event_ack = wire Event_kind.count in
  let events =
    Input_events.create
      (Scope.sub_scope scope "events")
      { Input_events.I.clock_i = i.clock_i
      ; reset_i = i.reset_i |: ~:(i.en_i)
      ; pin_in_i = i.pin_async_i
      ; event_set_i = event_set
      ; event_ack_i = event_ack
      }
  in
  let bank_software_claim = wire Pins.count in
  let bank_engine_claim = wire Pins.count in
  let lane_ready = wire 1 in

  let request = i.mechanism_request_valid_i &: i.en_i &: ~:(i.reset_i) &: ~:(i.abort_i) in
  let kind value = request &: is_kind i.mechanism_kind_i value in
  let read_pins = kind Control_execution.Mechanism_kind.read_pins in
  let read_status = kind Control_execution.Mechanism_kind.read_status in
  let ack_status = kind Control_execution.Mechanism_kind.ack_status in
  let branch_pin = kind Control_execution.Mechanism_kind.branch_pin in
  let write_pins =
    kind Control_execution.Mechanism_kind.write_pins_imm
    |: kind Control_execution.Mechanism_kind.write_pins_reg
  in
  let wait_cycles =
    kind Control_execution.Mechanism_kind.wait_cycles_imm
    |: kind Control_execution.Mechanism_kind.wait_cycles_reg
  in
  let wait_level = kind Control_execution.Mechanism_kind.wait_level in
  let wait_edge = kind Control_execution.Mechanism_kind.wait_edge in
  let start_periodic = kind Control_execution.Mechanism_kind.start_periodic in
  let stop_periodic = kind Control_execution.Mechanism_kind.stop_periodic in
  let issue_transfer = kind Control_execution.Mechanism_kind.issue_transfer in
  let fifo_push_request = kind Control_execution.Mechanism_kind.fifo_push in
  let fifo_pop_request = kind Control_execution.Mechanism_kind.fifo_pop in

  let wait_parameter_valid =
    (~:wait_cycles |: (i.mechanism_arg0_i <>:. 0))
    &: (~:(i.mechanism_timeout_enable_i) |: (i.mechanism_arg2_i <>:. 0))
  in
  let immediate_level =
    wait_level
    &: (selected events.snapshot_o (sel_bottom i.mechanism_arg0_i ~width:3)
        ==: bit i.mechanism_arg1_i ~pos:0)
  in
  let timing_ready = wire 1 in
  let timing_complete = wire 1 in
  let timing_timeout = wire 1 in
  let timing_tick = wire 1 in
  let wait_accept =
    (wait_cycles |: wait_level |: wait_edge) &: wait_parameter_valid &: timing_ready
  in
  let wait_delayed_accept = wait_accept &: ~:immediate_level in
  let wait_refused =
    (wait_cycles |: wait_level |: wait_edge)
    &: (~:wait_parameter_valid |: ~:timing_ready)
  in
  let edge_either = wait_edge &: (sel_bottom i.mechanism_arg1_i ~width:2 ==:. 2) in
  let timing_rising = mux2 r.wait_either.value (events.rising_o |: events.falling_o) events.rising_o in
  let timing =
    Timing.create
      (Scope.sub_scope scope "timing")
      { Timing.I.clock_i = i.clock_i
      ; reset_i = i.reset_i
      ; enable_i = i.en_i
      ; abort_i = i.abort_i
      ; wait_valid_i = wait_delayed_accept
      ; wait_kind_i =
          mux2
            wait_cycles
            (const ~width:2 0)
            (mux2 wait_level (const ~width:2 1)
               (mux2 edge_either (const ~width:2 2)
                  (sel_bottom i.mechanism_arg1_i ~width:2 +:. 2)))
      ; wait_pin_i = sel_bottom i.mechanism_arg0_i ~width:3
      ; wait_level_i = bit i.mechanism_arg1_i ~pos:0
      ; wait_timeout_enable_i = i.mechanism_timeout_enable_i
      ; wait_delay_i = mux2 wait_cycles i.mechanism_arg0_i i.mechanism_arg2_i
      ; snapshot_i = events.snapshot_o
      ; rising_i = timing_rising
      ; falling_i = events.falling_o
      ; periodic_start_i = start_periodic &: (i.mechanism_arg0_i <>:. 0)
      ; periodic_stop_i = stop_periodic
      ; periodic_period_i = i.mechanism_arg0_i
      ; phase_restart_i = gnd
      }
  in
  assign timing_ready timing.ready_o;
  assign timing_complete timing.complete_o;
  assign timing_timeout timing.timeout_o;
  assign timing_tick timing.tick_o;

  let tx_push_valid = wire 1 in
  let tx_push_data = wire 8 in
  let tx_pop_ready = wire 1 in
  let rx_push_valid = wire 1 in
  let rx_push_data = wire 8 in
  let rx_pop_ready = wire 1 in
  let tx_fifo =
    Byte_fifo.create
      ~depth:8
      (Scope.sub_scope scope "tx_fifo")
      { Byte_fifo.I.clock_i = i.clock_i
      ; reset_i = i.reset_i
      ; enable_i = i.en_i
      ; push_valid_i = tx_push_valid
      ; push_data_i = tx_push_data
      ; pop_ready_i = tx_pop_ready
      }
  in
  let rx_fifo =
    Byte_fifo.create
      ~depth:8
      (Scope.sub_scope scope "rx_fifo")
      { Byte_fifo.I.clock_i = i.clock_i
      ; reset_i = i.reset_i
      ; enable_i = i.en_i
      ; push_valid_i = rx_push_valid
      ; push_data_i = rx_push_data
      ; pop_ready_i = rx_pop_ready
      }
  in
  let fifo_request = fifo_push_request |: fifo_pop_request in
  let request_fifo_rx = bit i.mechanism_arg0_i ~pos:0 in
  let request_blocking = ~:(bit i.mechanism_arg1_i ~pos:0) in
  let request_data_valid = select i.mechanism_arg2_i ~high:15 ~low:8 ==:. 0 in
  let selected_push_ready = mux2 request_fifo_rx rx_fifo.push_ready_o tx_fifo.push_ready_o in
  let selected_pop_valid = mux2 request_fifo_rx rx_fifo.pop_valid_o tx_fifo.pop_valid_o in
  let selected_pop_data = mux2 request_fifo_rx rx_fifo.pop_data_o tx_fifo.pop_data_o in
  let fifo_invalid_data = fifo_push_request &: ~:request_data_valid in
  let fifo_immediate_push =
    fifo_push_request &: ~:fifo_invalid_data &: selected_push_ready
  in
  let fifo_immediate_pop = fifo_pop_request &: selected_pop_valid in
  let fifo_immediate = fifo_immediate_push |: fifo_immediate_pop in
  let fifo_blocked_accept =
    request_blocking
    &: ((fifo_push_request &: ~:fifo_invalid_data &: ~:selected_push_ready)
        |: (fifo_pop_request &: ~:selected_pop_valid))
  in
  let fifo_refused =
    fifo_invalid_data
    |: (~:request_blocking
        &: ((fifo_push_request &: ~:selected_push_ready)
            |: (fifo_pop_request &: ~:selected_pop_valid)))
  in
  let pending_push_ready =
    mux2 r.fifo_rx.value rx_fifo.push_ready_o tx_fifo.push_ready_o
  in
  let pending_pop_valid =
    mux2 r.fifo_rx.value rx_fifo.pop_valid_o tx_fifo.pop_valid_o
  in
  let pending_push_complete =
    r.fifo_pending.value
    &: r.fifo_push.value
    &: pending_push_ready
    &: ~:(i.abort_i)
  in
  let pending_pop_complete =
    r.fifo_pending.value
    &: ~:(r.fifo_push.value)
    &: pending_pop_valid
    &: ~:(i.abort_i)
  in
  let pending_fifo_complete = pending_push_complete |: pending_pop_complete in
  let pending_fifo_pop_data = mux2 r.fifo_rx.value rx_fifo.pop_data_o tx_fifo.pop_data_o in
  let core_fifo_push_fire =
    fifo_immediate_push |: pending_push_complete
  in
  let core_fifo_pop_fire =
    fifo_immediate_pop |: pending_pop_complete
  in
  let core_fifo_rx =
    mux2 r.fifo_pending.value r.fifo_rx.value request_fifo_rx
  in
  let core_fifo_data =
    mux2 r.fifo_pending.value r.fifo_data.value (sel_bottom i.mechanism_arg2_i ~width:8)
  in
  let core_tx_push = core_fifo_push_fire &: ~:core_fifo_rx in
  let core_rx_push = core_fifo_push_fire &: core_fifo_rx in
  let core_tx_pop = core_fifo_pop_fire &: ~:core_fifo_rx in
  let core_rx_pop = core_fifo_pop_fire &: core_fifo_rx in
  assign tx_push_valid core_tx_push;
  assign tx_push_data core_fifo_data;
  assign tx_pop_ready (core_tx_pop |: (i.tx_ready_i &: ~:core_tx_pop));
  assign rx_push_valid (core_rx_push |: (i.rx_valid_i &: ~:core_rx_push));
  assign rx_push_data (mux2 core_rx_push core_fifo_data i.rx_data_i);
  assign rx_pop_ready core_rx_pop;

  let desc_field index =
    select i.mechanism_descriptor_i ~high:((index * 16) + 15) ~low:(index * 16)
  in
  let control = desc_field 0 in
  let bit_count = desc_field 1 in
  let tx_value = desc_field 2 in
  let output_pin = desc_field 3 in
  let input_pin = desc_field 4 in
  let clock_pin = desc_field 5 in
  let initial_delay = desc_field 6 in
  let half_period = desc_field 7 in
  let pacing = desc_field 8 in
  let direction = select control ~high:1 ~low:0 in
  let tx_enable = direction <>:. 1 in
  let rx_enable = direction <>:. 0 in
  let lsb_first = ~:(bit control ~pos:2) in
  let idle_output = bit control ~pos:3 in
  let idle_clock = bit control ~pos:4 in
  let launch_falling = bit control ~pos:5 in
  let sample_falling = bit control ~pos:6 in
  let output_present = output_pin <:. Pins.count in
  let input_present = input_pin <:. Pins.count in
  let clock_present = clock_pin <:. Pins.count in
  let observed = pacing <>:. Descriptor.Pacing.internal in
  let pacing_valid = pacing <=:. (Pins.count * 3) in
  let pacing_pin = wire 3 in
  let pacing_edge = wire 2 in
  let pacing_pin_value =
    List.fold
      (List.range 1 ((Pins.count * 3) + 1))
      ~init:(zero 3)
      ~f:(fun value encoded ->
        mux2 (pacing ==:. encoded) (const ~width:3 ((encoded - 1) / 3)) value)
  in
  let pacing_edge_value =
    List.fold
      (List.range 1 ((Pins.count * 3) + 1))
      ~init:(zero 2)
      ~f:(fun value encoded ->
        mux2 (pacing ==:. encoded) (const ~width:2 ((encoded - 1) % 3)) value)
  in
  assign pacing_pin pacing_pin_value;
  assign pacing_edge pacing_edge_value;
  let pin_mask present pin = mux2 present (Shift_lane.pin_mask (sel_bottom pin ~width:3)) (zero 8) in
  let output_mask = pin_mask (tx_enable &: output_present) output_pin in
  let clock_mask = pin_mask clock_present clock_pin in
  let driven_mask = output_mask |: clock_mask in
  let tx_value_32 = uresize tx_value ~width:32 in
  let tx_value_too_wide =
    (bit_count <:. 16)
    &: ((log_shift ~f:srl tx_value ~by:(sel_bottom bit_count ~width:4)) <>:. 0)
  in
  let role_collision =
    (output_present &: clock_present &: (output_pin ==: clock_pin))
    |: (input_present &: clock_present &: (input_pin ==: clock_pin))
    |: (observed
        &: ((output_present &: (sel_bottom output_pin ~width:3 ==: pacing_pin))
            |: (input_present &: (sel_bottom input_pin ~width:3 ==: pacing_pin))
            |: (clock_present &: (sel_bottom clock_pin ~width:3 ==: pacing_pin))))
  in
  let direction_invalid =
    mux
      direction
      [ ~:output_present |: input_present
      ; ~:input_present |: output_present
      ; ~:output_present |: ~:input_present
      ; ~:output_present |: ~:input_present
      ]
  in
  let descriptor_invalid =
    (bit_count ==:. 0)
    |: (bit_count >:. 32)
    |: tx_value_too_wide
    |: direction_invalid
    |: role_collision
    |: (launch_falling ==: sample_falling)
    |: ~:pacing_valid
    |: (observed &: clock_present)
    |: (~:observed &: (half_period ==:. 0))
  in
  let transfer_conflict = (driven_mask &: (bank_software_claim |: i.occupied_i)) <>:. 0 in
  let bridge_idle = r.bridge_state.value ==:. Bridge_state.idle in
  let transfer_accept =
    issue_transfer
    &: ~:descriptor_invalid
    &: ~:transfer_conflict
    &: bridge_idle
    &: lane_ready
  in
  let transfer_refused_invalid = issue_transfer &: descriptor_invalid in
  let transfer_refused_conflict = issue_transfer &: ~:descriptor_invalid &: transfer_conflict in
  let transfer_refused_busy =
    issue_transfer
    &: ~:descriptor_invalid
    &: ~:transfer_conflict
    &: (~:bridge_idle |: ~:lane_ready)
  in
  let observed_edge =
    selected
      (mux
         r.bridge_pacing_edge.value
         [ events.rising_o; events.falling_o; events.rising_o |: events.falling_o; zero 8 ])
      r.bridge_pacing_pin.value
  in
  let lane =
    Shift_lane.create
      (Scope.sub_scope scope "lane")
      { Shift_lane.I.clock_i = i.clock_i
      ; reset_i = i.reset_i
      ; enable_i = i.en_i
      ; abort_i = i.abort_i
      ; start_valid_i = transfer_accept
      ; arm_i = gnd
      ; start_event_i = gnd
      ; bit_count_i = uresize (sel_bottom bit_count ~width:6) ~width:6
      ; tx_value_i = tx_value_32
      ; tx_valid_i = vdd
      ; rx_ready_i = i.transfer_rx_ready_i
      ; tx_enable_i = tx_enable
      ; rx_enable_i = rx_enable
      ; lsb_first_i = lsb_first
      ; output_pin_i = sel_bottom output_pin ~width:3
      ; input_pin_i = sel_bottom input_pin ~width:3
      ; clock_pin_i = sel_bottom clock_pin ~width:3
      ; clock_enable_i = clock_present &: ~:observed
      ; idle_output_i = idle_output
      ; idle_clock_i = idle_clock
      ; initial_delay_i = initial_delay
      ; half_period_i = half_period
      ; launch_trailing_i = launch_falling ^: idle_clock
      ; sample_trailing_i = sample_falling ^: idle_clock
      ; observed_i = observed
      ; observed_edge_i = observed_edge
      ; pin_in_i = events.snapshot_o
      ; occupied_i = i.occupied_i |: bank_software_claim
      }
  in
  assign lane_ready lane.ready_o;

  let lane_fault = lane.rejected_o |: lane.underrun_o |: lane.overrun_o in
  let lane_finished = lane.done_o |: lane_fault in
  let bridge_active = r.bridge_state.value ==:. Bridge_state.active in
  let bridge_releasing = r.bridge_state.value ==:. Bridge_state.release in
  let bridge_claim_request = transfer_accept &: (driven_mask <>:. 0) in
  let bridge_clear_request = bridge_active &: lane_finished &: (r.bridge_claim.value <>:. 0) in
  let bridge_write_request =
    bridge_active &: lane.busy_o &: ~:lane_finished &: (r.bridge_claim.value <>:. 0)
  in
  let bridge_release_request = bridge_releasing &: (r.bridge_claim.value <>:. 0) in
  let bridge_internal_request =
    bridge_claim_request |: bridge_clear_request |: bridge_write_request |: bridge_release_request
  in

  let pin_mask_value = sel_bottom i.mechanism_arg1_i ~width:8 in
  let pin_mask_valid = select i.mechanism_arg1_i ~high:15 ~low:8 ==:. 0 in
  let pin_write_conflict = (pin_mask_value &: bank_engine_claim) <>:. 0 in
  let core_pin_write_available = ~:bridge_internal_request in
  let pin_write_accept =
    write_pins &: pin_mask_valid &: ~:pin_write_conflict &: core_pin_write_available
  in
  let pin_write_refused =
    write_pins &: (~:pin_mask_valid |: pin_write_conflict)
  in
  let host_bank_request = i.software_claim_valid_i |: i.software_release_valid_i in
  let host_bank_allowed = ~:bridge_internal_request &: ~:pin_write_accept in
  let software_request_rejected = host_bank_request &: ~:host_bank_allowed in
  let bank =
    Pin_bank.create
      (Scope.sub_scope scope "bank")
      { Pin_bank.I.clock_i = i.clock_i
      ; reset_i = i.reset_i
      ; enable_i = i.en_i
      ; abort_i = i.abort_i
      ; claim_valid_i =
          bridge_claim_request |: (host_bank_allowed &: i.software_claim_valid_i)
      ; claim_engine_i = bridge_claim_request
      ; claim_mask_i = mux2 bridge_claim_request driven_mask i.software_claim_mask_i
      ; release_valid_i =
          bridge_release_request |: (host_bank_allowed &: i.software_release_valid_i)
      ; release_engine_i = bridge_release_request
      ; release_mask_i =
          mux2 bridge_release_request r.bridge_claim.value i.software_release_mask_i
      ; write_valid_i = bridge_write_request |: bridge_clear_request |: pin_write_accept
      ; write_engine_i = bridge_write_request |: bridge_clear_request
      ; write_mask_i =
          mux2
            (bridge_write_request |: bridge_clear_request)
            r.bridge_claim.value
            pin_mask_value
      ; write_value_i =
          mux2 bridge_write_request lane.pin_value_o
            (mux2 bridge_clear_request (zero 8) (sel_bottom i.mechanism_arg2_i ~width:8))
      ; write_open_drain_i =
          pin_write_accept &: bit i.mechanism_arg0_i ~pos:0
      ; write_oe_i =
          mux2 bridge_write_request lane.pin_oe_o
            (mux2 bridge_clear_request (zero 8)
               (mux2
                  (bit i.mechanism_arg0_i ~pos:0)
                  (pin_mask_value &: sel_bottom i.mechanism_arg2_i ~width:8)
                  pin_mask_value))
      }
  in
  assign bank_software_claim bank.software_claim_o;
  assign bank_engine_claim bank.engine_claim_o;
  let software_bank_rejected =
    host_bank_allowed
    &: ((i.software_claim_valid_i
         &: ((i.software_claim_mask_i &: bank_engine_claim) <>:. 0))
        |: (i.software_release_valid_i
            &: ((i.software_release_mask_i &: ~:bank_software_claim) <>:. 0))
        |: (i.software_claim_valid_i &: i.software_release_valid_i))
  in

  let immediate_accept =
    read_pins
    |: read_status
    |: ack_status
    |: branch_pin
    |: pin_write_accept
    |: immediate_level
    |: (start_periodic &: (i.mechanism_arg0_i <>:. 0))
    |: stop_periodic
    |: transfer_accept
    |: fifo_immediate
  in
  let accepted = immediate_accept |: wait_delayed_accept |: fifo_blocked_accept in
  let refused =
    wait_refused
    |: (start_periodic &: (i.mechanism_arg0_i ==:. 0))
    |: pin_write_refused
    |: transfer_refused_invalid
    |: transfer_refused_conflict
    |: transfer_refused_busy
    |: fifo_refused
  in
  let delayed_wait_completion =
    r.wait_pending.value
    &: (timing_complete |: timing_timeout)
    &: i.en_i
    &: ~:(i.reset_i)
    &: ~:(i.abort_i)
  in
  let completion = immediate_accept |: delayed_wait_completion |: pending_fifo_complete in
  let immediate_result =
    mux2 read_pins (uresize events.snapshot_o ~width:16)
      (mux2 read_status (uresize events.event_o ~width:16)
         (mux2 branch_pin (uresize (selected events.snapshot_o (sel_bottom i.mechanism_arg0_i ~width:3)
                                   ==: bit i.mechanism_arg1_i ~pos:0) ~width:16)
            (mux2 fifo_pop_request (uresize selected_pop_data ~width:16) (zero 16))))
  in
  let completion_result =
    mux2 pending_fifo_complete (uresize pending_fifo_pop_data ~width:16) immediate_result
  in
  let refusal_reason =
    mux2 fifo_invalid_data (const ~width:Reason.width Reason.data_out_of_range)
      (mux2 (fifo_refused &: fifo_push_request) (const ~width:Reason.width Reason.fifo_full)
         (mux2 (fifo_refused &: fifo_pop_request) (const ~width:Reason.width Reason.fifo_empty)
            (mux2 (pin_write_refused &: pin_write_conflict) (const ~width:Reason.width Reason.pin_conflict)
               (mux2 transfer_refused_conflict (const ~width:Reason.width Reason.pin_conflict)
                  (mux2 transfer_refused_busy (const ~width:Reason.width Reason.unavailable)
                     (const ~width:Reason.width Reason.invalid_parameter))))))
  in

  let ack_mask =
    mux2 (ack_status &: immediate_accept) (sel_bottom i.mechanism_arg0_i ~width:Event_kind.count) (zero Event_kind.count)
  in
  assign event_ack ack_mask;
  let event_bit index signal = mux2 signal (const ~width:Event_kind.count (1 lsl index)) (zero Event_kind.count) in
  let fifo_faults =
    concat_msb [ rx_fifo.starvation_o; rx_fifo.overflow_o; tx_fifo.starvation_o; tx_fifo.overflow_o ]
  in
  let new_fifo_fault = (fifo_faults &: ~:(r.fifo_faults.value)) <>:. 0 in
  let ownership_fault = pin_write_refused &: pin_write_conflict |: transfer_refused_conflict in
  let fault_event = ownership_fault |: lane_fault |: new_fifo_fault |: bank.rejected_o in
  let event_set_value =
    event_bit
      (Event_kind.index Delay_expired)
      (delayed_wait_completion &: timing_complete &: r.wait_is_delay.value)
    |: event_bit
         (Event_kind.index Wait_complete)
         (delayed_wait_completion &: timing_complete &: ~:(r.wait_is_delay.value))
    |: event_bit
         (Event_kind.index Wait_timeout)
         (delayed_wait_completion &: timing_timeout)
    |: event_bit (Event_kind.index Tick) timing_tick
    |: event_bit (Event_kind.index Aborted) i.abort_event_i
    |: event_bit (Event_kind.index Fault) fault_event
  in
  assign event_set event_set_value;

  compile
    [ r.wait_pending <-- r.wait_pending.value
    ; r.wait_is_delay <-- r.wait_is_delay.value
    ; r.wait_either <-- r.wait_either.value
    ; r.fifo_pending <-- r.fifo_pending.value
    ; r.fifo_push <-- r.fifo_push.value
    ; r.fifo_rx <-- r.fifo_rx.value
    ; r.fifo_data <-- r.fifo_data.value
    ; r.bridge_state <-- r.bridge_state.value
    ; r.bridge_claim <-- r.bridge_claim.value
    ; r.bridge_pacing_pin <-- r.bridge_pacing_pin.value
    ; r.bridge_pacing_edge <-- r.bridge_pacing_edge.value
    ; r.fifo_faults <-- fifo_faults
    ; when_ wait_delayed_accept
        [ r.wait_pending <--. 1
        ; r.wait_is_delay <-- wait_cycles
        ; r.wait_either <-- edge_either
        ]
    ; when_ delayed_wait_completion [ r.wait_pending <--. 0 ]
    ; when_ fifo_blocked_accept
        [ r.fifo_pending <--. 1
        ; r.fifo_push <-- fifo_push_request
        ; r.fifo_rx <-- request_fifo_rx
        ; r.fifo_data <-- sel_bottom i.mechanism_arg2_i ~width:8
        ]
    ; when_ pending_fifo_complete [ r.fifo_pending <--. 0 ]
    ; when_ transfer_accept
        [ r.bridge_state <--. Bridge_state.active
        ; r.bridge_claim <-- driven_mask
        ; r.bridge_pacing_pin <-- pacing_pin
        ; r.bridge_pacing_edge <-- pacing_edge
        ]
    ; when_ (bridge_active &: lane_finished)
        [ r.bridge_state
          <-- mux2 (r.bridge_claim.value ==:. 0)
                (const ~width:Bridge_state.width Bridge_state.idle)
                (const ~width:Bridge_state.width Bridge_state.release)
        ]
    ; when_ bridge_releasing
        [ r.bridge_state <--. Bridge_state.idle; r.bridge_claim <--. 0 ]
    ; when_ (i.abort_i |: ~:(i.en_i))
        [ r.wait_pending <--. 0
        ; r.fifo_pending <--. 0
        ; r.bridge_state <--. Bridge_state.idle
        ; r.bridge_claim <--. 0
        ; r.bridge_pacing_pin <--. 0
        ; r.bridge_pacing_edge <--. 0
        ]
    ];

  let engines_idle =
    ~:(r.wait_pending.value)
    &: ~:(timing.busy_o)
    &: ~:(r.fifo_pending.value)
    &: (r.bridge_state.value ==:. Bridge_state.idle)
    &: ~:(lane.busy_o)
    &: ~:(lane.armed_o)
    &: (bank.engine_claim_o ==:. 0)
    &: ~:bridge_internal_request
  in
  { O.mechanism_accepted_o = accepted
  ; mechanism_refused_o = refused
  ; mechanism_refusal_reason_o = refusal_reason
  ; mechanism_completion_valid_o = completion
  ; mechanism_completion_result_o = completion_result
  ; mechanism_completion_fault_o = gnd
  ; mechanism_completion_reason_o = const ~width:Reason.width Reason.none
  ; engines_idle_o = engines_idle
  ; snapshot_o = events.snapshot_o
  ; rising_o = events.rising_o
  ; falling_o = events.falling_o
  ; status_o = events.event_o
  ; status_overflow_o = events.overflow_o
  ; pins_o = bank.pins_o
  ; pin_oe_o = bank.pin_oe_o
  ; software_claim_o = bank.software_claim_o
  ; engine_claim_o = bank.engine_claim_o
  ; software_request_rejected_o = software_request_rejected |: software_bank_rejected
  ; bank_conflict_o = bank.conflict_o
  ; timing_busy_o = timing.busy_o
  ; transfer_busy_o = lane.busy_o |: lane.armed_o |: ~:bridge_idle
  ; transfer_done_o = lane.done_o
  ; transfer_fault_o = lane_fault
  ; transfer_rx_valid_o = lane.rx_valid_o
  ; transfer_rx_data_o = lane.rx_data_o
  ; tx_valid_o = tx_fifo.pop_valid_o &: ~:core_tx_pop
  ; tx_data_o = tx_fifo.pop_data_o
  ; rx_ready_o = rx_fifo.push_ready_o &: ~:core_rx_push
  ; tx_count_o = tx_fifo.count_o
  ; rx_count_o = rx_fifo.count_o
  }
;;
[@@@ocamlformat "enable"]
