(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "hardware_loader_transaction_tests.ml" *)
(* HL4a: legal transactions, host timing, pauses, and response replay/commit at the
   composed [Host_link]'s serial pins and [Control_port].

   Expected responses are written out from the P3.5 record and the scenario's stub
   configuration, never computed from the offered request or the loader's logic. Each test
   says whether its stub follows the [Control_port] contract or deliberately departs from
   it as a loader robustness probe. See docs/host_link_hl4a_record.md for the case map.
*)

open! Core
open! Hardcaml_protemu
open! Hardware_loader_testbench

(* Raw INFO response for tag 0x5c, with its CRC from an independent bitwise CRC-8/ATM
   script (check value [123456789] -> [0xf4]), not from [Wire].
*)
let info_response_5c = "5a 10 5c 00 00 0d 00 01 00 01 01 7f 00 10 00 00 01 04 00 08 36"

let%test_unit "INFO and STATUS report the fixed descriptor and the core's status" =
  (* Contract-faithful: status is a live observation with no qualifier (item 9). *)
  let t = create "INFO and STATUS" in
  let exchange = transact t ~tag:0x5c Info in
  check
    t
    ~phase:Host_sample
    "INFO bytes"
    [%sexp_of: string]
    String.equal
    ~expected:info_response_5c
    (hex exchange.bytes);
  expect_response
    t
    "INFO"
    ~expected:(response ~tag:0x5c Info ~payload:info_payload Complete)
    exchange.response;
  expect_no_offers t ~since:exchange.started "INFO is answered without an offer";
  expect_int
    t
    "INFO is ready one cycle after its dispatch cycle"
    ~expected:
      (exchange.request_deselected
       + Latency.offer_after_deselect
       + Latency.ready_after_offer)
    exchange.ready;
  let status_cases : (string * Status.t * Wire.Status.t) list =
    [ ( "after reset"
      , Status.halted_idle
      , { flags = [ Enabled; Halted; Engines_idle ]
        ; image_length = 0
        ; words_written = 0
        ; words_verified = 0
        ; pc = 0
        ; fault_kind = No_fault
        ; phase = Halted
        } )
    ; ( "verified image after a normal halt"
      , { Status.halted_idle with
          image_valid = 1
        ; image_length = 3
        ; words_written = 3
        ; words_verified = 3
        ; normal_halt = 1
        ; pc = 2
        }
      , { flags = [ Enabled; Halted; Engines_idle; Image_valid; Normal_halt ]
        ; image_length = 3
        ; words_written = 3
        ; words_verified = 3
        ; pc = 2
        ; fault_kind = No_fault
        ; phase = Halted
        } )
    ; ( "executing with an engine on pin 1; the 17-bit PC is reported in 16 bits"
      , { Status.running with image_length = 10; pc = 0x1_0007 }
      , { flags =
            [ Enabled; Image_valid; Execution_active; Pin_output_enabled; Pin_claimed ]
        ; image_length = 10
        ; words_written = 0
        ; words_verified = 0
        ; pc = 0x0007
        ; fault_kind = No_fault
        ; phase = Mechanism_wait
        } )
    ; ( "invalid-instruction fault"
      , { Status.halted_idle with
          image_valid = 1
        ; image_length = 1
        ; words_written = 1
        ; words_verified = 1
        ; execution_fault = 1
        ; fault_kind = 1
        ; phase = 6
        ; pc = 1
        }
      , { flags = [ Enabled; Halted; Engines_idle; Image_valid; Execution_fault ]
        ; image_length = 1
        ; words_written = 1
        ; words_verified = 1
        ; pc = 1
        ; fault_kind = Invalid_base
        ; phase = Fault
        } )
    ; ( "load in progress with a failed verify, a fetch fault, and a software claim"
      , { Status.halted_idle with
          load_active = 1
        ; verification_failed = 1
        ; fetch_fault = 1
        ; image_length = 256
        ; words_written = 255
        ; words_verified = 17
        ; software_claim = 0x80
        ; fault_kind = 9
        ; phase = 3
        }
      , { flags =
            [ Enabled
            ; Halted
            ; Engines_idle
            ; Load_active
            ; Verification_failed
            ; Fetch_fault
            ; Pin_claimed
            ]
        ; image_length = 256
        ; words_written = 255
        ; words_verified = 17
        ; pc = 0
        ; fault_kind = Mechanism_protocol
        ; phase = Extension_wait
        } )
    ]
  in
  List.iteri status_cases ~f:(fun index (what, status, expected) ->
    set_status t status;
    let tag = 0x60 + index in
    let exchange = transact t ~tag Status in
    expect_response
      t
      ("STATUS " ^ what)
      ~expected:(response ~tag Status ~payload:(Status expected) Complete)
      exchange.response;
    expect_no_offers t ~since:exchange.started "STATUS is answered without an offer")
