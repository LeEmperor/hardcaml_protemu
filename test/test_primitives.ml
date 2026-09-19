open! Core
open! Hardcaml
open! Hardcaml_protemu

let bits width n = Bits.of_int_trunc ~width n
let check label signal expected =
  [%test_result: int] ~message:label ~expect:expected (Bits.to_int_trunc !signal)
;;

module Pin_sim = Cyclesim.With_interface (Pin_bank.I) (Pin_bank.O)
module Event_sim = Cyclesim.With_interface (Input_events.I) (Input_events.O)
module Timing_sim = Cyclesim.With_interface (Timing.I) (Timing.O)
module Fifo_sim = Cyclesim.With_interface (Byte_fifo.I) (Byte_fifo.O)

let%test_unit "P2.1 masked commits, claims, conflict, and release" =
  let sim = Pin_sim.create (Pin_bank.create (Scope.create ~flatten_design:true ())) in
  let i = Cyclesim.inputs sim in
  let o = Cyclesim.outputs sim in
  i.reset_i := Bits.vdd;
  i.enable_i := Bits.vdd;
  Cyclesim.cycle sim;
  i.reset_i := Bits.gnd;
  i.write_valid_i := Bits.vdd;
  i.write_mask_i := bits 8 0x0f;
  i.write_value_i := bits 8 0x05;
  i.write_oe_i := bits 8 0x0f;
  Cyclesim.cycle sim;
  check "initial value" o.pins_o 0x05;
  check "initial enable" o.pin_oe_o 0x0f;
  i.write_mask_i := bits 8 0xf0;
  i.write_value_i := bits 8 0xa0;
  i.write_oe_i := bits 8 0x50;
  Cyclesim.cycle sim;
  check "masked value" o.pins_o 0xa5;
  check "masked enable" o.pin_oe_o 0x5f;
  i.write_valid_i := Bits.gnd;
  i.claim_valid_i := Bits.vdd;
  i.claim_engine_i := Bits.vdd;
  i.claim_mask_i := bits 8 0x20;
  Cyclesim.cycle sim;
  check "engine claim" o.engine_claim_o 0x20;
  i.claim_valid_i := Bits.gnd;
  i.write_valid_i := Bits.vdd;
  i.write_mask_i := bits 8 0x30;
  Cyclesim.cycle sim;
  check "conflicting write rejected" o.rejected_o 1;
  check "conflict sticks" o.conflict_o 1;
  check "atomic refusal" o.pins_o 0xa5;
  i.write_valid_i := Bits.gnd;
  i.abort_i := Bits.vdd;
  Cyclesim.cycle sim;
  check "abort releases" o.pin_oe_o 0;
  check "abort drops claim" o.engine_claim_o 0
;;

let%test_unit "P2.2 synchronizer, set-wins acknowledge, and overflow" =
  let sim = Event_sim.create (Input_events.create (Scope.create ~flatten_design:true ())) in
  let i = Cyclesim.inputs sim in
  let o = Cyclesim.outputs sim in
  i.reset_i := Bits.vdd;
  Cyclesim.cycle sim;
  i.reset_i := Bits.gnd;
  i.pin_in_i := bits 8 1;
  Cyclesim.cycle sim;
  check "first stage hidden" o.snapshot_o 0;
  Cyclesim.cycle sim;
  check "snapshot" o.snapshot_o 1;
  check "single rise" o.rising_o 1;
  Cyclesim.cycle sim;
  check "rise clears" o.rising_o 0;
  i.event_set_i := bits 6 1;
  Cyclesim.cycle sim;
  check "event latches" o.event_o 1;
  Cyclesim.cycle sim;
  check "repeated event overflows" o.overflow_o 1;
  i.event_ack_i := bits 6 1;
  Cyclesim.cycle sim;
  check "set wins ack" o.event_o 1;
  check "ack clears overflow" o.overflow_o 0;
  i.event_set_i := Bits.zero 6;
  Cyclesim.cycle sim;
  check "ack clears status" o.event_o 0
;;

let%test_unit "P2.3 exact delay, immediate level, stale edge, and timeout precedence" =
  let sim = Timing_sim.create (Timing.create (Scope.create ~flatten_design:true ())) in
  let i = Cyclesim.inputs sim in
  let o = Cyclesim.outputs sim in
  i.reset_i := Bits.vdd;
  i.enable_i := Bits.vdd;
  Cyclesim.cycle sim;
  i.reset_i := Bits.gnd;
  i.wait_valid_i := Bits.vdd;
  i.wait_delay_i := bits 16 3;
  Cyclesim.cycle sim;
  check "accepted" o.busy_o 1;
  i.wait_valid_i := Bits.gnd;
  Cyclesim.cycle sim;
  check "k+1" o.remaining_o 2;
  Cyclesim.cycle sim;
  check "k+2" o.remaining_o 1;
  Cyclesim.cycle sim;
  check "k+3" o.complete_o 1;
  i.wait_kind_i := bits 2 1;
  i.wait_level_i := Bits.vdd;
  i.snapshot_i := bits 8 1;
  i.wait_valid_i := Bits.vdd;
  Cyclesim.cycle sim;
  check "level immediate has no delayed event" o.complete_o 0;
  check "no level stall" o.busy_o 0;
  i.wait_kind_i := bits 2 2;
  i.wait_timeout_enable_i := Bits.vdd;
  i.wait_delay_i := bits 16 1;
  i.rising_i := bits 8 1;
  Cyclesim.cycle sim;
  check "old edge does not finish" o.busy_o 1;
  i.wait_valid_i := Bits.gnd;
  Cyclesim.cycle sim;
  check "new edge beats timeout" o.complete_o 1;
  check "not timeout" o.timeout_o 0;
  i.wait_valid_i := Bits.vdd;
  i.rising_i := Bits.zero 8;
  Cyclesim.cycle sim;
  i.wait_valid_i := Bits.gnd;
  Cyclesim.cycle sim;
  check "timeout without event" o.timeout_o 1;
  i.wait_valid_i := Bits.vdd;
  i.wait_kind_i := bits 2 0;
  i.wait_delay_i := Bits.zero 16;
  Cyclesim.cycle sim;
  check "zero rejected" o.rejected_o 1
