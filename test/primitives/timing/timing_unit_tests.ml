let%test_unit "P2.3 exact delay, immediate level, stale edge, and timeout precedence" =
  let sim = Sim.create (Timing.create (Scope.create ~flatten_design:true ())) in
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

let%test_unit "P2.3 periodic ticks continue during waits and restart from an event" =
  let sim = Sim.create (Timing.create (Scope.create ~flatten_design:true ())) in
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

let%test_unit "P2.3 waits and periodic ticks track the independent machine" =
  let sim = Sim.create (Timing.create (Scope.create ~flatten_design:true ())) in
  let i = Cyclesim.inputs sim in
  let o = Cyclesim.outputs sim in
  i.reset_i := Bits.vdd;
  i.enable_i := Bits.vdd;
  Cyclesim.cycle sim;
  i.reset_i := Bits.gnd;
  let machine = ref (F_model.Machine.create ()) in
  let step ?(pin_in = 0) command =
    let input =
      { F_model.Machine.Input.idle with command; pin_in }
    in
    machine := F_model.Machine.step !machine input;
    let snapshot = F_model.Input_pins.snapshot !machine.inputs in
    i.snapshot_i := bits 8 snapshot;
    i.rising_i := bits 8 (F_model.Input_pins.rising !machine.inputs);
    i.falling_i := bits 8 (F_model.Input_pins.falling !machine.inputs);
    i.wait_valid_i := Bits.gnd;
    i.periodic_start_i := Bits.gnd;
    (match command with
     | Some (F_model.Operation.Start_periodic { period }) ->
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
      if List.mem !machine.last.events kind ~equal:F_model.Event.Kind.equal then 1 else 0
    in
    check "model wait busy" o.busy_o (if F_model.Machine.waiting !machine then 1 else 0);
    check "model completion" o.complete_o
      (if occurred Delay_expired = 1 || occurred Wait_complete = 1 then 1 else 0);
    check "model timeout" o.timeout_o (occurred Wait_timeout);
    check "model periodic tick" o.tick_o (occurred Tick)
  in
  step (Some (F_model.Operation.Start_periodic { period = 3 }));
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
open! Core
open! Hardcaml
open! Hardcaml_protemu
open! Timing_testbench

