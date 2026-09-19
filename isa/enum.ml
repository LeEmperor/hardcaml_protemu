(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "enum.ml" *)
(* The one rule for encoding a small enumeration: an instruction field carries the
   constructor's position in its own [enumerate] list.

   Every enumerated field in the ISA follows it - an ALU operation, a branch condition, a
   wait's edge, a queue's identity, a descriptor field. Stating the rule once, as a
   function over [all], means the encoder's field value and the decoder's lookup come from
   the same list rather than from two hand-written tables that can drift apart. Adding a
   constructor in the middle of an [all] therefore changes the encoding, which is a real
   consequence and the reason the lists are ordered deliberately.
*)

open! Core

let index all ~equal value =
  match List.findi all ~f:(fun _ candidate -> equal candidate value) with
  | Some (index, _) -> index
  | None -> raise_s [%message "a value is missing from its own enumeration"]
;;

let of_index all index = List.nth all index

(* The field width a complete enumeration needs: enough bits for every constructor, and no
   spare code points beyond the next power of two. A decoder must still refuse the values
   between [List.length all] and the field's limit, which is what makes a field naming
   nothing a detectable error rather than a silent one. *)
let bits all = Int.max 1 (Int.ceil_log2 (List.length all))