;;

let%test_unit "P2.4 full simultaneous pop/push preserves byte order" =
  let sim = Fifo_sim.create (Byte_fifo.create ~depth:4 (Scope.create ~flatten_design:true ())) in
  let i = Cyclesim.inputs sim in
  let o = Cyclesim.outputs sim in
  i.reset_i := Bits.vdd;
  i.enable_i := Bits.vdd;
  Cyclesim.cycle sim;
  i.reset_i := Bits.gnd;
  i.push_valid_i := Bits.vdd;
  for n = 1 to 4 do
    i.push_data_i := bits 8 n;
    Cyclesim.cycle sim
  done;
  check "full" o.count_o 4;
  check "oldest" o.pop_data_o 1;
  i.push_data_i := bits 8 5;
  i.pop_ready_i := Bits.vdd;
  Cyclesim.cycle sim;
  check "occupancy unchanged" o.count_o 4;
  check "next oldest" o.pop_data_o 2;
  i.push_valid_i := Bits.gnd;
  for n = 3 to 5 do
    Cyclesim.cycle sim;
    check "ordered pop" o.pop_data_o n
  done;
  Cyclesim.cycle sim;
  check "empty" o.pop_valid_o 0;
  Cyclesim.cycle sim;
  check "starvation sticky" o.starvation_o 1
;;

module Shift_sim = Cyclesim.With_interface (Shift_lane.I) (Shift_lane.O)

let%test_unit "P2.5 internal lane preloads, clocks, samples, and completes" =
  let sim = Shift_sim.create (Shift_lane.create (Scope.create ~flatten_design:true ())) in
  let i = Cyclesim.inputs sim in
  let o = Cyclesim.outputs sim in
  i.reset_i := Bits.vdd;
  i.enable_i := Bits.vdd;
  Cyclesim.cycle sim;
  i.reset_i := Bits.gnd;
  i.start_valid_i := Bits.vdd;
  i.bit_count_i := bits 6 8;
  i.tx_value_i := bits 32 0xa5;
  i.tx_valid_i := Bits.vdd;
  i.rx_ready_i := Bits.vdd;
  i.tx_enable_i := Bits.vdd;
  i.rx_enable_i := Bits.vdd;
  i.output_pin_i := bits 3 0;
  i.input_pin_i := bits 3 2;
  i.clock_pin_i := bits 3 1;
  i.clock_enable_i := Bits.vdd;
  i.half_period_i := bits 16 2;
  i.launch_trailing_i := Bits.vdd;
  Cyclesim.cycle sim;
  i.start_valid_i := Bits.gnd;
  check "claims output and clock" o.claim_mask_o 3;
  check "preloads first MSB" o.pin_value_o 1;
  check "drives both pins" o.pin_oe_o 3;
  for n = 0 to 7 do
    let expected_bit = (0xa5 lsr (7 - n)) land 1 in
    i.pin_in_i := bits 8 (expected_bit lsl 2);
    Cyclesim.cycle sim;
    Cyclesim.cycle sim;
    check "leading edge clock" o.pin_value_o (3 land (2 lor expected_bit));
    Cyclesim.cycle sim;
    Cyclesim.cycle sim;
    if n < 7
    then check "next bit preloaded" o.pin_value_o ((0xa5 lsr (6 - n)) land 1)
  done;
  check "transfer complete" o.done_o 1;
  check "received word" o.rx_data_o 0xa5;
  check "received valid" o.rx_valid_o 1;
  check "ownership released" o.claim_mask_o 0;
  check "pins released" o.pin_oe_o 0
;;

let%test_unit "P2.6 observed edges pace a preconfigured lane and abort releases pins" =
  let sim = Shift_sim.create (Shift_lane.create (Scope.create ~flatten_design:true ())) in
  let i = Cyclesim.inputs sim in
  let o = Cyclesim.outputs sim in
  i.reset_i := Bits.vdd;
  i.enable_i := Bits.vdd;
  Cyclesim.cycle sim;
  i.reset_i := Bits.gnd;
  i.start_valid_i := Bits.vdd;
  i.bit_count_i := bits 6 2;
  i.tx_value_i := bits 32 2;
  i.tx_valid_i := Bits.vdd;
  i.tx_enable_i := Bits.vdd;
  i.output_pin_i := bits 3 0;
  i.observed_i := Bits.vdd;
  i.launch_trailing_i := Bits.vdd;
  Cyclesim.cycle sim;
  i.start_valid_i := Bits.gnd;
  check "first bit preload" o.pin_value_o 1;
  for _ = 1 to 4 do
    Cyclesim.cycle sim
  done;
  check "no progress without observed edge" o.busy_o 1;
  i.observed_edge_i := Bits.vdd;
  Cyclesim.cycle sim;
  i.observed_edge_i := Bits.gnd;
  Cyclesim.cycle sim;
  i.observed_edge_i := Bits.vdd;
  Cyclesim.cycle sim;
  check "second bit launched" o.pin_value_o 0;
  i.abort_i := Bits.vdd;
  Cyclesim.cycle sim;
  check "abort releases ownership" o.claim_mask_o 0;
  check "abort releases output" o.pin_oe_o 0;
  check "abort stops" o.busy_o 0
