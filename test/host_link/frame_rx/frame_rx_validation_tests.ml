(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "frame_rx_validation_tests.ml" *)
(* HL4c: [Frame_rx]'s deselect validation, byte bound, sticky overrun, and correlation.

   Every expected result is written by hand from the P3.5 record's framing rules, not from
   the receiver's expressions:

   - a twelfth byte is overrun ([Bad_length]), and nothing later in that selection can
     make the frame valid;
   - otherwise a frame that is not whole bytes, or whose length is not the declared
     payload length plus seven, is [Incomplete];
   - otherwise magic, then version, then CRC are checked ([Bad_magic], [Bad_version],
     [Bad_crc]);
   - tag and command are echoed only when all four bytes through the command arrived.

   Command legality, each command's fixed length, and device bounds are dispatch-stage
   decisions in [Hardware_loader]. Here such frames are [Complete] and the raw fields they
   need are retained.

   The receiver also maps a declared length above four to [Bad_length] after the header
   checks. No frame reaches that branch: a whole-byte frame of length plus seven bytes has
   at most eleven bytes, so its length is at most four, and a longer frame is overrun
   first. Lengths five to eight are therefore tested through overrun.
*)

open! Core
open! Hardcaml_protemu
open! Frame_rx_testbench

(* The result, echo, tag, and command presented in the release cycle. *)
let expect_result t ~released what ~result ~echo_valid ~tag ~command =
  let s = observed t released in
  check
    t
    ~cycle:released
    ~phase:Pre_edge
    (what ^ ": result, echo, tag, and command")
    [%sexp_of: Wire.Result_code.t option * bool * int * int]
    [%equal: Wire.Result_code.t option * bool * int * int]
    ~expected:(Some result, echo_valid, tag, command)
    (Wire.Result_code.of_int s.result, s.echo_valid, s.tag, s.command)
;;

(* One selection handing off once with the given result; checks only what is named. *)
let expect_rejected ?extra_bits ?period t what bytes ~result ~echo_valid ~tag ~command =
  let from = t.cycle in
  let { Selection.released; _ } = request ?extra_bits ?period t bytes in
  run t 1;
  expect_frame_end_cycles t ~from what [ released ];
  expect_result t ~released what ~result ~echo_valid ~tag ~command;
  run t 4;
  released
;;

let write = encode ~tag:0x33 (Write_word { address = 0x0102; word = 0x0304 })
let info tag = encode ~tag Info

let%test_unit "truncated header, payload, and CRC are incomplete; the echo needs four \
               bytes"
  =
  let t = create "truncation" in
  (* Bytes: a5 10 33 11 04 00 02 01 04 03 crc. *)
  let expected =
    [ 0, false, 0x00, 0x00, 0, 0x00000000
    ; 1, false, 0x00, 0x00, 0, 0x00000000
    ; 2, false, 0x00, 0x00, 0, 0x00000000
    ; 3, false, 0x33, 0x00, 0, 0x00000000
    ; 4, true, 0x33, 0x11, 0, 0x00000000
    ; 5, true, 0x33, 0x11, 4, 0x00000000
    ; 6, true, 0x33, 0x11, 4, 0x00000000
    ; 7, true, 0x33, 0x11, 4, 0x00000002
    ; 8, true, 0x33, 0x11, 4, 0x00000102
    ; 9, true, 0x33, 0x11, 4, 0x00040102
    ; 10, true, 0x33, 0x11, 4, 0x03040102
    ]
  in
  List.iter expected ~f:(fun (count, echo_valid, tag, command, payload_length, payload) ->
    let what = sprintf "first %d bytes of a WRITE" count in
    let { Selection.released; _ } = request t (String.prefix write count) in
    run t 1;
    expect_fields
      t
      ~cycle:released
      what
      { result = Incomplete; echo_valid; tag; command; payload_length; payload };
    run t 4)
;;

