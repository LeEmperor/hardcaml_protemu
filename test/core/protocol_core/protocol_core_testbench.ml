(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "protocol_core_testbench.ml" *)
(* Cycle product testbench for P3.1a.

   [Program_access] predicts control from scheduled inputs alone. The local RAM model
   independently implements only the external 1RW contract and deliberately varies values
   after writes and unwritten reads. No DUT acceptance or validity output feeds either
   model.
*)

open! Core
open! Hardcaml
open! Hardcaml_protemu
open! Protemu_f_model
module Sim = Cyclesim.With_interface (Protocol_core.I) (Protocol_core.O)

let width = Protocol_core.Config.program_width
let depth = Protocol_core.Config.program_depth

module Poison = struct
  type t =
    | Zero
    | Ones
    | Address
  [@@deriving sexp_of, compare, equal, enumerate]

  let value t ~address =
    match t with
    | Zero -> 0
    | Ones -> (1 lsl width) - 1
    | Address -> address * 257 lxor 0x5a5a land ((1 lsl width) - 1)
  ;;
end

module Program_store_stub = struct
  type t =
    { words : int option array
    ; poison : Poison.t
    ; mutable read_data : int
    }

  let create poison =
    { words = Array.create ~len:depth None
    ; poison
    ; read_data = Poison.value poison ~address:0
    }
  ;;

  let clock_edge t (port : Program_store.Port.t) =
    if port.enable
    then
      if port.write_enable
      then (
        t.words.(port.address) <- Some port.write_data;
        t.read_data <- Poison.value t.poison ~address:port.address)
      else
        t.read_data
        <- Option.value
             t.words.(port.address)
             ~default:(Poison.value t.poison ~address:port.address)
  ;;
end

type t =
  { sim : Sim.t
  ; store : Program_store_stub.t
  ; mutable model : Program_access.t
  ; mutable edge : int
  }

let bool signal = Bits.to_bool !signal
let int signal = Bits.to_int_trunc !signal
let set_bool signal value = signal := Bits.of_bool value
let set_int signal value = signal := Bits.of_int_trunc ~width:(Bits.width !signal) value

let port_of_outputs o : Program_store.Port.t =
  { enable = bool o.Protocol_core.O.prog_mem_enable_o
  ; write_enable = bool o.prog_mem_write_enable_o
  ; address = int o.prog_mem_address_o
  ; write_data = int o.prog_mem_write_data_o
  }
;;

let fail edge name =
  raise_s [%message "protocol-core mismatch" (edge : int) (name : string)]
;;

let check : 'a. int -> string -> 'a -> 'a -> unit =
  fun edge name expected actual -> if not (Poly.equal expected actual) then fail edge name
;;

let drive (i : _ Protocol_core.I.t) (input : Program_access.Input.t) =
  set_bool i.reset_i input.reset;
  set_bool i.en_i input.enable;
  set_bool i.engines_idle_i input.engines_idle;
  set_bool i.load_start_valid_i (Option.is_some input.load_start);
  set_int i.load_length_i (Option.value input.load_start ~default:0);
  set_bool i.load_write_valid_i (Option.is_some input.load_write);
  let load_address, load_data = Option.value input.load_write ~default:(0, 0) in
  set_int i.load_address_i load_address;
  set_int i.load_data_i load_data;
  set_bool i.load_complete_valid_i input.load_complete;
  set_bool i.readback_valid_i (Option.is_some input.readback);
  let read_address, verify, expected =
    Option.value input.readback ~default:(0, false, 0)
  in
  set_int i.readback_address_i read_address;
  set_bool i.readback_verify_i verify;
  set_int i.readback_expected_i expected;
  set_bool i.run_valid_i input.run;
  set_bool i.execution_halt_i input.execution_halt;
  set_bool i.fetch_valid_i (Option.is_some input.fetch);
  set_int i.fetch_address_i (Option.value input.fetch ~default:0)
;;

