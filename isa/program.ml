(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "program.ml" *)
(* A program: instructions, the labels between them, and the checks that can be made
   before anything is laid out in memory.

   construction-plan.md section 4 asks for "an OCaml assembler/library with labels and
   validation before designing a textual DSL", and this is the library half of that. A
   program is a list, built by ordinary OCaml, so a firmware helper such as a UART frame
   is a function that returns items and the caller concatenates them. There is no parser
   and no syntax; there is nothing for a syntax to buy yet.

   WHAT IS CHECKED HERE. Everything that depends on the instructions alone: each one is
   structurally legal, every label is unique, every named label exists, the program is not
   empty, and execution cannot fall off the end of it. Everything that depends on where
   the instructions land - whether a branch reaches, whether the image fits the store - is
   [Assembler]'s, because it needs the layout.
*)

open! Core

module Item = struct
  (* A label consumes no instruction slot: it names the slot of the next instruction, and
     a label at the end of a program names the slot past the last one. *)
  type t =
    | Label of string
    | Instr of string Instruction.t
  [@@deriving sexp, compare, equal]
end

(* The two constructors, short, because a program is mostly a list of them. *)
let instr i = Item.Instr i
let at label = Item.Label label

type t =
  { name : string
  ; items : Item.t list
  }
[@@deriving sexp, compare, equal]

let instructions t =
  List.filter_map t.items ~f:(function
    | Item.Instr instr -> Some instr
    | Label _ -> None)
;;

let labels t =
  List.filter_map t.items ~f:(function
    | Item.Label label -> Some label
    | Instr _ -> None)
;;

(* The last instruction, which has to be one execution cannot continue past: the word
   after the image was never written, and P1.1 forbids accepting an unwritten word as an
   instruction. A program that ends in a conditional branch would fault the first time the
   branch was not taken, which is a bug to report at assembly rather than a fault to
   diagnose in a trace. *)
let terminated t =
  match List.last (instructions t) with
  | None -> Error Invalid.Empty
  | Some last ->
    if Instruction.ends_flow last
    then Ok ()
    else
      Error
        (Invalid.Runs_off_the_end
           { last = Sexp.to_string_hum [%sexp (last : string Instruction.t)] })
;;

let validate t =
  let ( >>= ) result f = Result.bind result ~f in
  let defined = String.Set.of_list (labels t) in
  (if List.is_empty (instructions t) then Error Invalid.Empty else Ok ())
  >>= fun () ->
  (match List.find_a_dup (labels t) ~compare:String.compare with
   | Some label -> Error (Invalid.Duplicate_label label)
   | None -> Ok ())
  >>= fun () ->
  List.fold_result (instructions t) ~init:() ~f:(fun () instr ->
    Instruction.validate instr
    >>= fun () ->
    match Instruction.target instr with
    | Some label when not (Set.mem defined label) -> Error (Invalid.Undefined_label label)
    | _ -> Ok ())
  >>= fun () -> terminated t
;;

let create ~name items =
  let t = { name; items } in
  Result.map (validate t) ~f:(fun () -> t)
;;
