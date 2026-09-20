(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "observed_transfer_timing_testbench.ml" *)
(* A two-state, timestamped testbench for the implemented P2.6 event-to-engine path. One
   scheduler owns asynchronous pads and the clock. At an equal timestamp it settles the
   pad first, matching the Input_events timed-suite convention.

   The predictor contains no simulator values: it maps external timestamps to sampling
   edges, advances the independent input synchronizer model, and feeds its previous
   coherent snapshot to the independent shift-engine model. Pin transactions are then
   reconstructed independently from the model and from the DUT's boundary outputs. *)

open! Core
open! Hardcaml
open! Hardcaml_protemu
module Evsim = Hardcaml_event_driven_sim.Two_state_simulator
module Circuit = Evsim.With_interface (Observed_transfer.I) (Observed_transfer.O)
module Simulator = Evsim.Simulator
module F_model = Protemu_f_model
module Kinds = Protemu_isa.Kinds

let time_unit = "tick"
let half_period = 5
let period = 2 * half_period
let first_rising_edge = half_period

module Config = struct
  type t =
    { descriptor : F_model.Transfer.t
    ; start_pin : int
    ; start_edge : Kinds.Edge.t
    ; cancel : (int * Kinds.Edge.t) option
    }
  [@@deriving sexp, compare, equal]
end

module Action = struct
  type t =
    | Pad of int
    | Reset of bool
    | Enable of bool
    | Abort of bool
    | Arm of bool
  [@@deriving sexp, compare, equal]
end

module Transition = struct
  type t =
    { time : int
    ; action : Action.t
    }
  [@@deriving sexp, compare, equal]

  let create time action = { time; action }
end

module Scenario = struct
  type t =
    { config : Config.t
    ; edges : int
    ; transitions : Transition.t list
    }
  [@@deriving sexp, compare, equal]
end

module Sample = struct
  type t =
    { edge : int
    ; time : int
    ; sampled_at : int
    ; snapshot : int
    ; start_edge : int
    ; pacing_edge : int
    ; armed : int
    ; busy : int
    ; claim : int
    ; pins : int
    ; pin_oe : int
    ; done_ : int
    ; rx_valid : int
    ; rx_data : int
    ; rejected : int
    ; underrun : int
    ; overrun : int
    }
  [@@deriving sexp, compare, equal]

  let to_line t =
    [%string
      "edge %{t.edge#Int} t=%{t.time#Int} sample=%{t.sampled_at#Int} \
       snapshot=%{t.snapshot#Int} start=%{t.start_edge#Int} pace=%{t.pacing_edge#Int} \
       armed=%{t.armed#Int} busy=%{t.busy#Int} claim=%{t.claim#Int} pins=%{t.pins#Int} \
       oe=%{t.pin_oe#Int} done=%{t.done_#Int} rx_valid=%{t.rx_valid#Int} \
       rx=%{t.rx_data#Int} rejected=%{t.rejected#Int} underrun=%{t.underrun#Int} \
       overrun=%{t.overrun#Int}"]
  ;;

  let difference expected actual =
    [ "snapshot_o", expected.snapshot, actual.snapshot
    ; "start_edge_o", expected.start_edge, actual.start_edge
    ; "pacing_edge_o", expected.pacing_edge, actual.pacing_edge
    ; "armed_o", expected.armed, actual.armed
    ; "busy_o", expected.busy, actual.busy
    ; "claim_mask_o", expected.claim, actual.claim
    ; "pin_value_o", expected.pins, actual.pins
    ; "pin_oe_o", expected.pin_oe, actual.pin_oe
    ; "done_o", expected.done_, actual.done_
    ; "rx_valid_o", expected.rx_valid, actual.rx_valid
    ; "rx_data_o", expected.rx_data, actual.rx_data
    ; "rejected_o", expected.rejected, actual.rejected
    ; "underrun_o", expected.underrun, actual.underrun
    ; "overrun_o", expected.overrun, actual.overrun
    ]
    |> List.find_map ~f:(fun (name, expected, actual) ->
      if expected = actual then None else Some (name, expected, actual))
  ;;
end

module Pin_transaction = struct
  type t =
    { time : int
    ; claim : int
    ; pins : int
    ; pin_oe : int
    }
  [@@deriving sexp, compare, equal]

  let to_line t =
    [%string "t=%{t.time#Int} claim=%{t.claim#Int} pins=%{t.pins#Int} oe=%{t.pin_oe#Int}"]
  ;;
end

module Peer_sample = struct
  type t =
    { time : int
    ; bit_index : int
    ; expected : int
    ; actual : int
    ; driven : bool
    ; setup : int option
    }
  [@@deriving sexp, compare, equal]

  let valid t ~minimum_setup =
    t.driven
    && t.actual = t.expected
    && Option.value_map t.setup ~default:false ~f:(fun setup -> setup >= minimum_setup)
  ;;
end

module Mismatch = struct
  type t =
    { edge : int
    ; time : int
    ; signal : string
    ; expected : int
    ; actual : int
    }
  [@@deriving sexp, compare, equal]
end

module Outcome = struct
  type t =
    | Passed
    | Budget_exceeded
    | Mismatch of Mismatch.t
    | Transaction_mismatch of
        { expected : Pin_transaction.t list
        ; actual : Pin_transaction.t list
        }
  [@@deriving sexp, compare, equal]
end

module Run = struct
  type t =
    { outcome : Outcome.t
    ; expected : Sample.t list
    ; actual : Sample.t list
    ; expected_transactions : Pin_transaction.t list
    ; actual_transactions : Pin_transaction.t list
    }
  [@@deriving sexp_of]

  let passed t = Outcome.equal t.outcome Passed
end

let bit value = if value then Bits.vdd else Bits.gnd
let bits width value = Bits.of_int_trunc ~width value
let read signal = Simulator.Signal.read signal |> Bits.to_int_trunc

type input_state =
  { pad : int
  ; reset : bool
  ; enable : bool
  ; abort : bool
  ; arm : bool
  }

let initial_inputs = { pad = 0; reset = false; enable = true; abort = false; arm = false }

let apply_action state = function
  | Action.Pad pad -> { state with pad = pad land 0xff }
  | Reset reset -> { state with reset }
  | Enable enable -> { state with enable }
  | Abort abort -> { state with abort }
  | Arm arm -> { state with arm }
;;

let descriptor : F_model.Transfer.t =
  { direction = Kinds.Direction.Tx_only
  ; bit_count = 1
  ; bit_order = Kinds.Bit_order.Lsb_first
  ; tx_value = 1
  ; output_pin = Some 0
  ; input_pin = None
  ; clock_pin = None
  ; idle_output = false
  ; idle_clock = false
  ; initial_delay = None
  ; launch = Kinds.Clock_phase.On_falling
  ; sample = Kinds.Clock_phase.On_rising
  ; pacing = Observed_edge { pin = 1; edge = Kinds.Edge.Either }
  }
;;

let default_config =
  { Config.descriptor; start_pin = 3; start_edge = Kinds.Edge.Rising; cancel = None }
;;

let scenario ?(config = default_config) ~edges transitions =
  { Scenario.config; edges; transitions }
;;

let bool value = if value then 1 else 0

let edge_code = function
  | Kinds.Edge.Rising -> 0
  | Falling -> 1
  | Either -> 2
;;

let pin_or_zero = Option.value ~default:0

let direction_enables = function
  | Kinds.Direction.Tx_only -> true, false
  | Rx_only -> false, true
  | Duplex -> true, true
;;

let trailing_phases descriptor =
  let leading =
    if descriptor.F_model.Transfer.idle_clock
    then Kinds.Clock_phase.On_falling
    else On_rising
  in
  let trailing =
    if descriptor.idle_clock then Kinds.Clock_phase.On_rising else On_falling
  in
  ( Kinds.Clock_phase.equal descriptor.launch trailing
  , Kinds.Clock_phase.equal descriptor.sample trailing )
;;

let sample ~config ~edge ~front ~lane =
  let pacing_pin, pacing_edge =
    match config.Config.descriptor.pacing with
    | Observed_edge { pin; edge } -> pin, edge
    | Internal _ -> failwith "observed-transfer timing requires observed pacing"
  in
  { Sample.edge
  ; time = first_rising_edge + (edge * period)
  ; sampled_at = first_rising_edge + (edge * period) + 1
  ; snapshot = F_model.Input_pins.snapshot front
  ; start_edge =
      bool
        (F_model.Input_pins.has_edge front ~pin:config.start_pin ~edge:config.start_edge)
  ; pacing_edge =
      bool (F_model.Input_pins.has_edge front ~pin:pacing_pin ~edge:pacing_edge)
  ; armed = bool lane.F_model.Shift_engine.armed
  ; busy = bool lane.active
  ; claim = lane.claim
  ; pins = lane.pins land lane.output_enable
  ; pin_oe = lane.output_enable
  ; done_ = bool lane.done_
  ; rx_valid = bool lane.rx_valid
  ; rx_data = lane.rx_data
  ; rejected = bool lane.rejected
  ; underrun = bool lane.underrun
  ; overrun = bool lane.overrun
  }
;;

(* The lane consumes the front end's old registered edge pulse on the same edge that the
   front end computes its next one. This explicitly models the register boundary between
   the two blocks rather than aligning traces after the fact. *)
let predict (scenario : Scenario.t) =
  let config = scenario.config in
  let descriptor = config.descriptor in
  let pacing_pin, pacing_kind =
    match descriptor.pacing with
    | Observed_edge { pin; edge } -> pin, edge
    | Internal _ -> failwith "observed-transfer timing requires observed pacing"
  in
  let remaining = ref scenario.transitions in
  let inputs = ref initial_inputs in
  let front = ref F_model.Input_pins.cleared in
  let lane = ref F_model.Shift_engine.idle in
  let samples = Queue.create () in
  for edge = 0 to scenario.edges - 1 do
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
    if !inputs.reset
    then (
      front := F_model.Input_pins.cleared;
      lane := F_model.Shift_engine.idle)
    else (
      let start_event =
        F_model.Input_pins.has_edge !front ~pin:config.start_pin ~edge:config.start_edge
      in
      let observed_edge =
        F_model.Input_pins.has_edge !front ~pin:pacing_pin ~edge:pacing_kind
      in
      let cancel =
        match config.cancel with
        | None -> false
        | Some (pin, edge) ->
          (!lane.armed || !lane.active) && F_model.Input_pins.has_edge !front ~pin ~edge
      in
      lane
      := F_model.Shift_engine.step
           !lane
           ~enable:!inputs.enable
           ~abort:(!inputs.abort || cancel)
           ~command:(if !inputs.arm then Some (descriptor, true) else None)
           ~start_event
           ~observed_edge
           ~pin_in:(F_model.Input_pins.snapshot !front)
           ~occupied:0
           ~tx_valid:true
           ~rx_ready:true;
      front := F_model.Input_pins.step !front ~pin_in:!inputs.pad);
    Queue.enqueue samples (sample ~config ~edge ~front:!front ~lane:!lane)
  done;
  Queue.to_list samples
;;

let transactions samples =
  let _, transactions =
    List.fold
      samples
      ~init:((0, 0, 0), [])
      ~f:(fun ((old_claim, old_pins, old_oe), transactions) sample ->
        let state = sample.Sample.claim, sample.pins, sample.pin_oe in
        if [%equal: int * int * int] state (old_claim, old_pins, old_oe)
        then state, transactions
        else
          ( state
          , { Pin_transaction.time = sample.time
            ; claim = sample.claim
            ; pins = sample.pins
            ; pin_oe = sample.pin_oe
            }
            :: transactions ))
  in
  List.rev transactions
;;

let external_pacing_times (scenario : Scenario.t) =
  let pin_level word pin = word land (1 lsl pin) <> 0 in
  let descriptor = scenario.config.descriptor in
  let pacing_pin, pacing_edge =
    match descriptor.pacing with
    | Observed_edge { pin; edge } -> pin, edge
    | Internal _ -> failwith "external peer requires observed pacing"
  in
  let _, times =
    List.fold scenario.transitions ~init:(0, []) ~f:(fun (old_pad, times) transition ->
      match transition.action with
      | Pad pad ->
        let old_level = pin_level old_pad pacing_pin in
        let level = pin_level pad pacing_pin in
        let selected =
          match pacing_edge with
          | Kinds.Edge.Rising -> (not old_level) && level
          | Falling -> old_level && not level
          | Either -> Bool.(old_level <> level)
        in
        pad, if selected && transition.time > 0 then transition.time :: times else times
      | Reset _ | Enable _ | Abort _ | Arm _ -> old_pad, times)
  in
  List.rev times
;;

let peer_samples (scenario : Scenario.t) transactions =
  let descriptor = scenario.config.descriptor in
  let output_pin = Option.value_exn descriptor.output_pin in
  let _, sample_trailing = trailing_phases descriptor in
  let state_before time =
    let _, value, driven, changed_at =
      List.fold_until
        transactions
        ~init:(0, 0, false, None)
        ~f:(fun (old_pins, value, driven, changed_at) transaction ->
          if transaction.Pin_transaction.time >= time
          then Stop (old_pins, value, driven, changed_at)
          else (
            let next_value = (transaction.pins lsr output_pin) land 1 in
            let next_driven = transaction.pin_oe land (1 lsl output_pin) <> 0 in
            let changed_at =
              if next_value <> value || Bool.(next_driven <> driven)
              then Some transaction.time
              else changed_at
            in
            Continue (transaction.pins, next_value, next_driven, changed_at)))
        ~finish:Fn.id
    in
    value, driven, Option.map changed_at ~f:(fun changed_at -> time - changed_at)
  in
  external_pacing_times scenario
  |> List.filter_mapi ~f:(fun half_edge time ->
    let trailing = half_edge mod 2 = 1 in
    if Bool.equal trailing sample_trailing
    then (
      let bit_index = half_edge / 2 in
      if bit_index >= descriptor.bit_count
      then None
      else (
        let ordinal =
          if Kinds.Bit_order.equal descriptor.bit_order Lsb_first
          then bit_index
          else descriptor.bit_count - 1 - bit_index
        in
        let expected = (descriptor.tx_value lsr ordinal) land 1 in
        let actual, driven, setup = state_before time in
        Some { Peer_sample.time; bit_index; expected; actual; driven; setup }))
    else None)
;;

let launch_response_latencies (scenario : Scenario.t) transactions =
  let descriptor = scenario.config.descriptor in
  let output_pin = Option.value_exn descriptor.output_pin in
  let launch_trailing, _ = trailing_phases descriptor in
  external_pacing_times scenario
  |> List.filter_mapi ~f:(fun half_edge time ->
    let trailing = half_edge mod 2 = 1 in
    if Bool.equal trailing launch_trailing
    then (
      let bit_index = (half_edge / 2) + if trailing then 1 else 0 in
      if bit_index >= descriptor.bit_count
      then None
      else (
        let ordinal =
          if Kinds.Bit_order.equal descriptor.bit_order Lsb_first
          then bit_index
          else descriptor.bit_count - 1 - bit_index
        in
        let expected = (descriptor.tx_value lsr ordinal) land 1 in
        List.find_map transactions ~f:(fun transaction ->
          let value = (transaction.Pin_transaction.pins lsr output_pin) land 1 in
          let driven = transaction.pin_oe land (1 lsl output_pin) <> 0 in
          if transaction.time > time && driven && value = expected
          then Some (transaction.time - time)
          else None)))
    else None)
;;

let run_evsim (scenario : Scenario.t) =
  let config = scenario.config in
  let descriptor = config.descriptor in
  let pacing_pin, pacing_edge =
    match descriptor.pacing with
    | Observed_edge { pin; edge } -> pin, edge
    | Internal _ -> failwith "observed-transfer timing requires observed pacing"
  in
  let tx_enable, rx_enable = direction_enables descriptor.direction in
  let launch_trailing, sample_trailing = trailing_phases descriptor in
  let samples = ref [] in
  let testbench =
    Circuit.with_processes
      (Observed_transfer.create (Scope.create ~flatten_design:true ()))
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
  (* Fixed descriptor fields. The scenario owns only time-varying control and pads. *)
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
         ; sampled_at = rising_time + 1
         ; snapshot = read outputs.snapshot_o.signal
         ; start_edge = read outputs.start_edge_o.signal
         ; pacing_edge = read outputs.pacing_edge_o.signal
         ; armed = read outputs.armed_o.signal
         ; busy = read outputs.busy_o.signal
         ; claim = read outputs.claim_mask_o.signal
         ; pins = read outputs.pin_value_o.signal land read outputs.pin_oe_o.signal
         ; pin_oe = read outputs.pin_oe_o.signal
         ; done_ = read outputs.done_o.signal
         ; rx_valid = read outputs.rx_valid_o.signal
         ; rx_data = read outputs.rx_data_o.signal
         ; rejected = read outputs.rejected_o.signal
         ; underrun = read outputs.underrun_o.signal
         ; overrun = read outputs.overrun_o.signal
         }
         :: !samples));
  let last_sample = first_rising_edge + ((scenario.edges - 1) * period) + 1 in
  Simulator.run simulator ~time_limit:(last_sample + 1);
  List.rev !samples
