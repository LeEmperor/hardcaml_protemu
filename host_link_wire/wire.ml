(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "wire.ml" *)
(* The P3.5 host-link wire format, written once: frame layouts, command and result codes,
   INFO and STATUS payloads, CRC parameters, and a software codec for requests and
   responses.

   docs/p3.5-hardware-loader.md is the authority and this module transcribes it. A change
   here that the record does not make first is a protocol change, not a refactor.
   [Hardware_loader] takes its wire constants from here. Host software (the codec tests
   now, the P3.6 device backend later) encodes requests with [Request.encode] and reads
   responses with [Response.decode]. Nothing here depends on Hardcaml.

   The codec handles bytes only. It does not clock pins, poll LRDY, commit or replay a
   retained response, retry a command, or time anything out; those belong to whatever owns
   the physical transaction. A [Response.Decode_error.t] means the bytes are not a valid
   version-1 response to the expected request, so the transaction owner should treat the
   read as failed and replay rather than commit. A well-formed response that carries a
   refusal or a device-reported framing error is not a decode error: it is the device's
   answer, returned as [Response.t].

   Careful: the Verilog peer tinytapeout/test/p3_loader_tb.v must never be generated from
   this module (docs/verification.md). Its separate constants, frames and CRC are what
   make it an independent check on this file and on the RTL.
*)

open! Core

(* Wire version 1.0. The version byte carries the major number in its high nibble. *)
module Version = struct
  let major = 1
  let minor = 0
  let byte = (major lsl 4) lor minor
end

(* CRC-8/ATM over every byte before the CRC byte, in wire order, most significant bit
   first. The parameters are shared with the hardware, which checks at elaboration that
   its shift-register implementation supports them; [compute] is a separate software
   implementation. The empty string gives [initial].
*)
module Crc = struct
  let width = 8
  let polynomial = 0x07
  let initial = 0x00
  let reflected = false
  let final_xor = 0x00

  (* Bytes the CRC occupies at the end of every frame. *)
  let length = 1

  let update crc byte =
    Fn.apply_n_times
      ~n:8
      (fun crc ->
        let shifted = (crc lsl 1) land 0xff in
        if crc land 0x80 <> 0 then shifted lxor polynomial else shifted)
      (crc lxor byte)
  ;;

  let compute bytes =
    String.fold bytes ~init:initial ~f:(fun crc byte -> update crc (Char.to_int byte))
    lxor final_xor
  ;;
end

(* Every multibyte wire field is an unsigned 16-bit little-endian integer. *)
module U16 = struct
  let max = 0xffff
  let to_bytes value = [ value land 0xff; value lsr 8 ]
  let get bytes ~pos = Char.to_int bytes.[pos] lor (Char.to_int bytes.[pos + 1] lsl 8)
end

(* Request commands. [to_int] is the authoritative wire encoding. *)
module Command = struct
  type t =
    | Info
    | Status
    | Load_start
    | Write_word
    | Read_word
    | Verify_word
    | Load_complete
    | Run
    | Stop
    | Abort
  [@@deriving sexp_of, compare, equal, enumerate]

  let to_int = function
    | Info -> 0x00
    | Status -> 0x01
    | Load_start -> 0x10
    | Write_word -> 0x11
    | Read_word -> 0x12
    | Verify_word -> 0x13
    | Load_complete -> 0x14
    | Run -> 0x20
    | Stop -> 0x21
    | Abort -> 0x22
  ;;

  (* [None] for a byte the table does not name. The device answers such a command with
     [Result_code.Bad_command] and echoes the raw byte.
  *)
  let of_int code = List.find all ~f:(fun command -> to_int command = code)

  (* Each command has exactly one request payload length; a valid frame declaring any
     other length is answered with [Result_code.Bad_length].
  *)
  let request_payload_length = function
    | Info | Status | Load_complete | Run | Stop | Abort -> 0
    | Load_start | Read_word -> 2
    | Write_word | Verify_word -> 4
  ;;
end

