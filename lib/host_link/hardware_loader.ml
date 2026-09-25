(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "hardware_loader.ml" *)
(* P3.5 fixed serial loader and Integrated_core request adapter.

   The external host clock is observed through [Serial_phy]'s synchronizers; it never
   clocks logic. The PHY supplies synchronized levels, edge events, and deselect
   qualification. [Frame_rx] receives and validates each request and retains its fields.
   [Command_dispatch] takes the deselect handoff: it offers exactly one core request for a
   complete CRC-protected request, waits for READ/VERIFY and ABORT completion, and selects
   every response frame, publishing it in the cycle it is decided. [Frame_tx] stores the
   published frame and owns response arming, shifting, replay, and commit. Responses are
   retained until explicitly committed, and an interrupted or rejected response restarts
   from byte zero without repeating the command. Program RAM and image validity remain
   exclusively owned by Protocol_core.

   This block is their composition and holds no state. It wires the four together,
   supplies request eligibility from the dispatcher's and transmitter's state, and forms
   [busy_o]. The core-facing side is [Control_port]: [Command_dispatch] produces its
   [Request] and consumes its [Decision] and [Status], under the temporal contract
   recorded there; this block passes the records through.

   Wire values, frame and payload layouts, and CRC parameters come from
   [Protemu_host_link_wire.Wire], the one OCaml definition of the P3.5 wire format. Each
   block, and [Wire_crc], checks its own assumptions about them whenever it is elaborated.
*)

open! Core
open! Hardcaml
open! Signal

module I = struct
  type 'a t =
    { (* System clock domain; reset is synchronous and active high. *)
      clock_i : 'a
    ; reset_i : 'a
    ; enable_i : 'a
    ; (* Asynchronous physical loader pins. Select is active low, clock idles low. *)
      serial_select_n_i : 'a
    ; serial_clock_i : 'a
    ; serial_data_i : 'a
    ; (* Core decisions and status, observed before each edge; see [Control_port]. Each
         field keeps its flat port name, such as [load_start_accepted_i] and [halted_i]. *)
      control_decision_i : 'a Control_port.Decision.t [@rtlsuffix "_i"]
    ; control_status_i : 'a Control_port.Status.t [@rtlsuffix "_i"]
    }
  [@@deriving hardcaml ~rtlmangle:false]
end

module O = struct
  type 'a t =
    { (* Physical response pins. Data is push-pull and meaningful while selected. *)
      serial_data_o : 'a
    ; serial_ready_o : 'a
    ; (* One-shot requests into Integrated_core. Operands remain retained while offered.
         Flat port names, such as [load_start_valid_o]. *)
      control_request_o : 'a Control_port.Request.t [@rtlsuffix "_o"]
    ; busy_o : 'a
    }
  [@@deriving hardcaml ~rtlmangle:false]
end

[@@@ocamlformat "disable"]

let create (scope : Scope.t) (i : _ I.t) : _ O.t =
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
      ; response_publish_i   = dispatch.response_publish_o
      ; response_frame_i     = dispatch.response_frame_o
      ; response_length_i    = dispatch.response_length_o
      }
  in
  Signal.( <-- ) dispatch_busy dispatch.busy_o;
  Signal.( <-- ) response_pending tx.pending_o;

  { O.serial_data_o   = tx.serial_data_o
  ; serial_ready_o    = tx.serial_ready_o
  ; control_request_o = dispatch.control_request_o
  ; busy_o =
      rx.active_o
      |: dispatch.busy_o
      |: tx.pending_o
  }
;;
[@@@ocamlformat "enable"]