;;

let%test_unit "P2.5 invalid descriptor and missing TX data never drive pins" =
  let sim = Shift_sim.create (Shift_lane.create (Scope.create ~flatten_design:true ())) in
  let i = Cyclesim.inputs sim in
  let o = Cyclesim.outputs sim in
  i.reset_i := Bits.vdd;
  i.enable_i := Bits.vdd;
  Cyclesim.cycle sim;
  i.reset_i := Bits.gnd;
  i.start_valid_i := Bits.vdd;
  i.bit_count_i := bits 6 8;
  i.tx_enable_i := Bits.vdd;
  i.output_pin_i := bits 3 0;
  i.half_period_i := bits 16 1;
  i.launch_trailing_i := Bits.vdd;
  i.sample_trailing_i := Bits.vdd;
  Cyclesim.cycle sim;
  check "same launch and sample phase rejected" o.rejected_o 1;
  check "no claim on rejection" o.claim_mask_o 0;
  i.sample_trailing_i := Bits.gnd;
  Cyclesim.cycle sim;
  check "missing TX word faults before launch" o.underrun_o 1;
  check "no driven pin on underrun" o.pin_oe_o 0
;;

module Uart_sim = Cyclesim.With_interface (Uart_tx.I) (Uart_tx.O)

let%test_unit "P2.7 independent 8N1 receiver sees idle, start, data, and stop" =
  let sim = Uart_sim.create (Uart_tx.create (Scope.create ~flatten_design:true ())) in
  let i = Cyclesim.inputs sim in
  let o = Cyclesim.outputs sim in
  i.reset_i := Bits.vdd;
  i.enable_i := Bits.vdd;
  Cyclesim.cycle sim;
  i.reset_i := Bits.gnd;
  Cyclesim.cycle sim;
  check "UART idle high" o.pins_o 1;
  check "idle actively driven" o.pin_oe_o 1;
  i.byte_valid_i := Bits.vdd;
  i.byte_i := bits 8 0xa6;
  i.half_period_i := bits 16 4;
  Cyclesim.cycle sim;
  i.byte_valid_i := Bits.gnd;
  check "start low on acceptance" o.pins_o 0;
  let expected = Array.init 10 ~f:(function
    | 0 -> 0
    | 9 -> 1
    | n -> (0xa6 lsr (n - 1)) land 1)
  in
  for cycle = 1 to 80 do
    Cyclesim.cycle sim;
    if cycle <= 76 && (cycle - 4) mod 8 = 0
    then (
      let bit_index = (cycle - 4) / 8 in
      check
        (Printf.sprintf "UART bit %d at center" bit_index)
        o.pins_o
        expected.(bit_index);
      check "UART TX drive" o.pin_oe_o 1)
  done;
  check "frame complete" o.done_o 1;
  check "idle after frame" o.pins_o 1;
  i.byte_valid_i := Bits.vdd;
  Cyclesim.cycle sim;
  check "second frame starts without RTL regeneration" o.pins_o 0;
  i.enable_i := Bits.gnd;
  Cyclesim.cycle sim;
  check "disable releases UART" o.pin_oe_o 0;
  check "disable cancels frame" o.busy_o 0
;;

module Model = Protemu_model

