(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "command_dispatch.ml" *)
(* P3.5 serial loader command dispatch: command legality, fixed lengths and device bounds,
   one-shot core offers, refusal classification, READ/VERIFY and ABORT completion waits,
   and selection of every response frame.

   It consumes [Frame_rx]'s deselect handoff and retained request fields as plain inputs
   and adds no request register. A frame that failed validation publishes its error
   response in the handoff cycle itself. A valid frame arms [dispatch] for the next cycle,
   which offers a legal core command exactly once (INFO, STATUS, and rejected commands
   offer nothing) and either publishes an immediate response or enters a completion wait;
   each wait ends by publishing its response. Publication is combinational, in the cycle
   the response is decided: [Hardware_loader] stores the frame at that edge, with no
   ready, queue, or pipeline stage. Neither the offers nor the publication are gated by
   reset or disable; the core refuses such an offer and the loader discards such a
   response.

   [busy_o] covers dispatch and both waits. [Hardware_loader] keeps requests ineligible
   while [busy_o] is high or a response is retained, so the fields read here hold until
   the response is committed. docs/host_link_hl4b3_record.md records the ownership and
   timing contract. [check_wire_encodings] checks the response and payload layouts built
   here, and the fault and phase mapping STATUS relies on, against [Wire] whenever this
   block is elaborated; [Wire_crc] checks the CRC parameters.

   The core-facing side is [Control_port]: this block produces its [Request] and consumes
   its [Decision] and [Status], under the temporal contract recorded there.
*)

open! Core
open! Hardcaml
open! Signal
module Wire = Protemu_host_link_wire.Wire

(* Response sizing derived from the wire limits, and the descriptor INFO reports. *)
module Config = struct
  let max_response_bytes = Wire.Response.max_length
  let response_bits = max_response_bytes * 8

  (* The instruction specification's version, not the wire's. *)
  let isa_version = 1
  let memory_layout = Wire.Info.memory_layout_m16

  (* Every version-1 capability is implemented. *)
  let capabilities = Wire.Capability.all
end

(* STATUS reports the execution unit's fault kind and phase by wiring its encodings
   straight into the payload, with no translation logic. That is only correct while each
   stable wire value equals the internal value it reports. These functions are the
   mapping, and [check_wire_encodings] refuses to elaborate if the two diverge; a
   divergence needs an explicit translation here, never a renumbered wire value.

   Careful: [Execution_unit.Fault] and [Phase] are plain integers with no enumeration,
   so the check covers every wire value but cannot see a new internal value. Adding one
   there is a P3 protocol change that must add its [Wire] value first.
*)
let execution_fault : Wire.Fault_kind.t -> int = function
  | No_fault -> Execution_unit.Fault.none
  | Invalid_base -> Execution_unit.Fault.invalid_base
  | Invalid_extension -> Execution_unit.Fault.invalid_extension
  | Fetch_bounds -> Execution_unit.Fault.fetch_bounds
  | Truncated_extension -> Execution_unit.Fault.truncated_extension
  | Target_unrepresentable -> Execution_unit.Fault.target_unrepresentable
  | Mechanism_refused -> Execution_unit.Fault.mechanism_refused
  | Mechanism_completion -> Execution_unit.Fault.mechanism_completion
  | Unsolicited_completion -> Execution_unit.Fault.unsolicited_completion
  | Mechanism_protocol -> Execution_unit.Fault.mechanism_protocol
;;

let execution_phase : Wire.Phase.t -> int = function
  | Halted -> Execution_unit.Phase.halted
  | Fetch -> Execution_unit.Phase.fetch
  | Base_wait -> Execution_unit.Phase.base_wait
  | Extension_wait -> Execution_unit.Phase.extension_wait
  | Mechanism_offer -> Execution_unit.Phase.mechanism_offer
  | Mechanism_wait -> Execution_unit.Phase.mechanism_wait
  | Fault -> Execution_unit.Phase.fault
;;

