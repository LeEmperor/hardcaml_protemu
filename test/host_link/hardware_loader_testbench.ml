(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "hardware_loader_testbench.ml" *)
(* HL4a serial Cyclesim harness for the composed [Host_link].

   The real loader is driven only through its three serial pins. Legal requests are built
   with [Wire.Request.encode] and responses are read with
   [Wire.Response.decode_correlated]; malformed frames come from [Raw], which is local to
   this suite. A test-only core stub answers the loader's [Control_port] request and
   supplies its decision and status. The suite is the cycle-observed baseline that the
   HL4b extractions must reproduce. The contract below is also recorded in
   docs/host_link_hl4a_record.md.

   This is synchronous digital evidence. Every pin change happens at a cycle boundary, so
   the suite establishes nothing about asynchronous phase, metastability, board timing, or
   physical setup/hold margins. The independent emitted-RTL peer
   tinytapeout/test/p3_loader_tb.v and physical evidence own those. The stub's offer and
   side-effect records are evidence about loader dispatch only, never about RAM writes,
   core cleanup, or pins.

   Scheduling contract:

   1. Time. The unit is one system clock cycle. Cycle n is the interval before edge n. A
      reset, enable, pin, or status value set for cycle n is applied before that cycle's
      settle and sampled at edge n. [cycle] is the only function that advances the
      simulator. Host steps call it in sequence, and the stub runs inside it; neither
      advances time on its own.
   2. Within a cycle: apply reset/enable, the serial pins, the stub's status, and the
      stub's registered READBACK response; settle; read the offered request; apply the
      stub's combinational decision; settle again and check that the request did not
      change; take the pre-edge observation (LRDY, LDO, busy, offer); clock the edge; then
      do the stub's post-edge work (accepted side effects, completions, cancellation).
   3. Host pins follow the P3.5 envelope in whole cycles (see [Timing]). The host samples
      LDO in the cycle in which it raises LCLK, before that cycle's edge. This matches the
      peer's sample 1 ps after its rise.
   4. A response is read as 7 header bytes, then the length they declare, up to the final
      bit. The host samples that bit on its rise and validates the frame while LCLK stays
      high. Commit then supplies the final fall, waits [select_trail] and raises LSEL_N.
      Replay raises LSEL_N with LCLK high, and lowers LCLK [clock_high] cycles later.
   5. Every wait has a finite cycle budget. An exhausted budget or a failed check raises
      with the scenario, cycle, sampling phase, what was checked, the expected and actual
      values, and a bounded transcript of recent public-boundary events.
*)

open! Core
open! Hardcaml
open! Hardcaml_protemu
module Wire = Protemu_host_link_wire.Wire
module Sim = Cyclesim.With_interface (Host_link.I) (Host_link.O)

let hex bytes =
  String.to_list bytes
  |> List.map ~f:(fun byte -> sprintf "%02x" (Char.to_int byte))
  |> String.concat ~sep:" "
;;

(* Host serial timing in system cycles. P3.5 requires at least four of each. *)
module Timing = struct
  type t =
    { clock_low : int (* LCLK low; LDI setup before the rise *)
    ; clock_high : int (* LCLK high; LDI hold after the rise *)
    ; select_lead : int (* LSEL_N low before the first rise *)
    ; select_trail : int (* last fall before LSEL_N high *)
    ; deselect_gap : int (* LSEL_N high between frames *)
    }
  [@@deriving sexp_of]

  let minimum = 4

  let envelope =
    { clock_low = 4; clock_high = 4; select_lead = 4; select_trail = 4; deselect_gap = 4 }
  ;;

  let validate t =
    List.iter
      [ "clock_low", t.clock_low
      ; "clock_high", t.clock_high
      ; "select_lead", t.select_lead
      ; "select_trail", t.select_trail
      ; "deselect_gap", t.deselect_gap
      ]
      ~f:(fun (field, cycles) ->
        if cycles < minimum
        then
          raise_s
            [%message
              "host timing is outside the P3.5 envelope"
                (field : string)
                (cycles : int)
                (minimum : int)])
  ;;
end

