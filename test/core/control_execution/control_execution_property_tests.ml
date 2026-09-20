(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "control_execution_property_tests.ml" *)
(* Reproducible bounded assembled-program comparison against the independent reference
   executor. Programs contain random state operations followed by a finite DBNZ loop. *)

open! Core
open! Protemu_isa
open! Control_execution_model_tests

module Generator = struct
  module G = Base_quickcheck.Generator
  open G.Let_syntax

  let register = G.int_uniform_inclusive 0 6
  let value = G.int_uniform_inclusive 0 0xffff
  let alu_op = G.of_list Instruction.Alu_op.all
  let shift_dir = G.of_list Instruction.Shift_dir.all
  let descriptor_field = G.of_list Descriptor.Field.all

  let instruction =
    let%bind kind =
      G.of_weighted_list
        [ 4., `Ldi
        ; 2., `Mov
        ; 4., `Alu
        ; 4., `Alu_imm
        ; 2., `Cmp
        ; 2., `Cmp_imm
        ; 2., `Shift
        ; 2., `Config
        ]
    in
    match kind with
    | `Ldi ->
      let%map rd = register
      and value in
      Instruction.Ldi { rd; value }
    | `Mov ->
      let%map rd = register
      and rs = register in
      Instruction.Mov { rd; rs }
    | `Alu ->
      let%map op = alu_op
      and rd = register
      and rs = register in
      Instruction.Alu { op; rd; rs }
    | `Alu_imm ->
      let%map op = alu_op
      and rd = register
      and imm = value in
      Instruction.Alu_imm { op; rd; imm }
    | `Cmp ->
      let%map ra = register
      and rb = register in
      Instruction.Cmp { ra; rb }
    | `Cmp_imm ->
      let%map ra = register
      and imm = value in
      Instruction.Cmp_imm { ra; imm }
    | `Shift ->
      let%map dir = shift_dir
      and rd = register
      and amount = G.int_uniform_inclusive 1 15 in
      Instruction.Shift { dir; rd; amount }
    | `Config ->
      let%map field = descriptor_field
      and value in
      Instruction.Config { field; value }
  ;;

  let program =
    let%bind size = G.size in
    let length = Int.max 1 (Int.min 12 size) in
    let%bind body = G.list_with_length instruction ~length in
    let%map count = G.int_uniform_inclusive 1 4 in
    { Program.name = "generated_p3_2"
    ; items =
        List.map body ~f:(fun instruction -> Program.Item.Instr instruction)
        @ [ Instr (Instruction.Ldi { rd = 7; value = count })
          ; Label "loop"
          ; Instr (Instruction.Alu_imm { op = Instruction.Alu_op.Add; rd = 6; imm = 1 })
          ; Instr (Instruction.Dbnz { rd = 7; target = "loop" })
          ; Instr Instruction.Halt
          ]
    }
  ;;
end

let settings = Replay.Settings.create ~seed:20260920 ~trials:96 ~size:24

let run_generated ~here () =
  let settings = Replay.Settings.override settings in
  let random = Splittable_random.of_int settings.seed in
  let rec loop trial =
    if trial >= settings.trials
    then None
    else (
      let size = Replay.Settings.size_of_trial settings ~trial in
      let program = Base_quickcheck.Generator.generate Generator.program ~size ~random in
      match
        Or_error.try_with (fun () ->
          ignore (compare_program program : Control_execution_testbench.t))
      with
      | Ok () -> loop (trial + 1)
      | Error error ->
        let assembled = Assembler.assemble program in
        let replay =
          Replay.create
            ~test:"control_execution_generated_programs"
            ~source_file:here.pos_fname
            ~settings
            ~trial:(Some trial)
            ~config:[%sexp (program.items : Program.Item.t list)]
        in
        let program_text =
          Sexp.to_string_hum [%sexp (program.items : Program.Item.t list)]
        in
        let assembly_text =
          Sexp.to_string_hum
            ([%sexp_of: (Assembler.Assembled.t, Invalid.t) Result.t] assembled)
        in
        let report =
          String.concat
            ~sep:"\n"
            ([ "control_execution: generated model/RTL comparison failed"; "" ]
             @ Replay.to_lines replay
             @ [ ""
               ; [%string "first mismatch: %{Error.to_string_hum error}"]
               ; [%string "program: %{program_text}"]
               ; [%string "assembly: %{assembly_text}"]
               ; ""
               ])
        in
        let artifact =
          Replay.Artifacts.write
            ~test:"control_execution_generated_programs"
            ~settings
            ~trial
            ~contents:(report ^ Replay.artifact_appendix replay)
        in
        Some
          (match artifact with
           | None -> report
           | Some path -> report ^ [%string "artifact: %{path}\n"]))
  in
  loop 0
;;

let%expect_test "bounded assembled programs agree with the independent core" =
  (match run_generated ~here:[%here] () with
   | None -> print_endline "agreed on all 96 generated P3.2 programs at seed 20260920"
   | Some failure -> print_string failure);
  [%expect {| agreed on all 96 generated P3.2 programs at seed 20260920 |}]
;;

let%expect_test "generated P3.2 programs record an executable rerun" =
  print_endline
    (Replay.rerun_command
       ~source_file:"test/core/control_execution/control_execution_property_tests.ml"
       ~settings);
  [%expect
    {|
    PROTEMU_SEED=20260920 PROTEMU_TRIALS=96 PROTEMU_SIZE=24 dune runtest test/core/control_execution --force
    |}]
;;