;;

(* One accepted command: its request, response, and when LRDY rises after the offer. *)
type accepted_case =
  { what : string
  ; wire : Wire.Request.t
  ; request : Request.t
  ; expected : Wire.Response.t
  ; ready_after_offer : int
  ; prepare : t -> unit
  }

let%test_unit "each shared command is offered once with its operands and completes on \
               time"
  =
  (* Contract-faithful: the stub accepts every offer, READBACK responds at item 5's cycle,
     and ABORT cleanup is visible after the accepting edge (item 6).
  *)
  let t = create "accepted commands" in
  let immediate = Latency.ready_after_offer in
  let readback = Latency.readback_after_offer + Latency.ready_after_completion in
  let abort = Latency.abort_clean_after_offer + Latency.ready_after_completion in
  let no_prep (_ : t) = () in
  let cases =
    [ { what = "LOAD_START of one word"
      ; wire = Load_start { length = 1 }
      ; request = Load_start { length = 1 }
      ; expected = response ~tag:0x10 Load_start Complete
      ; ready_after_offer = immediate
      ; prepare = no_prep
      }
    ; { what = "LOAD_START of the whole memory"
      ; wire = Load_start { length = 256 }
      ; request = Load_start { length = 256 }
      ; expected = response ~tag:0x11 Load_start Complete
      ; ready_after_offer = immediate
      ; prepare = no_prep
      }
    ; { what = "WRITE_WORD at address 0"
      ; wire = Write_word { address = 0; word = 0xbeef }
      ; request = Load_write { address = 0; data = 0xbeef }
      ; expected = response ~tag:0x12 Write_word Complete
      ; ready_after_offer = immediate
      ; prepare = no_prep
      }
    ; { what = "WRITE_WORD at the last address"
      ; wire = Write_word { address = 255; word = 0x1234 }
      ; request = Load_write { address = 255; data = 0x1234 }
      ; expected = response ~tag:0x13 Write_word Complete
      ; ready_after_offer = immediate
      ; prepare = no_prep
      }
    ; { what = "READ_WORD"
      ; wire = Read_word { address = 7 }
      ; request = Read { address = 7 }
      ; expected = response ~tag:0x14 Read_word ~payload:(Word 0x0bad) Complete
      ; ready_after_offer = readback
      ; prepare = (fun t -> t.stub.memory.(7) <- 0x0bad)
      }
    ; { what = "VERIFY_WORD that matches"
      ; wire = Verify_word { address = 9; expected = 0x5678 }
      ; request = Verify { address = 9; expected = 0x5678 }
      ; expected = response ~tag:0x15 Verify_word ~payload:(Word 0x5678) Complete
      ; ready_after_offer = readback
      ; prepare = (fun t -> t.stub.memory.(9) <- 0x5678)
      }
    ; { what = "LOAD_COMPLETE"
      ; wire = Load_complete
      ; request = Load_complete
      ; expected = response ~tag:0x16 Load_complete Complete
      ; ready_after_offer = immediate
      ; prepare = no_prep
      }
    ; { what = "RUN"
      ; wire = Run
      ; request = Run
      ; expected = response ~tag:0x17 Run Complete
      ; ready_after_offer = immediate
      ; prepare = no_prep
      }
    ; { what = "STOP while executing"
      ; wire = Stop
      ; request = Stop
      ; expected = response ~tag:0x18 Stop Accepted_pending
      ; ready_after_offer = immediate
      ; prepare = (fun t -> set_status t Status.running)
      }
    ; { what = "ABORT while an engine drives pin 1"
      ; wire = Abort
      ; request = Abort
      ; expected = response ~tag:0x19 Abort Complete
      ; ready_after_offer = abort
      ; prepare = (fun t -> set_status t Status.running)
      }
    ; { what = "STOP while halted"
      ; wire = Stop
      ; request = Stop
      ; expected = response ~tag:0x1a Stop Accepted_pending
      ; ready_after_offer = immediate
      ; prepare = no_prep
      }
    ]
  in
  List.iter cases ~f:(fun case ->
    case.prepare t;
    let exchange = transact t ~tag:case.expected.tag case.wire in
    expect_response t case.what ~expected:case.expected exchange.response;
    expect_offered_once t exchange case.request ~accepted:true;
    let offer = exchange.request_deselected + Latency.offer_after_deselect in
    expect_int
      t
      (case.what ^ ": LRDY rises on time after the offer")
      ~expected:(offer + case.ready_after_offer)
      exchange.ready;
    (match case.request with
     | Read _ | Verify _ ->
       check
         t
         ~phase:Post_run
         (case.what ^ ": one READBACK response, two cycles after the offer")
         [%sexp_of: int list]
         [%equal: int list]
         ~expected:[ offer + Latency.readback_after_offer ]
         (List.map (responses ~since:exchange.started t) ~f:(fun r -> r.cycle))
     | _ -> ());
    expect_quiet t 200 (case.what ^ ": the command is never offered again"))
