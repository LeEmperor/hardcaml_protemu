(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "host_api_tests.ml" *)
(* Unit coverage for P3.4 image metadata, compatibility, and structured error codes. *)

open! Core
module Api = Protemu_host.Host_api

let discovery =
  { Api.Discovery.api_version = Api.Constants.api
  ; protocol_version = Api.Constants.protocol
  ; isa_id = Api.Constants.isa_id
  ; isa_version = Api.Constants.isa_version
  ; backend = "test"
  ; capabilities = []
  ; image =
      { Api.Image_format.name = Api.Constants.image_format
      ; version = Api.Constants.image_format_version
      ; layout = "m16"
      ; word_bits = 16
      ; depth_words = 256
      ; address_unit = Memory_word
      ; byte_order = Little_endian
      }
  ; pin_count = 8
  ; queues = []
  ; engine_count = 1
  ; trace_capacity = 8
  ; trace_timestamp_unit = "rising-edge-cycle"
  ; trace_storage = "test"
  }
;;

let error_code = function
  | Ok _ -> "ok"
  | Error error -> Api.Error.code error
;;

let%test_unit "image serialization round trips complete words" =
  let image = Api.Image.create [ 0xd400; 0xc800; 0 ] in
  let parsed = Api.Image.of_string (Api.Image.to_string image) in
  [%test_result: (Api.Image.t, Api.Error.t) Result.t] parsed ~expect:(Ok image);
  [%test_result: (unit, Api.Error.t) Result.t]
    (Api.Image.validate discovery image)
    ~expect:(Ok ())
;;

let%test_unit "image compatibility failures are typed and pre-mutation" =
  let image = Api.Image.create [ 0 ] in
  [%test_result: string]
    (error_code (Api.Image.validate discovery { image with isa_id = "other" }))
    ~expect:"incompatible_isa";
  [%test_result: string]
    (error_code (Api.Image.validate discovery { image with format_version = 2 }))
    ~expect:"incompatible_image";
  [%test_result: string]
    (error_code (Api.Image.validate discovery { image with word_bits = 32 }))
    ~expect:"incompatible_image";
  [%test_result: string]
    (error_code (Api.Image.validate discovery (Api.Image.create [])))
    ~expect:"invalid_argument";
  [%test_result: string]
    (error_code
       (Api.Image.validate discovery (Api.Image.create (List.init 257 ~f:Fn.id))))
    ~expect:"invalid_argument";
  [%test_result: string]
    (error_code (Api.Image.validate discovery (Api.Image.create [ 0x1_0000 ])))
    ~expect:"invalid_argument";
  [%test_result: string]
    (error_code (Api.Image.of_string "((format broken)"))
    ~expect:"image_parse"
;;

let%test_unit "API and ISA requirements reject incompatible peers" =
  [%test_result: string]
    (error_code (Api.require_api discovery { major = 2; minor = 0 }))
    ~expect:"incompatible_api";
  [%test_result: (unit, Api.Error.t) Result.t]
    (Api.require_api discovery { major = 1; minor = 0 })
    ~expect:(Ok ());
  [%test_result: string]
    (error_code (Api.require_isa discovery ~id:"other" ~version:1))
    ~expect:"incompatible_isa"
;;

let%test_unit "control and transfer timeout codes are distinct" =
  [%test_result: string]
    (Api.Error.code (Timeout { operation = "stop"; budget_cycles = 1; accepted = true }))
    ~expect:"timeout";
  [%test_result: string]
    (Api.Error.code
       (Transfer_incomplete
          { queue = "host-rx"
          ; requested = 2
          ; transferred = 1
          ; data = [ 0xa5 ]
          ; outcome = Timed_out
          }))
    ~expect:"transfer_timeout";
  [%test_result: string]
    (Api.Error.code
       (Transfer_incomplete
          { queue = "host-rx"
          ; requested = 1
          ; transferred = 0
          ; data = []
          ; outcome = Complete
          }))
    ~expect:"transfer_incomplete"
;;

let%test_unit "authoritative refusal reasons have stable codes" =
  let code reason = Api.Error.code (Refused { operation = "test"; reason }) in
  [%test_result: string] (code No_verified_image) ~expect:"no_verified_image";
  [%test_result: string] (code Image_bounds) ~expect:"image_bounds";
  [%test_result: string] (code Execution_faulted) ~expect:"execution_faulted";
  [%test_result: string] (code Terminal_halt) ~expect:"terminal_halt";
  [%test_result: string] (code Pin_conflict) ~expect:"pin_conflict";
  [%test_result: string] (code Hardware_rejected) ~expect:"refused"
;;
