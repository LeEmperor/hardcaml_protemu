(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "sim_cli.ml" *)
(* P3.4 command-line presentation for one in-process simulator session.

   The script command owns one backend from the first line through the last. Each output
   line is one versioned S-expression, making the workflow usable by people and scripts
   without making the command parser part of the portable host API.
*)

open! Core
open! Protemu_isa
module Api = Protemu_host.Host_api
module Backend = Protemu_simulator.Simulator_backend

let atom value = Sexp.Atom value
let field name value = Sexp.List [ atom name; value ]
let int_atom value = atom (Int.to_string value)

type session = { device : Backend.t }

let emit_at_cycle ~cycle ~line ~command ~status value =
  let output =
    Sexp.List
      [ atom "protemu-cli"
      ; field "version" (int_atom Api.Constants.cli_output_version)
      ; field "line" (int_atom line)
      ; field "command" (atom command)
      ; field "status" (atom status)
      ; field "cycle" (int_atom cycle)
      ; field "value" value
      ]
  in
  printf "%s\n" (Sexp.to_string output)
;;

let emit session ~line ~command ~status value =
  emit_at_cycle ~cycle:(Backend.status session.device).cycle ~line ~command ~status value
;;

let error operation detail = Error (Api.Error.Invalid_argument { operation; detail })

let parse_int operation text =
  try Ok (Int.of_string text) with
  | _ -> error operation (sprintf "invalid integer: %s" text)
;;

let parse_bool operation = function
  | "on" | "true" | "1" -> Ok true
  | "off" | "false" | "0" -> Ok false
  | value -> error operation (sprintf "expected on/off, got %s" value)
;;

let load_image path =
  try Api.Image.of_string (In_channel.read_all path) with
  | exn -> Error (Api.Error.Io (sprintf "%s: %s" path (Exn.to_string exn)))
;;

let exact_transfer queue (transfer : Api.Transfer.t) =
  match transfer.outcome with
  | Complete -> Ok (Api.Transfer.sexp_of_t transfer)
  (* The error constructor remains total for decoded/external values, but this wrapper
     never constructs [Transfer_incomplete] with [Complete]. *)
  | outcome ->
    Error
      (Api.Error.Transfer_incomplete
         { queue
         ; requested = transfer.requested
         ; transferred = transfer.transferred
         ; data = transfer.data
         ; outcome
         })
;;

let expect_equal operation expected actual sexp_of =
  if Poly.equal expected actual
  then Ok (sexp_of actual)
  else
    error
      operation
      (sprintf
         "expected %s, got %s"
         (Sexp.to_string_hum (sexp_of expected))
         (Sexp.to_string_hum (sexp_of actual)))
;;

