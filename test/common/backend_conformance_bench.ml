(* Run with: dune exec test/common/backend_conformance_bench.exe -- TRIALS *)

open! Core
open! Backend_conformance

let trials =
  match Sys.get_argv () with
  | [| _ |] -> 200
  | [| _; trials |] -> Int.of_string trials
  | _ -> failwith "usage: backend_conformance_bench.exe [TRIALS]"
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
  measure "cyclesim-startup" (fun () -> ignore (create_cyclesim () : Cycle_sim.t));
  measure "eventsim-startup" (fun () ->
    ignore (create_eventsim_without_testbench () : Event_circuit.testbench));
  measure "cyclesim-five-edge" (fun () -> ignore (run_cyclesim () : Edge_sample.t list));
  measure "eventsim-five-edge" (fun () -> ignore (run_eventsim () : Edge_sample.t list))
;;
