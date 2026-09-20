(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "emit_program_memory_backend.ml" *)
(* Emit either source role of the verification-only memory-bearing consumer. *)

open! Core
open! Hardcaml
open! Hardcaml_asic

let () =
  let mode, output =
    match Array.to_list (Sys.get_argv ()) with
    | [ _; "simulation"; output ] -> Elaboration_mode.Simulation, output
    | [ _; "implementation"; output ] -> Implementation, output
    | _ -> failwith "usage: emit_program_memory_backend (simulation|implementation) FILE"
  in
  let circuit = Program_memory_backend_design.build mode |> Build.circuit in
  let rtl = Rtl.create Verilog [ circuit ] |> Rtl.full_hierarchy |> Rope.to_string in
  Out_channel.write_all output ~data:rtl
;;
