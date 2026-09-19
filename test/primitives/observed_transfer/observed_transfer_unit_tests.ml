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
        F_model.Transfer.Pacing.Observed_edge
          { pin = 3; edge = Kinds.Edge.Either }
      else F_model.Transfer.Pacing.Internal { half_period = 2 }
    in
    let leading =
      if idle_clock then Kinds.Clock_phase.On_falling else On_rising
    in
    let trailing =
      if idle_clock then Kinds.Clock_phase.On_rising else On_falling
    in
    let descriptor : F_model.Transfer.t =
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
    let model = ref F_model.Shift_engine.idle in
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
        F_model.Shift_engine.step
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
open! Core
open! Hardcaml
open! Hardcaml_protemu
open! Observed_transfer_testbench

