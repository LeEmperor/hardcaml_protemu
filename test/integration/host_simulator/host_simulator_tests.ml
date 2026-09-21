(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "host_simulator_tests.ml" *)
(* Layered P3.4 coverage over one real [Integrated_core] Cyclesim session. *)

open! Core
open! Protemu_isa
module Api = Protemu_host.Host_api
module Backend = Protemu_simulator.Simulator_backend
module _ : Api.Device with type t = Backend.t = Backend

let ok = function
  | Ok value -> value
  | Error error -> raise_s [%message "unexpected host error" (error : Api.Error.t)]
;;

let error = function
  | Error error -> error
  | Ok _ -> raise_s [%message "expected host error"]
;;

let image name instructions =
  let program = { Program.name; items = List.map instructions ~f:Program.instr } in
  match Assembler.assemble ~memory:Assembler.Memory.word16 program with
  | Ok assembled -> Api.Image.of_assembled assembled
  | Error reason -> raise_s [%message "assembly failed" (reason : Invalid.t)]
;;

let echo_image =
  image
    "echo"
    [ Instruction.Fifo_pop { fifo = Kinds.Fifo_id.Rx; rd = 0; blocking = Blocking }
    ; Fifo_push { fifo = Tx; rs = 0; blocking = Blocking }
    ; Halt
    ]
;;

let run_echo t byte =
  ignore (ok (Backend.run t) : Api.Control_ack.t);
  ignore (ok (Backend.transmit t ~budget_cycles:16 [ byte ]) : Api.Transfer.t);
  ignore (ok (Backend.wait_halted t ~budget_cycles:64) : Api.Status.t);
  ok (Backend.receive t ~budget_cycles:0 ~count:1)
;;

let trace_rank = function
  | Api.Trace.Event.Host_operation _ -> 0
  | Instruction_boundary _ -> 1
  | Mechanism _ -> 2
  | Engine_completion _ -> 3
  | Pin_transition _ -> 4
  | Fault _ -> 5
;;

let assert_same_timestamp_order records =
  List.group records ~break:(fun left right ->
    left.Api.Trace.Record.timestamp <> right.timestamp)
  |> List.iter ~f:(fun group ->
    [%test_result: bool]
      (List.is_sorted group ~compare:(fun left right ->
         Int.compare (trace_rank left.event) (trace_rank right.event)))
      ~expect:true)
;;

let%test_unit "discovery advertises an explicit simulator capability set" =
  let capabilities = (Backend.discover (Backend.create ())).capabilities in
  [%test_result: Api.Capability.t list]
    capabilities
    ~expect:
      [ Program_load
      ; Program_readback
      ; Execution_control
      ; Single_step
      ; Pin_claims
      ; Host_tx_queue
      ; Host_rx_queue
      ; Architectural_inspection
      ; Timestamped_trace
      ; Simulator_cycle_control
      ; Simulator_pad_stimulus
      ]
;;

let%test_unit "program reads validate the full logical range before advancing" =
  let t = Backend.create () in
  let initial_cycle = (Backend.status t).cycle in
  [%test_result: Api.Error.t]
    (error (Backend.read_program t ~address:0 ~count:1))
    ~expect:(Refused { operation = "read-program"; reason = No_verified_image });
  [%test_result: int] (Backend.status t).cycle ~expect:initial_cycle;
  let one_word = Api.Image.create [ List.hd_exn echo_image.words ] in
  ignore (ok (Backend.load_image t one_word) : Api.Load_result.t);
  let loaded_cycle = (Backend.status t).cycle in
  [%test_result: Api.Error.t]
    (error (Backend.read_program t ~address:0 ~count:3))
    ~expect:(Refused { operation = "read-program"; reason = Image_bounds });
  [%test_result: int] (Backend.status t).cycle ~expect:loaded_cycle;
  [%test_result: int list]
    (ok (Backend.read_program t ~address:0 ~count:1))
    ~expect:one_word.words
;;

let%test_unit "step without a verified image reports the authoritative cause" =
  let t = Backend.create () in
  [%test_result: Api.Error.t]
    (error (Backend.step t ~budget_cycles:0))
    ~expect:(Refused { operation = "step"; reason = No_verified_image })
