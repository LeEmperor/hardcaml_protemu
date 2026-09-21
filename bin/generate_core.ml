(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "generate_core.ml" *)
(* Emit a standalone P3 access, execution, integration, or serial-loader composition. The
   external RAM is intentionally not part of any circuit. *)

open! Core
open! Hardcaml
open! Hardcaml_protemu

let () =
  let args = Sys.get_argv () in
  if Array.length args <> 3
  then failwith "usage: generate_core.exe (access|executable|integrated|loader) OUTPUT.v";
  let scope = Scope.create ~flatten_design:true () in
  let circuit =
    match args.(1) with
    | "access" ->
      let module C = Circuit.With_interface (Protocol_core.I) (Protocol_core.O) in
      C.create_exn ~name:"protocol_core" (Protocol_core.create scope)
    | "executable" ->
      let module C = Circuit.With_interface (Executable_core.I) (Executable_core.O) in
      C.create_exn ~name:"executable_core" (Executable_core.create scope)
    | "integrated" ->
      let module C = Circuit.With_interface (Integrated_core.I) (Integrated_core.O) in
      C.create_exn ~name:"integrated_core" (Integrated_core.create scope)
    | "loader" ->
      let module C = Circuit.With_interface (Loader_core.I) (Loader_core.O) in
      C.create_exn ~name:"loader_core" (Loader_core.create scope)
    | mode -> failwithf "unknown core mode %S" mode ()
  in
  let rtl = Rtl.create Verilog [ circuit ] |> Rtl.full_hierarchy |> Rope.to_string in
  Out_channel.write_all args.(2) ~data:rtl
;;
