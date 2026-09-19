(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "uart_slice_unit_tests.ml" *)
(* P2.7: the first working slice closed at the pin.

   [Uart_tx]'s own tests check the frame at the lane's output. These check it where it
   leaves the design, after the claim, the timed idle phase and the bank's masked commit,
   and they check it with a receiver that is told nothing but the expected bit period. The
   reset and disable cases are the ones the phase plan names: a frame interrupted part way
   through must release the pin and its ownership, not finish quietly.
*)

open! Core
open! Hardcaml
open! Hardcaml_protemu
open! Uart_slice_testbench

let%test_unit "P2.7 the pin bank carries the frame an independent receiver decodes" =
  let samples, _ = slice_samples () in
  let decoded = decode samples ~half_period in
  [%test_result: int] ~message:"received byte" ~expect:byte decoded.byte;
  [%test_result: int]
    ~message:"bit period measured from the waveform"
    ~expect:bit_cycles
    decoded.measured_period;
  [%test_eq: bool] ~message:"start bit low" false (List.nth_exn decoded.slots 0).level;
  [%test_eq: bool] ~message:"stop bit high" true (List.nth_exn decoded.slots 9).level
;;

let%test_unit "P2.7 the model, the engine and the hardware agree on the frame" =
  let trace samples = trace_of samples ~byte ~half_period ~tx_pin in
  let firmware = trace (firmware_samples ()) in
  let descriptor = trace (descriptor_samples ()) in
  let slice = trace (fst (slice_samples ())) in
  [%test_result: string]
    ~message:"typed descriptor against P1.3's bit-banged sequence"
    ~expect:firmware
    descriptor;
  [%test_result: string]
    ~message:"Hardcaml slice against the reference machine"
    ~expect:firmware
    slice
;;

let%expect_test "P2.7 the saved frame trace" =
  print_string (trace_of (fst (slice_samples ())) ~byte ~half_period ~tx_pin);
  [%expect
    {|
    # protemu P2.7 first working slice -- UART 8N1 transmit frame
    # byte=0xa6 half_period=4 bit_cycles=8 tx_pin=0
    # slot label level start end
    0 start 0 0 8
    1 d0 0 8 16
    2 d1 1 16 24
    3 d2 1 24 32
    4 d3 0 32 40
    5 d4 0 40 48
    6 d5 1 48 56
    7 d6 0 56 64
    8 d7 1 64 72
    9 stop 1 72 80
    |}]
;;

let%test_unit "P2.7 the frame is timed by the timer and owned by the engine" =
  let saw_gap = ref false in
  let saw_claim = ref false in
  let saw_done = ref false in
  let bank_clean = ref true in
  let samples, o =
    slice_samples
      ~f:(fun ~cycle:_ ~i:_ ~o ->
        if Bits.to_bool !(o.gap_busy_o) then saw_gap := true;
        if Bits.to_int_trunc !(o.engine_claim_o) land 1 <> 0 then saw_claim := true;
        if Bits.to_bool !(o.frame_done_o) then saw_done := true;
        if Bits.to_bool !(o.bank_rejected_o) || Bits.to_bool !(o.bank_conflict_o)
        then bank_clean := false)
      ()
  in
  [%test_eq: bool] ~message:"the timer ran the idle phase" true !saw_gap;
  [%test_eq: bool] ~message:"the engine owned the transmit pin" true !saw_claim;
  [%test_eq: bool] ~message:"the frame reported completion" true !saw_done;
  [%test_eq: bool] ~message:"no bank rejection or conflict" true !bank_clean;
  (* Ownership is given back, and the line is left resting where a UART line rests. *)
  [%test_result: int]
    ~message:"claim released after the frame"
    ~expect:0
    (Bits.to_int_trunc !(o.engine_claim_o));
  [%test_result: int]
    ~message:"line left idle high"
    ~expect:1
    (Bits.to_int_trunc !(o.pins_o));
  [%test_result: int]
    ~message:"line still driven"
    ~expect:1
    (Bits.to_int_trunc !(o.pin_oe_o));
  (* And the frame that ran under all that is still the frame. *)
  [%test_result: int]
    ~message:"received byte"
    ~expect:byte
    (decode samples ~half_period).byte
;;

let%test_unit "P2.7 only the selected pin is ever driven" =
  let others = ref 0 in
  let (_ : Uart_frame_monitor.Sample.t array * _ Uart_slice.O.t) =
    slice_samples
      ~pin:5
      ~f:(fun ~cycle:_ ~i:_ ~o ->
        others
        := !others
           lor (Bits.to_int_trunc !(o.pin_oe_o) land lnot (1 lsl 5))
           lor (Bits.to_int_trunc !(o.pins_o) land lnot (1 lsl 5)))
      ()
  in
  [%test_result: int] ~message:"other pins untouched" ~expect:0 !others
;;

