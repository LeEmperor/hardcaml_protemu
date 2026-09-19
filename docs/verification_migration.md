# Verification suite migration

Status: in progress on 2026-09-19. Baseline capture, the functional-model rename,
suite reorganization, cycle/event adapter conformance, and the timed `Input_events`
pilot are complete; four-state properties are not implemented.

This is a temporary implementation guide. [verification.md](verification.md) owns
the current-state inventory, target architecture, model/driver/monitor contracts,
backend responsibilities, and evidence map. Keep lasting decisions there. Remove
this guide after its exit checks pass and the actual paths/status are incorporated
into that document. Do not interpret a checked documentation task as test evidence.

## Sequence and preservation rules

Effort recommendations below are task-specific judgments for GPT-5.6 Sol, not
measured performance guarantees. Use medium to preserve an established contract
and high to establish uncertain semantics or diagnose interacting failures. Scope
each run to a stage or coherent substep and its exit checks.

Migrate in small reviewable steps. Establish the baseline, perform mechanical naming
and layout work, then introduce timed behavior. Do not combine changed expectations
with test relocation. Preserve directed cases, seeds, comparison semantics, and the
controlled-failure fixture. Keep all active regressions running during migration;
a relocated old test is not superseded until its assertions have an identified home.

The existing worktree may contain unrelated changes. Preserve them and record the
source/diff used for baseline results. Commits are left to the repository owner.

### 1. Capture the baseline

**Recommended effort: Sol 5.6 medium.** Inventory and reproduce existing evidence;
escalate if baseline failures require investigation across module boundaries.

- [x] Record the current revision/diff, switch/dependency versions, commands, and
  test results before source edits. Run the current `dune runtest` via
  `./scripts/with-switch.sh`; run `dune build @rtl` with the required host tools.
  Record unavailable tools as not run, not pass.
- [x] Inventory each directed case and property by block and obligation, using the
  evidence map in verification.md. Current baseline: 95 reference expect tests,
  four RTL/harness expect tests, and 29 directed `%test_unit` tests; the pin-bank
  Quickcheck driver is exercised inside an expect test.
- [x] Preserve pin-bank validity rules, pre/post-edge behavior, rejection/conflict
  semantics, deterministic reproduction, and prerequisite/failure-preserving shrinking.

Exit: a repeatable baseline and a case-to-destination inventory, not just test counts.

#### Baseline record — 2026-09-19

This baseline was captured before migration source edits at commit
`46f02193e752dae3115be2eeb5e098d5cab111c2` (`time to migrate the verif suite to
something more suiteable`). `git status --short` was empty, so the tested source
has no local diff to preserve. Later results must name their own revision and diff;
this record must not be reused after source changes.

| Item | Recorded value |
| --- | --- |
| Switch | `5.2.0+ox` |
| OCaml package | `5.2.0` |
| Dune | `3.24.2` |
| Jane Street preview packages | `core`, `core_unix`, `base_quickcheck`, `splittable_random`, `jane_rope`, `hardcaml`, `hardcaml_event_driven_sim`, `hardcaml_step_testbench`, `hardcaml_waveterm`, `ppx_expect`, `ppx_hardcaml`, `ppx_jane`, and `ppx_js_style`: `v0.18~preview.130.106+341` |
| Other test dependencies | `hardcaml_asic` `0.1.0`; `alcotest` `1.9.0+ox` |
| Development tools | `ocamlformat` `0.26.2+ox2`; `ocaml-lsp-server` `1.19.0+ox2` |
| Functional/reference and Cyclesim regression | `./scripts/with-switch.sh dune runtest --force` exited 0; 95 reference expect tests, four harness expect tests, and 29 directed `%test_unit` tests passed |
| Emitted RTL tier | `./scripts/with-switch.sh dune build @rtl` not run: `iverilog`, `vvp`, `verilator`, and `yosys` were all unavailable on `PATH`; this is no RTL-tier pass |

