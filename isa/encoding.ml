(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "encoding.ml" *)
(* The instruction encoding: one sixteen-bit word, sometimes followed by one extension
   word, and the field layout that says what its bits mean.

   THE CHOICE, AND WHERE IT COMES FROM. P1.4 measured sixteen-bit instructions with
   extension words against fixed thirty-two-bit instructions, in two memory-word widths
   each, on the same UART, SPI and I2C programs: the sixteen-bit format costs 26% to 50%
   fewer program bits and the same cycles except where an extension word is executed,
   where it costs 9% to 14% (docs/p1.4-encoding-study.md). Program storage dominates a
   design this small, so the smaller format wins and this is it. The decision, including
   what it gives up, is docs/p1.5-encoding-decision.md.

   ONE SPECIFICATION, TWO READERS. [Assembler] encodes with the field values below and the
   model's control core decodes with them; P3.2's RTL decoder is the third reader and is
   why this library exists at all. Nothing here is written twice: [Layout] declares each
   instruction's fields once, [encode] and [decode] use those declarations, and [forms]
   publishes the same values as data so a decoder can be generated from them rather than
   transcribed. A field's position exists in exactly one place in this repository.

   THE EXTENSION RULE, in one sentence: every instruction with an immediate carries an [x]
   bit, and [x] means "the inline field is zero and the next word is the full sixteen-bit
   value". One rule for every instruction, so a decoder needs no per-opcode table of which
   immediates may extend, and an extension is always exactly one word. [Write_pins_imm] is
   the one instruction whose extension is not optional: eight bits of mask and eight of
   value do not fit beside an opcode in sixteen bits at all.

   AN EXTENSION WORD IS NOT SELF-IDENTIFYING. It is sixteen bits of payload with no tag,
   so a word that is an extension when reached in sequence is an ordinary instruction when
   reached by a branch, and some extension words spell something legal. The assembler
   places labels only on instructions, so a correct program cannot do it; a corrupted
   program counter can. P1.5 kept the hazard rather than spending the tag bit that would
   remove it, and the reasoning is section 5 of the decision.

   AN INSTRUCTION IS NOT A MEMORY WORD. How instruction words sit in the program store -
   one per sixteen-bit word, or two packed into a thirty-two-bit one - is a separate
   choice, and it is [Assembler.Memory]'s. Nothing in this module knows which is in use.
*)

open! Core
open! Kinds
open! Instruction

(* The instruction word, and the split between the opcode and everything else. Five bits
   of opcode is what leaves eleven of payload, and eleven is the number every layout below
   is fitted into. *)
let instruction_bits = 16
let payload_bits = 11
let opcode_bits = instruction_bits - payload_bits
let payload_mask = (1 lsl payload_bits) - 1

