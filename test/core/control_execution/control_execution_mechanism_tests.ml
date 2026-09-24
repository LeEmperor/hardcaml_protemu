(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "control_execution_mechanism_tests.ml" *)
(* P3.3-facing command-port tests. The responder is intentionally a test peer, not engine
   integration evidence: it checks retained requests, decisions, completion, and faults. *)

open! Core
open! Hardcaml_protemu
open! Protemu_isa
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

type expected =
  { kind : int
  ; arg0 : int
  ; arg1 : int
  ; arg2 : int
  ; timeout : bool
  ; result : int
  ; result_register : (int * int) option
  }

let immediate_responder expected seen _t (o : _ Executable_core.O.t) =
  if bool o.mechanism_request_valid_o
  then (
    incr seen;
    [%test_result: int] (int o.mechanism_kind_o) ~expect:expected.kind;
    [%test_result: int] (int o.mechanism_arg0_o) ~expect:expected.arg0;
    [%test_result: int] (int o.mechanism_arg1_o) ~expect:expected.arg1;
    [%test_result: int] (int o.mechanism_arg2_o) ~expect:expected.arg2;
    [%test_result: bool] (bool o.mechanism_timeout_enable_o) ~expect:expected.timeout;
    { quiet_mechanism with accepted = true; completion = true; result = expected.result })
  else quiet_mechanism
;;

let run_case name instructions expected =
  let t = create () in
  ignore
    (load_program t (program name (instructions @ [ Instruction.Halt ]))
     : Assembler.Assembled.t);
  let seen = ref 0 in
  ignore (run_until_halted ~respond:(immediate_responder expected seen) t () : int);
  [%test_result: int] !seen ~expect:1;
  Option.iter expected.result_register ~f:(fun (index, value) ->
    [%test_result: int] (reg t index) ~expect:value);
  let o = outputs t in
  [%test_result: bool] (bool o.normal_halt_o) ~expect:true;
  [%test_result: bool] (bool o.execution_fault_o) ~expect:false
;;

let%test_unit "every delegated non-branch instruction is issued with retained operands" =
  let open Instruction in
  let cases =
    [ ( "read_pins"
      , [ Read_pins { rd = 3 } ]
      , { kind = Control_execution.Mechanism_kind.read_pins
        ; arg0 = 3
        ; arg1 = 0
        ; arg2 = 0
        ; timeout = false
        ; result = 0x5a
        ; result_register = Some (3, 0x5a)
        } )
    ; ( "read_status"
      , [ Read_status { rd = 2 } ]
      , { kind = Control_execution.Mechanism_kind.read_status
        ; arg0 = 2
        ; arg1 = 0
        ; arg2 = 0
        ; timeout = false
        ; result = 0x21
        ; result_register = Some (2, 0x21)
        } )
    ; ( "ack_status"
      , [ Ack_status { mask = 0x3f } ]
      , { kind = Control_execution.Mechanism_kind.ack_status
        ; arg0 = 0x3f
        ; arg1 = 0
        ; arg2 = 0
        ; timeout = false
        ; result = 0
        ; result_register = None
        } )
    ; ( "write_pins_imm"
      , [ Write_pins_imm { mode = Open_drain; mask = 0xa5; value = 0x5a } ]
      , { kind = Control_execution.Mechanism_kind.write_pins_imm
        ; arg0 = 1
        ; arg1 = 0xa5
        ; arg2 = 0x5a
        ; timeout = false
        ; result = 0
        ; result_register = None
        } )
    ; ( "write_pins_reg"
      , [ Ldi { rd = 0; value = 0xa5 }
        ; Ldi { rd = 1; value = 0x5a }
        ; Write_pins_reg { mode = Push_pull; mask_reg = 0; value_reg = 1 }
        ]
      , { kind = Control_execution.Mechanism_kind.write_pins_reg
        ; arg0 = 0
        ; arg1 = 0xa5
        ; arg2 = 0x5a
        ; timeout = false
        ; result = 0
        ; result_register = None
        } )
    ; ( "wait_cycles_imm"
      , [ Wait_cycles_imm { delay = 1024 } ]
      , { kind = Control_execution.Mechanism_kind.wait_cycles_imm
        ; arg0 = 1024
        ; arg1 = 0
        ; arg2 = 0
        ; timeout = false
        ; result = 0
        ; result_register = None
        } )
    ; ( "wait_cycles_reg"
      , [ Ldi { rd = 0; value = 7 }; Wait_cycles_reg { rd = 0 } ]
      , { kind = Control_execution.Mechanism_kind.wait_cycles_reg
        ; arg0 = 7
        ; arg1 = 0
        ; arg2 = 0
        ; timeout = false
        ; result = 0
        ; result_register = None
        } )
    ; ( "wait_level"
      , [ Wait_level { pin = 3; level = true; timeout = Some 32 } ]
      , { kind = Control_execution.Mechanism_kind.wait_level
        ; arg0 = 3
        ; arg1 = 1
        ; arg2 = 32
        ; timeout = true
        ; result = 0
        ; result_register = None
        } )
    ; ( "wait_edge"
      , [ Wait_edge { pin = 2; edge = Kinds.Edge.Either; timeout = Some 16 } ]
      , { kind = Control_execution.Mechanism_kind.wait_edge
        ; arg0 = 2
        ; arg1 = 2
        ; arg2 = 16
        ; timeout = true
        ; result = 0
        ; result_register = None
        } )
    ; ( "start_periodic"
      , [ Start_periodic { period = 1024 } ]
      , { kind = Control_execution.Mechanism_kind.start_periodic
        ; arg0 = 1024
        ; arg1 = 0
        ; arg2 = 0
        ; timeout = false
        ; result = 0
        ; result_register = None
        } )
    ; ( "stop_periodic"
      , [ Stop_periodic ]
      , { kind = Control_execution.Mechanism_kind.stop_periodic
        ; arg0 = 0
        ; arg1 = 0
        ; arg2 = 0
        ; timeout = false
        ; result = 0
        ; result_register = None
        } )
    ; ( "issue_transfer"
      , [ Config { field = Descriptor.Field.Bit_count; value = 8 }; Issue_transfer ]
      , { kind = Control_execution.Mechanism_kind.issue_transfer
        ; arg0 = 0
        ; arg1 = 0
        ; arg2 = 0
        ; timeout = false
        ; result = 0
        ; result_register = None
        } )
    ; ( "fifo_push"
      , [ Ldi { rd = 0; value = 0x55 }
        ; Fifo_push
            { fifo = Kinds.Fifo_id.Tx; rs = 0; blocking = Kinds.Blocking.Blocking }
        ]
      , { kind = Control_execution.Mechanism_kind.fifo_push
        ; arg0 = 0
        ; arg1 = 0
        ; arg2 = 0x55
        ; timeout = false
        ; result = 0
        ; result_register = None
        } )
    ; ( "fifo_pop"
      , [ Fifo_pop
            { fifo = Kinds.Fifo_id.Rx; rd = 4; blocking = Kinds.Blocking.Nonblocking }
        ]
      , { kind = Control_execution.Mechanism_kind.fifo_pop
        ; arg0 = 1
        ; arg1 = 1
        ; arg2 = 0
        ; timeout = false
        ; result = 0xaa
        ; result_register = Some (4, 0xaa)
        } )
    ]
  in
  List.iter cases ~f:(fun (name, instructions, expected) ->
    run_case name instructions expected)