let execute session tokens =
  let device = session.device in
  match tokens with
  | [ "discover" ] | [ "info" ] -> Ok (Api.Discovery.sexp_of_t (Backend.discover device))
  | [ "check-api"; major; minor ] ->
    Result.bind (parse_int "check-api" major) ~f:(fun major ->
      Result.bind (parse_int "check-api" minor) ~f:(fun minor ->
        Result.map
          (Api.require_api (Backend.discover device) { Api.Version.major; minor })
          ~f:(fun () -> atom "compatible")))
  | [ "check-isa"; id; version ] ->
    Result.bind (parse_int "check-isa" version) ~f:(fun version ->
      Result.map
        (Api.require_isa (Backend.discover device) ~id ~version)
        ~f:(fun () -> atom "compatible"))
  | [ "load"; path ] ->
    Result.bind (load_image path) ~f:(fun image ->
      Result.map (Backend.load_image device image) ~f:Api.Load_result.sexp_of_t)
  | [ "read"; address; count ] ->
    Result.bind (parse_int "read" address) ~f:(fun address ->
      Result.bind (parse_int "read" count) ~f:(fun count ->
        Result.map (Backend.read_program device ~address ~count) ~f:[%sexp_of: int list]))
  | "assert-read" :: address :: words when not (List.is_empty words) ->
    Result.bind (parse_int "assert-read" address) ~f:(fun address ->
      Result.bind
        (Result.all (List.map words ~f:(parse_int "assert-read")))
        ~f:(fun expected ->
          Result.bind
            (Backend.read_program device ~address ~count:(List.length expected))
            ~f:(fun actual ->
              expect_equal "assert-read" expected actual [%sexp_of: int list])))
  | [ "verify"; path ] ->
    Result.bind (load_image path) ~f:(fun image ->
      Result.map (Backend.verify_image device image) ~f:(fun () -> atom "verified"))
  | [ "loaded" ] -> Ok (Api.Loaded_image.sexp_of_t (Backend.loaded_image device))
  | [ "run" ] -> Result.map (Backend.run device) ~f:Api.Control_ack.sexp_of_t
  | [ "stop"; budget ] ->
    Result.bind (parse_int "stop" budget) ~f:(fun budget_cycles ->
      Result.map (Backend.stop device ~budget_cycles) ~f:Api.Control_ack.sexp_of_t)
  | [ "abort" ] -> Result.map (Backend.abort device) ~f:Api.Control_ack.sexp_of_t
  | [ "step"; budget ] ->
    Result.bind (parse_int "step" budget) ~f:(fun budget_cycles ->
      Result.map (Backend.step device ~budget_cycles) ~f:Api.Control_ack.sexp_of_t)
  | [ "status" ] -> Ok (Api.Status.sexp_of_t (Backend.status device))
  | [ "registers" ] -> Ok ([%sexp_of: int list] (Backend.status device).registers)
  | [ "assert-register"; index; value ] ->
    Result.bind (parse_int "assert-register" index) ~f:(fun index ->
      Result.bind (parse_int "assert-register" value) ~f:(fun expected ->
        match List.nth (Backend.status device).registers index with
        | None -> error "assert-register" "register index outside 0..7"
        | Some actual -> expect_equal "assert-register" expected actual Int.sexp_of_t))
  | [ "engine" ] -> Ok (Api.Engine_status.sexp_of_t (Backend.status device).engine)
  | [ "fault" ] -> Ok (Api.Fault.sexp_of_t (Backend.status device).fault)
  | [ "events" ] ->
    let status = Backend.status device in
    Ok [%sexp (status.events : int), (status.event_overflow : int)]
  | [ "pins" ] ->
    let status = Backend.status device in
    Ok
      [%sexp
        (status.pins : int), (status.pin_output_enable : int), (status.pin_snapshot : int)]
  | [ "assert-pins"; value; output_enable ] ->
    Result.bind (parse_int "assert-pins" value) ~f:(fun expected_value ->
      Result.bind (parse_int "assert-pins" output_enable) ~f:(fun expected_oe ->
        let status = Backend.status device in
        expect_equal
          "assert-pins"
          (expected_value, expected_oe)
          (status.pins, status.pin_output_enable)
          [%sexp_of: int * int]))
  | [ "pin-claim"; mask ] ->
    Result.bind (parse_int "pin-claim" mask) ~f:(fun mask ->
      Result.map
        (Backend.configure_pins device (Api.Pin_configuration.Claim mask))
        ~f:(fun () -> atom "configured"))
  | [ "pin-release"; mask ] ->
    Result.bind (parse_int "pin-release" mask) ~f:(fun mask ->
      Result.map
        (Backend.configure_pins device (Api.Pin_configuration.Release mask))
        ~f:(fun () -> atom "configured"))
  | "tx" :: budget :: bytes when not (List.is_empty bytes) ->
    Result.bind (parse_int "tx" budget) ~f:(fun budget_cycles ->
      Result.bind
        (Result.all (List.map bytes ~f:(parse_int "tx")))
        ~f:(fun bytes ->
          Result.bind (Backend.transmit device ~budget_cycles bytes) ~f:(fun transfer ->
            exact_transfer "host-tx" transfer)))
  | [ "rx"; count; budget ] ->
    Result.bind (parse_int "rx" count) ~f:(fun count ->
      Result.bind (parse_int "rx" budget) ~f:(fun budget_cycles ->
        Result.bind (Backend.receive device ~budget_cycles ~count) ~f:(fun transfer ->
          exact_transfer "host-rx" transfer)))
  | "assert-rx" :: budget :: bytes when not (List.is_empty bytes) ->
    Result.bind (parse_int "assert-rx" budget) ~f:(fun budget_cycles ->
      Result.bind
        (Result.all (List.map bytes ~f:(parse_int "assert-rx")))
        ~f:(fun expected ->
          Result.bind
            (Backend.receive device ~budget_cycles ~count:(List.length expected))
            ~f:(fun transfer ->
              Result.bind (exact_transfer "host-rx" transfer) ~f:(fun _ ->
                expect_equal "assert-rx" expected transfer.data [%sexp_of: int list]))))
  | [ "advance"; cycles ] ->
    Result.bind (parse_int "advance" cycles) ~f:(fun cycles ->
      Result.map (Backend.advance device ~cycles) ~f:Api.Status.sexp_of_t)
  | [ "wait-halted"; budget ] ->
    Result.bind (parse_int "wait-halted" budget) ~f:(fun budget_cycles ->
      Result.map (Backend.wait_halted device ~budget_cycles) ~f:Api.Status.sexp_of_t)
  | [ "pad"; value ] ->
    Result.bind (parse_int "pad" value) ~f:(fun value ->
      Result.map (Backend.set_external_pins device value) ~f:(fun () -> atom "set"))
  | [ "occupied"; value ] ->
    Result.bind (parse_int "occupied" value) ~f:(fun value ->
      Result.map (Backend.set_occupied_pins device value) ~f:(fun () -> atom "set"))
  | [ "trace-enable"; enabled ] ->
    Result.bind (parse_bool "trace-enable" enabled) ~f:(fun enabled ->
      Result.map (Backend.trace_enable device enabled) ~f:(fun () ->
        atom (if enabled then "enabled" else "disabled")))
  | [ "trace-get" ] ->
    Result.map
      (Backend.trace_retrieve device ~after:None)
      ~f:Api.Trace.Retrieval.sexp_of_t
  | [ "trace-get"; cursor ] ->
    Result.bind (parse_int "trace-get" cursor) ~f:(fun cursor ->
      Result.map
        (Backend.trace_retrieve device ~after:(Some cursor))
        ~f:Api.Trace.Retrieval.sexp_of_t)
  | [ "assert-trace-overflow"; expected ] ->
    Result.bind (parse_bool "assert-trace-overflow" expected) ~f:(fun expected ->
      Result.bind (Backend.trace_retrieve device ~after:None) ~f:(fun trace ->
        expect_equal "assert-trace-overflow" expected trace.overflowed Bool.sexp_of_t))
  | [ "trace-clear" ] ->
    Result.map (Backend.trace_clear device) ~f:(fun () -> atom "cleared")
  | [] -> error "script" "empty command"
  | command :: _ -> error command "unknown command or wrong argument count"
