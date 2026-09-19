(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "env.ml" *)
(* The shared verification environment: one runner, one checker, one failure report.

   This is the P1.6 harness (verification.md, and formatting_guide.md section 10.1). A
   block is verified by describing it once as a [Device] - how a scenario item reaches its
   ports, what the independent model does with the same item, what each side observes, and
   what a monitor reconstructs from those observations - and the same description then
   serves a directed expect test and a bounded Quickcheck run. There is no second runner
   and no second checker, so the two kinds of test cannot disagree about what "the same
   edge" means.

   Responsibilities are split as in UVM, without a UVM framework:

   - a scenario is a list of items, one per rising edge, produced by a directed test or by
     a generator; it is data and drives nothing itself;
   - [Dut] and [F_model] are the drivers, translating one item into interface activity and
     into a functional-model step;
   - [Monitor] reconstructs items from observations only, never from what a driver
     intended, so a driver that offered something the design refused cannot be mistaken
     for a transfer;
   - the runner below owns simulation time. It is the only thing that advances either
     side, and it advances both from the same item.

   The per-edge order is fixed and is the whole cycle-exact contract (verification.md
   section 2): drive the scheduled inputs, settle combinational logic, capture the
   pre-edge acceptance conditions, take the edge on both sides, capture the settled
   post-edge observations, then check. Nothing is realigned, no cycles are discarded, and
   the first disagreement stops the trial. A device whose model needs an implementation
   detail of the RTL to predict an observation has a specification gap, not a harness gap.

   A reactive peer belongs to the environment. A device that needs one creates a separate,
   identically initialised instance inside each of [Dut] and [F_model]; because the runner
   compares both sides at every edge, neither peer can conceal the other side's divergence
   for more than the edge it happens on.
*)

open! Core

(* Which way an observed item travelled, relative to the design. Reserved here, along with
   [Boundary] and the stream name, for construction-plan.md section 6: a logical bit
   accepted at a future stream interface and a physical symbol seen at the pins are
   different events, and a monitor that recorded only "a byte" could not tell them apart
   later. Nothing in P1.6 implements those engines; the conventions exist so the monitors
   written now do not have to be rewritten when they arrive. *)
module Direction = struct
  type t =
    | Outbound
    | Inbound
  [@@deriving sexp_of, compare, equal]
end

(* Where an item sits in its stream. [Complete] is a whole item observed at one edge;
   [Start], [Continue] and [End] delimit one that spans edges, such as a transaction
   between a claim and its release. *)
module Boundary = struct
  type t =
    | Start
    | Continue
    | End
    | Complete
  [@@deriving sexp_of, compare, equal]
end

(* One item a monitor reconstructed from observations. [edge] is the runner's monotonic
   edge index, which does not restart when the design is reset, so two items are ordered
   even across a reset. [error] carries a protocol violation the monitor saw; an item with
   an error is still reported, because "the bytes were right and the wire timing was not"
   has to be able to fail. *)
module Observed_item = struct
  type t =
    { edge : int
    ; stream : string
    ; direction : Direction.t
    ; boundary : Boundary.t
    ; payload : Sexp.t
    ; error : string option
    }
  [@@deriving sexp_of, compare, equal]

  let to_string t =
    let error =
      match t.error with
      | None -> ""
      | Some error -> [%string " error=%{error}"]
    in
    let boundary = Sexp.to_string (Boundary.sexp_of_t t.boundary) in
    let direction = Sexp.to_string (Direction.sexp_of_t t.direction) in
    [%string
      "@%{t.edge#Int} %{t.stream}/%{direction}/%{boundary} %{t.payload#Sexp}%{error}"]
  ;;
end

