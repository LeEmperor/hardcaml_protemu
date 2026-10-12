(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "input_events_four_state_testbench.ml" *)
(* The four-state verification environment for Input_events, built for one named property.

   PROPERTY: bounded unknown-pad recovery and unknown isolation.

   An external pad that is not driven to a known level is observed as X at [pin_in_i]. The
   contract this file checks is:

   1. Isolation. [event_o] and [overflow_o] never carry an unknown bit, because the event
      path does not depend on the pad. Pad bits that are driven to a known level never
      become unknown in [snapshot_o] either: contamination is per pin.
   2. Contamination is real. While an unknown pad sample is inside the synchronizer, the
      affected [snapshot_o] bits are X. A test that reads them as 0 has coerced an unknown
      and is failed, not passed.
   3. Bounded recovery. Three edges after the last edge that sampled an unknown pad bit,
      every output is known again and equals the ordinary f_model prediction. A
      synchronous reset edge restores known outputs at that same edge.

   Injection site, window, and resolution are declared, not inferred. X is driven only at
   the [pin_in_i] port, for whole sampling edges, and the window ends when the environment
   drives the pad back to a known level at a stated timestamp. Nothing inside the DUT is
   forced. This is the digital consequence of an undriven pad; it is NOT metastability,
   setup/hold, or analog resolution evidence, and the three-edge bound is the synchronizer
   register depth, not a reliability claim (verification.md, "Four-state observations").

   BACKEND SEMANTICS. The installed four-state logic is pessimistic where Verilog is not:
   X &: 0 is X here, while a Verilog simulator resolves it to 0. That affects the edge
   detectors only, where an unknown [previous] makes the result unknown even against a
   known zero [stage1]. Those bits are therefore declared unconstrained for the edges that
   the pessimism can reach, and are required known again outside that window. The recovery
   bound above is consequently an upper bound: an optimistic simulator recovers no later.

   VALIDITY IS NOT LOGIC. [Observation.Unavailable]/[Unspecified] describe whether an
   observation can be compared at all; X and Z are values seen on a wire. They are kept in
   different types on purpose, so this file has its own [Word] and [Expect] rather than
   reusing observation.ml (see its header). An unconstrained bit here is a contract
   statement about that bit, and it is still recorded in the transcript.
*)

open! Core
open! Hardcaml
open! Hardcaml_protemu
module Evsim = Hardcaml_event_driven_sim.Four_state_simulator
module Logic = Hardcaml_event_driven_sim.Four_state_logic
module Circuit = Evsim.With_interface (Input_events.I) (Input_events.O)
module Simulator = Evsim.Simulator
module F_model = Protemu_f_model

let time_unit = "tick"
let half_period = 5
let period = half_period * 2
let first_rising_edge = half_period
let pin_width = 8
let event_width = 6
let all_pins = (1 lsl pin_width) - 1
let all_events = (1 lsl event_width) - 1

(* The synchronizer is stage0/stage1/previous, so an unknown sample is out of the block
   three edges after the last edge that captured it. Stated here as the contract bound
   rather than read back from the DUT. *)
let recovery_edges = 3

(* A four-state word, kept as the simulator prints it: one character per bit, most
   significant first, from
   {0 ,1,X,Z}
   . Converting to an int is possible only when every bit is known, and the conversion is
   a function that can fail rather than a truncation. *)
module Word = struct
  type t =
    { width : int
    ; text : string
    }
  [@@deriving sexp_of, compare, equal]

  let of_logic logic = { width = Logic.width logic; text = Logic.to_string logic }

  let mask t ~f =
    String.foldi t.text ~init:0 ~f:(fun index mask character ->
      let bit = t.width - 1 - index in
      if f character then mask lor (1 lsl bit) else mask)
  ;;

  let unknown t = mask t ~f:(Char.equal 'X')
  let floating t = mask t ~f:(Char.equal 'Z')
  let not_known t = unknown t lor floating t
  let ones t = mask t ~f:(Char.equal '1')
  let is_known t = not_known t = 0
  let to_string t = t.text

  let to_int t =
    if is_known t
    then Ok (ones t)
    else Or_error.error_s [%message "four-state word has unknown bits" (t.text : string)]
  ;;

  (* Build the value driven at the pad. [unknown] bits become X; the rest take their bit
     from [value]. *)
  let create ~width ~value ~unknown =
    let text =
      String.init width ~f:(fun index ->
        let bit = width - 1 - index in
        if unknown land (1 lsl bit) <> 0
        then 'X'
        else if value land (1 lsl bit) <> 0
        then '1'
        else '0')
    in
    { width; text }
  ;;

  let to_logic t = Logic.of_string t.text

  (* The controlled observation defect: an adapter that reads an unknown bit as zero. It
     exists so the property can be shown to fail when a reader coerces, which is the one
     mistake a four-state check must not survive. *)
  let coerce_unknown_to_zero t =
    { t with
      text =
        String.map t.text ~f:(function
          | 'X' | 'Z' -> '0'
          | character -> character)
    }
  ;;
