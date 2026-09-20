(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "control_execution_unit_tests.ml" *)
(* Directed loaded-program checks for P3.2's execution composition. *)

open! Core
open! Hardcaml_protemu
open! Protemu_isa
open! Control_execution_testbench

let unwrap = function
  | Ok value -> value
  | Error reason -> raise_s [%message "program invalid" (reason : Invalid.t)]
;;

let representative_program () =
  Program.create
    ~name:"p3_2_representative"
    [ Instr (Ldi { rd = 0; value = 0x1234 })
    ; Instr (Cmp_imm { ra = 0; imm = 0x1234 })
    ; Instr (Branch { cond = Zero; target = "target" })
    ; Instr (Ldi { rd = 2; value = 99 })
    ; Label "target"
    ; Instr (Ldi { rd = 1; value = 2 })
    ; Label "loop"
    ; Instr (Dbnz { rd = 1; target = "loop" })
    ; Instr Halt
    ]
  |> unwrap
;;

let%test_unit "extended arithmetic, taken branch, loop, and halt take sixteen cycles" =
  let t = create () in
  let assembled = load_program t (representative_program ()) in
  [%test_eq: int list]
    (Array.to_list assembled.image.words)
    [ 0x0880; 0x1234; 0x3080; 0x1234; 0x6001; 0x0a63; 0x0902; 0x71ff; 0x0000 ];
  let cycles = run_until_halted t () in
  let o = outputs t in
  [%test_eq: int] cycles 16;
  [%test_eq: int] (reg t 0) 0x1234;
  [%test_eq: int] (reg t 1) 0;
  [%test_eq: int] (reg t 2) 0;
  [%test_eq: bool] (bool o.zero_o) true;
  [%test_eq: bool] (bool o.carry_o) false;
  [%test_eq: bool] (bool o.negative_o) false;
  [%test_eq: int] (int o.pc_o) 8;
  [%test_eq: int] (int o.fetch_cycles_o) 9;
  [%test_eq: int] (int o.execute_cycles_o) 7;
  [%test_eq: int] (int o.stall_cycles_o) 0;
  [%test_eq: int] (int o.instruction_count_o) 7;
  [%test_eq: int] (int o.extension_fetches_o) 2;
  [%test_eq: int] (int o.total_cycles_o) 16;
  [%test_eq: bool] (bool o.normal_halt_o) true;
  [%test_eq: bool] (bool o.execution_fault_o) false
;;
