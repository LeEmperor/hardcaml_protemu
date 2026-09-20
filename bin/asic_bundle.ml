(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "asic_bundle.ml" *)
(* ASIC project declaration for the current Tiny Tapeout observable top.

   Everything the Tiny Tapeout CMOS5L template fixes -- the wrapper ports, the LibreLane
   template settings and the reset and pad-gating idiom -- comes from Tt_cmos5l. What is
   left below is this chip: which core it wraps, how its pins are used, how fast it runs,
   and what it declares as its own source inputs. *)

open! Core
open! Hardcaml
open! Hardcaml_asic
open! Hardcaml_protemu

module Observable_design = struct
  module I = Tt_cmos5l.I
  module O = Tt_cmos5l.O

  let name = "tt_um_leemperor_hardcaml_protemu"

  let create context (i : _ I.t) =
    let open Signal in
    let core_reset = Tt_cmos5l.synchronised_reset ~clock:i.clk ~rst_n:i.rst_n () in
    let core =
      P0_observable.create
        (Elaboration_context.scope context)
        { P0_observable.I.clock_i = i.clk
        ; reset_i = core_reset
        ; enable_i = i.ena
        ; command_valid_i = bit i.ui_in ~pos:6
        ; delay_i = select i.ui_in ~high:3 ~low:0
        ; pin_value_i = concat_msb [ zero 7; bit i.ui_in ~pos:4 ]
        ; pin_oe_i = concat_msb [ zero 7; bit i.ui_in ~pos:5 ]
        }
    in
    (* The status byte is held low through the core reset as well, so a reader cannot
       mistake the reset state of the timer for a command result. *)
    let pads_enabled = i.rst_n &: i.ena in
    { O.uo_out =
        Tt_cmos5l.gate
          ~enable:(pads_enabled &: ( ~: ) core_reset)
          (concat_msb
             [ core.rejected_o; core.done_o; core.busy_o; core.ready_o; core.timer_o ])
    ; uio_out = Tt_cmos5l.gate ~enable:pads_enabled core.pins_o
    ; uio_oe = Tt_cmos5l.gate ~enable:pads_enabled core.pin_oe_o
    }
  ;;
end

module Memory_design = struct
  module I = Tt_cmos5l.I
  module O = Tt_cmos5l.O

  let name = "tt_um_leemperor_hardcaml_protemu_memory"

  (* P0.7 test protocol: uio_in[7:5] selects one request and ui_in carries an
     address/length (zero denotes length 256 for load-start only). Opcodes 7 and 6 stage
     the high and low word bytes before a write or verification request. Read responses
     return the high byte on uo_out and low byte on uio_out. *)
  let create context (i : _ I.t) =
    let open Signal in
    let core_reset = Tt_cmos5l.synchronised_reset ~clock:i.clk ~rst_n:i.rst_n () in
    let request = select i.uio_in ~high:7 ~low:5 in
    let request_is value = request ==:. value in
    let request_address = uresize i.ui_in ~width:9 in
    let request_length =
      mux2 (i.ui_in ==:. 0) (of_int_trunc ~width:9 256) request_address
    in
    let adapter_spec = Reg_spec.create ~clock:i.clk ~clear:core_reset () in
    let staged_high = reg adapter_spec ~enable:(request_is 7) i.ui_in in
    let staged_low = reg adapter_spec ~enable:(request_is 6) i.ui_in in
    let request_word = concat_msb [ staged_high; staged_low ] in
    let memory_read_data = wire Protocol_core.Config.program_width in
    let core =
      Protocol_core.create
        (Elaboration_context.scope context)
        { Protocol_core.I.clock_i = i.clk
        ; reset_i = core_reset
        ; en_i = i.ena
        ; engines_idle_i = vdd
        ; load_start_valid_i = request_is 1
        ; load_length_i = request_length
        ; load_write_valid_i = request_is 2
        ; load_address_i = request_address
        ; load_data_i = request_word
        ; load_complete_valid_i = request_is 4
        ; readback_valid_i = request_is 5 |: request_is 3
        ; readback_address_i = request_address
        ; readback_verify_i = request_is 3
        ; readback_expected_i = request_word
        ; run_valid_i = gnd
        ; execution_halt_i = gnd
        ; fetch_valid_i = gnd
        ; fetch_address_i = request_address
        ; prog_mem_read_data_i = memory_read_data
        }
    in
    let memory_config =
      Single_port_ram.Config.create_exn
        ~width:Protocol_core.Config.program_width
        ~depth:Protocol_core.Config.program_depth
        ~read_latency:1
    in
    let ram_read_data =
      Single_port_ram.create
        context
        ~name:"program"
        memory_config
        ~clock:i.clk
        ~enable:core.prog_mem_enable_o
        ~write_enable:core.prog_mem_write_enable_o
        ~address:core.prog_mem_address_o
        ~write_data:core.prog_mem_write_data_o
    in
    assign memory_read_data ram_read_data;
    let response_valid = core.readback_response_valid_o |: core.fetch_response_valid_o in
    let response_data =
      mux2
        core.readback_response_valid_o
        core.readback_response_data_o
        core.fetch_response_data_o
    in
    let accepted =
      core.load_start_accepted_o
      |: core.load_write_accepted_o
      |: core.load_complete_accepted_o
      |: core.readback_accepted_o
      |: core.run_accepted_o
      |: core.fetch_accepted_o
    in
    let rejected =
      core.load_start_rejected_o
      |: core.load_write_rejected_o
      |: core.load_complete_rejected_o
      |: core.readback_rejected_o
      |: core.run_rejected_o
      |: core.fetch_rejected_o
    in
    let status =
      concat_msb
        [ core.fetch_fault_o
        ; core.verification_failed_o
        ; core.image_valid_o
        ; core.load_active_o
        ; response_valid
        ; core.readback_response_match_o
        ; rejected
        ; accepted
        ]
    in
    let pads_enabled = i.rst_n &: i.ena &: ~:core_reset in
    { O.uo_out =
        Tt_cmos5l.gate
          ~enable:pads_enabled
          (mux2 response_valid (select response_data ~high:15 ~low:8) status)
    ; uio_out =
        Tt_cmos5l.gate
          ~enable:(pads_enabled &: response_valid)
          (select response_data ~high:7 ~low:0)
    ; uio_oe = Tt_cmos5l.gate ~enable:pads_enabled (repeat response_valid ~count:8)
    }
  ;;
