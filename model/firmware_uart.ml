(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "firmware_uart.ml" *)
(* UART 8N1 transmit, built two ways on purpose.

   [tx_8n1] is one validated transfer descriptor: ten bits, least significant first, with
   the start and stop bits folded into the shifted word. The emitted lane RTL receives the
   same transaction parameters, which is what makes it the model side of the P2.7
   comparison.

   [tx_sequence] is the same frame bit-banged out of pin writes and countdowns through
   [Firmware]. It exists to be more expensive than the descriptor, and to say by how much:
   two operations per bit against one configure, and a bit period that cannot go below
   three cycles. That is the measurement P1.4 needs when it weighs an instruction stream
   against a transfer engine, and it is the reason the engine is in the architecture at
   all.

   Both agree on the frame: idle high, a low start bit, eight data bits least significant
   first, then a high stop bit, each bit lasting two half periods.
*)

open! Core
open! Kinds

(* Start bit low, byte, stop bit high, laid out from the least significant bit up. *)
let frame_word byte = (1 lsl 9) lor (byte lsl 1)

let tx_8n1 ~pin ~half_period ~byte =
  if byte < 0 || byte > 255
  then Error (Fault.Reject.Data_out_of_range byte)
  else (
    let descriptor : Transfer.t =
      { direction = Tx_only
      ; bit_count = 10
      ; bit_order = Lsb_first
      ; tx_value = frame_word byte
      ; output_pin = Some pin
      ; input_pin = None
      ; clock_pin = None
      ; idle_output = true
      ; idle_clock = false
      ; initial_delay = None
      ; launch = Clock_phase.On_falling
      ; sample = Clock_phase.On_rising
      ; pacing = Transfer.Pacing.Internal { half_period }
      }
    in
    Result.map (Transfer.validate descriptor) ~f:(fun () -> descriptor))
;;

(* The ten frame bits with the label each one carries in a trace. *)
let frame_bits byte =
  (("start", false) :: List.init 8 ~f:(fun i -> sprintf "d%d" i, byte land (1 lsl i) <> 0))
  @ [ "stop", true ]
;;

(* The same frame as a firmware sequence. One bit is [2 * half_period] cycles, matching
   [Uart_tx], so a half period below two cannot be bit-banged at all: see
   [Firmware.phase]. The leading idle bit both drives the line to its resting level and
   gives the receiver a full bit of idle before the start edge. *)
let tx_sequence ~pin ~half_period ~byte =
  let ( >>= ) result f = Result.bind result ~f in
  let bit_cycles = 2 * half_period in
  let drive ~label ~level =
    Firmware.phase
      ~label
      ~write:
        (Pin_bank.Write.push_pull ~mask:(1 lsl pin) ~value:(Bool.to_int level lsl pin))
      ~cycles:bit_cycles
  in
  if byte < 0 || byte > 255
  then Error (Firmware.Invalid.Out_of_range { what = "byte"; value = byte })
  else
    drive ~label:"idle" ~level:true
    >>= fun idle ->
    List.fold_result (frame_bits byte) ~init:[] ~f:(fun acc (label, level) ->
      Result.map (drive ~label ~level) ~f:(fun steps -> steps :: acc))
    >>= fun frame ->
    Firmware.create
      ~name:(sprintf "uart_tx_8n1_0x%02x" byte)
      (idle @ List.concat (List.rev frame))
;;
