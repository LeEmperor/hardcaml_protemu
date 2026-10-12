(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "wire_tests.ml" *)
(* Fixed-vector coverage for the P3.5 wire definitions and software codec.

   Every expected byte, code and decoded field below is written out from
   docs/p3.5-hardware-loader.md, never computed by [Wire]. CRC bytes came from a separate
   bitwise CRC-8/ATM script written from the same record and checked against the standard
   "123456789" check value. A vector that disagrees with the codec is therefore evidence
   about the codec, not a restatement of it. The only derived checks are the supplementary
   CRC residue at the end.
*)

open! Core
module Wire = Protemu_host_link_wire.Wire
module Command = Wire.Command
module Result_code = Wire.Result_code
module Request = Wire.Request
module Response = Wire.Response
module Decode_error = Wire.Response.Decode_error

(* "a5 10 00" -> the three bytes. *)
let bytes hex =
  String.split hex ~on:' '
  |> List.filter ~f:(Fn.non String.is_empty)
  |> List.map ~f:(fun byte -> Char.of_int_exn (Int.of_string ("0x" ^ byte)))
  |> String.of_char_list
;;

let hex bytes =
  String.to_list bytes
  |> List.map ~f:(fun byte -> sprintf "%02x" (Char.to_int byte))
  |> String.concat ~sep:" "
;;

type decoded = (Response.t, Decode_error.t) Result.t [@@deriving sexp_of, compare]

let response ~tag ~command ~result payload = { Response.tag; command; result; payload }

let decodes frame expected =
  [%test_result: decoded] (Response.decode (bytes frame)) ~expect:(Ok expected)
;;

let rejects frame error =
  [%test_result: decoded] (Response.decode (bytes frame)) ~expect:(Error error)
;;

(* Constants *)

let%test_unit "frame constants match the P3.5 record" =
  [%test_result: int] Wire.Version.byte ~expect:0x10;
  [%test_result: int] Request.magic ~expect:0xa5;
  [%test_result: int] Response.magic ~expect:0x5a;
  [%test_result: int] Request.header_length ~expect:6;
  [%test_result: int] Request.max_payload_length ~expect:4;
  [%test_result: int] Request.min_length ~expect:7;
  [%test_result: int] Request.max_length ~expect:11;
  [%test_result: int] Response.header_length ~expect:7;
  [%test_result: int] Response.max_payload_length ~expect:13;
  [%test_result: int] Response.max_length ~expect:21;
  [%test_result: int] Wire.Info.length ~expect:13;
  [%test_result: int] Wire.Status.length ~expect:12;
  [%test_result: int] Wire.Info.memory_layout_m16 ~expect:1
;;

let%test_unit "CRC-8/ATM parameters and check values" =
  [%test_result: int] Wire.Crc.polynomial ~expect:0x07;
  [%test_result: int] Wire.Crc.initial ~expect:0x00;
  [%test_result: int] Wire.Crc.final_xor ~expect:0x00;
  [%test_result: bool] Wire.Crc.reflected ~expect:false;
  [%test_result: int] (Wire.Crc.compute "123456789") ~expect:0xf4;
  List.iter
    [ "", 0x00; "01", 0x07; "80", 0x89; "ff", 0xf3 ]
    ~f:(fun (data, expect) -> [%test_result: int] (Wire.Crc.compute (bytes data)) ~expect)
;;

(* Each code table is checked in both directions: every listed value encodes to its byte,
   and every byte outside the table decodes to [None].
*)
let check_code_table ~all ~equal ~to_int ~of_int table =
  [%test_result: int] (List.length all) ~expect:(List.length table);
  List.iter table ~f:(fun (value, code) ->
    [%test_result: int] (to_int value) ~expect:code;
    assert (Option.equal equal (of_int code) (Some value)));
  List.init 256 ~f:Fn.id
  |> List.filter ~f:(fun code -> not (List.exists table ~f:(fun (_, c) -> c = code)))
  |> List.iter ~f:(fun code -> assert (Option.is_none (of_int code)))
;;

