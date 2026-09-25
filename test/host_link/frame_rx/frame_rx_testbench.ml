(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "frame_rx_testbench.ml" *)
(* HL4c focused Cyclesim testbench for [Frame_rx].

   The receiver is driven only through its public ports, with explicit PHY-level
   observations: the synchronized selection and data levels and the one-cycle
   select-assert, select-release, and clock-rise events that [Serial_phy] produces. The
   PHY's synchronizers are not part of this boundary. Every observation is a public
   output. Expected results, fields, and cycles are written by hand in the tests from the
   P3.5 record and docs/host_link_hl4b2_record.md; none is computed from the receiver.
   [Wire.Request.encode] and [Wire.Crc.compute] build stimulus only.

   Scheduling contract:

   1. Time. The unit is one system clock cycle. Cycle n is the interval before edge n.
      Inputs set before [cycle] runs cycle n are applied for the whole of cycle n and
      sampled at edge n. [cycle] is the only function that advances the simulator.
   2. Levels ([reset], [enable], [eligible], [selected], [data]) keep their value until a
      test changes them. Events ([select_assert], [select_release], [clock_rise]) last one
      cycle: [cycle] clears them after the edge.
   3. Within a cycle: apply the inputs; settle; take the pre-edge sample (the observation
      for cycle n); clock the edge; take the post-edge sample.
   4. Every output except [frame_end_o] is a function of the receiver's registers. For
      those, the post-edge sample of edge n (taken with cycle n's inputs) must equal the
      pre-edge sample of cycle n+1 (taken after its new inputs settle), and [cycle] checks
      this every cycle. [frame_end_o] is combinational in [select_release_i] by design:
      the handoff has no register.
   5. Every wait has a finite cycle budget. An exhausted budget or a failed check raises
      [Rx_failure] with the scenario, cycle, sampling phase, what was checked, the
      expected and actual values, and the inputs and outputs of recent cycles.

   PHY-coherent stimulus (the default drivers) follows what [Serial_phy] can present: an
   assert event with the selected level rising, a release event with it falling, and clock
   rises at least two cycles apart. Probes outside that, or outside the P3.5 host
   envelope, are labelled as robustness probes in the tests. Everything here is
   synchronous digital evidence about this block's boundary.
*)

open! Core
open! Hardcaml
open! Hardcaml_protemu
module Wire = Protemu_host_link_wire.Wire
module Sim = Cyclesim.With_interface (Frame_rx.I) (Frame_rx.O)

(* The inputs applied for one cycle. *)
module Inputs = struct
  type t =
    { reset : bool
    ; enable : bool
    ; eligible : bool
    ; selected : bool
    ; data : bool
    ; select_assert : bool
    ; select_release : bool
    ; clock_rise : bool
    }
  [@@deriving sexp_of, equal]

  let idle =
    { reset = false
    ; enable = true
    ; eligible = true
    ; selected = false
    ; data = false
    ; select_assert = false
    ; select_release = false
    ; clock_rise = false
    }
  ;;

  let clear_events t =
    { t with select_assert = false; select_release = false; clock_rise = false }
  ;;

  let summary t =
    let bit b = if b then 1 else 0 in
    let events =
      List.filter_map
        [ t.select_assert, "assert"; t.select_release, "release"; t.clock_rise, "rise" ]
        ~f:(fun (on, name) -> Option.some_if on name)
    in
    sprintf
      "rst=%d en=%d elig=%d sel=%d data=%d%s"
      (bit t.reset)
      (bit t.enable)
      (bit t.eligible)
      (bit t.selected)
      (bit t.data)
      (if List.is_empty events then "" else " " ^ String.concat ~sep:"," events)
  ;;
end

(* One sample of every output. *)
module Sample = struct
  type t =
    { active : bool
    ; frame_end : bool
    ; result : int
    ; echo_valid : bool
    ; tag : int
    ; command : int
    ; payload_length : int
    ; payload : int
    }
  [@@deriving sexp_of, equal]

  let of_outputs (o : Bits.t ref Frame_rx.O.t) =
    let bool r = Bits.to_bool !r in
    let int r = Bits.to_int_trunc !r in
    { active = bool o.active_o
    ; frame_end = bool o.frame_end_o
    ; result = int o.result_o
    ; echo_valid = bool o.echo_valid_o
    ; tag = int o.tag_o
    ; command = int o.command_o
    ; payload_length = int o.payload_length_o
    ; payload = int o.payload_o
    }
  ;;

  (* The outputs that depend only on registers; see item 4 of the contract. *)
  let registered t = { t with frame_end = false }

  let summary t =
    sprintf
      "%s%sresult=%02x echo=%d tag=%02x command=%02x length=%04x payload=%08x"
      (if t.active then "active " else "")
      (if t.frame_end then "FRAME_END " else "")
      t.result
      (if t.echo_valid then 1 else 0)
      t.tag
      t.command
      t.payload_length
      t.payload
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
  ; mutable settled : Sample.t option (* post-edge sample of the last edge *)
  ; applied : Inputs.t Queue.t (* index = cycle *)
  ; observed : Sample.t Queue.t (* pre-edge samples; index = cycle *)
  ; transcript_cycles : int
  }

