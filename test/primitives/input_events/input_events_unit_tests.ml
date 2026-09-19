let%test_unit "P2.2 synchronizer, set-wins acknowledge, and overflow" =
  let sim = Sim.create (Input_events.create (Scope.create ~flatten_design:true ())) in
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

let%test_unit "P2.2 snapshots and sticky events track the independent model" =
  let sim = Sim.create (Input_events.create (Scope.create ~flatten_design:true ())) in
  let i = Cyclesim.inputs sim in
  let o = Cyclesim.outputs sim in
  i.reset_i := Bits.vdd;
  Cyclesim.cycle sim;
  i.reset_i := Bits.gnd;
  let inputs = ref F_model.Input_pins.cleared in
  let events = ref F_model.Event.cleared in
  let kinds =
    [| F_model.Event.Kind.Delay_expired
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
    inputs := F_model.Input_pins.step !inputs ~pin_in:pad;
    events := F_model.Event.step !events ~set:(selected set) ~ack:(selected ack);
    Cyclesim.cycle sim;
    check "model snapshot" o.snapshot_o (F_model.Input_pins.snapshot !inputs);
    check "model rising" o.rising_o (F_model.Input_pins.rising !inputs);
    check "model falling" o.falling_o (F_model.Input_pins.falling !inputs);
    check "model events" o.event_o (mask_of F_model.Event.is_set);
    check "model overflow" o.overflow_o (mask_of F_model.Event.overflowed)
  done
;;
open! Core
open! Hardcaml
open! Hardcaml_protemu
open! Input_events_testbench

