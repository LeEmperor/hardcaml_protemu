(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "protemu_top.ml" *)
(*
  Owning toplevel of the protocol emulator system with the emulator core; Has an external program-memory port that the owning chip_top instantiates connected to this item.

  Composition only; it holds no state, decodes no frames, and owns no RAM.

  Logical interfaces:
  - Serial host link: [serial_select_n_i], [serial_clock_i], [serial_data_i] in;
    [serial_data_o], [serial_ready_o] out. Passed straight to [Host_link].
  - Program memory: the external latency-one 1RW port, [prog_mem_*]. [Emulator_core]
    drives the request side and consumes [prog_mem_read_data_i]; the package top
    supplies the storage resource at this boundary.
  - Protocol pins: [pin_async_i], [occupied_i] in; [pins_o], [pin_oe_o] out, owned by
    [Emulator_core]'s mechanisms.
  - Internal only: [Host_link] and [Emulator_core] connect through the three
    [Control_port] records (request, decision, status).

  Unused tie-offs on [Emulator_core]: single-step, software pin claim/release, and the
  TX/RX byte queues are inactive (valid low, masks and data zero, [tx_ready_i] low);
  [transfer_rx_ready_i] is held high (always ready).

  Emitted instance names stay "core" and "loader" (pre-rename compatibility surface; see
  docs/architecture_migration.md).
*)

open! Core
open! Hardcaml
open! Signal

[@@@ocamlformat "disable"]
module I = struct
  type 'a t =
    { clock_i               : 'a
    ; reset_i               : 'a
    ; enable_i              : 'a
    ; serial_select_n_i     : 'a
    ; serial_clock_i        : 'a
    ; serial_data_i         : 'a
    ; prog_mem_read_data_i  : 'a [@bits Program_memory_controller.Config.program_width]
    ; pin_async_i           : 'a [@bits Protemu_isa.Pins.count]
    ; occupied_i            : 'a [@bits Protemu_isa.Pins.count]
    }
  [@@deriving hardcaml]
end

module O = struct
  type 'a t =
    { serial_data_o           : 'a
    ; serial_ready_o          : 'a
    ; prog_mem_enable_o       : 'a
    ; prog_mem_write_enable_o : 'a
    ; prog_mem_address_o      : 'a [@bits Program_memory_controller.Config.program_address_bits]
    ; prog_mem_write_data_o   : 'a [@bits Program_memory_controller.Config.program_width]
    ; pins_o                  : 'a [@bits Protemu_isa.Pins.count]
    ; pin_oe_o                : 'a [@bits Protemu_isa.Pins.count]
    }
  [@@deriving hardcaml]
end

let create 
  (scope : Scope.t) 
  (i : _ I.t) 
  : _ O.t 
  =

  (* Forward-declare request items in a named bundle for use *)
  (* Create a named Signal.wire bundle out of the shape of Control_port.Request *)
  let request = Control_port.Request.Of_signal.wires () in

  (* this might need renaming as well? *)
  let core =
    Emulator_core.create
      (Scope.sub_scope scope "core")
      { Emulator_core.I.clock_i = i.clock_i
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

  let host_link =
    Host_link.create
      (Scope.sub_scope scope "loader")
      { Host_link.I.clock_i = i.clock_i
      ; reset_i = i.reset_i
      ; enable_i = i.enable_i
      ; serial_select_n_i = i.serial_select_n_i
      ; serial_clock_i = i.serial_clock_i
      ; serial_data_i = i.serial_data_i
      ; control_decision_i = core.control_decision_o
      ; control_status_i = Emulator_core.control_status core
      }
  in

  (* Knot-tying for forward declares *)
  Control_port.Request.Of_signal.assign request host_link.control_request_o;

  { O.
    serial_data_o           = host_link.serial_data_o
  ; serial_ready_o          = host_link.serial_ready_o
  ; prog_mem_enable_o       = core.prog_mem_enable_o
  ; prog_mem_write_enable_o = core.prog_mem_write_enable_o
  ; prog_mem_address_o      = core.prog_mem_address_o
  ; prog_mem_write_data_o   = core.prog_mem_write_data_o
  ; pins_o                  = core.pins_o
  ; pin_oe_o                = core.pin_oe_o
  }
[@@@ocamlformat "enable"]
;;
