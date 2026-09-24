(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "control_execution_model_tests.ml" *)
(* Independent whole-program comparisons for every P3.2-local instruction. The reference
   core shares only the ISA declaration with RTL and supplies architectural results and
   fetch/execute cycle counts. *)

open! Core
open! Hardcaml
open! Hardcaml_protemu
open! Protemu_isa
open! Protemu_f_model
open! Control_execution_testbench

let unwrap = function
  | Ok value -> value
  | Error reason -> raise_s [%message "program invalid" (reason : Invalid.t)]
;;

let program name instructions =
  Program.create
    ~name
    (List.map instructions ~f:(fun instruction -> Program.Item.Instr instruction))
  |> unwrap
;;

let quiet_board = { Firmware.Board.initial = (); next = (fun () _machine -> (), 0) }

let descriptor_words (d : Descriptor.t) =
  [ d.control
  ; d.bit_count
  ; d.tx_value
  ; d.output_pin
  ; d.input_pin
  ; d.clock_pin
  ; d.initial_delay
  ; d.half_period
  ; d.pacing
  ]
;;

let retirement_of_reference (r : Control_core.Retirement.t) =
  { Control_execution_testbench.regs = r.regs
  ; zero = r.flags.zero
  ; carry = r.flags.carry
  ; negative = r.flags.negative
  ; descriptor = descriptor_words r.descriptor
  ; fetch_cycles = r.counts.fetch_cycles
  ; execute_cycles = r.counts.execute_cycles
  ; instruction_count = r.counts.instructions
  }
;;

let rtl_descriptor t =
  let bits = !((outputs t).descriptor_o) in
  List.init Descriptor.Field.count ~f:(fun index ->
    Bits.select bits ~high:((index * 16) + 15) ~low:(index * 16) |> Bits.to_int_trunc)
;;

let run_reference program =
  match Control_core.run quiet_board program with
  | Ok trace -> trace
  | Error reason -> raise_s [%message "reference assembly failed" (reason : Invalid.t)]
;;

let compare_program program =
  let reference = run_reference program in
  let t = create () in
  ignore (load_program t program : Assembler.Assembled.t);
  let measured_cycles = run_until_halted ~limit:200_000 t () in
  let o = outputs t in
  [%test_eq: Control_core.Outcome.t] reference.outcome Halted;
  List.iteri reference.regs ~f:(fun index expected ->
    [%test_result: int] (reg t index) ~expect:expected);
  [%test_result: bool] (bool o.zero_o) ~expect:reference.flags.zero;
  [%test_result: bool] (bool o.carry_o) ~expect:reference.flags.carry;
  [%test_result: bool] (bool o.negative_o) ~expect:reference.flags.negative;
  [%test_result: int list]
    (rtl_descriptor t)
    ~expect:(descriptor_words reference.descriptor);
  [%test_result: int] (int o.fetch_cycles_o) ~expect:reference.counts.fetch_cycles;
  [%test_result: int] (int o.execute_cycles_o) ~expect:reference.counts.execute_cycles;
  [%test_result: int] (int o.stall_cycles_o) ~expect:reference.counts.stall_cycles;
  [%test_result: int] (int o.instruction_count_o) ~expect:reference.counts.instructions;
  [%test_result: int]
    (int o.extension_fetches_o)
    ~expect:reference.counts.extension_fetches;
  [%test_result: int] (int o.total_cycles_o) ~expect:reference.counts.cycles;
  [%test_result: int] measured_cycles ~expect:reference.counts.cycles;
  [%test_result: Control_execution_testbench.retirement list]
    (retirements t)
    ~expect:(List.map reference.retirements ~f:retirement_of_reference);
  t
;;