The unforced command required by the checklist, `./scripts/with-switch.sh dune
runtest`, also exited 0. The forced result above is the reproducible result because
it did not rely on Dune's prior inline-test cache.

#### Case-to-destination inventory

Every expect block under the then-current `test/model/` remains independent of
Hardcaml and moves with the same basename to `test/f_model/`. The following rows assign every case in
those files to an obligation; the exact expect text is part of the case and must
remain unchanged unless a later stage deliberately changes behavior.

| Source cases | Count | Obligations | Destination |
| --- | ---: | --- | --- |
| `test/model/test_encoding.ml` | 20 | Encoding/decoding and refusal space; program/image layout and bounds; instruction/branch cost; UART, SPI and I²C program behavior; descriptor setup; cycle accounting; arithmetic/flags; queues; repeated-frame cost | `test/f_model/test_encoding.ml` |
| `test/model/test_isa.ml` | 20 | Published layout and consistency; encode/decode and assembler refusals; slots/displacements/program representation; word-space validity; committed P1.4 encoding; UART, SPI and I²C behavior; calls/returns; bad-word halt | `test/f_model/test_isa.ml` |
| `test/model/test_cycle.ml` | 22 | Reset/disable; exact command timing and parameter latching; level/edge waits and timeout priority; event set/ack/overflow; periodic timing; latency-one program-store behavior and instruction validity; run/write/stop/abort/single-step boundaries | `test/f_model/test_cycle.ml` |
| `test/model/test_mechanisms.ml` | 22 | Pin masking/open-drain/range/ownership/conflict; descriptor validation, phase, pin-role and direction rules; FIFO blocking/nonblocking/order/abort/width rules | `test/f_model/test_mechanisms.ml` |
| `test/model/test_firmware.ml` | 11 | UART, SPI and stretched-clock I²C waveforms; descriptor equivalence; peer timeout/ack/address behavior; refused/stalled runs; construction refusal; helper operation and latency accounting | `test/f_model/test_firmware.ml` |

The 29 directed RTL cases and the four harness properties have these individual
owners. A combined case may be split only if every named obligation remains active.