end

let observable_pinout : Pinout.t =
  let descriptions = function
    | Pinout.Bank.Ui ->
      [ "P0 delay bit 0"
      ; "P0 delay bit 1"
      ; "P0 delay bit 2"
      ; "P0 delay bit 3"
      ; "P0 protocol pin 0 value"
      ; "P0 protocol pin 0 output enable"
      ; "P0 command valid"
      ; "Reserved"
      ]
    | Uo ->
      [ "Timer bit 0"
      ; "Timer bit 1"
      ; "Timer bit 2"
      ; "Timer bit 3"
      ; "Command ready"
      ; "Timer busy"
      ; "Command done pulse"
      ; "Command rejected pulse"
      ]
    | Uio -> List.init 8 ~f:(fun bit -> "Protocol pin " ^ Int.to_string bit)
  in
  List.concat_map [ Pinout.Bank.Ui; Uo; Uio ] ~f:(fun bank ->
    List.mapi (descriptions bank) ~f:(fun bit description ->
      { Pinout.bank; bit; description }))
;;

let memory_pinout : Pinout.t =
  let descriptions = function
    | Pinout.Bank.Ui ->
      List.init 8 ~f:(fun bit -> "Memory request address/length bit " ^ Int.to_string bit)
    | Uo ->
      [ "Status/response high bit 0"
      ; "Status/response high bit 1"
      ; "Status/response high bit 2"
      ; "Status/response high bit 3"
      ; "Status/response high bit 4"
      ; "Status/response high bit 5"
      ; "Status/response high bit 6"
      ; "Status/response high bit 7"
      ]
    | Uio ->
      [ "Reserved request input / response bit 0"
      ; "Reserved request input / response bit 1"
      ; "Reserved request input / response bit 2"
      ; "Reserved request input / response bit 3"
      ; "Reserved request input / response bit 4"
      ; "Memory request opcode bit 0 / response bit 5"
      ; "Memory request opcode bit 1 / response bit 6"
      ; "Memory request opcode bit 2 / response bit 7"
      ]
  in
  List.concat_map [ Pinout.Bank.Ui; Uo; Uio ] ~f:(fun bank ->
    List.mapi (descriptions bank) ~f:(fun bit description ->
      { Pinout.bank; bit; description }))
;;

