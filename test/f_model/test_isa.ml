(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "test_isa.ml" *)
(* P1.5: the chosen encoding, the assembler, and the reference execution of labeled
   programs.

   THREE KINDS OF EVIDENCE, which are the three phase_plan.md P1.5 asks for:

   1. EXPECTED BYTES. Programs are assembled into instruction words, memory words and the
      byte stream a host would send, in both memory layouts, and the words are printed.
   2. DECODED MEANINGS. Every instruction form is encoded at the boundaries where its
      inline immediate stops fitting, decoded again, and compared with what went in; words
      that are not instructions are decoded and their refusal named.
   3. MODEL EXECUTION TRACES. The same UART, SPI and I2C transactions P1.3 and P1.4 ran,
      executed out of a [Program_store] by [Control_core] and answered by the same
      independent peers, with their sizes, cycle counts and wire timing.

   The layout table and the numbers the decision document quotes are printed here and
   transcribed there, so docs/p1.5-encoding-decision.md cannot drift from the encoding
   without this file changing first.
*)

open! Core
open! Protemu_f_model

let unwrap = function
  | Ok value -> value
  | Error invalid -> raise_s [%message "program did not build" (invalid : Invalid.t)]
;;

let assemble_exn ?depth ?memory program =
  match Assembler.assemble ?depth ?memory (unwrap program) with
  | Ok assembled -> assembled
  | Error invalid -> raise_s [%message "did not assemble" (invalid : Invalid.t)]
;;

let run ?depth ?max_cycles ?memory ?machine board program =
  match Control_core.run ?depth ?max_cycles ?memory ?machine board (unwrap program) with
  | Ok trace -> trace
  | Error invalid -> raise_s [%message "did not assemble" (invalid : Invalid.t)]
;;

let quiet = Firmware.Board.quiet

(* The two peers, with the parameters P1.3 and P1.4 used, so that a disagreement between
   the phases is about the core and not about the device on the other end. *)
let spi_peer () =
  Firmware_spi.Peer.board ~sclk:1 ~miso:2 ~bit_order:Msb_first ~bit_count:8 ~value:0x3c
;;

let i2c_peer () =
  Firmware_i2c.Peer.board ~stretch_cycles:12 ~scl:6 ~sda:7 ~address:0x42 ()
;;

(* The pin waveform as (level, run length) pairs: one pair per group of equal bits. *)
let waveform trace ~pin = Firmware.Trace.runs (Control_core.Trace.wave trace ~pin)

(* The bit period, measured from the waveform rather than predicted. The first run is the
   released pins before anything is driven, the second is the idle level, and the last is
   the stop level held until the program halts; none of those three is a bit period, so
   the measurement drops them. [uniform] is whether every interior run is an exact
   multiple of the shortest, which is what a receiver depends on. *)
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

(* The independent 8N1 receiver P1.3 and P1.4 used: find the start edge, then read each
   bit at its centre. Deliberately not the transmitter's own state, so agreement is
   evidence. *)
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

(* --------------------------------------------------------------------------------------
   The specification itself
   -------------------------------------------------------------------------------------- *)

(* The layout table, printed from [Encoding.forms] - the same values [Encoding.encode]
   writes with and an RTL decoder will read. This is the table
   docs/p1.5-encoding-decision.md carries; it is generated rather than written so that the
   document and the encoder cannot disagree. *)
let%expect_test "the published instruction layout" =
  printf "opcode mnemonic        payload (bits 10..0)\n";
  List.iter Encoding.forms ~f:(fun (form : Encoding.Form.t) ->
    printf
      "%6d %-15s %s\n"
      form.opcode
      form.mnemonic
      (let layout = Encoding.Form.to_string form in
       if String.is_empty layout then "-" else layout));
  printf
    "\n%d of %d opcodes defined; reserved: %s\n"
    Encoding.defined_opcodes
    Encoding.opcode_count
    (String.concat ~sep:" " (List.map Encoding.reserved_opcodes ~f:Int.to_string));
  [%expect
    {|
    opcode mnemonic        payload (bits 10..0)
         0 halt            -
         1 ldi             rd:10..8 x:7 imm:6..0
         2 mov             rd:10..8 rs:7..5
         3 alu             op:10..8 rd:7..5 rs:4..2
         4 alu_imm         op:10..8 rd:7..5 x:4 imm:3..0
         5 cmp             ra:10..8 rb:7..5
         6 cmp_imm         ra:10..8 x:7 imm:6..0
         7 shift           dir:10 rd:9..7 amount:6..3
         8 read_pins       rd:10..8
         9 read_status     rd:10..8
        10 ack_status      mask:5..0
        11 jump            disp:10..0
        12 branch          cond:10..8 disp:7..0
        13 branch_pin      pin:10..8 level:7 disp:6..0
        14 dbnz            rd:10..8 disp:7..0
        15 write_pins_imm  mode:10 mask:9..2 value:extension word
        16 write_pins_reg  mode:10 mask_reg:9..7 value_reg:6..4
        17 wait_cycles_imm x:10 imm:9..0
        18 wait_cycles_reg rd:10..8
        19 wait_level      pin:10..8 level:7 t:6 x:5 imm:4..0
        20 wait_edge       pin:10..8 edge:7..6 t:5 x:4 imm:3..0
        21 start_periodic  x:10 imm:9..0
        22 stop_periodic   -
        23 config          field:10..7 x:6 imm:5..0
        24 issue_transfer  -
        25 fifo_push       fifo:10 blocking:9 rs:8..6
        26 fifo_pop        fifo:10 blocking:9 rd:8..6
        27 call            link:10..8 disp:7..0
        28 jump_reg        rs:10..8

    29 of 32 opcodes defined; reserved: 29 30 31
    |}]