let%test_unit "state, every ALU operation, compare, shifts, and descriptor state agree" =
  let open Instruction in
  let instructions =
    ref
      [ Ldi { rd = 0; value = 0xffff }
      ; Ldi { rd = 1; value = 1 }
      ; Mov { rd = 7; rs = 0 }
      ]
  in
  List.iter Alu_op.all ~f:(fun op ->
    instructions
    := !instructions @ [ Ldi { rd = 2; value = 0x55aa }; Alu { op; rd = 2; rs = 1 } ]);
  List.iter Alu_op.all ~f:(fun op ->
    instructions
    := !instructions
       @ [ Ldi { rd = 3; value = 0xaa55 }; Alu_imm { op; rd = 3; imm = 0x1234 } ]);
  instructions
  := !instructions
     @ [ Cmp { ra = 0; rb = 1 }
       ; Cmp_imm { ra = 1; imm = 1 }
       ; Shift { dir = Left; rd = 1; amount = 15 }
       ; Shift { dir = Right; rd = 1; amount = 15 }
       ];
  List.iteri Descriptor.Field.all ~f:(fun index field ->
    instructions := !instructions @ [ Config { field; value = 0x100 + index } ]);
  ignore
    (compare_program (program "local_state_and_alu" (!instructions @ [ Halt ]))
     : Control_execution_testbench.t)
;;

let flag_setup cond taken =
  let open Instruction in
  let open Cond in
  match cond, taken with
  | Zero, true
  | Not_zero, false
  | Not_carry, true
  | Carry, false
  | Not_negative, true
  | Negative, false ->
    [ Ldi { rd = 0; value = 0 }; Ldi { rd = 1; value = 0 }; Cmp { ra = 0; rb = 1 } ]
  | Zero, false
  | Not_zero, true
  | Carry, true
  | Not_carry, false
  | Negative, true
  | Not_negative, false ->
    [ Ldi { rd = 0; value = 0 }; Ldi { rd = 1; value = 1 }; Cmp { ra = 0; rb = 1 } ]
;;

let branch_program cond taken =
  let open Instruction in
  let name = sprintf "branch_%s_%b" (Sexp.to_string (Cond.sexp_of_t cond)) taken in
  Program.create
    ~name
    (List.map (flag_setup cond taken) ~f:(fun instruction ->
       Program.Item.Instr instruction)
     @ [ Instr (Branch { cond; target = "taken" })
       ; Instr (Ldi { rd = 2; value = 0x11 })
       ; Instr (Jump { target = "done" })
       ; Label "taken"
       ; Instr (Ldi { rd = 2; value = 0x22 })
       ; Label "done"
       ; Instr Halt
       ])
  |> unwrap
;;

let%test_unit "every flag condition takes and falls through" =
  List.iter Instruction.Cond.all ~f:(fun cond ->
    List.iter [ false; true ] ~f:(fun taken ->
      let t = compare_program (branch_program cond taken) in
      [%test_result: int] (reg t 2) ~expect:(if taken then 0x22 else 0x11)))
;;

let dbnz_program count =
  let open Instruction in
  if count = 0
  then
    Program.create
      ~name:"dbnz_zero"
      [ Instr (Ldi { rd = 0; value = 0 })
      ; Instr (Dbnz { rd = 0; target = "taken" })
      ; Instr Halt
      ; Label "taken"
      ; Instr Halt
      ]
    |> unwrap
  else
    Program.create
      ~name:[%string "dbnz_%{count#Int}"]
      [ Instr (Ldi { rd = 0; value = count })
      ; Label "loop"
      ; Instr (Dbnz { rd = 0; target = "loop" })
      ; Instr Halt
      ]
    |> unwrap
;;

let%test_unit "dbnz counts zero, one, and two agree and preserve flags" =
  List.iter [ 0; 1; 2 ] ~f:(fun count ->
    let t = compare_program (dbnz_program count) in
    [%test_result: int] (reg t 0) ~expect:(if count = 0 then 0xffff else 0))
;;

let%test_unit "jump, call, return, and computed jump agree" =
  let open Instruction in
  let p =
    Program.create
      ~name:"flow_and_call"
      [ Instr (Jump { target = "call" })
      ; Instr (Ldi { rd = 0; value = 0xdead })
      ; Label "call"
      ; Instr (Call { link = 7; target = "subroutine" })
      ; Instr (Ldi { rd = 1; value = 0x33 })
      ; Instr Halt
      ; Label "subroutine"
      ; Instr (Ldi { rd = 0; value = 0x22 })
      ; Instr (Jump_reg { rs = 7 })
      ]
    |> unwrap
  in
  let t = compare_program p in
  [%test_result: int] (reg t 0) ~expect:0x22;
  [%test_result: int] (reg t 1) ~expect:0x33;
  [%test_result: int] (reg t 7) ~expect:4
;;