;;

(* One refused command and the result its status selects. *)
type refused_case =
  { status_name : string
  ; status : Status.t
  ; wire : Wire.Request.t
  ; request : Request.t
  ; result : Wire.Result_code.t
  }

let%test_unit "a refused command reports the status-derived class and has no side effect" =
  (* The stub refuses every offer. The classes are P3.5's results table applied to the
     status fields the HL3 record lists as refusal inputs: not halted gives
     [Active_execution], halted with an engine active gives [Engines_active], RUN with no
     image gives [No_verified_image], and anything else gives [Image_bounds].
     Program-request and RUN refusals are contract-faithful. A refused STOP or ABORT is a
     robustness probe: the real core accepts both whenever it is enabled and out of reset
     (item 4).
  *)
  let t = create "refused commands" in
  t.stub.accept <- (fun _ -> false);
  let busy_engine = { Status.halted_idle with engines_idle = 0; image_valid = 1 } in
  let with_image = { Status.halted_idle with image_valid = 1 } in
  let cases =
    [ { status_name = "executing"
      ; status = Status.running
      ; wire = Load_start { length = 1 }
      ; request = Load_start { length = 1 }
      ; result = Active_execution
      }
    ; { status_name = "executing"
      ; status = Status.running
      ; wire = Write_word { address = 1; word = 2 }
      ; request = Load_write { address = 1; data = 2 }
      ; result = Active_execution
      }
    ; { status_name = "executing"
      ; status = Status.running
      ; wire = Read_word { address = 0 }
      ; request = Read { address = 0 }
      ; result = Active_execution
      }
    ; { status_name = "executing"
      ; status = Status.running
      ; wire = Run
      ; request = Run
      ; result = Active_execution
      }
    ; { status_name = "halted, engine active"
      ; status = busy_engine
      ; wire = Verify_word { address = 3; expected = 4 }
      ; request = Verify { address = 3; expected = 4 }
      ; result = Engines_active
      }
    ; { status_name = "halted, engine active"
      ; status = busy_engine
      ; wire = Run
      ; request = Run
      ; result = Engines_active
      }
    ; { status_name = "halted, no image"
      ; status = Status.halted_idle
      ; wire = Run
      ; request = Run
      ; result = No_verified_image
      }
    ; { status_name = "halted, no image"
      ; status = Status.halted_idle
      ; wire = Load_complete
      ; request = Load_complete
      ; result = Image_bounds
      }
    ; { status_name = "halted, no image"
      ; status = Status.halted_idle
      ; wire = Write_word { address = 5; word = 6 }
      ; request = Load_write { address = 5; data = 6 }
      ; result = Image_bounds
      }
    ; { status_name = "halted, verified image"
      ; status = with_image
      ; wire = Run
      ; request = Run
      ; result = Image_bounds
      }
    ; { status_name = "robustness: STOP refused while halted"
      ; status = Status.halted_idle
      ; wire = Stop
      ; request = Stop
      ; result = Image_bounds
      }
    ; { status_name = "robustness: ABORT refused while executing"
      ; status = Status.running
      ; wire = Abort
      ; request = Abort
      ; result = Active_execution
      }
    ]
  in
  List.iteri cases ~f:(fun index case ->
    set_status t case.status;
    let tag = 0x20 + index in
    let exchange = transact t ~tag case.wire in
    let what =
      sprintf
        "%s: %s"
        case.status_name
        (Sexp.to_string [%sexp (case.request : Request.t)])
    in
    expect_response
      t
      what
      ~expected:(response ~tag (Wire.Request.command case.wire) case.result)
      exchange.response;
    expect_offered_once t exchange case.request ~accepted:false;
    expect_int
      t
      (what ^ ": a refusal is answered at once")
      ~expected:
        (exchange.request_deselected
         + Latency.offer_after_deselect
         + Latency.ready_after_offer)
      exchange.ready;
    check
      t
      ~phase:Post_run
      (what ^ ": no READBACK response follows a refusal")
      [%sexp_of: Core_stub.Response.t list]
      [%equal: Core_stub.Response.t list]
      ~expected:[]
      (responses ~since:exchange.started t));
  check
    t
    ~phase:Post_run
    "no refused command has an accepted side effect"
    [%sexp_of: Core_stub.Offer.t list]
    [%equal: Core_stub.Offer.t list]
    ~expected:[]
    (accepted t)
