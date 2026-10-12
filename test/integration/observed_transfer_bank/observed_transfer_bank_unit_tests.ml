(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "observed_transfer_bank_unit_tests.ml" *)

open! Core
open! Hardcaml
open! Hardcaml_protemu
module Sim = Cyclesim.With_interface (Observed_transfer_bank.I) (Observed_transfer_bank.O)

let bits width value = Bits.of_int_trunc ~width value
let int value = Bits.to_int_trunc !value

let create () =
  let sim =
    Sim.create (Observed_transfer_bank.create (Scope.create ~flatten_design:true ()))
  in
  let i = Cyclesim.inputs sim in
  let o = Cyclesim.outputs sim in
  i.enable_i := Bits.vdd;
  i.start_pin_i := bits 3 3;
  i.start_edge_kind_i := bits 2 0;
  i.pacing_pin_i := bits 3 1;
  i.pacing_edge_kind_i := bits 2 2;
  i.bit_count_i := bits 6 1;
  i.tx_value_i := bits 32 1;
  i.tx_valid_i := Bits.vdd;
  i.rx_ready_i := Bits.vdd;
  i.tx_enable_i := Bits.vdd;
  i.lsb_first_i := Bits.vdd;
  i.output_pin_i := bits 3 0;
  i.launch_trailing_i := Bits.vdd;
  i.reset_i := Bits.vdd;
  Cyclesim.cycle sim;
  i.reset_i := Bits.gnd;
  sim, i, o
;;

let pulse input sim =
  input := Bits.vdd;
  Cyclesim.cycle sim;
  input := Bits.gnd
;;

let cycles sim count =
  for _ = 1 to count do
    Cyclesim.cycle sim
  done
;;

let start sim (i : Bits.t ref Observed_transfer_bank.I.t) =
  i.pin_async_i := bits 8 0;
  cycles sim 2;
  i.pin_async_i := bits 8 8;
  cycles sim 4
;;

let%test_unit "software-owned unrelated pins survive transfer commits and cleanup" =
  let sim, i, o = create () in
  i.software_claim_mask_i := bits 8 0x80;
  pulse i.software_claim_valid_i sim;
  i.software_write_mask_i := bits 8 0x80;
  i.software_write_value_i := bits 8 0x80;
  i.software_write_oe_i := bits 8 0x80;
  pulse i.software_write_valid_i sim;
  pulse i.arm_valid_i sim;
  start sim i;
  [%test_result: int] ~expect:0x81 (int o.pin_oe_o);
  [%test_result: int] ~expect:0x81 (int o.pins_o);
  i.pin_async_i := bits 8 10;
  cycles sim 4;
  i.pin_async_i := bits 8 8;
  cycles sim 6;
  [%test_result: int]
    ~message:"only software output remains enabled"
    ~expect:0x80
    (int o.pin_oe_o);
  [%test_result: int] ~expect:0x80 (int o.pins_o);
  [%test_result: int] ~expect:0x80 (int o.software_claim_o);
  [%test_result: int] ~expect:0 (int o.engine_claim_o)
;;

let%test_unit "conflicting software ownership refuses the arm claim and retry recovers" =
  let sim, i, o = create () in
  i.software_claim_mask_i := bits 8 1;
  pulse i.software_claim_valid_i sim;
  pulse i.arm_valid_i sim;
  cycles sim 1;
  [%test_result: int]
    ~message:"conflicting arm is reported"
    ~expect:1
    (int o.transaction_rejected_o);
  [%test_result: int]
    ~message:"software keeps conflicting ownership"
    ~expect:1
    (int o.software_claim_o);
  [%test_result: int] ~expect:0 (int o.engine_claim_o);
  [%test_result: int] ~expect:1 (int o.bank_conflict_o);
  [%test_result: int] ~expect:0 (int o.pin_oe_o);
  i.software_release_mask_i := bits 8 1;
  pulse i.software_release_valid_i sim;
  pulse i.arm_valid_i sim;
  start sim i;
  [%test_result: int]
    ~message:"retry claims after conflict release"
    ~expect:1
    (int o.engine_claim_o);
  [%test_result: int] ~message:"retry commits preload" ~expect:1 (int o.pin_oe_o)
;;

let%test_unit "a concurrent software request is explicitly refused" =
  let sim, i, o = create () in
  i.arm_valid_i := Bits.vdd;
  i.software_claim_valid_i := Bits.vdd;
  i.software_claim_mask_i := bits 8 0x80;
  Cyclesim.cycle sim;
  [%test_result: int] ~expect:1 (int o.software_rejected_o);
  i.arm_valid_i := Bits.gnd;
  i.software_claim_valid_i := Bits.gnd;
  [%test_result: int] ~expect:0 (int o.software_claim_o);
  [%test_result: int] ~expect:1 (int o.engine_claim_o)
;;

let%test_unit "a rejected software operation cannot abort or strand an armed transfer" =
  let sim, i, o = create () in
  pulse i.arm_valid_i sim;
  [%test_result: int] ~expect:1 (int o.engine_claim_o);
  i.software_release_mask_i := bits 8 0x80;
  pulse i.software_release_valid_i sim;
  [%test_result: int]
    ~message:"software request reached the bank"
    ~expect:1
    (int o.bank_rejected_o);
  cycles sim 1;
  [%test_result: int]
    ~message:"engine claim survives software rejection"
    ~expect:1
    (int o.engine_claim_o);
  [%test_result: int] ~message:"lane remains armed" ~expect:1 (int o.armed_o);
  start sim i;
  [%test_result: int] ~message:"armed transfer still commits" ~expect:1 (int o.pin_oe_o)
;;
