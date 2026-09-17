(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "input_pins.ml" *)
(* The input front end: two synchronizer stages, one coherent registered snapshot, and
   rise/fall detection from consecutive snapshots.

   Two stages are a starting implementation, not a guaranteed external-edge latency
   (construction-plan.md section 3). Metastability reliability and the measured latency
   range are separate questions, assessed in P2.2 and P5.2; nothing here should be read as
   a timing result.

   Each pin crosses on its own flops, so the bits of one external bus are not guaranteed
   to have been sampled from the same external instant. What this module does guarantee is
   that every consumer in a given cycle reads the same [snapshot] word: the coherence is
   between consumers, not across the asynchronous boundary. Consumers must not compare
   independently synchronized pins and assume a consistent bus value.

   Edge detection compares the last two snapshots, so an edge is reported exactly once and
   only after the transition has been through both stages. A wait armed at edge k
   therefore sees only transitions first visible at k+1 or later, which is what makes edge
   waits reject stale events.

   Known artefact: reset clears all three registers, so an input already held high
   produces one rising edge as it propagates after reset release. That is real hardware
   behaviour, not a modelling shortcut; firmware arms edge waits after reset release.
*)

open! Core
open! Kinds

type t =
  { stage0 : int
  ; stage1 : int
  ; (* The previous [stage1], kept only for edge detection. *)
    previous : int
  }
[@@deriving sexp, compare, equal]

let cleared = { stage0 = 0; stage1 = 0; previous = 0 }

(* One rising edge of the system clock. [pin_in] is the asynchronous pad value. *)
let step t ~pin_in =
  { stage0 = pin_in land Pin_bank.all_pins; stage1 = t.stage0; previous = t.stage1 }
;;

(* The value every consumer reads this cycle. *)
let snapshot t = t.stage1
let level t ~pin = t.stage1 land (1 lsl pin) <> 0
let rising t = t.stage1 land lnot t.previous land Pin_bank.all_pins
let falling t = lnot t.stage1 land t.previous land Pin_bank.all_pins

let edges t ~(edge : Edge.t) =
  match edge with
  | Rising -> rising t
  | Falling -> falling t
  | Either -> rising t lor falling t
;;

let has_edge t ~pin ~edge = edges t ~edge land (1 lsl pin) <> 0
