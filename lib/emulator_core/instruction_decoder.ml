(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "instruction_decoder.ml" *)
(* Combinational P1.5 instruction decoder generated from the shared encoding layout.

   Opcode values, field positions, spare masks, and extension shape come from
   [Protemu_isa.Encoding]. The outputs separate base-word legality from extension
   resolution so the execution client can request an extension before committing state.
*)

open! Core
open! Hardcaml
open! Signal
open! Protemu_isa

module Error = struct
  let width = 3
  let none = 0
  let reserved_opcode = 1
  let reserved_bits = 2
  let field_out_of_range = 3
  let missing_extension = 4
  let extension_out_of_range = 5
end

module I = struct
  type 'a t =
    { word_i : 'a [@bits Encoding.instruction_bits]
    ; extension_valid_i : 'a
    ; extension_i : 'a [@bits Encoding.instruction_bits]
    }
  [@@deriving hardcaml]
end

module O = struct
  type 'a t =
    { opcode_o : 'a [@bits Encoding.opcode_bits]
    ; base_valid_o : 'a
    ; needs_extension_o : 'a
    ; valid_o : 'a
    ; error_o : 'a [@bits Error.width]
    ; immediate_o : 'a [@bits Encoding.instruction_bits]
    }
  [@@deriving hardcaml]
end

[@@@ocamlformat "disable"]

let field word (f : Encoding.Bit_field.t) =
  select word ~high:(f.pos + f.width - 1) ~low:f.pos
;;

let opcode_cases ~default f =
  List.init Encoding.opcode_count ~f:(fun opcode ->
    match Encoding.form_of_opcode opcode with
    | None -> default
    | Some form -> f form)
;;

let create (_scope : Scope.t) (i : _ I.t) : _ O.t =
  let open Encoding in
  let open Layout in
  let opcode = select i.word_i ~high:15 ~low:payload_bits in
  let payload = select i.word_i ~high:(payload_bits - 1) ~low:0 in
  let bit_set f = field i.word_i f in
  let field_zero f = field i.word_i f ==:. 0 in
  let field_nonzero f = field i.word_i f <>:. 0 in
  let opcode_is value = opcode ==:. value in

  let defined =
    mux opcode (opcode_cases ~default:gnd (fun _ -> vdd))
  in
  let spare_mask =
    mux
      opcode
      (opcode_cases ~default:(zero payload_bits) (fun form ->
         of_int_trunc ~width:payload_bits (Form.spare_bits form)))
  in
  let spare_valid = (payload &: spare_mask) ==:. 0 in

  let extension_shape_valid =
    mux
      opcode
      (opcode_cases ~default:gnd (fun form ->
         match form.Form.immediate with
         | None | Some (Extension_word _) -> vdd
         | Some (Inline_or_extended { flag; inline }) ->
           ~:(bit_set flag) |: field_zero inline))
  in
  let needs_extension =
    mux
      opcode
      (opcode_cases ~default:gnd (fun form ->
         match form.Form.immediate with
         | None -> gnd
         | Some (Extension_word _) -> vdd
         | Some (Inline_or_extended { flag; inline = _ }) -> bit_set flag))
  in

  let wait_shape ~timed ~x ~imm =
    mux2
      (bit_set timed)
      (mux2 (bit_set x) (field_zero imm) (field_nonzero imm))
      (~:(bit_set x) &: field_zero imm)
  in
  let field_valid =
    mux
      opcode
      (List.init opcode_count ~f:(fun op ->
         if op = Alu.opcode
         then field i.word_i Alu.op <:. List.length Instruction.Alu_op.all
         else if op = Alu_imm.opcode
         then field i.word_i Alu_imm.op <:. List.length Instruction.Alu_op.all
         else if op = Branch.opcode
         then field i.word_i Branch.cond <:. List.length Instruction.Cond.all
         else if op = Shift.opcode
         then field_nonzero Shift.amount
         else if op = Wait_cycles_imm.opcode
         then bit_set Wait_cycles_imm.x |: field_nonzero Wait_cycles_imm.imm
         else if op = Wait_level.opcode
         then wait_shape ~timed:Wait_level.timed ~x:Wait_level.x ~imm:Wait_level.imm
         else if op = Wait_edge.opcode
         then
           (field i.word_i Wait_edge.edge <:. List.length Kinds.Edge.all)
           &: wait_shape ~timed:Wait_edge.timed ~x:Wait_edge.x ~imm:Wait_edge.imm
         else if op = Start_periodic.opcode
         then bit_set Start_periodic.x |: field_nonzero Start_periodic.imm
         else if op = Config.opcode
         then field i.word_i Config.field <:. Descriptor.Field.count
         else vdd))
  in
  let base_valid = defined &: spare_valid &: extension_shape_valid &: field_valid in
  let extension_range_valid =
    mux2
      (opcode_is Write_pins_imm.opcode)
      (i.extension_i <=:. Pins.all_pins)
      (mux2
         ((opcode_is Wait_cycles_imm.opcode)
          |: (opcode_is Start_periodic.opcode)
          |: (opcode_is Wait_level.opcode)
          |: (opcode_is Wait_edge.opcode))
         (i.extension_i <>:. 0)
         vdd)
  in
  let extension_valid = i.extension_valid_i &: extension_range_valid in
  let valid = base_valid &: (~:needs_extension |: extension_valid) in

  let inline_immediate =
    mux
      opcode
      (opcode_cases ~default:(zero instruction_bits) (fun form ->
         match form.Form.immediate with
         | None | Some (Extension_word _) -> zero instruction_bits
         | Some (Inline_or_extended { flag = _; inline }) ->
           uresize (field i.word_i inline) ~width:instruction_bits))
  in
  let immediate = mux2 needs_extension i.extension_i inline_immediate in
  let error =
    mux2
      (~:defined)
      (of_int_trunc ~width:Error.width Error.reserved_opcode)
      (mux2
         (~:spare_valid |: ~:extension_shape_valid)
         (of_int_trunc ~width:Error.width Error.reserved_bits)
         (mux2
            (~:field_valid)
            (of_int_trunc ~width:Error.width Error.field_out_of_range)
            (mux2
               (needs_extension &: ~:(i.extension_valid_i))
               (of_int_trunc ~width:Error.width Error.missing_extension)
               (mux2
                  (needs_extension &: ~:extension_range_valid)
                  (of_int_trunc ~width:Error.width Error.extension_out_of_range)
                  (of_int_trunc ~width:Error.width Error.none)))))
  in
  { O.opcode_o = opcode
  ; base_valid_o = base_valid
  ; needs_extension_o = needs_extension
  ; valid_o = valid
  ; error_o = error
  ; immediate_o = immediate
  }
;;
[@@@ocamlformat "enable"]
