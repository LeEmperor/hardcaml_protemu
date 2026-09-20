(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "generate_core.ml" *)
(* Emit the plain-Hardcaml P3.1a program-store consumer as standalone Verilog. The
   external RAM is intentionally not part of this circuit. *)

open! Core
open! Hardcaml
open! Hardcaml_protemu

let () =
  let args = Sys.get_argv () in
  if Array.length args <> 2 then failwith "usage: generate_core.exe OUTPUT.v";
  let module C = Circuit.With_interface (Protocol_core.I) (Protocol_core.O) in
  let scope = Scope.create ~flatten_design:true () in
  let circuit = C.create_exn ~name:"protocol_core" (Protocol_core.create scope) in
  let rtl = Rtl.create Verilog [ circuit ] |> Rtl.full_hierarchy |> Rope.to_string in
  Out_channel.write_all args.(1) ~data:rtl
;;
