(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "backend_conformance.ml" *)
(* A deliberately tiny circuit and scenario used to characterize the Cyclesim and
   two-state Evsim step-testbench adapters.  This is scheduling evidence, not product
   coverage: no production RTL or functional-model behavior is defined here. *)

open! Core
open! Hardcaml
open! Signal

module I = struct
  type 'a t =
    { clock : 'a
    ; reset : 'a
    ; enable : 'a
    ; data : 'a [@bits 4]
    ; valid : 'a
    ; payload : 'a [@bits 4]
    }
  [@@deriving hardcaml]
end

module O = struct
  type 'a t =
    { q : 'a [@bits 4]
    ; ready : 'a
    ; accepted : 'a
    ; out_valid : 'a
    ; out_payload : 'a [@bits 4]
    }
  [@@deriving hardcaml]
end

module State = struct
  type 'a t =
    { full : 'a
    ; payload : 'a [@bits 4]
    }
  [@@deriving hardcaml]
end

let create (i : _ I.t) : _ O.t =
  let open Always in
  let spec = Reg_spec.create ~clock:i.clock ~clear:i.reset () in
  let q = Signal.reg spec ~enable:i.enable i.data in
  let state = State.Of_always.reg spec in
  compile
    [ when_
        (i.valid &: ~:(state.full.value))
        [ state.full <--. 1; state.payload <-- i.payload ]
    ];
  let ready = ~:(state.full.value) in
  { O.q
  ; ready
  ; accepted = i.valid &: ready &: ~:(i.reset)
  ; out_valid = state.full.value
  ; out_payload = state.payload.value
  }
;;

module Scenario = struct
  type t =
    { reset : bool
    ; enable : bool
    ; data : int
    ; valid : bool
    ; payload : int
    }

  let all =
    [ { reset = false; enable = true; data = 10; valid = true; payload = 6 }
    ; { reset = true; enable = true; data = 15; valid = true; payload = 15 }
    ; { reset = false; enable = false; data = 3; valid = false; payload = 0 }
    ; { reset = false; enable = true; data = 5; valid = true; payload = 9 }
    ; { reset = false; enable = false; data = 7; valid = true; payload = 12 }
    ]
  ;;

  let bit value = if value then Bits.vdd else Bits.gnd

  let to_inputs t : Bits.t I.t =
    { clock = Bits.empty
    ; reset = bit t.reset
    ; enable = bit t.enable
    ; data = Bits.of_int_trunc ~width:4 t.data
    ; valid = bit t.valid
    ; payload = Bits.of_int_trunc ~width:4 t.payload
    }
  ;;
end

module Sample = struct
  type t =
    { q : int
    ; ready : int
    ; accepted : int
    ; out_valid : int
    ; out_payload : int
    }
  [@@deriving sexp, compare, equal]

  let of_output (o : Bits.t O.t) =
    { q = Bits.to_int_trunc o.q
    ; ready = Bits.to_int_trunc o.ready
    ; accepted = Bits.to_int_trunc o.accepted
    ; out_valid = Bits.to_int_trunc o.out_valid
    ; out_payload = Bits.to_int_trunc o.out_payload
    }
  ;;
end

module Edge_sample = struct
  type t =
    { before : Sample.t
    ; after : Sample.t
    ; completed_at : int option
    }
  [@@deriving sexp, compare, equal]

  let without_time t = { t with completed_at = None }
end

module Clock_transition = struct
  type t =
    { time : int
    ; level : int
    }
  [@@deriving sexp, compare, equal]
end

module Cycle_step = Hardcaml_step_testbench.Functional.Cyclesim.Make (I) (O)
module Cycle_sim = Cyclesim.With_interface (I) (O)

let create_cyclesim () = Cycle_sim.create create

let run_cyclesim () =
  let simulator = create_cyclesim () in
  Cycle_step.run_until_finished
    ~input_default:Cycle_step.input_hold
    ()
    ~simulator
    ~testbench:(fun handler _initial ->
      let samples = ref [] in
      let items = Array.of_list Scenario.all in
      for index = 0 to Array.length items - 1 do
        let item = items.(index) in
        let output = Cycle_step.cycle handler (Scenario.to_inputs item) in
        samples
        := { Edge_sample.before =
               Sample.of_output (Cycle_step.O_data.before_edge output)
           ; after = Sample.of_output (Cycle_step.O_data.after_edge output)
           ; completed_at = None
           }
           :: !samples
      done;
      List.rev !samples)
;;

let cyclesim_times_out () =
  let simulator = create_cyclesim () in
  let result =
    Cycle_step.run_with_timeout
      ~input_default:Cycle_step.input_hold
      ~timeout:3
      ()
      ~simulator
      ~testbench:(fun handler _initial -> Cycle_step.never handler)
  in
  Option.is_none result
;;

module Event_backend = Hardcaml_step_testbench.Functional.Event_driven_sim
module Event_step = Event_backend.Make (I) (O)
module Event_circuit = Event_backend.With_interface (I) (O)

let port_signals ports = I.map ports ~f:(fun port -> port.Event_backend.Port.signal)
let output_signals ports = O.map ports ~f:(fun port -> port.Event_backend.Port.signal)

