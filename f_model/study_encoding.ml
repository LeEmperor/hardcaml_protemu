(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "study_encoding.ml" *)
(* The two instruction encodings P1.4 compares, the four instruction/memory-word
   combinations they can be stored in, and the assembler that turns a [Study_isa] program
   into a memory image for each.

   THE TWO SHAPES. [Word16] is a fixed 16-bit instruction with occasional extension words;
   [Word32] is a fixed 32-bit instruction with none. Both carry the same operation set, so
   a program written once is assembled by both and the difference between the two images
   is the measurement.

   THE EXTENSION RULE, in one sentence: every 16-bit instruction with an immediate carries
   an [x] bit, and [x] means "the inline field is zero and the next word is the full
   sixteen-bit value". One rule for every instruction, so a decoder needs no per-opcode
   table of which immediates may extend, and an extension is always exactly one word.
   [Write_pins_imm] is the single instruction whose extension is not optional: eight bits
   of mask and eight of value do not fit beside an opcode in sixteen bits at all.

   AN EXTENSION WORD IS NOT SELF-IDENTIFYING. It is sixteen bits of payload with no tag,
   so a word that is an extension when reached in sequence is an ordinary instruction when
   reached by a branch. The assembler only ever places labels on instructions, so a
   correct program cannot do it; a corrupted program counter can, and will execute
   whatever those bits happen to spell. The 32-bit candidate has no such word. That
   asymmetry is recorded in the report rather than engineered away, because removing it
   costs the tag bit that made the 16-bit format worth measuring.

   INSTRUCTION WIDTH AND MEMORY WIDTH ARE SEPARATE CHOICES, as construction-plan.md
   section 4 requires. [Candidate.all] is the cross product that matters: each instruction
   width in its natural memory word, 16-bit instructions packed two per 32-bit word, and
   32-bit instructions split across two 16-bit words. Packing changes no bits of any
   instruction; it changes how many memory reads reach them, which is [Study_core]'s
   business.

   BYTE ORDER is little-endian throughout, and it is a transport property rather than an
   instruction-format one: the loader assembles complete memory words before issuing
   writes (construction-plan.md section 4), so byte order describes how a host byte stream
   becomes those words, never how the core reads them. [Image.bytes] is that stream. In a
   32-bit memory word holding two 16-bit instructions, the earlier instruction occupies
   the less significant half, so the two conventions agree: earlier is lower.
*)

open! Core
open! Kinds
open Study_isa

(* Field extraction and insertion. Positions are counted from the least significant bit of
   the payload, which is the instruction word with its opcode removed. *)
module Bits = struct
  let mask width = (1 lsl width) - 1
  let put ~pos ~width value = (value land mask width) lsl pos
  let get word ~pos ~width = (word lsr pos) land mask width

  let signed word ~pos ~width =
    let value = get word ~pos ~width in
    if value land (1 lsl (width - 1)) <> 0 then value - (1 lsl width) else value
  ;;

  let fits_signed value ~width = value >= -(1 lsl (width - 1)) && value < 1 lsl (width - 1)

  (* The bits a layout uses, so that everything else can be required to be zero. *)
  let used fields =
    List.fold fields ~init:0 ~f:(fun acc (pos, width) -> acc lor (mask width lsl pos))
  ;;
end

(* One number per instruction, shared by both widths so that a reader comparing the two
   layout tables is comparing layouts and not numbering. Five bits hold all of them, which
   is what leaves the 16-bit format eleven bits of payload. *)
module Opcode = struct
  let halt = 0
  let ldi = 1
  let mov = 2
  let alu = 3
  let alu_imm = 4
  let cmp = 5
  let cmp_imm = 6
  let shift = 7
  let read_pins = 8
  let read_status = 9
  let ack_status = 10
  let jump = 11
  let branch = 12
  let branch_pin = 13
  let dbnz = 14
  let write_pins_imm = 15
  let write_pins_reg = 16
  let wait_cycles_imm = 17
  let wait_cycles_reg = 18
  let wait_level = 19
  let wait_edge = 20
  let start_periodic = 21
  let stop_periodic = 22
  let config = 23
  let issue_transfer = 24
  let fifo_push = 25
  let fifo_pop = 26

  (* Twenty-seven of the thirty-two 5-bit codes are defined. The remaining five are
     reserved and decode to nothing, which is what makes an invalid instruction detectable
     at all. *)
  let defined = 27
end

module Word_error = struct
  (* Why a fetched word is not an instruction. [Unspecified] is the program store's own
     answer (program_store.ml) and arrives before decoding; the rest are the decoder's. *)
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
         back instead of a wrong answer. *)
      Missing_extension
  [@@deriving sexp, compare, equal]
end

module Decoded = struct
  (* [Needs_extension] carries the rest of the decode as a function of the next word,
     which is how the core charges exactly one more fetch and no more. *)
  type t =
    | Complete of int Instr.t
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
   The 16-bit instruction
   --------------------------------------------------------------------------------------

   Payload layout, bits 10..0 of the word; the opcode occupies bits 15..11. [x] is the
   extension flag described in the header.

   | instruction | payload | | --------------- |
   ---------------------------------------------- | | ldi | rd:10..8 x:7 imm:6..0 | | mov
   | rd:10..8 rs:7..5 | | alu | op:10..8 rd:7..5 rs:4..2 | | alu_imm | op:10..8 rd:7..5
   x:4 imm:3..0 | | cmp | ra:10..8 rb:7..5 | | cmp_imm | ra:10..8 x:7 imm:6..0 | | shift |
   dir:10 rd:9..7 amount:6..3 | | read_pins | rd:10..8 | | read_status | rd:10..8 | |
   ack_status | mask:5..0 | | jump | displacement:10..0 | | branch | cond:10..8
   displacement:7..0 | | branch_pin | pin:10..8 level:7 displacement:6..0 | | dbnz |
   rd:10..8 displacement:7..0 | | write_pins_imm | mode:10 mask:9..2, value in the
   extension word | | write_pins_reg | mode:10 mask_reg:9..7 value_reg:6..4 | |
   wait_cycles_imm | x:10 imm:9..0 | | wait_cycles_reg | rd:10..8 | | wait_level |
   pin:10..8 level:7 t:6 x:5 imm:4..0 | | wait_edge | pin:10..8 edge:7..6 t:5 x:4 imm:3..0
   | | start_periodic | x:10 imm:9..0 | | config | field:10..7 x:6 imm:5..0 | |
   fifo_push/pop | fifo:10 blocking:9 reg:8..6 |

   Every bit not listed must be zero. [t] on a wait means a timeout is present; with [t]
   clear, [x] and the immediate must be zero. *)
