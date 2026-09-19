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
open! Core
open! Hardcaml
open! Protocol_core_testbench
