(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "test_cycle.ml" *)
(* P1.1: the cycle semantics of the reference machine, asserted edge by edge.

   Each test below covers one line of the phase plan's P1.1 list: command acceptance,
   parameter latching, commit edges, delays, wait arming, event and timeout precedence,
   set and acknowledge precedence, reset, disable, STOP, ABORT, idle-only single step, and
   the program store's shared port with latency-one reads, held output, and fetch
   validity.
*)

open! Core
open! Protemu_model
open! Harness

(* --------------------------------------------------------------------------------------
   Reset and disable
   -------------------------------------------------------------------------------------- *)

let%expect_test "reset releases the pins, clears status, and halts" =
  let t = create () in
  (* Drive something, then reset on top of it. *)
  let t =
    step t ~command:(Write_pins (Pin_bank.Write.push_pull ~mask:0b1111 ~value:0b1010))
  in
  show t;
  [%expect
    {|
    ((time 1) (exec Halted) (pin_out 10) (pin_oe 15) (waiting false) (ready true)
     (command (Accepted (Write_pins ((mask 15) (value 10) (output_enable 15)))))
     (events ()))
    |}];
  let t = step t ~request:Run in
  let t = reset t in
  show t;
  [%expect
    {|
    ((time 0) (exec Halted) (pin_out 0) (pin_oe 0) (waiting false) (ready true)
     (command Not_offered) (events ()))
    |}];
  show_status t;
  [%expect
    {|
    ((latched ()) (overflow ())
     (faults ((pin_ownership false) (fetch_invalid false) (fifo_fault false))))
    |}]
;;

let%expect_test "reset does not disturb the program store" =
  (* construction-plan.md section 4: reset validity and halt execution without bulk
     resetting RAM. A word written before reset is still there after it. *)
  let t = create () in
  let t = load t ~address:5 ~data:0x37 in
  let t = reset t in
  print_s [%sexp (Program_store.word t.store ~address:5 : int option)];
  [%expect {| (55) |}]
;;

let%expect_test "disabling aborts work in flight and releases the protocol pins" =
  let t = create ~program_depth:16 () in
  let t =
    List.foldi [ 0x11; 0x22 ] ~init:t ~f:(fun address t data -> load t ~address ~data)
  in
  let t =
    step t ~command:(Write_pins (Pin_bank.Write.push_pull ~mask:0b0011 ~value:0b0011))
  in
  let t = step t ~request:Run in
  let t = step t ~command:(Wait_cycles { delay = 10 }) in
  show t;
  [%expect
    {|
    ((time 5) (exec Running) (pin_out 3) (pin_oe 3) (waiting true) (ready false)
     (command (Accepted (Wait_cycles (delay 10)))) (events ()))
    |}];
  let t = step_disabled t in
  show t;
  [%expect
    {|
    ((time 6) (exec Halted) (pin_out 0) (pin_oe 0) (waiting false) (ready true)
     (command Not_offered) (events (Aborted)))
    |}];
  (* Latched status survives being disabled: disabling hides no evidence. *)
  show_status t;
  [%expect
    {|
    ((latched (Aborted)) (overflow ())
     (faults ((pin_ownership false) (fetch_invalid false) (fifo_fault false))))
    |}]
;;

(* --------------------------------------------------------------------------------------
   Command acceptance and parameter latching
   -------------------------------------------------------------------------------------- *)

let%expect_test "a timed command accepted at edge k with delay n fires at k + n" =
  let t = create () in
  let t = step t ~command:(Wait_cycles { delay = 3 }) in
  let accepted_at = t.time in
  show t;
  [%expect
    {|
    ((time 1) (exec Halted) (pin_out 0) (pin_oe 0) (waiting true) (ready false)
     (command (Accepted (Wait_cycles (delay 3)))) (events ()))
    |}];
  (* k+1 and k+2: still waiting, nothing set. *)
  let t = step t in
  show t;
  [%expect
    {|
    ((time 2) (exec Halted) (pin_out 0) (pin_oe 0) (waiting true) (ready false)
     (command Not_offered) (events ()))
    |}];
  let t = step t in
  show t;
  [%expect
    {|
    ((time 3) (exec Halted) (pin_out 0) (pin_oe 0) (waiting true) (ready false)
     (command Not_offered) (events ()))
    |}];
  (* k+3: exactly here. *)
  let t = step t in
  show t;
  [%expect
    {|
    ((time 4) (exec Halted) (pin_out 0) (pin_oe 0) (waiting false) (ready true)
     (command Not_offered) (events (Delay_expired)))
    |}];
  print_s [%message "" ~fired_after:(t.time - accepted_at : int)];
  [%expect {| (fired_after 3) |}]
