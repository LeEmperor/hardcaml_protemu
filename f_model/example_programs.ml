(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "example_programs.ml" *)
(* The labeled programs P1.5's evidence runs: the same UART, SPI and I2C work P1.3 built
   out of operations, written in the chosen instruction set.

   SAME TRANSACTIONS, ONE LAYER UP. [Firmware_uart], [Firmware_spi] and [Firmware_i2c]
   build sequences of operations and a runner offers them one per edge, which made their
   cycle counts a floor with no fetch in them. These programs do the same transactions
   with a program counter, registers and branches, so their counts include everything the
   encoding costs. Two of them are written more than once on purpose - straight-line and
   looped, inlined and called - because those choices trade program words against cycles
   and the trade is what the decision document reports.

   WHAT THE PEERS ARE FOR. The SPI and I2C programs are run against the independent
   targets in [Firmware_spi.Peer] and [Firmware_i2c.Peer], which follow the wire and
   nothing else. A program that assembles, executes and is then not understood by the
   device on the other end has not done the work, and the test says so.

   [~delay] IS THE COUNTDOWN WRITTEN IN THE PROGRAM, not the bit period: the bit period is
   the countdown plus the fetch and execute edges around it, and it is measured from the
   trace rather than predicted.
*)

open! Core
open! Kinds
open Program

(* The registers each program uses, named once so a reader does not have to follow a
   number through fifty instructions.

   r0 : the word being shifted out; r1 : bits remaining; r2 : the pin mask every write
   commits; r3 : the value of the next write; r4 : a received word, and the link register
   where I2C calls its byte writer; r5 : one sampled bit, and the byte writer's answer; r6
   : the first acknowledge; r7 : the second acknowledge;
*)
let shifted = 0
let counter = 1
let pin_mask = 2
let pin_value = 3
let received = 4
let link = 4
let sample = 5
let ack_first = 6
let ack_second = 7

(* The cheapest instruction that does nothing: one word, no flags touched. There is no
   dedicated no-operation opcode, and adding one would cost a code point to save nothing -
   a [Mov] into the register it came from already spells it. *)
let nop = Instruction.Mov { rd = ack_second; rs = ack_second }

(* --------------------------------------------------------------------------------------
   UART 8N1 transmit
   -------------------------------------------------------------------------------------- *)

(* Start bit low, byte, stop bit high, from the least significant bit up: the same frame
   word [Firmware_uart] builds, transmitted in the same order. *)
let frame_word byte = (1 lsl 9) lor (byte lsl 1)

let frame_bits byte =
  List.init 10 ~f:(fun index -> frame_word byte land (1 lsl index) <> 0)
;;

let byte_range what value =
  if value < 0 || value > 255
  then Error (Invalid.Immediate_out_of_range { what; value })
  else Ok ()
;;

(* Straight-line: one pin write and one countdown per bit, with the level in the
   instruction. Eleven levels - an idle bit and the ten frame bits - and nothing that
   depends on a register, so this is the program a firmware author writes first and the
   one whose size grows with every bit. *)
let uart_tx_unrolled ?(aligned = false) ~pin ~delay ~byte () =
  Result.bind (byte_range "byte" byte) ~f:(fun () ->
    let mask = 1 lsl pin in
    let drive level =
      [ instr
          (Instruction.Write_pins_imm
             { mode = Push_pull; mask; value = (if level then mask else 0) })
      ; instr (Instruction.Wait_cycles_imm { delay })
      ]
      (* [aligned] pads every bit to an even number of instruction slots. It buys nothing
         except in a packed image, where an odd-length bit body makes consecutive bits
         start in opposite halves of a memory word and fetch a different number of words -
         one cycle of jitter in the bit period, on a line whose whole job is uniform bit
         periods. The pad costs one word and one edge per bit. *)
      @ if aligned then [ instr nop ] else []
    in
    Program.create
      ~name:
        (sprintf "uart_tx_unrolled%s_0x%02x" (if aligned then "_aligned" else "") byte)
      ((at "idle" :: drive true)
       @ List.concat_mapi (frame_bits byte) ~f:(fun index level ->
         at (if index = 0 then "start" else sprintf "d%d" (index - 1)) :: drive level)
       @ [ at "done"; instr Instruction.Halt ]))
;;

(* Looped: the frame word goes in a register, one bit is peeled off per iteration, and
   [Dbnz] closes the loop. The line's level now comes from a register, so every write is
   [Write_pins_reg] and the mask is preloaded once. Ten bits cost one loop body instead of
   ten copies of it; what they cost in cycles is the loop overhead on every bit. *)