;;

let%test_unit "VERIFY reports a mismatch with the actual word; READ ignores the match \
               flag"
  =
  (* Contract-faithful. The stub drives the match flag low for READ, where it is
     meaningless (see [Core_stub]).
  *)
  let t = create "verify mismatch" in
  t.stub.memory.(0) <- 0xbeef;
  let exchange = transact t ~tag:0x43 (Verify_word { address = 0; expected = 0xcafe }) in
  expect_response
    t
    "VERIFY mismatch carries the actual word"
    ~expected:
      (response ~tag:0x43 Verify_word ~payload:(Word 0xbeef) Verification_mismatch)
    exchange.response;
  expect_offered_once
    t
    exchange
    (Verify { address = 0; expected = 0xcafe })
    ~accepted:true;
  let exchange = transact t ~tag:0x44 (Read_word { address = 0 }) in
  expect_response
    t
    "READ with a low match flag"
    ~expected:(response ~tag:0x44 Read_word ~payload:(Word 0xbeef) Complete)
    exchange.response;
  check
    t
    ~phase:Post_run
    "the READ response carried a low match flag"
    [%sexp_of: bool list]
    [%equal: bool list]
    ~expected:[ false ]
    (List.map (responses ~since:exchange.started t) ~f:(fun r -> r.matches))
;;

let%test_unit "a selected request may pause for a long finite time between and within \
               bits"
  =
  (* Contract-faithful. P3.5 has no inactivity timeout; ten thousand cycles is a long
     finite pause, not a proof of an unbounded one.
  *)
  let t = create "request pause" in
  let pause = 10_000 in
  let request = Wire.Request.Write_word { address = 0x42; word = 0xa1b2 } in
  let frame = encode ~tag:0x31 request in
  let started = t.cycle in
  begin_frame t;
  send t (String.prefix frame 3);
  hold t pause;
  send t (String.sub frame ~pos:3 ~len:2) ~extra_bits:3 ~extra_byte:frame.[5];
  hold t pause;
  send_rest_of_byte t frame.[5] ~bits:3;
  (* The last bit of byte 6 holds LCLK high for the pause. *)
  send t "" ~extra_bits:7 ~extra_byte:frame.[6];
  let timing = t.timing in
  set_timing t { timing with clock_high = pause };
  send_rest_of_byte t frame.[6] ~bits:7;
  set_timing t timing;
  send t (String.drop_prefix frame 7);
  let request_deselected = end_frame t in
  hold t t.timing.deselect_gap;
  let exchange =
    receive
      t
      ~started
      ~request_deselected
      ~expected:(Wire.Request.correlation ~tag:0x31 request)
  in
  expect_response
    t
    "paused WRITE"
    ~expected:(response ~tag:0x31 Write_word Complete)
    exchange.response;
  expect_offered_once
    t
    exchange
    (Load_write { address = 0x42; data = 0xa1b2 })
    ~accepted:true
;;