;;

let%expect_test "zero delay is rejected" =
  let t = create () in
  let t = step t ~command:(Wait_cycles { delay = 0 }) in
  show_command t;
  [%expect {| (Rejected (command (Wait_cycles (delay 0))) (reason Zero_delay)) |}];
  (* And so is a zero timeout, which is a deadline measured the same way. *)
  let t = step t ~command:(Wait_level { pin = 0; level = true; timeout = Some 0 }) in
  show_command t;
  [%expect
    {|
    (Rejected (command (Wait_level (pin 0) (level true) (timeout (0))))
     (reason Zero_delay))
    |}]
;;

let%expect_test "ready is a Moore output, so the edge a wait finishes still refuses" =
  let t = create () in
  let t = step t ~command:(Wait_cycles { delay = 2 }) in
  let t = step t in
  (* The wait finishes at this edge. Ready was low before it, so a command offered here is
     refused and is not queued; the next edge accepts it. *)
  let t = step t ~command:Stop_periodic in
  show t;
  [%expect
    {|
    ((time 3) (exec Halted) (pin_out 0) (pin_oe 0) (waiting false) (ready true)
     (command (Rejected (command Stop_periodic) (reason Not_ready)))
     (events (Delay_expired)))
    |}];
  let t = step t ~command:Stop_periodic in
  show t;
  [%expect
    {|
    ((time 4) (exec Halted) (pin_out 0) (pin_oe 0) (waiting false) (ready true)
     (command (Accepted Stop_periodic)) (events ()))
    |}]
;;

let%expect_test "parameters are latched at acceptance, not read again later" =
  (* A descriptor accepted at one edge is held unchanged; later edges cannot alter it. *)
  let t = create () in
  let t = step t ~command:(Configure_transfer base_transfer) in
  let t = steps t ~n:5 in
  print_s [%sexp (Option.equal Transfer.equal t.descriptor (Some base_transfer) : bool)];
  [%expect {| true |}]
;;

(* --------------------------------------------------------------------------------------
   Waits: arming, immediate completion, and precedence
   -------------------------------------------------------------------------------------- *)

let%expect_test "a level wait completes immediately when the condition already holds" =
  let t = create () in
  (* Hold pin 2 high long enough for both synchronizer stages. *)
  let t = steps t ~n:3 ~pin_in:0b100 in
  let t =
    step t ~pin_in:0b100 ~command:(Wait_level { pin = 2; level = true; timeout = Some 5 })
  in
  show t;
  [%expect
    {|
    ((time 4) (exec Halted) (pin_out 0) (pin_oe 0) (waiting false) (ready true)
     (command (Accepted (Wait_level (pin 2) (level true) (timeout (5)))))
     (events ()))
    |}]
;;

let%expect_test "a level wait that must wait times out at its deadline" =
  let t = create () in
  let t = step t ~command:(Wait_level { pin = 2; level = true; timeout = Some 3 }) in
  let t = steps t ~n:2 in
  show t;
  [%expect
    {|
    ((time 3) (exec Halted) (pin_out 0) (pin_oe 0) (waiting true) (ready false)
     (command Not_offered) (events ()))
    |}];
  let t = step t in
  show t;
  [%expect
    {|
    ((time 4) (exec Halted) (pin_out 0) (pin_oe 0) (waiting false) (ready true)
     (command Not_offered) (events (Wait_timeout)))
    |}]
;;

