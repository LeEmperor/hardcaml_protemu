(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "serial_phy_testbench.ml" *)
(* HL4c focused Cyclesim testbench for [Serial_phy].

   The PHY is driven only through its public ports, and every observation is a public
   output. The tests write their expected cycles by hand from the timing contract in
   docs/host_link_hl4b1_record.md. No expectation is derived from the RTL or from the
   loader harness.

   Scheduling contract:

   1. Time. The unit is one system clock cycle. Cycle n is the interval before edge n. A
      pin, reset, or enable value set before [cycle] runs cycle n is applied for the whole
      of cycle n and sampled at edge n. [cycle] is the only function that advances the
      simulator.
   2. Within a cycle: apply the inputs; settle; take the pre-edge sample (the observation
      for cycle n); clock the edge; take the post-edge sample.
   3. The post-edge sample of edge n is taken with cycle n's inputs still applied. The
      pre-edge sample of cycle n+1 is taken after its new inputs settle. The two must be
      equal, which checks every cycle that no output depends combinationally on a pin,
      reset, or enable.
   4. Every wait has a finite cycle budget. An exhausted budget or a failed check raises
      [Phy_failure] with the scenario, cycle, sampling phase, what was checked, the
      expected and actual values, and the inputs and outputs of recent cycles.

   This is synchronous digital evidence. Every pin change happens at a cycle boundary, so
   it establishes nothing about asynchronous phase, metastability, physical setup/hold, or
   board timing.
*)

open! Core
open! Hardcaml
open! Hardcaml_protemu
module Sim = Cyclesim.With_interface (Serial_phy.I) (Serial_phy.O)

