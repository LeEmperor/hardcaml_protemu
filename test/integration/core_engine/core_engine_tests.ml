(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "core_engine_tests.ml" *)
(* Directed and bounded generated checks for the real P3.3 loaded-program path. *)

open! Core
open! Hardcaml_protemu
open! Protemu_isa
open! Core_engine_testbench
open Instruction

let event_bit kind = 1 lsl Event_kind.index kind

let reference_fifo_sequence values =
  let module Fifo = Protemu_f_model.Fifo in
  let ok = function
    | Ok value -> value
    | Error reason ->
      raise_s
        [%message
          "unexpected reference FIFO refusal" (reason : Protemu_f_model.Fault.Reject.t)]
  in
  match values with
  | [] -> []
  | last :: reversed_initial ->
    let initial = List.rev reversed_initial in
    let full =
      List.fold
        initial
        ~init:(Fifo.create ~id:Kinds.Fifo_id.Tx ~depth:8)
        ~f:(fun fifo value -> ok (Fifo.push fifo value))
    in
    let fifo, first, pushed, popped = Fifo.step full ~push:(Some last) ~pop:true in
    [%test_result: (unit, Protemu_f_model.Fault.Reject.t) Result.t option]
      pushed
      ~expect:(Some (Ok ()));
    [%test_result: (unit, Protemu_f_model.Fault.Reject.t) Result.t option]
      popped
      ~expect:(Some (Ok ()));
    let rec drain fifo result =
      if Fifo.is_empty fifo
      then List.rev result
      else (
        let fifo, value = ok (Fifo.pop fifo) in
        drain fifo (value :: result))
    in
    Option.to_list first @ drain fifo []
;;

let%test_unit "prepared P2.6b program reaches the committed pin bank" =
  let t = create () in
  let words = [| 0x7804; 0x0000; 0xa300; 0x7804; 0x0001; 0x0000 |] in
  step t (Claim 0x01);
  [%test_result: int] (int (outputs t).software_claim_o) ~expect:1;
  load_image t words;
  step t Run;
  let first_commit = ref None in
  let armed = ref None in
  let external_edge = ref None in
  let synchronized = ref None in
  let decision = ref None in
  let bank_request = ref None in
  let final_commit = ref None in
  let trace = Queue.create () in
  for _ = 0 to 80 do
    let o = outputs t in
    Queue.enqueue
      trace
      ( t.edge
      , int o.pc_o
      , int o.phase_o
      , bool o.mechanism_request_valid_o
      , int o.mechanism_kind_o
      , bool o.mechanism_completion_valid_o
      , int o.pins_o
      , int o.pin_oe_o
      , bool o.execution_fault_o );
    if Option.is_none !first_commit && int o.pin_oe_o land 1 <> 0
    then first_commit := Some t.edge;
    if Option.is_none !armed && bool o.timing_busy_o
    then (
      armed := Some t.edge;
      t.pin_async <- 0x08;
      external_edge := Some t.edge);
    if Option.is_none !synchronized && int o.rising_o land 0x08 <> 0
    then synchronized := Some t.edge;
    if Option.is_none !final_commit && int o.pins_o land 1 <> 0
    then final_commit := Some t.edge;
    if bool o.halted_o && Option.is_some !final_commit
    then ()
    else
      step
        ~before:(fun edge o ->
          if Option.is_none !decision
             && bool o.mechanism_completion_valid_o
             && int o.mechanism_kind_o = Control_execution.Mechanism_kind.wait_edge
          then decision := Some edge;
          if Option.is_none !bank_request
             && bool o.mechanism_request_valid_o
             && int o.mechanism_kind_o = Control_execution.Mechanism_kind.write_pins_imm
             && Option.is_some !decision
          then bank_request := Some edge)
        t
        Idle
  done;
  let get name = function
    | Some value -> value
    | None ->
      raise_s
        [%message
          "missing P2.6b timestamp"
            (name : string)
            (Queue.to_list trace
             : (int * int * int * bool * int * bool * int * int * bool) list)]
  in
  let external_edge = get "external" !external_edge in
  let synchronized = get "synchronized" !synchronized in
  let decision = get "decision" !decision in
  let bank_request = get "bank request" !bank_request in
  let final_commit = get "final commit" !final_commit in
  [%test_result: int]
    (get "initial commit" !first_commit < external_edge |> Bool.to_int)
    ~expect:1;
  [%test_result: int] (synchronized - external_edge) ~expect:2;
  [%test_result: int] (decision - synchronized) ~expect:1;
  [%test_result: int] (bank_request - decision) ~expect:3;
  [%test_result: int] (final_commit - bank_request) ~expect:1;
  [%test_result: int] (int (outputs t).pins_o land 1) ~expect:1;
  [%test_result: int] (int (outputs t).pin_oe_o land 1) ~expect:1;
  [%test_result: bool] (bool (outputs t).normal_halt_o) ~expect:true