let%expect_test "an edge wait ignores a stale edge and arms for the next one" =
  let t = create () in
  (* Produce a rising edge on pin 0 and let it reach the snapshot. *)
  let t = step t ~pin_in:0b1 in
  let t = step t ~pin_in:0b1 in
  (* The transition is in this snapshot right now. Arming here must not see it. *)
  let t =
    step t ~pin_in:0b1 ~command:(Wait_edge { pin = 0; edge = Rising; timeout = None })
  in
  show t;
  [%expect
    {|
    ((time 3) (exec Halted) (pin_out 0) (pin_oe 0) (waiting true) (ready false)
     (command (Accepted (Wait_edge (pin 0) (edge Rising) (timeout ()))))
     (events ()))
    |}];
  (* Holding the pin high forever never completes it: it armed for a transition. *)
  let t = steps t ~n:5 ~pin_in:0b1 in
  print_s [%message "" ~still_waiting:(Option.is_some t.wait : bool)];
  [%expect {| (still_waiting true) |}];
  (* A falling edge is not the one it armed for either. *)
  let t = steps t ~n:3 ~pin_in:0b0 in
  print_s [%message "" ~still_waiting:(Option.is_some t.wait : bool)];
  [%expect {| (still_waiting true) |}];
  (* A genuinely new rising edge completes it, two edges after the pad changes. *)
  let t = step t ~pin_in:0b1 in
  print_s [%message "" ~still_waiting:(Option.is_some t.wait : bool)];
  [%expect {| (still_waiting true) |}];
  let t = step t ~pin_in:0b1 in
  show t;
  [%expect
    {|
    ((time 13) (exec Halted) (pin_out 0) (pin_oe 0) (waiting false) (ready true)
     (command Not_offered) (events (Wait_complete)))
    |}]
;;

let%expect_test "a matching event and an expiring timeout at the same edge: the event \
                 wins"
  =
  let t = create () in
  (* Accepted at edge 1 with timeout 3, so the deadline is edge 4. The synchronizer takes
     two edges, so driving the pin from edge 3 makes the level first visible at edge 4:
     exactly the deadline. *)
  let t = step t ~command:(Wait_level { pin = 1; level = true; timeout = Some 3 }) in
  let t = steps t ~n:1 in
  let t = step t ~pin_in:0b10 in
  print_s [%message "" ~time:(t.time : int) ~waiting:(Option.is_some t.wait : bool)];
  [%expect {| ((time 3) (waiting true)) |}];
  let t = step t ~pin_in:0b10 in
  show t;
  [%expect
    {|
    ((time 4) (exec Halted) (pin_out 0) (pin_oe 0) (waiting false) (ready true)
     (command Not_offered) (events (Wait_complete)))
    |}];
  (* Wait_complete, and no Wait_timeout, although the deadline was this same edge. *)
  show_status t;
  [%expect
    {|
    ((latched (Wait_complete)) (overflow ())
     (faults ((pin_ownership false) (fetch_invalid false) (fifo_fault false))))
    |}]
;;

(* --------------------------------------------------------------------------------------
   Latched status: set-wins and overflow
   -------------------------------------------------------------------------------------- *)

let%expect_test "set wins over acknowledge in the same cycle" =
  (* A tick every edge gives a new occurrence at the same edge an acknowledgement arrives,
     which is the only way to exercise the rule. *)
  let t = create () in
  let t = step t ~command:(Start_periodic { period = 1 }) in
  let t = step t in
  show_status t;
  [%expect
    {|
    ((latched (Tick)) (overflow ())
     (faults ((pin_ownership false) (fetch_invalid false) (fifo_fault false))))
    |}];
  (* Acknowledge at an edge that also produces a new occurrence. The bit stays set: the
     acknowledgement was aimed at the one already seen. *)
  let t = step t ~acknowledge:[ Tick ] in
  print_s [%message "" ~this_edge:(t.last.events : Event.Kind.t list)];
  [%expect {| (this_edge (Tick)) |}];
  show_status t;
  [%expect
    {|
    ((latched (Tick)) (overflow ())
     (faults ((pin_ownership false) (fetch_invalid false) (fifo_fault false))))
    |}];
  (* Stop the generator; now the same acknowledgement clears it. *)
  let t = step t ~command:Stop_periodic in
  let t = step t ~acknowledge:[ Tick ] in
  show_status t;
  [%expect
    {|
    ((latched ()) (overflow ())
     (faults ((pin_ownership false) (fetch_invalid false) (fifo_fault false))))
    |}]
;;

let%expect_test "a lost occurrence is recorded as overflow, not counted" =
  let t = create () in
  (* A tick every edge, never acknowledged: the second one lands on a set bit. *)
  let t = step t ~command:(Start_periodic { period = 1 }) in
  let t = steps t ~n:3 in
  show_status t;
  [%expect
    {|
    ((latched (Tick)) (overflow (Tick))
     (faults ((pin_ownership false) (fetch_invalid false) (fifo_fault false))))
    |}];
  (* Acknowledging clears both the latch and its overflow marker. *)
  let t = step t ~command:Stop_periodic in
  let t = step t ~acknowledge:[ Tick ] in
  show_status t;
  [%expect
    {|
    ((latched ()) (overflow ())
     (faults ((pin_ownership false) (fetch_invalid false) (fifo_fault false))))
    |}]