| Current case | Obligation | Destination/owner |
| --- | --- | --- |
| P2.1 masked commits, claims, conflict, and release | Pin writes, ownership, refusal and release | `test/primitives/pin_bank/` |
| P2.1 pin commits and ownership track the independent model | Pin-bank model agreement | `test/primitives/pin_bank/` |
| P2.1 open drain commit never drives a high | Open-drain safety | `test/primitives/pin_bank/` |
| P2.1 reset and disable release driven pins | Reset/disable pin release | `test/primitives/pin_bank/` |
| P2.2 synchronizer, set-wins acknowledge, and overflow | Synchronizer and sticky-event priority | `test/primitives/input_events/` |
| P2.2 snapshots and sticky events track the independent model | Input-event cycle agreement | `test/primitives/input_events/` |
| P2.3 exact delay, immediate level, stale edge, and timeout precedence | Timer/wait timing and priority | `test/primitives/timing/` |
| P2.3 periodic ticks continue during waits and restart from an event | Periodic timer behavior | `test/primitives/timing/` |
| P2.3 waits and periodic ticks track the independent machine | Timing model agreement | `test/primitives/timing/` |
| P2.3 an active transfer advances while the core timer waits | Concurrent timer/transfer integration | `test/integration/primitive_demo/` |
| P2.4 full simultaneous pop/push preserves byte order | FIFO full-boundary ordering | `test/primitives/byte_fifo/` |
| P2.4 simultaneous queue operations track the independent model | FIFO model agreement | `test/primitives/byte_fifo/` |
| P2.4 overflow and reset validity | FIFO overflow and reset outputs | `test/primitives/byte_fifo/` |
| P2.4 all configured FIFO depths preserve ordering | FIFO configuration sweep | `test/primitives/byte_fifo/` |
| P2.5 internal lane preloads, clocks, samples, and completes | Shift-lane sequencing | `test/primitives/shift_lane/` |
| P2.5 invalid descriptor and missing TX data never drive pins | Invalid/missing-input safety | `test/primitives/shift_lane/` |
| P2.5 receive-only overrun aborts and invalid data width is refused | Shift error/refusal behavior | `test/primitives/shift_lane/` |
| P2.5 pin conflict and 32-bit boundary | Shift ownership and width boundary | `test/primitives/shift_lane/` |
| P2.6 observed edges pace a preconfigured lane and abort releases pins | Observed-transfer pacing and abort | `test/primitives/observed_transfer/` |
| P2.6 arm latches parameters and starts only on a later event | Arm/start boundary and latching | `test/primitives/observed_transfer/` |
| P2.5/P2.6 shift timing and results match the independent model | Integrated lane/observer model agreement | `test/primitives/observed_transfer/` |
| P2.6 synchronized start and pacing use the same input snapshot | Synchronized sampling boundary | `test/primitives/observed_transfer/` |
| P2.7 independent 8N1 receiver sees idle, start, data, and stop | UART wire waveform | `test/primitives/uart_tx/` |
| P2.7 typed UART descriptor matches hardware frame trace | UART descriptor/model agreement | `test/primitives/uart_tx/` |
| Fetch reads the program store through one latency-one port | Core fetch/store latency contract | `test/core/protocol_core/` |
| RUN in the cycle of the last write never consumes its unspecified output | Core instruction-validity boundary | `test/core/protocol_core/` |
| Load requests are refused while running and STOP halts at a boundary | Core load/run/stop arbitration | `test/core/protocol_core/` |
| P0 pin/timer command commits at k+n | Wrapper-visible command latency | `test/integration/wrapper/` |
| P0 rejects delay zero and disable aborts safely | Wrapper-visible refusal and abort | `test/integration/wrapper/` |
| The checker keeps unavailable, unspecified and defined apart | Generic observation validity and required-observation failures | checker tests under `test/common/` |
| A directed pin-bank scenario, edge by edge | Pin-bank pre/post-edge transcript, writes, claims, refusal/conflict, open drain and disable | `test/primitives/pin_bank/pin_bank_expect_tests.ml` |
| Bounded scenarios agree with the independent model | Pin-bank generated model agreement; recorded seed `20260919`, 200 trials, size 24 | `test/primitives/pin_bank/pin_bank_unit_quickcheck_tests.ml` |
| A controlled mismatch is found, shrunk, and reproduced from its seed | Failure identity, reset prerequisite, shrink, replay and report determinism; recorded fixture seed `20260919`, 64 trials, size 12 | harness/replay tests under `test/common/`, retaining a pin-bank fixture |

The `@rtl` rules remain in `tinytapeout/test/`: wrapper and UART compile/simulate
rules using `iverilog`/`vvp`, wrapper lint using Verilator, and the generic wrapper
synthesis smoke test using Yosys. They are distinct evidence and do not move into
the OCaml suites.

The preservation ledger for later stages is therefore concrete:

- Keep the pin-bank required pre-edge held observations and required post-edge
  registered observations. Keep `reject_reason` declared but unavailable on the
  DUT side until RTL exposes it; do not silently promote, erase, or coerce it.
- Keep the one-edge rejection pulse and sticky conflict behavior, including the
  case where a request touches another owner's pin but is refused for another
  reason. Preserve open-drain resolution and reset/disable release behavior.
- Keep fresh DUT/model/monitor state per generated trial, recorded seeds and
  settings, environment-override behavior, and working Dune rerun commands.
- Keep the controlled `Ignore_open_drain` failure. Shrinking must retain the reset
  prerequisite and the same phase/observation/reason failure identity, and rerunning
  the seed/settings must reproduce the first mismatch.

