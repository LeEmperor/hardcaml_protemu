open! Core
open! Hardcaml
open! Hardcaml_protemu

module Sim = Cyclesim.With_interface (Input_events.I) (Input_events.O)
module F_model = Protemu_f_model

let bits width n = Bits.of_int_trunc ~width n

let check label signal expected =
  [%test_result: int] ~message:label ~expect:expected (Bits.to_int_trunc !signal)
;;
