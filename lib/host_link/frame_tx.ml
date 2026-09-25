(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "frame_tx.ml" *)
(* P3.5 serial loader response transmitter: the retained response, response arming, the
   restartable shifter, replay, and commit.

   It consumes [Serial_phy]'s one-cycle events and deselect qualification, and
   [Command_dispatch]'s combinational publication, as plain inputs. A publication stores
   the complete padded frame and its length at that edge and makes the response pending;
   nothing is registered between the dispatcher's decision and the store. A selection
   whose assert event finds a response already pending, after a qualified deselected
   interval, copies the stored frame into the shifter and presents its first bit. Each
   synchronized LCLK fall then advances one bit, MSB first, and a selected pause holds it.
   The release ends the read. It consumes the response only if the fall after the final
   bit came first; otherwise the response stays pending, and the next armed selection
   restarts at byte zero from the unchanged store.

   [pending_o] is the retained-response state the loader combines into request
   eligibility; [serial_ready_o] is the same state gated by enable, for LRDY. Reset clears
   every register. Disable clears pending, the read, and the bit count, but not the store,
   shifter, or length. Nothing can read those again: a new read needs a pending response,
   and only a publication, which rewrites the store and length, makes one.

   [Command_dispatch] owns every frame's content, CRC, and length; this block interprets
   none of it. docs/host_link_hl4b4_record.md records the timing and priority contract.

   Careful: a read copies the store but not the length. A publication during a read, or in
   its arming cycle, changes where that read drains. The loader never publishes while a
   response is retained, so it cannot happen there; the focused robustness tests pin it.
*)

open! Core
open! Hardcaml
open! Signal
module Wire = Protemu_host_link_wire.Wire

(* Response-store sizing derived from the wire limits. *)
module Config = struct
  let max_response_bytes = Wire.Response.max_length
  let response_bits = max_response_bytes * 8
end

(* Elaboration-time checks of the store's fixed register widths against [Wire]. Plain
   OCaml comparisons; they create no logic and cannot change emitted RTL.
*)
let check_wire_encodings () =
  let require condition message =
    if not condition then invalid_arg ("Frame_tx: " ^ message)
  in
  (* [response_length] and [response_bits] are 5 and 8 bits wide. *)
  require (Config.max_response_bytes < 1 lsl 5) "response length register too narrow";
  require (Config.response_bits < 1 lsl 8) "response bit counter too narrow"
;;

module I = struct
  type 'a t =
    { (* System clock domain; reset is synchronous and active high. Disable cancels the
         retained response and any read. *)
      clock_i : 'a
    ; reset_i : 'a
    ; enable_i : 'a
    ; (* Serial_phy -> transmitter: the one-cycle select and LCLK fall events, and whether
         the synchronized selection was deselected for the qualifying interval before this
         cycle. Qualification is read only with a select-assert event. *)
      select_assert_i : 'a
    ; select_release_i : 'a
    ; clock_fall_i : 'a
    ; deselect_qualified_i : 'a
    ; (* Command_dispatch -> transmitter: store this frame at this edge. The frame is
         complete, MSB-first from its top bit, and zero-padded; the length is its byte
         count. There is no ready: the loader keeps requests ineligible while a response
         is pending. *)
      response_publish_i : 'a
    ; response_frame_i : 'a [@bits Config.response_bits]
    ; response_length_i : 'a [@bits 5]
    }
  [@@deriving hardcaml]
end

module O = struct
  type 'a t =
    { (* Physical response pins, low while disabled. Data is meaningful while a read is
         armed and not drained, and low otherwise. *)
      serial_data_o : 'a
    ; serial_ready_o : 'a
    ; (* A response is retained, whatever enable; the loader's request eligibility and
         busy state. *)
      pending_o : 'a
    }
  [@@deriving hardcaml]
end

[@@@ocamlformat "disable"]

(* Registered response state. Fields hold unless explicitly assigned by [compile]; reset
   clears every field, and disable clears pending, active, and bits.

   response_pending : a published response is retained and not yet committed;
   response_active  : a read is armed, from its selection to its release;
   response_store   : the published frame, unchanged by reads;
   response_shift   : the read's copy, shifted left once per fall;
   response_length  : the published frame's byte count;
   response_bits    : falls taken in the current read;
*)
module I_Regs = struct
  type 'a t =
    { response_pending : 'a
    ; response_active  : 'a
    ; response_store   : 'a [@bits Config.response_bits]
    ; response_shift   : 'a [@bits Config.response_bits]
    ; response_length  : 'a [@bits 5]
    ; response_bits    : 'a [@bits 8]
    }
  [@@deriving hardcaml]
end

let create (scope : Scope.t) (i : _ I.t) : _ O.t =
  check_wire_encodings ();
  let open Always in
  let spec = Reg_spec.create ~clock:i.clock_i ~clear:i.reset_i () in
  let r = I_Regs.Of_always.reg spec in
  I_Regs.Of_always.apply_names ~prefix:"reg_" ~naming_op:(Scope.naming scope) r;

  (* Every bit of the frame has been shifted out: the final fall has occurred. *)
  let response_drained =
    r.response_bits.value ==: sll (uresize r.response_length.value ~width:8) ~by:3
  in

  (* Hold by default. Every condition reads registered values, so a publication does not
     arm a selection in its own cycle. Later statements win: a commit or disable clears
     [response_pending] after a coincident publication sets it, and disable is last.
  *)
  compile
    [ r.response_pending <-- r.response_pending.value
    ; r.response_active <-- r.response_active.value
    ; r.response_store <-- r.response_store.value
    ; r.response_shift <-- r.response_shift.value
    ; r.response_length <-- r.response_length.value
    ; r.response_bits <-- r.response_bits.value

    ; (* A handoff error, an immediate response, or a completion, in the cycle
         [Command_dispatch] decides it. Not gated by enable: disable below still wins for
         [response_pending]. *)
      when_ i.response_publish_i
        [ r.response_store <-- i.response_frame_i
        ; r.response_length <-- i.response_length_i
        ; r.response_pending <--. 1
        ]

    ; (* A response selection starts or restarts a retained frame. *)
      when_
        (i.select_assert_i
         &: i.enable_i
         &: r.response_pending.value
         &: i.deselect_qualified_i)
        [ r.response_shift <-- r.response_store.value
        ; r.response_bits <--. 0
        ; r.response_active <--. 1
        ]
    ; when_
        (i.clock_fall_i
         &: r.response_active.value
         &: ~:response_drained)
        [ r.response_shift <-- sll r.response_shift.value ~by:1
        ; r.response_bits <-- r.response_bits.value +:. 1
        ]
    ; (* Release ends the read; only a drained read commits. *)
      when_ (i.select_release_i &: r.response_active.value)
        [ r.response_active <--. 0
        ; if_ response_drained
            [ r.response_pending <--. 0; r.response_bits <--. 0 ]
            []
        ]

    ; (* Disable is cancellation, not a delayed wire timeout. *)
      when_ (~:(i.enable_i))
        [ r.response_pending <--. 0
        ; r.response_active <--. 0
        ; r.response_bits <--. 0
        ]
    ];

  { O.serial_data_o =
      mux2
        (i.enable_i &: r.response_active.value &: ~:response_drained)
        (msb r.response_shift.value)
        gnd
  ; serial_ready_o = i.enable_i &: r.response_pending.value
  ; pending_o      = r.response_pending.value
  }
;;
[@@@ocamlformat "enable"]