;;

let%test_unit "verify length mismatch preserves a valid loaded image" =
  let t = Backend.create () in
  ignore (ok (Backend.load_image t echo_image) : Api.Load_result.t);
  let shorter = { echo_image with words = List.take echo_image.words 2 } in
  [%test_result: Api.Error.t]
    (error (Backend.verify_image t shorter))
    ~expect:(Incompatible_image { field = "length_words"; required = "2"; actual = "3" });
  [%test_result: bool] (Backend.loaded_image t).valid ~expect:true;
  [%test_result: int] (Backend.loaded_image t).length_words ~expect:3
;;

let%test_unit "load, readback, live refusal, and real queue echo" =
  let t = Backend.create () in
  let load = ok (Backend.load_image t echo_image) in
  [%test_result: int] load.words ~expect:3;
  let incompatible = error (Backend.load_image t { echo_image with isa_id = "other" }) in
  [%test_result: string] (Api.Error.code incompatible) ~expect:"incompatible_isa";
  [%test_result: bool] (Backend.loaded_image t).valid ~expect:true;
  [%test_result: int list]
    (ok (Backend.read_program t ~address:0 ~count:3))
    ~expect:echo_image.words;
  let before_invalid_read = (Backend.status t).cycle in
  [%test_result: string]
    (Api.Error.code
       (error (Backend.read_program t ~address:Int.max_value ~count:Int.max_value)))
    ~expect:"invalid_argument";
  [%test_result: int] (Backend.status t).cycle ~expect:before_invalid_read;
  ok (Backend.verify_image t echo_image);
  let mismatch =
    error
      (Backend.verify_image
         t
         { echo_image with words = 0xffff :: List.tl_exn echo_image.words })
  in
  [%test_result: string] (Api.Error.code mismatch) ~expect:"verification_mismatch";
  let before_run = (Backend.status t).cycle in
  ignore (ok (Backend.run t) : Api.Control_ack.t);
  let refusal = error (Backend.read_program t ~address:0 ~count:1) in
  [%test_result: string] (Api.Error.code refusal) ~expect:"active_execution";
  let transfer = ok (Backend.transmit t ~budget_cycles:4 [ 0xa5 ]) in
  [%test_result: Api.Transfer_outcome.t] transfer.outcome ~expect:Complete;
  let final = ok (Backend.wait_halted t ~budget_cycles:64) in
  [%test_result: bool] final.normal_halt ~expect:true;
  [%test_result: int] (List.nth_exn final.registers 0) ~expect:0xa5;
  let received = ok (Backend.receive t ~budget_cycles:0 ~count:1) in
  [%test_result: int list] received.data ~expect:[ 0xa5 ];
  [%test_result: bool] (final.cycle > before_run) ~expect:true
;;

let%test_unit "STOP timeout preserves accepted work; step and ABORT recover" =
  let t = Backend.create () in
  ignore (ok (Backend.load_image t echo_image) : Api.Load_result.t);
  let before_invalid_step = (Backend.status t).cycle in
  [%test_result: string]
    (Api.Error.code (error (Backend.step t ~budget_cycles:(-1))))
    ~expect:"invalid_argument";
  [%test_result: int] (Backend.status t).cycle ~expect:before_invalid_step;
  ignore (ok (Backend.run t) : Api.Control_ack.t);
  ignore (ok (Backend.advance t ~cycles:8) : Api.Status.t);
  let before_invalid_stop = (Backend.status t).cycle in
  [%test_result: string]
    (Api.Error.code (error (Backend.stop t ~budget_cycles:(-1))))
    ~expect:"invalid_argument";
  [%test_result: int] (Backend.status t).cycle ~expect:before_invalid_stop;
  let timeout = error (Backend.stop t ~budget_cycles:2) in
  [%test_result: Api.Error.t]
    timeout
    ~expect:(Timeout { operation = "stop"; budget_cycles = 2; accepted = true });
  ignore (ok (Backend.transmit t ~budget_cycles:2 [ 0x3c ]) : Api.Transfer.t);
  let stopped = ok (Backend.wait_halted t ~budget_cycles:32) in
  [%test_result: bool] stopped.normal_halt ~expect:false;
  [%test_result: int] (List.nth_exn stopped.registers 0) ~expect:0x3c;
  ignore (ok (Backend.step t ~budget_cycles:32) : Api.Control_ack.t);
  [%test_result: int list]
    (ok (Backend.receive t ~budget_cycles:0 ~count:1)).data
    ~expect:[ 0x3c ];
  ignore (ok (Backend.run t) : Api.Control_ack.t);
  let aborted = ok (Backend.abort t) in
  [%test_result: bool] aborted.completed ~expect:true;
  [%test_result: bool] (Backend.status t).halted ~expect:true;
  [%test_result: bool] (Backend.loaded_image t).valid ~expect:true