(* Elaboration-time consistency between [Wire] and the fixed choices in [create]: the
   fault and phase mapping, the STATUS flag order and field widths, the literal response,
   INFO, and STATUS byte lists, the request payload fields, and the 5-bit
   [response_length_o]. Plain OCaml comparisons; they create no logic and cannot change
   emitted RTL.
*)
let check_wire_encodings () =
  let require condition message =
    if not condition then invalid_arg ("Command_dispatch: " ^ message)
  in
  let check_layout = Wire_layout.check ~owner:"Command_dispatch" in
  List.iter Wire.Fault_kind.all ~f:(fun fault ->
    require
      (Wire.Fault_kind.to_int fault = execution_fault fault)
      (sprintf
         "fault kind %d differs from the execution unit"
         (Wire.Fault_kind.to_int fault)));
  List.iter Wire.Phase.all ~f:(fun phase ->
    require
      (Wire.Phase.to_int phase = execution_phase phase)
      (sprintf "phase %d differs from the execution unit" (Wire.Phase.to_int phase)));
  List.iteri Wire.Status.Flag.all ~f:(fun index flag ->
    require (Wire.Status.Flag.bit flag = index) "STATUS flags are not listed in bit order");
  require (Execution_unit.Fault.width <= 8) "fault kind is wider than its STATUS byte";
  require (Execution_unit.Phase.width <= 8) "phase is wider than its STATUS byte";
  require (Config.max_response_bytes < 1 lsl 5) "response length output too narrow";
  Wire_layout.check_request_payload ~owner:"Command_dispatch";
  check_layout
    "response header"
    ~length:Wire.Response.header_length
    Wire.Response.Offset.
      [ magic, 1; version, 1; tag, 1; command, 1; result, 1; payload_length, 2 ];
  require
    (Wire.Response.Offset.payload = Wire.Response.header_length)
    "response payload does not follow the header";
  check_layout
    "INFO"
    ~length:Wire.Info.length
    Wire.Info.Offset.
      [ wire_major, 1
      ; wire_minor, 1
      ; isa_version, 1
      ; memory_layout, 1
      ; capabilities, 2
      ; memory_word_bits, 2
      ; memory_depth, 2
      ; max_request_payload_bytes, 2
      ; protocol_pin_count, 1
      ];
  check_layout
    "STATUS"
    ~length:Wire.Status.length
    Wire.Status.Offset.
      [ flags, 2
      ; image_length, 2
      ; words_written, 2
      ; words_verified, 2
      ; pc, 2
      ; fault_kind, 1
      ; phase, 1
      ]
;;

module I = struct
  type 'a t =
    { (* System clock domain; reset is synchronous and active high. Disable cancels
         dispatch and both waits. *)
      clock_i : 'a
    ; reset_i : 'a
    ; enable_i : 'a
    ; (* Frame_rx -> dispatcher: the one-cycle deselect handoff with its validation
         ([result_i] is a [Wire.Result_code]; [echo_valid_i] means tag and command
         arrived), and the retained request fields, which hold while [busy_o] is high. *)
      frame_end_i : 'a
    ; result_i : 'a [@bits 8]
    ; echo_valid_i : 'a
    ; tag_i : 'a [@bits 8]
    ; command_i : 'a [@bits 8]
    ; payload_length_i : 'a [@bits 16]
    ; payload_i : 'a [@bits 32]
    ; (* Core decisions and status, observed before each edge; see [Control_port]. *)
      control_decision_i : 'a Control_port.Decision.t [@rtlsuffix "_i"]
    ; control_status_i : 'a Control_port.Status.t [@rtlsuffix "_i"]
    }
  [@@deriving hardcaml ~rtlmangle:false]
end

module O = struct
  type 'a t =
    { (* One-shot requests into the core. Operands are driven continuously from the
         retained fields. *)
      control_request_o : 'a Control_port.Request.t [@rtlsuffix "_o"]
    ; (* Dispatch or a completion wait is in progress. *)
      busy_o : 'a
    ; (* Dispatcher -> loader: store this response frame at this edge. There is no ready;
         the loader never has a retained response while a request can be handed off. *)
      response_publish_o : 'a
    ; response_frame_o : 'a [@bits Config.response_bits]
    ; response_length_o : 'a [@bits 5]
    }
  [@@deriving hardcaml ~rtlmangle:false]
end

[@@@ocamlformat "disable"]

(* Registered dispatch and completion state. Fields hold unless explicitly assigned by
   [compile]; reset clears every field.
*)
module I_Regs = struct
  type 'a t =
    { dispatch   : 'a
    ; wait_read  : 'a
    ; wait_abort : 'a
    }
  [@@deriving hardcaml]
end

(* Combinational response publication; zero unless a statement publishes. When several
   statements publish in one cycle, the last one's frame is the one presented.
*)
module I_Wires = struct
  type 'a t =
    { response_publish : 'a
    ; response_frame   : 'a [@bits Config.response_bits]
    ; response_length  : 'a [@bits 5]
    }
  [@@deriving hardcaml]
end

let byte value = of_int_trunc ~width:8 value
let result_code code = byte (Wire.Result_code.to_int code)

