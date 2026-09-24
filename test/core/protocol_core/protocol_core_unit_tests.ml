(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "protocol_core_unit_tests.ml" *)
(* Directed P3.1a contract evidence. Generated model/RTL scenarios are in
   protocol_core_property_tests.ml. *)

open! Core
open! Protemu_f_model
open! Protocol_core_testbench

let reset_and_incomplete_images_cannot_run create =
  let t = create Poison.Zero in
  step t (input ~run:true ());
  check t.edge "RUN without image stays halted" true (Program_access.halted t.model);
  step t (input ~load_start:3 ());
  step t (input ~load_write:(0, 0x1111) ());
  step t (input ~load_write:(2, 0x3333) ());
  check t.edge "out-of-order write did not advance" 1 t.model.words_written;
  step t (input ~load_write:(0, 0xaaaa) ());
  check t.edge "duplicate write did not advance" 1 t.model.words_written;
  step t (input ~load_complete:true ~run:true ());
  check t.edge "premature completion did not validate" false t.model.image_valid;
  check t.edge "simultaneous RUN did not start" true (Program_access.halted t.model);
  step t (input ~reset:true ());
  step t (input ~run:true ());
  check t.edge "reset interrupted the partial session" false t.model.load_active;
  check t.edge "reset partial image cannot run" true (Program_access.halted t.model)
;;

let complete_sequential_write_and_matching_readback_authorize_run create =
  let words = [ 0x0000; 0x1234; 0xffff ] in
  List.iter Poison.all ~f:(fun poison ->
    let t = create poison in
    complete_load t words;
    check t.edge "image valid" true t.model.image_valid;
    step t (input ~run:true ());
    check t.edge "RUN accepted" false (Program_access.halted t.model);
    List.iteri words ~f:(fun address expected ->
      step t (input ~fetch:address ());
      step t (input ());
      check t.edge "fetched expected word" (Some expected) t.model.response.fetch))
;;

let verification_mismatch_and_unchecked_completion_cannot_authorize_image create =
  let t = create Poison.Ones in
  load_words t [ 0x1111; 0x2222 ];
  step t (input ~readback:(0, true, 0x1111) ());
  step t (input ());
  step t (input ~readback:(1, true, 0x9999) ());
  step t (input ());
  check t.edge "mismatch latched" true t.model.verification_failed;
  step t (input ~load_complete:true ());
  step t (input ~run:true ());
  check t.edge "bad image remains non-executable" true (Program_access.halted t.model)
;;

let replacement_invalidates_immediately_and_a_shorter_image_hides_old_tail create =
  let t = create Poison.Zero in
  complete_load t [ 0x1111; 0x2222; 0x3333; 0x4444 ];
  step t (input ~load_start:2 ());
  check t.edge "replacement invalidated old image" false t.model.image_valid;
  step t (input ~run:true ());
  complete_load t [ 0xaaaa; 0xbbbb ];
  step t (input ~run:true ());
  step t (input ~fetch:2 ());
  check t.edge "old tail fetch halted" true (Program_access.halted t.model);
  check t.edge "old tail fetch faulted" true t.model.fetch_fault;
  check t.edge "old tail did not read memory" false t.model.fetch_pending
;;

let zero_and_oversized_lengths_are_rejected_without_destroying_a_valid_image create =
  let t = create Poison.Zero in
  complete_load t [ 0x5a5a ];
  step t (input ~load_start:0 ());
  check t.edge "zero preserved image" true t.model.image_valid;
  step t (input ~load_start:257 ());
  check t.edge "oversize preserved image" true t.model.image_valid;
  let boundary = create Poison.Zero in
  let words = List.init depth ~f:(fun n -> n) in
  complete_load boundary words;
  check boundary.edge "depth-sized image valid" true boundary.model.image_valid
;;

let halted_busy_engines_refuse_all_program_access_and_run create =
  let t = create Poison.Zero in
  let before = memory_snapshot t in
  step
    t
    (input
       ~engines_idle:false
       ~load_start:1
       ~load_write:(0, 1)
       ~readback:(0, false, 0)
       ~load_complete:true
       ~run:true
       ());
  check t.edge "no session started" false t.model.load_active;
  check
    t.edge
    "engines busy left memory unchanged"
    true
    (Array.equal (Option.equal Int.equal) before t.store.words)