let uart_tx_loop ~pin ~delay ~byte =
  Result.bind (byte_range "byte" byte) ~f:(fun () ->
    let mask = 1 lsl pin in
    let write =
      instr
        (Instruction.Write_pins_reg
           { mode = Push_pull; mask_reg = pin_mask; value_reg = pin_value })
    in
    let place_bit =
      (* The frame's next bit is bit zero of [shifted]; the pin it drives may be any of
         the eight, so a nonzero pin costs one more instruction per bit. *)
      if pin = 0
      then []
      else [ instr (Instruction.Shift { dir = Left; rd = pin_value; amount = pin }) ]
    in
    Program.create
      ~name:(sprintf "uart_tx_loop_0x%02x" byte)
      ([ at "setup"
       ; instr (Instruction.Ldi { rd = pin_mask; value = mask })
       ; instr (Instruction.Ldi { rd = pin_value; value = mask })
       ; write
       ; instr (Instruction.Wait_cycles_imm { delay })
       ; instr (Instruction.Ldi { rd = shifted; value = frame_word byte })
       ; instr (Instruction.Ldi { rd = counter; value = 10 })
       ; at "bit"
       ; instr (Instruction.Mov { rd = pin_value; rs = shifted })
       ; instr (Instruction.Alu_imm { op = And; rd = pin_value; imm = 1 })
       ]
       @ place_bit
       @ [ write
         ; instr (Instruction.Shift { dir = Right; rd = shifted; amount = 1 })
         ; instr (Instruction.Wait_cycles_imm { delay })
         ; instr (Instruction.Dbnz { rd = counter; target = "bit" })
         ; at "stop"
         ; instr (Instruction.Wait_cycles_imm { delay })
         ; instr Instruction.Halt
         ]))
;;

(* The same frame handed to the transfer engine: eight descriptor fields that describe the
   frame's shape, then one transmitted word and one issue per byte. Nothing shifts a bit
   here, so the program's size does not grow with the frame, and its cycle count stops at
   acceptance - the eighty cycles the engine then occupies are P1.3's measurement, not
   this program's (P2.5 has not built the engine into the machine).

   [bytes] is a list so that the cost of a later frame can be measured rather than
   asserted: every field but the transmitted word still holds between frames. *)
let uart_tx_descriptor ~pin ~half_period ~bytes =
  match List.find bytes ~f:(fun byte -> byte < 0 || byte > 255) with
  | Some byte -> Error (Invalid.Immediate_out_of_range { what = "byte"; value = byte })
  | None ->
    let control =
      Descriptor.Control.of_choices
        ~direction:Tx_only
        ~bit_order:Lsb_first
        ~idle_output:true
        ~idle_clock:false
        ~launch:On_falling
        ~sample:On_rising
    in
    let set field value = instr (Instruction.Config { field; value }) in
    Program.create
      ~name:(sprintf "uart_tx_descriptor_x%d" (List.length bytes))
      ([ at "configure"
       ; set Control control
       ; set Bit_count 10
       ; set Output_pin pin
       ; set Input_pin Descriptor.no_pin
       ; set Clock_pin Descriptor.no_pin
       ; set Initial_delay 0
       ; set Half_period half_period
       ; set Pacing Descriptor.Pacing.internal
       ]
       @ List.concat_mapi bytes ~f:(fun index byte ->
         [ at (sprintf "frame%d" index)
         ; set Tx_value (frame_word byte)
         ; instr Instruction.Issue_transfer
         ])
       @ [ at "done"; instr Instruction.Halt ])
;;

(* --------------------------------------------------------------------------------------
   SPI mode 0
   -------------------------------------------------------------------------------------- *)

(* An eight-bit mode-0 exchange with chip select, most significant bit first, receiving
   into a register as it goes.

   This is the example P1.3 could not finish: it recorded a sample as a trace marker
   because reading a pin into a register needed a register file and an input-read
   instruction. Here the received word is assembled by [Read_pins] and five more
   instructions per bit, and the test compares it with what the independent target sent. *)