;;

let transfer_image =
  let control =
    Descriptor.Control.of_choices
      ~direction:Kinds.Direction.Tx_only
      ~bit_order:Kinds.Bit_order.Lsb_first
      ~idle_output:false
      ~idle_clock:false
      ~launch:Kinds.Clock_phase.On_falling
      ~sample:Kinds.Clock_phase.On_rising
  in
  image
    "background-transfer"
    [ Instruction.Config { field = Descriptor.Field.Control; value = control }
    ; Config { field = Bit_count; value = 16 }
    ; Config { field = Tx_value; value = 0xa55a }
    ; Config { field = Output_pin; value = 1 }
    ; Config { field = Input_pin; value = Descriptor.no_pin }
    ; Config { field = Clock_pin; value = Descriptor.no_pin }
    ; Config { field = Initial_delay; value = 0 }
    ; Config { field = Half_period; value = 3 }
    ; Config { field = Pacing; value = Descriptor.Pacing.internal }
    ; Issue_transfer
    ; Halt
    ]
;;

let%test_unit "halted background engine still rejects program access" =
  let t = Backend.create () in
  ignore (ok (Backend.load_image t transfer_image) : Api.Load_result.t);
  ignore (ok (Backend.run t) : Api.Control_ack.t);
  let halted = ok (Backend.wait_halted t ~budget_cycles:128) in
  [%test_result: bool] halted.engine.idle ~expect:false;
  let refusal = error (Backend.read_program t ~address:0 ~count:1) in
  [%test_result: Api.Error.t]
    refusal
    ~expect:(Refused { operation = "read-program"; reason = Engines_active });
  let rec wait budget =
    if (Backend.status t).engine.idle
    then ()
    else if budget = 0
    then raise_s [%message "engine did not become idle"]
    else (
      ignore (ok (Backend.advance t ~cycles:1) : Api.Status.t);
      wait (budget - 1))
  in
  wait 256;
  ignore (ok (Backend.read_program t ~address:0 ~count:1) : int list);
  let records = (ok (Backend.trace_retrieve t ~after:None)).records in
  assert_same_timestamp_order records
;;

let%test_unit "engine pin ownership rejects host changes and ABORT observes release" =
  let t = Backend.create () in
  ignore (ok (Backend.load_image t transfer_image) : Api.Load_result.t);
  ignore (ok (Backend.run t) : Api.Control_ack.t);
  let halted = ok (Backend.wait_halted t ~budget_cycles:128) in
  [%test_result: bool] halted.engine.idle ~expect:false;
  [%test_result: int] (halted.engine.engine_claims land 0x02) ~expect:0x02;
  [%test_result: int] (halted.pin_output_enable land 0x02) ~expect:0x02;
  List.iter [ Api.Pin_configuration.Claim 0x02; Release 0x02 ] ~f:(fun configuration ->
    [%test_result: Api.Error.t]
      (error (Backend.configure_pins t configuration))
      ~expect:
        (Refused
           { operation =
               (match configuration with
                | Claim _ -> "pin-claim"
                | Release _ -> "pin-release")
           ; reason = Pin_conflict
           });
    let state = Backend.status t in
    [%test_result: int] state.engine.software_claims ~expect:0;
    [%test_result: int] (state.engine.engine_claims land 0x02) ~expect:0x02;
    [%test_result: int] (state.pin_output_enable land 0x02) ~expect:0x02);
  let aborted = ok (Backend.abort t) in
  [%test_result: bool] aborted.completed ~expect:true;
  let state = Backend.status t in
  [%test_result: bool] state.halted ~expect:true;
  [%test_result: bool] state.engine.idle ~expect:true;
  [%test_result: int] state.engine.software_claims ~expect:0;
  [%test_result: int] state.engine.engine_claims ~expect:0;
  [%test_result: int] state.pin_output_enable ~expect:0;
  [%test_result: int] state.pins ~expect:0;
  ignore (ok (Backend.read_program t ~address:0 ~count:1) : int list)