;;

let first_mismatch expected actual =
  let rec loop expected actual =
    match expected, actual with
    | expected :: expected_rest, actual :: actual_rest ->
      (match Sample.difference expected actual with
       | None -> loop expected_rest actual_rest
       | Some (signal, expected_value, actual_value) ->
         Some
           { Mismatch.edge = expected.edge
           ; time = expected.time
           ; signal
           ; expected = expected_value
           ; actual = actual_value
           })
    | [], [] -> None
    | _ -> failwith "event simulator returned the wrong number of samples"
  in
  loop expected actual
;;

let run (scenario : Scenario.t) =
  let expected = predict scenario in
  if scenario.edges <= 0 || scenario.edges > 320 || List.length scenario.transitions > 256
  then
    { Run.outcome = Budget_exceeded
    ; expected
    ; actual = []
    ; expected_transactions = transactions expected
    ; actual_transactions = []
    }
  else (
    let actual = run_evsim scenario in
    let expected_transactions = transactions expected in
    let actual_transactions = transactions actual in
    let outcome =
      match first_mismatch expected actual with
      | Some mismatch -> Outcome.Mismatch mismatch
      | None
        when not
               ([%equal: Pin_transaction.t list]
                  expected_transactions
                  actual_transactions) ->
        Transaction_mismatch
          { expected = expected_transactions; actual = actual_transactions }
      | None -> Passed
    in
    { Run.outcome; expected; actual; expected_transactions; actual_transactions })