### 2. Rename the functional model

**Recommended effort: Sol 5.6 medium.** Mechanical naming and dependency updates
with unchanged behavior and existing regression checks.

This is a source/API naming change, not a change of reference behavior.

| Current | Target |
| --- | --- |
| `model/` | `f_model/` |
| `test/model/` | `test/f_model/` |
| Dune library `protemu_model` | `protemu_f_model` |
| Wrapped OCaml module `Protemu_model` | `Protemu_f_model` |
| Test library `test_protemu_model` | `test_protemu_f_model` |
| Shared environment role `Device.Model` | `Device.F_model` |
| Per-suite reference adapter `Model` | `F_model` where it denotes the functional predictor |

- [x] Move directories and update Dune library names/dependencies and all qualified
  OCaml references in one buildable step. The Dune library rename changes the
  generated wrapped module name; moving directories alone is insufficient.
- [x] Rename the environment role and its consumers consistently. `Reference` may
  remain a local alias to `Protemu_f_model.Pin_bank`; do not mechanically rename
  every occurrence of the English word “model”.
- [x] Classify helpers before renaming them: `Program_store_model` is a memory-contract
  stand-in, not the architectural predictor. Give helpers descriptive names such
  as `Program_store_stub` if useful; peer and sampling models retain their distinct roles.
- [x] Update source headers/comments, active documentation paths, commands, scripts,
  library references, and diagnostic wording that names the renamed components.
  Update expect output only for deliberate naming changes, not behavioral changes.
  Historical reports may keep old names if clearly identified as historical.
- [x] Keep `isa/` and `Protemu_isa` unchanged. Keep `f_model/` and its standalone tests
  free of Hardcaml and simulator dependencies, and outside RTL source lists.
- [x] Search for stale `Protemu_model`, `protemu_model`, `test_protemu_model`, and old
  path references; inspect matches rather than globally replacing substrings.
  Build and run reference plus RTL comparisons after the rename.

Exit: the same reference behavior and test results under the new names, with working
commands and links. Compatibility aliases are unnecessary unless an actual consumer
requires them; any temporary alias needs a removal condition.

#### Rename result — 2026-09-19

The rename was performed from commit
`46f02193e752dae3115be2eeb5e098d5cab111c2`, on top of the baseline-record
documentation diff above. No compatibility aliases were needed. The suite still
contains 95 standalone functional-model expect tests, four harness expect tests,
and 29 directed `%test_unit` tests.

`./scripts/with-switch.sh dune build @all` and
`./scripts/with-switch.sh dune runtest --force` both exited 0 after the rename.
The focused commands `dune runtest test/f_model --force` and
`dune build @f_model/lint @test/f_model/lint` also exited 0 through the switch wrapper.
`./scripts/with-switch.sh dune build @rtl` exited 0 after the host tools were
installed: Icarus Verilog 12.0 (including `vvp`), Verilator 5.020, and Yosys 0.33.
The P0 wrapper and P2 UART emitted-RTL simulations passed, as did wrapper lint and
the generic synthesis smoke test. This later result does not rewrite the historical
pre-migration baseline above. `dune build @fmt` continues to report repository-wide
pre-existing format differences, including files untouched except for their
directory move; `git diff --check` reports no whitespace errors in this migration diff.

### 3. Organize by primitives, core, and integration

**Recommended effort: Sol 5.6 medium.** Move and extract existing tests while
preserving their contracts. Use high if extraction exposes missing semantics or
requires redesigning the shared harness.