let project ?(overrides = Tt_cmos5l.overrides ()) kind =
  let design, name, title, description, pinout =
    match kind with
    | "observable" ->
      ( (module Observable_design : Project.Design)
      , "protemu_observable"
      , "Hardcaml protocol emulator"
      , "Programmable protocol emulator primitives generated by Hardcaml"
      , observable_pinout )
    | "memory" ->
      ( (module Memory_design : Project.Design)
      , "protemu_memory"
      , "Hardcaml protocol emulator memory consumer"
      , "P0.7 whole-word load and readback through registered flop memory"
      , memory_pinout )
    | _ -> failwith "kind must be observable or memory"
  in
  Project.create
    ~name
    ~metadata:{ title; author = "Bohdan Purtell"; description }
    ~design
    ~target:
      { harness = Tiny_tapeout { tiles = T6x4 }; technology = Technology.ihp_sg13cmos5l }
    ~flow:(Flow.librelane ~overrides Hardening)
    ~clocks:[ { Clock.port = "clk"; period = Time_float.Span.of_sec (1. /. 48e6) } ]
    ~timing:
      { input_delays =
          List.map [ "ui_in"; "uio_in"; "ena"; "rst_n" ] ~f:(fun port ->
            { Hardcaml_asic.Timing.Delay.port
            ; minimum = Time_float.Span.of_ns 0.
            ; maximum = Time_float.Span.of_ns 1.
            })
      ; output_delays =
          List.map [ "uo_out"; "uio_out"; "uio_oe" ] ~f:(fun port ->
            { Hardcaml_asic.Timing.Delay.port
            ; minimum = Time_float.Span.of_ns 0.
            ; maximum = Time_float.Span.of_ns 2.
            })
      }
    ~pinout
    ~policy:(Resource_policy.create ~default:Flops [] |> Or_error.ok_exn)
    ()
;;

let input_paths kind =
  [ "dune-project"
  ; "hardcaml_protemu.opam"
  ; "bin/dune"
  ; "bin/asic_bundle.ml"
  ; "lib/dune"
  ; "tinytapeout/asic-dependencies.lock"
  ; "tinytapeout/toolchain.lock"
  ]
  @
  match kind with
  | "observable" -> [ "lib/p0_observable.ml" ]
  | "memory" -> [ "lib/protocol_core.ml" ]
  | _ -> failwith "kind must be observable or memory"
;;

let check_conflicts kind =
  List.iter
    [ "CLOCK_PERIOD", "clock"; "VERILOG_FILES", "source"; "DIE_AREA", "target" ]
    ~f:(fun (key, label) ->
      let conflicting : Flow.Librelane.Override.t =
        { key; value = `Int 1; reason = "negative integration check" }
      in
      let result =
        project ~overrides:(Tt_cmos5l.overrides ~extra:[ conflicting ] ()) kind
        |> Or_error.bind ~f:Project.elaborate_for_flow
      in
      match result with
      | Ok _ -> failwithf "%s conflict was accepted" label ()
      | Error error ->
        let diagnostic = Error.to_string_hum error in
        if not (String.is_substring diagnostic ~substring:key)
        then failwithf "%s conflict did not identify %s: %s" label key diagnostic ());
  printf "PASS clock, source-list, and target configuration conflicts\n"
;;

let () =
  match Array.to_list Stdlib.Sys.argv with
  | [ _; "--check-conflicts" ] -> check_conflicts "observable"
  | [ _; "--check-conflicts"; kind ] -> check_conflicts kind
  | [ _; output_dir; source_root ] ->
    let kind = "observable" in
    let project = project kind |> Or_error.ok_exn in
    let resolved = Project.elaborate_for_flow project |> Or_error.ok_exn in
    let simulation_build =
      Project.elaborate project ~mode:Simulation |> Or_error.ok_exn
    in
    let bundle =
      Bundle.render
        ~simulation_build
        ~source_root
        ~input_paths:(input_paths kind)
        resolved
      |> Or_error.ok_exn
    in
    Bundle.write bundle ~output_dir |> Or_error.ok_exn;
    printf "%s %s\n" output_dir (Bundle.identity bundle)
  | [ _; kind; output_dir; source_root ] ->
    let project = project kind |> Or_error.ok_exn in
    let resolved = Project.elaborate_for_flow project |> Or_error.ok_exn in
    let simulation_build =
      Project.elaborate project ~mode:Simulation |> Or_error.ok_exn
    in
    let bundle =
      Bundle.render
        ~simulation_build
        ~source_root
        ~input_paths:(input_paths kind)
        resolved
      |> Or_error.ok_exn
    in
    Bundle.write bundle ~output_dir |> Or_error.ok_exn;
    printf "%s %s\n" output_dir (Bundle.identity bundle)
  | _ ->
    failwith
      "usage: asic_bundle [observable|memory] OUTPUT_DIR SOURCE_ROOT | --check-conflicts \
       [observable|memory]"
;;
