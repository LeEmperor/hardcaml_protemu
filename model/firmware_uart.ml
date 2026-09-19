(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "firmware_uart.ml" *)
(* A typed first-slice UART 8N1 transmit descriptor. It contains mechanism fields,
   while the emitted lane RTL receives the same validated transaction parameters. *)

open! Core
open! Kinds

let frame_word byte = (1 lsl 9) lor (byte lsl 1)

let tx_8n1 ~pin ~half_period ~byte =
  if byte < 0 || byte > 255 then Error (Fault.Reject.Data_out_of_range byte)
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
