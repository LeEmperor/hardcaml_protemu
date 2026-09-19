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
module Program_store_model = struct
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
  Program_store_model.clock_edge
    store
    ~enable
    ~write_enable
    ~address:(int before.prog_mem_address_o)
    ~write_data:(int before.prog_mem_write_data_o);
  i.prog_mem_read_data_i := Bits.of_int_trunc ~width store.read_data
;;

let create () =
  let sim = Sim.create (Protocol_core.create (Scope.create ~flatten_design:true ())) in
  let store = Program_store_model.create () in
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

let%test_unit "fetch reads the program store through one latency-one port" =
  let sim, store = create () in
  let i = Cyclesim.inputs sim in
  let o = Cyclesim.outputs sim in
  check_output ~name:"halted after reset" o.halted_o 1;
  let program = [ 0x11; 0x22; 0x33; 0x44 ] in
  load sim store program;
  i.run_i := Bits.vdd;
  [%test_result: int list]
    ~expect:program
    (run_instructions sim store ~n:(List.length program))
    ~message:"instructions in program order"
;;

let%test_unit "RUN in the cycle of the last write never consumes its unspecified output" =
  let sim, store = create () in
  let i = Cyclesim.inputs sim in
  let o = Cyclesim.outputs sim in
  i.load_valid_i := Bits.vdd;
  i.load_address_i := Bits.of_int_trunc ~width:(Bits.width !(i.load_address_i)) 0;
  i.load_data_i := Bits.of_int_trunc ~width 0x5c;
  i.run_i := Bits.vdd;
  step sim store;
  i.load_valid_i := Bits.gnd;
  check_output ~name:"running after RUN" o.halted_o 0;
  [%test_result: int list]
    ~expect:[ 0x5c ]
    (run_instructions sim store ~n:1)
    ~message:"fresh read, not post-write output"
;;

let%test_unit "load requests are refused while running and STOP halts at a boundary" =
  let sim, store = create () in
  let i = Cyclesim.inputs sim in
  let o = Cyclesim.outputs sim in
  load sim store [ 0x5c; 0x6d ];
  i.run_i := Bits.vdd;
  step sim store;
  (* Hold a conflicting write request for the whole run; [step] fails if it reaches the
     port. *)
  i.load_valid_i := Bits.vdd;
  i.load_address_i := Bits.of_int_trunc ~width:(Bits.width !(i.load_address_i)) 0;
  i.load_data_i := Bits.of_int_trunc ~width 0x77;
  check_output ~name:"not ready while running" o.load_ready_o 0;
  [%test_result: int list]
    ~expect:[ 0x5c; 0x6d ]
    (run_instructions sim store ~n:2)
    ~message:"original words executed";
  check_output ~name:"still not ready while running" o.load_ready_o 0;
  [%test_result: int option]
    ~expect:(Some 0x5c)
    store.words.(0)
    ~message:"refused request left the store unchanged";
  i.load_valid_i := Bits.gnd;
  i.run_i := Bits.gnd;
  let rec wait_halted budget =
    if not (bool o.halted_o)
    then (
      if budget = 0 then raise_s [%message "STOP did not reach Idle_s"];
      step sim store;
      wait_halted (budget - 1))
  in
  wait_halted 4;
  check_output ~name:"ready again once halted" o.load_ready_o 1
;;
