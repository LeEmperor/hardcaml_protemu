(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "assembler.ml" *)
(* Laying a program out: labels resolved to displacements, instructions encoded, and the
   result packed into program-store words.

   INSTRUCTION WIDTH AND MEMORY WIDTH ARE SEPARATE CHOICES, as construction-plan.md
   section 4 requires and as P1.4 measured. The instruction is sixteen bits ([Encoding]);
   whether the store is sixteen bits wide with one instruction per word, or thirty-two
   with two, is [Memory.t] and is chosen by the caller. The provisional default is
   [Memory.word16] and the reason is in docs/p1.5-encoding-decision.md: packing is faster
   and makes a bit-banged program's timing depend on which half of a word an instruction
   landed in, which is a trade that needs P5's physical evidence to settle.

   BYTE ORDER is little-endian and is a property of the transport, not of the format: the
   loader assembles complete memory words before issuing writes (construction-plan.md
   section 4), so byte order describes how a host byte stream becomes words and never how
   the core reads them. [Image.bytes] is that stream. In a thirty-two-bit word holding two
   instructions the earlier instruction occupies the less significant half, so both
   conventions agree that earlier is lower.

   ONE PASS, NOT A RELAXATION LOOP. An instruction's size does not depend on its target
   ([Encoding.words_of]), so every slot address is known after one walk over the items and
   every displacement is resolved on a second. A displacement that does not fit its field
   is refused rather than rewritten into a jump island: a branch that silently became two
   instructions would make a program's size a function of something its author cannot see.
*)

open! Core

module Memory = struct
  (* The program store's word, as far as a program image is concerned. Both layouts hold a
     whole number of instructions in a word, so one memory read always reaches a whole
     instruction slot and no instruction is ever split across two words - which is what
     P1.4 measured the cost of and why the thirty-two-bit-instruction candidates were
     dropped (docs/p1.5-encoding-decision.md section 2). *)
  type t =
    { name : string
    ; word_bits : int
    ; instructions_per_word : int
    }
  [@@deriving sexp_of, compare, equal]

  let word16 = { name = "m16"; word_bits = 16; instructions_per_word = 1 }
  let word32_packed = { name = "m32"; word_bits = 32; instructions_per_word = 2 }
  let all = [ word16; word32_packed ]
  let default = word16
end