;;

(* The specification has to be self-consistent before anything built from it means
   anything: one form per opcode, and no two fields of a form claiming the same bit. *)
let%expect_test "the layout is consistent" =
  let duplicate_opcodes =
    List.map Encoding.forms ~f:(fun form -> form.opcode)
    |> List.find_all_dups ~compare:Int.compare
  in
  let overlapping =
    List.filter_map Encoding.forms ~f:(fun (form : Encoding.Form.t) ->
      let fields =
        match form.immediate with
        | None | Some (Extension_word _) -> form.fields
        | Some (Inline_or_extended { flag; inline }) -> flag :: inline :: form.fields
      in
      let total =
        List.sum (module Int) fields ~f:(fun field -> field.Encoding.Bit_field.width)
      in
      let used = Encoding.Form.used_bits form in
      if total = Int.popcount used then None else Some form.mnemonic)
  in
  print_s
    [%message
      ""
        ~duplicate_opcodes:(duplicate_opcodes : int list)
        ~forms_with_overlapping_fields:(overlapping : string list)
        ~spare_payload_bits:
          (List.map Encoding.forms ~f:(fun form ->
             form.mnemonic, Int.popcount (Encoding.Form.spare_bits form))
           : (string * int) list)];
  [%expect
    {|
    ((duplicate_opcodes ()) (forms_with_overlapping_fields ())
     (spare_payload_bits
      ((halt 11) (ldi 0) (mov 5) (alu 2) (alu_imm 0) (cmp 5) (cmp_imm 0)
       (shift 3) (read_pins 8) (read_status 8) (ack_status 5) (jump 0) (branch 0)
       (branch_pin 0) (dbnz 0) (write_pins_imm 2) (write_pins_reg 4)
       (wait_cycles_imm 0) (wait_cycles_reg 8) (wait_level 0) (wait_edge 0)
       (start_periodic 0) (stop_periodic 11) (config 0) (issue_transfer 11)
       (fifo_push 6) (fifo_pop 6) (call 0) (jump_reg 8))))
    |}]
;;

(* Every instruction form, at the boundaries where the encoding changes its mind about an
   extension word: an immediate one below its inline field's limit and one above it, each
   enumerated field at its ends, and both branch directions. *)
let corpus =
  let open Instruction in
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
        ; Jump_reg { rs = rd }
        ; Shift { dir = Left; rd; amount = 1 }
        ; Shift { dir = Right; rd; amount = 15 }
        ; Call { link = rd; target = 127 }
        ; Call { link = rd; target = -128 }
        ])
    ; List.concat_map Instruction.Alu_op.all ~f:(fun op ->
        [ Alu { op; rd = 1; rs = 6 }
        ; Alu_imm { op; rd = 1; imm = 15 }
        ; Alu_imm { op; rd = 1; imm = 16 }
        ])
    ; List.concat_map Instruction.Cond.all ~f:(fun cond ->
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
           fit an inline field. *)
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
    ; List.map Descriptor.Field.all ~f:(fun field -> Config { field; value = 63 })
    ; List.map Descriptor.Field.all ~f:(fun field -> Config { field; value = 64 })
    ]
;;

let%expect_test "every instruction encodes and decodes back to itself" =
  let failures =
    List.filter_map corpus ~f:(fun instr ->
      match Encoding.encode instr with
      | Error reason -> Some (instr, `Refused reason)
      | Ok words ->
        let extension = List.nth words 1 in
        (match
           Encoding.Decoded.instruction (Encoding.decode (List.hd_exn words)) ~extension
         with
         | Error reason -> Some (instr, `Undecodable reason)
         | Ok decoded ->
           if Instruction.equal Int.equal decoded instr
           then None
           else Some (instr, `Decoded_differently decoded)))
  in
  print_s
    [%message
      ""
        ~instructions:(List.length corpus : int)
        ~instruction_words:(List.sum (module Int) corpus ~f:Encoding.words_of : int)
        ~failures:
          (failures
           : (int Instruction.t
             * [ `Refused of Invalid.t
               | `Undecodable of Encoding.Word_error.t
               | `Decoded_differently of int Instruction.t
               ])
               list)];
  [%expect {| ((instructions 111) (instruction_words 140) (failures ())) |}]
;;

(* Which forms need a second word, and the values that push them over. The extension rule
   is what the sixteen-bit format pays for its size, so the list of what triggers it is
   part of the decision's evidence rather than a detail. *)
let%expect_test "what costs a second word" =
  let two_words = List.filter corpus ~f:(fun instr -> Encoding.words_of instr = 2) in
  print_s [%sexp (two_words : int Instruction.t list)];
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
    ((of_the_corpus 111) (needing_an_extension 29))
    |}]
;;

(* --------------------------------------------------------------------------------------
   Expected bytes
   -------------------------------------------------------------------------------------- *)

(* One short labeled program, word for word, in both memory layouts, with the byte stream
   a host would send to load it. Packing and byte order are visible in the same place
   because they are the same question asked of the loader and of the core. *)
