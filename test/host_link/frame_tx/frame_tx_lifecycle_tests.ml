(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "frame_tx_lifecycle_tests.ml" *)
(* HL4c: [Frame_tx]'s reset and disable, and events that coincide at its boundary.

   Reset clears every register at its edge; the outputs still show the old state in the
   reset cycle itself. Disable gates the outputs low in the disabled cycle and clears
   pending, the read, and the bit count at its edge; [pending_o] still shows the old state
   in that cycle, which is how eligibility differs from [serial_ready_o]. Coincident
   events resolve per register in the transmitter's statement order: publication, arming,
   shift, release, disable. Tests named "robustness" drive coincidences the composed
   loader cannot present; each says why.
*)

open! Core
open! Hardcaml_protemu
open! Frame_tx_testbench

(* Where in a response's life a one-cycle reset or disable lands. *)
module Point = struct
  type t =
    | Pending (* published, no read armed *)
    | Armed (* a read armed, no fall yet *)
    | Partial (* a read armed, 13 bits shifted *)
    | Drained (* every bit shifted, not yet released *)
  [@@deriving sexp_of, enumerate]
end

module Cancel = struct
  type t =
    | Reset
    | Disable
  [@@deriving sexp_of, enumerate]
end

(* Publish INFO, bring it to [point], and leave the read (if any) selected. *)
let reach t (point : Point.t) bytes =
  let _ : int = publish t bytes in
  run t 3;
  match point with
  | Pending -> run t 4
  | Armed ->
    ignore (select t : int);
    run t 4
  | Partial ->
    ignore (select t : int);
    run t 3;
    ignore (read_bits t 13 : bool list);
    run t 2
  | Drained ->
    ignore (select t : int);
    run t 3;
    ignore (read_bits ~periods:[ 2 ] t (8 * String.length bytes) : bool list);
    run t 2
;;

(* Apply [cancel] for exactly the next cycle and return that cycle. *)
let cancel t (cancel : Cancel.t) =
  let at = t.cycle in
  (match cancel with
   | Reset -> set t ~reset:true
   | Disable -> set t ~enable:false);
  cycle t;
  set t ~reset:false ~enable:true;
  at
;;

let%test_unit "reset and disable at each point discard the response; a fresh one follows" =
  List.iter Cancel.all ~f:(fun how ->
    List.iter Point.all ~f:(fun point ->
      let name = Sexp.to_string [%sexp (how : Cancel.t), (point : Point.t)] in
      let t = create name in
      let bytes = Frames.info 0x44 in
      reach t point bytes;
      let before = observed t (t.cycle - 1) in
      let at = cancel t how in
      (* In the cancelling cycle: reset leaves the outputs as they were; disable gates the
         pins but [pending_o] still shows the retained response.
      *)
      expect_sample
        t
        ~cycle:at
        name
        (match how with
         | Reset -> before
         | Disable -> { data = false; ready = false; pending = true });
      (* The host carries on: falls, a release, and a new qualified selection with more
         falls. None of it finds a response.
      *)
      List.iter (List.range 0 20) ~f:(fun _ ->
        run t 3;
        ignore (fall t : int));
      run t 4;
      ignore (deselect t : int);
      run t 6;
      ignore (select t : int);
      List.iter (List.range 0 20) ~f:(fun _ ->
        run t 3;
        ignore (fall t : int));
      ignore (deselect t : int);
      run t 100;
      expect_quiet t ~from:(at + 1) (name ^ " after cancellation");
      let fresh = Frames.word 0x45 in
      let _ : int = publish t fresh in
      run t 3;
      let _ : Read.t = commit_read t (name ^ ", fresh response") fresh in
      ()))
;;

let%test_unit "a publication in a reset or disabled cycle leaves nothing to read" =
  (* The dispatcher publishes whatever it decided in a reset or disabled cycle; the
     transmitter must not retain it. Reset clears the store as well; disable leaves it
     written but not pending, which nothing can observe.
  *)
  List.iter Cancel.all ~f:(fun how ->
    let name = Sexp.to_string [%sexp "publication with", (how : Cancel.t)] in
    let t = create name in
    run t 3;
    let at = t.cycle in
    stage t (Frames.status 0x71);
    ignore (cancel t how : int);
    run t 4;
    ignore (select t : int);
    List.iter (List.range 0 30) ~f:(fun _ ->
      run t 3;
      ignore (fall t : int));
    ignore (deselect t : int);
    run t 50;
    expect_quiet t ~from:at name;
    let fresh = Frames.empty 0x72 in
    let _ : int = publish t fresh in
    run t 3;
    let _ : Read.t = commit_read t (name ^ ", fresh response") fresh in
    ())
;;

let%test_unit "disable coinciding with an assert, a fall, or a release still discards \
               the response"
  =
  let coincide name bytes ~prepare ~events =
    let t = create name in
    let _ : int = publish t bytes in
    run t 3;
    prepare t;
    let at = t.cycle in
    events t;
    ignore (cancel t Disable : int);
    run t 4;
    ignore (select t : int);
    List.iter (List.range 0 10) ~f:(fun _ ->
      run t 3;
      ignore (fall t : int));
    ignore (deselect t : int);
    run t 20;
    expect_sample t ~cycle:at name { data = false; ready = false; pending = true };
    expect_quiet t ~from:(at + 1) name
  in
  let bytes = Frames.word 0x5f in
  let total = 8 * String.length bytes in
  (* Arming needs enable; the selection is not armed and the response is gone. *)
  coincide
    "disable with a qualified assert"
    bytes
    ~prepare:(fun _ -> ())
    ~events:(fun t ->
      set t ~qualified:true;
      pulse t ~select_assert:true);
  coincide
    "disable with a fall"
    bytes
    ~prepare:(fun t ->
      ignore (select t : int);
      run t 3;
      ignore (read_bits t 6 : bool list))
    ~events:(fun t -> pulse t ~clock_fall:true);
  coincide
    "disable with a release before the final fall"
    bytes
    ~prepare:(fun t ->
      ignore (select t : int);
      run t 3;
      ignore (read_bits t 6 : bool list))
    ~events:(fun t -> pulse t ~select_release:true);
  coincide
    "disable with a committing release"
    bytes
    ~prepare:(fun t ->
      ignore (select t : int);
      run t 3;
      ignore (read_bits t total : bool list);
      run t 4)
    ~events:(fun t -> pulse t ~select_release:true)
;;

let%test_unit "a release coinciding with a fall after the read is drained commits" =
  (* A host that clocks past the frame's end: the extra fall changes nothing. *)
  let t = create "drained fall with release" in
  let bytes = Frames.empty 0x2e in
  let _ : int = publish t bytes in
  run t 3;
  let asserted = select t in
  run t 3;
  expect_read t "empty" bytes;
  run t 3;
  let released = t.cycle in
  pulse t ~clock_fall:true ~select_release:true;
  cycle t;
  run t 50;
  expect_pending_cycles t ~from:asserted "commit" (List.range asserted (released + 1));
  expect_quiet t ~from:(released + 1) "after the commit"
;;

let%test_unit "robustness: a final fall coinciding with the release does not commit" =
  (* Outside the P3.5 envelope, which puts at least four cycles between the last fall and
     the deselection. The release reads the count before the fall's edge, so the read is
     not yet drained: the response is retained and the next read replays it.
  *)
  let t = create "final fall with release" in
  let bytes = Frames.word 0x3d in
  let total = 8 * String.length bytes in
  let _ : int = publish t bytes in
  run t 3;
  let _ : int = select t in
  run t 3;
  expect_read ~count:(total - 1) t "word, all but the final fall" bytes;
  run t 7;
  let released = t.cycle in
  pulse t ~clock_fall:true ~select_release:true;
  cycle t;
  run t 100;
  expect_pending_cycles t ~from:released "retained" (List.range released t.cycle);
  expect_data_cycles t ~from:(released + 1) "after the release" [];
  let _ : Read.t = commit_read t "word replayed" bytes in
  ()
;;

let%test_unit "robustness: a publication while a response is retained" =
  (* The dispatcher never publishes while a response is retained: requests stay ineligible
     until commit. These pin the per-register priorities anyway. Arming copies the store
     into the shifter but not the length, so a publication at the start of a read, or
     during one, changes where that read drains.
  *)
  let first = Frames.info 0x01 in
  let second = Frames.word 0x02 in
  let second_bits = 8 * String.length second in
  (* With a qualified assert: the read shifts the old frame but drains at the new length;
     its release then commits, consuming the new publication unread.
  *)
  let t = create "publication with an arming assert" in
  let _ : int = publish t first in
  run t 3;
  stage t second;
  set t ~qualified:true;
  pulse t ~select_assert:true;
  cycle t;
  set t ~qualified:false;
  run t 3;
  expect_read ~count:second_bits t "the old frame, to the new length" first;
  let drained_from = t.cycle in
  List.iter (List.range 0 20) ~f:(fun _ ->
    run t 3;
    ignore (fall t : int));
  run t 4;
  let released = deselect t in
  run t 20;
  expect_data_cycles t ~from:drained_from "drained at the new length" [];
  expect_quiet t ~from:(released + 1) "after the commit";
  (* During a read, released early: the read continues from the shifter, and the replay
     presents the new frame from the store.
  *)
  let t = create "publication during a read, then a replay" in
  let _ : int = publish t first in
  run t 3;
  let _ : int = select t in
  run t 3;
  expect_read ~count:40 t "the old frame, first 40 bits" first;
  let _ : int = publish t second in
  let rest = wire_bits first |> Fn.flip List.drop 40 |> Fn.flip List.take 16 in
  let got = read_bits t (List.length rest) in
  check
    t
    ~phase:Post_run
    "the old frame, bits 40 to 55"
    [%sexp_of: string]
    [%equal: string]
    ~expected:(hex_of_bits rest)
    (hex_of_bits got);
  run t 4;
  ignore (deselect t : int);
  run t 5;
  let _ : Read.t = commit_read t "the new frame, replayed from the store" second in
  (* During a read, read on: the old frame's bits continue up to the new length, and the
     release commits.
  *)
  let t = create "publication during a read, then a commit" in
  let _ : int = publish t first in
  run t 3;
  let _ : int = select t in
  run t 3;
  expect_read ~count:40 t "the old frame, first 40 bits" first;
  let _ : int = publish t second in
  let rest =
    wire_bits first |> Fn.flip List.drop 40 |> Fn.flip List.take (second_bits - 40)
  in
  let got = read_bits t (List.length rest) in
  check
    t
    ~phase:Post_run
    "the old frame, bits 40 to the new length"
    [%sexp_of: string]
    [%equal: string]
    ~expected:(hex_of_bits rest)
    (hex_of_bits got);
  let drained_from = t.cycle in
  run t 4;
  let released = deselect t in
  run t 20;
  expect_data_cycles t ~from:drained_from "drained at the new length" [];
  expect_quiet t ~from:(released + 1) "after the commit";
  (* With a committing release: the commit wins for pending, so the new frame is never
     readable.
  *)
  let t = create "publication with a commit" in
  let _ : int = publish t first in
  run t 3;
  let _ : int = select t in
  run t 3;
  expect_read t "the old frame" first;
  run t 4;
  let released = t.cycle in
  stage t second;
  pulse t ~select_release:true;
  cycle t;
  run t 5;
  ignore (select t : int);
  List.iter (List.range 0 20) ~f:(fun _ ->
    run t 3;
    ignore (fall t : int));
  ignore (deselect t : int);
  run t 20;
  expect_quiet t ~from:(released + 1) "after the commit"
;;
