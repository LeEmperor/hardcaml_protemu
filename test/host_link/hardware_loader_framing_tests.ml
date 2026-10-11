(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "hardware_loader_framing_tests.ml" *)
(* HL4a: request framing, parser recovery, and device bounds at the composed
   [Host_link]'s serial pins.

   The stub accepts every offer, so any request that reached the core would show as an
   accepted offer; every malformed case requires none. Malformed frames come from
   [Hardware_loader_testbench.Raw], never from the codec. Expected results and echoed
   correlation are written out from the P3.5 record's request framing rules. Each
   malformed case is followed by a legal INFO with a fresh tag, which must succeed after
   the ordinary inter-frame gap.
*)

open! Core
open! Hardcaml_protemu
open! Hardware_loader_testbench

let write = Wire.Command.to_int Write_word
let load_start = Wire.Command.to_int Load_start
let info = Wire.Command.to_int Info

(* Where the loader rejects a frame: at deselect validation, before any dispatch cycle, or
   in the dispatch cycle without offering.
*)
module Stage = struct
  type t =
    | Validation
    | Dispatch

  let ready_after_deselect = function
    | Validation -> Latency.validation_error_ready
    | Dispatch -> Latency.offer_after_deselect + Latency.ready_after_offer
  ;;
end

(* Sends [frame] as one selection and requires the given error answer at the stage's
   cycle, no offer, and a working legal INFO afterwards.
*)
let expect_rejected
  t
  ~what
  ?(stage = Stage.Validation)
  ?extra_bits
  ?extra_byte
  frame
  ~(echo : Wire.Correlation.t)
  result
  =
  let started = t.cycle in
  let request_deselected = send_frame t ?extra_bits ?extra_byte frame in
  let exchange = receive t ~started ~request_deselected ~expected:echo in
  expect_response
    t
    what
    ~expected:{ tag = echo.tag; command = echo.command; result; payload = Empty }
    exchange.response;
  expect_no_offers t ~since:started (what ^ ": no core request is offered");
  expect_int
    t
    (what ^ ": LRDY rises at the rejecting stage's cycle")
    ~expected:(exchange.request_deselected + Stage.ready_after_deselect stage)
    exchange.ready;
  expect_info_works t ~tag:(0x80 lxor echo.tag) (what ^ ": a later legal INFO works")
;;

let echo ~tag ~command = { Wire.Correlation.tag; command }
let zeroed = echo ~tag:0 ~command:0

let%test_unit "the maximum legal frame dispatches; a twelfth byte latches overrun" =
  let t = create "maximum frame and overrun" in
  let frame = encode ~tag:0x3f (Write_word { address = 0; word = 0xbeef }) in
  expect_int
    t
    "a WRITE_WORD frame is the eleven-byte maximum"
    ~expected:11
    (String.length frame);
  let exchange = transact t ~tag:0x3f (Write_word { address = 0; word = 0xbeef }) in
  expect_response
    t
    "maximum frame"
    ~expected:(response ~tag:0x3f Write_word Complete)
    exchange.response;
  expect_offered_once
    t
    exchange
    (Load_write { address = 0; data = 0xbeef })
    ~accepted:true;
  expect_rejected
    t
    ~what:"one byte after the maximum frame"
    (frame ^ "\x00")
    ~echo:(echo ~tag:0x3f ~command:write)
    Bad_length;
  expect_rejected
    t
    ~what:"thirty bytes, ending in a valid INFO, after the maximum frame"
    (frame ^ Raw.zeros 23 ^ encode ~tag:0x40 Info)
    ~echo:(echo ~tag:0x3f ~command:write)
    Bad_length;
  expect_rejected
    t
    ~what:"a complete frame declaring a five-byte payload is twelve bytes long"
    (Raw.frame ~tag:0x28 ~command:info [ 0x11; 0x22; 0x33; 0x44; 0x55 ])
    ~echo:(echo ~tag:0x28 ~command:info)
    Bad_length;
  expect_rejected
    t
    ~what:"one extra byte after a seven-byte INFO"
    (encode ~tag:0x29 Info ^ "\x5a")
    ~echo:(echo ~tag:0x29 ~command:info)
    Incomplete
;;

let%test_unit "long zero prefixes and valid-looking suffixes cannot dispatch" =
  (* The historical four-bit counter-wrap attack shapes: 15, 16, 32, and 48 zero bytes
     before a valid LOAD_START, and 16 and 32 before a valid WRITE_WORD. Bytes 2 and 3 of
     the prefix are zero, so the echo is tag 0, command 0.
  *)
  let t = create "prefix attacks" in
  List.iter
    [ 15, encode ~tag:0x35 (Load_start { length = 1 })
    ; 16, encode ~tag:0x36 (Load_start { length = 1 })
    ; 32, encode ~tag:0x37 (Load_start { length = 1 })
    ; 48, encode ~tag:0x38 (Load_start { length = 1 })
    ; 16, encode ~tag:0x3d (Write_word { address = 0; word = 0xbeef })
    ; 32, encode ~tag:0x3e (Write_word { address = 0; word = 0xbeef })
    ]
    ~f:(fun (prefix, frame) ->
      expect_rejected
        t
        ~what:(sprintf "%d zero bytes before %s" prefix (hex frame))
        (Raw.zeros prefix ^ frame)
        ~echo:zeroed
        Bad_length)