(* The PHY's public outputs, by name. *)
module Output = struct
  type t =
    | Selected
    | Data
    | Select_assert
    | Select_release
    | Clock_rise
    | Clock_fall
    | Deselect_qualified
  [@@deriving sexp_of, compare, equal, enumerate]

  let get t (o : bool Serial_phy.O.t) =
    match t with
    | Selected -> o.selected_o
    | Data -> o.data_o
    | Select_assert -> o.select_assert_o
    | Select_release -> o.select_release_o
    | Clock_rise -> o.clock_rise_o
    | Clock_fall -> o.clock_fall_o
    | Deselect_qualified -> o.deselect_qualified_o
  ;;

  (* The outputs that are high, for transcripts. *)
  let high (o : bool Serial_phy.O.t) = List.filter all ~f:(fun t -> get t o)
end

(* The inputs applied for one cycle. [select_n] is the LSEL_N pin level. *)
module Inputs = struct
  type t =
    { reset : bool
    ; enable : bool
    ; select_n : bool
    ; clock : bool
    ; data : bool
    }
  [@@deriving sexp_of, equal]

  let idle =
    { reset = false; enable = true; select_n = true; clock = false; data = false }
  ;;

  let summary t =
    let bit b = if b then 1 else 0 in
    sprintf
      "rst=%d en=%d LSEL_N=%d LCLK=%d LDI=%d"
      (bit t.reset)
      (bit t.enable)
      (bit t.select_n)
      (bit t.clock)
      (bit t.data)
  ;;
end

module Phase = struct
  type t =
    | Pre_edge (* the observation of a cycle, before its edge *)
    | Post_edge (* after an edge, with that cycle's inputs still applied *)
    | Post_run (* a check made by the test between cycles *)
  [@@deriving sexp_of]
end

type t =
  { scenario : string
  ; sim : Sim.t
  ; mutable inputs : Inputs.t (* applied to the next cycle *)
  ; mutable cycle : int (* the next cycle to run *)
  ; mutable settled : bool Serial_phy.O.t option (* post-edge sample of the last edge *)
  ; applied : Inputs.t Queue.t (* index = cycle *)
  ; observed : bool Serial_phy.O.t Queue.t (* pre-edge samples; index = cycle *)
  ; transcript_cycles : int
  }

exception
  Phy_failure of
    { scenario : string
    ; cycle : int
    ; phase : Phase.t
    ; what : string
    ; expected : Sexp.t option
    ; actual : Sexp.t option
    ; transcript : Sexp.t
    }
[@@deriving sexp_of]

(* The inputs and high outputs of the last [transcript_cycles] cycles run. *)
let transcript t =
  let first = Int.max 0 (t.cycle - t.transcript_cycles) in
  List.range first t.cycle
  |> List.map ~f:(fun cycle ->
    let inputs = Queue.get t.applied cycle in
    let high = Output.high (Queue.get t.observed cycle) in
    [%sexp (cycle : int), (Inputs.summary inputs : string), (high : Output.t list)])
  |> Sexp.List
;;

let fail t ?(cycle = t.cycle - 1) ?expected ?actual ~phase what =
  raise
    (Phy_failure
       { scenario = t.scenario
       ; cycle
       ; phase
       ; what
       ; expected
       ; actual
       ; transcript = transcript t
       })
;;

let check t ?cycle ~phase what sexp_of equal ~expected actual =
  if not (equal expected actual)
  then fail t ?cycle ~phase what ~expected:(sexp_of expected) ~actual:(sexp_of actual)
;;

let sample (o : Bits.t ref Serial_phy.O.t) =
  Serial_phy.O.map o ~f:(fun r -> Bits.to_bool !r)
;;

(* The single owner of simulator advancement; see items 2 and 3 of the contract. *)
let cycle t =
  let i = Cyclesim.inputs t.sim in
  let before = Cyclesim.outputs ~clock_edge:Before t.sim in
  let after = Cyclesim.outputs ~clock_edge:After t.sim in
  let set port value = port := Bits.of_bool value in
  set i.reset_i t.inputs.reset;
  set i.enable_i t.inputs.enable;
  set i.serial_select_n_i t.inputs.select_n;
  set i.serial_clock_i t.inputs.clock;
  set i.serial_data_i t.inputs.data;
  Cyclesim.cycle_check t.sim;
  Cyclesim.cycle_before_clock_edge t.sim;
  let observed = sample before in
  Queue.enqueue t.applied t.inputs;
  Queue.enqueue t.observed observed;
  Option.iter t.settled ~f:(fun settled ->
    check
      t
      ~cycle:t.cycle
      ~phase:Pre_edge
      "outputs after the new inputs settle equal the last edge's post-edge outputs"
      [%sexp_of: bool Serial_phy.O.t]
      [%equal: bool Serial_phy.O.t]
      ~expected:settled
      observed);
  Cyclesim.cycle_at_clock_edge t.sim;
  Cyclesim.cycle_after_clock_edge t.sim;
  t.settled <- Some (sample after);
  t.cycle <- t.cycle + 1
;;

let run t cycles =
  for _ = 1 to cycles do
    cycle t
  done
;;

(* Set inputs for the next cycle onward; unnamed inputs keep their value. [select] is the
   protocol level: [true] drives LSEL_N low.
*)
let set ?reset ?enable ?select ?clock ?data t =
  let keep value current = Option.value value ~default:current in
  t.inputs
  <- { reset = keep reset t.inputs.reset
     ; enable = keep enable t.inputs.enable
     ; select_n = Option.value_map select ~default:t.inputs.select_n ~f:not
     ; clock = keep clock t.inputs.clock
     ; data = keep data t.inputs.data
     }
;;

(* Pins idle, enable high, reset high in cycles 0 and 1. The first cycle out of reset is
   cycle 2, which [create] returns before running. The PHY is then deselected and not yet
   qualified.
*)
let reset_cycles = 2

let create ?(transcript_cycles = 16) scenario =
  let sim = Sim.create (Serial_phy.create (Scope.create ~flatten_design:true ())) in
  let t =
    { scenario
    ; sim
    ; inputs = { Inputs.idle with reset = true }
    ; cycle = 0
    ; settled = None
    ; applied = Queue.create ()
    ; observed = Queue.create ()
    ; transcript_cycles
    }
  in
  run t reset_cycles;
  set t ~reset:false;
  t
;;

(* The pre-edge observation of a cycle that has run. *)
let observed t cycle =
  if cycle < 0 || cycle >= t.cycle
  then
    fail
      t
      ~phase:Post_run
      "observation of a cycle that has run"
      ~actual:[%sexp { requested = (cycle : int); cycles_run = (t.cycle : int) }];
  Queue.get t.observed cycle
;;

(* Cycles in [from, until) in which [output] was high. *)
let high_cycles t output ~from ~until =
  List.range from until
  |> List.filter ~f:(fun cycle -> Output.get output (observed t cycle))
;;

(* The exact set of cycles in [from, until) in which [output] was high. This also checks
   one-cycle duration and the absence of repeats.
*)
let expect_high_cycles t output ~from ~until what expected =
  check
    t
    ~phase:Post_run
    (sprintf
       "%s: %s high in cycles [%d, %d)"
       what
       (Sexp.to_string [%sexp (output : Output.t)])
       from
       until)
    [%sexp_of: int list]
    [%equal: int list]
    ~expected
    (high_cycles t output ~from ~until)
;;

let expect_output t output ~cycle what expected =
  check
    t
    ~cycle
    ~phase:Pre_edge
    (sprintf "%s: %s" what (Sexp.to_string [%sexp (output : Output.t)]))
    [%sexp_of: bool]
    [%equal: bool]
    ~expected
    (Output.get output (observed t cycle))
;;

(* Run until [output] is [value] in a cycle's pre-edge observation and return that cycle.
   Raises after [budget] cycles.
*)
let wait_for ?(budget = 100) t output ~value what =
  let rec loop spent =
    if spent >= budget
    then
      fail
        t
        ~phase:Pre_edge
        (sprintf "%s: wait for %s" what (Sexp.to_string [%sexp (output : Output.t)]))
        ~expected:[%sexp (value : bool)]
        ~actual:[%sexp { budget_exhausted = (budget : int) }]
    else (
      cycle t;
      let seen = t.cycle - 1 in
      if Bool.equal (Output.get output (observed t seen)) value
      then seen
      else loop (spent + 1))
  in
  loop 0
;;

(* Drive [select] from the next cycle and run [hold] cycles. Returns the cycle in which
   the pin first has the new level.
*)
let drive_select t ~select ~hold =
  let driven = t.cycle in
  set t ~select;
  run t hold;
  driven
;;

(* [Some failure] when [f] raises [Phy_failure]. Used by the negative checks. *)
let failure_of f =
  match f () with
  | (_ : unit) -> None
  | exception (Phy_failure _ as failure) -> Some [%sexp (failure : exn)]
;;

(* Hand-specified timing from the P3.5 record and the HL4b1 contract. They are written
   here, not read from [Serial_phy], so that a changed constant there fails these tests.

   [latency] : a pin level driven in cycle n is the synchronized level from cycle n+2, and
   a change is an event in exactly cycle n+2 (two-stage synchronizer); [threshold] : a
   cycle is qualified when the synchronized selection was low, with enable high and reset
   low, in each of the previous four cycles.
*)
let latency = 2
let threshold = 4
