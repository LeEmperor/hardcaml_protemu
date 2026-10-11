(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "control_port.ml" *)
(* The core control port: the request, decision, and status records shared by every
   producer of core control.

   [Emulator_core] owns this contract. [Host_link] (over serial) and
   [Simulator_backend] (directly in Cyclesim) are two transports over it. The records are
   direction-neutral; a module embeds them with its own [_i] or [_o] suffix, so the fields
   keep the port names they had before the records existed. This module depends only on
   the width definitions of [Program_memory_controller], [Execution_unit], and [Protemu_isa], never
   on a consumer.

   Step, pin claim/release, queues, pads, and program RAM are not part of this port. They
   remain separate ports of [Emulator_core], and a transport that does not use them ties
   them off.

   Temporal contract. Every statement is derived from [Emulator_core], [Program_memory_controller],
   and both producers as they exist, not from a cleaner handshake.

   1. Offers. Each rising edge of the core clock with a [*_valid] field high is one offer
      of that request, decided in that cycle. There is no ready signal, stall, or held
      offer: the core never defers a decision to a later cycle. A valid that stays high is
      a new offer on the next edge, decided against the updated state. Both producers
      raise a valid for exactly one cycle per operation and never re-offer automatically.

   2. Operands. An operand is meaningful only in a cycle where its request's valid is
      high. It must be stable before the sampling edge of that cycle. The core consumes it
      then and registers what a later cycle needs (image length, verify flag, expected
      word), so operands need not stay stable after the offer. [Host_link] drives
      them continuously from its retained request registers; [Simulator_backend] drives
      them only in the offer cycle and zeroes them otherwise.

   3. Decisions. Acceptance is combinational from the offer and the current core state. It
      is observed in the offer cycle, before the sampling edge. Its effect is visible
      after that edge. Rejection is [valid & ~accepted]: during a valid offer exactly one
      of the pair is high, and with no offer both are low. Both signals are kept even
      though [Host_link] reads only acceptance.

   4. Arbitration. Neither producer offers two requests in one cycle, but the core
      resolves simultaneous offers as follows.
      - ABORT is accepted whenever offered while enabled and out of reset. It halts
        execution at that edge, which refuses every other request in the same cycle.
      - STOP is accepted whenever offered while enabled, out of reset, and without an
        ABORT offer, whatever the execution state. It refuses a simultaneous RUN. It does
        not itself refuse program requests; only a pause that it causes at an instruction
        boundary in that cycle does.
      - Program requests need the core halted, engines idle, and no execution halt in that
        cycle. Among themselves the order is LOAD_START, LOAD_WRITE, READBACK,
        LOAD_COMPLETE, by validity rather than acceptance: a higher offer refuses the
        lower ones even if it is itself refused.
      - RUN is refused by any program request, STOP or ABORT offer, or step request in the
        same cycle.

   5. READBACK completion. Acceptance issues the RAM read at the sampling edge. The
      response fields are registered: for an offer accepted at edge E,
      [readback_response_valid] is high for exactly the cycle between edges E+1 and E+2,
      and [readback_response_data] and [readback_response_match] are meaningful only then.
      A second READBACK is refused while the response is outstanding. Reset, disable, an
      accepted ABORT, or an accepted LOAD_START in the cycle between E and E+1 cancels the
      response; it never appears later. [Host_link] waits for the valid pulse with
      no bound. [Simulator_backend] requires it in the next post-edge observation and
      reports its absence as a backend invariant.

   6. ABORT completion. Acceptance is not cleanup. Cleanup is complete when the status
      shows [halted], [engines_idle], and zero [pin_oe], [software_claim], and
      [engine_claim]. The core completes cleanup at the accepting edge (P3.3's control
      contract; P3.4's prompt completion boundary), so the first observation after that
      edge shows it. [Host_link] waits for that condition with no bound before
      responding. [Simulator_backend] does not wait: it reports completion only if that
      single observation shows it.

   7. STOP completion. Acceptance is not halting. If execution is active, the core latches
      the request and halts at the next instruction boundary; there is no bound on how
      long that takes. Halting is observed only through [Status.halted]. A STOP accepted
      while already halted leaves nothing pending, so a later RUN is not paused by it.

   8. Reset and disable. While [reset_i] is high or [en_i] is low, every offer is refused:
      its accepted signal is low and its rejected signal follows its valid. Either one
      cancels an outstanding READBACK response and any pending STOP. Disable halts
      execution and cancels mechanisms but preserves a completed image; reset also
      invalidates it. [Host_link] also discards its own dispatch, wait, and response
      state; [Simulator_backend] holds no request across cycles.

   9. Status. Every [Status] field is a live observation of core state, not an event, and
      has no valid qualifier. [Host_link] samples it before an edge: in a command's
      dispatch cycle to classify a refusal or build a STATUS response, and on each cycle
      of an ABORT wait. [Simulator_backend] samples it after an edge, and classifies a
      refusal from the status observed before it drives the offer.
*)

open! Core
open! Hardcaml
open! Signal

(* The shared request subset. A field is a valid bit or an operand of the request named by
   its prefix. Addresses and lengths keep [Program_memory_controller]'s request width, one bit wider
   than the physical port, so the core checks bounds before narrowing.
*)
module Request = struct
  type 'a t =
    { load_start_valid : 'a
    ; load_length : 'a [@bits Program_memory_controller.Config.request_address_bits]
    ; load_write_valid : 'a
    ; load_address : 'a [@bits Program_memory_controller.Config.request_address_bits]
    ; load_data : 'a [@bits Program_memory_controller.Config.program_width]
    ; load_complete_valid : 'a
    ; readback_valid : 'a
    ; readback_address : 'a [@bits Program_memory_controller.Config.request_address_bits]
    ; readback_verify : 'a
    ; readback_expected : 'a [@bits Program_memory_controller.Config.program_width]
    ; run_valid : 'a
    ; stop_valid : 'a
    ; abort_valid : 'a
    }
  [@@deriving hardcaml]
end

(* Per-request decisions in [Request]'s order, plus the registered READBACK response. See
   items 3 and 5 of the contract above.
*)
module Decision = struct
  type 'a t =
    { load_start_accepted : 'a
    ; load_start_rejected : 'a
    ; load_write_accepted : 'a
    ; load_write_rejected : 'a
    ; load_complete_accepted : 'a
    ; load_complete_rejected : 'a
    ; readback_accepted : 'a
    ; readback_rejected : 'a
    ; readback_response_valid : 'a
    ; readback_response_data : 'a [@bits Program_memory_controller.Config.program_width]
    ; readback_response_match : 'a
    ; run_accepted : 'a
    ; run_rejected : 'a
    ; stop_accepted : 'a
    ; stop_rejected : 'a
    ; abort_accepted : 'a
    ; abort_rejected : 'a
    }
  [@@deriving hardcaml]
end

(* Core observations that a transport reports or uses to classify a refusal; see item 9.
   [pin_oe], [software_claim], and [engine_claim] are observations only, used for STATUS
   flags and ABORT cleanup. Pin claim and release are not requests on this port.
*)
module Status = struct
  type 'a t =
    { halted : 'a
    ; engines_idle : 'a
    ; image_valid : 'a
    ; load_active : 'a
    ; image_length : 'a [@bits Program_memory_controller.Config.request_address_bits]
    ; words_written : 'a [@bits Program_memory_controller.Config.request_address_bits]
    ; words_verified : 'a [@bits Program_memory_controller.Config.request_address_bits]
    ; verification_failed : 'a
    ; fetch_fault : 'a
    ; execution_active : 'a
    ; normal_halt : 'a
    ; execution_fault : 'a
    ; fault_kind : 'a [@bits Execution_unit.Fault.width]
    ; pc : 'a [@bits Execution_unit.Config.pc_bits]
    ; phase : 'a [@bits Execution_unit.Phase.width]
    ; pin_oe : 'a [@bits Protemu_isa.Pins.count]
    ; software_claim : 'a [@bits Protemu_isa.Pins.count]
    ; engine_claim : 'a [@bits Protemu_isa.Pins.count]
    }
  [@@deriving hardcaml]
end
