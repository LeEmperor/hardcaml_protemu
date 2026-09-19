(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "test_mechanisms.ml" *)
(* P1.2: the typed mechanism interfaces - pin operations, timing requests, transfer
   descriptors, events, and queue operations - with their validation, ownership, blocking
   behaviour, and refusal results.

   The phase plan asks for two things here: legal examples that run, and invalid
   descriptors, conflicts, zero delays and queue boundary cases that produce specified
   outcomes. "Specified" is the point of the expect blocks: each one pins down which
   reason is reported, not merely that something was refused.
*)

open! Core
open! Protemu_model
open! Harness

(* --------------------------------------------------------------------------------------
   Pin commits
   -------------------------------------------------------------------------------------- *)

let%expect_test "a masked write commits value and enable together and preserves the rest" =
  let t = create () in
  let t =
    step t ~command:(Write_pins (Pin_bank.Write.push_pull ~mask:0b1111 ~value:0b1010))
  in
  print_s [%message "" ~out:(t.pins.value : int) ~oe:(t.pins.output_enable : int)];
  [%expect {| ((out 10) (oe 15)) |}];
  (* Touch only pins 4 and 5. Pins 0 to 3 keep both their value and their enable. *)
  let t =
    step t ~command:(Write_pins (Pin_bank.Write.push_pull ~mask:0b110000 ~value:0b100000))
  in
  print_s [%message "" ~out:(t.pins.value : int) ~oe:(t.pins.output_enable : int)];
  [%expect {| ((out 42) (oe 63)) |}]
;;

let%expect_test "open drain drives low or releases, never high" =
  let t = create () in
  (* Pins 6 and 7 are an I2C-shaped pair: pin 6 held low, pin 7 released to the pull-up. *)
  let t =
    step
      t
      ~command:
        (Write_pins (Pin_bank.Write.open_drain ~mask:0b11000000 ~drive_low:0b01000000))
  in
  print_s [%message "" ~out:(t.pins.value : int) ~oe:(t.pins.output_enable : int)];
  [%expect {| ((out 0) (oe 64)) |}];
  (* No masked pin is ever driven to a one. *)
  print_s [%sexp (t.pins.value land t.pins.output_enable = 0 : bool)];
  [%expect {| true |}]
;;

let%expect_test "an out-of-range pin mask is refused" =
  let t = create () in
  let t =
    step t ~command:(Write_pins { mask = 0b1_0000_0000; value = 0; output_enable = 0 })
  in
  show_command t;
  [%expect
    {|
    (Rejected (command (Write_pins ((mask 256) (value 0) (output_enable 0))))
     (reason (Pin_out_of_range 8)))
    |}]
;;

(* --------------------------------------------------------------------------------------
   Ownership
   -------------------------------------------------------------------------------------- *)

let%expect_test "a software write into an engine's pin is refused and raises a sticky \
                 fault"
  =
  let t = create () in
  let t = step t ~command:(Claim_pins { owner = Engine 0; mask = 0b0110 }) in
  show_command t;
  [%expect {| (Accepted (Claim_pins (owner (Engine 0)) (mask 6))) |}];
  let t =
    step t ~command:(Write_pins (Pin_bank.Write.push_pull ~mask:0b0010 ~value:0b0010))
  in
  show_command t;
  [%expect
    {|
    (Rejected (command (Write_pins ((mask 2) (value 2) (output_enable 2))))
     (reason (Pin_owned (pin 1) (owner (Engine 0)))))
    |}];
  show_status t;
  [%expect
    {|
    ((latched (Fault)) (overflow ())
     (faults ((pin_ownership true) (fetch_invalid false) (fifo_fault false))))
    |}];
  (* Pins outside the claim are still writable. *)
  let t =
    step t ~command:(Write_pins (Pin_bank.Write.push_pull ~mask:0b1001 ~value:0b1001))
  in
  print_s
    [%message
      "" ~command:(t.last.command : Machine.Command_result.t) ~out:(t.pins.value : int)];
  [%expect
    {|
    ((command (Accepted (Write_pins ((mask 9) (value 9) (output_enable 9)))))
     (out 9))
    |}];
  (* Releasing hands them back. *)
  let t = step t ~command:(Release_pins { owner = Engine 0; mask = 0b0110 }) in
  let t =
    step t ~command:(Write_pins (Pin_bank.Write.push_pull ~mask:0b0010 ~value:0b0010))
  in
  print_s
    [%message
      "" ~command:(t.last.command : Machine.Command_result.t) ~out:(t.pins.value : int)];
  [%expect
    {|
    ((command (Accepted (Write_pins ((mask 2) (value 2) (output_enable 2)))))
     (out 11))
    |}]