(* Latencies of the unsplit loader, in cycles, fixed here as the HL4b baseline. P3.5
   bounds only the host envelope; these values are the current cycle behavior, each
   explained from the loader's structure or the [Control_port] contract. Cycle n is the
   cycle in which the host drives the pin change.
*)
module Latency = struct
  (* LSEL_N high in cycle n passes the two-stage synchronizer (edges n and n+1), is seen
     as a release in cycle n+2, arms dispatch at edge n+2, and is offered in cycle n+3.
  *)
  let offer_after_deselect = 3

  (* An immediate response is stored at the offer's edge, so LRDY is high from the next
     cycle. Dispatch-stage errors (unknown command, wrong fixed length, device bounds) use
     the same cycle but offer nothing.
  *)
  let ready_after_offer = 1

  (* A frame that fails deselect validation (overrun, incomplete, magic, version,
     oversized length, CRC) stores its error at the release edge n+2, so LRDY is high from
     n+3: one cycle before a valid frame would be offered.
  *)
  let validation_error_ready = 3

  (* Contract item 5: an offer accepted at edge E has its response valid in the cycle
     between E+1 and E+2.
  *)
  let readback_after_offer = 2

  (* The loader stores a READ or ABORT response at the edge of the cycle in which the
     completion is visible.
  *)
  let ready_after_completion = 1

  (* Contract item 6: cleanup is visible in the first cycle after the accepting edge. *)
  let abort_clean_after_offer = 1

  (* After a synchronized final fall, LSEL_N high in cycle n is seen as a release in cycle
     n+2, which clears LRDY from cycle n+3.
  *)
  let ready_cleared_after_deselect = 3

  (* LSEL_N low in cycle n is seen as a selection in cycle n+2. It arms a response read
     only if LRDY is high and four deselected cycles have been counted in that cycle.
  *)
  let response_select_to_armed = 2
end

(* A decoded [Control_port.Request] offer. READ carries no expected word: that operand is
   meaningful only with [readback_verify].
*)
module Request = struct
  type t =
    | Load_start of { length : int }
    | Load_write of
        { address : int
        ; data : int
        }
    | Load_complete
    | Read of { address : int }
    | Verify of
        { address : int
        ; expected : int
        }
    | Run
    | Stop
    | Abort
  [@@deriving sexp_of, compare, equal]

  let of_port (r : Bits.t Control_port.Request.t) =
    let valid signal = Bits.to_bool signal in
    let value signal = Bits.to_int_trunc signal in
    List.filter_opt
      [ Option.some_if
          (valid r.load_start_valid)
          (Load_start { length = value r.load_length })
      ; Option.some_if
          (valid r.load_write_valid)
          (Load_write { address = value r.load_address; data = value r.load_data })
      ; Option.some_if (valid r.load_complete_valid) Load_complete
      ; Option.some_if
          (valid r.readback_valid)
          (if valid r.readback_verify
           then
             Verify
               { address = value r.readback_address
               ; expected = value r.readback_expected
               }
           else Read { address = value r.readback_address })
      ; Option.some_if (valid r.run_valid) Run
      ; Option.some_if (valid r.stop_valid) Stop
      ; Option.some_if (valid r.abort_valid) Abort
      ]
  ;;
end

(* Core status as plain integers, one per [Control_port.Status] field. *)
module Status = struct
  type t = int Control_port.Status.t

  let halted_idle : t =
    { halted = 1
    ; engines_idle = 1
    ; image_valid = 0
    ; load_active = 0
    ; image_length = 0
    ; words_written = 0
    ; words_verified = 0
    ; verification_failed = 0
    ; fetch_fault = 0
    ; execution_active = 0
    ; normal_halt = 0
    ; execution_fault = 0
    ; fault_kind = 0
    ; pc = 0
    ; phase = 0
    ; pin_oe = 0
    ; software_claim = 0
    ; engine_claim = 0
    }
  ;;

  (* Executing with one engine driving and claiming pin 1. *)
  let running : t =
    { halted_idle with
      halted = 0
    ; engines_idle = 0
    ; image_valid = 1
    ; execution_active = 1
    ; phase = 5
    ; pin_oe = 0x02
    ; engine_claim = 0x02
    }
  ;;

  (* Contract item 6: halted, engines idle, and no output enable or claim. The stub also
     clears [execution_active] and reports the halted phase.
  *)
  let cleaned (t : t) : t =
    { t with
      halted = 1
    ; engines_idle = 1
    ; execution_active = 0
    ; phase = 0
    ; pin_oe = 0
    ; software_claim = 0
    ; engine_claim = 0
    }
  ;;

  (* Nonzero fields only, for the transcript. *)
  let summary (t : t) =
    Control_port.Status.(map2 port_names t ~f:(fun name value -> name, value) |> to_list)
    |> List.filter ~f:(fun (_, value) -> value <> 0)
  ;;
end

