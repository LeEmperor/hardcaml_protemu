(* Run with: dune exec test/primitives/input_events/input_events_four_state_bench.exe --
   TRIALS *)

(* The cost of the four-state property, beside the two-state timed runner on the same
   block and an equivalent scenario, so the ratio is a statement about the logic value
   type rather than about two different circuits. *)

open! Core
open! Hardcaml
module Four_state = Input_events_four_state_testbench
module Two_state = Input_events_timing_testbench

let trials =
  match Sys.get_argv () with
  | [| _ |] -> 200
  | [| _; trials |] -> Int.of_string trials
  | _ -> failwith "usage: input_events_four_state_bench.exe [TRIALS]"
;;

(* The shrunk controlled case: the smallest scenario that still carries the property. *)
let four_state_scenario =
  Four_state.Scenario.create
    ~edges:5
    [ Four_state.Transition.create 0 (Reset true)
    ; Four_state.Transition.create 6 (Reset false)
    ; Four_state.Transition.create 6 (Pad_unknown { known = 0; unknown = 1 })
    ; Four_state.Transition.create 16 (Pad 0)
    ]
;;

(* The same schedule with the unknown window replaced by a driven pulse. *)
let two_state_scenario =
  Two_state.Scenario.create
    ~edges:5
    [ Two_state.Transition.create 0 (Reset true)
    ; Two_state.Transition.create 6 (Reset false)
    ; Two_state.Transition.create 6 (Pad 1)
    ; Two_state.Transition.create 16 (Pad 0)
    ]
;;

let measure label f =
  Gc.full_major ();
  let started = Core_unix.gettimeofday () in
  for _ = 1 to trials do
    f ()
  done;
  let seconds = Core_unix.gettimeofday () -. started in
  printf
    "%s: trials=%d total_ms=%.3f us_per_trial=%.3f\n"
    label
    trials
    (seconds *. 1_000.)
    (seconds *. 1_000_000. /. Float.of_int trials)
;;

let () =
  if trials < 1 then failwith "TRIALS must be positive";
  measure "two-state-startup" (fun () ->
    ignore
      (Two_state.Circuit.with_processes
         (Hardcaml_protemu.Input_events.create (Scope.create ~flatten_design:true ()))
         (fun _ _ -> [])
       : Two_state.Circuit.testbench));
  measure "four-state-startup" (fun () ->
    ignore
      (Four_state.Circuit.with_processes
         (Four_state.create_dut None (Scope.create ~flatten_design:true ()))
         (fun _ _ -> [])
       : Four_state.Circuit.testbench));
  measure "two-state-five-edge-trial" (fun () ->
    ignore (Two_state.run Two_state.Config.default two_state_scenario : Two_state.Run.t));
  measure "four-state-five-edge-trial" (fun () ->
    ignore
      (Four_state.run Four_state.Config.default four_state_scenario : Four_state.Run.t))
;;
