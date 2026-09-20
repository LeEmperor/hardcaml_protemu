(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "protocol_core_property_tests.ml" *)
(* Reproducible bounded generated comparison of P3.1a's independent model, RTL consumer,
   and external memory contract model. *)

open! Core
open! Protocol_core_testbench

module Action = struct
  type t =
    | Idle
    | Reset
    | Disable
    | Engines_busy
    | Start of int
    | Write of int * int
    | Complete
    | Read of int
    | Verify of int * int
    | Run
    | Halt
    | Fetch of int
  [@@deriving sexp_of]

  let input = function
    | Idle -> input ()
    | Reset -> input ~reset:true ()
    | Disable -> input ~enable:false ()
    | Engines_busy -> input ~engines_idle:false ()
    | Start length -> input ~load_start:length ()
    | Write (address, data) -> input ~load_write:(address, data) ()
    | Complete -> input ~load_complete:true ()
    | Read address -> input ~readback:(address, false, 0) ()
    | Verify (address, expected) -> input ~readback:(address, true, expected) ()
    | Run -> input ~run:true ()
    | Halt -> input ~execution_halt:true ()
    | Fetch address -> input ~fetch:address ()
  ;;
end

module Generator = struct
  module G = Base_quickcheck.Generator
  open G.Let_syntax

  let address = G.int_uniform_inclusive 0 300
  let word = G.int_uniform_inclusive 0 0xffff

  let action =
    let%bind kind =
      G.of_weighted_list
        [ 5., `Idle
        ; 1., `Reset
        ; 1., `Disable
        ; 1., `Busy
        ; 3., `Start
        ; 6., `Write
        ; 2., `Complete
        ; 4., `Read
        ; 5., `Verify
        ; 3., `Run
        ; 2., `Halt
        ; 6., `Fetch
        ]
    in
    match kind with
    | `Idle -> G.return Action.Idle
    | `Reset -> G.return Action.Reset
    | `Disable -> G.return Action.Disable
    | `Busy -> G.return Action.Engines_busy
    | `Complete -> G.return Action.Complete
    | `Run -> G.return Action.Run
    | `Halt -> G.return Action.Halt
    | `Start ->
      let%map length = G.int_uniform_inclusive 0 300 in
      Action.Start length
    | `Write ->
      let%map address
      and data = word in
      Action.Write (address, data)
    | `Read ->
      let%map address in
      Action.Read address
    | `Verify ->
      let%map address
      and expected = word in
      Action.Verify (address, expected)
    | `Fetch ->
      let%map address in
      Action.Fetch address
  ;;

  let scenario =
    let%bind size = G.size in
    let%bind image_length =
      G.int_uniform_inclusive 1 (Int.min 8 (Int.max 1 (size + 1)))
    in
    let%bind words = G.list_with_length word ~length:image_length in
    let%bind fetch_address = G.int_uniform_inclusive 0 (image_length - 1) in
    let%bind suffix_length = G.int_uniform_inclusive 8 (Int.max 8 (size + 8)) in
    let%map suffix = G.list_with_length action ~length:suffix_length in
    let writes = List.mapi words ~f:(fun address data -> Action.Write (address, data)) in
    let verification =
      List.concat_mapi words ~f:(fun address expected ->
        [ Action.Verify (address, expected); Action.Idle ])
    in
    [ Action.Start image_length ]
    @ writes
    @ verification
    @ [ Action.Complete; Action.Run; Action.Fetch fetch_address; Action.Idle ]
    @ suffix
  ;;
end

let settings = Replay.Settings.create ~seed:20260920 ~trials:240 ~size:32

let run_scenario ~trial scenario =
  let poison = List.nth_exn Poison.all (trial % List.length Poison.all) in
  let t = create ~poison () in
  Or_error.try_with (fun () ->
    List.iter scenario ~f:(fun action -> step t (Action.input action)))
  |> Result.map_error ~f:Error.to_string_hum
;;

let quickcheck ~(here : [%call_pos]) () =
  let settings = Replay.Settings.override settings in
  let random = Splittable_random.of_int settings.seed in
  let rec search trial =
    if trial >= settings.trials
    then None
    else (
      let size = Replay.Settings.size_of_trial settings ~trial in
      let scenario =
        Base_quickcheck.Generator.generate Generator.scenario ~size ~random
      in
      match run_scenario ~trial scenario with
      | Ok () -> search (trial + 1)
      | Error reason ->
        let replay =
          Replay.create
            ~test:"protocol_core_generated_load_access_fetch"
            ~source_file:here.pos_fname
            ~settings
            ~trial:(Some trial)
            ~config:[%sexp (scenario : Action.t list)]
        in
        let scenario = Sexp.to_string_hum [%sexp (scenario : Action.t list)] in
        let report =
          String.concat
            ~sep:"\n"
            ([ "protocol_core: generated model/RTL comparison failed"
             ; ""
             ; "reproduction:"
             ]
             @ Replay.to_lines replay
             @ [ ""
               ; [%string "first mismatch: %{reason}"]
               ; [%string "scenario: %{scenario}"]
               ; ""
               ])
        in
        let artifact =
          Replay.Artifacts.write
            ~test:"protocol_core_generated_load_access_fetch"
            ~settings
            ~trial
            ~contents:(report ^ Replay.artifact_appendix replay)
        in
        Some
          (match artifact with
           | None -> report
           | Some path -> report ^ [%string "artifact: %{path}\n"]))
  in
  search 0
;;

let%expect_test "bounded load/access/fetch schedules agree with the independent model" =
  (match quickcheck ~here:[%here] () with
   | None -> print_endline "agreed on all 240 generated protocol-core trials"
   | Some failure -> print_string failure);
  [%expect {| agreed on all 240 generated protocol-core trials |}]
;;

let%expect_test "generated core scenarios record an executable rerun" =
  print_endline
    (Replay.rerun_command
       ~source_file:"test/core/protocol_core/protocol_core_property_tests.ml"
       ~settings);
  [%expect
    {|
    PROTEMU_SEED=20260920 PROTEMU_TRIALS=240 PROTEMU_SIZE=32 dune runtest test/core/protocol_core --force
    |}]
;;
