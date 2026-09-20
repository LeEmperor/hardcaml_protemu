(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "uart_slice.ml" *)
(* P2.7's first working slice: one 8N1 frame driven through the pin and timer hardware.

   [Uart_tx] proves the frame; it does not prove the path. Its pin drive comes straight
   out of the lane's registers and never passes an owner, so nothing in that module
   exercises the bank a real engine has to share. This module closes that: the lane is the
   engine, [Pin_bank] owns the physical pins, and [Timing] holds the line at its resting
   level for a full bit period before the start edge, which is the leading idle phase
   [Firmware_uart.tx_sequence] spends two operations on. The sequence P1.3 wrote as pin
   writes and countdowns is issued here by a six-state harness instead of by firmware.

   WHAT THIS IS NOT. The harness is not the control core: there is no program memory, no
   fetch and no decode, and it issues exactly the one typed command the first slice needs.
   Runtime loading and a general operation stream are P3 deliverables, and the phase plan
   says as much - the harness may issue typed commands directly.

   THE PATH A BIT TAKES. The lane registers its drive at an edge; the harness offers that
   value to the bank as an engine write on the same edge; the bank commits it at the next
   one. The pin therefore lags the lane by exactly one cycle, uniformly, so every bit
   still lasts [2 * half_period] cycles and only the frame's absolute position moves.

   OWNERSHIP. The pin is claimed for the engine before the idle phase and released after
   the stop bit. Release ends ownership, not the drive: the bank keeps the last committed
   value, which is the idle high a UART line is supposed to rest at. Reset, disable, and
   abort release the pin outright, in the bank and in the lane at once.
*)

open! Core
open! Hardcaml
open! Signal

module I = struct
  type 'a t =
    { (* Synchronous active-high reset; disable and abort release the pin. *)
      clock_i : 'a
    ; reset_i : 'a
    ; enable_i : 'a
    ; abort_i : 'a
    ; (* One pulse requests one frame. Accepted only while [ready_o] is high. *)
      start_i : 'a
    ; byte_i : 'a [@bits 8]
    ; (* Half-bit duration in clock cycles, and the physical pin 0..7 to transmit on. *)
      half_period_i : 'a [@bits 16]
    ; tx_pin_i : 'a [@bits 3]
    }
  [@@deriving hardcaml]
end