| Current source | Destination/responsibility |
| --- | --- |
| `test/observation.ml`, `replay.ml`, `env.ml` | `test/common/`, initially preserving cycle-runner behavior |
| `test/pin_bank_env.ml` | `test/primitives/pin_bank/pin_bank_testbench.ml` |
| `test/test_pin_bank_harness.ml` | Pin-bank expect/property files; generic checker/replay fixtures under `test/common/` tests |
| `test/test_primitives.ml` | Per-DUT directories under `test/primitives/` (pin bank, input events, timing, FIFOs, shift lane, observed transfer, UART) |
| `test/test_protocol_core.ml` | `test/core/protocol_core/`, including its local program-store stub |
| `test/test_hardcaml_protemu.ml` | `test/integration/wrapper/` |
| `test/f_model/*` | Retains independent reference-only tests in place |
| `tinytapeout/test/*` | Remains the emitted-RTL tier |

- [x] Give each block a `*_testbench.ml`, `*_expect_tests.ml`, and
  `*_unit_quickcheck_tests.ml` as applicable. Add timing/four-state files only when
  that block has an obligation requiring them.
- [x] Extract drivers/scenarios/observations once into the block testbench. Both
  expect and generated cases call its entry points. Keep references independent
  of DUT helpers; do not copy RTL expressions to manufacture expected results.
- [x] Create a shared support library and per-suite Dune libraries with unique
  names. Keep generic harness tests separate from support code, and reference-only
  dependencies separate from Hardcaml dependencies. Avoid a parent stanza owning
  modules that a child stanza also owns.
- [x] Preserve the installed ppx_expect workaround:
  `(inline_tests (flags (:standard -source-tree-root .)))`, with its explanatory
  comment, in new inline-test stanzas until the underlying issue is resolved.
- [x] Update replay test-directory configuration and verify printed rerun commands
  work after moves. Preserve environment overrides and deterministic fixtures that
  explicitly disable overrides. Test artifact paths from Dune runner directories.
- [x] Keep existing directed assertions active; introduce compact expect transcripts
  and meaningful generated properties incrementally rather than replacing useful
  assertions with snapshots solely for uniformity.

Exit: every old case has an active owner, no duplicate/missing Dune ownership, and
per-module tests and their printed replay commands work.

#### Reorganization result — 2026-09-19

The reorganized source is based on commit
`a84d9b86e539b97cd5949e80a78c1f02c3a815b7`; the verification below also includes
the current follow-up diff that formats the split files, places their shared opens
before the tests, updates active documentation, and adds the artifact-path check.

The shared `Observation`, `Replay`, and `Env` modules now form the unwrapped
`protemu_test_common` support library under `test/common/`; its checker and replay
fixtures are a separate inline-test library. Each primitive, core, and integration
directory has a uniquely named Dune library and a block testbench. The pin-bank
testbench remains the single definition used by its directed transcript and bounded
generated comparison, while the controlled defect stays in the generic replay tests.
The remaining directed tests retain their original assertions in block-owned files.

All 29 directed `%test_unit` cases and four pre-existing RTL/harness expect tests
remain active; one new common expect test checks artifact paths and cleanup from a
Dune runner directory.
the 95 independent functional-model expect tests remain in `test/f_model/`.
`./scripts/with-switch.sh dune build @all` and
`./scripts/with-switch.sh dune build @lint`,
`./scripts/with-switch.sh dune runtest --force`, and
`./scripts/with-switch.sh dune build @rtl` exited 0. Focused runs for
`test/common`, `test/primitives/pin_bank`, `test/core/protocol_core`, and
`test/integration/wrapper` exited 0. The replay fixture now prints
`dune runtest test/common --force`; that exact command with its recorded environment
settings also exited 0. No event-driven behavior or test expectation changed in this
stage.

### 4. Establish cycle/event adapter conformance

**Recommended effort: Sol 5.6 high.** Establish scheduling and sampling semantics
through experiments, including the installed implementation/comment discrepancy.

- [x] Keep the current cycle runner and its pre/post-edge checks operational.
  Extract only reporting/checking/scenario facilities that the event pilot actually needs.
- [x] Specify time unit, clock phase/period, reset sequence, settle points, and
  coincident-event ordering before implementing timed scenarios. Include time/edge
  budgets and cancellation/termination behavior.
