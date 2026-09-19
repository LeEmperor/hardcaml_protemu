(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "event_kind.ml" *)
(* What the latched status register can report, in the order its bits are numbered.

   [Event] owns the latching rules - sticky until acknowledged, set-wins on a tie, and
   overflow when an occurrence lands on a bit that is already set. What is here is the
   enumeration alone, because the enumeration is programmer-visible: [Read_status] hands
   firmware one bit per constructor in this order, and [Ack_status] clears the bits of a
   mask read the same way. The order is therefore part of the ISA and is declared once,
   below the model, where the encoding can also see it (P1.5).
*)

open! Core

type t =
  | (* A [Wait_cycles] countdown reached its deadline. *)
    Delay_expired
  | (* A level or edge wait observed its condition. *)
    Wait_complete
  | (* A level or edge wait reached its deadline without observing its condition. *)
    Wait_timeout
  | (* A periodic tick generator rolled over. *)
    Tick
  | (* Work in flight was abandoned by ABORT or by the design being disabled. The
       transaction is incomplete; nothing here says how far it got. *)
    Aborted
  | (* One or more sticky bits in [Fault.t] became set. *)
    Fault
[@@deriving sexp, compare, equal, enumerate]

(* One bit per constructor, so the status word and the acknowledge mask are the same six
   bits read in the same order. *)
let count = List.length all
let mask = (1 lsl count) - 1
let index t = Option.value_exn (List.findi all ~f:(fun _ kind -> equal kind t)) |> fst