(* Test-only stand-in for [Emulator_core] behind the [Control_port]. It is not a RAM or
   execution model: acceptance comes from [accept], READBACK data from [memory], and
   status from [status], all set by the test. It never inspects the loader's refusal or
   dispatch logic.

   Contract-faithful behavior, from control_port.ml:

   - decisions are combinational in the offer cycle; with no offer both are low, and a
     refusal is [valid & ~accepted];
   - reset or disable refuses every offer and cancels a pending READBACK response;
   - an accepted READBACK has its response valid only in the cycle
     [Latency.readback_after_offer] after the offer (item 5); a second READBACK is refused
     while it is outstanding; an accepted ABORT or LOAD_START cancels it;
   - an accepted ABORT makes [Status.cleaned] visible from the cycle after its edge (item
     6);
   - [readback_response_match] compares the word with the expected operand for VERIFY and
     is driven low for READ, where it is meaningless and the loader must ignore it.

   [Completion.Delayed] and [Never] are robustness probes of the loader's waits, not
   behavior of the current [Emulator_core]; tests using them say so. So is
   [inject_readback_response], which raises an unsolicited response pulse.
*)
module Core_stub = struct
  module Completion = struct
    type t =
      | Contract
      | Delayed of int (* extra cycles beyond the contract; robustness only *)
      | Never (* robustness only *)
    [@@deriving sexp_of]
  end

  module Offer = struct
    type t =
      { cycle : int
      ; request : Request.t
      ; accepted : bool
      }
    [@@deriving sexp_of, compare, equal]
  end

  module Response = struct
    type t =
      { cycle : int
      ; data : int
      ; matches : bool
      }
    [@@deriving sexp_of, compare, equal]
  end

  type t =
    { mutable status : Status.t
    ; mutable accept : Request.t -> bool
    ; memory : int array
    ; mutable readback_completion : Completion.t
    ; mutable abort_completion : Completion.t
    ; mutable offers : Offer.t list (* newest first *)
    ; mutable responses : Response.t list (* delivered pulses, newest first *)
    ; mutable pending_response : Response.t option
    ; mutable pending_cleanup : int option (* edge at which cleanup becomes visible *)
    }

  let create () =
    { status = Status.halted_idle
    ; accept = (fun _ -> true)
    ; memory =
        Array.init Program_memory_controller.Config.program_depth ~f:(fun address ->
          address * 0x0101 lxor 0xa55a)
    ; readback_completion = Contract
    ; abort_completion = Contract
    ; offers = []
    ; responses = []
    ; pending_response = None
    ; pending_cleanup = None
    }
  ;;

  (* The registered response visible in [cycle], if any. *)
  let response t ~cycle =
    Option.filter t.pending_response ~f:(fun (response : Response.t) ->
      response.cycle = cycle)
  ;;

  (* Robustness only: a response pulse in [cycle] that no accepted READBACK requested. *)
  let inject_readback_response t ~cycle ~data ~matches =
    t.pending_response <- Some { cycle; data; matches }
  ;;

  let decide t ~cycle ~reset ~enable request =
    let outstanding =
      match request, t.pending_response with
      | (Request.Read _ | Verify _), Some _ -> true
      | _ -> false
    in
    let accepted = enable && (not reset) && (not outstanding) && t.accept request in
    t.offers <- { cycle; request; accepted } :: t.offers;
    accepted
  ;;

  let decision t ~cycle ~offer : int Control_port.Decision.t =
    let d = Control_port.Decision.map Control_port.Decision.port_widths ~f:(fun _ -> 0) in
    let d =
      match response t ~cycle with
      | None -> d
      | Some response ->
        { d with
          readback_response_valid = 1
        ; readback_response_data = response.data
        ; readback_response_match = Bool.to_int response.matches
        }
    in
    match offer with
    | None -> d
    | Some (request, accepted) ->
      let a = Bool.to_int accepted in
      let r = Bool.to_int (not accepted) in
      (match (request : Request.t) with
       | Load_start _ -> { d with load_start_accepted = a; load_start_rejected = r }
       | Load_write _ -> { d with load_write_accepted = a; load_write_rejected = r }
       | Load_complete ->
         { d with load_complete_accepted = a; load_complete_rejected = r }
       | Read _ | Verify _ -> { d with readback_accepted = a; readback_rejected = r }
       | Run -> { d with run_accepted = a; run_rejected = r }
       | Stop -> { d with stop_accepted = a; stop_rejected = r }
       | Abort -> { d with abort_accepted = a; abort_rejected = r })
  ;;

  let schedule completion ~contract =
    match (completion : Completion.t) with
    | Contract -> Some contract
    | Delayed extra -> Some (contract + extra)
    | Never -> None
  ;;

  (* Post-edge work for the edge that ends [cycle]. *)
  let edge t ~cycle ~reset ~enable ~offer =
    Option.iter (response t ~cycle) ~f:(fun response ->
      t.responses <- response :: t.responses;
      t.pending_response <- None);
    if reset || not enable
    then (
      t.pending_response <- None;
      t.pending_cleanup <- None);
    (match offer with
     | Some (((Request.Read { address } | Verify { address; _ }) as request), true) ->
       let expected =
         match request with
         | Verify { expected; _ } -> Some expected
         | _ -> None
       in
       let data = t.memory.(address) in
       t.pending_response
       <- Option.map
            (schedule t.readback_completion ~contract:Latency.readback_after_offer)
            ~f:(fun latency ->
              { Response.cycle = cycle + latency
              ; data
              ; matches = Option.value_map expected ~default:false ~f:(( = ) data)
              })
     | Some (Abort, true) ->
       t.pending_response <- None;
       t.pending_cleanup
       <- Option.map (schedule t.abort_completion ~contract:0) ~f:(fun latency ->
            cycle + latency)
     | Some (Load_start _, true) -> t.pending_response <- None
     | _ -> ());
    match t.pending_cleanup with
    | Some at when at = cycle ->
      t.status <- Status.cleaned t.status;
      t.pending_cleanup <- None
    | _ -> ()
  ;;
