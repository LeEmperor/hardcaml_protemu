(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "host_api.ml" *)
(* Transport-independent P3.4 host types and device operations.

   Backends implement [Device]. The API deliberately contains no command-line, simulator,
   serial framing, or Hardcaml types, so P3.5/P3.6 can implement the same boundary without
   inheriting simulator process or timing details.
*)

open! Core

module Version = struct
  type t =
    { major : int
    ; minor : int
    }
  [@@deriving sexp, compare, equal]
end

module Constants = struct
  let api = { Version.major = 1; minor = 0 }
  let protocol = { Version.major = 1; minor = 0 }
  let isa_id = "protemu-p1.5"
  let isa_version = 1
  let image_format = "protemu-image-sexp"
  let image_format_version = 1
  let cli_output_version = 1
end

module Capability = struct
  type t =
    | Program_load
    | Program_readback
    | Execution_control
    | Single_step
    | Pin_claims
    | Host_tx_queue
    | Host_rx_queue
    | Architectural_inspection
    | Timestamped_trace
    | Simulator_cycle_control
    | Simulator_pad_stimulus
  [@@deriving sexp, compare, equal, enumerate]
end

module Address_unit = struct
  type t = Memory_word [@@deriving sexp, compare, equal]
end

module Byte_order = struct
  type t = Little_endian [@@deriving sexp, compare, equal]
end

module Image_format = struct
  type t =
    { name : string
    ; version : int
    ; layout : string
    ; word_bits : int
    ; depth_words : int
    ; address_unit : Address_unit.t
    ; byte_order : Byte_order.t
    }
  [@@deriving sexp, compare, equal]
end

module Queue_info = struct
  type t =
    { name : string
    ; direction : string
    ; capacity_bytes : int
    }
  [@@deriving sexp, compare, equal]
end

module Discovery = struct
  type t =
    { api_version : Version.t
    ; protocol_version : Version.t
    ; isa_id : string
    ; isa_version : int
    ; backend : string
    ; capabilities : Capability.t list
    ; image : Image_format.t
    ; pin_count : int
    ; queues : Queue_info.t list
    ; engine_count : int
    ; trace_capacity : int
    ; trace_timestamp_unit : string
    ; trace_storage : string
    }
  [@@deriving sexp, compare, equal]
end

module Fault = struct
  type t =
    { fetch_fault : bool
    ; execution_fault : bool
    ; kind : int
    ; instruction_slot : int
    ; address : int
    ; reason : int
    }
  [@@deriving sexp, compare, equal]
end

module Refusal = struct
  type t =
    | Active_execution
    | Engines_active
    | No_verified_image
    | Image_bounds
    | Execution_faulted
    | Terminal_halt
    | Pin_conflict
    | Hardware_rejected
  [@@deriving sexp, compare, equal]
end

module Read_failure = struct
  module Cause = struct
    type t =
      | Refused of Refusal.t
      | Missing_fixed_latency_response
    [@@deriving sexp, compare, equal]
  end

  type t =
    { operation : string
    ; address : int
    ; count : int
    ; failing_address : int
    ; completed : int
    ; words : int list
    ; cause : Cause.t
    }
  [@@deriving sexp, compare, equal]
end

module Transfer_outcome = struct
  type t =
    | Complete
    | Would_block
    | Timed_out
  [@@deriving sexp, compare, equal]
end

module Error = struct
  type t =
    | Unsupported of
        { operation : string
        ; detail : string
        }
    | Invalid_argument of
        { operation : string
        ; detail : string
        }
    | Incompatible_api of
        { required : Version.t
        ; actual : Version.t
        }
    | Incompatible_isa of
        { required_id : string
        ; required_version : int
        ; actual_id : string
        ; actual_version : int
        }
    | Incompatible_image of
        { field : string
        ; required : string
        ; actual : string
        }
    | Refused of
        { operation : string
        ; reason : Refusal.t
        }
    | Timeout of
        { operation : string
        ; budget_cycles : int
        ; accepted : bool
        }
    | Transfer_incomplete of
        { queue : string
        ; requested : int
        ; transferred : int
        ; data : int list
        ; outcome : Transfer_outcome.t
        }
    | Read_failed of Read_failure.t
    | Verification_mismatch of
        { address : int
        ; expected : int
        ; actual : int
        }
    | Hardware_fault of Fault.t
    | Backend_invariant of
        { operation : string
        ; detail : string
        }
    | Image_parse of string
    | Io of string
  [@@deriving sexp, compare, equal]

  let code = function
    | Unsupported _ -> "unsupported"
    | Invalid_argument _ -> "invalid_argument"
    | Incompatible_api _ -> "incompatible_api"
    | Incompatible_isa _ -> "incompatible_isa"
    | Incompatible_image _ -> "incompatible_image"
    | Refused { reason = Active_execution; _ } -> "active_execution"
    | Refused { reason = Engines_active; _ } -> "engines_active"
    | Refused { reason = No_verified_image; _ } -> "no_verified_image"
    | Refused { reason = Image_bounds; _ } -> "image_bounds"
    | Refused { reason = Execution_faulted; _ } -> "execution_faulted"
    | Refused { reason = Terminal_halt; _ } -> "terminal_halt"
    | Refused { reason = Pin_conflict; _ } -> "pin_conflict"
    | Refused _ -> "refused"
    | Timeout _ -> "timeout"
    | Transfer_incomplete { outcome = Would_block; _ } -> "would_block"
    | Transfer_incomplete { outcome = Timed_out; _ } -> "transfer_timeout"
    | Transfer_incomplete _ -> "transfer_incomplete"
    | Read_failed _ -> "read_failed"
    | Verification_mismatch _ -> "verification_mismatch"
    | Hardware_fault _ -> "hardware_fault"
    | Backend_invariant _ -> "backend_invariant"
    | Image_parse _ -> "image_parse"
    | Io _ -> "io"
  ;;