;;

let%test_unit "status acknowledgement clears selected bits and waits leave periodic \
               timing live"
  =
  let t = create () in
  let p =
    program
      "status_and_timing"
      [ Instruction.Start_periodic { period = 2 }
      ; Wait_cycles_imm { delay = 5 }
      ; Read_status { rd = 0 }
      ; Ack_status { mask = Event_kind.mask }
      ; Stop_periodic
      ; Halt
      ]
  in
  ignore (load_program t p : Assembler.Assembled.t);
  ignore (run_until_halted t : int);
  let status = int (outputs t).status_o in
  [%test_result: int] (status land event_bit Event_kind.Delay_expired) ~expect:0;
  [%test_result: int] (status land event_bit Tick) ~expect:(event_bit Tick);
  [%test_result: bool] (bool (outputs t).execution_fault_o) ~expect:false
;;

let%test_unit "a synchronized event wins on the exact timeout completion edge" =
  let run inject_at =
    let t = create () in
    let p =
      program
        "event_timeout_collision"
        [ Instruction.Wait_edge { pin = 3; edge = Kinds.Edge.Rising; timeout = Some 6 }
        ; Halt
        ]
    in
    ignore (load_program t p : Assembler.Assembled.t);
    step t Run;
    while not (bool (outputs t).timing_busy_o) do
      step t Idle
    done;
    let rising = ref None in
    let completion = ref None in
    for relative = 0 to 20 do
      if Option.equal Int.equal inject_at (Some relative) then t.pin_async <- 0x08;
      step
        ~before:(fun _ o ->
          if int o.rising_o land 0x08 <> 0 && Option.is_none !rising
          then rising := Some relative;
          if bool o.mechanism_completion_valid_o && Option.is_none !completion
          then completion := Some relative)
        t
        Idle
    done;
    !rising, !completion, int (outputs t).status_o
  in
  let _, timeout_completion, _ = run None in
  let timeout_completion = Option.value_exn timeout_completion in
  let collision =
    List.find_map (List.range 0 10) ~f:(fun inject_at ->
      let rising, completion, status = run (Some inject_at) in
      if Option.equal Int.equal rising (Some (timeout_completion - 1))
         && Option.equal Int.equal completion (Some timeout_completion)
      then Some status
      else None)
    |> Option.value_exn
  in
  [%test_result: int]
    (collision land event_bit Event_kind.Wait_complete)
    ~expect:(event_bit Wait_complete);
  [%test_result: int] (collision land event_bit Event_kind.Wait_timeout) ~expect:0
;;

let%test_unit "FIFO pressure blocks only the core and preserves byte ordering" =
  let t = create () in
  let pushes =
    List.init 8 ~f:(fun value ->
      [ Instruction.Ldi { rd = 0; value }
      ; Fifo_push { fifo = Kinds.Fifo_id.Tx; rs = 0; blocking = Blocking }
      ])
    |> List.concat
  in
  let p =
    program
      "fifo_pressure"
      (pushes
       @ [ Ldi { rd = 0; value = 8 }
         ; Fifo_push { fifo = Tx; rs = 0; blocking = Blocking }
         ; Halt
         ])
  in
  ignore (load_program t p : Assembler.Assembled.t);
  step t Run;
  while int (outputs t).tx_count_o < 8 do
    step t Idle
  done;
  for _ = 1 to 4 do
    step t Idle
  done;
  [%test_result: bool] (bool (outputs t).engines_idle_o) ~expect:false;
  t.tx_ready <- true;
  let popped = Queue.create () in
  for _ = 0 to 80 do
    let o = outputs t in
    if bool o.tx_valid_o then Queue.enqueue popped (int o.tx_data_o);
    step t Idle
  done;
  [%test_result: int list]
    (Queue.to_list popped |> Fn.flip List.take 9)
    ~expect:(reference_fifo_sequence (List.range 0 9 |> List.rev));
  [%test_result: bool] (bool (outputs t).normal_halt_o) ~expect:true
