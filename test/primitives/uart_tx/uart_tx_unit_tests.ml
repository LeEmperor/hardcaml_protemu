open! Core
open! Hardcaml
open! Hardcaml_protemu
open! Uart_tx_testbench

let%test_unit "P2.7 independent 8N1 receiver sees idle, start, data, and stop" =
  let sim = Sim.create (Uart_tx.create (Scope.create ~flatten_design:true ())) in
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
  let expected =
    Array.init 10 ~f:(function
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

let%test_unit "P2.7 typed UART descriptor matches hardware frame trace" =
  let descriptor =
    match F_model.Firmware_uart.tx_8n1 ~pin:0 ~half_period:4 ~byte:0xa6 with
    | Ok descriptor -> descriptor
    | Error _ -> failwith "valid UART descriptor rejected"
  in
  let sim = Sim.create (Uart_tx.create (Scope.create ~flatten_design:true ())) in
  let i = Cyclesim.inputs sim in
  let o = Cyclesim.outputs sim in
  i.reset_i := Bits.vdd;
  i.enable_i := Bits.vdd;
  Cyclesim.cycle sim;
  i.reset_i := Bits.gnd;
  i.byte_valid_i := Bits.vdd;
  i.byte_i := bits 8 0xa6;
  i.half_period_i := bits 16 4;
  let model = ref F_model.Shift_engine.idle in
  for cycle = 0 to 81 do
    let command = if cycle = 0 then Some (descriptor, false) else None in
    i.byte_valid_i := if cycle = 0 then Bits.vdd else Bits.gnd;
    model
    := F_model.Shift_engine.step
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
