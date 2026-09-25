(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "command_dispatch_lifecycle_tests.ml" *)
(* HL4c: [Command_dispatch]'s lifecycle: dispatch-to-wait-to-publication transitions,
   [busy_o] over every cycle the retained fields are read, reset and disable at each
   boundary, and same-cycle priorities.

   Reset and disable are applied for one cycle. Neither gates the offer or the publication
   in the cycle it is applied: the core refuses the offer (control_port.ml item 8), and
   the loader's own reset or disable removes the published response. What the dispatcher
   guarantees is that nothing is offered or published afterwards. Tests named "robustness"
   present handoffs the composed loader cannot (while [busy_o] is high, when [Frame_rx] is
   ineligible); they pin the existing statement priority.
*)

open! Core
open! Hardcaml_protemu
open! Command_dispatch_testbench

type cancel =
  | Reset
  | Disable
[@@deriving sexp_of]

let cancels = [ Reset; Disable ]

(* Apply [cancel] for the next cycle only and return that cycle. *)
let cancel t = function
  | Reset ->
    set t ~reset:true;
    let at = t.cycle in
    run t 1;
    set t ~reset:false;
    at
  | Disable ->
    set t ~enable:false;
    let at = t.cycle in
    run t 1;
    set t ~enable:true;
    at
;;

(* Cancel in the cycle [offset] after the handoff of [request]. *)
let cancel_at t request ~offset kind =
  let h = handoff t request in
  run t (offset - 1);
  let at = cancel t kind in
  h, at
;;

(* The retained state is gone: a fresh INFO is answered normally. *)
let expect_fresh_info t what =
  let from = t.cycle in
  let h = handoff t (Handoff.request ~tag:0xee Info) in
  run t 3;
  match publications t ~from ~until:t.cycle with
  | [ (cycle, Response { tag = 0xee; command = 0x00; result = Complete; _ }) ]
    when cycle = h + 1 -> ()
  | other ->
    fail
      t
      ~phase:Post_run
      (what ^ ": a fresh INFO is answered in the cycle after its handoff")
      ~actual:[%sexp (other : (int * Published.t) list)]
;;

let%test_unit "dispatch, waits, and publications follow the handoff at exact cycles" =
  let t = create "lifecycle timeline" in
  set_status t Status.running;
  (* Framing error: published in the handoff cycle, never busy. *)
  let from = t.cycle in
  let h = handoff t (Handoff.error Bad_crc ~tag:0x01 ~command:0x20) in
  run t 5;
  expect_busy t ~from "framing error" [];
  expect_publications
    t
    ~from
    "framing error"
    [ h, raw_response ~tag:0x01 ~command:0x20 Bad_crc ];
  (* Immediate: busy only in the dispatch cycle, which publishes. *)
  let from = t.cycle in
  let h = handoff t (Handoff.request ~tag:0x02 Stop) in
  run t 5;
  expect_busy t ~from "STOP" [ h + 1 ];
  expect_publications t ~from "STOP" [ h + 1, response ~tag:0x02 Stop Accepted_pending ];
  (* READ: busy from dispatch through the response cycle, which publishes. *)
  let from = t.cycle in
  let h = handoff t (Handoff.request ~tag:0x03 (Read_word { address = 1 })) in
  run t 5;
  expect_busy t ~from "READ" [ h + 1; h + 2; h + 3 ];
  expect_publications
    t
    ~from
    "READ"
    [ h + 3, response ~tag:0x03 Read_word ~payload:(Word (t.stub.memory 1)) Complete ];
  (* ABORT from execution: busy from dispatch through the first clean cycle. *)
  let from = t.cycle in
  let h = handoff t (Handoff.request ~tag:0x04 Abort) in
  run t 5;
  expect_busy t ~from "ABORT" [ h + 1; h + 2 ];
  expect_publications t ~from "ABORT" [ h + 2, response ~tag:0x04 Abort Complete ];
  (* In every case busy is low in the handoff cycle and falls at the publication's edge,
     where the loader's retained response takes over eligibility.
  *)
  check
    t
    ~phase:Post_run
    "busy in any handoff cycle"
    [%sexp_of: bool]
    [%equal: bool]
    ~expected:false
    (List.exists (List.range 0 t.cycle) ~f:(fun c ->
       let applied = Queue.get t.applied c in
       applied.frame_end && (observed t c).busy))
