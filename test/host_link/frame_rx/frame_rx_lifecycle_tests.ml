(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "frame_rx_lifecycle_tests.ml" *)
(* HL4c: [Frame_rx]'s eligibility, retention, and cancellation.

   In the composed loader, eligibility is low from the cycle after a handoff until the
   response is committed: the handoff's edge sets dispatch or a retained response, and
   each wait ends in a retained response. These tests drive that pattern directly. Reset
   and disable are applied for one cycle at each meaningful point of a request.

   Tests named "robustness" drive combinations the loader or the PHY does not present in
   normal traffic; each says why.
*)

open! Core
open! Hardcaml_protemu
open! Frame_rx_testbench

let info tag = encode ~tag Info
let write tag = encode ~tag (Write_word { address = 0x0010; word = 0x1234 })

let complete_info tag : Expected.t =
  { result = Complete
  ; echo_valid = true
  ; tag
  ; command = 0x00
  ; payload_length = 0
  ; payload = Char.to_int (info tag).[6]
  }
;;

let complete_write tag : Expected.t =
  { result = Complete
  ; echo_valid = true
  ; tag
  ; command = 0x11
  ; payload_length = 4
  ; payload = 0x12340010
  }
;;

let%test_unit "a handed-off request's fields hold while ineligible, through intruding \
               selections"
  =
  let t = create "retention while ineligible" in
  let { Selection.released; _ } = request t (write 0x42) in
  (* The loader's dispatch makes the receiver ineligible from the next cycle. *)
  set t ~eligible:false;
  let from = released + 1 in
  (* An early selection in the dispatch cycle itself, carrying a complete frame; then an
     overrunning one, an empty one, and a long idle interval.
  *)
  ignore (request ~lead:1 t (info 0x99) : Selection.t);
  run t 20;
  ignore (request t (Raw.zeros 12) : Selection.t);
  ignore (request t "" : Selection.t);
  run t 5000;
  let until = t.cycle in
  expect_frame_end_cycles t ~from "intruders" [];
  expect_active_cycles t ~from "intruders" [];
  expect_stable t ~from ~until "retained fields";
  expect_fields t ~cycle:(until - 1) "retained fields" (complete_write 0x42);
  (* Commit makes it eligible again; the next selection is a new request. *)
  set t ~eligible:true;
  run t 4;
  expect_handoff t "next request" (info 0x77) (complete_info 0x77)
;;

let%test_unit "eligibility is sampled only in the select-assert cycle" =
  let t = create "eligibility edges" in
  expect_handoff t "first" (write 0x10) (complete_write 0x10);
  (* Ineligible in the assert cycle, eligible from the next: the selection is ignored
     until it ends, and the retained fields do not change.
  *)
  set t ~eligible:false;
  run t 5;
  let from = t.cycle in
  ignore (select t : int);
  set t ~eligible:true;
  run t 3;
  send t (info 0x11);
  run t 8;
  let released = deselect t in
  run t 1;
  expect_frame_end_cycles t ~from "eligible one cycle late" [];
  expect_active_cycles t ~from "eligible one cycle late" [];
  expect_fields t ~cycle:released "eligible one cycle late" (complete_write 0x10);
  (* Eligible from the assert cycle itself, after a long ineligible interval. *)
  set t ~eligible:false;
  run t 20;
  set t ~eligible:true;
  expect_handoff t "eligible in the assert cycle" (info 0x12) (complete_info 0x12)
;;

let%test_unit "robustness: eligibility falling after the assert does not end a request" =
  (* The loader cannot do this: nothing sets its dispatch or response state while a
     request is active. The receiver still keeps the request it started.
  *)
  let t = create "eligible only at the assert" in
  let from = t.cycle in
  let asserted = select t in
  set t ~eligible:false;
  run t 3;
  send t (write 0x13);
  run t 8;
  let released = deselect t in
  run t 1;
  expect_frame_end_cycles t ~from "eligible only at the assert" [ released ];
  expect_active_cycles
    t
    ~from
    "eligible only at the assert"
    (List.range (asserted + 1) (released + 1));
  expect_fields t ~cycle:released "eligible only at the assert" (complete_write 0x13)
;;

(* Where in a request a one-cycle reset or disable lands. *)
module Point = struct
  type t =
    | After_bits of int
    | Release
  [@@deriving sexp_of]
end

let%test_unit "reset and disable cancel at every receive and validation boundary" =
  let frame = write 0x71 in
  let bits = bits_of_string frame in
  List.iter [ `Reset; `Disable ] ~f:(fun kind ->
    List.iter
      [ "mid-byte", Point.After_bits ((8 * 5) + 3)
      ; "after the header", After_bits 48
      ; "after the whole frame", After_bits 88
      ; "in the release cycle", Release
      ]
      ~f:(fun (where, point) ->
        let name =
          sprintf
            "%s %s"
            (match kind with
             | `Reset -> "reset"
             | `Disable -> "disable")
            where
        in
        let t = create name in
        let cancel on =
          match kind with
          | `Reset -> set t ~reset:on
          | `Disable -> set t ~enable:(not on)
        in
        let from = t.cycle in
        let asserted = select t in
        run t 3;
        (match point with
         | After_bits count ->
           send_bits t (List.take bits count);
           let cancelled = t.cycle in
           cancel true;
           cycle t;
           cancel false;
           (* The rest of the frame, still selected, is not a request. *)
           send_bits t (List.drop bits count);
           run t 8;
           ignore (deselect t : int);
           run t 1;
           expect_frame_end_cycles t ~from name [];
           expect_active_cycles t ~from name (List.range (asserted + 1) (cancelled + 1));
           expect_fields t ~cycle:(cancelled + 1) name (Expected.empty Incomplete);
           expect_stable t ~from:(cancelled + 1) ~until:t.cycle name
         | Release ->
           send_bits t bits;
           run t 8;
           cancel true;
           let released = deselect t in
           cancel false;
           run t 1;
           (* The handoff is presented, ungated, in the cancelled cycle; the loader's own
              reset or disable clears the dispatch it would arm. The state is gone after.
           *)
           expect_frame_end_cycles t ~from name [ released ];
           expect_active_cycles t ~from name (List.range (asserted + 1) (released + 1));
           expect_fields t ~cycle:released name (complete_write 0x71);
           expect_fields t ~cycle:(released + 1) name (Expected.empty Incomplete));
        (* No stale state: a later request is received normally. *)
        run t 4;
        expect_handoff t (name ^ ", then INFO") (info 0x72) (complete_info 0x72)))
;;

let%test_unit "reset or disable held across an assert prevents that request" =
  List.iter [ `Reset; `Disable ] ~f:(fun kind ->
    let name =
      match kind with
      | `Reset -> "reset"
      | `Disable -> "disable"
    in
    let t = create (name ^ " across an assert") in
    expect_handoff t "first" (write 0x20) (complete_write 0x20);
    let cancel on =
      match kind with
      | `Reset -> set t ~reset:on
      | `Disable -> set t ~enable:(not on)
    in
    let from = t.cycle in
    cancel true;
    run t 3;
    ignore (select t : int);
    run t 3;
    cancel false;
    send t (info 0x21);
    run t 8;
    let released = deselect t in
    run t 1;
    expect_frame_end_cycles t ~from name [];
    expect_active_cycles t ~from name [];
    (* The cancellation also cleared the first request's retained fields. *)
    expect_fields t ~cycle:released name (Expected.empty Incomplete);
    expect_handoff t (name ^ ", then INFO") (info 0x22) (complete_info 0x22))
;;

let%test_unit "disable clears a latched overrun before the frame ends" =
  let t = create "disable after overrun" in
  let from = t.cycle in
  ignore (select t : int);
  run t 3;
  send t (Raw.zeros 12);
  set t ~enable:false;
  cycle t;
  set t ~enable:true;
  send t (info 0x30);
  run t 8;
  let released = deselect t in
  run t 1;
  expect_frame_end_cycles t ~from "disable after overrun" [];
  expect_fields t ~cycle:released "disable after overrun" (Expected.empty Incomplete);
  expect_handoff t "INFO after" (info 0x31) (complete_info 0x31)
;;

let%test_unit "clock rises while deselected and idle change nothing" =
  (* The PHY reports LCLK edges whether or not LSEL_N is low. *)
  let t = create "rises while deselected" in
  expect_handoff t "first" (write 0x40) (complete_write 0x40);
  let from = t.cycle in
  List.iter (List.init 50 ~f:(fun index -> index % 3 = 0)) ~f:(send_bit ~period:2 t);
  expect_frame_end_cycles t ~from "rises while deselected" [];
  expect_active_cycles t ~from "rises while deselected" [];
  expect_stable t ~from ~until:t.cycle "rises while deselected"
;;

let%test_unit "robustness: a clock rise coincident with the assert or the release is not \
               received"
  =
  (* [Serial_phy] can report these together, but the P3.5 envelope keeps four cycles
     between selection and the first rise, and between the last fall and deselection. Were
     either rise received, the frame would end with a partial byte.
  *)
  let t = create "coincident events" in
  let from = t.cycle in
  let asserted = t.cycle in
  set t ~selected:true ~data:true;
  pulse t ~select_assert:true ~clock_rise:true;
  cycle t;
  run t 3;
  send t (info 0x50);
  run t 8;
  let released = t.cycle in
  set t ~selected:false ~data:true;
  pulse t ~select_release:true ~clock_rise:true;
  cycle t;
  run t 1;
  expect_frame_end_cycles t ~from "coincident events" [ released ];
  expect_active_cycles
    t
    ~from
    "coincident events"
    (List.range (asserted + 1) (released + 1));
  expect_fields t ~cycle:released "coincident events" (complete_info 0x50)
;;

let%test_unit "robustness: a second assert while active does not restart the request" =
  (* Incoherent input: the PHY cannot report an assert without a release between. *)
  let t = create "repeated assert" in
  let frame = info 0x60 in
  let from = t.cycle in
  let asserted = select t in
  run t 3;
  send t (String.prefix frame 3);
  pulse t ~select_assert:true;
  cycle t;
  send t (String.drop_prefix frame 3);
  run t 8;
  let released = deselect t in
  run t 1;
  expect_frame_end_cycles t ~from "repeated assert" [ released ];
  expect_active_cycles
    t
    ~from
    "repeated assert"
    (List.range (asserted + 1) (released + 1));
  expect_fields t ~cycle:released "repeated assert" (complete_info 0x60)
;;