(* Response results. Named [Result_code] rather than [Result] so it does not shadow
   [Core.Result] wherever this module is opened.
*)
module Result_code = struct
  type t =
    | Complete
    | Accepted_pending
    | Bad_magic
    | Bad_version
    | Bad_length
    | Bad_crc
    | Bad_command
    | Incomplete
    | Active_execution
    | Engines_active
    | No_verified_image
    | Image_bounds
    | Verification_mismatch
    | Hardware_rejected
  [@@deriving sexp_of, compare, equal, enumerate]

  let to_int = function
    | Complete -> 0x00
    | Accepted_pending -> 0x01
    | Bad_magic -> 0x10
    | Bad_version -> 0x11
    | Bad_length -> 0x12
    | Bad_crc -> 0x13
    | Bad_command -> 0x14
    | Incomplete -> 0x15
    | Active_execution -> 0x20
    | Engines_active -> 0x21
    | No_verified_image -> 0x22
    | Image_bounds -> 0x23
    | Verification_mismatch -> 0x24
    | Hardware_rejected -> 0x2f
  ;;

  (* [None] for a code version 1 does not define. *)
  let of_int code = List.find all ~f:(fun result -> to_int result = code)
end

(* INFO capability bits. These are stable wire positions, not [Host_api.Capability]
   constructor order. Bits 7 to 15 are reserved and zero in version 1.
*)
module Capability = struct
  type t =
    | Status
    | Program_load
    | Program_read
    | Program_verify
    | Run
    | Stop
    | Abort
  [@@deriving sexp_of, compare, equal, enumerate]

  let bit = function
    | Status -> 0
    | Program_load -> 1
    | Program_read -> 2
    | Program_verify -> 3
    | Run -> 4
    | Stop -> 5
    | Abort -> 6
  ;;

  let mask capabilities =
    List.fold capabilities ~init:0 ~f:(fun mask capability ->
      mask lor (1 lsl bit capability))
  ;;
end

(* STATUS fault kind. These are stable wire values. They equal [Control_execution.Fault]
   today, which [Hardware_loader] checks at elaboration; this library does not depend on
   execution-unit code. Values 10 to 255 are undefined in version 1.
*)
module Fault_kind = struct
  type t =
    | No_fault
    | Invalid_base
    | Invalid_extension
    | Fetch_bounds
    | Truncated_extension
    | Target_unrepresentable
    | Mechanism_refused
    | Mechanism_completion
    | Unsolicited_completion
    | Mechanism_protocol
  [@@deriving sexp_of, compare, equal, enumerate]

  let to_int = function
    | No_fault -> 0
    | Invalid_base -> 1
    | Invalid_extension -> 2
    | Fetch_bounds -> 3
    | Truncated_extension -> 4
    | Target_unrepresentable -> 5
    | Mechanism_refused -> 6
    | Mechanism_completion -> 7
    | Unsolicited_completion -> 8
    | Mechanism_protocol -> 9
  ;;

  let of_int code = List.find all ~f:(fun fault -> to_int fault = code)
end

(* STATUS execution phase, with the same relationship to [Control_execution.Phase] as
   [Fault_kind] has to faults. Value 7 is reserved; 8 to 255 are undefined.
*)
module Phase = struct
  type t =
    | Halted
    | Fetch
    | Base_wait
    | Extension_wait
    | Mechanism_offer
    | Mechanism_wait
    | Fault
  [@@deriving sexp_of, compare, equal, enumerate]

  let to_int = function
    | Halted -> 0
    | Fetch -> 1
    | Base_wait -> 2
    | Extension_wait -> 3
    | Mechanism_offer -> 4
    | Mechanism_wait -> 5
    | Fault -> 6
  ;;

  let of_int code = List.find all ~f:(fun phase -> to_int phase = code)
end

