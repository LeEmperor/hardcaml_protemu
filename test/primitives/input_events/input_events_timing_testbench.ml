(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "input_events_timing_testbench.ml" *)
(* The time-resolved, two-state verification environment for Input_events. One scheduler
   owns both the asynchronous pad and the clock. At equal timestamps it submits every
   stimulus update before the clock update, so "at the edge" has one deterministic digital
   meaning. This deliberately does not model setup/hold or metastability. *)

open! Core
open! Hardcaml
open! Hardcaml_protemu
module Evsim = Hardcaml_event_driven_sim.Two_state_simulator
module Circuit = Evsim.With_interface (Input_events.I) (Input_events.O)
module Simulator = Evsim.Simulator
module F_model = Protemu_f_model

let time_unit = "tick"
let half_period = 5
let period = half_period * 2
let first_rising_edge = half_period

module Action = struct
  type t =
    | Pad of int
    | Reset of bool
    | Event_set of int
    | Event_ack of int
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
    { edges : int
    ; transitions : Transition.t list
    }
  [@@deriving sexp, compare, equal]

  let create ~edges transitions = { edges; transitions }

  let ordered t =
    List.is_sorted t.transitions ~compare:(fun a b -> Int.compare a.time b.time)
  ;;

  let has_reset_prerequisite t =
    match t.transitions with
    | { time = 0; action = Reset true } :: rest ->
      List.exists rest ~f:(fun transition ->
        transition.time > first_rising_edge
        && transition.time < first_rising_edge + period
        && Action.equal transition.action (Reset false))
    | _ -> false
  ;;

  (* A generated timing case must retain an actual pulse window, not merely two pad
     assignments. This is the prerequisite used by the temporal shrinker. *)
  let has_pulse_window t =
    let pads =
      List.filter_map t.transitions ~f:(fun transition ->
        match transition.action with
        | Pad value -> Some (transition.time, value)
        | Reset _ | Event_set _ | Event_ack _ -> None)
    in
    List.existsi pads ~f:(fun index (start, value) ->
      value land 1 <> 0
      && List.exists
           (List.drop pads (index + 1))
           ~f:(fun (finish, value) ->
             finish > start && finish - start <= period && value land 1 = 0))
  ;;

  let prerequisite t =
    t.edges > 0 && ordered t && has_reset_prerequisite t && has_pulse_window t
  ;;
end

module Defect = struct
  type t =
    | None
    | Delay_pad_transitions_one_tick
  [@@deriving sexp, compare, equal]
end

module Config = struct
  type t =
    { max_edges : int
    ; max_transitions : int
    ; defect : Defect.t
    }
  [@@deriving sexp, compare, equal]

  let default = { max_edges = 32; max_transitions = 96; defect = None }
  let with_defect defect = { default with defect }
end

module Sample = struct
  type t =
    { edge : int
    ; time : int
    ; sampled_at : int
    ; snapshot : int
    ; rising : int
    ; falling : int
    ; event : int
    ; overflow : int
    }
  [@@deriving sexp, compare, equal]

  let create ~edge ~time ~sampled_at ~snapshot ~rising ~falling ~event ~overflow =
    { edge; time; sampled_at; snapshot; rising; falling; event; overflow }
  ;;

  let to_line t =
    [%string
      "edge %{t.edge#Int} t=%{t.time#Int} sample=%{t.sampled_at#Int} \
       pins=%{t.snapshot#Int} rise=%{t.rising#Int} fall=%{t.falling#Int} \
       event=%{t.event#Int} overflow=%{t.overflow#Int}"]
  ;;

  let difference expected actual =
    let fields =
      [ "snapshot_o", expected.snapshot, actual.snapshot
      ; "rising_o", expected.rising, actual.rising
      ; "falling_o", expected.falling, actual.falling
      ; "event_o", expected.event, actual.event
      ; "overflow_o", expected.overflow, actual.overflow
      ]
    in
    List.find_map fields ~f:(fun (signal, expected, actual) ->
      if expected = actual then None else Some (signal, expected, actual))
  ;;
end

module Activity = struct
  type t =
    { time : int
    ; signal : string
    ; value : int
    }
  [@@deriving sexp, compare, equal]

  let to_line t = [%string "t=%{t.time#Int} %{t.signal}=%{t.value#Int}"]
end

module Mismatch = struct
  type t =
    { edge : int
    ; time : int
    ; sampled_at : int
    ; signal : string
    ; expected : int
    ; actual : int
    }
  [@@deriving sexp, compare, equal]

  let identity t = [%string "post_edge/%{t.signal}"]