;;

let branch_pin_program () =
  let open Instruction in
  Program.create
    ~name:"branch_pin"
    [ Instr (Branch_pin { pin = 5; level = true; target = "taken" })
    ; Instr (Ldi { rd = 0; value = 0x11 })
    ; Instr (Jump { target = "done" })
    ; Label "taken"
    ; Instr (Ldi { rd = 0; value = 0x22 })
    ; Label "done"
    ; Instr Halt
    ]
  |> unwrap
;;

let%test_unit "branch_pin commits its decision only on completion" =
  List.iter [ false; true ] ~f:(fun taken ->
    let t = create () in
    ignore (load_program t (branch_pin_program ()) : Assembler.Assembled.t);
    let expected =
      { kind = Control_execution.Mechanism_kind.branch_pin
      ; arg0 = 5
      ; arg1 = 1
      ; arg2 = 0
      ; timeout = false
      ; result = Bool.to_int taken
      ; result_register = None
      }
    in
    let seen = ref 0 in
    ignore (run_until_halted ~respond:(immediate_responder expected seen) t () : int);
    [%test_result: int] (reg t 0) ~expect:(if taken then 0x22 else 0x11))
;;

let%test_unit "delayed acceptance and completion hold one request without reissue" =
  let t = create () in
  ignore
    (load_program t (program "delayed_read" [ Instruction.Read_pins { rd = 2 }; Halt ])
     : Assembler.Assembled.t);
  let request_samples = ref [] in
  let phase = ref 0 in
  let respond _t (o : _ Executable_core.O.t) =
    if bool o.mechanism_request_valid_o
    then
      request_samples
      := (int o.mechanism_kind_o, int o.mechanism_arg0_o) :: !request_samples;
    match !phase with
    | 0 when bool o.mechanism_request_valid_o ->
      phase := 1;
      quiet_mechanism
    | 1 when bool o.mechanism_request_valid_o ->
      phase := 2;
      { quiet_mechanism with accepted = true }
    | 2 ->
      [%test_result: bool] (bool o.mechanism_request_valid_o) ~expect:false;
      phase := 3;
      { quiet_mechanism with completion = true; result = 0x77 }
    | _ -> quiet_mechanism
  in
  ignore (run_until_halted ~respond t () : int);
  [%test_result: (int * int) list]
    (List.rev !request_samples)
    ~expect:
      [ Control_execution.Mechanism_kind.read_pins, 2
      ; Control_execution.Mechanism_kind.read_pins, 2
      ];
  [%test_result: int] (reg t 2) ~expect:0x77;
  let o = outputs t in
  [%test_result: int] (int o.stall_cycles_o) ~expect:2