let%test_unit "a partial final byte is incomplete, whether extra or missing bits" =
  let t = create "partial bytes" in
  List.iter [ 1; 2; 3; 4; 5; 6; 7 ] ~f:(fun bits ->
    ignore
      (expect_rejected
         t
         (sprintf "INFO plus %d bits" bits)
         (info 0x21)
         ~extra_bits:(List.init bits ~f:(fun index -> index % 2 = 0))
         ~result:Incomplete
         ~echo_valid:true
         ~tag:0x21
         ~command:0x00
       : int);
    (* The same INFO with its CRC byte cut short by [bits]. *)
    let frame = info 0x22 in
    ignore
      (expect_rejected
         t
         (sprintf "INFO missing its last %d bits" bits)
         (String.prefix frame 6)
         ~extra_bits:(List.take (bits_of_byte (Char.to_int frame.[6])) (8 - bits))
         ~result:Incomplete
         ~echo_valid:true
         ~tag:0x22
         ~command:0x00
       : int))
;;

let%test_unit "whole extra bytes are incomplete up to eleven; the twelfth latches overrun"
  =
  let t = create "extra bytes" in
  List.iter [ 1; 2; 3; 4 ] ~f:(fun extra ->
    ignore
      (expect_rejected
         t
         (sprintf "INFO plus %d bytes" extra)
         (info 0x23 ^ Raw.zeros extra)
         ~result:Incomplete
         ~echo_valid:true
         ~tag:0x23
         ~command:0x00
       : int));
  ignore
    (expect_rejected
       t
       "INFO plus 5 bytes"
       (info 0x23 ^ Raw.zeros 5)
       ~result:Bad_length
       ~echo_valid:true
       ~tag:0x23
       ~command:0x00
     : int)
;;

let%test_unit "overrun is sticky: no suffix restores validity, and the header is not \
               recaptured"
  =
  let t = create "overrun" in
  (* The maximum frame, then one byte. *)
  let released =
    expect_rejected
      t
      "WRITE plus one byte"
      (write ^ Raw.zeros 1)
      ~result:Bad_length
      ~echo_valid:true
      ~tag:0x33
      ~command:0x11
  in
  expect_fields
    t
    ~cycle:released
    "WRITE plus one byte"
    { result = Bad_length
    ; echo_valid = true
    ; tag = 0x33
    ; command = 0x11
    ; payload_length = 4
    ; payload = 0x03040102
    };
  (* A complete valid frame after the maximum one: its header must not replace the first
     frame's, and it cannot become a second frame.
  *)
  ignore
    (expect_rejected
       t
       "WRITE then INFO"
       (write ^ info 0x55)
       ~result:Bad_length
       ~echo_valid:true
       ~tag:0x33
       ~command:0x11
     : int);
  ignore
    (expect_rejected
       t
       "twelve zeros then INFO"
       (Raw.zeros 12 ^ info 0x55)
       ~result:Bad_length
       ~echo_valid:true
       ~tag:0x00
       ~command:0x00
     : int);
  (* The next eligible selection starts clean. *)
  expect_handoff
    t
    "INFO after overrun"
    (info 0x56)
    { result = Complete
    ; echo_valid = true
    ; tag = 0x56
    ; command = 0x00
    ; payload_length = 0
    ; payload = Char.to_int (info 0x56).[6]
    }
;;

let%test_unit "long prefixes of the historical counter-wrap shapes cannot hand off a \
               valid frame"
  =
  (* With a four-bit count that wraps, sixteen bytes return it to zero, and the frame
     after the prefix would parse as a fresh request.
  *)
  let t = create "prefix attacks" in
  let load_start = encode ~tag:0x66 (Load_start { length = 0x0010 }) in
  let zero_fields : Expected.t =
    { result = Bad_length
    ; echo_valid = true
    ; tag = 0
    ; command = 0
    ; payload_length = 0
    ; payload = 0
    }
  in
  List.iter
    [ 15, load_start
    ; 16, load_start
    ; 32, load_start
    ; 48, load_start
    ; 16, write
    ; 15, write
    ; 11, write
    ]
    ~f:(fun (prefix, frame) ->
      let what = sprintf "%d zeros then a valid frame" prefix in
      let { Selection.released; _ } = request ~period:2 t (Raw.zeros prefix ^ frame) in
      run t 1;
      expect_fields t ~cycle:released what zero_fields;
      run t 4);
  (* Far beyond any count width the receiver could plausibly wrap at. *)
  let { Selection.released; _ } = request ~period:2 t (Raw.zeros 5000 ^ load_start) in
  run t 1;
  expect_fields t ~cycle:released "5000 zeros then LOAD_START" zero_fields
;;