end

module Outcome = struct
  type t =
    | Passed
    | Budget_exceeded of
        { edges : int
        ; transitions : int
        }
    | Mismatch of Mismatch.t
  [@@deriving sexp, compare, equal]

  let identity = function
    | Passed -> None
    | Budget_exceeded _ -> Some "budget"
    | Mismatch mismatch -> Some (Mismatch.identity mismatch)
  ;;
end

module Run = struct
  type t =
    { outcome : Outcome.t
    ; expected : Sample.t list
    ; actual : Sample.t list
    ; activity : Activity.t list
    }
  [@@deriving sexp_of]

  let passed t = Outcome.equal t.outcome Passed
end

let bit value = if value then Bits.vdd else Bits.gnd
let bits width value = Bits.of_int_trunc ~width value
let read signal = Simulator.Signal.read signal |> Bits.to_int_trunc

let event_kinds =
  [| F_model.Event.Kind.Delay_expired
   ; Wait_complete
   ; Wait_timeout
   ; Tick
   ; Aborted
   ; Fault
  |]
;;

let selected mask =
  Array.to_list event_kinds
  |> List.filteri ~f:(fun index _ -> mask land (1 lsl index) <> 0)
;;

let event_mask state predicate =
  Array.foldi event_kinds ~init:0 ~f:(fun index mask kind ->
    if predicate state kind then mask lor (1 lsl index) else mask)
;;

type input_state =
  { pad : int
  ; reset : bool
  ; event_set : int
  ; event_ack : int
  }

let initial_inputs = { pad = 0; reset = false; event_set = 0; event_ack = 0 }

let apply_action state = function
  | Action.Pad pad -> { state with pad = pad land 0xff }
  | Reset reset -> { state with reset }
  | Event_set event_set -> { state with event_set = event_set land 0x3f }
  | Event_ack event_ack -> { state with event_ack = event_ack land 0x3f }
;;

(* This predictor is intentionally simulator-free. The timestamp-to-edge mapping is stated
   here rather than inferred from the DUT: transitions at a rising timestamp are applied
   first; transitions one tick later belong to the next edge. *)
let predict (scenario : Scenario.t) =
  let remaining = ref scenario.transitions in
  let inputs = ref initial_inputs in
  let pins = ref F_model.Input_pins.cleared in
  let events = ref F_model.Event.cleared in
  let rec loop edge samples =
    if edge >= scenario.edges
    then List.rev samples
    else (
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
        pins := F_model.Input_pins.cleared;
        events := F_model.Event.cleared)
      else (
        pins := F_model.Input_pins.step !pins ~pin_in:!inputs.pad;
        events
        := F_model.Event.step
             !events
             ~set:(selected !inputs.event_set)
             ~ack:(selected !inputs.event_ack));
      let sample =
        Sample.create
          ~edge
          ~time
          ~sampled_at:(time + 1)
          ~snapshot:(F_model.Input_pins.snapshot !pins)
          ~rising:(F_model.Input_pins.rising !pins)
          ~falling:(F_model.Input_pins.falling !pins)
          ~event:(event_mask !events F_model.Event.is_set)
          ~overflow:(event_mask !events F_model.Event.overflowed)
      in
      loop (edge + 1) (sample :: samples))
  in
  loop 0 []
;;

let monitor signal_name signal activity =
  let initial = ref true in
  Simulator.Process.create
    ~here:[%here]
    [ Simulator.Signal.id signal ]
    (fun () ->
      if !initial
      then initial := false
      else
        activity
        := { Activity.time = Simulator.Async.current_time ()
           ; signal = signal_name
           ; value = read signal
           }
           :: !activity)
;;

let effective_time defect (transition : Transition.t) =
  match defect, transition.action with
  | Defect.Delay_pad_transitions_one_tick, Pad _ -> transition.time + 1
  | None, _ | Delay_pad_transitions_one_tick, (Reset _ | Event_set _ | Event_ack _) ->
    transition.time
;;