let spi_exchange ~cs ~sclk ~mosi ~miso ~delay ~byte =
  Result.bind (byte_range "byte" byte) ~f:(fun () ->
    let mask = (1 lsl cs) lor (1 lsl sclk) lor (1 lsl mosi) in
    let write =
      instr
        (Instruction.Write_pins_reg
           { mode = Push_pull; mask_reg = pin_mask; value_reg = pin_value })
    in
    let drive value =
      [ instr (Instruction.Ldi { rd = pin_value; value })
      ; write
      ; instr (Instruction.Wait_cycles_imm { delay })
      ]
    in
    Program.create
      ~name:(sprintf "spi_mode0_0x%02x" byte)
      ([ at "idle"; instr (Instruction.Ldi { rd = pin_mask; value = mask }) ]
       (* Chip select high, clock and data low. *)
       @ drive (1 lsl cs)
       @ [ at "select" ]
       (* Chip select falls a half period before the first launch edge. *)
       @ drive 0
       @ [ at "byte"
         ; instr (Instruction.Ldi { rd = shifted; value = byte })
         ; instr (Instruction.Ldi { rd = counter; value = 8 })
         ; instr (Instruction.Ldi { rd = received; value = 0 })
         ; at "bit" (* Launch: clock low, the next bit of the byte on the data pin. *)
         ; instr (Instruction.Mov { rd = pin_value; rs = shifted })
         ; instr (Instruction.Shift { dir = Right; rd = pin_value; amount = 7 })
         ; instr (Instruction.Alu_imm { op = And; rd = pin_value; imm = 1 })
         ]
       @ (if mosi = 0
          then []
          else [ instr (Instruction.Shift { dir = Left; rd = pin_value; amount = mosi }) ])
       @ [ write
         ; instr (Instruction.Wait_cycles_imm { delay })
           (* Sample edge: the clock rises with the same data still driven. *)
         ; instr (Instruction.Alu_imm { op = Or; rd = pin_value; imm = 1 lsl sclk })
         ; write
         ; instr (Instruction.Wait_cycles_imm { delay })
           (* The target's bit has been stable across the whole high phase by now, which
              is what the two synchronizer stages need. *)
         ; instr (Instruction.Shift { dir = Left; rd = received; amount = 1 })
         ; instr (Instruction.Read_pins { rd = sample })
         ; instr (Instruction.Shift { dir = Right; rd = sample; amount = miso })
         ; instr (Instruction.Alu_imm { op = And; rd = sample; imm = 1 })
         ; instr (Instruction.Alu { op = Or; rd = received; rs = sample })
         ; instr (Instruction.Shift { dir = Left; rd = shifted; amount = 1 })
         ; instr (Instruction.Dbnz { rd = counter; target = "bit" })
         ; at "release"
         ]
       (* Clock low, chip select high: the target resets its own bit counter. *)
       @ drive (1 lsl cs)
       @ [ at "done"; instr Instruction.Halt ]))
;;

(* --------------------------------------------------------------------------------------
   I2C single-master write
   -------------------------------------------------------------------------------------- *)