module Word16 = struct
  let payload_bits = 11
  let word opcode payload = (opcode lsl payload_bits) lor payload

  (* An immediate either fits its inline field or takes the whole extension word. The
     encoder is canonical - it never spends an extension on a value that fits - so a
     program's size is a function of its values alone. *)
  let immediate ~pos ~width ~x value =
    if value <= Bits.mask width
    then Bits.put ~pos ~width value, []
    else Bits.put ~pos:x ~width:1 1, [ value ]
  ;;

  let flag ~pos condition = Bits.put ~pos ~width:1 (Bool.to_int condition)

  let displacement value ~width ~target =
    if Bits.fits_signed value ~width
    then Ok (Bits.put ~pos:0 ~width value)
    else
      Error
        (Invalid.Displacement_out_of_range
           { target = Int.to_string target; displacement = value; bits = width })
  ;;

  let encode (instr : int Instr.t) =
    match (instr : int Instr.t) with
    | Halt -> Ok [ word Opcode.halt 0 ]
    | Stop_periodic -> Ok [ word Opcode.stop_periodic 0 ]
    | Issue_transfer -> Ok [ word Opcode.issue_transfer 0 ]
    | Ldi { rd; value } ->
      let imm, extension = immediate ~pos:0 ~width:7 ~x:7 value in
      Ok (word Opcode.ldi (Bits.put ~pos:8 ~width:3 rd lor imm) :: extension)
    | Mov { rd; rs } ->
      Ok [ word Opcode.mov (Bits.put ~pos:8 ~width:3 rd lor Bits.put ~pos:5 ~width:3 rs) ]
    | Alu { op; rd; rs } ->
      Ok
        [ word
            Opcode.alu
            (Bits.put ~pos:8 ~width:3 (Alu_op.index op)
             lor Bits.put ~pos:5 ~width:3 rd
             lor Bits.put ~pos:2 ~width:3 rs)
        ]
    | Alu_imm { op; rd; imm } ->
      let value, extension = immediate ~pos:0 ~width:4 ~x:4 imm in
      Ok
        (word
           Opcode.alu_imm
           (Bits.put ~pos:8 ~width:3 (Alu_op.index op)
            lor Bits.put ~pos:5 ~width:3 rd
            lor value)
         :: extension)
    | Cmp { ra; rb } ->
      Ok [ word Opcode.cmp (Bits.put ~pos:8 ~width:3 ra lor Bits.put ~pos:5 ~width:3 rb) ]
    | Cmp_imm { ra; imm } ->
      let value, extension = immediate ~pos:0 ~width:7 ~x:7 imm in
      Ok (word Opcode.cmp_imm (Bits.put ~pos:8 ~width:3 ra lor value) :: extension)
    | Shift { dir; rd; amount } ->
      Ok
        [ word
            Opcode.shift
            (Bits.put ~pos:10 ~width:1 (Shift_dir.index dir)
             lor Bits.put ~pos:7 ~width:3 rd
             lor Bits.put ~pos:3 ~width:4 amount)
        ]
    | Read_pins { rd } -> Ok [ word Opcode.read_pins (Bits.put ~pos:8 ~width:3 rd) ]
    | Read_status { rd } -> Ok [ word Opcode.read_status (Bits.put ~pos:8 ~width:3 rd) ]
    | Ack_status { mask } -> Ok [ word Opcode.ack_status (Bits.put ~pos:0 ~width:6 mask) ]
    | Write_pins_imm { mode; mask; value } ->
      (* The one mandatory extension: mask and value together need sixteen bits. *)
      Ok
        [ word
            Opcode.write_pins_imm
            (Bits.put ~pos:10 ~width:1 (Pin_mode.index mode)
             lor Bits.put ~pos:2 ~width:8 mask)
        ; value
        ]
    | Write_pins_reg { mode; mask_reg; value_reg } ->
      Ok
        [ word
            Opcode.write_pins_reg
            (Bits.put ~pos:10 ~width:1 (Pin_mode.index mode)
             lor Bits.put ~pos:7 ~width:3 mask_reg
             lor Bits.put ~pos:4 ~width:3 value_reg)
        ]
    | Jump { target } ->
      Result.map (displacement target ~width:11 ~target) ~f:(fun d ->
        [ word Opcode.jump d ])
    | Branch { cond; target } ->
      Result.map (displacement target ~width:8 ~target) ~f:(fun d ->
        [ word Opcode.branch (Bits.put ~pos:8 ~width:3 (Cond.index cond) lor d) ])
    | Branch_pin { pin; level; target } ->
      Result.map (displacement target ~width:7 ~target) ~f:(fun d ->
        [ word Opcode.branch_pin (Bits.put ~pos:8 ~width:3 pin lor flag ~pos:7 level lor d)
        ])
    | Dbnz { rd; target } ->
      Result.map (displacement target ~width:8 ~target) ~f:(fun d ->
        [ word Opcode.dbnz (Bits.put ~pos:8 ~width:3 rd lor d) ])
    | Wait_cycles_imm { delay } ->
      let imm, extension = immediate ~pos:0 ~width:10 ~x:10 delay in
      Ok (word Opcode.wait_cycles_imm imm :: extension)
    | Wait_cycles_reg { rd } ->
      Ok [ word Opcode.wait_cycles_reg (Bits.put ~pos:8 ~width:3 rd) ]
    | Wait_level { pin; level; timeout } ->
      let imm, extension =
        match timeout with
        | None -> 0, []
        | Some value ->
          let imm, extension = immediate ~pos:0 ~width:5 ~x:5 value in
          imm lor flag ~pos:6 true, extension
      in
      Ok
        (word
           Opcode.wait_level
           (Bits.put ~pos:8 ~width:3 pin lor flag ~pos:7 level lor imm)
         :: extension)
    | Wait_edge { pin; edge; timeout } ->
      let imm, extension =
        match timeout with
        | None -> 0, []
        | Some value ->
          let imm, extension = immediate ~pos:0 ~width:4 ~x:4 value in
          imm lor flag ~pos:5 true, extension
      in
      Ok
        (word
           Opcode.wait_edge
           (Bits.put ~pos:8 ~width:3 pin
            lor Bits.put ~pos:6 ~width:2 (rank Edge.all ~equal:Edge.equal edge)
            lor imm)
         :: extension)
    | Start_periodic { period } ->
      let imm, extension = immediate ~pos:0 ~width:10 ~x:10 period in
      Ok (word Opcode.start_periodic imm :: extension)
    | Config { field; value } ->
      let imm, extension = immediate ~pos:0 ~width:6 ~x:6 value in
      Ok
        (word Opcode.config (Bits.put ~pos:7 ~width:4 (Field.index field) lor imm)
         :: extension)
    | Fifo_push { fifo; rs; blocking } ->
      Ok
        [ word
            Opcode.fifo_push
            (Bits.put ~pos:10 ~width:1 (rank Fifo_id.all ~equal:Fifo_id.equal fifo)
             lor Bits.put
                   ~pos:9
                   ~width:1
                   (rank Blocking.all ~equal:Blocking.equal blocking)
             lor Bits.put ~pos:6 ~width:3 rs)
        ]
    | Fifo_pop { fifo; rd; blocking } ->
      Ok
        [ word
            Opcode.fifo_pop
            (Bits.put ~pos:10 ~width:1 (rank Fifo_id.all ~equal:Fifo_id.equal fifo)
             lor Bits.put
                   ~pos:9
                   ~width:1
                   (rank Blocking.all ~equal:Blocking.equal blocking)
             lor Bits.put ~pos:6 ~width:3 rd)
        ]
  ;;

  (* Decoding. Every case checks that the bits its layout does not use are zero and that
     each enumerated field names something, so a word is an instruction only if it was
     built as one. *)
  let decode word =
    let opcode = word lsr payload_bits in
    let payload = word land Bits.mask payload_bits in
    let reserved fields =
      let unused = payload land lnot (Bits.used fields) in
      if unused = 0
      then Ok ()
      else Error (Word_error.Reserved_bits_set { opcode; bits = unused })
    in
    let field ~pos ~width = Bits.get payload ~pos ~width in
    let signed ~pos ~width = Bits.signed payload ~pos ~width in
    let enum ~what value =
      Result.of_option value ~error:(Word_error.Field_out_of_range { opcode; what })
    in
    let extended ~x ~inline ~build =
      if field ~pos:x ~width:1 = 1
      then
        if inline <> 0
        then Decoded.Invalid (Word_error.Reserved_bits_set { opcode; bits = inline })
        else Decoded.Needs_extension (fun value -> Decoded.Complete (build value))
      else Decoded.Complete (build inline)
    in
    let result =
      match () with
      | () when opcode = Opcode.halt ->
        Result.map (reserved []) ~f:(fun () -> `Complete Instr.Halt)
      | () when opcode = Opcode.stop_periodic ->
        Result.map (reserved []) ~f:(fun () -> `Complete Instr.Stop_periodic)
      | () when opcode = Opcode.issue_transfer ->
        Result.map (reserved []) ~f:(fun () -> `Complete Instr.Issue_transfer)
      | () when opcode = Opcode.ldi ->
        Result.map
          (reserved [ 8, 3; 7, 1; 0, 7 ])
          ~f:(fun () ->
            let rd = field ~pos:8 ~width:3 in
            `Extended (7, field ~pos:0 ~width:7, fun value -> Instr.Ldi { rd; value }))
      | () when opcode = Opcode.mov ->
        Result.map
          (reserved [ 8, 3; 5, 3 ])
          ~f:(fun () ->
            `Complete
              (Instr.Mov { rd = field ~pos:8 ~width:3; rs = field ~pos:5 ~width:3 }))
      | () when opcode = Opcode.alu ->
        Result.bind
          (reserved [ 8, 3; 5, 3; 2, 3 ])
          ~f:(fun () ->
            Result.map
              (enum ~what:"alu_op" (Alu_op.of_index (field ~pos:8 ~width:3)))
              ~f:(fun op ->
                `Complete
                  (Instr.Alu
                     { op; rd = field ~pos:5 ~width:3; rs = field ~pos:2 ~width:3 })))
      | () when opcode = Opcode.alu_imm ->
        Result.bind
          (reserved [ 8, 3; 5, 3; 4, 1; 0, 4 ])
          ~f:(fun () ->
            Result.map
              (enum ~what:"alu_op" (Alu_op.of_index (field ~pos:8 ~width:3)))
              ~f:(fun op ->
                let rd = field ~pos:5 ~width:3 in
                `Extended
                  (4, field ~pos:0 ~width:4, fun imm -> Instr.Alu_imm { op; rd; imm })))
      | () when opcode = Opcode.cmp ->
        Result.map
          (reserved [ 8, 3; 5, 3 ])
          ~f:(fun () ->
            `Complete
              (Instr.Cmp { ra = field ~pos:8 ~width:3; rb = field ~pos:5 ~width:3 }))
      | () when opcode = Opcode.cmp_imm ->
        Result.map
          (reserved [ 8, 3; 7, 1; 0, 7 ])
          ~f:(fun () ->
            let ra = field ~pos:8 ~width:3 in
            `Extended (7, field ~pos:0 ~width:7, fun imm -> Instr.Cmp_imm { ra; imm }))
      | () when opcode = Opcode.shift ->
        Result.bind
          (reserved [ 10, 1; 7, 3; 3, 4 ])
          ~f:(fun () ->
            let amount = field ~pos:3 ~width:4 in
            if amount = 0
            then Error (Word_error.Field_out_of_range { opcode; what = "amount" })
            else
              Result.map
                (enum ~what:"shift_dir" (Shift_dir.of_index (field ~pos:10 ~width:1)))
                ~f:(fun dir ->
                  `Complete (Instr.Shift { dir; rd = field ~pos:7 ~width:3; amount })))
      | () when opcode = Opcode.read_pins ->
        Result.map
          (reserved [ 8, 3 ])
          ~f:(fun () -> `Complete (Instr.Read_pins { rd = field ~pos:8 ~width:3 }))
      | () when opcode = Opcode.read_status ->
        Result.map
          (reserved [ 8, 3 ])
          ~f:(fun () -> `Complete (Instr.Read_status { rd = field ~pos:8 ~width:3 }))
      | () when opcode = Opcode.ack_status ->
        Result.map
          (reserved [ 0, 6 ])
          ~f:(fun () -> `Complete (Instr.Ack_status { mask = field ~pos:0 ~width:6 }))
      | () when opcode = Opcode.jump ->
        Result.map
          (reserved [ 0, 11 ])
          ~f:(fun () -> `Complete (Instr.Jump { target = signed ~pos:0 ~width:11 }))
      | () when opcode = Opcode.branch ->
        Result.bind
          (reserved [ 8, 3; 0, 8 ])
          ~f:(fun () ->
            Result.map
              (enum ~what:"cond" (Cond.of_index (field ~pos:8 ~width:3)))
              ~f:(fun cond ->
                `Complete (Instr.Branch { cond; target = signed ~pos:0 ~width:8 })))
      | () when opcode = Opcode.branch_pin ->
        Result.map
          (reserved [ 8, 3; 7, 1; 0, 7 ])
          ~f:(fun () ->
            `Complete
              (Instr.Branch_pin
                 { pin = field ~pos:8 ~width:3
                 ; level = field ~pos:7 ~width:1 = 1
                 ; target = signed ~pos:0 ~width:7
                 }))
      | () when opcode = Opcode.dbnz ->
        Result.map
          (reserved [ 8, 3; 0, 8 ])
          ~f:(fun () ->
            `Complete
              (Instr.Dbnz { rd = field ~pos:8 ~width:3; target = signed ~pos:0 ~width:8 }))
      | () when opcode = Opcode.write_pins_imm ->
        Result.bind
          (reserved [ 10, 1; 2, 8 ])
          ~f:(fun () ->
            Result.map
              (enum ~what:"pin_mode" (Pin_mode.of_index (field ~pos:10 ~width:1)))
              ~f:(fun mode ->
                let mask = field ~pos:2 ~width:8 in
                `Mandatory_extension
                  (fun value -> Instr.Write_pins_imm { mode; mask; value })))
      | () when opcode = Opcode.write_pins_reg ->
        Result.bind
          (reserved [ 10, 1; 7, 3; 4, 3 ])
          ~f:(fun () ->
            Result.map
              (enum ~what:"pin_mode" (Pin_mode.of_index (field ~pos:10 ~width:1)))
              ~f:(fun mode ->
                `Complete
                  (Instr.Write_pins_reg
                     { mode
                     ; mask_reg = field ~pos:7 ~width:3
                     ; value_reg = field ~pos:4 ~width:3
                     })))
      | () when opcode = Opcode.wait_cycles_imm ->
        Result.map
          (reserved [ 10, 1; 0, 10 ])
          ~f:(fun () ->
            `Extended
              (10, field ~pos:0 ~width:10, fun delay -> Instr.Wait_cycles_imm { delay }))
      | () when opcode = Opcode.wait_cycles_reg ->
        Result.map
          (reserved [ 8, 3 ])
          ~f:(fun () -> `Complete (Instr.Wait_cycles_reg { rd = field ~pos:8 ~width:3 }))
      | () when opcode = Opcode.wait_level ->
        Result.bind
          (reserved [ 8, 3; 7, 1; 6, 1; 5, 1; 0, 5 ])
          ~f:(fun () ->
            let pin = field ~pos:8 ~width:3 in
            let level = field ~pos:7 ~width:1 = 1 in
            if field ~pos:6 ~width:1 = 0
            then
              if field ~pos:5 ~width:1 <> 0 || field ~pos:0 ~width:5 <> 0
              then
                Error (Word_error.Reserved_bits_set { opcode; bits = payload land 0x3f })
              else Ok (`Complete (Instr.Wait_level { pin; level; timeout = None }))
            else
              Ok
                (`Extended
                  ( 5
                  , field ~pos:0 ~width:5
                  , fun timeout -> Instr.Wait_level { pin; level; timeout = Some timeout }
                  )))
      | () when opcode = Opcode.wait_edge ->
        Result.bind
          (reserved [ 8, 3; 6, 2; 5, 1; 4, 1; 0, 4 ])
          ~f:(fun () ->
            Result.bind
              (enum ~what:"edge" (List.nth Edge.all (field ~pos:6 ~width:2)))
              ~f:(fun edge ->
                let pin = field ~pos:8 ~width:3 in
                if field ~pos:5 ~width:1 = 0
                then
                  if field ~pos:4 ~width:1 <> 0 || field ~pos:0 ~width:4 <> 0
                  then
                    Error
                      (Word_error.Reserved_bits_set { opcode; bits = payload land 0x1f })
                  else Ok (`Complete (Instr.Wait_edge { pin; edge; timeout = None }))
                else
                  Ok
                    (`Extended
                      ( 4
                      , field ~pos:0 ~width:4
                      , fun timeout ->
                          Instr.Wait_edge { pin; edge; timeout = Some timeout } ))))
      | () when opcode = Opcode.start_periodic ->
        Result.map
          (reserved [ 10, 1; 0, 10 ])
          ~f:(fun () ->
            `Extended
              (10, field ~pos:0 ~width:10, fun period -> Instr.Start_periodic { period }))
      | () when opcode = Opcode.config ->
        Result.bind
          (reserved [ 7, 4; 6, 1; 0, 6 ])
          ~f:(fun () ->
            Result.map
              (enum ~what:"field" (Field.of_index (field ~pos:7 ~width:4)))
              ~f:(fun descriptor_field ->
                `Extended
                  ( 6
                  , field ~pos:0 ~width:6
                  , fun value -> Instr.Config { field = descriptor_field; value } )))
      | () when opcode = Opcode.fifo_push || opcode = Opcode.fifo_pop ->
        Result.bind
          (reserved [ 10, 1; 9, 1; 6, 3 ])
          ~f:(fun () ->
            Result.bind
              (enum ~what:"fifo" (List.nth Fifo_id.all (field ~pos:10 ~width:1)))
              ~f:(fun fifo ->
                Result.map
                  (enum ~what:"blocking" (List.nth Blocking.all (field ~pos:9 ~width:1)))
                  ~f:(fun blocking ->
                    let reg = field ~pos:6 ~width:3 in
                    `Complete
                      (if opcode = Opcode.fifo_push
                       then Instr.Fifo_push { fifo; rs = reg; blocking }
                       else Instr.Fifo_pop { fifo; rd = reg; blocking }))))
      | () -> Error (Word_error.Reserved_opcode opcode)
    in
    match result with
    | Error reason -> Decoded.Invalid reason
    | Ok (`Complete instr) -> Decoded.Complete instr
    | Ok (`Extended (x, inline, build)) -> extended ~x ~inline ~build
    | Ok (`Mandatory_extension build) ->
      Decoded.Needs_extension
        (fun value ->
          if value > Pin_bank.all_pins
          then
            Decoded.Invalid
              (Word_error.Reserved_bits_set
                 { opcode = Opcode.write_pins_imm
                 ; bits = value land lnot Pin_bank.all_pins
                 })
          else Decoded.Complete (build value))
  ;;
end

(* --------------------------------------------------------------------------------------
   The 32-bit instruction
   --------------------------------------------------------------------------------------

   Payload layout, bits 25..0; the opcode occupies bits 31..26. Every immediate is sixteen
   bits and inline, so no instruction is ever more than one word, and the fields that were
   packed against each other at sixteen bits are simply placed:

   | instruction | payload | | --------------- |
   ------------------------------------------- | | ldi | rd:25..23 imm:15..0 | | mov |
   rd:25..23 rs:22..20 | | alu | op:25..23 rd:22..20 rs:19..17 | | alu_imm | op:25..23
   rd:22..20 imm:15..0 | | cmp | ra:25..23 rb:22..20 | | cmp_imm | ra:25..23 imm:15..0 | |
   shift | dir:25 rd:24..22 amount:21..18 | | read_pins | rd:25..23 | | read_status |
   rd:25..23 | | ack_status | mask:5..0 | | jump | displacement:25..0 | | branch |
   cond:25..23 displacement:15..0 | | branch_pin | pin:25..23 level:22 displacement:15..0
   | | dbnz | rd:25..23 displacement:15..0 | | write_pins_imm | mode:25 mask:24..17
   value:16..9 | | write_pins_reg | mode:25 mask_reg:24..22 value_reg:21..19 | |
   wait_cycles_imm | imm:15..0 | | wait_cycles_reg | rd:25..23 | | wait_level | pin:25..23
   level:22 t:21 imm:15..0 | | wait_edge | pin:25..23 edge:22..21 t:20 imm:15..0 | |
   start_periodic | imm:15..0 | | config | field:25..22 imm:15..0 | | fifo_push/pop |
   fifo:25 blocking:24 reg:23..21 |

   The spare room is real and is recorded rather than spent: nine bits are free in [alu],
   which is where a three-address form would go, and every immediate instruction has at
   least four. P1.5 decides whether to spend them. *)
module Word32 = struct
  let payload_bits = 26
  let word opcode payload = (opcode lsl payload_bits) lor payload
  let flag ~pos condition = Bits.put ~pos ~width:1 (Bool.to_int condition)

  let displacement value ~width ~target =
    if Bits.fits_signed value ~width
    then Ok (Bits.put ~pos:0 ~width value)
    else
      Error
        (Invalid.Displacement_out_of_range
           { target = Int.to_string target; displacement = value; bits = width })
  ;;

  let encode (instr : int Instr.t) =
    match instr with
    | Halt -> Ok [ word Opcode.halt 0 ]
    | Stop_periodic -> Ok [ word Opcode.stop_periodic 0 ]
    | Issue_transfer -> Ok [ word Opcode.issue_transfer 0 ]
    | Ldi { rd; value } ->
      Ok
        [ word
            Opcode.ldi
            (Bits.put ~pos:23 ~width:3 rd lor Bits.put ~pos:0 ~width:16 value)
        ]
    | Mov { rd; rs } ->
      Ok
        [ word Opcode.mov (Bits.put ~pos:23 ~width:3 rd lor Bits.put ~pos:20 ~width:3 rs)
        ]
    | Alu { op; rd; rs } ->
      Ok
        [ word
            Opcode.alu
            (Bits.put ~pos:23 ~width:3 (Alu_op.index op)
             lor Bits.put ~pos:20 ~width:3 rd
             lor Bits.put ~pos:17 ~width:3 rs)
        ]
    | Alu_imm { op; rd; imm } ->
      Ok
        [ word
            Opcode.alu_imm
            (Bits.put ~pos:23 ~width:3 (Alu_op.index op)
             lor Bits.put ~pos:20 ~width:3 rd
             lor Bits.put ~pos:0 ~width:16 imm)
        ]
    | Cmp { ra; rb } ->
      Ok
        [ word Opcode.cmp (Bits.put ~pos:23 ~width:3 ra lor Bits.put ~pos:20 ~width:3 rb)
        ]
    | Cmp_imm { ra; imm } ->
      Ok
        [ word
            Opcode.cmp_imm
            (Bits.put ~pos:23 ~width:3 ra lor Bits.put ~pos:0 ~width:16 imm)
        ]
    | Shift { dir; rd; amount } ->
      Ok
        [ word
            Opcode.shift
            (Bits.put ~pos:25 ~width:1 (Shift_dir.index dir)
             lor Bits.put ~pos:22 ~width:3 rd
             lor Bits.put ~pos:18 ~width:4 amount)
        ]
    | Read_pins { rd } -> Ok [ word Opcode.read_pins (Bits.put ~pos:23 ~width:3 rd) ]
    | Read_status { rd } -> Ok [ word Opcode.read_status (Bits.put ~pos:23 ~width:3 rd) ]
    | Ack_status { mask } -> Ok [ word Opcode.ack_status (Bits.put ~pos:0 ~width:6 mask) ]
    | Write_pins_imm { mode; mask; value } ->
      Ok
        [ word
            Opcode.write_pins_imm
            (Bits.put ~pos:25 ~width:1 (Pin_mode.index mode)
             lor Bits.put ~pos:17 ~width:8 mask
             lor Bits.put ~pos:9 ~width:8 value)
        ]
    | Write_pins_reg { mode; mask_reg; value_reg } ->
      Ok
        [ word
            Opcode.write_pins_reg
            (Bits.put ~pos:25 ~width:1 (Pin_mode.index mode)
             lor Bits.put ~pos:22 ~width:3 mask_reg
             lor Bits.put ~pos:19 ~width:3 value_reg)
        ]
    | Jump { target } ->
      Result.map (displacement target ~width:26 ~target) ~f:(fun d ->
        [ word Opcode.jump d ])
    | Branch { cond; target } ->
      Result.map (displacement target ~width:16 ~target) ~f:(fun d ->
        [ word Opcode.branch (Bits.put ~pos:23 ~width:3 (Cond.index cond) lor d) ])
    | Branch_pin { pin; level; target } ->
      Result.map (displacement target ~width:16 ~target) ~f:(fun d ->
        [ word
            Opcode.branch_pin
            (Bits.put ~pos:23 ~width:3 pin lor flag ~pos:22 level lor d)
        ])
    | Dbnz { rd; target } ->
      Result.map (displacement target ~width:16 ~target) ~f:(fun d ->
        [ word Opcode.dbnz (Bits.put ~pos:23 ~width:3 rd lor d) ])
    | Wait_cycles_imm { delay } ->
      Ok [ word Opcode.wait_cycles_imm (Bits.put ~pos:0 ~width:16 delay) ]
    | Wait_cycles_reg { rd } ->
      Ok [ word Opcode.wait_cycles_reg (Bits.put ~pos:23 ~width:3 rd) ]
    | Wait_level { pin; level; timeout } ->
      Ok
        [ word
            Opcode.wait_level
            (Bits.put ~pos:23 ~width:3 pin
             lor flag ~pos:22 level
             lor flag ~pos:21 (Option.is_some timeout)
             lor Bits.put ~pos:0 ~width:16 (Option.value timeout ~default:0))
        ]
    | Wait_edge { pin; edge; timeout } ->
      Ok
        [ word
            Opcode.wait_edge
            (Bits.put ~pos:23 ~width:3 pin
             lor Bits.put ~pos:21 ~width:2 (rank Edge.all ~equal:Edge.equal edge)
             lor flag ~pos:20 (Option.is_some timeout)
             lor Bits.put ~pos:0 ~width:16 (Option.value timeout ~default:0))
        ]
    | Start_periodic { period } ->
      Ok [ word Opcode.start_periodic (Bits.put ~pos:0 ~width:16 period) ]
    | Config { field; value } ->
      Ok
        [ word
            Opcode.config
            (Bits.put ~pos:22 ~width:4 (Field.index field)
             lor Bits.put ~pos:0 ~width:16 value)
        ]
    | Fifo_push { fifo; rs; blocking } ->
      Ok
        [ word
            Opcode.fifo_push
            (Bits.put ~pos:25 ~width:1 (rank Fifo_id.all ~equal:Fifo_id.equal fifo)
             lor Bits.put
                   ~pos:24
                   ~width:1
                   (rank Blocking.all ~equal:Blocking.equal blocking)
             lor Bits.put ~pos:21 ~width:3 rs)
        ]
    | Fifo_pop { fifo; rd; blocking } ->
      Ok
        [ word
            Opcode.fifo_pop
            (Bits.put ~pos:25 ~width:1 (rank Fifo_id.all ~equal:Fifo_id.equal fifo)
             lor Bits.put
                   ~pos:24
                   ~width:1
                   (rank Blocking.all ~equal:Blocking.equal blocking)
             lor Bits.put ~pos:21 ~width:3 rd)
        ]
  ;;

  let decode word =
    let opcode = word lsr payload_bits in
    let payload = word land Bits.mask payload_bits in
    let reserved fields =
      let unused = payload land lnot (Bits.used fields) in
      if unused = 0
      then Ok ()
      else Error (Word_error.Reserved_bits_set { opcode; bits = unused })
    in
    let field ~pos ~width = Bits.get payload ~pos ~width in
    let signed ~pos ~width = Bits.signed payload ~pos ~width in
    let enum ~what value =
      Result.of_option value ~error:(Word_error.Field_out_of_range { opcode; what })
    in
    let timeout ~present ~value = if present then Some value else None in
    let result =
      match () with
      | () when opcode = Opcode.halt -> Result.map (reserved []) ~f:(fun () -> Instr.Halt)
      | () when opcode = Opcode.stop_periodic ->
        Result.map (reserved []) ~f:(fun () -> Instr.Stop_periodic)
      | () when opcode = Opcode.issue_transfer ->
        Result.map (reserved []) ~f:(fun () -> Instr.Issue_transfer)
      | () when opcode = Opcode.ldi ->
        Result.map
          (reserved [ 23, 3; 0, 16 ])
          ~f:(fun () ->
            Instr.Ldi { rd = field ~pos:23 ~width:3; value = field ~pos:0 ~width:16 })
      | () when opcode = Opcode.mov ->
        Result.map
          (reserved [ 23, 3; 20, 3 ])
          ~f:(fun () ->
            Instr.Mov { rd = field ~pos:23 ~width:3; rs = field ~pos:20 ~width:3 })
      | () when opcode = Opcode.alu ->
        Result.bind
          (reserved [ 23, 3; 20, 3; 17, 3 ])
          ~f:(fun () ->
            Result.map
              (enum ~what:"alu_op" (Alu_op.of_index (field ~pos:23 ~width:3)))
              ~f:(fun op ->
                Instr.Alu { op; rd = field ~pos:20 ~width:3; rs = field ~pos:17 ~width:3 }))
      | () when opcode = Opcode.alu_imm ->
        Result.bind
          (reserved [ 23, 3; 20, 3; 0, 16 ])
          ~f:(fun () ->
            Result.map
              (enum ~what:"alu_op" (Alu_op.of_index (field ~pos:23 ~width:3)))
              ~f:(fun op ->
                Instr.Alu_imm
                  { op; rd = field ~pos:20 ~width:3; imm = field ~pos:0 ~width:16 }))
      | () when opcode = Opcode.cmp ->
        Result.map
          (reserved [ 23, 3; 20, 3 ])
          ~f:(fun () ->
            Instr.Cmp { ra = field ~pos:23 ~width:3; rb = field ~pos:20 ~width:3 })
      | () when opcode = Opcode.cmp_imm ->
        Result.map
          (reserved [ 23, 3; 0, 16 ])
          ~f:(fun () ->
            Instr.Cmp_imm { ra = field ~pos:23 ~width:3; imm = field ~pos:0 ~width:16 })
      | () when opcode = Opcode.shift ->
        Result.bind
          (reserved [ 25, 1; 22, 3; 18, 4 ])
          ~f:(fun () ->
            let amount = field ~pos:18 ~width:4 in
            if amount = 0
            then Error (Word_error.Field_out_of_range { opcode; what = "amount" })
            else
              Result.map
                (enum ~what:"shift_dir" (Shift_dir.of_index (field ~pos:25 ~width:1)))
                ~f:(fun dir -> Instr.Shift { dir; rd = field ~pos:22 ~width:3; amount }))
      | () when opcode = Opcode.read_pins ->
        Result.map
          (reserved [ 23, 3 ])
          ~f:(fun () -> Instr.Read_pins { rd = field ~pos:23 ~width:3 })
      | () when opcode = Opcode.read_status ->
        Result.map
          (reserved [ 23, 3 ])
          ~f:(fun () -> Instr.Read_status { rd = field ~pos:23 ~width:3 })
      | () when opcode = Opcode.ack_status ->
        Result.map
          (reserved [ 0, 6 ])
          ~f:(fun () -> Instr.Ack_status { mask = field ~pos:0 ~width:6 })
      | () when opcode = Opcode.jump ->
        Result.map
          (reserved [ 0, 26 ])
          ~f:(fun () -> Instr.Jump { target = signed ~pos:0 ~width:26 })
      | () when opcode = Opcode.branch ->
        Result.bind
          (reserved [ 23, 3; 0, 16 ])
          ~f:(fun () ->
            Result.map
              (enum ~what:"cond" (Cond.of_index (field ~pos:23 ~width:3)))
              ~f:(fun cond -> Instr.Branch { cond; target = signed ~pos:0 ~width:16 }))
      | () when opcode = Opcode.branch_pin ->
        Result.map
          (reserved [ 23, 3; 22, 1; 0, 16 ])
          ~f:(fun () ->
            Instr.Branch_pin
              { pin = field ~pos:23 ~width:3
              ; level = field ~pos:22 ~width:1 = 1
              ; target = signed ~pos:0 ~width:16
              })
      | () when opcode = Opcode.dbnz ->
        Result.map
          (reserved [ 23, 3; 0, 16 ])
          ~f:(fun () ->
            Instr.Dbnz { rd = field ~pos:23 ~width:3; target = signed ~pos:0 ~width:16 })
      | () when opcode = Opcode.write_pins_imm ->
        Result.bind
          (reserved [ 25, 1; 17, 8; 9, 8 ])
          ~f:(fun () ->
            Result.map
              (enum ~what:"pin_mode" (Pin_mode.of_index (field ~pos:25 ~width:1)))
              ~f:(fun mode ->
                Instr.Write_pins_imm
                  { mode; mask = field ~pos:17 ~width:8; value = field ~pos:9 ~width:8 }))
      | () when opcode = Opcode.write_pins_reg ->
        Result.bind
          (reserved [ 25, 1; 22, 3; 19, 3 ])
          ~f:(fun () ->
            Result.map
              (enum ~what:"pin_mode" (Pin_mode.of_index (field ~pos:25 ~width:1)))
              ~f:(fun mode ->
                Instr.Write_pins_reg
                  { mode
                  ; mask_reg = field ~pos:22 ~width:3
                  ; value_reg = field ~pos:19 ~width:3
                  }))
      | () when opcode = Opcode.wait_cycles_imm ->
        Result.bind
          (reserved [ 0, 16 ])
          ~f:(fun () ->
            let delay = field ~pos:0 ~width:16 in
            if delay = 0
            then Error (Word_error.Field_out_of_range { opcode; what = "delay" })
            else Ok (Instr.Wait_cycles_imm { delay }))
      | () when opcode = Opcode.wait_cycles_reg ->
        Result.map
          (reserved [ 23, 3 ])
          ~f:(fun () -> Instr.Wait_cycles_reg { rd = field ~pos:23 ~width:3 })
      | () when opcode = Opcode.wait_level ->
        Result.bind
          (reserved [ 23, 3; 22, 1; 21, 1; 0, 16 ])
          ~f:(fun () ->
            let present = field ~pos:21 ~width:1 = 1 in
            let value = field ~pos:0 ~width:16 in
            if Bool.equal present (value = 0)
            then Error (Word_error.Field_out_of_range { opcode; what = "timeout" })
            else
              Ok
                (Instr.Wait_level
                   { pin = field ~pos:23 ~width:3
                   ; level = field ~pos:22 ~width:1 = 1
                   ; timeout = timeout ~present ~value
                   }))
      | () when opcode = Opcode.wait_edge ->
        Result.bind
          (reserved [ 23, 3; 21, 2; 20, 1; 0, 16 ])
          ~f:(fun () ->
            Result.bind
              (enum ~what:"edge" (List.nth Edge.all (field ~pos:21 ~width:2)))
              ~f:(fun edge ->
                let present = field ~pos:20 ~width:1 = 1 in
                let value = field ~pos:0 ~width:16 in
                if Bool.equal present (value = 0)
                then Error (Word_error.Field_out_of_range { opcode; what = "timeout" })
                else
                  Ok
                    (Instr.Wait_edge
                       { pin = field ~pos:23 ~width:3
                       ; edge
                       ; timeout = timeout ~present ~value
                       })))
      | () when opcode = Opcode.start_periodic ->
        Result.bind
          (reserved [ 0, 16 ])
          ~f:(fun () ->
            let period = field ~pos:0 ~width:16 in
            if period = 0
            then Error (Word_error.Field_out_of_range { opcode; what = "period" })
            else Ok (Instr.Start_periodic { period }))
      | () when opcode = Opcode.config ->
        Result.bind
          (reserved [ 22, 4; 0, 16 ])
          ~f:(fun () ->
            Result.map
              (enum ~what:"field" (Field.of_index (field ~pos:22 ~width:4)))
              ~f:(fun descriptor_field ->
                Instr.Config { field = descriptor_field; value = field ~pos:0 ~width:16 }))
      | () when opcode = Opcode.fifo_push || opcode = Opcode.fifo_pop ->
        Result.bind
          (reserved [ 25, 1; 24, 1; 21, 3 ])
          ~f:(fun () ->
            Result.bind
              (enum ~what:"fifo" (List.nth Fifo_id.all (field ~pos:25 ~width:1)))
              ~f:(fun fifo ->
                Result.map
                  (enum ~what:"blocking" (List.nth Blocking.all (field ~pos:24 ~width:1)))
                  ~f:(fun blocking ->
                    let reg = field ~pos:21 ~width:3 in
                    if opcode = Opcode.fifo_push
                    then Instr.Fifo_push { fifo; rs = reg; blocking }
                    else Instr.Fifo_pop { fifo; rd = reg; blocking })))
      | () -> Error (Word_error.Reserved_opcode opcode)
    in
    match result with
    | Ok instr -> Decoded.Complete instr
    | Error reason -> Decoded.Invalid reason
  ;;
end

(* --------------------------------------------------------------------------------------
   Candidates: an instruction width stored in a memory word
   -------------------------------------------------------------------------------------- *)

module Candidate = struct
  (* construction-plan.md section 4: "Instruction width and physical memory-word width are
     separate choices". So a candidate is the pair, and the four below are the ones worth
     measuring: each instruction width in the memory word that matches it, 16-bit
     instructions packed two to a 32-bit word, and 32-bit instructions split across two
     16-bit words. *)
  type t =
    { name : string
    ; instruction_bits : int
    ; memory_bits : int
    }
  [@@deriving sexp, compare, equal]

  let i16_m16 = { name = "i16/m16"; instruction_bits = 16; memory_bits = 16 }
  let i16_m32 = { name = "i16/m32"; instruction_bits = 16; memory_bits = 32 }
  let i32_m32 = { name = "i32/m32"; instruction_bits = 32; memory_bits = 32 }
  let i32_m16 = { name = "i32/m16"; instruction_bits = 32; memory_bits = 16 }
  let all = [ i16_m16; i16_m32; i32_m32; i32_m16 ]
end

module Packing = struct
  (* How instruction slots sit in memory words. Packing moves no bits inside an
     instruction; it decides how many reads of the single port reach one. *)
  type t =
    | One_instruction_per_word
    | (* Two 16-bit instructions in a 32-bit word, earlier instruction in the less
         significant half. *)
      Two_instructions_per_word
    | (* One 32-bit instruction across two 16-bit words, less significant word first. *)
      Two_words_per_instruction
  [@@deriving sexp, compare, equal]
end

let packing (candidate : Candidate.t) =
  match candidate.instruction_bits, candidate.memory_bits with
  | 16, 32 -> Packing.Two_instructions_per_word
  | 32, 16 -> Packing.Two_words_per_instruction
  | _ -> Packing.One_instruction_per_word
;;

let encode (candidate : Candidate.t) instr =
  if candidate.instruction_bits = 16 then Word16.encode instr else Word32.encode instr
;;

let decode (candidate : Candidate.t) word =
  if candidate.instruction_bits = 16 then Word16.decode word else Word32.decode word
;;

(* How many slots an instruction occupies. A displacement of zero fits every displacement
   field, and no other field's width depends on the target, so the size of a flow
   instruction is known before its target is: that is what keeps the assembler a single
   pass rather than a relaxation loop. *)
let slots_of candidate instr =
  match encode candidate (Instr.map_target instr ~f:(fun _ -> 0)) with
  | Ok words -> List.length words
  | Error reason ->
    raise_s
      [%message
        "an instruction with a zero displacement failed to encode" (reason : Invalid.t)]
;;

(* The memory words a slot lives in, least significant first. *)
let addresses candidate ~slot =
  match packing candidate with
  | Packing.One_instruction_per_word -> [ slot ]
  | Two_instructions_per_word -> [ slot / 2 ]
  | Two_words_per_instruction -> [ slot * 2; (slot * 2) + 1 ]
;;

(* Rebuild a slot's instruction word from the memory words [addresses] named. *)
let extract candidate ~slot ~words =
  match packing candidate, words with
  | Packing.One_instruction_per_word, [ word ] -> word
  | Two_instructions_per_word, [ word ] -> Bits.get word ~pos:(16 * (slot % 2)) ~width:16
  | Two_words_per_instruction, [ low; high ] -> low lor (high lsl 16)
  | _ ->
    raise_s
      [%message "wrong number of memory words for a slot" (slot : int) (words : int list)]
;;

module Image = struct
  (* The loaded program as memory words, and as the byte stream a host transport would
     carry. The loader assembles complete memory words before issuing writes
     (construction-plan.md section 4), so the byte order below describes the transport and
     never the core's view. *)
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
      List.init per_word ~f:(fun index -> Bits.get word ~pos:(index * 8) ~width:8))
  ;;
end

(* The odd half-word left by an odd number of 16-bit instructions in a 32-bit memory word.
   It is written, not left unwritten, and it is [Halt]: running into the padding stops the
   core rather than executing whatever the store held. An unwritten word is a different
   thing entirely and faults, which is program_store.ml's rule and P1.1's. *)
let padding_word = 0

let build_image (candidate : Candidate.t) slots =
  let words =
    match packing candidate with
    | Packing.One_instruction_per_word -> slots
    | Two_instructions_per_word ->
      let rec pair = function
        | [] -> []
        | [ low ] -> [ low lor (padding_word lsl 16) ]
        | low :: high :: rest -> (low lor (high lsl 16)) :: pair rest
      in
      pair slots
    | Two_words_per_instruction ->
      List.concat_map slots ~f:(fun word ->
        [ Bits.get word ~pos:0 ~width:16; Bits.get word ~pos:16 ~width:16 ])
  in
  { Image.words = Array.of_list words; word_bits = candidate.memory_bits }
;;

(* --------------------------------------------------------------------------------------
   The assembler
   -------------------------------------------------------------------------------------- *)

module Entry = struct
  (* One assembled instruction. [slot] is its instruction-slot address; [words] are the
     encoded instruction word and its extension word when it has one. *)
  type t =
    { index : int
    ; slot : int
    ; instr : string Instr.t
    ; words : int list
    }
  [@@deriving sexp_of, compare, equal]

  let extension_words t = List.length t.words - 1
end

module Size = struct
  (* What a program costs to store under one candidate. Physical area is deliberately
     absent: P1.4 records sizes and cycles, and P5 supplies mapped area against these
     numbers (phase_plan.md P1.4). *)
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
    { candidate : Candidate.t
    ; name : string
    ; entries : Entry.t list
    ; labels : int String.Map.t
    ; image : Image.t
    ; size : Size.t
    }
  [@@deriving sexp_of]
end

(* The default program store, from construction-plan.md section 4's sweep points. A
   candidate with a 16-bit memory word needs twice as many of them for the same 32-bit
   instructions, which is exactly the storage question P1.4 is asked to record. *)
let default_depth = 256

(* Assemble in one pass over sizes and a second over values:

   1. validate the program, so that no later failure is about something structural;
   2. lay every instruction out at a slot and record where each label landed;
   3. resolve each branch to a displacement from the slot after it, and encode;
   4. pack the slots into memory words and check the image fits the store.

   A displacement that does not fit its field is refused rather than rewritten as a jump
   island: the range of a branch is part of what the two candidates are being compared on,
   so hiding it behind an assembler workaround would hide the measurement. *)
let assemble ?(depth = default_depth) candidate (program : Study_isa.t) =
  let ( >>= ) result f = Result.bind result ~f in
  Study_isa.validate program
  >>= fun () ->
  let _, placed, labels =
    List.fold
      program.items
      ~init:(0, [], String.Map.empty)
      ~f:(fun (slot, placed, labels) item ->
        match (item : Item.t) with
        | Label label -> slot, placed, Map.set labels ~key:label ~data:slot
        | Instr instr -> slot + slots_of candidate instr, (slot, instr) :: placed, labels)
  in
  let placed = List.rev placed in
  List.mapi placed ~f:(fun index (slot, instr) ->
    let resolved =
      Instr.map_target instr ~f:(fun label ->
        (* Relative to the slot after the branch, the usual convention and the one that
           makes a backward branch to the instruction itself [-1] rather than zero. *)
        Map.find_exn labels label - (slot + 1))
    in
    Result.map (encode candidate resolved) ~f:(fun words ->
      { Entry.index; slot; instr; words }))
  |> Result.all
  >>= fun entries ->
  let slots = List.concat_map entries ~f:(fun entry -> entry.words) in
  let image = build_image candidate slots in
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
  else Ok { Assembled.candidate; name = program.name; entries; labels; image; size }
;;
