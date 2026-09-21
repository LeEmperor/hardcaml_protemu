(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "observed_transfer_bank.ml" *)
(* Connect one observed transfer to the registered pin bank.

   The bridge reserves the configured output pin when the arm is accepted, before an
   asynchronous start can activate the lane. Lane writes then take one additional clock to
   reach the bank. Completion and local cancellation first commit a released output enable
   and release ownership on the following edge; reset, disable, and explicit abort retain
   the bank's global-release semantics.

   Software requests share the bank port. An internal bridge request has priority and a
   simultaneous software request is explicitly refused rather than silently dropped. *)

open! Core
open! Hardcaml
open! Signal

module I = struct
  type 'a t =
    { (* System clock domain. Reset, disable, and abort release the whole bank. *)
      clock_i : 'a
    ; reset_i : 'a
    ; enable_i : 'a
    ; abort_i : 'a
    ; pin_async_i : 'a [@bits 8]
    ; (* Observed-transfer arm and descriptor. *)
      arm_valid_i : 'a
    ; start_pin_i : 'a [@bits 3]
    ; start_edge_kind_i : 'a [@bits 2]
    ; pacing_pin_i : 'a [@bits 3]
    ; pacing_edge_kind_i : 'a [@bits 2]
    ; cancel_enable_i : 'a
    ; cancel_pin_i : 'a [@bits 3]
    ; cancel_edge_kind_i : 'a [@bits 2]
    ; bit_count_i : 'a [@bits 6]
    ; tx_value_i : 'a [@bits 32]
    ; tx_valid_i : 'a
    ; rx_ready_i : 'a
    ; tx_enable_i : 'a
    ; rx_enable_i : 'a
    ; lsb_first_i : 'a
    ; output_pin_i : 'a [@bits 3]
    ; input_pin_i : 'a [@bits 3]
    ; idle_output_i : 'a
    ; idle_clock_i : 'a
    ; launch_trailing_i : 'a
    ; sample_trailing_i : 'a
    ; occupied_i : 'a [@bits 8]
    ; (* Software side of the shared pin bank. Requests are one-cycle offers. *)
      software_claim_valid_i : 'a
    ; software_claim_mask_i : 'a [@bits 8]
    ; software_release_valid_i : 'a
    ; software_release_mask_i : 'a [@bits 8]
    ; software_write_valid_i : 'a
    ; software_write_mask_i : 'a [@bits 8]
    ; software_write_value_i : 'a [@bits 8]
    ; software_write_open_drain_i : 'a
    ; software_write_oe_i : 'a [@bits 8]
    }
  [@@deriving hardcaml]
end

module O = struct
  type 'a t =
    { arm_ready_o : 'a
    ; transaction_done_o : 'a
    ; transaction_rejected_o : 'a
    ; software_rejected_o : 'a
    ; snapshot_o : 'a [@bits 8]
    ; start_edge_o : 'a
    ; pacing_edge_o : 'a
    ; cancel_edge_o : 'a
    ; armed_o : 'a
    ; busy_o : 'a
    ; lane_claim_o : 'a [@bits 8]
    ; lane_pin_value_o : 'a [@bits 8]
    ; lane_pin_oe_o : 'a [@bits 8]
    ; done_o : 'a
    ; rx_valid_o : 'a
    ; rx_data_o : 'a [@bits 32]
    ; rejected_o : 'a
    ; underrun_o : 'a
    ; overrun_o : 'a
    ; (* Registered bank outputs are the observable boundary of this composition. *)
      pins_o : 'a [@bits 8]
    ; pin_oe_o : 'a [@bits 8]
    ; software_claim_o : 'a [@bits 8]
    ; engine_claim_o : 'a [@bits 8]
    ; bank_rejected_o : 'a
    ; bank_conflict_o : 'a
    }
  [@@deriving hardcaml]
end

module States = struct
  type t =
    | Idle_s
    | Run_s
    | Release_s
  [@@deriving sexp_of, compare ~localize, enumerate]
end

(* The output reservation accepted with the arm. *)
module I_Regs = struct
  type 'a t =
    { claim_mask : 'a [@bits 8]
    ; software_rejected : 'a
    ; transaction_rejected : 'a
    ; internal_pending : 'a
    ; claim_pending : 'a
    }
  [@@deriving hardcaml]
end