;;

let%expect_test "two engines cannot claim the same pin" =
  let t = create () in
  let t = step t ~command:(Claim_pins { owner = Engine 0; mask = 0b0011 }) in
  let t = step t ~command:(Claim_pins { owner = Engine 1; mask = 0b0110 }) in
  show_command t;
  [%expect
    {|
    (Rejected (command (Claim_pins (owner (Engine 1)) (mask 6)))
     (reason (Pin_owned (pin 1) (owner (Engine 0)))))
    |}];
  (* The non-overlapping part is not silently granted: the whole claim is refused. *)
  print_s [%sexp (Pin_bank.owner_of t.pins ~pin:2 : Kinds.Owner.t option)];
  [%expect {| () |}]
;;

let%expect_test "releasing a pin an owner does not hold is refused" =
  let t = create () in
  let t = step t ~command:(Claim_pins { owner = Engine 0; mask = 0b0001 }) in
  let t = step t ~command:(Release_pins { owner = Engine 1; mask = 0b0001 }) in
  show_command t;
  [%expect
    {|
    (Rejected (command (Release_pins (owner (Engine 1)) (mask 1)))
     (reason (Pin_not_owned (pin 0) (claimed_by ((Engine 0))))))
    |}]
;;

(* --------------------------------------------------------------------------------------
   Transfer descriptors
   -------------------------------------------------------------------------------------- *)

let%expect_test "a legal descriptor validates and is latched unchanged" =
  show_validation base_transfer;
  [%expect {| (Ok ()) |}];
  let t = create () in
  let t = step t ~command:(Configure_transfer base_transfer) in
  print_s
    [%message
      ""
        ~command:(t.last.command : Machine.Command_result.t)
        ~latched:(Option.equal Transfer.equal t.descriptor (Some base_transfer) : bool)];
  [%expect
    {|
    ((command
      (Accepted
       (Configure_transfer
        ((direction Tx_only) (bit_count 8) (bit_order Lsb_first) (tx_value 90)
         (output_pin (0)) (input_pin ()) (clock_pin (1)) (idle_output true)
         (idle_clock false) (initial_delay ()) (launch On_falling)
         (sample On_rising) (pacing (Internal (half_period 4)))))))
     (latched true))
    |}]
;;

let%expect_test "bit counts outside 1..32 are refused" =
  show_validation { base_transfer with bit_count = 0 };
  [%expect {| (Error (Bit_count_out_of_range 0)) |}];
  show_validation { base_transfer with bit_count = 33 };
  [%expect {| (Error (Bit_count_out_of_range 33)) |}];
  (* The bounds themselves are legal. *)
  show_validation { base_transfer with bit_count = 1; tx_value = 1 };
  [%expect {| (Ok ()) |}];
  show_validation { base_transfer with bit_count = 32; tx_value = 0xffff_ffff };
  [%expect {| (Ok ()) |}]
;;

let%expect_test "a preload wider than the transfer is refused" =
  show_validation { base_transfer with bit_count = 4; tx_value = 0x1f };
  [%expect {| (Error (Data_out_of_range 31)) |}]
;;

let%expect_test "launching and sampling on the same edge is an impossible phase \
                 combination"
  =
  show_validation { base_transfer with launch = On_rising; sample = On_rising };
  [%expect {| (Error (Launch_equals_sample On_rising)) |}]
;;

