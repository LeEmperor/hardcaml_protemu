(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "simulator_backend.ml" *)
(* Deterministic host backend for one live Cyclesim instance of [Integrated_core].

   This module owns the external latency-one program RAM, clock, persistent pad state,
   queue handshakes, and bounded observation trace. All device mutations cross real DUT
   ports; the functional model is not used as the device and internal state is never
   forced.
*)

open! Core
open! Hardcaml
open! Hardcaml_protemu
module Api = Protemu_host.Host_api
module Sim = Cyclesim.With_interface (Integrated_core.I) (Integrated_core.O)

type request =
  | Idle
  | Reset
  | Load_start of int
  | Load_write of int * int
  | Load_complete
  | Readback of
      { address : int
      ; verify : bool
      ; expected : int
      }
  | Run
  | Stop
  | Abort
  | Step
  | Pin_claim of int
  | Pin_release of int
  | Host_tx of int
  | Host_rx

type view =
  { load_start_accepted : bool
  ; load_start_rejected : bool
  ; load_write_accepted : bool
  ; load_write_rejected : bool
  ; load_complete_accepted : bool
  ; load_complete_rejected : bool
  ; readback_accepted : bool
  ; readback_rejected : bool
  ; readback_response_valid : bool
  ; readback_response_data : int
  ; readback_response_match : bool
  ; run_accepted : bool
  ; run_rejected : bool
  ; stop_accepted : bool
  ; stop_rejected : bool
  ; abort_accepted : bool
  ; abort_rejected : bool
  ; step_accepted : bool
  ; step_rejected : bool
  ; software_request_rejected : bool
  ; tx_valid : bool
  ; tx_data : int
  ; rx_ready : bool
  ; instruction_boundary : bool
  ; retired : bool
  ; mechanism_kind : int
  ; mechanism_accepted : bool
  ; mechanism_refused : bool
  ; mechanism_completion : bool
  ; transfer_done : bool
  ; transfer_fault : bool
  ; transfer_rx_valid : bool
  ; transfer_rx_data : int
  ; pins : int
  ; pin_output_enable : int
  ; fault : Api.Fault.t
  ; pc : int
  }

type t =
  { sim : Sim.t
  ; words : int option array
  ; mutable read_data : int
  ; mutable pin_async : int
  ; mutable occupied : int
  ; mutable cycle : int
  ; trace : Api.Trace.Record.t Queue.t
  ; trace_capacity : int
  ; mutable trace_enabled : bool
  ; mutable trace_lost : int
  ; mutable trace_sequence : int
  ; mutable previous : view option
  }

let bool signal = Bits.to_bool !signal
let int signal = Bits.to_int_trunc !signal
let set_bool signal value = signal := Bits.of_bool value
let set_int signal value = signal := Bits.of_int_trunc ~width:(Bits.width !signal) value
let outputs t = Cyclesim.outputs t.sim
let outputs_before t = Cyclesim.outputs ~clock_edge:Before t.sim

let settle t =
  Cyclesim.cycle_check t.sim;
  Cyclesim.cycle_before_clock_edge t.sim
;;

let clear_inputs (i : _ Integrated_core.I.t) =
  set_bool i.reset_i false;
  set_bool i.en_i true;
  set_bool i.load_start_valid_i false;
  set_int i.load_length_i 0;
  set_bool i.load_write_valid_i false;
  set_int i.load_address_i 0;
  set_int i.load_data_i 0;
  set_bool i.load_complete_valid_i false;
  set_bool i.readback_valid_i false;
  set_int i.readback_address_i 0;
  set_bool i.readback_verify_i false;
  set_int i.readback_expected_i 0;
  set_bool i.run_valid_i false;
  set_bool i.stop_valid_i false;
  set_bool i.abort_valid_i false;
  set_bool i.step_valid_i false;
  set_int i.pin_async_i 0;
  set_int i.occupied_i 0;
  set_bool i.software_claim_valid_i false;
  set_int i.software_claim_mask_i 0;
  set_bool i.software_release_valid_i false;
  set_int i.software_release_mask_i 0;
  set_bool i.tx_ready_i false;
  set_bool i.rx_valid_i false;
  set_int i.rx_data_i 0;
  set_bool i.transfer_rx_ready_i true
