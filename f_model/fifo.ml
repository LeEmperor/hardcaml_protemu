(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "fifo.ml" *)
(* The reference model's byte queue, with explicit full/empty and one-edge push/pop.

   Machine owns the Tx and Rx instances and uses [push] and [pop] when an instruction
   or peripheral action needs them. Those helpers share [step]'s queue rules. This
   module decides queue order and reports rejected operations; it does not advance
   Machine's clock or set sticky fault bits.

   Depth is a sweep point, not a decision: construction-plan.md section 4 starts the
   study at 4, 8 and 16 entries, so [create] takes it rather than fixing it here.

   A pop frees its slot at the same edge as an accompanying push takes one, so a push into
   a full queue succeeds when a pop goes with it. Ordering survives that case: the popped
   word is the oldest present before the edge and the pushed word becomes the newest, so
   nothing is lost or duplicated.

   Reset clears validity rather than contents (construction-plan.md section 3), which for
   a queue with no initialisation requirement is the same thing: [clear] drops the
   entries.
*)

open! Core
open! Kinds

(* The queue state; oldest bytes appear first in [entries].

   id      : names the queue in rejection reasons;
   depth   : maximum number of entries;
   entries : valid bytes, oldest first; an empty list means an empty queue;

   There is no mli, so callers can construct this record directly. [create] alone
   checks that [depth] is positive; [step] validates bytes offered to it.
*)
type t =
  { id : Fifo_id.t
  ; depth : int
  ; (* Oldest first. *)
    entries : int list
  }
[@@deriving sexp, compare, equal]

(* Make an empty queue; a nonpositive depth raises because it cannot describe a
   usable queue, and Machine.create builds these as part of its initial state. *)
let create ~id ~depth =
  (* error check at construction time; *)
  if depth < 1 then raise_s [%message "fifo depth must be positive" (depth : int)];
  { id; depth; entries = [] }
;;

(* Drop all valid entries while keeping the queue identity and configured depth. *)
let clear t = { t with entries = [] }

(* Number of valid bytes, used for capacity checks and observation. *)
let occupancy t = List.length t.entries

(* Whether a pop would have no byte to return. *)
let is_empty t = List.is_empty t.entries

(* Whether a push needs a simultaneous pop to make room. *)
let is_full t = occupancy t >= t.depth

(* Observe the oldest byte without removing it; [None] means empty. *)
let peek t = List.hd t.entries

(* The byte width of a queue entry; wider words are an encoding decision (P1.4). *)
let data_bits = 8
let max_data = (1 lsl data_bits) - 1

(* A queue entry is an eight-bit unsigned value; report an invalid byte as a
   command rejection so Machine can distinguish it from a hardware fault. *)
let validate_data data =
  if data < 0 || data > max_data
  then Error (Fault.Reject.Data_out_of_range data)
  else Ok ()
;;

(* Resolve one edge, with an optional push and an optional pop;

   1. Pop the oldest pre-edge byte, or report Fifo_empty;
   2. Validate the offered push byte, if any;
   3. Check capacity after the pop and append a valid byte if there is room;

   A full queue therefore accepts a push paired with a successful pop; Each outcome
   is reported separately; [None] means that operation was not requested. 

   A rejected push does not undo a successful pop.
*)
let step t ~push ~pop =
  (* create the result tuple *)
  let (popped, pop_result, after_pop) =
    (* match result on queue correctness only if we got a valid return pop *)
    match pop with
    | false -> None, None, t.entries
    | true -> (* i love nested shenanigans *)
      (match t.entries with
       | [] -> None, Some (Error (Fault.Reject.Fifo_empty t.id)), []
       | oldest :: rest -> Some oldest, Some (Ok ()), rest)
  in

  (* push variant of the above item *)
  let push_result, entries =
    match push with
    | None -> None, after_pop
    | Some data ->
      (match validate_data data with
       | Error reason -> Some (Error reason), after_pop
       | Ok () ->
         if List.length after_pop >= t.depth
         then Some (Error (Fault.Reject.Fifo_full t.id)), after_pop
         else Some (Ok ()), after_pop @ [ data ])
  in

  { t with entries }, popped, push_result, pop_result
;;

(* Push one byte through [step], preserving its capacity and byte checks. *)
let push t data =

  (* observed construction *)
  let after, _, push, _ = step t ~push:(Some data) ~pop:false in

  (* prop the error *)
  match push with
  | Some (Ok ()) -> Ok after
  | Some (Error reason) -> Error reason
  | None -> Ok after
;;

(* Pop one byte through [step], returning Fifo_empty when none is present. *)
let pop t =

  (* observed construction *)
  let after, popped, _, pop = step t ~push:None ~pop:true in

  (* prop the error *)
  match pop, popped with
  | Some (Ok ()), Some data -> Ok (after, data)
  | Some (Error reason), _ -> Error reason
  | (Some (Ok ()) | None), _ -> Error (Fault.Reject.Fifo_empty t.id)
;;