;;

let faulting_response
  ?(refused = false)
  ?(completion_fault = false)
  reason
  _t
  (o : _ Executable_core.O.t)
  =
  if bool o.mechanism_request_valid_o
  then
    { quiet_mechanism with
      accepted = not refused
    ; refused
    ; refusal_reason = reason
    ; completion = not refused
    ; completion_fault
    ; completion_reason = reason
    }
  else quiet_mechanism
;;

let%test_unit "refusal and completion fault are distinct non-retiring boundaries" =
  List.iter
    [ true, false, Control_execution.Fault.mechanism_refused
    ; false, true, Control_execution.Fault.mechanism_completion
    ]
    ~f:(fun (refused, completion_fault, fault_kind) ->
      let t = create () in
      ignore
        (load_program
           t
           (program "mechanism_fault" [ Instruction.Read_status { rd = 1 }; Halt ])
         : Assembler.Assembled.t);
      ignore
        (run_until_halted ~respond:(faulting_response ~refused ~completion_fault 9) t ()
         : int);
      let o = outputs t in
      [%test_result: bool] (bool o.execution_fault_o) ~expect:true;
      [%test_result: int] (int o.fault_kind_o) ~expect:fault_kind;
      [%test_result: int] (int o.fault_reason_o) ~expect:9;
      [%test_result: int] (int o.instruction_count_o) ~expect:0)
;;

let%test_unit "an unsolicited completion faults without consuming a result" =
  let t = create () in
  ignore
    (load_program t (program "unsolicited" [ Instruction.Halt ]) : Assembler.Assembled.t);
  let sent = ref false in
  let respond _t _o =
    if !sent
    then quiet_mechanism
    else (
      sent := true;
      { quiet_mechanism with completion = true; result = 0x1234 })
  in
  ignore (run_until_halted ~respond t () : int);
  let o = outputs t in
  [%test_result: bool] (bool o.execution_fault_o) ~expect:true;
  [%test_result: int]
    (int o.fault_kind_o)
    ~expect:Control_execution.Fault.unsolicited_completion
;;

let%test_unit "an unsolicited completion cannot retire a simultaneous local instruction" =
  let t = create () in
  ignore
    (load_program
       t
       (program "unsolicited_local" [ Instruction.Ldi { rd = 0; value = 0x1234 }; Halt ])
     : Assembler.Assembled.t);
  let sent = ref false in
  let respond _t (o : _ Executable_core.O.t) =
    if (not !sent)
       && int o.phase_o = Control_execution.Phase.base_wait
       && bool o.fetch_completion_valid_o
    then (
      sent := true;
      { quiet_mechanism with completion = true; result = 0xbeef })
    else quiet_mechanism
  in
  ignore (run_until_halted ~respond t () : int);
  let o = outputs t in
  [%test_result: bool] !sent ~expect:true;
  [%test_result: bool] (bool o.execution_fault_o) ~expect:true;
  [%test_result: int]
    (int o.fault_kind_o)
    ~expect:Control_execution.Fault.unsolicited_completion;
  [%test_result: int] (reg t 0) ~expect:0;
  [%test_result: int] (int o.instruction_count_o) ~expect:0;
  [%test_result: bool] (bool o.retired_o) ~expect:false
;;

let await_mechanism_request t =
  step t Run;
  let rec loop remaining =
    if remaining = 0
    then raise_s [%message "mechanism request was not offered"]
    else if bool (outputs t).mechanism_request_valid_o
    then ()
    else (
      step t Idle;
      loop (remaining - 1))
  in
  loop 10
;;

let%test_unit "reset and disable suppress a retained mechanism request before the edge" =
  List.iter [ Reset; Enable false ] ~f:(fun cancellation ->
    let t = create () in
    ignore
      (load_program
         t
         (program "cancel_offer" [ Instruction.Read_status { rd = 0 }; Halt ])
       : Assembler.Assembled.t);
    await_mechanism_request t;
    [%test_result: bool] (bool (outputs t).mechanism_request_valid_o) ~expect:true;
    step
      ~respond:(fun _t (o : _ Executable_core.O.t) ->
        [%test_result: bool] (bool o.mechanism_request_valid_o) ~expect:false;
        { quiet_mechanism with accepted = true; completion = true; result = 0x55 })
      t
      cancellation;
    let o = outputs t in
    [%test_result: bool] (bool o.halted_o) ~expect:true;
    [%test_result: bool] (bool o.execution_fault_o) ~expect:false;
    [%test_result: int] (int o.instruction_count_o) ~expect:0)
;;
