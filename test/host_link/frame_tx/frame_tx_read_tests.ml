(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "frame_tx_read_tests.ml" *)
(* HL4c: [Frame_tx]'s response reads: arming, shifting, replay, and commit.

   A read is armed only by a select-assert event that finds a response already pending and
   is qualified. Each fall event advances exactly one bit. A release consumes the response
   only after the final fall; any earlier release, including one with the final bit
   presented, leaves it retained, and the next read restarts at byte zero. Tests named
   "robustness" present what the PHY or the dispatcher cannot; each says why.
*)

open! Core
open! Hardcaml_protemu
open! Frame_tx_testbench

(* Arming. *)

let%test_unit "an unqualified selection is not armed, and cannot shift or consume the \
               response"
  =
  let t = create "unqualified" in
  let bytes = Frames.word 0x24 in
  let published = publish t bytes in
  run t 3;
  let from = t.cycle in
  let _ : int = select ~qualified:false t in
  run t 3;
  List.iter (List.range 0 80) ~f:(fun _ ->
    run t 3;
    ignore (fall t : int));
  run t 4;
  let _ : int = deselect t in
  run t 6;
  expect_data_cycles t ~from "unqualified selection" [];
  expect_pending_cycles
    t
    ~from:published
    "unqualified selection"
    (List.range (published + 1) t.cycle);
  let _ : Read.t = commit_read t "qualified read after it" bytes in
  ()
;;

let%test_unit "a publication in the select-assert cycle does not arm that selection; one \
               a cycle earlier does"
  =
  (* Pending in the assert cycle itself is what arms; nothing requires the response to
     have been ready for the qualifying interval. The composed loader can present the
     coincidence: an early selection whose assert event falls in the publication cycle.
  *)
  let t = create "publication with the assert" in
  let bytes = Frames.empty 0x77 in
  run t 4;
  let asserted = t.cycle in
  stage t bytes;
  set t ~qualified:true;
  pulse t ~select_assert:true;
  cycle t;
  set t ~qualified:false;
  run t 3;
  List.iter (List.range 0 70) ~f:(fun _ ->
    run t 3;
    ignore (fall t : int));
  run t 4;
  let released = deselect t in
  run t 10;
  expect_data_cycles t ~from:asserted "coincident publication" [];
  expect_pending_cycles
    t
    ~from:asserted
    "coincident publication"
    (List.range (asserted + 1) t.cycle);
  ignore (released : int);
  let _ : Read.t = commit_read t "the next qualified read" bytes in
  (* The boundary case: published one cycle before a qualified assert. *)
  let t = create "publication one cycle before the assert" in
  let bytes = Frames.info 0x78 in
  run t 4;
  let published = publish t bytes in
  let { Read.asserted; _ } = commit_read ~lead:1 t "published one cycle earlier" bytes in
  check
    t
    ~phase:Post_run
    "assert cycle"
    [%sexp_of: int]
    [%equal: int]
    ~expected:(published + 1)
    asserted
;;

let%test_unit "an early selection before the publication cannot shift or consume it" =
  let t = create "early selection" in
  let bytes = Frames.status 0x5e in
  run t 4;
  let from = t.cycle in
  let _ : int = select t in
  run t 5;
  List.iter (List.range 0 12) ~f:(fun _ ->
    run t 3;
    ignore (fall t : int));
  let published = publish t bytes in
  List.iter (List.range 0 200) ~f:(fun _ ->
    run t 3;
    ignore (fall t : int));
  run t 4;
  let _ : int = deselect t in
  run t 8;
  expect_data_cycles t ~from "early selection" [];
  expect_pending_cycles t ~from "early selection" (List.range (published + 1) t.cycle);
  let _ : Read.t = commit_read t "the next qualified read" bytes in
  ()
;;

(* Shifting. *)

let%test_unit "each fall advances exactly one bit, at its edge, at any spacing" =
  List.iter
    [ "2-cycle falls", [ 2 ]
    ; "8-cycle falls", [ 8 ]
    ; "irregular falls", [ 2; 5; 3; 17; 2; 9; 4 ]
    ; "slow host", [ 22 ]
    ]
    ~f:(fun (name, periods) ->
      let t = create name in
      let bytes = Frames.info 0x3a in
      let _ : int = publish t bytes in
      run t 3;
      let _ : Read.t = commit_read ~periods t name bytes in
      ())
;;

let%test_unit "falls outside an armed read are ignored and the read still starts at bit \
               zero"
  =
  let t = create "falls outside a read" in
  let bytes = Frames.word 0x5b in
  let _ : int = publish t bytes in
  (* Deselected clocking, as a host might do between frames. *)
  List.iter (List.range 0 50) ~f:(fun _ ->
    run t 2;
    ignore (fall t : int));
  run t 4;
  let _ : Read.t = commit_read t "after deselected falls" bytes in
  ()
;;

let%test_unit "a selected pause holds the presented bit indefinitely" =
  let t = create "pauses" in
  let bytes = Frames.info 0x12 in
  let _ : int = publish t bytes in
  run t 3;
  (* 10 000 cycles before the first fall, then a pause inside a byte and one on a byte
     boundary.
  *)
  let periods = [ 10_000; 8; 8; 5_000; 8; 8; 8; 8; 8; 8; 8; 8; 7_000; 8 ] in
  let _ : Read.t = commit_read ~periods t "paused read" bytes in
  ()
;;

