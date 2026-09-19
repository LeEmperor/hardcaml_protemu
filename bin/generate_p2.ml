(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "generate_p2.ml" *)
(* Emit a selected P2 primitive as standalone Verilog for direct RTL simulation and
   block cost studies. The generated circuit is independent of the P0 TT wrapper. *)

open! Core
open! Hardcaml
open! Hardcaml_protemu

let circuit block =
  let scope () = Scope.create ~flatten_design:true () in
  match block with
  | "pin_bank" ->
    let module C = Circuit.With_interface (Pin_bank.I) (Pin_bank.O) in
    C.create_exn ~name:block (Pin_bank.create (scope ()))
  | "input_events" ->
    let module C = Circuit.With_interface (Input_events.I) (Input_events.O) in
    C.create_exn ~name:block (Input_events.create (scope ()))
  | "timing" ->
    let module C = Circuit.With_interface (Timing.I) (Timing.O) in
    C.create_exn ~name:block (Timing.create (scope ()))
  | "byte_fifo_8" ->
    let module C = Circuit.With_interface (Byte_fifo.I) (Byte_fifo.O) in
    C.create_exn ~name:block (Byte_fifo.create ~depth:8 (scope ()))
  | "shift_lane" ->
    let module C = Circuit.With_interface (Shift_lane.I) (Shift_lane.O) in
    C.create_exn ~name:block (Shift_lane.create (scope ()))
  | "observed_transfer" ->
    let module C = Circuit.With_interface (Observed_transfer.I) (Observed_transfer.O) in
    C.create_exn ~name:block (Observed_transfer.create (scope ()))
  | "primitive_demo" ->
    let module C = Circuit.With_interface (Primitive_demo.I) (Primitive_demo.O) in
    C.create_exn ~name:block (Primitive_demo.create (scope ()))
  | "uart_tx" ->
    let module C = Circuit.With_interface (Uart_tx.I) (Uart_tx.O) in
    C.create_exn ~name:block (Uart_tx.create (scope ()))
  | _ -> failwith "unknown P2 block"
;;

let () =
  let args = Sys.get_argv () in
  if Array.length args <> 3
  then failwith "usage: generate_p2.exe BLOCK OUTPUT.v";
  let circuit = circuit args.(1) in
  let rtl = Rtl.create Verilog [ circuit ] |> Rtl.full_hierarchy |> Rope.to_string in
  Out_channel.write_all args.(2) ~data:rtl
;;
