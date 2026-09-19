(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "study_examples.ml" *)
(* The programs P1.4 measures: the same UART, SPI and I2C work P1.3 built out of
   operations, written this time as instructions.

   SAME EXAMPLES, DIFFERENT LAYER. [Firmware_uart], [Firmware_spi] and [Firmware_i2c]
   build sequences of operations and a runner offers them one per edge, which made their
   cycle counts a floor with no fetch in them. These programs do the same transactions
   with a program counter, registers and branches, so their counts include everything an
   encoding costs. Two of them are written twice on purpose - straight-line and looped -
   because that choice trades program words against cycles and the trade is different for
   each candidate.

   ONE PROGRAM TEXT PER EXAMPLE, NOT ONE PER CANDIDATE. Nothing below knows which encoding
   will assemble it. That is what makes the comparison a comparison; it also means the
   delay immediates are the same for every candidate, so the wire timing each one achieves
   differs by its own fetch overhead. [~delay] is therefore the countdown written in the
   program and not the bit period: the bit period is measured from the trace, and at
   [~delay:1] what is measured is the fastest bit period the candidate can bit-bang at
   all.

   REGISTER STYLE AND IMMEDIATE STYLE. A straight-line frame writes its pins with
   [Write_pins_imm], which is the natural form and is the one the 16-bit encoding cannot
   fit in a single word. A loop cannot: its level comes from a shifted register, so it
   writes with [Write_pins_reg] and preloads the mask once. Both forms are in the
   instruction set for exactly this reason, and the report gives each one's cost.

   WHAT THE PEERS ARE FOR. The SPI and I2C programs are run against the independent
   targets in [Firmware_spi.Peer] and [Firmware_i2c.Peer], which follow the wire and
   nothing else. A program that assembles, executes and then fails to be understood by the
   device on the other end has not done the work, and the test would say so.
*)

open! Core
open! Kinds
open Study_isa

let instr i = Item.Instr i
let at label = Item.Label label

(* The registers each program uses, named once so a reader does not have to follow a
   number through fifty instructions.

   r0 : the word being shifted out; r1 : bits remaining; r2 : the pin mask every write
   commits; r3 : the value of the next write; r4 : a received word; r5 : scratch for one
   sampled bit; r6 : the first acknowledge; r7 : the second acknowledge;
*)
let shifted = 0
let counter = 1
let pin_mask = 2
let pin_value = 3
let received = 4
let sample = 5
let ack_first = 6
let ack_second = 7

(* The cheapest instruction that does nothing: one word in either encoding, no flags
   touched. There is no dedicated no-operation opcode, and adding one would cost a code
   point to save nothing - [Mov] into the register it came from already spells it. *)
let nop = Instr.Mov { rd = ack_second; rs = ack_second }

(* --------------------------------------------------------------------------------------
   UART 8N1 transmit
   -------------------------------------------------------------------------------------- *)

(* Start bit low, byte, stop bit high, from the least significant bit up: the same frame
   word [Firmware_uart] builds, and transmitted in the same order. *)
let frame_word byte = (1 lsl 9) lor (byte lsl 1)

let frame_bits byte =
  List.init 10 ~f:(fun index -> frame_word byte land (1 lsl index) <> 0)
;;

(* Straight-line: one pin write and one countdown per bit, with the level in the
   instruction. Eleven levels - an idle bit and the ten frame bits - and nothing that
   depends on a register, so this is the program a firmware author writes first and the
   one whose size grows with every bit. *)
let uart_tx_unrolled ?(aligned = false) ~pin ~delay ~byte () =
  if byte < 0 || byte > 255
  then Error (Invalid.Immediate_out_of_range { what = "byte"; value = byte })
  else (
    let mask = 1 lsl pin in
    let drive level =
      [ instr
          (Instr.Write_pins_imm
             { mode = Pin_mode.Push_pull; mask; value = (if level then mask else 0) })
      ; instr (Instr.Wait_cycles_imm { delay })
      ]
      (* [aligned] pads every bit to an even number of instruction slots. It buys nothing
         except under a candidate that packs two instructions into a memory word, where an
         odd-length bit body makes consecutive bits start in opposite halves and fetch a
         different number of words - one cycle of jitter in the bit period, on a line
         whose whole job is uniform bit periods. The pad costs one word and one edge per
         bit. *)
      @ if aligned then [ instr nop ] else []
    in
    Study_isa.create
      ~name:
        (sprintf "uart_tx_unrolled%s_0x%02x" (if aligned then "_aligned" else "") byte)
      ((at "idle" :: drive true)
       @ List.concat_mapi (frame_bits byte) ~f:(fun index level ->
         at (if index = 0 then "start" else sprintf "d%d" (index - 1)) :: drive level)
       @ [ at "done"; instr Instr.Halt ]))
