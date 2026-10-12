(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "serial_phy_tests.ml" *)
(* HL4c: [Serial_phy]'s public timing, from pin changes to synchronized levels, events,
   and deselect qualification.

   Each test drives pins in known cycles and checks the exact set of cycles in which an
   output is high over the whole window. An exact set also checks one-cycle event duration
   and the absence of repeats. Expected cycles are written from the contract in
   docs/host_link_hl4b1_record.md: a pin change in cycle n is visible in cycle n+2, and a
   cycle is qualified after four synchronized deselected, enabled, unreset cycles.
*)

open! Core
open! Hardcaml_protemu
open! Serial_phy_testbench

let%test_unit "each pin reaches its synchronized level two cycles after it changes" =
  let t = create "synchronizer latency" in
  let start = t.cycle in
  let selected = drive_select t ~select:true ~hold:6 in
  let data_high = t.cycle in
  set t ~data:true;
  run t 6;
  let deselected = drive_select t ~select:false ~hold:6 in
  let data_low = t.cycle in
  set t ~data:false;
  run t 6;
  (* One-cycle pin pulses pass unfiltered, two cycles later. *)
  let pulse = t.cycle in
  set t ~select:true ~data:true;
  run t 1;
  set t ~select:false ~data:false;
  run t 10;
  let until = t.cycle in
  expect_high_cycles
    t
    Selected
    ~from:start
    ~until
    "LSEL_N low in [selected, deselected) and in the pulse cycle"
    (List.range (selected + latency) (deselected + latency) @ [ pulse + latency ]);
  expect_high_cycles
    t
    Data
    ~from:start
    ~until
    "LDI high in [data_high, data_low) and in the pulse cycle"
    (List.range (data_high + latency) (data_low + latency) @ [ pulse + latency ])
;;

let%test_unit "each pin change is one event in the cycle its level is first visible, and \
               a stable pin repeats nothing"
  =
  let t = create "edge events" in
  let start = t.cycle in
  let selected = drive_select t ~select:true ~hold:50 in
  let rise = t.cycle in
  set t ~clock:true;
  run t 50;
  let fall = t.cycle in
  set t ~clock:false;
  run t 50;
  let deselected = drive_select t ~select:false ~hold:50 in
  (* One-cycle pulses give a rise and a fall on consecutive cycles. *)
  let clock_pulse = t.cycle in
  set t ~clock:true;
  run t 1;
  set t ~clock:false;
  run t 10;
  let select_pulse = t.cycle in
  set t ~select:true;
  run t 1;
  set t ~select:false;
  run t 10;
  let until = t.cycle in
  let expect output what expected =
    expect_high_cycles t output ~from:start ~until what expected
  in
  expect
    Select_assert
    "LSEL_N falls at [selected] and [select_pulse]"
    [ selected + latency; select_pulse + latency ];
  expect
    Select_release
    "LSEL_N rises at [deselected] and after the pulse"
    [ deselected + latency; select_pulse + latency + 1 ];
  expect
    Clock_rise
    "LCLK rises at [rise] and [clock_pulse]"
    [ rise + latency; clock_pulse + latency ];
  expect
    Clock_fall
    "LCLK falls at [fall] and after the pulse"
    [ fall + latency; clock_pulse + latency + 1 ]
;;

