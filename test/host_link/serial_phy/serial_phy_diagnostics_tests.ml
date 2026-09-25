(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "serial_phy_diagnostics_tests.ml" *)
(* HL4c: the Serial_phy checks detect the timing errors they exist for, and report enough
   to reproduce them.

   Each case states an expectation that is wrong by one cycle, or waits for something that
   never happens, and requires the check to raise [Phy_failure]. None of them changes the
   PHY or leaves a failing test in the suite. The first case prints a complete report, so
   its format is reviewed here.
*)

open! Core
open! Hardcaml_protemu
open! Serial_phy_testbench

let require_failure t what f =
  match failure_of f with
  | Some failure -> failure
  | None -> fail t ~phase:Post_run ("the negative check must fail: " ^ what)
;;

let%expect_test "an event expected one cycle late is reported with the recent cycles" =
  (* Stands in for an added synchronizer stage. *)
  let t = create ~transcript_cycles:6 "negative: select assert one cycle late" in
  run t 4;
  let selected = drive_select t ~select:true ~hold:4 in
  print_s
    (require_failure t "a three-cycle select latency" (fun () ->
       expect_high_cycles
         t
         Select_assert
         ~from:selected
         ~until:t.cycle
         "assert"
         [ selected + latency + 1 ]));
  [%expect
    {|
    (test/host_link/serial_phy/serial_phy_testbench.ml.Phy_failure
     (scenario "negative: select assert one cycle late") (cycle 9)
     (phase Post_run) (what "assert: Select_assert high in cycles [6, 10)")
     (expected ((9))) (actual ((8)))
     (transcript
      ((4 "rst=0 en=1 LSEL_N=1 LCLK=0 LDI=0" ())
       (5 "rst=0 en=1 LSEL_N=1 LCLK=0 LDI=0" ())
       (6 "rst=0 en=1 LSEL_N=0 LCLK=0 LDI=0" (Deselect_qualified))
       (7 "rst=0 en=1 LSEL_N=0 LCLK=0 LDI=0" (Deselect_qualified))
       (8 "rst=0 en=1 LSEL_N=0 LCLK=0 LDI=0"
        (Selected Select_assert Deselect_qualified))
       (9 "rst=0 en=1 LSEL_N=0 LCLK=0 LDI=0" (Selected)))))
    |}]
;;

let%test_unit "qualification expected one cycle early is detected" =
  (* Stands in for a threshold of three. *)
  let t = create "negative: qualification after three cycles" in
  run t 10;
  ignore (drive_select t ~select:true ~hold:10 : int);
  let deselected = drive_select t ~select:false ~hold:10 in
  ignore
    (require_failure t "a three-cycle threshold" (fun () ->
       expect_output
         t
         Deselect_qualified
         ~cycle:(deselected + latency + threshold - 1)
         "three deselected cycles"
         true)
     : Sexp.t)
;;

let%test_unit "a wait for an event that never happens stops at its budget" =
  let t = create "negative: no selection" in
  let started = t.cycle in
  ignore
    (require_failure t "a selection with idle pins" (fun () ->
       ignore (wait_for ~budget:25 t Select_assert ~value:true "idle pins" : int))
     : Sexp.t);
  check
    t
    ~phase:Post_run
    "cycles run by the exhausted wait"
    [%sexp_of: int]
    [%equal: int]
    ~expected:(started + 25)
    t.cycle
;;
