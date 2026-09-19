let%test_unit "P0 pin/timer command commits at k+n" =
  let sim = Sim.create (P0_observable.create (Scope.create ~flatten_design:true ())) in
  let i = Cyclesim.inputs sim in
  let o = Cyclesim.outputs sim in
  i.reset_i := Bits.vdd;
  i.enable_i := Bits.vdd;
  Cyclesim.cycle sim;
  i.reset_i := Bits.gnd;
  check_output ~name:"ready after reset" o.ready_o 1;
  i.delay_i := Bits.of_int_trunc ~width:4 3;
  i.pin_value_i := Bits.of_int_trunc ~width:8 0xa5;
  i.pin_oe_i := Bits.of_int_trunc ~width:8 0x3c;
  i.command_valid_i := Bits.vdd;
  Cyclesim.cycle sim;
  i.command_valid_i := Bits.gnd;
  check_output ~name:"busy after acceptance" o.busy_o 1;
  check_output ~name:"latched delay" o.timer_o 3;
  check_output ~name:"pins unchanged at k" o.pins_o 0;
  check_output ~name:"pin enables unchanged at k" o.pin_oe_o 0;
  Cyclesim.cycle sim;
  check_output ~name:"timer at k+1" o.timer_o 2;
  Cyclesim.cycle sim;
  check_output ~name:"timer at k+2" o.timer_o 1;
  Cyclesim.cycle sim;
  check_output ~name:"timer at k+3" o.timer_o 0;
  check_output ~name:"pins committed at k+3" o.pins_o 0xa5;
  check_output ~name:"pin enables committed at k+3" o.pin_oe_o 0x3c;
  check_output ~name:"done pulse" o.done_o 1;
  check_output ~name:"not busy after commit" o.busy_o 0;
  Cyclesim.cycle sim;
  check_output ~name:"done clears" o.done_o 0
;;

let%test_unit "P0 rejects delay zero and disable aborts safely" =
  let sim = Sim.create (P0_observable.create (Scope.create ~flatten_design:true ())) in
  let i = Cyclesim.inputs sim in
  let o = Cyclesim.outputs sim in
  i.reset_i := Bits.vdd;
  i.enable_i := Bits.vdd;
  Cyclesim.cycle sim;
  i.reset_i := Bits.gnd;
  i.command_valid_i := Bits.vdd;
  i.delay_i := Bits.zero 4;
  Cyclesim.cycle sim;
  check_output ~name:"zero delay rejected" o.rejected_o 1;
  check_output ~name:"zero delay does not start" o.busy_o 0;
  i.delay_i := Bits.of_int_trunc ~width:4 4;
  i.pin_value_i := Bits.of_int_trunc ~width:8 0xff;
  i.pin_oe_i := Bits.of_int_trunc ~width:8 0xff;
  Cyclesim.cycle sim;
  i.command_valid_i := Bits.gnd;
  check_output ~name:"nonzero command starts" o.busy_o 1;
  i.enable_i := Bits.gnd;
  Cyclesim.cycle sim;
  check_output ~name:"disable cancels timer" o.timer_o 0;
  check_output ~name:"disable cancels command" o.busy_o 0;
  check_output ~name:"disable clears values" o.pins_o 0;
  check_output ~name:"disable releases pins" o.pin_oe_o 0;
  check_output ~name:"not ready while disabled" o.ready_o 0
;;
open! Core
open! Hardcaml
open! Wrapper_testbench
