(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "test_firmware.ml" *)
(* P1.3: the first firmware helpers - UART transmit, a mode-0 SPI exchange, and explicit
   I2C drive/sample/wait sequences - with the traces that show the expected transaction
   and the operation counts and response latencies each one costs.
*)

open! Core
open! Protemu_f_model

let run ?machine ?max_cycles board firmware =
  match firmware with
  | Error invalid ->
    raise_s [%message "firmware did not build" (invalid : Firmware.Invalid.t)]
  | Ok firmware ->
    (match Firmware.run ?machine ?max_cycles board firmware with
     | Error invalid -> raise_s [%message "invalid" (invalid : Firmware.Invalid.t)]
     | Ok trace -> trace)
;;

let show_summary (trace : _ Firmware.Trace.t) =
  print_s
    [%message
      ""
        ~_:(Firmware.Trace.summary trace : Firmware.Summary.t)
        ~outcome:(trace.outcome : Firmware.Outcome.t)]
;;

let show_runs (trace : _ Firmware.Trace.t) ~pin =
  print_s
    [%sexp (Firmware.Trace.runs (Firmware.Trace.wave trace ~pin) : (char * int) list)]
;;

let%expect_test "a bit-banged 8N1 frame drives the expected waveform" =
  let trace =
    run Firmware.Board.quiet (Firmware_uart.tx_sequence ~pin:0 ~half_period:4 ~byte:0xa6)
  in
  show_summary trace;
  [%expect
    {|
    (((name uart_tx_8n1_0xa6) (operations 22) (cycles 88) (max_response 7)
      (samples 0))
     (outcome Completed))
    |}];
  show_runs trace ~pin:0;
  [%expect {| ((1 8) (0 16) (1 16) (0 16) (1 8) (0 8) (1 16)) |}];
  print_s [%sexp (Firmware.Trace.regions trace : Firmware.Region.t list)];
  [%expect
    {|
    (((label idle) (operations 2) (cycles 8))
     ((label start) (operations 2) (cycles 8))
     ((label d0) (operations 2) (cycles 8))
     ((label d1) (operations 2) (cycles 8))
     ((label d2) (operations 2) (cycles 8))
     ((label d3) (operations 2) (cycles 8))
     ((label d4) (operations 2) (cycles 8))
     ((label d5) (operations 2) (cycles 8))
     ((label d6) (operations 2) (cycles 8))
     ((label d7) (operations 2) (cycles 8))
     ((label stop) (operations 2) (cycles 8)))
    |}]
;;

let%expect_test "a mode-0 SPI exchange clocks out a byte and reads the target's" =
  let board =
    Firmware_spi.Peer.board ~sclk:1 ~miso:2 ~bit_order:Msb_first ~bit_count:8 ~value:0x3c
  in
  let trace =
    run
      board
      (Firmware_spi.exchange
         ~cs:3
         ~sclk:1
         ~mosi:0
         ~miso:2
         ~half_period:4
         ~bit_count:8
         ~bit_order:Msb_first
         ~tx_value:0x5a
         ())
  in
  show_summary trace;
  [%expect
    {|
    (((name spi_mode0_x8_0x5a) (operations 36) (cycles 72) (max_response 3)
      (samples 8))
     (outcome Completed))
    |}];
  print_s
    [%message
      ""
        ~mosi:(Firmware.Trace.wave trace ~pin:0 : string)
        ~sclk:(Firmware.Trace.wave trace ~pin:1 : string)
        ~cs:(Firmware.Trace.wave trace ~pin:3 : string)];
  [%expect
    {|
    ((mosi
      000000000000111111110000000011111111111111110000000011111111000000000000)
     (sclk
      000000001111000011110000111100001111000011110000111100001111000011110000)
     (cs
      000000000000000000000000000000000000000000000000000000000000000000001111))
    |}];
  print_s
    [%message
      ""
        ~received:(Firmware.Trace.word trace ~name:"miso" ~order:Msb_first : int)
        ~bits:(Firmware.Trace.samples trace ~name:"miso" : bool list)];
  [%expect {| ((received 60) (bits (false false true true true true false false))) |}]
