(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "harness.ml" *)
(* Driving and observing the reference machine, for the model tests.

   These are the conventions P1.6 will formalise; for now they are deliberately thin. One
   call is one rising clock edge, so a test reads as a cycle-by-cycle transcript and an
   assertion about "the next edge" is literally the next line.

   [show] prints the state after an edge. Everything it prints is registered state or the
   record of the edge just taken, never a recomputed guess, so an expect block is evidence
   about the model rather than about the printer.
*)

open! Core
open! Protemu_model

let create ?program_depth ?program_width ?fifo_depth () =
  Machine.create ?program_depth ?program_width ?fifo_depth ()
;;

(* One edge with reset asserted, as a testbench releases a design. *)
let reset t = Machine.step t { Machine.Input.idle with reset = true }

let step ?(pin_in = 0) ?request ?command ?(acknowledge = []) ?load t =
  Machine.step t { Machine.Input.idle with pin_in; request; command; acknowledge; load }
;;

(* One edge with the design disabled. *)
let step_disabled ?(pin_in = 0) t =
  Machine.step t { Machine.Input.idle with enable = false; pin_in }
;;

let steps ?(pin_in = 0) t ~n = Fn.apply_n_times ~n (fun t -> step ~pin_in t) t

(* Write one program word. Accepted only while halted. *)
let load t ~address ~data = step t ~load:{ Machine.Load.address; data }

let show (t : Machine.t) =
  print_s
    [%message
      ""
        ~time:(t.time : int)
        ~exec:(t.exec : Machine.Exec.t)
        ~pin_out:(t.pins.value : int)
        ~pin_oe:(t.pins.output_enable : int)
        ~waiting:(Option.is_some t.wait : bool)
        ~ready:(Machine.command_ready t : bool)
        ~command:(t.last.command : Machine.Command_result.t)
        ~events:(t.last.events : Event.Kind.t list)]
;;

(* The latched status register rather than this edge's occurrences. *)
let show_status (t : Machine.t) =
  print_s
    [%message
      ""
        ~latched:(Set.to_list t.events.latched : Event.Kind.t list)
        ~overflow:(Set.to_list t.events.overflow : Event.Kind.t list)
        ~faults:(t.faults : Fault.t)]
;;

let show_command (t : Machine.t) =
  print_s [%sexp (t.last.command : Machine.Command_result.t)]
;;

(* A legal descriptor, used as the starting point for the invalid variations so that each
   test changes exactly one thing. Mode-0-like: launch on one edge, sample on the other. *)
let base_transfer =
  { Transfer.direction = Tx_only
  ; bit_count = 8
  ; bit_order = Lsb_first
  ; tx_value = 0x5a
  ; output_pin = Some 0
  ; input_pin = None
  ; clock_pin = Some 1
  ; idle_output = true
  ; idle_clock = false
  ; initial_delay = None
  ; launch = On_falling
  ; sample = On_rising
  ; pacing = Transfer.Pacing.Internal { half_period = 4 }
  }
;;

let show_validation descriptor =
  print_s [%sexp (Transfer.validate descriptor : (unit, Fault.Reject.t) Result.t)]
;;