- [x] Characterize a tiny register and ready/valid circuit on both backends. Verify
  input application, reset, pre-edge acceptance, settled registered outputs, timeout,
  and completion. The installed `cyclesim_compatible` implementation/comment
  disagree about edge order; establish behavior experimentally rather than copying
  the former documentation's assumption.
- [x] Use step-testbench only where it helps author concurrent two-state stimulus.
  Keep its handler lifetime local. Drive the Evsim clock and asynchronous pads from
  scheduler processes with explicit ownership. No producer advances time privately.
- [x] Reuse a small set of known synchronous scenarios to compare adapters;
  benchmark startup and representative trial costs before deciding regression budgets.

Exit: matching known-value observations at documented sampling points, with a
reproducible result and a measured cost. This does not claim timed feature coverage.

#### Adapter conformance result — 2026-09-19

[`test/common/backend_conformance.ml`](../test/common/backend_conformance.ml) defines
one test-only four-bit register and one-entry ready/valid sink. The same five items load
nonzero state, clear it with synchronous reset, exercise a disabled register edge, accept
an offer, and refuse a later offer after the sink becomes full. The Cyclesim and two-state
Evsim adapters consume the same item values and produce identical known-value before/after
observations. The existing `Env` cycle runner and its dependencies are unchanged; the
conformance library is separate so event-simulator dependencies do not leak into it.

The experiment establishes this adapter contract:

- Evsim time is an abstract integer tick, not a claim about nanoseconds. The clock is
  initially low, has a five-tick half-period and ten-tick period, rises first at time 5,
  and falls at time 10. A dedicated scheduler process is the sole clock owner.
- Synchronous inputs, including reset, are applied at time 0 or immediately after the
  preceding falling-edge sample and remain stable through the next rising edge. The first
  edge loads nonzero state, reset is asserted for the second edge, and it is deasserted for
  the third, proving clear behavior rather than merely observing zero-initialized state.
- `before` is captured when the rising-edge change wakes the step adapter, before the
  register update has propagated through Evsim delta cycles. It therefore carries the
  acceptance decision and old registered state. `after` is read on the following falling
  edge, after the registered state has settled. Five steps return at times 10, 20, 30,
  40, and 50. This observed implementation order is rising then falling; the installed
  interface comment that says falling then rising is not the operative contract.
- A future asynchronous-pad scheduler owns only its declared pad signals. For an event
  specified at the same timestamp as a clock edge, the common event runner must enqueue
  and settle the pad update before enqueueing the clock transition; that case means
  "before the edge." An "after the edge" transition uses a later tick. Producers submit
  timestamps and never call a private delay or simulator step. Scheduled transitions have
  transport semantics, retaining every transition rather than suppressing short pulses.
  Stage 4 has no asynchronous product stimulus, so this is a runner convention to enforce
  in the Stage 5 pilot, not evidence about pad capture.
- The conformance scenario has an eight-step adapter budget and a 51-tick simulator cap;
  it completes in five steps/50 ticks. A separate never-completing fixture is stopped by
  a three-step budget on both backends. Evsim processes wait forever after completion or
  timeout, and the finite top-level run terminates the trial; a fresh simulator is created
  for every run, so no process or handler escapes its trial.

The inline conformance test is run by
`./scripts/with-switch.sh dune runtest test/common --force`. The reproducible microbenchmark
is `./scripts/with-switch.sh dune exec test/common/backend_conformance_bench.exe -- 10000`.
On commit `8fc23f51845cb230db68f99dd5dace4cd90ed0f0` plus the Stage 4 diff, OCaml
`5.2.0+ox`, Linux `6.8.0-139-generic`, and an AMD Ryzen Threadripper PRO 5955WX, it
measured 44.658 microseconds per Cyclesim startup, 50.124 per Evsim startup, 48.159 per
five-edge Cyclesim trial, and 69.864 per five-edge Evsim trial over 10,000 iterations.
These are local regression-budget measurements, not general performance guarantees.