(* The 13-byte INFO payload. [Offset] values are byte positions within the payload.

   The device descriptor fields are data, not checks: a host must be able to read an
   unfamiliar ISA version or memory layout in order to report it as incompatible. The wire
   major and minor are the exception, because they must agree with the frame's own version
   byte.
*)
module Info = struct
  module Offset = struct
    let wire_major = 0
    let wire_minor = 1
    let isa_version = 2
    let memory_layout = 3
    let capabilities = 4
    let memory_word_bits = 6
    let memory_depth = 8
    let max_request_payload_bytes = 10
    let protocol_pin_count = 12
  end

  let length = 13

  (* Memory-layout identifiers. Only [m16] is defined. *)
  let memory_layout_m16 = 1

  type t =
    { wire_major : int
    ; wire_minor : int
    ; isa_version : int
    ; memory_layout : int
    ; capabilities : Capability.t list
    ; memory_word_bits : int
    ; memory_depth : int
    ; max_request_payload_bytes : int
    ; protocol_pin_count : int
    }
  [@@deriving sexp_of, compare, equal]
end

(* The 12-byte STATUS payload. [Offset] values are byte positions within the payload. *)
module Status = struct
  (* Flag bits of the u16 at [Offset.flags]. [all] is in bit order. Bits 12 to 15 are
     reserved and zero in version 1.
  *)
  module Flag = struct
    type t =
      | Enabled
      | Halted
      | Engines_idle
      | Image_valid
      | Load_active
      | Verification_failed
      | Execution_active
      | Normal_halt
      | Execution_fault
      | Fetch_fault
      | Pin_output_enabled
      | Pin_claimed
    [@@deriving sexp_of, compare, equal, enumerate]

    let bit = function
      | Enabled -> 0
      | Halted -> 1
      | Engines_idle -> 2
      | Image_valid -> 3
      | Load_active -> 4
      | Verification_failed -> 5
      | Execution_active -> 6
      | Normal_halt -> 7
      | Execution_fault -> 8
      | Fetch_fault -> 9
      | Pin_output_enabled -> 10
      | Pin_claimed -> 11
    ;;

    let width = 16
  end

  module Offset = struct
    let flags = 0
    let image_length = 2
    let words_written = 4
    let words_verified = 6
    let pc = 8
    let fault_kind = 10
    let phase = 11
  end

  let length = 12

  (* [flags] lists the set flags in bit order. *)
  type t =
    { flags : Flag.t list
    ; image_length : int
    ; words_written : int
    ; words_verified : int
    ; pc : int
    ; fault_kind : Fault_kind.t
    ; phase : Phase.t
    }
  [@@deriving sexp_of, compare, equal]

  let has t flag = List.mem t.flags flag ~equal:Flag.equal
end

(* The tag and command a response echoes. The command is a raw byte because the device
   echoes whatever it received, including a byte [Command.of_int] does not name.
*)
module Correlation = struct
  type t =
    { tag : int
    ; command : int
    }
  [@@deriving sexp_of, compare, equal]
end

