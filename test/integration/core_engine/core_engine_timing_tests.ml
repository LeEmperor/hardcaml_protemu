(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "core_engine_timing_tests.ml" *)
(* Integer-phase P2.6b measurement of the loaded event-to-core-to-bank path. The RAM
   predictor is an independent latency-one array and all host offers are scheduled before
   clock callbacks, including exact-edge asynchronous transitions. *)

open! Core
open! Hardcaml
open! Hardcaml_protemu
module Evsim = Hardcaml_event_driven_sim.Two_state_simulator
module Circuit = Evsim.With_interface (Integrated_core.I) (Integrated_core.O)
module Simulator = Evsim.Simulator

let half_period = 5
let period = 10
let first_rising = 5
let words = [| 0x7804; 0x0000; 0xa300; 0x7804; 0x0001; 0x0000 |]
let bit value = if value then Bits.vdd else Bits.gnd
let bits width value = Bits.of_int_trunc ~width value
let read signal = Simulator.Signal.read signal |> Bits.to_int_trunc

type result =
  { armed : int option
  ; external_ : int option
  ; synchronized : int option
  ; decision : int option
  ; bank_request : int option
  ; bank_commit : int option
  ; halted : int option
  }

let run external_time =
  let memory = Array.create ~len:256 0 in
  let armed = ref None in
  let synchronized = ref None in
  let decision = ref None in
  let bank_request = ref None in
  let bank_commit = ref None in
  let halted = ref None in
  let testbench =
    Circuit.with_processes
      (Integrated_core.create (Scope.create ~flatten_design:true ()))
      (fun _inputs _outputs -> [])
  in
  let simulator = testbench.simulator in
  let inputs = testbench.ports_and_processes.input in
  let outputs = testbench.ports_and_processes.output in
  let schedule time f = Simulator.Expert.schedule_call simulator ~delay:time ~f in
  let set signal value = Simulator.Expert.schedule_external_set simulator signal value in
  let rec settle remaining f =
    if remaining = 0 then f () else schedule 0 (fun () -> settle (remaining - 1) f)
  in
  let pulse signal ~edge value =
    let time = first_rising + (edge * period) in
    schedule (time - 2) (fun () -> set signal value);
    schedule (time + 1) (fun () -> set signal (Bits.zero (Bits.width value)))
  in
  schedule 0 (fun () ->
    set inputs.en_i.signal Bits.vdd;
    set inputs.transfer_rx_ready_i.signal Bits.vdd;
    set inputs.reset_i.signal Bits.vdd);
  schedule 6 (fun () -> set inputs.reset_i.signal Bits.gnd);
  pulse inputs.software_claim_valid_i.signal ~edge:1 Bits.vdd;
  schedule 8 (fun () -> set inputs.software_claim_mask_i.signal (bits 8 1));
  pulse inputs.load_start_valid_i.signal ~edge:2 Bits.vdd;
  schedule 18 (fun () -> set inputs.load_length_i.signal (bits 9 6));
  Array.iteri words ~f:(fun address data ->
    let edge = 3 + address in
    let time = first_rising + (edge * period) in
    schedule (time - 2) (fun () ->
      set inputs.load_address_i.signal (bits 9 address);
      set inputs.load_data_i.signal (bits 16 data);
      set inputs.load_write_valid_i.signal Bits.vdd);
    schedule (time + 1) (fun () -> set inputs.load_write_valid_i.signal Bits.gnd));
  Array.iteri words ~f:(fun address expected ->
    let edge = 9 + (address * 2) in
    let time = first_rising + (edge * period) in
    schedule (time - 2) (fun () ->
      set inputs.readback_address_i.signal (bits 9 address);
      set inputs.readback_expected_i.signal (bits 16 expected);
      set inputs.readback_verify_i.signal Bits.vdd;
      set inputs.readback_valid_i.signal Bits.vdd);
    schedule (time + 1) (fun () ->
      set inputs.readback_valid_i.signal Bits.gnd;
      set inputs.readback_verify_i.signal Bits.gnd));
  pulse inputs.load_complete_valid_i.signal ~edge:21 Bits.vdd;
  pulse inputs.run_valid_i.signal ~edge:22 Bits.vdd;
  Option.iter external_time ~f:(fun time ->
    schedule time (fun () -> set inputs.pin_async_i.signal (bits 8 0x08)));
  let edges = 48 in
  List.iter (List.init edges ~f:Fn.id) ~f:(fun edge ->
    let time = first_rising + (edge * period) in
    schedule time (fun () ->
      let mem_enable = read outputs.prog_mem_enable_o.signal <> 0 in
      let mem_write = read outputs.prog_mem_write_enable_o.signal <> 0 in
      let address = read outputs.prog_mem_address_o.signal in
      let data = read outputs.prog_mem_write_data_o.signal in
      if read outputs.mechanism_completion_valid_o.signal <> 0
         && read outputs.mechanism_kind_o.signal
            = Control_execution.Mechanism_kind.wait_edge
         && Option.is_none !decision
      then decision := Some time;
      if read outputs.mechanism_request_valid_o.signal <> 0
         && read outputs.mechanism_kind_o.signal
            = Control_execution.Mechanism_kind.write_pins_imm
         && Option.is_some !decision
         && Option.is_none !bank_request
      then bank_request := Some time;
      settle 32 (fun () -> set inputs.clock_i.signal Bits.vdd);
      settle 40 (fun () ->
        if mem_enable
        then
          if mem_write
          then memory.(address) <- data
          else set inputs.prog_mem_read_data_i.signal (bits 16 memory.(address))));
    schedule (time + half_period) (fun () ->
      settle 32 (fun () -> set inputs.clock_i.signal Bits.gnd));
    schedule (time + 1) (fun () ->
      if read outputs.timing_busy_o.signal <> 0 && Option.is_none !armed
      then armed := Some time;
      if read outputs.rising_o.signal land 0x08 <> 0 && Option.is_none !synchronized
      then synchronized := Some time;
      if read outputs.pins_o.signal land 1 <> 0 && Option.is_none !bank_commit
      then bank_commit := Some time;
      if read outputs.halted_o.signal <> 0
         && read outputs.normal_halt_o.signal <> 0
         && Option.is_none !halted
      then halted := Some time));
  Simulator.run simulator ~time_limit:(first_rising + (edges * period));
  { armed = !armed
  ; external_ = external_time
  ; synchronized = !synchronized
  ; decision = !decision
  ; bank_request = !bank_request
  ; bank_commit = !bank_commit
  ; halted = !halted
  }