;;

(* --------------------------------------------------------------------------------------
   Waits stall control, not engines
   -------------------------------------------------------------------------------------- *)

let%expect_test "a periodic tick keeps running while the core is stalled" =
  let t = create () in
  let t = step t ~command:(Start_periodic { period = 2 }) in
  let t = step t ~command:(Wait_cycles { delay = 20 }) in
  let ticks =
    List.folding_map (List.init 6 ~f:Fn.id) ~init:t ~f:(fun t _ ->
      let t = step t in
      t, (List.mem t.last.events Tick ~equal:Event.Kind.equal, Option.is_some t.wait))
  in
  print_s [%message "" ~tick_and_still_stalled:(ticks : (bool * bool) list)];
  [%expect
    {|
    (tick_and_still_stalled
     ((true true) (false true) (true true) (false true) (true true) (false true)))
    |}]
;;

(* --------------------------------------------------------------------------------------
   The program store's shared port
   -------------------------------------------------------------------------------------- *)

let%expect_test "a fetch reads through one latency-one port" =
  let t = create ~program_depth:16 () in
  let t = load t ~address:0 ~data:0x11 in
  let t = load t ~address:1 ~data:0x22 in
  let t = step t ~request:Run in
  (* The RUN edge issues the read at address 0; its data is consumed at the next edge. *)
  print_s [%sexp (t.last.port : Program_store.Port.t)];
  [%expect {| ((enable true) (write_enable false) (address 0) (write_data 0)) |}];
  print_s [%sexp (t.last.fetched : Program_store.Word.t option)];
  [%expect {| () |}];
  let t = step t in
  print_s [%sexp (t.last.fetched : Program_store.Word.t option)];
  [%expect {| ((Specified 17)) |}];
  let t = step t in
  print_s [%sexp (t.last.fetched : Program_store.Word.t option)];
  [%expect {| ((Specified 34)) |}]
;;

let%expect_test "an unspecified word is never accepted as an instruction" =
  (* Address 2 was never written, so the contract leaves the read result unspecified. It
     must raise the sticky fetch fault and halt, not become an instruction. *)
  let t = create ~program_depth:16 () in
  let t = load t ~address:0 ~data:0x11 in
  let t = load t ~address:1 ~data:0x22 in
  let t = step t ~request:Run in
  let t = steps t ~n:3 in
  print_s [%sexp (t.last.fetched : Program_store.Word.t option)];
  [%expect {| (Unspecified) |}];
  show t;
  [%expect
    {|
    ((time 6) (exec Halted) (pin_out 0) (pin_oe 0) (waiting false) (ready true)
     (command Not_offered) (events (Fault)))
    |}];
  show_status t;
  [%expect
    {|
    ((latched (Fault)) (overflow ())
     (faults ((pin_ownership false) (fetch_invalid true) (fifo_fault false))))
    |}]
;;

let%expect_test "the store output holds while the port is disabled" =
  let t = create ~program_depth:16 () in
  let t = load t ~address:0 ~data:0x44 in
  (* One single step issues exactly one read, of address 0, and then the port goes idle. *)
  let t = step t ~request:Step in
  let t = step t in
  let held = t.store.read_data in
  print_s [%message "" ~fetched:(t.last.fetched : Program_store.Word.t option)];
  [%expect {| (fetched ((Specified 68))) |}];
  (* Four idle edges later the output register still has it. *)
  let t = steps t ~n:4 in
  print_s
    [%message
      ""
        ~held:(held : Program_store.Word.t)
        ~still:(t.store.read_data : Program_store.Word.t)
        ~port_idle:(not t.last.port.enable : bool)];
  [%expect {| ((held (Specified 68)) (still (Specified 68)) (port_idle true)) |}]
;;

let%expect_test "a program write is refused while running and never reaches the port" =
  let t = create ~program_depth:16 () in
  let t = load t ~address:0 ~data:0x11 in
  let t = step t ~request:Run in
  let t = step t ~load:{ address = 0; data = 0x99 } in
  print_s
    [%message
      ""
        ~load:(t.last.load : (unit, Fault.Reject.t) Result.t option)
        ~port_wrote:(t.last.port.write_enable : bool)
        ~word:(Program_store.word t.store ~address:0 : int option)];
  [%expect {| ((load ((Error Not_halted))) (port_wrote false) (word (17))) |}]