;;

let%test_unit "pin snapshots, register writes, level waits, branches, and FIFO pop \
               compose"
  =
  let t = create () in
  let p =
    { Program.name = "remaining_mechanisms"
    ; items =
        List.map
          [ Ldi { rd = 0; value = 1 }
          ; Ldi { rd = 1; value = 1 }
          ; Write_pins_reg { mode = Push_pull; mask_reg = 0; value_reg = 1 }
          ; Wait_level { pin = 3; level = true; timeout = None }
          ; Read_pins { rd = 2 }
          ; Ldi { rd = 3; value = 2 }
          ; Wait_cycles_reg { rd = 3 }
          ; Branch_pin { pin = 3; level = true; target = "taken" }
          ; Ldi { rd = 4; value = 0xdead }
          ]
          ~f:Program.instr
        @ [ Program.at "taken"
          ; Program.instr
              (Fifo_pop { fifo = Kinds.Fifo_id.Rx; rd = 5; blocking = Blocking })
          ; Program.instr Halt
          ]
    }
  in
  step t (Claim 1);
  t.pin_async <- 0x08;
  step t Idle;
  step t Idle;
  t.rx_valid <- true;
  t.rx_data <- 0xa5;
  step t Idle;
  t.rx_valid <- false;
  ignore (load_program t p : Assembler.Assembled.t);
  ignore (run_until_halted t : int);
  let registers = !((outputs t).registers_o) in
  let reg index =
    Hardcaml.Bits.select registers ~high:((index * 16) + 15) ~low:(index * 16)
    |> Hardcaml.Bits.to_int_trunc
  in
  [%test_result: int] (reg 2 land 0x08) ~expect:0x08;
  [%test_result: int] (reg 4) ~expect:0;
  [%test_result: int] (reg 5) ~expect:0xa5;
  [%test_result: int] (int (outputs t).pins_o land 1) ~expect:1
;;

let descriptor_program
  ?(bit_count = 4)
  ?(half_period = 2)
  ?(pacing = Descriptor.Pacing.internal)
  ~name
  ~direction
  ~tx_value
  ~after_issue
  ()
  =
  let control =
    Descriptor.Control.of_choices
      ~direction
      ~bit_order:Kinds.Bit_order.Lsb_first
      ~idle_output:false
      ~idle_clock:false
      ~launch:Kinds.Clock_phase.On_falling
      ~sample:Kinds.Clock_phase.On_rising
  in
  let output_pin =
    if Kinds.Direction.equal direction Rx_only then Descriptor.no_pin else 1
  in
  let input_pin =
    if Kinds.Direction.equal direction Tx_only then Descriptor.no_pin else 2
  in
  program
    name
    ([ Config { field = Descriptor.Field.Control; value = control }
     ; Config { field = Bit_count; value = bit_count }
     ; Config { field = Tx_value; value = tx_value }
     ; Config { field = Output_pin; value = output_pin }
     ; Config { field = Input_pin; value = input_pin }
     ; Config { field = Clock_pin; value = Descriptor.no_pin }
     ; Config { field = Initial_delay; value = 0 }
     ; Config { field = Half_period; value = half_period }
     ; Config { field = Pacing; value = pacing }
     ; Issue_transfer
     ]
     @ after_issue)
;;

let%test_unit "accepted transfers run in the background and latch their descriptor" =
  let t = create () in
  let p =
    descriptor_program
      ~name:"background_transfer"
      ~direction:Kinds.Direction.Tx_only
      ~tx_value:0b1011
      ~after_issue:
        [ Config { field = Descriptor.Field.Tx_value; value = 0 }
        ; Wait_cycles_imm { delay = 24 }
        ; Halt
        ]
      ()
  in
  ignore (load_program t p : Assembler.Assembled.t);
  step t Run;
  let saw_driven_one = ref false in
  let done_during_wait = ref false in
  while not (bool (outputs t).halted_o) do
    let o = outputs t in
    if int o.pins_o land 0x02 <> 0 then saw_driven_one := true;
    if bool o.transfer_done_o && bool o.timing_busy_o then done_during_wait := true;
    step t Idle
  done;
  [%test_result: bool] !saw_driven_one ~expect:true;
  [%test_result: bool] !done_during_wait ~expect:true;
  [%test_result: int] (int (outputs t).engine_claim_o) ~expect:0;
  [%test_result: int] (int (outputs t).pin_oe_o land 0x02) ~expect:0;
  [%test_result: bool] (bool (outputs t).engines_idle_o) ~expect:true