let%test_unit "asymmetric and slower whole-cycle host timing keeps the same offer timing" =
  (* Contract-faithful. These are whole-cycle 4/5, 5/4, and slower hosts inside the P3.5
     envelope. The peer's all-phase and 3/3 or 1/1 sweeps are asynchronous and stay
     RTL-only.
  *)
  let slow =
    { Timing.clock_low = 9
    ; clock_high = 13
    ; select_lead = 7
    ; select_trail = 6
    ; deselect_gap = 11
    }
  in
  List.iter
    [ "4/5", { Timing.envelope with clock_high = 5 }
    ; "5/4", { Timing.envelope with clock_low = 5 }
    ; "slow", slow
    ]
    ~f:(fun (name, timing) ->
      let t = create ~timing ("host timing " ^ name) in
      expect_info_works t ~tag:0x10 ("INFO at " ^ name);
      let exchange = transact t ~tag:0x11 (Write_word { address = 1; word = 0x0203 }) in
      expect_response
        t
        ("WRITE at " ^ name)
        ~expected:(response ~tag:0x11 Write_word Complete)
        exchange.response;
      expect_offered_once
        t
        exchange
        (Load_write { address = 1; data = 0x0203 })
        ~accepted:true;
      expect_int
        t
        ("WRITE at " ^ name ^ ": LRDY one cycle after the offer")
        ~expected:
          (exchange.request_deselected
           + Latency.offer_after_deselect
           + Latency.ready_after_offer)
        exchange.ready)
;;

let%test_unit "a selected response may pause for a long finite time and resume" =
  (* Contract-faithful. The pause is inside the payload, once after a fall with LCLK low
     and once after a sample with LCLK high.
  *)
  let t = create "response pause" in
  let status =
    { Status.halted_idle with image_valid = 1; image_length = 7; pc = 0x1234 }
  in
  let expected : Wire.Status.t =
    { flags = [ Enabled; Halted; Engines_idle; Image_valid ]
    ; image_length = 7
    ; words_written = 0
    ; words_verified = 0
    ; pc = 0x1234
    ; fault_kind = No_fault
    ; phase = Halted
    }
  in
  set_status t status;
  List.iteri [ false; true ] ~f:(fun index clock_high ->
    let tag = 0x20 + index in
    let pause = { Pause.after_bits = 77; cycles = 10_000; clock_high } in
    let exchange = transact t ~tag ~pause Status in
    expect_response
      t
      (sprintf "STATUS paused with LCLK %s" (if clock_high then "high" else "low"))
      ~expected:(response ~tag Status ~payload:(Status expected) Complete)
      exchange.response)
;;

let%test_unit "an abandoned partial read replays from byte zero without re-offering" =
  (* Contract-faithful. RUN is the side-effecting command the peer uses for replay. *)
  let t = create "partial read replay" in
  set_status t { Status.halted_idle with image_valid = 1 };
  let started = t.cycle in
  let request_deselected = send_frame t (encode ~tag:0x75 Run) in
  let ready = wait_ready t ~since:request_deselected in
  let prefix, deselected = read_prefix t ~bits:24 in
  expect_retained t ~deselected ~cycles:200;
  let exchange =
    receive
      t
      ~started
      ~request_deselected
      ~expected:(Wire.Request.correlation ~tag:0x75 Run)
  in
  expect_response
    t
    "replayed RUN"
    ~expected:(response ~tag:0x75 Run Complete)
    exchange.response;
  check
    t
    ~phase:Host_sample
    "the abandoned read saw the first three bytes of the same frame"
    [%sexp_of: string]
    String.equal
    ~expected:(hex (String.prefix exchange.bytes 3))
    (hex prefix);
  expect_int t "LRDY rose once, before the abandoned read" ~expected:ready exchange.ready;
  expect_offered_once t exchange Run ~accepted:true;
  expect_quiet t 200 "RUN is not offered again after replay and commit"
;;