;;

let tokens_of_line line =
  let command =
    match String.lsplit2 line ~on:'#' with
    | None -> line
    | Some (command, _) -> command
  in
  String.split command ~on:' ' |> List.filter ~f:(Fn.non String.is_empty)
;;

let execute_line session ~line_number tokens =
  match tokens with
  | "expect-error" :: code :: command ->
    let command_text = String.concat ~sep:" " tokens in
    (match execute session command with
     | Error actual when String.equal code (Api.Error.code actual) ->
       emit
         session
         ~line:line_number
         ~command:command_text
         ~status:"ok"
         [%sexp (code : string), (actual : Api.Error.t)];
       Ok ()
     | Error actual ->
       let reason =
         Api.Error.Invalid_argument
           { operation = "expect-error"
           ; detail =
               sprintf
                 "expected %s, got %s: %s"
                 code
                 (Api.Error.code actual)
                 (Sexp.to_string_hum (Api.Error.sexp_of_t actual))
           }
       in
       emit
         session
         ~line:line_number
         ~command:command_text
         ~status:"error"
         (Api.Error.sexp_of_t reason);
       Error reason
     | Ok value ->
       let reason =
         Api.Error.Invalid_argument
           { operation = "expect-error"
           ; detail =
               sprintf
                 "expected %s, command succeeded: %s"
                 code
                 (Sexp.to_string_hum value)
           }
       in
       emit
         session
         ~line:line_number
         ~command:command_text
         ~status:"error"
         (Api.Error.sexp_of_t reason);
       Error reason)
  | _ ->
    let command_text = String.concat ~sep:" " tokens in
    (match execute session tokens with
     | Ok value ->
       emit session ~line:line_number ~command:command_text ~status:"ok" value;
       Ok ()
     | Error reason ->
       emit
         session
         ~line:line_number
         ~command:command_text
         ~status:"error"
         (Api.Error.sexp_of_t reason);
       Error reason)
;;

let run_script ~trace_capacity path =
  try
    let session = { device = Backend.create ~trace_capacity () } in
    In_channel.read_lines path
    |> List.foldi ~init:(Ok ()) ~f:(fun index result line ->
      Result.bind result ~f:(fun () ->
        let tokens = tokens_of_line (String.strip line) in
        if List.is_empty tokens
        then Ok ()
        else execute_line session ~line_number:(index + 1) tokens))
  with
  | exn -> Error (Api.Error.Io (sprintf "%s: %s" path (Exn.to_string exn)))
