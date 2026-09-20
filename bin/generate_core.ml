(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "generate_core.ml" *)
(* Emit either the standalone P3.1a access controller or P3.2's executable composition.
   The external RAM is intentionally not part of either circuit. *)

open! Core
open! Hardcaml
open! Hardcaml_protemu

let () =
  let args = Sys.get_argv () in
  if Array.length args <> 3
  then failwith "usage: generate_core.exe (access|executable) OUTPUT.v";
  let scope = Scope.create ~flatten_design:true () in
  let circuit =
    match args.(1) with
    | "access" ->
      let module C = Circuit.With_interface (Protocol_core.I) (Protocol_core.O) in
      C.create_exn ~name:"protocol_core" (Protocol_core.create scope)
    | "executable" ->
      let module C = Circuit.With_interface (Executable_core.I) (Executable_core.O) in
      C.create_exn ~name:"executable_core" (Executable_core.create scope)
    | mode -> failwithf "unknown core mode %S" mode ()
  in
  let rtl = Rtl.create Verilog [ circuit ] |> Rtl.full_hierarchy |> Rope.to_string in
  Out_channel.write_all args.(2) ~data:rtl
;;