module Bit_field = struct
  (* One field of an instruction's payload, counted from the payload's least significant
     bit. This is the unit the whole specification is written in: an encoder puts a value
     into one, a decoder gets a value out of one, and [Form] publishes the same records to
     anything that needs to build a decoder of its own. *)
  type t =
    { name : string
    ; pos : int
    ; width : int
    }
  [@@deriving sexp_of, compare, equal]

  let create ~name ~pos ~width =
    if pos < 0 || width < 1 || pos + width > payload_bits
    then
      raise_s
        [%message
          "field does not fit the payload" (name : string) (pos : int) (width : int)];
    { name; pos; width }
  ;;

  let limit t = (1 lsl t.width) - 1
  let mask t = limit t lsl t.pos
  let put t value = (value land limit t) lsl t.pos
  let get t word = (word lsr t.pos) land limit t

  (* A displacement field is two's complement in its own width. *)
  let signed t word =
    let value = get t word in
    if value land (1 lsl (t.width - 1)) <> 0 then value - (1 lsl t.width) else value
  ;;

  let fits t value = value >= 0 && value <= limit t
  let fits_signed t value = value >= -(1 lsl (t.width - 1)) && value < 1 lsl (t.width - 1)

  (* "rd:10..8", or "x:7" for a single bit: the notation the decision document's layout
     table is printed in. *)
  let to_string t =
    if t.width = 1
    then sprintf "%s:%d" t.name t.pos
    else sprintf "%s:%d..%d" t.name (t.pos + t.width - 1) t.pos
  ;;
end

module Immediate = struct
  (* How an instruction carries a value that may be wider than its payload has room for.
     [Inline_or_extended] is the general rule; [Extension_word] is [Write_pins_imm] alone,
     which has no inline form to fall back on. *)
  type t =
    | Inline_or_extended of
        { flag : Bit_field.t
        ; inline : Bit_field.t
        }
    | Extension_word of { name : string }
  [@@deriving sexp_of]
end

module Form = struct
  (* The published layout of one opcode: everything a decoder needs and nothing it does
     not. [fields] are the fixed fields; the immediate's flag and inline field are in
     [immediate] because they are governed by the extension rule rather than read
     directly. *)
  type t =
    { opcode : int
    ; mnemonic : string
    ; fields : Bit_field.t list
    ; immediate : Immediate.t option
    }
  [@@deriving sexp_of]

  let create ?immediate ~opcode ~mnemonic fields = { opcode; mnemonic; fields; immediate }

  (* Every payload bit the layout uses. Everything else must be zero in a valid
     instruction, which is what [decode] checks and what makes a corrupted word detectable
     at all. *)
  let used_bits t =
    let fields =
      match t.immediate with
      | None | Some (Immediate.Extension_word _) -> t.fields
      | Some (Inline_or_extended { flag; inline }) -> flag :: inline :: t.fields
    in
    List.fold fields ~init:0 ~f:(fun acc field -> acc lor Bit_field.mask field)
  ;;

  let spare_bits t = payload_mask land lnot (used_bits t)

  (* The row this form occupies in the layout table. *)
  let to_string t =
    let immediate =
      match t.immediate with
      | None -> []
      | Some (Inline_or_extended { flag; inline }) ->
        [ Bit_field.to_string flag; Bit_field.to_string inline ]
      | Some (Extension_word { name }) -> [ sprintf "%s:extension word" name ]
    in
    String.concat ~sep:" " (List.map t.fields ~f:Bit_field.to_string @ immediate)
  ;;
end

(* --------------------------------------------------------------------------------------
   The layout
   --------------------------------------------------------------------------------------

   One module per opcode, each holding its number and its fields. This is the instruction
   specification: everything below reads these values, and so does anything outside this
   library that needs to agree with them.

   Field positions are packed towards the top of the payload for the fields a reader looks
   for first - a destination register is always at 10..8 where one exists - so that a
   decoder's register-file read can start before the opcode is fully resolved. *)
module Layout = struct
  let f = Bit_field.create
  let rd_at_top = f ~name:"rd" ~pos:8 ~width:Register.index_bits
  let pin_at_top = f ~name:"pin" ~pos:8 ~width:Pins.index_bits

  module Halt = struct
    let opcode = 0
    let form = Form.create ~opcode ~mnemonic:"halt" []
  end

  module Ldi = struct
    let opcode = 1
    let rd = rd_at_top
    let x = f ~name:"x" ~pos:7 ~width:1
    let imm = f ~name:"imm" ~pos:0 ~width:7

    let form =
      Form.create
        ~opcode
        ~mnemonic:"ldi"
        ~immediate:(Inline_or_extended { flag = x; inline = imm })
        [ rd ]
    ;;
  end

  module Mov = struct
    let opcode = 2
    let rd = rd_at_top
    let rs = f ~name:"rs" ~pos:5 ~width:Register.index_bits
    let form = Form.create ~opcode ~mnemonic:"mov" [ rd; rs ]
  end

  module Alu = struct
    let opcode = 3
    let op = f ~name:"op" ~pos:8 ~width:(Enum.bits Alu_op.all)
    let rd = f ~name:"rd" ~pos:5 ~width:Register.index_bits
    let rs = f ~name:"rs" ~pos:2 ~width:Register.index_bits
    let form = Form.create ~opcode ~mnemonic:"alu" [ op; rd; rs ]
  end

  module Alu_imm = struct
    let opcode = 4
    let op = f ~name:"op" ~pos:8 ~width:(Enum.bits Alu_op.all)
    let rd = f ~name:"rd" ~pos:5 ~width:Register.index_bits
    let x = f ~name:"x" ~pos:4 ~width:1
    let imm = f ~name:"imm" ~pos:0 ~width:4

    let form =
      Form.create
        ~opcode
        ~mnemonic:"alu_imm"
        ~immediate:(Inline_or_extended { flag = x; inline = imm })
        [ op; rd ]
    ;;
  end

  module Cmp = struct
    let opcode = 5
    let ra = f ~name:"ra" ~pos:8 ~width:Register.index_bits
    let rb = f ~name:"rb" ~pos:5 ~width:Register.index_bits
    let form = Form.create ~opcode ~mnemonic:"cmp" [ ra; rb ]
  end

  module Cmp_imm = struct
    let opcode = 6
    let ra = f ~name:"ra" ~pos:8 ~width:Register.index_bits
    let x = f ~name:"x" ~pos:7 ~width:1
    let imm = f ~name:"imm" ~pos:0 ~width:7

    let form =
      Form.create
        ~opcode
        ~mnemonic:"cmp_imm"
        ~immediate:(Inline_or_extended { flag = x; inline = imm })
        [ ra ]
    ;;
  end

  module Shift = struct
    let opcode = 7
    let dir = f ~name:"dir" ~pos:10 ~width:1
    let rd = f ~name:"rd" ~pos:7 ~width:Register.index_bits

    (* One to fifteen. A shift of zero is not an instruction: it would be a [Mov] that
       also cleared the carry, and refusing it keeps every amount in the field meaningful. *)
    let amount = f ~name:"amount" ~pos:3 ~width:4
    let form = Form.create ~opcode ~mnemonic:"shift" [ dir; rd; amount ]
  end

  module Read_pins = struct
    let opcode = 8
    let rd = rd_at_top
    let form = Form.create ~opcode ~mnemonic:"read_pins" [ rd ]
  end

  module Read_status = struct
    let opcode = 9
    let rd = rd_at_top
    let form = Form.create ~opcode ~mnemonic:"read_status" [ rd ]
  end

  module Ack_status = struct
    let opcode = 10
    let mask = f ~name:"mask" ~pos:0 ~width:Event_kind.count
    let form = Form.create ~opcode ~mnemonic:"ack_status" [ mask ]
  end

  (* The flow instructions. Every displacement is signed and counted in instruction slots
     from the slot after the branch, which is the usual convention and the one that makes
     a branch to itself -1 rather than 0. The three widths are what each layout had room
     for after its other fields; P1.4 measured the reach they buy. *)
  module Jump = struct
    let opcode = 11
    let disp = f ~name:"disp" ~pos:0 ~width:11
    let form = Form.create ~opcode ~mnemonic:"jump" [ disp ]
  end

  module Branch = struct
    let opcode = 12
    let cond = f ~name:"cond" ~pos:8 ~width:(Enum.bits Cond.all)
    let disp = f ~name:"disp" ~pos:0 ~width:8
    let form = Form.create ~opcode ~mnemonic:"branch" [ cond; disp ]
  end

  module Branch_pin = struct
    let opcode = 13
    let pin = pin_at_top
    let level = f ~name:"level" ~pos:7 ~width:1
    let disp = f ~name:"disp" ~pos:0 ~width:7
    let form = Form.create ~opcode ~mnemonic:"branch_pin" [ pin; level; disp ]
  end

  module Dbnz = struct
    let opcode = 14
    let rd = rd_at_top
    let disp = f ~name:"disp" ~pos:0 ~width:8
    let form = Form.create ~opcode ~mnemonic:"dbnz" [ rd; disp ]
  end

  module Write_pins_imm = struct
    let opcode = 15
    let mode = f ~name:"mode" ~pos:10 ~width:1
    let mask = f ~name:"mask" ~pos:2 ~width:Pins.count

    (* The one mandatory extension: a mask and a value are sixteen bits together, and
       there are eleven. *)
    let form =
      Form.create
        ~opcode
        ~mnemonic:"write_pins_imm"
        ~immediate:(Extension_word { name = "value" })
        [ mode; mask ]
    ;;
  end

  module Write_pins_reg = struct
    let opcode = 16
    let mode = f ~name:"mode" ~pos:10 ~width:1
    let mask_reg = f ~name:"mask_reg" ~pos:7 ~width:Register.index_bits
    let value_reg = f ~name:"value_reg" ~pos:4 ~width:Register.index_bits

    let form =
      Form.create ~opcode ~mnemonic:"write_pins_reg" [ mode; mask_reg; value_reg ]
    ;;
  end

  module Wait_cycles_imm = struct
    let opcode = 17
    let x = f ~name:"x" ~pos:10 ~width:1
    let imm = f ~name:"imm" ~pos:0 ~width:10

    let form =
      Form.create
        ~opcode
        ~mnemonic:"wait_cycles_imm"
        ~immediate:(Inline_or_extended { flag = x; inline = imm })
        []
    ;;
  end

  module Wait_cycles_reg = struct
    let opcode = 18
    let rd = rd_at_top
    let form = Form.create ~opcode ~mnemonic:"wait_cycles_reg" [ rd ]
  end

  (* [t] says a timeout is present. With it clear the immediate and its extension flag
     must both be zero, so "wait forever" has exactly one encoding. *)
  module Wait_level = struct
    let opcode = 19
    let pin = pin_at_top
    let level = f ~name:"level" ~pos:7 ~width:1
    let timed = f ~name:"t" ~pos:6 ~width:1
    let x = f ~name:"x" ~pos:5 ~width:1
    let imm = f ~name:"imm" ~pos:0 ~width:5

    let form =
      Form.create
        ~opcode
        ~mnemonic:"wait_level"
        ~immediate:(Inline_or_extended { flag = x; inline = imm })
        [ pin; level; timed ]
    ;;
  end

  module Wait_edge = struct
    let opcode = 20
    let pin = pin_at_top
    let edge = f ~name:"edge" ~pos:6 ~width:(Enum.bits Edge.all)
    let timed = f ~name:"t" ~pos:5 ~width:1
    let x = f ~name:"x" ~pos:4 ~width:1
    let imm = f ~name:"imm" ~pos:0 ~width:4

    let form =
      Form.create
        ~opcode
        ~mnemonic:"wait_edge"
        ~immediate:(Inline_or_extended { flag = x; inline = imm })
        [ pin; edge; timed ]
    ;;
  end

  module Start_periodic = struct
    let opcode = 21
    let x = f ~name:"x" ~pos:10 ~width:1
    let imm = f ~name:"imm" ~pos:0 ~width:10

    let form =
      Form.create
        ~opcode
        ~mnemonic:"start_periodic"
        ~immediate:(Inline_or_extended { flag = x; inline = imm })
        []
    ;;
  end

  module Stop_periodic = struct
    let opcode = 22
    let form = Form.create ~opcode ~mnemonic:"stop_periodic" []
  end

  module Config = struct
    let opcode = 23
    let field = f ~name:"field" ~pos:7 ~width:4
    let x = f ~name:"x" ~pos:6 ~width:1
    let imm = f ~name:"imm" ~pos:0 ~width:6

    let form =
      Form.create
        ~opcode
        ~mnemonic:"config"
        ~immediate:(Inline_or_extended { flag = x; inline = imm })
        [ field ]
    ;;
  end

  module Issue_transfer = struct
    let opcode = 24
    let form = Form.create ~opcode ~mnemonic:"issue_transfer" []
  end

  module Fifo_push = struct
    let opcode = 25
    let fifo = f ~name:"fifo" ~pos:10 ~width:(Enum.bits Fifo_id.all)
    let blocking = f ~name:"blocking" ~pos:9 ~width:(Enum.bits Blocking.all)
    let reg = f ~name:"rs" ~pos:6 ~width:Register.index_bits
    let form = Form.create ~opcode ~mnemonic:"fifo_push" [ fifo; blocking; reg ]
  end

  module Fifo_pop = struct
    let opcode = 26
    let fifo = f ~name:"fifo" ~pos:10 ~width:(Enum.bits Fifo_id.all)
    let blocking = f ~name:"blocking" ~pos:9 ~width:(Enum.bits Blocking.all)
    let reg = f ~name:"rd" ~pos:6 ~width:Register.index_bits
    let form = Form.create ~opcode ~mnemonic:"fifo_pop" [ fifo; blocking; reg ]
  end

  (* The call pair P1.5 added. [Call]'s displacement is eight bits rather than [Jump]'s
     eleven because the link register's three bits come out of the same payload; a callee
     further away than that is reached by loading its address and using [Jump_reg], at the
     cost of the return address the call would have written. *)
  module Call = struct
    let opcode = 27
    let link = f ~name:"link" ~pos:8 ~width:Register.index_bits
    let disp = f ~name:"disp" ~pos:0 ~width:8
    let form = Form.create ~opcode ~mnemonic:"call" [ link; disp ]
  end

  module Jump_reg = struct
    let opcode = 28
    let rs = f ~name:"rs" ~pos:8 ~width:Register.index_bits
    let form = Form.create ~opcode ~mnemonic:"jump_reg" [ rs ]
  end

  (* Every defined opcode, in numerical order. This list is the specification a decoder is
     built from; [forms] below is its published name and a test checks that it is complete
     and that no two entries claim the same number. *)
  let forms =
    [ Halt.form
    ; Ldi.form
    ; Mov.form
    ; Alu.form
    ; Alu_imm.form
    ; Cmp.form
    ; Cmp_imm.form
    ; Shift.form
    ; Read_pins.form
    ; Read_status.form
    ; Ack_status.form
    ; Jump.form
    ; Branch.form
    ; Branch_pin.form
    ; Dbnz.form
    ; Write_pins_imm.form
    ; Write_pins_reg.form
    ; Wait_cycles_imm.form
    ; Wait_cycles_reg.form
    ; Wait_level.form
    ; Wait_edge.form
    ; Start_periodic.form
    ; Stop_periodic.form
    ; Config.form
    ; Issue_transfer.form
    ; Fifo_push.form
    ; Fifo_pop.form
    ; Call.form
    ; Jump_reg.form
    ]
  ;;
end

(* The published specification. *)
let forms = Layout.forms
let opcode_count = 1 lsl opcode_bits
let defined_opcodes = List.length forms

let form_of_opcode =
  let table = Array.create ~len:opcode_count None in
  List.iter forms ~f:(fun (form : Form.t) -> table.(form.opcode) <- Some form);
  fun opcode -> table.(opcode)
;;

(* The codes a decoder must refuse. They are what makes a corrupted word detectable, so
   they are named rather than left implicit. *)
let reserved_opcodes =
  List.init opcode_count ~f:Fn.id
  |> List.filter ~f:(fun op -> Option.is_none (form_of_opcode op))
;;

module Word_error = struct
  (* Why a fetched word is not an instruction. [Unspecified] is the program store's own
     answer (model/program_store.ml) and arrives before decoding; the rest are the
     decoder's. *)
  type t =
    | Unspecified
    | Reserved_opcode of int
    | Reserved_bits_set of
        { opcode : int
        ; bits : int
        }
    | Field_out_of_range of
        { opcode : int
        ; what : string
        }
    | (* The word asks for an extension word that the caller did not supply. The core
         always supplies one; evidence that decodes a single word in isolation gets this
         instead of a wrong answer. *)
      Missing_extension
  [@@deriving sexp, compare, equal]
end

module Decoded = struct
  (* [Needs_extension] carries the rest of the decode as a function of the next word,
     which is how a core charges exactly one more fetch and no more. *)
  type t =
    | Complete of int Instruction.t
    | Needs_extension of (int -> t)
    | Invalid of Word_error.t

  let rec resolve t ~extension =
    match t with
    | Needs_extension f ->
      (match extension with
       | Some value -> resolve (f value) ~extension:None
       | None -> Invalid Word_error.Missing_extension)
    | Complete _ | Invalid _ -> t
  ;;

  (* For evidence: the instruction a word decodes to, given the extension word that
     follows it when one does. *)
  let instruction t ~extension =
    match resolve t ~extension with
    | Complete instr -> Ok instr
    | Invalid reason -> Error reason
    | Needs_extension _ -> Error Word_error.Missing_extension
  ;;
end

(* --------------------------------------------------------------------------------------
   Encoding
   -------------------------------------------------------------------------------------- *)

let word opcode payload = (opcode lsl payload_bits) lor payload
let put = Bit_field.put
let enum field all ~equal value = Bit_field.put field (Enum.index all ~equal value)

(* An immediate either fits its inline field or takes the whole extension word. The
   encoder is canonical - it never spends an extension on a value that fits - so a
   program's size is a function of its values alone, and a round trip through [decode]
   returns the same words. *)
let immediate ~flag ~inline value =
  if Bit_field.fits inline value
  then Bit_field.put inline value, []
  else Bit_field.put flag 1, [ value ]
;;

let flag field condition = Bit_field.put field (Bool.to_int condition)

let displacement field value ~target =
  if Bit_field.fits_signed field value
  then Ok (Bit_field.put field value)
  else
    Error
      (Invalid.Displacement_out_of_range
         { target = Int.to_string target
         ; displacement = value
         ; bits = field.Bit_field.width
         })
;;

(* One instruction as the words that hold it: the instruction word, and its extension word
   when it has one. Only a displacement can fail, and only because the target is out of
   reach; every other field was checked by [Instruction.validate] before a program got
   this far. *)
let encode (instr : int Instruction.t) =
  let open Layout in
  match instr with
  | Halt -> Ok [ word Halt.opcode 0 ]
  | Stop_periodic -> Ok [ word Stop_periodic.opcode 0 ]
  | Issue_transfer -> Ok [ word Issue_transfer.opcode 0 ]
  | Ldi { rd; value } ->
    let imm, extension = immediate ~flag:Ldi.x ~inline:Ldi.imm value in
    Ok (word Ldi.opcode (put Ldi.rd rd lor imm) :: extension)
  | Mov { rd; rs } -> Ok [ word Mov.opcode (put Mov.rd rd lor put Mov.rs rs) ]
  | Alu { op; rd; rs } ->
    Ok
      [ word
          Alu.opcode
          (enum Alu.op Alu_op.all ~equal:Alu_op.equal op
           lor put Alu.rd rd
           lor put Alu.rs rs)
      ]
  | Alu_imm { op; rd; imm } ->
    let value, extension = immediate ~flag:Alu_imm.x ~inline:Alu_imm.imm imm in
    Ok
      (word
         Alu_imm.opcode
         (enum Alu_imm.op Alu_op.all ~equal:Alu_op.equal op
          lor put Alu_imm.rd rd
          lor value)
       :: extension)
  | Cmp { ra; rb } -> Ok [ word Cmp.opcode (put Cmp.ra ra lor put Cmp.rb rb) ]
  | Cmp_imm { ra; imm } ->
    let value, extension = immediate ~flag:Cmp_imm.x ~inline:Cmp_imm.imm imm in
    Ok (word Cmp_imm.opcode (put Cmp_imm.ra ra lor value) :: extension)
  | Shift { dir; rd; amount } ->
    Ok
      [ word
          Shift.opcode
          (enum Shift.dir Shift_dir.all ~equal:Shift_dir.equal dir
           lor put Shift.rd rd
           lor put Shift.amount amount)
      ]
  | Read_pins { rd } -> Ok [ word Read_pins.opcode (put Read_pins.rd rd) ]
  | Read_status { rd } -> Ok [ word Read_status.opcode (put Read_status.rd rd) ]
  | Ack_status { mask } -> Ok [ word Ack_status.opcode (put Ack_status.mask mask) ]
  | Write_pins_imm { mode; mask; value } ->
    Ok
      [ word
          Write_pins_imm.opcode
          (enum Write_pins_imm.mode Pin_mode.all ~equal:Pin_mode.equal mode
           lor put Write_pins_imm.mask mask)
      ; value
      ]
  | Write_pins_reg { mode; mask_reg; value_reg } ->
    Ok
      [ word
          Write_pins_reg.opcode
          (enum Write_pins_reg.mode Pin_mode.all ~equal:Pin_mode.equal mode
           lor put Write_pins_reg.mask_reg mask_reg
           lor put Write_pins_reg.value_reg value_reg)
      ]
  | Jump { target } ->
    Result.map (displacement Jump.disp target ~target) ~f:(fun d ->
      [ word Jump.opcode d ])
  | Branch { cond; target } ->
    Result.map (displacement Branch.disp target ~target) ~f:(fun d ->
      [ word Branch.opcode (enum Branch.cond Cond.all ~equal:Cond.equal cond lor d) ])
  | Branch_pin { pin; level; target } ->
    Result.map (displacement Branch_pin.disp target ~target) ~f:(fun d ->
      [ word
          Branch_pin.opcode
          (put Branch_pin.pin pin lor flag Branch_pin.level level lor d)
      ])
  | Dbnz { rd; target } ->
    Result.map (displacement Dbnz.disp target ~target) ~f:(fun d ->
      [ word Dbnz.opcode (put Dbnz.rd rd lor d) ])
  | Call { link; target } ->
    Result.map (displacement Call.disp target ~target) ~f:(fun d ->
      [ word Call.opcode (put Call.link link lor d) ])
  | Jump_reg { rs } -> Ok [ word Jump_reg.opcode (put Jump_reg.rs rs) ]
  | Wait_cycles_imm { delay } ->
    let imm, extension =
      immediate ~flag:Wait_cycles_imm.x ~inline:Wait_cycles_imm.imm delay
    in
    Ok (word Wait_cycles_imm.opcode imm :: extension)
  | Wait_cycles_reg { rd } ->
    Ok [ word Wait_cycles_reg.opcode (put Wait_cycles_reg.rd rd) ]
  | Wait_level { pin; level; timeout } ->
    let imm, extension =
      match timeout with
      | None -> 0, []
      | Some value ->
        let imm, extension = immediate ~flag:Wait_level.x ~inline:Wait_level.imm value in
        imm lor flag Wait_level.timed true, extension
    in
    Ok
      (word
         Wait_level.opcode
         (put Wait_level.pin pin lor flag Wait_level.level level lor imm)
       :: extension)
  | Wait_edge { pin; edge; timeout } ->
    let imm, extension =
      match timeout with
      | None -> 0, []
      | Some value ->
        let imm, extension = immediate ~flag:Wait_edge.x ~inline:Wait_edge.imm value in
        imm lor flag Wait_edge.timed true, extension
    in
    Ok
      (word
         Wait_edge.opcode
         (put Wait_edge.pin pin
          lor enum Wait_edge.edge Edge.all ~equal:Edge.equal edge
          lor imm)
       :: extension)
  | Start_periodic { period } ->
    let imm, extension =
      immediate ~flag:Start_periodic.x ~inline:Start_periodic.imm period
    in
    Ok (word Start_periodic.opcode imm :: extension)
  | Config { field; value } ->
    let imm, extension = immediate ~flag:Config.x ~inline:Config.imm value in
    Ok
      (word Config.opcode (put Config.field (Descriptor.Field.index field) lor imm)
       :: extension)
  | Fifo_push { fifo; rs; blocking } ->
    Ok
      [ word
          Fifo_push.opcode
          (enum Fifo_push.fifo Fifo_id.all ~equal:Fifo_id.equal fifo
           lor enum Fifo_push.blocking Blocking.all ~equal:Blocking.equal blocking
           lor put Fifo_push.reg rs)
      ]
  | Fifo_pop { fifo; rd; blocking } ->
    Ok
      [ word
          Fifo_pop.opcode
          (enum Fifo_pop.fifo Fifo_id.all ~equal:Fifo_id.equal fifo
           lor enum Fifo_pop.blocking Blocking.all ~equal:Blocking.equal blocking
           lor put Fifo_pop.reg rd)
      ]
;;

(* How many instruction words an instruction takes. A displacement of zero fits every
   displacement field and no other field's width depends on the target, so an
   instruction's size is known before its target is - which is what keeps the assembler
   one pass over sizes rather than a relaxation loop. *)
let words_of instr =
  match encode (Instruction.map_target instr ~f:(fun _ -> 0)) with
  | Ok words -> List.length words
  | Error reason ->
    raise_s
      [%message
        "an instruction with a zero displacement failed to encode" (reason : Invalid.t)]
;;

(* --------------------------------------------------------------------------------------
   Decoding
   --------------------------------------------------------------------------------------

   A word is an instruction only if it was built as one: its opcode is defined, every
   payload bit its layout does not use is zero, and every enumerated field names
   something. Nothing is decoded permissively - there is no "unused bits ignored" case -
   because the whole error-detection value of the format is in what it refuses. *)
let decode instruction_word =
  let opcode = instruction_word lsr payload_bits in
  let payload = instruction_word land payload_mask in
  match form_of_opcode opcode with
  | None -> Decoded.Invalid (Word_error.Reserved_opcode opcode)
  | Some form ->
    let spare = payload land Form.spare_bits form in
    if spare <> 0
    then Decoded.Invalid (Word_error.Reserved_bits_set { opcode; bits = spare })
    else (
      let get field = Bit_field.get field payload in
      let signed field = Bit_field.signed field payload in
      let is_set field = get field = 1 in
      let out_of_range what =
        Decoded.Invalid (Word_error.Field_out_of_range { opcode; what })
      in
      let enum all ~what field ~f =
        match Enum.of_index all (get field) with
        | Some value -> f value
        | None -> out_of_range what
      in
      let complete (instr : int Instruction.t) = Decoded.Complete instr in
      (* The extension rule, once. With [x] set the inline field must be zero - the
         encoder never writes both - and the value comes from the next word. *)
      let extended ~flag:flag_field ~inline ~build =
        if is_set flag_field
        then
          if get inline <> 0
          then
            Decoded.Invalid
              (Word_error.Reserved_bits_set
                 { opcode; bits = Bit_field.mask inline land payload })
          else Decoded.Needs_extension (fun value -> build value)
        else build (get inline)
      in
      (* A wait's timeout: absent unless [t] is set, and with [t] clear the immediate and
         its flag must both be zero so that "no timeout" has one encoding. *)
      let timeout ~timed ~flag:flag_field ~inline ~build =
        if is_set timed
        then extended ~flag:flag_field ~inline ~build:(fun value -> build (Some value))
        else if get flag_field <> 0 || get inline <> 0
        then
          Decoded.Invalid
            (Word_error.Reserved_bits_set
               { opcode
               ; bits = payload land (Bit_field.mask flag_field lor Bit_field.mask inline)
               })
        else build None
      in
      (* A delay or a shift amount of zero is not an instruction, for the same reason
         [Instruction.validate] refuses one: there is nothing it could mean. *)
      let positive value ~what ~f = if value = 0 then out_of_range what else f value in
      let open Layout in
      if opcode = Halt.opcode
      then complete Halt
      else if opcode = Stop_periodic.opcode
      then complete Stop_periodic
      else if opcode = Issue_transfer.opcode
      then complete Issue_transfer
      else if opcode = Ldi.opcode
      then
        extended ~flag:Ldi.x ~inline:Ldi.imm ~build:(fun value ->
          complete (Ldi { rd = get Ldi.rd; value }))
      else if opcode = Mov.opcode
      then complete (Mov { rd = get Mov.rd; rs = get Mov.rs })
      else if opcode = Alu.opcode
      then
        enum Alu_op.all ~what:"op" Alu.op ~f:(fun op ->
          complete (Alu { op; rd = get Alu.rd; rs = get Alu.rs }))
      else if opcode = Alu_imm.opcode
      then
        enum Alu_op.all ~what:"op" Alu_imm.op ~f:(fun op ->
          extended ~flag:Alu_imm.x ~inline:Alu_imm.imm ~build:(fun imm ->
            complete (Alu_imm { op; rd = get Alu_imm.rd; imm })))
      else if opcode = Cmp.opcode
      then complete (Cmp { ra = get Cmp.ra; rb = get Cmp.rb })
      else if opcode = Cmp_imm.opcode
      then
        extended ~flag:Cmp_imm.x ~inline:Cmp_imm.imm ~build:(fun imm ->
          complete (Cmp_imm { ra = get Cmp_imm.ra; imm }))
      else if opcode = Shift.opcode
      then
        enum Shift_dir.all ~what:"dir" Shift.dir ~f:(fun dir ->
          positive (get Shift.amount) ~what:"amount" ~f:(fun amount ->
            complete (Shift { dir; rd = get Shift.rd; amount })))
      else if opcode = Read_pins.opcode
      then complete (Read_pins { rd = get Read_pins.rd })
      else if opcode = Read_status.opcode
      then complete (Read_status { rd = get Read_status.rd })
      else if opcode = Ack_status.opcode
      then complete (Ack_status { mask = get Ack_status.mask })
      else if opcode = Jump.opcode
      then complete (Jump { target = signed Jump.disp })
      else if opcode = Branch.opcode
      then
        enum Cond.all ~what:"cond" Branch.cond ~f:(fun cond ->
          complete (Branch { cond; target = signed Branch.disp }))
      else if opcode = Branch_pin.opcode
      then
        complete
          (Branch_pin
             { pin = get Branch_pin.pin
             ; level = is_set Branch_pin.level
             ; target = signed Branch_pin.disp
             })
      else if opcode = Dbnz.opcode
      then complete (Dbnz { rd = get Dbnz.rd; target = signed Dbnz.disp })
      else if opcode = Call.opcode
      then complete (Call { link = get Call.link; target = signed Call.disp })
      else if opcode = Jump_reg.opcode
      then complete (Jump_reg { rs = get Jump_reg.rs })
      else if opcode = Write_pins_imm.opcode
      then
        enum Pin_mode.all ~what:"mode" Write_pins_imm.mode ~f:(fun mode ->
          Decoded.Needs_extension
            (fun value ->
              complete (Write_pins_imm { mode; mask = get Write_pins_imm.mask; value })))
      else if opcode = Write_pins_reg.opcode
      then
        enum Pin_mode.all ~what:"mode" Write_pins_reg.mode ~f:(fun mode ->
          complete
            (Write_pins_reg
               { mode
               ; mask_reg = get Write_pins_reg.mask_reg
               ; value_reg = get Write_pins_reg.value_reg
               }))
      else if opcode = Wait_cycles_imm.opcode
      then
        extended ~flag:Wait_cycles_imm.x ~inline:Wait_cycles_imm.imm ~build:(fun delay ->
          positive delay ~what:"delay" ~f:(fun delay ->
            complete (Wait_cycles_imm { delay })))
      else if opcode = Wait_cycles_reg.opcode
      then complete (Wait_cycles_reg { rd = get Wait_cycles_reg.rd })
      else if opcode = Wait_level.opcode
      then
        timeout
          ~timed:Wait_level.timed
          ~flag:Wait_level.x
          ~inline:Wait_level.imm
          ~build:(fun timeout ->
            match timeout with
            | Some 0 -> out_of_range "timeout"
            | _ ->
              complete
                (Wait_level
                   { pin = get Wait_level.pin; level = is_set Wait_level.level; timeout }))
      else if opcode = Wait_edge.opcode
      then
        enum Edge.all ~what:"edge" Wait_edge.edge ~f:(fun edge ->
          timeout
            ~timed:Wait_edge.timed
            ~flag:Wait_edge.x
            ~inline:Wait_edge.imm
            ~build:(fun timeout ->
              match timeout with
              | Some 0 -> out_of_range "timeout"
              | _ -> complete (Wait_edge { pin = get Wait_edge.pin; edge; timeout })))
      else if opcode = Start_periodic.opcode
      then
        extended ~flag:Start_periodic.x ~inline:Start_periodic.imm ~build:(fun period ->
          positive period ~what:"period" ~f:(fun period ->
            complete (Start_periodic { period })))
      else if opcode = Config.opcode
      then (
        match Descriptor.Field.of_index (get Config.field) with
        | None -> out_of_range "field"
        | Some field ->
          extended ~flag:Config.x ~inline:Config.imm ~build:(fun value ->
            complete (Config { field; value })))
      else if opcode = Fifo_push.opcode
      then
        enum Fifo_id.all ~what:"fifo" Fifo_push.fifo ~f:(fun fifo ->
          enum Blocking.all ~what:"blocking" Fifo_push.blocking ~f:(fun blocking ->
            complete (Fifo_push { fifo; rs = get Fifo_push.reg; blocking })))
      else if opcode = Fifo_pop.opcode
      then
        enum Fifo_id.all ~what:"fifo" Fifo_pop.fifo ~f:(fun fifo ->
          enum Blocking.all ~what:"blocking" Fifo_pop.blocking ~f:(fun blocking ->
            complete (Fifo_pop { fifo; rd = get Fifo_pop.reg; blocking })))
      else
        (* [form_of_opcode] found a form, so every defined opcode is handled above. *)
        raise_s [%message "a defined opcode has no decoder" (opcode : int)])
;;
