# `hardcaml_step_testbench` across Cyclesim and event-driven simulation

Status: reference notes, written 2026-09-19 against the `5.2.0+ox` switch, to support the
P2.2/P2.6 harness decision. [verification.md](verification.md) owns the accepted P1.6
approach and [phase_plan.md](phase_plan.md) tracks the work; this document only describes
what the library does and does not abstract, so the harness is sized correctly before it
is written. It records no completion evidence.

## 1. The short answer

`hardcaml_step_testbench` is a testbench-authoring layer over *both* `Hardcaml.Cyclesim`
and `hardcaml_event_driven_sim`. It genuinely abstracts over the two engines, but not as a
runtime backend switch. It is a **2x2 matrix of functors**, and the portability it offers
is a compile-time structural property.

From `hardcaml_step_testbench/src/hardcaml_step_testbench.ml`:

```ocaml
module Functional = struct
  include Functional                      (* simulator-agnostic core *)
  module Cyclesim = Functional_cyclesim
  module Event_driven_sim = Functional_event_driven_sim
end

module Imperative = struct
  include Imperative
  module Cyclesim = Imperative_cyclesim
  module Event_driven_sim = Imperative_event_driven_sim
end
```

Two independent axes:

- **Functional vs Imperative** — how a testbench exchanges values with the ports.
- **Cyclesim vs Event_driven_sim** — which engine advances time.

The practical consequence for this repository: adopting the event-driven backend does not
mean rewriting testbench bodies. It means writing a different *runner*, and settling what a
cycle means on both sides. That matches the scope note already recorded against P2.2 in the
[phase plan](phase_plan.md) — a simulator backend conversion, not another test file.

## 2. What is portable, and what is not

`Functional.Make(I)(O)` is the engine-neutral part, and says so in its own header
(`functional_intf.ml`):

> Testbenches written against this API make may be used with either cyclesim or
> event_driven_sim.

It supplies the whole testbench vocabulary: `cycle`, `delay`, `spawn`, `spawn_io`,
`wait_for`, `wait_for_with_timeout`, `forever`, `merge_inputs`, and the `input_hold` /
`input_zero` defaults.

Each backend module then begins:

```ocaml
module type S = sig
  include Functional.S
  (* ... and adds only the run functions and a Simulator type ... *)
end
```

The backends add **nothing to the testbench vocabulary**. They add only the glue that
drives it. That is the entire abstraction, and it is a real one.

This works because `Handler.t` is `(O_data.t, I_data.t) Step_effect.Handler.t`, fully
determined by `I` and `O`, so the neutral handler type and each backend's handler type are
structurally equal. The upstream tests rely on exactly this: `send_and_receive_testbench.mli`
declares

```ocaml
module Tb : Hardcaml_step_testbench.Functional.M(I)(O).S
val testbench : _ -> Tb.Handler.t -> Bits.t list
```

and that same `testbench` value is run by `test_effectful.ml` through
`Functional.Cyclesim.Make` and by `test_effectful_evsim.ml` through
`Functional.Event_driven_sim.Make`. One testbench body, two engines, no conditional code.

What is *not* portable is the setup: constructing the simulator, creating the clock, and
starting the run. Those differ in shape, not just in spelling, for the reason given in
section 4.

## 3. Functional vs Imperative

| | Functional | Imperative |
| --- | --- | --- |
| `I_data.t` | `Bits.t I.t` | `unit` |
| `O_data.t` | `Bits.t O.t Before_and_after_edge.t` | `unit Before_and_after_edge.t` |
| Driving inputs | the step *returns* input values | poke the simulator's `Bits.t ref` ports |
| Conflicting drivers | resolved by `merge_inputs` and the `input_default` | the author's problem |

In the functional style, a step returns the inputs it wants applied; the harness merges
child values into parent values with `merge_inputs` and fills every unset field from the
chosen default — `input_hold` keeps the previous value, `input_zero` clears it. Outputs
arrive as a `Before_and_after_edge.t`, so pre-edge acceptance and settled post-edge results
are separate values rather than a convention. That is the distinction
[verification.md](verification.md) section 3 already requires the runner to capture, so the
functional style is the closer fit for the P1.6 environment.

