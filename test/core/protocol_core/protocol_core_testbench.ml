open! Core
open! Hardcaml
open! Hardcaml_protemu
module Sim = Cyclesim.With_interface (Protocol_core.I) (Protocol_core.O)

let width = Protocol_core.Config.program_width
let depth = Protocol_core.Config.program_depth

(* Test-only stand-in for hardcaml_asic's [Single_port_ram], following its program-memory
   contract: latency-one reads, output held while disabled, and a poison value after a
   write or for a never-written word. It keeps these tests independent of the ASIC
   library. Test programs avoid the poison value, so consuming an unspecified output shows
   up as a wrong instruction. *)
module Program_store_stub = struct
  type t =
    { words : int option array
    ; mutable read_data : int
    }

  let poison = 0xaa
  let create () = { words = Array.create ~len:depth None; read_data = poison }

  let clock_edge t ~enable ~write_enable ~address ~write_data =
    if enable
    then
      if write_enable
      then (
        t.words.(address) <- Some write_data;
        t.read_data <- poison)
      else t.read_data <- Option.value t.words.(address) ~default:poison
  ;;
end

let bool signal = Bits.to_bool !signal
let int signal = Bits.to_int_trunc !signal

let check_output ~name signal expected =
  [%test_result: int] ~expect:expected (int signal) ~message:name
;;

(* One clock edge. The RAM model samples the port values the core drove before the edge,
   then presents its output for the next cycle. *)
let step (sim : Sim.t) store =
  let i = Cyclesim.inputs sim in
  let before = Cyclesim.outputs ~clock_edge:Before sim in
  Cyclesim.cycle sim;
  let enable = bool before.prog_mem_enable_o in
  let write_enable = bool before.prog_mem_write_enable_o in
  if enable && write_enable && not (bool before.halted_o)
  then raise_s [%message "program store written while running"];
  Program_store_stub.clock_edge
    store
    ~enable
    ~write_enable
    ~address:(int before.prog_mem_address_o)
    ~write_data:(int before.prog_mem_write_data_o);
  i.prog_mem_read_data_i := Bits.of_int_trunc ~width store.read_data
;;

let create () =
  let sim = Sim.create (Protocol_core.create (Scope.create ~flatten_design:true ())) in
  let store = Program_store_stub.create () in
  let i = Cyclesim.inputs sim in
  i.reset_i := Bits.vdd;
  i.en_i := Bits.vdd;
  step sim store;
  i.reset_i := Bits.gnd;
  sim, store
;;

let load (sim : Sim.t) store words =
  let i = Cyclesim.inputs sim in
  let o = Cyclesim.outputs sim in
  List.iteri words ~f:(fun address word ->
    check_output ~name:"ready to load while halted" o.load_ready_o 1;
    i.load_valid_i := Bits.vdd;
    i.load_address_i := Bits.of_int_trunc ~width:(Bits.width !(i.load_address_i)) address;
    i.load_data_i := Bits.of_int_trunc ~width word;
    step sim store);
  i.load_valid_i := Bits.gnd
;;

(* Step until [n] instructions have been captured, returning them in order. *)
let run_instructions (sim : Sim.t) store ~n =
  let o = Cyclesim.outputs sim in
  let rec loop ~budget captured previous_pc =
    if List.length captured = n
    then List.rev captured
    else if budget = 0
    then raise_s [%message "instructions not captured" (captured : int list)]
    else (
      step sim store;
      (* [pc_o] advances on the fetch edge; the instruction lands on the next edge. *)
      let pc = int o.pc_o in
      if pc <> previous_pc
      then (
        step sim store;
        loop ~budget:(budget - 1) (int o.instruction_o :: captured) pc)
      else loop ~budget:(budget - 1) captured previous_pc)
  in
  loop ~budget:(8 * n) [] (int o.pc_o)
;;
