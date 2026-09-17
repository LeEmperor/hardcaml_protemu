(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "fifo.ml" *)
(* A small byte queue with explicit full/empty and a single-edge push/pop.

   Depth is a sweep point, not a decision: construction-plan.md section 4 starts the study
   at 4, 8 and 16 entries, so [create] takes it rather than fixing it here.

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

type t =
  { id : Fifo_id.t
  ; depth : int
  ; (* Oldest first. *)
    entries : int list
  }
[@@deriving sexp, compare, equal]

let create ~id ~depth =
  if depth < 1 then raise_s [%message "fifo depth must be positive" (depth : int)];
  { id; depth; entries = [] }
;;

let clear t = { t with entries = [] }
let occupancy t = List.length t.entries
let is_empty t = List.is_empty t.entries
let is_full t = occupancy t >= t.depth
let peek t = List.hd t.entries

(* The byte width of a queue entry. Wider words are an encoding decision (P1.4). *)
let data_bits = 8
let max_data = (1 lsl data_bits) - 1

let validate_data data =
  if data < 0 || data > max_data
  then Error (Fault.Reject.Data_out_of_range data)
  else Ok ()
;;

(* One edge, with an optional push and an optional pop. The pop is evaluated first, so it
   is unaffected by a push that is refused, and a full queue accepts a push that arrives
   with a pop. Each outcome is reported separately: [None] means the operation was not
   requested at this edge. *)
let step t ~push ~pop =
  let popped, pop_result, after_pop =
    match pop with
    | false -> None, None, t.entries
    | true ->
      (match t.entries with
       | [] -> None, Some (Error (Fault.Reject.Fifo_empty t.id)), []
       | oldest :: rest -> Some oldest, Some (Ok ()), rest)
  in
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

(* The single-operation forms, defined through [step] so that one set of rules governs
   both. *)
let push t data =
  let after, _, push, _ = step t ~push:(Some data) ~pop:false in
  match push with
  | Some (Ok ()) -> Ok after
  | Some (Error reason) -> Error reason
  | None -> Ok after
;;

let pop t =
  let after, popped, _, pop = step t ~push:None ~pop:true in
  match pop, popped with
  | Some (Ok ()), Some data -> Ok (after, data)
  | Some (Error reason), _ -> Error reason
  | (Some (Ok ()) | None), _ -> Error (Fault.Reject.Fifo_empty t.id)
;;
