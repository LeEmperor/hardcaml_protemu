open! Hardcaml
open! Signal
open! Base

let () = Stdio.print_endline "bruh"

(* These are the main instruction types that the protocol CPU will function based off of.
*)
module Instruction_type = struct
  type t =
    | Write_pin
    | Write_pins
    | Config_Xfer
    | Xfer
    | Wait_done
end
