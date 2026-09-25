(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "hardware_loader_diagnostics_tests.ml" *)
(* HL4a: the harness's key assertions detect the failures they exist for, and report
   enough to reproduce them.

   Each case sets up a controlled mismatch between what the host did and what the check
   expects, and requires the check to raise [Harness_failure]. None of them changes the
   loader or leaves a failing test in the suite. The first case prints a complete report,
   so its format is reviewed here.
*)

open! Core
open! Hardcaml_protemu
open! Hardware_loader_testbench

let require_failure t what f =
  match failure_of f with
  | Some failure -> failure
  | None -> fail t ~phase:Post_run ("the negative check must fail: " ^ what)
;;

let%expect_test "the retention check detects a response that the host committed" =
  (* The host supplies the final fall, which commits the response; the retention check
     that guards replay must then fail at the commit boundary. The transcript is limited
     to twelve events to show how truncation is reported.
  *)
  let t =
    create ~transcript_limit:12 "negative: committed response checked as retained"
  in
  set_status t { Status.halted_idle with image_valid = 1 };
  let request_deselected = send_frame t (encode ~tag:0x75 Run) in
  ignore (wait_ready t ~since:request_deselected : int);
  let read =
    read_response
      t
      ~expected:(Wire.Request.correlation ~tag:0x75 Run)
      ~decide:(fun _ -> Commit)
      ()
  in
  print_s
    (require_failure t "retention after a commit" (fun () ->
       expect_retained t ~deselected:read.deselected ~cycles:10));
  [%expect
    {|
    (test/host_link/hardware_loader_testbench.ml.Harness_failure
     (scenario "negative: committed response checked as retained") (cycle 990)
     (phase Pre_edge) (what "retained response keeps LRDY high for 10 cycles")
     (expected ((() true))) (actual ((((984 false)) false)))
     (transcript
      ((earlier_events_omitted 2)
       (events
        ((8 (Select true))
         (8 (Sent (bytes "a5 10 75 20 00 00 57") (extra_bits 0)))
         (8 (Status ((halted 1) (engines_idle 1) (image_valid 1))))
         (11 (Busy true)) (460 (Select false))
         (463 (Offer (request Run) (accepted true))) (464 (Ready true))
         (465 (Select true))
         (974 (Response_read (bytes "5a 10 75 20 00 00 00 e6") (outcome Commit)))
         (981 (Select false)) (984 (Ready false)) (984 (Busy false)))))))
    |}]
;;

let%test_unit "the offer check detects a one-cycle change in offer timing" =
  (* HL4b must not add a pipeline stage. An expectation one cycle late stands in for a
     loader that offers one cycle late.
  *)
  let t = create "negative: offer one cycle late" in
  let exchange = transact t ~tag:0x11 (Write_word { address = 1; word = 2 }) in
  ignore
    (require_failure t "a late offer" (fun () ->
       expect_offers
         t
         ~since:exchange.started
         "offer one cycle later than observed"
         [ { cycle = exchange.request_deselected + Latency.offer_after_deselect + 1
           ; request = Load_write { address = 1; data = 2 }
           ; accepted = true
           }
         ])
     : Sexp.t)
;;

let%test_unit "the quiet check detects a response that was not cancelled" =
  (* Without the disable, the retained STATUS response keeps LRDY high. *)
  let t = create "negative: response not discarded" in
  let request_deselected = send_frame t (encode ~tag:0x12 Status) in
  ignore (wait_ready t ~since:request_deselected : int);
  ignore
    (require_failure t "a retained response" (fun () -> expect_quiet t 10 "no response")
     : Sexp.t)
;;

let%test_unit "waits are bounded and time out with a report" =
  (* Robustness stub: the READBACK response never arrives. *)
  let t = create "negative: bounded wait" in
  t.stub.readback_completion <- Never;
  let request_deselected = send_frame t (encode ~tag:0x13 (Read_word { address = 0 })) in
  ignore
    (require_failure t "an unbounded wait" (fun () ->
       ignore (wait_ready ~budget:100 t ~since:request_deselected : int))
     : Sexp.t);
  expect_int
    t
    "the wait stopped at its budget"
    ~expected:(request_deselected + t.timing.deselect_gap + 100)
    t.cycle
;;

let%test_unit "the harness refuses host timing outside the P3.5 envelope" =
  match create ~timing:{ Timing.envelope with clock_low = 3 } "negative: 3-cycle low" with
  | (_ : t) -> raise_s [%message "a 3-cycle LCLK low was accepted"]
  | exception _ -> ()
;;
