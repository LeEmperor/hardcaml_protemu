(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "test_encoding.ml" *)
(* P1.4: the two instruction encodings, the four ways of storing them, and what the same
   UART, SPI and I2C work costs under each.

   Every number here is run rather than computed. A program is assembled into real words,
   loaded into a [Program_store] and executed by [Study_core] through the same command
   port the P1.1 tests use, and the SPI and I2C traces are answered by the independent
   peers [Firmware_spi.Peer] and [Firmware_i2c.Peer] that P1.3 already talks to. The
   tables at the end are the ones docs/p1.4-encoding-study.md carries.

   Physical area is absent on purpose: P1.4 records sizes and cycles and P5 measures area
   against them (phase_plan.md).
*)

open! Core
open! Protemu_model

let unwrap = function
  | Ok value -> value
  | Error invalid ->
    raise_s [%message "program did not build" (invalid : Study_isa.Invalid.t)]
;;

let assemble_exn ?depth candidate program =
  match Study_encoding.assemble ?depth candidate (unwrap program) with
  | Ok assembled -> assembled
  | Error invalid -> raise_s [%message "did not assemble" (invalid : Study_isa.Invalid.t)]
;;

let run ?depth ?max_cycles ~candidate board program =
  match Study_core.run ?depth ?max_cycles ~candidate board (unwrap program) with
  | Ok trace -> trace
  | Error invalid -> raise_s [%message "did not assemble" (invalid : Study_isa.Invalid.t)]
;;

let quiet = Firmware.Board.quiet

(* The two peers, with the parameters P1.3 used, so that a disagreement between the phases
   is about the core and not about the device on the other end. *)
let spi_peer () =
  Firmware_spi.Peer.board ~sclk:1 ~miso:2 ~bit_order:Msb_first ~bit_count:8 ~value:0x3c
;;

let i2c_peer () =
  Firmware_i2c.Peer.board ~stretch_cycles:12 ~scl:6 ~sda:7 ~address:0x42 ()
;;

(* The pin waveform as (level, run length) pairs: one pair per group of equal bits. *)
let waveform trace ~pin = Firmware.Trace.runs (Study_core.Trace.wave trace ~pin)

(* The bit period, measured from the waveform rather than predicted.

   Every interior run of a frame is a whole number of bit periods, so the shortest of them
   is one bit. The first run is the released pins before anything is driven, the second is
   the idle level - which lasts as long as whatever setup preceded it - and the last is
   the stop level held until the program halts. None of those three is a bit period, so
   the measurement drops them.

   [uniform] is whether every interior run is an exact multiple of the shortest one. A
   frame whose bit period wanders is not a frame any receiver can read, and one candidate
   here has that problem. *)
let bit_period trace ~pin =
  let driven =
    List.filter_map (waveform trace ~pin) ~f:(fun (level, length) ->
      if Char.equal level 'z' then None else Some length)
  in
  let interior =
    match driven with
    | [] | [ _ ] -> []
    | _ :: rest -> List.drop_last_exn rest
  in
  match List.min_elt interior ~compare:Int.compare with
  | None -> 0, false
  | Some shortest ->
    shortest, List.for_all interior ~f:(fun length -> length % shortest = 0)
;;

(* --------------------------------------------------------------------------------------
   The two encodings
   -------------------------------------------------------------------------------------- *)

(* Every instruction form, at the boundaries where the 16-bit encoding changes its mind
   about an extension word: an immediate one below its inline field's limit and one above
   it, each enumerated field at its ends, and both branch directions. *)
let corpus =
  let open Study_isa.Instr in
  let registers = [ 0; 7 ] in
  List.concat
    [ [ Halt; Stop_periodic; Issue_transfer ]
    ; List.concat_map registers ~f:(fun rd ->
        [ Ldi { rd; value = 0 }
        ; Ldi { rd; value = 127 }
        ; Ldi { rd; value = 128 }
        ; Ldi { rd; value = 65535 }
        ; Mov { rd; rs = 7 - rd }
        ; Cmp { ra = rd; rb = 7 - rd }
        ; Cmp_imm { ra = rd; imm = 127 }
        ; Cmp_imm { ra = rd; imm = 128 }
        ; Read_pins { rd }
        ; Read_status { rd }
        ; Wait_cycles_reg { rd }
        ; Shift { dir = Left; rd; amount = 1 }
        ; Shift { dir = Right; rd; amount = 15 }
        ])
    ; List.concat_map Study_isa.Alu_op.all ~f:(fun op ->
        [ Alu { op; rd = 1; rs = 6 }
        ; Alu_imm { op; rd = 1; imm = 15 }
        ; Alu_imm { op; rd = 1; imm = 16 }
        ])
    ; List.concat_map Study_isa.Cond.all ~f:(fun cond ->
        [ Branch { cond; target = 1 }; Branch { cond; target = -1 } ])
    ; [ Ack_status { mask = 0 }
      ; Ack_status { mask = 63 }
      ; Jump { target = 1023 }
      ; Jump { target = -1024 }
      ; Branch_pin { pin = 0; level = true; target = 63 }
      ; Branch_pin { pin = 7; level = false; target = -64 }
      ; Dbnz { rd = 3; target = -5 }
      ; Write_pins_imm { mode = Push_pull; mask = 255; value = 255 }
      ; Write_pins_imm { mode = Open_drain; mask = 1; value = 0 }
      ; Write_pins_reg { mode = Push_pull; mask_reg = 2; value_reg = 3 }
      ; Write_pins_reg { mode = Open_drain; mask_reg = 7; value_reg = 0 }
      ; Wait_cycles_imm { delay = 1 }
      ; Wait_cycles_imm { delay = 1023 }
      ; Wait_cycles_imm { delay = 1024 }
      ; (* One bit period of 9600 baud at fifty megahertz: the ordinary case that does not
           fit a 16-bit instruction's inline field. *)
        Wait_cycles_imm { delay = 5208 }
      ; Start_periodic { period = 1023 }
      ; Start_periodic { period = 1024 }
      ; Wait_level { pin = 0; level = true; timeout = None }
      ; Wait_level { pin = 7; level = false; timeout = Some 31 }
      ; Wait_level { pin = 3; level = true; timeout = Some 32 }
      ; Fifo_push { fifo = Tx; rs = 4; blocking = Blocking }
      ; Fifo_pop { fifo = Rx; rd = 5; blocking = Nonblocking }
      ]
    ; List.concat_map Kinds.Edge.all ~f:(fun edge ->
        [ Wait_edge { pin = 2; edge; timeout = None }
        ; Wait_edge { pin = 2; edge; timeout = Some 15 }
        ; Wait_edge { pin = 2; edge; timeout = Some 16 }
        ])
    ; List.map Study_isa.Field.all ~f:(fun field -> Config { field; value = 63 })
    ; List.map Study_isa.Field.all ~f:(fun field -> Config { field; value = 64 })
    ]
;;

let%expect_test "every instruction encodes and decodes back to itself" =
  let round_trip candidate =
    let failures =
      List.filter_map corpus ~f:(fun instr ->
        match Study_encoding.encode candidate instr with
        | Error reason -> Some (instr, `Refused reason)
        | Ok words ->
          let extension = List.nth words 1 in
          (match
             Study_encoding.Decoded.instruction
               (Study_encoding.decode candidate (List.hd_exn words))
               ~extension
           with
           | Error reason -> Some (instr, `Undecodable reason)
           | Ok decoded ->
             if Study_isa.Instr.equal Int.equal decoded instr
             then None
             else Some (instr, `Decoded_differently decoded)))
    in
    print_s
      [%message
        ""
          ~candidate:(candidate.Study_encoding.Candidate.name : string)
          ~instructions:(List.length corpus : int)
          ~instruction_words:
            (List.sum (module Int) corpus ~f:(Study_encoding.slots_of candidate) : int)
          ~failures:
            (failures
             : (int Study_isa.Instr.t
               * [ `Refused of Study_isa.Invalid.t
                 | `Undecodable of Study_encoding.Word_error.t
                 | `Decoded_differently of int Study_isa.Instr.t
                 ])
                 list)]
  in
  round_trip Study_encoding.Candidate.i16_m16;
  round_trip Study_encoding.Candidate.i32_m32;
  [%expect
    {|
    ((candidate i16/m16) (instructions 105) (instruction_words 134)
     (failures ()))
    ((candidate i32/m32) (instructions 105) (instruction_words 105)
     (failures ()))
    |}]
