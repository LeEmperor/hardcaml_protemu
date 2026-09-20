(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "observed_transfer_bank_timing_testbench.ml" *)
(* Timestamped adapter for the observed-transfer and pin-bank composition. The external
   schedule and peer come from the primitive testbench; this adapter observes only the
   lane and registered bank boundaries of the composed DUT. *)

open! Core
open! Hardcaml
open! Hardcaml_protemu
open! Observed_transfer_timing_testbench
module Evsim = Hardcaml_event_driven_sim.Two_state_simulator

module Circuit =
  Evsim.With_interface (Observed_transfer_bank.I) (Observed_transfer_bank.O)

module Simulator = Evsim.Simulator
module F_model = Protemu_f_model

module Sample = struct
  type t =
    { edge : int
    ; time : int
    ; lane_pins : int
    ; lane_oe : int
    ; bank_pins : int
    ; bank_oe : int
    ; engine_claim : int
    ; software_claim : int
    ; done_ : int
    ; transaction_done : int
    ; rx_valid : int
    ; rx_data : int
    ; bank_rejected : int
    ; bank_conflict : int
    }
  [@@deriving sexp_of]
end

module Run = struct
  type t =
    { samples : Sample.t list
    ; lane_transactions : Pin_transaction.t list
    ; expected_bank_transactions : Pin_transaction.t list
    ; bank_transactions : Pin_transaction.t list
    }
  [@@deriving sexp_of]
end

let bit value = if value then Bits.vdd else Bits.gnd
let bits width value = Bits.of_int_trunc ~width value
let read signal = Simulator.Signal.read signal |> Bits.to_int_trunc

let transactions samples ~bank =
  let _, changes =
    List.fold
      samples
      ~init:((0, 0, 0), [])
      ~f:(fun (old, changes) sample ->
        let claim, pins, pin_oe =
          if bank
          then sample.Sample.engine_claim, sample.bank_pins, sample.bank_oe
          else 0, sample.lane_pins, sample.lane_oe
        in
        let state = claim, pins land pin_oe, pin_oe in
        if [%equal: int * int * int] state old
        then state, changes
        else
          ( state
          , { Pin_transaction.time = sample.time; claim; pins = pins land pin_oe; pin_oe }
            :: changes ))
  in
  List.rev changes
;;

module Bridge_state = struct
  type t =
    | Idle
    | Run
    | Release
  [@@deriving equal]
end

(* Compose the existing simulator-free lane predictor with the functional pin bank. The
   bridge schedule is restated here from its public contract, not read from DUT acceptance
   or state signals. *)
