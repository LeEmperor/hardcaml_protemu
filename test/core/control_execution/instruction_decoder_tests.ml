(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "instruction_decoder_tests.ml" *)
(* Exhaustive agreement checks between the shared procedural decoder and its Hardcaml
   reader. Extension values are swept at every semantic boundary used by the ISA. *)

open! Core
open! Hardcaml
open! Hardcaml_protemu
open! Protemu_isa
module Sim = Cyclesim.With_interface (Instruction_decoder.I) (Instruction_decoder.O)

let bool signal = Bits.to_bool !signal
let int signal = Bits.to_int_trunc !signal

let settle sim ~word ~extension_valid ~extension =
  let i : _ Instruction_decoder.I.t = Cyclesim.inputs sim in
  i.word_i := Bits.of_int_trunc ~width:Encoding.instruction_bits word;
  i.extension_valid_i := Bits.of_bool extension_valid;
  i.extension_i := Bits.of_int_trunc ~width:Encoding.instruction_bits extension;
  Cyclesim.cycle_check sim;
  Cyclesim.cycle_before_clock_edge sim;
  Cyclesim.outputs ~clock_edge:Before sim
;;

let fail ~word ~extension what expected actual =
  raise_s
    [%message
      "instruction decoder mismatch"
        (word : int)
        (extension : int option)
        (what : string)
        (expected : bool)
        (actual : bool)]
;;

let%test_unit "all base words agree with Encoding.decode" =
  let sim =
    Sim.create (Instruction_decoder.create (Scope.create ~flatten_design:true ()))
  in
  for word = 0 to 0xffff do
    let o = settle sim ~word ~extension_valid:false ~extension:0 in
    match Encoding.decode word with
    | Encoding.Decoded.Invalid _ ->
      if bool o.base_valid_o then fail ~word ~extension:None "base_valid" false true
    | Complete _ ->
      if not (bool o.base_valid_o) then fail ~word ~extension:None "base_valid" true false;
      if bool o.needs_extension_o
      then fail ~word ~extension:None "needs_extension" false true;
      if not (bool o.valid_o) then fail ~word ~extension:None "valid" true false
    | Needs_extension _ ->
      if not (bool o.base_valid_o) then fail ~word ~extension:None "base_valid" true false;
      if not (bool o.needs_extension_o)
      then fail ~word ~extension:None "needs_extension" true false;
      if bool o.valid_o then fail ~word ~extension:None "valid" false true
  done
;;

let extension_boundaries =
  [ 0; 1; 15; 16; 31; 32; 63; 64; 127; 128; 255; 256; 1023; 1024; 0xffff ]
;;

let%test_unit "extension resolution agrees at semantic boundaries" =
  let sim =
    Sim.create (Instruction_decoder.create (Scope.create ~flatten_design:true ()))
  in
  for word = 0 to 0xffff do
    match Encoding.decode word with
    | Encoding.Decoded.Needs_extension build ->
      List.iter extension_boundaries ~f:(fun extension ->
        let expected =
          match build extension with
          | Encoding.Decoded.Complete _ -> true
          | Invalid _ | Needs_extension _ -> false
        in
        let o = settle sim ~word ~extension_valid:true ~extension in
        let actual = bool o.valid_o in
        if Bool.(expected <> actual)
        then fail ~word ~extension:(Some extension) "extension valid" expected actual;
        if actual && int o.immediate_o <> extension
        then
          raise_s
            [%message
              "extension value mismatch"
                (word : int)
                (extension : int)
                ~actual:(int o.immediate_o : int)])
    | Complete _ | Invalid _ -> ()
  done
;;