;;

let%test_unit "RX and duplex transfers return independently sampled data" =
  List.iter [ Kinds.Direction.Rx_only; Duplex ] ~f:(fun direction ->
    let t = create () in
    t.pin_async <- 0x04;
    step t Idle;
    step t Idle;
    let p =
      descriptor_program
        ~name:"receive_transfer"
        ~direction
        ~tx_value:(if Kinds.Direction.equal direction Duplex then 0xf else 0)
        ~after_issue:[ Wait_cycles_imm { delay = 24 }; Halt ]
        ()
    in
    ignore (load_program t p : Assembler.Assembled.t);
    step t Run;
    let received = ref None in
    while not (bool (outputs t).halted_o) do
      let o = outputs t in
      if bool o.transfer_rx_valid_o then received := Some (int o.transfer_rx_data_o);
      step t Idle
    done;
    [%test_result: int option] !received ~expect:(Some 0xf))
;;

let%test_unit "observed pacing advances only on synchronized selected edges" =
  let t = create () in
  let p =
    descriptor_program
      ~bit_count:2
      ~half_period:0
      ~pacing:(Descriptor.Pacing.observed ~pin:3 ~edge:Kinds.Edge.Rising)
      ~name:"observed_pacing"
      ~direction:Kinds.Direction.Tx_only
      ~tx_value:1
      ~after_issue:
        [ Config
            { field = Descriptor.Field.Pacing
            ; value = Descriptor.Pacing.observed ~pin:4 ~edge:Kinds.Edge.Falling
            }
        ; Wait_cycles_imm { delay = 80 }
        ; Halt
        ]
      ()
  in
  ignore (load_program t p : Assembler.Assembled.t);
  step t Run;
  while not (bool (outputs t).transfer_busy_o) do
    step t Idle
  done;
  for _ = 1 to 8 do
    step t Idle
  done;
  [%test_result: bool] (bool (outputs t).transfer_busy_o) ~expect:true;
  for edge = 0 to 7 do
    t.pin_async <- (if edge % 2 = 0 then 0x10 else 0);
    for _ = 1 to 3 do
      step t Idle
    done
  done;
  [%test_result: bool] (bool (outputs t).transfer_busy_o) ~expect:true;
  let saw_done = ref false in
  for edge = 0 to 7 do
    t.pin_async <- (if edge % 2 = 0 then 0x08 else 0);
    for _ = 1 to 3 do
      step t Idle;
      if bool (outputs t).transfer_done_o then saw_done := true
    done
  done;
  [%test_result: bool] !saw_done ~expect:true;
  for _ = 1 to 200 do
    if not (bool (outputs t).halted_o) then step t Idle
  done;
  [%test_result: bool] (bool (outputs t).halted_o) ~expect:true;
  [%test_result: bool] (bool (outputs t).engines_idle_o) ~expect:true;
  [%test_result: int] (int (outputs t).engine_claim_o) ~expect:0
;;

let%test_unit "engine ownership refuses a conflicting core write without partial effect" =
  let module Bank = Protemu_f_model.Pin_bank in
  let reference =
    match Bank.claim Bank.released ~owner:(Kinds.Owner.Engine 0) ~mask:0x02 with
    | Ok bank -> bank
    | Error reason ->
      raise_s
        [%message
          "unexpected reference pin claim refusal"
            (reason : Protemu_f_model.Fault.Reject.t)]
  in
  [%test_result: bool]
    (Result.is_error
       (Bank.commit
          reference
          (Bank.Write.push_pull ~mask:0x06 ~value:0x04)
          ~owner:Kinds.Owner.Software))
    ~expect:true;
  let t = create () in
  let p =
    descriptor_program
      ~name:"ownership_conflict"
      ~direction:Kinds.Direction.Tx_only
      ~tx_value:0xf
      ~after_issue:
        [ Write_pins_imm { mode = Push_pull; mask = 0x06; value = 0x04 }; Halt ]
      ()
  in
  ignore (load_program t p : Assembler.Assembled.t);
  step t Run;
  for _ = 1 to 200 do
    if not (bool (outputs t).execution_fault_o) then step t Idle
  done;
  [%test_result: bool] (bool (outputs t).execution_fault_o) ~expect:true;
  [%test_result: int]
    (int (outputs t).fault_kind_o)
    ~expect:Control_execution.Fault.mechanism_refused;
  [%test_result: int]
    (int (outputs t).fault_reason_o)
    ~expect:Core_mechanisms.Reason.pin_conflict;
  [%test_result: int] (int (outputs t).software_claim_o) ~expect:0;
  [%test_result: bool] (bool (outputs t).bank_conflict_o) ~expect:false;
  [%test_result: int] (int (outputs t).engine_claim_o land 0x02) ~expect:0x02;
  [%test_result: int] (int (outputs t).pins_o land 0x04) ~expect:0;
  [%test_result: int] (int (outputs t).pin_oe_o land 0x04) ~expect:0