(* Little-endian bytes of a u16 constant; a wider value is an elaboration error, never a
   truncated field.
*)
let low_byte value = value land 0xff

let high_byte value =
  if value < 0 || value > 0xffff then invalid_argf "Command_dispatch: %d is not a u16" value ();
  value lsr 8
;;

(* Payload byte lists are built literally below; their lengths must match [Wire]. *)
let check_payload name payload ~length =
  if List.length payload <> length
  then
    invalid_argf "Command_dispatch: %s payload is %d bytes, expected %d"
      name (List.length payload) length ()
;;

let crc8 bytes =
  List.fold bytes
    ~init:(of_int_trunc ~width:Wire.Crc.width Wire.Crc.initial)
    ~f:Wire_crc.crc8_byte
;;

let response_frame ~tag ~command ~result payload =
  let payload_length = List.length payload in
  let body =
    [ byte Wire.Response.magic
    ; byte Wire.Version.byte
    ; tag
    ; command
    ; result
    ; byte payload_length
    ; zero 8
    ]
    @ payload
  in
  let frame = body @ [ crc8 body ] in
  let padding = List.init (Config.max_response_bytes - List.length frame) ~f:(fun _ -> zero 8) in
  concat_msb (frame @ padding), of_int_trunc ~width:5 (List.length frame)
;;

let choose_response condition (true_frame, true_length) (false_frame, false_length) =
  mux2 condition true_frame false_frame, mux2 condition true_length false_length
;;

