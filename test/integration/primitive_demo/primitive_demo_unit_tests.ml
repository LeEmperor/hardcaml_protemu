let%test_unit "P2.3 an active transfer advances while the core timer waits" =
  let sim = Sim.create (Primitive_demo.create (Scope.create ~flatten_design:true ())) in
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
open! Core
open! Hardcaml
open! Hardcaml_protemu
open! Primitive_demo_testbench

