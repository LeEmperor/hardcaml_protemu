(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "integrated_core.ml" *)
(* P3.3 production composition of program access, execution, and P2 mechanisms.

   Program RAM remains an external latency-one port. STOP pauses only at P3.2's existing
   instruction boundary, ABORT cancels immediately, and a step resumes preserved state for
   one instruction. Program access receives the adapter's real engine-idle indication.
*)

open! Core
open! Hardcaml
open! Signal

module I = struct
  type 'a t =
    { clock_i : 'a
    ; reset_i : 'a
    ; en_i : 'a
    ; load_start_valid_i : 'a
    ; load_length_i : 'a [@bits Protocol_core.Config.request_address_bits]
    ; load_write_valid_i : 'a
    ; load_address_i : 'a [@bits Protocol_core.Config.request_address_bits]
    ; load_data_i : 'a [@bits Protocol_core.Config.program_width]
    ; load_complete_valid_i : 'a
    ; readback_valid_i : 'a
    ; readback_address_i : 'a [@bits Protocol_core.Config.request_address_bits]
    ; readback_verify_i : 'a
    ; readback_expected_i : 'a [@bits Protocol_core.Config.program_width]
    ; run_valid_i : 'a
    ; stop_valid_i : 'a
    ; abort_valid_i : 'a
    ; step_valid_i : 'a
    ; prog_mem_read_data_i : 'a [@bits Protocol_core.Config.program_width]
    ; pin_async_i : 'a [@bits Protemu_isa.Pins.count]
    ; occupied_i : 'a [@bits Protemu_isa.Pins.count]
    ; software_claim_valid_i : 'a
    ; software_claim_mask_i : 'a [@bits Protemu_isa.Pins.count]
    ; software_release_valid_i : 'a
    ; software_release_mask_i : 'a [@bits Protemu_isa.Pins.count]
    ; tx_ready_i : 'a
    ; rx_valid_i : 'a
    ; rx_data_i : 'a [@bits 8]
    ; transfer_rx_ready_i : 'a
    }
  [@@deriving hardcaml]
end