In the imperative style `I_data.t` is `unit` and the testbench writes ports directly. It is
less ceremony and no automatic arbitration between concurrent tasks.

The two interoperate in one direction: `Io_ports_for_imperative`,
`create_io_ports_for_imperative`, `spawn_from_imperative` and
`exec_never_returns_from_imperative` let a functional sub-testbench run inside an imperative
one. The Cyclesim-imperative module additionally offers `wrap`, which folds testbenches into
a `Cyclesim.t` so that a plain `Cyclesim.cycle sim` steps them — useful for retrofitting
onto an existing loop such as [`test_protocol_core.ml`](../test/test_protocol_core.ml),
which drives `Cyclesim` directly today.

## 4. The two runners are shaped differently

| | Cyclesim | Event_driven_sim |
| --- | --- | --- |
| Entry point | `run_until_finished ~simulator ~testbench`, `run_with_timeout` | `process ()` returning a `Simulator.Process.t`, or `deferred` |
| Simulator handle | `Cyclesim.With_interface(I)(O).t` | `clock:`, `inputs:`, `outputs:` as `Logic.t Simulator.Signal.t` |
| Who drives the clock | the harness | **the test**, as a separate process |
| Cycle semantics | fixed | selected by `Simulation_step` |
| Also available | `wrap` / `wrap_never_returns` | `Async.Deferred` composition |

Cyclesim is a driver: step_testbench owns the loop and returns the testbench's result.

Event-driven simulation is a process scheduler, so step_testbench cannot own the loop. It
hands back a process to *insert* into the simulation, and the interface is explicit that the
clock must be driven externally and **not** set from inside the step monad. The shape is:

```ocaml
let { Evsim.processes; input; output; _ } = Evsim.create create in
let step_process =
  Step.process () ~clock:input.clock.signal ~inputs ~outputs ~testbench
in
let clock = Evsim.create_clock input.clock.signal ~time:5 in
Event_simulator.run ~time_limit:100
  (Event_simulator.create (clock :: step_process :: trace :: processes))
```

This is also where the capability P2.2 needs comes from. Because the testbench is one
process among several on a real time axis, a pad driver can be another process that changes
an input at an arbitrary time, independent of the clock process. That is precisely what
`Cyclesim` cannot express, as recorded in [`dune-project`](../dune-project) and the
[P2 implementation record](p2-implementation.md).

## 5. Agreeing on what a cycle is

The event-driven simulator has no built-in notion of a cycle, so step_testbench defines one.
`Simulation_step` is the knob, and it is the single most important setting when results from
the two engines are to be reported side by side.

- **`cyclesim_compatible`** (the default) — set inputs, wait for the falling edge, read
  outputs as `before_edge`; wait for the rising edge, read outputs as `after_edge`. This
  reproduces the Cyclesim before/after-edge model and is what makes a shared testbench
  actually agree between engines.
- **`rising_edge`** — set inputs, wait for the rising edge, read once. `before_edge` and
  `after_edge` become the same value.

Use `cyclesim_compatible` for anything whose results are compared against existing
`Cyclesim` evidence. If a ported testbench disagrees between engines, check this first,
before suspecting the DUT.

The imperative event-driven variant additionally lets `cyclesim_compatible` take
`?before_edge` and `?after_edge` callbacks, which is the natural place to sample monitors at
the two points [verification.md](verification.md) section 3 distinguishes.

## 6. Limits that affect the P2.2/P2.6 harness

**The step_testbench event-driven backend is two-state only.** Both
`functional_event_driven_sim.ml` and `imperative_event_driven_sim.ml` begin with
`include Hardcaml_event_driven_sim.Two_state_simulator`. `Four_state_logic` exists in
`hardcaml_event_driven_sim` and is reachable as `Four_state_simulator` and
`With_interface(Four_state_logic)(I)(O)`, but **not through step_testbench**.

This matters because the P2.2 scope note in [phase_plan.md](phase_plan.md) gives three
reasons for adopting the event-driven simulator — a real time axis, transport delays, and
four-state values for an unresolved sampling window — and step_testbench delivers the first
two but not the third. The choice is therefore explicit rather than incidental:

- Phase sweeps and narrow pulses with a shared, portable testbench body: use
  `Functional.Event_driven_sim`, two-state.
- An unresolved or X-valued sampling window: write raw event-driven processes against
  `Four_state_simulator`, outside step_testbench, and give up the shared body for those
  cases.

Conveniently, `Two_state_logic.t = Hardcaml.Bits.t`, so `Bits.vdd` / `Bits.gnd` and the
existing observation helpers in [`observation.ml`](../test/observation.ml) carry over to the
event-driven side without conversion.

**`Sim_mode.Hybrid` is a different axis and should not be conflated with this one.**
`hardcaml_event_driven_sim`'s `Config.sim_mode` is `Evsim | Hybrid of Hybrid_sim_options.t`.
Hybrid uses `Clock_domain_splitting.group_by_clock_domain` to carve the circuit into clock
domains and simulate some of them with Cyclesim as combinational ops embedded inside the
event simulation. That is dual-engine on the *DUT*, for speed, and is independent of which
step_testbench backend the testbench uses.

## 7. Version notes for this switch

Per the workspace [CLAUDE.md](../../CLAUDE.md), the `.mli` files under
`~/.opam/5.2.0+ox/lib/` are authoritative for what is installed; the `~/devel/jane`
checkouts sit on `master` and are not the same version. Two differences are worth knowing
before writing against the checkouts:

- **`hardcaml_step_testbench`**: the installed version carries OxCaml mode annotations that
  `master` does not. Every occurrence of `Handler.t` is `Handler.t @ local` — in `start`,
  `cycle`, `delay`, `spawn`, `wait_for`, `forever`, `never`, and every `testbench:`
  callback. Practically, **the handler cannot escape**: it cannot be stored in a ref, a
  record, or a closure that outlives the step. A harness that wants to hand the handler to a
  driver or monitor object must pass it down each step instead of capturing it. Code copied
  from the `master` checkout may not typecheck.
- **`hardcaml_event_driven_sim`**: essentially identical, with one signature difference —
  `create_clock` takes `here:[%call_pos]` installed versus `?here:Stdlib.Lexing.position` on
  `master`.

## 8. What this means for the harness

The dependency work is already done: both `hardcaml_step_testbench` and
`hardcaml_event_driven_sim` are declared `:with-test` in [`dune-project`](../dune-project)
and listed in [`test/dune`](../test/dune). What remains is convention, not wiring.

Points to settle when the harness is written:

1. **Write testbench bodies against `Functional.Make(I)(O)`**, not against a backend module,
   so the same body can be run on either engine. Keep the backend choice in the runner.
2. **Default to `cyclesim_compatible`** so event-driven results are comparable with the
   existing `Cyclesim` evidence in [`test_primitives.ml`](../test/test_primitives.ml).
   Reserve `rising_edge` for cases that explicitly do not need the two sampling points.
3. **Decide per test which engine runs it.** Cyclesim remains correct and faster for
   everything that only changes inputs on cycle boundaries; the event-driven runner is for
   the P2.2 phase sweeps and the P2.6 event-to-core-decision-to-pin measurement.
4. **Keep the handler local.** See section 7 — this constrains how drivers and monitors are
   structured, and is cheaper to accommodate now than to retrofit.
5. **Treat four-state as a separate decision**, per section 6, rather than assuming the
   step_testbench adoption delivers it.
6. **Settle the seed and failure-artifact convention first**, as the P2.2 scope note says.
   [`replay.ml`](../test/replay.ml) already records the fields; the event-driven runner needs
   to report a time as well as an edge index, and that belongs in the convention rather than
   being added afterwards.

## 9. A note on the upstream README

`hardcaml_step_testbench/README.md` describes the library as "a monad for interacting with
`Hardcaml.Cyclesim` based simulations". Both halves are stale, and the file's own later
paragraphs contradict it. The API is no longer monadic — it is direct-style over OxCaml
effects (`Digital_components.Step_effect`, hence the upstream `test_effectful*.ml`
filenames), and `cycle h inputs` returns outputs directly with no bind. It is not
Cyclesim-only, as sections 1 through 5 above describe. Read the `.mli` files rather than the
README.