let predict_bank_transactions (scenario : Scenario.t) =
  let descriptor = scenario.config.descriptor in
  let claim_mask =
    match descriptor.output_pin with
    | None -> 0
    | Some pin -> 1 lsl pin
  in
  let owner = Kinds.Owner.Engine 0 in
  let remaining = ref scenario.transitions in
  let inputs = ref initial_inputs in
  let bridge = ref Bridge_state.Idle in
  let bank = ref F_model.Pin_bank.released in
  let previous_armed = ref false in
  let previous_busy = ref false in
  let previous_done = ref false in
  let previous_pins = ref 0 in
  let previous_oe = ref 0 in
  let old_transaction = ref (0, 0, 0) in
  let changes = Queue.create () in
  let apply result =
    match result with
    | Ok next -> bank := next
    | Error reason ->
      raise_s
        [%message
          "independent bank composition rejected" (reason : F_model.Fault.Reject.t)]
  in
  List.iter2_exn
    (predict scenario)
    (List.init scenario.edges ~f:Fn.id)
    ~f:(fun lane edge ->
      let time = first_rising_edge + (edge * period) in
      let rec apply_due () =
        match !remaining with
        | transition :: rest when transition.time <= time ->
          inputs := apply_action !inputs transition.action;
          remaining := rest;
          apply_due ()
        | _ -> ()
      in
      apply_due ();
      if !inputs.reset || (not !inputs.enable) || !inputs.abort
      then (
        bank := F_model.Pin_bank.released;
        bridge := Idle)
      else (
        let cancelled =
          Bridge_state.(equal !bridge Run)
          && (!previous_armed || !previous_busy)
          && (not (lane.armed <> 0 || lane.busy <> 0))
          && lane.done_ = 0
          && not !previous_done
        in
        match !bridge with
        | Idle ->
          if !inputs.arm
          then (
            if claim_mask <> 0
            then apply (F_model.Pin_bank.claim !bank ~owner ~mask:claim_mask);
            bridge := Run)
        | Run ->
          if cancelled
          then (
            if claim_mask <> 0
            then
              apply
                (F_model.Pin_bank.commit
                   !bank
                   (F_model.Pin_bank.Write.release ~mask:claim_mask)
                   ~owner);
            bridge := Release)
          else if !previous_done
          then (
            if claim_mask <> 0
            then
              apply
                (F_model.Pin_bank.commit
                   !bank
                   (F_model.Pin_bank.Write.release ~mask:claim_mask)
                   ~owner);
            bridge := Release)
          else if !previous_busy && claim_mask <> 0
          then
            apply
              (F_model.Pin_bank.commit
                 !bank
                 { F_model.Pin_bank.Write.mask = claim_mask
                 ; value = !previous_pins
                 ; output_enable = !previous_oe
                 }
                 ~owner)
        | Release ->
          if claim_mask <> 0
          then apply (F_model.Pin_bank.release !bank ~owner ~mask:claim_mask);
          bridge := Idle);
      previous_armed := lane.armed <> 0;
      previous_busy := lane.busy <> 0;
      previous_done := lane.done_ <> 0;
      previous_pins := lane.pins;
      previous_oe := lane.pin_oe;
      let state =
        ( F_model.Pin_bank.mask_owned_by !bank ~owner
        , !bank.value land !bank.output_enable
        , !bank.output_enable )
      in
      if not ([%equal: int * int * int] state !old_transaction)
      then (
        let claim, pins, pin_oe = state in
        Queue.enqueue changes { Pin_transaction.time; claim; pins; pin_oe };
        old_transaction := state));
  Queue.to_list changes
;;