;;

(* Looped: the frame word goes in a register, one bit is peeled off per iteration, and
   [Dbnz] closes the loop. The line's level now comes from a register, so every write is
   [Write_pins_reg] and the mask is preloaded once. Ten bits cost one loop body instead of
   ten copies of it; what they cost in cycles is the loop overhead on every bit. *)
let uart_tx_loop ~pin ~delay ~byte =
  if byte < 0 || byte > 255
  then Error (Invalid.Immediate_out_of_range { what = "byte"; value = byte })
  else (
    let mask = 1 lsl pin in
    let write =
      instr
        (Instr.Write_pins_reg
           { mode = Pin_mode.Push_pull; mask_reg = pin_mask; value_reg = pin_value })
    in
    let place_bit =
      (* The frame's next bit is bit zero of [shifted]; the pin it drives may be any of
         the eight, so a nonzero pin costs one more instruction per bit. *)
      if pin = 0
      then []
      else [ instr (Instr.Shift { dir = Left; rd = pin_value; amount = pin }) ]
    in
    Study_isa.create
      ~name:(sprintf "uart_tx_loop_0x%02x" byte)
      ([ at "setup"
       ; instr (Instr.Ldi { rd = pin_mask; value = mask })
       ; instr (Instr.Ldi { rd = pin_value; value = mask })
       ; write
       ; instr (Instr.Wait_cycles_imm { delay })
       ; instr (Instr.Ldi { rd = shifted; value = frame_word byte })
       ; instr (Instr.Ldi { rd = counter; value = 10 })
       ; at "bit"
       ; instr (Instr.Mov { rd = pin_value; rs = shifted })
       ; instr (Instr.Alu_imm { op = And; rd = pin_value; imm = 1 })
       ]
       @ place_bit
       @ [ write
         ; instr (Instr.Shift { dir = Right; rd = shifted; amount = 1 })
         ; instr (Instr.Wait_cycles_imm { delay })
         ; instr (Instr.Dbnz { rd = counter; target = "bit" })
         ; at "stop"
         ; instr (Instr.Wait_cycles_imm { delay })
         ; instr Instr.Halt
         ]))
;;

(* The same frame handed to the transfer engine: eight descriptor fields that describe the
   frame's shape, then one transmitted word and one issue per byte. Nothing shifts a bit
   here, so the program's size does not grow with the frame, and its cycle count stops at
   acceptance - the eighty cycles the engine then occupies are P1.3's measurement, not
   this program's.

   [bytes] is a list so that the cost of a later frame can be measured rather than
   asserted. Every field but the transmitted word still holds between frames, so a second
   byte adds one [Config] and one [Issue_transfer], and the difference between a one-byte
   and a two-byte program is what re-arming costs. *)
let uart_tx_descriptor ~pin ~half_period ~bytes =
  match List.find bytes ~f:(fun byte -> byte < 0 || byte > 255) with
  | Some byte -> Error (Invalid.Immediate_out_of_range { what = "byte"; value = byte })
  | None ->
    let control =
      Descriptor.control
        ~direction:Direction.Tx_only
        ~bit_order:Bit_order.Lsb_first
        ~idle_output:true
        ~idle_clock:false
        ~launch:Clock_phase.On_falling
        ~sample:Clock_phase.On_rising
    in
    let set field value = instr (Instr.Config { field; value }) in
    Study_isa.create
      ~name:(sprintf "uart_tx_descriptor_x%d" (List.length bytes))
      ([ at "configure"
       ; set Field.Control control
       ; set Field.Bit_count 10
       ; set Field.Output_pin pin
       ; set Field.Input_pin Descriptor.no_pin
       ; set Field.Clock_pin Descriptor.no_pin
       ; set Field.Initial_delay 0
       ; set Field.Half_period half_period
       ; set Field.Pacing 0
       ]
       @ List.concat_mapi bytes ~f:(fun index byte ->
         [ at (sprintf "frame%d" index)
         ; set Field.Tx_value (frame_word byte)
         ; instr Instr.Issue_transfer
         ])
       @ [ at "done"; instr Instr.Halt ])
;;

(* --------------------------------------------------------------------------------------
   SPI mode 0
   -------------------------------------------------------------------------------------- *)

