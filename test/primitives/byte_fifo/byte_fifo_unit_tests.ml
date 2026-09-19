open! Core
open! Hardcaml
open! Hardcaml_protemu
open! Byte_fifo_testbench

let%test_unit "P2.4 full simultaneous pop/push preserves byte order" =
  let sim =
    Sim.create (Byte_fifo.create ~depth:4 (Scope.create ~flatten_design:true ()))
  in
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

let%test_unit "P2.4 simultaneous queue operations track the independent model" =
  let sim =
    Sim.create (Byte_fifo.create ~depth:4 (Scope.create ~flatten_design:true ()))
  in
  let i = Cyclesim.inputs sim in
  let o = Cyclesim.outputs sim in
  i.reset_i := Bits.vdd;
  i.enable_i := Bits.vdd;
  Cyclesim.cycle sim;
  i.reset_i := Bits.gnd;
  let fifo = ref (F_model.Fifo.create ~id:Kinds.Fifo_id.Tx ~depth:4) in
  for cycle = 0 to 99 do
    let push = if cycle mod 7 < 5 then Some (cycle land 255) else None in
    let pop = cycle mod 5 < 3 in
    i.push_valid_i := if Option.is_some push then Bits.vdd else Bits.gnd;
    i.push_data_i := bits 8 (Option.value push ~default:0);
    i.pop_ready_i := if pop then Bits.vdd else Bits.gnd;
    let next, popped, _, _ = F_model.Fifo.step !fifo ~push ~pop in
    (match popped with
     | None -> ()
     | Some byte -> check "model popped byte" o.pop_data_o byte);
    Cyclesim.cycle sim;
    fifo := next;
    check "model occupancy" o.count_o (F_model.Fifo.occupancy !fifo);
    check "model empty" o.pop_valid_o (if F_model.Fifo.is_empty !fifo then 0 else 1)
  done
;;

let%test_unit "P2.4 overflow and reset validity" =
  let sim =
    Sim.create (Byte_fifo.create ~depth:4 (Scope.create ~flatten_design:true ()))
  in
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

let%test_unit "P2.4 all configured FIFO depths preserve ordering" =
  List.iter [ 4; 8; 16 ] ~f:(fun depth ->
    let sim =
      Sim.create (Byte_fifo.create ~depth (Scope.create ~flatten_design:true ()))
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
