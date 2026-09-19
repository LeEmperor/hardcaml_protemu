(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "instruction.ml" *)
(* The instruction set: what an instruction is, and the part of its meaning that one
   instruction settles on its own.

   This is the provisional ISA chosen by P1.5 and recorded in
   docs/p1.5-encoding-decision.md. It is the operation set [Study_isa] measured for P1.4,
   with the three decisions that study left open now taken: sixteen-bit instructions with
   extension words, two-address arithmetic, and a call. What is here is the vocabulary and
   its structural rules; [Encoding] owns the bits, [Assembler] owns labels and images, and
   the model's control core owns what executing one does.

   WHAT AN INSTRUCTION MAY DO. Anything the mechanism model accepts as an operation, plus
   the register and control-flow work that operations deliberately leave out
   (model/operation.ml: "Nothing here has an opcode"). Reading a pin into a register is
   the instruction P1.3 recorded as missing when it had to treat a sample as a trace
   marker; it is [Read_pins].

   THE CALL, AND WHY IT IS TWO INSTRUCTIONS. P1.4 measured the cost of not having one: 31
   of its I2C transaction's 85 instructions were a second inlined copy of one eight-bit
   byte loop, and a third byte would have cost 31 more. [Call] writes the address of the
   following instruction into a named register and branches; [Jump_reg] jumps to a
   register. There is no stack and no dedicated link register, because either would need
   data memory or a ninth register, and neither exists: the return address lives in one of
   the eight, the callee's contract says which, and a nested call saves it with an
   ordinary [Mov] first. [Jump_reg] is absolute where every other flow instruction is
   relative, which is what makes a returned-to address meaningful at all, and it doubles
   as the computed jump a dispatch table needs.

   STILL DELIBERATELY ABSENT. No load or store: the program store is a single 1RW port
   already shared with fetch (construction-plan.md section 4), so a data access needs an
   arbitration contract that does not exist. Registers and the two byte queues are the
   only data. No multiply or divide, on construction-plan.md section 4's instruction.
*)

open! Core
open! Kinds

(* Eight sixteen-bit registers, the starting point construction-plan.md section 4 names
   and the one P1.4 measured. Three bits of register field is what makes eight the
   interesting number: a fourth costs more than a sixteen-bit instruction can spare. *)
module Register = struct
  let count = 8
  let index_bits = Int.ceil_log2 count
  let width = 16
  let mask = (1 lsl width) - 1
  let is_valid index = index >= 0 && index < count
end

