(* P0.7 integration of protemu's consumer with hardcaml_asic's registered RAM. *)

open! Core
open! Hardcaml
open! Hardcaml_asic
open! Hardcaml_protemu
open! Protemu_f_model
open! Protocol_core_testbench

let build = Program_memory_backend_design.build

let check_resource build ~mode =
  let resource = List.hd_exn (Build.resources build) in
  let actual = Sexp.to_string_hum ([%sexp_of: Resource_record.t] resource) in
  List.iter
    [ "program"
    ; "single_port_ram"
    ; "(width 16)"
    ; "(depth 256)"
    ; "(read_latency 1)"
    ; "(requirement Flops)"
    ; "(implementation Flops)"
    ; "(reason Explicit_flops)"
    ]
    ~f:(fun expected ->
      if not (String.is_substring actual ~substring:expected)
      then
        raise_s
          [%message "resource record missing field" (expected : string) (actual : string)]);
  let elaboration, source =
    match mode with
    | Elaboration_mode.Simulation -> "Behavioral_model", "Generated_behavioral_model"
    | Implementation -> "Selected_implementation", "Generated_synthesis_rtl"
  in
  List.iter [ elaboration; source ] ~f:(fun expected ->
    if not (String.is_substring actual ~substring:expected)
    then
      raise_s
        [%message "resource record has wrong mode" (expected : string) (actual : string)])
;;

let run mode =
  let build = build mode in
  check_resource build ~mode;
  let t = create ~circuit:(Build.circuit build) () in
  let words = [ 0x00ff; 0xa55a; 0xffff ] in
  complete_load t words;
  step t (input ~readback:(1, false, 0) ());
  check t.edge "read request has no same-edge response" None t.model.response.readback;
  step t (input ());
  check
    t.edge
    "registered read response after disabled port cycle"
    (Some (0xa55a, false))
    t.model.response.readback;
  step t (input ());
  check
    t.edge
    "held output is not consumed without validity"
    None
    t.model.response.readback;
  let before = memory_snapshot t in
  step t (input ~load_write:(3, 0x1234) ());
  check
    t.edge
    "rejected write did not alter valid storage"
    true
    (Array.equal (Option.equal Int.equal) before t.store.words);
  step t (input ~run:true ());
  step t (input ~fetch:2 ());
  step t (input ());
  check
    t.edge
    "fetch returned a defined written word"
    (Some 0xffff)
    t.model.response.fetch
;;

let run_acceptance mode =
  let build = build mode in
  check_resource build ~mode;
  let circuit = Build.circuit build in
  let create poison = create ~poison ~circuit () in
  Protocol_core_unit_tests.run_all create;
  match Protocol_core_property_tests.quickcheck ~circuit ~here:[%here] () with
  | None -> ()
  | Some failure -> failwith failure
;;

let%test_unit "behavioral RAM elaboration serves the protemu consumer" =
  run Elaboration_mode.Simulation
;;

let%test_unit "explicit flop RAM elaboration serves the protemu consumer" =
  run Elaboration_mode.Implementation
;;

let%test_unit "behavioral RAM reruns P3.1a directed and generated acceptance" =
  run_acceptance Elaboration_mode.Simulation
;;

let%test_unit "explicit flop RAM reruns P3.1a directed and generated acceptance" =
  run_acceptance Elaboration_mode.Implementation
;;
