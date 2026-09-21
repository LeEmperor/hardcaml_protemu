(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "loader_core.ml" *)
(* P3.5 composition of the fixed serial loader and the firmware-independent core.

   Program RAM remains an external latency-one 1RW port so the behavioral core stays
   independent of ASIC infrastructure. The production project supplies the registered
   resource at this boundary.
*)

open! Core
open! Hardcaml
open! Signal

module I = struct
  type 'a t =
    { clock_i : 'a
    ; reset_i : 'a
    ; enable_i : 'a
    ; serial_select_n_i : 'a
    ; serial_clock_i : 'a
    ; serial_data_i : 'a
    ; prog_mem_read_data_i : 'a [@bits Protocol_core.Config.program_width]
    ; pin_async_i : 'a [@bits Protemu_isa.Pins.count]
    ; occupied_i : 'a [@bits Protemu_isa.Pins.count]
    }
  [@@deriving hardcaml]
end

module O = struct
  type 'a t =
    { serial_data_o : 'a
    ; serial_ready_o : 'a
    ; prog_mem_enable_o : 'a
    ; prog_mem_write_enable_o : 'a
    ; prog_mem_address_o : 'a [@bits Protocol_core.Config.program_address_bits]
    ; prog_mem_write_data_o : 'a [@bits Protocol_core.Config.program_width]
    ; pins_o : 'a [@bits Protemu_isa.Pins.count]
    ; pin_oe_o : 'a [@bits Protemu_isa.Pins.count]
    }
  [@@deriving hardcaml]
end

let create (scope : Scope.t) (i : _ I.t) : _ O.t =
  let load_start_valid = wire 1 in
  let load_length = wire Protocol_core.Config.request_address_bits in
  let load_write_valid = wire 1 in
  let load_address = wire Protocol_core.Config.request_address_bits in
  let load_data = wire Protocol_core.Config.program_width in
  let load_complete_valid = wire 1 in
  let readback_valid = wire 1 in
  let readback_address = wire Protocol_core.Config.request_address_bits in
  let readback_verify = wire 1 in
  let readback_expected = wire Protocol_core.Config.program_width in
  let run_valid = wire 1 in
  let stop_valid = wire 1 in
  let abort_valid = wire 1 in
  let core =
    Integrated_core.create
      (Scope.sub_scope scope "core")
      { Integrated_core.I.clock_i = i.clock_i
      ; reset_i = i.reset_i
      ; en_i = i.enable_i
      ; load_start_valid_i = load_start_valid
      ; load_length_i = load_length
      ; load_write_valid_i = load_write_valid
      ; load_address_i = load_address
      ; load_data_i = load_data
      ; load_complete_valid_i = load_complete_valid
      ; readback_valid_i = readback_valid
      ; readback_address_i = readback_address
      ; readback_verify_i = readback_verify
      ; readback_expected_i = readback_expected
      ; run_valid_i = run_valid
      ; stop_valid_i = stop_valid
      ; abort_valid_i = abort_valid
      ; step_valid_i = gnd
      ; prog_mem_read_data_i = i.prog_mem_read_data_i
      ; pin_async_i = i.pin_async_i
      ; occupied_i = i.occupied_i
      ; software_claim_valid_i = gnd
      ; software_claim_mask_i = zero Protemu_isa.Pins.count
      ; software_release_valid_i = gnd
      ; software_release_mask_i = zero Protemu_isa.Pins.count
      ; tx_ready_i = gnd
      ; rx_valid_i = gnd
      ; rx_data_i = zero 8
      ; transfer_rx_ready_i = vdd
      }
  in
  let loader =
    Hardware_loader.create
      (Scope.sub_scope scope "loader")
      { Hardware_loader.I.clock_i = i.clock_i
      ; reset_i = i.reset_i
      ; enable_i = i.enable_i
      ; serial_select_n_i = i.serial_select_n_i
      ; serial_clock_i = i.serial_clock_i
      ; serial_data_i = i.serial_data_i
      ; load_start_accepted_i = core.load_start_accepted_o
      ; load_start_rejected_i = core.load_start_rejected_o
      ; load_write_accepted_i = core.load_write_accepted_o
      ; load_write_rejected_i = core.load_write_rejected_o
      ; load_complete_accepted_i = core.load_complete_accepted_o
      ; load_complete_rejected_i = core.load_complete_rejected_o
      ; readback_accepted_i = core.readback_accepted_o
      ; readback_rejected_i = core.readback_rejected_o
      ; readback_response_valid_i = core.readback_response_valid_o
      ; readback_response_data_i = core.readback_response_data_o
      ; readback_response_match_i = core.readback_response_match_o
      ; run_accepted_i = core.run_accepted_o
      ; run_rejected_i = core.run_rejected_o
      ; stop_accepted_i = core.stop_accepted_o
      ; stop_rejected_i = core.stop_rejected_o
      ; abort_accepted_i = core.abort_accepted_o
      ; abort_rejected_i = core.abort_rejected_o
      ; halted_i = core.halted_o
      ; engines_idle_i = core.engines_idle_o
      ; image_valid_i = core.image_valid_o
      ; load_active_i = core.load_active_o
      ; image_length_i = core.image_length_o
      ; words_written_i = core.words_written_o
      ; words_verified_i = core.words_verified_o
      ; verification_failed_i = core.verification_failed_o
      ; fetch_fault_i = core.fetch_fault_o
      ; execution_active_i = core.execution_active_o
      ; normal_halt_i = core.normal_halt_o
      ; execution_fault_i = core.execution_fault_o
      ; fault_kind_i = core.fault_kind_o
      ; pc_i = core.pc_o
      ; phase_i = core.phase_o
      ; pin_oe_i = core.pin_oe_o
      ; software_claim_i = core.software_claim_o
      ; engine_claim_i = core.engine_claim_o
      }
  in
  assign load_start_valid loader.load_start_valid_o;
  assign load_length loader.load_length_o;
  assign load_write_valid loader.load_write_valid_o;
  assign load_address loader.load_address_o;
  assign load_data loader.load_data_o;
  assign load_complete_valid loader.load_complete_valid_o;
  assign readback_valid loader.readback_valid_o;
  assign readback_address loader.readback_address_o;
  assign readback_verify loader.readback_verify_o;
  assign readback_expected loader.readback_expected_o;
  assign run_valid loader.run_valid_o;
  assign stop_valid loader.stop_valid_o;
  assign abort_valid loader.abort_valid_o;
  { O.serial_data_o = loader.serial_data_o
  ; serial_ready_o = loader.serial_ready_o
  ; prog_mem_enable_o = core.prog_mem_enable_o
  ; prog_mem_write_enable_o = core.prog_mem_write_enable_o
  ; prog_mem_address_o = core.prog_mem_address_o
  ; prog_mem_write_data_o = core.prog_mem_write_data_o
  ; pins_o = core.pins_o
  ; pin_oe_o = core.pin_oe_o
  }
;;