;;

let drive_request (i : _ Integrated_core.I.t) = function
  | Idle -> ()
  | Reset -> set_bool i.reset_i true
  | Load_start length ->
    set_bool i.load_start_valid_i true;
    set_int i.load_length_i length
  | Load_write (address, data) ->
    set_bool i.load_write_valid_i true;
    set_int i.load_address_i address;
    set_int i.load_data_i data
  | Load_complete -> set_bool i.load_complete_valid_i true
  | Readback { address; verify; expected } ->
    set_bool i.readback_valid_i true;
    set_int i.readback_address_i address;
    set_bool i.readback_verify_i verify;
    set_int i.readback_expected_i expected
  | Run -> set_bool i.run_valid_i true
  | Stop -> set_bool i.stop_valid_i true
  | Abort -> set_bool i.abort_valid_i true
  | Step -> set_bool i.step_valid_i true
  | Pin_claim mask ->
    set_bool i.software_claim_valid_i true;
    set_int i.software_claim_mask_i mask
  | Pin_release mask ->
    set_bool i.software_release_valid_i true;
    set_int i.software_release_mask_i mask
  | Host_tx data ->
    set_bool i.rx_valid_i true;
    set_int i.rx_data_i data
  | Host_rx -> set_bool i.tx_ready_i true
;;

let fault_of_outputs (o : _ Integrated_core.O.t) =
  { Api.Fault.fetch_fault = bool o.fetch_fault_o
  ; execution_fault = bool o.execution_fault_o
  ; kind = int o.fault_kind_o
  ; instruction_slot = int o.fault_instruction_slot_o
  ; address = int o.fault_address_o
  ; reason = int o.fault_reason_o
  }
;;

let view (o : _ Integrated_core.O.t) =
  { load_start_accepted = bool o.load_start_accepted_o
  ; load_start_rejected = bool o.load_start_rejected_o
  ; load_write_accepted = bool o.load_write_accepted_o
  ; load_write_rejected = bool o.load_write_rejected_o
  ; load_complete_accepted = bool o.load_complete_accepted_o
  ; load_complete_rejected = bool o.load_complete_rejected_o
  ; readback_accepted = bool o.readback_accepted_o
  ; readback_rejected = bool o.readback_rejected_o
  ; readback_response_valid = bool o.readback_response_valid_o
  ; readback_response_data = int o.readback_response_data_o
  ; readback_response_match = bool o.readback_response_match_o
  ; run_accepted = bool o.run_accepted_o
  ; run_rejected = bool o.run_rejected_o
  ; stop_accepted = bool o.stop_accepted_o
  ; stop_rejected = bool o.stop_rejected_o
  ; abort_accepted = bool o.abort_accepted_o
  ; abort_rejected = bool o.abort_rejected_o
  ; step_accepted = bool o.step_accepted_o
  ; step_rejected = bool o.step_rejected_o
  ; software_request_rejected = bool o.software_request_rejected_o
  ; tx_valid = bool o.tx_valid_o
  ; tx_data = int o.tx_data_o
  ; rx_ready = bool o.rx_ready_o
  ; instruction_boundary = bool o.instruction_boundary_o
  ; retired = bool o.retired_o
  ; mechanism_kind = int o.mechanism_kind_o
  ; mechanism_accepted = bool o.mechanism_accepted_o
  ; mechanism_refused = bool o.mechanism_refused_o
  ; mechanism_completion = bool o.mechanism_completion_valid_o
  ; transfer_done = bool o.transfer_done_o
  ; transfer_fault = bool o.transfer_fault_o
  ; transfer_rx_valid = bool o.transfer_rx_valid_o
  ; transfer_rx_data = int o.transfer_rx_data_o
  ; pins = int o.pins_o
  ; pin_output_enable = int o.pin_oe_o
  ; fault = fault_of_outputs o
  ; pc = int o.pc_o
  }