;;

let%test_unit "external occupancy refuses transfer issue before retirement" =
  let t = create () in
  let p =
    descriptor_program
      ~name:"external_occupancy"
      ~direction:Kinds.Direction.Tx_only
      ~tx_value:0xf
      ~after_issue:[ Halt ]
      ()
  in
  t.occupied <- 0x02;
  ignore (load_program t p : Assembler.Assembled.t);
  step t Run;
  for _ = 1 to 200 do
    if not (bool (outputs t).execution_fault_o) then step t Idle
  done;
  [%test_result: bool] (bool (outputs t).execution_fault_o) ~expect:true;
  [%test_result: int]
    (int (outputs t).fault_reason_o)
    ~expect:Core_mechanisms.Reason.pin_conflict;
  [%test_result: int] (int (outputs t).instruction_count_o) ~expect:9;
  [%test_result: int] (int (outputs t).engine_claim_o) ~expect:0;
  [%test_result: int] (int (outputs t).pin_oe_o) ~expect:0
;;

let%test_unit "single-step can start background work but is then gated by real engine \
               idle"
  =
  let t = create () in
  let p =
    descriptor_program
      ~name:"step_background"
      ~direction:Kinds.Direction.Tx_only
      ~tx_value:0xf
      ~after_issue:[ Halt ]
      ()
  in
  ignore (load_program t p : Assembler.Assembled.t);
  let step_instruction () =
    let accepted = ref false in
    step ~before:(fun _ o -> accepted := bool o.step_accepted_o) t Step;
    [%test_result: bool] !accepted ~expect:true
  in
  for expected = 1 to 9 do
    step_instruction ();
    for _ = 1 to 100 do
      if not (bool (outputs t).halted_o) then step t Idle
    done;
    [%test_result: bool] (bool (outputs t).halted_o) ~expect:true;
    [%test_result: int] (int (outputs t).instruction_count_o) ~expect:expected
  done;
  step_instruction ();
  for _ = 1 to 100 do
    if not (bool (outputs t).halted_o) then step t Idle
  done;
  [%test_result: bool] (bool (outputs t).halted_o) ~expect:true;
  [%test_result: int] (int (outputs t).instruction_count_o) ~expect:10;
  [%test_result: bool] (bool (outputs t).transfer_busy_o) ~expect:true;
  [%test_result: bool] (bool (outputs t).engines_idle_o) ~expect:false;
  step t Step;
  [%test_result: bool] (bool (outputs t).step_rejected_o) ~expect:true;
  step t (Read 0);
  [%test_result: bool] (bool (outputs t).readback_rejected_o) ~expect:true;
  let saw_done = ref false in
  let saw_driven = ref false in
  for _ = 1 to 100 do
    if not (bool (outputs t).engines_idle_o)
    then (
      step t Idle;
      if bool (outputs t).transfer_done_o then saw_done := true;
      if int (outputs t).pin_oe_o land 0x02 <> 0 then saw_driven := true)
  done;
  [%test_result: bool] !saw_done ~expect:true;
  [%test_result: bool] !saw_driven ~expect:true;
  [%test_result: bool] (bool (outputs t).halted_o) ~expect:true;
  [%test_result: int] (int (outputs t).instruction_count_o) ~expect:10;
  [%test_result: int] (int (outputs t).pin_oe_o) ~expect:0;
  [%test_result: int] (int (outputs t).engine_claim_o) ~expect:0;
  [%test_result: bool] (bool (outputs t).engines_idle_o) ~expect:true;
  let readback_accepted = ref false in
  step ~before:(fun _ o -> readback_accepted := bool o.readback_accepted_o) t (Read 0);
  [%test_result: bool] !readback_accepted ~expect:true