end

(* What the contract says about one observation at one edge, bit by bit. Three disjoint
   sets: bits that must be X, bits that must be known and equal [value], and the rest,
   which the contract leaves unconstrained inside a declared window. *)
module Expect = struct
  type t =
    { required_unknown : int
    ; required_known : int
    ; value : int
    }
  [@@deriving sexp_of, compare, equal]

  let create ~width ~required_unknown ~value =
    let full = (1 lsl width) - 1 in
    { required_unknown
    ; required_known = full land lnot required_unknown
    ; value = value land full
    }
  ;;

  (* [required_unknown] bits plus [unconstrained] bits are both excluded from the value
     comparison, but only the first must actually be X. *)
  let create_with_window ~width ~unconstrained ~value =
    let full = (1 lsl width) - 1 in
    { required_unknown = 0
    ; required_known = full land lnot unconstrained
    ; value = value land full
    }
  ;;

  let to_string ~width t =
    String.init width ~f:(fun index ->
      let bit = width - 1 - index in
      let set mask = mask land (1 lsl bit) <> 0 in
      if set t.required_unknown
      then 'X'
      else if not (set t.required_known)
      then '?'
      else if set t.value
      then '1'
      else '0')
  ;;
end

module Reason = struct
  type t =
    | Unexpected_unknown (* a bit the contract requires known is X or Z *)
    | Missing_unknown (* a bit the contract requires unknown was read as a level *)
    | Value (* both sides known, different *)
    | Unknown_past_deadline (* still unknown after the bounded recovery window *)
  [@@deriving sexp, compare, equal]

  let to_string t = Sexp.to_string (sexp_of_t t)
end

module Action = struct
  type t =
    | Pad of int
    | Pad_unknown of
        { known : int
        ; unknown : int
        }
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

  (* The property is about unknown pads, so a case without one is not a smaller case; it
     is a different test. The shrinker keeps this. *)
  let injects_unknown t =
    List.exists t.transitions ~f:(fun transition ->
      match transition.action with
      | Pad_unknown { unknown; _ } -> unknown <> 0
      | Pad _ | Reset _ | Event_set _ | Event_ack _ -> false)
  ;;
end

type input_state =
  { pad_value : int
  ; pad_unknown : int
  ; reset : bool
  ; event_set : int
  ; event_ack : int
  }

let initial_inputs =
  { pad_value = 0; pad_unknown = 0; reset = false; event_set = 0; event_ack = 0 }
;;

let apply_action state = function
  | Action.Pad value -> { state with pad_value = value land all_pins; pad_unknown = 0 }
  | Pad_unknown { known; unknown } ->
    { state with pad_value = known land all_pins; pad_unknown = unknown land all_pins }
  | Reset reset -> { state with reset }
  | Event_set event_set -> { state with event_set = event_set land all_events }
  | Event_ack event_ack -> { state with event_ack = event_ack land all_events }
;;

let edge_time edge = first_rising_edge + (edge * period)

(* Walk the scenario's timeline once, applying every transition due at or before each
   rising edge. Shared by the predictor and the deadline, so both read the same schedule.
   Coincident stimulus settles before the clock transition, as in the Stage 4 contract. *)
let fold_edges (scenario : Scenario.t) ~init ~f =
  let remaining = ref scenario.transitions in
  let inputs = ref initial_inputs in
  let rec loop edge accumulator =
    if edge >= scenario.edges
    then accumulator
    else (
      let time = edge_time edge in
      let rec apply_due () =
        match !remaining with
        | transition :: rest when transition.time <= time ->
          inputs := apply_action !inputs transition.action;
          remaining := rest;
          apply_due ()
        | _ -> ()
      in
      apply_due ();
      loop (edge + 1) (f accumulator ~edge ~time ~inputs:!inputs))
  in
  loop 0 init