;;

let phase_scenario phase =
  scenario
    ~edges:13
    [ Transition.create 0 (Reset true)
    ; Transition.create 6 (Reset false)
    ; Transition.create 6 (Arm true)
    ; Transition.create 16 (Arm false)
    ; Transition.create (16 + phase) (Pad 8)
    ; Transition.create 46 (Pad 10)
    ; Transition.create 76 (Pad 8)
    ]
;;

let abort_scenario =
  scenario
    ~edges:10
    [ Transition.create 0 (Reset true)
    ; Transition.create 6 (Reset false)
    ; Transition.create 6 (Arm true)
    ; Transition.create 16 (Arm false)
    ; Transition.create 16 (Pad 8)
    ; Transition.create 66 (Abort true)
    ; Transition.create 76 (Abort false)
    ]
;;

let control_interruption_scenario action =
  scenario
    ~edges:10
    [ Transition.create 0 (Reset true)
    ; Transition.create 6 (Reset false)
    ; Transition.create 6 (Arm true)
    ; Transition.create 16 (Arm false)
    ; Transition.create 16 (Pad 8)
    ; Transition.create 66 action
    ]
;;

let cancellation_scenario phase =
  let config = { default_config with Config.cancel = Some (4, Kinds.Edge.Falling) } in
  scenario
    ~config
    ~edges:15
    [ Transition.create 0 (Pad 16)
    ; Transition.create 0 (Reset true)
    ; Transition.create 16 (Reset false)
    ; Transition.create 26 (Arm true)
    ; Transition.create 36 (Arm false)
    ; Transition.create 46 (Pad 24)
    ; (* Select withdrawal and a pacing rise are coincident; cancellation wins. *)
      Transition.create (76 + phase) (Pad 10)
    ]