let%expect_test "a labeled program as instruction words, memory words and transport bytes"
  =
  let program =
    Program.create
      ~name:"three_instructions"
      [ Label "start"
      ; Instr (Ldi { rd = 1; value = 0x1234 })
      ; Instr (Write_pins_imm { mode = Push_pull; mask = 0x0f; value = 0x0a })
      ; Instr (Jump { target = "start" })
      ]
  in
  List.iter Assembler.Memory.all ~f:(fun memory ->
    let assembled = assemble_exn ~memory program in
    print_s
      [%message
        ""
          ~memory:(memory.name : string)
          ~instructions_per_word:(memory.instructions_per_word : int)
          ~labels:(Map.to_alist assembled.labels : (string * int) list)
          ~instruction_words:
            (List.concat_map assembled.entries ~f:(fun entry -> entry.words)
             |> List.map ~f:(sprintf "%04x")
             : string list)
          ~memory_words:
            (Array.to_list assembled.image.words |> List.map ~f:(sprintf "%04x")
             : string list)
          ~transport_bytes:
            (Assembler.Image.bytes assembled.image |> List.map ~f:(sprintf "%02x")
             : string list)
          ~size:(assembled.size : Assembler.Size.t)]);
  [%expect
    {|
    ((memory m16) (instructions_per_word 1) (labels ((start 0)))
     (instruction_words (0980 1234 783c 000a 5ffb))
     (memory_words (0980 1234 783c 000a 5ffb))
     (transport_bytes (80 09 34 12 3c 78 0a 00 fb 5f))
     (size
      ((instructions 3) (slots 5) (extension_words 2) (memory_words 5)
       (memory_bits 80))))
    ((memory m32) (instructions_per_word 2) (labels ((start 0)))
     (instruction_words (0980 1234 783c 000a 5ffb))
     (memory_words (12340980 a783c 5ffb))
     (transport_bytes (80 09 34 12 3c 78 0a 00 fb 5f 00 00))
     (size
      ((instructions 3) (slots 5) (extension_words 2) (memory_words 3)
       (memory_bits 96))))
    |}]
;;

(* The slot each instruction landed in, and the bits it became, for a program with a
   backward branch, a forward call and an extension word in it. A displacement is counted
   from the slot after the instruction, which is what makes the branch to "loop" below -3
   and not -2. *)
let%expect_test "slots, displacements and encoded words" =
  let program =
    Program.create
      ~name:"call_and_loop"
      [ Instr (Ldi { rd = 0; value = 300 })
      ; Label "loop"
      ; Instr (Call { link = 7; target = "double" })
      ; Instr (Dbnz { rd = 0; target = "loop" })
      ; Instr Halt
      ; Label "double"
      ; Instr (Alu { op = Add; rd = 1; rs = 1 })
      ; Instr (Jump_reg { rs = 7 })
      ]
  in
  let assembled = assemble_exn program in
  List.iter assembled.entries ~f:(fun (entry : Assembler.Entry.t) ->
    printf
      "%3d  %-46s %s\n"
      entry.slot
      (Sexp.to_string [%sexp (entry.instr : string Instruction.t)])
      (String.concat ~sep:" " (List.map entry.words ~f:(sprintf "%04x"))));
  print_s [%sexp (Map.to_alist assembled.labels : (string * int) list)];
  [%expect
    {|
      0  (Ldi(rd 0)(value 300))                         0880 012c
      2  (Call(link 7)(target double))                  df02
      3  (Dbnz(rd 0)(target loop))                      70fe
      4  Halt                                           0000
      5  (Alu(op Add)(rd 1)(rs 1))                      1824
      6  (Jump_reg(rs 7))                               e700
    ((double 5) (loop 2))
    |}]
;;

(* --------------------------------------------------------------------------------------
   Decoded meanings
   -------------------------------------------------------------------------------------- *)

let%expect_test "a decoder accepts only words that were built as instructions" =
  let show word =
    print_s
      [%message
        ""
          ~word:(sprintf "%04x" word : string)
          ~decoded:
            (Encoding.Decoded.instruction (Encoding.decode word) ~extension:(Some 0)
             : (int Instruction.t, Encoding.Word_error.t) Result.t)]
  in
  (* A reserved opcode: three of the thirty-two codes are unused. *)
  show 0xf800;
  (* [Halt] with a payload bit set. *)
  show 0x0001;
  (* [Alu] naming an operation that does not exist. *)
  show 0x1f00;
  (* [Config] naming a descriptor field, and the same instruction naming a field number
     that does not exist. *)
  show (23 lsl 11);
  show ((23 lsl 11) lor (15 lsl 7));
  (* A shift of zero, and a countdown of zero: fields whose every other value is legal. *)
  show (7 lsl 11);
  show (17 lsl 11);
  (* A wait with no timeout, and the same word with the extension flag set anyway, which
     no encoder produces and which therefore is not an instruction. *)
  show (19 lsl 11);
  show ((19 lsl 11) lor (1 lsl 5));
  (* The call pair. *)
  show ((27 lsl 11) lor (7 lsl 8) lor 0xfc);
  show ((28 lsl 11) lor (3 lsl 8));
  [%expect
    {|
    ((word f800) (decoded (Error (Reserved_opcode 31))))
    ((word 0001) (decoded (Error (Reserved_bits_set (opcode 0) (bits 1)))))
    ((word 1f00) (decoded (Error (Field_out_of_range (opcode 3) (what op)))))
    ((word b800) (decoded (Ok (Config (field Control) (value 0)))))
    ((word bf80) (decoded (Error (Field_out_of_range (opcode 23) (what field)))))
    ((word 3800) (decoded (Error (Field_out_of_range (opcode 7) (what amount)))))
    ((word 8800) (decoded (Error (Field_out_of_range (opcode 17) (what delay)))))
    ((word 9800) (decoded (Ok (Wait_level (pin 0) (level false) (timeout ())))))
    ((word 9820) (decoded (Error (Reserved_bits_set (opcode 19) (bits 32)))))
    ((word dffc) (decoded (Ok (Call (link 7) (target -4)))))
    ((word e300) (decoded (Ok (Jump_reg (rs 3)))))
    |}]
