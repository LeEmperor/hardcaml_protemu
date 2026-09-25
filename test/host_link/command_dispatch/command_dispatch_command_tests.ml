(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "command_dispatch_command_tests.ml" *)
(* HL4c: [Command_dispatch]'s command recognition, fixed lengths, device bounds, result
   precedence, and one-shot core offers with exact operands.

   Expected records are written by hand. Every operand of the request record is driven
   continuously from the retained fields (control_port.ml item 2): addresses and lengths
   are the low nine bits of payload bytes 0 and 1, and both data operands are payload
   bytes 2 and 3, which after a two-byte payload are the CRC byte and zero
   (docs/host_link_hl4b2_record.md). The tests pin those driven values even where the core
   ignores them.
*)

open! Core
open! Hardcaml_protemu
open! Command_dispatch_testbench

let quiet_after = 50

(* The request record for 16-bit address/length [a] and data [d], with no valid. *)
let operands ~a ~d ~verify : Port.t =
  { Port.idle with
    load_length = a
  ; load_address = a
  ; load_data = d
  ; readback_address = a
  ; readback_verify = Bool.to_int verify
  ; readback_expected = d
  }
;;

(* Dispatch one legal request and check its offer, operands, response, and busy cycles.
   The stub accepts, so every response is the success case.
*)
let expect_dispatch t ~tag request ~offer ~record ~response =
  let from = t.cycle in
  let h = handoff t (Handoff.request ~tag request) in
  run t quiet_after;
  let o = h + Latency.offer_after_handoff in
  expect_offers
    t
    ~since:from
    "one offer, in the cycle after the handoff"
    (Option.to_list offer
     |> List.map ~f:(fun request ->
       { Core_stub.Offer.cycle = o; request; accepted = true }));
  expect_request t ~cycle:o "offer cycle" record;
  let what = Sexp.to_string [%sexp (request : Wire.Request.t)] in
  expect_publications t ~from what [ h + Latency.immediate_after_handoff, response ];
  expect_busy t ~from what [ o ]
;;

let%test_unit "each immediate command is offered once, in the cycle after the handoff, \
               with exact operands"
  =
  let t = create "immediate commands" in
  (* INFO and STATUS answer from the dispatcher and offer nothing. *)
  let info = Handoff.request ~tag:0x01 Info in
  let from = t.cycle in
  let h = handoff t info in
  run t quiet_after;
  expect_offers t ~since:from "INFO" [];
  expect_request
    t
    ~cycle:(h + 1)
    "INFO operands (CRC byte in payload[7:0])"
    (operands ~a:(info.payload land 0xff) ~d:0 ~verify:false);
  expect_busy t ~from "INFO" [ h + 1 ];
  let from = t.cycle in
  let h = handoff t (Handoff.request ~tag:0x02 Status) in
  run t quiet_after;
  expect_offers t ~since:from "STATUS" [];
  expect_busy t ~from "STATUS" [ h + 1 ];
  let load_start = Handoff.request ~tag:0x10 (Load_start { length = 0x0040 }) in
  expect_dispatch
    t
    ~tag:0x10
    (Load_start { length = 0x0040 })
    ~offer:(Some (Load_start { length = 0x040 }))
    ~record:
      { (operands ~a:0x040 ~d:(load_start.payload lsr 16) ~verify:false) with
        load_start_valid = 1
      }
    ~response:(response ~tag:0x10 Load_start Complete);
  expect_dispatch
    t
    ~tag:0x11
    (Write_word { address = 0x00ff; word = 0xbeef })
    ~offer:(Some (Load_write { address = 0x0ff; data = 0xbeef }))
    ~record:{ (operands ~a:0x0ff ~d:0xbeef ~verify:false) with load_write_valid = 1 }
    ~response:(response ~tag:0x11 Write_word Complete);
  expect_dispatch
    t
    ~tag:0x14
    Load_complete
    ~offer:(Some Load_complete)
    ~record:
      { (operands ~a:(Handoff.request ~tag:0x14 Load_complete).payload ~d:0 ~verify:false) with
        load_complete_valid = 1
      }
    ~response:(response ~tag:0x14 Load_complete Complete);
  expect_dispatch
    t
    ~tag:0x20
    Run
    ~offer:(Some Run)
    ~record:
      { (operands ~a:(Handoff.request ~tag:0x20 Run).payload ~d:0 ~verify:false) with
        run_valid = 1
      }
    ~response:(response ~tag:0x20 Run Complete);
  expect_dispatch
    t
    ~tag:0x21
    Stop
    ~offer:(Some Stop)
    ~record:
      { (operands ~a:(Handoff.request ~tag:0x21 Stop).payload ~d:0 ~verify:false) with
        stop_valid = 1
      }
    ~response:(response ~tag:0x21 Stop Accepted_pending)