exception
  Rx_failure of
    { scenario : string
    ; cycle : int
    ; phase : Phase.t
    ; what : string
    ; expected : Sexp.t option
    ; actual : Sexp.t option
    ; transcript : Sexp.t
    }
[@@deriving sexp_of]

(* The inputs and outputs of the last [transcript_cycles] cycles run. *)
let transcript t =
  let first = Int.max 0 (t.cycle - t.transcript_cycles) in
  List.range first t.cycle
  |> List.map ~f:(fun cycle ->
    [%sexp
      (cycle : int)
      , (Inputs.summary (Queue.get t.applied cycle) : string)
      , (Sample.summary (Queue.get t.observed cycle) : string)])
  |> Sexp.List
;;

let fail t ?(cycle = t.cycle - 1) ?expected ?actual ~phase what =
  raise
    (Rx_failure
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

(* The single owner of simulator advancement; see items 2 to 4 of the contract. *)
let cycle t =
  let i = Cyclesim.inputs t.sim in
  let before = Cyclesim.outputs ~clock_edge:Before t.sim in
  let after = Cyclesim.outputs ~clock_edge:After t.sim in
  let set port value = port := Bits.of_bool value in
  let inputs = t.inputs in
  set i.reset_i inputs.reset;
  set i.enable_i inputs.enable;
  set i.eligible_i inputs.eligible;
  set i.selected_i inputs.selected;
  set i.data_i inputs.data;
  set i.select_assert_i inputs.select_assert;
  set i.select_release_i inputs.select_release;
  set i.clock_rise_i inputs.clock_rise;
  Cyclesim.cycle_check t.sim;
  Cyclesim.cycle_before_clock_edge t.sim;
  let observed = Sample.of_outputs before in
  Queue.enqueue t.applied inputs;
  Queue.enqueue t.observed observed;
  Option.iter t.settled ~f:(fun settled ->
    check
      t
      ~cycle:t.cycle
      ~phase:Pre_edge
      "registered outputs after the new inputs settle equal the last edge's post-edge \
       outputs"
      [%sexp_of: Sample.t]
      [%equal: Sample.t]
      ~expected:(Sample.registered settled)
      (Sample.registered observed));
  Cyclesim.cycle_at_clock_edge t.sim;
  Cyclesim.cycle_after_clock_edge t.sim;
  t.settled <- Some (Sample.of_outputs after);
  t.inputs <- Inputs.clear_events inputs;
  t.cycle <- t.cycle + 1
;;

let run t cycles =
  for _ = 1 to cycles do
    cycle t
  done
;;

(* Set levels for the next cycle onward; unnamed levels keep their value. *)
let set ?reset ?enable ?eligible ?selected ?data t =
  let keep value current = Option.value value ~default:current in
  t.inputs
  <- { t.inputs with
       reset = keep reset t.inputs.reset
     ; enable = keep enable t.inputs.enable
     ; eligible = keep eligible t.inputs.eligible
     ; selected = keep selected t.inputs.selected
     ; data = keep data t.inputs.data
     }
;;

(* Raise events for the next cycle only. *)
let pulse ?(select_assert = false) ?(select_release = false) ?(clock_rise = false) t =
  t.inputs
  <- { t.inputs with
       select_assert = t.inputs.select_assert || select_assert
     ; select_release = t.inputs.select_release || select_release
     ; clock_rise = t.inputs.clock_rise || clock_rise
     }
;;

(* Reset is high in cycles 0 and 1, with everything else idle and eligible. [create]
   returns before running cycle 2, the first cycle out of reset.
*)
let reset_cycles = 2

let create ?(transcript_cycles = 12) scenario =
  let sim = Sim.create (Frame_rx.create (Scope.create ~flatten_design:true ())) in
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

(* PHY-coherent drivers. Each runs whole cycles and returns the cycle of its event. *)

(* An assert event with the selected level rising in the same cycle. *)
let select t =
  let at = t.cycle in
  set t ~selected:true;
  pulse t ~select_assert:true;
  cycle t;
  at
;;

(* A release event with the selected level falling in the same cycle. *)
let deselect t =
  let at = t.cycle in
  set t ~selected:false;
  pulse t ~select_release:true;
  cycle t;
  at
;;

(* One bit: a clock-rise cycle carrying [value] on the data level, then [period] - 1
   cycles carrying its complement. Only the rise cycle's sample can produce [value], which
   pins the sampling cycle. [Serial_phy] cannot present rises less than two cycles apart.
*)
let default_period = 8

let send_bit ?(period = default_period) t value =
  set t ~data:value;
  pulse t ~clock_rise:true;
  cycle t;
  set t ~data:(not value);
  run t (period - 1)
;;

(* Wire order: most significant bit first. *)
let bits_of_byte byte = List.init 8 ~f:(fun index -> (byte lsr (7 - index)) land 1 = 1)

let bits_of_string bytes =
  List.concat_map (String.to_list bytes) ~f:(fun c -> bits_of_byte (Char.to_int c))
;;

let send_bits ?period t bits = List.iter bits ~f:(send_bit ?period t)
let send ?period t bytes = send_bits ?period t (bits_of_string bytes)

(* The event cycles of one complete selection. *)
module Selection = struct
  type t =
    { asserted : int
    ; released : int
    }
  [@@deriving sexp_of]
end

(* Select, wait [lead] cycles, send [bytes] and then [extra_bits], wait [trail] cycles,
   and deselect. The defaults are close to the P3.5 four-cycle host envelope.
*)
let request ?(lead = 4) ?(trail = 8) ?period ?(extra_bits = []) t bytes =
  let asserted = select t in
  run t (lead - 1);
  send ?period t bytes;
  send_bits ?period t extra_bits;
  run t trail;
  let released = deselect t in
  { Selection.asserted; released }
;;

(* A legal request's bytes; the encoder refuses nothing the tests pass it. *)
let encode ~tag request =
  Wire.Request.encode ~tag request |> Result.ok |> Option.value_exn
;;

(* Test-local frames the codec cannot build. *)
module Raw = struct
  let crc body = String.of_char (Char.of_int_exn (Wire.Crc.compute body))
  let bytes list = String.of_char_list (List.map list ~f:Char.of_int_exn)

  (* Header and payload with the declared length defaulting to the payload's. *)
  let body ?(magic = 0xa5) ?(version = 0x10) ?payload_length ~tag ~command payload =
    let payload_length = Option.value payload_length ~default:(List.length payload) in
    bytes
      ([ magic; version; tag; command; payload_length land 0xff; payload_length lsr 8 ]
       @ payload)
  ;;

  (* Header, payload, and a correct CRC for them. *)
  let frame ?magic ?version ?payload_length ~tag ~command payload =
    let body = body ?magic ?version ?payload_length ~tag ~command payload in
    body ^ crc body
  ;;

  let flip_last frame ~mask =
    let last = String.length frame - 1 in
    String.prefix frame last
    ^ String.of_char (Char.of_int_exn (Char.to_int frame.[last] lxor mask))
  ;;

  let zeros count = String.make count '\x00'
end

(* What the receiver presents at a handoff. [result] is a [Wire.Result_code]. *)
module Expected = struct
  type t =
    { result : Wire.Result_code.t
    ; echo_valid : bool
    ; tag : int
    ; command : int
    ; payload_length : int
    ; payload : int
    }
  [@@deriving sexp_of, equal]

  let of_sample (s : Sample.t) =
    match Wire.Result_code.of_int s.result with
    | None -> None
    | Some result ->
      Some
        { result
        ; echo_valid = s.echo_valid
        ; tag = s.tag
        ; command = s.command
        ; payload_length = s.payload_length
        ; payload = s.payload
        }
  ;;

  (* A result with everything else zero: the state after a start, a disable, or a reset
     with no byte received since.
  *)
  let empty result =
    { result; echo_valid = false; tag = 0; command = 0; payload_length = 0; payload = 0 }
  ;;
end

(* The presented validation and fields in a cycle that has run. *)
let expect_fields t ~cycle what (expected : Expected.t) =
  check
    t
    ~cycle
    ~phase:Pre_edge
    (what ^ ": result, echo, and retained fields")
    [%sexp_of: Expected.t option]
    [%equal: Expected.t option]
    ~expected:(Some expected)
    (Expected.of_sample (observed t cycle))
;;

(* Cycles in [from, until) in which a sampled flag was high. *)
let high_cycles t ~from ~until ~f =
  List.range from until |> List.filter ~f:(fun cycle -> f (observed t cycle))
;;

let expect_cycles t ~from ~until what ~f expected =
  check
    t
    ~phase:Post_run
    (sprintf "%s: high in cycles [%d, %d)" what from until)
    [%sexp_of: int list]
    [%equal: int list]
    ~expected
    (high_cycles t ~from ~until ~f)
;;

let expect_frame_end_cycles t ~from what expected =
  expect_cycles
    t
    ~from
    ~until:t.cycle
    (what ^ ": frame_end_o")
    ~f:(fun s -> s.frame_end)
    expected
;;

let expect_active_cycles t ~from what expected =
  expect_cycles
    t
    ~from
    ~until:t.cycle
    (what ^ ": active_o")
    ~f:(fun s -> s.active)
    expected
;;

(* The retained fields and validation are the same in every cycle of [from, until). *)
let expect_stable t ~from ~until what =
  let first = observed t from in
  List.range from until
  |> List.iter ~f:(fun cycle ->
    check
      t
      ~cycle
      ~phase:Pre_edge
      (sprintf "%s: registered outputs unchanged since cycle %d" what from)
      [%sexp_of: Sample.t]
      [%equal: Sample.t]
      ~expected:(Sample.registered first)
      (Sample.registered (observed t cycle)))
;;

(* One complete selection that must hand off exactly once, in its release cycle, with
   [expected]. The request is active from the cycle after the assert through the release
   cycle, and inactive from the cycle after. Runs one cycle past the release.
*)
let expect_handoff ?lead ?trail ?period ?extra_bits t what bytes (expected : Expected.t) =
  let from = t.cycle in
  let { Selection.asserted; released } =
    request ?lead ?trail ?period ?extra_bits t bytes
  in
  run t 1;
  expect_frame_end_cycles t ~from what [ released ];
  expect_active_cycles t ~from what (List.range (asserted + 1) (released + 1));
  expect_fields t ~cycle:released what expected;
  (* The handoff is presented again, unchanged, after the edge. *)
  expect_fields t ~cycle:(released + 1) (what ^ " after the release edge") expected
;;

(* Run until [f] holds for a cycle's pre-edge sample and return that cycle. Raises after
   [budget] cycles.
*)
let wait_for ?(budget = 100) t what ~f =
  let rec loop spent =
    if spent >= budget
    then
      fail
        t
        ~phase:Pre_edge
        ("wait for " ^ what)
        ~actual:[%sexp { budget_exhausted = (budget : int) }]
    else (
      cycle t;
      let seen = t.cycle - 1 in
      if f (observed t seen) then seen else loop (spent + 1))
  in
  loop 0
;;

(* [Some failure] when [f] raises [Rx_failure]. Used by the negative checks. *)
let failure_of f =
  match f () with
  | (_ : unit) -> None
  | exception (Rx_failure _ as failure) -> Some [%sexp (failure : exn)]
;;