;;

(* Which forms the 16-bit encoding cannot hold in one word, and the values that push them
   over. This is the extension-word column of the report, and it is where the 32-bit
   candidate spends its extra sixteen bits to buy nothing back. *)
let%expect_test "what costs a second word at sixteen bits" =
  let two_words =
    List.filter corpus ~f:(fun instr ->
      Study_encoding.slots_of Study_encoding.Candidate.i16_m16 instr = 2)
  in
  print_s [%sexp (two_words : int Study_isa.Instr.t list)];
  print_s
    [%message
      ""
        ~of_the_corpus:(List.length corpus : int)
        ~needing_an_extension:(List.length two_words : int)];
  [%expect
    {|
    ((Ldi (rd 0) (value 128)) (Ldi (rd 0) (value 65535))
     (Cmp_imm (ra 0) (imm 128)) (Ldi (rd 7) (value 128))
     (Ldi (rd 7) (value 65535)) (Cmp_imm (ra 7) (imm 128))
     (Alu_imm (op Add) (rd 1) (imm 16)) (Alu_imm (op Sub) (rd 1) (imm 16))
     (Alu_imm (op And) (rd 1) (imm 16)) (Alu_imm (op Or) (rd 1) (imm 16))
     (Alu_imm (op Xor) (rd 1) (imm 16))
     (Write_pins_imm (mode Push_pull) (mask 255) (value 255))
     (Write_pins_imm (mode Open_drain) (mask 1) (value 0))
     (Wait_cycles_imm (delay 1024)) (Wait_cycles_imm (delay 5208))
     (Start_periodic (period 1024))
     (Wait_level (pin 3) (level true) (timeout (32)))
     (Wait_edge (pin 2) (edge Rising) (timeout (16)))
     (Wait_edge (pin 2) (edge Falling) (timeout (16)))
     (Wait_edge (pin 2) (edge Either) (timeout (16)))
     (Config (field Control) (value 64)) (Config (field Bit_count) (value 64))
     (Config (field Tx_value) (value 64)) (Config (field Output_pin) (value 64))
     (Config (field Input_pin) (value 64)) (Config (field Clock_pin) (value 64))
     (Config (field Initial_delay) (value 64))
     (Config (field Half_period) (value 64)) (Config (field Pacing) (value 64)))
    ((of_the_corpus 105) (needing_an_extension 29))
    |}]
;;

(* One short program in all four candidates, word for word, with the byte stream a host
   would send to load it. Packing and byte order are visible in the same place because
   they are the same question asked of the loader and of the core. *)
let%expect_test "the same program as instruction words, memory words and transport bytes" =
  let program =
    Study_isa.create
      ~name:"three_instructions"
      [ Label "start"
      ; Instr (Ldi { rd = 1; value = 0x1234 })
      ; Instr (Write_pins_imm { mode = Push_pull; mask = 0x0f; value = 0x0a })
      ; Instr (Jump { target = "start" })
      ]
  in
  List.iter Study_encoding.Candidate.all ~f:(fun candidate ->
    let assembled = assemble_exn candidate program in
    print_s
      [%message
        ""
          ~candidate:(candidate.name : string)
          ~packing:(Study_encoding.packing candidate : Study_encoding.Packing.t)
          ~instruction_words:
            (List.concat_map assembled.entries ~f:(fun entry -> entry.words)
             |> List.map ~f:(sprintf "%04x")
             : string list)
          ~memory_words:
            (Array.to_list assembled.image.words |> List.map ~f:(sprintf "%04x")
             : string list)
          ~transport_bytes:
            (Study_encoding.Image.bytes assembled.image |> List.map ~f:(sprintf "%02x")
             : string list)]);
  [%expect
    {|
    ((candidate i16/m16) (packing One_instruction_per_word)
     (instruction_words (0980 1234 783c 000a 5ffb))
     (memory_words (0980 1234 783c 000a 5ffb))
     (transport_bytes (80 09 34 12 3c 78 0a 00 fb 5f)))
    ((candidate i16/m32) (packing Two_instructions_per_word)
     (instruction_words (0980 1234 783c 000a 5ffb))
     (memory_words (12340980 a783c 5ffb))
     (transport_bytes (80 09 34 12 3c 78 0a 00 fb 5f 00 00)))
    ((candidate i32/m32) (packing One_instruction_per_word)
     (instruction_words (4801234 3c1e1400 2ffffffd))
     (memory_words (4801234 3c1e1400 2ffffffd))
     (transport_bytes (34 12 80 04 00 14 1e 3c fd ff ff 2f)))
    ((candidate i32/m16) (packing Two_words_per_instruction)
     (instruction_words (4801234 3c1e1400 2ffffffd))
     (memory_words (1234 0480 1400 3c1e fffd 2fff))
     (transport_bytes (34 12 80 04 00 14 1e 3c fd ff ff 2f)))
    |}]
;;

(* --------------------------------------------------------------------------------------
   Words that are not instructions
   -------------------------------------------------------------------------------------- *)