let run_evsim (config : Config.t) (scenario : Scenario.t) =
  let samples = ref [] in
  let activity = ref [] in
  let testbench =
    Circuit.with_processes
      (Input_events.create (Scope.create ~flatten_design:true ()))
      (fun inputs outputs ->
        [ monitor "reset_i" inputs.reset_i.signal activity
        ; monitor "pin_in_i" inputs.pin_in_i.signal activity
        ; monitor "event_set_i" inputs.event_set_i.signal activity
        ; monitor "event_ack_i" inputs.event_ack_i.signal activity
        ; monitor "snapshot_o" outputs.snapshot_o.signal activity
        ; monitor "rising_o" outputs.rising_o.signal activity
        ; monitor "falling_o" outputs.falling_o.signal activity
        ; monitor "event_o" outputs.event_o.signal activity
        ; monitor "overflow_o" outputs.overflow_o.signal activity
        ])
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
  let scheduled_transitions =
    List.mapi scenario.transitions ~f:(fun index transition ->
      effective_time config.defect transition, index, transition.action)
    |> List.sort ~compare:(fun (a_time, a_index, _) (b_time, b_index, _) ->
      match Int.compare a_time b_time with
      | 0 -> Int.compare a_index b_index
      | order -> order)
  in
  (* All stimulus callbacks are inserted before all clock callbacks. The simulator's
     stable timestamp/sequence ordering then applies and settles a same-time stimulus
     before the rising-edge-sensitive processes run. *)
  List.iter scheduled_transitions ~f:(fun (time, _, action) ->
    schedule time (fun () ->
      match action with
      | Action.Pad value -> set inputs.pin_in_i.signal (bits 8 value)
      | Reset value -> set inputs.reset_i.signal (bit value)
      | Event_set value -> set inputs.event_set_i.signal (bits 6 value)
      | Event_ack value -> set inputs.event_ack_i.signal (bits 6 value)));
  List.iter (List.init scenario.edges ~f:Fn.id) ~f:(fun edge ->
    let rising_time = first_rising_edge + (edge * period) in
    (* The delta settling is intentional. Same-time stimulus callbacks first enqueue their
       port updates and the combinational input network reaches quiescence before the
       clock port update. Thirty-two is a finite runner budget, not elapsed test time; it
       comfortably exceeds this block's combinational delta depth. *)
    schedule rising_time (fun () ->
      after_delta_settle 32 (fun () -> set inputs.clock_i.signal Bits.vdd));
    schedule (rising_time + half_period) (fun () ->
      after_delta_settle 32 (fun () -> set inputs.clock_i.signal Bits.gnd)));
  List.iter (List.init scenario.edges ~f:Fn.id) ~f:(fun edge ->
    let time = first_rising_edge + (edge * period) in
    let sampled_at = time + 1 in
    schedule sampled_at (fun () ->
      samples
      := Sample.create
           ~edge
           ~time
           ~sampled_at
           ~snapshot:(read outputs.snapshot_o.signal)
           ~rising:(read outputs.rising_o.signal)
           ~falling:(read outputs.falling_o.signal)
           ~event:(read outputs.event_o.signal)
           ~overflow:(read outputs.overflow_o.signal)
         :: !samples));
  let last_sample = first_rising_edge + ((scenario.edges - 1) * period) + 1 in
  Simulator.run simulator ~time_limit:(last_sample + 1);
  List.rev !samples, List.rev !activity
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
           ; sampled_at = expected.sampled_at
           ; signal
           ; expected = expected_value
           ; actual = actual_value
           })
    | [], [] -> None
    | expected :: _, [] ->
      Some
        { Mismatch.edge = expected.edge
        ; time = expected.time
        ; sampled_at = expected.sampled_at
        ; signal = "sample"
        ; expected = 1
        ; actual = 0
        }
    | [], actual :: _ ->
      Some
        { Mismatch.edge = actual.edge
        ; time = actual.time
        ; sampled_at = actual.sampled_at
        ; signal = "sample"
        ; expected = 0
        ; actual = 1
        }
  in
  loop expected actual
;;

let run (config : Config.t) (scenario : Scenario.t) =
  let expected = predict scenario in
  if scenario.edges > config.max_edges
     || List.length scenario.transitions > config.max_transitions
  then
    { Run.outcome =
        Budget_exceeded
          { edges = scenario.edges; transitions = List.length scenario.transitions }
    ; expected
    ; actual = []
    ; activity = []
    }
  else (
    let actual, activity = run_evsim config scenario in
    let outcome =
      match first_mismatch expected actual with
      | None -> Outcome.Passed
      | Some mismatch -> Mismatch mismatch
    in
    { Run.outcome; expected; actual; activity })
;;