;;

(* --------------------------------------------------------------------------------------
   Execution control: STOP, ABORT, single step
   -------------------------------------------------------------------------------------- *)

let%expect_test "STOP halts at an instruction boundary" =
  let t = create ~program_depth:16 () in
  let t =
    List.foldi [ 0x11; 0x22; 0x33; 0x44 ] ~init:t ~f:(fun address t data ->
      load t ~address ~data)
  in
  let t = step t ~request:Run in
  (* Stall the core on a long wait, so an instruction is genuinely in progress. *)
  let t = step t ~command:(Wait_cycles { delay = 6 }) in
  let t = step t ~request:Stop in
  (* STOP is accepted but does not take effect yet: the instruction has not finished, the
     pins are untouched, and the wait is still running. *)
  show t;
  [%expect
    {|
    ((time 7) (exec Stopping) (pin_out 0) (pin_oe 0) (waiting true) (ready false)
     (command Not_offered) (events ()))
    |}];
  let t = steps t ~n:4 in
  print_s
    [%message "" ~exec:(t.exec : Machine.Exec.t) ~waiting:(Option.is_some t.wait : bool)];
  [%expect {| ((exec Stopping) (waiting true)) |}];
  (* The wait finishes: that is the boundary, and the core halts there. *)
  let t = step t in
  show t;
  [%expect
    {|
    ((time 12) (exec Halted) (pin_out 0) (pin_oe 0) (waiting false) (ready true)
     (command Not_offered) (events (Delay_expired)))
    |}];
  print_s [%sexp (t.last.port : Program_store.Port.t)];
  [%expect {| ((enable false) (write_enable false) (address 0) (write_data 0)) |}]
;;

let%expect_test "ABORT releases the pins promptly and reports the work incomplete" =
  let t = create ~program_depth:16 () in
  let t = load t ~address:0 ~data:0x11 in
  let t =
    step t ~command:(Write_pins (Pin_bank.Write.push_pull ~mask:0b1111 ~value:0b1001))
  in
  let t = step t ~request:Run in
  let t = step t ~command:(Wait_cycles { delay = 20 }) in
  show t;
  [%expect
    {|
    ((time 4) (exec Running) (pin_out 9) (pin_oe 15) (waiting true) (ready false)
     (command (Accepted (Wait_cycles (delay 20)))) (events ()))
    |}];
  let t = step t ~request:Abort in
  show t;
  [%expect
    {|
    ((time 5) (exec Halted) (pin_out 0) (pin_oe 0) (waiting false) (ready true)
     (command Not_offered) (events (Aborted)))
    |}]
;;

let%expect_test "a command offered at the same edge as ABORT is refused" =
  let t = create () in
  let t = step t ~request:Run in
  let t =
    step
      t
      ~request:Abort
      ~command:(Write_pins (Pin_bank.Write.push_pull ~mask:0b1 ~value:0b1))
  in
  show t;
  [%expect
    {|
    ((time 2) (exec Halted) (pin_out 0) (pin_oe 0) (waiting false) (ready true)
     (command
      (Rejected (command (Write_pins ((mask 1) (value 1) (output_enable 1))))
       (reason Aborting)))
     (events (Aborted)))
    |}]
;;

let%expect_test "single step runs one instruction, and only with engines idle" =
  let t = create ~program_depth:16 () in
  let t =
    List.foldi [ 0xa1; 0xa2 ] ~init:t ~f:(fun address t data -> load t ~address ~data)
  in
  let t = step t ~request:Step in
  show t;
  [%expect
    {|
    ((time 3) (exec Stepping) (pin_out 0) (pin_oe 0) (waiting false) (ready true)
     (command Not_offered) (events ()))
    |}];
  let t = step t in
  print_s
    [%message
      ""
        ~fetched:(t.last.fetched : Program_store.Word.t option)
        ~exec:(t.exec : Machine.Exec.t)];
  [%expect {| ((fetched ((Specified 161))) (exec Halted)) |}];
  (* With an engine holding pins, a step is refused. *)
  let t = step t ~command:(Claim_pins { owner = Engine 0; mask = 0b0011 }) in
  let t = step t ~request:Step in
  print_s
    [%message
      ""
        ~request:(t.last.request : (unit, Fault.Reject.t) Result.t option)
        ~exec:(t.exec : Machine.Exec.t)];
  [%expect {| ((request ((Error Engines_not_idle))) (exec Halted)) |}]
;;
