# System verification

Status: current implementation updated on 2026-09-21 after the P3.5 independent
hardware loader and wrapper serial peer, the P3.4 host/simulator
workflow, P3.3 integrated core/mechanisms and loaded core-decision path, P3.2 executable
control core, P3.1 program-store integration, independent load/access and execution models,
generated core regression, functional-model
rename, per-block suite reorganization, cycle/event adapter conformance experiment,
timed `Input_events` pilot, one four-state `Input_events` property, the timed P2.6
event-to-engine path, the observed-transfer/pin-bank composition, and the integrated P2.7
UART-slice suite. Resolved-bus four-state behavior, physical host transport, and the
physical obligations below remain unimplemented.

This is the enduring source of truth for verification architecture, suite ownership,
current evidence, and the intended next state. It incorporates the former test
architecture survey and step-testbench backend notes. The temporary
[verification migration guide](verification_migration.md) sequences the work;
[phase_plan.md](phase_plan.md) tracks product milestones. The
[construction plan](construction-plan.md) owns hardware contracts, and
[flow.md](flow.md) owns physical-flow execution. Those documents link here for
verification policy rather than maintaining another test architecture.

### Agent execution constraints

Every `dune build` and `dune runtest` call must include `-j 5`, including focused or
forced reruns and calls through scripts. Run them sequentially to avoid multiplying
the workload; this server has experienced crashes under heavy workloads. Use `-j 5`
on `dune exec` commands that generate or verify artifacts as well. Apply this rule when
executing examples below even where historical command records omit the flag; historical
records describe what ran at the time and are not rewritten.

Agents must not create or amend commits. Only the repository owner commits. Return
source changes and verification evidence uncommitted; do not stage changes unless
requested, except for index updates inherent in an explicitly planned `git mv`/`git rm`.

### Host-link migration preservation rule

[host_link_migration.md](host_link_migration.md) owns the planned structural migration
and [organization_migration.md](organization_migration.md) its initial file move.
The independent `tinytapeout/test/p3_loader_tb.v` peer must retain its own constants,
frame construction, CRC, and expected responses. Do not derive them from the planned
OCaml `Wire` library or RTL helpers. As with `f_model/` independence from RTL, this
prevents one shared implementation mistake from satisfying both sides of a comparison.
Shared-wire OCaml tests supplement, rather than replace, all three emitted-RTL peer
tiers and their existing obligations.

HL4 establishes cycle-observed serial behavior against the unsplit loader before
extracting blocks. Each extraction must preserve offer/completion timing, cancellation,
correlation, replay, and final-fall commit, with focused tests for the new boundary.
Record exact synthesis tool/configuration identity and cell-count deltas; investigate
nonzero deltas instead of accepting an unspecified noise allowance. These are planned
acceptance gates, not claims that the codec, harness, or split blocks already exist.

## Current state

Paths in this section describe files that exist now. The rename to `f_model`, per-block
suite layout, backend sampling characterization, timed P2.2 and P2.6 paths, P3.2 control
execution, and one named four-state P2.2 property are implemented. A core-to-pin timed
path and a stateful simulator host workflow are implemented; a resolved-bus four-state
suite is not.

### Backend and test inventory

| Question | Answer |
| --- | --- |
| OCaml RTL simulation backend | Synchronous product suites use `Hardcaml.Cyclesim`; timed P2.2 and P2.6 use two-state Evsim, as does the isolated conformance fixture. Emitted-Verilog checks use separate tools. |
| `hardcaml_step_testbench` | Used by the isolated cycle/event adapter conformance suite; production block suites have not migrated to it. |
| `hardcaml_event_driven_sim` | Two-state Evsim is exercised by adapter conformance and the timed P2.2/P2.6 product suites. Four-state Evsim is exercised by the P2.2 unknown-pad property and nothing else. |
| `hardcaml_waveterm`, `alcotest` | Declared `:with-test` but unused. No waveforms are produced and no Alcotest suite exists. |
| Test styles | Directed expect/unit tests, three model/RTL Quickcheck environments, and one bounded UART-slice property built on `base_quickcheck`; explicit aliases rerun selected generators with larger budgets. |
| Blocks on the shared harness | One: P2.1 `Pin_bank`. Everything else still runs its own loop. |

The conformance fixture is evidence about adapter scheduling only; a declared dependency
or a synthetic fixture is not evidence for a product obligation.

### Existing evidence layers

The suite has an independent model library, per-suite RTL test libraries, and a Verilog tier,
deliberately kept apart so that a disagreement between two of them is evidence rather than a shared mistake.

| Layer | Library | Depends on Hardcaml | Contents |
| --- | --- | --- | --- |
| Reference model | `test_protemu_f_model` ([`test/f_model/`](../test/f_model/dune)) | No | 96 expect tests over [`f_model/`](../f_model/dune). |
| Model/RTL comparison and backend conformance | uniquely named libraries under [`test/common/`](../test/common/dune), [`test/primitives/`](../test/primitives), [`test/core/`](../test/core), and [`test/integration/`](../test/integration) | Yes, except generic support | Directed cycle product tests, cycle harness expect tests, adapter conformance, timed P2.2/P2.6 product tests, and the targeted P2.2 four-state property. |
| Emitted RTL | none — Dune rules | n/a | iverilog, verilator and yosys checks behind `dune build @rtl`. |

#### Model tests — `test/f_model/`

Pure OCaml against the independent execution model, with no Hardcaml dependency at
all; [`test/f_model/dune`](../test/f_model/dune) states why, and it is the same reason
`f_model/` sits outside `lib/`.

| File | Expect tests | Covers |
| --- | --- | --- |
| [`test_encoding.ml`](../test/f_model/test_encoding.ml) | 20 | P1.4/P1.5 instruction encoding and the assembler's refusals. |
| [`test_isa.ml`](../test/f_model/test_isa.ml) | 20 | Instruction semantics against the reference machine. |
| [`test_cycle.ml`](../test/f_model/test_cycle.ml) | 22 | The P1.5 core schedule, edge by edge. |
| [`test_mechanisms.ml`](../test/f_model/test_mechanisms.ml) | 22 | Pin bank, FIFOs, transfers, faults and events in the model. |
| [`test_firmware.ml`](../test/f_model/test_firmware.ml) | 11 | Bit-banged UART/SPI/I²C firmware sequences. |

[`harness.ml`](../test/f_model/harness.ml) is 88 lines and deliberately thin: `reset`,
`step`, `steps`, `load`, and three printers. One call is one rising edge, so a test
body reads as a cycle-by-cycle transcript and "the next edge" is literally the next
line. `show` prints registered state and the record of the edge just taken, never a
recomputed value, so an expect block is evidence about the model rather than about
the printer. These are the conventions `Env` later formalised.

#### Model/RTL comparison — `test/`

Two styles coexist here, and the split is the current migration boundary.

**The directed `%test_unit` layer** is still the majority of the RTL evidence. The
original 29 cases retain their assertions in block-owned files; later core and timed
integration cases extend them:

| File | Tests | Covers |
| --- | --- | --- |
| [`test/primitives/`](../test/primitives) | 55 | P2.1 to P2.7 inline directed, expect, generated, timed, and four-state cases: pin bank, input events, timing, FIFOs, shift lane, observed transfer, and UART. |
| [`primitive_demo_unit_tests.ml`](../test/integration/primitive_demo/primitive_demo_unit_tests.ml) | 1 | Concurrent timer/transfer integration. |
| [`test/integration/observed_transfer_bank/`](../test/integration/observed_transfer_bank) | 13 | Real pin-bank reservation/commit/cleanup, software arbitration, phase-swept standalone-versus-bank timing, boundary peer checks, interruption/rearm, and a 24-trial fixed-seed property. |
| [`uart_slice_unit_tests.ml`](../test/integration/uart_slice/uart_slice_unit_tests.ml) | 13 | P2.7 frame, ownership/timer/bank status, pin isolation, completion/release, receiver negatives, model agreement including an overridden period, and the saved-trace expect block. |
| [`test/core/protocol_core/`](../test/core/protocol_core) | 14 | P3.1a has twelve directed load/access/fetch cases and two generated/replay expect tests. RTL is compared cycle by cycle with independent [`Program_access`](../f_model/program_access.ml) control and a local 1RW contract store under three unspecified-output policies. |
| [`test/core/control_execution/`](../test/core/control_execution) | 25 | P3.2 exhaustive base-word legality/extension classification, directed local-execution/model agreement, all condition/loop/control paths, mechanism handshakes and collisions, faults, lifecycle/bounds, and 96 generated assembled-program comparisons at seed `20260920`. |
| [`test/integration/core_engine/`](../test/integration/core_engine) | 17 | P3.3 loaded-program, fixed-seed generated and timed integration: all delegated kinds, independent FIFO/ownership projections, internal/observed transfer, control and event collisions, interruption, background progress, cleanup, engine-idle gating, and the real P2.6b path. |
| [`test/host/`](../test/host) | 5 | P3.4 metadata-bearing image round trips and malformed, image/API/ISA compatibility, bounds, structured refusal/error classification, and distinct control/transfer timeout codes. |
| [`test/integration/host_simulator/`](../test/integration/host_simulator) | 15 backend tests plus 6 CLI cases | P3.4 real integrated-core load/readback/verify, all-or-error image bounds, missing-image and length-mismatch classification, explicit capabilities/`Device` conformance, live and engine-busy access refusal, engine-owned pin conflicts, queue echo/partial resume/full concurrent-pop pressure, STOP timeout, step, post-edge active-transfer ABORT, malformed-program fault recovery, register/flag inspection, deterministic time/pad ordering, exact bounded-trace cursor/loss/clear/order semantics, generated-image diff, actual stateful CLI workflow, and machine-readable failure/transfer-timeout output. |
| [`tinytapeout/test/p3_loader_tb.v`](../tinytapeout/test/p3_loader_tb.v) | 3 emitted-RTL tiers | P3.5 independent serial peer against `Loader_core` plus a contract 1RW store, the adopted wrapper/behavioral `program` resource, and the production synthesis wrapper with explicit-flop RAM. Covers decoded wire records, framing/CRC/overrun, complete-word loading and hardware verification, all-phase timing, validated response replay/commit, reset/disable, protected in-flight state, side-effecting RUN replay, recovery, replacement load/readback/RUN, plus 16 deterministic malformed trials at seed `20260921`. |
| [`test/integration/program_memory_backend/`](../test/integration/program_memory_backend) | 4 | P0.7/P3.1b checks exact resource records and contract-defined responses, then reruns P3.1a's twelve directed and 240 fixed-seed generated scenarios against both `Single_port_ram` Simulation and explicit-Flops Implementation elaborations. |
| [`wrapper_unit_tests.ml`](../test/integration/wrapper/wrapper_unit_tests.ml) | 2 | The P0 observable wrapper. |

Each builds a `Cyclesim.With_interface` simulator and advances it through an owned cycle
loop. The protocol-core testbench additionally carries its own `Program_store_stub`, a
test-only stand-in for `hardcaml_asic`'s `Single_port_ram` following the program-memory
contract: latency-one reads, output held while disabled, and independently selectable
zero, all-ones, or address-derived values after a write or for a never-written word.
Expected acceptance, port ownership, validity, and state come from the plain-OCaml
`Program_access` model, never from DUT outputs, so these tests stay independent of the
ASIC library and do not encode poison into synthesized logic.

**The P1.6 `Env` harness** is the existing synchronous foundation. Four modules,
none of which reaches `lib/` or `f_model/`:

| Module | Lines | What it is |
| --- | --- | --- |
| [`observation.ml`](../test/common/observation.ml) | 162 | The unavailable/unspecified/defined distinction, named observation sets, and the first-difference checker. |
| [`replay.ml`](../test/common/replay.ml) | 233 | The reproduction record: settings, failing trial, configuration, source identity, rerun command, artifact directory. |
| [`env.ml`](../test/common/env.ml) | 625 | The `Device` signature, the runner, monitor plumbing, the Quickcheck driver, the shrinker, and the failure report. |
| [`pin_bank_testbench.ml`](../test/primitives/pin_bank/pin_bank_testbench.ml) | 696 | P2.1 described once as a `Device`, plus a bounded generator and an injectable defect. |

The four preserved harness expect tests now have explicit owners: checker and replay
fixtures under [`test/common/`](../test/common), and the directed transcript plus
bounded Quickcheck run under
[`test/primitives/pin_bank/`](../test/primitives/pin_bank). A fifth common expect
test checks artifact creation and cleanup from a Dune runner directory.

#### Emitted RTL — `tinytapeout/test/`

Not OCaml. Dune rules under the `@rtl` alias, kept out of `runtest` so the
Hardcaml tests do not require host tools:

- `iverilog -g2012 -Wall` plus `vvp` on [`tb.v`](../tinytapeout/test/tb.v) against
  the committed P0 wrapper;
- the same on [`p2_uart_tb.v`](../tinytapeout/test/p2_uart_tb.v) against the
  generated UART transmitter;
- the independent Verilog receiver in
  [`p2_uart_slice_tb.v`](../tinytapeout/test/p2_uart_slice_tb.v) against the generated
  slice, with its frame trace diffed against the committed model/Hardcaml trace;
- the P3.2 executable core under [`p3_control_tb.v`](../tinytapeout/test/p3_control_tb.v),
  which loads/verifies/runs an `m16` image against an independent latency-one RAM model and
  checks nine fetch plus seven execute cycles;
- P3.1b's verification-only full-interface memory-bearing consumer under
  [`p3_memory_backend_tb.v`](../tinytapeout/test/p3_memory_backend_tb.v), compiled
  separately against emitted behavioral and explicit-flop RTL. It covers RUN/load gating,
  sequential/replacement loads, engine-busy and live-host rejection, priority, bounds,
  latency/hold validity, and stale-response cancellation. The complete generated corpus
  remains on both backend circuits rather than being copied into Verilog;
- `verilator --lint-only` on the wrapper;
- a `yosys` `hierarchy`/`synth`/`stat` smoke test, which is **not** CMOS5L-mapped
  synthesis and is labelled as such in the rule.

### What a block has to supply

