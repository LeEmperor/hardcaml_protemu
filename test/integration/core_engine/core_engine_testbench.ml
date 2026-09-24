(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "core_engine_testbench.ml" *)
(* Loaded-program Cyclesim harness for the P3.3 integrated core and a contract-only
   latency-one program memory. External pins and queue peers remain test-controlled. *)

open! Core
open! Hardcaml
open! Hardcaml_protemu
open! Protemu_isa
module Sim = Cyclesim.With_interface (Integrated_core.I) (Integrated_core.O)

type request =
  | Idle
  | Reset
  | Enable of bool
  | Start of int
  | Write of int * int
  | Read of int
  | Verify of int * int
  | Complete
  | Run
  | Stop
  | Abort
  | Step
  | Controls of
      { run : bool
      ; stop : bool
      ; abort : bool
      ; step : bool
      }
  | Claim of int
  | Release of int

type t =
  { sim : Sim.t
  ; words : int option array
  ; mutable read_data : int
  ; mutable enabled : bool
  ; mutable pin_async : int
  ; mutable occupied : int
  ; mutable tx_ready : bool
  ; mutable rx_valid : bool
  ; mutable rx_data : int
  ; mutable transfer_rx_ready : bool
  ; mutable edge : int
  }

let bool signal = Bits.to_bool !signal
let int signal = Bits.to_int_trunc !signal
let set_bool signal value = signal := Bits.of_bool value
let set_int signal value = signal := Bits.of_int_trunc ~width:(Bits.width !signal) value
let outputs t = Cyclesim.outputs t.sim
let outputs_before t = Cyclesim.outputs ~clock_edge:Before t.sim

let clear_inputs (i : _ Integrated_core.I.t) =
  set_bool i.reset_i false;
  set_bool i.en_i true;
  set_bool i.load_start_valid_i false;
  set_int i.load_length_i 0;
  set_bool i.load_write_valid_i false;
  set_int i.load_address_i 0;
  set_int i.load_data_i 0;
  set_bool i.load_complete_valid_i false;
  set_bool i.readback_valid_i false;
  set_int i.readback_address_i 0;
  set_bool i.readback_verify_i false;
  set_int i.readback_expected_i 0;
  set_bool i.run_valid_i false;
  set_bool i.stop_valid_i false;
  set_bool i.abort_valid_i false;
  set_bool i.step_valid_i false;
  set_int i.pin_async_i 0;
  set_int i.occupied_i 0;
  set_bool i.software_claim_valid_i false;
  set_int i.software_claim_mask_i 0;
  set_bool i.software_release_valid_i false;
  set_int i.software_release_mask_i 0;
  set_bool i.tx_ready_i false;
  set_bool i.rx_valid_i false;
  set_int i.rx_data_i 0;
  set_bool i.transfer_rx_ready_i true
;;

let drive_request (i : _ Integrated_core.I.t) = function
  | Idle -> ()
  | Reset -> set_bool i.reset_i true
  | Enable value -> set_bool i.en_i value
  | Start length ->
    set_bool i.load_start_valid_i true;
    set_int i.load_length_i length
  | Write (address, data) ->
    set_bool i.load_write_valid_i true;
    set_int i.load_address_i address;
    set_int i.load_data_i data
  | Read address ->
    set_bool i.readback_valid_i true;
    set_int i.readback_address_i address
  | Verify (address, expected) ->
    set_bool i.readback_valid_i true;
    set_int i.readback_address_i address;
    set_bool i.readback_verify_i true;
    set_int i.readback_expected_i expected
  | Complete -> set_bool i.load_complete_valid_i true
  | Run -> set_bool i.run_valid_i true
  | Stop -> set_bool i.stop_valid_i true
  | Abort -> set_bool i.abort_valid_i true
  | Step -> set_bool i.step_valid_i true
  | Controls { run; stop; abort; step } ->
    set_bool i.run_valid_i run;
    set_bool i.stop_valid_i stop;
    set_bool i.abort_valid_i abort;
    set_bool i.step_valid_i step
  | Claim mask ->
    set_bool i.software_claim_valid_i true;
    set_int i.software_claim_mask_i mask
  | Release mask ->
    set_bool i.software_release_valid_i true;
    set_int i.software_release_mask_i mask
;;

let settle sim =
  Cyclesim.cycle_check sim;
  Cyclesim.cycle_before_clock_edge sim
;;

let step ?before t request =
  let i = Cyclesim.inputs t.sim in
  clear_inputs i;
  set_bool i.en_i t.enabled;
  set_int i.pin_async_i t.pin_async;
  set_int i.occupied_i t.occupied;
  set_bool i.tx_ready_i t.tx_ready;
  set_bool i.rx_valid_i t.rx_valid;
  set_int i.rx_data_i t.rx_data;
  set_bool i.transfer_rx_ready_i t.transfer_rx_ready;
  drive_request i request;
  (match request with
   | Enable value -> t.enabled <- value
   | _ -> ());
  settle t.sim;
  let o = outputs_before t in
  let mem_enable = bool o.prog_mem_enable_o in
  let mem_write = bool o.prog_mem_write_enable_o in
  let address = int o.prog_mem_address_o in
  let write_data = int o.prog_mem_write_data_o in
  Option.iter before ~f:(fun f -> f t.edge o);
  Cyclesim.cycle_at_clock_edge t.sim;
  Cyclesim.cycle_after_clock_edge t.sim;
  if mem_enable
  then
    if mem_write
    then (
      t.words.(address) <- Some write_data;
      t.read_data <- 0xdead)
    else t.read_data <- Option.value t.words.(address) ~default:0xbeef;
  i.prog_mem_read_data_i := Bits.of_int_trunc ~width:16 t.read_data;
  t.edge <- t.edge + 1
;;

let create () =
  let sim = Sim.create (Integrated_core.create (Scope.create ~flatten_design:true ())) in
  let t =
    { sim
    ; words = Array.create ~len:Protocol_core.Config.program_depth None
    ; read_data = 0xa5a5
    ; enabled = true
    ; pin_async = 0
    ; occupied = 0
    ; tx_ready = false
    ; rx_valid = false
    ; rx_data = 0
    ; transfer_rx_ready = true
    ; edge = 0
    }
  in
  let i = Cyclesim.inputs sim in
  i.prog_mem_read_data_i := Bits.of_int_trunc ~width:16 t.read_data;
  step t Reset;
  t
;;

let load_image t words =
  step t (Start (Array.length words));
  Array.iteri words ~f:(fun address data -> step t (Write (address, data)));
  Array.iteri words ~f:(fun address expected ->
    step t (Verify (address, expected));
    step t Idle);
  step t Complete
;;

let assemble program =
  match Assembler.assemble ~memory:Assembler.Memory.word16 program with
  | Ok assembled -> assembled
  | Error reason -> raise_s [%message "assembly failed" (reason : Invalid.t)]
;;

let load_program t program =
  let assembled = assemble program in
  load_image t assembled.image.words;
  assembled
;;

let run_until_halted ?(limit = 1000) t =
  step t Run;
  let rec loop cycles =
    if cycles >= limit then raise_s [%message "execution did not halt" (limit : int)];
    if bool (outputs t).halted_o
    then cycles
    else (
      step t Idle;
      loop (cycles + 1))
  in
  loop 0
;;

let program name instructions =
  { Program.name
  ; items = List.map instructions ~f:(fun instruction -> Program.instr instruction)
  }
;;
