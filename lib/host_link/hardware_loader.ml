(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "hardware_loader.ml" *)
(* P3.5 fixed serial loader and Integrated_core request adapter.

   The external host clock is observed through synchronizers; it never clocks logic. A
   complete CRC-protected request is retained before exactly one core request is offered.
   Responses are retained until explicitly committed, and an interrupted or rejected
   response restarts from byte zero without repeating the command. Program RAM and image
   validity remain exclusively owned by Protocol_core.
*)

open! Core
open! Hardcaml
open! Signal

module Config = struct
  let wire_version = 0x10
  let request_magic = 0xa5
  let response_magic = 0x5a
  let max_payload_bytes = 4
  let max_request_bytes = 6 + max_payload_bytes + 1
  let request_byte_count_bits = Int.ceil_log2 (max_request_bytes + 1)
  let max_response_bytes = 21
  let response_bits = max_response_bytes * 8
end

module Command = struct
  let info = 0x00
  let status = 0x01
  let load_start = 0x10
  let write_word = 0x11
  let read_word = 0x12
  let verify_word = 0x13
  let load_complete = 0x14
  let run = 0x20
  let stop = 0x21
  let abort = 0x22
end

module Result = struct
  let complete = 0x00
  let accepted_pending = 0x01
  let bad_magic = 0x10
  let bad_version = 0x11
  let bad_length = 0x12
  let bad_crc = 0x13
  let bad_command = 0x14
  let incomplete = 0x15
  let active_execution = 0x20
  let engines_active = 0x21
  let no_verified_image = 0x22
  let image_bounds = 0x23
  let verification_mismatch = 0x24
  let hardware_rejected = 0x2f
end

(* Stable INFO capability bits. These are wire definitions, not constructor positions from
   the transport-independent host API.
*)
module Capability = struct
  let status = 1 lsl 0
  let program_load = 1 lsl 1
  let program_read = 1 lsl 2
  let program_verify = 1 lsl 3
  let run = 1 lsl 4
  let stop = 1 lsl 5
  let abort = 1 lsl 6

  let supported =
    status lor program_load lor program_read lor program_verify lor run lor stop lor abort
  ;;
end

module I = struct
  type 'a t =
    { (* System clock domain; reset is synchronous and active high. *)
      clock_i : 'a
    ; reset_i : 'a
    ; enable_i : 'a
    ; (* Asynchronous physical loader pins. Select is active low, clock idles low. *)
      serial_select_n_i : 'a
    ; serial_clock_i : 'a
    ; serial_data_i : 'a
    ; (* Integrated_core request decisions and completion/status observations. *)
      load_start_accepted_i : 'a
    ; load_start_rejected_i : 'a
    ; load_write_accepted_i : 'a
    ; load_write_rejected_i : 'a
    ; load_complete_accepted_i : 'a
    ; load_complete_rejected_i : 'a
    ; readback_accepted_i : 'a
    ; readback_rejected_i : 'a
    ; readback_response_valid_i : 'a
    ; readback_response_data_i : 'a [@bits Protocol_core.Config.program_width]
    ; readback_response_match_i : 'a
    ; run_accepted_i : 'a
    ; run_rejected_i : 'a
    ; stop_accepted_i : 'a
    ; stop_rejected_i : 'a
    ; abort_accepted_i : 'a
    ; abort_rejected_i : 'a
    ; halted_i : 'a
    ; engines_idle_i : 'a
    ; image_valid_i : 'a
    ; load_active_i : 'a
    ; image_length_i : 'a [@bits Protocol_core.Config.request_address_bits]
    ; words_written_i : 'a [@bits Protocol_core.Config.request_address_bits]
    ; words_verified_i : 'a [@bits Protocol_core.Config.request_address_bits]
    ; verification_failed_i : 'a
    ; fetch_fault_i : 'a
    ; execution_active_i : 'a
    ; normal_halt_i : 'a
    ; execution_fault_i : 'a
    ; fault_kind_i : 'a [@bits Control_execution.Fault.width]
    ; pc_i : 'a [@bits Control_execution.Config.pc_bits]
    ; phase_i : 'a [@bits Control_execution.Phase.width]
    ; pin_oe_i : 'a [@bits Protemu_isa.Pins.count]
    ; software_claim_i : 'a [@bits Protemu_isa.Pins.count]
    ; engine_claim_i : 'a [@bits Protemu_isa.Pins.count]
    }
  [@@deriving hardcaml]