;;

let armed_cancellation_scenario phase =
  let config = { default_config with Config.cancel = Some (4, Kinds.Edge.Falling) } in
  scenario
    ~config
    ~edges:13
    [ Transition.create 0 (Pad 16)
    ; Transition.create 0 (Reset true)
    ; Transition.create 16 (Reset false)
    ; Transition.create 26 (Arm true)
    ; Transition.create 36 (Arm false)
    ; Transition.create (46 + phase) (Pad 0)
    ; Transition.create 86 (Pad 8)
    ]
;;

let rx_data_scenario ~pace_time ~data_time ~data_clear_time =
  let config =
    { default_config with
      Config.descriptor =
        { descriptor with
          direction = Kinds.Direction.Rx_only
        ; tx_value = 0
        ; output_pin = None
        ; input_pin = Some 2
        }
    }
  in
  let updates = Hashtbl.create (module Int) in
  let add time mask =
    Hashtbl.update updates time ~f:(fun old -> Option.value old ~default:8 lor mask)
  in
  add pace_time 2;
  add data_time 4;
  add data_clear_time 0;
  let timed =
    Hashtbl.to_alist updates
    |> List.sort ~compare:(fun (left, _) (right, _) -> Int.compare left right)
    |> List.map ~f:(fun (time, _) ->
      let pace = if time >= pace_time && time < 125 then 2 else 0 in
      let data = if time >= data_time && time < data_clear_time then 4 else 0 in
      Transition.create time (Pad (8 lor pace lor data)))
  in
  scenario
    ~config
    ~edges:16
    ([ Transition.create 0 (Reset true)
     ; Transition.create 16 (Reset false)
     ; Transition.create 26 (Arm true)
     ; Transition.create 36 (Arm false)
     ; Transition.create 46 (Pad 8)
     ; Transition.create 125 (Pad 8)
     ]
     @ timed
     |> List.sort ~compare:Transition.compare)