end

module Image = struct
  type t =
    { format : string
    ; format_version : int
    ; api_major : int
    ; isa_id : string
    ; isa_version : int
    ; layout : string
    ; word_bits : int
    ; address_unit : Address_unit.t
    ; byte_order : Byte_order.t
    ; words : int list
    }
  [@@deriving sexp, compare, equal]

  let create words =
    { format = Constants.image_format
    ; format_version = Constants.image_format_version
    ; api_major = Constants.api.major
    ; isa_id = Constants.isa_id
    ; isa_version = Constants.isa_version
    ; layout = Protemu_isa.Assembler.Memory.word16.name
    ; word_bits = Protemu_isa.Assembler.Memory.word16.word_bits
    ; address_unit = Memory_word
    ; byte_order = Little_endian
    ; words
    }
  ;;

  let of_assembled (assembled : Protemu_isa.Assembler.Assembled.t) =
    { (create (Array.to_list assembled.image.words)) with
      layout = assembled.memory.name
    ; word_bits = assembled.memory.word_bits
    }
  ;;

  let to_string t = Sexp.to_string_hum (sexp_of_t t) ^ "\n"

  let of_string text =
    try Ok (t_of_sexp (Sexp.of_string text)) with
    | exn -> Error (Error.Image_parse (Exn.to_string exn))
  ;;

  let validate (discovery : Discovery.t) t =
    let incompatible field required actual =
      Error (Error.Incompatible_image { field; required; actual })
    in
    if not (String.equal t.format discovery.image.name)
    then incompatible "format" discovery.image.name t.format
    else if t.format_version <> discovery.image.version
    then
      incompatible
        "format_version"
        (Int.to_string discovery.image.version)
        (Int.to_string t.format_version)
    else if t.api_major <> discovery.api_version.major
    then
      Error
        (Error.Incompatible_api
           { required = { Version.major = t.api_major; minor = 0 }
           ; actual = discovery.api_version
           })
    else if (not (String.equal t.isa_id discovery.isa_id))
            || t.isa_version <> discovery.isa_version
    then
      Error
        (Error.Incompatible_isa
           { required_id = t.isa_id
           ; required_version = t.isa_version
           ; actual_id = discovery.isa_id
           ; actual_version = discovery.isa_version
           })
    else if not (String.equal t.layout discovery.image.layout)
    then incompatible "layout" discovery.image.layout t.layout
    else if t.word_bits <> discovery.image.word_bits
    then
      incompatible
        "word_bits"
        (Int.to_string discovery.image.word_bits)
        (Int.to_string t.word_bits)
    else if not (Address_unit.equal t.address_unit discovery.image.address_unit)
    then
      incompatible
        "address_unit"
        (Sexp.to_string (Address_unit.sexp_of_t discovery.image.address_unit))
        (Sexp.to_string (Address_unit.sexp_of_t t.address_unit))
    else if not (Byte_order.equal t.byte_order discovery.image.byte_order)
    then
      incompatible
        "byte_order"
        (Sexp.to_string (Byte_order.sexp_of_t discovery.image.byte_order))
        (Sexp.to_string (Byte_order.sexp_of_t t.byte_order))
    else if List.is_empty t.words
    then Error (Error.Invalid_argument { operation = "load"; detail = "empty image" })
    else if List.length t.words > discovery.image.depth_words
    then
      Error
        (Error.Invalid_argument
           { operation = "load"
           ; detail =
               sprintf
                 "image has %d words; depth is %d"
                 (List.length t.words)
                 discovery.image.depth_words
           })
    else (
      let maximum = (1 lsl t.word_bits) - 1 in
      match List.findi t.words ~f:(fun _ word -> word < 0 || word > maximum) with
      | Some (address, word) ->
        Error
          (Error.Invalid_argument
             { operation = "load"
             ; detail = sprintf "word %d is outside 0..0x%x: %d" address maximum word
             })
      | None -> Ok ())
  ;;
end

let require_api (discovery : Discovery.t) (required : Version.t) =
  if required.major <> discovery.api_version.major
     || required.minor > discovery.api_version.minor
  then Error (Error.Incompatible_api { required; actual = discovery.api_version })
  else Ok ()