let%test_unit "command codes" =
  check_code_table
    ~all:Command.all
    ~equal:Command.equal
    ~to_int:Command.to_int
    ~of_int:Command.of_int
    [ Info, 0x00
    ; Status, 0x01
    ; Load_start, 0x10
    ; Write_word, 0x11
    ; Read_word, 0x12
    ; Verify_word, 0x13
    ; Load_complete, 0x14
    ; Run, 0x20
    ; Stop, 0x21
    ; Abort, 0x22
    ]
;;

let%test_unit "result codes" =
  check_code_table
    ~all:Result_code.all
    ~equal:Result_code.equal
    ~to_int:Result_code.to_int
    ~of_int:Result_code.of_int
    [ Complete, 0x00
    ; Accepted_pending, 0x01
    ; Bad_magic, 0x10
    ; Bad_version, 0x11
    ; Bad_length, 0x12
    ; Bad_crc, 0x13
    ; Bad_command, 0x14
    ; Incomplete, 0x15
    ; Active_execution, 0x20
    ; Engines_active, 0x21
    ; No_verified_image, 0x22
    ; Image_bounds, 0x23
    ; Verification_mismatch, 0x24
    ; Hardware_rejected, 0x2f
    ]
;;

let%test_unit "fault kind and phase values" =
  check_code_table
    ~all:Wire.Fault_kind.all
    ~equal:Wire.Fault_kind.equal
    ~to_int:Wire.Fault_kind.to_int
    ~of_int:Wire.Fault_kind.of_int
    [ No_fault, 0
    ; Invalid_base, 1
    ; Invalid_extension, 2
    ; Fetch_bounds, 3
    ; Truncated_extension, 4
    ; Target_unrepresentable, 5
    ; Mechanism_refused, 6
    ; Mechanism_completion, 7
    ; Unsolicited_completion, 8
    ; Mechanism_protocol, 9
    ];
  (* 7 is reserved; no phase decodes from it. *)
  check_code_table
    ~all:Wire.Phase.all
    ~equal:Wire.Phase.equal
    ~to_int:Wire.Phase.to_int
    ~of_int:Wire.Phase.of_int
    [ Halted, 0
    ; Fetch, 1
    ; Base_wait, 2
    ; Extension_wait, 3
    ; Mechanism_offer, 4
    ; Mechanism_wait, 5
    ; Fault, 6
    ]
;;

let%test_unit "capability and STATUS flag bit positions" =
  let capabilities : (Wire.Capability.t * int) list =
    [ Status, 0x0001
    ; Program_load, 0x0002
    ; Program_read, 0x0004
    ; Program_verify, 0x0008
    ; Run, 0x0010
    ; Stop, 0x0020
    ; Abort, 0x0040
    ]
  in
  [%test_result: int] (List.length Wire.Capability.all) ~expect:(List.length capabilities);
  List.iter capabilities ~f:(fun (capability, mask) ->
    [%test_result: int] (Wire.Capability.mask [ capability ]) ~expect:mask);
  [%test_result: int] (Wire.Capability.mask Wire.Capability.all) ~expect:0x007f;
  let flags : (Wire.Status.Flag.t * int) list =
    [ Enabled, 0
    ; Halted, 1
    ; Engines_idle, 2
    ; Image_valid, 3
    ; Load_active, 4
    ; Verification_failed, 5
    ; Execution_active, 6
    ; Normal_halt, 7
    ; Execution_fault, 8
    ; Fetch_fault, 9
    ; Pin_output_enabled, 10
    ; Pin_claimed, 11
    ]
  in
  [%test_result: int] (List.length Wire.Status.Flag.all) ~expect:(List.length flags);
  List.iter flags ~f:(fun (flag, bit) ->
    [%test_result: int] (Wire.Status.Flag.bit flag) ~expect:bit)
;;

let%test_unit "fixed request payload lengths" =
  List.iter
    [ Command.Info, 0
    ; Status, 0
    ; Load_start, 2
    ; Write_word, 4
    ; Read_word, 2
    ; Verify_word, 4
    ; Load_complete, 0
    ; Run, 0
    ; Stop, 0
    ; Abort, 0
    ]
    ~f:(fun (command, expect) ->
      [%test_result: int] (Command.request_payload_length command) ~expect)