(* The shared enumerations moved below the model when P1.5 gave the encoding and the RTL
   one specification to read them from; [Pin_bank]'s owner is still the same type. *)
module Kinds = Protemu_isa.Kinds

let%test_unit "P2.1 pin commits and ownership track the independent model" =
  let sim = Pin_sim.create (Pin_bank.create (Scope.create ~flatten_design:true ())) in
  let i = Cyclesim.inputs sim in
  let o = Cyclesim.outputs sim in
  i.reset_i := Bits.vdd;
  i.enable_i := Bits.vdd;
  Cyclesim.cycle sim;
  i.reset_i := Bits.gnd;
  let state = ref Model.Pin_bank.released in
  let commit mask value output_enable =
    i.write_valid_i := Bits.vdd;
    i.write_mask_i := bits 8 mask;
    i.write_value_i := bits 8 value;
    i.write_oe_i := bits 8 output_enable;
    let expected =
      Model.Pin_bank.commit
        !state
        { Model.Pin_bank.Write.mask; value; output_enable }
        ~owner:Kinds.Owner.Software
    in
    Cyclesim.cycle sim;
    i.write_valid_i := Bits.gnd;
    (match expected with
     | Ok next -> state := next; check "accepted write" o.rejected_o 0
     | Error _ -> check "rejected write" o.rejected_o 1);
    check "model value" o.pins_o !state.value;
    check "model output enable" o.pin_oe_o !state.output_enable
  in
  commit 0x0f 0x05 0x0f;
  commit 0xf0 0xa0 0x50;
  i.claim_valid_i := Bits.vdd;
  i.claim_engine_i := Bits.vdd;
  i.claim_mask_i := bits 8 0x30;
  (match Model.Pin_bank.claim !state ~owner:(Kinds.Owner.Engine 0) ~mask:0x30 with
   | Ok next -> state := next
   | Error _ -> failwith "model claim was unexpectedly rejected");
  Cyclesim.cycle sim;
  i.claim_valid_i := Bits.gnd;
  commit 0x21 0x21 0x21;
  commit 0x40 0 0x40;
  i.abort_i := Bits.vdd;
  Cyclesim.cycle sim;
  state := Model.Pin_bank.released;
  check "model abort value" o.pins_o !state.value;
  check "model abort enable" o.pin_oe_o !state.output_enable
;;

let%test_unit "P2.2 snapshots and sticky events track the independent model" =
  let sim = Event_sim.create (Input_events.create (Scope.create ~flatten_design:true ())) in
  let i = Cyclesim.inputs sim in
  let o = Cyclesim.outputs sim in
  i.reset_i := Bits.vdd;
  Cyclesim.cycle sim;
  i.reset_i := Bits.gnd;
  let inputs = ref Model.Input_pins.cleared in
  let events = ref Model.Event.cleared in
  let kinds =
    [| Model.Event.Kind.Delay_expired
     ; Wait_complete
     ; Wait_timeout
     ; Tick
     ; Aborted
     ; Fault
    |]
  in
  let selected mask =
    Array.to_list kinds
    |> List.filteri ~f:(fun n _ -> mask land (1 lsl n) <> 0)
  in
  let mask_of predicate =
    Array.foldi kinds ~init:0 ~f:(fun n mask kind ->
      if predicate !events kind then mask lor (1 lsl n) else mask)
  in
  for cycle = 0 to 99 do
    let pad = cycle * 73 land 255 in
    let set = if cycle mod 3 = 0 then 1 lsl (cycle mod 6) else 0 in
    let ack = if cycle mod 5 = 0 then 1 lsl ((cycle / 5) mod 6) else 0 in
    i.pin_in_i := bits 8 pad;
    i.event_set_i := bits 6 set;
    i.event_ack_i := bits 6 ack;
    inputs := Model.Input_pins.step !inputs ~pin_in:pad;
    events := Model.Event.step !events ~set:(selected set) ~ack:(selected ack);
    Cyclesim.cycle sim;
    check "model snapshot" o.snapshot_o (Model.Input_pins.snapshot !inputs);
    check "model rising" o.rising_o (Model.Input_pins.rising !inputs);
    check "model falling" o.falling_o (Model.Input_pins.falling !inputs);
    check "model events" o.event_o (mask_of Model.Event.is_set);
    check "model overflow" o.overflow_o (mask_of Model.Event.overflowed)
  done
;;

let%test_unit "P2.4 simultaneous queue operations track the independent model" =
  let sim = Fifo_sim.create (Byte_fifo.create ~depth:4 (Scope.create ~flatten_design:true ())) in
  let i = Cyclesim.inputs sim in
  let o = Cyclesim.outputs sim in
  i.reset_i := Bits.vdd;
  i.enable_i := Bits.vdd;
  Cyclesim.cycle sim;
  i.reset_i := Bits.gnd;
  let fifo = ref (Model.Fifo.create ~id:Kinds.Fifo_id.Tx ~depth:4) in
  for cycle = 0 to 99 do
    let push = if cycle mod 7 < 5 then Some (cycle land 255) else None in
    let pop = cycle mod 5 < 3 in
    i.push_valid_i := (if Option.is_some push then Bits.vdd else Bits.gnd);
    i.push_data_i := bits 8 (Option.value push ~default:0);
    i.pop_ready_i := (if pop then Bits.vdd else Bits.gnd);
    let next, popped, _, _ = Model.Fifo.step !fifo ~push ~pop in
    (match popped with
     | None -> ()
     | Some byte -> check "model popped byte" o.pop_data_o byte);
    Cyclesim.cycle sim;
    fifo := next;
    check "model occupancy" o.count_o (Model.Fifo.occupancy !fifo);
    check "model empty" o.pop_valid_o (if Model.Fifo.is_empty !fifo then 0 else 1)
  done
;;

let%test_unit "P2.6 arm latches parameters and starts only on a later event" =
  let sim = Shift_sim.create (Shift_lane.create (Scope.create ~flatten_design:true ())) in
  let i = Cyclesim.inputs sim in
  let o = Cyclesim.outputs sim in
  i.reset_i := Bits.vdd;
  i.enable_i := Bits.vdd;
  Cyclesim.cycle sim;
  i.reset_i := Bits.gnd;
  i.start_valid_i := Bits.vdd;
  i.arm_i := Bits.vdd;
  i.start_event_i := Bits.vdd;
  i.bit_count_i := bits 6 2;
  i.tx_value_i := bits 32 2;
  i.tx_valid_i := Bits.vdd;
  i.tx_enable_i := Bits.vdd;
  i.output_pin_i := bits 3 0;
  i.observed_i := Bits.vdd;
  i.launch_trailing_i := Bits.vdd;
  Cyclesim.cycle sim;
  check "armed" o.armed_o 1;
  check "same-edge event is stale" o.busy_o 0;
  check "armed output released" o.pin_oe_o 0;
  i.start_valid_i := Bits.gnd;
  i.start_event_i := Bits.gnd;
  i.tx_value_i := Bits.zero 32;
  i.output_pin_i := bits 3 5;
  Cyclesim.cycle sim;
  check "still armed" o.armed_o 1;
  i.start_event_i := Bits.vdd;
  Cyclesim.cycle sim;
  check "event starts" o.busy_o 1;
  check "descriptor pin latched" o.claim_mask_o 1;
  check "descriptor data latched" o.pin_value_o 1;
  i.abort_i := Bits.vdd;
  Cyclesim.cycle sim;
  check "abort clears arm and busy" o.armed_o 0;
  check "abort releases armed transfer" o.pin_oe_o 0
;;

let%test_unit "P2.3 periodic ticks continue during waits and restart from an event" =
  let sim = Timing_sim.create (Timing.create (Scope.create ~flatten_design:true ())) in
  let i = Cyclesim.inputs sim in
  let o = Cyclesim.outputs sim in
  i.reset_i := Bits.vdd;
  i.enable_i := Bits.vdd;
  Cyclesim.cycle sim;
  i.reset_i := Bits.gnd;
  i.periodic_start_i := Bits.vdd;
  i.periodic_period_i := bits 16 3;
  Cyclesim.cycle sim;
  i.periodic_start_i := Bits.gnd;
  i.wait_valid_i := Bits.vdd;
  i.wait_delay_i := bits 16 7;
  Cyclesim.cycle sim;
  i.wait_valid_i := Bits.gnd;
  Cyclesim.cycle sim;
  Cyclesim.cycle sim;
  check "tick during wait" o.tick_o 1;
  check "wait still busy" o.busy_o 1;
  i.phase_restart_i := Bits.vdd;
  Cyclesim.cycle sim;
  check "restart suppresses old tick" o.tick_o 0;
  i.phase_restart_i := Bits.gnd;
  Cyclesim.cycle sim;
  Cyclesim.cycle sim;
  check "no early tick after restart" o.tick_o 0;
  Cyclesim.cycle sim;
  check "tick at restarted phase" o.tick_o 1
;;

let%test_unit "P2.1 open drain commit never drives a high" =
  let sim = Pin_sim.create (Pin_bank.create (Scope.create ~flatten_design:true ())) in
  let i = Cyclesim.inputs sim in
  let o = Cyclesim.outputs sim in
  i.reset_i := Bits.vdd;
  i.enable_i := Bits.vdd;
  Cyclesim.cycle sim;
  i.reset_i := Bits.gnd;
  i.write_valid_i := Bits.vdd;
  i.write_mask_i := bits 8 0xc0;
  i.write_value_i := bits 8 0xff;
  i.write_open_drain_i := Bits.vdd;
  i.write_oe_i := bits 8 0x40;
  Cyclesim.cycle sim;
  check "low or released" o.pins_o 0;
  check "one low, one released" o.pin_oe_o 0x40
;;

let%test_unit "P2.4 overflow and reset validity" =
  let sim = Fifo_sim.create (Byte_fifo.create ~depth:4 (Scope.create ~flatten_design:true ())) in
  let i = Cyclesim.inputs sim in
  let o = Cyclesim.outputs sim in
  i.reset_i := Bits.vdd;
  i.enable_i := Bits.vdd;
  Cyclesim.cycle sim;
  i.reset_i := Bits.gnd;
  i.push_valid_i := Bits.vdd;
  for n = 0 to 4 do
    i.push_data_i := bits 8 n;
    Cyclesim.cycle sim
  done;
  check "full remains bounded" o.count_o 4;
  check "overflow sticks" o.overflow_o 1;
  i.reset_i := Bits.vdd;
  Cyclesim.cycle sim;
  check "reset empties queue" o.count_o 0;
  check "reset clears fault" o.overflow_o 0;
  check "reset clears valid" o.pop_valid_o 0
;;

let%test_unit "P2.5 receive-only overrun aborts and invalid data width is refused" =
  let sim = Shift_sim.create (Shift_lane.create (Scope.create ~flatten_design:true ())) in
  let i = Cyclesim.inputs sim in
  let o = Cyclesim.outputs sim in
  i.reset_i := Bits.vdd;
  i.enable_i := Bits.vdd;
  Cyclesim.cycle sim;
  i.reset_i := Bits.gnd;
  i.start_valid_i := Bits.vdd;
  i.bit_count_i := bits 6 1;
  i.tx_enable_i := Bits.vdd;
  i.tx_valid_i := Bits.vdd;
  i.tx_value_i := bits 32 2;
  i.output_pin_i := bits 3 0;
  i.half_period_i := bits 16 1;
  i.launch_trailing_i := Bits.vdd;
  Cyclesim.cycle sim;
  check "out-of-width data rejected" o.rejected_o 1;
  i.tx_enable_i := Bits.gnd;
  i.rx_enable_i := Bits.vdd;
  i.tx_value_i := Bits.zero 32;
  i.input_pin_i := bits 3 2;
  i.pin_in_i := bits 8 4;
  Cyclesim.cycle sim;
  check "receive-only accepted" o.busy_o 1;
  i.start_valid_i := Bits.gnd;
  Cyclesim.cycle sim;
  Cyclesim.cycle sim;
  check "overrun reported" o.overrun_o 1;
  check "overrun aborts" o.busy_o 0;
  check "overrun releases" o.claim_mask_o 0
;;

let%test_unit "P2.4 all configured FIFO depths preserve ordering" =
  List.iter [ 4; 8; 16 ] ~f:(fun depth ->
    let sim =
      Fifo_sim.create
        (Byte_fifo.create ~depth (Scope.create ~flatten_design:true ()))
    in
    let i = Cyclesim.inputs sim in
    let o = Cyclesim.outputs sim in
    i.reset_i := Bits.vdd;
    i.enable_i := Bits.vdd;
    Cyclesim.cycle sim;
    i.reset_i := Bits.gnd;
    i.push_valid_i := Bits.vdd;
    for n = 0 to depth - 1 do
      i.push_data_i := bits 8 (n + 1);
      Cyclesim.cycle sim
    done;
    check "configured depth reached" o.count_o depth;
    i.push_valid_i := Bits.gnd;
    i.pop_ready_i := Bits.vdd;
    for n = 0 to depth - 1 do
      check "ordered byte" o.pop_data_o (n + 1);
      Cyclesim.cycle sim
    done;
    check "configured queue empty" o.count_o 0)
;;

let%test_unit "P2.1 reset and disable release driven pins" =
  let sim = Pin_sim.create (Pin_bank.create (Scope.create ~flatten_design:true ())) in
  let i = Cyclesim.inputs sim in
  let o = Cyclesim.outputs sim in
  i.reset_i := Bits.vdd;
  i.enable_i := Bits.vdd;
  Cyclesim.cycle sim;
  i.reset_i := Bits.gnd;
  i.write_valid_i := Bits.vdd;
  i.write_mask_i := bits 8 1;
  i.write_value_i := bits 8 1;
  i.write_oe_i := bits 8 1;
  Cyclesim.cycle sim;
  check "driven before disable" o.pin_oe_o 1;
  i.write_valid_i := Bits.gnd;
  i.enable_i := Bits.gnd;
  Cyclesim.cycle sim;
  check "disable release" o.pin_oe_o 0;
  i.enable_i := Bits.vdd;
  i.write_valid_i := Bits.vdd;
  Cyclesim.cycle sim;
  check "driven before reset" o.pin_oe_o 1;
  i.reset_i := Bits.vdd;
  Cyclesim.cycle sim;
  check "reset release" o.pin_oe_o 0
;;

let%test_unit "P2.5/P2.6 shift timing and results match the independent model" =
  let run ~observed ~arm ~lsb ~idle_clock =
    let sim = Shift_sim.create (Shift_lane.create (Scope.create ~flatten_design:true ())) in
    let i = Cyclesim.inputs sim in
    let o = Cyclesim.outputs sim in
    i.reset_i := Bits.vdd;
    i.enable_i := Bits.vdd;
    Cyclesim.cycle sim;
    i.reset_i := Bits.gnd;
    let direction = Kinds.Direction.Duplex in
    let pacing =
      if observed
      then
        Model.Transfer.Pacing.Observed_edge
          { pin = 3; edge = Kinds.Edge.Either }
      else Model.Transfer.Pacing.Internal { half_period = 2 }
    in
    let leading =
      if idle_clock then Kinds.Clock_phase.On_falling else On_rising
    in
    let trailing =
      if idle_clock then Kinds.Clock_phase.On_rising else On_falling
    in
    let descriptor : Model.Transfer.t =
      { direction
      ; bit_count = 4
      ; bit_order = (if lsb then Lsb_first else Msb_first)
      ; tx_value = 0x9
      ; output_pin = Some 0
      ; input_pin = Some 2
      ; clock_pin = (if observed then None else Some 1)
      ; idle_output = false
      ; idle_clock
      ; initial_delay = None
      ; launch = trailing
      ; sample = leading
      ; pacing
      }
    in
    let model = ref Model.Shift_engine.idle in
    i.bit_count_i := bits 6 4;
    i.tx_value_i := bits 32 0x9;
    i.tx_valid_i := Bits.vdd;
    i.rx_ready_i := Bits.vdd;
    i.tx_enable_i := Bits.vdd;
    i.rx_enable_i := Bits.vdd;
    i.lsb_first_i := (if lsb then Bits.vdd else Bits.gnd);
    i.output_pin_i := bits 3 0;
    i.input_pin_i := bits 3 2;
    i.clock_pin_i := bits 3 1;
    i.clock_enable_i := (if observed then Bits.gnd else Bits.vdd);
    i.idle_clock_i := (if idle_clock then Bits.vdd else Bits.gnd);
    i.half_period_i := bits 16 2;
    i.launch_trailing_i := Bits.vdd;
    i.observed_i := (if observed then Bits.vdd else Bits.gnd);
    for cycle = 0 to 34 do
      let command = if cycle = 0 then Some (descriptor, arm) else None in
      let start_event = arm && cycle = 3 in
      let observed_edge = observed && cycle > 3 && cycle mod 3 = 0 in
      let bit_index = !model.index in
      let sampled =
        if bit_index < 4
        then
          let position = if lsb then bit_index else 3 - bit_index in
          (0x9 lsr position) land 1
        else 0
      in
      let pin_in = sampled lsl 2 in
      i.start_valid_i := (if Option.is_some command then Bits.vdd else Bits.gnd);
      i.arm_i := (if arm then Bits.vdd else Bits.gnd);
      i.start_event_i := (if start_event then Bits.vdd else Bits.gnd);
      i.observed_edge_i := (if observed_edge then Bits.vdd else Bits.gnd);
      i.pin_in_i := bits 8 pin_in;
      model :=
        Model.Shift_engine.step
          !model
          ~enable:true
          ~abort:false
          ~command
          ~start_event
          ~observed_edge
          ~pin_in
          ~occupied:0
          ~tx_valid:true
          ~rx_ready:true;
      Cyclesim.cycle sim;
      check "model busy" o.busy_o (if !model.active then 1 else 0);
      check "model armed" o.armed_o (if !model.armed then 1 else 0);
      check "model ownership" o.claim_mask_o !model.claim;
      check "model output enable" o.pin_oe_o !model.output_enable;
      [%test_result: int]
        ~message:"model driven pin levels"
        ~expect:(!model.pins land !model.output_enable)
        (Bits.to_int_trunc !(o.pin_value_o) land !model.output_enable);
      check "model completion" o.done_o (if !model.done_ then 1 else 0);
      check "model RX validity" o.rx_valid_o (if !model.rx_valid then 1 else 0);
      if !model.rx_valid then check "model RX word" o.rx_data_o !model.rx_data
    done
  in
  List.iter [ false; true ] ~f:(fun observed ->
    List.iter [ false; true ] ~f:(fun lsb ->
      run ~observed ~arm:observed ~lsb ~idle_clock:false));
  run ~observed:false ~arm:false ~lsb:false ~idle_clock:true
;;

let%test_unit "P2.3 waits and periodic ticks track the independent machine" =
  let sim = Timing_sim.create (Timing.create (Scope.create ~flatten_design:true ())) in
  let i = Cyclesim.inputs sim in
  let o = Cyclesim.outputs sim in
  i.reset_i := Bits.vdd;
  i.enable_i := Bits.vdd;
  Cyclesim.cycle sim;
  i.reset_i := Bits.gnd;
  let machine = ref (Model.Machine.create ()) in
  let step ?(pin_in = 0) command =
    let input =
      { Model.Machine.Input.idle with command; pin_in }
    in
    machine := Model.Machine.step !machine input;
    let snapshot = Model.Input_pins.snapshot !machine.inputs in
    i.snapshot_i := bits 8 snapshot;
    i.rising_i := bits 8 (Model.Input_pins.rising !machine.inputs);
    i.falling_i := bits 8 (Model.Input_pins.falling !machine.inputs);
    i.wait_valid_i := Bits.gnd;
    i.periodic_start_i := Bits.gnd;
    (match command with
     | Some (Model.Operation.Start_periodic { period }) ->
       i.periodic_start_i := Bits.vdd;
       i.periodic_period_i := bits 16 period
     | Some (Wait_cycles { delay }) ->
       i.wait_valid_i := Bits.vdd;
       i.wait_kind_i := bits 2 0;
       i.wait_delay_i := bits 16 delay
     | Some (Wait_level { pin; level; timeout }) ->
       i.wait_valid_i := Bits.vdd;
       i.wait_kind_i := bits 2 1;
       i.wait_pin_i := bits 3 pin;
       i.wait_level_i := (if level then Bits.vdd else Bits.gnd);
       i.wait_timeout_enable_i :=
         (if Option.is_some timeout then Bits.vdd else Bits.gnd);
       i.wait_delay_i := bits 16 (Option.value timeout ~default:0)
     | Some (Wait_edge { pin; edge; timeout }) ->
       i.wait_valid_i := Bits.vdd;
       i.wait_kind_i :=
         bits 2 (if Kinds.Edge.equal edge Rising then 2 else 3);
       i.wait_pin_i := bits 3 pin;
       i.wait_timeout_enable_i :=
         (if Option.is_some timeout then Bits.vdd else Bits.gnd);
       i.wait_delay_i := bits 16 (Option.value timeout ~default:0)
     | Some _ | None -> ());
    Cyclesim.cycle sim;
    let occurred kind =
      if List.mem !machine.last.events kind ~equal:Model.Event.Kind.equal then 1 else 0
    in
    check "model wait busy" o.busy_o (if Model.Machine.waiting !machine then 1 else 0);
    check "model completion" o.complete_o
      (if occurred Delay_expired = 1 || occurred Wait_complete = 1 then 1 else 0);
    check "model timeout" o.timeout_o (occurred Wait_timeout);
    check "model periodic tick" o.tick_o (occurred Tick)
  in
  step (Some (Model.Operation.Start_periodic { period = 3 }));
  step (Some (Wait_cycles { delay = 5 }));
  for _ = 1 to 5 do
    step None
  done;
  for _ = 1 to 2 do
    step ~pin_in:1 None
  done;
  step ~pin_in:1 (Some (Wait_level { pin = 0; level = true; timeout = Some 2 }));
  step ~pin_in:0 None;
  step ~pin_in:0 None;
  step ~pin_in:0 None;
  step ~pin_in:0 (Some (Wait_edge { pin = 0; edge = Rising; timeout = Some 2 }));
  step ~pin_in:1 None;
  step ~pin_in:1 None
;;

module Observed_sim =
  Cyclesim.With_interface (Observed_transfer.I) (Observed_transfer.O)

let%test_unit "P2.6 synchronized start and pacing use the same input snapshot" =
  let sim =
    Observed_sim.create
      (Observed_transfer.create (Scope.create ~flatten_design:true ()))
  in
  let i = Cyclesim.inputs sim in
  let o = Cyclesim.outputs sim in
  i.reset_i := Bits.vdd;
  i.enable_i := Bits.vdd;
  Cyclesim.cycle sim;
  i.reset_i := Bits.gnd;
  i.arm_valid_i := Bits.vdd;
  i.start_pin_i := bits 3 3;
  i.pacing_pin_i := bits 3 1;
  i.pacing_edge_kind_i := bits 2 2;
  i.bit_count_i := bits 6 1;
  i.tx_value_i := bits 32 1;
  i.tx_valid_i := Bits.vdd;
  i.rx_ready_i := Bits.vdd;
  i.tx_enable_i := Bits.vdd;
  i.rx_enable_i := Bits.vdd;
  i.output_pin_i := bits 3 0;
  i.input_pin_i := bits 3 2;
  i.launch_trailing_i := Bits.vdd;
  Cyclesim.cycle sim;
  i.arm_valid_i := Bits.gnd;
  check "armed before asynchronous start" o.armed_o 1;
  i.pin_async_i := bits 8 8;
  Cyclesim.cycle sim;
  check "first synchronizer stage hidden" o.snapshot_o 0;
  Cyclesim.cycle sim;
  check "start visible in snapshot" o.snapshot_o 8;
  check "start edge visible" o.start_edge_o 1;
  check "engine not yet started" o.busy_o 0;
  Cyclesim.cycle sim;
  check "engine starts one edge later" o.busy_o 1;
  check "preload driven after start" o.pin_oe_o 1;
  i.pin_async_i := bits 8 14;
  Cyclesim.cycle sim;
  Cyclesim.cycle sim;
  check "clock/data snapshot aligned" o.snapshot_o 14;
  check "pacing rise" o.pacing_edge_o 1;
  Cyclesim.cycle sim;
  check "first paced half-edge keeps transfer active" o.busy_o 1;
  i.pin_async_i := bits 8 12;
  Cyclesim.cycle sim;
  Cyclesim.cycle sim;
  check "pacing fall" o.pacing_edge_o 1;
  Cyclesim.cycle sim;
  check "paced transfer completes" o.done_o 1;
  check "aligned data sampled" o.rx_data_o 1;
  check "pacing completion releases" o.pin_oe_o 0
;;

let%test_unit "P2.5 pin conflict and 32-bit boundary" =
  let sim = Shift_sim.create (Shift_lane.create (Scope.create ~flatten_design:true ())) in
  let i = Cyclesim.inputs sim in
  let o = Cyclesim.outputs sim in
  i.reset_i := Bits.vdd;
  i.enable_i := Bits.vdd;
  Cyclesim.cycle sim;
  i.reset_i := Bits.gnd;
  i.start_valid_i := Bits.vdd;
  i.bit_count_i := bits 6 32;
  i.tx_value_i := bits 32 0x80000001;
  i.tx_valid_i := Bits.vdd;
  i.tx_enable_i := Bits.vdd;
  i.lsb_first_i := Bits.vdd;
  i.output_pin_i := bits 3 0;
  i.half_period_i := bits 16 1;
  i.launch_trailing_i := Bits.vdd;
  i.occupied_i := bits 8 1;
  Cyclesim.cycle sim;
  check "occupied pin rejects transaction" o.rejected_o 1;
  check "no claim on conflict" o.claim_mask_o 0;
  i.occupied_i := Bits.zero 8;
  Cyclesim.cycle sim;
  i.start_valid_i := Bits.gnd;
  check "32-bit transfer accepted" o.busy_o 1;
  check "first bit preloaded" o.pin_value_o 1;
  for _ = 1 to 62 do
    Cyclesim.cycle sim
  done;
  check "last bit preloaded" o.pin_value_o 1;
  Cyclesim.cycle sim;
  Cyclesim.cycle sim;
  check "32-bit completion" o.done_o 1
;;

module Demo_sim = Cyclesim.With_interface (Primitive_demo.I) (Primitive_demo.O)

let%test_unit "P2.3 an active transfer advances while the core timer waits" =
  let sim = Demo_sim.create (Primitive_demo.create (Scope.create ~flatten_design:true ())) in
  let i = Cyclesim.inputs sim in
  let o = Cyclesim.outputs sim in
  i.reset_i := Bits.vdd;
  i.enable_i := Bits.vdd;
  Cyclesim.cycle sim;
  i.reset_i := Bits.gnd;
  i.wait_valid_i := Bits.vdd;
  i.wait_delay_i := bits 16 10;
  i.transfer_valid_i := Bits.vdd;
  i.transfer_count_i := bits 6 2;
  i.transfer_data_i := bits 32 2;
  i.half_period_i := bits 16 1;
  Cyclesim.cycle sim;
  i.wait_valid_i := Bits.gnd;
  i.transfer_valid_i := Bits.gnd;
  check "wait started" o.wait_busy_o 1;
  check "transfer started" o.transfer_busy_o 1;
  Cyclesim.cycle sim;
  Cyclesim.cycle sim;
  check "transfer changes pin during wait" o.pins_o 1;
  check "wait still active" o.wait_busy_o 1;
  Cyclesim.cycle sim;
  Cyclesim.cycle sim;
  check "transfer finishes before wait" o.transfer_done_o 1;
  check "core still waiting" o.wait_busy_o 1;
  for _ = 1 to 6 do
    Cyclesim.cycle sim
  done;
  check "wait eventually completes" o.wait_complete_o 1
;;

let%test_unit "P2.7 typed UART descriptor matches hardware frame trace" =
  let descriptor =
    match Model.Firmware_uart.tx_8n1 ~pin:0 ~half_period:4 ~byte:0xa6 with
    | Ok descriptor -> descriptor
    | Error _ -> failwith "valid UART descriptor rejected"
  in
  let sim = Uart_sim.create (Uart_tx.create (Scope.create ~flatten_design:true ())) in
  let i = Cyclesim.inputs sim in
  let o = Cyclesim.outputs sim in
  i.reset_i := Bits.vdd;
  i.enable_i := Bits.vdd;
  Cyclesim.cycle sim;
  i.reset_i := Bits.gnd;
  i.byte_valid_i := Bits.vdd;
  i.byte_i := bits 8 0xa6;
  i.half_period_i := bits 16 4;
  let model = ref Model.Shift_engine.idle in
  for cycle = 0 to 81 do
    let command = if cycle = 0 then Some (descriptor, false) else None in
    i.byte_valid_i := (if cycle = 0 then Bits.vdd else Bits.gnd);
    model :=
      Model.Shift_engine.step
        !model
        ~enable:true
        ~abort:false
        ~command
        ~start_event:false
        ~observed_edge:false
        ~pin_in:0
        ~occupied:0
        ~tx_valid:true
        ~rx_ready:true;
    Cyclesim.cycle sim;
    let expected = if !model.active then !model.pins land 1 else 1 in
    check "typed firmware UART pin" o.pins_o expected;
    check "typed firmware UART enable" o.pin_oe_o 1;
    check "typed firmware UART done" o.done_o (if !model.done_ then 1 else 0)
  done
;;