end

module Phase = struct
  type t =
    | Settle (* between the two settles of a cycle *)
    | Pre_edge
    | Host_sample (* the host's LDO sample, pre-edge in its LCLK rise cycle *)
    | Post_run (* a check made by the test between cycles *)
  [@@deriving sexp_of]
end

module Outcome = struct
  type t =
    | Commit
    | Replay
  [@@deriving sexp_of, compare, equal]
end

(* Public-boundary events, logged in the cycle they are driven or observed. *)
module Event = struct
  type t =
    | Reset of bool
    | Enable of bool
    | Select of bool (* host drives LSEL_N low when true *)
    | Sent of
        { bytes : string
        ; extra_bits : int
        }
    | Offer of
        { request : Request.t
        ; accepted : bool
        }
    | Readback_response of
        { data : int
        ; matches : bool
        }
    | Status of (string * int) list
    | Ready of bool
    | Busy of bool
    | Response_read of
        { bytes : string
        ; outcome : Outcome.t
        }
    | Note of string
  [@@deriving sexp_of]
end

type t =
  { scenario : string
  ; sim : Sim.t
  ; stub : Core_stub.t
  ; mutable timing : Timing.t
  ; mutable cycle : int
  ; mutable reset : bool
  ; mutable enable : bool
  ; mutable select_n : bool
  ; mutable clock : bool
  ; mutable data : bool
  ; mutable ready : bool (* pre-edge LRDY of the last cycle *)
  ; mutable ldo : bool (* pre-edge LDO of the last cycle *)
  ; mutable busy : bool
  ; mutable ready_changes : (int * bool) list (* newest first *)
  ; mutable last_status : Status.t
  ; transcript : (int * Event.t) Queue.t
  ; transcript_limit : int
  ; mutable omitted : int
  }

let log t ?(cycle = t.cycle) event =
  Queue.enqueue t.transcript (cycle, event);
  while Queue.length t.transcript > t.transcript_limit do
    ignore (Queue.dequeue_exn t.transcript : int * Event.t);
    t.omitted <- t.omitted + 1
  done
;;

let note t message = log t (Note message)

let transcript t =
  let events = Queue.to_list t.transcript in
  if t.omitted = 0
  then [%sexp (events : (int * Event.t) list)]
  else
    [%sexp { earlier_events_omitted = (t.omitted : int); events : (int * Event.t) list }]
;;

exception
  Harness_failure of
    { scenario : string
    ; cycle : int
    ; phase : Phase.t
    ; what : string
    ; expected : Sexp.t option
    ; actual : Sexp.t option
    ; transcript : Sexp.t
    }
[@@deriving sexp_of]

let fail t ?(cycle = t.cycle - 1) ?expected ?actual ~phase what =
  raise
    (Harness_failure
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

let set_int port value = port := Bits.of_int_trunc ~width:(Bits.width !port) value
let set_bool port value = port := Bits.of_bool value

(* The single owner of simulator advancement; see item 2 of the contract. *)
let cycle t =
  let sim = t.sim in
  let i = Cyclesim.inputs sim in
  let o = Cyclesim.outputs ~clock_edge:Before sim in
  let stub = t.stub in
  if not (Control_port.Status.equal Int.equal stub.status t.last_status)
  then (
    log t (Status (Status.summary stub.status));
    t.last_status <- stub.status);
  set_bool i.reset_i t.reset;
  set_bool i.enable_i t.enable;
  set_bool i.serial_select_n_i t.select_n;
  set_bool i.serial_clock_i t.clock;
  set_bool i.serial_data_i t.data;
  Control_port.Status.iter2 i.control_status_i stub.status ~f:set_int;
  let drive_decision offer =
    Control_port.Decision.iter2
      i.control_decision_i
      (Core_stub.decision stub ~cycle:t.cycle ~offer)
      ~f:set_int
  in
  drive_decision None;
  Cyclesim.cycle_check sim;
  Cyclesim.cycle_before_clock_edge sim;
  let request () = Control_port.Request.map o.control_request_o ~f:( ! ) in
  let offered = request () in
  let offer =
    match Request.of_port offered with
    | [] -> None
    | [ request ] ->
      Some
        ( request
        , Core_stub.decide stub ~cycle:t.cycle ~reset:t.reset ~enable:t.enable request )
    | requests ->
      fail
        t
        ~cycle:t.cycle
        ~phase:Settle
        "at most one request is offered per cycle"
        ~actual:[%sexp (requests : Request.t list)]
  in
  drive_decision offer;
  Cyclesim.cycle_before_clock_edge sim;
  check
    t
    ~cycle:t.cycle
    ~phase:Settle
    "the offered request does not depend on the decision in the same cycle"
    [%sexp_of: Bits.t Control_port.Request.t]
    (Control_port.Request.equal Bits.equal)
    ~expected:offered
    (request ());
  Option.iter offer ~f:(fun (request, accepted) -> log t (Offer { request; accepted }));
  Option.iter (Core_stub.response stub ~cycle:t.cycle) ~f:(fun response ->
    log t (Readback_response { data = response.data; matches = response.matches }));
  let ready = Bits.to_bool !(o.serial_ready_o) in
  if Bool.( <> ) ready t.ready
  then (
    t.ready_changes <- (t.cycle, ready) :: t.ready_changes;
    log t (Ready ready));
  let busy = Bits.to_bool !(o.busy_o) in
  if Bool.( <> ) busy t.busy then log t (Busy busy);
  t.ready <- ready;
  t.busy <- busy;
  t.ldo <- Bits.to_bool !(o.serial_data_o);
  Cyclesim.cycle_at_clock_edge sim;
  Cyclesim.cycle_after_clock_edge sim;
  Core_stub.edge stub ~cycle:t.cycle ~reset:t.reset ~enable:t.enable ~offer;
  t.cycle <- t.cycle + 1
;;

let hold t cycles =
  for _ = 1 to cycles do
    cycle t
  done
;;

let set_reset t value =
  t.reset <- value;
  log t (Reset value)
;;

let set_enable t value =
  t.enable <- value;
  log t (Enable value)
;;

let set_status t status = t.stub.status <- status

(* Pins idle, reset held for four cycles, then four idle cycles. The loader's
   deselected-cycle count therefore already qualifies a response selection.
*)
let create ?(timing = Timing.envelope) ?(transcript_limit = 48) scenario =
  Timing.validate timing;
  let sim = Sim.create (Host_link.create (Scope.create ~flatten_design:true ())) in
  let stub = Core_stub.create () in
  let t =
    { scenario
    ; sim
    ; stub
    ; timing
    ; cycle = 0
    ; reset = false
    ; enable = true
    ; select_n = true
    ; clock = false
    ; data = false
    ; ready = false
    ; ldo = false
    ; busy = false
    ; ready_changes = []
    ; last_status = stub.status
    ; transcript = Queue.create ()
    ; transcript_limit
    ; omitted = 0
    }
  in
  set_reset t true;
  hold t 4;
  set_reset t false;
  hold t 4;
  t
;;

let set_timing t timing =
  Timing.validate timing;
  t.timing <- timing
;;

(* Offers and delivered READBACK responses, oldest first. *)
let offers ?(since = 0) t =
  List.rev t.stub.offers
  |> List.filter ~f:(fun (offer : Core_stub.Offer.t) -> offer.cycle >= since)
;;

let accepted ?since t =
  offers ?since t |> List.filter ~f:(fun (offer : Core_stub.Offer.t) -> offer.accepted)
;;

let responses ?(since = 0) t =
  List.rev t.stub.responses
  |> List.filter ~f:(fun (response : Core_stub.Response.t) -> response.cycle >= since)
;;

let ready_changes ?(since = 0) t =
  List.rev t.ready_changes |> List.filter ~f:(fun (cycle, _) -> cycle >= since)
;;

let expect_no_offers t ~since what =
  check
    t
    ~phase:Post_run
    what
    [%sexp_of: Core_stub.Offer.t list]
    [%equal: Core_stub.Offer.t list]
    ~expected:[]
    (offers ~since t)
;;

let expect_offers t ~since what expected =
  check
    t
    ~phase:Post_run
    what
    [%sexp_of: Core_stub.Offer.t list]
    [%equal: Core_stub.Offer.t list]
    ~expected
    (offers ~since t)
;;

let expect_int t ?cycle what ~expected actual =
  check t ?cycle ~phase:Post_run what [%sexp_of: int] Int.equal ~expected actual
;;

(* Holds [cycles] and requires LRDY and LDO low and no offer throughout. *)
let expect_quiet t cycles what =
  let since = t.cycle in
  for _ = 1 to cycles do
    cycle t;
    if t.ready || t.ldo
    then
      fail
        t
        ~phase:Pre_edge
        what
        ~expected:[%sexp { ready = false; ldo = false }]
        ~actual:[%sexp { ready : bool = t.ready; ldo : bool = t.ldo }]
  done;
  expect_no_offers t ~since what
;;

(* Host serial driver. Pins are applied by [cycle]; these functions only set them and hold
   the durations in [t.timing].
*)

let select t =
  t.select_n <- false;
  log t (Select true)
;;

(* LSEL_N high and LDI low from the current cycle; returns that cycle. *)
let deselect t =
  t.select_n <- true;
  t.data <- false;
  log t (Select false);
  t.cycle
;;

(* One request bit: LDI changes with the preceding fall, is held [clock_low] cycles before
   the rise and [clock_high] after it. At each rise LDO must be low: a selection that is
   sending a request is never also shifting out a response.
*)
let send_bit t value =
  t.data <- value;
  t.clock <- false;
  hold t t.timing.clock_low;
  t.clock <- true;
  cycle t;
  if t.ldo
  then
    fail
      t
      ~phase:Host_sample
      "LDO stays low while a request is clocked in"
      ~expected:[%sexp false]
      ~actual:[%sexp true];
  hold t (t.timing.clock_high - 1);
  t.clock <- false
;;

let bits_of_byte byte =
  List.init 8 ~f:(fun index -> Char.to_int byte land (0x80 lsr index) <> 0)
;;

(* Clocks [bytes], then the first [extra_bits] bits of [extra_byte]; all MSB first. *)
let send t ?(extra_bits = 0) ?(extra_byte = '\xff') bytes =
  log t (Sent { bytes = hex bytes; extra_bits });
  String.iter bytes ~f:(fun byte -> List.iter (bits_of_byte byte) ~f:(send_bit t));
  List.iter (List.take (bits_of_byte extra_byte) extra_bits) ~f:(send_bit t)
;;

(* The last [8 - bits] bits of [byte], completing a byte begun with [~extra_bits:bits]. *)
let send_rest_of_byte t byte ~bits =
  List.iter (List.drop (bits_of_byte byte) bits) ~f:(send_bit t)
;;

(* LSEL_N low, then [select_lead] cycles before the first rise. The first bit's setup
   interval ([clock_low]) is part of the lead.
*)
let begin_frame t =
  select t;
  hold t (Int.max 0 (t.timing.select_lead - t.timing.clock_low))
;;

(* [select_trail] cycles after the last fall, then LSEL_N high; returns that cycle. The
   caller holds the gap.
*)
let end_frame t =
  hold t t.timing.select_trail;
  deselect t
;;

(* A complete selected frame, including the trailing gap; returns the deselection cycle. *)
let send_frame t ?extra_bits ?extra_byte bytes =
  begin_frame t;
  send t ?extra_bits ?extra_byte bytes;
  let deselected = end_frame t in
  hold t t.timing.deselect_gap;
  deselected
;;

(* First LRDY rise at or after [since], advancing at most [budget] cycles. *)
let wait_ready ?(budget = 20_000) t ~since =
  let rec loop spent =
    match
      List.find (ready_changes ~since t) ~f:(fun (_, ready) -> ready) |> Option.map ~f:fst
    with
    | Some rise -> rise
    | None ->
      if spent >= budget
      then
        fail
          t
          ~phase:Pre_edge
          (sprintf "LRDY rises within %d cycles of cycle %d" budget since)
          ~expected:[%sexp true]
          ~actual:[%sexp false]
      else (
        cycle t;
        loop (spent + 1))
  in
  loop 0
;;

(* A pause inside a selected response read, after bit [after_bits] (counting from one).
   With [clock_high] the pause follows that bit's sample with LCLK still high; otherwise
   it follows the bit's fall.
*)
module Pause = struct
  type t =
    { after_bits : int
    ; cycles : int
    ; clock_high : bool
    }
end

(* One response bit: [clock_low] cycles low, then a rise whose cycle samples LDO. With
   [final], LCLK is left high after the sample.
*)
let read_bit ?(final = false) ?(high_pause = 0) t =
  t.clock <- false;
  hold t t.timing.clock_low;
  t.clock <- true;
  cycle t;
  let value = t.ldo in
  hold t high_pause;
  if not final
  then (
    hold t (t.timing.clock_high - 1);
    t.clock <- false);
  value
;;

let bytes_of_bits bits =
  List.chunks_of bits ~length:8
  |> List.map ~f:(fun byte ->
    List.fold byte ~init:0 ~f:(fun value bit -> (value lsl 1) lor Bool.to_int bit)
    |> Char.of_int_exn)
  |> String.of_char_list
;;

(* Stops a selected response read before its final bit: [select_trail] cycles after the
   last fall, LSEL_N high, then the gap. Returns the deselection cycle.
*)
let abandon_response t =
  let deselected = end_frame t in
  hold t t.timing.deselect_gap;
  deselected
;;

(* After the final rise and validation, with LCLK high. Commit supplies the final fall;
   replay deselects first and leaves the final fall out. Returns the deselection cycle.
*)
let finish_response t (outcome : Outcome.t) =
  hold t (t.timing.clock_high - 1);
  let deselected =
    match outcome with
    | Commit ->
      t.clock <- false;
      end_frame t
    | Replay ->
      let deselected = deselect t in
      hold t t.timing.clock_high;
      t.clock <- false;
      deselected
  in
  hold t t.timing.deselect_gap;
  deselected
;;

module Read = struct
  type t =
    { selected : int
    ; deselected : int
    ; bytes : string
    ; decoded : (Wire.Response.t, Wire.Response.Decode_error.t) Result.t
    ; outcome : Outcome.t
    }
end

(* Reads the response through its final rise, validates it with LCLK high, and finishes
   with [decide]'s outcome. The length comes from the received header; a declared payload
   beyond the largest response is read only to the maximum frame length, so the decoder
   reports it.
*)
let read_response t ?expected ?(pause : Pause.t option) ~decide () =
  begin_frame t;
  let selected = t.cycle in
  let bits = Queue.create () in
  let read_one ~final =
    let count = Queue.length bits + 1 in
    let pause_here = Option.filter pause ~f:(fun pause -> pause.after_bits = count) in
    let high_pause =
      match pause_here with
      | Some { cycles; clock_high = true; _ } -> cycles
      | _ -> 0
    in
    Queue.enqueue bits (read_bit t ~final ~high_pause);
    match pause_here with
    | Some { cycles; clock_high = false; _ } -> hold t cycles
    | _ -> ()
  in
  for _ = 1 to 8 * Wire.Response.header_length do
    read_one ~final:false
  done;
  let header = bytes_of_bits (Queue.to_list bits) in
  let declared = Wire.U16.get header ~pos:Wire.Response.Offset.payload_length in
  let total =
    Int.min
      (Wire.Response.header_length + declared + Wire.Crc.length)
      Wire.Response.max_length
  in
  for index = (8 * Wire.Response.header_length) + 1 to 8 * total do
    read_one ~final:(index = 8 * total)
  done;
  let bytes = bytes_of_bits (Queue.to_list bits) in
  let decoded =
    match expected with
    | Some expected -> Wire.Response.decode_correlated ~expected bytes
    | None -> Wire.Response.decode bytes
  in
  let outcome = decide decoded in
  log t (Response_read { bytes = hex bytes; outcome });
  let deselected = finish_response t outcome in
  { Read.selected; deselected; bytes; decoded; outcome }
;;

(* Validation before the final fall: commit a decodable, correlated response; replay
   anything else.
*)
let commit_if_valid : (Wire.Response.t, _) Result.t -> Outcome.t = function
  | Ok _ -> Commit
  | Error _ -> Replay
;;

let expect_ready_cleared t ~deselected =
  hold t (Int.max 0 (deselected + Latency.ready_cleared_after_deselect + 1 - t.cycle));
  check
    t
    ~phase:Pre_edge
    ~cycle:(deselected + Latency.ready_cleared_after_deselect)
    "committed response clears LRDY"
    [%sexp_of: (int * bool) list]
    [%equal: (int * bool) list]
    ~expected:[ deselected + Latency.ready_cleared_after_deselect, false ]
    (ready_changes ~since:deselected t)
;;

(* A retained response keeps LRDY high for [cycles] after the host deselects. *)
let expect_retained t ~deselected ~cycles =
  hold t (Int.max 0 (deselected + cycles - t.cycle));
  check
    t
    ~phase:Pre_edge
    (sprintf "retained response keeps LRDY high for %d cycles" cycles)
    [%sexp_of: (int * bool) list * bool]
    [%equal: (int * bool) list * bool]
    ~expected:([], true)
    (ready_changes ~since:deselected t, t.ready)
;;

module Exchange = struct
  type t =
    { started : int (* cycle LSEL_N was asserted for the request *)
    ; request_deselected : int
    ; ready : int
    ; response_selected : int
    ; response_deselected : int
    ; bytes : string
    ; response : Wire.Response.t
    }
end

(* Waits for LRDY after a request frame, reads and validates the response, commits it, and
   checks that LRDY clears on the commit boundary. A response that fails validation is
   replayed first, so the failure report describes a retained response.
*)
let receive ?ready_budget ?pause t ~started ~request_deselected ~expected =
  let ready = wait_ready ?budget:ready_budget t ~since:request_deselected in
  let read = read_response t ~expected ?pause ~decide:commit_if_valid () in
  match read.decoded with
  | Error error ->
    fail
      t
      ~phase:Host_sample
      "response decodes and correlates; it was replayed"
      ~expected:[%sexp (expected : Wire.Correlation.t)]
      ~actual:[%sexp (error : Wire.Response.Decode_error.t), (hex read.bytes : string)]
  | Ok response ->
    expect_ready_cleared t ~deselected:read.deselected;
    { Exchange.started
    ; request_deselected
    ; ready
    ; response_selected = read.selected
    ; response_deselected = read.deselected
    ; bytes = read.bytes
    ; response
    }
;;

(* A complete transaction for [frame]: send it with the gap, then [receive]. *)
let exchange ?ready_budget ?pause t frame ~expected =
  let started = t.cycle in
  let request_deselected = send_frame t frame in
  receive ?ready_budget ?pause t ~started ~request_deselected ~expected
;;

let encode ~tag request =
  match Wire.Request.encode ~tag request with
  | Ok frame -> frame
  | Error error ->
    raise_s [%message "bad test request" (error : Wire.Request.Encode_error.t)]
;;

let transact ?ready_budget ?pause t ~tag request =
  exchange
    ?ready_budget
    ?pause
    t
    (encode ~tag request)
    ~expected:(Wire.Request.correlation ~tag request)
;;

(* The command reached the core exactly once, [Latency.offer_after_deselect] cycles after
   its frame's deselection, with [request]'s operands.
*)
let expect_offered_once t (exchange : Exchange.t) request ~accepted =
  expect_offers
    t
    ~since:exchange.started
    "the command is offered once, three cycles after its deselection"
    [ { cycle = exchange.request_deselected + Latency.offer_after_deselect
      ; request
      ; accepted
      }
    ]
;;

(* Reads the first [bits] bits of a response and deselects before the final bit. Returns
   the bits read, packed MSB first, and the deselection cycle.
*)
let read_prefix t ~bits =
  begin_frame t;
  let values = Queue.create () in
  for _ = 1 to bits do
    Queue.enqueue values (read_bit t)
  done;
  let deselected = abandon_response t in
  bytes_of_bits (Queue.to_list values), deselected
;;

(* Out-of-contract selection while a command is in flight: select, clock [bytes] as if
   sending a request ([send] checks that LDO stays low at every rise), deselect, and hold
   the gap. Returns the deselection cycle.
*)
let disturb t bytes =
  note t "out-of-contract selection";
  send_frame t bytes
;;

(* [Some failure] when [f] raises [Harness_failure]. Used by the negative checks. *)
let failure_of f =
  match f () with
  | (_ : unit) -> None
  | exception (Harness_failure _ as failure) -> Some [%sexp (failure : exn)]
;;

let expect_response t what ~expected (actual : Wire.Response.t) =
  check
    t
    ~phase:Host_sample
    what
    [%sexp_of: Wire.Response.t]
    [%equal: Wire.Response.t]
    ~expected
    actual
;;

(* Response written out from a scenario's expected fields. *)
let response ~tag command ?(payload = Wire.Response.Payload.Empty) result =
  { Wire.Response.tag; command = Wire.Command.to_int command; result; payload }
;;

(* A legal INFO with a fresh tag, answered with the fixed INFO descriptor: the check that
   the loader accepts new work after a malformed frame or a cancellation.
*)
let info_payload =
  Wire.Response.Payload.Info
    { wire_major = 1
    ; wire_minor = 0
    ; isa_version = 1
    ; memory_layout = 1
    ; capabilities =
        [ Status; Program_load; Program_read; Program_verify; Run; Stop; Abort ]
    ; memory_word_bits = 16
    ; memory_depth = 256
    ; max_request_payload_bytes = 4
    ; protocol_pin_count = 8
    }
;;

let expect_info_works t ~tag what =
  let since = t.cycle in
  let exchange = transact t ~tag Info in
  expect_response
    t
    what
    ~expected:(response ~tag Info ~payload:info_payload Complete)
    exchange.response;
  expect_no_offers t ~since what
;;

(* Malformed request frames, built byte by byte. [Wire.Request.encode] builds only legal
   frames, so intentional corruption lives here, never in the codec. [crc] uses the
   software CRC over the bytes given.
*)
module Raw = struct
  let crc body = String.of_char (Char.of_int_exn (Wire.Crc.compute body))

  let body ?(magic = 0xa5) ?(version = 0x10) ?payload_length ~tag ~command payload =
    let payload_length = Option.value payload_length ~default:(List.length payload) in
    String.of_char_list
      (List.map
         ([ magic; version; tag; command; payload_length land 0xff; payload_length lsr 8 ]
          @ payload)
         ~f:Char.of_int_exn)
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