;;

(* Requests *)

(* One vector per command, plus u16 boundaries. Fields are little-endian; an address above
   the 256-word memory is still a legal wire value that the device refuses.
*)
let request_vectors : (int * Request.t * string) list =
  [ 0x00, Info, "a5 10 00 00 00 00 68"
  ; 0x01, Status, "a5 10 01 01 00 00 15"
  ; 0x02, Load_start { length = 0x0100 }, "a5 10 02 10 02 00 00 01 16"
  ; 0x7f, Load_start { length = 0x0000 }, "a5 10 7f 10 02 00 00 00 00"
  ; 0x80, Load_start { length = 0xffff }, "a5 10 80 10 02 00 ff ff 8b"
  ; ( 0x03
    , Write_word { address = 0x00ff; word = 0xbeef }
    , "a5 10 03 11 04 00 ff 00 ef be 1a" )
  ; ( 0xfe
    , Write_word { address = 0xffff; word = 0x0000 }
    , "a5 10 fe 11 04 00 ff ff 00 00 7f" )
  ; 0x04, Read_word { address = 0x0102 }, "a5 10 04 12 02 00 02 01 0e"
  ; ( 0xff
    , Verify_word { address = 0x0000; expected = 0x1234 }
    , "a5 10 ff 13 04 00 00 00 34 12 fc" )
  ; 0x10, Load_complete, "a5 10 10 14 00 00 06"
  ; 0x20, Run, "a5 10 20 20 00 00 e5"
  ; 0x21, Stop, "a5 10 21 21 00 00 98"
  ; 0x80, Abort, "a5 10 80 22 00 00 cc"
  ]
;;

let%test_unit "every command encodes to its fixed vector" =
  List.iter request_vectors ~f:(fun (tag, request, expect) ->
    [%test_result: (string, Request.Encode_error.t) Result.t]
      (Request.encode ~tag request |> Result.map ~f:hex)
      ~expect:(Ok expect));
  List.iter Command.all ~f:(fun command ->
    assert (
      List.exists request_vectors ~f:(fun (_, request, _) ->
        Command.equal (Request.command request) command)))
;;

let%test_unit "encoder rejects out-of-range fields instead of narrowing them" =
  let rejects ~tag request ~field ~value ~max =
    [%test_result: (string, Request.Encode_error.t) Result.t]
      (Request.encode ~tag request)
      ~expect:(Error (Out_of_range { field; value; max }))
  in
  rejects ~tag:(-1) Info ~field:"tag" ~value:(-1) ~max:0xff;
  rejects ~tag:0x100 Run ~field:"tag" ~value:0x100 ~max:0xff;
  rejects
    ~tag:0
    (Load_start { length = 0x1_0000 })
    ~field:"length"
    ~value:0x1_0000
    ~max:0xffff;
  rejects ~tag:0 (Load_start { length = -1 }) ~field:"length" ~value:(-1) ~max:0xffff;
  rejects
    ~tag:0
    (Write_word { address = 0x1_0000; word = 0 })
    ~field:"address"
    ~value:0x1_0000
    ~max:0xffff;
  rejects
    ~tag:0
    (Write_word { address = 0; word = 0x1_0000 })
    ~field:"word"
    ~value:0x1_0000
    ~max:0xffff;
  rejects ~tag:0 (Read_word { address = -1 }) ~field:"address" ~value:(-1) ~max:0xffff;
  rejects
    ~tag:0
    (Verify_word { address = 0; expected = -1 })
    ~field:"expected"
    ~value:(-1)
    ~max:0xffff;
  (* The first bad field in wire order is the one reported. *)
  rejects
    ~tag:0x100
    (Verify_word { address = 0x1_0000; expected = 0x1_0000 })
    ~field:"tag"
    ~value:0x100
    ~max:0xff;
  rejects
    ~tag:0
    (Verify_word { address = 0x1_0000; expected = 0x1_0000 })
    ~field:"address"
    ~value:0x1_0000
    ~max:0xffff
;;

let%test_unit "request correlation names the tag and command byte" =
  [%test_result: Wire.Correlation.t]
    (Request.correlation ~tag:0x5c (Verify_word { address = 1; expected = 2 }))
    ~expect:{ tag = 0x5c; command = 0x13 }