;;

(* The first edge from which every output must be known again, derived from the scenario
   rather than from the DUT: three edges after the last edge that sampled an unknown pad,
   or the last reset edge if that is later. A reset edge clears the synchronizer, so it
   needs no recovery window of its own. *)
let recovery_deadline scenario =
  let last_unknown, last_reset =
    fold_edges
      scenario
      ~init:(None, None)
      ~f:(fun (unknown, reset) ~edge ~time:_ ~inputs ->
        if inputs.reset
        then unknown, Some edge
        else if inputs.pad_unknown <> 0
        then Some edge, reset
        else unknown, reset)
  in
  match last_unknown, last_reset with
  | None, _ -> 0
  | Some unknown, Some reset when reset > unknown -> reset
  | Some unknown, _ -> unknown + recovery_edges
;;

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

module Prediction = struct
  type t =
    { edge : int
    ; time : int
    ; sampled_at : int
    ; expectations : (string * Expect.t) list
    }
  [@@deriving sexp_of]
end

(* Two references, deliberately separated (verification.md, "Functional model, drivers,
   monitors, and prediction"). The ordinary f_model supplies every known value. A
   dedicated contamination model - three unknown masks shifted one stage per edge -
   supplies the X-sensitive part and nothing else. f_model is stepped with the unknown pad
   bits replaced by zero; those bit positions are exactly the ones the contamination
   pipeline excludes from comparison for exactly the edges they can reach, so the
   substituted value is never compared. It is not an X oracle and is not asked to be one. *)
module Contamination = struct
  type t =
    { stage0 : int
    ; stage1 : int
    ; previous : int
    }

  let cleared = { stage0 = 0; stage1 = 0; previous = 0 }

  let step t ~pad_unknown =
    { stage0 = pad_unknown; stage1 = t.stage0; previous = t.stage1 }
  ;;

  (* An unknown [previous] makes the edge detectors unknown for this backend even where
     [stage1] is a known zero. Those bits are left unconstrained rather than predicted. *)
  let edge_window t = t.stage1 lor t.previous
end

let predict (scenario : Scenario.t) =
  let pins = ref F_model.Input_pins.cleared in
  let events = ref F_model.Event.cleared in
  let contamination = ref Contamination.cleared in
  fold_edges scenario ~init:[] ~f:(fun predictions ~edge ~time ~inputs ->
    if inputs.reset
    then (
      pins := F_model.Input_pins.cleared;
      events := F_model.Event.cleared;
      contamination := Contamination.cleared)
    else (
      pins
      := F_model.Input_pins.step
           !pins
           ~pin_in:(inputs.pad_value land lnot inputs.pad_unknown);
      events
      := F_model.Event.step
           !events
           ~set:(selected inputs.event_set)
           ~ack:(selected inputs.event_ack);
      contamination := Contamination.step !contamination ~pad_unknown:inputs.pad_unknown);
    let snapshot_unknown = !contamination.stage1 in
    let edge_window = Contamination.edge_window !contamination in
    let expectations =
      [ ( "snapshot_o"
        , Expect.create
            ~width:pin_width
            ~required_unknown:snapshot_unknown
            ~value:(F_model.Input_pins.snapshot !pins) )
      ; ( "rising_o"
        , Expect.create_with_window
            ~width:pin_width
            ~unconstrained:edge_window
            ~value:(F_model.Input_pins.rising !pins) )
      ; ( "falling_o"
        , Expect.create_with_window
            ~width:pin_width
            ~unconstrained:edge_window
            ~value:(F_model.Input_pins.falling !pins) )
        (* Isolation: the event path never reads the pad, so no bit of either word may be
           unknown at any edge, however contaminated the pad is. *)
      ; ( "event_o"
        , Expect.create
            ~width:event_width
            ~required_unknown:0
            ~value:(event_mask !events F_model.Event.is_set) )
      ; ( "overflow_o"
        , Expect.create
            ~width:event_width
            ~required_unknown:0
            ~value:(event_mask !events F_model.Event.overflowed) )
      ]
    in
    { Prediction.edge; time; sampled_at = time + 1; expectations } :: predictions)
  |> List.rev
;;

module Defect = struct
  type t =
    | None
    (* A design defect: the pad is wired into the event set path, so an unknown pad makes
       the event status unknown. The isolation check must catch this. *)
    | Leak_pad_into_events
    (* An environment defect: the observation adapter reads X as a level. The
       contamination check must catch this, or the property could pass by coercion. *)
    | Coerce_unknown_to_zero
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
    ; observations : (string * Word.t) list
    }
  [@@deriving sexp_of]

  let find t name = List.Assoc.find_exn t.observations name ~equal:String.equal

  let to_line t =
    let observations =
      List.map t.observations ~f:(fun (name, word) ->
        [%string "%{name}=%{Word.to_string word}"])
      |> String.concat ~sep:" "
    in
    [%string
      "edge %{t.edge#Int} t=%{t.time#Int} sample=%{t.sampled_at#Int} %{observations}"]
  ;;

  let fully_known t = List.for_all t.observations ~f:(fun (_, word) -> Word.is_known word)