let run (scenario : Scenario.t) =
  let config = scenario.config in
  let descriptor = config.descriptor in
  let pacing_pin, pacing_edge =
    match descriptor.pacing with
    | Observed_edge { pin; edge } -> pin, edge
    | Internal _ -> failwith "observed-transfer bank timing requires observed pacing"
  in
  let tx_enable, rx_enable = direction_enables descriptor.direction in
  let launch_trailing, sample_trailing = trailing_phases descriptor in
  let samples = ref [] in
  let testbench =
    Circuit.with_processes
      (Observed_transfer_bank.create (Scope.create ~flatten_design:true ()))
      (fun _inputs _outputs -> [])
  in
  let simulator = testbench.simulator in
  let inputs = testbench.ports_and_processes.input in
  let outputs = testbench.ports_and_processes.output in
  let schedule time f = Simulator.Expert.schedule_call simulator ~delay:time ~f in
  let set signal value = Simulator.Expert.schedule_external_set simulator signal value in
  let rec after_delta_settle remaining f =
    if remaining = 0
    then f ()
    else schedule 0 (fun () -> after_delta_settle (remaining - 1) f)
  in
  schedule 0 (fun () ->
    set inputs.enable_i.signal Bits.vdd;
    set inputs.start_pin_i.signal (bits 3 config.start_pin);
    set inputs.start_edge_kind_i.signal (bits 2 (edge_code config.start_edge));
    set inputs.pacing_pin_i.signal (bits 3 pacing_pin);
    set inputs.pacing_edge_kind_i.signal (bits 2 (edge_code pacing_edge));
    (match config.cancel with
     | None -> set inputs.cancel_enable_i.signal Bits.gnd
     | Some (pin, edge) ->
       set inputs.cancel_enable_i.signal Bits.vdd;
       set inputs.cancel_pin_i.signal (bits 3 pin);
       set inputs.cancel_edge_kind_i.signal (bits 2 (edge_code edge)));
    set inputs.bit_count_i.signal (bits 6 descriptor.bit_count);
    set inputs.tx_value_i.signal (bits 32 descriptor.tx_value);
    set inputs.tx_valid_i.signal Bits.vdd;
    set inputs.rx_ready_i.signal Bits.vdd;
    set inputs.tx_enable_i.signal (bit tx_enable);
    set inputs.rx_enable_i.signal (bit rx_enable);
    set
      inputs.lsb_first_i.signal
      (bit (Kinds.Bit_order.equal descriptor.bit_order Lsb_first));
    set inputs.output_pin_i.signal (bits 3 (pin_or_zero descriptor.output_pin));
    set inputs.input_pin_i.signal (bits 3 (pin_or_zero descriptor.input_pin));
    set inputs.idle_output_i.signal (bit descriptor.idle_output);
    set inputs.idle_clock_i.signal (bit descriptor.idle_clock);
    set inputs.launch_trailing_i.signal (bit launch_trailing);
    set inputs.sample_trailing_i.signal (bit sample_trailing);
    set inputs.occupied_i.signal (bits 8 0));
  List.iter scenario.transitions ~f:(fun transition ->
    schedule transition.time (fun () ->
      match transition.action with
      | Action.Pad value -> set inputs.pin_async_i.signal (bits 8 value)
      | Reset value -> set inputs.reset_i.signal (bit value)
      | Enable value -> set inputs.enable_i.signal (bit value)
      | Abort value -> set inputs.abort_i.signal (bit value)
      | Arm value -> set inputs.arm_valid_i.signal (bit value)));
  List.iter (List.init scenario.edges ~f:Fn.id) ~f:(fun edge ->
    let rising_time = first_rising_edge + (edge * period) in
    schedule rising_time (fun () ->
      after_delta_settle 32 (fun () -> set inputs.clock_i.signal Bits.vdd));
    schedule (rising_time + half_period) (fun () ->
      after_delta_settle 32 (fun () -> set inputs.clock_i.signal Bits.gnd));
    schedule (rising_time + 1) (fun () ->
      samples
      := { Sample.edge
         ; time = rising_time
         ; lane_pins = read outputs.lane_pin_value_o.signal
         ; lane_oe = read outputs.lane_pin_oe_o.signal
         ; bank_pins = read outputs.pins_o.signal
         ; bank_oe = read outputs.pin_oe_o.signal
         ; engine_claim = read outputs.engine_claim_o.signal
         ; software_claim = read outputs.software_claim_o.signal
         ; done_ = read outputs.done_o.signal
         ; transaction_done = read outputs.transaction_done_o.signal
         ; rx_valid = read outputs.rx_valid_o.signal
         ; rx_data = read outputs.rx_data_o.signal
         ; bank_rejected = read outputs.bank_rejected_o.signal
         ; bank_conflict = read outputs.bank_conflict_o.signal
         }
         :: !samples));
  let last_sample = first_rising_edge + ((scenario.edges - 1) * period) + 1 in
  Simulator.run simulator ~time_limit:(last_sample + 1);
  let samples = List.rev !samples in
  let expected_bank_transactions = predict_bank_transactions scenario in
  let bank_transactions = transactions samples ~bank:true in
  if not ([%equal: Pin_transaction.t list] expected_bank_transactions bank_transactions)
  then
    raise_s
      [%message
        "independent bank transaction mismatch"
          (scenario : Scenario.t)
          (expected_bank_transactions : Pin_transaction.t list)
          (bank_transactions : Pin_transaction.t list)];
  { Run.samples
  ; lane_transactions = transactions samples ~bank:false
  ; expected_bank_transactions
  ; bank_transactions
  }
;;

let received run =
  List.find_map run.Run.samples ~f:(fun sample ->
    if sample.Sample.rx_valid <> 0 then Some sample.rx_data else None)
;;

let completed run =
  List.exists run.Run.samples ~f:(fun sample -> sample.Sample.transaction_done <> 0)
;;

let first_driven transactions =
  List.find_exn transactions ~f:(fun transaction ->
    transaction.Pin_transaction.pin_oe <> 0)
;;

let last_released transactions =
  List.find_exn (List.rev transactions) ~f:(fun transaction ->
    transaction.Pin_transaction.pin_oe = 0)
;;
