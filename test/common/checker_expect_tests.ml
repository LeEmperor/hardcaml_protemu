open! Core

let%expect_test "the checker keeps unavailable, unspecified and defined apart" =
  let show ~required ~model ~dut =
    print_s
      [%sexp
        (Observation.first_difference ~required ~model ~dut
         : Observation.Difference.t option)]
  in
  (* A defined zero is an ordinary value: agreeing on it is agreement. *)
  show ~required:[ "ready" ] ~model:[ "ready", Defined 0 ] ~dut:[ "ready", Defined 0 ];
  [%expect {| () |}];
  show ~required:[ "ready" ] ~model:[ "ready", Defined 0 ] ~dut:[ "ready", Defined 1 ];
  [%expect
    {|
    (((observation ready) (reason Value) (expected (Defined 0))
      (actual (Defined 1))))
    |}];
  (* Where the contract says nothing, the two sides may differ. *)
  show ~required:[] ~model:[ "level", Unspecified ] ~dut:[ "level", Unspecified ];
  [%expect {| () |}];
  (* But they may not differ about whether the contract says anything. *)
  show ~required:[] ~model:[ "level", Unspecified ] ~dut:[ "level", Defined 1 ];
  [%expect
    {|
    (((observation level) (reason Validity) (expected Unspecified)
      (actual (Defined 1))))
    |}];
  (* An adapter that cannot expose something not under test: skipped, and only that one. *)
  show
    ~required:[ "ready" ]
    ~model:[ "reason", Defined 3; "ready", Defined 1 ]
    ~dut:[ "reason", Unavailable; "ready", Defined 1 ];
  [%expect {| () |}];
  (* The same hole in something the test declared it needs: an error, not a skip. *)
  show
    ~required:[ "reason" ]
    ~model:[ "reason", Defined 3 ]
    ~dut:[ "reason", Unavailable ];
  [%expect
    {|
    (((observation reason) (reason Required_unavailable) (expected (Defined 3))
      (actual Unavailable)))
    |}];
  show
    ~required:[ "reason" ]
    ~model:[ "reason", Unspecified ]
    ~dut:[ "reason", Defined 3 ];
  [%expect
    {|
    (((observation reason) (reason Required_unspecified) (expected Unspecified)
      (actual (Defined 3))))
    |}];
  (* A side that quietly stopped publishing an observation shrinks the comparison. *)
  show ~required:[] ~model:[ "a", Defined 1; "b", Defined 2 ] ~dut:[ "a", Defined 1 ];
  [%expect
    {|
    (((observation b) (reason Undeclared) (expected (Defined 2))
      (actual Unavailable)))
    |}]
;;