module Request = struct
  let magic = 0xa5

  (* Byte offsets from the start of a request frame. The payload length is a u16 whose
     high byte must be zero in version 1.
  *)
  module Offset = struct
    let magic = 0
    let version = 1
    let tag = 2
    let command = 3
    let payload_length = 4
    let payload = 6
  end

  let header_length = 6
  let max_payload_length = 4
  let min_length = header_length + Crc.length
  let max_length = header_length + max_payload_length + Crc.length

  (* Field offsets within a request payload. LOAD_START's image length sits where the
     other commands put their address.
  *)
  module Payload_offset = struct
    let address = 0
    let word = 2
  end

  (* One request per command. Addresses, lengths and words are u16 on the wire; the
     device, not the codec, decides whether an address or length fits its memory.
  *)
  type t =
    | Info
    | Status
    | Load_start of { length : int }
    | Write_word of
        { address : int
        ; word : int
        }
    | Read_word of { address : int }
    | Verify_word of
        { address : int
        ; expected : int
        }
    | Load_complete
    | Run
    | Stop
    | Abort
  [@@deriving sexp_of, compare, equal]

  let command : t -> Command.t = function
    | Info -> Info
    | Status -> Status
    | Load_start _ -> Load_start
    | Write_word _ -> Write_word
    | Read_word _ -> Read_word
    | Verify_word _ -> Verify_word
    | Load_complete -> Load_complete
    | Run -> Run
    | Stop -> Stop
    | Abort -> Abort
  ;;

  (* What a response to this request must echo. *)
  let correlation ~tag t = { Correlation.tag; command = Command.to_int (command t) }

  module Encode_error = struct
    (* [field] is outside [0, max]. *)
    type t =
      | Out_of_range of
          { field : string
          ; value : int
          ; max : int
          }
    [@@deriving sexp_of, compare, equal]
  end

  (* Payload fields in wire order, named for error reporting. *)
  let payload_fields = function
    | Info | Status | Load_complete | Run | Stop | Abort -> []
    | Load_start { length } -> [ "length", length ]
    | Write_word { address; word } -> [ "address", address; "word", word ]
    | Read_word { address } -> [ "address", address ]
    | Verify_word { address; expected } -> [ "address", address; "expected", expected ]
  ;;

  (* The complete frame, CRC included. Every field is range-checked before any byte is
     produced, and the first failing field in wire order is reported; nothing is truncated
     to fit.
  *)
  let encode ~tag t =
    let open Result.Let_syntax in
    let check (field, value, max) =
      if value < 0 || value > max
      then Error (Encode_error.Out_of_range { field; value; max })
      else Ok ()
    in
    let fields = payload_fields t in
    let%map () =
      ("tag", tag, 0xff)
      :: List.map fields ~f:(fun (field, value) -> field, value, U16.max)
      |> List.map ~f:check
      |> Result.all_unit
    in
    let payload = List.concat_map fields ~f:(fun (_, value) -> U16.to_bytes value) in
    let header =
      [ magic; Version.byte; tag; Command.to_int (command t) ]
      @ U16.to_bytes (List.length payload)
    in
    let body = String.of_char_list (List.map (header @ payload) ~f:Char.of_int_exn) in
    body ^ String.of_char (Char.of_int_exn (Crc.compute body))
  ;;
end