module type Device = sig
  (* Named in reports; one word, the block under test. *)
  val name : string

  (* Everything a trial is parameterised by. It is recorded in the reproduction record, so
     anything that changes what the scenario means belongs here rather than in a global. *)
  module Config : sig
    type t

    val sexp_of_t : t -> Sexp.t
  end

  (* One rising edge's stimulus. Generated up front, so a trial's stimulus does not depend
     on what the design did. *)
  module Item : sig
    type t [@@deriving sexp_of]
  end

  (* The Hardcaml side. The five calls are the runner's per-edge order and nothing else
     may advance the simulation. *)
  module Dut : sig
    type t

    val create : Config.t -> t

    (* Scheduled inputs for this edge, applied before anything settles. *)
    val drive : t -> Item.t -> unit

    (* Settle combinational logic against the inputs just driven; no edge is taken. *)
    val settle : t -> unit

    (* Acceptance conditions as they stand before the edge: a handshake is sampled here,
       never from a ready that rises after the edge. *)
    val pre_edge : t -> Observation.Set.t
    val edge : t -> unit

    (* Settled observations after the edge. *)
    val post_edge : t -> Observation.Set.t
  end

  (* The independent reference. It shares the instruction specification, scenario data and
     reporting with the DUT and nothing else; it must not be computed from Hardcaml. *)
  module F_model : sig
    type t

    val create : Config.t -> t
    val pre_edge : t -> Item.t -> Observation.Set.t
    val edge : t -> Item.t -> t
    val post_edge : t -> Observation.Set.t
  end

  (* Reconstructs items from one side's post-edge observations. The runner gives each side
     its own instance and compares what the two reconstructed. *)
  module Monitor : sig
    type t

    val create : Config.t -> t
    val observe : t -> edge:int -> Observation.Set.t -> t * Observed_item.t list
  end

  (* Observations that must be [Defined] on both sides. One that an adapter cannot expose
     is an error rather than a quietly skipped comparison (verification.md section 5). *)
  val required_pre_edge : string list
  val required_post_edge : string list
end

module Phase = struct
  type t =
    | Pre_edge
    | Post_edge
    | Monitor
  [@@deriving sexp_of, compare, equal]

  let to_string t = Sexp.to_string (sexp_of_t t)
end

(* What disagreed. An observation difference names the observation; a monitor difference
   names the two reconstructed item lists, which is how "correct data, wrong wire timing"
   is reported. *)
module Detail = struct
  type t =
    | Observation of Observation.Difference.t
    | Items of
        { expected : Observed_item.t list
        ; actual : Observed_item.t list
        }
  [@@deriving sexp_of, compare, equal]
end

module Mismatch = struct
  type t =
    { edge : int
    ; phase : Phase.t
    ; item : Sexp.t
    ; detail : Detail.t
    }
  [@@deriving sexp_of, compare, equal]
end

module Outcome = struct
  type t =
    | Passed of { edges : int }
    | Timed_out of
        { budget : int
        ; unscheduled : int
        }
    | Mismatch of Mismatch.t
  [@@deriving sexp_of, compare, equal]

  let is_failure = function
    | Passed _ -> false
    | Timed_out _ | Mismatch _ -> true
  ;;

  (* What makes two failures "the same failure" while shrinking: the phase and the thing
     that disagreed, not the edge it happened on or the values involved. A shrunk scenario
     that fails a different check is a different test and is rejected. *)
  let identity t =
    match t with
    | Passed _ -> None
    | Timed_out _ -> Some "timeout"
    | Mismatch { phase; detail; _ } ->
      let phase = Phase.to_string phase in
      (match detail with
       | Observation { observation; reason; _ } ->
         let reason = Sexp.to_string (Observation.Reason.sexp_of_t reason) in
         Some [%string "%{phase}/%{observation}/%{reason}"]
       | Items _ -> Some [%string "%{phase}/items"])
  ;;
end

