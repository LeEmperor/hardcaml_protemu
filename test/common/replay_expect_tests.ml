open! Core
open! Pin_bank_testbench

let fixture_settings = Replay.Settings.create ~seed:20260919 ~trials:64 ~size:12

let%expect_test "artifact paths are valid from a dune runner directory" =
  let directory = [%string "protemu-artifacts-test-%{Replay.Posix.getpid ()#Int}"] in
  let path =
    Replay.Artifacts.write_to
      ~directory
      ~test:"artifact_path"
      ~settings:(Replay.Settings.create ~seed:1 ~trials:1 ~size:1)
      ~trial:0
      ~contents:"artifact path check\n"
    |> Option.value_exn
  in
  print_s
    [%message
      (Filename.is_relative path : bool)
        (String.equal (Filename.dirname path) directory : bool)
        (Stdlib.Sys.file_exists path : bool)];
  Stdlib.Sys.remove path;
  Replay.Posix.rmdir directory;
  [%expect
    {|
    (("Filename.is_relative path" true)
     ("String.equal (Filename.dirname path) directory" true)
     ("Stdlib.Sys.file_exists path" true))
    |}]
;;

let%expect_test "a controlled mismatch is found, shrunk, and reproduced from its seed" =
  (* The same generator, the same seed, the same settings; only the environment's
     reference is wrong. No artifact is written: this run is expected and a regression
     should not leave files behind. *)
  let run defect =
    quickcheck
      ~test:"pin_bank_open_drain_defect"
      ~config:(Config.with_defect defect)
      ~generator:Generator.scenario
      ~prerequisite:Generator.begins_with_reset
      ~write_artifact:false
        (* This test snapshots one seed's report, so it runs its recorded settings even
           during a PROTEMU_SEED sweep; an artifact path carries a process id and would
           not be reproducible either. *)
      ~environment_overrides:false
      ~settings:fixture_settings
      ()
  in
  (* Without the defect these settings find nothing, so what follows is the defect. *)
  print_s [%sexp (Option.is_none (run No_defect) : bool)];
  [%expect {| true |}];
  let first = Option.value_exn (run Ignore_open_drain) in
  let again = Option.value_exn (run Ignore_open_drain) in
  print_string (Failure.to_string_hum ~redact_source:true first);
  [%expect
    {|
    pin_bank: f_model/Hardcaml comparison failed

    reproduction:
      test:             pin_bank_open_drain_defect
      test file:        test/common/replay_expect_tests.ml
      seed:             20260919
      trials:           64
      max size:         12
      failing trial:    6
      configuration:    ((engine 0)(defect Ignore_open_drain))
      source identity:  <recorded; redacted in expect output>
      rerun:            PROTEMU_SEED=20260919 PROTEMU_TRIALS=64 PROTEMU_SIZE=12 dune runtest test/common --force

    first mismatch:
      edge:             1
      phase:            Post_edge
      item at edge:     ((enable true)(write((engine false)(mask 15)(value 50)(output_enable 48)(open_drain true))))
      observation:      pins
      reason:           Value
      expected (model): 2
      actual (dut):     0

    failing scenario (5 items):
      ((reset)(enable true))
      ((enable true)(write((engine false)(mask 15)(value 50)(output_enable 48)(open_drain true))))
      ((enable true)(write((engine true)(mask 1)(value 193)(output_enable 141)(open_drain true))))
      ((enable true)(write((engine false)(mask 0)(value 98)(output_enable 101)(open_drain false))))
      ((enable true)(release((engine true)(mask 22))))

    shrunk scenario (2 items):
      ((reset)(enable true))
      ((enable true)(write((engine true)(mask 1)(value 193)(output_enable 141)(open_drain true))))
    shrunk failure:
      edge:             1
      phase:            Post_edge
      item at edge:     ((enable true)(write((engine true)(mask 1)(value 193)(output_enable 141)(open_drain true))))
      observation:      pins
      reason:           Value
      expected (model): 1
      actual (dut):     0

    trace context:
    edge 0  item ((reset)(enable true))
      before  held.pins=0 held.pin_oe=0 held.software_claim=0 held.engine_claim=0 held.rejected=0
              held.conflict=0
      after   pins=0 pin_oe=0 software_claim=0 engine_claim=0 rejected=0 conflict=0
              reject_reason=- bus0=? bus1=? bus2=? bus3=? bus4=? bus5=? bus6=? bus7=?
    edge 1  item ((enable true)(write((engine false)(mask 15)(value 50)(output_enable 48)(open_drain true))))
      before  held.pins=0 held.pin_oe=0 held.software_claim=0 held.engine_claim=0 held.rejected=0
              held.conflict=0
      after   pins=0 pin_oe=0 software_claim=0 engine_claim=0 rejected=0 conflict=0
              reject_reason=- bus0=? bus1=? bus2=? bus3=? bus4=? bus5=? bus6=? bus7=?
    |}];
  (* Rerunning the recorded seed and settings finds the same first mismatch, at the same
     edge, in the same trial. *)
  print_s
    [%message
      ""
        ~same_first_mismatch:(Outcome.equal first.outcome again.outcome : bool)
        ~same_trial:(Option.equal Int.equal first.replay.trial again.replay.trial : bool)];
  [%expect {| ((same_first_mismatch true) (same_trial true)) |}]
;;