;;

let get name = function
  | Some value -> value
  | None -> raise_s [%message "missing P2.6b timing observation" (name : string)]
;;

let%test_unit "P2.6b sweeps the real loaded core path across every external phase" =
  let calibration = run None in
  let armed = get "armed" calibration.armed in
  let latencies = ref [] in
  for phase = 0 to period - 1 do
    let external_ = armed + period + phase in
    let result = run (Some external_) in
    let synchronized = get "synchronized" result.synchronized in
    let decision = get "decision" result.decision in
    let bank_request = get "bank request" result.bank_request in
    let bank_commit = get "bank commit" result.bank_commit in
    ignore (get "halted" result.halted : int);
    if synchronized - external_ < 10
       || synchronized - external_ > 19
       || decision - synchronized <> 20
       || bank_request - decision <> 30
       || bank_commit <> bank_request
    then
      raise_s
        [%message
          "P2.6b phase mismatch"
            (phase : int)
            (external_ : int)
            (synchronized : int)
            (decision : int)
            (bank_request : int)
            (bank_commit : int)];
    latencies := (bank_commit - external_) :: !latencies
  done;
  [%test_result: int]
    (List.min_elt !latencies ~compare:Int.compare |> Option.value_exn)
    ~expect:60;
  [%test_result: int]
    (List.max_elt !latencies ~compare:Int.compare |> Option.value_exn)
    ~expect:69
;;