module Byte_loop = struct
  (* The two ways of writing a transaction that sends more than one byte. P1.4 measured
     [Inlined] because it had no other option - its instruction set had no call - and
     recorded that 31 of the transaction's 85 instructions were the second copy of one
     loop. [Called] is the same body reached by [Call] and left by [Jump_reg], and the
     difference between the two is the measurement that settled P1.5's call decision. *)
  type t =
    | Inlined
    | Called
  [@@deriving sexp, compare, equal, enumerate]

  let name = function
    | Inlined -> "inlined"
    | Called -> "called"
  ;;
end

(* START, an addressed write byte, one payload byte, STOP - every write open drain, every
   acknowledge a sample of the wire, every clock-high phase preceded by a level wait so
   that a stretching target is waited out rather than clocked over. The rules are
   [Firmware_i2c]'s; what is new is that they are instructions. *)
let i2c_write ?(byte_loop = Byte_loop.Called) ~scl ~sda ~delay ~timeout ~address ~byte () =
  let ( >>= ) result f = Result.bind result ~f in
  let scl_low = 1 lsl scl in
  let sda_low = 1 lsl sda in
  let mask = scl_low lor sda_low in
  let write =
    instr
      (Instruction.Write_pins_reg
         { mode = Open_drain; mask_reg = pin_mask; value_reg = pin_value })
  in
  (* One open-drain commit of both lines, then a countdown. [low] names the lines held at
     zero; everything else is released to the board pull-up. *)
  let commit low =
    [ instr (Instruction.Ldi { rd = pin_value; value = low })
    ; write
    ; instr (Instruction.Wait_cycles_imm { delay })
    ]
  in
  (* Release the clock, wait until the wire really is high, and hold it there. The level
     wait is the clock-stretch tolerance. *)
  let clock_high ~holding =
    [ instr (Instruction.Ldi { rd = pin_value; value = holding })
    ; write
    ; instr (Instruction.Wait_level { pin = scl; level = true; timeout = Some timeout })
    ; instr (Instruction.Wait_cycles_imm { delay })
    ]
  in
  (* Eight bits, most significant first, then the acknowledge slot. Takes the byte in
     [shifted] and leaves the target's answer in [sample]; the caller moves it wherever it
     wants it. Identical under both structures, which is what makes the comparison a
     comparison. *)
  let write_byte_body ~label =
    [ at (label ^ ".bit")
    ; instr (Instruction.Mov { rd = pin_value; rs = shifted })
    ; instr (Instruction.Shift { dir = Right; rd = pin_value; amount = 7 })
    ; instr (Instruction.Alu_imm { op = And; rd = pin_value; imm = 1 })
      (* A one is released and a zero is driven low, so the bit is inverted before it
         becomes a drive mask. *)
    ; instr (Instruction.Alu_imm { op = Xor; rd = pin_value; imm = 1 })
    ; instr (Instruction.Shift { dir = Left; rd = pin_value; amount = sda })
    ; instr (Instruction.Alu_imm { op = Or; rd = pin_value; imm = scl_low })
    ; write
    ; instr (Instruction.Wait_cycles_imm { delay })
      (* Release the clock with the data line unchanged. *)
    ; instr (Instruction.Alu_imm { op = And; rd = pin_value; imm = sda_low })
    ; write
    ; instr (Instruction.Wait_level { pin = scl; level = true; timeout = Some timeout })
    ; instr (Instruction.Wait_cycles_imm { delay })
    ; instr (Instruction.Alu_imm { op = Or; rd = pin_value; imm = scl_low })
    ; write
    ; instr (Instruction.Wait_cycles_imm { delay })
    ; instr (Instruction.Shift { dir = Left; rd = shifted; amount = 1 })
    ; instr (Instruction.Dbnz { rd = counter; target = label ^ ".bit" })
    ; at (label ^ ".ack")
    ]
    (* The ninth slot: release the data line and read what the target does with it. *)
    @ commit scl_low
    @ clock_high ~holding:0
      (* Zero is an acknowledge: the target answers by pulling the line low, and the
         sample keeps only that line's bit, so the register holds the answer and not the
         state of seven pins nobody asked about. *)
    @ [ instr (Instruction.Read_pins { rd = sample })
      ; instr (Instruction.Alu_imm { op = And; rd = sample; imm = sda_low })
      ]
    @ commit scl_low
  in
  let load_byte ~label ~value =
    [ at label
    ; instr (Instruction.Ldi { rd = shifted; value })
    ; instr (Instruction.Ldi { rd = counter; value = 8 })
    ]
  in
  let take_ack ~into = [ instr (Instruction.Mov { rd = into; rs = sample }) ] in
  (* The two structures. Inlined, each byte carries its own copy of the body; called, one
     copy sits past the halt and both bytes reach it with [Call]. *)
  let body =
    match byte_loop with
    | Byte_loop.Inlined ->
      ( load_byte ~label:"addr" ~value:((address lsl 1) lor 0)
        @ write_byte_body ~label:"addr"
        @ take_ack ~into:ack_first
        @ load_byte ~label:"payload" ~value:byte
        @ write_byte_body ~label:"payload"
        @ take_ack ~into:ack_second
      , [] )
    | Called ->
      ( load_byte ~label:"addr" ~value:((address lsl 1) lor 0)
        @ [ instr (Instruction.Call { link; target = "write_byte" }) ]
        @ take_ack ~into:ack_first
        @ load_byte ~label:"payload" ~value:byte
        @ [ instr (Instruction.Call { link; target = "write_byte" }) ]
        @ take_ack ~into:ack_second
      , (* The subroutine sits after the halt, where nothing falls into it, and returns
           through the register the call wrote. There is no stack: the callee's contract
           is that it keeps the link register, which a leaf like this one does for free. *)
        (at "write_byte" :: write_byte_body ~label:"write_byte")
        @ [ instr (Instruction.Jump_reg { rs = link }) ] )
  in
  let transaction, subroutine = body in
  if address < 0 || address > 0x7f
  then Error (Invalid.Immediate_out_of_range { what = "address"; value = address })
  else
    byte_range "byte" byte
    >>= fun () ->
    Program.create
      ~name:(sprintf "i2c_write_%s_0x%02x_0x%02x" (Byte_loop.name byte_loop) address byte)
      ([ at "free"
       ; instr (Instruction.Ldi { rd = pin_mask; value = mask })
       ; instr (Instruction.Ldi { rd = pin_value; value = 0 })
       ; write
         (* After reset the input front end reports both lines low until the pull-ups have
            crossed the synchronizers, so the bus-free check is a wait and not a delay. *)
       ; instr
           (Instruction.Wait_level { pin = sda; level = true; timeout = Some timeout })
       ; instr
           (Instruction.Wait_level { pin = scl; level = true; timeout = Some timeout })
       ; instr (Instruction.Wait_cycles_imm { delay })
       ; at "start"
       ]
       (* START: pull the data line low while the clock is high, then pull the clock low. *)
       @ commit sda_low
       @ commit mask
       @ transaction
       (* STOP: with the data line held low, release the clock, then release the data. *)
       @ (at "stop" :: commit mask)
       @ clock_high ~holding:sda_low
       @ commit 0
       @ [ at "done"; instr Instruction.Halt ]
       @ subroutine)
;;
