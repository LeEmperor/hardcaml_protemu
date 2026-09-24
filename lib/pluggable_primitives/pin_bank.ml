(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "pin_bank.ml" *)
(* Eight registered protocol pins. Claims are exclusive between software and one engine.
   A commit and its value/enable bits take effect together at the accepting edge. *)

open! Core
open! Hardcaml
open! Signal

module I = struct
  type 'a t =
    { clock_i : 'a
    ; reset_i : 'a
    ; enable_i : 'a
    ; abort_i : 'a
    ; claim_valid_i : 'a
    ; claim_engine_i : 'a
    ; claim_mask_i : 'a [@bits 8]
    ; release_valid_i : 'a
    ; release_engine_i : 'a
    ; release_mask_i : 'a [@bits 8]
    ; write_valid_i : 'a
    ; write_engine_i : 'a
    ; write_mask_i : 'a [@bits 8]
    ; write_value_i : 'a [@bits 8]
    ; write_open_drain_i : 'a
    ; write_oe_i : 'a [@bits 8]
    }
  [@@deriving hardcaml]
end

module O = struct
  type 'a t =
    { pins_o : 'a [@bits 8]
    ; pin_oe_o : 'a [@bits 8]
    ; software_claim_o : 'a [@bits 8]
    ; engine_claim_o : 'a [@bits 8]
    ; rejected_o : 'a
    ; conflict_o : 'a
    }
  [@@deriving hardcaml]
end

module I_Regs = struct
  (* Registered outputs, ownership, and sticky conflict. *)
  type 'a t =
    { pins : 'a [@bits 8]
    ; pin_oe : 'a [@bits 8]
    ; software_claim : 'a [@bits 8]
    ; engine_claim : 'a [@bits 8]
    ; rejected : 'a
    ; conflict : 'a
    }
  [@@deriving hardcaml]
end

let create (scope : Scope.t) (i : _ I.t) : _ O.t =
  let open Always in
  let spec = Reg_spec.create ~clock:i.clock_i ~clear:i.reset_i () in
  let r = I_Regs.Of_always.reg spec in
  I_Regs.Of_always.apply_names ~prefix:"reg_" ~naming_op:(Scope.naming scope) r;
  let other_claim =
    mux2 i.write_engine_i r.software_claim.value r.engine_claim.value
  in
  let claim_other =
    mux2 i.claim_engine_i r.software_claim.value r.engine_claim.value
  in
  let release_held =
    mux2 i.release_engine_i r.engine_claim.value r.software_claim.value
  in
  let claim_conflict = (i.claim_mask_i &: claim_other) <>:. 0 in
  let write_conflict = (i.write_mask_i &: other_claim) <>:. 0 in
  let release_invalid = (i.release_mask_i &: ~:release_held) <>:. 0 in
  let write_value = mux2 i.write_open_drain_i (zero 8) i.write_value_i in
  (* At most one ownership or write request is accepted per edge. A simultaneous
     request is refused, so there is no ambiguous old/new ownership ordering. *)
  let multiple =
    (i.claim_valid_i &: (i.release_valid_i |: i.write_valid_i))
    |: (i.release_valid_i &: i.write_valid_i)
  in
  let rejected =
    multiple
    |: (i.claim_valid_i &: claim_conflict)
    |: (i.release_valid_i &: release_invalid)
    |: (i.write_valid_i &: write_conflict)
  in
  compile
    [ r.pins <-- r.pins.value
    ; r.pin_oe <-- r.pin_oe.value
    ; r.software_claim <-- r.software_claim.value
    ; r.engine_claim <-- r.engine_claim.value
    ; r.rejected <--. 0
    ; r.conflict <-- r.conflict.value
    ; if_
        (~:(i.enable_i) |: i.abort_i)
        [ r.pins <--. 0
        ; r.pin_oe <--. 0
        ; r.software_claim <--. 0
        ; r.engine_claim <--. 0
        ]
        [ if_
            rejected
            [ r.rejected <--. 1
            ; when_
                ((i.claim_valid_i &: claim_conflict)
                 |: (i.write_valid_i &: write_conflict))
                [ r.conflict <--. 1 ]
            ]
            [ when_
                i.claim_valid_i
                [ if_
                    i.claim_engine_i
                    [ r.engine_claim <-- (r.engine_claim.value |: i.claim_mask_i) ]
                    [ r.software_claim <-- (r.software_claim.value |: i.claim_mask_i) ]
                ]
            ; when_
                i.release_valid_i
                [ if_
                    i.release_engine_i
                    [ r.engine_claim <-- (r.engine_claim.value &: ~:(i.release_mask_i)) ]
                    [ r.software_claim <-- (r.software_claim.value &: ~:(i.release_mask_i)) ]
                ]
            ; when_
                i.write_valid_i
                [ r.pins
                  <-- ((r.pins.value &: ~:(i.write_mask_i))
                       |: (write_value &: i.write_mask_i))
                ; r.pin_oe
                  <-- ((r.pin_oe.value &: ~:(i.write_mask_i))
                       |: (i.write_oe_i &: i.write_mask_i))
                ]
            ]
        ]
    ];
  { O.pins_o = r.pins.value
  ; pin_oe_o = r.pin_oe.value
  ; software_claim_o = r.software_claim.value
  ; engine_claim_o = r.engine_claim.value
  ; rejected_o = r.rejected.value
  ; conflict_o = r.conflict.value
  }
;;
