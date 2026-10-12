(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "command_dispatch_response_tests.ml" *)
(* HL4c: [Command_dispatch]'s immediate responses, INFO and STATUS contents and sampling,
   refusal classification, framing-error responses, and correlation.

   Refusal classes are written from the P3.5 result table: executing (not halted) is 0x20,
   an active engine 0x21, RUN without a verified image 0x22, and anything else 0x23. The
   stub's [accept] decides refusals; the status it reports is what the dispatcher
   classifies.
*)

open! Core
open! Hardcaml_protemu
open! Command_dispatch_testbench

(* The P3.5 INFO descriptor, written from the record's table. *)
let info_payload : Wire.Response.Payload.t =
  Info
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

let%test_unit "INFO reports the fixed descriptor whatever the status" =
  let t = create "INFO" in
  List.iter
    [ 0x00, Status.halted_idle
    ; 0x80, Status.running
    ; 0xff, Status.cleaned Status.running
    ]
    ~f:(fun (tag, status) ->
      set_status t status;
      let from = t.cycle in
      let h = handoff t (Handoff.request ~tag Info) in
      run t 5;
      expect_publications
        t
        ~from
        "INFO"
        [ h + 1, response ~tag Info ~payload:info_payload Complete ]);
  (* The raw frame for tag 0x5c, with its CRC computed independently of both the hardware
     and [Wire]: CRC-8 (polynomial 0x07, initial 0) of the 20 bytes before it.
  *)
  let from = t.cycle in
  let h = handoff t (Handoff.request ~tag:0x5c Info) in
  run t 2;
  let body =
    [ 0x5a
    ; 0x10
    ; 0x5c
    ; 0x00
    ; 0x00
    ; 0x0d
    ; 0x00
    ; 0x01
    ; 0x00
    ; 0x01
    ; 0x01
    ; 0x7f
    ; 0x00
    ; 0x10
    ; 0x00
    ; 0x00
    ; 0x01
    ; 0x04
    ; 0x00
    ; 0x08
    ]
  in
  let crc =
    List.fold body ~init:0 ~f:(fun crc byte ->
      List.fold (List.range 0 8) ~init:(crc lxor byte) ~f:(fun crc _ ->
        if crc land 0x80 <> 0
        then (crc lsl 1) lxor 0x07 land 0xff
        else (crc lsl 1) land 0xff))
  in
  expect_published_bytes
    t
    ~cycle:(h + 1)
    "INFO raw bytes"
    (hex (String.of_char_list (List.map (body @ [ crc ]) ~f:Char.of_int_exn)))
;;

let%test_unit "STATUS reports the status observed in its dispatch cycle" =
  let t = create "STATUS" in
  (* A different status in the handoff cycle and after the dispatch cycle; only the
     dispatch cycle's is reported.
  *)
  let check_status ~tag status (expected : Wire.Status.t) =
    set_status t Status.running;
    let from = t.cycle in
    let h = handoff t (Handoff.request ~tag Status) in
    set_status t status;
    run t 1;
    set_status t { Status.halted_idle with image_length = 0x0ab; phase = 3 };
    run t 5;
    expect_publications
      t
      ~from
      (sprintf "STATUS %02x" tag)
      [ h + 1, response ~tag Status ~payload:(Status expected) Complete ]
  in
  check_status
    ~tag:0x01
    Status.halted_idle
    { flags = [ Enabled; Halted; Engines_idle ]
    ; image_length = 0
    ; words_written = 0
    ; words_verified = 0
    ; pc = 0
    ; fault_kind = No_fault
    ; phase = Halted
    };
  check_status
    ~tag:0x02
    Status.running
    { flags = [ Enabled; Image_valid; Execution_active; Pin_output_enabled; Pin_claimed ]
    ; image_length = 0
    ; words_written = 0
    ; words_verified = 0
    ; pc = 0
    ; fault_kind = No_fault
    ; phase = Mechanism_wait
    };
  (* Every flag, the 9-bit counters at their maximum, a fault, and the fault phase. *)
  check_status
    ~tag:0x03
    { halted = 1
    ; engines_idle = 1
    ; image_valid = 1
    ; load_active = 1
    ; image_length = 0x100
    ; words_written = 0x1ff
    ; words_verified = 0x0ff
    ; verification_failed = 1
    ; fetch_fault = 1
    ; execution_active = 1
    ; normal_halt = 1
    ; execution_fault = 1
    ; fault_kind = 9
    ; pc = 0x0_1234
    ; phase = 6
    ; pin_oe = 0x80
    ; software_claim = 0x01
    ; engine_claim = 0x00
    }
    { flags = Wire.Status.Flag.all
    ; image_length = 0x100
    ; words_written = 0x1ff
    ; words_verified = 0x0ff
    ; pc = 0x1234
    ; fault_kind = Mechanism_protocol
    ; phase = Fault
    };
  (* The PC is 17 bits; STATUS carries its low 16 (the existing projection). *)
  check_status
    ~tag:0x04
    { Status.halted_idle with pc = 0x1_fedc; fault_kind = 1; engine_claim = 0x40 }
    { flags = [ Enabled; Halted; Engines_idle; Pin_claimed ]
    ; image_length = 0
    ; words_written = 0
    ; words_verified = 0
    ; pc = 0xfedc
    ; fault_kind = Invalid_base
    ; phase = Halted
    };
  (* The raw payload for the 17-bit PC case: bytes 8 and 9 are dc fe. *)
  set_status t { Status.halted_idle with pc = 0x1_fedc };
  let h = handoff t (Handoff.request ~tag:0x05 Status) in
  run t 2;
  let s = observed t (h + 1) in
  check
    t
    ~phase:Post_run
    "STATUS payload bytes"
    [%sexp_of: string]
    [%equal: string]
    ~expected:"07 00 00 00 00 00 00 00 dc fe 00 00"
    (hex (String.sub s.frame ~pos:7 ~len:12))
;;

let%test_unit "accepted immediate operations report Complete; STOP reports \
               Accepted_pending, including when already halted"
  =
  let t = create "accepted immediate operations" in
  let expect ~tag request result =
    let from = t.cycle in
    let h = handoff t (Handoff.request ~tag request) in
    run t 5;
    expect_publications
      t
      ~from
      (Sexp.to_string [%sexp (request : Wire.Request.t)])
      [ h + 1, response ~tag (Wire.Request.command request) result ]
  in
  expect ~tag:0x10 (Load_start { length = 4 }) Complete;
  expect ~tag:0x11 (Write_word { address = 0; word = 0xffff }) Complete;
  expect ~tag:0x12 Load_complete Complete;
  expect ~tag:0x13 Run Complete;
  (* Already halted, then executing: the same result, which only means accepted. *)
  expect ~tag:0x14 Stop Accepted_pending;
  set_status t Status.running;
  expect ~tag:0x15 Stop Accepted_pending
;;

let%test_unit "a refused command reports the class of the status observed in its \
               dispatch cycle"
  =
  let t = create "refusal classes" in
  t.stub.accept <- (fun _ -> false);
  let engines_busy = { Status.halted_idle with engines_idle = 0 } in
  let image_valid = { Status.halted_idle with image_valid = 1 } in
  let requests : Wire.Request.t list =
    [ Load_start { length = 4 }
    ; Write_word { address = 1; word = 2 }
    ; Read_word { address = 3 }
    ; Verify_word { address = 4; expected = 5 }
    ; Load_complete
    ; Run
    ]
  in
  let expect ~tag status request (result : Wire.Result_code.t) =
    (* A different status in the handoff cycle and after dispatch. *)
    set_status t (Status.cleaned Status.running);
    let from = t.cycle in
    let h = handoff t (Handoff.request ~tag request) in
    set_status t status;
    run t 1;
    set_status t Status.halted_idle;
    run t 5;
    let what =
      Sexp.to_string [%sexp (request : Wire.Request.t), (result : Wire.Result_code.t)]
    in
    check
      t
      ~phase:Post_run
      (what ^ ": exactly one offer, refused")
      [%sexp_of: (int * bool) list]
      [%equal: (int * bool) list]
      ~expected:[ h + 1, false ]
      (offers ~since:from t
       |> List.map ~f:(fun (o : Core_stub.Offer.t) -> o.cycle, o.accepted));
    expect_publications
      t
      ~from
      what
      [ h + 1, response ~tag (Wire.Request.command request) result ];
    expect_busy t ~from what [ h + 1 ]
  in
  List.iteri requests ~f:(fun index request ->
    let tag = 0x20 + index in
    expect ~tag Status.running request Active_execution;
    (* Executing but reporting engines idle: still "execution active". *)
    expect ~tag { Status.running with engines_idle = 1 } request Active_execution;
    expect ~tag engines_busy request Engines_active;
    expect
      ~tag
      Status.halted_idle
      request
      (match request with
       | Run -> No_verified_image
       | _ -> Image_bounds);
    expect ~tag image_valid request Image_bounds)
;;

let%test_unit "robustness: a refused STOP or ABORT reports the refusal class; the real \
               core accepts both whenever enabled"
  =
  let t = create "robustness: refused STOP and ABORT" in
  t.stub.accept
  <- (function
       | Stop | Abort -> false
       | _ -> true);
  set_status t Status.running;
  List.iter
    [ Wire.Request.Stop, 0x71; Abort, 0x72 ]
    ~f:(fun (request, tag) ->
      let from = t.cycle in
      let h = handoff t (Handoff.request ~tag request) in
      run t 20;
      let what = Sexp.to_string [%sexp (request : Wire.Request.t)] in
      expect_publications
        t
        ~from
        what
        [ h + 1, response ~tag (Wire.Request.command request) Active_execution ];
      (* A refused ABORT does not wait for cleanup. *)
      expect_busy t ~from what [ h + 1 ])
;;

let%test_unit "robustness: acceptance alone decides; the rejected signals are not read" =
  let t = create "robustness: rejected signals ignored" in
  (* Both decisions low for a refusal, and both high for an acceptance: incoherent under
     control_port.ml item 3, used only to show which signal decides.
  *)
  t.stub.rejected <- Some false;
  t.stub.accept <- (fun _ -> false);
  let from = t.cycle in
  let h = handoff t (Handoff.request ~tag:0x73 Run) in
  run t 5;
  expect_publications
    t
    ~from
    "accepted low, rejected low"
    [ h + 1, response ~tag:0x73 Run No_verified_image ];
  t.stub.rejected <- Some true;
  t.stub.accept <- (fun _ -> true);
  let from = t.cycle in
  let h = handoff t (Handoff.request ~tag:0x74 Run) in
  run t 5;
  expect_publications
    t
    ~from
    "accepted high, rejected high"
    [ h + 1, response ~tag:0x74 Run Complete ];
  let from = t.cycle in
  let h = handoff t (Handoff.request ~tag:0x75 (Read_word { address = 9 })) in
  run t 5;
  expect_publications
    t
    ~from
    "READ accepted high, rejected high"
    [ h + 3, response ~tag:0x75 Read_word ~payload:(Word (t.stub.memory 9)) Complete ]
;;

let%test_unit "framing errors publish in the handoff cycle, echo tag and command, and \
               never dispatch"
  =
  let t = create "framing errors" in
  (* Every result [Frame_rx] can present for a failed frame, with a known and an unknown
     command byte echoed raw.
  *)
  List.iter
    [ Wire.Result_code.Bad_magic; Bad_version; Bad_length; Bad_crc; Incomplete ]
    ~f:(fun result ->
      List.iter
        [ 0x01, 0x6e; 0x7f, 0x6f; 0x22, 0x00; 0x11, 0xff ]
        ~f:(fun (command, tag) ->
          let from = t.cycle in
          let h =
            handoff
              t
              (Handoff.error result ~tag ~command ~payload_length:4 ~payload:0x0000_0100)
          in
          run t 10;
          let what =
            sprintf
              "%s, command %02x"
              (Sexp.to_string [%sexp (result : Wire.Result_code.t)])
              command
          in
          expect_publications
            t
            ~from
            what
            [ h + Latency.framing_error, raw_response ~tag ~command result ];
          expect_offers t ~since:from what [];
          expect_busy t ~from what []))
;;

let%test_unit "a framing error without an echo zeroes tag and command, whatever the \
               retained bytes"
  =
  let t = create "zero echo" in
  (* Fewer than four bytes: [Frame_rx] may still hold a tag byte; three bytes of an INFO
     with tag 0x44 leave the tag register set and the command zero.
  *)
  List.iter
    [ 0x44, 0x00; 0x00, 0x00; 0xff, 0xff ]
    ~f:(fun (tag, command) ->
      let from = t.cycle in
      let h = handoff t (Handoff.error Incomplete ~echo_valid:false ~tag ~command) in
      run t 5;
      expect_publications
        t
        ~from
        "no echo"
        [ h, raw_response ~tag:0 ~command:0 Incomplete ]);
  (* Overrun has no echo only when the header never arrived; with it, the echo stays. *)
  let from = t.cycle in
  let h =
    handoff t (Handoff.error Bad_length ~echo_valid:false ~tag:0x00 ~command:0x00)
  in
  run t 5;
  expect_publications
    t
    ~from
    "zero prefix"
    [ h, raw_response ~tag:0 ~command:0 Bad_length ];
  (* An INFO with tag 0 and an echoless error are distinguishable only by the result. *)
  let from = t.cycle in
  let h = handoff t (Handoff.request ~tag:0x00 Info) in
  run t 5;
  expect_publications
    t
    ~from
    "INFO tag 0"
    [ h + 1, response ~tag:0x00 Info ~payload:info_payload Complete ]
;;

let%test_unit "every response carries the handed-off tag and command, for consecutive \
               distinct requests"
  =
  let t = create "correlation" in
  let requests : (int * Wire.Request.t) list =
    [ 0x00, Status
    ; 0xff, Run
    ; 0x80, Load_start { length = 1 }
    ; 0x7f, Stop
    ; 0x01, Write_word { address = 2; word = 3 }
    ; 0xfe, Load_complete
    ; 0x55, Read_word { address = 0x80 }
    ; 0xaa, Abort
    ; 0x33, Verify_word { address = 0x80; expected = t.stub.memory 0x80 }
    ; 0xcc, Info
    ]
  in
  List.iter requests ~f:(fun (tag, request) ->
    let from = t.cycle in
    ignore (handoff t (Handoff.request ~tag request) : int);
    run t 8;
    let expected =
      match request with
      | Info -> [ response ~tag Info ~payload:info_payload Complete ]
      | _ -> []
    in
    match publications t ~from ~until:t.cycle with
    | [ (_, Response r) ] ->
      check
        t
        ~phase:Post_run
        "correlation"
        [%sexp_of: int * int]
        [%equal: int * int]
        ~expected:(tag, Wire.Command.to_int (Wire.Request.command request))
        (r.tag, r.command);
      if not (List.is_empty expected)
      then expect_publications t ~from "INFO" [ from + 1, List.hd_exn expected ]
    | other ->
      fail
        t
        ~phase:Post_run
        "exactly one decodable publication per request"
        ~actual:[%sexp (other : (int * Published.t) list)])
;;