end

module Activity = struct
  type t =
    { time : int
    ; signal : string
    ; value : string
    }
  [@@deriving sexp_of]

  let to_line t = [%string "t=%{t.time#Int} %{t.signal}=%{t.value}"]
end

module Mismatch = struct
  type t =
    { edge : int
    ; time : int
    ; sampled_at : int
    ; observation : string
    ; reason : Reason.t
    ; bits : int
    ; expected : string
    ; actual : string
    }
  [@@deriving sexp_of]

  (* What makes two failures the same failure while shrinking: the observation and why it
     failed, not the edge it happened on or the bits involved. *)
  let identity t = [%string "%{t.observation}/%{Reason.to_string t.reason}"]
end

module Outcome = struct
  type t =
    | Passed
    | Budget_exceeded of
        { edges : int
        ; transitions : int
        }
    | Mismatch of Mismatch.t
  [@@deriving sexp_of]

  let identity = function
    | Passed -> None
    | Budget_exceeded _ -> Some "budget"
    | Mismatch mismatch -> Some (Mismatch.identity mismatch)
  ;;
end

module Run = struct
  type t =
    { outcome : Outcome.t
    ; deadline : int
    ; predictions : Prediction.t list
    ; actual : Sample.t list
    ; activity : Activity.t list
    }
  [@@deriving sexp_of]

  let passed t =
    match t.outcome with
    | Outcome.Passed -> true
    | Budget_exceeded _ | Mismatch _ -> false
  ;;
end

let bit value = if value then Logic.vdd else Logic.gnd
let logic_bits width value = Logic.of_bits (Bits.of_int_trunc ~width value)

let observe defect signal =
  let word = Word.of_logic (Simulator.Signal.read signal) in
  match (defect : Defect.t) with
  | Coerce_unknown_to_zero -> Word.coerce_unknown_to_zero word
  | None | Leak_pad_into_events -> word
;;

let create_dut (defect : Defect.t) scope (i : _ Input_events.I.t) =
  match defect with
  | Leak_pad_into_events ->
    Input_events.create
      scope
      { i with
        event_set_i =
          Signal.(i.event_set_i |: select i.pin_in_i ~high:(event_width - 1) ~low:0)
      }
  | None | Coerce_unknown_to_zero -> Input_events.create scope i
;;

let monitor defect signal_name signal activity =
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
           ; value = Word.to_string (observe defect signal)
           }
           :: !activity)
;;

