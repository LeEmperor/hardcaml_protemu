(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "uart_tx.ml" *)
(* A transmit-only 8N1 UART wrapper around Shift_lane.

   A byte offered on [byte_valid_i] while [byte_ready_o] is high requests a ten-bit,
   least-significant-bit-first lane transaction: start=0, eight data bits, stop=1.
   Shift_lane owns the transfer timing and result pulses; this module supplies the
   fixed UART descriptor and maps the lane's drive onto the chosen output pin.

   One bit lasts twice [half_period_i] cycles. A zero half period is rejected by
   Shift_lane. There is no receive path or byte queue here: the producer must use
   the ready/valid handshake for each byte and check [rejected_o].
*)

open! Core
open! Hardcaml
open! Signal

(* UART request and pin selection, sampled in the [clock_i] domain. *)
module I = struct
  type 'a t =
    { (* Synchronous active-high reset; disabling or aborting releases the pin. *)
      clock_i : 'a
    ; reset_i : 'a
    ; enable_i : 'a
    ; abort_i : 'a
    ; (* Producer -> UART. Offered on an edge with [byte_ready_o] high. *)
      byte_valid_i : 'a
    ; byte_i : 'a [@bits 8]
    ; (* Half-bit duration in clock cycles, and the selected physical pin 0..7. *)
      half_period_i : 'a [@bits 16]
    ; tx_pin_i : 'a [@bits 3]
    }
  [@@deriving hardcaml]
end

(* UART handshake, pin drive, and Shift_lane result pulses. *)
module O = struct
  type 'a t =
    { byte_ready_o : 'a
    ; (* Only the selected pin is driven; an idle enabled UART drives it high. *)
      pins_o : 'a [@bits 8]
    ; pin_oe_o : 'a [@bits 8]
    ; busy_o : 'a
    ; done_o : 'a
    ; rejected_o : 'a
    }
  [@@deriving hardcaml]
end

[@@@ocamlformat "disable"]
(* Fix the lane descriptor to 8N1 transmit and expose its pin drive;

   [tx_value_i] is laid out from least to most significant bit. 
   Low zero is the start bit, followed by [byte_i] and the high stop bit. 
   Upper 22 bits are zero because Shift_lane's descriptor is 32 bits wide.
*)
let create (scope : Scope.t) (i : _ I.t) : _ O.t =

  (* byte count mask form on the input set *)
  let tx_mask = Shift_lane.pin_mask i.tx_pin_i in

  (* The lane accepts the byte directly; no buffering lives in this wrapper. *)
  let lane =
    Shift_lane.create
      (Scope.sub_scope scope "lane")
      { Shift_lane.I.clock_i  = i.clock_i
      ; reset_i               = i.reset_i
      ; enable_i              = i.enable_i
      ; abort_i               = i.abort_i
      ; start_valid_i         = i.byte_valid_i
      ; arm_i                 = gnd
      ; start_event_i         = gnd
      ; bit_count_i           = of_int_trunc ~width:6 10
      ; tx_value_i            = concat_msb [ zero 22; vdd; i.byte_i; gnd ]
      ; tx_valid_i            = vdd
      ; rx_ready_i            = vdd
      ; tx_enable_i           = vdd
      ; rx_enable_i           = gnd
      ; lsb_first_i           = vdd
      ; output_pin_i          = i.tx_pin_i
      ; input_pin_i           = zero 3
      ; clock_pin_i           = zero 3
      ; clock_enable_i        = gnd
      ; idle_output_i         = vdd
      ; idle_clock_i          = gnd
      ; initial_delay_i       = zero 16
      ; half_period_i         = i.half_period_i
      ; launch_trailing_i     = vdd
      ; sample_trailing_i     = gnd
      ; observed_i            = gnd
      ; observed_edge_i       = gnd
      ; pin_in_i              = zero 8
      ; occupied_i            = zero 8
      }
  in

  (* Release the physical pin immediately on disable, reset, or abort, even though
     the lane's registered state changes only at the next edge. 
  *)
  let active = i.enable_i &: 
                ~:(i.reset_i) &: 
                ~:(i.abort_i) in

  { O.byte_ready_o  = lane.ready_o
  ; pins_o          = mux2 active (mux2 lane.busy_o lane.pin_value_o tx_mask) (zero 8)
  ; pin_oe_o        = mux2 active (mux2 lane.busy_o lane.pin_oe_o tx_mask) (zero 8)
  ; busy_o          = lane.busy_o
  ; done_o          = lane.done_o
  ; rejected_o      = lane.rejected_o
  }
;;
[@@@ocamlformat "enable"]