;;

let add_trace t ~timestamp event =
  if t.trace_enabled
  then (
    if Queue.length t.trace = t.trace_capacity
    then (
      ignore (Queue.dequeue_exn t.trace : Api.Trace.Record.t);
      t.trace_lost <- t.trace_lost + 1);
    let record = { Api.Trace.Record.sequence = t.trace_sequence; timestamp; event } in
    t.trace_sequence <- t.trace_sequence + 1;
    Queue.enqueue t.trace record)
;;

let capture_trace t ~timestamp ~operation before after =
  Option.iter operation ~f:(fun (operation, outcome) ->
    add_trace t ~timestamp (Host_operation { operation; outcome }));
  if after.instruction_boundary
  then
    add_trace
      t
      ~timestamp
      (Instruction_boundary { pc = after.pc; retired = after.retired });
  if after.mechanism_accepted || after.mechanism_refused || after.mechanism_completion
  then
    add_trace
      t
      ~timestamp
      (Mechanism
         { kind = after.mechanism_kind
         ; accepted = after.mechanism_accepted
         ; refused = after.mechanism_refused
         ; completed = after.mechanism_completion
         });
  if after.transfer_done || after.transfer_fault
  then
    add_trace
      t
      ~timestamp
      (Engine_completion
         { fault = after.transfer_fault
         ; rx_valid = after.transfer_rx_valid
         ; rx_data = after.transfer_rx_data
         });
  if before.pins <> after.pins || before.pin_output_enable <> after.pin_output_enable
  then
    add_trace
      t
      ~timestamp
      (Pin_transition
         { old_value = before.pins
         ; new_value = after.pins
         ; old_output_enable = before.pin_output_enable
         ; new_output_enable = after.pin_output_enable
         });
  if (after.fault.fetch_fault && not before.fault.fetch_fault)
     || (after.fault.execution_fault && not before.fault.execution_fault)
  then add_trace t ~timestamp (Fault after.fault)
;;

let request_outcome request before =
  let accepted, rejected =
    match request with
    | Load_start _ -> before.load_start_accepted, before.load_start_rejected
    | Load_write _ -> before.load_write_accepted, before.load_write_rejected
    | Load_complete -> before.load_complete_accepted, before.load_complete_rejected
    | Readback _ -> before.readback_accepted, before.readback_rejected
    | Run -> before.run_accepted, before.run_rejected
    | Stop -> before.stop_accepted, before.stop_rejected
    | Abort -> before.abort_accepted, before.abort_rejected
    | Step -> before.step_accepted, before.step_rejected
    | Pin_claim _ | Pin_release _ ->
      not before.software_request_rejected, before.software_request_rejected
    | Host_tx _ -> before.rx_ready, not before.rx_ready
    | Host_rx -> before.tx_valid, not before.tx_valid
    | Idle | Reset -> true, false
  in
  if accepted then "accepted" else if rejected then "rejected" else "observed"
;;

let cycle ?operation t request =
  let i = Cyclesim.inputs t.sim in
  clear_inputs i;
  set_int i.pin_async_i t.pin_async;
  set_int i.occupied_i t.occupied;
  drive_request i request;
  Cyclesim.cycle_check t.sim;
  Cyclesim.cycle_before_clock_edge t.sim;
  let o_before = outputs_before t in
  let before = view o_before in
  let mem_enable = bool o_before.prog_mem_enable_o in
  let mem_write = bool o_before.prog_mem_write_enable_o in
  let address = int o_before.prog_mem_address_o in
  let write_data = int o_before.prog_mem_write_data_o in
  Cyclesim.cycle_at_clock_edge t.sim;
  Cyclesim.cycle_after_clock_edge t.sim;
  if mem_enable
  then
    if mem_write
    then (
      t.words.(address) <- Some write_data;
      t.read_data <- 0xdead)
    else t.read_data <- Option.value t.words.(address) ~default:0xbeef;
  i.prog_mem_read_data_i := Bits.of_int_trunc ~width:16 t.read_data;
  settle t;
  t.cycle <- t.cycle + 1;
  let after = view (outputs_before t) in
  let operation =
    Option.map operation ~f:(fun name -> name, request_outcome request before)
  in
  let previous = Option.value t.previous ~default:before in
  capture_trace t ~timestamp:t.cycle ~operation previous after;
  t.previous <- Some after;
  before, after