;;

let%expect_test "an I2C write transaction drives, samples, and waits out a stretched \
                 clock"
  =
  let board = Firmware_i2c.Peer.board ~stretch_cycles:12 ~scl:6 ~sda:7 ~address:0x42 () in
  let trace =
    run
      board
      (Firmware_i2c.write_transaction
         ~scl:6
         ~sda:7
         ~quarter_period:4
         ~address:0x42
         ~bytes:[ 0xa5 ]
         ())
  in
  show_summary trace;
  [%expect
    {|
    (((name i2c_write_0x42_x1) (operations 105) (cycles 224) (max_response 10)
      (samples 2))
     (outcome Completed))
    |}];
  print_s
    [%message
      ""
        ~acknowledges:(Firmware.Trace.samples trace ~name:"ack" : bool list)
        ~target_received:(trace.peer.received : int list)];
  [%expect {| ((acknowledges (false false)) (target_received (132 165))) |}];
  print_s
    [%message
      ""
        ~scl_driven:
          (Firmware.Trace.runs (Firmware.Trace.wave trace ~pin:6) : (char * int) list)
        ~scl_wire:
          (Firmware.Trace.runs (Firmware.Trace.input_wave trace ~pin:6)
           : (char * int) list)];
  [%expect
    {|
    ((scl_driven
      ((z 10) (0 8) (z 6) (0 4) (z 6) (0 4) (z 6) (0 4) (z 6) (0 4) (z 6)
       (0 4) (z 6) (0 4) (z 6) (0 4) (z 6) (0 4) (z 14) (0 4) (z 6) (0 4)
       (z 6) (0 4) (z 6) (0 4) (z 6) (0 4) (z 6) (0 4) (z 6) (0 4) (z 6)
       (0 4) (z 6) (0 4) (z 14) (0 4) (z 10)))
     (scl_wire
      ((0 1) (1 11) (0 8) (1 6) (0 4) (1 6) (0 4) (1 6) (0 4) (1 6) (0 4)
       (1 6) (0 4) (1 6) (0 4) (1 6) (0 4) (1 6) (0 12) (1 6) (0 4) (1 6)
       (0 4) (1 6) (0 4) (1 6) (0 4) (1 6) (0 4) (1 6) (0 4) (1 6) (0 4)
       (1 6) (0 4) (1 6) (0 12) (1 6) (0 4) (1 8))))
    |}];
  print_s
    [%sexp
      (List.filter (Firmware.Trace.regions trace) ~f:(fun r ->
         String.is_substring r.label ~substring:"ack")
       : Firmware.Region.t list)];
  [%expect
    {|
    (((label addr.ack.release) (operations 2) (cycles 4))
     ((label addr.ack.clock) (operations 3) (cycles 14))
     ((label w0.ack.release) (operations 2) (cycles 4))
     ((label w0.ack.clock) (operations 3) (cycles 14)))
    |}]
;;

(* --------------------------------------------------------------------------------------
   The cost of bit-banging the same frame
   -------------------------------------------------------------------------------------- *)