;;

let%test_unit "STOP waits for a boundary, ABORT releases, and step retires exactly one" =
  let wait_program =
    program
      "control"
      [ Instruction.Wait_cycles_imm { delay = 8 }
      ; Write_pins_imm { mode = Push_pull; mask = 1; value = 1 }
      ; Halt
      ]
  in
  let stopped = create () in
  step stopped (Claim 1);
  ignore (load_program stopped wait_program : Assembler.Assembled.t);
  step stopped Run;
  while not (bool (outputs stopped).timing_busy_o) do
    step stopped Idle
  done;
  step stopped Stop;
  [%test_result: bool] (bool (outputs stopped).halted_o) ~expect:false;
  while not (bool (outputs stopped).halted_o) do
    step stopped Idle
  done;
  [%test_result: int] (int (outputs stopped).instruction_count_o) ~expect:1;
  [%test_result: int] (int (outputs stopped).pins_o land 1) ~expect:0;
  step stopped Step;
  while not (bool (outputs stopped).halted_o) do
    step stopped Idle
  done;
  [%test_result: int] (int (outputs stopped).instruction_count_o) ~expect:2;
  [%test_result: int] (int (outputs stopped).pins_o land 1) ~expect:1;
  let aborted = create () in
  step aborted (Claim 1);
  ignore (load_program aborted wait_program : Assembler.Assembled.t);
  step aborted Run;
  while not (bool (outputs aborted).timing_busy_o) do
    step aborted Idle
  done;
  step aborted Abort;
  [%test_result: bool] (bool (outputs aborted).halted_o) ~expect:true;
  [%test_result: int] (int (outputs aborted).pin_oe_o) ~expect:0;
  [%test_result: int] (int (outputs aborted).software_claim_o) ~expect:0;
  [%test_result: int]
    (int (outputs aborted).status_o land event_bit Aborted)
    ~expect:(event_bit Aborted)
;;

let%test_unit "ABORT suppresses a same-edge wait completion and retirement" =
  let p =
    program
      "abort_completion_collision"
      [ Instruction.Wait_cycles_imm { delay = 6 }; Halt ]
  in
  let start () =
    let t = create () in
    ignore (load_program t p : Assembler.Assembled.t);
    step t Run;
    while not (bool (outputs t).timing_busy_o) do
      step t Idle
    done;
    t
  in
  let baseline = start () in
  let completion_at = ref None in
  for relative = 0 to 20 do
    step
      ~before:(fun _ o ->
        if bool o.mechanism_completion_valid_o && Option.is_none !completion_at
        then completion_at := Some relative)
      baseline
      Idle
  done;
  let completion_at = Option.value_exn !completion_at in
  let aborted = start () in
  for _ = 1 to completion_at do
    step aborted Idle
  done;
  let completion_visible = ref true in
  step
    ~before:(fun _ o -> completion_visible := bool o.mechanism_completion_valid_o)
    aborted
    Abort;
  [%test_result: bool] !completion_visible ~expect:false;
  [%test_result: bool] (bool (outputs aborted).halted_o) ~expect:true;
  [%test_result: int] (int (outputs aborted).instruction_count_o) ~expect:0;
  [%test_result: int]
    (int (outputs aborted).status_o land event_bit Event_kind.Aborted)
    ~expect:(event_bit Aborted);
  [%test_result: int]
    (int (outputs aborted).status_o land event_bit Event_kind.Delay_expired)
    ~expect:0
;;

