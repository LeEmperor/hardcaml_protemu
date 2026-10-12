(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "backend_conformance_expect_tests.ml" *)

open! Core
open! Backend_conformance

let strip_times = List.map ~f:Edge_sample.without_time

let%expect_test "Cyclesim and two-state Evsim agree at the adapter sampling points" =
  let cyclesim = run_cyclesim () in
  let eventsim, clock = run_eventsim_with_clock_trace () in
  [%test_result: Edge_sample.t list] cyclesim ~expect:expected;
  [%test_result: Edge_sample.t list] (strip_times eventsim) ~expect:expected;
  [%test_result: Edge_sample.t list] (strip_times eventsim) ~expect:cyclesim;
  print_s [%message (eventsim : Edge_sample.t list) (clock : Clock_transition.t list)];
  [%expect
    {|
    ((eventsim
      (((before ((q 0) (ready 1) (accepted 1) (out_valid 0) (out_payload 0)))
        (after ((q 10) (ready 0) (accepted 0) (out_valid 1) (out_payload 6)))
        (completed_at (10)))
       ((before ((q 10) (ready 0) (accepted 0) (out_valid 1) (out_payload 6)))
        (after ((q 0) (ready 1) (accepted 0) (out_valid 0) (out_payload 0)))
        (completed_at (20)))
       ((before ((q 0) (ready 1) (accepted 0) (out_valid 0) (out_payload 0)))
        (after ((q 0) (ready 1) (accepted 0) (out_valid 0) (out_payload 0)))
        (completed_at (30)))
       ((before ((q 0) (ready 1) (accepted 1) (out_valid 0) (out_payload 0)))
        (after ((q 5) (ready 0) (accepted 0) (out_valid 1) (out_payload 9)))
        (completed_at (40)))
       ((before ((q 5) (ready 0) (accepted 0) (out_valid 1) (out_payload 9)))
        (after ((q 5) (ready 0) (accepted 0) (out_valid 1) (out_payload 9)))
        (completed_at (50)))))
     (clock
      (((time 5) (level 1)) ((time 10) (level 0)) ((time 15) (level 1))
       ((time 20) (level 0)) ((time 25) (level 1)) ((time 30) (level 0))
       ((time 35) (level 1)) ((time 40) (level 0)) ((time 45) (level 1))
       ((time 50) (level 0)))))
    |}]
;;

let%test_unit "both adapters terminate a non-completing testbench at the step budget" =
  [%test_result: bool] (cyclesim_times_out ()) ~expect:true;
  [%test_result: bool] (eventsim_times_out ()) ~expect:true
;;