module Response = struct
  let magic = 0x5a

  (* Byte offsets from the start of a response frame. The payload length is a u16 whose
     high byte is zero in version 1.
  *)
  module Offset = struct
    let magic = 0
    let version = 1
    let tag = 2
    let command = 3
    let result = 4
    let payload_length = 5
    let payload = 7
  end

  let header_length = 7

  (* INFO is the largest payload. *)
  let max_payload_length = Info.length
  let min_length = header_length + Crc.length
  let max_length = header_length + max_payload_length + Crc.length

  module Payload = struct
    type t =
      | Empty
      | Word of int
      | Info of Info.t
      | Status of Status.t
    [@@deriving sexp_of, compare, equal]
  end

  (* A decoded response. [command] is the raw echoed byte (see [Correlation]); READ_WORD
     and VERIFY_WORD carry the actual word as [Word], including a VERIFY_WORD
     [Verification_mismatch].
  *)
  type t =
    { tag : int
    ; command : int
    ; result : Result_code.t
    ; payload : Payload.t
    }
  [@@deriving sexp_of, compare, equal]

  let correlation t = { Correlation.tag = t.tag; command = t.command }

  type response = t [@@deriving sexp_of, compare, equal]

  (* Why bytes are not a valid version-1 response, in the order [decode] checks. Only
     [Correlation_mismatch] carries a well-formed response: it is the device's answer to
     some other request.
  *)
  module Decode_error = struct
    type t =
      | Truncated of
          { expected : int
          ; actual : int
          }
      | Extra_bytes of
          { expected : int
          ; actual : int
          }
      | Bad_magic of int
      | Bad_version of int
      | Payload_length_too_large of int
      | Bad_crc of
          { computed : int
          ; received : int
          }
      | Unknown_result of int
      | Unexpected_result of
          { command : int
          ; result : Result_code.t
          }
      | Payload_length_mismatch of
          { command : int
          ; result : Result_code.t
          ; expected : int
          ; actual : int
          }
      | Invalid_field of
          { field : string
          ; value : int
          }
      | Correlation_mismatch of
          { expected : Correlation.t
          ; response : response
          }
    [@@deriving sexp_of, compare, equal]
  end

  (* The payload a response must carry for its echoed command and result, or [None] when
     version 1 never answers that command with that result:

     - device-reported framing errors answer whatever arrived, so they accept any command
       byte, including an unknown one or the zeroes sent when fewer than four request
       bytes arrived;
     - [Bad_command] answers only a byte the command table does not name;
     - refusals answer only a named command. The contract does not say which named
       commands may be refused, so the decoder does not either;
     - success follows the command table: STOP succeeds only as [Accepted_pending], every
       other command only as [Complete], and only VERIFY_WORD reports
       [Verification_mismatch].
  *)
  type shape =
    | Empty_payload
    | Word_payload
    | Info_payload
    | Status_payload

  let shape ~command (result : Result_code.t) =
    match Command.of_int command, result with
    | _, (Bad_magic | Bad_version | Bad_length | Bad_crc | Incomplete) ->
      Some Empty_payload
    | None, Bad_command -> Some Empty_payload
    | None, _ | Some _, Bad_command -> None
    | ( Some _
      , ( Active_execution
        | Engines_active
        | No_verified_image
        | Image_bounds
        | Hardware_rejected ) ) -> Some Empty_payload
    | Some Stop, Accepted_pending -> Some Empty_payload
    | Some _, Accepted_pending | Some Stop, Complete -> None
    | Some Verify_word, Verification_mismatch -> Some Word_payload
    | Some _, Verification_mismatch -> None
    | Some Info, Complete -> Some Info_payload
    | Some Status, Complete -> Some Status_payload
    | Some (Read_word | Verify_word), Complete -> Some Word_payload
    | Some (Load_start | Write_word | Load_complete | Run | Abort), Complete ->
      Some Empty_payload
  ;;

  let shape_length = function
    | Empty_payload -> 0
    | Word_payload -> 2
    | Info_payload -> Info.length
    | Status_payload -> Status.length
  ;;

  let invalid_field field value = Error (Decode_error.Invalid_field { field; value })

  (* Set bits of [mask] as [all] entries, or [Invalid_field] if a reserved bit is set. *)
  let decode_bits ~field ~all ~bit mask =
    let set = List.filter all ~f:(fun entry -> mask land (1 lsl bit entry) <> 0) in
    let known =
      List.fold set ~init:0 ~f:(fun known entry -> known lor (1 lsl bit entry))
    in
    if mask = known then Ok set else invalid_field field mask
  ;;

  let decode_enum ~field ~of_int value =
    match of_int value with
    | Some decoded -> Ok decoded
    | None -> invalid_field field value
  ;;

  let decode_info payload =
    let open Result.Let_syntax in
    let byte pos = Char.to_int payload.[pos] in
    let u16 pos = U16.get payload ~pos in
    let%bind () =
      if byte Info.Offset.wire_major <> Version.major
      then invalid_field "INFO wire major" (byte Info.Offset.wire_major)
      else if byte Info.Offset.wire_minor <> Version.minor
      then invalid_field "INFO wire minor" (byte Info.Offset.wire_minor)
      else Ok ()
    in
    let%map capabilities =
      decode_bits
        ~field:"INFO capabilities"
        ~all:Capability.all
        ~bit:Capability.bit
        (u16 Info.Offset.capabilities)
    in
    { Info.wire_major = byte Info.Offset.wire_major
    ; wire_minor = byte Info.Offset.wire_minor
    ; isa_version = byte Info.Offset.isa_version
    ; memory_layout = byte Info.Offset.memory_layout
    ; capabilities
    ; memory_word_bits = u16 Info.Offset.memory_word_bits
    ; memory_depth = u16 Info.Offset.memory_depth
    ; max_request_payload_bytes = u16 Info.Offset.max_request_payload_bytes
    ; protocol_pin_count = byte Info.Offset.protocol_pin_count
    }
  ;;

  let decode_status payload =
    let open Result.Let_syntax in
    let byte pos = Char.to_int payload.[pos] in
    let u16 pos = U16.get payload ~pos in
    let%bind flags =
      decode_bits
        ~field:"STATUS flags"
        ~all:Status.Flag.all
        ~bit:Status.Flag.bit
        (u16 Status.Offset.flags)
    in
    let%bind fault_kind =
      decode_enum
        ~field:"STATUS fault kind"
        ~of_int:Fault_kind.of_int
        (byte Status.Offset.fault_kind)
    in
    let%map phase =
      decode_enum ~field:"STATUS phase" ~of_int:Phase.of_int (byte Status.Offset.phase)
    in
    { Status.flags
    ; image_length = u16 Status.Offset.image_length
    ; words_written = u16 Status.Offset.words_written
    ; words_verified = u16 Status.Offset.words_verified
    ; pc = u16 Status.Offset.pc
    ; fault_kind
    ; phase
    }
  ;;

  (* Checks, in order, each failing with the matching [Decode_error]:

     1. at least a header and CRC are present;
     2. magic, then version byte;
     3. the declared payload length is at most [max_payload_length] (so a nonzero high
        byte always fails here);
     4. the frame is exactly header, declared payload and CRC long;
     5. the CRC matches;
     6. the result code is defined;
     7. the result may answer the echoed command, with the payload length that pair
        requires;
     8. INFO and STATUS fields hold no reserved bit or undefined value.

     Nothing is compared with a request here; see [decode_correlated].
  *)
  let decode frame =
    let open Result.Let_syntax in
    let length = String.length frame in
    let byte pos = Char.to_int frame.[pos] in
    let fail_if condition (error : Decode_error.t) =
      if condition then Error error else Ok ()
    in
    let%bind () =
      fail_if
        (length < min_length)
        (Decode_error.Truncated { expected = min_length; actual = length })
    in
    let%bind () = fail_if (byte Offset.magic <> magic) (Bad_magic (byte Offset.magic)) in
    let%bind () =
      fail_if (byte Offset.version <> Version.byte) (Bad_version (byte Offset.version))
    in
    let payload_length = U16.get frame ~pos:Offset.payload_length in
    let%bind () =
      fail_if
        (payload_length > max_payload_length)
        (Payload_length_too_large payload_length)
    in
    let expected = header_length + payload_length + Crc.length in
    let%bind () = fail_if (length < expected) (Truncated { expected; actual = length }) in
    let%bind () =
      fail_if (length > expected) (Extra_bytes { expected; actual = length })
    in
    let computed = Crc.compute (String.prefix frame (length - Crc.length)) in
    let received = byte (length - Crc.length) in
    let%bind () = fail_if (computed <> received) (Bad_crc { computed; received }) in
    let command = byte Offset.command in
    let%bind result =
      Result_code.of_int (byte Offset.result)
      |> Result.of_option ~error:(Decode_error.Unknown_result (byte Offset.result))
    in
    let%bind shape =
      shape ~command result
      |> Result.of_option ~error:(Decode_error.Unexpected_result { command; result })
    in
    let%bind () =
      fail_if
        (payload_length <> shape_length shape)
        (Payload_length_mismatch
           { command; result; expected = shape_length shape; actual = payload_length })
    in
    let payload = String.sub frame ~pos:Offset.payload ~len:payload_length in
    let%map payload =
      match shape with
      | Empty_payload -> Ok Payload.Empty
      | Word_payload -> Ok (Payload.Word (U16.get payload ~pos:0))
      | Info_payload -> decode_info payload >>| fun info -> Payload.Info info
      | Status_payload -> decode_status payload >>| fun status -> Payload.Status status
    in
    { tag = byte Offset.tag; command; result; payload }
  ;;

  (* The caller-facing correlation boundary. [expected] is the correlation of the request
     just sent ([Request.correlation]). A response that decodes but echoes another tag or
     command is [Correlation_mismatch], which keeps the decoded response.

     Careful: a device that received fewer than four request bytes zeroes both echoed
     fields, so its framing error normally surfaces as a mismatch. For an INFO request
     with tag 0 the zeroes are indistinguishable from a real echo and the framing error is
     returned as the device's answer instead. Neither outcome is a success.
  *)
  let decode_correlated ~expected frame =
    let open Result.Let_syntax in
    let%bind response = decode frame in
    if Correlation.equal (correlation response) expected
    then Ok response
    else Error (Decode_error.Correlation_mismatch { expected; response })
  ;;
end