let%test_unit "a declared length is checked against the bytes received; command sizes \
               are left to dispatch"
  =
  let t = create "declared lengths" in
  (* Consistent frames whose length is wrong for their command: [Complete] here, with the
     declared length retained for dispatch's [Bad_length].
  *)
  let info_4 = Raw.frame ~tag:0x40 ~command:0x00 [ 0x01; 0x02; 0x03; 0x04 ] in
  expect_handoff
    t
    "INFO declaring and carrying four bytes"
    info_4
    { result = Complete
    ; echo_valid = true
    ; tag = 0x40
    ; command = 0x00
    ; payload_length = 4
    ; payload = 0x04030201
    };
  let run_2 = Raw.frame ~tag:0x41 ~command:0x20 [ 0x05; 0x06 ] in
  expect_handoff
    t
    "RUN declaring and carrying two bytes"
    run_2
    { result = Complete
    ; echo_valid = true
    ; tag = 0x41
    ; command = 0x20
    ; payload_length = 2
    ; payload = (Char.to_int run_2.[8] lsl 16) lor 0x0605
    };
  (* Declared and carried lengths disagree. *)
  List.iter
    [ ( "WRITE declaring 4, carrying 2"
      , Raw.frame ~payload_length:4 ~tag:0x42 ~command:0x11 [ 1; 2 ] )
    ; ( "WRITE declaring 2, carrying 4"
      , Raw.frame ~payload_length:2 ~tag:0x42 ~command:0x11 [ 1; 2; 3; 4 ] )
    ; ( "INFO declaring 1, carrying 0"
      , Raw.frame ~payload_length:1 ~tag:0x42 ~command:0x00 [] )
    ]
    ~f:(fun (what, frame) ->
      ignore
        (expect_rejected
           t
           what
           frame
           ~result:Incomplete
           ~echo_valid:true
           ~tag:0x42
           ~command:(Char.to_int frame.[3])
         : int));
  (* Lengths five to eight, sent whole: overrun at the twelfth byte. *)
  List.iter [ 5; 6; 7; 8 ] ~f:(fun length ->
    ignore
      (expect_rejected
         t
         (sprintf "length %d sent whole" length)
         (Raw.frame
            ~tag:0x43
            ~command:0x11
            (List.init length ~f:(fun index -> index + 1)))
         ~result:Bad_length
         ~echo_valid:true
         ~tag:0x43
         ~command:0x11
       : int));
  (* A nonzero high length byte never reaches its declared CRC position. The last three
     would wrap a 16-bit "length plus seven" to 0, 3, and 6.
  *)
  List.iter [ 0x0100; 0x0400; 0xff00; 0xfff9; 0xfffc; 0xffff ] ~f:(fun payload_length ->
    let frame = Raw.frame ~payload_length ~tag:0x44 ~command:0x00 [] in
    let { Selection.released; _ } = request t frame in
    run t 1;
    expect_fields
      t
      ~cycle:released
      (sprintf "INFO declaring %#x" payload_length)
      { result = Incomplete
      ; echo_valid = true
      ; tag = 0x44
      ; command = 0x00
      ; payload_length
      ; payload = Char.to_int frame.[6]
      };
    run t 4)
;;

let%test_unit "bad magic, version, and CRC are rejected; unknown commands and device \
               bounds are not framing errors"
  =
  let t = create "header and CRC" in
  List.iter
    [ ( "magic a4"
      , Raw.frame ~magic:0xa4 ~tag:0x50 ~command:0x00 []
      , Wire.Result_code.Bad_magic )
    ; "response magic 5a", Raw.frame ~magic:0x5a ~tag:0x50 ~command:0x00 [], Bad_magic
    ; "version 11", Raw.frame ~version:0x11 ~tag:0x50 ~command:0x00 [], Bad_version
    ; "version 00", Raw.frame ~version:0x00 ~tag:0x50 ~command:0x00 [], Bad_version
    ; "version 20", Raw.frame ~version:0x20 ~tag:0x50 ~command:0x00 [], Bad_version
    ]
    ~f:(fun (what, frame, result) ->
      ignore
        (expect_rejected t what frame ~result ~echo_valid:true ~tag:0x50 ~command:0x00
         : int));
  (* Every single-bit CRC error in the maximum frame. *)
  List.iter [ 0x01; 0x02; 0x04; 0x08; 0x10; 0x20; 0x40; 0x80 ] ~f:(fun mask ->
    ignore
      (expect_rejected
         t
         (sprintf "WRITE with CRC ^ %#x" mask)
         (Raw.flip_last write ~mask)
         ~result:Bad_crc
         ~echo_valid:true
         ~tag:0x33
         ~command:0x11
       : int));
  (* Command legality and device bounds belong to dispatch: the raw fields are kept. *)
  List.iter [ 0x7f; 0xff; 0x15; 0x23 ] ~f:(fun command ->
    expect_handoff
      t
      (sprintf "unknown command %#x" command)
      (Raw.frame ~tag:0x51 ~command [])
      { result = Complete
      ; echo_valid = true
      ; tag = 0x51
      ; command
      ; payload_length = 0
      ; payload = Char.to_int (Raw.frame ~tag:0x51 ~command []).[6]
      });
  expect_handoff
    t
    "WRITE to address 0x100"
    (encode ~tag:0x52 (Write_word { address = 0x0100; word = 0xffff }))
    { result = Complete
    ; echo_valid = true
    ; tag = 0x52
    ; command = 0x11
    ; payload_length = 4
    ; payload = 0xffff0100
    }
