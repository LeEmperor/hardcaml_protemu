(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "frame_rx_receive_tests.ml" *)
(* HL4c: legal requests at [Frame_rx]'s boundary.

   Every legal command is received with its exact retained fields and handed off once, in
   its release cycle. Expected fields are written literally from the P3.5 request layout.
   The payload output is positional: it holds whatever arrived at bytes 6 to 9,
   little-endian, so after a shorter payload it also holds the CRC byte. The expected
   values below spell those bytes out.
*)

open! Core
open! Hardcaml_protemu
open! Frame_rx_testbench

(* Little-endian bytes 6 to 9 of what was sent. Used where a CRC byte lands in the payload
   positions; the tests with a four-byte payload write the value literally.
*)
let positional_payload bytes =
  List.range 6 (Int.min 10 (String.length bytes))
  |> List.foldi ~init:0 ~f:(fun index acc position ->
    acc lor (Char.to_int bytes.[position] lsl (8 * index)))
;;

let complete ~tag ~command ~payload_length ~payload : Expected.t =
  { result = Complete; echo_valid = true; tag; command; payload_length; payload }
;;

let%test_unit "every legal request is received with its exact fields and handed off once \
               at deselection"
  =
  let t = create "legal requests" in
  (* Request, tag, command byte, declared length, and a literal payload where all four
     payload bytes are payload. The write comes first, so the INFO after it shows that a
     new request starts from cleared fields.
  *)
  let cases : (Wire.Request.t * int * int * int * int option) list =
    [ Write_word { address = 0x80fe; word = 0x7f01 }, 0xff, 0x11, 4, Some 0x7f0180fe
    ; Info, 0x01, 0x00, 0, None
    ; Read_word { address = 0x00ff }, 0x05, 0x12, 2, None
    ; Verify_word { address = 0x0102; expected = 0xa55a }, 0x06, 0x13, 4, Some 0xa55a0102
    ; Status, 0x80, 0x01, 0, None
    ; Load_start { length = 0x0102 }, 0x03, 0x10, 2, None
    ; Load_complete, 0x07, 0x14, 0, None
    ; Run, 0x00, 0x20, 0, None
    ; Stop, 0x5a, 0x21, 0, None
    ; Abort, 0xa5, 0x22, 0, None
    ]
  in
  List.iter cases ~f:(fun (request, tag, command, payload_length, payload) ->
    let bytes = encode ~tag request in
    (* Four-byte payloads make the eleven-byte maximum frame. *)
    check
      t
      ~phase:Post_run
      "frame length"
      [%sexp_of: int]
      [%equal: int]
      ~expected:(7 + payload_length)
      (String.length bytes);
    let payload = Option.value payload ~default:(positional_payload bytes) in
    expect_handoff
      t
      (Sexp.to_string [%sexp (request : Wire.Request.t)])
      bytes
      (complete ~tag ~command ~payload_length ~payload);
    run t 4)
;;

let%test_unit "the short payloads keep their operands in the low bytes" =
  (* Written out for the two-byte payloads: the operand in bytes 6-7 and the CRC in 8. *)
  let t = create "short payloads" in
  let bytes = encode ~tag:0x10 (Load_start { length = 0x0102 }) in
  let crc = Char.to_int bytes.[8] in
  expect_handoff
    t
    "LOAD_START"
    bytes
    (complete
       ~tag:0x10
       ~command:0x10
       ~payload_length:2
       ~payload:((crc lsl 16) lor 0x0102));
  let bytes = encode ~tag:0x11 Info in
  let crc = Char.to_int bytes.[6] in
  expect_handoff
    t
    "INFO"
    bytes
    (complete ~tag:0x11 ~command:0x00 ~payload_length:0 ~payload:crc)
;;

let%test_unit "each byte is assembled most significant bit first from the data level in \
               the clock-rise cycle only"
  =
  (* [send_bit] drives the complement of each bit in every other cycle, so only a sample
     in the rise cycle yields the frame. Asymmetric bytes distinguish MSB-first from
     LSB-first and little-endian from big-endian assembly.
  *)
  let write = Wire.Request.Write_word { address = 0x8001; word = 0x0f70 } in
  List.iter [ 2; 3; 8; 37 ] ~f:(fun period ->
    let t = create (sprintf "bit order, period %d" period) in
    expect_handoff
      t
      "WRITE"
      ~period
      (encode ~tag:0x01 write)
      (complete ~tag:0x01 ~command:0x11 ~payload_length:4 ~payload:0x0f708001))
;;

let%test_unit "a selected request may pause for a long finite time and resume without \
               losing state"
  =
  let t = create "selected pauses" in
  let bytes = encode ~tag:0x5c (Verify_word { address = 0x00fe; expected = 0x1234 }) in
  let pause = 10_000 in
  let from = t.cycle in
  let asserted = select t in
  run t pause;
  (* Pauses within a byte (after bit 3 of byte 2) and between bytes (after bytes 5 and 9,
     counting from 0), with the data level held at the complement of the last bit.
  *)
  let pause_after = [ (8 * 2) + 3; (8 * 6) - 1; (8 * 10) - 1 ] in
  List.iteri (bits_of_string bytes) ~f:(fun index bit ->
    send_bit t bit;
    if List.mem pause_after index ~equal:Int.equal then run t pause);
  run t pause;
  let released = deselect t in
  run t 1;
  expect_frame_end_cycles t ~from "paused" [ released ];
  expect_active_cycles t ~from "paused" (List.range (asserted + 1) (released + 1));
  expect_fields
    t
    ~cycle:released
    "paused"
    (complete ~tag:0x5c ~command:0x13 ~payload_length:4 ~payload:0x123400fe)
;;