An `Env.Device` is a `Config`, an `Item` (one edge's stimulus), a `Dut`, an `F_model`,
a `Monitor`, and the two lists of required observations. The runner calls exactly
five things on the design, in this order, once per edge: `drive`, `settle`,
`pre_edge`, `edge`, `post_edge`. `settle` is `Cyclesim.cycle_before_clock_edge` and
`edge` is the two calls after it, which is how a pre-edge observation exists at all;
nothing else may advance the simulation. `Env.Make` then yields `directed` for an
expect transcript and `quickcheck`/`require_agreement` for generated scenarios.

The pin-bank state reference lives in [`f_model/pin_bank.ml`](../f_model/pin_bank.ml),
not in the testbench. `pin_bank_testbench.ml` adds the port-level acceptance/rejection
contract and sticky conflict behavior without calling RTL implementation helpers.
The adapter reads separate `Before` and `After` output maps; `settle` also invokes
`Cyclesim.cycle_check` before `cycle_before_clock_edge`. Each side has its own monitor
instance, so checking reconstructed items is separate from checking raw values.

### Switches and artifacts

Recorded settings are what the regression runs. These override them without editing
a test, and whatever ran is what the report prints:

| Variable | Effect |
| --- | --- |
| `PROTEMU_SEED`, `PROTEMU_TRIALS`, `PROTEMU_SIZE` | Replace the recorded generator settings; a seed sweep is a loop over the first. |
| `PROTEMU_ARTIFACTS` | The directory a failure report is written to; the default is `protemu-artifacts` beside the runner's working directory. |
| `PROTEMU_SOURCE_REVISION` | The source revision, for a build that cannot be asked through git. |

A test that snapshots one seed's report passes `~environment_overrides:false` and
runs its recorded settings regardless, so a sweep does not fail a fixture for
reporting exactly what it was asked to report.

A failure prints its own rerun command, which is `dune runtest <dir> --force` behind
the settings that produced it: dune's inline runner needs flags and a working
directory dune sets up, so a command naming the executable would be one that does
not work. Artifact file names carry the test, seed, trial and process id, so
concurrent trials do not overwrite one another, and the path is printed with the
report. Waveforms are not produced; the bounded trace context and the failing
scenario are the diagnostics, as section 4 allows.

Source identity is read from the source tree rather than the working directory,
because dune runs an inline test inside a sandbox whose parent holds a stub `.git`.
A run that cannot reach git records `unavailable` rather than inventing a revision.

On a generated failure the concise report records the revision, working-tree status,
OCaml and host-tool versions, plus fingerprints of the dependency manifest and local
patch. The failure artifact additionally contains the exact relevant opam package
versions and a binary-capable patch against the recorded revision, including untracked
files. This keeps routine terminal output bounded while retaining the inputs needed to
reconstruct a dirty-tree run.

### Regression aliases and CI policy

The root aliases make the required/optional boundary executable:

| Alias | Command | Policy |
| --- | --- | --- |
| `@verification-required` | `./scripts/with-switch.sh dune build @verification-required` | All ordinary bounded model, cycle, timed, and four-state inline regressions; suitable when host HDL tools are unavailable. |
| `@verification` | `./scripts/with-switch.sh dune build @verification` | Required inline regressions plus every emitted-RTL rule under `@rtl`; this is the CI gate. |
| `@verification-long` | `./scripts/with-switch.sh dune build @verification-long` | Five recorded seeds through 1,000 pin-bank trials, 500 timed P2.2 trials, and the timed P2.6 phase/interruption sweep. |
| `@verification-four-state` | `./scripts/with-switch.sh dune build @verification-four-state` | Five recorded seeds through 500 trials of the named P2.2 four-state property. |

The bounded four-state property remains in ordinary `@runtest`; the explicit alias adds
depth and does not remove it from required evidence. The workflow in
[`.github/workflows/verification.yml`](../.github/workflows/verification.yml) installs
the host simulators, checks out the `hardcaml_asic` revision recorded by
`tinytapeout/asic-dependencies.lock`, builds the pinned OxCaml environment, and invokes
`@verification` on pushes and pull requests. Long aliases are intentionally opt-in.

### What P2.1 through the harness established

The recorded P1.6 runs report that the pin bank agrees with [`f_model/pin_bank.ml`](../f_model/pin_bank.ml) on every edge
of 200 generated scenarios and of the directed transcript, and on 150-trial sweeps
at seeds 1, 7, 99, 424242 and 20261231. Two things came out of getting there, and
both are recorded rather than absorbed:

- The sticky ownership conflict is set by a request that reached for another owner's
  pin even when that edge was refused for an unrelated reason. The harness found the
  disagreement between the design and a first reading of the contract; the contract
  was the ambiguous one, and [construction-plan.md section 3](construction-plan.md#3-initial-architecture)
  now says so.
- `reject_reason` is `Unavailable` on the design's side: the model knows why a
  request was refused and the RTL publishes only that one was. It is declared and
  skipped rather than dropped, so the hole is visible. Moving it into
  `required_post_edge` is the single change that would turn it into a failure.

The other primitive, core, and integration tests are structurally migrated into
block-owned suites but still use their existing directed Cyclesim loops. Structural
relocation does not claim shared-harness adoption or new generated coverage.

### Cycle/event adapter conformance

[`backend_conformance.ml`](../test/common/backend_conformance.ml) isolates the event
dependencies from `protemu_test_common` and characterizes the installed step-testbench
adapters with a test-only four-bit register and one-entry ready/valid sink. One shared
five-edge scenario loads nonzero state, clears it with reset, and checks input application,
pre-edge acceptance, settled registered outputs, completion, and refusal after the sink
fills. Cyclesim and two-state
Evsim produce identical known-value observations. A separate non-completing testbench
times out after three adapter steps on both backends.

The established event convention uses abstract integer ticks, a clock initially low,
a five-tick half-period, and rising edges at times 5, 15, 25, 35, and 45. Synchronous inputs
are applied at time 0 or after the preceding falling-edge sample and remain stable through
the rising edge. The installed `cyclesim_compatible` implementation wakes on rising to
capture the old/pre-edge values, then wakes on falling to return settled post-edge values;
the five scenario steps consequently return at times 10, 20, 30, 40, and 50. Its installed
interface comment describes the waits in the opposite order and is not used as the
contract. The Evsim step-testbench handler remains local to its process.

The clock scheduler alone drives the clock. The timed pad driver owns only its declared
pads and submits events to the timed runner rather than advancing simulation itself.
At an exact clock timestamp, the convention is to enqueue and settle the pad update before
the clock transition ("before the edge"); an after-edge transition uses a later tick. The
P2.2 runner enforces this ordering with a bounded delta-settle allowance. Scheduled
transitions use transport semantics: every transition is retained; the runner does not
silently suppress a short pulse as an inertial delay would.

The conformance run has an eight-step adapter budget and a 51-tick simulator cap, although
it completes in five steps/50 ticks. On completion or timeout, the testbench process waits
forever and the finite top-level Evsim run ends the trial; each run discards that simulator
and constructs fresh state. Run it with
`./scripts/with-switch.sh dune runtest test/common --force`. The local cost probe is
`./scripts/with-switch.sh dune exec test/common/backend_conformance_bench.exe -- 10000`;
the recorded 2026-09-19 result and machine identity remain in the migration guide. This
experiment establishes adapter sampling and budgeting only, not timed product coverage.

### Timed P2.2 product pilot

[`input_events_timing_testbench.ml`](../test/primitives/input_events/input_events_timing_testbench.ml)
and [`input_events_timing_tests.ml`](../test/primitives/input_events/input_events_timing_tests.ml)
form the first event-driven product suite. Timestamped pad/reset/event scenarios feed a
two-state Evsim adapter and a separate simulator-free predictor built from explicit
sampling rules plus `Protemu_f_model.Input_pins` and `Event`. Raw simulator signals remain
inside the test adapter. Every generated trial constructs fresh DUT/reference state.

The time unit is an abstract integer tick. The clock rises at 5, 15, 25, and so on. At an
exact rising timestamp, the runner applies stimulus first and permits 32 delta cycles for
the combinational input network to settle before changing the clock. Outputs are sampled
one tick later. A transition at that later tick is after the edge. The 32-delta allowance
is a finite scheduler budget and no simulated elapsed time. Continuous monitors record pad,
snapshot, edge, event, and overflow changes between samples.

Under that convention, a ten-phase sweep measured 10--19 ticks from an external high
transition to the synchronized rising indication: the sampled value reaches the registered
snapshot after the following clock edge. A two-tick pulse straddling a sample was captured;
an eight-tick pulse wholly between samples was missed. Capture therefore assumes that the
pulse covers a sampling point. A full-period pulse guarantees that in this deterministic
digital model, while no sub-period width does independently of phase. These results do not
measure setup/hold, analog pulse rejection, metastability, MTBF, or physical timing.

The directed case also exercises exact-edge reset and sticky event set/acknowledge/overflow
priority. The generated regression uses seed `20260919`, 160 trials, and maximum size 18.
Its shrinker preserves reset, temporal ordering, a pulse window, and mismatch identity.
The controlled one-tick pad-delay defect is reproducible and shrinks to reset plus an
exact-edge two-tick pulse. Failure reports carry timestamp/unit, edge, seed/trial,
source/configuration, first mismatch, nearby samples, and between-edge activity. Run it
with `./scripts/with-switch.sh dune runtest test/primitives/input_events --force`.

### Timed P2.6 event-to-engine path

[`observed_transfer_timing_testbench.ml`](../test/primitives/observed_transfer/observed_transfer_timing_testbench.ml)
and
[`observed_transfer_timing_tests.ml`](../test/primitives/observed_transfer/observed_transfer_timing_tests.ml)
reuse the P2.2 clock, timestamp, exact-coincidence, delta-settle, and finite-budget
conventions for the implemented `Input_events` → `Shift_lane` composition. The predictor
is simulator-free: it maps the external schedule to input-sampling edges, advances
`Protemu_f_model.Input_pins`, feeds the previous coherent snapshot into
`Protemu_f_model.Shift_engine`, and reconstructs driven pin transactions from that state.
The DUT side reconstructs the same transactions only from `pin_value_o`/`pin_oe_o`; a
released pin's stored value is deliberately ignored.

All ten integer phases agree on samples, full RX/fault state, and pin transactions.
Directed and generated cases cover lengths 1 and 32, both bit orders, TX-only, RX-only,
duplex, every start/pacing edge-kind combination at every integer phase, both
launch/sample arrangements, asymmetric and bounded-variable duty cycles,
reset/disable/abort, armed and active cancellation, and coincident cancellation/pacing
priority. The generated run is 48 fresh-state trials at seed `20260920`; a failure records
its first mismatch, typed configuration, source/dependency identity, and rerun command.

An independent external peer now checks the wire claim separately from model/RTL state.
It derives sampling edges only from the scheduled external clock and reads only boundary
pin transactions strictly before each edge. With a required one-tick digital setup, the
peer receives every bit of 1-, 8-, and 32-bit TX and duplex words for both bit orders,
idle-low and idle-high, preload-first and launch-first arrangements, every phase, and swept
asymmetric high/low widths. `Either`-edge pacing starts at the descriptor's `idle_clock`;
the first transition is the physical leading edge.

The measured path is 10--19 ticks from external transition to synchronized event, exactly
10 more ticks to engine action, and 20--29 ticks from external start, launch, or
cancellation to the registered lane output action. Ten-tick high and low intervals are
an input-capture and RX-only limit, corresponding to 24 MHz at an assumed 48 MHz system
clock. They are not a TX/duplex wire limit: a 10/10 schedule completes internally but the
peer samples stale later bits. TX/duplex requires at least 30 ticks from each launch edge
to its sampling edge and at least 10 ticks for the opposite half-cycle. This gives 12 MHz
with asymmetric 10/30 halves or 8 MHz with symmetric 30/30 halves at 48 MHz. A preloaded
first bit requires 30 ticks from select to first sample; a launch-first configuration
requires 10 ticks select-to-launch plus 30 ticks launch-to-sample. At the boundary, first
and subsequent bits have one tick of measured peer setup; 29 ticks fails some phases.
No pin-bank stage is in this fixture. These are deterministic two-state digital limits,
not analog CDC, metastability, or physical setup/hold evidence.

Rise-only and fall-only pacing remain event-source functional tests, not wire-clock claims.
The lane alternates its ordinal leading/trailing phase on each selected event and cannot
infer a missing opposite physical edge. Wire-level TX/duplex claims therefore use an
alternating `Either` clock initialized to the declared idle level; this does not infer all
SPI modes from a parameter toggle.

### Observed-transfer pin-bank integration

[`observed_transfer_bank.ml`](../lib/staging/observed_transfer_bank.ml) and
[`test/integration/observed_transfer_bank/`](../test/integration/observed_transfer_bank)
form the smallest current product composition through the real bank. The bridge reserves
the configured TX pin at arm acceptance, before a synchronized start can activate the lane;
passes active lane values through masked engine writes; commits zero output-enable before a
separate release; and shares the bank with one software request port. An internal request
has priority, and a coincident software offer raises `software_rejected_o` rather than being
silently discarded. Synchronized cancellation clears and releases only the engine mask;
reset, disable, and explicit abort retain `Pin_bank`'s documented global release.

The timed adapter samples both the lane and bank outputs. Its simulator-free predictor
composes the existing `Input_pins` and `Shift_engine` models with `f_model/Pin_bank` and a
separately stated bridge schedule, and compares every resulting bank transaction before
giving only those observable bank transactions to the external peer. Directed exhaustive
sweeps cover every integer phase, idle-low/high, preload-first/launch-first, both bit orders,
TX and duplex at lengths 1/8/32, and RX-only at 1/32. Unit cases preclaim and drive an unrelated software pin,
inject a conflicting software claim, retry after release, and offer a concurrent software
operation. Cancellation is phase-swept and followed by a fresh arm/start/completion. A
24-trial generated run at seed `20260920` varies direction, length 1..32, order, idle level,
mapping, phase, data and supported widths; failures use the shared source/configuration and
replay record.

| Measured path | Digital result |
| --- | --- |
| External start/launch to lane output | 20--29 ticks |
| Ordinary lane preload/data output to bank commit | exactly 10 ticks |
| External start/launch to committed bank output | 30--39 ticks |
| External cancellation to committed output-enable clear | 20--29 ticks |
| External cancellation to bank ownership release | 30--39 ticks |

The peer needs one tick of setup. TX/duplex therefore requires 40 ticks from each physical
launch to the peer sample and 10 ticks in the opposite half; 39 ticks fails at some phases.
At an assumed 48 MHz system clock that is 9.6 MHz for asymmetric 10/40 halves or 6 MHz for
symmetric 40/40 halves. RX-only still uses the 10/10 capture envelope and claims no output.
The first preloaded sample waits 40 ticks from select; launch-first waits 10 ticks to launch
and another 40 to sample. The observed bank outputs are the boundary of this fixture only:
there is no chip wrapper, pad model, routed delay, analog setup/hold, or metastability
evidence in these measurements.

Those are the direct event-to-engine paths. P3.3 now supplies the separate loaded
event-to-core-decision-to-pin path in [`integrated_core.ml`](../lib/emulator_core/integrated_core.ml).
The time-resolved fixture runs the actual P3.1a load/verify/RUN sequence, timestamps the
shared synchronized event, decoded decision, bank request, registered commit and boundary
pin, and sweeps all ten integer phases. Run it with
`./scripts/with-switch.sh dune runtest test/integration/core_engine --force`.
Run the primitive suite with
`./scripts/with-switch.sh dune runtest test/primitives/observed_transfer --force`.
Run the bank composition with
`./scripts/with-switch.sh dune runtest test/integration/observed_transfer_bank --force`.

The loaded-path contract is concrete rather than tied to private core internals.
The `wait_start_then_drive` image in `test/f_model/test_isa.ml` preclaims pin 0 for the
software owner in fixture initial state, writes it low, executes `Wait_edge` on pin 3 rising,
writes pin 0 high, and halts. It assembles to default-memory words `7804 0000 a300 7804 0001
0000` and executes in 13 reference edges. The integrated sweep retains the P1.5 fetch
schedule and records 10--19 ticks external-to-synchronized, 20 ticks synchronized-to-core
decision, 30 ticks decision-to-bank-request, and 60--69 ticks external-to-bank commit. The
request and registered commit share the clock edge, on opposite sides of it. The direct
engine/bank path is 30--39 ticks, so the loaded core path adds 30 ticks. Runs are finite and
phase failures report all named timestamps.
The ISA has no claim/release instruction, so the software claim is explicit fixture initial
state; changing that requires an ISA/architecture decision, not a test-only opcode.

### P2.7 UART-slice evidence

[`test/integration/uart_slice/`](../test/integration/uart_slice) retains its
purpose-built Cyclesim loops rather than forcing them through `Env`. The independent
receiver checks a fully driven leading idle, low start, eight LSB-first data slots, high
stop, constant level throughout every slot, a period consistent with the requested bit
period, and driven idle after the frame. Its negative cases reject a shortened slot, a
released pin inside a slot, and insufficient leading idle. The `0xa6` calibration case
still requires the transition-interval GCD to equal one bit period; generated bytes only
require the mathematically valid multiple relation because longer runs cannot reveal the
fundamental period from transitions alone.

The directed cases also preserve timer activity, engine claim/release, one completion
pulse, clean bank status, selected-pin isolation, the existing byte/pin/period vectors,
normal completion with the pin still driven idle-high, and next-edge pin/claim release
on reset, disable, and abort. `uart_frame.trace` is generated only after the bit-banged
firmware model, typed descriptor model, and Hardcaml slice decode to the same normalized
slot table; `@rtl` independently reconstructs and diffs that table from emitted Verilog.
These are **frame-relative** comparisons: every monitor finds its own start edge. They do
not claim cycle-exact request-to-start or completion latency across producers, whose
startup schedules intentionally differ. No independent absolute-latency oracle exists.

[`uart_slice_property_tests.ml`](../test/integration/uart_slice/uart_slice_property_tests.ml)
runs seed `20260920`, 96 trials, maximum generator size 16, and at most 328 captured
Cyclesim edges in a slice run. Each trial creates fresh model and simulator state and varies
the byte, all eight selected pins, half-periods 2--12, and complete versus reset/disable/
abort behavior at positions from acceptance into the active frame. Completed cases compare
the three normalized OCaml traces and all slice-level status/isolation obligations;
interrupted cases check release on the following edge and absence of completion. Returned
check failures use the shared `Replay.Settings`, source/dependency/tool identity, artifact
writer, and environment overrides, and print the full single-scenario value plus an
executable rerun command. Exceptions raised by the frame decoder or producer helpers
currently bypass this custom report/artifact path and fail the inline test directly.
There is deliberately no new shrinker or checker adapter. The recorded successful rerun
checks command/settings plumbing; no UART-specific controlled failure has demonstrated
artifact generation or reproduction of the same first mismatch. Existing receiver
negative tests establish waveform rejection, not that generated-failure reporting path.

The bounded property and committed trace diff are ordinary `@runtest` evidence and hence
remain in `@verification-required` and `@verification`. No separate UART long sweep is
defined. Half-periods 2--12 are the generated comparison range, not a change to the
hardware's supported-input contract or a published operating envelope. Firmware
comparison requires `half_period >= 2`. In the RTL, the 16-bit leading-idle countdown is
formed by doubling `half_period_i`; zero encounters primitive refusal and values at or
above 32768 overflow that countdown. The suite does not establish slice-level completion,
refusal, or recovery behavior for those requests. Positive values through 32767 avoid
the doubling overflow, but that arithmetic fact does not verify the full range.
Half-period 1 and the wider range remain coverage holes. Defining slice-level handling
or changing the supported period contract is separate product work, not a consequence
of this test-domain choice.

### Four-state unknown-pad property — P2.2

[`input_events_four_state_testbench.ml`](../test/primitives/input_events/input_events_four_state_testbench.ml)
and [`input_events_four_state_tests.ml`](../test/primitives/input_events/input_events_four_state_tests.ml)
implement one named property and nothing wider: *bounded unknown-pad recovery and unknown
isolation*. It uses direct `Four_state_simulator` processes behind the suite's own
adapter; no step-testbench binding is involved.

The contract is stated before the test, not read back from the DUT.

| Item | Statement |
| --- | --- |
| Injection site | `pin_in_i` only, at the module boundary. Nothing inside the DUT is forced. |
| Window | Whole sampling edges, driven by timestamped transitions on the same clock/coincidence convention as the timed pilot. |
| Resolution | The environment drives the pad back to a known level at a stated timestamp, or a synchronous reset clears the synchronizer. No probabilistic resolution. |
| Isolation | `event_o` and `overflow_o` carry no unknown bit at any edge, and a driven pin never becomes unknown because a neighbouring pin is undriven. |
| Contamination | While an unknown sample is inside the synchronizer, the affected `snapshot_o` bits must read X. A level there is a failure, so the property cannot pass by coercion. |
| Recovery bound | Three edges after the last edge that sampled an unknown pad bit, every output is known and equals the `f_model` prediction. A reset edge recovers at that edge. |

The bound is the synchronizer register depth — `stage0`, `stage1`, `previous` — and is a
digital statement only. It is not metastability, setup/hold, MTBF or analog evidence, and
four-state simulation does not create any of those.

Known values come from the ordinary `Protemu_f_model.Input_pins` and `Event`; a separate
contamination model of three shifted unknown masks supplies the X-sensitive part, so the
integer reference is never asked to be an X oracle. Observed logic is kept in an
X/Z-preserving word type, distinct from the `Observation` validity type: validity says
whether a thing can be compared, X and Z are values on a wire.

The installed four-state logic is pessimistic where Verilog is not — `X &: 0` is `X`
here — which reaches the edge detectors through an unknown `previous`. Those bits are
declared unconstrained for the edges the pessimism can reach and required known outside
them, so the recorded bound is an upper bound that an optimistic simulator cannot exceed.

Evidence: a directed transcript covering one resolved unknown window, one reset-cleared
window and concurrent event traffic; per-pin containment; reset recovery at the reset
edge; and a generated property at seed `20260919`, 120 trials, maximum size 16, whose
prerequisite keeps an applied reset, at least one edge that samples an unknown pad, and
room to observe recovery. Two controlled negatives run in the regression: a design defect
wiring the pad into the event set path fails isolation with `Unexpected_unknown` on
`event_o`, and an observer that reads X as zero fails contamination with
`Missing_unknown` on `snapshot_o`. Both shrink to a five-edge scenario with a
single-bit, single-edge unknown window and reproduce identically from their recorded
settings. Run it with
`./scripts/with-switch.sh dune runtest test/primitives/input_events --force`; measure it
with
`./scripts/with-switch.sh dune exec test/primitives/input_events/input_events_four_state_bench.exe -- 5000`.

### Deferred: resolved buses and open-drain wire resolution

This is the other four-state obligation, named here so it stays visible rather than
being implied by the one property above. It is **not implemented**, and nothing in the
current suite should be read as evidence for it.

The contract exists already. [construction-plan.md](construction-plan.md) fixes the
driver side — for open drain, always drive a zero, `pin_out = 0` with `pin_oe = drive_low`
— and requires the pull-up and multiple open-drain drivers to be modelled in the
testbench. [phase_plan.md](phase_plan.md) owes the wire side at P4.5/P4.6: resolved
open-drain bus tests with pull-ups covering actual SCL observation, stuck bus, NACK
paths, and forced arbitration loss followed by release. The invariant list under
"Evidence map and completion rules" below includes open-drain never driving high.

What exists today is the *driver-side half*, in two-state Cyclesim: `Pin_bank` forces
write data low when `write_open_drain_i` is set, and `test/primitives/pin_bank/` checks
that an open-drain commit never drives a high, with the controlled
`Defect.Ignore_open_drain` fixture proving that check can fail. That is a statement about
the two words the block emits, `pins_o` and `pin_oe_o`. It is not a statement about a
wire.

What is missing is everything past the block boundary. The OCaml design has no tri-state
pad and no bus: value and enable stay separate words all the way out to
[`tinytapeout/src/project.v`](../tinytapeout/src/project.v), where `uio_out`/`uio_oe`
become the pads and the resolution happens off-chip. So there is no model of a released
pin as Z, no pull-up, no second external driver, no wired-AND, and no contention case in
which two drivers disagree and the wire is X.

It is deferred rather than attempted because no implemented consumer shares a bus yet.
I²C is P4.5 and unimplemented, so a property written now would be about an invented wire,
which the migration guide explicitly rules out. Inventing a physical model is worse than
recording the hole.

A future property needs, at minimum: a resolved four-state signal
(`Four_state_logic.create_signal ~resolution:`Resolved`) standing for the wire; an
explicit tri-state model driving it from the DUT's `pins_o`/`pin_oe_o`, where a released
pin contributes Z rather than a level; an explicit pull-up driver; one or more
independent external open-drain peers; and expectations covering wired-AND resolution, a
released bus reading high through the pull-up, a stuck-low bus, and a contention case
that reads X and is required to fail. The never-drive-high invariant would then be
checked at the wire instead of at the register. Whether this lands in the OCaml tier at
all, or is left to the emitted-RTL tier where the pads actually exist, is itself an open
decision and is recorded as such in the evidence map.

### Current limitations and evidence boundaries

The cycle runner takes one item per edge and monitors edge-indexed observations. Its
`Dut` adapter hides Cyclesim operations, but its scheduling contract is still
synchronous. `Observation.Defined` contains an `int`; `Unavailable` and
`Unspecified` describe observation validity, not four-state electrical logic.

The generator loop uses `base_quickcheck` and one seeded `Splittable_random.t`;
trial n has size `n mod (size + 1)`. The shrinker removes items while preserving
scenario prerequisites and failure identity (phase/observation/reason). Timeout
is a failure. Each trial starts with fresh state. The controlled
`Defect.Ignore_open_drain` fixture verifies detection, shrinking, reporting, and
reproduction without altering production RTL or the functional model.

Current replay records revision, dirty status, the exact local patch, relevant opam
dependency versions, OCaml/host-tool versions, settings, trial, configuration, and
scenarios. Patch and dependency details live in the failure artifact, with fingerprints
in terminal output. Trace context is bounded (six edges by default); no waveform,
stimulus journal, or general replay-file format is implemented.

The UART property uses the same replay record and fresh-state rule for returned check
failures, but its scenario is one frame or interruption and it does not use the shared
`Env` shrinker. No minimality claim is made for its parameters or interruption position.
Its exception-reporting gap and unexercised controlled-failure replay path are recorded
in the P2.7 section above; common harness replay evidence does not close those local gaps.

Exactly one four-state property is implemented, on `Input_events` alone. Resolved buses
with explicit drivers and pull-ups, open-drain wire resolution and any other X/Z
obligation have no four-state evidence. No coverage-collection suite is implemented.
Two-state timed runners cover P2.2 and both P2.6 event-to-engine and loaded
event-to-core-decision paths. P3.3's core-engine suite owns the latter.
The existing RTL smoke checks do
not establish gate-level functional behavior, physical timing closure, or metastability
reliability. See the evidence map below for the distinction between implemented checks
and outstanding obligations.

## Next state

Retain the paired expect/property test style. Organize suites by the block or
integration boundary they verify. Use Cyclesim for the main synchronous functional
regression, two-state Evsim for explicit time, and narrowly scoped four-state
Evsim for properties that require X/Z. Do not convert the whole suite to raw Evsim.

### Backend responsibilities

| Tier | Owns | Does not establish |
| --- | --- | --- |
| Standalone `f_model` tests | Specification examples, ISA/encoding, cycle schedules, independent protocol expectations | RTL agreement |
| Cyclesim | Exact synchronous state, acceptance, latency, FIFO/arbitration/core behavior; broad generated regression | Sub-cycle phase, X/Z, physical timing |
| Two-state Evsim | Timestamped pad activity, phase/jitter/pulse sweeps, externally paced transfers, event-to-pin latency | Analog metastability or unknown propagation |
| Four-state Evsim | Explicit unknown injection/propagation and resolved external bus behavior under stated models | Automatic setup/hold analysis or analog resolution |
| Emitted RTL and implementation tools | Wrapper/backend integration, emission checks, applicable formal, CDC/reset and mapped/gate-level evidence | Coverage merely because a flow or synthesis smoke test ran |

Use a small common two-state scenario subset to check runner agreement. Do not
repeat the entire Cyclesim regression on every backend. Benchmark representative
trials before making performance claims or expanding the event tier.

### Functional model, drivers, monitors, and prediction

`f_model` means the independent functional reference, including the specified
cycle schedule. It must not import Cyclesim, Evsim, simulator signal handles,
`Hardcaml.Bits`, or a step-testbench handler. It can accept ordinary OCaml values,
explicit clock-step events, and timestamps when the specification needs them.
Simulator independence does not imply that every module has the same abstraction
or that every test can use the same model entry point.

The conceptual data paths are:

```text
scenario -> backend driver -> DUT -> monitor -> actual observations/items
    |                                             |
    +-> independent input/sampling model -> f_model -> expected observations/items
                                                  |
                                      checker compares both streams
```

A driver translates stimulus into port activity and states whether offers are
one-shot or held until accepted. A monitor reconstructs what actually happened,
including acceptance, timing, errors, and output-enable behavior. The predictor
computes what should happen from the contract and independent inputs. The checker
compares the two; the monitor is not the source of expected DUT results.

| Boundary | Reference inputs and predictions |
| --- | --- |
| FIFO, pin bank, synchronous core | Requests and sampled inputs per edge; predict acceptance and state on that edge, independently of simulator choice |
| Input synchronizer/front end | External transition schedule plus explicit sampling assumptions; predict captures/latency or a specified set of legal outcomes |
| Protocol interface | Independently specified peer traffic and accepted input transactions; predict output transactions, with separate wire timing checks |
| X-sensitive behavior | A dedicated logic/sampling model or property checker that preserves unknowns; the normal integer-valued reference is not an X oracle |

An input monitor may legitimately feed accepted transactions to a transaction-level
reference, as in UVM. In that case acceptance/backpressure itself must be checked
separately. Feeding the DUT's `accepted` decision into the only reference would
hide an erroneous rejection; for exact cycle comparisons the reference predicts
that decision independently. Output monitors never generate expected outputs.

For asynchronous inputs, the environment owns the mapping from external time to
reference sampling events. If sampling behavior is itself under test, that mapping
must be independently specified, not copied from the DUT's synchronized output.
Outside an explicitly declared uncertainty window, require exact behavior. Inside
one, enumerate permitted outcomes or use a bounded uncertainty model, retaining
exact checks downstream for each chosen outcome. Do not silently realign traces.

Do not assume four-state simulation creates metastability. Define injection site,
window, duration, resolution assumptions, and expected response. Exploring old/new
capture or a bounded capture delay can be more suitable than X injection. Digital
tests do not prove analog reliability; CDC structure and physical assumptions need
separate evidence.

### Suite hierarchy and ownership

Proposed paths (not yet present):

```text
f_model/                           independent reference library
test/
  f_model/                         standalone reference tests
  common/                        cycle/event runners, checks, replay, diagnostics
  primitives/
    pin_bank/
      pin_bank_testbench.ml
      pin_bank_expect_tests.ml
      pin_bank_unit_quickcheck_tests.ml
      dune
    input_events/
      input_events_testbench.ml
      input_events_expect_tests.ml
      input_events_unit_quickcheck_tests.ml
      input_events_timing_tests.ml
      input_events_four_state_tests.ml
      dune
  core/
    protocol_core/               same testbench/expect/property convention
  integration/
    wrapper/                     wrapper and later whole-system boundaries
tinytapeout/test/                 emitted-RTL checks remain separate
```

A module's `*_testbench.ml` owns typed scenarios, adapters, reference wiring,
monitors, and run entry points. Expect and property files consume these definitions;
they do not each invent a simulator loop. Larger suites may split backend adapters
into local helper files. Timing and four-state files exist only for named obligations;
every primitive does not need all tiers. Directed assertions can live alongside
Quickcheck properties without manufacturing meaningless golden transcripts.

Keep production reference state in `f_model/`; testbench-only protocol adaptation
belongs beside the suite. The shared instruction specification remains in `isa/`.
Keep reference-only tests free of Hardcaml dependencies and diagnostic code out of
synthesizable source sets. The naming migration is specified in the temporary guide.

### Runner and step-testbench boundary

Keep the existing `Env` behavior as the cycle runner foundation. Introduce an event
runner for timestamped stimuli and continuous pin monitors; share generators,
independent predictions, checker semantics, and replay/reporting where applicable.
One selected runner owns time in a trial. Do not require the event runner to fit
one-item-per-edge scheduling or make raw simulator operations leak into every test.

The event contract must define time units, clock period/phase, reset timing,
coincident-event ordering, pre-edge sampling, settled post-edge sampling, finite
time/event budgets, and whether delays are transport or inertial. Report time and
edge index, with a domain identifier if multiple clocks are introduced. Capture
between-edge activity in timed monitors rather than only polling once per cycle.

`hardcaml_step_testbench` is optional authoring infrastructure, not the verification
architecture. Its functional and imperative APIs each have Cyclesim and Evsim
backends. `Functional.Make(I)(O)` allows shared two-state bodies; backend-specific
setup still constructs the simulator, clocks, and runner. Functional ports exchange
`Bits.t` inputs and before/after outputs; imperative tests poke port references.
The functional style provides merging/defaults for concurrent input producers.

On Evsim, `process`/`deferred` installs a testbench in the event scheduler and a
separate process drives the clock. Additional processes may drive asynchronous
pins, with explicit port ownership. On Cyclesim, `run_until_finished` or
`run_with_timeout` owns the synchronous loop; imperative `wrap` supports existing
cycle-driven callers. These are distinct execution arrangements, not a runtime
backend flag.

Installed `5.2.0+ox` notes, inspected on 2026-09-19:

- Both step-testbench Evsim adapters include `Two_state_simulator`. Four-state
  tests need direct `Four_state_simulator` processes behind an adapter, unless a
  separately justified four-state step binding is implemented later.
- `cyclesim_compatible` is intended to return before/after samples, but the
  installed functional implementation waits for rising then falling, while its
  interface comment says falling then rising. The conformance fixture above established
  that the rising wake observes old/pre-edge state and the falling wake returns settled
  post-edge state for this version. The experiment, rather than the conflicting comment,
  defines the shared convention.
- `rising_edge` returns the same sample as both before and after; it does not
  satisfy a contract requiring distinct samples without additional machinery.
- `Handler.t @ local` cannot escape its permitted lifetime; pass it down operations
  rather than retaining it in long-lived driver objects. Installed `create_clock`
  also carries a `here:[%call_pos]` argument.
- Evsim `Hybrid` partitions DUT simulation for acceleration. It is independent of
  testbench portability and is not the proposed division of verification duties.

Installed interfaces and implementations under `~/.opam/5.2.0+ox/lib/` are the
version authority; sibling upstream checkouts can differ. Recheck these notes when
dependencies change. The old monadic/Cyclesim-only step-testbench README description
does not describe this installed effect-based API.

### Four-state observations

Keep contract validity separate from sampled logic. `Unavailable` means an adapter
cannot expose an observation; `Unspecified` means the contract does not constrain
its value. X and Z are observed logic values, not synonyms for either case.

Use an X/Z-preserving value representation at the four-state adapter/checker boundary.
A known required value compared with X must fail; conversion to an integer must be
checked, never silently coerce unknown bits. Record unexpected unknowns even when
other data is masked. Allow don't-care bits only where the contract explicitly
permits them. Known-value scenarios can reuse the ordinary reference; X-sensitive
properties use dedicated expectations without making the entire reference library
four-state. Resolved buses must model all drivers and the pull-up explicitly; the
implemented P2.2 unknown-pad property above follows this policy and is currently its only
instance.

### 1. Keep the test environment small

The following numbered contracts retain the section identifiers used by source
comments in the existing harness. They apply across the target architecture with
the backend-specific boundaries above.

Use directed expect tests paired with Quickcheck generators and properties. Within
each simulation tier, both use the same environment and runner. Cycle and event
tiers may have different runners while sharing scenarios, independent predictions,
checks, and reporting. Expect tests make selected edge sequences,
transactions, and failures readable; Quickcheck explores bounded variations and
checks invariants and model agreement. Do not snapshot entire random runs.

Use the UVM separation of responsibilities without introducing a UVM framework:

- A scenario supplies items: commands, programs, peer traffic, delays, resets,
  interruptions, and queue service actions.
- The environment owns the drivers, independent functional model, monitors, and
  checker. It feeds the same scheduled stimuli to the DUT and model in parallel.
- Drivers translate items into interface activity. A driver declares whether an
  offer is made once or held until accepted; retries must not hide rejections.
- Monitors observe actual interfaces and reconstruct items/events, including
  timestamps and errors. They never infer success from what a driver intended.
- The checker compares model and DUT observations and applies protocol assertions.
  The selected runner alone owns simulation time; event processes execute under
  its scheduler.

Model execution remains independent of RTL execution logic. Shared ISA definitions,
scenario data, scheduling, and reporting helpers are allowed. Expected results must
not be computed using DUT implementation helpers. Keep the functional model and
its standalone tests free of Hardcaml (`f_model/` and `test/f_model/`);
functional-model/Hardcaml comparison environments belong under `test/`.

### 2. One cycle-exact contract

For a specified sampled-input trace, the core and primitives must agree with the
independent model on the same clock edges for all defined observations. Any
explicit asynchronous sampling uncertainty belongs at the input boundary described
above; it does not relax this downstream cycle contract. Do not match effects after discarding cycles,
allow arbitrary latency tolerance, or silently realign traces after a mismatch.
Check acceptance, completion, pin value/enable, events, faults, and relevant
architectural state at the boundary selected by each test. Private RTL state need
not have the same representation as model state.

Adopt P1.5's reference core schedule: no fetch/execute overlap, one buffered memory
word, and one execution edge per instruction plus its specified wait/stall edges.
Memory reads have the established latency-one contract. Packed-word buffer hits,
extensions, and branch buffer invalidation retain their reference timing. Memory
layout is a test configuration: cycle-exact comparison uses the same configuration
on both sides. A timing optimization requires an explicit contract revision and
updated model, timing expectations, and protocol evidence.

The reference is not automatically correct because RTL matches it. Directed cases
must assert contract edge timing, and independent protocol monitors must check
wire timing and reconstructed data. Existing model gaps, including engine/core
integration and host recovery paths, must be specified and modeled as their phase
items are implemented; P1.6 does not claim the current core models all of P3.

### 3. Runner and Quickcheck

A Quickcheck generator produces a bounded scenario, not an independently running
driver. Each trial creates fresh DUT, model, peer, and checker state, then invokes
the same runner used by directed tests. No component reads wall-clock time or an
unrecorded random source. Generate stimulus choices up front where practical;
reactive choices must use explicitly seeded state with deterministic ordering.

In the cycle runner, for each rising edge it drives scheduled inputs, settles combinational
logic, captures pre-edge acceptance conditions, advances DUT and model, and
captures settled post-edge observations for the checker. Sample handshakes using
the pre-edge values and the interface's reset/disable priority, not newly raised
post-edge ready. Each trial has a monotonic edge index that does not restart on
DUT reset, and a finite edge budget. Report budget exhaustion as a timeout.

Reactive peers belong to the environment. If peers depend on implementation
outputs, use separate, identically initialized peer instances for model and DUT;
compare the observed outputs before proceeding so one side cannot conceal the
other's divergence. Resolve open-drain buses from all drivers and pull-ups.

P1.6 evidence uses edge-scheduled inputs. For tests exercising asynchronous phase
or jitter, use the event runner to schedule transitions between edges
with an explicit time unit and deterministic ordering. State pulse-width and
sampling assumptions; digital simulation does not demonstrate metastability safety.

Use small directed boundary cases alongside generated cases. Generators should
cover valid traffic and explicitly identified invalid/interruption scenarios;
shrinking must preserve the scenario's prerequisites or report an invalid case
rather than silently turning it into a different test.

### 4. Seeds and failure reporting

Seed-based Quickcheck replay is the normal reproduction path. Use explicit seeds
for regular regression and permit additional seed sweeps. Record the test name,
seed, trial count/size settings, failing trial identity, configuration, source
revision (and any local diff), and dependency/tool versions needed to reproduce the
generator. A seed reproduces within that code and environment; it is not a promise
that a changed generator will emit the same cases.

Failure output includes the failing generated scenario, the shrunk scenario when
available, and the first mismatch with its edge, observation name, expected and
actual values, and nearby trace context. Print the exact invocation and seed
needed to rerun. Retain enough inputs for the failing case, including program image
or exact assembly inputs, to understand it without reading a waveform. Promote
useful minimized failures to directed regression tests.

A persistent stimulus journal or general replay-file format is not required for
P1.6. Waveforms are optional diagnostics, produced on failure or request. Keep
trace context bounded, identify truncation, and keep full waveforms out of expect
snapshots. Use a documented writable artifact directory and print artifact paths;
concurrent trials must not overwrite one another. Exact helper APIs, file names,
and CLI spelling are implementation choices to document with the harness.

Demonstrate failure reproduction using a controlled mismatch in a test fixture:
rerunning the recorded seed/settings must find the same first mismatch. The
normal regression asserts that this diagnostic exercise behaves as expected;
do not leave an intentionally failing test in the suite.

### 5. Observation validity and memory

Represent observations distinctly as unavailable, unspecified, or defined with a
value. Defined zero is an ordinary value. Test setup declares required observations;
a required observation that the adapter cannot expose or the contract marks
unspecified is an error, not a skipped comparison. Unspecified values may differ only where the contract permits them;
unexpected validity differences are failures.

`hardcaml_asic` owns memory backend conformance. Link its evidence separately.
Compare only contract-defined memory values across backends; check disabled-output
hold within each backend, including after an unspecified result. Simulation poison
must not enter synthesized storage or become a required physical output value.
Emulator tests own valid instruction consumption, shared-port access, whole-word
loading, image bounds, and recovery. Do not duplicate the library's backend suite.

### 6. Protocol monitors and the future bitstream boundary

Follow the familiar pin-to-item monitor model: reconstruct bytes, transfers,
frames, or error events from observed pins, then send those items to the checker.
Include observed timing and protocol validity, so correct bytes with incorrect wire
timing still fail. Independent peers and monitors supplement cycle comparisons;
self-loopback alone is insufficient.

Construction-plan section 6 reserves a future logical-bit interface with data,
valid/ready, stream boundaries, and error metadata. A logical bit accepted there
and a physical symbol observed at the pins are different events: stuffing or line
encoding can change their count and timing. Record logical acceptance only when
its handshake occurs; reconstruct physical events from observed pin activity.
Do not assume one bit corresponds to one emitted symbol or a complete transaction.

P1.6 reserves these distinctions in monitor/trace conventions, including direction,
stream identity, timestamps, boundaries, and errors where applicable. It does not
implement USB/Ethernet transforms or require unused stretch-engine interfaces.
Detailed symbol formats and buffering/abort behavior belong to the later stretch
work. Backpressure must never silently lengthen an active wire waveform.

### 7. Delivery and evidence

P1.6 established the initial harness by demonstrating one small existing primitive
through the shared environment
with a directed expect test and a bounded Quickcheck suite, exact per-edge model
comparison, and the controlled failure-reproduction exercise. Wholesale conversion
and a full core were not prerequisites for that initial milestone; the next-state
migration has its own completion conditions below.

Retain model, Hardcaml, emitted-RTL/wrapper, and physical/gate-level checks as distinct
evidence layers. The same functional conventions apply to ASIC RTL simulation;
physical timing, reset/CDC assumptions, memory backends, and gate-level checks add
separate obligations rather than requiring a more elaborate functional framework.
No P1.6 planning decision constitutes implementation or physical acceptance evidence.


## Evidence map and completion rules

This table records suite ownership, not a coverage percentage. Update it when work
lands, with the test path, command, assumptions, and a linked result where relevant.
Historical run reports are not fresh results for later source revisions.

| Obligation | Current evidence/owner | Next evidence still owed |
| --- | --- | --- |
| ISA, encoding, reference cycle schedule, firmware examples | `test/f_model/`, 96 expect tests | Preserve independently; extend with new contracts |
| Cycle/event adapter scheduling | `test/common/backend_conformance*.ml`; matching five-edge known-value trace, completion, and timeout on Cyclesim/two-state Evsim; exact-coincidence ordering is enforced by the P2.2 runner | Recheck the characterized adapter and delta-settle convention when dependencies change |
| Pin bank cycle agreement and harness diagnostics | `test/primitives/pin_bank/` plus generic fixtures in `test/common/`; recorded 200 trials and seed sweeps above | Extend properties as the block contract grows |
| Other primitive cycle behavior | 55 block-owned inline directed, expect, generated, timed, and four-state cases under `test/primitives/`, plus one integration case under `test/integration/primitive_demo/` | Add bounded generated properties where they provide distinct evidence |
| Core program load/access/fetch behavior | [`test/core/protocol_core/`](../test/core/protocol_core): twelve directed cases plus 240 generated fresh-state scenarios at seed `20260920` compare RTL with independent [`f_model/program_access.ml`](../f_model/program_access.ml) and a 1RW contract store. P0.7 additionally reruns the consumer against selected context-registered Simulation/Flops backends. P3.3 supplies real engine-idle production and boundary STOP/ABORT/single-step integration under [`test/integration/core_engine/`](../test/integration/core_engine). | The physical `Host_api.Device` transport and full-system physical evidence remain later obligations. |
| Core decode and mechanism integration | [`test/core/control_execution/`](../test/core/control_execution) preserves P3.2 decoder/retirement evidence. [`test/integration/core_engine/`](../test/integration/core_engine) adds seventeen loaded-program, generated and timed cases for all delegated kinds, real mechanisms, background transfer, ownership/pressure, observed pacing, control/event collisions, interruption, cleanup and engine-idle gating. `p3_control_tb.v` retains the 16-cycle P3.2 image; `p3_integration_tb.v` runs the loaded wait/event/pin path and ABORT release from emitted RTL. See the [P3.3 record](p3.3-implementation.md). | P5 still owns mapped area/timing; formal invariants, the physical `Host_api.Device` transport, and physical protocol acceptance are not established. |
| Host API and integrated simulator workflow | [`test/host/`](../test/host) checks serialization, compatibility, and stable timeout codes independently of command parsing. [`test/integration/host_simulator/`](../test/integration/host_simulator) drives the actual P3.3 DUT and contract RAM, including logical-image read bounds, refusal classification, signature/capability conformance, engine-owned pin conflicts and ABORT release, partial queue recovery and full-FIFO concurrent pop, defined execution-fault recovery, exact trace loss/cursors/ordering, and executable workflows with defined machine-readable failures. See the [P3.4 record](p3.4-host-api.md). | P3.5 supplies transport interruption, fixed hardware loading/framing, and retained-response replay/commit. P3.6 owns queue transport, physical error/time mapping, a physical backend, and two-image portable reload evidence. Simulator-side trace is not hardware trace storage. |
| Independent hardware loader | [`lib/host_link/hardware_loader.ml`](../lib/host_link/hardware_loader.ml) and [`lib/host_link/loader_core.ml`](../lib/host_link/loader_core.ml), with [`p3_loader_tb.v`](../tinytapeout/test/p3_loader_tb.v) driving emitted serial pins at reusable-core, behavioral-wrapper, and production synthesis-wrapper tiers. The independent peer checks framing/CRC/correlation and decoded INFO/STATUS; rejects the reproduced counter-wrap attacks, long prefixes and extra bytes without dispatch/write/progress; protects dispatch/READ/ABORT context; validates before explicit response commit and replays one side-effecting RUN response without repeating its output-enable effect; performs actual RAM verification; sweeps the four-cycle envelope at every phase and asymmetric duties; and recovers looping, blocked-queue, active-transfer, driven-pin, and invalid-instruction states before replacement loading. See the [P3.5 record](p3.5-hardware-loader.md). | P3.6 still owns queue transport, the physical `Host_api.Device` backend, unsupported step/pin/trace mapping, full portable inspection/error strategy, physical timeout semantics, and the two-image portable workflow. Board timing, metastability reliability, mapped cost, and physical closure remain unclaimed. |
| P0 wrapper | Two tests in `test/integration/wrapper/` plus `@rtl` wrapper checks | Later host/load/recovery evidence |
| P2.2 external phase and pulse capture | `test/primitives/input_events/input_events_timing_{testbench,tests}.ml`; directed cases plus 160 generated trials, 10--19 tick deterministic latency, captured/missed pulse cases, reset/event interactions, temporal shrink/replay | Physical CDC/setup/hold/metastability evidence remains separate |
| P2.6 event-to-engine/core-to-pin latency | The primitive timed suite covers idle-low/high physical mappings at the lane boundary: external-to-event is 10--19 ticks, event-to-lane is 10, and external-to-lane is 20--29. `test/integration/observed_transfer_bank/` gives 30--39 ticks external-to-bank. The P3.3 loaded-program sweep measures 60--69 ticks external-to-bank: 10--19 to synchronization, 20 to the core decision and 30 to the decoded bank request/commit edge. | Wrapper/pad, analog CDC/setup/hold and physical timing remain separate |
| P2.7 UART TX slice | `test/integration/uart_slice/`: 12 directed unit cases, a saved-trace expect/diff, and 96 generated Cyclesim trials at seed `20260920`; model/descriptor/Hardcaml frames agree relative to their detected start edges, while slice ownership, timer, bank, pin isolation, completion and interruption contracts are checked at the hardware boundary; `p2_uart_slice_tb.v` repeats the frame/release checks on emitted RTL | Independent request-to-pin/completion latency, the unverified wider period range, P3 fetch/decode/core-to-engine behavior, the P4 UART baseline, physical timing, and formal invariants remain separate obligations |
| Unknown pad propagation and recovery | `test/primitives/input_events/input_events_four_state_{testbench,tests}.ml`; declared injection site/window/resolution, isolation and per-pin containment, a three-edge recovery bound, 120 generated trials at seed `20260919`, and two controlled negatives covering a design leak and a coercing observer | Extend to further blocks only where a contract names an X/Z obligation |
| Resolved external buses, open-drain wire resolution | No four-state suite | An explicit multi-driver/pull-up model and targeted tests, or a recorded decision to leave it to the emitted-RTL tier |
| Memory backend conformance | Owned by `hardcaml_asic`: [`test_single_port_ram.ml`](../../hardcaml_asic/test/test_single_port_ram.ml) runs its independent scoreboard against both implementations; P0.7 reruns the emulator consumer against adopted Simulation and explicit-Flops implementations | SRAM/macro selection and full-system physical memory timing remain open; emulator still owns consumption/arbitration/image bounds/recovery |
| UART generated-failure diagnostics | Shared replay settings/report/artifact integration for returned check failures; successful recorded-seed rerun; directed receiver rejection tests | Route producer/decoder exceptions through scenario-aware reporting and demonstrate a controlled generated failure with artifact and first-mismatch replay; no UART shrinking evidence is claimed |
| Protocol correctness and timing | Reference firmware/peer tests, primitive UART RTL smoke, and the integrated P2.7 independent frame/release monitors described above | Broader P4 independent-peer and timing evidence; loopback alone insufficient |
| Formal, CDC/reset, mapped/gate-level and physical timing | Not established by this functional suite or generic Yosys smoke test | Record applicable analyses, assumptions, tool/source identity and outstanding gaps in phase/flow evidence |

Applicable formal checks include exclusive pin ownership, open-drain never driving
high, FIFO bounds, handshake loss/duplication, reset release, and bounded waits.
No such proof is implied by a passing simulation. Record environmental assumptions
and separate modeled latency from measured physical latency. Physical measurements
and build/execution identities follow construction-plan section 9 and the
[experiment record format](../tinytapeout/reports/README.md).

The next-state suite is complete only when migrated cases preserve current evidence,
cycle/event sampling is characterized, P2.2/P2.6 timed obligations have actual results,
and every claimed four-state property has an explicit contract and test. Missing
physical or integration evidence stays visible; an architecture document is not
acceptance evidence. The migration guide can then be removed after its enduring
facts and resulting paths have been folded into this document.

### Migration retirement and formatting backlog

The recorded UART integration checks on 2026-09-20 passed the focused UART formatting
and lint aliases, repository-wide lint/build, forced ordinary regression, and
`@verification` including emitted RTL. These are historical results for the source/diff
recorded in the migration guide, not fresh checks of subsequent edits.

Repository-wide `@fmt` still reports the pre-existing formatting backlog outside that
integration. Keep that backlog separate from verification acceptance: formatting checks
appropriate to changed files must pass, but unrelated formatting cleanup is not by itself
a blocker to retiring the migration guide. Retirement still requires preserving enduring
results, assumptions, commands and deferred obligations here, and updating the index and
inbound links. Benchmark provenance and other historical evidence must retain a durable
home before their only record is removed. A UART controlled-failure replay check is a
named follow-up, not existing evidence or a requirement to redesign the migrated suite.