;;

(* Responses: every result and payload shape *)

let info_payload : Wire.Info.t =
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

let%test_unit "INFO decodes every documented field" =
  decodes
    "5a 10 00 00 00 0d 00 01 00 01 01 7f 00 10 00 00 01 04 00 08 d1"
    (response ~tag:0x00 ~command:0x00 ~result:Complete (Info info_payload))
;;

let%test_unit "STATUS decodes flags, little-endian counters, fault and phase" =
  (* Flags 0x0c8b set bits 0, 1, 3, 7, 10 and 11. *)
  let status =
    { Wire.Status.flags =
        [ Enabled; Halted; Image_valid; Normal_halt; Pin_output_enabled; Pin_claimed ]
    ; image_length = 0x0100
    ; words_written = 0x00ff
    ; words_verified = 0x0080
    ; pc = 0x1234
    ; fault_kind = Mechanism_protocol
    ; phase = Fault
    }
  in
  decodes
    "5a 10 01 01 00 0c 00 8b 0c 00 01 ff 00 80 00 34 12 09 06 e8"
    (response ~tag:0x01 ~command:0x01 ~result:Complete (Status status));
  assert (Wire.Status.has status Image_valid);
  assert (not (Wire.Status.has status Engines_idle));
  (* Every flag and the u16 maximum in every counter. *)
  decodes
    "5a 10 02 01 00 0c 00 ff 0f ff ff ff ff ff ff ff ff 00 00 62"
    (response
       ~tag:0x02
       ~command:0x01
       ~result:Complete
       (Status
          { flags =
              [ Enabled
              ; Halted
              ; Engines_idle
              ; Image_valid
              ; Load_active
              ; Verification_failed
              ; Execution_active
              ; Normal_halt
              ; Execution_fault
              ; Fetch_fault
              ; Pin_output_enabled
              ; Pin_claimed
              ]
          ; image_length = 0xffff
          ; words_written = 0xffff
          ; words_verified = 0xffff
          ; pc = 0xffff
          ; fault_kind = No_fault
          ; phase = Halted
          }))
;;

