open! Core
open! Hardcaml
open! Hardcaml_protemu
open! Pin_bank_testbench

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

let%test_unit "P2.1 pin commits and ownership track the independent model" =
  let sim = Pin_sim.create (Pin_bank.create (Scope.create ~flatten_design:true ())) in
  let i = Cyclesim.inputs sim in
  let o = Cyclesim.outputs sim in
  i.reset_i := Bits.vdd;
  i.enable_i := Bits.vdd;
  Cyclesim.cycle sim;
  i.reset_i := Bits.gnd;
  let state = ref Protemu_f_model.Pin_bank.released in
  let commit mask value output_enable =
    i.write_valid_i := Bits.vdd;
    i.write_mask_i := bits 8 mask;
    i.write_value_i := bits 8 value;
    i.write_oe_i := bits 8 output_enable;
    let expected =
      Protemu_f_model.Pin_bank.commit
        !state
        { Protemu_f_model.Pin_bank.Write.mask; value; output_enable }
        ~owner:Kinds.Owner.Software
    in
    Cyclesim.cycle sim;
    i.write_valid_i := Bits.gnd;
    (match expected with
     | Ok next ->
       state := next;
       check "accepted write" o.rejected_o 0
     | Error _ -> check "rejected write" o.rejected_o 1);
    check "model value" o.pins_o !state.value;
    check "model output enable" o.pin_oe_o !state.output_enable
  in
  commit 0x0f 0x05 0x0f;
  commit 0xf0 0xa0 0x50;
  i.claim_valid_i := Bits.vdd;
  i.claim_engine_i := Bits.vdd;
  i.claim_mask_i := bits 8 0x30;
  (match
     Protemu_f_model.Pin_bank.claim !state ~owner:(Kinds.Owner.Engine 0) ~mask:0x30
   with
   | Ok next -> state := next
   | Error _ -> failwith "model claim was unexpectedly rejected");
  Cyclesim.cycle sim;
  i.claim_valid_i := Bits.gnd;
  commit 0x21 0x21 0x21;
  commit 0x40 0 0x40;
  i.abort_i := Bits.vdd;
  Cyclesim.cycle sim;
  state := Protemu_f_model.Pin_bank.released;
  check "model abort value" o.pins_o !state.value;
  check "model abort enable" o.pin_oe_o !state.output_enable
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
