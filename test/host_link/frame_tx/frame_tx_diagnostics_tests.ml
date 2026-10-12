(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "frame_tx_diagnostics_tests.ml" *)
(* HL4c: the Frame_tx checks detect the errors they exist for, and report enough to
   reproduce them.

   Each case states an expectation that is wrong, or waits for something that never
   happens, and requires the check to raise [Tx_failure]. None of them changes the
   transmitter or leaves a failing test in the suite. The first case prints a complete
   report, so its format is reviewed here.
*)

open! Core
open! Hardcaml_protemu
open! Frame_tx_testbench

let require_failure t what f =
  match failure_of f with
  | Some failure -> failure
  | None -> fail t ~phase:Post_run ("the negative check must fail: " ^ what)
;;

let%expect_test "a wrong bit is reported with the recent cycles" =
  (* Stands in for a transmitter that presents the version byte's nibbles swapped. *)
  let t = create ~transcript_cycles:4 "negative: wrong second byte" in
  let _ : int = publish t (Frames.empty 0x5e) in
  run t 2;
  let _ : int = select t in
  run t 3;
  print_s
    (require_failure t "a version byte of 01" (fun () ->
       expect_read ~periods:[ 2 ] ~count:16 t "header" "\x5a\x01"));
  [%expect
    {|
    (test/host_link/frame_tx/frame_tx_testbench.ml.Tx_failure
     (scenario "negative: wrong second byte") (cycle 40) (phase Post_run)
     (what "header: bits read, MSB first") (expected ("5a 01"))
     (actual ("5a 10"))
     (transcript
      ((37 "rst=0 en=1 qual=0" "data=0 ready=1 pending=1")
       (38 "rst=0 en=1 qual=0 fall" "data=0 ready=1 pending=1")
       (39 "rst=0 en=1 qual=0" "data=0 ready=1 pending=1")
       (40 "rst=0 en=1 qual=0 fall" "data=0 ready=1 pending=1"))))
    |}]
;;

let%test_unit "a first bit expected in the assert cycle is detected" =
  (* Stands in for a transmitter that presents the frame before it is armed. *)
  let t = create "negative: first bit in the assert cycle" in
  let bytes = "\x80" ^ String.make 7 '\x00' in
  let _ : int = publish t bytes in
  run t 2;
  let asserted = select t in
  run t 3;
  ignore
    (require_failure t "data in the assert cycle" (fun () ->
       expect_data_cycles t ~from:asserted "early" (List.range asserted t.cycle))
     : Sexp.t)
;;

let%test_unit "a commit expected one cycle early is detected" =
  let t = create "negative: early commit" in
  let bytes = Frames.empty 0x21 in
  let _ : int = publish t bytes in
  run t 2;
  let { Read.asserted; released } = commit_read t "empty" bytes in
  ignore
    (require_failure t "pending low in the release cycle" (fun () ->
       expect_pending_cycles t ~from:asserted "early" (List.range asserted released))
     : Sexp.t)
;;

let%test_unit "a replay that does not restart at byte zero is detected" =
  let t = create "negative: replay from byte one" in
  let bytes = Frames.word 0x22 in
  let _ : int = publish t bytes in
  run t 2;
  let _ : Read.t = partial_read t "first byte" bytes ~count:8 in
  run t 4;
  ignore
    (require_failure t "a replay that continues" (fun () ->
       ignore (commit_read t "continued" (String.drop_prefix bytes 1) : Read.t))
     : Sexp.t)
;;

let%test_unit "waits are bounded and time out with a report" =
  let t = create "negative: wait budget" in
  let start = t.cycle in
  ignore
    (require_failure t "a wait for a response nobody publishes" (fun () ->
       ignore (wait_for ~budget:25 t "pending" ~f:(fun s -> s.pending) : int))
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
