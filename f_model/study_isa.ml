(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "study_isa.ml" *)
(* The instruction vocabulary the P1.4 encoding study measures, and the part of its
   meaning that is decidable from one instruction alone.

   P1.4 compares two encodings "using the same examples", so there has to be something for
   both of them to encode. This module is that something: one operation set, drawn from
   construction-plan.md section 4's family table, written once so that
   [Study_encoding.Word16] and [Study_encoding.Word32] differ in field layout and nothing
   else. A program built here is a list of these instructions plus labels; which candidate
   assembles it is chosen afterwards.

   THIS IS NOT THE ISA. P1.5 chooses the provisional encoding through a recorded
   architecture decision, and it is free to add, remove or rename anything here. What P1.4
   owes it is measurements of two shapes of the same work, and the limits each shape
   imposes - which is why the deliberate gaps below are as interesting as the operations.

   DELIBERATE GAPS. There is no call and no return: construction-plan.md section 4's flow
   family lists jump, conditional branch, decrement-and-branch and halt, so a repeated
   structure is inlined or driven by a pointer. [Study_examples] pays that cost twice in
   its I2C transaction and the report records what it cost. There is no load or store to
   data memory either: the program store is a single 1RW port already shared with fetch
   (construction-plan.md section 4), so a data access would need an arbitration contract
   that does not exist yet. Registers and the two byte queues are the only data.

   WHAT AN INSTRUCTION MAY DO. Anything the mechanism model already accepts as an
   [Operation.t], plus the register and control-flow work that operations deliberately
   leave out (operation.ml: "Nothing here has an opcode"). Reading a pin into a register
   is the instruction P1.3 said it was missing when it recorded a sample as a trace marker
   rather than an operation; it is [Read_pins] here, and [Study_examples] uses it to
   receive a SPI byte and an I2C acknowledge.
*)

open! Core
open! Kinds

(* The position of a value in its [enumerate] list. kinds.ml derives [enumerate] but not
   [variants], so an encoding's field value and the decoder's lookup both come from the
   one list they already agree on rather than from two hand-written tables. *)
let rank all ~equal value =
  match List.findi all ~f:(fun _ candidate -> equal candidate value) with
  | Some (index, _) -> index
  | None -> raise_s [%message "a value is missing from its own enumeration"]
;;

(* Eight sixteen-bit registers, the starting point construction-plan.md section 4 names.
   Three bits of register field is what makes eight the interesting number: a fourth bit
   costs more than a 16-bit instruction can spare. *)
module Register = struct
  let count = 8
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

  let index = function
    | Add -> 0
    | Sub -> 1
    | And -> 2
    | Or -> 3
    | Xor -> 4
  ;;

  let of_index index = List.nth all index
end

module Shift_dir = struct
  type t =
    | Left
    | Right
  [@@deriving sexp, compare, equal, enumerate]

  let index = function
    | Left -> 0
    | Right -> 1
  ;;

  let of_index index = List.nth all index
end