;;

let require_isa (discovery : Discovery.t) ~id ~version =
  if String.equal id discovery.isa_id && version = discovery.isa_version
  then Ok ()
  else
    Error
      (Error.Incompatible_isa
         { required_id = id
         ; required_version = version
         ; actual_id = discovery.isa_id
         ; actual_version = discovery.isa_version
         })
;;

module Loaded_image = struct
  type t =
    { valid : bool
    ; load_active : bool
    ; length_words : int
    ; words_written : int
    ; words_verified : int
    ; verification_failed : bool
    }
  [@@deriving sexp, compare, equal]
end

module Engine_status = struct
  type t =
    { idle : bool
    ; timing_busy : bool
    ; transfer_busy : bool
    ; transfer_done : bool
    ; transfer_fault : bool
    ; software_claims : int
    ; engine_claims : int
    }
  [@@deriving sexp, compare, equal]
end

module Status = struct
  type t =
    { cycle : int
    ; halted : bool
    ; execution_active : bool
    ; normal_halt : bool
    ; pc : int
    ; phase : int
    ; registers : int list
    ; zero : bool
    ; carry : bool
    ; negative : bool
    ; descriptor_words : int list
    ; events : int
    ; event_overflow : int
    ; pins : int
    ; pin_output_enable : int
    ; pin_snapshot : int
    ; tx_count : int
    ; rx_count : int
    ; fetch_cycles : int
    ; execute_cycles : int
    ; stall_cycles : int
    ; instruction_count : int
    ; extension_fetches : int
    ; total_cycles : int
    ; image : Loaded_image.t
    ; engine : Engine_status.t
    ; fault : Fault.t
    }
  [@@deriving sexp, compare, equal]
end

module Control_ack = struct
  type t =
    { operation : string
    ; accepted_cycle : int
    ; completed : bool
    ; completed_cycle : int option
    }
  [@@deriving sexp, compare, equal]
end

module Load_result = struct
  type t =
    { words : int
    ; started_cycle : int
    ; completed_cycle : int
    }
  [@@deriving sexp, compare, equal]
end

module Transfer = struct
  type t =
    { requested : int
    ; transferred : int
    ; data : int list
    ; cycles : int
    ; outcome : Transfer_outcome.t
    }
  [@@deriving sexp, compare, equal]
end

module Pin_configuration = struct
  type t =
    | Claim of int
    | Release of int
  [@@deriving sexp, compare, equal]
end

module Trace = struct
  module Event = struct
    type t =
      | Host_operation of
          { operation : string
          ; outcome : string
          }
      | Instruction_boundary of
          { pc : int
          ; retired : bool
          }
      | Mechanism of
          { kind : int
          ; accepted : bool
          ; refused : bool
          ; completed : bool
          }
      | Engine_completion of
          { fault : bool
          ; rx_valid : bool
          ; rx_data : int
          }
      | Pin_transition of
          { old_value : int
          ; new_value : int
          ; old_output_enable : int
          ; new_output_enable : int
          }
      | Fault of Fault.t
    [@@deriving sexp, compare, equal]
  end

  module Record = struct
    type t =
      { sequence : int
      ; timestamp : int
      ; event : Event.t
      }
    [@@deriving sexp, compare, equal]
  end

  module Retrieval = struct
    type t =
      { records : Record.t list
      ; next_cursor : int option
      ; oldest_sequence : int option
      ; overflowed : bool
      ; lost_records : int
      ; capacity : int
      ; enabled : bool
      }
    [@@deriving sexp, compare, equal]
  end
end

module type Device = sig
  type t

  val discover : t -> Discovery.t
  val load_image : t -> Image.t -> (Load_result.t, Error.t) Result.t
  val read_program : t -> address:int -> count:int -> (int list, Error.t) Result.t
  val verify_image : t -> Image.t -> (unit, Error.t) Result.t
  val loaded_image : t -> Loaded_image.t
  val run : t -> (Control_ack.t, Error.t) Result.t
  val stop : t -> budget_cycles:int -> (Control_ack.t, Error.t) Result.t
  val abort : t -> (Control_ack.t, Error.t) Result.t
  val step : t -> budget_cycles:int -> (Control_ack.t, Error.t) Result.t
  val status : t -> Status.t
  val configure_pins : t -> Pin_configuration.t -> (unit, Error.t) Result.t
  val transmit : t -> budget_cycles:int -> int list -> (Transfer.t, Error.t) Result.t
  val receive : t -> budget_cycles:int -> count:int -> (Transfer.t, Error.t) Result.t
  val advance : t -> cycles:int -> (Status.t, Error.t) Result.t
  val wait_halted : t -> budget_cycles:int -> (Status.t, Error.t) Result.t
  val trace_enable : t -> bool -> (unit, Error.t) Result.t
  val trace_retrieve : t -> after:int option -> (Trace.Retrieval.t, Error.t) Result.t
  val trace_clear : t -> (unit, Error.t) Result.t
end
