open! Core
open! Hardcaml
open! Hardcaml_protemu

let default_output = "tinytapeout/src/p0_observable.v"
let default_module_name = "p0_observable"

let generate ~output ~module_name =
  let module Circuit = Circuit.With_interface (P0_observable.I) (P0_observable.O) in
  let circuit =
    Circuit.create_exn
      ~name:module_name
      (P0_observable.create (Scope.create ~flatten_design:true ()))
  in
  let rtl = Rtl.create Verilog [ circuit ] |> Rtl.full_hierarchy |> Rope.to_string in
  Out_channel.write_all output ~data:rtl;
  printf "Generated %s (%s, 8 pins, 4-bit delay)\n" output module_name
;;

let command =
  Command.basic
    ~summary:"Generate the phase-P0 observable pin/timer Verilog RTL"
    (let%map_open.Command output =
       flag
         "-output"
         (optional_with_default default_output string)
         ~doc:"PATH output Verilog path"
     and module_name =
       flag
         "-module-name"
         (optional_with_default default_module_name string)
         ~doc:"NAME generated Verilog module name"
     in
     fun () -> generate ~output ~module_name)
;;

let () = Command_unix.run command