let%expect_test "a decoder accepts only words that were built as instructions" =
  let show candidate word =
    print_s
      [%message
        ""
          ~word:(sprintf "%x" word : string)
          ~decoded:
            (Study_encoding.Decoded.instruction
               (Study_encoding.decode candidate word)
               ~extension:(Some 0)
             : (int Study_isa.Instr.t, Study_encoding.Word_error.t) Result.t)]
  in
  let i16 = Study_encoding.Candidate.i16_m16 in
  let i32 = Study_encoding.Candidate.i32_m32 in
  (* A reserved opcode: five of the thirty-two 5-bit codes are unused. *)
  show i16 0xf800;
  (* [Halt] with a payload bit set. *)
  show i16 0x0001;
  (* [Alu] naming an operation that does not exist. *)
  show i16 0x1f00;
  (* [Config] naming a descriptor field, and the same instruction naming a field number
     that does not exist. *)
  show i16 (23 lsl 11);
  show i16 ((23 lsl 11) lor (15 lsl 7));
  (* The same two conditions at thirty-two bits. *)
  show i32 (40 lsl 26);
  show i32 0x0000_0001;
  [%expect
    {|
    ((word f800) (decoded (Error (Reserved_opcode 31))))
    ((word 1) (decoded (Error (Reserved_bits_set (opcode 0) (bits 1)))))
    ((word 1f00) (decoded (Error (Field_out_of_range (opcode 3) (what alu_op)))))
    ((word b800) (decoded (Ok (Config (field Control) (value 0)))))
    ((word bf80) (decoded (Error (Field_out_of_range (opcode 23) (what field)))))
    ((word a0000000) (decoded (Error (Reserved_opcode 40))))
    ((word 1) (decoded (Error (Reserved_bits_set (opcode 0) (bits 1)))))
    |}]
;;

(* How much of each word space is an instruction at all. At sixteen bits the question can
   simply be asked of every word; at thirty-two it is sampled, with a fixed seed so the
   number is reproducible. The interesting quantity is the ratio: a corrupted word is
   caught far more often when the format has more room to leave unused. *)
let%expect_test "how many words decode" =
  let decodes candidate word =
    match Study_encoding.decode candidate word with
    | Study_encoding.Decoded.Invalid _ -> false
    | Complete _ | Needs_extension _ -> true
  in
  let i16 = Study_encoding.Candidate.i16_m16 in
  let valid16 = List.count (List.init 65536 ~f:Fn.id) ~f:(fun word -> decodes i16 word) in
  print_s [%message "" ~sixteen_bit_words_that_decode:(valid16 : int) ~of_:(65536 : int)];
  let state = Random.State.make [| 14 |] in
  let samples = 1_000_000 in
  let valid32 =
    List.count (List.init samples ~f:Fn.id) ~f:(fun _ ->
      decodes Study_encoding.Candidate.i32_m32 (Random.State.int state (1 lsl 32)))
  in
  print_s
    [%message "" ~thirty_two_bit_samples_that_decode:(valid32 : int) ~of_:(samples : int)];
  [%expect
    {|
    ((sixteen_bit_words_that_decode 15518) (of_ 65536))
    ((thirty_two_bit_samples_that_decode 17925) (of_ 1000000))
    |}]
;;

(* An extension word is sixteen bits of payload with no tag. Reached in sequence it is the
   value its instruction asked for; reached by a branch it is whatever those bits spell,
   and some of them spell something legal. *)
let%expect_test "an extension word reached as an instruction" =
  let i16 = Study_encoding.Candidate.i16_m16 in
  let show instr =
    let extension =
      match Study_encoding.encode i16 instr with
      | Ok [ _; extension ] -> extension
      | Ok _ | Error _ ->
        raise_s [%message "expected an extension word" (instr : int Study_isa.Instr.t)]
    in
    print_s
      [%message
        ""
          ~instruction:(instr : int Study_isa.Instr.t)
          ~extension_word:(sprintf "%04x" extension : string)
          ~if_branched_to:
            (Study_encoding.Decoded.instruction
               (Study_encoding.decode i16 extension)
               ~extension:(Some 0)
             : (int Study_isa.Instr.t, Study_encoding.Word_error.t) Result.t)]
  in
  show (Ldi { rd = 0; value = 0x2000 });
  show (Ldi { rd = 0; value = 1000 });
  show (Write_pins_imm { mode = Push_pull; mask = 1; value = 0 });
  [%expect
    {|
    ((instruction (Ldi (rd 0) (value 8192))) (extension_word 2000)
     (if_branched_to (Ok (Alu_imm (op Add) (rd 0) (imm 0)))))
    ((instruction (Ldi (rd 0) (value 1000))) (extension_word 03e8)
     (if_branched_to (Error (Reserved_bits_set (opcode 0) (bits 1000)))))
    ((instruction (Write_pins_imm (mode Push_pull) (mask 1) (value 0)))
     (extension_word 0000) (if_branched_to (Ok Halt)))
    |}]
;;

(* Running off the end of a program. The two 16-bit-memory candidates and [i32/m32] reach
   a word the store never had written, which the contract leaves unspecified and P1.1
   forbids accepting as an instruction; the packed candidate reaches the half-word the
   assembler padded with [Halt] instead. *)
let%expect_test "a program with no halt runs into what follows it" =
  List.iter Study_encoding.Candidate.all ~f:(fun candidate ->
    let trace =
      run
        ~candidate
        quiet
        (Study_isa.create
           ~name:"falls_off"
           [ Study_isa.Item.Label "x"; Instr (Ldi { rd = 0; value = 1 }) ])
    in
    print_s
      [%message
        ""
          ~candidate:(candidate.name : string)
          ~outcome:(trace.outcome : Study_core.Outcome.t)]);
  [%expect
    {|
    ((candidate i16/m16) (outcome (Faulted (slot 1) (reason Unspecified))))
    ((candidate i16/m32) (outcome Halted))
    ((candidate i32/m32) (outcome (Faulted (slot 1) (reason Unspecified))))
    ((candidate i32/m16) (outcome (Faulted (slot 1) (reason Unspecified))))
    |}]
;;

(* A branch that cannot reach its target is refused by the assembler rather than rewritten
   into a jump island, because the reach of a branch is one of the things being compared.
   Displacements are in instruction slots and are measured from the slot after the branch. *)
let%expect_test "a branch out of range" =
  let far distance =
    Study_isa.create
      ~name:"far_branch"
      ((Study_isa.Item.Instr (Branch { cond = Zero; target = "far" })
        :: List.init distance ~f:(fun _ -> Study_isa.Item.Instr (Mov { rd = 7; rs = 7 }))
       )
       @ [ Label "far"; Instr Halt ])
  in
  let show candidate distance =
    print_s
      [%message
        ""
          ~candidate:(candidate.Study_encoding.Candidate.name : string)
          ~slots_away:(distance : int)
          ~assembled:
            (Result.map
               (Study_encoding.assemble ~depth:1024 candidate (unwrap (far distance)))
               ~f:(fun assembled -> assembled.size.memory_words)
             : (int, Study_isa.Invalid.t) Result.t)]
  in
  show Study_encoding.Candidate.i16_m16 127;
  show Study_encoding.Candidate.i16_m16 128;
  show Study_encoding.Candidate.i32_m32 128;
  [%expect
    {|
    ((candidate i16/m16) (slots_away 127) (assembled (Ok 129)))
    ((candidate i16/m16) (slots_away 128)
     (assembled
      (Error
       (Displacement_out_of_range (target 128) (displacement 128) (bits 8)))))
    ((candidate i32/m32) (slots_away 128) (assembled (Ok 130)))
    |}]
