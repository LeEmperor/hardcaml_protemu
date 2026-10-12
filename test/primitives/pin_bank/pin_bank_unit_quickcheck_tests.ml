open! Core
open! Pin_bank_testbench

let regression_settings = Replay.Settings.create ~seed:20260919 ~trials:200 ~size:24

let%expect_test "bounded scenarios agree with the independent model" =
  (match
     quickcheck
       ~test:"pin_bank_agreement"
       ~config:Config.default
       ~generator:Generator.scenario
       ~prerequisite:Generator.begins_with_reset
       ~settings:regression_settings
       ()
   with
   | None -> print_endline "agreed on every trial"
   | Some failure -> print_string (Failure.to_string_hum failure));
  [%expect {| agreed on every trial |}]
;;