let run_evsim (config : Config.t) (scenario : Scenario.t) =
  let samples = ref [] in
  let activity = ref [] in
  let defect = config.defect in
  let testbench =
    Circuit.with_processes
      (create_dut defect (Scope.create ~flatten_design:true ()))
      (fun inputs outputs ->
        [ monitor defect "pin_in_i" inputs.pin_in_i.signal activity
        ; monitor defect "reset_i" inputs.reset_i.signal activity
        ; monitor defect "snapshot_o" outputs.snapshot_o.signal activity
        ; monitor defect "rising_o" outputs.rising_o.signal activity
        ; monitor defect "falling_o" outputs.falling_o.signal activity
        ; monitor defect "event_o" outputs.event_o.signal activity
        ; monitor defect "overflow_o" outputs.overflow_o.signal activity
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
      transition.time, index, transition.action)
    |> List.sort ~compare:(fun (a_time, a_index, _) (b_time, b_index, _) ->
      match Int.compare a_time b_time with
      | 0 -> Int.compare a_index b_index
      | order -> order)
  in
  List.iter scheduled_transitions ~f:(fun (time, _, action) ->
    schedule time (fun () ->
      match action with
      | Action.Pad value ->
        set
          inputs.pin_in_i.signal
          (Word.to_logic (Word.create ~width:pin_width ~value ~unknown:0))
      | Pad_unknown { known; unknown } ->
        set
          inputs.pin_in_i.signal
          (Word.to_logic (Word.create ~width:pin_width ~value:known ~unknown))
      | Reset value -> set inputs.reset_i.signal (bit value)
      | Event_set value -> set inputs.event_set_i.signal (logic_bits event_width value)
      | Event_ack value -> set inputs.event_ack_i.signal (logic_bits event_width value)));
  (* Same clock ownership and coincidence convention as the two-state timed environment:
     all stimulus callbacks are inserted before all clock callbacks and are given a finite
     delta allowance to settle, so "at the edge" means before it. *)
  List.iter (List.init scenario.edges ~f:Fn.id) ~f:(fun edge ->
    let rising_time = edge_time edge in
    schedule rising_time (fun () ->
      after_delta_settle 32 (fun () -> set inputs.clock_i.signal Logic.vdd));
    schedule (rising_time + half_period) (fun () ->
      after_delta_settle 32 (fun () -> set inputs.clock_i.signal Logic.gnd)));
  List.iter (List.init scenario.edges ~f:Fn.id) ~f:(fun edge ->
    let time = edge_time edge in
    let sampled_at = time + 1 in
    schedule sampled_at (fun () ->
      samples
      := { Sample.edge
         ; time
         ; sampled_at
         ; observations =
             [ "snapshot_o", observe defect outputs.snapshot_o.signal
             ; "rising_o", observe defect outputs.rising_o.signal
             ; "falling_o", observe defect outputs.falling_o.signal
             ; "event_o", observe defect outputs.event_o.signal
             ; "overflow_o", observe defect outputs.overflow_o.signal
             ]
         }
         :: !samples));
  let last_sample = edge_time (scenario.edges - 1) + 1 in
  Simulator.run simulator ~time_limit:(last_sample + 1);
  List.rev !samples, List.rev !activity
;;

(* Validity first, then value, and an unknown bit is never silently dropped on either
   side. The order matters: a required-known bit that came back X is reported as an
   unexpected unknown rather than as a value difference against a coerced integer. *)
let check_observation ~(expect : Expect.t) ~(actual : Word.t) =
  let unexpected = expect.required_known land Word.not_known actual in
  if unexpected <> 0
  then Some (Reason.Unexpected_unknown, unexpected)
  else (
    let missing = expect.required_unknown land lnot (Word.unknown actual) in
    if missing <> 0
    then Some (Reason.Missing_unknown, missing)
    else (
      let differing = expect.required_known land (Word.ones actual lxor expect.value) in
      if differing <> 0 then Some (Reason.Value, differing) else None))
;;

let first_mismatch ~deadline predictions samples =
  let per_edge =
    List.fold2 predictions samples ~init:None ~f:(fun found prediction sample ->
      match found with
      | Some _ -> found
      | None ->
        List.find_map prediction.Prediction.expectations ~f:(fun (name, expect) ->
          let actual = Sample.find sample name in
          Option.map (check_observation ~expect ~actual) ~f:(fun (reason, bits) ->
            { Mismatch.edge = prediction.edge
            ; time = prediction.time
            ; sampled_at = prediction.sampled_at
            ; observation = name
            ; reason
            ; bits
            ; expected = Expect.to_string ~width:actual.width expect
            ; actual = Word.to_string actual
            })))
  in
  let per_edge =
    match per_edge with
    | List.Or_unequal_lengths.Ok found -> found
    | Unequal_lengths ->
      Some
        { Mismatch.edge = List.length samples
        ; time = edge_time (List.length samples)
        ; sampled_at = edge_time (List.length samples) + 1
        ; observation = "sample"
        ; reason = Reason.Value
        ; bits = 1
        ; expected = Int.to_string (List.length predictions)
        ; actual = Int.to_string (List.length samples)
        }
  in
  match per_edge with
  | Some _ -> per_edge
  (* The bounded-recovery statement, checked against the DUT rather than against the
     contamination model that produced the per-edge expectations. *)
  | None ->
    List.find_map samples ~f:(fun sample ->
      if sample.edge < deadline || Sample.fully_known sample
      then None
      else
        List.find_map sample.observations ~f:(fun (name, word) ->
          let bits = Word.not_known word in
          if bits = 0
          then None
          else
            Some
              { Mismatch.edge = sample.edge
              ; time = sample.time
              ; sampled_at = sample.sampled_at
              ; observation = name
              ; reason = Reason.Unknown_past_deadline
              ; bits
              ; expected = String.make word.width '0'
              ; actual = Word.to_string word
              }))
;;

let run (config : Config.t) (scenario : Scenario.t) =
  let predictions = predict scenario in
  let deadline = recovery_deadline scenario in
  if scenario.edges > config.max_edges
     || List.length scenario.transitions > config.max_transitions
  then
    { Run.outcome =
        Budget_exceeded
          { edges = scenario.edges; transitions = List.length scenario.transitions }
    ; deadline
    ; predictions
    ; actual = []
    ; activity = []
    }
  else (
    let actual, activity = run_evsim config scenario in
    let outcome =
      match first_mismatch ~deadline predictions actual with
      | None -> Outcome.Passed
      | Some mismatch -> Outcome.Mismatch mismatch
    in
    { Run.outcome; deadline; predictions; actual; activity })
;;

(* A generated case must keep the property's subject: an applied reset, at least one edge
   that samples an unknown pad, and enough edges after it to observe recovery. The
   shrinker preserves all three, so it never turns the four-state property into a
   two-state one. *)
let prerequisite (scenario : Scenario.t) =
  let deadline = recovery_deadline scenario in
  scenario.edges > 0
  && Scenario.ordered scenario
  && Scenario.has_reset_prerequisite scenario
  && Scenario.injects_unknown scenario
  && deadline > 0
  && deadline < scenario.edges
;;

module Generator = struct
  module G = Base_quickcheck.Generator
  open G.Let_syntax

  let extra = G.of_weighted_list [ 3., `Pad; 2., `Set; 2., `Ack ]

  let scenario =
    let%bind size = G.size in
    let edges = Int.min 20 (Int.max 10 (size + 10)) in
    (* The window must close early enough that the three recovery edges are inside the
       run; the prerequisite rejects anything that is not, and the generator is written so
       it never produces one. *)
    let latest_start_edge = edges - 7 in
    let%bind lead = G.int_uniform_inclusive 0 (period - 1)
    and start_edge = G.int_uniform_inclusive 1 latest_start_edge
    and trail = G.int_uniform_inclusive 0 period
    and unknown = G.int_uniform_inclusive 1 all_pins
    and known = G.int_uniform_inclusive 0 all_pins
    and resolved = G.int_uniform_inclusive 0 all_pins
    and extra_count = G.int_uniform_inclusive 0 (Int.min 16 (size + 2)) in
    (* The window is built around a chosen sampling edge rather than from a free start and
       width, so a generated case always has at least one edge that samples an unknown
       pad. A window that fell between two edges would be a valid scenario but not an
       instance of this property. *)
    let window_start = edge_time start_edge - lead in
    let window_end = edge_time start_edge + 1 + trail in
    let last_time = edge_time (edges - 1) in
    let%map extras =
      G.list_with_length
        (let%bind kind = extra
         and event = G.int_uniform_inclusive 0 all_events
         and byte = G.int_uniform_inclusive 0 all_pins
         and event_time = G.int_uniform_inclusive (first_rising_edge + 1) last_time
         and pad_time = G.int_uniform_inclusive (window_end + 1) (last_time + 1) in
         G.return
           (match kind with
            | `Pad -> Transition.create pad_time (Pad byte)
            | `Set -> Transition.create event_time (Event_set event)
            | `Ack -> Transition.create event_time (Event_ack event)))
        ~length:extra_count
    in
    let transitions =
      [ Transition.create 0 (Reset true)
      ; Transition.create (first_rising_edge + 1) (Reset false)
      ; Transition.create window_start (Pad_unknown { known; unknown })
      ; Transition.create window_end (Pad resolved)
      ]
      @ extras
      |> List.stable_sort ~compare:Transition.compare
    in
    Scenario.create ~edges transitions
  ;;

  (* One fixed case for the controlled defects: a single unknown bit, held across exactly
     one sampling edge, with no event traffic at all. The only thing that can make
     [event_o] unknown is a pad leak, and the only thing that can make [snapshot_o] read
     as a level while the unknown is inside the synchronizer is a coercing observer. *)
  let controlled_scenario =
    G.return
      (Scenario.create
         ~edges:9
         [ Transition.create 0 (Reset true)
         ; Transition.create 6 (Reset false)
         ; Transition.create 24 (Pad_unknown { known = 0; unknown = 1 })
         ; Transition.create 34 (Pad 0)
         ])
  ;;
