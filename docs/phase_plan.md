# Protocol emulator phase plan

Status: working execution plan, updated 2026-09-16 for ASIC library adoption.
P0.1–P0.3 retain their recorded completion; new integration items are unchecked.
A scaffold, accepted architecture, or emitted build is not completion evidence.

## 1. Purpose and use

This is the actionable breakdown of [construction-plan.md](construction-plan.md).
That document remains the source of truth for architecture, contracts, scope,
and design decisions. Phase numbers here match its construction stages in
[section 8](construction-plan.md#8-construction-sequence).

Use this plan to select a bounded piece of work, identify its prerequisites, and
record the evidence that it is complete. If implementation reveals a needed
architecture change, update the construction plan first, then adjust the affected
items here. Do not settle an open architecture decision by silently changing a
checklist item. Proposed sizes, rates, and encodings remain experiments until
the corresponding decision has evidence.

- Keep IDs such as `P2.3` stable so commits, issues, and reports can refer to them.
- Treat each checkbox as an independently reviewable slice. Split a large item
  into suffixed IDs, such as `P2.3a`, preserving the parent ID and acceptance goal.
- An item is done when its deliverable and stated evidence exist. Add a relative
  link to the implementation, test, or report beside the checked item.
- Record a blocker and the missing prerequisite beside an item; leave it unchecked.
- A phase exits only when its required items and exit gate are satisfied. An
  evaluation may finish with a documented decision to defer the capability.
- No durations or calendar commitments are assigned in this draft. Sequence by
  dependencies and measured risk; use the architecture document for target context.

Follow [formatting_guide.md](formatting_guide.md) for source changes. Existing
locations are `lib/` for hardware, `bin/` for executables, `test/` for tests, and
`tinytapeout/` for ASIC integration. New model, assembler, host, and firmware
locations should be chosen when their first real implementation lands.

### Ownership and external prerequisites

Follow the construction plan's [stack ownership](construction-plan.md#stack-ownership-and-document-authority).
The emulator owns behavioral logic, firmware, host operations, and application
verification. `hardcaml_asic` owns project/resource/target/flow infrastructure;
Workbench owns optional development jobs and views. Library implementation work
belongs in those repositories, with dependency evidence linked here.

P0.6/P0.7 consume APIs and backends developed within the ASIC library's
[first milestone](../../hardcaml_asic/docs/architecture.md#8-first-implementation-milestone):
project/context/build APIs, TT/CMOS5L resolution/emission, and behavioral/flop
`Single_port_ram` implementations with conformance tests. Emulator adoption helps
close that library milestone; it need not already be complete before integration
starts. These are planned, not available APIs at this review. Ordinary elaboration
must not bootstrap tools or fetch a PDK. Track dependency revisions and reproduction instructions when
adopting the library; a sibling checkout path alone is not dependency management.

## 2. Phase map and first working slice

| Phase | Outcome | Main prerequisites | Architecture source |
| --- | --- | --- | --- |
| P0 — Tool path | Observable RTL, adopted ASIC bundle, registered flop memory, and a proven small physical-flow run | Existing P0 path; ASIC project/resource APIs for P0.6/P0.7 | [§8](construction-plan.md#8-construction-sequence), [flow plan](../tinytapeout/README.md) |
| P1 — Execution model | Executable contracts, typed programs, and encoding study | Can begin alongside P0 | [§3](construction-plan.md#3-initial-architecture), [§4](construction-plan.md#4-minimum-control-isa-and-memory-study) |
| P2 — Reusable primitives | Verified pins, timing, events, transfers, and queues | Relevant P1 contracts; P0 emitter for RTL checks | [§3](construction-plan.md#3-initial-architecture), [§9](construction-plan.md#9-verification-and-measurements) |
| P3 — Reloadable system | Core, storage, loader, and CLI execute replaceable programs | P1 execution specification, relevant P2 blocks, P0.6/P0.7 storage integration | [§4](construction-plan.md#4-minimum-control-isa-and-memory-study), [§7](construction-plan.md#7-host-control-now-application-later) |
| P4 — Baseline protocols | UART, SPI, and I2C firmware with independent peer tests | P3 integration; early tests can start on P1/P2 | [§5](construction-plan.md#5-protocol-milestones-and-acceptance-tests) |
| P5 — Physical selection | Measured configuration and explicit stretch decisions | P0 flow; P2/P3 candidates; P4 workloads | [§6](construction-plan.md#6-keeping-usb-and-ethernet-possible), [§10](construction-plan.md#10-decisions-to-resolve-with-evidence) |
| P6 — Tapeout preparation | Reproducible, checked submission package and bring-up procedure | P4 baseline and P5 configuration decision | [§8](construction-plan.md#8-construction-sequence), [§9](construction-plan.md#9-verification-and-measurements) |
| Later — Application | Optional Workbench integration and operator workflow over the host API | Driver/artifact support for development; P3 for device operations | [§7](construction-plan.md#7-host-control-now-application-later) |

Phases are gates, not a requirement to finish every item before starting any work
in the next phase. P0 and P1 interleave. Primitive and memory measurements begin
as soon as candidates exist, then accumulate toward P5. Target-mode latency
experiments should start before the complete baseline is finished. Run ASIC
adoption alongside the UART slice; full P0 closure is not a prerequisite for
model or primitive work. P0.6 precedes P0.7; both precede P3 hardware storage
integration. P5.1a macro investigation starts early but does not block the explicit
flop path. Workbench integration is optional throughout.

### First working slice: programmable UART transmit

Use this sequence as the initial implementation queue:

1. `P1.1` and the pin/timer portion of `P1.2`: specify cycle edges, pin commits,
   reset, and timed waits in a small executable model.
2. `P2.1` and the countdown portion of `P2.3`: implement atomic pin updates and
   timing with focused model/Hardcaml comparisons.
3. Reuse `P0.1`–`P0.3`'s completed tool path for the evolving observable circuit;
   rerun its checks without treating the original P0 tests as UART evidence.
4. `P1.3` and `P2.7`: drive a typed UART 8N1 transmit sequence through a test
   harness and check the waveform with an independent receiver/timing monitor.
5. `P0.4`–`P0.5`: harden the same small design and record its physical cost.
   P0.6 adopts the ASIC-generated bundle and revalidates the path; P0.7 adds a
   separate small program-memory integration without requiring a full CPU.

The slice is complete when model, Hardcaml, and emitted RTL agree on the UART
frame and reset/disable release behavior, and the small physical run has recorded
results. Simulation work can progress while the physical environment is prepared.
The harness may issue typed commands directly; runtime loading and a full control
core are P3 deliverables. This early demonstration does not complete baseline UART.
Its functional work does not wait for the ASIC APIs, an SRAM macro, or Workbench;
full P0 closure also requires the adoption evidence below.

## 3. P0 — Make the tool path real

**Entry:** the existing Dune/Hardcaml scaffold. Coordinate the observable circuit
with the first pin/timer work in P1/P2.

- [x] **P0.1 — Establish generation.** Make `bin/generate.ml` a working command
  that emits a named, observable pin/timer circuit. Define the output path and
  parameters. Evidence: the build succeeds, generation is repeatable for the
  same inputs, and the emitted design contains functional outputs. Evidence:
  [`p0_observable.ml`](../lib/p0_observable.ml),
  [`generate.ml`](../bin/generate.ml), and
  [`check-p0.sh`](../tinytapeout/scripts/check-p0.sh).
- [x] **P0.2 — Integrate the wrapper.** Add the thin Tiny Tapeout wrapper, explicit
  RTL source list, metadata, and provisional pin map under `tinytapeout/`.
  Specify reset polarity conversion, synchronized reset release, and disable
  behavior. Evidence: wrapper tests observe output changes and released protocol
  pins during reset/disable, with all wrapper outputs assigned. Evidence:
  [`project.v`](../tinytapeout/src/project.v),
  [`info.yaml`](../tinytapeout/info.yaml), and
  [`tb.v`](../tinytapeout/test/tb.v).
- [x] **P0.3 — Test emitted RTL.** Add a reproducible generation and HDL simulation
  command using the wrapper. Compare a timed output trace with the Hardcaml
  expectation. Evidence: reset, enable/disable, pin value/enable, and timer
  transitions pass at the wrapper boundary. Evidence:
  [`test_hardcaml_protemu.ml`](../test/test_hardcaml_protemu.ml),
  [`test-rtl.sh`](../tinytapeout/scripts/test-rtl.sh), and the
  [P0 experiment record](../tinytapeout/reports/2026-09-14-p0-tool-path.md).
- [ ] **P0.4 — Establish the physical environment.** Select exact CMOS5L template,
  action, support-tool, container, and PDK revisions; validate the requested
  floorplan with that flow. Implement the staging layout described in the
  [flow plan](../tinytapeout/README.md). Keep explicit environment preparation
  separate from elaboration and execution; existing bootstrap/staging scripts
  remain usable during adapter migration. Evidence: a reproducible staged project
  reaches synthesis with the intended libraries and source files. The official
  `6x4` floorplan and pinned support-tools checkout are validated during staging;
  mapped CMOS5L synthesis remains to be run. Revisions and staging are recorded in
  [`toolchain.lock`](../tinytapeout/toolchain.lock) and the
  [P0 experiment record](../tinytapeout/reports/2026-09-14-p0-tool-path.md).
- [ ] **P0.5 — Complete the first physical run.** Run placement/routing, timing,
  required physical checks, precheck, and a gate-level wrapper test for the small
  circuit. Save an [experiment record](../tinytapeout/reports/README.md) with
  commands, exact inputs, artifacts, results, and any remaining limitations.
  Preserve scripts as consumers of the bundle; no library runner is required.
  After P0.6, validate this run against the adopted bundle, including source sets
  and generated configuration, before closing the phase.
- [ ] **P0.6 — Adopt the ASIC project declaration.** Integrate the planned
  `Project`/`Elaboration_context`/`Build` path with the observable circuit and
  emulator-owned wrapper. Declare TT harness plus CMOS5L technology, clocks,
  metadata/pin meanings, resource policies, and reasoned flow overrides. Resolve
  dependency versions without relying on a particular sibling directory.
  Evidence: repeatable bundle emission, validated top-level interface, generated
  TT metadata/constraints/configuration, separate simulation/synthesis source
  lists, immutable manifest, and rerun P0 wrapper regression. Conflicting clock,
  source-list, or target-derived overrides produce diagnostic errors. Preserve
  P0.1–P0.3 as evidence for the original path, not proof of this migration.
- [ ] **P0.7 — Exercise registered program memory.** After P0.6 and library
  backend conformance, elaborate a small load/readback design using context-
  registered `Single_port_ram` and an explicitly selected flop implementation.
  Evidence: latency-one read, disabled-output hold, whole-word writes, consumer
  validity/access gating, and independence from unspecified outputs pass model/
  RTL integration checks; the manifest records shape, identity, and selection.
  Consume the emitted bundle with the pinned flow and record mapped synthesis
  cost. This fixture does not complete P3's loader or instruction execution.

**Exit gate:** P0.1–P0.7 have evidence. A small observable design from the adopted
ASIC bundle passes generated-RTL simulation, CMOS5L hardening, required physical
checks, precheck, and gate-level wrapper testing; the small registered-memory
design passes integration and mapped synthesis. Tool availability, an emitted
bundle, or synthesis alone does not establish physical closure.

## 4. P1 — Define execution before committing to an ISA

**Entry:** architecture contracts in sections 3–4. P0 need not be complete.

- [ ] **P1.1 — Make cycle semantics executable.** Define independent OCaml model
  state and one-cycle advancement. Cover command acceptance, parameter latching,
  commit edges, delays, wait arming, event/timeout precedence, set/ack precedence,
  reset, disable, STOP, ABORT, and idle-only single-step. Evidence: small examples
  assert exact edge behavior, including simultaneous-event cases. Model the
  program store's shared port, latency-one reads, disabled-output hold, and
  fetch validity; unspecified memory results cannot be accepted as instructions.
- [ ] **P1.2 — Model the mechanism interfaces.** Add typed pin commands, timing
  requests, transfer descriptors, events, and FIFO operations. Define validation,
  ownership, blocking/nonblocking behavior, and safe abort results before opcode
  encoding. Evidence: legal examples run and invalid descriptors, conflicts,
  zero delays, and queue boundary cases produce specified outcomes.
- [ ] **P1.3 — Build the first firmware helpers.** Add labels, validation, and
  helpers for UART TX, a mode-0 SPI exchange, and explicit I2C drive/sample/wait
  sequences. Evidence: model traces show the expected transactions and record
  operation counts and response latency. No textual DSL is required.
- [ ] **P1.4 — Compare instruction and storage candidates.** Evaluate 16-bit
  instructions with extensions against fixed 32-bit instructions using the same
  examples. Use the settled 1RW latency-one memory contract; record memory-word
  width, instruction packing, byte order, extension fetches, register/flag
  semantics, branch paths, and invalid-instruction behavior. Evidence: an initial
  report of encoded program sizes and cycle counts; leave physical area columns
  unmeasured until P5 supplies results.
- [ ] **P1.5 — Establish shared encoding and independent execution.** Choose a
  provisional encoding through a recorded architecture decision, implement the
  assembler with validation, and expose one instruction specification for the
  assembler and RTL decoder. Keep reference execution independent of RTL logic.
  Evidence: encoding boundary cases and labeled programs have expected bytes,
  decoded meanings, and model execution traces.
- [ ] **P1.6 — Define the verification harness.** Establish driver, monitor,
  trace, seed, and failure-artifact conventions, and fill in testbench guidance
  in the formatting guide. Reserve the logical bitstream boundary and metadata
  from architecture section 6 without implementing stretch engines. Evidence:
  at least one model/Hardcaml comparison uses the harness and a failing case
  can be reproduced from its recorded inputs. Link ASIC backend conformance
  separately from emulator consumer checks; compare only defined memory outputs
  across backends and check held outputs within each backend. Simulation poison
  must not become synthesized logic or a required physical output value.

**Exit gate:** UART/SPI/I2C examples execute in the model, execution contracts are
testable, and program sizes and path timing are recorded. The chosen encoding is
usable for P3 while remaining subject to physical evaluation in P5.

## 5. P2 — Implement and verify reusable primitives

**Entry:** the relevant P1 contracts, incrementally. Use P0 generation for emitted
RTL checks and its physical environment for per-block measurements. These are
emulator primitives; small FIFOs/registers remain flop logic, not v0.1 ASIC RAM
resources. Behavioral implementation can proceed before ASIC adapter availability.

- [ ] **P2.1 — Atomic pin bank.** Implement eight logical pins with registered
  value/enable, masked commits, ownership, and sticky conflict reporting.
  Evidence: masked writes preserve other pins, overlapping claims are rejected,
  open-drain operations never drive high, and reset/disable/abort release pins
  according to the contract.
- [ ] **P2.2 — Input and event front end.** Add synchronization, registered
  snapshots, edge detection, latched status, acknowledgement, and overflow
  reporting where applicable. Evidence: asynchronous-phase sweeps, stale-edge
  rejection, set-wins acknowledgement, and reset cases pass. Record the observed
  digital latency range and assumptions about minimum pulse width.
- [ ] **P2.3 — Timing and waits.** Implement countdown, periodic ticks, level/edge
  waits with timeout, and event-based phase restart. Evidence: exact delay edges,
  zero-delay rejection, immediate level completion, event-over-timeout precedence,
  and waits that leave active engines running match the model.
- [ ] **P2.4 — Data queues.** Implement configurable small TX/RX FIFOs with
  explicit ready/valid, full/empty, validity reset, and fault behavior. Evidence:
  simultaneous push/pop and boundary cases preserve ordering and occupancy with
  no loss or duplication; starvation/overflow follows the specified policy.
- [ ] **P2.5 — Internally paced transfers.** Implement the candidate shift lane
  with lengths 1..32, both bit orders, TX-only/RX-only/duplex, initial preload,
  separate launch/sample phases, and latched descriptors. Evidence: first/last
  bit placement, pin conflicts, invalid phase combinations, completion, and
  underrun/overrun safe aborts match the model.
- [ ] **P2.6 — Observed-event transfers.** Add generic preconfigured arming/start
  and external-edge pacing on top of P2.2/P2.5. Align observed clock, select, and
  data paths. Evidence: phase sweeps measure event-to-engine and event-to-core-
  decision-to-pin latency; externally interrupted transfers release ownership.
  Record limits needed for UART RX and SPI target experiments.
- [ ] **P2.7 — Close the first UART TX demonstration.** Connect P1.3's sequence
  to the pin/timer hardware and the emitted-RTL harness. Evidence: an independent
  monitor checks idle, start, data, stop, bit periods, and reset/disable during
  transmission. Save matching model and RTL traces for the first working slice.
- [ ] **P2.8 — Record primitive costs and invariants.** Measure mapped sequential
  and combinational area per block/configuration using P0's flow. Exercise pin
  ownership, open-drain, FIFO, handshake, reset, and wait invariants; apply formal
  checks where useful and record environmental assumptions and checks not run.
  Use declared configurations and link costs to build/selection and execution
  identities; label legacy pre-adoption measurements explicitly.

**Exit gate:** primitives agree with the model on normal and fault paths, the
first UART TX slice works, and initial per-block area and latency evidence exists.
Filtering, extra descriptor slots, and extra lanes remain measured decisions.

## 6. P3 — Make the system reloadable

**Entry:** P1 execution/encoding and the required P2 primitives; hardware storage
uses P0.6/P0.7's adopted ASIC path. Model host work can begin before that path or
the complete hardware integration is ready.

- [ ] **P3.1 — Program store and load validity.** Replace the scaffold's memory
  with context-registered `hardcaml_asic.Single_port_ram` (1RW, latency one).
  Keep program/loaded-image validity and bounds enforcement in the emulator.
  Gate both host writes and readback on halted-and-engines-idle; reject requests
  during execution without consuming a fetch cycle. Require verified load-complete
  before RUN. Evidence: partial loads, reset, out-of-image/out-of-range fetches,
  and attempted live accesses cannot start or corrupt execution; post-write and
  unwritten outputs are never valid instructions. RAM is not bulk-reset or assumed
  initialized; selection and any allowed fallback are recorded in the build.
- [ ] **P3.2 — Minimal control execution.** Implement fetch/decode, registers,
  flags, state operations, branches/loops, and halt for the provisional ISA.
  Evidence: independent-model comparisons cover each implemented instruction,
  taken/untaken paths, latency-one fetches, stalled fetch/output hold, pipeline
  validity, extension-word fetches, invalid instructions, and cycle counts.
- [ ] **P3.3 — Core-to-engine integration.** Connect pin, time, transfer, event,
  and FIFO instructions. Add boundary STOP, prompt ABORT, and single-step with
  engines idle. Evidence: engines continue through ordinary core waits; completion,
  faults, ownership, queue pressure, and interruption match reference traces.
- [ ] **P3.4 — Host API and simulator backend.** Define version/capability
  discovery, program load/readback, pin configuration, data queues, execution
  control, register/engine inspection, and bounded timestamped trace retrieval.
  Add CLI operations over a simulator backend. Evidence: a scripted CLI workflow
  loads, verifies, runs, exchanges data, and retrieves status; trace overflow is
  observable and capability/ISA mismatches have defined errors. Advertise memory
  width/depth and image format; active-execution program-access requests have a
  defined rejection. Keep ordinary status/data-queue operations separate.
- [ ] **P3.5 — Independent hardware loader.** Specify the dedicated serial link's
  framing, pin allocation, host clock envelope, acknowledgement, length/error
  checks, byte order/word assembly, and flow control before implementation.
  Issue only complete configured memory words; reject incomplete trailing words
  without declaring the image valid. Add fixed loader logic and
  wrapper integration independent of firmware execution. Evidence: malformed or
  interrupted loads are rejected and a halted/broken program remains recoverable.
- [ ] **P3.6 — Device backend and reload demonstration.** Implement the physical
  transport backend and run its transaction sequence against wrapper simulation;
  exercise hardware when available. Use the same CLI/API to load and run two
  different protocol programs without regenerating RTL. Evidence: readback,
  observed pin transactions, data exchange, status, and recovery traces; state
  explicitly whether the backend has been verified on a board.

**Exit gate:** one generated hardware design can load/read back/run two protocol
programs, exchange bytes, and report status through the host workflow. Recovery
does not depend on a functioning user program.

## 7. P4 — Complete baseline protocol firmware

**Entry:** P3's runnable system. Build independent peer models and initial
firmware against P1/P2 earlier where practical. Support one selected protocol at
a time initially; do not infer concurrent protocols or independent UART duplex.

- [ ] **P4.1 — UART TX baseline.** Run programmable 8N1 TX at the architecture's
  initial 115,200-baud study target, including back-to-back frames. Evidence:
  independent receiver checks, bit-period measurements, and TX FIFO fault paths.
- [ ] **P4.2 — UART RX and duplex evaluation.** Add RX with event-aligned start
  detection, false-start rejection, and framing status. Sweep asynchronous phase,
  baud mismatch, back-to-back frames, RX queue pressure, and rates toward the
  proposed 1 Mbaud target. Measure unrelated TX/RX frame starts; record whether
  the initial lane arrangement supports them or a second lane is needed.
- [ ] **P4.3 — SPI controller.** Progress from mode-0 bytes to all four modes,
  both bit orders, selected widths 1..32, and CS held across words. Study 1 MHz
  then 5 MHz subject to clock compatibility. Evidence: independent-peer checks
  for preload, first/last bits, CS timing, unequal half-periods, and legal pauses.
- [ ] **P4.4 — SPI target.** Start with preloaded responses at a conservative
  external clock, then exercise all four modes. Evidence: phase/setup/hold sweeps,
  minimum SCK high/low widths, CS assertion/abort, first-bit preload, and underrun
  behavior. Publish a measured clock envelope; the target cannot stretch SCK.
- [ ] **P4.5 — I2C controller.** Implement 7-bit addressing and write/read with
  ACK/NACK at the proposed 100 kbit/s target, then repeated START, final-read NACK,
  STOP, stretch wait/timeout, and a 400 kbit/s evaluation. Evidence: resolved
  open-drain bus tests with pull-ups cover actual SCL observation, stuck bus,
  NACK paths, and forced arbitration loss followed by release.
- [ ] **P4.6 — I2C target.** Progress from address match and a byte response to
  read/write sequences, repeated START/STOP, ACK/NACK, and intentional stretching.
  Evidence: independent-controller checks of SDA stability while SCL is high,
  STOP during waits, response latency, read termination, and bus release.
- [ ] **P4.7 — Publish the baseline coverage matrix.** Collect firmware images,
  reproduction commands/seeds, tested configurations, rates, external timing
  assumptions, min/max response latency, queue/host service budgets, fault results,
  and concurrency limits. Include wrapper-level regression and FPGA/board exercise
  if available, distinguishing modeled, RTL, routed, and board evidence. Link
  firmware/image hashes, hardware configuration, selected memory implementation,
  and ASIC build/run identities so coverage survives configuration sweeps.

**Exit gate:** each baseline mode has firmware and independent-peer evidence for
its normal, interruption, and failure paths. Unsupported rates/features are
explicit. Forced arbitration-loss handling does not claim full multi-controller
I2C support. Rate claims remain conditional on P5 timing and the board boundary.

## 8. P5 — Select the physical architecture using measurements

**Entry:** P0's working flow and representative P2/P3 candidates. Start studies
early; use P4's full workloads before making the final configuration decision.

- [ ] **P5.1 — Compare storage and encoding costs.** Sweep the construction plan's
  instruction encodings, memory widths/depths, register configuration, and FIFO
  depths with identical workloads through ASIC project declarations. Start with explicit flop storage;
  compare a macro only after P5.1a and helper-library backend conformance pass.
  Evidence: firmware size, packing/fetch counts, storage bits, mapped area, and
  placed feasibility, linked to resource policies/selections and build/run records.
  Never silently round dimensions, compose macros, or substitute implementations.
- [ ] **P5.1a — Resolve the CMOS5L SRAM capability gate.** Begin alongside P0
  environment preparation. Record candidate existence, exact shape/latency/hold
  compatibility, complete model/Liberty/LEF/GDS and power views, target permission,
  and flow compatibility. Coordinate backend work in `hardcaml_asic` only after
  these prerequisites are established. Evidence: a supported-candidate decision
  with linked evidence or an explicit unavailable/deferred decision. PDK presence
  alone is insufficient. The explicit flop path proceeds either way.
- [ ] **P5.2 — Compare timing and engine configurations.** Measure one lane
  against any justified independent lane or second descriptor slot. Evaluate
  filtering only with glitch/pulse-width evidence. Sweep clock choices and
  integer/fractional schedules where relevant. Evidence: response latency, jitter,
  FIFO refill budget, sustained host throughput, and protocol results per candidate.
- [ ] **P5.3 — Repeat full physical evaluation.** Place and route promising
  configurations from emitted ASIC bundles with reviewed clock, I/O, synchronizer,
  and reset constraints. Use the adapter's protected derived settings and justified
  overrides; avoid independent hand-maintained TT/source/clock configuration.
  Evidence: utilization, routing, worst setup/hold slack, unconstrained paths,
  reviewed exceptions, and required physical checks, linked to exact source and
  tool/PDK revisions. Reconcile protocol timing with pad and board assumptions.
- [ ] **P5.4 — Resolve stretch feasibility.** Evaluate USB/Ethernet only far enough
  to decide whether either belongs in the fabrication scope. Record electrical
  boundary, pins, resources, continuous service budget, and retain/defer decisions.
  Detailed experiments below are conditional; baseline work need not wait for
  implementation of a deferred stretch capability.
- [ ] **P5.5 — Select and document the configuration.** Resolve the decision table
  in construction-plan.md using P4/P5 reports: core/lane count, ISA, memory, clock,
  filters, loader/pins, stretch boundary, and flow integration. Define and record
  resource/timing margin and supported operating limits. Evidence: the selected
  declared configuration and explicit resource policy fit the resolved target
  floorplan with routed timing and stated margin. Rerun affected regressions
  after any selection-driven implementation changes.

### Conditional stretch experiments under P5.4

These items close with experiment evidence or a linked deferral decision. They
do not make USB or Ethernet part of the baseline acceptance gate.

- [ ] **P5.4a — Bitstream mechanisms.** Model logical-bit versus physical-symbol
  consumption, boundaries/error metadata, CRC/LFSR conventions, NRZI/Manchester,
  and run-length insertion/removal. Compare implementations only as needed for
  the feasibility decision. Check known vectors, buffering, and safe aborts;
  internal backpressure must not silently stretch an active waveform.
- [ ] **P5.4b — USB low-speed study.** Model line states, packet boundaries,
  stuffing, CRC5/CRC16, receive recovery, and response deadlines. Report the
  resources and electrical interface required. Distinguish packet-loopback
  evidence from reset, enumeration, control-request, and turnaround support.
- [ ] **P5.4c — Ethernet study.** Choose an external-PHY digital boundary or a
  direct line-interface study before proposing hardware. Measure modeled framing,
  CRC32, and sustained throughput. For a direct interface, include Manchester
  timing/recovery, link behavior, and required collision behavior in the scope.

**Exit gate:** a measured baseline configuration fits with reviewed margins and
supported limits, and stretch capabilities are explicitly retained or deferred.
If a stretch capability is retained for fabrication, add its implementation and
acceptance slices here and complete them before P6 closes. Firmware updates
cannot supply missing hardware resources after fabrication.

## 9. P6 — Prepare and verify the tapeout package

**Entry:** P4 baseline acceptance, P5's selected configuration, and completion of
any explicitly retained stretch work.

- [ ] **P6.1 — Reproduce from a clean checkout.** Pin final tool/PDK/configuration
  inputs, including `hardcaml_asic` and collateral dependencies, and automate
  bundle emission/export, staging, checks, and artifact collection. Resolve them
  without developer-local sibling paths. Decide generated-output snapshot/
  regeneration policy and verify RTL, metadata, constraints, and source sets.
  Evidence: a clean-checkout run produces the intended submission layout without
  relying on untracked local inputs.
- [ ] **P6.2 — Run final functional and gate-level regression.** Run model,
  Hardcaml, emitted-RTL, and flow-supported gate-level checks for the selected
  system. Include load/readback/reload, protocol peers, reset/disable, STOP/ABORT,
  fault recovery, and applicable timing corners. Evidence: reproducible results
  tied to the final generated RTL/netlist and firmware versions.
- [ ] **P6.3 — Close physical and submission checks.** Run final routed timing,
  required physical checks, and Tiny Tapeout precheck with the pinned flow.
  Review emitted constraints, distinct source sets, top/interface, resource
  collateral, pin metadata, and package contents against the declared build.
  Evidence: required checks are clean and reports identify exact final artifacts.
- [ ] **P6.4 — Write the bring-up and recovery guide.** Document pinout, clock,
  reset/enable, electrical assumptions, host wiring, loading, example commands,
  expected protocol observations, supported limits, and broken-program recovery.
  Evidence: the procedure is exercised against the final simulator/wrapper and
  available hardware, with unavailable board validation labeled explicitly.
- [ ] **P6.5 — Assemble the submission candidate.** Bundle design, metadata,
  required layout/netlist outputs, documentation, immutable build manifest and
  separate execution records, preserved inputs/collateral, and validation links.
  Evidence: package completeness and reproduction checks pass. Track actual
  submission separately from preparation of this plan.

**Exit gate:** a complete, reproducible submission candidate has the required
functional and physical evidence, documented operating limits, and a tested
recovery procedure.

## 10. Later — Application on the existing host API

Development Workbench integration and device operation are separate deliverables.
Generic Dune use can start when Workbench supports it; neither track gates P0–P6.

- [ ] **L.1 — Choose the operator interaction surface.** Use the working P3
  CLI/device workflow to decide a Workbench device extension versus a separate
  client and any local-service/browser access. Reuse supported development views;
  Workbench already selects Bonsai Web, but its emulator device extension is not
  specified. Evidence: a recorded placement decision supporting the established
  host API/errors without a second device-control implementation.
- [ ] **L.2 — Implement the operator workflow.** Add program editing/loading,
  capability discovery, data exchange, execution control, and status inspection.
  Use the P3 API and existing source-editing tools for firmware editing.
  Evidence: the same load/run/stop/abort/recovery scenarios as the CLI pass.
- [ ] **L.3 — Add trace inspection.** Present timestamped events/waveforms and
  export, including bounded-trace overflow. Evidence: displayed data agrees with
  CLI exports and failure cases remain visible. Reuse Workbench waveform/event
  views only where their supported formats and semantics fit the emulator trace.
- [ ] **L.4 — Optionally integrate the development Workbench.** After compatible
  Workbench manifest/driver support and P0.6, expose project-owned target discovery,
  generation/check commands, and ASIC build/run artifacts through a small versioned
  manifest/driver in this project's environment. Extend to typed simulation when
  supported. Derive target facts from the ASIC declaration; keep SDK/application
  dependencies out of synthesizable libraries. Evidence: CLI/Dune use still works
  independently; UI jobs reference the same build/execution identities and artifact
  contents, version errors are explicit, and unknown ASIC measurements stay unknown.
  This may close with an explicit deferral and does not gate L.1–L.3.

**Exit gate:** the application exposes the proven host workflow and its errors.
It is not a prerequisite for baseline hardware or tapeout preparation.

## 11. Evidence and completion rules

For implementation slices, run the affected tests and repository build, format,
and lint checks through `scripts/with-switch.sh` as described in the formatting
guide. Record the commands and results with the change. Use focused unit/model
tests for primitives, independent peers for protocol acceptance, and wrapper
tests for emitted RTL and integration; self-loopback alone is insufficient.

Use [tinytapeout/reports/README.md](../tinytapeout/reports/README.md) for physical
experiments. Preserve input/configuration hashes, random seeds, constraints,
tool/PDK revisions, reproduction commands, and artifact links. Use immutable
build manifests plus separate execution records after adoption; retain input
content, dependency/collateral identity, firmware versions, and selection/override
reasons. Label earlier records as legacy rather than inventing manifests. Mark missing
measurements `not run` or `unknown`; do not turn estimates into verified limits.

When selecting the next slice, prefer the earliest unmet prerequisite for the
first working demonstration or the next phase gate. Keep architecture decisions
and their rationale in construction-plan.md, execution status here, and detailed
measurements in linked reports.
