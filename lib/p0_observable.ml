(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "p0_observable.ml" *)
(* Minimal observable pin/timer circuit for construction phase P0.

   A command accepted at edge [k] with delay [n] commits its pin value and output enable
   together at edge [k+n]. Delay zero is rejected. Reset and disable synchronously cancel
   an active command and release every pin.
*)

open! Core
open! Hardcaml
open! Signal

module I = struct
  type 'a t =
    { (* System clock domain. Synchronous active-high reset. *)
      clock_i : 'a
    ; reset_i : 'a
    ; enable_i : 'a
    ; (* Direct command harness. Parameters are latched when valid and ready are high. *)
      command_valid_i : 'a
    ; delay_i : 'a [@bits 4]
    ; pin_value_i : 'a [@bits 8]
    ; pin_oe_i : 'a [@bits 8]
    }
  [@@deriving hardcaml]
end

module O = struct
  type 'a t =
    { pins_o : 'a [@bits 8]
    ; pin_oe_o : 'a [@bits 8]
    ; timer_o : 'a [@bits 4]
    ; ready_o : 'a
    ; busy_o : 'a
    ; done_o : 'a
    ; rejected_o : 'a
    }
  [@@deriving hardcaml]
end

(* Registered state. Every field is assigned inside [compile]. *)
module I_Regs = struct
  type 'a t =
    { pins : 'a [@bits 8]
    ; pin_oe : 'a [@bits 8]
    ; timer : 'a [@bits 4]
    ; pending_pin_value : 'a [@bits 8]
    ; pending_pin_oe : 'a [@bits 8]
    ; busy : 'a
    ; done_ : 'a
    ; rejected : 'a
    }
  [@@deriving hardcaml]
end

let create (scope : Scope.t) (i : _ I.t) : _ O.t =
  let open Always in
  let spec = Reg_spec.create ~clock:i.clock_i ~clear:i.reset_i () in
  let r = I_Regs.Of_always.reg spec in
  I_Regs.Of_always.apply_names ~prefix:"reg_" ~naming_op:(Scope.naming scope) r;
  let accepting = i.command_valid_i &: ~:(r.busy.value) in
  compile
    [ r.pins <-- r.pins.value
    ; r.pin_oe <-- r.pin_oe.value
    ; r.timer <-- r.timer.value
    ; r.pending_pin_value <-- r.pending_pin_value.value
    ; r.pending_pin_oe <-- r.pending_pin_oe.value
    ; r.busy <-- r.busy.value
    ; r.done_ <--. 0
    ; r.rejected <--. 0
    ; if_
        ~:(i.enable_i)
        [ r.pins <--. 0; r.pin_oe <--. 0; r.timer <--. 0; r.busy <--. 0 ]
        [ if_
            r.busy.value
            [ if_
                (r.timer.value ==:. 1)
                [ r.pins <-- r.pending_pin_value.value
                ; r.pin_oe <-- r.pending_pin_oe.value
                ; r.timer <--. 0
                ; r.busy <--. 0
                ; r.done_ <--. 1
                ]
                [ r.timer <-- r.timer.value -:. 1 ]
            ]
            [ when_
                accepting
                [ if_
                    (i.delay_i ==:. 0)
                    [ r.rejected <--. 1 ]
                    [ r.pending_pin_value <-- i.pin_value_i
                    ; r.pending_pin_oe <-- i.pin_oe_i
                    ; r.timer <-- i.delay_i
                    ; r.busy <--. 1
                    ]
                ]
            ]
        ]
    ];
  { O.pins_o = r.pins.value
  ; pin_oe_o = r.pin_oe.value
  ; timer_o = r.timer.value
  ; ready_o = i.enable_i &: ~:(r.busy.value)
  ; busy_o = r.busy.value
  ; done_o = r.done_.value
  ; rejected_o = r.rejected.value
  }
;;