end

module O = struct
  type 'a t =
    { (* Physical response pins. Data is push-pull and meaningful while selected. *)
      serial_data_o : 'a
    ; serial_ready_o : 'a
    ; (* One-shot requests into Integrated_core. Operands remain retained while offered. *)
      load_start_valid_o : 'a
    ; load_length_o : 'a [@bits Protocol_core.Config.request_address_bits]
    ; load_write_valid_o : 'a
    ; load_address_o : 'a [@bits Protocol_core.Config.request_address_bits]
    ; load_data_o : 'a [@bits Protocol_core.Config.program_width]
    ; load_complete_valid_o : 'a
    ; readback_valid_o : 'a
    ; readback_address_o : 'a [@bits Protocol_core.Config.request_address_bits]
    ; readback_verify_o : 'a
    ; readback_expected_o : 'a [@bits Protocol_core.Config.program_width]
    ; run_valid_o : 'a
    ; stop_valid_o : 'a
    ; abort_valid_o : 'a
    ; busy_o : 'a
    }
  [@@deriving hardcaml]
end

[@@@ocamlformat "disable"]

(* Registered parser, dispatch, completion, and retained-response state. Fields hold unless
   explicitly assigned by [compile]; reset clears every field.
*)
module I_Regs = struct
  type 'a t =
    { select_meta      : 'a
    ; select_sync      : 'a
    ; select_previous  : 'a
    ; select_high_count : 'a [@bits 3]
    ; clock_meta       : 'a
    ; clock_sync       : 'a
    ; clock_previous   : 'a
    ; data_meta        : 'a
    ; data_sync        : 'a
    ; byte_shift       : 'a [@bits 8]
    ; bit_count        : 'a [@bits 3]
    ; byte_count       : 'a [@bits Config.request_byte_count_bits]
    ; request_active   : 'a
    ; request_overrun  : 'a
    ; request_magic    : 'a [@bits 8]
    ; request_version  : 'a [@bits 8]
    ; request_tag      : 'a [@bits 8]
    ; request_command  : 'a [@bits 8]
    ; payload_length   : 'a [@bits 16]
    ; payload          : 'a [@bits 32]
    ; request_crc      : 'a [@bits 8]
    ; crc_match        : 'a
    ; dispatch         : 'a
    ; wait_read        : 'a
    ; wait_abort       : 'a
    ; response_pending : 'a
    ; response_active  : 'a
    ; response_store   : 'a [@bits Config.response_bits]
    ; response_shift   : 'a [@bits Config.response_bits]
    ; response_length  : 'a [@bits 5]
    ; response_bits    : 'a [@bits 8]
    }
  [@@deriving hardcaml]
end

let byte value = of_int_trunc ~width:8 value

let crc8_byte crc data =
  List.fold (List.init 8 ~f:(fun index -> 7 - index)) ~init:crc ~f:(fun crc bit_index ->
    let feedback = bit crc ~pos:7 ^: bit data ~pos:bit_index in
    mux2 feedback ((sll crc ~by:1) ^:. 0x07) (sll crc ~by:1))
;;

let crc8 bytes = List.fold bytes ~init:(zero 8) ~f:crc8_byte

