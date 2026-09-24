(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "operation.ml" *)
(* The typed vocabulary of operations the control core issues to its mechanisms, and the
   part of their validation that needs nothing but the operation itself.

   Named [Operation] rather than [Command] for a dull reason: [Core.Command] shadows the
   name inside this library. construction-plan.md section 4 lists these as "candidate
   operations" anyway, and the phase plan's "typed pin commands, timing requests, transfer
   descriptors" are the same things under the plan's wording.

   This is P1.2's deliverable and it is deliberately not an ISA. construction-plan.md
   section 4 wants the mechanisms settled - what may be asked for, what is refused, what
   blocks and what does not - before an encoding is chosen, so that P1.4 can compare
   encodings of a fixed set of operations rather than inventing operations and encodings
   at once. Nothing here has an opcode, a width, or a field layout.

   Until P1.5 supplies an encoding and P3.2 a decoder, these values arrive from the test
   harness rather than from the program store, which is what the phase plan's first
   working slice describes.

   Acceptance is a ready/valid handshake at a rising edge, and parameters are latched at
   acceptance (construction-plan.md section 3, rule 1). An operation whose effect cannot
   complete at that edge either stalls the core until it can, or is refused now: the
   [Blocking.t] argument on the queue operations chooses, and the timing operations are
   always blocking because stalling is what they are for.

   One consequence to know about while this phase is unfinished: nothing here drains a
   queue. The transfer engine that would is P2.5 and the host data-queue port is P3.4, so
   a blocking queue operation issued now stays blocked until ABORT, reset, or the design
   being disabled ends it, which raises the sticky queue fault. That is the specified
   safe-abort result rather than a hang, but a nonblocking form is the useful one until
   then.
*)

open! Core
open! Kinds

type t =
  (* Pins. One atomic commit of value and enable together, on behalf of [Software]. *)
  | Write_pins of Pin_bank.Write.t
  | (* Drive rights, the mechanism a transfer engine will use to hold its pins for a
       transaction. Exposed to firmware and the harness now so the ownership rules are
       exercisable before P2.5 exists. *)
    Claim_pins of
      { owner : Owner.t
      ; mask : int
      }
  | Release_pins of
      { owner : Owner.t
      ; mask : int
      }
  (* Time. All three stall the control core and leave running engines alone: a core wait
     is not an engine pause (construction-plan.md section 3, rule 6). *)
  | Wait_cycles of { delay : int }
  | Wait_level of
      { pin : int
      ; level : bool
      ; timeout : int option
      }
  | Wait_edge of
      { pin : int
      ; edge : Edge.t
      ; timeout : int option
      }
  | (* A free-running tick generator. Unlike the waits it does not stall anything, which
       is what makes it usable as a baud schedule while the core does other work. *)
    Start_periodic of { period : int }
  | Stop_periodic
  (* Transfers. [Configure] validates and latches a descriptor; issuing one is P2.5. *)
  | Configure_transfer of Transfer.t
  (* Data queues. *)
  | Fifo_push of
      { fifo : Fifo_id.t
      ; data : int
      ; blocking : Blocking.t
      }
  | Fifo_pop of
      { fifo : Fifo_id.t
      ; blocking : Blocking.t
      }
[@@deriving sexp, compare, equal]

(* Whether a command that cannot complete now may stall the core rather than being
   refused. The timing commands stall by definition. *)
let blocking : t -> Blocking.t = function
  | Wait_cycles _ | Wait_level _ | Wait_edge _ -> Blocking
  | Fifo_push { blocking; _ } | Fifo_pop { blocking; _ } -> blocking
  | Write_pins _
  | Claim_pins _
  | Release_pins _
  | Start_periodic _
  | Stop_periodic
  | Configure_transfer _ -> Nonblocking
;;

let check condition reason = if condition then Ok () else Error reason

let pin_in_range pin =
  check (Pin_bank.is_valid_pin pin) (Fault.Reject.Pin_out_of_range pin)
;;

(* A timed command accepted at edge k with delay n fires at k + n, so n must be at least
   one: zero delay is rejected initially (construction-plan.md section 3, rule 2). The
   same rule applies to a timeout, which is a deadline measured the same way. *)
let delay_in_range delay = check (delay >= 1) Fault.Reject.Zero_delay

let timeout_in_range = function
  | None -> Ok ()
  | Some timeout -> delay_in_range timeout
;;

(* Structural validation. Everything that depends on machine state - pin ownership,
   whether a queue is full - is checked by [Machine] at acceptance, because only it knows. *)
let validate t =
  let ( >>= ) result f = Result.bind result ~f in
  match t with
  | Write_pins write -> Pin_bank.validate_mask write.mask
  | Claim_pins { owner = _; mask } | Release_pins { owner = _; mask } ->
    Pin_bank.validate_mask mask
  | Wait_cycles { delay } -> delay_in_range delay
  | Wait_level { pin; level = _; timeout } ->
    pin_in_range pin >>= fun () -> timeout_in_range timeout
  | Wait_edge { pin; edge = _; timeout } ->
    pin_in_range pin >>= fun () -> timeout_in_range timeout
  | Start_periodic { period } -> delay_in_range period
  | Stop_periodic -> Ok ()
  | Configure_transfer descriptor -> Transfer.validate descriptor
  | Fifo_push { fifo = _; data; blocking = _ } -> Fifo.validate_data data
  | Fifo_pop _ -> Ok ()
;;
