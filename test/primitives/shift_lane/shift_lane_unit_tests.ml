let%test_unit "P2.5 internal lane preloads, clocks, samples, and completes" =
  let sim = Sim.create (Shift_lane.create (Scope.create ~flatten_design:true ())) in
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

let%test_unit "P2.5 invalid descriptor and missing TX data never drive pins" =
  let sim = Sim.create (Shift_lane.create (Scope.create ~flatten_design:true ())) in
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

let%test_unit "P2.5 receive-only overrun aborts and invalid data width is refused" =
  let sim = Sim.create (Shift_lane.create (Scope.create ~flatten_design:true ())) in
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

let%test_unit "P2.5 pin conflict and 32-bit boundary" =
  let sim = Sim.create (Shift_lane.create (Scope.create ~flatten_design:true ())) in
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
open! Core
open! Hardcaml
open! Hardcaml_protemu
open! Shift_lane_testbench

