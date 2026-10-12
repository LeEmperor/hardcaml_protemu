(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "wire_crc.ml" *)
(* The synthesizable CRC-8 step shared by the host-link hardware.

   [Frame_rx] folds it over each received request byte and [Command_dispatch] over every
   response frame it builds, so both sides of the link use one hardware expression. The
   parameters come from [Wire.Crc], the P3.5 definition; the software CRC there is a
   separate implementation and is not used here. This is the one CRC the link needs, not a
   general CRC generator.

   The implementation is an MSB-first shift register with no reflection and no final XOR.
   [crc8_byte] checks at elaboration, every time it is used, that [Wire.Crc] still
   describes that; so the check runs whichever block is elaborated, alone or composed.
*)

open! Core
open! Hardcaml
open! Signal
module Wire = Protemu_host_link_wire.Wire

(* Plain OCaml; raises at circuit construction and creates no logic. *)
let check_parameters () =
  if not (Wire.Crc.width = 8 && (not Wire.Crc.reflected) && Wire.Crc.final_xor = 0)
  then invalid_arg "Wire_crc: CRC parameters are not supported by crc8_byte"
;;

(* One byte of CRC-8, MSB first, with no reflection or final XOR. *)
let crc8_byte crc data =
  check_parameters ();
  List.fold
    (List.init 8 ~f:(fun index -> 7 - index))
    ~init:crc
    ~f:(fun crc bit_index ->
      let feedback = bit crc ~pos:7 ^: bit data ~pos:bit_index in
      mux2 feedback (sll crc ~by:1 ^:. Wire.Crc.polynomial) (sll crc ~by:1))
;;
