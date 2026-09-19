(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "input_events.ml" *)
(* Two-stage pad synchronizer and six independent sticky event bits. The snapshot and
   edge outputs describe the same registered cycle. New events win over acknowledge. *)

open! Core
open! Hardcaml
open! Signal

module I = struct
  type 'a t =
    { clock_i : 'a
    ; reset_i : 'a
    ; pin_in_i : 'a [@bits 8]
    ; event_set_i : 'a [@bits 6]
    ; event_ack_i : 'a [@bits 6]
    }
  [@@deriving hardcaml]
end

module O = struct
  type 'a t =
    { snapshot_o : 'a [@bits 8]
    ; rising_o : 'a [@bits 8]
    ; falling_o : 'a [@bits 8]
    ; event_o : 'a [@bits 6]
    ; overflow_o : 'a [@bits 6]
    }
  [@@deriving hardcaml]
end

module I_Regs = struct
  (* Registered synchronizer, history, and event status. *)
  type 'a t =
    { stage0 : 'a [@bits 8]
    ; stage1 : 'a [@bits 8]
    ; previous : 'a [@bits 8]
    ; event : 'a [@bits 6]
    ; overflow : 'a [@bits 6]
    }
  [@@deriving hardcaml]
end

let create (scope : Scope.t) (i : _ I.t) : _ O.t =
  let open Always in
  let spec = Reg_spec.create ~clock:i.clock_i ~clear:i.reset_i () in
  let r = I_Regs.Of_always.reg spec in
  I_Regs.Of_always.apply_names ~prefix:"reg_" ~naming_op:(Scope.naming scope) r;
  let lost = r.event.value &: i.event_set_i &: ~:(i.event_ack_i) in
  compile
    [ r.stage0 <-- i.pin_in_i
    ; r.stage1 <-- r.stage0.value
    ; r.previous <-- r.stage1.value
    ; r.event <-- ((r.event.value &: ~:(i.event_ack_i)) |: i.event_set_i)
    ; r.overflow <-- ((r.overflow.value &: ~:(i.event_ack_i)) |: lost)
    ];
  { O.snapshot_o = r.stage1.value
  ; rising_o = r.stage1.value &: ~:(r.previous.value)
  ; falling_o = ~:(r.stage1.value) &: r.previous.value
  ; event_o = r.event.value
  ; overflow_o = r.overflow.value
  }
;;
