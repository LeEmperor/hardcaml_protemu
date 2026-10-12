(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "uart_frame_monitor.ml" *)
(* An independent 8N1 receiver, written from the frame definition rather than from any
   transmitter in this repository.

   P2.7 asks for a monitor that checks idle, start, data, stop, and bit periods. This one
   is handed nothing but a per-cycle record of what a single pin did - its level and
   whether it was driven at all - and the bit period it was told to expect. It finds the
   start edge itself, recovers the byte itself, and measures the period from the waveform
   instead of trusting it.

   WHAT IT REFUSES TO ASSUME. A bit slot is checked for a constant level across its whole
   span, not sampled at its centre: a glitch or an early transition inside a slot is a
   failure here, where centre sampling would step over it. A released pin is never read as
   a level, because what a pull-up would do with it is the board's business and not the
   design's claim (the same rule [Firmware.Trace.wave] keeps on the model side).

   WHAT THE MEASURED PERIOD MEANS. The greatest common divisor of the intervals between
   transitions is the largest period the waveform could have been drawn on. It equals the
   bit period exactly when the byte puts at least one bit between two unlike neighbours;
   for a byte that never does, it is a multiple, and the check below says so rather than
   pretending to more resolution than the waveform carries.
*)

open! Core

module Sample = struct
  (* One clock cycle of one pin, as the outside world would see it. *)
  type t =
    { level : bool
    ; driven : bool
    }
  [@@deriving sexp_of, compare, equal]

  let idle_high = { level = true; driven = true }
  let released = { level = false; driven = false }
end

module Slot = struct
  (* One bit of the frame, timed relative to the falling start edge. *)
  type t =
    { index : int
    ; label : string
    ; level : bool
    ; start_cycle : int
    ; end_cycle : int
    }
  [@@deriving sexp_of, compare, equal]
end

type t =
  { (* The byte the receiver recovered, not the byte anything claimed to send. *)
    byte : int
  ; (* The period the waveform was measured on, and the one it was checked against. *)
    measured_period : int
  ; expected_period : int
  ; (* Driven high cycles immediately before the start edge. *)
    leading_idle : int
  ; (* Cycle of the falling start edge in the supplied trace. *)
    start_edge : int
  ; slots : Slot.t list
  }
[@@deriving sexp_of, compare, equal]

(* 8N1: a low start bit, eight data bits least significant first, a high stop bit. *)
let frame_bits = 10

let label index =
  if index = 0
  then "start"
  else if index = frame_bits - 1
  then "stop"
  else sprintf "d%d" (index - 1)
;;

let rec gcd a b = if b = 0 then a else gcd b (a % b)

let decode ~bit_cycles (samples : Sample.t array) =
  let length = Array.length samples in
  let error message = Error (String.concat message) in
  let at k = samples.(k) in
  let driven_high k = (at k).driven && (at k).level in
  if bit_cycles < 1
  then error [ "bit period must be positive" ]
  else (
    (* The start edge is the first driven fall on an idle line. *)
    match
      List.find (List.range 1 length) ~f:(fun k ->
        driven_high (k - 1) && (at k).driven && not (at k).level)
    with
    | None -> error [ "no start edge: the line never fell from a driven idle" ]
    | Some start_edge ->
      let leading_idle =
        let rec count k n =
          if k >= 0 && driven_high k then count (k - 1) (n + 1) else n
        in
        count (start_edge - 1) 0
      in
      let frame_end = start_edge + (frame_bits * bit_cycles) in
      if leading_idle < bit_cycles
      then
        error
          [ sprintf
              "idle of %d cycles before the start edge is shorter than one bit period of \
               %d"
              leading_idle
              bit_cycles
          ]
      else if frame_end + bit_cycles > length
      then
        error
          [ sprintf
              "trace ends at %d, before the frame and a bit period of return to idle at \
               %d"
              length
              (frame_end + bit_cycles)
          ]
      else (
        (* Every cycle of a bit slot must be driven and hold one level. *)
        let slot_level index =
          let base = start_edge + (index * bit_cycles) in
          let level = (at base).level in
          List.find
            (List.range base (base + bit_cycles))
            ~f:(fun k -> (not (at k).driven) || Bool.( <> ) (at k).level level)
          |> function
          | Some k when not (at k).driven ->
            Error (sprintf "pin released at cycle %d, inside bit slot %d" k index)
          | Some k ->
            Error
              (sprintf
                 "level changed at cycle %d, %d cycles into bit slot %d"
                 k
                 (k - base)
                 index)
          | None -> Ok level
        in
        match List.map (List.range 0 frame_bits) ~f:slot_level |> Result.all with
        | Error message -> Error message
        | Ok levels ->
          let slots =
            List.mapi levels ~f:(fun index level ->
              { Slot.index
              ; label = label index
              ; level
              ; start_cycle = index * bit_cycles
              ; end_cycle = (index + 1) * bit_cycles
              })
          in
          (* The period the frame's own transitions were drawn on. *)
          let transitions =
            List.filter_map slots ~f:(fun slot ->
              if slot.index = 0
              then Some 0
              else if Bool.( <> ) slot.level (List.nth_exn levels (slot.index - 1))
              then Some slot.start_cycle
              else None)
          in
          let measured_period =
            List.fold
              (List.zip_exn (List.drop_last_exn transitions) (List.tl_exn transitions))
              ~init:(frame_bits * bit_cycles)
              ~f:(fun acc (previous, next) -> gcd acc (next - previous))
          in
          let byte =
            List.foldi (List.sub levels ~pos:1 ~len:8) ~init:0 ~f:(fun index acc level ->
              if level then acc lor (1 lsl index) else acc)
          in
          let trailing_idle =
            List.for_all (List.range frame_end (frame_end + bit_cycles)) ~f:driven_high
          in
          if List.nth_exn levels 0
          then error [ "start bit is not low" ]
          else if not (List.nth_exn levels (frame_bits - 1))
          then error [ "stop bit is not high" ]
          else if measured_period % bit_cycles <> 0
          then
            error
              [ sprintf
                  "measured period %d is not a multiple of the expected %d"
                  measured_period
                  bit_cycles
              ]
          else if not trailing_idle
          then error [ "the line did not return to a driven idle after the stop bit" ]
          else
            Ok
              { byte
              ; measured_period
              ; expected_period = bit_cycles
              ; leading_idle
              ; start_edge
              ; slots
              }))
;;

let decode_exn ~bit_cycles samples =
  match decode ~bit_cycles samples with
  | Ok t -> t
  | Error message -> raise_s [%message "UART monitor rejected the waveform" message]
;;

(* The saved trace: the frame as the receiver timed it, in the one format the model, the
   Hardcaml slice, and the emitted RTL all write. Anything that changes here changes
   [uart_frame.trace] and the Verilog writer beside it. *)
let to_trace t ~byte ~half_period ~tx_pin =
  let line = Buffer.create 512 in
  bprintf line "# protemu P2.7 first working slice -- UART 8N1 transmit frame\n";
  bprintf
    line
    "# byte=0x%02x half_period=%d bit_cycles=%d tx_pin=%d\n"
    byte
    half_period
    t.expected_period
    tx_pin;
  bprintf line "# slot label level start end\n";
  List.iter t.slots ~f:(fun slot ->
    bprintf
      line
      "%d %s %d %d %d\n"
      slot.index
      slot.label
      (Bool.to_int slot.level)
      slot.start_cycle
      slot.end_cycle);
  Buffer.contents line
;;