;;

(* An extension word is sixteen bits of payload with no tag, so a word that is an
   extension when reached in sequence is an ordinary instruction when reached by a branch.
   The assembler places labels only on instructions, so a correct program cannot do it; a
   corrupted program counter can, and some extension words spell something legal. This is
   the hazard section 5 of the decision keeps rather than spends a bit to remove. *)
let%expect_test "what an extension word decodes to on its own" =
  let show instr =
    match Encoding.encode instr with
    | Ok [ _; extension ] ->
      print_s
        [%message
          ""
            ~instruction:(instr : int Instruction.t)
            ~extension_word:(sprintf "%04x" extension : string)
            ~decoded_as_an_instruction:
              (Encoding.Decoded.instruction
                 (Encoding.decode extension)
                 ~extension:(Some 0)
               : (int Instruction.t, Encoding.Word_error.t) Result.t)]
    | _ -> raise_s [%message "expected an instruction with an extension word"]
  in
  show (Ldi { rd = 0; value = 0x2000 });
  show (Ldi { rd = 0; value = 1000 });
  show (Write_pins_imm { mode = Push_pull; mask = 1; value = 0 });
  [%expect
    {|
    ((instruction (Ldi (rd 0) (value 8192))) (extension_word 2000)
     (decoded_as_an_instruction (Ok (Alu_imm (op Add) (rd 0) (imm 0)))))
    ((instruction (Ldi (rd 0) (value 1000))) (extension_word 03e8)
     (decoded_as_an_instruction
      (Error (Reserved_bits_set (opcode 0) (bits 1000)))))
    ((instruction (Write_pins_imm (mode Push_pull) (mask 1) (value 0)))
     (extension_word 0000) (decoded_as_an_instruction (Ok Halt)))
    |}]
;;

(* How much of the word space is an instruction at all. Exhaustive, because sixteen bits
   can simply be asked. A randomly corrupted or misaddressed word executing as though it
   were an instruction is the error-detection cost of the format, and P1.4 measured the
   fixed thirty-two-bit format as thirteen times better at it. *)
let%expect_test "how much of the word space decodes" =
  let decodes word =
    match Encoding.decode word with
    | Encoding.Decoded.Invalid _ -> false
    | Complete _ -> true
    | Needs_extension _ -> true
  in
  let count = List.count (List.init 65536 ~f:Fn.id) ~f:decodes in
  print_s
    [%message
      ""
        ~words_that_decode:(count : int)
        ~of_:(65536 : int)
        ~percent:
          (Float.round_significant
             ~significant_digits:3
             (100.0 *. Float.of_int count /. 65536.0)
           : float)];
  [%expect {| ((words_that_decode 17532) (of_ 65536) (percent 26.8)) |}]
;;

(* The committed encoding against the candidate that was measured. P1.4's [Study_encoding]
   is frozen evidence: it is what the sizes and cycle counts in
   docs/p1.4-encoding-study.md were produced by. A decision that claims to adopt the
   sixteen-bit candidate has to encode what that candidate encoded, so every shared opcode
   is compared word for word across the whole sixteen-bit space.

   The differences are deliberate and are listed rather than tolerated: this decoder
   refuses a zero delay, a zero period and a zero timeout, which the measured decoder
   accepted although its own encoder could never produce one and [Instruction.validate]
   refuses them. Nothing else about a shared opcode changed, so P1.4's measurements apply
   to the encoding this document chose. *)