let response_frame ~tag ~command ~result payload =
  let payload_length = List.length payload in
  let body =
    [ byte Config.response_magic
    ; byte Config.wire_version
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
  let open Always in
  let spec = Reg_spec.create ~clock:i.clock_i ~clear:i.reset_i () in
  let r = I_Regs.Of_always.reg spec in
  I_Regs.Of_always.apply_names ~prefix:"reg_" ~naming_op:(Scope.naming scope) r;

  let selected_async = ~:(i.serial_select_n_i) in
  let select_assert = r.select_sync.value &: ~:(r.select_previous.value) in
  let select_release = ~:(r.select_sync.value) &: r.select_previous.value in
  let clock_rise = r.clock_sync.value &: ~:(r.clock_previous.value) in
  let clock_fall = ~:(r.clock_sync.value) &: r.clock_previous.value in
  let command_busy = r.dispatch.value |: r.wait_read.value |: r.wait_abort.value in
  let request_idle =
    ~:(r.request_active.value) &: ~:command_busy &: ~:(r.response_pending.value)
  in
  let receiving =
    i.enable_i &: r.select_sync.value &: r.request_active.value
  in
  let completed_byte = concat_lsb [ r.data_sync.value; select r.byte_shift.value ~high:6 ~low:0 ] in
  let expected_crc_index = uresize r.payload_length.value ~width:16 +:. 6 in
  let completed_byte_index = uresize r.byte_count.value ~width:16 in
  let completed_is_crc = completed_byte_index ==: expected_crc_index in
  let expected_frame_bytes = r.payload_length.value +:. 7 in
  let request_bytes = uresize r.byte_count.value ~width:16 in
  let request_complete =
    ~:(r.request_overrun.value)
    &: (r.bit_count.value ==:. 0)
    &: (request_bytes >=:. 7)
    &: (request_bytes ==: expected_frame_bytes)
  in

  let payload_address = select r.payload.value ~high:15 ~low:0 in
  let payload_word = select r.payload.value ~high:31 ~low:16 in
  let address_in_range = select payload_address ~high:15 ~low:8 ==:. 0 in
  let length_in_range =
    (payload_address >:. 0) &: (payload_address <=:. Protocol_core.Config.program_depth)
  in
  let request_address = sel_bottom payload_address ~width:Protocol_core.Config.request_address_bits in

  let command_is value = r.request_command.value ==:. value in
  let payload_length_is value = r.payload_length.value ==:. value in
  let load_start_offer =
    r.dispatch.value &: command_is Command.load_start &: payload_length_is 2 &: length_in_range
  in
  let write_offer =
    r.dispatch.value &: command_is Command.write_word &: payload_length_is 4 &: address_in_range
  in
  let read_offer =
    r.dispatch.value
    &: (command_is Command.read_word |: command_is Command.verify_word)
    &: mux2 (command_is Command.read_word) (payload_length_is 2) (payload_length_is 4)
    &: address_in_range
  in
  let complete_offer =
    r.dispatch.value &: command_is Command.load_complete &: payload_length_is 0
  in
  let run_offer = r.dispatch.value &: command_is Command.run &: payload_length_is 0 in
  let stop_offer = r.dispatch.value &: command_is Command.stop &: payload_length_is 0 in
  let abort_offer = r.dispatch.value &: command_is Command.abort &: payload_length_is 0 in

  let refusal_result =
    mux2 (~:(i.halted_i)) (byte Result.active_execution)
      (mux2 (~:(i.engines_idle_i)) (byte Result.engines_active)
         (mux2 (command_is Command.run &: ~:(i.image_valid_i))
            (byte Result.no_verified_image)
            (byte Result.image_bounds)))
  in
  let empty_response result =
    response_frame ~tag:r.request_tag.value ~command:r.request_command.value ~result []
  in
  let complete_response = empty_response (byte Result.complete) in
  let refused_response = empty_response refusal_result in
  let bad_length_response = empty_response (byte Result.bad_length) in
  let image_bounds_response = empty_response (byte Result.image_bounds) in
  let bad_command_response = empty_response (byte Result.bad_command) in
  let stop_response = empty_response (byte Result.accepted_pending) in
  let read_response result data =
    response_frame
      ~tag:r.request_tag.value
      ~command:r.request_command.value
      ~result
      [ select data ~high:7 ~low:0; select data ~high:15 ~low:8 ]
  in
  let info_payload =
    [ byte 1
    ; byte 0
    ; byte 1
    ; byte 1
    ; byte Capability.supported
    ; byte 0
    ; byte Protocol_core.Config.program_width
    ; byte 0
    ; byte 0
    ; byte 1
    ; byte Config.max_payload_bytes
    ; byte 0
    ; byte Protemu_isa.Pins.count
    ]
  in
  let info_response =
    response_frame
      ~tag:r.request_tag.value
      ~command:r.request_command.value
      ~result:(byte Result.complete)
      info_payload
  in
  let status_flags =
    concat_lsb
      [ i.enable_i
      ; i.halted_i
      ; i.engines_idle_i
      ; i.image_valid_i
      ; i.load_active_i
      ; i.verification_failed_i
      ; i.execution_active_i
      ; i.normal_halt_i
      ; i.execution_fault_i
      ; i.fetch_fault_i
      ; i.pin_oe_i <>:. 0
      ; (i.software_claim_i |: i.engine_claim_i) <>:. 0
      ; zero 4
      ]
  in
  let le16 value = [ select value ~high:7 ~low:0; select value ~high:15 ~low:8 ] in
  let status_payload =
    le16 status_flags
    @ le16 (uresize i.image_length_i ~width:16)
    @ le16 (uresize i.words_written_i ~width:16)
    @ le16 (uresize i.words_verified_i ~width:16)
    @ le16 (uresize i.pc_i ~width:16)
    @ [ uresize i.fault_kind_i ~width:8; uresize i.phase_i ~width:8 ]
  in
  let status_response =
    response_frame
      ~tag:r.request_tag.value
      ~command:r.request_command.value
      ~result:(byte Result.complete)
      status_payload
  in
  let parser_error =
    mux2 r.request_overrun.value (byte Result.bad_length)
      (mux2 (~:(request_complete)) (byte Result.incomplete)
      (mux2 (r.request_magic.value <>:. Config.request_magic) (byte Result.bad_magic)
         (mux2 (r.request_version.value <>:. Config.wire_version) (byte Result.bad_version)
            (mux2 (r.payload_length.value >:. Config.max_payload_bytes) (byte Result.bad_length)
               (mux2 (~:(r.crc_match.value)) (byte Result.bad_crc) (byte Result.complete))))))
  in
  let correlation_valid = r.byte_count.value >=:. 4 in
  let parser_error_response =
    response_frame
      ~tag:(mux2 correlation_valid r.request_tag.value (zero 8))
      ~command:(mux2 correlation_valid r.request_command.value (zero 8))
      ~result:parser_error
      []
  in

  let response_drained =
    r.response_bits.value ==: sll (uresize r.response_length.value ~width:8) ~by:3
  in
  let abort_clean =
    i.halted_i
    &: i.engines_idle_i
    &: (i.pin_oe_i ==:. 0)
    &: (i.software_claim_i ==:. 0)
    &: (i.engine_claim_i ==:. 0)
  in
  let set_response (frame, length) =
    [ r.response_store <-- frame
    ; r.response_length <-- length
    ; r.response_pending <--. 1
    ]
  in
  let load_start_response =
    choose_response i.load_start_accepted_i complete_response refused_response
  in
  let load_write_response =
    choose_response i.load_write_accepted_i complete_response refused_response
  in
  let load_complete_response =
    choose_response i.load_complete_accepted_i complete_response refused_response
  in
  let run_response = choose_response i.run_accepted_i complete_response refused_response in
  let stop_completion_response =
    choose_response i.stop_accepted_i stop_response refused_response
  in
  let verify_mismatch =
    command_is Command.verify_word &: ~:(i.readback_response_match_i)
  in
  let read_completion_response =
    read_response
      (mux2 verify_mismatch (byte Result.verification_mismatch) (byte Result.complete))
      i.readback_response_data_i
  in

  compile
    [ (* The three asynchronous inputs use matching two-stage synchronizers. *)
      r.select_meta <-- selected_async
    ; r.select_sync <-- r.select_meta.value
    ; r.select_previous <-- r.select_sync.value
    ; r.select_high_count <-- r.select_high_count.value
    ; r.clock_meta <-- i.serial_clock_i
    ; r.clock_sync <-- r.clock_meta.value
    ; r.clock_previous <-- r.clock_sync.value
    ; r.data_meta <-- i.serial_data_i
    ; r.data_sync <-- r.data_meta.value
    ; r.byte_shift <-- r.byte_shift.value
    ; r.bit_count <-- r.bit_count.value
    ; r.byte_count <-- r.byte_count.value
    ; r.request_active <-- r.request_active.value
    ; r.request_overrun <-- r.request_overrun.value
    ; r.request_magic <-- r.request_magic.value
    ; r.request_version <-- r.request_version.value
    ; r.request_tag <-- r.request_tag.value
    ; r.request_command <-- r.request_command.value
    ; r.payload_length <-- r.payload_length.value
    ; r.payload <-- r.payload.value
    ; r.request_crc <-- r.request_crc.value
    ; r.crc_match <-- r.crc_match.value
    ; r.dispatch <-- r.dispatch.value
    ; r.wait_read <-- r.wait_read.value
    ; r.wait_abort <-- r.wait_abort.value
    ; r.response_pending <-- r.response_pending.value
    ; r.response_active <-- r.response_active.value
    ; r.response_store <-- r.response_store.value
    ; r.response_shift <-- r.response_shift.value
    ; r.response_length <-- r.response_length.value
    ; r.response_bits <-- r.response_bits.value

    ; if_ r.select_sync.value
        [ r.select_high_count <--. 0 ]
        [ when_ (r.select_high_count.value <:. 4)
            [ r.select_high_count <-- r.select_high_count.value +:. 1 ]
        ]

    ; when_ (select_assert &: i.enable_i &: request_idle)
        [ r.byte_shift <--. 0
        ; r.bit_count <--. 0
        ; r.byte_count <--. 0
        ; r.request_active <--. 1
        ; r.request_overrun <--. 0
        ; r.request_magic <--. 0
        ; r.request_version <--. 0
        ; r.request_tag <--. 0
        ; r.request_command <--. 0
        ; r.payload_length <--. 0
        ; r.payload <--. 0
        ; r.request_crc <--. 0
        ; r.crc_match <--. 0
        ]
    ; when_ (clock_rise &: receiving)
        [ r.byte_shift <-- completed_byte
        ; if_ (r.bit_count.value ==:. 7)
            [ r.bit_count <--. 0
            ; if_ (r.byte_count.value >=:. Config.max_request_bytes)
                [ (* Saturation plus a sticky error prevents any suffix from becoming a
                     second frame before deselection. *)
                  r.byte_count <--. Config.max_request_bytes
                ; r.request_overrun <--. 1
                ]
                [ r.byte_count <-- r.byte_count.value +:. 1
                ; if_ completed_is_crc
                    [ r.crc_match <-- (completed_byte ==: r.request_crc.value) ]
                    [ r.request_crc <-- crc8_byte r.request_crc.value completed_byte ]
                ; switch r.byte_count.value
                [ of_int_trunc ~width:Config.request_byte_count_bits 0, [ r.request_magic <-- completed_byte ]
                ; of_int_trunc ~width:Config.request_byte_count_bits 1, [ r.request_version <-- completed_byte ]
                ; of_int_trunc ~width:Config.request_byte_count_bits 2, [ r.request_tag <-- completed_byte ]
                ; of_int_trunc ~width:Config.request_byte_count_bits 3, [ r.request_command <-- completed_byte ]
                ; of_int_trunc ~width:Config.request_byte_count_bits 4, [ r.payload_length <-- concat_msb [ zero 8; completed_byte ] ]
                ; of_int_trunc ~width:Config.request_byte_count_bits 5,
                  [ r.payload_length <--
                      concat_msb [ completed_byte; select r.payload_length.value ~high:7 ~low:0 ]
                  ]
                ; of_int_trunc ~width:Config.request_byte_count_bits 6, [ r.payload <-- concat_msb [ zero 24; completed_byte ] ]
                ; of_int_trunc ~width:Config.request_byte_count_bits 7,
                  [ r.payload <--
                      concat_msb
                        [ zero 16; completed_byte; select r.payload.value ~high:7 ~low:0 ]
                  ]
                ; of_int_trunc ~width:Config.request_byte_count_bits 8,
                  [ r.payload <--
                      concat_msb
                        [ zero 8; completed_byte; select r.payload.value ~high:15 ~low:0 ]
                  ]
                ; of_int_trunc ~width:Config.request_byte_count_bits 9,
                  [ r.payload <--
                      concat_msb [ completed_byte; select r.payload.value ~high:23 ~low:0 ]
                  ]
                ]
                ]
            ]
            [ r.bit_count <-- r.bit_count.value +:. 1 ]
        ]
    ; (* Deselect validates the complete frame before any core-facing request exists. *)
      when_ (select_release &: r.request_active.value)
        [ r.request_active <--. 0
        ; if_ (parser_error ==:. Result.complete)
            [ r.dispatch <--. 1 ]
            (set_response parser_error_response)
        ]

    ; (* Immediate commands and one-shot request decisions. *)
      when_ r.dispatch.value
        [ r.dispatch <--. 0
        ; if_ (command_is Command.info)
            [ if_ (payload_length_is 0)
                (set_response info_response)
                (set_response bad_length_response)
            ]
            [ if_ (command_is Command.status)
                [ if_ (payload_length_is 0)
                    (set_response status_response)
                    (set_response bad_length_response)
                ]
                [ if_ (command_is Command.load_start)
                    [ if_ (~:(payload_length_is 2))
                        (set_response bad_length_response)
                        [ if_ length_in_range
                            (set_response load_start_response)
                            (set_response image_bounds_response)
                        ]
                    ]
                    [ if_ (command_is Command.write_word)
                        [ if_ (~:(payload_length_is 4))
                            (set_response bad_length_response)
                            [ if_ address_in_range
                                (set_response load_write_response)
                                (set_response image_bounds_response)
                            ]
                        ]
                        [ if_ (command_is Command.read_word |: command_is Command.verify_word)
                            [ if_ (mux2 (command_is Command.read_word)
                                        (~:(payload_length_is 2))
                                        (~:(payload_length_is 4)))
                                (set_response bad_length_response)
                                [ if_ address_in_range
                                    [ if_ i.readback_accepted_i
                                        [ r.wait_read <--. 1 ]
                                        (set_response refused_response)
                                    ]
                                    (set_response image_bounds_response)
                                ]
                            ]
                            [ if_ (command_is Command.load_complete)
                                [ if_ (~:(payload_length_is 0))
                                    (set_response bad_length_response)
                                    (set_response load_complete_response)
                                ]
                                [ if_ (command_is Command.run)
                                    [ if_ (~:(payload_length_is 0))
                                        (set_response bad_length_response)
                                        (set_response run_response)
                                    ]
                                    [ if_ (command_is Command.stop)
                                        [ if_ (~:(payload_length_is 0))
                                            (set_response bad_length_response)
                                            (set_response stop_completion_response)
                                        ]
                                        [ if_ (command_is Command.abort)
                                            [ if_ (~:(payload_length_is 0))
                                                (set_response bad_length_response)
                                                [ if_ i.abort_accepted_i
                                                    [ r.wait_abort <--. 1 ]
                                                    (set_response refused_response)
                                                ]
                                            ]
                                            (set_response bad_command_response)
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
        (r.wait_read.value &: i.readback_response_valid_i)
        ([ r.wait_read <--. 0 ] @ set_response read_completion_response)
    ; when_ (r.wait_abort.value &: abort_clean)
        ([ r.wait_abort <--. 0 ] @ set_response complete_response)

    ; (* A response selection starts or restarts a retained frame. *)
      when_
        (select_assert
         &: i.enable_i
         &: r.response_pending.value
         &: (r.select_high_count.value >=:. 4))
        [ r.response_shift <-- r.response_store.value
        ; r.response_bits <--. 0
        ; r.response_active <--. 1
        ]
    ; when_
        (clock_fall
         &: r.response_active.value
         &: ~:response_drained)
        [ r.response_shift <-- sll r.response_shift.value ~by:1
        ; r.response_bits <-- r.response_bits.value +:. 1
        ]
    ; when_ (select_release &: r.response_active.value)
        [ r.response_active <--. 0
        ; if_ response_drained
            [ r.response_pending <--. 0; r.response_bits <--. 0 ]
            []
        ]

    ; (* Disable is cancellation, not a delayed wire timeout. *)
      when_ (~:(i.enable_i))
        [ r.byte_shift <--. 0
        ; r.bit_count <--. 0
        ; r.byte_count <--. 0
        ; r.select_high_count <--. 0
        ; r.request_active <--. 0
        ; r.request_overrun <--. 0
        ; r.request_magic <--. 0
        ; r.request_version <--. 0
        ; r.request_tag <--. 0
        ; r.request_command <--. 0
        ; r.payload_length <--. 0
        ; r.payload <--. 0
        ; r.request_crc <--. 0
        ; r.crc_match <--. 0
        ; r.dispatch <--. 0
        ; r.wait_read <--. 0
        ; r.wait_abort <--. 0
        ; r.response_pending <--. 0
        ; r.response_active <--. 0
        ; r.response_bits <--. 0
        ]
    ];

  { O.serial_data_o =
      mux2
        (i.enable_i &: r.response_active.value &: ~:response_drained)
        (msb r.response_shift.value)
        gnd
  ; serial_ready_o = i.enable_i &: r.response_pending.value
  ; load_start_valid_o = load_start_offer
  ; load_length_o = request_address
  ; load_write_valid_o = write_offer
  ; load_address_o = request_address
  ; load_data_o = payload_word
  ; load_complete_valid_o = complete_offer
  ; readback_valid_o = read_offer
  ; readback_address_o = request_address
  ; readback_verify_o = command_is Command.verify_word
  ; readback_expected_o = payload_word
  ; run_valid_o = run_offer
  ; stop_valid_o = stop_offer
  ; abort_valid_o = abort_offer
  ; busy_o =
      r.request_active.value
      |: r.dispatch.value
      |: r.wait_read.value
      |: r.wait_abort.value
      |: r.response_pending.value
  }
;;
[@@@ocamlformat "enable"]