;;

let pin_level word pin = word land (1 lsl pin) <> 0

let set_pin word pin value =
  if value then word lor (1 lsl pin) else word land lnot (1 lsl pin)
;;

let paced_scenario ~config ~phase ~lead ~high_width ~low_width ~rx_word =
  let descriptor = config.Config.descriptor in
  let pacing_pin, pacing_edge =
    match descriptor.pacing with
    | Observed_edge { pin; edge } -> pin, edge
    | Internal _ -> failwith "observed-transfer timing requires observed pacing"
  in
  let initial_for_edge = function
    | Kinds.Edge.Rising | Either -> false
    | Falling -> true
  in
  let pad = ref 0 in
  pad := set_pin !pad config.start_pin (initial_for_edge config.start_edge);
  pad := set_pin !pad pacing_pin (initial_for_edge pacing_edge);
  Option.iter config.cancel ~f:(fun (pin, edge) ->
    pad := set_pin !pad pin (initial_for_edge edge));
  let transitions =
    ref [ Transition.create 0 (Pad !pad); Transition.create 0 (Reset true) ]
  in
  let add_pad time update =
    pad := update !pad;
    transitions := Transition.create time (Pad !pad) :: !transitions
  in
  let start_time = 46 + phase in
  transitions
  := Transition.create 16 (Reset false)
     :: Transition.create 26 (Arm true)
     :: Transition.create 36 (Arm false)
     :: !transitions;
  add_pad start_time (fun pad ->
    set_pin pad config.start_pin (not (pin_level pad config.start_pin)));
  let time = ref (start_time + lead) in
  let launch_trailing, sample_trailing = trailing_phases descriptor in
  ignore launch_trailing;
  for half_edge = 0 to (2 * descriptor.bit_count) - 1 do
    let bit_index = half_edge / 2 in
    let ordinal =
      if Kinds.Bit_order.equal descriptor.bit_order Lsb_first
      then bit_index
      else descriptor.bit_count - 1 - bit_index
    in
    let data = rx_word land (1 lsl ordinal) <> 0 in
    let is_sample = Bool.equal (half_edge mod 2 = 1) sample_trailing in
    let with_data pad =
      match descriptor.input_pin with
      | Some pin when is_sample -> set_pin pad pin data
      | _ -> pad
    in
    match pacing_edge with
    | Either ->
      let was_high = pin_level !pad pacing_pin in
      add_pad !time (fun pad -> set_pin (with_data pad) pacing_pin (not was_high));
      time := !time + if was_high then low_width else high_width
    | Rising ->
      add_pad !time (fun pad -> set_pin (with_data pad) pacing_pin true);
      add_pad (!time + high_width) (fun pad -> set_pin pad pacing_pin false);
      time := !time + high_width + low_width
    | Falling ->
      add_pad !time (fun pad -> set_pin (with_data pad) pacing_pin false);
      add_pad (!time + low_width) (fun pad -> set_pin pad pacing_pin true);
      time := !time + low_width + high_width
  done;
  let edges = ((!time + 45 - first_rising_edge) / period) + 1 in
  scenario ~config ~edges (List.sort !transitions ~compare:Transition.compare)
;;

let completed run = List.exists run.Run.actual ~f:(fun sample -> sample.Sample.done_ <> 0)

let received run =
  List.find_map run.Run.actual ~f:(fun sample ->
    if sample.Sample.rx_valid <> 0 then Some sample.rx_data else None)
;;