let%test_unit "ABORT, STOP, single-step, and RUN obey simultaneous priority" =
  let loaded () =
    let t = create () in
    ignore
      (load_program t (program "priority" [ Instruction.Halt ]) : Assembler.Assembled.t);
    t
  in
  let sample t request =
    let result = ref None in
    step
      ~before:(fun _ o ->
        result
        := Some
             ( bool o.abort_accepted_o
             , bool o.stop_accepted_o
             , bool o.step_accepted_o
             , bool o.run_accepted_o
             , bool o.abort_rejected_o
             , bool o.stop_rejected_o
             , bool o.step_rejected_o
             , bool o.run_rejected_o ))
      t
      request;
    Option.value_exn !result
  in
  [%test_result: bool * bool * bool * bool * bool * bool * bool * bool]
    (sample (loaded ()) (Controls { run = true; stop = true; abort = true; step = true }))
    ~expect:(true, false, false, false, false, true, true, true);
  [%test_result: bool * bool * bool * bool * bool * bool * bool * bool]
    (sample
       (loaded ())
       (Controls { run = true; stop = true; abort = false; step = true }))
    ~expect:(false, true, false, false, false, false, true, true);
  let stepped = loaded () in
  [%test_result: bool * bool * bool * bool * bool * bool * bool * bool]
    (sample stepped (Controls { run = true; stop = false; abort = false; step = true }))
    ~expect:(false, false, true, false, false, false, false, true);
  while not (bool (outputs stepped).halted_o) do
    step stepped Idle
  done;
  [%test_result: int] (int (outputs stepped).instruction_count_o) ~expect:1
;;

let%test_unit "disable clears blocked and active engines while reset also invalidates \
               image"
  =
  let active name =
    let t = create () in
    let p =
      descriptor_program
        ~half_period:8
        ~name
        ~direction:Kinds.Direction.Tx_only
        ~tx_value:0xf
        ~after_issue:[ Wait_cycles_imm { delay = 80 }; Halt ]
        ()
    in
    ignore (load_program t p : Assembler.Assembled.t);
    step t Run;
    while int (outputs t).engine_claim_o = 0 do
      step t Idle
    done;
    t
  in
  let disabled = active "disable_active" in
  step disabled (Enable false);
  [%test_result: int] (int (outputs disabled).engine_claim_o) ~expect:0;
  [%test_result: int] (int (outputs disabled).pin_oe_o) ~expect:0;
  [%test_result: bool] (bool (outputs disabled).image_valid_o) ~expect:true;
  step disabled (Enable true);
  [%test_result: bool] (bool (outputs disabled).image_valid_o) ~expect:true;
  let blocked_fifo = create () in
  let fifo_program =
    List.init 9 ~f:(fun value ->
      [ Instruction.Ldi { rd = 0; value }
      ; Fifo_push { fifo = Kinds.Fifo_id.Tx; rs = 0; blocking = Blocking }
      ])
    |> List.concat
    |> Fn.flip List.append [ Halt ]
    |> program "disable_blocked_fifo"
  in
  ignore (load_program blocked_fifo fifo_program : Assembler.Assembled.t);
  step blocked_fifo Run;
  while bool (outputs blocked_fifo).engines_idle_o do
    step blocked_fifo Idle
  done;
  [%test_result: int] (int (outputs blocked_fifo).tx_count_o) ~expect:8;
  step blocked_fifo (Enable false);
  [%test_result: int] (int (outputs blocked_fifo).tx_count_o) ~expect:0;
  [%test_result: bool] (bool (outputs blocked_fifo).engines_idle_o) ~expect:true;
  [%test_result: bool] (bool (outputs blocked_fifo).image_valid_o) ~expect:true;
  let reset = active "reset_active" in
  step reset Reset;
  [%test_result: int] (int (outputs reset).engine_claim_o) ~expect:0;
  [%test_result: int] (int (outputs reset).pin_oe_o) ~expect:0;
  [%test_result: bool] (bool (outputs reset).image_valid_o) ~expect:false
;;

let%test_unit "fixed generated wait programs retire with exact accepted delays" =
  let seed = 20260920 in
  let state = Random.State.make [| seed |] in
  for scenario = 0 to 31 do
    let delay = 1 + Random.State.int state 31 in
    let t = create () in
    let p =
      program
        [%string "generated_%{scenario#Int}"]
        [ Instruction.Wait_cycles_imm { delay }; Halt ]
    in
    ignore (load_program t p : Assembler.Assembled.t);
    ignore (run_until_halted ~limit:256 t : int);
    let o = outputs t in
    if int o.instruction_count_o <> 2 || int o.stall_cycles_o <> delay + 1
    then
      raise_s
        [%message
          "generated core/engine mismatch"
            (seed : int)
            (scenario : int)
            (delay : int)
            ~instructions:(int o.instruction_count_o : int)
            ~stalls:(int o.stall_cycles_o : int)]
  done
;;