(* The store from construction-plan.md section 4's sweep points. *)
let default_depth = 256

(* The memory word a slot lives in, and the half of it the slot occupies. Packing moves no
   bits inside an instruction; it decides how many reads of the single port reach one. *)
let address (memory : Memory.t) ~slot = slot / memory.instructions_per_word

let extract (memory : Memory.t) ~slot ~word =
  let half = slot % memory.instructions_per_word in
  (word lsr (half * Encoding.instruction_bits))
  land ((1 lsl Encoding.instruction_bits) - 1)
;;

module Image = struct
  (* The loaded program as memory words, and as the byte stream a host transport would
     carry. *)
  type t =
    { words : int array
    ; word_bits : int
    }
  [@@deriving sexp_of, compare, equal]

  let word_count t = Array.length t.words
  let bits t = word_count t * t.word_bits

  (* Little-endian: least significant byte of each word first. *)
  let bytes t =
    let per_word = t.word_bits / 8 in
    Array.to_list t.words
    |> List.concat_map ~f:(fun word ->
      List.init per_word ~f:(fun index -> (word lsr (index * 8)) land 0xff))
  ;;
end

(* The half-word an odd number of instructions leaves in a packed image. It is written,
   not left unwritten, and it is [Halt]: running into the padding stops the core rather
   than executing whatever the store held. An unwritten word is a different thing entirely
   and faults, which is the memory contract's rule and P1.1's. *)
let padding_word =
  match Encoding.encode Instruction.Halt with
  | Ok [ word ] -> word
  | _ -> raise_s [%message "halt is not one word"]
;;

let build_image (memory : Memory.t) slots =
  let words =
    List.chunks_of slots ~length:memory.instructions_per_word
    |> List.map ~f:(fun chunk ->
      let padded =
        chunk
        @ List.init
            (memory.instructions_per_word - List.length chunk)
            ~f:(fun _ -> padding_word)
      in
      List.foldi padded ~init:0 ~f:(fun half acc word ->
        acc lor (word lsl (half * Encoding.instruction_bits))))
  in
  { Image.words = Array.of_list words; word_bits = memory.word_bits }
;;

module Entry = struct
  (* One assembled instruction. [slot] is its instruction-slot address; [words] are the
     encoded instruction word and its extension word when it has one. *)
  type t =
    { index : int
    ; slot : int
    ; instr : string Instruction.t
    ; words : int list
    }
  [@@deriving sexp_of, compare, equal]

  let extension_words t = List.length t.words - 1
end

module Size = struct
  (* What a program costs to store. Physical area is deliberately absent: P1.4 recorded
     sizes and cycles, and P5 measures area against them (phase_plan.md). *)
  type t =
    { instructions : int
    ; slots : int
    ; extension_words : int
    ; memory_words : int
    ; memory_bits : int
    }
  [@@deriving sexp_of, compare, equal]
end

module Assembled = struct
  type t =
    { memory : Memory.t
    ; name : string
    ; entries : Entry.t list
    ; labels : int String.Map.t
    ; image : Image.t
    ; size : Size.t
    }
  [@@deriving sexp_of]

  (* The slot a label names, for a test or a host that wants to start somewhere other than
     zero. *)
  let label t name = Map.find t.labels name
end

(* Assemble:

   1. validate the program, so that no later failure is about something structural;
   2. lay every instruction out at a slot and record where each label landed;
   3. resolve each target to a displacement from the slot after the instruction, and
      encode;
   4. pack the slots into memory words and check the image fits the store. *)
let assemble ?(depth = default_depth) ?(memory = Memory.default) (program : Program.t) =
  let ( >>= ) result f = Result.bind result ~f in
  Program.validate program
  >>= fun () ->
  let _, placed, labels =
    List.fold
      program.items
      ~init:(0, [], String.Map.empty)
      ~f:(fun (slot, placed, labels) item ->
        match (item : Program.Item.t) with
        | Label label -> slot, placed, Map.set labels ~key:label ~data:slot
        | Instr instr -> slot + Encoding.words_of instr, (slot, instr) :: placed, labels)
  in
  let placed = List.rev placed in
  List.mapi placed ~f:(fun index (slot, instr) ->
    let resolved =
      Instruction.map_target instr ~f:(fun label ->
        (* Relative to the slot after the instruction, the usual convention and the one
           that makes a backward branch to the instruction itself -1 rather than zero. *)
        Map.find_exn labels label - (slot + 1))
    in
    Encoding.encode resolved
    |> Result.map_error ~f:(fun reason ->
      (* [Encoding] only knows the displacement it was handed; the label the author wrote
         is what they can act on, so it is put back here. *)
      match reason, Instruction.target instr with
      | Invalid.Displacement_out_of_range { target = _; displacement; bits }, Some label
        -> Invalid.Displacement_out_of_range { target = label; displacement; bits }
      | reason, _ -> reason)
    |> Result.map ~f:(fun words -> { Entry.index; slot; instr; words }))
  |> Result.all
  >>= fun entries ->
  let slots = List.concat_map entries ~f:(fun entry -> entry.words) in
  let image = build_image memory slots in
  let size =
    { Size.instructions = List.length entries
    ; slots = List.length slots
    ; extension_words = List.sum (module Int) entries ~f:Entry.extension_words
    ; memory_words = Image.word_count image
    ; memory_bits = Image.bits image
    }
  in
  if size.memory_words > depth
  then Error (Invalid.Program_too_large { words = size.memory_words; depth })
  else Ok { Assembled.memory; name = program.name; entries; labels; image; size }
;;
