(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "frame_rx.ml" *)
(* P3.5 serial loader request receiver: byte assembly, the bounded byte count and sticky
   overrun, header and payload capture, CRC accumulation, and deselect validation.

   It consumes [Serial_phy]'s synchronized levels and events as plain inputs. A request
   starts at an eligible selection, takes one MSB-first bit at each clock rise while
   selected, and ends at deselection, which is the only frame boundary. In the release
   cycle [frame_end_o] is high and [result_o] and [echo_valid_o] hold the frame's
   validation; nothing is registered between validation and the consumer. The retained
   tag, command, length, and payload then hold until the next eligible selection or
   disable.

   [Hardware_loader] supplies eligibility. [Command_dispatch] consumes the handoff and the
   retained fields: command legality, fixed lengths and device bounds, dispatch,
   completion waits, and every response. docs/host_link_hl4b2_record.md records the timing
   contract. [check_wire_encodings] checks the request layout and CRC start value this
   block assumes against [Wire] whenever it is elaborated; [Wire_crc] checks the CRC
   parameters.
*)

open! Core
open! Hardcaml
open! Signal
module Wire = Protemu_host_link_wire.Wire

(* Receiver sizing derived from the wire limits. *)
module Config = struct
  let max_request_bytes = Wire.Request.max_length
  let request_byte_count_bits = Int.ceil_log2 (max_request_bytes + 1)
end

(* Elaboration-time consistency between [Wire] and the fixed choices in [create]: the
   literal byte counts that capture each header field and payload byte, and the CRC
   accumulator's clear to zero at each start. Plain OCaml comparisons; they create no
   logic and cannot change emitted RTL.
*)
let check_wire_encodings () =
  let require condition message =
    if not condition then invalid_arg ("Frame_rx: " ^ message)
  in
  Wire_layout.check
    ~owner:"Frame_rx"
    "request header"
    ~length:Wire.Request.header_length
    Wire.Request.Offset.[ magic, 1; version, 1; tag, 1; command, 1; payload_length, 2 ];
  require
    (Wire.Request.Offset.payload = Wire.Request.header_length)
    "request payload does not follow the header";
  Wire_layout.check_request_payload ~owner:"Frame_rx";
  require (Wire.Crc.initial = 0) "request CRC does not start from zero"
;;

module I = struct
  type 'a t =
    { (* System clock domain; reset is synchronous and active high. Disable cancels the
         request and clears every field. *)
      clock_i : 'a
    ; reset_i : 'a
    ; enable_i : 'a
    ; (* Serial_phy -> receiver: synchronized selection (active high) and LDI levels, and
         the one-cycle select and LCLK rise events. *)
      selected_i : 'a
    ; data_i : 'a
    ; select_assert_i : 'a
    ; select_release_i : 'a
    ; clock_rise_i : 'a
    ; (* Loader -> receiver: no command, completion wait, or retained response exists, so
         a selection may start a request. Sampled only in the select-assert cycle. *)
      eligible_i : 'a
    }
  [@@deriving hardcaml]
end

module O = struct
  type 'a t =
    { (* A request selection is being received. *)
      active_o : 'a
    ; (* The active request's deselection: one cycle, the frame's only handoff. *)
      frame_end_o : 'a
    ; (* Deselect validation as a [Wire.Result_code]: [Complete] for a frame the loader
         may dispatch, else the framing error. Read with [frame_end_o]. *)
      result_o : 'a [@bits 8]
    ; (* Tag and command were both received, so an error response may echo them. *)
      echo_valid_o : 'a
    ; (* Retained request fields; payload integers are little-endian on the wire. *)
      tag_o : 'a [@bits 8]
    ; command_o : 'a [@bits 8]
    ; payload_length_o : 'a [@bits 16]
    ; payload_o : 'a [@bits 32]
    }
  [@@deriving hardcaml]
end

[@@@ocamlformat "disable"]

(* Registered receiver state. Fields hold unless explicitly assigned by [compile]; an
   eligible selection, disable, and reset clear every field.
*)
module I_Regs = struct
  type 'a t =
    { byte_shift       : 'a [@bits 8]
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
    }
  [@@deriving hardcaml]
end

let result_code code = of_int_trunc ~width:8 (Wire.Result_code.to_int code)

let create (scope : Scope.t) (i : _ I.t) : _ O.t =
  check_wire_encodings ();
  let open Always in
  let spec = Reg_spec.create ~clock:i.clock_i ~clear:i.reset_i () in
  let r = I_Regs.Of_always.reg spec in
  I_Regs.Of_always.apply_names ~prefix:"reg_" ~naming_op:(Scope.naming scope) r;

  let request_idle = ~:(r.request_active.value) &: i.eligible_i in
  let receiving =
    i.enable_i &: i.selected_i &: r.request_active.value
  in
  let frame_end = i.select_release_i &: r.request_active.value in
  let completed_byte = concat_lsb [ i.data_i; select r.byte_shift.value ~high:6 ~low:0 ] in
  let expected_crc_index = uresize r.payload_length.value ~width:16 +:. Wire.Request.header_length in
  let completed_byte_index = uresize r.byte_count.value ~width:16 in
  let completed_is_crc = completed_byte_index ==: expected_crc_index in
  let expected_frame_bytes = r.payload_length.value +:. Wire.Request.min_length in
  let request_bytes = uresize r.byte_count.value ~width:16 in
  let request_complete =
    ~:(r.request_overrun.value)
    &: (r.bit_count.value ==:. 0)
    &: (request_bytes >=:. Wire.Request.min_length)
    &: (request_bytes ==: expected_frame_bytes)
  in
  (* Overrun, then completeness, then the header fields, then the CRC. *)
  let parser_error =
    mux2 r.request_overrun.value (result_code Bad_length)
      (mux2 (~:(request_complete)) (result_code Incomplete)
      (mux2 (r.request_magic.value <>:. Wire.Request.magic) (result_code Bad_magic)
         (mux2 (r.request_version.value <>:. Wire.Version.byte) (result_code Bad_version)
            (mux2 (r.payload_length.value >:. Wire.Request.max_payload_length) (result_code Bad_length)
               (mux2 (~:(r.crc_match.value)) (result_code Bad_crc) (result_code Complete))))))
  in
  (* The echo needs every byte through the command. *)
  let correlation_valid = r.byte_count.value >=:. Wire.Request.Offset.command + 1 in

  (* Hold by default. Start, receive, and deselect are mutually exclusive; disable is last
     and clears every field.
  *)
  compile
    [ r.byte_shift <-- r.byte_shift.value
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

    ; when_ (i.select_assert_i &: i.enable_i &: request_idle)
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
    ; when_ (i.clock_rise_i &: receiving)
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
                    [ r.request_crc <-- Wire_crc.crc8_byte r.request_crc.value completed_byte ]
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
    ; (* Deselect ends the request; the loader validates and dispatches in this cycle. *)
      when_ frame_end
        [ r.request_active <--. 0 ]

    ; (* Disable is cancellation, not a delayed wire timeout. *)
      when_ (~:(i.enable_i))
        [ r.byte_shift <--. 0
        ; r.bit_count <--. 0
        ; r.byte_count <--. 0
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
        ]
    ];

  { O.active_o       = r.request_active.value
  ; frame_end_o      = frame_end
  ; result_o         = parser_error
  ; echo_valid_o     = correlation_valid
  ; tag_o            = r.request_tag.value
  ; command_o        = r.request_command.value
  ; payload_length_o = r.payload_length.value
  ; payload_o        = r.payload.value
  }
;;
[@@@ocamlformat "enable"]
