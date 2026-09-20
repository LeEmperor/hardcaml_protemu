(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "program_memory_backend_design.ml" *)
(* Verification-only composition of P3.1a's consumer and the context-registered RAM. *)

open! Core
open! Hardcaml
open! Hardcaml_asic
open! Hardcaml_protemu

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