(* An eight-bit mode-0 exchange with chip select, most significant bit first, receiving
   into a register as it goes.

   This is the example P1.3 could not finish: it recorded a sample as a trace marker
   because reading a pin into a register needed the register file and input-read operation
   of P1.4. Here the received word is assembled by [Read_pins] and five more instructions
   per bit, and the test compares it with what the independent target sent. *)
let spi_exchange ~cs ~sclk ~mosi ~miso ~delay ~byte =
  if byte < 0 || byte > 255
  then Error (Invalid.Immediate_out_of_range { what = "byte"; value = byte })
  else (
    let mask = (1 lsl cs) lor (1 lsl sclk) lor (1 lsl mosi) in
    let write =
      instr
        (Instr.Write_pins_reg
           { mode = Pin_mode.Push_pull; mask_reg = pin_mask; value_reg = pin_value })
    in
    let drive value =
      [ instr (Instr.Ldi { rd = pin_value; value })
      ; write
      ; instr (Instr.Wait_cycles_imm { delay })
      ]
    in
    Study_isa.create
      ~name:(sprintf "spi_mode0_0x%02x" byte)
      ([ at "idle"; instr (Instr.Ldi { rd = pin_mask; value = mask }) ]
       (* Chip select high, clock and data low. *)
       @ drive (1 lsl cs)
       @ [ at "select" ]
       (* Chip select falls a half period before the first launch edge. *)
       @ drive 0
       @ [ at "byte"
         ; instr (Instr.Ldi { rd = shifted; value = byte })
         ; instr (Instr.Ldi { rd = counter; value = 8 })
         ; instr (Instr.Ldi { rd = received; value = 0 })
         ; at "bit" (* Launch: clock low, the next bit of the byte on the data pin. *)
         ; instr (Instr.Mov { rd = pin_value; rs = shifted })
         ; instr (Instr.Shift { dir = Right; rd = pin_value; amount = 7 })
         ; instr (Instr.Alu_imm { op = And; rd = pin_value; imm = 1 })
         ]
       @ (if mosi = 0
          then []
          else [ instr (Instr.Shift { dir = Left; rd = pin_value; amount = mosi }) ])
       @ [ write
         ; instr (Instr.Wait_cycles_imm { delay })
           (* Sample edge: the clock rises with the same data still driven. *)
         ; instr (Instr.Alu_imm { op = Or; rd = pin_value; imm = 1 lsl sclk })
         ; write
         ; instr (Instr.Wait_cycles_imm { delay })
           (* The target's bit has been stable across the whole high phase by now, which
              is what the two synchronizer stages need. *)
         ; instr (Instr.Shift { dir = Left; rd = received; amount = 1 })
         ; instr (Instr.Read_pins { rd = sample })
         ; instr (Instr.Shift { dir = Right; rd = sample; amount = miso })
         ; instr (Instr.Alu_imm { op = And; rd = sample; imm = 1 })
         ; instr (Instr.Alu { op = Or; rd = received; rs = sample })
         ; instr (Instr.Shift { dir = Left; rd = shifted; amount = 1 })
         ; instr (Instr.Dbnz { rd = counter; target = "bit" })
         ; at "release"
         ]
       (* Clock low, chip select high: the target resets its own bit counter. *)
       @ drive (1 lsl cs)
       @ [ at "done"; instr Instr.Halt ]))
;;

(* --------------------------------------------------------------------------------------
   I2C single-master write
   -------------------------------------------------------------------------------------- *)

(* START, an addressed write byte, one payload byte, STOP - every write open drain, every
   acknowledge a sample of the wire, every clock-high phase preceded by a level wait so
   that a stretching target is waited out rather than clocked over. The rules are
   [Firmware_i2c]'s; what is new is that they are instructions.

   THE BYTE LOOP IS INLINED TWICE. There is no call instruction (study_isa.ml), so the
   address byte and the payload byte each carry their own copy of the eight-bit loop and
   their own acknowledge slot. That is the largest single cost in this program and the
   report names it. *)