let%test_unit "final-bit validation rejection retains the response; a later read commits" =
  (* Contract-faithful. As in the peer, the host rejects a frame it has received in full:
     it deselects with the final LCLK still high, so the final fall is absent. It rejects
     twice before committing.
  *)
  let t = create "reject then commit" in
  set_status t { Status.halted_idle with image_valid = 1 };
  let expected = Wire.Request.correlation ~tag:0x76 Run in
  let started = t.cycle in
  let request_deselected = send_frame t (encode ~tag:0x76 Run) in
  ignore (wait_ready t ~since:request_deselected : int);
  let reject () =
    let read = read_response t ~expected ~decide:(fun _ -> Replay) () in
    check
      t
      ~phase:Host_sample
      "the rejected frame was complete and valid; the rejection is the host's"
      [%sexp_of: (Wire.Response.t, Wire.Response.Decode_error.t) Result.t]
      [%equal: (Wire.Response.t, Wire.Response.Decode_error.t) Result.t]
      ~expected:(Ok (response ~tag:0x76 Run Complete))
      read.decoded;
    expect_retained t ~deselected:read.deselected ~cycles:200;
    read.bytes
  in
  let first = reject () in
  let second = reject () in
  let rejected = [ first; second ] in
  let exchange = receive t ~started ~request_deselected ~expected in
  check
    t
    ~phase:Host_sample
    "every read of the retained response returns the same frame"
    [%sexp_of: string list]
    [%equal: string list]
    ~expected:[ hex exchange.bytes; hex exchange.bytes ]
    (List.map rejected ~f:hex);
  expect_offered_once t exchange Run ~accepted:true;
  expect_quiet t 200 "RUN is offered once across two rejections and a commit"
;;

let%test_unit "a response selection arms only after four deselected cycles and with LRDY \
               high"
  =
  (* Characterization of the unsplit loader, fixed for HL4b. Each host here breaks the
     P3.5 envelope on purpose, by selecting too soon, to find the device-side boundary. A
     selection LSEL_N-low in cycle n is seen in cycle n + 2 and arms only if the loader
     has counted four deselected cycles and LRDY is high in that cycle. An armed read
     returns magic [0x5a] as its first byte; an ignored one returns zeros. Either way the
     retained response is then read in full.
  *)
  let first_byte t = fst (read_prefix t ~bits:8) in
  List.iter
    [ 3, "\x00"; 4, "\x5a" ]
    ~f:(fun (gap, expected) ->
      let t = create (sprintf "INFO read after a %d-cycle gap" gap) in
      let started = t.cycle in
      begin_frame t;
      send t (encode ~tag:0x51 Info);
      let request_deselected = end_frame t in
      hold t gap;
      check
        t
        ~phase:Host_sample
        (sprintf "first response byte after a %d-cycle deselected gap" gap)
        [%sexp_of: string]
        String.equal
        ~expected:(hex expected)
        (hex (first_byte t));
      let exchange =
        receive
          t
          ~started
          ~request_deselected
          ~expected:(Wire.Request.correlation ~tag:0x51 Info)
      in
      expect_response
        t
        "INFO after the probe"
        ~expected:(response ~tag:0x51 Info ~payload:info_payload Complete)
        exchange.response);
  (* Robustness probe: a READ response delayed by 20 cycles makes the LRDY rise late
     enough that only the LRDY condition decides.
  *)
  let delay = 20 in
  List.iter
    [ 3, "\x00"; 2, "\x5a" ]
    ~f:(fun (early, expected) ->
      let t = create (sprintf "READ selected %d cycles before LRDY" early) in
      t.stub.readback_completion <- Delayed delay;
      t.stub.memory.(4) <- 0x4444;
      let started = t.cycle in
      begin_frame t;
      send t (encode ~tag:0x52 (Read_word { address = 4 }));
      let request_deselected = end_frame t in
      let ready =
        request_deselected
        + Latency.offer_after_deselect
        + Latency.readback_after_offer
        + delay
        + Latency.ready_after_completion
      in
      hold t (ready - early - t.cycle);
      check
        t
        ~phase:Host_sample
        (sprintf "first response byte, selected %d cycles before LRDY" early)
        [%sexp_of: string]
        String.equal
        ~expected:(hex expected)
        (hex (first_byte t));
      let exchange =
        receive
          t
          ~started
          ~request_deselected
          ~expected:(Wire.Request.correlation ~tag:0x52 (Read_word { address = 4 }))
      in
      expect_int
        t
        "LRDY rose where the delayed response put it"
        ~expected:ready
        exchange.ready;
      expect_response
        t
        "READ after the probe"
        ~expected:(response ~tag:0x52 Read_word ~payload:(Word 0x4444) Complete)
        exchange.response)
;;