;;

let%test_unit "READ, VERIFY, and ABORT are offered once and wait; operands are exact" =
  let t = create "waiting commands" in
  (* READ: the expected operand carries the CRC byte; the core ignores it without
     [readback_verify]. *)
  let read = Handoff.request ~tag:0x12 (Read_word { address = 0x0042 }) in
  let from = t.cycle in
  let h = handoff t read in
  run t quiet_after;
  let o = h + 1 in
  expect_offers
    t
    ~since:from
    "READ"
    [ { cycle = o; request = Read { address = 0x042 }; accepted = true } ];
  expect_request
    t
    ~cycle:o
    "READ"
    { (operands ~a:0x042 ~d:(read.payload lsr 16) ~verify:false) with readback_valid = 1 };
  check
    t
    ~phase:Post_run
    "READ's expected operand is the CRC byte, as stimulus"
    [%sexp_of: int]
    [%equal: int]
    ~expected:
      (Char.to_int (Handoff.encode ~tag:0x12 (Read_word { address = 0x0042 })).[8])
    (read.payload lsr 16);
  let word = t.stub.memory 0x42 in
  expect_publications
    t
    ~from
    "READ"
    [ ( o + Latency.readback_after_offer
      , response ~tag:0x12 Read_word ~payload:(Word word) Complete )
    ];
  expect_busy t ~from "READ" [ o; o + 1; o + 2 ];
  let from = t.cycle in
  let h =
    handoff
      t
      (Handoff.request ~tag:0x13 (Verify_word { address = 0x0007; expected = 0x1234 }))
  in
  run t quiet_after;
  let o = h + 1 in
  expect_offers
    t
    ~since:from
    "VERIFY"
    [ { cycle = o
      ; request = Verify { address = 0x007; expected = 0x1234 }
      ; accepted = true
      }
    ];
  expect_request
    t
    ~cycle:o
    "VERIFY"
    { (operands ~a:0x007 ~d:0x1234 ~verify:true) with readback_valid = 1 };
  let from = t.cycle in
  let h = handoff t (Handoff.request ~tag:0x22 Abort) in
  run t quiet_after;
  let o = h + 1 in
  expect_offers t ~since:from "ABORT" [ { cycle = o; request = Abort; accepted = true } ];
  expect_request
    t
    ~cycle:o
    "ABORT"
    { (operands ~a:(Handoff.request ~tag:0x22 Abort).payload ~d:0 ~verify:false) with
      abort_valid = 1
    };
  expect_publications
    t
    ~from
    "ABORT"
    [ o + Latency.abort_clean_after_offer, response ~tag:0x22 Abort Complete ];
  expect_busy t ~from "ABORT" [ o; o + 1 ]
;;

let%test_unit "nothing is offered while idle, while waiting, or after completion" =
  let t = create "no unsolicited offers" in
  run t 2000;
  expect_quiet t ~from:0 "idle after reset";
  (* A READ whose response never comes (robustness): one offer, then only the wait. *)
  t.stub.readback_completion <- Never;
  let from = t.cycle in
  let h = handoff t (Handoff.request ~tag:0x31 (Read_word { address = 0x0001 })) in
  run t 2000;
  expect_offers
    t
    ~since:from
    "robustness: an unbounded READ wait"
    [ { cycle = h + 1; request = Read { address = 0x001 }; accepted = true } ];
  expect_publications t ~from "robustness: an unbounded READ wait" [];
  expect_busy t ~from "robustness: an unbounded READ wait" (List.range (h + 1) t.cycle);
  (* Disable ends the wait; then a completed STOP and a long idle interval. *)
  set t ~enable:false;
  run t 1;
  set t ~enable:true;
  t.stub.readback_completion <- Contract;
  let from = t.cycle in
  let h = handoff t (Handoff.request ~tag:0x32 Stop) in
  run t 3000;
  expect_offers
    t
    ~since:from
    "after completion"
    [ { cycle = h + 1; request = Stop; accepted = true } ]