### 5. Pilot timed verification on `Input_events`

**Recommended effort: Sol 5.6 high.** Establish independent sampling predictions,
timed monitoring, temporal shrinking, and reproducible event scheduling.

- [x] Add timestamped transition scenarios, a two-state Evsim adapter, and an
  independent sampling/reference adapter. Keep raw simulator handles out of `f_model`.
- [x] Sweep transitions before/after edges and across a period, pulses narrower
  than a period, reset timing, and applicable acknowledgement/event interactions.
  State how exactly coincident transitions are ordered and which physical cases
  that digital convention does not establish.
- [x] Check missed/captured pulses and pipeline latency against explicit assumptions.
  Preserve Cyclesim checks for synchronous event priority and state behavior.
- [x] Monitor relevant activity between edges. Report timestamp, time unit, edge,
  seed/trial, source/configuration, first mismatch, and bounded nearby context.
  Add waveform capture only as a useful diagnostic, not a passing-test requirement.
- [x] Extend generated scenarios and shrinking to preserve temporal ordering,
  pulse/window prerequisites, and failure identity. Prove replay with a controlled
  timed mismatch and fresh simulation state per trial.

Exit: actual P2.2 phase/pulse evidence, independently predicted and replayable.

#### Timed `Input_events` result — 2026-09-19

[`input_events_timing_testbench.ml`](../test/primitives/input_events/input_events_timing_testbench.ml)
owns timestamped pad/reset/event scenarios, the two-state Evsim adapter, a simulator-free
sampling predictor, continuous activity monitors, bounded generation, temporal shrinking,
and replay reporting. Each trial constructs a fresh circuit and simulator. The ordinary
functional model still accepts only integer samples at clock edges and has no simulator
handles or timing backend dependency.

One scheduler owns stimulus and clock updates. Time is an abstract integer tick, the
clock rises first at tick 5 and has a 10-tick period, and registered outputs are sampled
one tick after each rising edge. Stimulus at an exact rising-edge timestamp is submitted
first and given a bounded 32-delta settle allowance before the clock transition; it is
therefore defined as before-edge stimulus. A transition at the following tick is after
that edge. All scheduled transitions have transport semantics. This ordering establishes
a deterministic digital case only: it is not setup/hold, metastability, analog pulse, CDC,
or physical timing evidence.

The complete integer-phase sweep observed 10 through 19 ticks from a high transition to
the reported synchronized rising edge. Equivalently, a value sampled at one edge becomes
the registered snapshot/edge result after the following edge. A two-tick pulse crossing a
sampling edge was captured, while an eight-tick pulse wholly between edges was missed.
Thus the digital assumption is sampling-point coverage, not an unconditional sub-period
minimum pulse width; a pulse spanning a full period necessarily covers a sampling edge
under this convention. Directed cases also cover reset before an exact edge and event
set/acknowledge/overflow priority. The existing Cyclesim tests remain active.

The normal property runs seed `20260919`, 160 trials, and maximum size 18. Scenarios keep
an applied reset and a bounded pulse window. Shrinking removes transitions, moves them
earlier without reordering them, and shortens the run only while those prerequisites and
the same phase/observation failure identity survive. The controlled
`Delay_pad_transitions_one_tick` adapter defect is found on trial zero, shrinks to reset
plus an exact-edge two-tick pulse, and produces the same redacted report on a second run
from the recorded settings. Reports include source/configuration, timestamp/unit, edge,
first mismatch, nearby samples, and between-edge activity. No waveform is required for a
pass; the bounded textual trace is sufficient for this pilot.

