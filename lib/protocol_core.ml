(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "protocol_core.ml" *)
(* Program-store consumer and the P3.2 fetch boundary.

   The memory remains outside this module. This block drives one synchronous 1RW port,
   owns load-session and executable-image validity, arbitrates halted host access against
   running fetches, and associates each latency-one response with its requester. It does
   not decode or execute instructions.

   The implemented configuration is P1.5's default image layout: 256 sixteen-bit memory
   words, one instruction slot per word, addressed in words. Host and fetch addresses are
   one bit wider than the physical port so bounds are checked before narrowing. See
   construction-plan.md, "Program load, access, and fetch contract".
*)

open! Core
open! Hardcaml
open! Signal

module Config = struct
  let program_width = 16
  let program_depth = 256
  let program_address_bits = Int.ceil_log2 program_depth
  let request_address_bits = Int.ceil_log2 (program_depth + 1)
end

module I = struct
  type 'a t =
    { (* System clock domain. Reset is synchronous and active high. [en_i] low halts
         execution and cancels response ownership without resetting memory. *)
      clock_i : 'a
    ; reset_i : 'a
    ; en_i : 'a
    ; engines_idle_i : 'a
    ; (* Host load-session requests. Each valid offer receives accepted or rejected. *)
      load_start_valid_i : 'a
    ; load_length_i : 'a [@bits Config.request_address_bits]
    ; load_write_valid_i : 'a
    ; load_address_i : 'a [@bits Config.request_address_bits]
    ; load_data_i : 'a [@bits Config.program_width]
    ; load_complete_valid_i : 'a
    ; (* Host readback. Verification requests compare the returned word with
         [readback_expected_i] and advance the load verification pass on equality. *)
      readback_valid_i : 'a
    ; readback_address_i : 'a [@bits Config.request_address_bits]
    ; readback_verify_i : 'a
    ; readback_expected_i : 'a [@bits Config.program_width]
    ; (* Execution ownership. RUN starts the P3.2 fetch consumer; [execution_halt_i]
         returns ownership to the host. *)
      run_valid_i : 'a
    ; execution_halt_i : 'a
    ; fetch_valid_i : 'a
    ; fetch_address_i : 'a [@bits Config.request_address_bits]
    ; (* Program store -> core. The external store presents latency-one read data. *)
      prog_mem_read_data_i : 'a [@bits Config.program_width]
    }
  [@@deriving hardcaml]
end

module O = struct
  type 'a t =
    { (* Core -> external program-store 1RW port. *)
      prog_mem_enable_o : 'a
    ; prog_mem_write_enable_o : 'a
    ; prog_mem_address_o : 'a [@bits Config.program_address_bits]
    ; prog_mem_write_data_o : 'a [@bits Config.program_width]
    ; (* One-cycle request decisions. A valid offer asserts exactly one of its pair. *)
      load_start_accepted_o : 'a
    ; load_start_rejected_o : 'a
    ; load_write_accepted_o : 'a
    ; load_write_rejected_o : 'a
    ; load_complete_accepted_o : 'a
    ; load_complete_rejected_o : 'a
    ; readback_accepted_o : 'a
    ; readback_rejected_o : 'a
    ; run_accepted_o : 'a
    ; run_rejected_o : 'a
    ; fetch_accepted_o : 'a
    ; fetch_rejected_o : 'a
    ; (* Registered latency-one responses. Data is meaningful only with valid high. *)
      readback_response_valid_o : 'a
    ; readback_response_data_o : 'a [@bits Config.program_width]
    ; readback_response_match_o : 'a
    ; (* Execution-only latency-one completion. Unlike the registered observation below,
         this is consumed at the edge on which pending ownership completes. *)
      fetch_completion_valid_o : 'a
    ; fetch_completion_data_o : 'a [@bits Config.program_width]
    ; fetch_response_valid_o : 'a
    ; fetch_response_data_o : 'a [@bits Config.program_width]
    ; (* Control and bounded-image status. *)
      halted_o : 'a
    ; image_valid_o : 'a
    ; load_active_o : 'a
    ; image_length_o : 'a [@bits Config.request_address_bits]
    ; words_written_o : 'a [@bits Config.request_address_bits]
    ; words_verified_o : 'a [@bits Config.request_address_bits]
    ; verification_failed_o : 'a
    ; fetch_fault_event_o : 'a
    ; fetch_fault_o : 'a
    }
  [@@deriving hardcaml]
end

[@@@ocamlformat "disable"]

(* Registered ownership, image metadata, and response association. Data memory itself is
   deliberately absent and is never reset here. *)
module I_Regs = struct
  type 'a t =
    { running                 : 'a
    ; image_valid             : 'a
    ; load_active             : 'a
    ; image_length            : 'a [@bits Config.request_address_bits]
    ; words_written           : 'a [@bits Config.request_address_bits]
    ; words_verified          : 'a [@bits Config.request_address_bits]
    ; verification_failed     : 'a
    ; host_read_pending       : 'a
    ; host_read_verify        : 'a
    ; host_read_expected      : 'a [@bits Config.program_width]
    ; fetch_pending           : 'a
    ; readback_response_valid : 'a
    ; readback_response_data  : 'a [@bits Config.program_width]
    ; readback_response_match : 'a
    ; fetch_response_valid    : 'a
    ; fetch_response_data     : 'a [@bits Config.program_width]
    ; fetch_fault             : 'a
    }
  [@@deriving hardcaml]