;;

let execution_halt_rejects_lower_priority_host_work_and_discards_a_host_response create =
  let start = create Poison.Zero in
  complete_load start [ 0x1111 ];
  step start (input ~execution_halt:true ~load_start:1 ());
  check start.edge "halt preserved valid image" true start.model.image_valid;
  check start.edge "halt did not start replacement" false start.model.load_active;
  let write = create Poison.Zero in
  step write (input ~load_start:1 ());
  let before = memory_snapshot write in
  step write (input ~execution_halt:true ~load_write:(0, 0x2222) ());
  check write.edge "halt did not advance write" 0 write.model.words_written;
  check
    write.edge
    "halt did not write memory"
    true
    (Array.equal (Option.equal Int.equal) before write.store.words);
  let complete = create Poison.Zero in
  load_words complete [ 0x3333 ];
  verify_words complete [ 0x3333 ];
  step complete (input ~execution_halt:true ~load_complete:true ());
  check complete.edge "halt did not complete image" false complete.model.image_valid;
  check complete.edge "halt preserved active load" true complete.model.load_active;
  let read = create Poison.Zero in
  complete_load read [ 0x4444 ];
  step read (input ~readback:(0, false, 0) ());
  step read (input ~execution_halt:true ~readback:(0, false, 0) ());
  check read.edge "halt discarded due host response" None read.model.response.readback;
  check read.edge "halt cleared host ownership" None read.model.host_read_pending;
  step read (input ());
  check
    read.edge
    "discarded host response did not recur"
    None
    read.model.response.readback
;;

let live_host_requests_cannot_steal_or_corrupt_a_fetch create =
  let t = create Poison.Zero in
  complete_load t [ 0x1357; 0x2468 ];
  step t (input ~run:true ());
  let before = memory_snapshot t in
  step
    t
    (input
       ~load_start:1
       ~load_write:(0, 0xdead)
       ~readback:(0, false, 0)
       ~load_complete:true
       ~run:true
       ~fetch:0
       ());
  step t (input ~load_write:(1, 0xbeef) ~readback:(1, false, 0) ());
  check t.edge "fetch survived live requests" (Some 0x1357) t.model.response.fetch;
  check
    t.edge
    "live requests left memory unchanged"
    true
    (Array.equal (Option.equal Int.equal) before t.store.words)
;;

let read_and_fetch_validity_are_exact_latency_one_and_disabled_output_cannot_recur create =
  let t = create Poison.Address in
  complete_load t [ 0x0000 ];
  step t (input ~readback:(0, false, 0) ());
  check t.edge "request edge has no response" None t.model.response.readback;
  step t (input ());
  check t.edge "next edge has response" (Some (0, false)) t.model.response.readback;
  step t (input ());
  check t.edge "held RAM output has no validity" None t.model.response.readback;
  step t (input ~run:true ());
  step t (input ~fetch:0 ());
  check t.edge "fetch request edge has no response" None t.model.response.fetch;
  step t (input ());
  check
    t.edge
    "fetch response is valid even for zero data"
    (Some 0)
    t.model.response.fetch
;;

let a_due_fetch_completion_can_turn_over_into_the_next_fetch create =
  let t = create Poison.Zero in
  complete_load t [ 0x1111; 0x2222 ];
  step t (input ~run:true ());
  step t (input ~fetch:0 ());
  step t (input ~fetch:1 ());
  check t.edge "first response delivered" (Some 0x1111) t.model.response.fetch;
  check t.edge "second fetch retained ownership" true t.model.fetch_pending;
  step t (input ());
  check t.edge "second response delivered" (Some 0x2222) t.model.response.fetch
;;