;;

let%test_unit "reset or disable in the handoff cycle discards the request; a framing \
               error is still presented in that cycle"
  =
  let t = create "cancel at the handoff" in
  List.iter cancels ~f:(fun kind ->
    let what = Sexp.to_string [%sexp (kind : cancel)] in
    (* A valid frame: nothing is armed, so nothing is offered. *)
    let from = t.cycle in
    (match kind with
     | Reset -> set t ~reset:true
     | Disable -> set t ~enable:false);
    let h = handoff t (Handoff.request ~tag:0x10 Run) in
    set t ~reset:false ~enable:true;
    run t 10;
    expect_quiet t ~from (what ^ ", valid frame");
    ignore h;
    (* A framing error: presented in the handoff cycle (the loader's own cancellation
       discards it), and nothing later.
    *)
    let from = t.cycle in
    (match kind with
     | Reset -> set t ~reset:true
     | Disable -> set t ~enable:false);
    let h = handoff t (Handoff.error Bad_magic ~tag:0x11 ~command:0x01) in
    set t ~reset:false ~enable:true;
    run t 10;
    expect_publications
      t
      ~from
      (what ^ ", framing error")
      [ h, raw_response ~tag:0x11 ~command:0x01 Bad_magic ];
    expect_offers t ~since:from (what ^ ", framing error") [];
    expect_busy t ~from (what ^ ", framing error") [];
    expect_fresh_info t what)
;;

let%test_unit "reset or disable in the dispatch cycle: the offer stays visible and is \
               refused, its refusal is presented, and nothing follows"
  =
  let t = create "cancel in the dispatch cycle" in
  List.iter cancels ~f:(fun kind ->
    let what = Sexp.to_string [%sexp (kind : cancel)] in
    List.iter
      [ Wire.Request.Load_start { length = 2 }, 0x20
      ; Read_word { address = 3 }, 0x21
      ; Abort, 0x22
      ; Stop, 0x23
      ]
      ~f:(fun (request, tag) ->
        let from = t.cycle in
        let h, at = cancel_at t (Handoff.request ~tag request) ~offset:1 kind in
        run t 20;
        let what = what ^ " " ^ Sexp.to_string [%sexp (request : Wire.Request.t)] in
        check
          t
          ~phase:Post_run
          (what ^ ": one offer, in the cancelled dispatch cycle, refused")
          [%sexp_of: (int * bool) list]
          [%equal: (int * bool) list]
          ~expected:[ h + 1, false ]
          (offers ~since:from t
           |> List.map ~f:(fun (o : Core_stub.Offer.t) -> o.cycle, o.accepted));
        check
          t
          ~phase:Post_run
          (what ^ ": cancel cycle")
          [%sexp_of: int]
          [%equal: int]
          ~expected:(h + 1)
          at;
        (* Halted and idle, with no verified image: the refusal class is 0x23. *)
        expect_publications
          t
          ~from
          what
          [ h + 1, response ~tag (Wire.Request.command request) Image_bounds ];
        expect_busy t ~from what [ h + 1 ]);
    (* STATUS dispatched while disabled reports the enabled flag clear. *)
    let from = t.cycle in
    let h, _ = cancel_at t (Handoff.request ~tag:0x24 Status) ~offset:1 kind in
    run t 5;
    let flags : Wire.Status.Flag.t list =
      match kind with
      | Reset -> [ Enabled; Halted; Engines_idle ]
      | Disable -> [ Halted; Engines_idle ]
    in
    expect_publications
      t
      ~from
      (what ^ " STATUS")
      [ ( h + 1
        , response
            ~tag:0x24
            Status
            ~payload:
              (Status
                 { flags
                 ; image_length = 0
                 ; words_written = 0
                 ; words_verified = 0
                 ; pc = 0
                 ; fault_kind = No_fault
                 ; phase = Halted
                 })
            Complete )
      ];
    expect_fresh_info t what)