;;

let%test_unit "partial receive progress resumes without loss or duplication" =
  let t = Backend.create () in
  ignore (ok (Backend.load_image t echo_image) : Api.Load_result.t);
  ignore (run_echo t 0xa5 : Api.Transfer.t);
  (* Put one byte back in the DUT TX FIFO for the partial two-byte receive. *)
  ignore (ok (Backend.run t) : Api.Control_ack.t);
  ignore (ok (Backend.transmit t ~budget_cycles:16 [ 0x3c ]) : Api.Transfer.t);
  ignore (ok (Backend.wait_halted t ~budget_cycles:64) : Api.Status.t);
  let partial = ok (Backend.receive t ~budget_cycles:2 ~count:2) in
  [%test_result: int] partial.requested ~expect:2;
  [%test_result: int] partial.transferred ~expect:1;
  [%test_result: int list] partial.data ~expect:[ 0x3c ];
  [%test_result: Api.Transfer_outcome.t] partial.outcome ~expect:Timed_out;
  let empty = ok (Backend.receive t ~budget_cycles:0 ~count:1) in
  [%test_result: int] empty.transferred ~expect:0;
  [%test_result: int list] empty.data ~expect:[];
  [%test_result: Api.Transfer_outcome.t] empty.outcome ~expect:Would_block;
  let resumed = run_echo t 0x7e in
  [%test_result: int] resumed.transferred ~expect:1;
  [%test_result: int list] resumed.data ~expect:[ 0x7e ]
;;

let%test_unit "full host TX queue accepts a concurrent core pop exactly once" =
  let t = Backend.create () in
  ignore (ok (Backend.load_image t echo_image) : Api.Load_result.t);
  ignore (ok (Backend.transmit t ~budget_cycles:0 (List.range 0 8)) : Api.Transfer.t);
  let blocked_cycle = (Backend.status t).cycle in
  let blocked = ok (Backend.transmit t ~budget_cycles:0 [ 8 ]) in
  [%test_result: Api.Transfer_outcome.t] blocked.outcome ~expect:Would_block;
  [%test_result: int] (Backend.status t).cycle ~expect:blocked_cycle;
  ignore (ok (Backend.run t) : Api.Control_ack.t);
  let rec offer_after_edges remaining =
    if remaining = 0 then raise_s [%message "core never made room in the full RX FIFO"];
    let before = (Backend.status t).cycle in
    let transfer = ok (Backend.transmit t ~budget_cycles:0 [ 8 ]) in
    match transfer.outcome with
    | Complete ->
      [%test_result: int] transfer.transferred ~expect:1;
      [%test_result: int] transfer.cycles ~expect:1
    | Would_block ->
      [%test_result: int] (Backend.status t).cycle ~expect:before;
      ignore (ok (Backend.advance t ~cycles:1) : Api.Status.t);
      offer_after_edges (remaining - 1)
    | Timed_out -> raise_s [%message "zero-budget transmit timed out"]
  in
  offer_after_edges 32;
  [%test_result: int] (Backend.status t).rx_count ~expect:8;
  ignore (ok (Backend.wait_halted t ~budget_cycles:64) : Api.Status.t);
  let received = ref (ok (Backend.receive t ~budget_cycles:0 ~count:1)).data in
  for _ = 1 to 8 do
    ignore (ok (Backend.run t) : Api.Control_ack.t);
    ignore (ok (Backend.wait_halted t ~budget_cycles:64) : Api.Status.t);
    received := !received @ (ok (Backend.receive t ~budget_cycles:0 ~count:1)).data
  done;
  [%test_result: int list] !received ~expect:(List.range 0 9)