let%expect_test "a pin may carry only one role, except a half-duplex data wire" =
  (* Clock on the data pin: refused. *)
  show_validation { base_transfer with clock_pin = Some 0 };
  [%expect {| (Error (Duplicate_pin (pin 0) (first Output) (second Clock))) |}];
  (* Drive and sample the same wire: the open-drain case the construction plan requires. *)
  show_validation
    { base_transfer with direction = Duplex; output_pin = Some 0; input_pin = Some 0 };
  [%expect {| (Ok ()) |}]
;;

let%expect_test "a lane cannot both generate and follow a clock" =
  show_validation
    { base_transfer with
      pacing = Transfer.Pacing.Observed_edge { pin = 3; edge = Rising }
    };
  [%expect {| (Error (Unexpected_pin Clock)) |}];
  (* Without a generated clock pin it is legal: this is the target-mode shape. *)
  show_validation
    { base_transfer with
      clock_pin = None
    ; pacing = Transfer.Pacing.Observed_edge { pin = 3; edge = Rising }
    };
  [%expect {| (Ok ()) |}]
;;

let%expect_test "direction decides which pins are required and which are refused" =
  show_validation { base_transfer with direction = Rx_only };
  [%expect {| (Error (Missing_pin Input)) |}];
  show_validation { base_transfer with direction = Tx_only; output_pin = None };
  [%expect {| (Error (Missing_pin Output)) |}];
  show_validation { base_transfer with direction = Duplex; input_pin = None };
  [%expect {| (Error (Missing_pin Input)) |}]
;;

let%expect_test "a zero initial delay and a zero half period are refused" =
  show_validation { base_transfer with initial_delay = Some 0 };
  [%expect {| (Error Zero_delay) |}];
  show_validation
    { base_transfer with pacing = Transfer.Pacing.Internal { half_period = 0 } };
  [%expect {| (Error (Half_period_out_of_range 0)) |}]
;;

let%expect_test "an out-of-range pin is refused" =
  show_validation { base_transfer with output_pin = Some 8 };
  [%expect {| (Error (Pin_out_of_range 8)) |}]
;;

(* --------------------------------------------------------------------------------------
   Queue boundaries
   -------------------------------------------------------------------------------------- *)

let%expect_test "a nonblocking push into a full queue is refused, and does not disturb it"
  =
  let t = create ~fifo_depth:2 () in
  let push data blocking = Operation.Fifo_push { fifo = Tx; data; blocking } in
  let t = step t ~command:(push 0x11 Nonblocking) in
  let t = step t ~command:(push 0x22 Nonblocking) in
  let t = step t ~command:(push 0x33 Nonblocking) in
  print_s
    [%message
      ""
        ~command:(t.last.command : Machine.Command_result.t)
        ~occupancy:(Fifo.occupancy t.tx_fifo : int)
        ~waiting:(Option.is_some t.wait : bool)];
  [%expect
    {|
    ((command
      (Rejected (command (Fifo_push (fifo Tx) (data 51) (blocking Nonblocking)))
       (reason (Fifo_full Tx))))
     (occupancy 2) (waiting false))
    |}]
;;

let%expect_test "a blocking push into a full queue stalls the core until a pop frees a \
                 slot"
  =
  let t = create ~fifo_depth:2 () in
  let push data blocking = Operation.Fifo_push { fifo = Tx; data; blocking } in
  let t = step t ~command:(push 0x11 Nonblocking) in
  let t = step t ~command:(push 0x22 Nonblocking) in
  let t = step t ~command:(push 0x33 Blocking) in
  print_s
    [%message
      ""
        ~command:(t.last.command : Machine.Command_result.t)
        ~waiting:(Option.is_some t.wait : bool)
        ~ready:(Machine.command_ready t : bool)];
  [%expect
    {|
    ((command (Accepted (Fifo_push (fifo Tx) (data 51) (blocking Blocking))))
     (waiting true) (ready false))
    |}];
  (* It stays stalled while the queue is full, and further commands are refused. *)
  let t = step t ~command:Stop_periodic in
  print_s [%message "" ~command:(t.last.command : Machine.Command_result.t)];
  [%expect {| (command (Rejected (command Stop_periodic) (reason Not_ready))) |}]
;;