let%test_unit "the final bit, the drained boundary, and the output after it" =
  let t = create "drained" in
  let bytes = Frames.empty 0x2d in
  let _ : int = publish t bytes in
  run t 3;
  let _ : int = select t in
  run t 3;
  expect_read ~count:63 t "empty, bits 0 to 62" bytes;
  (* The last bit is presented until the final fall's edge, then the output is low. *)
  let last = List.last_exn (wire_bits bytes) in
  let from = t.cycle in
  run t 5;
  let final_fall = fall t in
  run t 5;
  expect_data_cycles
    t
    ~from
    "last bit, then drained"
    (if last then List.range from (final_fall + 1) else []);
  (* Further falls change nothing; the release still commits. *)
  List.iter (List.range 0 20) ~f:(fun _ ->
    run t 3;
    ignore (fall t : int));
  run t 4;
  let released = deselect t in
  run t 20;
  expect_data_cycles t ~from:(final_fall + 1) "after the final fall" [];
  expect_pending_cycles
    t
    ~from:(final_fall + 1)
    "commit"
    (List.range (final_fall + 1) (released + 1))
;;

(* Replay and commit. *)

let%test_unit "a release before the final fall retains the response; the next read \
               restarts at byte zero"
  =
  List.iter
    [ "empty", Frames.empty 0x10; "INFO", Frames.info 0x11 ]
    ~f:(fun (name, bytes) ->
      let total = 8 * String.length bytes in
      (* No bit, one bit, part of a byte, a byte, and every bit but the final fall. *)
      List.iter
        [ 0; 1; 5; 8; total - 1 ]
        ~f:(fun count ->
          let t = create (sprintf "replay after %d of %d bits of %s" count total name) in
          let _ : int = publish t bytes in
          run t 3;
          let { Read.released; _ } =
            partial_read t (sprintf "%s, %d bits" name count) bytes ~count
          in
          run t 200;
          expect_pending_cycles
            t
            ~from:released
            "retained after the release"
            (List.range released t.cycle);
          let _ : Read.t = commit_read t (name ^ " replayed") bytes in
          ()))
;;

let%test_unit "the final bit presented without the final fall is a replay, whatever the \
               host saw"
  =
  (* The host validated the whole frame with LCLK high and deselected without the final
     fall: P3.5's replay sequence. The last bit stays presented until the release.
  *)
  let t = create "final bit without the final fall" in
  let bytes = Frames.status 0x6f in
  let total = 8 * String.length bytes in
  let _ : int = publish t bytes in
  run t 3;
  let _ : int = select t in
  run t 3;
  expect_read ~count:(total - 1) t "STATUS, all but the final fall" bytes;
  let last = List.last_exn (wire_bits bytes) in
  let from = t.cycle in
  run t 12;
  let released = deselect t in
  run t 100;
  expect_data_cycles
    t
    ~from
    "last bit held until the release"
    (if last then List.range from (released + 1) else []);
  expect_pending_cycles t ~from "retained" (List.range from t.cycle);
  let _ : Read.t = commit_read t "STATUS replayed" bytes in
  ()
;;

let%test_unit "a committed response is consumed exactly once, with no stale readiness or \
               data"
  =
  let t = create "commit once" in
  let bytes = Frames.word 0x90 in
  let _ : int = publish t bytes in
  run t 3;
  let { Read.released; _ } = commit_read t "word" bytes in
  (* Later qualified selections find nothing pending: nothing is presented and nothing
     reappears.
  *)
  List.iter (List.range 0 3) ~f:(fun _ ->
    run t 6;
    let _ : int = select t in
    List.iter (List.range 0 90) ~f:(fun _ ->
      run t 3;
      ignore (fall t : int));
    run t 3;
    ignore (deselect t : int));
  run t 1000;
  expect_quiet t ~from:(released + 1) "after the commit";
  (* A new publication is read in full. *)
  let bytes = Frames.info 0x91 in
  let _ : int = publish t bytes in
  run t 3;
  let _ : Read.t = commit_read t "next response" bytes in
  ()
;;

let%test_unit "repeated replays leave the retained frame unchanged" =
  let t = create "repeated replays" in
  let bytes = Frames.info 0x4e in
  let total = 8 * String.length bytes in
  let _ : int = publish t bytes in
  List.iter
    [ 3; total - 1; 0; 100; 17; total - 1; 64 ]
    ~f:(fun count ->
      run t 5;
      ignore (partial_read t (sprintf "replay of %d bits" count) bytes ~count : Read.t));
  run t 5;
  let _ : Read.t = commit_read t "INFO after seven replays" bytes in
  ()
;;

let%test_unit "robustness: frame content is not interpreted; a first bit of one is \
               presented from the cycle after the assert"
  =
  (* Every legal response starts with magic 5a, whose first bit is zero. This pattern
     frame, which the dispatcher never builds, shows the first bit's timing directly and
     exercises every bit position.
  *)
  let t = create "pattern frame" in
  let bytes =
    String.of_char_list
      (List.map
         [ 0x80
         ; 0x01
         ; 0xff
         ; 0x00
         ; 0xa5
         ; 0x5a
         ; 0x40
         ; 0x02
         ; 0xc3
         ; 0x3c
         ; 0x81
         ; 0x7e
         ; 0x20
         ; 0x04
         ; 0xf0
         ; 0x0f
         ; 0x10
         ; 0x08
         ; 0xaa
         ; 0x55
         ; 0xfe
         ]
         ~f:Char.of_int_exn)
  in
  let _ : int = publish t bytes in
  run t 3;
  let _ : Read.t = commit_read ~periods:[ 2; 3 ] t "pattern" bytes in
  ()
;;