;;

let%test_unit "queue boundaries and bounded trace overflow are explicit" =
  let t = Backend.create ~trace_capacity:3 () in
  ignore (ok (Backend.load_image t echo_image) : Api.Load_result.t);
  let queued = ok (Backend.transmit t ~budget_cycles:0 (List.range 0 7)) in
  [%test_result: int] queued.transferred ~expect:7;
  let partial = ok (Backend.transmit t ~budget_cycles:0 [ 7; 8 ]) in
  [%test_result: int] partial.transferred ~expect:1;
  [%test_result: Api.Transfer_outcome.t] partial.outcome ~expect:Would_block;
  let empty = ok (Backend.receive t ~budget_cycles:0 ~count:1) in
  [%test_result: Api.Transfer_outcome.t] empty.outcome ~expect:Would_block;
  let timeout_start = (Backend.status t).cycle in
  let timed_out = ok (Backend.receive t ~budget_cycles:3 ~count:1) in
  [%test_result: Api.Transfer_outcome.t] timed_out.outcome ~expect:Timed_out;
  [%test_result: int] timed_out.cycles ~expect:3;
  [%test_result: int] (Backend.status t).cycle ~expect:(timeout_start + 3);
  let cycle_before = (Backend.status t).cycle in
  let trace = ok (Backend.trace_retrieve t ~after:None) in
  [%test_result: int] (List.length trace.records) ~expect:3;
  [%test_result: bool] trace.overflowed ~expect:true;
  [%test_result: int] trace.lost_records ~expect:13;
  [%test_result: int option] trace.oldest_sequence ~expect:(Some 13);
  [%test_result: int option] trace.next_cursor ~expect:(Some 15);
  [%test_result: int list]
    (List.map trace.records ~f:(fun record -> record.sequence))
    ~expect:[ 13; 14; 15 ];
  [%test_result: int list]
    (List.map trace.records ~f:(fun record -> record.timestamp))
    ~expect:[ 17; 18; 19 ];
  [%test_result: bool]
    (List.is_sorted trace.records ~compare:(fun left right ->
       match Int.compare left.timestamp right.timestamp with
       | 0 -> Int.compare left.sequence right.sequence
       | order -> order))
    ~expect:true;
  [%test_result: int] (Backend.status t).cycle ~expect:cycle_before;
  let cursor = (List.hd_exn trace.records).sequence in
  let after = ok (Backend.trace_retrieve t ~after:(Some cursor)) in
  [%test_result: int] (List.length after.records) ~expect:2;
  [%test_result: int option]
    after.next_cursor
    ~expect:(Option.map (List.last trace.records) ~f:(fun record -> record.sequence));
  ok (Backend.trace_clear t);
  let cleared = ok (Backend.trace_retrieve t ~after:None) in
  [%test_result: bool] cleared.overflowed ~expect:false;
  [%test_result: int] cleared.lost_records ~expect:0;
  [%test_result: Api.Trace.Record.t list] cleared.records ~expect:[]
;;

let%test_unit "trace clear preserves sequence and same-timestamp categories are ordered" =
  let t = Backend.create ~trace_capacity:64 () in
  ignore (ok (Backend.configure_pins t (Claim 1)) : unit);
  ok (Backend.trace_clear t);
  ignore (ok (Backend.configure_pins t (Release 1)) : unit);
  let after_clear = ok (Backend.trace_retrieve t ~after:None) in
  [%test_result: int list]
    (List.map after_clear.records ~f:(fun record -> record.sequence))
    ~expect:[ 1 ];
  [%test_result: int] (List.hd_exn after_clear.records).timestamp ~expect:2;
  ok (Backend.trace_clear t);
  ignore (ok (Backend.load_image t echo_image) : Api.Load_result.t);
  ok (Backend.trace_clear t);
  ignore (ok (Backend.run t) : Api.Control_ack.t);
  ignore (ok (Backend.advance t ~cycles:8) : Api.Status.t);
  ignore (ok (Backend.transmit t ~budget_cycles:0 [ 0xa5 ]) : Api.Transfer.t);
  let trace = ok (Backend.trace_retrieve t ~after:None) in
  assert_same_timestamp_order trace.records;
  let final_timestamp = (List.last_exn trace.records).timestamp in
  let simultaneous =
    List.filter trace.records ~f:(fun record -> record.timestamp = final_timestamp)
  in
  [%test_result: Api.Trace.Event.t list]
    (List.map simultaneous ~f:(fun record -> record.event))
    ~expect:
      [ Host_operation { operation = "host-tx"; outcome = "accepted" }
      ; Mechanism { kind = 14; accepted = false; refused = false; completed = true }
      ]