let%test_unit "deselect qualification: below, at, and above four cycles, saturating over \
               a long interval and clearing at a selection"
  =
  let t = create "qualification threshold" in
  (* Out of reset from cycle [reset_cycles], deselected throughout. A three-bit count that
     did not saturate would drop qualification within eight cycles.
  *)
  run t 5000;
  expect_high_cycles
    t
    Deselect_qualified
    ~from:0
    ~until:t.cycle
    "after reset, deselected for 5000 cycles"
    (List.range (reset_cycles + threshold) t.cycle);
  (* The selection's own assert cycle is still qualified; the count clears at its edge. *)
  let selected = drive_select t ~select:true ~hold:20 in
  expect_output t Select_assert ~cycle:(selected + latency) "selection seen" true;
  expect_high_cycles
    t
    Deselect_qualified
    ~from:selected
    ~until:t.cycle
    "selected from [selected]"
    (List.range selected (selected + latency + 1));
  (* After release the count restarts from zero. *)
  let deselected = drive_select t ~select:false ~hold:5000 in
  let release = deselected + latency in
  expect_output t Select_release ~cycle:release "release seen" true;
  expect_output
    t
    Deselect_qualified
    ~cycle:(release + threshold - 1)
    "below threshold"
    false;
  expect_output t Deselect_qualified ~cycle:(release + threshold) "at threshold" true;
  expect_output
    t
    Deselect_qualified
    ~cycle:(release + threshold + 1)
    "above threshold"
    true;
  expect_high_cycles
    t
    Deselect_qualified
    ~from:deselected
    ~until:t.cycle
    "deselected for 5000 cycles after a selection"
    (List.range (release + threshold) t.cycle)
;;

let%test_unit "a selection is qualified exactly when LSEL_N was high for at least four \
               cycles before it"
  =
  (* LSEL_N high for [gap] cycles, then low again; the second assertion is seen [latency]
     cycles after the pin falls. This is the PHY half of the loader's response-arming
     boundary (HL4a: a 3-cycle gap is not armed, a 4-cycle gap is).
  *)
  List.iter
    [ 1, false; 2, false; 3, false; 4, true; 5, true; 8, true; 100, true ]
    ~f:(fun (gap, qualified) ->
      let t = create (sprintf "deselected gap of %d cycles" gap) in
      run t 10;
      let first = drive_select t ~select:true ~hold:10 in
      let deselected = drive_select t ~select:false ~hold:gap in
      let reselected = drive_select t ~select:true ~hold:10 in
      let until = t.cycle in
      expect_high_cycles
        t
        Select_assert
        ~from:first
        ~until
        "both selections are seen"
        [ first + latency; reselected + latency ];
      expect_high_cycles
        t
        Select_release
        ~from:first
        ~until
        "the gap is seen"
        [ deselected + latency ];
      expect_output
        t
        Deselect_qualified
        ~cycle:(reselected + latency)
        (sprintf "second selection after a %d-cycle gap" gap)
        qualified)
;;

let%test_unit "short deselected gaps do not accumulate toward qualification" =
  (* Three-cycle gaps separated by one-cycle selections: each selection clears the count. *)
  let t = create "repeated short gaps" in
  run t 10;
  let start = drive_select t ~select:true ~hold:10 in
  for _ = 1 to 5 do
    ignore (drive_select t ~select:false ~hold:3 : int);
    ignore (drive_select t ~select:true ~hold:1 : int)
  done;
  run t 10;
  expect_high_cycles
    t
    Deselect_qualified
    ~from:start
    ~until:t.cycle
    "only before the first selection's edge"
    (List.range start (start + latency + 1))
;;

let%test_unit "coincident select, clock, and data changes are reported in the same \
               cycle, each on its own output"
  =
  let t = create "coincident transitions" in
  run t 10;
  let start = t.cycle in
  let step ?select ?clock ?data () =
    let driven = t.cycle in
    set t ?select ?clock ?data;
    run t 20;
    driven
  in
  let together = step ~select:true ~clock:true ~data:true () in
  let apart = step ~select:false ~clock:false ~data:false () in
  let reselected = step ~select:true () in
  let release_rise = step ~select:false ~clock:true () in
  let assert_fall = step ~select:true ~clock:false () in
  let until = t.cycle in
  let expect output what expected =
    expect_high_cycles t output ~from:start ~until what expected
  in
  expect
    Select_assert
    "selections"
    [ together + latency; reselected + latency; assert_fall + latency ];
  expect Select_release "releases" [ apart + latency; release_rise + latency ];
  expect Clock_rise "rises" [ together + latency; release_rise + latency ];
  expect Clock_fall "falls" [ apart + latency; assert_fall + latency ];
  expect Data "data" (List.range (together + latency) (apart + latency));
  expect
    Selected
    "selected level"
    (List.range (together + latency) (apart + latency)
     @ List.range (reselected + latency) (release_rise + latency)
     @ List.range (assert_fall + latency) until)
;;

let%test_unit "reset clears the synchronizers, edge history, and qualification at its \
               edge"
  =
  (* A. Reset while an assertion is visible. Outputs are registered, so the event still
        shows in the reset cycle. Reset then clears the level and the history, so no
        release is reported. A pin still low afterwards is a new selection two cycles
        after reset ends.
  *)
  let t = create "reset while selected" in
  run t 10;
  let selected = drive_select t ~select:true ~hold:latency in
  let reset_from = t.cycle in
  set t ~reset:true;
  run t 2;
  let released = t.cycle in
  set t ~reset:false;
  run t 16;
  let until = t.cycle in
  let expect output what expected =
    expect_high_cycles t output ~from:selected ~until what expected
  in
  expect Select_assert "before and after reset" [ reset_from; released + latency ];
  expect Select_release "reset is not a release" [];
  expect Selected "cleared by reset" (reset_from :: List.range (released + latency) until);
  expect
    Deselect_qualified
    "qualified until the reset edge"
    [ selected; selected + 1; reset_from ];
  (* B. A one-cycle pulse on every pin, with reset in the next cycle, is discarded from
     the first stage. The control run without reset reports it.
  *)
  let pulse ~with_reset =
    let t =
      create (if with_reset then "reset discards a pulse in flight" else "pulse control")
    in
    run t 10;
    let pulse = t.cycle in
    set t ~select:true ~clock:true ~data:true;
    run t 1;
    set t ~select:false ~clock:false ~data:false ~reset:with_reset;
    run t 1;
    set t ~reset:false;
    run t 20;
    t, pulse
  in
  let t, p = pulse ~with_reset:false in
  let expect output what expected =
    expect_high_cycles t output ~from:p ~until:t.cycle what expected
  in
  expect Selected "control" [ p + latency ];
  expect Data "control" [ p + latency ];
  expect Select_assert "control" [ p + latency ];
  expect Select_release "control" [ p + latency + 1 ];
  expect Clock_rise "control" [ p + latency ];
  expect Clock_fall "control" [ p + latency + 1 ];
  (* Selected only in cycle p+2; the count restarts from the release in p+3. *)
  expect
    Deselect_qualified
    "control"
    (List.range p (p + latency + 1) @ List.range (p + latency + 1 + threshold) t.cycle);
  let t, p = pulse ~with_reset:true in
  let expect output what expected =
    expect_high_cycles t output ~from:p ~until:t.cycle what expected
  in
  List.iter
    [ Output.Selected; Data; Select_assert; Select_release; Clock_rise; Clock_fall ]
    ~f:(fun output -> expect output "reset in cycle p+1" []);
  (* The count restarts from the first cycle out of reset, p+2. *)
  expect
    Deselect_qualified
    "reset in cycle p+1"
    ([ p; p + 1 ] @ List.range (p + 2 + threshold) t.cycle)
;;

let%test_unit "disable clears only the qualification; synchronizers and events keep \
               running"
  =
  (* A. Disabled for three cycles while deselected, with LCLK and LDI changing in the
        first. Qualification is still visible in the first disabled cycle (registered) and
        returns four enabled cycles after enable does.
  *)
  let t = create "disable while deselected" in
  run t 10;
  let disabled = t.cycle in
  set t ~enable:false ~clock:true ~data:true;
  run t 3;
  let enabled = t.cycle in
  set t ~enable:true;
  run t 2;
  let fall = t.cycle in
  set t ~clock:false;
  run t 15;
  let until = t.cycle in
  let expect output what expected =
    expect_high_cycles t output ~from:disabled ~until what expected
  in
  expect
    Deselect_qualified
    "disabled in [disabled, enabled)"
    (disabled :: List.range (enabled + threshold) until);
  expect Clock_rise "during disable" [ disabled + latency ];
  expect Clock_fall "after disable" [ fall + latency ];
  expect Data "unaffected by disable" (List.range (disabled + latency) until);
  (* B. A selection driven just before disable is still reported while disabled (reset
     would discard it), and the count stays clear while selected after enable returns.
  *)
  let t = create "disable keeps synchronizers running" in
  run t 10;
  let selected = drive_select t ~select:true ~hold:1 in
  set t ~enable:false;
  run t 4;
  set t ~enable:true;
  run t 10;
  let deselected = drive_select t ~select:false ~hold:12 in
  let until = t.cycle in
  let expect output what expected =
    expect_high_cycles t output ~from:selected ~until what expected
  in
  expect Select_assert "while disabled" [ selected + latency ];
  expect Select_release "after enable" [ deselected + latency ];
  expect
    Selected
    "unaffected by disable"
    (List.range (selected + latency) (deselected + latency));
  expect
    Deselect_qualified
    "cleared by the first disabled edge"
    ([ selected; selected + 1 ] @ List.range (deselected + latency + threshold) until);
  (* C. Disable in the cycle whose edge would complete the count: disable wins over the
     increment, and the count restarts after it.
  *)
  let t = create "disable at the threshold edge" in
  run t 10;
  ignore (drive_select t ~select:true ~hold:10 : int);
  let deselected = drive_select t ~select:false ~hold:(latency + threshold - 1) in
  let disabled = t.cycle in
  set t ~enable:false;
  run t 1;
  set t ~enable:true;
  run t 10;
  expect_output
    t
    Deselect_qualified
    ~cycle:(deselected + latency + threshold)
    "the edge that would have qualified was disabled"
    false;
  expect_high_cycles
    t
    Deselect_qualified
    ~from:deselected
    ~until:t.cycle
    "disabled in one cycle"
    (List.range (disabled + 1 + threshold) t.cycle)
;;