let i2c_write ~scl ~sda ~delay ~timeout ~address ~byte =
  let ( >>= ) result f = Result.bind result ~f in
  let scl_low = 1 lsl scl in
  let sda_low = 1 lsl sda in
  let mask = scl_low lor sda_low in
  let write =
    instr
      (Instr.Write_pins_reg
         { mode = Pin_mode.Open_drain; mask_reg = pin_mask; value_reg = pin_value })
  in
  (* One open-drain commit of both lines, then a countdown. [low] names the lines held at
     zero; everything else is released to the board pull-up. *)
  let commit low =
    [ instr (Instr.Ldi { rd = pin_value; value = low })
    ; write
    ; instr (Instr.Wait_cycles_imm { delay })
    ]
  in
  (* Release the clock, wait until the wire really is high, and hold it there. The level
     wait is the clock-stretch tolerance. *)
  let clock_high ~holding =
    [ instr (Instr.Ldi { rd = pin_value; value = holding })
    ; write
    ; instr (Instr.Wait_level { pin = scl; level = true; timeout = Some timeout })
    ; instr (Instr.Wait_cycles_imm { delay })
    ]
  in
  (* Eight bits, most significant first, then the acknowledge slot. The loop body sets the
     data line while the clock is low, releases the clock, waits out any stretching, and
     pulls the clock low again. *)
  let write_byte ~label ~value ~ack =
    [ at label
    ; instr (Instr.Ldi { rd = shifted; value })
    ; instr (Instr.Ldi { rd = counter; value = 8 })
    ; at (label ^ ".bit")
    ; instr (Instr.Mov { rd = pin_value; rs = shifted })
    ; instr (Instr.Shift { dir = Right; rd = pin_value; amount = 7 })
    ; instr (Instr.Alu_imm { op = And; rd = pin_value; imm = 1 })
      (* A one is released and a zero is driven low, so the bit is inverted before it
         becomes a drive mask. *)
    ; instr (Instr.Alu_imm { op = Xor; rd = pin_value; imm = 1 })
    ; instr (Instr.Shift { dir = Left; rd = pin_value; amount = sda })
    ; instr (Instr.Alu_imm { op = Or; rd = pin_value; imm = scl_low })
    ; write
    ; instr (Instr.Wait_cycles_imm { delay })
      (* Release the clock with the data line unchanged. *)
    ; instr (Instr.Alu_imm { op = And; rd = pin_value; imm = sda_low })
    ; write
    ; instr (Instr.Wait_level { pin = scl; level = true; timeout = Some timeout })
    ; instr (Instr.Wait_cycles_imm { delay })
    ; instr (Instr.Alu_imm { op = Or; rd = pin_value; imm = scl_low })
    ; write
    ; instr (Instr.Wait_cycles_imm { delay })
    ; instr (Instr.Shift { dir = Left; rd = shifted; amount = 1 })
    ; instr (Instr.Dbnz { rd = counter; target = label ^ ".bit" })
    ; at (label ^ ".ack")
    ]
    (* The ninth slot: release the data line and read what the target does with it. *)
    @ commit scl_low
    @ clock_high ~holding:0
      (* Zero is an acknowledge: the target answers by pulling the line low, and the
         sample keeps only that line's bit so the register holds the answer and not the
         state of seven pins nobody asked about. *)
    @ [ instr (Instr.Read_pins { rd = ack })
      ; instr (Instr.Alu_imm { op = And; rd = ack; imm = sda_low })
      ]
    @ commit scl_low
  in
  if address < 0 || address > 0x7f
  then Error (Invalid.Immediate_out_of_range { what = "address"; value = address })
  else if byte < 0 || byte > 255
  then Error (Invalid.Immediate_out_of_range { what = "byte"; value = byte })
  else
    Ok
      ([ at "free"
       ; instr (Instr.Ldi { rd = pin_mask; value = mask })
       ; instr (Instr.Ldi { rd = pin_value; value = 0 })
       ; write
         (* After reset the input front end reports both lines low until the pull-ups have
            crossed the synchronizers, so the bus-free check is a wait and not a delay. *)
       ; instr (Instr.Wait_level { pin = sda; level = true; timeout = Some timeout })
       ; instr (Instr.Wait_level { pin = scl; level = true; timeout = Some timeout })
       ; instr (Instr.Wait_cycles_imm { delay })
       ; at "start"
       ]
       (* START: pull the data line low while the clock is high, then pull the clock low. *)
       @ commit sda_low
       @ commit mask)
    >>= fun preamble ->
    Ok
      (write_byte ~label:"addr" ~value:((address lsl 1) lor 0) ~ack:ack_first
       @ write_byte ~label:"payload" ~value:byte ~ack:ack_second)
    >>= fun body ->
    (* STOP: with the data line held low, release the clock, then release the data. *)
    Ok ((at "stop" :: commit mask) @ clock_high ~holding:sda_low @ commit 0)
    >>= fun stop ->
    Study_isa.create
      ~name:(sprintf "i2c_write_0x%02x_0x%02x" address byte)
      (preamble @ body @ stop @ [ at "done"; instr Instr.Halt ])
;;