let%expect_test "ABORT is the way out of a blocked queue operation, and it is recorded" =
  (* Nothing in this phase drains a queue: the transfer engine that would is P2.5 and the
     host data-queue port is P3.4. So a blocking operation stays blocked, and the only
     documented escape is ABORT, reset, or disabling the design. That is a safe abort
     result, not a hang: the core releases, and the sticky queue fault records that an
     operation was abandoned part way. *)
  let t = create ~fifo_depth:1 () in
  let t =
    step t ~command:(Fifo_push { fifo = Tx; data = 0x11; blocking = Nonblocking })
  in
  let t = step t ~command:(Fifo_push { fifo = Tx; data = 0x22; blocking = Blocking }) in
  let t = steps t ~n:5 in
  print_s [%message "" ~still_blocked:(Option.is_some t.wait : bool)];
  [%expect {| (still_blocked true) |}];
  let t = step t ~request:Abort in
  print_s
    [%message
      ""
        ~blocked:(Option.is_some t.wait : bool)
        ~events:(t.last.events : Event.Kind.t list)];
  [%expect {| ((blocked false) (events (Aborted Fault))) |}];
  show_status t;
  [%expect
    {|
    ((latched (Aborted Fault)) (overflow ())
     (faults ((pin_ownership false) (fetch_invalid false) (fifo_fault true))))
    |}]
;;

let%expect_test "a nonblocking pop from an empty queue is refused" =
  let t = create ~fifo_depth:2 () in
  let t = step t ~command:(Fifo_pop { fifo = Rx; blocking = Nonblocking }) in
  print_s
    [%message
      ""
        ~command:(t.last.command : Machine.Command_result.t)
        ~popped:(t.last.popped : int option)];
  [%expect
    {|
    ((command
      (Rejected (command (Fifo_pop (fifo Rx) (blocking Nonblocking)))
       (reason (Fifo_empty Rx))))
     (popped ()))
    |}]
;;

let%expect_test "a pop returns the oldest word and frees exactly one slot" =
  let t = create ~fifo_depth:4 () in
  let t =
    List.fold [ 0x11; 0x22; 0x33 ] ~init:t ~f:(fun t data ->
      step t ~command:(Fifo_push { fifo = Tx; data; blocking = Nonblocking }))
  in
  let t = step t ~command:(Fifo_pop { fifo = Tx; blocking = Nonblocking }) in
  print_s
    [%message
      ""
        ~popped:(t.last.popped : int option)
        ~occupancy:(Fifo.occupancy t.tx_fifo : int)
        ~next:(Fifo.peek t.tx_fifo : int option)];
  [%expect {| ((popped (17)) (occupancy 2) (next (34))) |}]
;;

let%expect_test "a simultaneous push and pop on a full queue keeps order and occupancy" =
  (* The queue primitive supports both at one edge even though the command port issues one
     operation at a time; P2.4 and the engines use this form. *)
  let push_exn queue data =
    Fifo.push queue data
    |> Result.map_error ~f:(fun reason ->
      Error.create_s [%sexp (reason : Fault.Reject.t)])
    |> ok_exn
  in
  let queue = Fifo.create ~id:Tx ~depth:2 in
  let queue = push_exn queue 0x11 in
  let queue = push_exn queue 0x22 in
  let queue, popped, push, pop = Fifo.step queue ~push:(Some 0x33) ~pop:true in
  print_s
    [%message
      ""
        ~popped:(popped : int option)
        ~push:(push : (unit, Fault.Reject.t) Result.t option)
        ~pop:(pop : (unit, Fault.Reject.t) Result.t option)
        ~occupancy:(Fifo.occupancy queue : int)
        ~oldest:(Fifo.peek queue : int option)];
  [%expect
    {| ((popped (17)) (push ((Ok ()))) (pop ((Ok ()))) (occupancy 2) (oldest (34))) |}]
;;

let%expect_test "a queue word wider than a byte is refused" =
  let t = create () in
  let t =
    step t ~command:(Fifo_push { fifo = Tx; data = 0x100; blocking = Nonblocking })
  in
  show_command t;
  [%expect
    {|
    (Rejected (command (Fifo_push (fifo Tx) (data 256) (blocking Nonblocking)))
     (reason (Data_out_of_range 256)))
    |}]
;;
