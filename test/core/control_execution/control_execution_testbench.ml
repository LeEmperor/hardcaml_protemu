(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "control_execution_testbench.ml" *)
(* Loaded-program testbench for the executable P3.2 composition and a contract-only
   latency-one memory. Mechanism inputs are scheduled explicitly by each test. *)

open! Core
open! Hardcaml
open! Hardcaml_protemu
open! Protemu_isa
module Sim = Cyclesim.With_interface (Executable_core.I) (Executable_core.O)

type mechanism =
  { accepted : bool
  ; refused : bool
  ; refusal_reason : int
  ; completion : bool
  ; result : int
  ; completion_fault : bool
  ; completion_reason : int
  }

let quiet_mechanism =
  { accepted = false
  ; refused = false
  ; refusal_reason = 0
  ; completion = false
  ; result = 0
  ; completion_fault = false
  ; completion_reason = 0
  }
;;

type request =
  | Idle
  | Reset
  | Enable of bool
  | Start of int
  | Write of int * int
  | Verify of int * int
  | Complete
  | Run

type retirement =
  { regs : int list
  ; zero : bool
  ; carry : bool
  ; negative : bool
  ; descriptor : int list
  ; fetch_cycles : int
  ; execute_cycles : int
  ; instruction_count : int
  }
[@@deriving sexp_of, compare, equal]

type t =
  { sim : Sim.t
  ; words : int option array
  ; mutable read_data : int
  ; mutable enabled : bool
  ; mutable edge : int
  ; mutable retirements : retirement list
  }

let bool signal = Bits.to_bool !signal
let int signal = Bits.to_int_trunc !signal
let set_bool signal value = signal := Bits.of_bool value
let set_int signal value = signal := Bits.of_int_trunc ~width:(Bits.width !signal) value
let outputs t = Cyclesim.outputs t.sim
let outputs_before t = Cyclesim.outputs ~clock_edge:Before t.sim

let words_of_bits bits count =
  List.init count ~f:(fun index ->
    Bits.select bits ~high:((index * 16) + 15) ~low:(index * 16) |> Bits.to_int_trunc)
;;

let clear_inputs (i : _ Executable_core.I.t) =
  set_bool i.reset_i false;
  set_bool i.en_i true;
  set_bool i.engines_idle_i true;
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
  set_bool i.mechanism_accepted_i false;
  set_bool i.mechanism_refused_i false;
  set_int i.mechanism_refusal_reason_i 0;
  set_bool i.mechanism_completion_valid_i false;
  set_int i.mechanism_completion_result_i 0;
  set_bool i.mechanism_completion_fault_i false;
  set_int i.mechanism_completion_reason_i 0
;;

let drive_request (i : _ Executable_core.I.t) = function
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
  | Verify (address, expected) ->
    set_bool i.readback_valid_i true;
    set_int i.readback_address_i address;
    set_bool i.readback_verify_i true;
    set_int i.readback_expected_i expected
  | Complete -> set_bool i.load_complete_valid_i true
  | Run -> set_bool i.run_valid_i true
;;

let drive_mechanism (i : _ Executable_core.I.t) m =
  set_bool i.mechanism_accepted_i m.accepted;
  set_bool i.mechanism_refused_i m.refused;
  set_int i.mechanism_refusal_reason_i m.refusal_reason;
  set_bool i.mechanism_completion_valid_i m.completion;
  set_int i.mechanism_completion_result_i m.result;
  set_bool i.mechanism_completion_fault_i m.completion_fault;
  set_int i.mechanism_completion_reason_i m.completion_reason
;;

let settle sim =
  Cyclesim.cycle_check sim;
  Cyclesim.cycle_before_clock_edge sim
;;

let step ?(mechanism = quiet_mechanism) ?respond t request =
  let i = Cyclesim.inputs t.sim in
  clear_inputs i;
  set_bool i.en_i t.enabled;
  drive_request i request;
  (match request with
   | Enable value -> t.enabled <- value
   | _ -> ());
  drive_mechanism i mechanism;
  settle t.sim;
  Option.iter respond ~f:(fun f ->
    drive_mechanism i (f t (outputs_before t));
    settle t.sim);
  let o = outputs_before t in
  let mem_enable = bool o.prog_mem_enable_o in
  let mem_write = bool o.prog_mem_write_enable_o in
  let address = int o.prog_mem_address_o in
  let write_data = int o.prog_mem_write_data_o in
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
  let post = outputs t in
  if bool post.retired_o
  then
    t.retirements
    <- { regs = words_of_bits !(post.registers_o) 8
       ; zero = bool post.zero_o
       ; carry = bool post.carry_o
       ; negative = bool post.negative_o
       ; descriptor = words_of_bits !(post.descriptor_o) Descriptor.Field.count
       ; fetch_cycles = int post.fetch_cycles_o
       ; execute_cycles = int post.execute_cycles_o
       ; instruction_count = int post.instruction_count_o
       }
       :: t.retirements;
  t.edge <- t.edge + 1
;;

let create () =
  let sim = Sim.create (Executable_core.create (Scope.create ~flatten_design:true ())) in
  let t =
    { sim
    ; words = Array.create ~len:Protocol_core.Config.program_depth None
    ; read_data = 0xa5a5
    ; enabled = true
    ; edge = 0
    ; retirements = []
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

let run_until_halted ?(limit = 1000) ?respond t () =
  step t Run;
  let rec loop cycles =
    if cycles >= limit then raise_s [%message "execution did not halt" (limit : int)];
    let o = outputs t in
    if bool o.halted_o
    then cycles
    else (
      ignore o;
      step ?respond t Idle;
      loop (cycles + 1))
  in
  loop 0
;;

let reg t index =
  let bits = !((outputs t).registers_o) in
  Bits.select bits ~high:((index * 16) + 15) ~low:(index * 16) |> Bits.to_int_trunc
;;

let retirements t = List.rev t.retirements