end

module Failure = struct
  type t =
    { replay : Replay.t
    ; scenario : Scenario.t
    ; shrunk : Scenario.t option
    ; outcome : Outcome.t
    ; deadline : int
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
      ; [%string "  observation:      %{mismatch.observation}"]
      ; [%string "  reason:           %{Reason.to_string mismatch.reason}"]
      ; [%string "  offending bits:   0x%{mismatch.bits#Int}"]
      ; [%string "  expected:         %{mismatch.expected}"]
      ; [%string "  actual (dut):     %{mismatch.actual}"]
      ]
  ;;

  let scenario_lines label (scenario : Scenario.t) =
    [%string "%{label}:"]
    :: [%string "  edges: %{scenario.edges#Int}"]
    :: List.map scenario.transitions ~f:(fun transition ->
      let transition = Transition.sexp_of_t transition in
      [%string "  %{transition#Sexp}"])
  ;;

  let to_lines ?(redact_source = false) t =
    List.concat
      [ [ "input_events: four-state unknown-pad property failed"; "" ]
      ; [ "reproduction:" ]
      ; Replay.to_lines ~redact_source t.replay
      ; [ [%string "  time unit:        %{time_unit}"]
        ; [%string
            "  clock:            period=%{period#Int}, first \
             rising=%{first_rising_edge#Int}"]
        ; "  coincidence:      stimulus settles before the clock transition"
        ; [%string "  injection:        X driven at pin_in_i only"]
        ; [%string
            "  recovery bound:   %{recovery_edges#Int} edges after the last unknown \
             sample"]
        ; [%string "  recovery edge:    %{t.deadline#Int}"]
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

let context_for_mismatch (run : Run.t) =
  match run.outcome with
  | Outcome.Mismatch mismatch ->
    ( List.filter run.actual ~f:(fun (sample : Sample.t) ->
        Int.abs (sample.edge - mismatch.edge) <= 2)
    , List.filter run.activity ~f:(fun (activity : Activity.t) ->
        Int.abs (activity.time - mismatch.time) <= period) )
  | Passed | Budget_exceeded _ -> run.actual, run.activity
;;

(* Temporal shrinking, as in the two-state timed environment: drop a transition, move one
   earlier without reordering, or shorten the run. Every candidate must still satisfy the
   prerequisite and fail with the same identity. *)
let shrink_candidates (scenario : Scenario.t) =
  let removed =
    List.init (List.length scenario.transitions) ~f:(fun skip ->
      { scenario with
        transitions = List.filteri scenario.transitions ~f:(fun index _ -> index <> skip)
      })
  in
  let moved =
    List.filter_mapi scenario.transitions ~f:(fun index (transition : Transition.t) ->
      if transition.time = 0
      then None
      else (
        let previous_time =
          match List.nth scenario.transitions (index - 1) with
          | None -> 0
          | Some (previous : Transition.t) -> previous.time
        in
        let time = Int.max previous_time (transition.time - 1) in
        let transitions =
          List.mapi scenario.transitions ~f:(fun candidate_index candidate ->
            if candidate_index = index
            then { candidate with Transition.time }
            else candidate)
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
  ?(prerequisite = prerequisite)
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
      then
        raise_s [%message "four-state generator violated its prerequisite" (trial : int)];
      let run = run config scenario in
      match Outcome.identity run.outcome with
      | None -> search (trial + 1)
      | Some _ -> Some (trial, scenario, run))
  in
  match search 0 with
  | None -> None
  | Some (trial, scenario, initial_run) ->
    let identity = Outcome.identity initial_run.Run.outcome in
    let rec shrink remaining scenario =
      if remaining <= 0
      then scenario
      else (
        match
          List.find_map (shrink_candidates scenario) ~f:(fun candidate ->
            if not (prerequisite candidate)
            then None
            else (
              let candidate_run = run config candidate in
              if Option.equal
                   String.equal
                   (Outcome.identity candidate_run.Run.outcome)
                   identity
              then Some candidate
              else None))
        with
        | None -> scenario
        | Some candidate -> shrink (remaining - 1) candidate)
    in
    let shrunk = shrink shrink_steps scenario in
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
      ; deadline = initial_run.deadline
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
    Some { failure with artifact }
;;