;;

let%test_unit "several defects resolve in the existing precedence" =
  let t = create "precedence" in
  let bad_everything = Raw.frame ~magic:0x00 ~version:0x00 ~tag:0x60 ~command:0x7f [] in
  List.iter
    [ ( "overrun with bad magic, version, and CRC"
      , Raw.flip_last (bad_everything ^ Raw.zeros 5) ~mask:0x01
      , []
      , Wire.Result_code.Bad_length )
    ; ( "length 5 sent whole, with bad magic and CRC"
      , Raw.flip_last
          (Raw.frame ~magic:0x00 ~tag:0x60 ~command:0x7f [ 1; 2; 3; 4; 5 ])
          ~mask:0x01
      , []
      , Bad_length )
    ; ( "incomplete header with bad magic and version"
      , String.prefix bad_everything 6
      , []
      , Incomplete )
    ; "partial byte with bad magic", bad_everything, [ true ], Incomplete
    ; ( "high length byte with bad magic"
      , Raw.frame ~magic:0x00 ~payload_length:0x0100 ~tag:0x60 ~command:0x7f []
      , []
      , Incomplete )
    ; ( "bad magic, version, and CRC"
      , Raw.flip_last bad_everything ~mask:0x01
      , []
      , Bad_magic )
    ; ( "bad version and CRC"
      , Raw.flip_last (Raw.frame ~version:0x00 ~tag:0x60 ~command:0x7f []) ~mask:0x01
      , []
      , Bad_version )
    ; ( "bad CRC, unknown command, and a length wrong for it"
      , Raw.flip_last (Raw.frame ~tag:0x60 ~command:0x7f [ 1; 2 ]) ~mask:0x80
      , []
      , Bad_crc )
    ]
    ~f:(fun (what, frame, extra_bits, result) ->
      ignore
        (expect_rejected
           t
           what
           frame
           ~extra_bits
           ~result
           ~echo_valid:true
           ~tag:0x60
           ~command:0x7f
         : int))
;;

let%test_unit "correlation just below and at the four-byte threshold, and the zeroed echo"
  =
  let t = create "correlation" in
  (* Tag received, command not: the tag is retained, but the echo is invalid, so the
     loader must zero it.
  *)
  ignore
    (expect_rejected
       t
       "three bytes"
       (String.prefix (info 0x33) 3)
       ~result:Incomplete
       ~echo_valid:false
       ~tag:0x33
       ~command:0x00
     : int);
  ignore
    (expect_rejected
       t
       "four bytes"
       (String.prefix write 4)
       ~result:Incomplete
       ~echo_valid:true
       ~tag:0x33
       ~command:0x11
     : int);
  (* Two bytes of an INFO with tag 0: the zeroed correlation is INFO/tag 0, but the result
     is never [Complete].
  *)
  ignore
    (expect_rejected
       t
       "two bytes of INFO, tag 0"
       (String.prefix (info 0x00) 2)
       ~result:Incomplete
       ~echo_valid:false
       ~tag:0x00
       ~command:0x00
     : int);
  (* An empty selection is handed off too. *)
  ignore
    (expect_rejected
       t
       "empty selection"
       ""
       ~result:Incomplete
       ~echo_valid:false
       ~tag:0x00
       ~command:0x00
     : int)
;;
