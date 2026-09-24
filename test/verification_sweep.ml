(* Explicit verification sweeps used by the root regression aliases. These call the same
   generators, predictors, checkers, and replay writers as the bounded inline tests; the
   aliases change only the recorded seeds and budgets. *)

open! Core

let fail report = failwith report

let run_pin_bank ~seed =
  let module T = Pin_bank_testbench in
  match
    T.quickcheck
      ~test:"pin_bank_long_agreement"
      ~config:T.Config.default
      ~generator:T.Generator.scenario
      ~prerequisite:T.Generator.begins_with_reset
      ~environment_overrides:false
      ~settings:(Replay.Settings.create ~seed ~trials:1000 ~size:32)
      ()
  with
  | None -> ()
  | Some failure -> fail (T.Failure.to_string_hum failure)
;;

let run_timed_input_events ~seed =
  let module T = Input_events_timing_testbench in
  match
    T.quickcheck
      ~here:[%here]
      ~test:"input_events_long_timed_agreement"
      ~config:T.Config.default
      ~generator:T.Generator.scenario
      ~environment_overrides:false
      ~settings:(Replay.Settings.create ~seed ~trials:500 ~size:24)
      ()
  with
  | None -> ()
  | Some failure -> fail (T.Failure.to_string_hum failure)
;;

let run_observed_transfer () =
  let module T = Observed_transfer_timing_testbench in
  List.iter (List.init T.period ~f:Fn.id) ~f:(fun phase ->
    let result = T.run (T.phase_scenario phase) in
    if not (T.Run.passed result)
    then
      failwith
        (Sexp.to_string_hum
           [%message
             "observed-transfer phase sweep failed"
               (phase : int)
               (result.outcome : T.Outcome.t)]));
  let result = T.run T.abort_scenario in
  if not (T.Run.passed result)
  then
    failwith
      (Sexp.to_string_hum
         [%message "observed-transfer abort sweep failed" (result.outcome : T.Outcome.t)])
;;

let run_four_state ~seed =
  let module T = Input_events_four_state_testbench in
  match
    T.quickcheck
      ~here:[%here]
      ~test:"input_events_long_four_state_agreement"
      ~config:T.Config.default
      ~generator:T.Generator.scenario
      ~environment_overrides:false
      ~settings:(Replay.Settings.create ~seed ~trials:500 ~size:20)
      ()
  with
  | None -> ()
  | Some failure -> fail (T.Failure.to_string_hum failure)
;;

let seeds = [ 1; 7; 99; 424242; 20261231 ]

let () =
  match Sys.get_argv () |> Array.to_list with
  | [ _; "long" ] ->
    List.iter seeds ~f:(fun seed ->
      run_pin_bank ~seed;
      run_timed_input_events ~seed);
    run_observed_transfer ();
    print_endline "long functional and timed sweeps passed"
  | [ _; "four-state" ] ->
    List.iter seeds ~f:(fun seed -> run_four_state ~seed);
    print_endline "long four-state sweeps passed"
  | _ -> failwith "usage: verification_sweep.exe (long|four-state)"
;;