module O = struct
  type 'a t =
    { prog_mem_enable_o : 'a
    ; prog_mem_write_enable_o : 'a
    ; prog_mem_address_o : 'a [@bits Protocol_core.Config.program_address_bits]
    ; prog_mem_write_data_o : 'a [@bits Protocol_core.Config.program_width]
    ; load_start_accepted_o : 'a
    ; load_start_rejected_o : 'a
    ; load_write_accepted_o : 'a
    ; load_write_rejected_o : 'a
    ; load_complete_accepted_o : 'a
    ; load_complete_rejected_o : 'a
    ; readback_accepted_o : 'a
    ; readback_rejected_o : 'a
    ; readback_response_valid_o : 'a
    ; readback_response_data_o : 'a [@bits Protocol_core.Config.program_width]
    ; readback_response_match_o : 'a
    ; run_accepted_o : 'a
    ; run_rejected_o : 'a
    ; stop_accepted_o : 'a
    ; stop_rejected_o : 'a
    ; abort_accepted_o : 'a
    ; abort_rejected_o : 'a
    ; step_accepted_o : 'a
    ; step_rejected_o : 'a
    ; halted_o : 'a
    ; engines_idle_o : 'a
    ; image_valid_o : 'a
    ; load_active_o : 'a
    ; image_length_o : 'a [@bits Protocol_core.Config.request_address_bits]
    ; words_written_o : 'a [@bits Protocol_core.Config.request_address_bits]
    ; words_verified_o : 'a [@bits Protocol_core.Config.request_address_bits]
    ; verification_failed_o : 'a
    ; fetch_fault_o : 'a
    ; execution_active_o : 'a
    ; normal_halt_o : 'a
    ; execution_fault_o : 'a
    ; fault_kind_o : 'a [@bits Control_execution.Fault.width]
    ; fault_instruction_slot_o : 'a [@bits Control_execution.Config.pc_bits]
    ; fault_address_o : 'a [@bits Control_execution.Config.pc_bits]
    ; fault_reason_o : 'a [@bits Control_execution.Config.mechanism_reason_bits]
    ; instruction_boundary_o : 'a
    ; retired_o : 'a
    ; pc_o : 'a [@bits Control_execution.Config.pc_bits]
    ; registers_o : 'a [@bits 128]
    ; zero_o : 'a
    ; carry_o : 'a
    ; negative_o : 'a
    ; descriptor_o : 'a [@bits Control_execution.Config.descriptor_bits]
    ; phase_o : 'a [@bits Control_execution.Phase.width]
    ; fetch_cycles_o : 'a [@bits Control_execution.Config.count_bits]
    ; execute_cycles_o : 'a [@bits Control_execution.Config.count_bits]
    ; stall_cycles_o : 'a [@bits Control_execution.Config.count_bits]
    ; instruction_count_o : 'a [@bits Control_execution.Config.count_bits]
    ; extension_fetches_o : 'a [@bits Control_execution.Config.count_bits]
    ; total_cycles_o : 'a [@bits Control_execution.Config.count_bits]
    ; mechanism_request_valid_o : 'a
    ; mechanism_kind_o : 'a [@bits Control_execution.Config.mechanism_kind_bits]
    ; mechanism_accepted_o : 'a
    ; mechanism_refused_o : 'a
    ; mechanism_completion_valid_o : 'a
    ; snapshot_o : 'a [@bits Protemu_isa.Pins.count]
    ; rising_o : 'a [@bits Protemu_isa.Pins.count]
    ; falling_o : 'a [@bits Protemu_isa.Pins.count]
    ; status_o : 'a [@bits Protemu_isa.Event_kind.count]
    ; status_overflow_o : 'a [@bits Protemu_isa.Event_kind.count]
    ; pins_o : 'a [@bits Protemu_isa.Pins.count]
    ; pin_oe_o : 'a [@bits Protemu_isa.Pins.count]
    ; software_claim_o : 'a [@bits Protemu_isa.Pins.count]
    ; engine_claim_o : 'a [@bits Protemu_isa.Pins.count]
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
    { stop_pending : 'a
    ; stepping     : 'a
    }
  [@@deriving hardcaml]
end

let create (scope : Scope.t) (i : _ I.t) : _ O.t =
  let open Always in
  let spec = Reg_spec.create ~clock:i.clock_i ~clear:i.reset_i () in
  let r = I_Regs.Of_always.reg spec in
  I_Regs.Of_always.apply_names ~prefix:"reg_" ~naming_op:(Scope.naming scope) r;

  let fetch_valid = wire 1 in
  let fetch_address = wire Protocol_core.Config.request_address_bits in
  let core_execution_halt = wire 1 in
  let execution_halt = wire 1 in
  let engine_idle = wire 1 in
  let execution_boundary = wire 1 in
  let execution_active = wire 1 in
  let execution_fault = wire 1 in
  let normal_halt = wire 1 in
  let mechanism_request = wire 1 in
  let mechanism_kind = wire Control_execution.Config.mechanism_kind_bits in
  let mechanism_arg0 = wire 16 in
  let mechanism_arg1 = wire 16 in
  let mechanism_arg2 = wire 16 in
  let mechanism_timeout = wire 1 in
  let mechanism_descriptor = wire Control_execution.Config.descriptor_bits in
  let mechanism_accepted = wire 1 in
  let mechanism_refused = wire 1 in
  let mechanism_refusal_reason = wire Control_execution.Config.mechanism_reason_bits in
  let mechanism_completion = wire 1 in
  let mechanism_result = wire 16 in
  let mechanism_completion_fault = wire 1 in
  let mechanism_completion_reason = wire Control_execution.Config.mechanism_reason_bits in

  let abort_offer = i.abort_valid_i &: i.en_i &: ~:(i.reset_i) in
  let stop_offer = i.stop_valid_i &: i.en_i &: ~:(i.reset_i) &: ~:abort_offer in
  let step_offer =
    i.step_valid_i
    &: i.en_i
    &: ~:(i.reset_i)
    &: ~:abort_offer
    &: ~:stop_offer
  in
  let run_offer =
    i.run_valid_i
    &: ~:abort_offer
    &: ~:stop_offer
    &: ~:(i.step_valid_i)
  in
  let access_run = wire 1 in
  let access =
    Protocol_core.create
      (Scope.sub_scope scope "access")
      { Protocol_core.I.clock_i = i.clock_i
      ; reset_i = i.reset_i
      ; en_i = i.en_i
      ; engines_idle_i = engine_idle
      ; load_start_valid_i = i.load_start_valid_i
      ; load_length_i = i.load_length_i
      ; load_write_valid_i = i.load_write_valid_i
      ; load_address_i = i.load_address_i
      ; load_data_i = i.load_data_i
      ; load_complete_valid_i = i.load_complete_valid_i
      ; readback_valid_i = i.readback_valid_i
      ; readback_address_i = i.readback_address_i
      ; readback_verify_i = i.readback_verify_i
      ; readback_expected_i = i.readback_expected_i
      ; run_valid_i = access_run
      ; execution_halt_i = execution_halt
      ; fetch_valid_i = fetch_valid
      ; fetch_address_i = fetch_address
      ; prog_mem_read_data_i = i.prog_mem_read_data_i
      }
  in
  let step_candidate =
    step_offer
    &: access.halted_o
    &: engine_idle
    &: ~:execution_fault
    &: ~:normal_halt
  in
  assign access_run (run_offer |: step_candidate);
  let run_accepted = access.run_accepted_o &: run_offer in
  let step_accepted = access.run_accepted_o &: step_candidate in
  let stop_accepted = stop_offer in
  let abort_accepted = abort_offer in

  let pause_for_stop = (r.stop_pending.value |: stop_accepted) &: execution_boundary in
  let pause_for_step = r.stepping.value &: execution_boundary in
  let pause = pause_for_stop |: pause_for_step in
  assign execution_halt (core_execution_halt |: abort_accepted |: pause);

  let execution =
    Control_execution.create
      (Scope.sub_scope scope "execution")
      { Control_execution.I.clock_i = i.clock_i
      ; reset_i = i.reset_i
      ; en_i = i.en_i
      ; run_accepted_i = run_accepted
      ; resume_i = step_accepted
      ; pause_i = pause
      ; abort_i = abort_accepted
      ; fetch_accepted_i = access.fetch_accepted_o
      ; fetch_rejected_i = access.fetch_rejected_o
      ; fetch_fault_i = access.fetch_fault_event_o
      ; fetch_completion_valid_i = access.fetch_completion_valid_o
      ; fetch_completion_data_i = access.fetch_completion_data_o
      ; mechanism_accepted_i = mechanism_accepted
      ; mechanism_refused_i = mechanism_refused
      ; mechanism_refusal_reason_i = mechanism_refusal_reason
      ; mechanism_completion_valid_i = mechanism_completion
      ; mechanism_completion_result_i = mechanism_result
      ; mechanism_completion_fault_i = mechanism_completion_fault
      ; mechanism_completion_reason_i = mechanism_completion_reason
      }
  in
  assign fetch_valid execution.fetch_valid_o;
  assign fetch_address execution.fetch_address_o;
  assign core_execution_halt execution.execution_halt_o;
  assign execution_boundary execution.instruction_boundary_o;
  assign execution_active execution.active_o;
  assign execution_fault execution.execution_fault_o;
  assign normal_halt execution.normal_halt_o;
  assign mechanism_request execution.mechanism_request_valid_o;
  assign mechanism_kind execution.mechanism_kind_o;
  assign mechanism_arg0 execution.mechanism_arg0_o;
  assign mechanism_arg1 execution.mechanism_arg1_o;
  assign mechanism_arg2 execution.mechanism_arg2_o;
  assign mechanism_timeout execution.mechanism_timeout_enable_o;
  assign mechanism_descriptor execution.mechanism_descriptor_o;

  let mechanisms =
    Core_mechanisms.create
      (Scope.sub_scope scope "mechanisms")
      { Core_mechanisms.I.clock_i = i.clock_i
      ; reset_i = i.reset_i
      ; en_i = i.en_i
      ; abort_i = abort_accepted
      ; abort_event_i = abort_accepted &: (execution_active |: ~:engine_idle)
      ; pin_async_i = i.pin_async_i
      ; occupied_i = i.occupied_i
      ; mechanism_request_valid_i = mechanism_request
      ; mechanism_kind_i = mechanism_kind
      ; mechanism_arg0_i = mechanism_arg0
      ; mechanism_arg1_i = mechanism_arg1
      ; mechanism_arg2_i = mechanism_arg2
      ; mechanism_timeout_enable_i = mechanism_timeout
      ; mechanism_descriptor_i = mechanism_descriptor
      ; software_claim_valid_i = i.software_claim_valid_i
      ; software_claim_mask_i = i.software_claim_mask_i
      ; software_release_valid_i = i.software_release_valid_i
      ; software_release_mask_i = i.software_release_mask_i
      ; tx_ready_i = i.tx_ready_i
      ; rx_valid_i = i.rx_valid_i
      ; rx_data_i = i.rx_data_i
      ; transfer_rx_ready_i = i.transfer_rx_ready_i
      }
  in
  assign engine_idle mechanisms.engines_idle_o;
  assign mechanism_accepted mechanisms.mechanism_accepted_o;
  assign mechanism_refused mechanisms.mechanism_refused_o;
  assign mechanism_refusal_reason mechanisms.mechanism_refusal_reason_o;
  assign mechanism_completion mechanisms.mechanism_completion_valid_o;
  assign mechanism_result mechanisms.mechanism_completion_result_o;
  assign mechanism_completion_fault mechanisms.mechanism_completion_fault_o;
  assign mechanism_completion_reason mechanisms.mechanism_completion_reason_o;

  compile
    [ r.stop_pending <-- r.stop_pending.value
    ; r.stepping <-- r.stepping.value
    ; when_ (stop_accepted &: ~:(access.halted_o)) [ r.stop_pending <--. 1 ]
    ; when_ step_accepted [ r.stepping <--. 1 ]
    ; when_ pause_for_stop [ r.stop_pending <--. 0 ]
    ; when_ pause_for_step [ r.stepping <--. 0 ]
    ; when_ (run_accepted |: abort_accepted |: ~:(i.en_i))
        [ r.stop_pending <--. 0; r.stepping <--. 0 ]
    ];

  { O.prog_mem_enable_o = access.prog_mem_enable_o
  ; prog_mem_write_enable_o = access.prog_mem_write_enable_o
  ; prog_mem_address_o = access.prog_mem_address_o
  ; prog_mem_write_data_o = access.prog_mem_write_data_o
  ; load_start_accepted_o = access.load_start_accepted_o
  ; load_start_rejected_o = access.load_start_rejected_o
  ; load_write_accepted_o = access.load_write_accepted_o
  ; load_write_rejected_o = access.load_write_rejected_o
  ; load_complete_accepted_o = access.load_complete_accepted_o
  ; load_complete_rejected_o = access.load_complete_rejected_o
  ; readback_accepted_o = access.readback_accepted_o
  ; readback_rejected_o = access.readback_rejected_o
  ; readback_response_valid_o = access.readback_response_valid_o
  ; readback_response_data_o = access.readback_response_data_o
  ; readback_response_match_o = access.readback_response_match_o
  ; run_accepted_o = run_accepted
  ; run_rejected_o = i.run_valid_i &: ~:run_accepted
  ; stop_accepted_o = stop_accepted
  ; stop_rejected_o = i.stop_valid_i &: ~:stop_accepted
  ; abort_accepted_o = abort_accepted
  ; abort_rejected_o = i.abort_valid_i &: ~:abort_accepted
  ; step_accepted_o = step_accepted
  ; step_rejected_o = i.step_valid_i &: ~:step_accepted
  ; halted_o = access.halted_o
  ; engines_idle_o = engine_idle
  ; image_valid_o = access.image_valid_o
  ; load_active_o = access.load_active_o
  ; image_length_o = access.image_length_o
  ; words_written_o = access.words_written_o
  ; words_verified_o = access.words_verified_o
  ; verification_failed_o = access.verification_failed_o
  ; fetch_fault_o = access.fetch_fault_o
  ; execution_active_o = execution.active_o
  ; normal_halt_o = execution.normal_halt_o
  ; execution_fault_o = execution.execution_fault_o
  ; fault_kind_o = execution.fault_kind_o
  ; fault_instruction_slot_o = execution.fault_instruction_slot_o
  ; fault_address_o = execution.fault_address_o
  ; fault_reason_o = execution.fault_reason_o
  ; instruction_boundary_o = execution.instruction_boundary_o
  ; retired_o = execution.retired_o
  ; pc_o = execution.pc_o
  ; registers_o = execution.registers_o
  ; zero_o = execution.zero_o
  ; carry_o = execution.carry_o
  ; negative_o = execution.negative_o
  ; descriptor_o = execution.descriptor_o
  ; phase_o = execution.phase_o
  ; fetch_cycles_o = execution.fetch_cycles_o
  ; execute_cycles_o = execution.execute_cycles_o
  ; stall_cycles_o = execution.stall_cycles_o
  ; instruction_count_o = execution.instruction_count_o
  ; extension_fetches_o = execution.extension_fetches_o
  ; total_cycles_o = execution.total_cycles_o
  ; mechanism_request_valid_o = mechanism_request
  ; mechanism_kind_o = mechanism_kind
  ; mechanism_accepted_o = mechanism_accepted
  ; mechanism_refused_o = mechanism_refused
  ; mechanism_completion_valid_o = mechanism_completion
  ; snapshot_o = mechanisms.snapshot_o
  ; rising_o = mechanisms.rising_o
  ; falling_o = mechanisms.falling_o
  ; status_o = mechanisms.status_o
  ; status_overflow_o = mechanisms.status_overflow_o
  ; pins_o = mechanisms.pins_o
  ; pin_oe_o = mechanisms.pin_oe_o
  ; software_claim_o = mechanisms.software_claim_o
  ; engine_claim_o = mechanisms.engine_claim_o
  ; software_request_rejected_o = mechanisms.software_request_rejected_o
  ; bank_conflict_o = mechanisms.bank_conflict_o
  ; timing_busy_o = mechanisms.timing_busy_o
  ; transfer_busy_o = mechanisms.transfer_busy_o
  ; transfer_done_o = mechanisms.transfer_done_o
  ; transfer_fault_o = mechanisms.transfer_fault_o
  ; transfer_rx_valid_o = mechanisms.transfer_rx_valid_o
  ; transfer_rx_data_o = mechanisms.transfer_rx_data_o
  ; tx_valid_o = mechanisms.tx_valid_o
  ; tx_data_o = mechanisms.tx_data_o
  ; rx_ready_o = mechanisms.rx_ready_o
  ; tx_count_o = mechanisms.tx_count_o
  ; rx_count_o = mechanisms.rx_count_o
  }
;;
[@@@ocamlformat "enable"]