let check_decisions t input =
  let o = Cyclesim.outputs ~clock_edge:Before t.sim in
  let d = Program_access.decisions t.model input in
  let actual_port = port_of_outputs o in
  check t.edge "memory enable" d.port.enable actual_port.enable;
  if d.port.enable
  then (
    check t.edge "memory write enable" d.port.write_enable actual_port.write_enable;
    check t.edge "memory address" d.port.address actual_port.address;
    if d.port.write_enable
    then check t.edge "memory write data" d.port.write_data actual_port.write_data);
  check t.edge "load-start accepted" d.load_start_accepted (bool o.load_start_accepted_o);
  check
    t.edge
    "load-start rejected"
    (Option.is_some input.Program_access.Input.load_start && not d.load_start_accepted)
    (bool o.load_start_rejected_o);
  check t.edge "load-write accepted" d.load_write_accepted (bool o.load_write_accepted_o);
  check
    t.edge
    "load-write rejected"
    (Option.is_some input.load_write && not d.load_write_accepted)
    (bool o.load_write_rejected_o);
  check
    t.edge
    "load-complete accepted"
    d.load_complete_accepted
    (bool o.load_complete_accepted_o);
  check
    t.edge
    "load-complete rejected"
    (input.load_complete && not d.load_complete_accepted)
    (bool o.load_complete_rejected_o);
  check t.edge "readback accepted" d.readback_accepted (bool o.readback_accepted_o);
  check
    t.edge
    "readback rejected"
    (Option.is_some input.readback && not d.readback_accepted)
    (bool o.readback_rejected_o);
  check t.edge "run accepted" d.run_accepted (bool o.run_accepted_o);
  check t.edge "run rejected" (input.run && not d.run_accepted) (bool o.run_rejected_o);
  check t.edge "fetch accepted" d.fetch_accepted (bool o.fetch_accepted_o);
  check
    t.edge
    "fetch rejected"
    (Option.is_some input.fetch && not d.fetch_accepted)
    (bool o.fetch_rejected_o);
  d
;;

let check_state t =
  let o = Cyclesim.outputs t.sim in
  let m = t.model in
  check t.edge "halted" (Program_access.halted m) (bool o.halted_o);
  check t.edge "image valid" m.image_valid (bool o.image_valid_o);
  check t.edge "load active" m.load_active (bool o.load_active_o);
  check t.edge "image length" m.image_length (int o.image_length_o);
  check t.edge "words written" m.words_written (int o.words_written_o);
  check t.edge "words verified" m.words_verified (int o.words_verified_o);
  check t.edge "verification failed" m.verification_failed (bool o.verification_failed_o);
  check t.edge "fetch fault" m.fetch_fault (bool o.fetch_fault_o);
  check
    t.edge
    "read response valid"
    (Option.is_some m.response.readback)
    (bool o.readback_response_valid_o);
  Option.iter m.response.readback ~f:(fun (data, matches) ->
    check t.edge "read response data" data (int o.readback_response_data_o);
    check t.edge "read response match" matches (bool o.readback_response_match_o));
  check
    t.edge
    "fetch response valid"
    (Option.is_some m.response.fetch)
    (bool o.fetch_response_valid_o);
  Option.iter m.response.fetch ~f:(fun data ->
    check t.edge "fetch response data" data (int o.fetch_response_data_o))
;;

(* Drive, compare pre-edge decisions, advance DUT/model/RAM once, then compare registered
   state and responses. The model sees the RAM value that was present at the edge, before
   the current port operation updates the external output register. *)
let step t input =
  let i = Cyclesim.inputs t.sim in
  drive i input;
  Cyclesim.cycle_check t.sim;
  Cyclesim.cycle_before_clock_edge t.sim;
  let d = check_decisions t input in
  let read_data_at_edge = t.store.read_data in
  Cyclesim.cycle_at_clock_edge t.sim;
  Cyclesim.cycle_after_clock_edge t.sim;
  t.model <- Program_access.step t.model input ~read_data:read_data_at_edge;
  Program_store_stub.clock_edge t.store d.port;
  i.prog_mem_read_data_i := Bits.of_int_trunc ~width t.store.read_data;
  t.edge <- t.edge + 1;
  check_state t
;;

let create ?(poison = Poison.Zero) ?circuit () =
  let sim =
    match circuit with
    | None -> Sim.create (Protocol_core.create (Scope.create ~flatten_design:true ()))
    | Some circuit -> Sim.coerce (Cyclesim.create circuit)
  in
  let store = Program_store_stub.create poison in
  let t = { sim; store; model = Program_access.create; edge = 0 } in
  let i = Cyclesim.inputs sim in
  i.prog_mem_read_data_i := Bits.of_int_trunc ~width store.read_data;
  step t { Program_access.Input.idle with reset = true };
  t
;;

let input
  ?(reset = false)
  ?(enable = true)
  ?(engines_idle = true)
  ?load_start
  ?load_write
  ?(load_complete = false)
  ?readback
  ?(run = false)
  ?(execution_halt = false)
  ?fetch
  ()
  : Program_access.Input.t
  =
  { reset
  ; enable
  ; engines_idle
  ; load_start
  ; load_write
  ; load_complete
  ; readback
  ; run
  ; execution_halt
  ; fetch
  }
;;

let load_words t words =
  step t (input ~load_start:(List.length words) ());
  List.iteri words ~f:(fun address data -> step t (input ~load_write:(address, data) ()))
;;

let verify_words t words =
  List.iteri words ~f:(fun address expected ->
    step t (input ~readback:(address, true, expected) ());
    step t (input ()))
;;

let complete_load t words =
  load_words t words;
  verify_words t words;
  step t (input ~load_complete:true ())
;;

let memory_snapshot t = Array.copy t.store.words