(* Internal bank operations and completion status. All default low. *)
module I_Wires = struct
  type 'a t =
    { claim : 'a
    ; write : 'a
    ; clear : 'a
    ; release : 'a
    ; local_abort : 'a
    ; transaction_done : 'a
    ; transaction_rejected : 'a
    }
  [@@deriving hardcaml]
end

let create (scope : Scope.t) (i : _ I.t) : _ O.t =
  let open Always in
  let spec = Reg_spec.create ~clock:i.clock_i ~clear:i.reset_i () in
  let sm = State_machine.create (module States) spec in
  let r = I_Regs.Of_always.reg spec in
  I_Regs.Of_always.apply_names ~prefix:"reg_" ~naming_op:(Scope.naming scope) r;
  let w = I_Wires.Of_always.wire Signal.zero in
  I_Wires.Of_always.apply_names ~prefix:"wire_" ~naming_op:(Scope.naming scope) w;
  let halt = ~:(i.enable_i) |: i.abort_i in
  let arm_ready = sm.is Idle_s &: ~:halt in
  let arm_fire = i.arm_valid_i &: arm_ready in
  let request_mask = mux2 i.tx_enable_i (Shift_lane.pin_mask i.output_pin_i) (zero 8) in
  let mask_nonzero = r.claim_mask.value <>:. 0 in
  let transfer_abort = i.abort_i |: w.local_abort.value in
  let bank_output = wire 8 in
  let transfer =
    Observed_transfer.create
      (Scope.sub_scope scope "transfer")
      { Observed_transfer.I.clock_i = i.clock_i
      ; reset_i = i.reset_i
      ; enable_i = i.enable_i
      ; abort_i = transfer_abort
      ; pin_async_i = i.pin_async_i
      ; arm_valid_i = arm_fire
      ; start_pin_i = i.start_pin_i
      ; start_edge_kind_i = i.start_edge_kind_i
      ; pacing_pin_i = i.pacing_pin_i
      ; pacing_edge_kind_i = i.pacing_edge_kind_i
      ; cancel_enable_i = i.cancel_enable_i
      ; cancel_pin_i = i.cancel_pin_i
      ; cancel_edge_kind_i = i.cancel_edge_kind_i
      ; bit_count_i = i.bit_count_i
      ; tx_value_i = i.tx_value_i
      ; tx_valid_i = i.tx_valid_i
      ; rx_ready_i = i.rx_ready_i
      ; tx_enable_i = i.tx_enable_i
      ; rx_enable_i = i.rx_enable_i
      ; lsb_first_i = i.lsb_first_i
      ; output_pin_i = i.output_pin_i
      ; input_pin_i = i.input_pin_i
      ; idle_output_i = i.idle_output_i
      ; idle_clock_i = i.idle_clock_i
      ; launch_trailing_i = i.launch_trailing_i
      ; sample_trailing_i = i.sample_trailing_i
      ; occupied_i = i.occupied_i |: bank_output
      }
  in
  let internal_request =
    w.claim.value |: w.write.value |: w.clear.value |: w.release.value
  in
  let software_request =
    i.software_claim_valid_i |: i.software_release_valid_i |: i.software_write_valid_i
  in
  let software_rejected = internal_request &: software_request in
  let software_allowed = ~:internal_request in
  let bank =
    Pin_bank.create
      (Scope.sub_scope scope "bank")
      { Pin_bank.I.clock_i = i.clock_i
      ; reset_i = i.reset_i
      ; enable_i = i.enable_i
      ; abort_i = i.abort_i
      ; claim_valid_i = w.claim.value |: (software_allowed &: i.software_claim_valid_i)
      ; claim_engine_i = w.claim.value
      ; claim_mask_i = mux2 w.claim.value request_mask i.software_claim_mask_i
      ; release_valid_i =
          w.release.value |: (software_allowed &: i.software_release_valid_i)
      ; release_engine_i = w.release.value
      ; release_mask_i = mux2 w.release.value r.claim_mask.value i.software_release_mask_i
      ; write_valid_i =
          w.write.value |: w.clear.value |: (software_allowed &: i.software_write_valid_i)
      ; write_engine_i = w.write.value |: w.clear.value
      ; write_mask_i =
          mux2 (w.write.value |: w.clear.value) r.claim_mask.value i.software_write_mask_i
      ; write_value_i =
          mux2
            w.write.value
            transfer.pin_value_o
            (mux2 w.clear.value (zero 8) i.software_write_value_i)
      ; write_open_drain_i =
          software_allowed &: i.software_write_valid_i &: i.software_write_open_drain_i
      ; write_oe_i =
          mux2
            w.write.value
            transfer.pin_oe_o
            (mux2 w.clear.value (zero 8) i.software_write_oe_i)
      }
  in
  assign bank_output bank.software_claim_o;
  let internal_bank_rejected = bank.rejected_o &: r.internal_pending.value in
  let internal_claim_rejected = internal_bank_rejected &: r.claim_pending.value in
  compile
    [ r.claim_mask <-- r.claim_mask.value
    ; r.software_rejected <-- software_rejected
    ; r.transaction_rejected <-- w.transaction_rejected.value
    ; r.internal_pending <-- internal_request
    ; r.claim_pending <-- w.claim.value
    ; sm.switch
        ~default:[]
        [ ( Idle_s
          , [ when_
                arm_fire
                [ r.claim_mask <-- request_mask
                ; when_ (request_mask <>:. 0) [ w.claim <--. 1 ]
                ]
            ] )
        ; ( Run_s
          , [ if_
                internal_bank_rejected
                [ w.local_abort <--. 1
                ; w.transaction_rejected <--. 1
                ; when_ (~:internal_claim_rejected &: mask_nonzero) [ w.clear <--. 1 ]
                ]
                [ if_
                    (transfer.rejected_o |: transfer.underrun_o |: transfer.overrun_o)
                    [ w.local_abort <--. 1
                    ; w.transaction_rejected <--. 1
                    ; when_ mask_nonzero [ w.clear <--. 1 ]
                    ]
                    [ if_
                        (transfer.cancel_edge_o |: transfer.done_o)
                        [ when_ mask_nonzero [ w.clear <--. 1 ] ]
                        [ when_ (transfer.busy_o &: mask_nonzero) [ w.write <--. 1 ] ]
                    ]
                ]
            ] )
        ; ( Release_s
          , [ when_ mask_nonzero [ w.release <--. 1 ]; w.transaction_done <--. 1 ] )
        ]
    ; sm.switch
        ~default:[ sm.set_next Idle_s ]
        [ Idle_s, [ when_ arm_fire [ sm.set_next Run_s ] ]
        ; ( Run_s
          , [ if_
                internal_bank_rejected
                [ if_
                    internal_claim_rejected
                    [ sm.set_next Idle_s ]
                    [ sm.set_next Release_s ]
                ]
                [ if_
                    (transfer.rejected_o
                     |: transfer.underrun_o
                     |: transfer.overrun_o
                     |: transfer.cancel_edge_o
                     |: transfer.done_o)
                    [ sm.set_next Release_s ]
                    [ sm.set_next Run_s ]
                ]
            ] )
        ; Release_s, [ sm.set_next Idle_s ]
        ]
    ; when_
        halt
        [ w.claim <--. 0
        ; w.write <--. 0
        ; w.clear <--. 0
        ; w.release <--. 0
        ; w.local_abort <--. 0
        ; w.transaction_done <--. 0
        ; w.transaction_rejected <--. 0
        ; sm.set_next Idle_s
        ]
    ];
  { O.arm_ready_o = arm_ready
  ; transaction_done_o = w.transaction_done.value
  ; transaction_rejected_o = r.transaction_rejected.value
  ; software_rejected_o = r.software_rejected.value
  ; snapshot_o = transfer.snapshot_o
  ; start_edge_o = transfer.start_edge_o
  ; pacing_edge_o = transfer.pacing_edge_o
  ; cancel_edge_o = transfer.cancel_edge_o
  ; armed_o = transfer.armed_o
  ; busy_o = transfer.busy_o
  ; lane_claim_o = transfer.claim_mask_o
  ; lane_pin_value_o = transfer.pin_value_o
  ; lane_pin_oe_o = transfer.pin_oe_o
  ; done_o = transfer.done_o
  ; rx_valid_o = transfer.rx_valid_o
  ; rx_data_o = transfer.rx_data_o
  ; rejected_o = transfer.rejected_o
  ; underrun_o = transfer.underrun_o
  ; overrun_o = transfer.overrun_o
  ; pins_o = bank.pins_o
  ; pin_oe_o = bank.pin_oe_o
  ; software_claim_o = bank.software_claim_o
  ; engine_claim_o = bank.engine_claim_o
  ; bank_rejected_o = bank.rejected_o
  ; bank_conflict_o = bank.conflict_o
  }
;;