let%test_unit "READ_WORD and VERIFY_WORD carry the actual word" =
  decodes
    "5a 10 04 12 00 02 00 ef be bd"
    (response ~tag:0x04 ~command:0x12 ~result:Complete (Word 0xbeef));
  decodes
    "5a 10 ff 13 00 02 00 34 12 c5"
    (response ~tag:0xff ~command:0x13 ~result:Complete (Word 0x1234));
  (* A mismatch is the device's answer, not a malformed frame, and keeps the word read. *)
  decodes
    "5a 10 ff 13 24 02 00 33 12 45"
    (response ~tag:0xff ~command:0x13 ~result:Verification_mismatch (Word 0x1233))
;;

let%test_unit "empty successes, including STOP's Accepted_pending" =
  List.iter
    [ "5a 10 02 10 00 00 00 f8", 0x02, 0x10, Result_code.Complete
    ; "5a 10 03 11 00 00 00 8c", 0x03, 0x11, Complete
    ; "5a 10 10 14 00 00 00 56", 0x10, 0x14, Complete
    ; "5a 10 20 20 00 00 00 f1", 0x20, 0x20, Complete
    ; "5a 10 80 22 00 00 00 2e", 0x80, 0x22, Complete
    ; "5a 10 21 21 01 00 00 ee", 0x21, 0x21, Accepted_pending
    ]
    ~f:(fun (frame, tag, command, result) ->
      decodes frame (response ~tag ~command ~result Empty))
;;

let%test_unit "device-reported framing errors are valid responses" =
  List.iter
    [ "5a 10 05 20 10 00 00 da", 0x05, 0x20, Result_code.Bad_magic
    ; "5a 10 06 00 11 00 00 d9", 0x06, 0x00, Bad_version
    ; "5a 10 07 11 12 00 00 77", 0x07, 0x11, Bad_length
    ; "5a 10 08 12 13 00 00 16", 0x08, 0x12, Bad_crc
      (* Fewer than four request bytes arrived: correlation is zeroed. *)
    ; "5a 10 00 00 15 00 00 39", 0x00, 0x00, Incomplete
      (* An unsupported command byte is echoed raw. *)
    ; "5a 10 33 7e 14 00 00 54", 0x33, 0x7e, Bad_command
    ]
    ~f:(fun (frame, tag, command, result) ->
      decodes frame (response ~tag ~command ~result Empty))
;;

let%test_unit "refusals are valid responses" =
  List.iter
    [ "5a 10 02 10 20 00 00 bb", 0x02, 0x10, Result_code.Active_execution
    ; "5a 10 03 11 21 00 00 a4", 0x03, 0x11, Engines_active
    ; "5a 10 20 20 22 00 00 64", 0x20, 0x20, No_verified_image
    ; "5a 10 02 10 23 00 00 06", 0x02, 0x10, Image_bounds
    ; "5a 10 80 22 2f 00 00 2a", 0x80, 0x22, Hardware_rejected
    ]
    ~f:(fun (frame, tag, command, result) ->
      decodes frame (response ~tag ~command ~result Empty))
;;

(* Malformed responses *)

let%test_unit "truncation and extra bytes" =
  rejects "" (Truncated { expected = 8; actual = 0 });
  rejects "5a 10 00 00 00 00 00" (Truncated { expected = 8; actual = 7 });
  (* READ_WORD response missing one payload byte. *)
  rejects "5a 10 04 12 00 02 00 ef bd" (Truncated { expected = 10; actual = 9 });
  rejects "5a 10 20 20 00 00 00 f1 00" (Extra_bytes { expected = 8; actual = 9 })
;;

let%test_unit "bad magic, version and oversized lengths" =
  rejects "a5 10 20 20 00 00 00 f1" (Bad_magic 0xa5);
  rejects "5a 11 00 00 00 00 00 72" (Bad_version 0x11);
  rejects
    "5a 10 00 00 00 0e 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 9c"
    (Payload_length_too_large 14);
  (* A nonzero high length byte is never valid in version 1. *)
  rejects "5a 10 00 00 00 00 01 5c" (Payload_length_too_large 0x0100)
;;

let%test_unit "CRC failure" =
  rejects "5a 10 20 20 00 00 00 f0" (Bad_crc { computed = 0xf1; received = 0xf0 });
  (* A corrupted tag under the original CRC. *)
  rejects "5a 10 21 20 00 00 00 f1" (Bad_crc { computed = 0x93; received = 0xf1 })
;;

let%test_unit "unknown result codes" =
  rejects "5a 10 20 20 02 00 00 27" (Unknown_result 0x02);
  rejects "5a 10 20 20 30 00 00 10" (Unknown_result 0x30)
;;

let%test_unit "results that never answer the echoed command" =
  List.iter
    [ "5a 10 21 21 00 00 00 85", 0x21, Result_code.Complete
    ; "5a 10 20 20 01 00 00 9a", 0x20, Accepted_pending
    ; "5a 10 04 12 24 02 00 ef be 56", 0x12, Verification_mismatch
    ; "5a 10 20 20 14 00 00 f8", 0x20, Bad_command
    ; "5a 10 33 7e 20 00 00 1e", 0x7e, Active_execution
    ; "5a 10 33 7e 00 00 00 5d", 0x7e, Complete
    ]
    ~f:(fun (frame, command, result) ->
      rejects frame (Unexpected_result { command; result }))
;;

let%test_unit "payload length inconsistent with command and result" =
  List.iter
    [ ( "5a 10 00 00 00 0c 00 01 00 01 01 7f 00 10 00 00 01 04 00 c6"
      , 0x00
      , Result_code.Complete
      , 13
      , 12 )
    ; "5a 10 04 12 00 00 00 9f", 0x12, Complete, 2, 0
    ; "5a 10 20 20 00 02 00 01 00 38", 0x20, Complete, 0, 2
    ; "5a 10 20 20 22 02 00 01 00 98", 0x20, No_verified_image, 0, 2
    ]
    ~f:(fun (frame, command, result, expected, actual) ->
      rejects frame (Payload_length_mismatch { command; result; expected; actual }))
;;

let%test_unit "reserved bits and undefined INFO/STATUS values" =
  rejects
    "5a 10 00 00 00 0d 00 01 00 01 01 ff 00 10 00 00 01 04 00 08 e5"
    (Invalid_field { field = "INFO capabilities"; value = 0x00ff });
  rejects
    "5a 10 00 00 00 0d 00 02 00 01 01 7f 00 10 00 00 01 04 00 08 6a"
    (Invalid_field { field = "INFO wire major"; value = 2 });
  rejects
    "5a 10 01 01 00 0c 00 00 10 00 00 00 00 00 00 00 00 00 00 b4"
    (Invalid_field { field = "STATUS flags"; value = 0x1000 });
  rejects
    "5a 10 01 01 00 0c 00 00 00 00 00 00 00 00 00 00 00 0a 00 c1"
    (Invalid_field { field = "STATUS fault kind"; value = 10 });
  rejects
    "5a 10 01 01 00 0c 00 00 00 00 00 00 00 00 00 00 00 00 07 56"
    (Invalid_field { field = "STATUS phase"; value = 7 })
;;

(* Correlation *)

let%test_unit "correlated decode accepts only the request's tag and command" =
  let decode_correlated ~tag request frame =
    Response.decode_correlated ~expected:(Request.correlation ~tag request) (bytes frame)
  in
  let run_complete = response ~tag:0x20 ~command:0x20 ~result:Complete Empty in
  [%test_result: decoded]
    (decode_correlated ~tag:0x20 Run "5a 10 20 20 00 00 00 f1")
    ~expect:(Ok run_complete);
  [%test_result: decoded]
    (decode_correlated ~tag:0x21 Run "5a 10 20 20 00 00 00 f1")
    ~expect:
      (Error
         (Correlation_mismatch
            { expected = { tag = 0x21; command = 0x20 }; response = run_complete }));
  [%test_result: decoded]
    (decode_correlated ~tag:0x20 Stop "5a 10 20 20 00 00 00 f1")
    ~expect:
      (Error
         (Correlation_mismatch
            { expected = { tag = 0x20; command = 0x21 }; response = run_complete }));
  (* A framing error with zeroed correlation keeps the decoded response in the error. *)
  [%test_result: decoded]
    (decode_correlated
       ~tag:0x07
       (Write_word { address = 0; word = 0 })
       "5a 10 00 00 15 00 00 39")
    ~expect:
      (Error
         (Correlation_mismatch
            { expected = { tag = 0x07; command = 0x11 }
            ; response = response ~tag:0 ~command:0 ~result:Incomplete Empty
            }));
  (* Tag 0 INFO cannot be told apart from zeroed correlation; the non-success result is
     returned as the answer.
  *)
  [%test_result: decoded]
    (decode_correlated ~tag:0x00 Info "5a 10 00 00 15 00 00 39")
    ~expect:(Ok (response ~tag:0 ~command:0 ~result:Incomplete Empty));
  (* Malformed bytes stay malformed whatever was expected. *)
  [%test_result: decoded]
    (decode_correlated ~tag:0x20 Run "5a 10 20 20 00 00 00 f0")
    ~expect:(Error (Bad_crc { computed = 0xf1; received = 0xf0 }))
;;

let%test_unit "an echoed unsupported command correlates by its raw byte" =
  [%test_result: decoded]
    (Response.decode_correlated
       ~expected:{ tag = 0x33; command = 0x7e }
       (bytes "5a 10 33 7e 14 00 00 54"))
    ~expect:(Ok (response ~tag:0x33 ~command:0x7e ~result:Bad_command Empty))
;;

(* Supplementary: a zero-init, no-XOR CRC over a frame including its own CRC is zero. This
   checks the encoder's CRC placement against the software CRC; the fixed vectors above
   remain the oracle.
*)
let%test_unit "encoded frames have a zero CRC residue" =
  List.iter request_vectors ~f:(fun (tag, request, _) ->
    let frame = Request.encode ~tag request |> Result.ok |> Option.value_exn in
    [%test_result: int] (Wire.Crc.compute frame) ~expect:0)
;;