;;

let create ?(trace_capacity = 256) () =
  if trace_capacity <= 0 then invalid_arg "trace_capacity must be positive";
  let sim = Sim.create (Integrated_core.create (Scope.create ~flatten_design:true ())) in
  let t =
    { sim
    ; words = Array.create ~len:Protocol_core.Config.program_depth None
    ; read_data = 0xa5a5
    ; pin_async = 0
    ; occupied = 0
    ; cycle = 0
    ; trace = Queue.create ()
    ; trace_capacity
    ; trace_enabled = false
    ; trace_lost = 0
    ; trace_sequence = 0
    ; previous = None
    }
  in
  let i = Cyclesim.inputs sim in
  i.prog_mem_read_data_i := Bits.of_int_trunc ~width:16 t.read_data;
  ignore (cycle t Reset : view * view);
  t.cycle <- 0;
  t.previous <- Some (view (outputs t));
  t.trace_enabled <- true;
  t
;;

let discover t =
  { Api.Discovery.api_version = Api.Constants.api
  ; protocol_version = Api.Constants.protocol
  ; isa_id = Api.Constants.isa_id
  ; isa_version = Api.Constants.isa_version
  ; backend = "integrated-core-cyclesim"
  ; capabilities =
      [ Api.Capability.Program_load
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
  ; image =
      { Api.Image_format.name = Api.Constants.image_format
      ; version = Api.Constants.image_format_version
      ; layout = Protemu_isa.Assembler.Memory.word16.name
      ; word_bits = Protocol_core.Config.program_width
      ; depth_words = Protocol_core.Config.program_depth
      ; address_unit = Memory_word
      ; byte_order = Little_endian
      }
  ; pin_count = Protemu_isa.Pins.count
  ; queues =
      [ { Api.Queue_info.name = "host-tx"
        ; direction = "host-to-device-rx-fifo"
        ; capacity_bytes = 8
        }
      ; { Api.Queue_info.name = "host-rx"
        ; direction = "device-tx-fifo-to-host"
        ; capacity_bytes = 8
        }
      ]
  ; engine_count = 1
  ; trace_capacity = t.trace_capacity
  ; trace_timestamp_unit = "rising-edge-cycle"
  ; trace_storage = "simulator-side-drop-oldest"
  }
;;

let loaded_image t =
  let o = outputs t in
  { Api.Loaded_image.valid = bool o.image_valid_o
  ; load_active = bool o.load_active_o
  ; length_words = int o.image_length_o
  ; words_written = int o.words_written_o
  ; words_verified = int o.words_verified_o
  ; verification_failed = bool o.verification_failed_o
  }
;;

let status t =
  let o = outputs t in
  let registers = !(o.registers_o) in
  let descriptor = !(o.descriptor_o) in
  let chunks bits count =
    List.init count ~f:(fun index ->
      Bits.select bits ~high:((index * 16) + 15) ~low:(index * 16) |> Bits.to_int_trunc)
  in
  { Api.Status.cycle = t.cycle
  ; halted = bool o.halted_o
  ; execution_active = bool o.execution_active_o
  ; normal_halt = bool o.normal_halt_o
  ; pc = int o.pc_o
  ; phase = int o.phase_o
  ; registers = chunks registers 8
  ; zero = bool o.zero_o
  ; carry = bool o.carry_o
  ; negative = bool o.negative_o
  ; descriptor_words = chunks descriptor 9
  ; events = int o.status_o
  ; event_overflow = int o.status_overflow_o
  ; pins = int o.pins_o
  ; pin_output_enable = int o.pin_oe_o
  ; pin_snapshot = int o.snapshot_o
  ; tx_count = int o.tx_count_o
  ; rx_count = int o.rx_count_o
  ; fetch_cycles = int o.fetch_cycles_o
  ; execute_cycles = int o.execute_cycles_o
  ; stall_cycles = int o.stall_cycles_o
  ; instruction_count = int o.instruction_count_o
  ; extension_fetches = int o.extension_fetches_o
  ; total_cycles = int o.total_cycles_o
  ; image = loaded_image t
  ; engine =
      { Api.Engine_status.idle = bool o.engines_idle_o
      ; timing_busy = bool o.timing_busy_o
      ; transfer_busy = bool o.transfer_busy_o
      ; transfer_done = bool o.transfer_done_o
      ; transfer_fault = bool o.transfer_fault_o
      ; software_claims = int o.software_claim_o
      ; engine_claims = int o.engine_claim_o
      }
  ; fault = fault_of_outputs o
  }
;;

let operation_needs_image operation =
  String.equal operation "run"
  || String.equal operation "step"
  || String.equal operation "read-program"
;;

let refusal (s : Api.Status.t) operation =
  let reason =
    if not s.halted
    then Api.Refusal.Active_execution
    else if not s.engine.idle
    then Engines_active
    else if operation_needs_image operation && not s.image.valid
    then No_verified_image
    else if s.fault.execution_fault
    then Execution_faulted
    else if s.normal_halt && String.equal operation "step"
    then Terminal_halt
    else Hardware_rejected
  in
  Error (Api.Error.Refused { operation; reason })
;;

let offer t ~operation request accepted =
  let prior = status t in
  let before, _ = cycle ~operation t request in
  if accepted before then Ok () else refusal prior operation
;;

let read_word t ~operation ~verify ~address ~expected =
  match
    offer
      t
      ~operation
      (Readback { address; verify; expected })
      (fun v -> v.readback_accepted)
  with
  | Error _ as error -> error
  | Ok () ->
    let _, after = cycle t Idle in
    if not after.readback_response_valid
    then
      Error
        (Api.Error.Backend_invariant
           { operation
           ; detail = "accepted program read produced no latency-one response"
           })
    else Ok (after.readback_response_data, after.readback_response_match)
;;

let load_image t image =
  match Api.Image.validate (discover t) image with
  | Error _ as error -> error
  | Ok () ->
    let words = Array.of_list image.words in
    let started_cycle = t.cycle + 1 in
    (match
       offer
         t
         ~operation:"load-start"
         (Load_start (Array.length words))
         (fun v -> v.load_start_accepted)
     with
     | Error _ as error -> error
     | Ok () ->
       let rec writes address =
         if address = Array.length words
         then Ok ()
         else (
           match
             offer
               t
               ~operation:"load-write"
               (Load_write (address, words.(address)))
               (fun v -> v.load_write_accepted)
           with
           | Error _ as error -> error
           | Ok () -> writes (address + 1))
       in
       let rec verify address =
         if address = Array.length words
         then Ok ()
         else (
           match
             read_word
               t
               ~operation:"load-verify"
               ~verify:true
               ~address
               ~expected:words.(address)
           with
           | Error _ as error -> error
           | Ok (actual, matches) ->
             if matches
             then verify (address + 1)
             else
               Error
                 (Api.Error.Verification_mismatch
                    { address; expected = words.(address); actual }))
       in
       (match writes 0 with
        | Error _ as error -> error
        | Ok () ->
          (match verify 0 with
           | Error _ as error -> error
           | Ok () ->
             (match
                offer t ~operation:"load-complete" Load_complete (fun v ->
                  v.load_complete_accepted)
              with
              | Error _ as error -> error
              | Ok () ->
                Ok
                  { Api.Load_result.words = Array.length words
                  ; started_cycle
                  ; completed_cycle = t.cycle
                  }))))
;;

let read_program t ~address ~count =
  let depth = Protocol_core.Config.program_depth in
  if address < 0 || count < 0 || address > depth || count > depth - address
  then
    Error
      (Api.Error.Invalid_argument
         { operation = "read-program"; detail = "address/count outside program memory" })
  else if count = 0
  then Ok []
  else (
    let state = status t in
    if not state.halted
    then refusal state "read-program"
    else if not state.engine.idle
    then refusal state "read-program"
    else if not state.image.valid
    then refusal state "read-program"
    else if address > state.image.length_words
            || count > state.image.length_words - address
    then
      Error
        (Api.Error.Refused
           { operation = "read-program"; reason = Api.Refusal.Image_bounds })
    else (
      let rec loop offset words =
        if offset = count
        then Ok (List.rev words)
        else (
          match
            read_word
              t
              ~operation:"read-program"
              ~verify:false
              ~address:(address + offset)
              ~expected:0
          with
          | Error (Api.Error.Refused { reason; _ }) ->
            Error
              (Api.Error.Read_failed
                 { operation = "read-program"
                 ; address
                 ; count
                 ; failing_address = address + offset
                 ; completed = offset
                 ; words = List.rev words
                 ; cause = Refused reason
                 })
          | Error (Api.Error.Backend_invariant _) ->
            Error
              (Api.Error.Read_failed
                 { operation = "read-program"
                 ; address
                 ; count
                 ; failing_address = address + offset
                 ; completed = offset
                 ; words = List.rev words
                 ; cause = Missing_fixed_latency_response
                 })
          | Error _ as error -> error
          | Ok (word, _) -> loop (offset + 1) (word :: words))
      in
      loop 0 []))
;;

let verify_image t image =
  match Api.Image.validate (discover t) image with
  | Error _ as error -> error
  | Ok () ->
    let loaded = loaded_image t in
    if not loaded.valid
    then
      Error
        (Api.Error.Refused
           { operation = "verify-image"; reason = Api.Refusal.No_verified_image })
    else if loaded.length_words <> List.length image.words
    then
      Error
        (Api.Error.Incompatible_image
           { field = "length_words"
           ; required = Int.to_string (List.length image.words)
           ; actual = Int.to_string loaded.length_words
           })
    else (
      match read_program t ~address:0 ~count:(List.length image.words) with
      | Error _ as error -> error
      | Ok actual ->
        (match
           List.zip_exn image.words actual
           |> List.find_mapi ~f:(fun address (expected, actual) ->
             if expected = actual then None else Some (address, expected, actual))
         with
         | None -> Ok ()
         | Some (address, expected, actual) ->
           Error (Api.Error.Verification_mismatch { address; expected; actual })))
;;

let run t =
  let accepted_cycle = t.cycle + 1 in
  match offer t ~operation:"run" Run (fun v -> v.run_accepted) with
  | Error _ as error -> error
  | Ok () ->
    Ok
      { Api.Control_ack.operation = "run"
      ; accepted_cycle
      ; completed = false
      ; completed_cycle = None
      }
;;

let wait_until t ~operation ~budget_cycles ~accepted predicate =
  if budget_cycles < 0
  then
    Error
      (Api.Error.Invalid_argument
         { operation; detail = "cycle budget must be nonnegative" })
  else (
    let rec loop remaining =
      let state = status t in
      if predicate state
      then Ok state
      else if remaining = 0
      then Error (Api.Error.Timeout { operation; budget_cycles; accepted })
      else (
        ignore (cycle t Idle : view * view);
        loop (remaining - 1))
    in
    loop budget_cycles)
;;

let stop t ~budget_cycles =
  if budget_cycles < 0
  then
    Error
      (Api.Error.Invalid_argument
         { operation = "stop"; detail = "cycle budget must be nonnegative" })
  else (
    let accepted_cycle = t.cycle + 1 in
    match offer t ~operation:"stop" Stop (fun v -> v.stop_accepted) with
    | Error _ as error -> error
    | Ok () ->
      (match
         wait_until t ~operation:"stop" ~budget_cycles ~accepted:true (fun state ->
           state.halted)
       with
       | Error _ as error -> error
       | Ok state ->
         Ok
           { Api.Control_ack.operation = "stop"
           ; accepted_cycle
           ; completed = true
           ; completed_cycle = Some state.cycle
           }))
;;

let abort t =
  let accepted_cycle = t.cycle + 1 in
  match offer t ~operation:"abort" Abort (fun v -> v.abort_accepted) with
  | Error _ as error -> error
  | Ok () ->
    let state = status t in
    let completed =
      state.halted
      && state.engine.idle
      && state.engine.software_claims = 0
      && state.engine.engine_claims = 0
      && state.pin_output_enable = 0
    in
    Ok
      { Api.Control_ack.operation = "abort"
      ; accepted_cycle
      ; completed
      ; completed_cycle = Option.some_if completed t.cycle
      }
;;

let step t ~budget_cycles =
  if budget_cycles < 0
  then
    Error
      (Api.Error.Invalid_argument
         { operation = "step"; detail = "cycle budget must be nonnegative" })
  else (
    let accepted_cycle = t.cycle + 1 in
    match offer t ~operation:"step" Step (fun v -> v.step_accepted) with
    | Error _ as error -> error
    | Ok () ->
      (match
         wait_until t ~operation:"step" ~budget_cycles ~accepted:true (fun state ->
           state.halted)
       with
       | Error _ as error -> error
       | Ok state ->
         Ok
           { Api.Control_ack.operation = "step"
           ; accepted_cycle
           ; completed = true
           ; completed_cycle = Some state.cycle
           }))
;;

let configure_pins t configuration =
  let operation, request, mask =
    match configuration with
    | Api.Pin_configuration.Claim mask -> "pin-claim", Pin_claim mask, mask
    | Release mask -> "pin-release", Pin_release mask, mask
  in
  if mask < 0 || mask >= 1 lsl Protemu_isa.Pins.count
  then
    Error
      (Api.Error.Invalid_argument
         { operation; detail = "pin mask is outside the eight-pin bank" })
  else (
    let before, _ = cycle ~operation t request in
    if before.software_request_rejected
    then Error (Api.Error.Refused { operation; reason = Api.Refusal.Pin_conflict })
    else Ok ())
;;

let transfer_outcome ~budget_cycles ~blocked =
  if blocked && budget_cycles = 0
  then Api.Transfer_outcome.Would_block
  else if blocked
  then Timed_out
  else Complete
;;

let transmit t ~budget_cycles bytes =
  if budget_cycles < 0
  then
    Error
      (Api.Error.Invalid_argument
         { operation = "transmit"; detail = "cycle budget must be nonnegative" })
  else if List.exists bytes ~f:(fun byte -> byte < 0 || byte > 0xff)
  then
    Error
      (Api.Error.Invalid_argument
         { operation = "transmit"; detail = "bytes must be in 0..255" })
  else (
    let requested = List.length bytes in
    let rec loop bytes transferred cycles waited =
      match bytes with
      | [] ->
        { Api.Transfer.requested; transferred; data = []; cycles; outcome = Complete }
      | byte :: rest ->
        let ready = bool (outputs t).rx_ready_o in
        if ready
        then (
          let before, _ = cycle ~operation:"host-tx" t (Host_tx byte) in
          if before.rx_ready
          then loop rest (transferred + 1) (cycles + 1) waited
          else
            { Api.Transfer.requested
            ; transferred
            ; data = []
            ; cycles = cycles + 1
            ; outcome = transfer_outcome ~budget_cycles ~blocked:true
            })
        else if budget_cycles = 0 || waited = budget_cycles
        then
          { Api.Transfer.requested
          ; transferred
          ; data = []
          ; cycles
          ; outcome = transfer_outcome ~budget_cycles ~blocked:true
          }
        else (
          ignore (cycle t Idle : view * view);
          loop bytes transferred (cycles + 1) (waited + 1))
    in
    Ok (loop bytes 0 0 0))
;;

let receive t ~budget_cycles ~count =
  if budget_cycles < 0 || count < 0
  then
    Error
      (Api.Error.Invalid_argument
         { operation = "receive"; detail = "count and cycle budget must be nonnegative" })
  else (
    let rec loop remaining data cycles waited =
      if remaining = 0
      then
        { Api.Transfer.requested = count
        ; transferred = List.length data
        ; data = List.rev data
        ; cycles
        ; outcome = Complete
        }
      else (
        let valid = bool (outputs t).tx_valid_o in
        if valid
        then (
          let before, _ = cycle ~operation:"host-rx" t Host_rx in
          if before.tx_valid
          then loop (remaining - 1) (before.tx_data :: data) (cycles + 1) waited
          else
            { Api.Transfer.requested = count
            ; transferred = List.length data
            ; data = List.rev data
            ; cycles = cycles + 1
            ; outcome = transfer_outcome ~budget_cycles ~blocked:true
            })
        else if budget_cycles = 0 || waited = budget_cycles
        then
          { Api.Transfer.requested = count
          ; transferred = List.length data
          ; data = List.rev data
          ; cycles
          ; outcome = transfer_outcome ~budget_cycles ~blocked:true
          }
        else (
          ignore (cycle t Idle : view * view);
          loop remaining data (cycles + 1) (waited + 1)))
    in
    Ok (loop count [] 0 0))
;;

let advance t ~cycles =
  if cycles < 0
  then
    Error
      (Api.Error.Invalid_argument
         { operation = "advance"; detail = "cycle count must be nonnegative" })
  else (
    for _ = 1 to cycles do
      ignore (cycle t Idle : view * view)
    done;
    Ok (status t))
;;

let wait_halted t ~budget_cycles =
  wait_until t ~operation:"wait-halted" ~budget_cycles ~accepted:false (fun state ->
    state.halted)
;;

let set_external_pins t value =
  if value < 0 || value >= 1 lsl Protemu_isa.Pins.count
  then
    Error
      (Api.Error.Invalid_argument
         { operation = "set-external-pins"; detail = "pad value is outside 0..255" })
  else (
    t.pin_async <- value;
    Ok ())
;;

let set_occupied_pins t value =
  if value < 0 || value >= 1 lsl Protemu_isa.Pins.count
  then
    Error
      (Api.Error.Invalid_argument
         { operation = "set-occupied-pins"; detail = "mask is outside 0..255" })
  else (
    t.occupied <- value;
    Ok ())
;;

let trace_enable t enabled =
  t.trace_enabled <- enabled;
  Ok ()
;;

let trace_retrieve t ~after =
  let records =
    Queue.to_list t.trace
    |> List.filter ~f:(fun record ->
      Option.value_map after ~default:true ~f:(fun cursor -> record.sequence > cursor))
  in
  let oldest_sequence =
    Option.map (Queue.peek t.trace) ~f:(fun record -> record.sequence)
  in
  let next_cursor =
    match List.last records, after with
    | Some record, _ -> Some record.sequence
    | None, cursor -> cursor
  in
  Ok
    { Api.Trace.Retrieval.records
    ; next_cursor
    ; oldest_sequence
    ; overflowed = t.trace_lost > 0
    ; lost_records = t.trace_lost
    ; capacity = t.trace_capacity
    ; enabled = t.trace_enabled
    }
;;

let trace_clear t =
  Queue.clear t.trace;
  t.trace_lost <- 0;
  Ok ()
;;