(* An independent 8N1 receiver: find the start edge, then read each bit at its centre.
   Deliberately not the transmitter's own state, so agreement is evidence. *)
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

(* The same descriptor the P2.7 hardware comparison uses, run in the model's own transfer
   engine, with an enabled idle line reading high. Built by an explicit recursion because
   [List.init] does not promise to apply its function in increasing order. *)
let engine_wave descriptor ~cycles =
  let rec go (state : Shift_engine.t) cycle acc =
    if cycle >= cycles
    then List.rev acc
    else (
      let state =
        Shift_engine.step
          state
          ~enable:true
          ~abort:false
          ~command:(if cycle = 0 then Some (descriptor, false) else None)
          ~start_event:false
          ~observed_edge:false
          ~pin_in:0
          ~occupied:0
          ~tx_valid:true
          ~rx_ready:true
      in
      let level =
        if not state.active then '1' else if state.pins land 1 <> 0 then '1' else '0'
      in
      go state (cycle + 1) (level :: acc))
  in
  String.of_char_list (go Shift_engine.idle 0 [])
;;

let%expect_test "a frame costs one descriptor or twenty-two operations, and decodes the \
                 same either way"
  =
  let byte = 0xa6 in
  let sequence =
    match Firmware_uart.tx_sequence ~pin:0 ~half_period:4 ~byte with
    | Ok sequence -> sequence
    | Error invalid -> raise_s [%message "" (invalid : Firmware.Invalid.t)]
  in
  let descriptor =
    match Firmware_uart.tx_8n1 ~pin:0 ~half_period:4 ~byte with
    | Ok descriptor -> descriptor
    | Error reason -> raise_s [%message "" (reason : Fault.Reject.t)]
  in
  let trace = run Firmware.Board.quiet (Ok sequence) in
  print_s
    [%message
      ""
        ~bit_banged_operations:(Firmware.operation_count sequence : int)
        ~descriptor_operations:
          (Firmware.operation_count
             { name = "configure"; steps = [ Do (Configure_transfer descriptor) ] }
           : int)
        ~bit_banged_decoded:
          (decode_8n1 (Firmware.Trace.wave trace ~pin:0) ~bit_cycles:8 : int option)
        ~engine_decoded:
          (decode_8n1 (engine_wave descriptor ~cycles:96) ~bit_cycles:8 : int option)];
  [%expect
    {|
    ((bit_banged_operations 22) (descriptor_operations 1)
     (bit_banged_decoded (166)) (engine_decoded (166)))
    |}]
;;

(* --------------------------------------------------------------------------------------
   Specified outcomes
   -------------------------------------------------------------------------------------- *)

let%expect_test "a target that stretches past the timeout reports a timeout" =
  let board = Firmware_i2c.Peer.board ~stretch_cycles:64 ~scl:6 ~sda:7 ~address:0x42 () in
  let trace =
    run
      board
      (Firmware_i2c.write_transaction
         ~stretch_timeout:6
         ~scl:6
         ~sda:7
         ~quarter_period:4
         ~address:0x42
         ~bytes:[ 0xa5 ]
         ())
  in
  show_summary trace;
  [%expect
    {|
    (((name i2c_write_0x42_x1) (operations 105) (cycles 228) (max_response 7)
      (samples 2))
     (outcome Completed))
    |}];
  print_s
    [%message
      ""
        ~latched:(Set.to_list trace.final.events.latched : Event.Kind.t list)
        ~faults:(trace.final.faults : Fault.t)];
  [%expect
    {|
    ((latched (Delay_expired Wait_complete Wait_timeout))
     (faults ((pin_ownership false) (fetch_invalid false) (fifo_fault false))))
    |}]
;;

(* No target at all: the pull-ups hold both lines high whenever the master releases them,
   so every acknowledge slot reads a one. A master that inferred the bus level from what
   it meant to drive would see an acknowledge here. *)
let%expect_test "an empty open-drain bus acknowledges nothing" =
  let trace =
    run
      (Firmware.Board.pulled_up ~lines:((1 lsl 6) lor (1 lsl 7)))
      (Firmware_i2c.write_transaction
         ~scl:6
         ~sda:7
         ~quarter_period:4
         ~address:0x42
         ~bytes:[ 0xa5 ]
         ())
  in
  print_s
    [%message
      ""
        ~outcome:(trace.outcome : Firmware.Outcome.t)
        ~acknowledges:(Firmware.Trace.samples trace ~name:"ack" : bool list)];
  [%expect {| ((outcome Completed) (acknowledges (true true))) |}]
;;

let%expect_test "an unaddressed target does not acknowledge and keeps nothing" =
  let board = Firmware_i2c.Peer.board ~scl:6 ~sda:7 ~address:0x42 () in
  let trace =
    run
      board
      (Firmware_i2c.write_transaction
         ~scl:6
         ~sda:7
         ~quarter_period:4
         ~address:0x21
         ~bytes:[ 0xa5 ]
         ())
  in
  print_s
    [%message
      ""
        ~acknowledges:(Firmware.Trace.samples trace ~name:"ack" : bool list)
        ~target_received:(trace.peer.received : int list)];
  [%expect {| ((acknowledges (true true)) (target_received (66))) |}]
;;

let%expect_test "a refused operation ends the run and names the reason" =
  let firmware =
    Firmware.create
      ~name:"write_into_an_engine_pin"
      [ At "claim"
      ; Do (Claim_pins { owner = Engine 0; mask = 0b0010 })
      ; At "intrude"
      ; Do (Write_pins (Pin_bank.Write.push_pull ~mask:0b0010 ~value:0b0010))
      ; At "unreached"
      ; Do (Wait_cycles { delay = 1 })
      ]
  in
  let trace = run Firmware.Board.quiet firmware in
  print_s [%sexp (trace.outcome : Firmware.Outcome.t)];
  [%expect
    {|
    (Refused (index 3) (label (intrude))
     (operation (Write_pins ((mask 2) (value 2) (output_enable 2))))
     (reason (Pin_owned (pin 1) (owner (Engine 0)))))
    |}];
  print_s [%message "" ~faults:(trace.final.faults : Fault.t)];
  [%expect {| (faults ((pin_ownership true) (fetch_invalid false) (fifo_fault false))) |}]
;;

let%expect_test "a blocking pop with nothing to drain it runs out of cycles" =
  let firmware =
    Firmware.create
      ~name:"blocking_pop"
      [ At "pop"; Do (Fifo_pop { fifo = Rx; blocking = Blocking }) ]
  in
  let trace = run ~max_cycles:32 Firmware.Board.quiet firmware in
  print_s [%sexp (trace.outcome : Firmware.Outcome.t)];
  [%expect {| (Out_of_cycles (index 1) (limit 32)) |}]
;;

(* --------------------------------------------------------------------------------------
   Sequence validation
   -------------------------------------------------------------------------------------- *)

let show_invalid result =
  print_s
    [%sexp
      (Result.map result ~f:(fun t -> t.Firmware.name)
       : (string, Firmware.Invalid.t) Result.t)]
;;

let%expect_test "a sequence that cannot be built says why" =
  show_invalid
    (Firmware.create ~name:"duplicate" [ At "loop"; Do Stop_periodic; At "loop" ]);
  [%expect {| (Error (Duplicate_label loop)) |}];
  show_invalid (Firmware.create ~name:"empty" []);
  [%expect {| (Error Empty) |}];
  show_invalid
    (Firmware.create ~name:"zero_delay" [ At "wait"; Do (Wait_cycles { delay = 0 }) ]);
  [%expect
    {|
    (Error
     (Invalid_operation (index 1) (operation (Wait_cycles (delay 0)))
      (reason Zero_delay)))
    |}];
  show_invalid
    (Firmware.create ~name:"bad_sample" [ At "read"; Sample { pin = 9; name = "miso" } ]);
  [%expect {| (Error (Invalid_sample (index 1) (pin 9))) |}];
  show_invalid (Firmware.create ~name:"unnamed" [ At ""; Do Stop_periodic ]);
  [%expect {| (Error (Unnamed_step 0)) |}];
  (* A half period of one cannot be bit-banged: two cycles a bit leaves nothing for the
     countdown between the two pin writes. *)
  show_invalid (Firmware_uart.tx_sequence ~pin:0 ~half_period:1 ~byte:0x55);
  [%expect {| (Error (Phase_too_short (label idle) (cycles 2))) |}];
  show_invalid (Firmware_uart.tx_sequence ~pin:0 ~half_period:4 ~byte:0x100);
  [%expect {| (Error (Out_of_range (what byte) (value 256))) |}];
  show_invalid
    (Firmware_spi.exchange
       ~sclk:1
       ~mosi:0
       ~miso:2
       ~half_period:2
       ~bit_count:8
       ~bit_order:Msb_first
       ~tx_value:0x5a
       ());
  [%expect {| (Error (Phase_too_short (label select) (cycles 2))) |}]
;;

(* --------------------------------------------------------------------------------------
   The recorded cost of the three helpers
   -------------------------------------------------------------------------------------- *)

(* One place to read off the operation counts and response latencies P1.3 asks to record.
   Every number is the floor: the runner offers one operation per edge and there is no
   fetch or decode yet, so P3.2 can only add to them. [max_response] is the largest
   [Record.cycles] in the run, which for these sequences is always a stall - a bit period,
   or an I2C target holding the clock. *)
let%expect_test "operation counts and response latency for each helper" =
  let uart =
    run Firmware.Board.quiet (Firmware_uart.tx_sequence ~pin:0 ~half_period:4 ~byte:0xa6)
  in
  let spi =
    run
      (Firmware_spi.Peer.board
         ~sclk:1
         ~miso:2
         ~bit_order:Msb_first
         ~bit_count:8
         ~value:0x3c)
      (Firmware_spi.exchange
         ~cs:3
         ~sclk:1
         ~mosi:0
         ~miso:2
         ~half_period:4
         ~bit_count:8
         ~bit_order:Msb_first
         ~tx_value:0x5a
         ())
  in
  let i2c =
    run
      (Firmware_i2c.Peer.board ~stretch_cycles:12 ~scl:6 ~sda:7 ~address:0x42 ())
      (Firmware_i2c.write_transaction
         ~scl:6
         ~sda:7
         ~quarter_period:4
         ~address:0x42
         ~bytes:[ 0xa5 ]
         ())
  in
  let show trace = print_s [%sexp (Firmware.Trace.summary trace : Firmware.Summary.t)] in
  show uart;
  show spi;
  show i2c;
  [%expect
    {|
    ((name uart_tx_8n1_0xa6) (operations 22) (cycles 88) (max_response 7)
     (samples 0))
    ((name spi_mode0_x8_0x5a) (operations 36) (cycles 72) (max_response 3)
     (samples 8))
    ((name i2c_write_0x42_x1) (operations 105) (cycles 224) (max_response 10)
     (samples 2))
    |}];
  (* A stretched acknowledge slot against an ordinary data bit slot, both in the same
     transaction: the difference is what the level wait bought. *)
  print_s
    [%sexp
      (List.filter (Firmware.Trace.regions i2c) ~f:(fun r ->
         List.mem
           [ "addr.b7.clock"; "addr.ack.clock"; "w0.b0.clock" ]
           r.label
           ~equal:String.equal)
       : Firmware.Region.t list)];
  [%expect
    {|
    (((label addr.b7.clock) (operations 3) (cycles 6))
     ((label addr.ack.clock) (operations 3) (cycles 14))
     ((label w0.b0.clock) (operations 3) (cycles 6)))
    |}];
  (* Where the stretched slot's extra cycles went: the level wait was accepted at once,
     then held the core until the target let the clock rise. *)
  print_s
    [%sexp
      (List.filter_map (Firmware.Trace.records i2c) ~f:(fun record ->
         match record.operation, record.label with
         | Operation.Wait_level _, Some "addr.ack.clock" ->
           Some
             ( Firmware.Record.accept_latency record
             , Firmware.Record.service_latency record
             , Firmware.Record.cycles record )
         | _ -> None)
       : (int * int * int) list)];
  [%expect {| ((0 9 10)) |}]
;;