let clock_process (inputs : _ Event_backend.Port.t I.t) =
  Event_circuit.create_clock ~here:[%here] ~time:5 inputs.clock.signal
;;

let create_eventsim_without_testbench () =
  Event_circuit.with_processes create (fun inputs _outputs -> [ clock_process inputs ])
;;

let clock_monitor signal transitions =
  Event_backend.Simulator.Async.create_process (fun () ->
    Event_backend.Simulator.Async.forever (fun () ->
      let open Event_backend.Simulator.Async.Deferred.Let_syntax in
      let%map () =
        Event_backend.Simulator.Async.wait_for_change
          (Event_backend.Simulator.Signal.id signal)
      in
      transitions
      := { Clock_transition.time = Event_backend.Simulator.Async.current_time ()
         ; level =
             Event_backend.Simulator.Signal.read signal
             |> Event_backend.Logic.to_bits_exn
             |> Bits.to_int_trunc
         }
         :: !transitions))
;;

let run_eventsim_with_clock_trace () =
  let result = ref None in
  let transitions = ref [] in
  let testbench =
    Event_circuit.with_processes create (fun inputs outputs ->
      let process =
        Event_step.process
          ~input_default:Event_step.input_hold
          ~timeout:8
          ~simulation_step:Event_step.Simulation_step.cyclesim_compatible
          ()
          ~clock:inputs.clock.signal
          ~inputs:(port_signals inputs)
          ~outputs:(output_signals outputs)
          ~testbench:(fun handler _initial ->
            let samples = ref [] in
            let items = Array.of_list Scenario.all in
            for index = 0 to Array.length items - 1 do
              let item = items.(index) in
              let output = Event_step.cycle handler (Scenario.to_inputs item) in
              samples
              := { Edge_sample.before =
                     Sample.of_output (Event_step.O_data.before_edge output)
                 ; after = Sample.of_output (Event_step.O_data.after_edge output)
                 ; completed_at = Some (Event_backend.Simulator.Async.current_time ())
                 }
                 :: !samples
            done;
            result := Some (List.rev !samples))
      in
      [ clock_process inputs; clock_monitor inputs.clock.signal transitions; process ])
  in
  (* The fifth step completes at time 50.  Running one extra tick proves completion did
     not depend on stopping exactly on the final falling edge. *)
  Event_backend.Simulator.run testbench.simulator ~time_limit:51;
  Option.value_exn !result, List.rev !transitions
;;

let run_eventsim () = fst (run_eventsim_with_clock_trace ())

let eventsim_times_out () =
  let result = ref `Pending in
  let testbench =
    Event_circuit.with_processes create (fun inputs outputs ->
      let process =
        Event_backend.Simulator.Async.create_process (fun () ->
          let open Event_backend.Simulator.Async.Deferred.Let_syntax in
          let run =
            Event_step.deferred
              ~input_default:Event_step.input_hold
              ~timeout:3
              ~simulation_step:Event_step.Simulation_step.cyclesim_compatible
              ()
              ~clock:inputs.clock.signal
              ~inputs:(port_signals inputs)
              ~outputs:(output_signals outputs)
              ~testbench:(fun handler _initial -> Event_step.never handler)
          in
          let%bind completed = run () in
          result := (if Option.is_none completed then `Timed_out else `Completed);
          Event_backend.Simulator.Async.wait_forever ())
      in
      [ clock_process inputs; process ])
  in
  Event_backend.Simulator.run testbench.simulator ~time_limit:40;
  Poly.equal !result `Timed_out
;;

let expected : Edge_sample.t list =
  let sample ~q ~ready ~accepted ~out_valid ~out_payload =
    { Sample.q; ready; accepted; out_valid; out_payload }
  in
  [ { before = sample ~q:0 ~ready:1 ~accepted:1 ~out_valid:0 ~out_payload:0
    ; after = sample ~q:10 ~ready:0 ~accepted:0 ~out_valid:1 ~out_payload:6
    ; completed_at = None
    }
  ; { before = sample ~q:10 ~ready:0 ~accepted:0 ~out_valid:1 ~out_payload:6
    ; after = sample ~q:0 ~ready:1 ~accepted:0 ~out_valid:0 ~out_payload:0
    ; completed_at = None
    }
  ; { before = sample ~q:0 ~ready:1 ~accepted:0 ~out_valid:0 ~out_payload:0
    ; after = sample ~q:0 ~ready:1 ~accepted:0 ~out_valid:0 ~out_payload:0
    ; completed_at = None
    }
  ; { before = sample ~q:0 ~ready:1 ~accepted:1 ~out_valid:0 ~out_payload:0
    ; after = sample ~q:5 ~ready:0 ~accepted:0 ~out_valid:1 ~out_payload:9
    ; completed_at = None
    }
  ; { before = sample ~q:5 ~ready:0 ~accepted:0 ~out_valid:1 ~out_payload:9
    ; after = sample ~q:5 ~ready:0 ~accepted:0 ~out_valid:1 ~out_payload:9
    ; completed_at = None
    }
  ]
;;
