(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "fault.ml" *)
(* Two distinct kinds of bad news, kept apart on purpose.

   [Reject.t] is why a command was refused at the edge it was offered. It is transient: it
   describes one issue attempt and is not latched anywhere. Most rejections are ordinary
   flow control (the port was busy, a nonblocking pop found the queue empty) and must not
   look like a hardware failure.

   [t] is the sticky fault register. Its bits record that a condition occurred, not how
   many times, as construction-plan.md section 3 specifies for sticky status. They clear
   only on acknowledgement or reset.

   Only conditions a program cannot legitimately provoke become sticky faults. A refused
   nonblocking FIFO operation is a documented result; a software write into a pin another
   engine owns is a fault.
*)

open! Core
open! Kinds

module Reject = struct
  type t =
    (* Flow control: the port was not accepting a command at this edge. *)
    | Not_ready
    | Aborting
    (* Structural validation, decidable from the command alone. *)
    | Zero_delay
    | Pin_out_of_range of int
    | Data_out_of_range of int
    | Bit_count_out_of_range of int
    | Half_period_out_of_range of int
    | Duplicate_pin of
        { pin : int
        ; first : Pin_role.t
        ; second : Pin_role.t
        }
    | Missing_pin of Pin_role.t
    | Unexpected_pin of Pin_role.t
    | Launch_equals_sample of Clock_phase.t
    (* Stateful validation, decidable only against the machine. *)
    | Pin_owned of
        { pin : int
        ; owner : Owner.t
        }
    | Pin_not_owned of
        { pin : int
        ; claimed_by : Owner.t option
        }
    | Fifo_full of Fifo_id.t
    | Fifo_empty of Fifo_id.t
    | Engines_not_idle
    | Not_halted
    | (* A sticky fault took the core down at this same edge, so the request could not be
         honoured. *)
      Faulted
  [@@deriving sexp, compare, equal]
end

(* One sticky bit per condition, as in hardware. *)
type t =
  { pin_ownership : bool
  ; (* A fetch produced a word the program-memory contract leaves unspecified, or the
       fetch pipeline was asked for an address outside the loaded image. Such a word can
       never be accepted as an instruction (P1.1). *)
    fetch_invalid : bool
  ; (* A blocking queue operation was still blocked when its transaction was aborted. *)
    fifo_fault : bool
  }
[@@deriving sexp, compare, equal, fields ~getters]

let none = { pin_ownership = false; fetch_invalid = false; fifo_fault = false }
let any t = t.pin_ownership || t.fetch_invalid || t.fifo_fault

(* Sticky: a set bit stays set. *)
let set_pin_ownership t = { t with pin_ownership = true }
let set_fetch_invalid t = { t with fetch_invalid = true }
let set_fifo_fault t = { t with fifo_fault = true }