end

let create (_scope : Scope.t) (i : _ I.t) : _ O.t =
  let open Always in
  let spec = Reg_spec.create ~clock:i.clock_i ~clear:i.reset_i () in
  let r = I_Regs.Of_always.reg spec in

  let halted       = ~:(r.running.value) in
  let host_allowed = i.en_i &: halted &: i.engines_idle_i &: ~:(i.reset_i) in
  let no_start     = ~:(i.load_start_valid_i) in
  let no_write     = no_start &: ~:(i.load_write_valid_i) in
  let no_read      = no_write &: ~:(i.readback_valid_i) in
  let no_complete  = no_read &: ~:(i.load_complete_valid_i) in

  (* Length/address comparisons remain at request width. Only an accepted operation is
     narrowed for the physical port. *)
  let length_valid = (i.load_length_i >:. 0) &: (i.load_length_i <=:. Config.program_depth) in
  let start_accept = host_allowed &: i.load_start_valid_i &: length_valid in
  let write_accept =
    host_allowed
    &: no_start
    &: i.load_write_valid_i
    &: r.load_active.value
    &: (i.load_address_i ==: r.words_written.value)
    &: (i.load_address_i <: r.image_length.value)
  in
  let read_limit =
    mux2 r.load_active.value r.words_written.value r.image_length.value
  in
  let ordinary_read_legal =
    (r.load_active.value |: r.image_valid.value)
    &: (i.readback_address_i <: read_limit)
  in
  let verification_read_legal =
    r.load_active.value
    &: (r.words_written.value ==: r.image_length.value)
    &: ~:(r.verification_failed.value)
    &: (i.readback_address_i ==: r.words_verified.value)
    &: (i.readback_address_i <: r.image_length.value)
  in
  let read_accept =
    host_allowed
    &: no_write
    &: i.readback_valid_i
    &: ~:(r.host_read_pending.value)
    &: mux2 i.readback_verify_i verification_read_legal ordinary_read_legal
  in
  let complete_accept =
    host_allowed
    &: no_read
    &: i.load_complete_valid_i
    &: r.load_active.value
    &: (r.words_written.value ==: r.image_length.value)
    &: (r.words_verified.value ==: r.image_length.value)
    &: ~:(r.verification_failed.value)
    &: ~:(r.host_read_pending.value)
  in
  let run_accept =
    host_allowed
    &: no_complete
    &: i.run_valid_i
    &: r.image_valid.value
    &: ~:(r.host_read_pending.value)
  in

  let fetch_in_bounds =
    (i.fetch_address_i <:. Config.program_depth)
    &: (i.fetch_address_i <: r.image_length.value)
  in
  let fetch_completion =
    i.en_i &: r.fetch_pending.value &: ~:(i.reset_i)
  in
  let fetch_slot_available = ~:(r.fetch_pending.value) |: fetch_completion in
  let fetch_active_offer =
    i.en_i &: r.running.value &: ~:(i.reset_i) &: fetch_slot_available
  in
  let fetch_accept =
    fetch_active_offer &: ~:(i.execution_halt_i) &: i.fetch_valid_i &: fetch_in_bounds
  in
  let invalid_fetch = fetch_active_offer &: i.fetch_valid_i &: ~:(fetch_in_bounds) in

  let host_read_response =
    i.en_i
    &: r.host_read_pending.value
    &: ~:(start_accept)
    &: ~:(i.reset_i)
  in
  let fetch_response = fetch_completion &: ~:(i.execution_halt_i) in
  let verification_match = i.prog_mem_read_data_i ==: r.host_read_expected.value in

  (* The external port has one owner per edge. Running fetch is independent of every live
     host offer; while halted, a write has priority over a read. *)
  let mem_write  = write_accept in
  let mem_read   = read_accept |: fetch_accept in
  let mem_enable = mem_write |: mem_read in
  let mem_address_wide =
    mux2 mem_write i.load_address_i (mux2 read_accept i.readback_address_i i.fetch_address_i)
  in

  (* Defaults hold durable state and clear response pulses. Later assignments encode the
     documented priority: disable/cancellation, response completion, load operations,
     completion, RUN, and fetch fault/start. Synchronous reset dominates the whole block. *)
  compile
    [ r.running                 <-- r.running.value
    ; r.image_valid             <-- r.image_valid.value
    ; r.load_active             <-- r.load_active.value
    ; r.image_length            <-- r.image_length.value
    ; r.words_written           <-- r.words_written.value
    ; r.words_verified          <-- r.words_verified.value
    ; r.verification_failed     <-- r.verification_failed.value
    ; r.host_read_pending       <-- r.host_read_pending.value
    ; r.host_read_verify        <-- r.host_read_verify.value
    ; r.host_read_expected      <-- r.host_read_expected.value
    ; r.fetch_pending           <-- r.fetch_pending.value
    ; r.readback_response_valid <--. 0
    ; r.readback_response_data  <-- r.readback_response_data.value
    ; r.readback_response_match <--. 0
    ; r.fetch_response_valid    <--. 0
    ; r.fetch_response_data     <-- r.fetch_response_data.value
    ; r.fetch_fault             <-- r.fetch_fault.value

    ; if_ ~:(i.en_i)
        [ r.running                 <--. 0
        ; r.load_active             <--. 0
        ; r.host_read_pending       <--. 0
        ; r.fetch_pending           <--. 0
        ; r.readback_response_valid <--. 0
        ; r.fetch_response_valid    <--. 0
        ]
        [ (* Deliver only responses whose ownership survived this edge. *)
          when_ host_read_response
            [ r.host_read_pending       <--. 0
            ; r.readback_response_valid <--. 1
            ; r.readback_response_data  <-- i.prog_mem_read_data_i
            ; r.readback_response_match <-- (r.host_read_verify.value &: verification_match)
            ; when_ r.host_read_verify.value
                [ if_ verification_match
                    [ r.words_verified <-- r.words_verified.value +:. 1 ]
                    [ r.verification_failed <--. 1 ]
                ]
            ]
        ; when_ fetch_response
            [ r.fetch_pending        <--. 0
            ; r.fetch_response_valid <--. 1
            ; r.fetch_response_data  <-- i.prog_mem_read_data_i
            ]

        ; when_ i.execution_halt_i
            [ r.running              <--. 0
            ; r.fetch_pending        <--. 0
            ; r.fetch_response_valid <--. 0
            ]

        ; when_ start_accept
            [ r.image_valid             <--. 0
            ; r.load_active             <--. 1
            ; r.image_length            <-- i.load_length_i
            ; r.words_written           <--. 0
            ; r.words_verified          <--. 0
            ; r.verification_failed     <--. 0
            ; r.host_read_pending       <--. 0
            ; r.readback_response_valid <--. 0
            ; r.fetch_fault             <--. 0
            ]
        ; when_ write_accept
            [ r.words_written <-- r.words_written.value +:. 1 ]
        ; when_ read_accept
            [ r.host_read_pending  <--. 1
            ; r.host_read_verify   <-- i.readback_verify_i
            ; r.host_read_expected <-- i.readback_expected_i
            ]
        ; when_ complete_accept
            [ r.load_active <--. 0
            ; r.image_valid <--. 1
            ]
        ; when_ run_accept
            [ r.running     <--. 1
            ; r.fetch_fault <--. 0
            ]

        ; when_ invalid_fetch
            [ r.running              <--. 0
            ; r.fetch_pending        <--. 0
            ; r.fetch_response_valid <--. 0
            ; r.fetch_fault          <--. 1
            ]
        ; when_ fetch_accept
            [ r.fetch_pending <--. 1 ]
        ]
    ];

  { O.prog_mem_enable_o          = mem_enable &: ~:(i.reset_i)
  ; prog_mem_write_enable_o      = mem_write &: ~:(i.reset_i)
  ; prog_mem_address_o           = sel_bottom mem_address_wide ~width:Config.program_address_bits
  ; prog_mem_write_data_o        = i.load_data_i
  ; load_start_accepted_o        = start_accept
  ; load_start_rejected_o        = i.load_start_valid_i &: ~:(start_accept)
  ; load_write_accepted_o        = write_accept
  ; load_write_rejected_o        = i.load_write_valid_i &: ~:(write_accept)
  ; load_complete_accepted_o     = complete_accept
  ; load_complete_rejected_o     = i.load_complete_valid_i &: ~:(complete_accept)
  ; readback_accepted_o          = read_accept
  ; readback_rejected_o          = i.readback_valid_i &: ~:(read_accept)
  ; run_accepted_o               = run_accept
  ; run_rejected_o               = i.run_valid_i &: ~:(run_accept)
  ; fetch_accepted_o             = fetch_accept
  ; fetch_rejected_o             = i.fetch_valid_i &: ~:(fetch_accept)
  ; readback_response_valid_o    = r.readback_response_valid.value
  ; readback_response_data_o     = r.readback_response_data.value
  ; readback_response_match_o    = r.readback_response_match.value
  ; fetch_completion_valid_o     = fetch_completion
  ; fetch_completion_data_o      = i.prog_mem_read_data_i
  ; fetch_response_valid_o       = r.fetch_response_valid.value
  ; fetch_response_data_o        = r.fetch_response_data.value
  ; halted_o                     = halted
  ; image_valid_o                = r.image_valid.value
  ; load_active_o                = r.load_active.value
  ; image_length_o               = r.image_length.value
  ; words_written_o              = r.words_written.value
  ; words_verified_o             = r.words_verified.value
  ; verification_failed_o        = r.verification_failed.value
  ; fetch_fault_event_o          = invalid_fetch
  ; fetch_fault_o                = r.fetch_fault.value
  }
;;
[@@@ocamlformat "enable"]
