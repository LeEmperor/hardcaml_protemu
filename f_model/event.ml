(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "event.ml" *)
(* Latched completion and error status with explicit acknowledgement.

   The rules come from construction-plan.md section 3, rule 4:

   - A bit stays set until acknowledged, so an event stays visible while the core is busy
     doing something else.
   - Set and acknowledge in the same cycle is set-wins. An acknowledgement aimed at the
     occurrence the consumer has already seen can never erase a newer one.
   - A sticky bit records occurrence, not multiplicity. A second occurrence arriving while
     the bit is still set, and not being acknowledged at that edge, is lost; [overflow]
     records that loss so the consumer knows its count is not exact. A workload that must
     distinguish successive occurrences needs a counter or a queue, not this register.
*)

open! Core

(* The kinds themselves are [Event_kind], in the instruction-specification library: their
   order is the bit order of the status word [Read_status] hands firmware, so the encoding
   has to see it too. What this module adds is the comparison structure the latch needs -
   the sets below - which is model state and belongs nowhere near an encoding. *)
module Kind = struct
  include Event_kind
  include Comparable.Make (Event_kind)
end

type t =
  { latched : Kind.Set.t
  ; overflow : Kind.Set.t
  }
[@@deriving sexp, compare, equal]

let cleared = { latched = Kind.Set.empty; overflow = Kind.Set.empty }
let is_set t kind = Set.mem t.latched kind
let overflowed t kind = Set.mem t.overflow kind
let any t = not (Set.is_empty t.latched)

(* One edge. [set] are the occurrences at this edge; [ack] are the kinds the consumer is
   acknowledging at this same edge. *)
let step t ~set ~ack =
  let set = Kind.Set.of_list set in
  let ack = Kind.Set.of_list ack in
  (* Lost only if it lands on a bit that is both already set and not being cleared now. If
     the consumer acknowledges at this edge it has seen the previous occurrence, so the
     new one replaces it without loss. *)
  let lost = Set.diff (Set.inter set t.latched) ack in
  { latched = Set.union (Set.diff t.latched ack) set
  ; overflow = Set.union (Set.diff t.overflow ack) lost
  }
;;