let%expect_test "the committed encoding is the candidate P1.4 measured" =
  let decodes word =
    match Encoding.decode word with
    | Encoding.Decoded.Invalid _ -> false
    | Complete _ | Needs_extension _ -> true
  in
  let measured word =
    match Study_encoding.decode Study_encoding.Candidate.i16_m16 word with
    | Study_encoding.Decoded.Invalid _ -> false
    | Complete _ | Needs_extension _ -> true
  in
  (* Opcodes 0 to 26 are the ones both encodings define; 27 and 28 are P1.5's call pair. *)
  let shared =
    List.init 65536 ~f:Fn.id |> List.filter ~f:(fun word -> word lsr 11 < 27)
  in
  let differ =
    List.filter shared ~f:(fun word -> Bool.( <> ) (decodes word) (measured word))
  in
  let instructions_differ =
    List.filter shared ~f:(fun word ->
      match
        ( Encoding.Decoded.instruction (Encoding.decode word) ~extension:(Some 0x1234)
        , Study_encoding.Decoded.instruction
            (Study_encoding.decode Study_encoding.Candidate.i16_m16 word)
            ~extension:(Some 0x1234) )
      with
      | Ok mine, Ok theirs ->
        not
          (String.equal
             (Sexp.to_string [%sexp (mine : int Instruction.t)])
             (Sexp.to_string [%sexp (theirs : int Study_isa.Instr.t)]))
      | _ -> false)
  in
  print_s
    [%message
      ""
        ~shared_opcodes:(27 : int)
        ~words_compared:(List.length shared : int)
        ~words_one_accepts_and_the_other_does_not:(List.length differ : int)
        ~which:
          (List.map differ ~f:(fun word ->
             ( sprintf "%04x" word
             , Sexp.to_string
                 [%sexp
                   (Encoding.decode word
                    |> fun d -> Encoding.Decoded.instruction d ~extension:(Some 0)
                    : (int Instruction.t, Encoding.Word_error.t) Result.t)] ))
           |> List.dedup_and_sort ~compare:(fun (_, a) (_, b) -> String.compare a b)
           |> List.map ~f:snd
           : string list)
        ~words_decoded_to_different_instructions:(List.length instructions_differ : int)];
  [%expect
    {|
    ((shared_opcodes 27) (words_compared 55296)
     (words_one_accepts_and_the_other_does_not 42)
     (which
      ("(Error(Field_out_of_range(opcode 17)(what delay)))"
       "(Error(Field_out_of_range(opcode 19)(what timeout)))"
       "(Error(Field_out_of_range(opcode 20)(what timeout)))"
       "(Error(Field_out_of_range(opcode 21)(what period)))"))
     (words_decoded_to_different_instructions 0))
    |}]
;;

(* --------------------------------------------------------------------------------------
   Assembler validation
   -------------------------------------------------------------------------------------- *)

(* Everything the assembler refuses, and the reason it gives. Each case changes exactly
   one thing about a program that would otherwise assemble. *)
let%expect_test "what the assembler refuses" =
  let show name (items : Program.Item.t list) =
    let result =
      Result.bind (Program.create ~name items) ~f:(fun program ->
        Result.map (Assembler.assemble program) ~f:(fun assembled ->
          assembled.size.memory_words))
    in
    print_s [%message name ~_:(result : (int, Invalid.t) Result.t)]
  in
  show "legal" [ Instr (Ldi { rd = 0; value = 1 }); Instr Halt ];
  show "empty" [ Label "only_a_label" ];
  show "duplicate label" [ Label "x"; Instr Halt; Label "x"; Instr Halt ];
  show "undefined label" [ Instr (Jump { target = "nowhere" }) ];
  show "register out of range" [ Instr (Ldi { rd = 8; value = 0 }); Instr Halt ];
  show
    "pin out of range"
    [ Instr (Wait_level { pin = 8; level = true; timeout = None }); Instr Halt ];
  show "immediate out of range" [ Instr (Ldi { rd = 0; value = 65536 }); Instr Halt ];
  show "zero delay" [ Instr (Wait_cycles_imm { delay = 0 }); Instr Halt ];
  show "runs off the end" [ Instr (Branch { cond = Zero; target = "top" }); Label "top" ];
  (* A conditional branch reaches 128 slots forward; this one is asked for 129. *)
  show
    "displacement out of range"
    ((Program.Item.Instr (Branch { cond = Zero; target = "far" })
      :: List.init 129 ~f:(fun _ -> Program.Item.Instr (Mov { rd = 0; rs = 0 })))
     @ [ Label "far"; Instr Halt ]);
  [%expect
    {|
    (legal (Ok 2))
    (empty (Error Empty))
    ("duplicate label" (Error (Duplicate_label x)))
    ("undefined label" (Error (Undefined_label nowhere)))
    ("register out of range" (Error (Register_out_of_range 8)))
    ("pin out of range" (Error (Pin_out_of_range 8)))
    ("immediate out of range"
     (Error (Immediate_out_of_range (what value) (value 65536))))
    ("zero delay" (Error (Immediate_out_of_range (what delay) (value 0))))
    ("runs off the end"
     (Error (Runs_off_the_end (last "(Branch (cond Zero) (target top))"))))
    ("displacement out of range"
     (Error (Displacement_out_of_range (target far) (displacement 129) (bits 8))))
    |}]
;;

let%expect_test "a program larger than the store" =
  let big =
    Program.create
      ~name:"too_big"
      (List.init 300 ~f:(fun _ -> Program.Item.Instr (Mov { rd = 0; rs = 0 }))
       @ [ Instr Halt ])
  in
  let show ?memory ~depth () =
    print_s
      [%message
        ""
          ~memory:((Option.value memory ~default:Assembler.Memory.default).name : string)
          ~depth:(depth : int)
          ~_:
            (Result.map
               (Assembler.assemble ~depth ?memory (unwrap big))
               ~f:(fun a -> a.size.memory_words)
             : (int, Invalid.t) Result.t)]
  in
  show ~depth:256 ();
  show ~depth:256 ~memory:Assembler.Memory.word32_packed ();
  [%expect
    {|
    ((memory m16) (depth 256)
     (Error (Program_too_large (words 301) (depth 256))))
    ((memory m32) (depth 256) (Ok 151))
    |}]
;;

(* --------------------------------------------------------------------------------------
   Model execution traces
   -------------------------------------------------------------------------------------- *)

let show_run ?(pin = 0) ?(show_wire = true) trace =
  let counts = trace.Control_core.Trace.counts in
  print_s
    [%message
      ""
        ~name:(trace.name : string)
        ~memory:(trace.memory.name : string)
        ~outcome:(trace.outcome : Control_core.Outcome.t)
        ~size:(trace.size : Assembler.Size.t)
        ~counts:(counts : Control_core.Counts.t)];
  if show_wire
  then (
    let period, uniform = bit_period trace ~pin in
    print_s [%message "" ~bit_period:(period : int) ~uniform:(uniform : bool)])
;;

let%expect_test "loaded event decision commits a pin in the reference core" =
  let program =
    Program.create
      ~name:"wait_start_then_drive"
      [ Instr (Write_pins_imm { mode = Push_pull; mask = 1; value = 0 })
      ; Instr (Wait_edge { pin = 3; edge = Rising; timeout = None })
      ; Instr (Write_pins_imm { mode = Push_pull; mask = 1; value = 1 })
      ; Instr Halt
      ]
  in
  let assembled = assemble_exn program in
  let board =
    { Firmware.Board.initial = 0
    ; next =
        (fun edge _machine ->
          let edge = edge + 1 in
          edge, if edge >= 7 then 1 lsl 3 else 0)
    }
  in
  print_s
    [%message
      ""
        ~words:(Array.to_list assembled.image.words : int list)
        ~bytes:(Assembler.Image.bytes assembled.image : int list)];
  let machine = Machine.create () in
  let pins =
    match Pin_bank.claim machine.pins ~owner:Kinds.Owner.Software ~mask:1 with
    | Ok pins -> pins
    | Error reason ->
      raise_s [%message "initial pin claim failed" (reason : Fault.Reject.t)]
  in
  let trace = run ~machine:{ machine with pins } board program in
  show_run ~show_wire:false trace;
  print_s [%message "" ~pin0:(Control_core.Trace.wave trace ~pin:0 : string)];
  [%expect
    {|
    ((words (30724 0 41728 30724 1 0)) (bytes (4 120 0 0 0 163 4 120 1 0 0 0)))
    ((name wait_start_then_drive) (memory m16) (outcome Halted)
     (size
      ((instructions 4) (slots 6) (extension_words 2) (memory_words 6)
       (memory_bits 96)))
     (counts
      ((cycles 13) (fetch_cycles 6) (execute_cycles 4) (stall_cycles 3)
       (instructions 4) (extension_fetches 2) (memory_reads 6) (buffer_hits 0))))
    (pin0 zz00000000111)
    |}]
;;

let%expect_test "UART 8N1 transmit, three ways" =
  let byte = 0xa6 in
  List.iter
    [ "unrolled", Example_programs.uart_tx_unrolled ~pin:0 ~delay:3 ~byte ()
    ; ( "unrolled, slot-aligned"
      , Example_programs.uart_tx_unrolled ~aligned:true ~pin:0 ~delay:3 ~byte () )
    ; "bit loop", Example_programs.uart_tx_loop ~pin:0 ~delay:3 ~byte
    ]
    ~f:(fun (what, program) ->
      List.iter Assembler.Memory.all ~f:(fun memory ->
        printf "%s\n" what;
        show_run (run ~memory quiet program)));
  [%expect
    {|
    unrolled
    ((name uart_tx_unrolled_0xa6) (memory m16) (outcome Halted)
     (size
      ((instructions 23) (slots 34) (extension_words 11) (memory_words 34)
       (memory_bits 544)))
     (counts
      ((cycles 90) (fetch_cycles 34) (execute_cycles 23) (stall_cycles 33)
       (instructions 23) (extension_fetches 11) (memory_reads 34)
       (buffer_hits 0))))
    ((bit_period 8) (uniform true))
    unrolled
    ((name uart_tx_unrolled_0xa6) (memory m32) (outcome Halted)
     (size
      ((instructions 23) (slots 34) (extension_words 11) (memory_words 17)
       (memory_bits 544)))
     (counts
      ((cycles 73) (fetch_cycles 17) (execute_cycles 23) (stall_cycles 33)
       (instructions 23) (extension_fetches 11) (memory_reads 17)
       (buffer_hits 17))))
    ((bit_period 6) (uniform false))
    unrolled, slot-aligned
    ((name uart_tx_unrolled_aligned_0xa6) (memory m16) (outcome Halted)
     (size
      ((instructions 34) (slots 45) (extension_words 11) (memory_words 45)
       (memory_bits 720)))
     (counts
      ((cycles 112) (fetch_cycles 45) (execute_cycles 34) (stall_cycles 33)
       (instructions 34) (extension_fetches 11) (memory_reads 45)
       (buffer_hits 0))))
    ((bit_period 10) (uniform true))
    unrolled, slot-aligned
    ((name uart_tx_unrolled_aligned_0xa6) (memory m32) (outcome Halted)
     (size
      ((instructions 34) (slots 45) (extension_words 11) (memory_words 23)
       (memory_bits 736)))
     (counts
      ((cycles 90) (fetch_cycles 23) (execute_cycles 34) (stall_cycles 33)
       (instructions 34) (extension_fetches 11) (memory_reads 23)
       (buffer_hits 22))))
    ((bit_period 8) (uniform true))
    bit loop
    ((name uart_tx_loop_0xa6) (memory m16) (outcome Halted)
     (size
      ((instructions 14) (slots 15) (extension_words 1) (memory_words 15)
       (memory_bits 240)))
     (counts
      ((cycles 173) (fetch_cycles 69) (execute_cycles 68) (stall_cycles 36)
       (instructions 68) (extension_fetches 1) (memory_reads 69) (buffer_hits 0))))
    ((bit_period 15) (uniform true))
    bit loop
    ((name uart_tx_loop_0xa6) (memory m32) (outcome Halted)
     (size
      ((instructions 14) (slots 15) (extension_words 1) (memory_words 8)
       (memory_bits 256)))
     (counts
      ((cycles 148) (fetch_cycles 44) (execute_cycles 68) (stall_cycles 36)
       (instructions 68) (extension_fetches 1) (memory_reads 44)
       (buffer_hits 25))))
    ((bit_period 13) (uniform true))
    |}]
;;

(* The frame really is the frame: an independent bit-centre receiver reads the transmitted
   byte back out of the waveform. A program whose bit period wanders does not survive
   this, which is how packing's cost is detected rather than asserted. *)
let%expect_test "an independent receiver reads the transmitted byte" =
  let byte = 0xa6 in
  List.iter
    [ "unrolled", Example_programs.uart_tx_unrolled ~pin:0 ~delay:3 ~byte ()
    ; ( "unrolled, slot-aligned"
      , Example_programs.uart_tx_unrolled ~aligned:true ~pin:0 ~delay:3 ~byte () )
    ; "bit loop", Example_programs.uart_tx_loop ~pin:0 ~delay:3 ~byte
    ]
    ~f:(fun (what, program) ->
      List.iter Assembler.Memory.all ~f:(fun memory ->
        let trace = run ~memory quiet program in
        let period, uniform = bit_period trace ~pin:0 in
        let wave = Control_core.Trace.wave trace ~pin:0 in
        print_s
          [%message
            what
              ~memory:(trace.memory.name : string)
              ~bit_period:(period : int)
              ~uniform:(uniform : bool)
              ~received:
                (Option.map (decode_8n1 wave ~bit_cycles:period) ~f:(sprintf "0x%02x")
                 : string option)]));
  [%expect
    {|
    (unrolled (memory m16) (bit_period 8) (uniform true) (received (0xa6)))
    (unrolled (memory m32) (bit_period 6) (uniform false) (received (0x26)))
    ("unrolled, slot-aligned" (memory m16) (bit_period 10) (uniform true)
     (received (0xa6)))
    ("unrolled, slot-aligned" (memory m32) (bit_period 8) (uniform true)
     (received (0xa6)))
    ("bit loop" (memory m16) (bit_period 15) (uniform true) (received (0xa6)))
    ("bit loop" (memory m32) (bit_period 13) (uniform true) (received (0xa6)))
    |}]
;;

let%expect_test "the same frame as a transfer descriptor" =
  List.iter [ 1; 2 ] ~f:(fun frames ->
    let program =
      Example_programs.uart_tx_descriptor
        ~pin:0
        ~half_period:4
        ~bytes:(List.init frames ~f:(fun _ -> 0xa6))
    in
    show_run ~show_wire:false (run quiet program));
  [%expect
    {|
    ((name uart_tx_descriptor_x1) (memory m16) (outcome Halted)
     (size
      ((instructions 11) (slots 12) (extension_words 1) (memory_words 12)
       (memory_bits 192)))
     (counts
      ((cycles 23) (fetch_cycles 12) (execute_cycles 11) (stall_cycles 0)
       (instructions 11) (extension_fetches 1) (memory_reads 12) (buffer_hits 0))))
    ((name uart_tx_descriptor_x2) (memory m16) (outcome Halted)
     (size
      ((instructions 13) (slots 15) (extension_words 2) (memory_words 15)
       (memory_bits 240)))
     (counts
      ((cycles 28) (fetch_cycles 15) (execute_cycles 13) (stall_cycles 0)
       (instructions 13) (extension_fetches 2) (memory_reads 15) (buffer_hits 0))))
    |}]
;;

let%expect_test "SPI mode 0, against an independent target" =
  List.iter Assembler.Memory.all ~f:(fun memory ->
    let trace =
      run
        ~memory
        (spi_peer ())
        (Example_programs.spi_exchange ~cs:3 ~sclk:1 ~mosi:0 ~miso:2 ~delay:3 ~byte:0x5a)
    in
    show_run ~show_wire:false trace;
    (* The target sends 0x3c and the core assembles it a bit at a time out of [Read_pins];
       what the target received is read off its own clock and data lines in the waveform
       below rather than out of its state, which it does not keep. *)
    print_s
      [%message
        ""
          ~received_by_the_core:
            (sprintf "0x%02x" (Control_core.Trace.reg trace ~index:4) : string)
          ~mosi:(waveform trace ~pin:0 : (char * int) list)
          ~sclk:(waveform trace ~pin:1 : (char * int) list)]);
  [%expect
    {|
    ((name spi_mode0_0x5a) (memory m16) (outcome Halted)
     (size
      ((instructions 29) (slots 29) (extension_words 0) (memory_words 29)
       (memory_bits 464)))
     (counts
      ((cycles 325) (fetch_cycles 134) (execute_cycles 134) (stall_cycles 57)
       (instructions 134) (extension_fetches 0) (memory_reads 134)
       (buffer_hits 0))))
    ((received_by_the_core 0x3c)
     (mosi ((z 5) (0 64) (1 36) (0 36) (1 72) (0 36) (1 36) (0 40)))
     (sclk
      ((z 5) (0 37) (1 27) (0 9) (1 27) (0 9) (1 27) (0 9) (1 27) (0 9) (1 27)
       (0 9) (1 27) (0 9) (1 27) (0 9) (1 23) (0 8))))
    ((name spi_mode0_0x5a) (memory m32) (outcome Halted)
     (size
      ((instructions 29) (slots 29) (extension_words 0) (memory_words 15)
       (memory_bits 480)))
     (counts
      ((cycles 262) (fetch_cycles 71) (execute_cycles 134) (stall_cycles 57)
       (instructions 134) (extension_fetches 0) (memory_reads 71)
       (buffer_hits 63))))
    ((received_by_the_core 0x3c)
     (mosi ((z 4) (0 51) (1 29) (0 29) (1 58) (0 29) (1 29) (0 33)))
     (sclk
      ((z 4) (0 30) (1 21) (0 8) (1 21) (0 8) (1 21) (0 8) (1 21) (0 8) (1 21)
       (0 8) (1 21) (0 8) (1 21) (0 8) (1 18) (0 7))))
    |}]
;;

(* The I2C transaction, written both ways. This is the measurement that settled P1.5's
   call decision: the same body, inlined twice or called twice, against the same
   stretching target. *)
let%expect_test "I2C write, inlined against called" =
  List.iter Example_programs.Byte_loop.all ~f:(fun byte_loop ->
    let trace =
      run
        (i2c_peer ())
        (Example_programs.i2c_write
           ~byte_loop
           ~scl:6
           ~sda:7
           ~delay:3
           ~timeout:64
           ~address:0x42
           ~byte:0xa5
           ())
    in
    show_run ~show_wire:false trace;
    print_s
      [%message
        ""
          ~address_ack:(Control_core.Trace.reg trace ~index:6 : int)
          ~payload_ack:(Control_core.Trace.reg trace ~index:7 : int)
          ~target_received:
            (List.map trace.peer.received ~f:(sprintf "0x%02x") : string list)]);
  [%expect
    {|
    ((name i2c_write_inlined_0x42_0xa5) (memory m16) (outcome Halted)
     (size
      ((instructions 87) (slots 109) (extension_words 22) (memory_words 109)
       (memory_bits 1744)))
     (counts
      ((cycles 908) (fetch_cycles 403) (execute_cycles 325) (stall_cycles 180)
       (instructions 325) (extension_fetches 78) (memory_reads 403)
       (buffer_hits 0))))
    ((address_ack 0) (payload_ack 0) (target_received (0x84 0xa5)))
    ((name i2c_write_called_0x42_0xa5) (memory m16) (outcome Halted)
     (size
      ((instructions 61) (slots 77) (extension_words 16) (memory_words 77)
       (memory_bits 1232)))
     (counts
      ((cycles 916) (fetch_cycles 407) (execute_cycles 329) (stall_cycles 180)
       (instructions 329) (extension_fetches 78) (memory_reads 407)
       (buffer_hits 0))))
    ((address_ack 0) (payload_ack 0) (target_received (0x84 0xa5)))
    |}]
;;

(* What the call cost and what it saved, as the difference between the two programs above.
   Both send the same two bytes to the same target. *)
let%expect_test "what the call is worth" =
  let measure byte_loop =
    let trace =
      run
        (i2c_peer ())
        (Example_programs.i2c_write
           ~byte_loop
           ~scl:6
           ~sda:7
           ~delay:3
           ~timeout:64
           ~address:0x42
           ~byte:0xa5
           ())
    in
    trace.size, trace.counts
  in
  let inlined_size, inlined_counts = measure Inlined in
  let called_size, called_counts = measure Called in
  print_s
    [%message
      ""
        ~instructions:((inlined_size.instructions, called_size.instructions) : int * int)
        ~memory_words:((inlined_size.memory_words, called_size.memory_words) : int * int)
        ~memory_bits:((inlined_size.memory_bits, called_size.memory_bits) : int * int)
        ~cycles:((inlined_counts.cycles, called_counts.cycles) : int * int)
        ~fetch_cycles:
          ((inlined_counts.fetch_cycles, called_counts.fetch_cycles) : int * int)];
  [%expect
    {|
    ((instructions (87 61)) (memory_words (109 77)) (memory_bits (1744 1232))
     (cycles (908 916)) (fetch_cycles (403 407)))
    |}]
;;

(* [Call] writes the slot after itself and [Jump_reg] goes there, which is the whole of
   the return contract. Called twice from different places, the same subroutine returns to
   two different slots. *)
let%expect_test "a call returns to where it was called from" =
  let program =
    Program.create
      ~name:"two_call_sites"
      [ Instr (Call { link = 7; target = "add_one" })
      ; Instr (Mov { rd = 1; rs = 7 })
      ; Instr (Call { link = 7; target = "add_one" })
      ; Instr (Mov { rd = 2; rs = 7 })
      ; Instr Halt
      ; Label "add_one"
      ; Instr (Alu_imm { op = Add; rd = 0; imm = 1 })
      ; Instr (Jump_reg { rs = 7 })
      ]
  in
  let trace = run quiet program in
  print_s
    [%message
      ""
        ~outcome:(trace.outcome : Control_core.Outcome.t)
        ~calls_counted_in_r0:(Control_core.Trace.reg trace ~index:0 : int)
        ~first_return_address:(Control_core.Trace.reg trace ~index:1 : int)
        ~second_return_address:(Control_core.Trace.reg trace ~index:2 : int)
        ~cycles:(trace.counts.cycles : int)];
  [%expect
    {|
    ((outcome Halted) (calls_counted_in_r0 2) (first_return_address 1)
     (second_return_address 3) (cycles 18))
    |}]
;;

(* An invalid instruction halts the core at the slot that produced it, with the pins left
   driving whatever they were driving. That is P1.1's rule for a bad fetch applied to
   decoded words: a program error is not an abort, and whether to abort, reset or inspect
   is the host's decision. *)
let%expect_test "a bad word stops the core where it is" =
  (* The store is written by hand here, because an assembler that emitted a reserved
     opcode would be the bug. *)
  let program =
    Program.create
      ~name:"drive_then_run_into_padding"
      [ Instr (Write_pins_imm { mode = Push_pull; mask = 0xff; value = 0x5a })
      ; Instr (Jump { target = "past_the_end" })
      ; Instr Halt
      ; Label "past_the_end"
      ]
  in
  let trace = run quiet program in
  print_s
    [%message
      ""
        ~outcome:(trace.outcome : Control_core.Outcome.t)
        ~pins_still_driving:(sprintf "%02x" trace.final.pins.value : string)
        ~output_enable:(sprintf "%02x" trace.final.pins.output_enable : string)];
  [%expect
    {|
    ((outcome (Faulted (slot 4) (reason Unspecified))) (pins_still_driving 5a)
     (output_enable ff))
    |}]
;;