;;

(* Whether an assembled image fits the store at all. 128 and 256 words are
   construction-plan.md section 4's sweep points. *)
let%expect_test "an image larger than the store is refused" =
  let program =
    Study_examples.i2c_write ~scl:6 ~sda:7 ~delay:3 ~timeout:64 ~address:0x42 ~byte:0xa5
  in
  List.iter [ 128; 256 ] ~f:(fun depth ->
    List.iter Study_encoding.Candidate.all ~f:(fun candidate ->
      print_s
        [%message
          ""
            ~candidate:(candidate.name : string)
            ~depth:(depth : int)
            ~fits:
              (Result.map
                 (Study_encoding.assemble ~depth candidate (unwrap program))
                 ~f:(fun assembled -> assembled.size.memory_words)
               : (int, Study_isa.Invalid.t) Result.t)]));
  [%expect
    {|
    ((candidate i16/m16) (depth 128) (fits (Ok 107)))
    ((candidate i16/m32) (depth 128) (fits (Ok 54)))
    ((candidate i32/m32) (depth 128) (fits (Ok 85)))
    ((candidate i32/m16) (depth 128)
     (fits (Error (Program_too_large (words 170) (depth 128)))))
    ((candidate i16/m16) (depth 256) (fits (Ok 107)))
    ((candidate i16/m32) (depth 256) (fits (Ok 54)))
    ((candidate i32/m32) (depth 256) (fits (Ok 85)))
    ((candidate i32/m16) (depth 256) (fits (Ok 170)))
    |}]
;;

(* --------------------------------------------------------------------------------------
   What one instruction and each branch path cost
   -------------------------------------------------------------------------------------- *)

let cycles ~candidate items =
  let trace = run ~candidate quiet (Study_isa.create ~name:"probe" items) in
  trace.counts.cycles
;;

(* Each probe executes exactly the instructions of its baseline plus the one being
   measured, so the difference is that instruction's cost: its own fetch, its execute
   edge, and any fetch it forced on whatever ran next. A taken branch is charged for
   throwing the buffered memory word away, which is where the two packed candidates differ
   from the two unpacked ones. *)
let%expect_test "the cost of one instruction, and of each branch path" =
  List.iter Study_encoding.Candidate.all ~f:(fun candidate ->
    let halt = [ Study_isa.Item.Instr Study_isa.Instr.Halt ] in
    let baseline = cycles ~candidate halt in
    (* The two decrement-and-branch probes carry a leading no-operation so that the branch
       lands on the same slot parity as the plain branch probes above. Under a packed
       candidate an instruction's cost depends on which half of a memory word it sits in,
       so a probe that did not control for that would be measuring its own layout. *)
    let nop = Study_isa.Item.Instr (Study_isa.Instr.Mov { rd = 7; rs = 7 }) in
    let after_load =
      cycles ~candidate (nop :: Instr (Ldi { rd = 0; value = 2 }) :: halt)
    in
    let cost items = cycles ~candidate items - baseline in
    let cost_after items = cycles ~candidate items - after_load in
    print_s
      [%message
        ""
          ~candidate:(candidate.name : string)
          ~halt_alone:(baseline : int)
          ~one_word_instruction:
            (cost (Study_isa.Item.Instr (Ldi { rd = 0; value = 1 }) :: halt) : int)
          ~instruction_with_extension:
            (cost (Study_isa.Item.Instr (Ldi { rd = 0; value = 1000 }) :: halt) : int)
          ~jump:
            (cost [ Study_isa.Item.Instr (Jump { target = "t" }); Label "t"; Instr Halt ]
             : int)
          ~branch_taken:
            (cost
               [ Study_isa.Item.Instr (Branch { cond = Not_zero; target = "t" })
               ; Instr Halt
               ; Label "t"
               ; Instr Halt
               ]
             : int)
          ~branch_not_taken:
            (cost
               [ Study_isa.Item.Instr (Branch { cond = Zero; target = "t" })
               ; Instr Halt
               ; Label "t"
               ; Instr Halt
               ]
             : int)
          ~dbnz_taken:
            (cost_after
               [ nop
               ; Instr (Ldi { rd = 0; value = 2 })
               ; Instr (Dbnz { rd = 0; target = "t" })
               ; Instr Halt
               ; Label "t"
               ; Instr Halt
               ]
             : int)
          ~dbnz_not_taken:
            (cost_after
               [ nop
               ; Instr (Ldi { rd = 0; value = 1 })
               ; Instr (Dbnz { rd = 0; target = "t" })
               ; Instr Halt
               ; Label "t"
               ; Instr Halt
               ]
             : int)]);
  [%expect
    {|
    ((candidate i16/m16) (halt_alone 2) (one_word_instruction 2)
     (instruction_with_extension 3) (jump 2) (branch_taken 2)
     (branch_not_taken 2) (dbnz_taken 2) (dbnz_not_taken 2))
    ((candidate i16/m32) (halt_alone 2) (one_word_instruction 1)
     (instruction_with_extension 2) (jump 2) (branch_taken 2)
     (branch_not_taken 1) (dbnz_taken 2) (dbnz_not_taken 1))
    ((candidate i32/m32) (halt_alone 2) (one_word_instruction 2)
     (instruction_with_extension 2) (jump 2) (branch_taken 2)
     (branch_not_taken 2) (dbnz_taken 2) (dbnz_not_taken 2))
    ((candidate i32/m16) (halt_alone 3) (one_word_instruction 3)
     (instruction_with_extension 3) (jump 3) (branch_taken 3)
     (branch_not_taken 3) (dbnz_taken 3) (dbnz_not_taken 3))
    |}]
;;

(* --------------------------------------------------------------------------------------
   The examples do the work
   -------------------------------------------------------------------------------------- *)

(* The independent 8N1 receiver P1.3 used: find the start edge, then read each bit at its
   centre. Deliberately not the transmitter's own state, so agreement is evidence. *)
let decode_8n1 wave ~bit_cycles =
  match String.index wave '0' with
  | None -> None
  | Some start ->
    let at index = Char.equal wave.[index] '1' in
    let centre bit = start + (bit * bit_cycles) + (bit_cycles / 2) in
    if centre 9 >= String.length wave || not (at (centre 9))
    then None
    else
      Some
        (List.fold (List.init 8 ~f:Fn.id) ~init:0 ~f:(fun acc i ->
           if at (centre (i + 1)) then acc lor (1 lsl i) else acc))
;;

(* The frame on the wire, under each candidate, with the same program and the same
   countdown. The bit period is not the same, because it is the countdown plus the fetch
   the encoding needs between two pin writes; the packed candidate's period is not even
   uniform, because an odd number of instruction slots per bit puts consecutive bits in
   opposite halves of a memory word. The aligned variant pads each bit to an even number
   of slots and gets its uniformity back for one more word per bit. *)
let%expect_test "the same UART frame, bit-banged three ways" =
  let frame name program =
    List.iter Study_encoding.Candidate.all ~f:(fun candidate ->
      let trace = run ~candidate quiet (program ~delay:3) in
      let wave = Study_core.Trace.wave trace ~pin:0 in
      let period, uniform = bit_period trace ~pin:0 in
      print_s
        [%message
          ""
            ~program:(name : string)
            ~candidate:(candidate.name : string)
            ~runs:(waveform trace ~pin:0 : (char * int) list)
            ~bit_period:(period : int)
            ~uniform:(uniform : bool)
            ~decoded:(decode_8n1 wave ~bit_cycles:period : int option)])
  in
  frame "unrolled" (fun ~delay ->
    Study_examples.uart_tx_unrolled ~pin:0 ~delay ~byte:0xa6 ());
  frame "unrolled, aligned" (fun ~delay ->
    Study_examples.uart_tx_unrolled ~aligned:true ~pin:0 ~delay ~byte:0xa6 ());
  frame "loop" (fun ~delay -> Study_examples.uart_tx_loop ~pin:0 ~delay ~byte:0xa6);
  [%expect
    {|
    ((program unrolled) (candidate i16/m16)
     (runs ((z 2) (1 8) (0 16) (1 16) (0 16) (1 8) (0 8) (1 16))) (bit_period 8)
     (uniform true) (decoded (166)))
    ((program unrolled) (candidate i16/m32)
     (runs ((z 1) (1 7) (0 13) (1 13) (0 13) (1 6) (0 7) (1 13))) (bit_period 6)
     (uniform false) (decoded (38)))
    ((program unrolled) (candidate i32/m32)
     (runs ((z 1) (1 7) (0 14) (1 14) (0 14) (1 7) (0 7) (1 15))) (bit_period 7)
     (uniform true) (decoded (166)))
    ((program unrolled) (candidate i32/m16)
     (runs ((z 2) (1 9) (0 18) (1 18) (0 18) (1 9) (0 9) (1 19))) (bit_period 9)
     (uniform true) (decoded (166)))
    ((program "unrolled, aligned") (candidate i16/m16)
     (runs ((z 2) (1 10) (0 20) (1 20) (0 20) (1 10) (0 10) (1 20)))
     (bit_period 10) (uniform true) (decoded (166)))
    ((program "unrolled, aligned") (candidate i16/m32)
     (runs ((z 1) (1 8) (0 16) (1 16) (0 16) (1 8) (0 8) (1 17))) (bit_period 8)
     (uniform true) (decoded (166)))
    ((program "unrolled, aligned") (candidate i32/m32)
     (runs ((z 1) (1 9) (0 18) (1 18) (0 18) (1 9) (0 9) (1 19))) (bit_period 9)
     (uniform true) (decoded (166)))
    ((program "unrolled, aligned") (candidate i32/m16)
     (runs ((z 2) (1 12) (0 24) (1 24) (0 24) (1 12) (0 12) (1 25)))
     (bit_period 12) (uniform true) (decoded (166)))
    ((program loop) (candidate i16/m16)
     (runs ((z 5) (1 16) (0 30) (1 30) (0 30) (1 15) (0 15) (1 32)))
     (bit_period 15) (uniform true) (decoded (166)))
    ((program loop) (candidate i16/m32)
     (runs ((z 4) (1 12) (0 26) (1 26) (0 26) (1 13) (0 13) (1 28)))
     (bit_period 13) (uniform true) (decoded (166)))
    ((program loop) (candidate i32/m32)
     (runs ((z 5) (1 15) (0 30) (1 30) (0 30) (1 15) (0 15) (1 32)))
     (bit_period 15) (uniform true) (decoded (166)))
    ((program loop) (candidate i32/m16)
     (runs ((z 8) (1 21) (0 42) (1 42) (0 42) (1 21) (0 21) (1 43)))
     (bit_period 21) (uniform true) (decoded (166)))
    |}]
;;

(* The fastest bit period each candidate can bit-bang, which is the same program with the
   shortest countdown an instruction may carry. At a nominal fifty megahertz these are
   megabits per second divided by the period; the clock rate is nominal and no timing
   closure has been run against it. *)
let%expect_test "the shortest bit period each candidate can drive" =
  let shortest name program =
    let periods =
      List.map Study_encoding.Candidate.all ~f:(fun candidate ->
        let trace = run ~candidate quiet (program ~delay:1) in
        let period, uniform = bit_period trace ~pin:0 in
        candidate.Study_encoding.Candidate.name, period, uniform)
    in
    print_s
      [%message
        "" ~program:(name : string) ~cycles_per_bit:(periods : (string * int * bool) list)]
  in
  shortest "unrolled" (fun ~delay ->
    Study_examples.uart_tx_unrolled ~pin:0 ~delay ~byte:0xa6 ());
  shortest "unrolled, aligned" (fun ~delay ->
    Study_examples.uart_tx_unrolled ~aligned:true ~pin:0 ~delay ~byte:0xa6 ());
  shortest "loop" (fun ~delay -> Study_examples.uart_tx_loop ~pin:0 ~delay ~byte:0xa6);
  [%expect
    {|
    ((program unrolled)
     (cycles_per_bit
      ((i16/m16 6 true) (i16/m32 4 false) (i32/m32 5 true) (i32/m16 7 true))))
    ((program "unrolled, aligned")
     (cycles_per_bit
      ((i16/m16 8 true) (i16/m32 6 true) (i32/m32 7 true) (i32/m16 10 true))))
    ((program loop)
     (cycles_per_bit
      ((i16/m16 13 true) (i16/m32 11 true) (i32/m32 13 true) (i32/m16 19 true))))
    |}]
;;

(* The exchange P1.3 could only half finish. Its sample was a trace marker because reading
   a pin into a register needed the register file and input-read instruction P1.4 was to
   choose; here the received word is assembled in a register, and it is the byte the
   independent target sent. *)
let%expect_test "a mode-0 SPI exchange receives the target's byte" =
  List.iter Study_encoding.Candidate.all ~f:(fun candidate ->
    let trace =
      run
        ~candidate
        (spi_peer ())
        (Study_examples.spi_exchange ~cs:3 ~sclk:1 ~mosi:0 ~miso:2 ~delay:3 ~byte:0x5a)
    in
    print_s
      [%message
        ""
          ~candidate:(candidate.name : string)
          ~received:(Study_core.Trace.reg trace ~index:4 : int)
          ~outcome:(trace.outcome : Study_core.Outcome.t)]);
  let trace =
    run
      ~candidate:Study_encoding.Candidate.i16_m16
      (spi_peer ())
      (Study_examples.spi_exchange ~cs:3 ~sclk:1 ~mosi:0 ~miso:2 ~delay:3 ~byte:0x5a)
  in
  print_s
    [%message
      ""
        ~mosi:(waveform trace ~pin:0 : (char * int) list)
        ~sclk:(waveform trace ~pin:1 : (char * int) list)
        ~cs:(waveform trace ~pin:3 : (char * int) list)];
  [%expect
    {|
    ((candidate i16/m16) (received 60) (outcome Halted))
    ((candidate i16/m32) (received 60) (outcome Halted))
    ((candidate i32/m32) (received 60) (outcome Halted))
    ((candidate i32/m16) (received 60) (outcome Halted))
    ((mosi ((z 5) (0 64) (1 36) (0 36) (1 72) (0 36) (1 36) (0 40)))
     (sclk
      ((z 5) (0 37) (1 27) (0 9) (1 27) (0 9) (1 27) (0 9) (1 27) (0 9) (1 27)
       (0 9) (1 27) (0 9) (1 27) (0 9) (1 23) (0 8)))
     (cs ((z 5) (1 9) (0 303) (1 8))))
    |}]
;;

(* START, an addressed write, a payload byte and STOP, against a target that acknowledges
   by address and holds the clock down for twelve cycles after each byte. The bytes the
   target kept are what reached the other end; the acknowledges are samples of the wire,
   and zero is an acknowledge. *)
let%expect_test "an I2C write transaction reaches the target and reads its acknowledges" =
  List.iter Study_encoding.Candidate.all ~f:(fun candidate ->
    let trace =
      run
        ~candidate
        (i2c_peer ())
        (Study_examples.i2c_write
           ~scl:6
           ~sda:7
           ~delay:3
           ~timeout:64
           ~address:0x42
           ~byte:0xa5)
    in
    print_s
      [%message
        ""
          ~candidate:(candidate.name : string)
          ~target_received:(trace.peer.received : int list)
          ~acknowledges:
            ((Study_core.Trace.reg trace ~index:6, Study_core.Trace.reg trace ~index:7)
             : int * int)
          ~outcome:(trace.outcome : Study_core.Outcome.t)]);
  [%expect
    {|
    ((candidate i16/m16) (target_received (132 165)) (acknowledges (0 0))
     (outcome Halted))
    ((candidate i16/m32) (target_received (132 165)) (acknowledges (0 0))
     (outcome Halted))
    ((candidate i32/m32) (target_received (132 165)) (acknowledges (0 0))
     (outcome Halted))
    ((candidate i32/m16) (target_received (132 165)) (acknowledges (0 0))
     (outcome Halted))
    |}]
;;

(* The same frame handed to the engine instead of shifted by the core: nine descriptor
   writes and one issue, which the machine validates and latches. Nothing here drives a
   pin - executing the transfer is P2.5 - so the eighty cycles the engine then occupies
   are P1.3's number and not this program's. *)
let%expect_test "the descriptor program configures and issues a validated transfer" =
  let trace =
    run
      ~candidate:Study_encoding.Candidate.i16_m16
      quiet
      (Study_examples.uart_tx_descriptor ~pin:0 ~half_period:4 ~bytes:[ 0xa6 ])
  in
  print_s
    [%message
      ""
        ~outcome:(trace.outcome : Study_core.Outcome.t)
        ~latched:(trace.final.descriptor : Transfer.t option)];
  (* An unconfigured descriptor is refused rather than half executed: the cleared fields
     leave launch equal to sample, which [Transfer.validate] rejects. *)
  let unconfigured =
    run
      ~candidate:Study_encoding.Candidate.i16_m16
      quiet
      (Study_isa.create
         ~name:"issue_without_configuring"
         [ Study_isa.Item.Instr Issue_transfer; Instr Halt ])
  in
  print_s [%sexp (unconfigured.outcome : Study_core.Outcome.t)];
  [%expect
    {|
    ((outcome Halted)
     (latched
      (((direction Tx_only) (bit_count 10) (bit_order Lsb_first) (tx_value 844)
        (output_pin (0)) (input_pin ()) (clock_pin ()) (idle_output true)
        (idle_clock false) (initial_delay ()) (launch On_falling)
        (sample On_rising) (pacing (Internal (half_period 4)))))))
    (Refused (slot 0) (instr Issue_transfer) (reason (Bit_count_out_of_range 0)))
    |}]
;;

(* --------------------------------------------------------------------------------------
   The recorded comparison
   -------------------------------------------------------------------------------------- *)

(* One row per example per candidate: what it costs to store, and what it costs to run.
   [stall] is the firmware's own countdowns and level waits and is the same under every
   candidate; [fetch] and [execute] are what the encoding costs, and are the columns to
   compare. These are the tables docs/p1.4-encoding-study.md carries. *)
let%expect_test "program sizes and cycle counts" =
  let delay = 3 in
  let examples =
    [ ( "uart tx, unrolled"
      , `Quiet (Study_examples.uart_tx_unrolled ~pin:0 ~delay ~byte:0xa6 ()) )
    ; ( "uart tx, unrolled aligned"
      , `Quiet (Study_examples.uart_tx_unrolled ~aligned:true ~pin:0 ~delay ~byte:0xa6 ())
      )
    ; "uart tx, loop", `Quiet (Study_examples.uart_tx_loop ~pin:0 ~delay ~byte:0xa6)
    ; ( "uart tx, descriptor"
      , `Quiet (Study_examples.uart_tx_descriptor ~pin:0 ~half_period:4 ~bytes:[ 0xa6 ]) )
    ; ( "spi mode 0, eight bits"
      , `Spi (Study_examples.spi_exchange ~cs:3 ~sclk:1 ~mosi:0 ~miso:2 ~delay ~byte:0x5a)
      )
    ; ( "i2c write, address plus one byte"
      , `I2c
          (Study_examples.i2c_write
             ~scl:6
             ~sda:7
             ~delay
             ~timeout:64
             ~address:0x42
             ~byte:0xa5) )
    ]
  in
  List.iter examples ~f:(fun (name, program) ->
    List.iter Study_encoding.Candidate.all ~f:(fun candidate ->
      (* The three peers have three different state types, so each branch reduces its
         trace to the two records the table needs before they meet. *)
      let size, counts =
        match program with
        | `Quiet program ->
          let trace = run ~candidate quiet program in
          trace.size, trace.counts
        | `Spi program ->
          let trace = run ~candidate (spi_peer ()) program in
          trace.size, trace.counts
        | `I2c program ->
          let trace = run ~candidate (i2c_peer ()) program in
          trace.size, trace.counts
      in
      print_s
        [%message
          ""
            ~example:(name : string)
            ~candidate:(candidate.name : string)
            ~instructions:(size.instructions : int)
            ~instruction_words:(size.slots : int)
            ~extension_words:(size.extension_words : int)
            ~memory_words:(size.memory_words : int)
            ~memory_bits:(size.memory_bits : int)
            ~fetch:(counts.fetch_cycles : int)
            ~execute:(counts.execute_cycles : int)
            ~stall:(counts.stall_cycles : int)
            ~cycles:(counts.cycles : int)
            ~extension_fetches:(counts.extension_fetches : int)]));
  [%expect
    {|
    ((example "uart tx, unrolled") (candidate i16/m16) (instructions 23)
     (instruction_words 34) (extension_words 11) (memory_words 34)
     (memory_bits 544) (fetch 34) (execute 23) (stall 33) (cycles 90)
     (extension_fetches 11))
    ((example "uart tx, unrolled") (candidate i16/m32) (instructions 23)
     (instruction_words 34) (extension_words 11) (memory_words 17)
     (memory_bits 544) (fetch 17) (execute 23) (stall 33) (cycles 73)
     (extension_fetches 11))
    ((example "uart tx, unrolled") (candidate i32/m32) (instructions 23)
     (instruction_words 23) (extension_words 0) (memory_words 23)
     (memory_bits 736) (fetch 23) (execute 23) (stall 33) (cycles 79)
     (extension_fetches 0))
    ((example "uart tx, unrolled") (candidate i32/m16) (instructions 23)
     (instruction_words 23) (extension_words 0) (memory_words 46)
     (memory_bits 736) (fetch 46) (execute 23) (stall 33) (cycles 102)
     (extension_fetches 0))
    ((example "uart tx, unrolled aligned") (candidate i16/m16) (instructions 34)
     (instruction_words 45) (extension_words 11) (memory_words 45)
     (memory_bits 720) (fetch 45) (execute 34) (stall 33) (cycles 112)
     (extension_fetches 11))
    ((example "uart tx, unrolled aligned") (candidate i16/m32) (instructions 34)
     (instruction_words 45) (extension_words 11) (memory_words 23)
     (memory_bits 736) (fetch 23) (execute 34) (stall 33) (cycles 90)
     (extension_fetches 11))
    ((example "uart tx, unrolled aligned") (candidate i32/m32) (instructions 34)
     (instruction_words 34) (extension_words 0) (memory_words 34)
     (memory_bits 1088) (fetch 34) (execute 34) (stall 33) (cycles 101)
     (extension_fetches 0))
    ((example "uart tx, unrolled aligned") (candidate i32/m16) (instructions 34)
     (instruction_words 34) (extension_words 0) (memory_words 68)
     (memory_bits 1088) (fetch 68) (execute 34) (stall 33) (cycles 135)
     (extension_fetches 0))
    ((example "uart tx, loop") (candidate i16/m16) (instructions 14)
     (instruction_words 15) (extension_words 1) (memory_words 15)
     (memory_bits 240) (fetch 69) (execute 68) (stall 36) (cycles 173)
     (extension_fetches 1))
    ((example "uart tx, loop") (candidate i16/m32) (instructions 14)
     (instruction_words 15) (extension_words 1) (memory_words 8)
     (memory_bits 256) (fetch 44) (execute 68) (stall 36) (cycles 148)
     (extension_fetches 1))
    ((example "uart tx, loop") (candidate i32/m32) (instructions 14)
     (instruction_words 14) (extension_words 0) (memory_words 14)
     (memory_bits 448) (fetch 68) (execute 68) (stall 36) (cycles 172)
     (extension_fetches 0))
    ((example "uart tx, loop") (candidate i32/m16) (instructions 14)
     (instruction_words 14) (extension_words 0) (memory_words 28)
     (memory_bits 448) (fetch 136) (execute 68) (stall 36) (cycles 240)
     (extension_fetches 0))
    ((example "uart tx, descriptor") (candidate i16/m16) (instructions 11)
     (instruction_words 12) (extension_words 1) (memory_words 12)
     (memory_bits 192) (fetch 12) (execute 11) (stall 0) (cycles 23)
     (extension_fetches 1))
    ((example "uart tx, descriptor") (candidate i16/m32) (instructions 11)
     (instruction_words 12) (extension_words 1) (memory_words 6)
     (memory_bits 192) (fetch 6) (execute 11) (stall 0) (cycles 17)
     (extension_fetches 1))
    ((example "uart tx, descriptor") (candidate i32/m32) (instructions 11)
     (instruction_words 11) (extension_words 0) (memory_words 11)
     (memory_bits 352) (fetch 11) (execute 11) (stall 0) (cycles 22)
     (extension_fetches 0))
    ((example "uart tx, descriptor") (candidate i32/m16) (instructions 11)
     (instruction_words 11) (extension_words 0) (memory_words 22)
     (memory_bits 352) (fetch 22) (execute 11) (stall 0) (cycles 33)
     (extension_fetches 0))
    ((example "spi mode 0, eight bits") (candidate i16/m16) (instructions 29)
     (instruction_words 29) (extension_words 0) (memory_words 29)
     (memory_bits 464) (fetch 134) (execute 134) (stall 57) (cycles 325)
     (extension_fetches 0))
    ((example "spi mode 0, eight bits") (candidate i16/m32) (instructions 29)
     (instruction_words 29) (extension_words 0) (memory_words 15)
     (memory_bits 480) (fetch 71) (execute 134) (stall 57) (cycles 262)
     (extension_fetches 0))
    ((example "spi mode 0, eight bits") (candidate i32/m32) (instructions 29)
     (instruction_words 29) (extension_words 0) (memory_words 29)
     (memory_bits 928) (fetch 134) (execute 134) (stall 57) (cycles 325)
     (extension_fetches 0))
    ((example "spi mode 0, eight bits") (candidate i32/m16) (instructions 29)
     (instruction_words 29) (extension_words 0) (memory_words 58)
     (memory_bits 928) (fetch 268) (execute 134) (stall 57) (cycles 459)
     (extension_fetches 0))
    ((example "i2c write, address plus one byte") (candidate i16/m16)
     (instructions 85) (instruction_words 107) (extension_words 22)
     (memory_words 107) (memory_bits 1712) (fetch 401) (execute 323) (stall 180)
     (cycles 904) (extension_fetches 78))
    ((example "i2c write, address plus one byte") (candidate i16/m32)
     (instructions 85) (instruction_words 107) (extension_words 22)
     (memory_words 54) (memory_bits 1728) (fetch 208) (execute 323) (stall 180)
     (cycles 711) (extension_fetches 78))
    ((example "i2c write, address plus one byte") (candidate i32/m32)
     (instructions 85) (instruction_words 85) (extension_words 0)
     (memory_words 85) (memory_bits 2720) (fetch 323) (execute 323) (stall 180)
     (cycles 826) (extension_fetches 0))
    ((example "i2c write, address plus one byte") (candidate i32/m16)
     (instructions 85) (instruction_words 85) (extension_words 0)
     (memory_words 170) (memory_bits 2720) (fetch 646) (execute 323) (stall 180)
     (cycles 1149) (extension_fetches 0))
    |}]
;;

(* Every edge is one of three kinds and nothing is counted twice. Asserting it here is
   what lets the report add the fetch column to the execute column and call the result the
   encoding's cost. *)
let%expect_test "the cycle accounting closes" =
  let ok =
    List.for_all Study_encoding.Candidate.all ~f:(fun candidate ->
      let trace =
        run
          ~candidate
          (i2c_peer ())
          (Study_examples.i2c_write
             ~scl:6
             ~sda:7
             ~delay:3
             ~timeout:64
             ~address:0x42
             ~byte:0xa5)
      in
      let counts = trace.counts in
      counts.cycles = counts.fetch_cycles + counts.execute_cycles + counts.stall_cycles
      && counts.execute_cycles = counts.instructions
      && counts.memory_reads = counts.fetch_cycles)
  in
  print_s [%message "" ~accounting_closes:(ok : bool)];
  [%expect {| (accounting_closes true) |}]
;;

(* --------------------------------------------------------------------------------------
   Register and flag semantics
   -------------------------------------------------------------------------------------- *)

(* Eight sixteen-bit registers, two-address arithmetic, and three flags. What is worth
   pinning down is which instructions touch the flags: an addition, a subtraction, a
   comparison and a shift do, and moving a value about does not, so a value can be fetched
   between a comparison and the branch that uses it. *)
let%expect_test "what arithmetic leaves in the registers and the flags" =
  let final items =
    let trace =
      run
        ~candidate:Study_encoding.Candidate.i16_m16
        quiet
        (Study_isa.create ~name:"flags" items)
    in
    print_s
      [%message
        ""
          ~registers:(List.take trace.regs 3 : int list)
          ~flags:(trace.flags : Study_core.Flags.t)]
  in
  (* An addition that wraps the sixteen-bit register sets the carry and leaves the
     truncated sum. *)
  final
    [ Study_isa.Item.Instr (Ldi { rd = 0; value = 0xffff })
    ; Instr (Ldi { rd = 1; value = 2 })
    ; Instr (Alu { op = Add; rd = 0; rs = 1 })
    ; Instr Halt
    ];
  (* A subtraction that borrows sets the same bit, and the result is negative because its
     top bit is set. *)
  final
    [ Study_isa.Item.Instr (Ldi { rd = 0; value = 1 })
    ; Instr (Ldi { rd = 1; value = 2 })
    ; Instr (Alu { op = Sub; rd = 0; rs = 1 })
    ; Instr Halt
    ];
  (* A shift carries out the bit that left the register, and a load afterwards leaves that
     flag alone. *)
  final
    [ Study_isa.Item.Instr (Ldi { rd = 0; value = 0x8001 })
    ; Instr (Shift { dir = Left; rd = 0; amount = 1 })
    ; Instr (Ldi { rd = 2; value = 5 })
    ; Instr (Mov { rd = 1; rs = 2 })
    ; Instr Halt
    ];
  (* A comparison sets the flags and writes no register. *)
  final
    [ Study_isa.Item.Instr (Ldi { rd = 0; value = 7 })
    ; Instr (Cmp_imm { ra = 0; imm = 7 })
    ; Instr Halt
    ];
  [%expect
    {|
    ((registers (1 2 0)) (flags ((zero false) (carry true) (negative false))))
    ((registers (65535 2 0)) (flags ((zero false) (carry true) (negative true))))
    ((registers (2 5 5)) (flags ((zero false) (carry true) (negative false))))
    ((registers (7 0 0)) (flags ((zero true) (carry false) (negative false))))
    |}]
;;

(* The data-queue instructions reach the machine's queues, and a nonblocking pop of an
   empty queue is refused rather than stalling - the specified outcome from P1.2, now
   reached through an opcode. *)
let%expect_test "the queue instructions" =
  let trace =
    run
      ~candidate:Study_encoding.Candidate.i16_m16
      quiet
      (Study_isa.create
         ~name:"queues"
         [ Study_isa.Item.Instr (Ldi { rd = 0; value = 0xa5 })
         ; Instr (Fifo_push { fifo = Tx; rs = 0; blocking = Nonblocking })
         ; Instr (Fifo_pop { fifo = Rx; rd = 1; blocking = Nonblocking })
         ; Instr Halt
         ])
  in
  print_s
    [%message
      ""
        ~outcome:(trace.outcome : Study_core.Outcome.t)
        ~tx_queue:(trace.final.tx_fifo.entries : int list)];
  [%expect
    {|
    ((outcome
      (Refused (slot 3)
       (instr (Fifo_pop (fifo Rx) (rd 1) (blocking Nonblocking)))
       (reason (Fifo_empty Rx))))
     (tx_queue (165)))
    |}]
;;

(* What a later frame costs the engine, measured rather than asserted: the same program
   with one byte and with two. Every descriptor field but the transmitted word still
   holds, so the difference is one [Config] and one [Issue_transfer]. *)
let%expect_test "what a second frame costs the engine" =
  List.iter Study_encoding.Candidate.all ~f:(fun candidate ->
    let frames bytes =
      let trace =
        run
          ~candidate
          quiet
          (Study_examples.uart_tx_descriptor ~pin:0 ~half_period:4 ~bytes)
      in
      trace.size, trace.counts.cycles, trace.outcome
    in
    let one_size, one_cycles, outcome = frames [ 0xa6 ] in
    let two_size, two_cycles, _ = frames [ 0xa6; 0x5a ] in
    print_s
      [%message
        ""
          ~candidate:(candidate.name : string)
          ~one_frame:((one_size.memory_bits, one_cycles) : int * int)
          ~two_frames:((two_size.memory_bits, two_cycles) : int * int)
          ~a_later_frame_adds:
            ((two_size.memory_bits - one_size.memory_bits, two_cycles - one_cycles)
             : int * int)
          ~outcome:(outcome : Study_core.Outcome.t)]);
  [%expect
    {|
    ((candidate i16/m16) (one_frame (192 23)) (two_frames (240 28))
     (a_later_frame_adds (48 5)) (outcome Halted))
    ((candidate i16/m32) (one_frame (192 17)) (two_frames (256 21))
     (a_later_frame_adds (64 4)) (outcome Halted))
    ((candidate i32/m32) (one_frame (352 22)) (two_frames (416 26))
     (a_later_frame_adds (64 4)) (outcome Halted))
    ((candidate i32/m16) (one_frame (352 33)) (two_frames (416 39))
     (a_later_frame_adds (64 6)) (outcome Halted))
    |}]
;;