;;

let%test_unit "unknown command bytes publish Bad_command with the raw byte and offer \
               nothing"
  =
  let t = create "unknown commands" in
  List.iter
    [ 0x02, 0; 0x0f, 0; 0x15, 0; 0x23, 0; 0x7f, 0; 0x80, 0; 0xff, 0; 0x15, 2; 0x7f, 4 ]
    ~f:(fun (command, payload_length) ->
      let from = t.cycle in
      let h =
        handoff t (Handoff.raw ~tag:0xc3 ~command ~payload_length ~payload:0x0000_0100)
      in
      run t 10;
      let what = sprintf "command %02x, length %d" command payload_length in
      expect_offers t ~since:from what [];
      expect_publications
        t
        ~from
        what
        [ h + 1, raw_response ~tag:0xc3 ~command Bad_command ];
      expect_busy t ~from what [ h + 1 ])
;;

let%test_unit "every known command with a wrong fixed length publishes Bad_length and \
               offers nothing"
  =
  let t = create "wrong fixed lengths" in
  (* Legal lengths: 0 for INFO, STATUS, LOAD_COMPLETE, RUN, STOP, ABORT; 2 for LOAD_START
     and READ; 4 for WRITE and VERIFY. Operands are in range, so only the length fails.
  *)
  let cases : (Wire.Command.t * int list) list =
    [ Info, [ 1; 2; 3; 4 ]
    ; Status, [ 1; 2; 3; 4 ]
    ; Load_start, [ 0; 1; 3; 4 ]
    ; Write_word, [ 0; 1; 2; 3 ]
    ; Read_word, [ 0; 1; 3; 4 ]
    ; Verify_word, [ 0; 1; 2; 3 ]
    ; Load_complete, [ 1; 2; 3; 4 ]
    ; Run, [ 1; 2; 3; 4 ]
    ; Stop, [ 1; 2; 3; 4 ]
    ; Abort, [ 1; 2; 3; 4 ]
    ]
  in
  List.iter cases ~f:(fun (command, lengths) ->
    List.iter lengths ~f:(fun payload_length ->
      let from = t.cycle in
      let h =
        handoff
          t
          (Handoff.raw
             ~tag:0x5a
             ~command:(Wire.Command.to_int command)
             ~payload_length
             ~payload:0x1234_0010)
      in
      run t 10;
      let what =
        sprintf
          "%s, length %d"
          (Sexp.to_string [%sexp (command : Wire.Command.t)])
          payload_length
      in
      expect_offers t ~since:from what [];
      expect_publications t ~from what [ h + 1, response ~tag:0x5a command Bad_length ]));
  (* Robustness: [Frame_rx] never hands off [Complete] with a length above four, but the
     comparison is on all sixteen bits: a matching low byte does not pass.
  *)
  List.iter
    [ Wire.Command.Run, 0x0100; Load_start, 0x0102; Write_word, 0x0404; Info, 0xff00 ]
    ~f:(fun (command, payload_length) ->
      let from = t.cycle in
      let h =
        handoff
          t
          (Handoff.raw
             ~tag:0x5b
             ~command:(Wire.Command.to_int command)
             ~payload_length
             ~payload:0x1234_0010)
      in
      run t 10;
      let what = sprintf "robustness: length %04x" payload_length in
      expect_offers t ~since:from what [];
      expect_publications t ~from what [ h + 1, response ~tag:0x5b command Bad_length ])
;;

