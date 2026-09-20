(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "executable_core.ml" *)
(* P3.2 composition of program access and minimal control execution.

   The external memory port and all load/readback ownership remain Protocol_core's. The
   execution client receives only accepted RUN, fetch decisions, and owned completions.
   P3.3 supplies the mechanism responder through the exposed command interface.
*)

open! Core
open! Hardcaml
open! Signal

module I = struct
  type 'a t =
    { clock_i : 'a
    ; reset_i : 'a
    ; en_i : 'a
    ; engines_idle_i : 'a
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
    ; prog_mem_read_data_i : 'a [@bits Protocol_core.Config.program_width]
    ; mechanism_accepted_i : 'a
    ; mechanism_refused_i : 'a
    ; mechanism_refusal_reason_i : 'a
         [@bits Control_execution.Config.mechanism_reason_bits]
    ; mechanism_completion_valid_i : 'a
    ; mechanism_completion_result_i : 'a [@bits 16]
    ; mechanism_completion_fault_i : 'a
    ; mechanism_completion_reason_i : 'a
         [@bits Control_execution.Config.mechanism_reason_bits]
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
    ; run_accepted_o : 'a
    ; run_rejected_o : 'a
    ; readback_response_valid_o : 'a
    ; readback_response_data_o : 'a [@bits Protocol_core.Config.program_width]
    ; readback_response_match_o : 'a
    ; fetch_completion_valid_o : 'a
    ; fetch_completion_data_o : 'a [@bits Protocol_core.Config.program_width]
    ; fetch_response_valid_o : 'a
    ; fetch_response_data_o : 'a [@bits Protocol_core.Config.program_width]
    ; halted_o : 'a
    ; image_valid_o : 'a
    ; load_active_o : 'a
    ; image_length_o : 'a [@bits Protocol_core.Config.request_address_bits]
    ; words_written_o : 'a [@bits Protocol_core.Config.request_address_bits]
    ; words_verified_o : 'a [@bits Protocol_core.Config.request_address_bits]
    ; verification_failed_o : 'a
    ; fetch_fault_event_o : 'a
    ; fetch_fault_o : 'a
    ; mechanism_request_valid_o : 'a
    ; mechanism_kind_o : 'a [@bits Control_execution.Config.mechanism_kind_bits]
    ; mechanism_arg0_o : 'a [@bits 16]
    ; mechanism_arg1_o : 'a [@bits 16]
    ; mechanism_arg2_o : 'a [@bits 16]
    ; mechanism_timeout_enable_o : 'a
    ; mechanism_descriptor_o : 'a [@bits Control_execution.Config.descriptor_bits]
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
    }
  [@@deriving hardcaml]
end

let create (scope : Scope.t) (i : _ I.t) : _ O.t =
  let fetch_valid = wire 1 in
  let fetch_address = wire Protocol_core.Config.request_address_bits in
  let execution_halt = wire 1 in
  let access =
    Protocol_core.create
      (Scope.sub_scope scope "access")
      { Protocol_core.I.clock_i = i.clock_i
      ; reset_i = i.reset_i
      ; en_i = i.en_i
      ; engines_idle_i = i.engines_idle_i
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
      ; run_valid_i = i.run_valid_i
      ; execution_halt_i = execution_halt
      ; fetch_valid_i = fetch_valid
      ; fetch_address_i = fetch_address
      ; prog_mem_read_data_i = i.prog_mem_read_data_i
      }
  in
  let execution =
    Control_execution.create
      (Scope.sub_scope scope "execution")
      { Control_execution.I.clock_i = i.clock_i
      ; reset_i = i.reset_i
      ; en_i = i.en_i
      ; run_accepted_i = access.run_accepted_o
      ; fetch_accepted_i = access.fetch_accepted_o
      ; fetch_rejected_i = access.fetch_rejected_o
      ; fetch_fault_i = access.fetch_fault_event_o
      ; fetch_completion_valid_i = access.fetch_completion_valid_o
      ; fetch_completion_data_i = access.fetch_completion_data_o
      ; mechanism_accepted_i = i.mechanism_accepted_i
      ; mechanism_refused_i = i.mechanism_refused_i
      ; mechanism_refusal_reason_i = i.mechanism_refusal_reason_i
      ; mechanism_completion_valid_i = i.mechanism_completion_valid_i
      ; mechanism_completion_result_i = i.mechanism_completion_result_i
      ; mechanism_completion_fault_i = i.mechanism_completion_fault_i
      ; mechanism_completion_reason_i = i.mechanism_completion_reason_i
      }
  in
  assign fetch_valid execution.fetch_valid_o;
  assign fetch_address execution.fetch_address_o;
  assign execution_halt execution.execution_halt_o;
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
  ; run_accepted_o = access.run_accepted_o
  ; run_rejected_o = access.run_rejected_o
  ; readback_response_valid_o = access.readback_response_valid_o
  ; readback_response_data_o = access.readback_response_data_o
  ; readback_response_match_o = access.readback_response_match_o
  ; fetch_completion_valid_o = access.fetch_completion_valid_o
  ; fetch_completion_data_o = access.fetch_completion_data_o
  ; fetch_response_valid_o = access.fetch_response_valid_o
  ; fetch_response_data_o = access.fetch_response_data_o
  ; halted_o = access.halted_o
  ; image_valid_o = access.image_valid_o
  ; load_active_o = access.load_active_o
  ; image_length_o = access.image_length_o
  ; words_written_o = access.words_written_o
  ; words_verified_o = access.words_verified_o
  ; verification_failed_o = access.verification_failed_o
  ; fetch_fault_event_o = access.fetch_fault_event_o
  ; fetch_fault_o = access.fetch_fault_o
  ; mechanism_request_valid_o = execution.mechanism_request_valid_o
  ; mechanism_kind_o = execution.mechanism_kind_o
  ; mechanism_arg0_o = execution.mechanism_arg0_o
  ; mechanism_arg1_o = execution.mechanism_arg1_o
  ; mechanism_arg2_o = execution.mechanism_arg2_o
  ; mechanism_timeout_enable_o = execution.mechanism_timeout_enable_o
  ; mechanism_descriptor_o = execution.mechanism_descriptor_o
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
  }
;;
