(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "loader_core.ml" *)
(* P3.5 composition of the fixed serial loader and the firmware-independent core.

   Program RAM remains an external latency-one 1RW port so the behavioral core stays
   independent of ASIC infrastructure. The production project supplies the registered
   resource at this boundary. The loader and core connect through the three [Control_port]
   records; the core's step, pin-claim, and queue ports are tied off.
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
  (* The loader's requests are wired back into the core that decides them. *)
  let request = Control_port.Request.Of_signal.wires () in
  let core =
    Integrated_core.create
      (Scope.sub_scope scope "core")
      { Integrated_core.I.clock_i = i.clock_i
      ; reset_i = i.reset_i
      ; en_i = i.enable_i
      ; control_request_i = request
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
      ; control_decision_i = core.control_decision_o
      ; control_status_i = Integrated_core.control_status core
      }
  in
  Control_port.Request.Of_signal.assign request loader.control_request_o;
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