;;

let%test_unit "defined execution fault is inspectable and recoverable" =
  let t = Backend.create ~trace_capacity:64 () in
  let invalid_word = List.hd_exn Encoding.reserved_opcodes lsl Encoding.payload_bits in
  let malformed = Api.Image.create [ invalid_word ] in
  ignore (ok (Backend.load_image t malformed) : Api.Load_result.t);
  ignore (ok (Backend.run t) : Api.Control_ack.t);
  let faulted = ok (Backend.wait_halted t ~budget_cycles:32) in
  [%test_result: bool] faulted.fault.execution_fault ~expect:true;
  [%test_result: int]
    faulted.fault.kind
    ~expect:Hardcaml_protemu.Control_execution.Fault.invalid_base;
  [%test_result: int] faulted.fault.instruction_slot ~expect:0;
  [%test_result: Api.Error.t]
    (error (Backend.step t ~budget_cycles:0))
    ~expect:(Refused { operation = "step"; reason = Execution_faulted });
  [%test_result: int list]
    (ok (Backend.read_program t ~address:0 ~count:1))
    ~expect:[ invalid_word ];
  let trace = ok (Backend.trace_retrieve t ~after:None) in
  assert_same_timestamp_order trace.records;
  let fault_timestamp =
    List.find_map_exn trace.records ~f:(fun record ->
      match record.event with
      | Fault _ -> Some record.timestamp
      | _ -> None)
  in
  [%test_result: Api.Trace.Event.t list]
    (List.filter_map trace.records ~f:(fun record ->
       if record.timestamp = fault_timestamp
       then (
         match record.event with
         | Instruction_boundary _ | Fault _ -> Some record.event
         | _ -> None)
       else None))
    ~expect:[ Instruction_boundary { pc = 0; retired = false }; Fault faulted.fault ];
  let aborted = ok (Backend.abort t) in
  [%test_result: bool] aborted.completed ~expect:true;
  ignore (ok (Backend.load_image t echo_image) : Api.Load_result.t);
  let recovered = run_echo t 0x5a in
  [%test_result: int list] recovered.data ~expect:[ 0x5a ];
  let status = Backend.status t in
  [%test_result: bool] status.normal_halt ~expect:true;
  [%test_result: bool] status.fault.execution_fault ~expect:false;
  [%test_result: bool] status.engine.idle ~expect:true
;;

let%test_unit "external pad changes are applied before the next edge" =
  let t = Backend.create () in
  let cycle = (Backend.status t).cycle in
  ok (Backend.set_external_pins t 0x08);
  [%test_result: int] (Backend.status t).cycle ~expect:cycle;
  ignore (ok (Backend.advance t ~cycles:2) : Api.Status.t);
  [%test_result: int] ((Backend.status t).pin_snapshot land 0x08) ~expect:0x08
;;

let%test_unit "architectural flags are exposed through the integrated top" =
  let t = Backend.create () in
  let flags_image =
    image
      "flags"
      [ Instruction.Ldi { rd = 0; value = 1 }; Cmp_imm { ra = 0; imm = 1 }; Halt ]
  in
  ignore (ok (Backend.load_image t flags_image) : Api.Load_result.t);
  ignore (ok (Backend.run t) : Api.Control_ack.t);
  let final = ok (Backend.wait_halted t ~budget_cycles:32) in
  [%test_result: bool] final.zero ~expect:true;
  [%test_result: int] (List.nth_exn final.registers 0) ~expect:1
;;
