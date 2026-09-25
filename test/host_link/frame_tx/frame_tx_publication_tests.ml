(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "frame_tx_publication_tests.ml" *)
(* HL4c: [Frame_tx] captures a published frame at the publication edge and retains it,
   unchanged, until a read of it is committed.

   Publications here are the dispatcher's: complete frames of each legal length,
   zero-padded, with the strobe for one cycle, never while a response is retained. Tests
   named "robustness" present what the dispatcher cannot; each says why.
*)

open! Core
open! Hardcaml_protemu
open! Frame_tx_testbench

let%test_unit "each legal response length is captured at the publication edge and read \
               out MSB first"
  =
  List.iter Frames.legal ~f:(fun (name, bytes) ->
    let t = create ("capture: " ^ name) in
    run t 3;
    let from = t.cycle in
    let published = publish t bytes in
    run t 20;
    (* Pending and ready rise at the publication edge, not in the publication cycle. *)
    expect_pending_cycles t ~from name (List.range (published + 1) t.cycle);
    expect_ready_cycles t ~from name (List.range (published + 1) t.cycle);
    expect_data_cycles t ~from name [];
    let { Read.released; _ } = commit_read t name bytes in
    run t 200;
    expect_quiet t ~from:(released + 1) (name ^ " after commit"))
;;

let%test_unit "a retained frame is unchanged by time and by other inputs until it is \
               committed"
  =
  let t = create "retention" in
  let bytes = Frames.status 0x5c in
  let published = publish t bytes in
  (* A long idle interval, unqualified selections, falls while no read is armed, and
     qualification presented without a selection change nothing.
  *)
  run t 5000;
  let _ : int = select ~qualified:false t in
  run t 8;
  List.iter (List.range 0 30) ~f:(fun _ ->
    run t 3;
    ignore (fall t : int));
  let _ : int = deselect t in
  run t 20;
  set t ~qualified:true;
  run t 50;
  set t ~qualified:false;
  List.iter (List.range 0 10) ~f:(fun _ ->
    run t 3;
    ignore (fall t : int));
  run t 10;
  expect_pending_cycles
    t
    ~from:(published + 1)
    "retained"
    (List.range (published + 1) t.cycle);
  expect_data_cycles t ~from:(published + 1) "retained" [];
  let _ : Read.t = commit_read t "retained STATUS" bytes in
  ()
;;

let%test_unit "the store and the shifted copy are independent: every read starts from \
               the stored frame"
  =
  let t = create "store versus shifter" in
  let bytes = Frames.info 0x19 in
  let _ : int = publish t bytes in
  run t 5;
  (* Each partial read shifts the copy; the store is unchanged, so each read restarts at
     byte zero with the same frame.
  *)
  List.iter [ 1; 8; 57; 167 ] ~f:(fun count ->
    run t 4;
    ignore (partial_read t (sprintf "INFO, %d bits" count) bytes ~count : Read.t));
  run t 4;
  let _ : Read.t = commit_read t "INFO after four partial reads" bytes in
  ()
;;

let%test_unit "consecutive publications and commits each deliver their own frame" =
  let t = create "consecutive" in
  List.iteri
    (Frames.legal @ List.rev Frames.legal)
    ~f:(fun index (name, bytes) ->
      let from = t.cycle in
      let published = publish t bytes in
      run t (index % 3);
      let { Read.released; _ } = commit_read t name bytes in
      expect_pending_cycles t ~from name (List.range (published + 1) (released + 1));
      run t 4)
;;

let%test_unit "robustness: frame and length inputs without the strobe are ignored" =
  (* The dispatcher drives zero on both when it does not publish. *)
  let t = create "unstrobed inputs" in
  let bytes = Frames.word 0x66 in
  List.iter (List.range 0 20) ~f:(fun _ ->
    stage ~strobe:false t (Frames.info 0xee);
    cycle t);
  expect_quiet t ~from:reset_cycles "unstrobed inputs while idle";
  let published = publish t bytes in
  List.iter (List.range 0 20) ~f:(fun _ ->
    stage ~strobe:false ~padding:0xff t (Frames.status 0xdd);
    cycle t);
  let _ : Read.t = commit_read t "word after unstrobed inputs" bytes in
  expect_pending_cycles
    t
    ~from:published
    "strobe"
    (List.range (published + 1) (t.cycle - 1))
;;

let%test_unit "robustness: out-of-contract lengths and nonzero padding" =
  (* The dispatcher publishes only 8, 10, 20, or 21 bytes, zero-padded. These show what
     the transmitter does with anything else; none is behavior of the composed loader.
  *)
  (* Nonzero padding is never presented: the output is low once the read is drained. *)
  let t = create "padding" in
  let bytes = Frames.empty 0x01 in
  stage ~padding:0xff t bytes;
  cycle t;
  run t 2;
  let _ : Read.t = commit_read t "empty with ff padding" bytes in
  (* Length 0 is drained when armed: nothing is presented, and the release commits without
     any fall.
  *)
  let t = create "length 0" in
  let published = t.cycle in
  stage ~length:0 ~padding:0xff t "";
  cycle t;
  run t 2;
  let asserted = select t in
  run t 6;
  let released = deselect t in
  run t 2;
  expect_data_cycles t ~from:published "length 0" [];
  expect_pending_cycles
    t
    ~from:published
    "length 0"
    (List.range (published + 1) (released + 1));
  ignore (asserted : int);
  (* Length 31 counts 248 falls. The 168 stored bits come first, then zeros; a release
     after 247 falls retains the response, and only the 248th fall lets a release commit.
  *)
  let t = create "length 31" in
  let bytes = Frames.info 0x31 in
  stage ~length:31 t bytes;
  cycle t;
  run t 2;
  let asserted = select t in
  run t 3;
  expect_read ~periods:[ 2 ] t "length 31, stored bits" bytes;
  expect_read
    ~periods:[ 2 ]
    ~count:79
    t
    "length 31, bits past the store"
    (String.make 10 '\x00');
  let released = deselect t in
  run t 1;
  expect_pending_cycles
    t
    ~from:asserted
    "length 31 before its last fall"
    (List.range asserted (released + 2));
  let _ : Read.t =
    commit_read ~periods:[ 2 ] t "length 31" (bytes ^ String.make 10 '\x00')
  in
  ()
;;