let%test_unit "device bounds are checked on the full sixteen-bit operand before narrowing"
  =
  let t = create "device bounds" in
  let dispatch ~tag request =
    let from = t.cycle in
    let h = handoff t (Handoff.request ~tag request) in
    run t 10;
    from, h
  in
  (* LOAD_START: 1 to 256 words. 0x0201 and 0x0300 would narrow to 1 and 0x100. *)
  List.iter
    [ 0x0001, 0x001; 0x00ff, 0x0ff; 0x0100, 0x100 ]
    ~f:(fun (length, narrowed) ->
      let from, h = dispatch ~tag:0x40 (Load_start { length }) in
      let what = sprintf "LOAD_START %04x" length in
      expect_offers
        t
        ~since:from
        what
        [ { cycle = h + 1; request = Load_start { length = narrowed }; accepted = true } ];
      expect_publications t ~from what [ h + 1, response ~tag:0x40 Load_start Complete ]);
  List.iter [ 0x0000; 0x0101; 0x0201; 0x0300; 0x1000; 0xffff ] ~f:(fun length ->
    let from, h = dispatch ~tag:0x41 (Load_start { length }) in
    let what = sprintf "LOAD_START %04x" length in
    expect_offers t ~since:from what [];
    expect_publications t ~from what [ h + 1, response ~tag:0x41 Load_start Image_bounds ]);
  (* WRITE, READ, VERIFY: addresses 0 to 0xff. 0x0200 would narrow to 0. *)
  List.iter [ 0x0000; 0x00ff ] ~f:(fun address ->
    let from, h = dispatch ~tag:0x42 (Write_word { address; word = 0x5555 }) in
    expect_offers
      t
      ~since:from
      "WRITE in range"
      [ { cycle = h + 1
        ; request = Load_write { address; data = 0x5555 }
        ; accepted = true
        }
      ]);
  List.iter [ 0x0100; 0x0200; 0x01ff; 0xff00; 0xffff ] ~f:(fun address ->
    List.iter
      [ Wire.Request.Write_word { address; word = 0x5555 }
      ; Read_word { address }
      ; Verify_word { address; expected = 0x5555 }
      ]
      ~f:(fun request ->
        let from, h = dispatch ~tag:0x43 request in
        let what = Sexp.to_string [%sexp (request : Wire.Request.t)] in
        expect_offers t ~since:from what [];
        expect_publications
          t
          ~from
          what
          [ h + 1, response ~tag:0x43 (Wire.Request.command request) Image_bounds ];
        expect_busy t ~from what [ h + 1 ]))
;;

let%test_unit "results resolve in the existing precedence: length, then bounds, then the \
               core's decision"
  =
  let t = create "result precedence" in
  (* The core would refuse everything; it is never asked when an earlier check fails. *)
  t.stub.accept <- (fun _ -> false);
  set_status t Status.running;
  let case ~tag ~command ~payload_length ~payload expected =
    let from = t.cycle in
    let h =
      handoff
        t
        (Handoff.raw ~tag ~command:(Wire.Command.to_int command) ~payload_length ~payload)
    in
    run t 10;
    let what = sprintf "tag %02x" tag in
    expect_offers t ~since:from what [];
    expect_publications t ~from what [ h + 1, response ~tag command expected ]
  in
  (* Wrong length and out of bounds: Bad_length. *)
  case ~tag:0x60 ~command:Write_word ~payload_length:3 ~payload:0x0000_0100 Bad_length;
  case ~tag:0x61 ~command:Load_start ~payload_length:4 ~payload:0x0000_0000 Bad_length;
  case ~tag:0x62 ~command:Verify_word ~payload_length:2 ~payload:0x0000_0010 Bad_length;
  case ~tag:0x63 ~command:Read_word ~payload_length:4 ~payload:0x0000_0010 Bad_length;
  (* Right length, out of bounds, core refusing and executing: Image_bounds, no offer. *)
  case ~tag:0x64 ~command:Read_word ~payload_length:2 ~payload:0x0000_0100 Image_bounds;
  case ~tag:0x65 ~command:Load_start ~payload_length:2 ~payload:0x0000_0000 Image_bounds;
  (* In bounds: offered, and the refusal is classified from status. *)
  let from = t.cycle in
  let h = handoff t (Handoff.request ~tag:0x66 (Read_word { address = 0x0010 })) in
  run t 10;
  expect_offers
    t
    ~since:from
    "in bounds"
    [ { cycle = h + 1; request = Read { address = 0x010 }; accepted = false } ];
  expect_publications
    t
    ~from
    "in bounds"
    [ h + 1, response ~tag:0x66 Read_word Active_execution ]
;;
