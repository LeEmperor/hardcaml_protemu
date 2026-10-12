(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "frame_tx_testbench.ml" *)
(* HL4c focused Cyclesim testbench for [Frame_tx].

   The transmitter is driven only through its public ports: [Serial_phy]'s one-cycle
   select-assert, select-release, and clock-fall events with its deselect qualification,
   and [Command_dispatch]'s one-cycle publication of a complete frame and its length. The
   PHY's synchronizers and the dispatcher are not part of this boundary. Every observation
   is a public output: [serial_data_o], [serial_ready_o], and [pending_o]. Expected bits
   and cycles are written by hand in the tests from the P3.5 record and
   docs/host_link_hl4b4_record.md: a frame is its bytes in wire order, each most
   significant bit first. None is computed from the transmitter. [Wire.Crc.compute] builds
   stimulus only.

   Scheduling contract:

   1. Time. The unit is one system clock cycle. Cycle n is the interval before edge n.
      Inputs set before [cycle] runs cycle n are applied for the whole of cycle n and
      sampled at edge n. [cycle] is the only function that advances the simulator.
   2. Levels ([reset], [enable], [qualified]) keep their value until a test changes them.
      Events ([select_assert], [select_release], [clock_fall]) and the publication last
      one cycle: [cycle] clears them after the edge, and the frame and length inputs
      return to zero, as the dispatcher drives them when it is not publishing.
   3. Within a cycle: apply the inputs; settle; take the pre-edge sample (the observation
      for cycle n); clock the edge; take the post-edge sample.
   4. Every output is a function of the transmitter's registers and [enable_i] alone. So
      the post-edge sample of edge n (taken with cycle n's inputs) must equal the pre-edge
      sample of cycle n+1 (taken after its new inputs settle) whenever enable is the same
      in both cycles, and [pending_o] must be equal always. [cycle] checks this every
      cycle.
   5. Every wait has a finite cycle budget. An exhausted budget or a failed check raises
      [Tx_failure] with the scenario, cycle, sampling phase, what was checked, the
      expected and actual values, and the inputs and outputs of recent cycles.

   PHY- and dispatcher-coherent stimulus (the default drivers) follows what the composed
   loader can present: select-assert and select-release events alternate; falls are at
   least two cycles apart; qualification is presented only with an assert event, as the
   value the PHY computes for the deselected interval before it; and the dispatcher
   publishes a complete frame of 8, 10, 20, or 21 bytes, zero-padded, never while a
   response is retained. Probes outside that, or outside the P3.5 host envelope, are
   labelled as robustness probes in the tests. Everything here is synchronous digital
   evidence about this block's boundary.
*)

open! Core
open! Hardcaml
open! Hardcaml_protemu
module Wire = Protemu_host_link_wire.Wire
module Sim = Cyclesim.With_interface (Frame_tx.I) (Frame_tx.O)

(* P3.5: one retained 21-byte response register; INFO is the largest response. *)
let store_bytes = 21

(* A frame as the dispatcher presents it: [bytes] in wire order, zero-padded to the store
   ([padding] replaces the zeros in robustness probes), and a byte count.
*)
module Publication = struct
  type t =
    { bytes : string
    ; padding : int
    ; length : int
    }
  [@@deriving sexp_of]

  let none = { bytes = ""; padding = 0; length = 0 }

  let padded t =
    t.bytes
    ^ String.make (store_bytes - String.length t.bytes) (Char.of_int_exn t.padding)
  ;;

  let summary t =
    let shown = String.prefix t.bytes 3 in
    sprintf
      "len=%d %s%s"
      t.length
      (String.concat_map shown ~f:(fun c -> sprintf "%02x" (Char.to_int c)))
      (if String.length t.bytes > 3 then ".." else "")
  ;;
end

(* The inputs applied for one cycle. *)
module Inputs = struct
  type t =
    { reset : bool
    ; enable : bool
    ; qualified : bool
    ; select_assert : bool
    ; select_release : bool
    ; clock_fall : bool
    ; publish : bool
    ; frame : Publication.t (* the frame and length inputs, with or without [publish] *)
    }
  [@@deriving sexp_of]

  let idle =
    { reset = false
    ; enable = true
    ; qualified = false
    ; select_assert = false
    ; select_release = false
    ; clock_fall = false
    ; publish = false
    ; frame = Publication.none
    }
  ;;

  let clear_events t =
    { t with
      select_assert = false
    ; select_release = false
    ; clock_fall = false
    ; publish = false
    ; frame = Publication.none
    }
  ;;

  let summary t =
    let bit b = if b then 1 else 0 in
    let events =
      List.filter_map
        [ t.select_assert, "assert"
        ; t.select_release, "release"
        ; t.clock_fall, "fall"
        ; t.publish, "publish " ^ Publication.summary t.frame
        ; ( (not t.publish) && t.frame.length <> 0
          , "unstrobed " ^ Publication.summary t.frame )
        ]
        ~f:(fun (on, name) -> Option.some_if on name)
    in
    sprintf
      "rst=%d en=%d qual=%d%s"
      (bit t.reset)
      (bit t.enable)
      (bit t.qualified)
      (if List.is_empty events then "" else " " ^ String.concat ~sep:"," events)
  ;;
end

(* One sample of every output. *)
module Sample = struct
  type t =
    { data : bool
    ; ready : bool
    ; pending : bool
    }
  [@@deriving sexp_of, equal]

  let of_outputs (o : Bits.t ref Frame_tx.O.t) =
    let bool r = Bits.to_bool !r in
    { data = bool o.serial_data_o
    ; ready = bool o.serial_ready_o
    ; pending = bool o.pending_o
    }
  ;;

  let summary t =
    let bit b = if b then 1 else 0 in
    sprintf "data=%d ready=%d pending=%d" (bit t.data) (bit t.ready) (bit t.pending)
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
  ; mutable settled : (Inputs.t * Sample.t) option (* last cycle's inputs, post-edge *)
  ; applied : Inputs.t Queue.t (* index = cycle *)
  ; observed : Sample.t Queue.t (* pre-edge samples; index = cycle *)
  ; transcript_cycles : int
  }

exception
  Tx_failure of
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
    (Tx_failure
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

let bits_of_bytes bytes =
  Bits.concat_msb
    (List.map (String.to_list bytes) ~f:(fun c ->
       Bits.of_int_trunc ~width:8 (Char.to_int c)))
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
  set i.deselect_qualified_i inputs.qualified;
  set i.select_assert_i inputs.select_assert;
  set i.select_release_i inputs.select_release;
  set i.clock_fall_i inputs.clock_fall;
  set i.response_publish_i inputs.publish;
  i.response_frame_i := bits_of_bytes (Publication.padded inputs.frame);
  i.response_length_i := Bits.of_int_trunc ~width:5 inputs.frame.length;
  Cyclesim.cycle_check t.sim;
  Cyclesim.cycle_before_clock_edge t.sim;
  let observed = Sample.of_outputs before in
  Queue.enqueue t.applied inputs;
  Queue.enqueue t.observed observed;
  Option.iter t.settled ~f:(fun ((previous : Inputs.t), settled) ->
    let comparable (s : Sample.t) =
      if Bool.equal previous.enable inputs.enable
      then s
      else { s with data = false; ready = false }
    in
    check
      t
      ~cycle:t.cycle
      ~phase:Pre_edge
      "outputs after the new inputs settle equal the last edge's post-edge outputs"
      [%sexp_of: Sample.t]
      [%equal: Sample.t]
      ~expected:(comparable settled)
      (comparable observed));
  Cyclesim.cycle_at_clock_edge t.sim;
  Cyclesim.cycle_after_clock_edge t.sim;
  t.settled <- Some (inputs, Sample.of_outputs after);
  t.inputs <- Inputs.clear_events inputs;
  t.cycle <- t.cycle + 1
;;

let run t cycles =
  for _ = 1 to cycles do
    cycle t
  done
;;

(* Set levels for the next cycle onward; unnamed levels keep their value. *)
let set ?reset ?enable ?qualified t =
  let keep value current = Option.value value ~default:current in
  t.inputs
  <- { t.inputs with
       reset = keep reset t.inputs.reset
     ; enable = keep enable t.inputs.enable
     ; qualified = keep qualified t.inputs.qualified
     }
;;

(* Raise events for the next cycle only. *)
let pulse ?(select_assert = false) ?(select_release = false) ?(clock_fall = false) t =
  t.inputs
  <- { t.inputs with
       select_assert = t.inputs.select_assert || select_assert
     ; select_release = t.inputs.select_release || select_release
     ; clock_fall = t.inputs.clock_fall || clock_fall
     }
;;

(* Present [bytes] for the next cycle only: a publication, or with [strobe = false] a
   robustness probe that drives the frame and length inputs without the strobe. [length]
   and [padding] override the contract values in robustness probes.
*)
let stage ?(strobe = true) ?length ?(padding = 0) t bytes =
  let length = Option.value length ~default:(String.length bytes) in
  t.inputs <- { t.inputs with publish = strobe; frame = { bytes; padding; length } }
;;

(* Reset is high in cycles 0 and 1, with everything else idle. [create] returns before
   running cycle 2, the first cycle out of reset.
*)
let reset_cycles = 2

let create ?(transcript_cycles = 12) scenario =
  let sim = Sim.create (Frame_tx.create (Scope.create ~flatten_design:true ())) in
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
  check
    t
    ~phase:Post_run
    "response_frame_i holds the 21-byte store"
    [%sexp_of: int]
    [%equal: int]
    ~expected:(store_bytes * 8)
    (Bits.width !((Cyclesim.inputs sim).response_frame_i));
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

(* Coherent drivers. Each runs one cycle and returns the cycle of its event. *)

let publish t bytes =
  let at = t.cycle in
  stage t bytes;
  cycle t;
  at
;;

(* An assert event, with [qualified] presented in that cycle only. *)
let select ?(qualified = true) t =
  let at = t.cycle in
  set t ~qualified;
  pulse t ~select_assert:true;
  cycle t;
  set t ~qualified:false;
  at
;;

let deselect t =
  let at = t.cycle in
  pulse t ~select_release:true;
  cycle t;
  at
;;

let fall t =
  let at = t.cycle in
  pulse t ~clock_fall:true;
  cycle t;
  at
;;

(* Wire order: bytes in order, each most significant bit first. *)
let wire_bits bytes =
  List.concat_map (String.to_list bytes) ~f:(fun c ->
    let byte = Char.to_int c in
    List.init 8 ~f:(fun index -> (byte lsr (7 - index)) land 1 = 1))
;;

(* Read [count] bits of an armed read. Each bit is presented for [period] cycles: the
   presented value must not change during them, and the last is a fall event cycle, whose
   edge advances to the next bit. [period] may vary per bit ([periods], cycled); the PHY
   cannot present falls less than two cycles apart. Returns the presented bits.
*)
let default_period = 8

let read_bits ?(periods = [ default_period ]) t count =
  let periods = Array.of_list periods in
  let read = Queue.create () in
  (* Bits are read in order; [List.init] does not promise an evaluation order. *)
  for index = 0 to count - 1 do
    let period = periods.(index % Array.length periods) in
    let from = t.cycle in
    run t (period - 1);
    let _ : int = fall t in
    let values =
      List.range from t.cycle |> List.map ~f:(fun cycle -> (observed t cycle).data)
    in
    check
      t
      ~phase:Post_run
      (sprintf "bit %d presented unchanged in cycles [%d, %d)" index from t.cycle)
      [%sexp_of: bool list]
      [%equal: bool list]
      ~expected:(List.map values ~f:(fun _ -> List.hd_exn values))
      values;
    Queue.enqueue read (List.hd_exn values)
  done;
  Queue.to_list read
;;

(* Bits as hex bytes, for readable failures; a partial final byte is left-aligned. *)
let hex_of_bits bits =
  List.chunks_of bits ~length:8
  |> List.map ~f:(fun chunk ->
    List.foldi chunk ~init:0 ~f:(fun index acc b ->
      if b then acc lor (0x80 lsr index) else acc)
    |> sprintf "%02x")
  |> String.concat ~sep:" "
;;

(* Read the first [count] bits of [bytes] (all of them by default) and check them. *)
let expect_read ?periods ?count t what bytes =
  let expected = wire_bits bytes in
  let count = Option.value count ~default:(List.length expected) in
  let expected = List.take expected count in
  check
    t
    ~phase:Post_run
    (what ^ ": bits read, MSB first")
    [%sexp_of: string]
    [%equal: string]
    ~expected:(hex_of_bits expected)
    (hex_of_bits (read_bits ?periods t count))
;;

(* Cycles in [from, until) in which a sampled flag was high. *)
let high_cycles t ~from ~until ~f =
  List.range from until |> List.filter ~f:(fun cycle -> f (observed t cycle))
;;

let expect_cycles t ~from ?(until = t.cycle) what ~f expected =
  check
    t
    ~phase:Post_run
    (sprintf "%s: high in cycles [%d, %d)" what from until)
    [%sexp_of: int list]
    [%equal: int list]
    ~expected
    (high_cycles t ~from ~until ~f)
;;

let expect_pending_cycles t ~from ?until what expected =
  expect_cycles t ~from ?until (what ^ ": pending_o") ~f:(fun s -> s.pending) expected
;;

let expect_ready_cycles t ~from ?until what expected =
  expect_cycles t ~from ?until (what ^ ": serial_ready_o") ~f:(fun s -> s.ready) expected
;;

let expect_data_cycles t ~from ?until what expected =
  expect_cycles t ~from ?until (what ^ ": serial_data_o") ~f:(fun s -> s.data) expected
;;

let expect_sample t ~cycle what (expected : Sample.t) =
  check
    t
    ~cycle
    ~phase:Pre_edge
    (what ^ ": outputs")
    [%sexp_of: Sample.t]
    [%equal: Sample.t]
    ~expected
    (observed t cycle)
;;

(* Nothing retained and nothing presented from [from] through the end of the run. *)
let expect_quiet t ~from what =
  expect_pending_cycles t ~from what [];
  expect_ready_cycles t ~from what [];
  expect_data_cycles t ~from what []
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

(* The event cycles of one complete read. *)
module Read = struct
  type t =
    { asserted : int
    ; released : int
    }
  [@@deriving sexp_of]
end

(* A qualified selection presents nothing in its assert cycle and the first bit of [bytes]
   from the next cycle, before any fall. Runs [lead] - 1 cycles after the assert.
*)
let expect_armed t ~asserted ~lead what bytes =
  run t (lead - 1);
  let first = List.hd_exn (wire_bits bytes) in
  expect_data_cycles
    t
    ~from:asserted
    (what ^ " first bit, before any fall")
    (if first then List.range (asserted + 1) t.cycle else [])
;;

(* A qualified selection that reads all of [bytes], supplies the final fall, waits [trail]
   cycles, and releases. Checks the first bit's timing, every bit, the drained output
   after the final fall, the commit edge (pending, ready low from the cycle after the
   release), and that pending and ready were high throughout the read. Runs one cycle past
   the release.
*)
let commit_read ?periods ?(lead = 4) ?(trail = 4) t what bytes =
  let asserted = select t in
  expect_armed t ~asserted ~lead what bytes;
  expect_read ?periods t what bytes;
  let drained_from = t.cycle in
  run t trail;
  let released = deselect t in
  run t 1;
  expect_data_cycles t ~from:drained_from (what ^ " after the final fall") [];
  expect_pending_cycles
    t
    ~from:asserted
    (what ^ " commit")
    (List.range asserted (released + 1));
  expect_ready_cycles
    t
    ~from:asserted
    (what ^ " commit")
    (List.range asserted (released + 1));
  { Read.asserted; released }
;;

(* A qualified selection that reads [count] bits and releases without a further fall.
   Checks the bits, and that the response is still retained after the release.
*)
let partial_read ?periods ?(lead = 4) ?(trail = 4) t what bytes ~count =
  let asserted = select t in
  expect_armed t ~asserted ~lead what bytes;
  expect_read ?periods ~count t what bytes;
  run t trail;
  let released = deselect t in
  run t 1;
  expect_pending_cycles
    t
    ~from:asserted
    (what ^ " retained")
    (List.range asserted (released + 2));
  { Read.asserted; released }
;;

(* [Some failure] when [f] raises [Tx_failure]. Used by the negative checks. *)
let failure_of f =
  match f () with
  | (_ : unit) -> None
  | exception (Tx_failure _ as failure) -> Some [%sexp (failure : exn)]
;;

(* Response frames the dispatcher builds, written from the P3.5 layouts: magic 5a, version
   10, tag, command, result, little-endian payload length, payload, CRC-8/ATM.
*)
module Frames = struct
  let bytes list = String.of_char_list (List.map list ~f:Char.of_int_exn)

  let frame ~tag ~command ~result payload =
    let body =
      bytes ([ 0x5a; 0x10; tag; command; result; List.length payload; 0x00 ] @ payload)
    in
    body ^ String.of_char (Char.of_int_exn (Wire.Crc.compute body))
  ;;

  (* 8 bytes: STOP accepted, pending. *)
  let empty tag = frame ~tag ~command:0x21 ~result:0x01 []

  (* 10 bytes: READ_WORD of 0xbeef. *)
  let word tag = frame ~tag ~command:0x12 ~result:0x00 [ 0xef; 0xbe ]

  (* 20 bytes: a STATUS with every byte distinct. *)
  let status tag =
    frame
      ~tag
      ~command:0x01
      ~result:0x00
      [ 0x07; 0x00; 0x12; 0x00; 0x34; 0x00; 0x56; 0x00; 0x9a; 0x78; 0x00; 0x02 ]
  ;;

  (* 21 bytes: an INFO. *)
  let info tag =
    frame
      ~tag
      ~command:0x00
      ~result:0x00
      [ 0x01; 0x00; 0x01; 0x01; 0x7f; 0x00; 0x10; 0x00; 0x00; 0x01; 0x04; 0x00; 0x08 ]
  ;;

  (* Every legal length, with a distinct tag each. *)
  let legal =
    [ "empty (8 bytes)", empty 0x81
    ; "word (10 bytes)", word 0x42
    ; "STATUS (20 bytes)", status 0x3c
    ; "INFO (21 bytes)", info 0xa7
    ]
  ;;
end
