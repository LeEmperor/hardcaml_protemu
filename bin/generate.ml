open! Core

let command =
  Command.basic
    ~summary:"Generate Verilog RTL for hardcaml_protemu"
    (let%map_open.Command () = return () in
     fun () -> print_endline "no circuits yet")
;;

let () = Command_unix.run command
