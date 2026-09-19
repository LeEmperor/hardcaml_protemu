(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "pins.ml" *)
(* The shape of the logical protocol pin bank: how many pins there are, and what a mask
   over them means.

   Behaviour is not here. Registered value and enable, masked atomic commits, drive
   ownership and conflict reporting are [Pin_bank]'s, in the reference model; this module
   is only the counting that an instruction field has to agree with.

   It is separate because it is shared. A pin number is three bits of an encoded
   instruction and a pin mask is eight ([Encoding]), so the specification, the model and
   the RTL all have to mean the same eight pins. [Pin_bank] re-exports what is here rather
   than declaring its own count, so there is one number and not three (P1.5).
*)

open! Core

(* The first logical bank (construction-plan.md section 3). Wider banks are a later
   decision; nothing outside this module assumes the number eight, and an instruction
   field's width is derived from [index_bits] rather than written down again. *)
let count = 8
let index_bits = Int.ceil_log2 count
let all_pins = (1 lsl count) - 1
let is_valid_pin pin = pin >= 0 && pin < count
let bit mask pin = mask land (1 lsl pin) <> 0
let pins_of_mask mask = List.filter (List.init count ~f:Fn.id) ~f:(bit mask)