;;

let validate_trace_capacity trace_capacity =
  if trace_capacity > 0
  then Ok ()
  else
    Error
      (Api.Error.Invalid_argument
         { operation = "session"; detail = "trace capacity must be positive" })
;;

let echo_image () =
  let program =
    { Program.name = "p3.4-queue-echo"
    ; items =
        List.map
          [ Instruction.Fifo_pop
              { fifo = Kinds.Fifo_id.Rx; rd = 0; blocking = Kinds.Blocking.Blocking }
          ; Fifo_push { fifo = Tx; rs = 0; blocking = Blocking }
          ; Halt
          ]
          ~f:Program.instr
    }
  in
  match Assembler.assemble ~memory:Assembler.Memory.word16 program with
  | Ok assembled -> Ok (Api.Image.of_assembled assembled)
  | Error reason ->
    Error
      (Api.Error.Invalid_argument
         { operation = "write-echo-image"
         ; detail = Sexp.to_string_hum (Invalid.sexp_of_t reason)
         })
;;

let info =
  Command.basic
    ~summary:"Discover the simulator API, ISA, memory, queues, engines, and trace"
    (let%map_open.Command trace_capacity =
       flag
         "trace-capacity"
         (optional_with_default 256 int)
         ~doc:"N bounded simulator trace records"
     in
     fun () ->
       match validate_trace_capacity trace_capacity with
       | Error reason ->
         emit_at_cycle
           ~cycle:0
           ~line:0
           ~command:"session"
           ~status:"error"
           (Api.Error.sexp_of_t reason);
         exit 2
       | Ok () ->
         let session = { device = Backend.create ~trace_capacity () } in
         emit
           session
           ~line:0
           ~command:"discover"
           ~status:"ok"
           (Api.Discovery.sexp_of_t (Backend.discover session.device)))
;;

let script =
  Command.basic
    ~summary:"Run host operations against one live simulator session"
    ~readme:(fun () ->
      {|One command is read per line. Blank lines and text after # are ignored. Commands:
discover; check-api MAJOR MINOR; check-isa ID VERSION; load FILE; read ADDRESS COUNT;
assert-read ADDRESS WORD...; verify FILE; loaded; run; stop BUDGET; abort; step BUDGET;
status; registers; assert-register INDEX VALUE; engine; fault; events; pins;
assert-pins VALUE OE; pin-claim MASK; pin-release MASK; tx BUDGET BYTE...;
rx COUNT BUDGET; assert-rx BUDGET BYTE...; advance CYCLES; wait-halted BUDGET;
pad VALUE; occupied MASK; trace-enable on|off; trace-get [CURSOR];
assert-trace-overflow BOOL; trace-clear. Prefix a command with `expect-error CODE` to
assert a defined failure and continue. Integers may use 0x. All output is one versioned
S-expression per executed line.|})
    (let%map_open.Command path = anon ("SCRIPT" %: string)
     and trace_capacity =
       flag
         "trace-capacity"
         (optional_with_default 256 int)
         ~doc:"N bounded simulator trace records"
     in
     fun () ->
       match validate_trace_capacity trace_capacity with
       | Error reason ->
         emit_at_cycle
           ~cycle:0
           ~line:0
           ~command:"session"
           ~status:"error"
           (Api.Error.sexp_of_t reason);
         exit 2
       | Ok () ->
         (match run_script ~trace_capacity path with
          | Ok () -> ()
          | Error reason ->
            eprintf
              "sim script failed: %s\n"
              (Sexp.to_string_hum (Api.Error.sexp_of_t reason));
            exit 2))
;;

let write_echo_image =
  Command.basic
    ~summary:"Assemble and write the P3.4 queue-echo image"
    (let%map_open.Command output_path =
       flag "output" (required string) ~doc:"FILE output metadata-bearing image"
     in
     fun () ->
       match echo_image () with
       | Error reason ->
         eprintf "%s\n" (Sexp.to_string_hum (Api.Error.sexp_of_t reason));
         exit 2
       | Ok image ->
         (try Out_channel.write_all output_path ~data:(Api.Image.to_string image) with
          | exn ->
            eprintf "%s: %s\n" output_path (Exn.to_string exn);
            exit 2))
;;

let command =
  Command.group
    ~summary:"Host API operations over the integrated-core simulator"
    [ "info", info; "script", script; "write-echo-image", write_echo_image ]
;;