let%test_unit "P2.7 a frame transmits on any selected pin" =
  List.iter [ 0; 3; 7 ] ~f:(fun pin ->
    let samples, _ = slice_samples ~pin () in
    let decoded = decode samples ~half_period in
    [%test_result: int]
      ~message:(sprintf "received byte on pin %d" pin)
      ~expect:byte
      decoded.byte)
;;

let%test_unit "P2.7 several bytes and bit periods decode" =
  List.iter
    [ 0x00, 4; 0xff, 4; 0x55, 2; 0xa6, 6 ]
    ~f:(fun (byte, half_period) ->
      let samples, _ = slice_samples ~byte ~half_period () in
      let decoded = decode samples ~half_period in
      [%test_result: int]
        ~message:(sprintf "received 0x%02x at half period %d" byte half_period)
        ~expect:byte
        decoded.byte)
;;

(* The interruption cases. A partially transmitted frame must not leave the pin driven at
   whatever level the lane happened to be holding. *)

let released_at ~event =
  let released = ref None in
  let interrupt_cycle = ref 0 in
  let (_ : Uart_frame_monitor.Sample.t array * _ Uart_slice.O.t) =
    slice_samples
      ~extra_cycles:8
      ~f:(fun ~cycle ~i ~o ->
        (* Part way into the data bits, with the line low, so a pin left driven would be
           visible as a stuck start bit rather than as idle. *)
        if cycle = 30
        then (
          interrupt_cycle := cycle;
          match event with
          | `Reset -> i.reset_i := Bits.vdd
          | `Disable -> i.enable_i := Bits.gnd
          | `Abort -> i.abort_i := Bits.vdd);
        if cycle > 30 && Option.is_none !released
        then
          if Bits.to_int_trunc !(o.pin_oe_o) = 0 && Bits.to_int_trunc !(o.pins_o) = 0
          then released := Some (cycle, Bits.to_int_trunc !(o.engine_claim_o)))
      ()
  in
  !released
;;

let%test_unit "P2.7 reset during transmission releases the pin and its ownership" =
  match released_at ~event:`Reset with
  | None -> failwith "reset left the transmit pin driven"
  | Some (cycle, claim) ->
    [%test_result: int] ~message:"released on the next edge" ~expect:31 cycle;
    [%test_result: int] ~message:"claim dropped" ~expect:0 claim
;;

let%test_unit "P2.7 disable during transmission releases the pin and its ownership" =
  match released_at ~event:`Disable with
  | None -> failwith "disable left the transmit pin driven"
  | Some (cycle, claim) ->
    [%test_result: int] ~message:"released on the next edge" ~expect:31 cycle;
    [%test_result: int] ~message:"claim dropped" ~expect:0 claim
;;

let%test_unit "P2.7 abort during transmission releases the pin and its ownership" =
  match released_at ~event:`Abort with
  | None -> failwith "abort left the transmit pin driven"
  | Some (cycle, claim) ->
    [%test_result: int] ~message:"released on the next edge" ~expect:31 cycle;
    [%test_result: int] ~message:"claim dropped" ~expect:0 claim
;;

(* The monitor is evidence only if it fails on a broken waveform. *)

let%test_unit "P2.7 the monitor rejects a frame it should not accept" =
  let short_stop =
    let samples, _ = slice_samples () in
    (* Cut the stop bit short by one cycle of the line falling early. *)
    let decoded = decode samples ~half_period in
    let index = decoded.start_edge + (9 * bit_cycles) + 2 in
    samples.(index) <- { Uart_frame_monitor.Sample.level = false; driven = true };
    Uart_frame_monitor.decode ~bit_cycles samples
  in
  (match short_stop with
   | Ok _ -> failwith "the monitor accepted a broken stop bit"
   | Error message ->
     [%test_eq: bool]
       ~message:"the monitor said where"
       true
       (String.is_substring message ~substring:"bit slot 9"));
  let released_mid_frame =
    let samples, _ = slice_samples () in
    let decoded = decode samples ~half_period in
    samples.(decoded.start_edge + bit_cycles + 1) <- Uart_frame_monitor.Sample.released;
    Uart_frame_monitor.decode ~bit_cycles samples
  in
  match released_mid_frame with
  | Ok _ -> failwith "the monitor accepted a released pin inside the frame"
  | Error message ->
    [%test_eq: bool]
      ~message:"the monitor said the pin was released"
      true
      (String.is_substring message ~substring:"released")
;;

let%test_unit "P2.7 the monitor rejects a frame with no idle before it" =
  let samples, _ = slice_samples () in
  let decoded = decode samples ~half_period in
  let clipped =
    Array.sub
      samples
      ~pos:(decoded.start_edge - 2)
      ~len:(Array.length samples - decoded.start_edge + 2)
  in
  match Uart_frame_monitor.decode ~bit_cycles clipped with
  | Ok _ -> failwith "the monitor accepted a frame with no leading idle"
  | Error message ->
    [%test_eq: bool]
      ~message:"the monitor said the idle was short"
      true
      (String.is_substring message ~substring:"shorter than one bit period")
;;