let create (scope : Scope.t) (i : _ I.t) : _ O.t =
  check_wire_encodings ();
  let open Always in
  let spec = Reg_spec.create ~clock:i.clock_i ~clear:i.reset_i () in
  let r = I_Regs.Of_always.reg spec in
  I_Regs.Of_always.apply_names ~prefix:"reg_" ~naming_op:(Scope.naming scope) r;
  let w = I_Wires.Of_always.wire Signal.zero in
  I_Wires.Of_always.apply_names ~prefix:"wire_" ~naming_op:(Scope.naming scope) w;
  let decision = i.control_decision_i in
  let status   = i.control_status_i in

  (* [Frame_rx]'s retained fields; payload integers are little-endian on the wire. *)
  let request_tag     = i.tag_i in
  let request_command = i.command_i in
  let payload_length  = i.payload_length_i in

  let payload_u16 offset = select i.payload_i ~high:((8 * offset) + 15) ~low:(8 * offset) in
  let payload_address = payload_u16 Wire.Request.Payload_offset.address in
  let payload_word    = payload_u16 Wire.Request.Payload_offset.word in
  let address_in_range = select payload_address ~high:15 ~low:8 ==:. 0 in
  let length_in_range =
    (payload_address >:. 0) &: (payload_address <=:. Program_memory_controller.Config.program_depth)
  in
  let request_address = sel_bottom payload_address ~width:Program_memory_controller.Config.request_address_bits in

  let command_is command = request_command ==:. Wire.Command.to_int command in
  let payload_length_is value = payload_length ==:. value in
  (* The command's one legal request payload length. *)
  let payload_length_fits command =
    payload_length_is (Wire.Command.request_payload_length command)
  in
  let load_start_offer =
    r.dispatch.value &: command_is Load_start &: payload_length_fits Load_start &: length_in_range
  in
  let write_offer =
    r.dispatch.value &: command_is Write_word &: payload_length_fits Write_word &: address_in_range
  in
  let read_offer =
    r.dispatch.value
    &: (command_is Read_word |: command_is Verify_word)
    &: mux2 (command_is Read_word) (payload_length_fits Read_word) (payload_length_fits Verify_word)
    &: address_in_range
  in
  let complete_offer =
    r.dispatch.value &: command_is Load_complete &: payload_length_fits Load_complete
  in
  let run_offer = r.dispatch.value &: command_is Run &: payload_length_fits Run in
  let stop_offer = r.dispatch.value &: command_is Stop &: payload_length_fits Stop in
  let abort_offer = r.dispatch.value &: command_is Abort &: payload_length_fits Abort in

  let refusal_result =
    mux2 (~:(status.halted)) (result_code Active_execution)
      (mux2 (~:(status.engines_idle)) (result_code Engines_active)
         (mux2 (command_is Run &: ~:(status.image_valid))
            (result_code No_verified_image)
            (result_code Image_bounds)))
  in
  let empty_response result =
    response_frame ~tag:request_tag ~command:request_command ~result []
  in
  let complete_response = empty_response (result_code Complete) in
  let refused_response = empty_response refusal_result in
  let bad_length_response = empty_response (result_code Bad_length) in
  let image_bounds_response = empty_response (result_code Image_bounds) in
  let bad_command_response = empty_response (result_code Bad_command) in
  let stop_response = empty_response (result_code Accepted_pending) in
  let read_response result data =
    response_frame
      ~tag:request_tag
      ~command:request_command
      ~result
      [ select data ~high:7 ~low:0; select data ~high:15 ~low:8 ]
  in
  let info_payload =
    [ byte Wire.Version.major
    ; byte Wire.Version.minor
    ; byte Config.isa_version
    ; byte Config.memory_layout
    ; byte (low_byte (Wire.Capability.mask Config.capabilities))
    ; byte (high_byte (Wire.Capability.mask Config.capabilities))
    ; byte (low_byte Program_memory_controller.Config.program_width)
    ; byte (high_byte Program_memory_controller.Config.program_width)
    ; byte (low_byte Program_memory_controller.Config.program_depth)
    ; byte (high_byte Program_memory_controller.Config.program_depth)
    ; byte (low_byte Wire.Request.max_payload_length)
    ; byte (high_byte Wire.Request.max_payload_length)
    ; byte Protemu_isa.Pins.count
    ]
  in
  check_payload "INFO" info_payload ~length:Wire.Info.length;
  let info_response =
    response_frame
      ~tag:request_tag
      ~command:request_command
      ~result:(result_code Complete)
      info_payload
  in
  (* One signal per [Wire.Status.Flag]; [Flag.all] is in bit order and the reserved high
     bits are zero.
  *)
  let status_flag : Wire.Status.Flag.t -> Signal.t = function
    | Enabled             -> i.enable_i
    | Halted              -> status.halted
    | Engines_idle        -> status.engines_idle
    | Image_valid         -> status.image_valid
    | Load_active         -> status.load_active
    | Verification_failed -> status.verification_failed
    | Execution_active    -> status.execution_active
    | Normal_halt         -> status.normal_halt
    | Execution_fault     -> status.execution_fault
    | Fetch_fault         -> status.fetch_fault
    | Pin_output_enabled  -> status.pin_oe <>:. 0
    | Pin_claimed         -> (status.software_claim |: status.engine_claim) <>:. 0
  in
  let status_flags =
    concat_lsb
      (List.map Wire.Status.Flag.all ~f:status_flag
       @ [ zero (Wire.Status.Flag.width - List.length Wire.Status.Flag.all) ])
  in
  let le16 value = [ select value ~high:7 ~low:0; select value ~high:15 ~low:8 ] in
  let status_payload =
    le16 status_flags
    @ le16 (uresize status.image_length ~width:16)
    @ le16 (uresize status.words_written ~width:16)
    @ le16 (uresize status.words_verified ~width:16)
    @ le16 (uresize status.pc ~width:16)
    @ [ uresize status.fault_kind ~width:8; uresize status.phase ~width:8 ]
  in
  check_payload "STATUS" status_payload ~length:Wire.Status.length;
  let status_response =
    response_frame
      ~tag:request_tag
      ~command:request_command
      ~result:(result_code Complete)
      status_payload
  in
  (* A framing error echoes tag and command only when [Frame_rx] received both. *)
  let parser_error_response =
    response_frame
      ~tag:(mux2 i.echo_valid_i request_tag (zero 8))
      ~command:(mux2 i.echo_valid_i request_command (zero 8))
      ~result:i.result_i
      []
  in

  let abort_clean =
    status.halted
    &: status.engines_idle
    &: (status.pin_oe ==:. 0)
    &: (status.software_claim ==:. 0)
    &: (status.engine_claim ==:. 0)
  in
  let publish (frame, length) =
    [ w.response_frame <-- frame
    ; w.response_length <-- length
    ; w.response_publish <--. 1
    ]
  in
  let load_start_response =
    choose_response decision.load_start_accepted complete_response refused_response
  in
  let load_write_response =
    choose_response decision.load_write_accepted complete_response refused_response
  in
  let load_complete_response =
    choose_response decision.load_complete_accepted complete_response refused_response
  in
  let run_response =
    choose_response decision.run_accepted complete_response refused_response
  in
  let stop_completion_response =
    choose_response decision.stop_accepted stop_response refused_response
  in
  let verify_mismatch =
    command_is Verify_word &: ~:(decision.readback_response_match)
  in
  let read_completion_response =
    read_response
      (mux2 verify_mismatch (result_code Verification_mismatch) (result_code Complete))
      decision.readback_response_data
  in

  (* Registers hold and the publication wires are zero by default. The handoff, dispatch,
     and both completions are published in this order, so the last to fire in a cycle
     wins; disable is last and cancels dispatch and both waits, but does not suppress a
     publication, which the loader's own disable handles.
  *)
  compile
    [ r.dispatch <-- r.dispatch.value
    ; r.wait_read <-- r.wait_read.value
    ; r.wait_abort <-- r.wait_abort.value

    ; (* [Frame_rx] validates the complete frame at deselect, before any core-facing
         request exists. *)
      when_ i.frame_end_i
        [ if_ (i.result_i ==:. Wire.Result_code.to_int Complete)
            [ r.dispatch <--. 1 ]
            (publish parser_error_response)
        ]

    ; (* Immediate commands and one-shot request decisions. *)
      when_ r.dispatch.value
        [ r.dispatch <--. 0
        ; if_ (command_is Info)
            [ if_ (payload_length_fits Info)
                (publish info_response)
                (publish bad_length_response)
            ]
            [ if_ (command_is Status)
                [ if_ (payload_length_fits Status)
                    (publish status_response)
                    (publish bad_length_response)
                ]
                [ if_ (command_is Load_start)
                    [ if_ (~:(payload_length_fits Load_start))
                        (publish bad_length_response)
                        [ if_ length_in_range
                            (publish load_start_response)
                            (publish image_bounds_response)
                        ]
                    ]
                    [ if_ (command_is Write_word)
                        [ if_ (~:(payload_length_fits Write_word))
                            (publish bad_length_response)
                            [ if_ address_in_range
                                (publish load_write_response)
                                (publish image_bounds_response)
                            ]
                        ]
                        [ if_ (command_is Read_word |: command_is Verify_word)
                            [ if_ (mux2 (command_is Read_word)
                                        (~:(payload_length_fits Read_word))
                                        (~:(payload_length_fits Verify_word)))
                                (publish bad_length_response)
                                [ if_ address_in_range
                                    [ if_ decision.readback_accepted
                                        [ r.wait_read <--. 1 ]
                                        (publish refused_response)
                                    ]
                                    (publish image_bounds_response)
                                ]
                            ]
                            [ if_ (command_is Load_complete)
                                [ if_ (~:(payload_length_fits Load_complete))
                                    (publish bad_length_response)
                                    (publish load_complete_response)
                                ]
                                [ if_ (command_is Run)
                                    [ if_ (~:(payload_length_fits Run))
                                        (publish bad_length_response)
                                        (publish run_response)
                                    ]
                                    [ if_ (command_is Stop)
                                        [ if_ (~:(payload_length_fits Stop))
                                            (publish bad_length_response)
                                            (publish stop_completion_response)
                                        ]
                                        [ if_ (command_is Abort)
                                            [ if_ (~:(payload_length_fits Abort))
                                                (publish bad_length_response)
                                                [ if_ decision.abort_accepted
                                                    [ r.wait_abort <--. 1 ]
                                                    (publish refused_response)
                                                ]
                                            ]
                                            (publish bad_command_response)
                                        ]
                                    ]
                                ]
                            ]
                        ]
                    ]
                ]
            ]
        ]
    ; when_
        (r.wait_read.value &: decision.readback_response_valid)
        ([ r.wait_read <--. 0 ] @ publish read_completion_response)
    ; when_ (r.wait_abort.value &: abort_clean)
        ([ r.wait_abort <--. 0 ] @ publish complete_response)

    ; (* Disable is cancellation, not a delayed wire timeout. *)
      when_ (~:(i.enable_i))
        [ r.dispatch <--. 0
        ; r.wait_read <--. 0
        ; r.wait_abort <--. 0
        ]
    ];

  { O.control_request_o =
      { Control_port.Request.load_start_valid = load_start_offer
      ; load_length         = request_address
      ; load_write_valid    = write_offer
      ; load_address        = request_address
      ; load_data           = payload_word
      ; load_complete_valid = complete_offer
      ; readback_valid      = read_offer
      ; readback_address    = request_address
      ; readback_verify     = command_is Verify_word
      ; readback_expected   = payload_word
      ; run_valid           = run_offer
      ; stop_valid          = stop_offer
      ; abort_valid         = abort_offer
      }
  ; busy_o             = r.dispatch.value |: r.wait_read.value |: r.wait_abort.value
  ; response_publish_o = w.response_publish.value
  ; response_frame_o   = w.response_frame.value
  ; response_length_o  = w.response_length.value
  }
;;
[@@@ocamlformat "enable"]