(* One edge as the runner saw it, kept for trace context. The observations recorded are
   the DUT's: when the trial fails they are the side being questioned, and when it passes
   they equal the model's by construction. *)
module Edge_record = struct
  type t =
    { edge : int
    ; item : Sexp.t
    ; pre_edge : Observation.Set.t
    ; post_edge : Observation.Set.t
    ; items : Observed_item.t list
    }
  [@@deriving sexp_of]

  let to_lines t =
    (* One labelled block per phase; a continuation line is indented under its label so a
       wrapped observation set still reads as one phase. *)
    let block label observations =
      List.mapi (Observation.Set.to_lines observations) ~f:(fun index line ->
        let label = if index = 0 then label else "        " in
        [%string "  %{label}%{line}"])
    in
    List.concat
      [ [ [%string "edge %{t.edge#Int}  item %{t.item#Sexp}"] ]
      ; block "before  " t.pre_edge
      ; block "after   " t.post_edge
      ; List.map t.items ~f:(fun item -> [%string "  item    %{item#Observed_item}"])
      ]
  ;;
end

module Make (D : Device) = struct
  module Phase = Phase
  module Mismatch = Mismatch
  module Outcome = Outcome
  module Edge_record = Edge_record

  (* One trial's result: the outcome, and as much of the transcript as was kept. *)
  module Run = struct
    type t =
      { outcome : Outcome.t
      ; transcript : Edge_record.t list
      ; truncated : bool
      }

    let to_lines t =
      let head = if t.truncated then [ "(earlier edges truncated)" ] else [] in
      head @ List.concat_map t.transcript ~f:Edge_record.to_lines
    ;;

    let print t = List.iter (to_lines t) ~f:print_endline
  end

  (* Run one scenario. [context] bounds the transcript kept for a failure report;
     [transcript:true] keeps all of it, which is what a directed test prints.

     The edge budget is the trial's finite bound. Running out of it is a timeout, not a
     pass: a scenario the design never finished is not evidence that it agreed. *)
  let run ?(context = 6) ?(transcript = false) config ~scenario ~edge_budget =
    let dut = D.Dut.create config in
    let f_model = ref (D.F_model.create config) in
    let dut_monitor = ref (D.Monitor.create config) in
    let f_model_monitor = ref (D.Monitor.create config) in
    let keep = if transcript then Int.max_value else context in
    let records = Queue.create () in
    let truncated = ref false in
    let push record =
      Queue.enqueue records record;
      while Queue.length records > keep do
        ignore (Queue.dequeue_exn records : Edge_record.t);
        truncated := true
      done
    in
    let finish outcome =
      { Run.outcome; transcript = Queue.to_list records; truncated = !truncated }
    in
    let rec advance edge items =
      match items with
      | [] -> finish (Outcome.Passed { edges = edge })
      | item :: rest ->
        if edge >= edge_budget
        then
          finish
            (Outcome.Timed_out { budget = edge_budget; unscheduled = List.length items })
        else (
          let item_sexp = D.Item.sexp_of_t item in
          (* Drive, settle, and sample the pre-edge conditions on both sides. *)
          D.Dut.drive dut item;
          D.Dut.settle dut;
          let dut_pre = D.Dut.pre_edge dut in
          let f_model_pre = D.F_model.pre_edge !f_model item in
          let mismatch phase detail =
            finish (Outcome.Mismatch { edge; phase; item = item_sexp; detail })
          in
          match
            Observation.first_difference
              ~required:D.required_pre_edge
              ~model:f_model_pre
              ~dut:dut_pre
          with
          | Some difference ->
            push
              { Edge_record.edge
              ; item = item_sexp
              ; pre_edge = dut_pre
              ; post_edge = []
              ; items = []
              };
            mismatch Phase.Pre_edge (Detail.Observation difference)
          | None ->
            (* Both sides take the same edge. *)
            D.Dut.edge dut;
            f_model := D.F_model.edge !f_model item;
            let dut_post = D.Dut.post_edge dut in
            let f_model_post = D.F_model.post_edge !f_model in
            let next_dut_monitor, dut_items =
              D.Monitor.observe !dut_monitor ~edge dut_post
            in
            let next_f_model_monitor, f_model_items =
              D.Monitor.observe !f_model_monitor ~edge f_model_post
            in
            dut_monitor := next_dut_monitor;
            f_model_monitor := next_f_model_monitor;
            push
              { Edge_record.edge
              ; item = item_sexp
              ; pre_edge = dut_pre
              ; post_edge = dut_post
              ; items = dut_items
              };
            (match
               Observation.first_difference
                 ~required:D.required_post_edge
                 ~model:f_model_post
                 ~dut:dut_post
             with
             | Some difference -> mismatch Phase.Post_edge (Detail.Observation difference)
             | None ->
               if List.equal Observed_item.equal f_model_items dut_items
               then advance (edge + 1) rest
               else
                 mismatch
                   Phase.Monitor
                   (Detail.Items { expected = f_model_items; actual = dut_items })))
    in
    advance 0 scenario
  ;;

  module Failure = struct
    type t =
      { replay : Replay.t
      ; scenario : Sexp.t list
      ; shrunk : (Sexp.t list * Outcome.t) option
      ; outcome : Outcome.t
      ; context : Edge_record.t list
      ; context_truncated : bool
      ; artifact : string option
      }

    let detail_lines (mismatch : Mismatch.t) =
      match mismatch.detail with
      | Detail.Observation { observation; reason; expected; actual } ->
        let reason = Sexp.to_string (Observation.Reason.sexp_of_t reason) in
        [ [%string "  observation:      %{observation}"]
        ; [%string "  reason:           %{reason}"]
        ; [%string "  expected (model): %{expected#Observation}"]
        ; [%string "  actual (dut):     %{actual#Observation}"]
        ]
      | Detail.Items { expected; actual } ->
        let show label items =
          match items with
          | [] -> [ [%string "  %{label}[]"] ]
          | items ->
            List.map items ~f:(fun item -> [%string "  %{label}%{item#Observed_item}"])
        in
        List.concat
          [ [ "  reason:           reconstructed items differ" ]
          ; show "expected (model): " expected
          ; show "actual (dut):     " actual
          ]
    ;;

    let outcome_lines (outcome : Outcome.t) =
      match outcome with
      | Passed { edges } -> [ [%string "  passed after %{edges#Int} edges"] ]
      | Timed_out { budget; unscheduled } ->
        [ [%string "  timed out: edge budget %{budget#Int} exhausted"]
        ; [%string "  unscheduled items: %{unscheduled#Int}"]
        ]
      | Mismatch mismatch ->
        let phase = Phase.to_string mismatch.phase in
        List.concat
          [ [ [%string "  edge:             %{mismatch.edge#Int}"]
            ; [%string "  phase:            %{phase}"]
            ; [%string "  item at edge:     %{mismatch.item#Sexp}"]
            ]
          ; detail_lines mismatch
          ]
    ;;

    let scenario_lines label scenario =
      let count = List.length scenario in
      [%string "%{label} (%{count#Int} items):"]
      :: List.map scenario ~f:(fun item -> [%string "  %{item#Sexp}"])
    ;;

    let to_lines ?(redact_source = false) t =
      List.concat
        [ [ [%string "%{D.name}: f_model/Hardcaml comparison failed"]; "" ]
        ; [ "reproduction:" ]
        ; Replay.to_lines ~redact_source t.replay
        ; [ "" ]
        ; [ "first mismatch:" ]
        ; outcome_lines t.outcome
        ; [ "" ]
        ; scenario_lines "failing scenario" t.scenario
        ; (match t.shrunk with
           | None -> [ ""; "shrunk scenario:  none smaller reproduced the same failure" ]
           | Some (scenario, outcome) ->
             List.concat
               [ [ "" ]
               ; scenario_lines "shrunk scenario" scenario
               ; [ "shrunk failure:" ]
               ; outcome_lines outcome
               ])
        ; [ "" ]
        ; [ (if t.context_truncated
             then "trace context (nearby edges; earlier edges truncated):"
             else "trace context:")
          ]
        ; List.concat_map t.context ~f:Edge_record.to_lines
        ; (match t.artifact with
           | None -> []
           | Some path -> [ ""; [%string "artifact: %{path}"] ])
        ]
    ;;

    let to_string_hum ?redact_source t =
      String.concat ~sep:"\n" (to_lines ?redact_source t) ^ "\n"
    ;;
  end

  (* A directed scenario, printed edge by edge. The transcript is the DUT's observations
     and the monitor's reconstructed items, followed by the verdict; the model is never
     printed, because a snapshot of the reference would be evidence about the printer
     rather than about the two sides agreeing. *)
  let directed ?(edge_budget = 1024) config ~scenario =
    let result = run ~transcript:true ~edge_budget config ~scenario in
    Run.print result;
    (match result.outcome with
     | Passed { edges } ->
       print_endline [%string "model and design agreed on all %{edges#Int} edges"]
     | outcome ->
       print_endline "FAILED";
       List.iter (Failure.outcome_lines outcome) ~f:print_endline);
    result
  ;;

  (* Search for a failing trial, shrink it, and build the report.

     Trials come from one [Splittable_random.t] seeded by the recorded seed, so trial [n]
     is the same scenario on every machine running the same code. [prerequisite] states
     what a scenario must satisfy to be a valid test of this device; the generator is
     required to produce only valid scenarios, and shrinking is required to preserve them.

     Returns [None] when every trial agreed. The caller decides what a failure means: a
     regression raises it, and the reproduction fixture inspects it.

     [environment_overrides:false] pins a test to its recorded settings. A fixture that
     snapshots one seed's report has to refuse a sweep's seed, or a sweep would fail it
     for reporting exactly what it was asked to report. *)
  let quickcheck
    ~(here : [%call_pos])
    ~test
    ~config
    ~generator
    ?(prerequisite = fun _ -> true)
    ?(edge_budget = 256)
    ?(context = 6)
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
    let run_scenario scenario = run ~context config ~scenario ~edge_budget in
    let rec search trial =
      if trial >= settings.trials
      then None
      else (
        let size = Replay.Settings.size_of_trial settings ~trial in
        let scenario = Base_quickcheck.Generator.generate generator ~size ~random in
        if not (prerequisite scenario)
        then
          raise_s
            [%message
              "generator produced a scenario its own prerequisite rejects"
                (test : string)
                (trial : int)
                (size : int)];
        let result = run_scenario scenario in
        if Outcome.is_failure result.outcome
        then Some (trial, scenario, result)
        else search (trial + 1))
    in
    match search 0 with
    | None -> None
    | Some (trial, scenario, result) ->
      let identity = Outcome.identity result.outcome in
      (* Drop one item at a time. A candidate that breaks the prerequisite, or that fails
         a different check, is not a smaller version of this failure. *)
      let rec shrink budget scenario best =
        if budget <= 0
        then best
        else (
          let candidates =
            List.init (List.length scenario) ~f:(fun skip ->
              List.filteri scenario ~f:(fun index _ -> index <> skip))
          in
          match
            List.find_map candidates ~f:(fun candidate ->
              if not (prerequisite candidate)
              then None
              else (
                let result = run_scenario candidate in
                if Option.equal String.equal (Outcome.identity result.outcome) identity
                then Some (candidate, result)
                else None))
          with
          | None -> best
          | Some (candidate, result) ->
            shrink (budget - 1) candidate (Some (candidate, result)))
      in
      let shrunk = shrink shrink_steps scenario None in
      let replay =
        Replay.create
          ~test
          ~source_file:here.pos_fname
          ~settings
          ~trial:(Some trial)
          ~config:(D.Config.sexp_of_t config)
      in
      let failure =
        { Failure.replay
        ; scenario = List.map scenario ~f:D.Item.sexp_of_t
        ; shrunk =
            Option.map shrunk ~f:(fun (scenario, result) ->
              List.map scenario ~f:D.Item.sexp_of_t, result.outcome)
        ; outcome = result.outcome
        ; context = result.transcript
        ; context_truncated = result.truncated
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
            ~contents:(Failure.to_string_hum failure)
        else None
      in
      Some { failure with artifact }
  ;;

  (* The regression form: agree, or die with the whole report. *)
  let require_agreement
    ~(here : [%call_pos])
    ~test
    ~config
    ~generator
    ?prerequisite
    ?edge_budget
    ?context
    ?shrink_steps
    ~settings
    ()
    =
    match
      quickcheck
        ~here
        ~test
        ~config
        ~generator
        ?prerequisite
        ?edge_budget
        ?context
        ?shrink_steps
        ~settings
        ()
    with
    | None -> ()
    | Some failure -> failwith (Failure.to_string_hum failure)
  ;;
end