;;

let%test_unit "bad magic, version, CRC, command, and payload length are rejected" =
  let t = create "header errors" in
  expect_rejected
    t
    ~what:"LOAD_START with its CRC's top bit flipped"
    (Raw.flip_last (encode ~tag:0x21 (Load_start { length = 1 })) ~mask:0x80)
    ~echo:(echo ~tag:0x21 ~command:load_start)
    Bad_crc;
  expect_rejected
    t
    ~what:"magic 0x00"
    (Raw.frame ~magic:0x00 ~tag:0x24 ~command:info [])
    ~echo:(echo ~tag:0x24 ~command:info)
    Bad_magic;
  expect_rejected
    t
    ~what:"version 0x20"
    (Raw.frame ~version:0x20 ~tag:0x25 ~command:info [])
    ~echo:(echo ~tag:0x25 ~command:info)
    Bad_version;
  List.iter [ 0xff; 0x15; 0x02 ] ~f:(fun command ->
    expect_rejected
      t
      ~what:(sprintf "unknown command 0x%02x" command)
      ~stage:Dispatch
      (Raw.frame ~tag:0x26 ~command [])
      ~echo:(echo ~tag:0x26 ~command)
      Bad_command);
  (* Complete frames with a correct CRC and a payload length at most four that is not the
     command's one legal length.
  *)
  List.iteri
    [ Wire.Command.Info, 2
    ; Status, 4
    ; Load_start, 0
    ; Load_start, 4
    ; Write_word, 3
    ; Write_word, 2
    ; Read_word, 4
    ; Verify_word, 2
    ; Load_complete, 2
    ; Run, 4
    ; Stop, 2
    ; Abort, 1
    ]
    ~f:(fun index (command, length) ->
      let tag = 0x90 + index in
      let command = Wire.Command.to_int command in
      expect_rejected
        t
        ~what:(sprintf "command 0x%02x with a %d-byte payload" command length)
        ~stage:Dispatch
        (Raw.frame ~tag ~command (List.init length ~f:(fun byte -> 0x10 + byte)))
        ~echo:(echo ~tag ~command)
        Bad_length)
;;

let%test_unit "device bounds refuse lengths and addresses without an offer" =
  (* Addresses and lengths stay 16-bit until checked, so none of these is narrowed into a
     legal RAM address.
  *)
  let t = create "device bounds" in
  List.iteri
    [ Wire.Request.Load_start { length = 0 }
    ; Load_start { length = 257 }
    ; Load_start { length = 0xffff }
    ; Write_word { address = 256; word = 1 }
    ; Write_word { address = 0x8000; word = 1 }
    ; Read_word { address = 256 }
    ; Verify_word { address = 0xffff; expected = 0 }
    ]
    ~f:(fun index request ->
      let tag = 0xa0 + index in
      let exchange = transact t ~tag request in
      let what = Sexp.to_string [%sexp (request : Wire.Request.t)] in
      expect_response
        t
        what
        ~expected:(response ~tag (Wire.Request.command request) Image_bounds)
        exchange.response;
      expect_no_offers t ~since:exchange.started (what ^ ": no core request is offered");
      expect_int
        t
        (what ^ ": the refusal is ready one cycle after the dispatch cycle")
        ~expected:(exchange.request_deselected + Stage.ready_after_deselect Dispatch)
        exchange.ready)
;;

