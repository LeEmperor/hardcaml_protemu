# Verification approach

Status: P1.6 planning decisions accepted 2026-09-19; harness implementation and
completion evidence remain outstanding. The [construction plan](construction-plan.md)
owns architectural contracts; this document specifies how tests exercise them.
[Phase plan P1.6](phase_plan.md) tracks delivery.

## 1. Keep the test environment small

Use directed expect tests paired with Quickcheck generators and properties. Both
use the same environment and runner. Expect tests make selected edge sequences,
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
  The runner alone advances simulation time.

Model execution remains independent of RTL execution logic. Shared ISA definitions,
scenario data, scheduling, and reporting helpers are allowed. Expected results must
not be computed using DUT implementation helpers. Keep `model/` and `test/model/`
free of Hardcaml; model/Hardcaml comparison environments belong under `test/`.

## 2. One cycle-exact contract

The core and primitives must agree with the independent model on the same clock
edges for all defined observations. Do not match effects after discarding cycles,
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

## 3. Runner and Quickcheck

A Quickcheck generator produces a bounded scenario, not an independently running
driver. Each trial creates fresh DUT, model, peer, and checker state, then invokes
the same runner used by directed tests. No component reads wall-clock time or an
unrecorded random source. Generate stimulus choices up front where practical;
reactive choices must use explicitly seeded state with deterministic ordering.

For each rising edge the runner drives scheduled inputs, settles combinational
logic, captures pre-edge acceptance conditions, advances DUT and model, and
captures settled post-edge observations for the checker. Sample handshakes using
the pre-edge values and the interface's reset/disable priority, not newly raised
post-edge ready. Each trial has a monotonic edge index that does not restart on
DUT reset, and a finite edge budget. Report budget exhaustion as a timeout.

Reactive peers belong to the environment. If peers depend on implementation
outputs, use separate, identically initialized peer instances for model and DUT;
compare the observed outputs before proceeding so one side cannot conceal the
other's divergence. Resolve open-drain buses from all drivers and pull-ups.

Initial P1.6 evidence can use edge-scheduled inputs. When later tests exercise
asynchronous phase or jitter, let the runner schedule transitions between edges
with an explicit time unit and deterministic ordering. State pulse-width and
sampling assumptions; digital simulation does not demonstrate metastability safety.

Use small directed boundary cases alongside generated cases. Generators should
cover valid traffic and explicitly identified invalid/interruption scenarios;
shrinking must preserve the scenario's prerequisites or report an invalid case
rather than silently turning it into a different test.

## 4. Seeds and failure reporting

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

## 5. Observation validity and memory

Represent observations distinctly as unavailable, unspecified, or defined with a
value. Defined zero is an ordinary value. Test setup declares required observations;
a required observation that the adapter cannot expose is an error, not a skipped
comparison. Unspecified values may differ only where the contract permits them;
unexpected validity differences are failures.

`hardcaml_asic` owns memory backend conformance. Link its evidence separately.
Compare only contract-defined memory values across backends; check disabled-output
hold within each backend, including after an unspecified result. Simulation poison
must not enter synthesized storage or become a required physical output value.
Emulator tests own valid instruction consumption, shared-port access, whole-word
loading, image bounds, and recovery. Do not duplicate the library's backend suite.

## 6. Protocol monitors and the future bitstream boundary

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

## 7. Delivery and evidence

P1.6 should demonstrate one small existing primitive through the shared environment
with a directed expect test and a bounded Quickcheck suite, exact per-edge model
comparison, and the controlled failure-reproduction exercise. This is sufficient
to establish the conventions; wholesale conversion of existing tests and a full
core implementation are not prerequisites.

Retain model, Hardcaml, emitted-RTL/wrapper, and physical/gate-level checks as distinct
evidence layers. The same functional conventions apply to ASIC RTL simulation;
physical timing, reset/CDC assumptions, memory backends, and gate-level checks add
separate obligations rather than requiring a more elaborate functional framework.
No P1.6 planning decision constitutes implementation or physical acceptance evidence.