(* The arithmetic and logic operations. Multiply and divide are omitted on
   construction-plan.md section 4's instruction, not for lack of encoding space. *)
module Alu_op = struct
  type t =
    | Add
    | Sub
    | And
    | Or
    | Xor
  [@@deriving sexp, compare, equal, enumerate]
end

module Shift_dir = struct
  type t =
    | Left
    | Right
  [@@deriving sexp, compare, equal, enumerate]
end

(* What a conditional branch tests. Flags only; branching on a pin has its own instruction
   because a pin number does not fit beside a condition code, and branching on latched
   status is [Read_status] followed by a flag test, so that the acknowledge stays
   explicit. *)
module Cond = struct
  type t =
    | Zero
    | Not_zero
    | Carry
    | Not_carry
    | Negative
    | Not_negative
  [@@deriving sexp, compare, equal, enumerate]
end

(* Which of the pin bank's two write forms a commit uses. The value field means the driven
   level under [Push_pull] and the pins held low under [Open_drain]; open drain cannot
   express a driven one, which is the rule the bank enforces. *)
module Pin_mode = struct
  type t =
    | Push_pull
    | Open_drain
  [@@deriving sexp, compare, equal, enumerate]
end

(* A branch names its target by label. The assembler resolves it to a signed displacement
   in instruction slots and refuses one that does not fit.

   ['target] is that difference of stage made visible in the type. A program carries
   [string t]; a decoded word carries [int t], because a displacement is what the encoding
   preserved and the label is what it threw away. Nothing else about an instruction
   changes between the two, so they share one type rather than two that could drift. *)
type 'target t =
  | Halt
  (* State. *)
  | Ldi of
      { rd : int
      ; value : int
      }
  | Mov of
      { rd : int
      ; rs : int
      }
  | (* Two-address: [rd] is both a source and the destination. A sixteen-bit instruction
       has no room for three register fields beside an opcode and an operation code, and
       P1.4 measured the alternative - a three-address form in a 32-bit instruction - as
       costing 26% to 50% more program bits for the same work. A program that needs its
       source preserved pays a [Mov]. *)
    Alu of
      { op : Alu_op.t
      ; rd : int
      ; rs : int
      }
  | Alu_imm of
      { op : Alu_op.t
      ; rd : int
      ; imm : int
      }
  | Cmp of
      { ra : int
      ; rb : int
      }
  | Cmp_imm of
      { ra : int
      ; imm : int
      }
  | Shift of
      { dir : Shift_dir.t
      ; rd : int
      ; amount : int
      }
  (* Pins and status. *)
  | (* The coherent input snapshot, not the value this bank is driving. *)
    Read_pins of { rd : int }
  | Read_status of { rd : int }
  | Ack_status of { mask : int }
  | Write_pins_imm of
      { mode : Pin_mode.t
      ; mask : int
      ; value : int
      }
  | Write_pins_reg of
      { mode : Pin_mode.t
      ; mask_reg : int
      ; value_reg : int
      }
  (* Flow. *)
  | Jump of { target : 'target }
  | Branch of
      { cond : Cond.t
      ; target : 'target
      }
  | Branch_pin of
      { pin : int
      ; level : bool
      ; target : 'target
      }
  | (* Decrement [rd] and branch while it is not zero. The fused form is why a bit loop
       costs one instruction per iteration to close rather than two. *)
    Dbnz of
      { rd : int
      ; target : 'target
      }
  | (* Write the slot address of the next instruction into [link], then branch. *)
    Call of
      { link : int
      ; target : 'target
      }
  | (* Jump to the absolute slot address in [rs]: the return half of a call, and a
       computed jump. *)
    Jump_reg of { rs : int }
  (* Time. Each of these stalls the core and leaves engines running, exactly as the
     operation it issues does. *)
  | Wait_cycles_imm of { delay : int }
  | Wait_cycles_reg of { rd : int }
  | Wait_level of
      { pin : int
      ; level : bool
      ; timeout : int option
      }
  | Wait_edge of
      { pin : int
      ; edge : Edge.t
      ; timeout : int option
      }
  | Start_periodic of { period : int }
  | Stop_periodic
  (* Engine. *)
  | Config of
      { field : Descriptor.Field.t
      ; value : int
      }
  | Issue_transfer
  (* Data queues. *)
  | Fifo_push of
      { fifo : Fifo_id.t
      ; rs : int
      ; blocking : Blocking.t
      }
  | Fifo_pop of
      { fifo : Fifo_id.t
      ; rd : int
      ; blocking : Blocking.t
      }
[@@deriving sexp, compare, equal]

(* The label a flow instruction names, if any. [Jump_reg] has none: its target is a
   register value, which is the point of it. *)
let target = function
  | Jump { target }
  | Branch { target; _ }
  | Branch_pin { target; _ }
  | Dbnz { target; _ }
  | Call { target; _ } -> Some target
  | _ -> None
;;

(* Replace the target, which is what resolution and decoding each do once. Instructions
   without one are returned unchanged; the rebuild is explicit so that adding a flow
   instruction without handling it here does not compile. *)
let map_target t ~f =
  match t with
  | Jump { target } -> Jump { target = f target }
  | Branch { cond; target } -> Branch { cond; target = f target }
  | Branch_pin { pin; level; target } -> Branch_pin { pin; level; target = f target }
  | Dbnz { rd; target } -> Dbnz { rd; target = f target }
  | Call { link; target } -> Call { link; target = f target }
  | Jump_reg { rs } -> Jump_reg { rs }
  | Halt -> Halt
  | Ldi { rd; value } -> Ldi { rd; value }
  | Mov { rd; rs } -> Mov { rd; rs }
  | Alu { op; rd; rs } -> Alu { op; rd; rs }
  | Alu_imm { op; rd; imm } -> Alu_imm { op; rd; imm }
  | Cmp { ra; rb } -> Cmp { ra; rb }
  | Cmp_imm { ra; imm } -> Cmp_imm { ra; imm }
  | Shift { dir; rd; amount } -> Shift { dir; rd; amount }
  | Read_pins { rd } -> Read_pins { rd }
  | Read_status { rd } -> Read_status { rd }
  | Ack_status { mask } -> Ack_status { mask }
  | Write_pins_imm { mode; mask; value } -> Write_pins_imm { mode; mask; value }
  | Write_pins_reg { mode; mask_reg; value_reg } ->
    Write_pins_reg { mode; mask_reg; value_reg }
  | Wait_cycles_imm { delay } -> Wait_cycles_imm { delay }
  | Wait_cycles_reg { rd } -> Wait_cycles_reg { rd }
  | Wait_level { pin; level; timeout } -> Wait_level { pin; level; timeout }
  | Wait_edge { pin; edge; timeout } -> Wait_edge { pin; edge; timeout }
  | Start_periodic { period } -> Start_periodic { period }
  | Stop_periodic -> Stop_periodic
  | Config { field; value } -> Config { field; value }
  | Issue_transfer -> Issue_transfer
  | Fifo_push { fifo; rs; blocking } -> Fifo_push { fifo; rs; blocking }
  | Fifo_pop { fifo; rd; blocking } -> Fifo_pop { fifo; rd; blocking }
;;

(* Whether execution can reach the following instruction. An assembler uses it to refuse a
   program whose last instruction would let the core fetch the never-written word after
   the image (P1.1: an unwritten location must never supply a valid instruction). A
   conditional branch falls through, so only the three unconditional ends qualify. *)
let ends_flow = function
  | Halt | Jump _ | Jump_reg _ -> true
  | _ -> false
;;

let check condition reason = if condition then Ok () else Error reason
let register index = check (Register.is_valid index) (Invalid.Register_out_of_range index)
let pin index = check (Pins.is_valid_pin index) (Invalid.Pin_out_of_range index)

let range what value ~max =
  check (value >= 0 && value <= max) (Invalid.Immediate_out_of_range { what; value })
;;

(* A delay or timeout of zero is refused here for the same reason model/operation.ml
   refuses it: a timed command accepted at edge k with delay n fires at k+n, so n must be
   at least one. *)
let delay what value = check (value >= 1) (Invalid.Immediate_out_of_range { what; value })

let optional_delay what = function
  | None -> Ok ()
  | Some value -> delay what value
;;

(* Structural validation of one instruction: every register and pin exists, and every
   immediate is a value its field could hold at full width. What it deliberately does not
   check is whether an immediate fits the INLINE field - that is what an extension word is
   for - or whether a displacement reaches, which needs the program's layout and is
   [Assembler]'s. *)
let validate (instr : _ t) =
  let ( >>= ) result f = Result.bind result ~f in
  match instr with
  | Halt | Stop_periodic | Issue_transfer -> Ok ()
  | Ldi { rd; value } -> register rd >>= fun () -> range "value" value ~max:Register.mask
  | Mov { rd; rs } -> register rd >>= fun () -> register rs
  | Alu { op = _; rd; rs } -> register rd >>= fun () -> register rs
  | Alu_imm { op = _; rd; imm } ->
    register rd >>= fun () -> range "imm" imm ~max:Register.mask
  | Cmp { ra; rb } -> register ra >>= fun () -> register rb
  | Cmp_imm { ra; imm } -> register ra >>= fun () -> range "imm" imm ~max:Register.mask
  | Shift { dir = _; rd; amount } ->
    register rd
    >>= fun () ->
    check
      (amount >= 1 && amount <= 15)
      (Invalid.Immediate_out_of_range { what = "amount"; value = amount })
  | Read_pins { rd } | Read_status { rd } | Wait_cycles_reg { rd } | Jump_reg { rs = rd }
    -> register rd
  | Ack_status { mask } -> range "mask" mask ~max:Event_kind.mask
  | Write_pins_imm { mode = _; mask; value } ->
    range "mask" mask ~max:Pins.all_pins
    >>= fun () -> range "value" value ~max:Pins.all_pins
  | Write_pins_reg { mode = _; mask_reg; value_reg } ->
    register mask_reg >>= fun () -> register value_reg
  | Jump _ | Branch _ -> Ok ()
  | Branch_pin { pin = index; level = _; target = _ } -> pin index
  | Dbnz { rd; target = _ } -> register rd
  | Call { link; target = _ } -> register link
  | Wait_cycles_imm { delay = cycles } -> delay "delay" cycles
  | Wait_level { pin = index; level = _; timeout } ->
    pin index >>= fun () -> optional_delay "timeout" timeout
  | Wait_edge { pin = index; edge = _; timeout } ->
    pin index >>= fun () -> optional_delay "timeout" timeout
  | Start_periodic { period } -> delay "period" period
  | Config { field = _; value } -> range "value" value ~max:Register.mask
  | Fifo_push { fifo = _; rs; blocking = _ } -> register rs
  | Fifo_pop { fifo = _; rd; blocking = _ } -> register rd
;;
