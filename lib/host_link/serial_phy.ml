(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "serial_phy.ml" *)
(* P3.5 serial loader PHY: pin synchronizers, edge events, and deselect qualification.

   [LSEL_N], [LCLK], and [LDI] pass through matching two-stage synchronizers into the
   system clock domain; the host clock never clocks logic. A pin value driven in cycle n
   is visible as a level in cycle n+2, and a change is reported as a one-cycle event in
   that same cycle. Deselect qualification counts synchronized deselected cycles and
   saturates at the threshold response arming uses.

   Every output is a function of this block's registers alone, so reset and disable act
   only through the next edge. Reset clears every register, which reads as deselected with
   [LCLK] and [LDI] low. Disable clears only the qualification count; the synchronizers
   and edge history keep running.

   This block interprets no frame. [Frame_rx] owns request arming and framing,
   [Command_dispatch] dispatch, and [Frame_tx] response arming, the retained response, and
   commit; [Hardware_loader] composes them. docs/host_link_hl4b1_record.md records the
   timing contract.
*)

open! Core
open! Hardcaml
open! Signal

(* Deselected cycles, not counting the current one, that qualify a selection for a
   response read.
*)
let deselect_qualification = 4

module I = struct
  type 'a t =
    { (* System clock domain; reset is synchronous and active high. Disable clears the
         deselect qualification only. *)
      clock_i : 'a
    ; reset_i : 'a
    ; enable_i : 'a
    ; (* Asynchronous physical loader pins. Select is active low, clock idles low. *)
      serial_select_n_i : 'a
    ; serial_clock_i : 'a
    ; serial_data_i : 'a
    }
  [@@deriving hardcaml]
end

module O = struct
  type 'a t =
    { (* Synchronized levels: selection (active high) and LDI. *)
      selected_o : 'a
    ; data_o : 'a
    ; (* One-cycle events, visible in the cycle the synchronized level first changes. *)
      select_assert_o : 'a
    ; select_release_o : 'a
    ; clock_rise_o : 'a
    ; clock_fall_o : 'a
    ; (* The synchronized selection was low (deselected), with enable high and reset low,
         in each of the [deselect_qualification] cycles before this one. *)
      deselect_qualified_o : 'a
    }
  [@@deriving hardcaml]
end

[@@@ocamlformat "disable"]

(* Registered synchronizer and qualification state; [compile] holds each field by default.

   *_meta            : first synchronizer stage, possibly metastable, read only by *_sync;
   *_sync            : second stage, the synchronized level;
   *_previous        : *_sync one cycle earlier, for edge detection;
   select_high_count : consecutive synchronized deselected cycles, saturating at
                       [deselect_qualification];
*)
module I_Regs = struct
  type 'a t =
    { select_meta       : 'a
    ; select_sync       : 'a
    ; select_previous   : 'a
    ; select_high_count : 'a [@bits 3]
    ; clock_meta        : 'a
    ; clock_sync        : 'a
    ; clock_previous    : 'a
    ; data_meta         : 'a
    ; data_sync         : 'a
    }
  [@@deriving hardcaml]
end

let create (scope : Scope.t) (i : _ I.t) : _ O.t =
  let open Always in
  let spec = Reg_spec.create ~clock:i.clock_i ~clear:i.reset_i () in
  let r = I_Regs.Of_always.reg spec in
  I_Regs.Of_always.apply_names ~prefix:"reg_" ~naming_op:(Scope.naming scope) r;

  let selected_async = ~:(i.serial_select_n_i) in

  (* The synchronizers advance every edge. A selection resets the count; otherwise it
     saturates at the threshold. Disable clears the count last, so it wins.
  *)
  compile
    [ (* The three asynchronous inputs use matching two-stage synchronizers. *)
      r.select_meta <-- selected_async
    ; r.select_sync <-- r.select_meta.value
    ; r.select_previous <-- r.select_sync.value
    ; r.select_high_count <-- r.select_high_count.value
    ; r.clock_meta <-- i.serial_clock_i
    ; r.clock_sync <-- r.clock_meta.value
    ; r.clock_previous <-- r.clock_sync.value
    ; r.data_meta <-- i.serial_data_i
    ; r.data_sync <-- r.data_meta.value

    ; if_ r.select_sync.value
        [ r.select_high_count <--. 0 ]
        [ when_ (r.select_high_count.value <:. deselect_qualification)
            [ r.select_high_count <-- r.select_high_count.value +:. 1 ]
        ]

    ; when_ (~:(i.enable_i))
        [ r.select_high_count <--. 0 ]
    ];

  { O.selected_o         = r.select_sync.value
  ; data_o               = r.data_sync.value
  ; select_assert_o      = r.select_sync.value &: ~:(r.select_previous.value)
  ; select_release_o     = ~:(r.select_sync.value) &: r.select_previous.value
  ; clock_rise_o         = r.clock_sync.value &: ~:(r.clock_previous.value)
  ; clock_fall_o         = ~:(r.clock_sync.value) &: r.clock_previous.value
  ; deselect_qualified_o = r.select_high_count.value >=:. deselect_qualification
  }
;;
[@@@ocamlformat "enable"]