;;

let%test_unit "reset or disable at each READ wait boundary ends the wait with no later \
               publication"
  =
  let t = create "cancel a READ wait" in
  List.iter cancels ~f:(fun kind ->
    let what = Sexp.to_string [%sexp (kind : cancel)] in
    (* The first wait cycle: the core's response is cancelled with it (item 8). *)
    let from = t.cycle in
    let h, _ =
      cancel_at t (Handoff.request ~tag:0x30 (Read_word { address = 6 })) ~offset:2 kind
    in
    run t 20;
    expect_publications t ~from (what ^ ", first wait cycle") [];
    expect_busy t ~from (what ^ ", first wait cycle") [ h + 1; h + 2 ];
    (* The response cycle: the completion is presented in that cycle, as the loader's own
       cancellation discards it, and the wait is over.
    *)
    let from = t.cycle in
    let h, _ =
      cancel_at t (Handoff.request ~tag:0x31 (Read_word { address = 7 })) ~offset:3 kind
    in
    run t 20;
    expect_publications
      t
      ~from
      (what ^ ", response cycle")
      [ h + 3, response ~tag:0x31 Read_word ~payload:(Word (t.stub.memory 7)) Complete ];
    expect_busy t ~from (what ^ ", response cycle") [ h + 1; h + 2; h + 3 ];
    expect_fresh_info t what)
;;

let%test_unit "reset or disable in the ABORT cleanup cycle presents the completion and \
               nothing more"
  =
  let t = create "cancel in the cleanup cycle" in
  List.iter cancels ~f:(fun kind ->
    let what = Sexp.to_string [%sexp (kind : cancel)] in
    set_status t Status.running;
    let from = t.cycle in
    let h, _ = cancel_at t (Handoff.request ~tag:0x40 Abort) ~offset:2 kind in
    run t 20;
    expect_publications t ~from what [ h + 2, response ~tag:0x40 Abort Complete ];
    expect_busy t ~from what [ h + 1; h + 2 ];
    expect_fresh_info t what)
;;

let%test_unit "robustness: a READ completion coinciding with a framing-error handoff \
               publishes the completion"
  =
  let t = create "robustness: completion versus handoff" in
  let read = Handoff.request ~tag:0x50 (Read_word { address = 8 }) in
  let from = t.cycle in
  let h = handoff t read in
  run t 1;
  (* The response cycle h + 3 also carries a failed handoff with the same fields. *)
  run t 1;
  ignore (handoff t { read with result = Wire.Result_code.to_int Bad_crc } : int);
  run t 10;
  expect_publications
    t
    ~from
    "completion and handoff"
    [ h + 3, response ~tag:0x50 Read_word ~payload:(Word (t.stub.memory 8)) Complete ];
  expect_busy t ~from "completion and handoff" [ h + 1; h + 2; h + 3 ]
;;

let%test_unit "robustness: a handoff in the dispatch cycle neither re-arms dispatch nor \
               replaces the immediate response"
  =
  let t = create "robustness: handoff during dispatch" in
  (* A valid handoff: dispatch clears at that edge, so there is still one offer. *)
  let run_request = Handoff.request ~tag:0x60 Run in
  let from = t.cycle in
  let h = handoff t run_request in
  ignore (handoff t run_request : int);
  run t 10;
  expect_offers
    t
    ~since:from
    "valid"
    [ { cycle = h + 1; request = Run; accepted = true } ];
  expect_publications t ~from "valid" [ h + 1, response ~tag:0x60 Run Complete ];
  expect_busy t ~from "valid" [ h + 1 ];
  (* A failed handoff: the dispatch response is published, not the error. *)
  let from = t.cycle in
  let h = handoff t run_request in
  ignore
    (handoff t { run_request with result = Wire.Result_code.to_int Bad_version } : int);
  run t 10;
  expect_publications t ~from "failed" [ h + 1, response ~tag:0x60 Run Complete ];
  expect_busy t ~from "failed" [ h + 1 ]
;;
