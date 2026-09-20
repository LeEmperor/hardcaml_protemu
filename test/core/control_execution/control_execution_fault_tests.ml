(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "control_execution_fault_tests.ml" *)
(* Invalid words, extension acquisition, target bounds, cancellation, and restart checks
   through the real P3.1a load/verify/RUN path. *)

open! Core
open! Hardcaml_protemu
open! Protemu_isa
open! Control_execution_testbench

let encode instruction =
  match Encoding.encode instruction with
  | Ok words -> words
  | Error reason -> raise_s [%message "encoding failed" (reason : Invalid.t)]
;;

let run_words words =
  let t = create () in
  load_image t (Array.of_list words);
  ignore (run_until_halted t () : int);
  t
;;

let check_fault t kind ~instruction_slot ~address =
  let o = outputs t in
  [%test_result: bool] (bool o.execution_fault_o) ~expect:true;
  [%test_result: bool] (bool o.normal_halt_o) ~expect:false;
  [%test_result: int] (int o.fault_kind_o) ~expect:kind;
  [%test_result: int] (int o.fault_instruction_slot_o) ~expect:instruction_slot;
  [%test_result: int] (int o.fault_address_o) ~expect:address
;;

let%test_unit "reserved opcode, spare bits, and invalid enum fault as base words" =
  List.iter [ 0xf800; 0x0001; 0x1f00 ] ~f:(fun word ->
    let t = run_words [ word ] in
    check_fault t Control_execution.Fault.invalid_base ~instruction_slot:0 ~address:0;
    let o = outputs t in
    [%test_result: int] (int o.fetch_cycles_o) ~expect:1;
    [%test_result: int] (int o.execute_cycles_o) ~expect:0;
    [%test_result: int] (int o.instruction_count_o) ~expect:0;
    [%test_result: int] (int o.total_cycles_o) ~expect:1)
;;

let%test_unit "invalid and truncated extensions fault without partial commit" =
  let base, _ =
    match
      encode
        (Instruction.Write_pins_imm
           { mode = Instruction.Pin_mode.Push_pull; mask = 1; value = 1 })
    with
    | [ base; extension ] -> base, extension
    | _ -> assert false
  in
  let invalid = run_words [ base; 0x0100 ] in
  check_fault
    invalid
    Control_execution.Fault.invalid_extension
    ~instruction_slot:0
    ~address:1;
  [%test_result: int] (int (outputs invalid).fetch_cycles_o) ~expect:2;
  [%test_result: int] (int (outputs invalid).execute_cycles_o) ~expect:0;
  let truncated = run_words [ base ] in
  check_fault
    truncated
    Control_execution.Fault.truncated_extension
    ~instruction_slot:0
    ~address:1;
  [%test_result: int] (int (outputs truncated).fetch_cycles_o) ~expect:1;
  [%test_result: int] (int (outputs truncated).execute_cycles_o) ~expect:0
;;

let%test_unit "negative, oversized, and loaded-image targets never wrap" =
  let negative_jump = List.hd_exn (encode (Instruction.Jump { target = -2 })) in
  let negative = run_words [ negative_jump ] in
  check_fault
    negative
    Control_execution.Fault.target_unrepresentable
    ~instruction_slot:0
    ~address:(-1 land 0x1ffff);
  [%test_result: int] (int (outputs negative).instruction_count_o) ~expect:1;
  let oversized =
    encode (Instruction.Ldi { rd = 0; value = 0xffff })
    @ encode (Instruction.Jump_reg { rs = 0 })
    @ encode Instruction.Halt
    |> run_words
  in
  check_fault
    oversized
    Control_execution.Fault.target_unrepresentable
    ~instruction_slot:2
    ~address:0xffff;
  let physical =
    encode (Instruction.Ldi { rd = 0; value = 256 })
    @ encode (Instruction.Jump_reg { rs = 0 })
    @ encode Instruction.Halt
    |> run_words
  in
  check_fault
    physical
    Control_execution.Fault.fetch_bounds
    ~instruction_slot:2
    ~address:256
;;

let%test_unit "sequential fallthrough beyond the verified image becomes a fetch fault" =
  let words = encode (Instruction.Mov { rd = 0; rs = 0 }) in
  let t = run_words words in
  check_fault t Control_execution.Fault.fetch_bounds ~instruction_slot:0 ~address:1;
  [%test_result: int] (int (outputs t).instruction_count_o) ~expect:1
;;

let%test_unit "accepted RUN is fresh and a disabled pending fetch is cancelled" =
  let t = create () in
  let words =
    encode (Instruction.Ldi { rd = 0; value = 0x1234 }) @ encode Instruction.Halt
  in
  load_image t (Array.of_list words);
  let first = run_until_halted t () in
  [%test_result: int] (reg t 0) ~expect:0x1234;
  let second = run_until_halted t () in
  [%test_result: int] second ~expect:first;
  [%test_result: int] (int (outputs t).total_cycles_o) ~expect:first;
  let cancelled = create () in
  load_image cancelled (Array.of_list words);
  step cancelled Run;
  step cancelled Idle;
  step cancelled (Enable false);
  [%test_result: bool] (bool (outputs cancelled).halted_o) ~expect:true;
  [%test_result: bool] (bool (outputs cancelled).image_valid_o) ~expect:true;
  [%test_result: bool] (bool (outputs cancelled).execution_fault_o) ~expect:false;
  step cancelled (Enable true);
  ignore (run_until_halted cancelled () : int);
  [%test_result: int] (reg cancelled 0) ~expect:0x1234
;;

let%test_unit "live host writes cannot steal autonomous fetches" =
  let t = create () in
  let words =
    encode (Instruction.Ldi { rd = 0; value = 0x1234 })
    @ encode (Instruction.Alu_imm { op = Add; rd = 0; imm = 1 })
    @ encode Instruction.Halt
  in
  load_image t (Array.of_list words);
  let before = Array.copy t.words in
  step t Run;
  let rec run cycles =
    if cycles > 100 then raise_s [%message "live-write execution did not halt"];
    if bool (outputs t).halted_o
    then cycles
    else (
      step t (Write (0, 0xdead));
      run (cycles + 1))
  in
  let cycles = run 0 in
  [%test_result: int] cycles ~expect:7;
  [%test_result: int] (reg t 0) ~expect:0x1235;
  [%test_result: bool] (Array.equal (Option.equal Int.equal) before t.words) ~expect:true
;;

let%test_unit "the first instruction can jump to the final physical image slot" =
  let open Instruction in
  let program =
    Program.create
      ~name:"last_slot"
      ([ Program.Item.Instr (Jump { target = "last" }) ]
       @ List.init 254 ~f:(fun _ -> Program.Item.Instr (Mov { rd = 0; rs = 0 }))
       @ [ Program.Item.Label "last"; Program.Item.Instr Halt ])
    |> function
    | Ok program -> program
    | Error reason -> raise_s [%message "program invalid" (reason : Invalid.t)]
  in
  let t = create () in
  let assembled = load_program t program in
  [%test_result: int] assembled.size.memory_words ~expect:256;
  let cycles = run_until_halted t () in
  [%test_result: int] cycles ~expect:4;
  [%test_result: int] (int (outputs t).pc_o) ~expect:255;
  [%test_result: int] (int (outputs t).fetch_cycles_o) ~expect:2
;;