let%test_unit "truncated frames and partial bytes are incomplete, echoed from four bytes" =
  (* P3.5: all four magic/version/tag/command bytes echo tag and command; fewer zero both.
     A partial final byte, a missing payload or CRC, and a nonzero high length byte are
     all [Incomplete].
  *)
  let t = create "truncation" in
  let frame = encode ~tag:0x22 (Write_word { address = 0; word = 0x1234 }) in
  let echoed = echo ~tag:0x22 ~command:write in
  List.iter
    [ "an empty selection", 0, 0, zeroed
    ; "one byte", 1, 0, zeroed
    ; "three bytes", 3, 0, zeroed
    ; "three bytes and five bits", 3, 5, zeroed
    ; "four bytes", 4, 0, echoed
    ; "four bytes and three bits", 4, 3, echoed
    ; "the header only", 6, 0, echoed
    ; "the header and half the payload", 8, 0, echoed
    ; "no CRC", 10, 0, echoed
    ; "no CRC, with seven of its bits", 10, 7, echoed
    ]
    ~f:(fun (what, bytes, bits, echo) ->
      expect_rejected
        t
        ~what:("WRITE_WORD truncated to " ^ what)
        (String.prefix frame bytes)
        ~extra_bits:bits
        ~extra_byte:(if bytes < String.length frame then frame.[bytes] else '\xff')
        ~echo
        Incomplete);
  expect_rejected
    t
    ~what:"a complete WRITE_WORD followed by three bits"
    frame
    ~extra_bits:3
    ~echo:echoed
    Incomplete;
  expect_rejected
    t
    ~what:"INFO with a nonzero high length byte and a seven-byte transfer"
    (Raw.frame ~payload_length:0x100 ~tag:0x2a ~command:info [])
    ~echo:(echo ~tag:0x2a ~command:info)
    Incomplete
;;

let%test_unit "a zeroed echo can match INFO with tag 0 but is still an error" =
  (* The HL2 record's recorded ambiguity. Two bytes of an INFO with tag 0 get a zeroed
     echo that [decode_correlated] accepts as INFO/tag 0, and its result is still
     [Incomplete]: correlation equality does not prove the header arrived. For tag 0x33
     the same answer is a correlation mismatch, which the host replays. The test then
     reads it without a correlation check and commits it itself, only to clean up; that is
     not a recovery policy, and no command is retried.
  *)
  let t = create "zeroed echo" in
  let info_tag_0 = encode ~tag:0 Info in
  expect_rejected
    t
    ~what:"INFO tag 0 truncated to two bytes"
    (String.prefix info_tag_0 2)
    ~echo:zeroed
    Incomplete;
  let expected = Wire.Request.correlation ~tag:0x33 Info in
  let started = t.cycle in
  let request_deselected = send_frame t (String.prefix (encode ~tag:0x33 Info) 2) in
  ignore (wait_ready t ~since:request_deselected : int);
  let read = read_response t ~expected ~decide:commit_if_valid () in
  check
    t
    ~phase:Host_sample
    "a zeroed echo for tag 0x33 is a correlation mismatch and is replayed"
    [%sexp_of: Outcome.t * (Wire.Response.t, Wire.Response.Decode_error.t) Result.t]
    [%equal: Outcome.t * (Wire.Response.t, Wire.Response.Decode_error.t) Result.t]
    ~expected:
      ( Replay
      , Error
          (Correlation_mismatch
             { expected
             ; response = { tag = 0; command = 0; result = Incomplete; payload = Empty }
             }) )
    (read.outcome, read.decoded);
  expect_retained t ~deselected:read.deselected ~cycles:100;
  let exchange = receive t ~started ~request_deselected ~expected:zeroed in
  expect_response
    t
    "the retained zeroed answer, committed by the test"
    ~expected:{ tag = 0; command = 0; result = Incomplete; payload = Empty }
    exchange.response;
  expect_no_offers t ~since:started "a truncated INFO offers nothing";
  expect_info_works t ~tag:0x34 "INFO after the zeroed answer"
;;

(* The peer's replayable malformed generator: a 32-bit LFSR with taps 31, 21, 1, and 0,
   seeded with 20260921. Trial n builds an INFO tagged with the state's low byte and a CRC
   inverted in bit 7 when n is odd, then applies mutation n mod 4.
*)
let next_state state =
  let tap bit = (state lsr bit) land 1 in
  (state lsl 1) land 0xffff_ffff lor (tap 31 lxor tap 21 lxor tap 1 lxor tap 0)
;;

let%test_unit "the peer's sixteen malformed trials at seed 20260921 are rejected" =
  let t = create "seeded malformed trials" in
  let state = ref 20260921 in
  for trial = 0 to 15 do
    state := next_state !state;
    let tag = !state land 0xff in
    let base = encode ~tag Info in
    let base = if trial land 1 = 1 then Raw.flip_last base ~mask:0x80 else base in
    let frame, result, mutation =
      match trial % 4 with
      | 0 -> Raw.flip_last base ~mask:0x80, Wire.Result_code.Bad_crc, "CRC bit 7 inverted"
      | 1 -> String.prefix base 6, Incomplete, "CRC missing"
      | 2 ->
        ( base ^ String.of_char (Char.of_int_exn ((!state lsr 8) land 0xff))
        , Incomplete
        , "one extra byte" )
      | _ ->
        ( String.mapi base ~f:(fun index byte -> if index = 5 then '\x01' else byte)
        , Incomplete
        , "high length byte 1" )
    in
    expect_rejected
      t
      ~what:(sprintf "trial %d (tag 0x%02x): %s" trial tag mutation)
      frame
      ~echo:(echo ~tag ~command:info)
      result
  done
;;
