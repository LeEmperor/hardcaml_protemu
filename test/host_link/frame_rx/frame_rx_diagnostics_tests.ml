(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "frame_rx_diagnostics_tests.ml" *)
(* HL4c: the Frame_rx checks detect the errors they exist for, and report enough to
   reproduce them.

   Each case states an expectation that is wrong, or waits for something that never
   happens, and requires the check to raise [Rx_failure]. None of them changes the
   receiver or leaves a failing test in the suite. The first case prints a complete
   report, so its format is reviewed here.
*)

open! Core
open! Hardcaml_protemu
open! Frame_rx_testbench

let require_failure t what f =
  match failure_of f with
  | Some failure -> failure
  | None -> fail t ~phase:Post_run ("the negative check must fail: " ^ what)
;;

let%expect_test "a wrong validation result is reported with the recent cycles" =
  let t = create ~transcript_cycles:4 "negative: bad CRC expected to be complete" in
  let frame = Raw.flip_last (encode ~tag:0x5e Stop) ~mask:0x01 in
  print_s
    (require_failure t "a CRC error reported as complete" (fun () ->
       expect_handoff
         t
         "STOP"
         frame
         { result = Complete
         ; echo_valid = true
         ; tag = 0x5e
         ; command = 0x21
         ; payload_length = 0
         ; payload = Char.to_int frame.[6]
         }));
  [%expect
    {|
    (test/host_link/frame_rx/frame_rx_testbench.ml.Rx_failure
     (scenario "negative: bad CRC expected to be complete") (cycle 462)
     (phase Pre_edge) (what "STOP: result, echo, and retained fields")
     (expected
      ((((result Complete) (echo_valid true) (tag 94) (command 33)
         (payload_length 0) (payload 121)))))
     (actual
      ((((result Bad_crc) (echo_valid true) (tag 94) (command 33)
         (payload_length 0) (payload 121)))))
     (transcript
      ((460 "rst=0 en=1 elig=1 sel=1 data=0"
        "active result=13 echo=1 tag=5e command=21 length=0000 payload=00000079")
       (461 "rst=0 en=1 elig=1 sel=1 data=0"
        "active result=13 echo=1 tag=5e command=21 length=0000 payload=00000079")
       (462 "rst=0 en=1 elig=1 sel=0 data=0 release"
        "active FRAME_END result=13 echo=1 tag=5e command=21 length=0000 payload=00000079")
       (463 "rst=0 en=1 elig=1 sel=0 data=0"
        "result=13 echo=1 tag=5e command=21 length=0000 payload=00000079"))))
    |}]
;;

let%test_unit "a handoff expected one cycle late is detected" =
  (* Stands in for a registered handoff between validation and dispatch. *)
  let t = create "negative: handoff one cycle late" in
  let from = t.cycle in
  let { Selection.released; _ } = request t (encode ~tag:0x01 Info) in
  run t 2;
  ignore
    (require_failure t "a one-cycle-late handoff" (fun () ->
       expect_frame_end_cycles t ~from "late" [ released + 1 ])
     : Sexp.t)
;;

let%test_unit "an echo expected below the four-byte threshold is detected" =
  (* Stands in for a threshold of three bytes. *)
  let t = create "negative: echo after three bytes" in
  let { Selection.released; _ } = request t (String.prefix (encode ~tag:0x02 Info) 3) in
  run t 1;
  ignore
    (require_failure t "an echo after three bytes" (fun () ->
       expect_fields
         t
         ~cycle:released
         "three bytes"
         { (Expected.empty Incomplete) with echo_valid = true; tag = 0x02 })
     : Sexp.t)
;;

let%test_unit "waits are bounded and time out with a report" =
  let t = create "negative: wait budget" in
  let start = t.cycle in
  ignore
    (require_failure t "a wait for a request that never starts" (fun () ->
       ignore (wait_for ~budget:25 t "active" ~f:(fun s -> s.active) : int))
     : Sexp.t);
  check
    t
    ~phase:Post_run
    "cycles spent by the exhausted wait"
    [%sexp_of: int]
    [%equal: int]
    ~expected:25
    (t.cycle - start)
;;
