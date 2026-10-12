open! Core
open! Hardcaml
open! Hardcaml_protemu
module Sim = Cyclesim.With_interface (Primitive_demo.I) (Primitive_demo.O)

let bits width n = Bits.of_int_trunc ~width n

let check label signal expected =
  [%test_result: int] ~message:label ~expect:expected (Bits.to_int_trunc !signal)
;;
