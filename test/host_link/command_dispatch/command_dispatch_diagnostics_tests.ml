(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "command_dispatch_diagnostics_tests.ml" *)
(* HL4c: the Command_dispatch checks detect the errors they exist for, and report enough
   to reproduce them.

   Each case states an expectation that is wrong, or waits for something that never
   happens, and requires the check to raise [Dispatch_failure]. None of them changes the
   dispatcher or leaves a failing test in the suite. The first case prints a complete
   report, so its format is reviewed here.
*)

open! Core
open! Hardcaml_protemu
open! Command_dispatch_testbench

let require_failure t what f =
  match failure_of f with
  | Some failure -> failure
  | None -> fail t ~phase:Post_run ("the negative check must fail: " ^ what)
;;

let%expect_test "a wrong refusal class is reported with the recent cycles" =
  let t = create ~transcript_cycles:4 "negative: engines-active refusal expected" in
  t.stub.accept <- (fun _ -> false);
  set_status t Status.running;
  let from = t.cycle in
  let h = handoff t (Handoff.request ~tag:0x5e Run) in
  run t 2;
  print_s
    (require_failure t "execution refusal reported as engines active" (fun () ->
       expect_publications t ~from "RUN" [ h + 1, response ~tag:0x5e Run Engines_active ]));
  [%expect
    {|
    (test/host_link/command_dispatch/command_dispatch_testbench.ml.Dispatch_failure
     (scenario "negative: engines-active refusal expected") (cycle 4)
     (phase Post_run) (what "RUN: publications in cycles [2, 5)")
     (expected
      (((3
         (Response
          ((tag 94) (command 32) (result Engines_active) (payload Empty)))))))
     (actual
      (((3
         (Response
          ((tag 94) (command 32) (result Active_execution) (payload Empty)))))))
     (transcript
      ((1
        "rst=1 en=1 result=15 echo=0 tag=00 command=00 length=0000 payload=00000000"
        "idle status=halted=1,engines_idle=1")
       (2
        "rst=0 en=1 FRAME_END result=00 echo=1 tag=5e command=20 length=0000 payload=00000013"
        "idle status=image_valid=1,execution_active=1,phase=5,pin_oe=2,engine_claim=2")
       (3
        "rst=0 en=1 result=00 echo=1 tag=5e command=20 length=0000 payload=00000013"
        "busy offer=Run refused PUBLISH 5a 10 5e 20 20 00 00 7e status=image_valid=1,execution_active=1,phase=5,pin_oe=2,engine_claim=2")
       (4
        "rst=0 en=1 result=00 echo=1 tag=5e command=20 length=0000 payload=00000013"
        "idle status=image_valid=1,execution_active=1,phase=5,pin_oe=2,engine_claim=2"))))
    |}]
;;

let%test_unit "a publication expected one cycle late is detected" =
  (* Stands in for a registered publication between the decision and the store. *)
  let t = create "negative: publication one cycle late" in
  let from = t.cycle in
  let h = handoff t (Handoff.request ~tag:0x01 Stop) in
  run t 5;
  ignore
    (require_failure t "a one-cycle-late publication" (fun () ->
       expect_publications
         t
         ~from
         "late"
         [ h + 2, response ~tag:0x01 Stop Accepted_pending ])
     : Sexp.t)
;;

let%test_unit "a repeated offer is detected" =
  (* Stands in for dispatch that is not cleared after its offer. *)
  let t = create "negative: a second offer expected" in
  let from = t.cycle in
  let h = handoff t (Handoff.request ~tag:0x02 Run) in
  run t 5;
  ignore
    (require_failure t "two offers" (fun () ->
       expect_offers
         t
         ~since:from
         "twice"
         [ { cycle = h + 1; request = Run; accepted = true }
         ; { cycle = h + 2; request = Run; accepted = true }
         ])
     : Sexp.t)
;;

let%test_unit "a lost correlation is detected" =
  let t = create "negative: wrong tag expected" in
  let from = t.cycle in
  let h = handoff t (Handoff.request ~tag:0x03 Load_complete) in
  run t 3;
  ignore
    (require_failure t "a response with another tag" (fun () ->
       expect_publications
         t
         ~from
         "tag"
         [ h + 1, response ~tag:0x04 Load_complete Complete ])
     : Sexp.t)
;;

let%test_unit "waits are bounded and time out with a report" =
  let t = create "negative: wait budget" in
  let start = t.cycle in
  ignore
    (require_failure t "a wait for a publication that never happens" (fun () ->
       ignore (wait_for ~budget:25 t "publication" ~f:(fun s -> s.publish) : int))
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
