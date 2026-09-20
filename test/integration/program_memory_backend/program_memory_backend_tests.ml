(* P0.7 integration of protemu's consumer with hardcaml_asic's registered RAM. *)

open! Core
open! Hardcaml
open! Hardcaml_asic
open! Hardcaml_protemu
open! Protemu_f_model
open! Protocol_core_testbench

module Design = struct
  module I = Protocol_core.I
  module O = Protocol_core.O

  let name = "protemu_program_memory_backend"

  let create context (i : _ I.t) =
    let read_data = Signal.wire Protocol_core.Config.program_width in
    let core =
      Protocol_core.create
        (Elaboration_context.scope context)
        { i with prog_mem_read_data_i = read_data }
    in
    let config =
      Single_port_ram.Config.create_exn
        ~width:Protocol_core.Config.program_width
        ~depth:Protocol_core.Config.program_depth
        ~read_latency:1
    in
    let ram_read_data =
      Single_port_ram.create
        context
        ~name:"program"
        config
        ~clock:i.clock_i
        ~enable:core.prog_mem_enable_o
        ~write_enable:core.prog_mem_write_enable_o
        ~address:core.prog_mem_address_o
        ~write_data:core.prog_mem_write_data_o
    in
    Signal.assign read_data ram_read_data;
    core
  ;;
end

let project () =
  Project.create
    ~name:"protemu_program_memory_backend"
    ~metadata:
      { title = "Protemu program memory backend test"
      ; author = "hardcaml_protemu"
      ; description = "Consumer integration with explicit flop-backed memory"
      }
    ~design:(module Design)
    ~target:
      { harness = Tiny_tapeout { tiles = T1x1 }; technology = Technology.ihp_sg13cmos5l }
    ~flow:(Flow.librelane Hardening)
    ~policy:(Resource_policy.create ~default:Flops [] |> Or_error.ok_exn)
    ()
  |> Or_error.ok_exn
;;

let build mode = Project.elaborate (project ()) ~mode |> Or_error.ok_exn

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

let%test_unit "behavioral RAM elaboration serves the protemu consumer" =
  run Elaboration_mode.Simulation
;;

let%test_unit "explicit flop RAM elaboration serves the protemu consumer" =
  run Elaboration_mode.Implementation
;;