Run the pilot with
`./scripts/with-switch.sh dune runtest test/primitives/input_events --force`. On commit
`989f7a6acc7b8e72c5380f07a1ea3845c79f1d87` plus the Stage 5 diff, the focused suite and
its lint alias exited 0. `dune build @all @lint`, the full forced `dune runtest`, and
`dune build @rtl` also exited 0 through the switch wrapper. The controlled report's
recorded seed/trial/size rerun of the `test/primitives/input_events` directory exited 0.
`dune build @fmt` still reports the repository-wide pre-existing format differences
recorded in Stage 2; both new timing files themselves were formatted with the pinned
formatter, and `git diff --check` exited 0.

### 6. Add one justified four-state property

**Recommended effort: Sol 5.6 high.** Define and validate X/Z observation semantics,
injection assumptions, and a property that cannot pass through accidental coercion.

- [ ] Name the property first (for example, specified recovery after a bounded
  unknown pad sample). Specify injection site, duration, resolution, allowed
  observations, and deadlines. Do not infer metastability behavior from X support.
- [ ] Use direct four-state Evsim processes behind a suite adapter; preserve X/Z in
  observations. Keep validity metadata separate, and fail unexpected unknowns on
  required known outputs. Do not convert X into integer zero or `Unspecified`.
- [ ] Use ordinary `f_model` predictions for known-value behavior and a dedicated
  property/sampling model for the X-sensitive part. Check raw bus resolution with
  explicit drivers/pull-ups if bus resolution is the selected obligation.
- [ ] Include an intentional controlled violation to show the X-aware check fails
  for the intended reason. Record replay and runtime costs.

Exit: one meaningful four-state property with positive and controlled-negative
checks. If no contract justifies a property yet, record it as deferred rather than
inventing a physical model or claiming four-state coverage.

### 7. Extend to the integrated path and regression policy

**Recommended effort: Sol 5.6 high** for integrated event-to-core-to-pin behavior
and failures spanning modules. Use medium for subsequent module migrations that
follow a proven adapter pattern and for mechanical CI/alias wiring.

- [ ] Reuse the timed facilities for `Observed_transfer` and the integrated
  P2.6 event-to-engine/core-decision-to-pin path when that integration exists.
  Compare actual timestamps and independently reconstructed pin transactions.
- [ ] Extend core and integration suites with load/readback/fetch arbitration,
  instruction validity, image bounds, interruptions, and recovery as implemented.
  Link `hardcaml_asic` memory conformance rather than duplicating that library suite.
- [ ] Keep bounded functional and timed regressions visible in normal CI; expose
  explicit aliases for longer sweeps and four-state suites. Document actual alias
  names and commands once implemented, and ensure CI invokes every required tier.
  Do not let an optional alias silently remove required evidence from regression.
- [ ] Record which requirements each property exercises; retain named holes.
  Capture dependency/tool identity and the actual local diff needed for replay,
  beyond the current revision/dirty-status fields.

Exit: the evidence map names implemented suites, commands, assumptions, and remaining
physical/CDC/reset/formal obligations without treating one layer as proof of another.

## Final checks and retirement

**Recommended effort: Sol 5.6 medium.** Run established checks, refresh evidence
and paths, and retire the guide. Use high for unresolved semantic failures or a
review of whether the combined suites leave gaps at their boundaries.

- [ ] Run build, lint/format checks appropriate to source changes, all affected
  inline suites, the required event/four-state tiers, and `@rtl` with host tools.
- [ ] Exercise printed reproduction commands after all path and library changes.
- [ ] Verify independent reference dependencies, required observations, no silent
  X coercion, finite budgets, and no removed assertions without replacements.
- [ ] Refresh verification.md's current-state inventory, paths, backend version
  notes, commands, and evidence map from the implemented tree. Keep target items
  separate where work remains; never promote plans to recorded evidence.
- [ ] Remove obsolete migration-only text and this guide once all applicable work
  is complete, updating the documentation index and inbound links. Any deferred
  obligation must remain explicitly tracked in verification.md/phase_plan.md.
