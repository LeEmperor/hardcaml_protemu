(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "host_link.ml" *)
(*
  The complete serial host-control endpoint. This can be thought of as a large IP block that would go into an ASIC where the customer is other people on the chip itself.
*)

open! Core
open! Hardcaml
open! Signal

module I = struct
  type 'a t = 
  {
      clock_i   : 'a
    ; reset_i   : 'a
    ; enable_i  : 'a

    (* select is active low, clock idles low; built in loose symmetry to SPI *)
    ; serial_select_n_i : 'a
    ; serial_clock_i    : 'a (* fed from the master; in this case the external clock pin *)
    ; serial_data_i     : 'a

    (* These are the wrapped words that are input/output *)
    (* do these not have some sort of backpressure emission scheme? *)
    (* The fanout on these is VERY LARGE; be warned here, as the interface nesting is much more intense than you might think; *)
    ; control_decision_i : 'a Control_port.Decision.t [@rtlsuffix "_i"]

    (* This is our status bus; In theory we include a pin that does some sort of scan chain thing for DFT? *)
    ; control_status_i : 'a Control_port.Status.t [@rtlsuffix "_i"]
  } [@@deriving hardcaml ~rtlmangle:false]
end

module O = struct
  type 'a t = 
    {
      (* the data *)
      serial_data_o       : 'a

      (* Highkey no idea what this is for; and why it isnt a valid signal instead? *)
    ; serial_ready_o      : 'a

    (* This is the emitted request the serial link is making to the control core; *)
    ; control_request_o   : 'a Control_port.Request.t [@rtlsuffix "_o"]

    (* Main busy designator. A proper CSR block might be in order; we'll see. *)
    ; busy_o              : 'a
    } [@@deriving hardcaml ~rtlmangle:false]
end

[@@@ocamlformat "disable"]

let create 
  (scope : Scope.t) 
  (i : _ I.t) 
  : _ O.t =

  (* Synchronized pins and their one-cycle events; see [Serial_phy] for their timing. *)
  let phy =
    Serial_phy.create
      (Scope.sub_scope scope "serial_phy")
      { Serial_phy.I.clock_i = i.clock_i
      ; reset_i              = i.reset_i
      ; enable_i             = i.enable_i
      ; serial_select_n_i    = i.serial_select_n_i
      ; serial_clock_i       = i.serial_clock_i
      ; serial_data_i        = i.serial_data_i
      }
  in

  let select_assert      = phy.select_assert_o in
  let select_release     = phy.select_release_o in
  let clock_rise         = phy.clock_rise_o in
  let clock_fall         = phy.clock_fall_o in
  let deselect_qualified = phy.deselect_qualified_o in

  (* A request may start only while no command, completion wait, or retained response
     exists, so [Frame_rx]'s retained fields hold for as long as [Command_dispatch] reads
     them. Eligibility reads the retained response itself, not the enable-gated
     [serial_ready_o]. [dispatch_busy] and [response_pending] are joined once their blocks
     exist; both are registered, so the loops through [Frame_rx] are not combinational.
  *)
  let dispatch_busy    = Signal.wire 1 in
  let response_pending = Signal.wire 1 in
  let rx =
    Frame_rx.create
      (Scope.sub_scope scope "frame_rx")
      { Frame_rx.I.clock_i = i.clock_i
      ; reset_i            = i.reset_i
      ; enable_i           = i.enable_i
      ; selected_i         = phy.selected_o
      ; data_i             = phy.data_o
      ; select_assert_i    = select_assert
      ; select_release_i   = select_release
      ; clock_rise_i       = clock_rise
      ; eligible_i         = ~:dispatch_busy &: ~:response_pending
      }
  in

  let dispatch_response_publish = Signal.wire Frame_tx.I.port_widths.response_publish_i in
  let dispatch_response_frame   = Signal.wire Frame_tx.I.port_widths.response_frame_i in
  let dispatch_response_length  = Signal.wire Frame_tx.I.port_widths.response_length_i in

  (* The published response, retained until a read of it is committed. *)
  let tx =
    Frame_tx.create
      (Scope.sub_scope scope "frame_tx")
      { Frame_tx.I.clock_i   = i.clock_i
      ; reset_i              = i.reset_i
      ; enable_i             = i.enable_i
      ; select_assert_i      = select_assert
      ; select_release_i     = select_release
      ; clock_fall_i         = clock_fall
      ; deselect_qualified_i = deselect_qualified
      ; response_publish_i   = dispatch_response_publish
      ; response_frame_i     = dispatch_response_frame
      ; response_length_i    = dispatch_response_length
      }
  in

  (* Offers, completion waits, and the response to store, from the handoff onward. *)
  let dispatch =
    Command_dispatch.create
      (Scope.sub_scope scope "command_dispatch")
      { Command_dispatch.I.clock_i = i.clock_i
      ; reset_i                    = i.reset_i
      ; enable_i                   = i.enable_i
      ; frame_end_i                = rx.frame_end_o
      ; result_i                   = rx.result_o
      ; echo_valid_i               = rx.echo_valid_o
      ; tag_i                      = rx.tag_o
      ; command_i                  = rx.command_o
      ; payload_length_i           = rx.payload_length_o
      ; payload_i                  = rx.payload_o
      ; control_decision_i         = i.control_decision_i
      ; control_status_i           = i.control_status_i
      }
  in

  (* Backwards assignments; *)
  Signal.( <-- ) response_pending           tx.pending_o;
  Signal.( <-- ) dispatch_busy              dispatch.busy_o;
  Signal.( <-- ) dispatch_response_publish  dispatch.response_publish_o;
  Signal.( <-- ) dispatch_response_frame    dispatch.response_frame_o;
  Signal.( <-- ) dispatch_response_length   dispatch.response_length_o;

  let busy = 
    tx.pending_o
    |: rx.active_o 
    |: dispatch.busy_o
  in

  { O.
    serial_data_o     = tx.serial_data_o
  ; serial_ready_o    = tx.serial_ready_o
  ; control_request_o = dispatch.control_request_o
  ; busy_o            = busy
  }
;;
[@@@ocamlformat "enable"]