module Generator = struct
  module G = Base_quickcheck.Generator
  open G.Let_syntax

  let action = G.of_weighted_list [ 5., `Pad; 2., `Set; 2., `Ack ]

  let scenario =
    let%bind size = G.size in
    let edges = Int.min 20 (Int.max 6 (size + 6)) in
    let last_time = first_rising_edge + ((edges - 3) * period) in
    let%bind pulse_phase = G.int_uniform_inclusive 0 (period - 1)
    and pulse_width = G.int_uniform_inclusive 1 period
    and extra_count = G.int_uniform_inclusive 0 (Int.min 24 (size + 2)) in
    let pulse_start = first_rising_edge + period + pulse_phase in
    let pulse_end = pulse_start + pulse_width in
    let%map extras =
      G.list_with_length
        (let%bind time = G.int_uniform_inclusive (first_rising_edge + 1) last_time
         and kind = action
         and byte = G.int_uniform_inclusive 0 0xff
         and event = G.int_uniform_inclusive 0 0x3f in
         G.return
           (match kind with
            | `Pad -> Transition.create time (Pad byte)
            | `Set -> Transition.create time (Event_set event)
            | `Ack -> Transition.create time (Event_ack event)))
        ~length:extra_count
    in
    let transitions =
      [ Transition.create 0 (Reset true)
      ; Transition.create (first_rising_edge + 1) (Reset false)
      ; Transition.create pulse_start (Pad 1)
      ; Transition.create pulse_end (Pad 0)
      ]
      @ extras
      |> List.stable_sort ~compare:Transition.compare
    in
    Scenario.create ~edges transitions
  ;;

  (* Every controlled trial contains a pulse that begins exactly at a rising edge. A
     one-tick pad-driver defect moves the entire pulse beyond that sampling edge. *)
  let controlled_scenario =
    G.return
      (Scenario.create
         ~edges:6
         [ Transition.create 0 (Reset true)
         ; Transition.create 6 (Reset false)
         ; Transition.create 15 (Pad 1)
         ; Transition.create 16 (Pad 0)
         ; Transition.create 36 (Event_set 1)
         ; Transition.create 37 (Event_set 0)
         ])
  ;;
end

module Failure = struct
  type t =
    { replay : Replay.t
    ; scenario : Scenario.t
    ; shrunk : Scenario.t option
    ; outcome : Outcome.t
    ; context : Sample.t list
    ; activity : Activity.t list
    ; artifact : string option
    }

  let outcome_lines = function
    | Outcome.Passed -> [ "  passed" ]
    | Budget_exceeded { edges; transitions } ->
      [ [%string
          "  time/event budget exceeded: edges=%{edges#Int} \
           transitions=%{transitions#Int}"]
      ]
    | Mismatch mismatch ->
      [ [%string "  time:             %{mismatch.time#Int} %{time_unit}"]
      ; [%string "  sample time:      %{mismatch.sampled_at#Int} %{time_unit}"]
      ; [%string "  edge:             %{mismatch.edge#Int}"]
      ; [%string "  phase:            post_edge"]
      ; [%string "  observation:      %{mismatch.signal}"]
      ; [%string "  expected (model): %{mismatch.expected#Int}"]
      ; [%string "  actual (dut):     %{mismatch.actual#Int}"]
      ]
  ;;

  let scenario_lines label scenario =
    [%string "%{label}:"]
    :: [%string "  edges: %{scenario.Scenario.edges#Int}"]
    :: List.map scenario.transitions ~f:(fun transition ->
      let transition = Transition.sexp_of_t transition in
      [%string "  %{transition#Sexp}"])
  ;;

  let to_lines ?(redact_source = false) t =
    List.concat
      [ [ "input_events: timed f_model/two-state Evsim comparison failed"; "" ]
      ; [ "reproduction:" ]
      ; Replay.to_lines ~redact_source t.replay
      ; [ [%string "  time unit:        %{time_unit}"]
        ; [%string
            "  clock:            period=%{period#Int}, first \
             rising=%{first_rising_edge#Int}"]
        ; "  coincidence:      stimulus settles before the clock transition"
        ; ""
        ; "first mismatch:"
        ]
      ; outcome_lines t.outcome
      ; [ "" ]
      ; scenario_lines "failing scenario" t.scenario
      ; (match t.shrunk with
         | None -> [ ""; "shrunk scenario: none smaller preserved the failure" ]
         | Some scenario -> [ "" ] @ scenario_lines "shrunk scenario" scenario)
      ; [ ""; "nearby sampled context:" ]
      ; List.map t.context ~f:(fun sample -> "  " ^ Sample.to_line sample)
      ; [ ""; "between-edge activity:" ]
      ; List.map t.activity ~f:(fun activity -> "  " ^ Activity.to_line activity)
      ; (match t.artifact with
         | None -> []
         | Some path -> [ ""; [%string "artifact: %{path}"] ])
      ]
  ;;

  let to_string_hum ?redact_source t =
    String.concat ~sep:"\n" (to_lines ?redact_source t) ^ "\n"
  ;;
