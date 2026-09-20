open! Core
open! Hardcaml
open! Protocol_core_testbench

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

let%test_unit "a disabled core holds fetch state and resumes without consuming memory" =
  let sim, store = create () in
  let i = Cyclesim.inputs sim in
  let o = Cyclesim.outputs sim in
  load sim store [ 0x31; 0x42 ];
  i.run_i := Bits.vdd;
  step sim store;
  (* The core is now in Fetch_s. Disabling it gates both the state registers and the
     external memory port, so a pause cannot accidentally consume a read response. *)
  i.en_i := Bits.gnd;
  let held_pc = int o.pc_o in
  let held_instruction = int o.instruction_o in
  for _ = 1 to 3 do
    step sim store;
    check_output ~name:"PC held while disabled" o.pc_o held_pc;
    check_output ~name:"instruction held while disabled" o.instruction_o held_instruction;
    check_output ~name:"memory port disabled" o.prog_mem_enable_o 0
  done;
  i.en_i := Bits.vdd;
  step sim store;
  step sim store;
  check_output ~name:"the interrupted fetch completes after resume" o.instruction_o 0x31;
  check_output ~name:"one fetch advanced the PC once" o.pc_o 1
;;

let%test_unit "reset interrupts execution and halted loading recovers the core" =
  let sim, store = create () in
  let i = Cyclesim.inputs sim in
  let o = Cyclesim.outputs sim in
  load sim store [ 0x11; 0x22 ];
  i.run_i := Bits.vdd;
  step sim store;
  step sim store;
  i.reset_i := Bits.vdd;
  step sim store;
  check_output ~name:"reset returns to halted" o.halted_o 1;
  check_output ~name:"reset returns the PC to zero" o.pc_o 0;
  check_output ~name:"reset suppresses the memory port" o.prog_mem_enable_o 0;
  i.reset_i := Bits.gnd;
  i.run_i := Bits.gnd;
  load sim store [ 0x7e ];
  i.run_i := Bits.vdd;
  [%test_result: int list]
    ~expect:[ 0x7e ]
    (run_instructions sim store ~n:1)
    ~message:"a replacement word executes after reset recovery"
;;

let%test_unit "a load held across disable is accepted only after re-enable" =
  let sim, store = create () in
  let i = Cyclesim.inputs sim in
  let o = Cyclesim.outputs sim in
  i.en_i := Bits.gnd;
  i.load_valid_i := Bits.vdd;
  i.load_address_i := Bits.of_int_trunc ~width:(Bits.width !(i.load_address_i)) 7;
  i.load_data_i := Bits.of_int_trunc ~width 0x6b;
  step sim store;
  check_output ~name:"disabled loader is not ready" o.load_ready_o 0;
  [%test_result: int option]
    ~expect:None
    store.words.(7)
    ~message:"disabled request did not write";
  i.en_i := Bits.vdd;
  step sim store;
  check_output ~name:"halted loader is ready after re-enable" o.load_ready_o 1;
  [%test_result: int option]
    ~expect:(Some 0x6b)
    store.words.(7)
    ~message:"the still-valid request was accepted after re-enable"
;;