let final_legal_address_works_and_out_of_image_or_physical_range_addresses_fault create =
  let t = create Poison.Zero in
  let words = List.init depth ~f:(fun n -> n * 17 land 0xffff) in
  complete_load t words;
  step t (input ~run:true ());
  step t (input ~fetch:(depth - 1) ());
  step t (input ());
  check t.edge "last word fetched" (Some (List.last_exn words)) t.model.response.fetch;
  step t (input ~fetch:depth ());
  check t.edge "depth address faulted before truncation" true t.model.fetch_fault;
  let short = create Poison.Zero in
  complete_load short [ 7 ];
  step short (input ~readback:(1, false, 0) ());
  check short.edge "out-of-image readback was refused" None short.model.host_read_pending;
  step short (input ~readback:(depth, false, 0) ());
  check short.edge "out-of-range readback was refused" None short.model.host_read_pending;
  step short (input ~run:true ());
  step short (input ~fetch:1 ());
  check short.edge "first out-of-image address faulted" true short.model.fetch_fault
;;

let reset_disable_halt_and_reload_discard_outstanding_ownership create =
  let reset_case = create Poison.Zero in
  complete_load reset_case [ 0x1111 ];
  step reset_case (input ~readback:(0, false, 0) ());
  step reset_case (input ~reset:true ());
  check
    reset_case.edge
    "reset discarded host response"
    None
    reset_case.model.response.readback;
  check reset_case.edge "reset invalidated image" false reset_case.model.image_valid;
  let halt_case = create Poison.Zero in
  complete_load halt_case [ 0x2222 ];
  step halt_case (input ~run:true ());
  step halt_case (input ~fetch:0 ());
  step halt_case (input ~execution_halt:true ());
  check halt_case.edge "halt discarded fetch response" None halt_case.model.response.fetch;
  let reload_case = create Poison.Zero in
  complete_load reload_case [ 0x3333 ];
  step reload_case (input ~readback:(0, false, 0) ());
  step reload_case (input ~load_start:1 ());
  check
    reload_case.edge
    "reload discarded read response"
    None
    reload_case.model.response.readback;
  let disable_case = create Poison.Zero in
  complete_load disable_case [ 0x4444 ];
  step disable_case (input ~run:true ());
  step disable_case (input ~fetch:0 ());
  step disable_case (input ~enable:false ());
  check
    disable_case.edge
    "disable discarded fetch response"
    None
    disable_case.model.response.fetch;
  check
    disable_case.edge
    "disable preserved completed image"
    true
    disable_case.model.image_valid
;;

let scenarios =
  [ "reset and incomplete images cannot run", reset_and_incomplete_images_cannot_run
  ; ( "complete sequential write and matching readback authorize RUN"
    , complete_sequential_write_and_matching_readback_authorize_run )
  ; ( "verification mismatch and unchecked completion cannot authorize image"
    , verification_mismatch_and_unchecked_completion_cannot_authorize_image )
  ; ( "replacement invalidates immediately and a shorter image hides old tail"
    , replacement_invalidates_immediately_and_a_shorter_image_hides_old_tail )
  ; ( "zero and oversized lengths are rejected without destroying a valid image"
    , zero_and_oversized_lengths_are_rejected_without_destroying_a_valid_image )
  ; ( "halted busy engines refuse all program access and RUN"
    , halted_busy_engines_refuse_all_program_access_and_run )
  ; ( "execution halt rejects lower-priority host work and discards a host response"
    , execution_halt_rejects_lower_priority_host_work_and_discards_a_host_response )
  ; ( "live host requests cannot steal or corrupt a fetch"
    , live_host_requests_cannot_steal_or_corrupt_a_fetch )
  ; ( "read and fetch validity are exact latency one and disabled output cannot recur"
    , read_and_fetch_validity_are_exact_latency_one_and_disabled_output_cannot_recur )
  ; ( "a due fetch completion can turn over into the next fetch"
    , a_due_fetch_completion_can_turn_over_into_the_next_fetch )
  ; ( "final legal address works and out-of-image or physical-range addresses fault"
    , final_legal_address_works_and_out_of_image_or_physical_range_addresses_fault )
  ; ( "reset, disable, halt, and reload discard outstanding ownership"
    , reset_disable_halt_and_reload_discard_outstanding_ownership )
  ]
;;

let run_all create = List.iter scenarios ~f:(fun (_, scenario) -> scenario create)
let%test_unit "directed P3.1a scenarios" = run_all (fun poison -> create ~poison ())