module O = struct
  type 'a t =
    { ready_o : 'a
    ; busy_o : 'a
    ; (* One cycle at the end of a frame, after the pin is released. *)
      frame_done_o : 'a
    ; (* The timer is running the leading idle phase. *)
      gap_busy_o : 'a
    ; (* The bank's registered pins: what leaves the design. *)
      pins_o : 'a [@bits 8]
    ; pin_oe_o : 'a [@bits 8]
    ; engine_claim_o : 'a [@bits 8]
    ; software_claim_o : 'a [@bits 8]
    ; (* Bank status. Nothing in this sequence should ever raise either one. *)
      bank_rejected_o : 'a
    ; bank_conflict_o : 'a
    }
  [@@deriving hardcaml]
end

module States = struct
  type t =
    | (* Accepting a frame request. *)
      Idle_s
    | (* The claim was issued; drive the resting level and start the idle countdown. *)
      Gap_start_s
    | (* The timer is counting one bit period of idle. *)
      Gap_s
    | (* Offer the byte to the lane. *)
      Frame_start_s
    | (* Commit the lane's drive to the bank, bit by bit. *)
      Frame_s
    | (* Give the pin back. *)
      Release_s
  [@@deriving sexp_of, compare ~localize, enumerate]
end

(* The frame parameters, latched at acceptance so the requester need not hold them. *)
module I_Regs = struct
  type 'a t =
    { byte : 'a [@bits 8]
    ; half_period : 'a [@bits 16]
    ; tx_pin : 'a [@bits 3]
    }
  [@@deriving hardcaml]
end

(* Per-state strobes into the bank, the timer, and the lane. Default zero. *)
module I_Wires = struct
  type 'a t =
    { ready : 'a
    ; claim_valid : 'a
    ; release_valid : 'a
    ; write_valid : 'a
    ; wait_valid : 'a
    ; byte_valid : 'a
    ; frame_done : 'a
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
  (* Disabled or aborting: issue nothing and return to [Idle_s]. The bank and the lane
     release the pin on the same condition, so the line goes away in one edge. *)
  let halt = ~:(i.enable_i) |: i.abort_i in
  (* The claim is issued at the acceptance edge, when the pin is still only on the input;
     everything after it uses the latched pin. *)
  let request_mask = Shift_lane.pin_mask i.tx_pin_i in
  let frame_mask = Shift_lane.pin_mask r.tx_pin.value in
  (* One bit period of idle: the half period doubled, truncated to the timer's width
     exactly as a doubling must be. A zero half period is refused by the lane, and a zero
     delay by the timer. *)
  let gap_delay = concat_lsb [ gnd; lsbs r.half_period.value ] in
  let uart =
    Uart_tx.create
      (Scope.sub_scope scope "uart")
      { Uart_tx.I.clock_i = i.clock_i
      ; reset_i = i.reset_i
      ; enable_i = i.enable_i
      ; abort_i = i.abort_i
      ; byte_valid_i = w.byte_valid.value
      ; byte_i = r.byte.value
      ; half_period_i = r.half_period.value
      ; tx_pin_i = r.tx_pin.value
      }
  in
  let timing =
    Timing.create
      (Scope.sub_scope scope "timing")
      { Timing.I.clock_i = i.clock_i
      ; reset_i = i.reset_i
      ; enable_i = i.enable_i
      ; abort_i = i.abort_i
      ; wait_valid_i = w.wait_valid.value
      ; wait_kind_i = zero 2 (* cycles *)
      ; wait_pin_i = zero 3
      ; wait_level_i = gnd
      ; wait_timeout_enable_i = gnd
      ; wait_delay_i = gap_delay
      ; snapshot_i = zero 8
      ; rising_i = zero 8
      ; falling_i = zero 8
      ; periodic_start_i = gnd
      ; periodic_stop_i = gnd
      ; periodic_period_i = zero 16
      ; phase_restart_i = gnd
      }
  in
  let bank =
    Pin_bank.create
      (Scope.sub_scope scope "bank")
      { Pin_bank.I.clock_i = i.clock_i
      ; reset_i = i.reset_i
      ; enable_i = i.enable_i
      ; abort_i = i.abort_i
      ; claim_valid_i = w.claim_valid.value
      ; claim_engine_i = vdd
      ; claim_mask_i = request_mask
      ; release_valid_i = w.release_valid.value
      ; release_engine_i = vdd
      ; release_mask_i = frame_mask
      ; write_valid_i = w.write_valid.value
      ; write_engine_i = vdd
      ; write_mask_i = frame_mask
      ; (* Only the transmit pin is committed; the mask protects the rest of the bank. *)
        write_value_i = uart.pins_o
      ; write_open_drain_i = gnd
      ; write_oe_i = uart.pin_oe_o
      }
  in
  let accept = i.start_i &: ~:halt in
  compile
    [ r.byte <-- r.byte.value
    ; r.half_period <-- r.half_period.value
    ; r.tx_pin <-- r.tx_pin.value
    ; (* Per-state strobes. At most one bank request is raised at any edge, because the
         bank refuses an edge that carries more than one. *)
      sm.switch
        ~default:[]
        [ ( Idle_s
          , [ w.ready <--. 1
            ; when_
                accept
                [ r.byte <-- i.byte_i
                ; r.half_period <-- i.half_period_i
                ; r.tx_pin <-- i.tx_pin_i
                ; w.claim_valid <--. 1
                ]
            ] )
        ; Gap_start_s, [ w.write_valid <--. 1; w.wait_valid <--. 1 ]
        ; Gap_s, []
        ; Frame_start_s, [ w.byte_valid <--. 1; w.write_valid <--. 1 ]
        ; Frame_s, [ w.write_valid <--. 1 ]
        ; Release_s, [ w.release_valid <--. 1; w.frame_done <--. 1 ]
        ]
    ; sm.switch
        ~default:[ sm.set_next Idle_s ]
        [ Idle_s, [ when_ accept [ sm.set_next Gap_start_s ] ]
        ; Gap_start_s, [ sm.set_next Gap_s ]
        ; ( Gap_s
          , [ if_ timing.complete_o [ sm.set_next Frame_start_s ] [ sm.set_next Gap_s ] ]
          )
        ; Frame_start_s, [ sm.set_next Frame_s ]
        ; Frame_s, [ if_ uart.done_o [ sm.set_next Release_s ] [ sm.set_next Frame_s ] ]
        ; Release_s, [ sm.set_next Idle_s ]
        ]
    ; (* A disabled or aborting harness offers the bank nothing at all: the release is the
         bank's own, not a request that could be refused. *)
      when_
        halt
        [ w.ready <--. 0
        ; w.claim_valid <--. 0
        ; w.release_valid <--. 0
        ; w.write_valid <--. 0
        ; w.wait_valid <--. 0
        ; w.byte_valid <--. 0
        ; w.frame_done <--. 0
        ; sm.set_next Idle_s
        ]
    ];
  { O.ready_o = w.ready.value
  ; busy_o = ~:(sm.is Idle_s)
  ; frame_done_o = w.frame_done.value
  ; gap_busy_o = timing.busy_o
  ; pins_o = bank.pins_o
  ; pin_oe_o = bank.pin_oe_o
  ; engine_claim_o = bank.engine_claim_o
  ; software_claim_o = bank.software_claim_o
  ; bank_rejected_o = bank.rejected_o
  ; bank_conflict_o = bank.conflict_o
  }
;;