end

let context_for_mismatch run =
  match run.Run.outcome with
  | Outcome.Mismatch mismatch ->
    ( List.filter run.actual ~f:(fun sample -> Int.abs (sample.edge - mismatch.edge) <= 2)
    , List.filter run.activity ~f:(fun activity ->
        Int.abs (activity.time - mismatch.time) <= period) )
  | Passed | Budget_exceeded _ -> run.actual, run.activity
;;

let shrink_candidates (scenario : Scenario.t) =
  let removed =
    List.init (List.length scenario.transitions) ~f:(fun skip ->
      { scenario with
        transitions = List.filteri scenario.transitions ~f:(fun index _ -> index <> skip)
      })
  in
  let moved =
    List.filter_mapi scenario.transitions ~f:(fun index transition ->
      if transition.time = 0
      then None
      else (
        let previous_time =
          match List.nth scenario.transitions (index - 1) with
          | None -> 0
          | Some previous -> previous.time
        in
        let time = Int.max previous_time (transition.time - 1) in
        let transitions =
          List.mapi scenario.transitions ~f:(fun candidate_index candidate ->
            if candidate_index = index then { candidate with time } else candidate)
        in
        Some { scenario with transitions }))
  in
  let fewer_edges =
    if scenario.edges <= 1 then [] else [ { scenario with edges = scenario.edges - 1 } ]
  in
  (* A transition that is already as early as its predecessor produces a candidate equal
     to the scenario it came from. Accepting one would consume the whole shrink budget
     without making the case smaller, and the later candidates - shortening the run -
     would never be reached. *)
  removed @ moved @ fewer_edges
  |> List.filter ~f:(fun candidate -> not (Scenario.equal candidate scenario))
;;

let quickcheck
  ~(here : [%call_pos])
  ~test
  ~config
  ~generator
  ?(prerequisite = Scenario.prerequisite)
  ?(shrink_steps = 64)
  ?(write_artifact = true)
  ?(environment_overrides = true)
  ~settings
  ()
  =
  let settings =
    if environment_overrides then Replay.Settings.override settings else settings
  in
  let random = Splittable_random.of_int settings.seed in
  let rec search trial =
    if trial >= settings.trials
    then None
    else (
      let size = Replay.Settings.size_of_trial settings ~trial in
      let scenario = Base_quickcheck.Generator.generate generator ~size ~random in
      if not (prerequisite scenario)
      then raise_s [%message "timed generator violated its prerequisite" (trial : int)];
      let run = run config scenario in
      match Outcome.identity run.outcome with
      | None -> search (trial + 1)
      | Some _ -> Some (trial, scenario, run))
  in
  match search 0 with
  | None -> None
  | Some (trial, scenario, initial_run) ->
    let identity = Outcome.identity initial_run.outcome in
    let rec shrink remaining scenario best_run =
      if remaining <= 0
      then scenario, best_run
      else (
        match
          List.find_map (shrink_candidates scenario) ~f:(fun candidate ->
            if not (prerequisite candidate)
            then None
            else (
              let candidate_run = run config candidate in
              if Option.equal
                   String.equal
                   (Outcome.identity candidate_run.outcome)
                   identity
              then Some (candidate, candidate_run)
              else None))
        with
        | None -> scenario, best_run
        | Some (candidate, candidate_run) ->
          shrink (remaining - 1) candidate candidate_run)
    in
    let shrunk, shrunk_run = shrink shrink_steps scenario initial_run in
    let context, activity = context_for_mismatch initial_run in
    let replay =
      Replay.create
        ~test
        ~source_file:here.pos_fname
        ~settings
        ~trial:(Some trial)
        ~config:(Config.sexp_of_t config)
    in
    let failure =
      { Failure.replay
      ; scenario
      ; shrunk = (if Scenario.equal scenario shrunk then None else Some shrunk)
      ; outcome = initial_run.outcome
      ; context
      ; activity
      ; artifact = None
      }
    in
    let artifact =
      if write_artifact
      then
        Replay.Artifacts.write
          ~test
          ~settings
          ~trial
          ~contents:
            (Failure.to_string_hum failure ^ Replay.artifact_appendix failure.replay)
      else None
    in
    ignore shrunk_run;
    Some { failure with artifact }
;;