(* What a conditional branch tests. Flags only; branching on a pin has its own instruction
   because the pin number does not fit beside a condition code, and branching on latched
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

  let index = function
    | Zero -> 0
    | Not_zero -> 1
    | Carry -> 2
    | Not_carry -> 3
    | Negative -> 4
    | Not_negative -> 5
  ;;

  let of_index index = List.nth all index
end

(* Which of [Pin_bank.Write]'s two forms a pin write commits. The value field means the
   driven level under [Push_pull] and the pins held low under [Open_drain]; open drain
   cannot express a driven one, which is the rule pin_bank.ml enforces. *)
module Pin_mode = struct
  type t =
    | Push_pull
    | Open_drain
  [@@deriving sexp, compare, equal, enumerate]

  let index = function
    | Push_pull -> 0
    | Open_drain -> 1
  ;;

  let of_index index = List.nth all index
end

(* One writable piece of the transfer descriptor. construction-plan.md section 4 allows
   that "configuration can take several instructions"; this says how many, by naming the
   pieces. [Control] is the one packed field: everything that is a choice between two or
   three alternatives travels together so that a descriptor costs nine writes rather than
   fourteen. *)
module Field = struct
  type t =
    | Control
    | Bit_count
    | Tx_value
    | Output_pin
    | Input_pin
    | Clock_pin
    | Initial_delay
    | Half_period
    | Pacing
  [@@deriving sexp, compare, equal, enumerate]

  let index = function
    | Control -> 0
    | Bit_count -> 1
    | Tx_value -> 2
    | Output_pin -> 3
    | Input_pin -> 4
    | Clock_pin -> 5
    | Initial_delay -> 6
    | Half_period -> 7
    | Pacing -> 8
  ;;

  let of_index index = List.nth all index
  let count = List.length all
end

module Instr = struct
  (* A branch names its target by label. The assembler resolves it to a signed
     displacement in instruction slots and refuses one that does not fit the field, which
     is a real difference between the candidates rather than a detail: see
     [Study_encoding].

     ['target] is that difference of stage made visible in the type. A program carries
     [string Instr.t]; a decoded word carries [int Instr.t], because a displacement is
     what the encoding preserved and the label is what it threw away. Nothing else about
     an instruction changes between the two, so they share one type rather than two that
     could drift. *)
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
    | (* Two-address: [rd] is both a source and the destination. A 16-bit instruction has
         no room for three register fields beside an opcode and an operation code, so the
         whole study is two-address and the report records what the 32-bit format's spare
         bits could have bought instead. *)
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
        { field : Field.t
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

  (* The label a flow instruction names, if any. *)
  let target = function
    | Jump { target }
    | Branch { target; _ }
    | Branch_pin { target; _ }
    | Dbnz { target; _ } -> Some target
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
end

module Invalid = struct
  (* Why an instruction or a program could not be assembled. Everything here is decided
     before the first edge, like [Firmware.Invalid.t] and unlike [Fault.Reject.t]. *)
  type t =
    | Empty
    | Duplicate_label of string
    | Undefined_label of string
    | Register_out_of_range of int
    | Pin_out_of_range of int
    | Immediate_out_of_range of
        { what : string
        ; value : int
        }
    | (* The target is reachable in the program but not from this instruction's
         displacement field in this candidate. *)
      Displacement_out_of_range of
        { target : string
        ; displacement : int
        ; bits : int
        }
    | (* The assembled image needs more memory words than the store has. *)
      Program_too_large of
        { words : int
        ; depth : int
        }
  [@@deriving sexp, compare, equal]
end

let check condition reason = if condition then Ok () else Error reason
let register index = check (Register.is_valid index) (Invalid.Register_out_of_range index)
let pin index = check (Pin_bank.is_valid_pin index) (Invalid.Pin_out_of_range index)

let range what value ~max =
  check (value >= 0 && value <= max) (Invalid.Immediate_out_of_range { what; value })
;;

(* A delay or timeout of zero is refused here for the same reason operation.ml refuses it:
   a timed command accepted at edge k with delay n fires at k+n, so n must be at least
   one. *)
let delay what value = check (value >= 1) (Invalid.Immediate_out_of_range { what; value })

let optional_delay what = function
  | None -> Ok ()
  | Some value -> delay what value
;;

(* Structural validation of one instruction, independent of the candidate. An encoding may
   still refuse an instruction this accepts - a 16-bit branch displacement, for instance -
   and that refusal is the measurement. *)
let validate (instr : _ Instr.t) =
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
  | Read_pins { rd } | Read_status { rd } | Wait_cycles_reg { rd } -> register rd
  | Ack_status { mask } -> range "mask" mask ~max:((1 lsl List.length Event.Kind.all) - 1)
  | Write_pins_imm { mode = _; mask; value } ->
    range "mask" mask ~max:Pin_bank.all_pins
    >>= fun () -> range "value" value ~max:Pin_bank.all_pins
  | Write_pins_reg { mode = _; mask_reg; value_reg } ->
    register mask_reg >>= fun () -> register value_reg
  | Jump _ | Branch _ -> Ok ()
  | Branch_pin { pin = index; level = _; target = _ } -> pin index
  | Dbnz { rd; target = _ } -> register rd
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

(* The descriptor a run of [Config] writes into, and the [Transfer.t] [Issue_transfer]
   hands to the machine.

   Nothing here validates: [Transfer.validate] does, at acceptance, which is the point. An
   unconfigured descriptor reaches it as one with [launch] equal to [sample] and a zero
   half period, and comes back refused rather than silently doing something. *)
module Descriptor = struct
  type t =
    { control : int
    ; bit_count : int
    ; tx_value : int
    ; output_pin : int
    ; input_pin : int
    ; clock_pin : int
    ; initial_delay : int
    ; half_period : int
    ; pacing : int
    }
  [@@deriving sexp, compare, equal]

  (* Every field zero: the state after reset, and deliberately not a legal descriptor.
     [no_pin] is nine, one past the last pin, so that zero means "pin zero" and a
     descriptor that never set a pin field is refused for the missing pin rather than
     quietly driving pin zero. *)
  let no_pin = Pin_bank.count + 1

  let cleared =
    { control = 0
    ; bit_count = 0
    ; tx_value = 0
    ; output_pin = no_pin
    ; input_pin = no_pin
    ; clock_pin = no_pin
    ; initial_delay = 0
    ; half_period = 0
    ; pacing = 0
    }
  ;;

  let set t (field : Field.t) value =
    match field with
    | Control -> { t with control = value }
    | Bit_count -> { t with bit_count = value }
    | Tx_value -> { t with tx_value = value }
    | Output_pin -> { t with output_pin = value }
    | Input_pin -> { t with input_pin = value }
    | Clock_pin -> { t with clock_pin = value }
    | Initial_delay -> { t with initial_delay = value }
    | Half_period -> { t with half_period = value }
    | Pacing -> { t with pacing = value }
  ;;

  (* [Control]'s bits, low to high: direction (two bits), bit order, idle output, idle
     clock, launch phase, sample phase. Seven bits, which is one more than the 16-bit
     candidate's inline immediate holds; a descriptor therefore costs it an extension word
     here as well. *)
  let bit control index = control land (1 lsl index) <> 0

  let direction control =
    match control land 0b11 with
    | 0 -> Direction.Tx_only
    | 1 -> Direction.Rx_only
    | _ -> Direction.Duplex
  ;;

  let phase control index =
    if bit control index then Clock_phase.On_falling else Clock_phase.On_rising
  ;;

  let pin_option value = if value >= 0 && value < Pin_bank.count then Some value else None

  (* [Pacing] is zero for an internally generated schedule; any other value selects an
     observed pin and edge, encoded as 1 + pin * 3 + edge. *)
  let pacing t =
    if t.pacing = 0
    then Transfer.Pacing.Internal { half_period = t.half_period }
    else (
      let index = t.pacing - 1 in
      let edge = Option.value (List.nth Edge.all (index % 3)) ~default:Edge.Rising in
      Transfer.Pacing.Observed_edge { pin = index / 3; edge })
  ;;

  let to_transfer t : Transfer.t =
    { direction = direction t.control
    ; bit_count = t.bit_count
    ; bit_order = (if bit t.control 2 then Bit_order.Msb_first else Bit_order.Lsb_first)
    ; tx_value = t.tx_value
    ; output_pin = pin_option t.output_pin
    ; input_pin = pin_option t.input_pin
    ; clock_pin = pin_option t.clock_pin
    ; idle_output = bit t.control 3
    ; idle_clock = bit t.control 4
    ; initial_delay = (if t.initial_delay = 0 then None else Some t.initial_delay)
    ; launch = phase t.control 5
    ; sample = phase t.control 6
    ; pacing = pacing t
    }
  ;;

  (* The [Control] value for a set of choices, so a firmware builder never writes a magic
     number. *)
  let control
    ~(direction : Direction.t)
    ~(bit_order : Bit_order.t)
    ~idle_output
    ~idle_clock
    ~(launch : Clock_phase.t)
    ~(sample : Clock_phase.t)
    =
    let set condition index = if condition then 1 lsl index else 0 in
    let direction_bits =
      match direction with
      | Tx_only -> 0
      | Rx_only -> 1
      | Duplex -> 2
    in
    let falling = function
      | Clock_phase.On_falling -> true
      | On_rising -> false
    in
    direction_bits
    lor set
          (match bit_order with
           | Msb_first -> true
           | Lsb_first -> false)
          2
    lor set idle_output 3
    lor set idle_clock 4
    lor set (falling launch) 5
    lor set (falling sample) 6
  ;;
end

module Item = struct
  (* A program is instructions and the labels between them. A label consumes no slot. *)
  type t =
    | Label of string
    | Instr of string Instr.t
  [@@deriving sexp, compare, equal]
end

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

(* Structural validation of a whole program: every instruction legal, every label unique
   and defined, and at least one instruction. Displacement range is not checked here
   because it depends on the candidate. *)
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
    validate instr
    >>= fun () ->
    match Instr.target instr with
    | Some label when not (Set.mem defined label) -> Error (Invalid.Undefined_label label)
    | _ -> Ok ())
;;

let create ~name items =
  let t = { name; items } in
  Result.map (validate t) ~f:(fun () -> t)
;;
