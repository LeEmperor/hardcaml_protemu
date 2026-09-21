# Protocol emulator phase plan

Status: working execution plan, updated 2026-09-21 for P3.5 completion,
2026-09-20 for P3.2 completion,
2026-09-19 for the P1.5 encoding decision, and 2026-09-18 for decoupled RTL
development and P0.6 ASIC library adoption. The
instruction encoding is now provisionally chosen and lives in `isa/`; P0.7 and P3.1
are complete; P0 is closed with registered-memory mapped synthesis and the
clean-staging adopted observable physical reproduction. P0.5 retains its
legacy/adopted records, and pre-adoption P2.8 evidence is defined.
P0.1–P0.3 retain their recorded completion; P0.6 has adopted the observable top.
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
locations are `lib/` for hardware, `bin/` for executables, `test/` for tests,
`isa/` for the instruction specification and assembler, `f_model/` for the reference
execution model, and `tinytapeout/` for ASIC integration. `f_model/` is a separate Dune
library, `protemu_f_model`, with no Hardcaml dependency, so a diagnostic model can never
reach a synthesis source set and cannot share a mistake with the RTL; its tests live in
`test/f_model/`. `isa/` is a third library, `hardcaml_protemu.isa`, below both of them:
P1.5 put the encoding there because `lib/` is installed and `f_model/` is not, so the
assembler and the RTL decoder could not otherwise share one description of the
instruction word. New host and firmware locations should be chosen when their first real
implementation lands.

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
starts. The library's P0–P3, P4.1–P4.4, and P5.1 have evidence, so these
APIs and the flop backend exist and a separate consumer can install the package.
The P0.6 bundle emitter uses the pinned revision in
[`asic-dependencies.lock`](../tinytapeout/asic-dependencies.lock). See
[construction-plan.md §2](construction-plan.md#2-what-exists-today). Ordinary elaboration
must not bootstrap tools or fetch a PDK. Track dependency revisions and reproduction instructions when
adopting the library; a sibling checkout path alone is not dependency management.

## 2. Phase map and first working slice

| Phase | Outcome | Main prerequisites | Architecture source |
| --- | --- | --- | --- |
| P0 — Tool path (closed) | Observable RTL, adopted ASIC bundle, registered flop memory, and a proven small physical-flow run | Existing P0 path; consumable ASIC library (ASIC P5.1) for P0.6/P0.7 | [§8](construction-plan.md#8-construction-sequence), [flow plan](../tinytapeout/README.md) |
| P1 — Execution model | Executable contracts, typed programs, and encoding study | Can begin alongside P0 | [§3](construction-plan.md#3-initial-architecture), [§4](construction-plan.md#4-minimum-control-isa-and-memory-study) |
| P2 — Reusable primitives | Verified pins, timing, events, transfers, and queues | Relevant P1 contracts; P0 emitter for RTL checks | [§3](construction-plan.md#3-initial-architecture), [§9](construction-plan.md#9-verification-and-measurements) |
| P3 — Reloadable system | Core, storage, loader, and CLI execute replaceable programs | P1 execution specification and relevant P2 blocks; P0.6/P0.7 only for P3.1b | [§4](construction-plan.md#4-minimum-control-isa-and-memory-study), [§7](construction-plan.md#7-host-control-now-application-later) |
| P4 — Baseline protocols | UART, SPI, and I2C firmware with independent peer tests | P3 integration; early tests can start on P1/P2 | [§5](construction-plan.md#5-protocol-milestones-and-acceptance-tests) |
| P5 — Physical selection | Measured configuration and explicit stretch decisions | P0 flow; P2/P3 candidates; P4 workloads | [§6](construction-plan.md#6-keeping-usb-and-ethernet-possible), [§10](construction-plan.md#10-decisions-to-resolve-with-evidence) |
| P6 — Tapeout preparation | Reproducible, checked submission package and bring-up procedure | P4 baseline and P5 configuration decision | [§8](construction-plan.md#8-construction-sequence), [§9](construction-plan.md#9-verification-and-measurements) |
| Later — Application | Optional Workbench integration and operator workflow over the host API | Driver/artifact support for development; P3 for device operations | [§7](construction-plan.md#7-host-control-now-application-later) |

Phases are gates, not a requirement to finish every item before starting any work
in the next phase. P0 and P1 interleave. Primitive and memory measurements begin
as soon as candidates exist, then accumulate toward P5. Target-mode latency
experiments should start before the complete baseline is finished. Full P0
closure is not a prerequisite for model, primitive, or core work. P0.6 precedes
P0.7; both precede P3.1b only. P5.1a macro investigation starts early but does not
block the explicit flop path. Workbench integration is optional throughout.

### Non-linear sequencing: RTL decoupled from ASIC adoption

Emulator RTL is developed independently of `hardcaml_asic`, following the rules in
[construction-plan.md §1](construction-plan.md#decoupling-rtl-from-the-asic-tooling):
only the project top touches the library (program-store constructor, project
declaration, bundle emission), and every other module is plain Hardcaml. Store
consumers expose the 1RW port and are tested against a contract model. As a result,
phase numbers describe gates and dependencies, not the order work happens in:

- **P0.6 and P0.7 are adopted.** P0.6 adopted the then-current observable top after
  ASIC P5.1 became available. P0.7 subsequently added registered program memory.
  The physical evidence is complete: P0.5a recorded the legacy
  scripts' own result and P0.5b reran the same design from the adopted bundle,
  so the `tinytapeout/` scripts are now a retired baseline rather than the
  physical path. P0.5c reproduced the adopted observable path from committed
  clean staging. P0.7's memory integration and mapped-synthesis evidence are
  recorded below; together these close P0.
- **P3 splits at the adoption boundary.** P3.1a (program-store consumer logic against
  the contract port) and P3.2–P3.5 proceed without adoption; only P3.1b
  (context-registered `Single_port_ram` at the top) waits for P0.6/P0.7.
- **Area and timing feedback does not wait.** Use the estimate tiers in
  [construction-plan.md §1](construction-plan.md#decoupling-rtl-from-the-asic-tooling):
  generic and liberty-mapped yowasp-yosys runs for per-block comparisons, then the
  existing P0 hardening scripts. Estimates inform choices; they do not close
  physical items.
- **Deferral has accepted costs.** Flow evidence gathered before adoption is labeled
  legacy and must be rerun from the adopted bundle before P0, P5, or P6 close
  (P0.5a's run is repeated as P0.5b). Legacy mapped costs can close P2.8 but not P5
  items. Late
  adoption can surface top-level interface, clock, or metadata mismatches. Keep the
  wrapper thin to bound that rework.
- **The deferral deadline was met.** P0.7/P3.1b landed before P3 exit or P5
  selection work. P5 sweeps can therefore run through project declarations and P6 can
  reproduce from pinned dependencies.

Consumer evidence now closes ASIC P5.3–P5.4 in the
[library's own plan](../../hardcaml_asic/docs/phase_plan.md#8-p5--reference-consumer-adoption-and-initial-usage).
The library's P5.5 usage documentation and therefore M3 remain open; they do
not block continued emulator development or its physical studies.

### First working slice: programmable UART transmit

Use this sequence as the initial implementation queue:

1. `P1.1` and the pin/timer portion of `P1.2`: specify cycle edges, pin commits,
   reset, and timed waits in a small executable model.
2. `P2.1` and the countdown portion of `P2.3`: implement atomic pin updates and
   timing with focused functional-model/Hardcaml comparisons.
3. Reuse `P0.1`–`P0.3`'s completed tool path for the evolving observable circuit;
   rerun its checks without treating the original P0 tests as UART evidence.
4. `P1.3` and `P2.7`: drive a typed UART 8N1 transmit sequence through a test
   harness and check the waveform with an independent receiver/timing monitor.
5. `P0.4` and `P0.5a`: harden the same small design with the existing scripts and
   record its (legacy) physical cost.
   P0.6 bundle adoption is complete independently of this UART slice; P0.7
   program-memory integration remains separate.

The slice is complete when model, Hardcaml, and emitted RTL agree on the UART
frame and reset/disable release behavior, and the small physical run has recorded
results. Both halves now have records: P2.7 holds the agreement and the release
behavior, and P0.5a holds the physical run — of P0's small observable circuit, which is
what that step asked for, not of the UART slice itself. Simulation work can progress while the physical environment is prepared.
The harness may issue typed commands directly; runtime loading and a full control
core are P3 deliverables. This early demonstration does not complete baseline UART.
Its functional work does not wait for the ASIC APIs, an SRAM macro, or Workbench.
P0 is closed: P0.7 has its memory evidence and P0.5c supplies the clean-staging
adopted physical reproduction.

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
  [`wrapper_unit_tests.ml`](../test/integration/wrapper/wrapper_unit_tests.ml),
  [`test-rtl.sh`](../tinytapeout/scripts/test-rtl.sh), and the
  [P0 experiment record](../tinytapeout/reports/2026-09-14-p0-tool-path.md).
- [x] **P0.4 — Establish the physical environment.** Select exact CMOS5L template,
  action, support-tool, container, and PDK revisions; validate the requested
  floorplan with that flow. Implement the staging layout described in the
  [flow plan](../tinytapeout/README.md). Keep explicit environment preparation
  separate from elaboration and execution; existing bootstrap/staging scripts
  remain usable during adapter migration. Evidence: a reproducible staged project
  reaches synthesis with the intended libraries and source files. The official
  `6x4` floorplan and pinned support-tools checkout are validated during staging.
  Revisions and initial staging are recorded in
  [`toolchain.lock`](../tinytapeout/toolchain.lock) and the
  [P0 experiment record](../tinytapeout/reports/2026-09-14-p0-tool-path.md).
  *Done:* the [P0.5c clean-staging record](../tinytapeout/reports/2026-09-20-p0.5c-clean-staging-physical.md)
  demonstrates committed-source restoration, isolated installation of the locked
  library, pinned tool/PDK preflight, mapped CMOS5L synthesis and full hardening
  on the intended `6x4` floorplan. Actual versions and the explicit Python
  mismatch waiver are preserved in the
  [run archive](../flow_results/20260920-081325-ccecd9ed/README.md).
- [x] **P0.5 — Complete the first physical run.** Split at the adoption boundary;
  P0.5 is checked only when both parts are.
  *Done:* both parts have records; see each below.
  - [x] **P0.5a — Legacy physical run.** Using the existing `tinytapeout/` scripts,
    run placement/routing, timing, required physical checks, precheck, and a
    gate-level wrapper test for the small circuit. Save an
    [experiment record](../tinytapeout/reports/README.md) labeled legacy, with
    commands, exact inputs, artifacts, results, and remaining limitations.
    Evidence: that record. This satisfies the first working slice's physical
    step, not the P0 exit gate.
    *Done:* the [legacy physical record](../tinytapeout/reports/2026-09-19-p0.5a-legacy-physical.md)
    covers the 2026-09-19 run at source `7e29ecd` from a clean tree. The design
    closes on all three reported corners (worst setup 11.3135 ns, worst hold
    0.15566 ns, no total negative slack); routing DRC converged to zero, Magic
    DRC, LVS and antenna are zero, precheck passes all nine rows, and the
    gate-level wrapper test passes. Producing it required three workarounds on
    that path, recorded in the same note: `harden-cmos5l.sh` counted the
    router's `route__drc_errors__iter:N` convergence history as violations and
    reported a false "does not close" (fixed here, and re-applied to the
    preserved metrics); `tinytapeout/test/Makefile` omits the PDK's
    `sg13cmos5l_udp.v`, so the gate-level target cannot elaborate a design with
    flops; and that target assumes a host `iverilog` this machine no longer
    has. Only the first is fixed in the repository.
  - [x] **P0.5b — Adopted-bundle physical run.** After P0.6, repeat P0.5a's run
    from the emitted bundle, with scripts as bundle consumers (no library runner
    is required). Evidence: a new record linked to the build manifest, with
    source sets and generated configuration checked against the declaration and
    any differences from P0.5a explained.
    *Done:* the [adopted physical record](../tinytapeout/reports/2026-09-19-p0.5b-adopted-physical.md)
    covers build identity `5edf30f9…` / run `05f650428c…`, with curated
    artifacts at [`flow_results/20260918-230920-05f65042`](../flow_results/20260918-230920-05f65042/README.md).
    `./flow.sh` ran `build → emit → preflight → run → postcheck → collect →
    report → archive` unattended. Worst setup 15.5891 ns and worst hold
    0.14745 ns with no unconstrained mode; DRC, LVS, antenna, all nine precheck
    rows and the gate-level wrapper test pass; inferred latches, unmapped
    instances and synthesis errors are zero. Differences from P0.5a are
    explained in the record and trace to one cause: the legacy configuration
    supplies no SDC, so its slack figures describe LibreLane's defaults rather
    than this design's declared constraints, and the two numbers are not
    directly comparable. The run predates the `Tt_cmos5l` template adoption,
    but re-emitting from the current declaration at `7e29ecd` produces
    byte-identical `config.json`, `top.sdc`, `info.yaml` and RTL, so it still
    describes what this repository emits today. The later
    [P0.5c clean-staging reproduction](../tinytapeout/reports/2026-09-20-p0.5c-clean-staging-physical.md)
    closes the provenance limitation: committed `8d3ada1`, bundle `85729c18…`,
    and run `ccecd9ed…` pass the same physical/check acceptance, with the
    [complete bundle and run archive](../flow_results/20260920-081325-ccecd9ed/README.md)
    restored and revalidated independently.
- [x] **P0.6 — Adopt the ASIC project declaration.** Integrate the planned
  `Project`/`Elaboration_context`/`Build` path with the observable circuit and
  emulator-owned wrapper. Declare TT harness plus CMOS5L technology, clocks,
  metadata/pin meanings, resource policies, and reasoned flow overrides. Resolve
  dependency versions without relying on a particular sibling directory.
  Evidence: repeatable bundle emission, validated top-level interface, generated
  TT metadata/constraints/configuration, separate simulation/synthesis source
  lists, immutable manifest, and rerun P0 wrapper regression. Conflicting clock,
  source-list, or target-derived overrides produce diagnostic errors. Preserve
  P0.1–P0.3 as evidence for the original path, not proof of this migration.
  *Done:* [`asic_bundle.ml`](../bin/asic_bundle.ml) declares the then-current
  observable top, and [`asic-adoption.md`](asic-adoption.md) documents package
  pinning and emission. [`check-adopted-bundle.py`](../tinytapeout/scripts/check-adopted-bundle.py)
  passes repeatable emission, metadata and configuration conflicts, and the
  existing wrapper regression, Verilator lint, and generic synthesis against
  emitted RTL in the pinned LibreLane image. P0.5b has since recorded the
  physical rerun; P0.5c has since reproduced it from committed clean staging.
- [x] **P0.7 — Exercise registered program memory.** After P0.6 and library
  backend conformance, elaborate a small load/readback design using context-
  registered `Single_port_ram` and an explicitly selected flop implementation.
  Evidence: latency-one read, disabled-output hold, whole-word writes, consumer
  validity/access gating, and independence from unspecified outputs pass f_model/
  RTL integration checks; the manifest records shape, identity, and selection.
  Consume the emitted bundle with the pinned flow and record mapped synthesis
  cost. This fixture does not complete P3's loader or instruction execution.
  *Done:* P3.1a's 256x16 consumer is connected to context-registered
  `Single_port_ram` in [`asic_bundle.ml`](../bin/asic_bundle.ml), with explicit
  `Flops` policy and stable resource name `program`. Independent consumer,
  behavioral/flop elaboration, and both emitted-RTL checks cover latency,
  whole-word load/readback, validity, hold, bounds, rejected accesses, reset,
  disable, and unspecified-output independence. Bundle `7ce444837068766c...` /
  run `a538212c80fb407b...` completed mapped CMOS5L synthesis at 16,294 cells
  and 349,314.9408 um^2 with zero latches, unmapped instances, or synthesis
  errors. See the
  [P0.7 record](../tinytapeout/reports/2026-09-20-p0.7-memory-synthesis.md) and
  [archive](../flow_results/20260920-071538-a538212c/README.md). This is
  synthesis-only evidence, not SRAM or physical closure. The archive now carries
  the complete original dirty-tree input bundle. A raw ABC driving-cell lookup
  diagnostic qualifies only ABC's post-map delay print for this `AREA 0` run;
  source-backed investigation found that mapping and area were unaffected.

**Exit gate met — P0 closed, 2026-09-20:** P0.1–P0.7 have evidence, including
P0.5b and its [P0.5c clean-staging reproduction](../tinytapeout/reports/2026-09-20-p0.5c-clean-staging-physical.md).
The observable design from the adopted ASIC bundle passes generated-RTL
simulation, CMOS5L hardening, three-corner timing, required physical checks,
all nine TT prechecks, and final-netlist wrapper testing. The registered 256x16
flop-memory design separately passes [consumer integration and mapped synthesis](../tinytapeout/reports/2026-09-20-p0.7-memory-synthesis.md).
The clean physical run used consumer `8d3ada1`, build `85729c18…`, and run
`ccecd9ed…`; its evidence and the memory evidence are committed at `61384c3`.
This closes the initial tool path. Memory physical feasibility and final-system
selection remain P5.1/P5.3 work; SRAM capability remains P5.1a and the ASIC
library's separate S track.

## 4. P1 — Define execution before committing to an ISA

**Entry:** architecture contracts in sections 3–4. P0 need not be complete.

- [x] **P1.1 — Make cycle semantics executable.** Define independent OCaml model
  state and one-cycle advancement. Cover command acceptance, parameter latching,
  commit edges, delays, wait arming, event/timeout precedence, set/ack precedence,
  reset, disable, STOP, ABORT, and idle-only single-step. Evidence: small examples
  assert exact edge behavior, including simultaneous-event cases. Model the
  program store's shared port, latency-one reads, disabled-output hold, and
  fetch validity; unspecified memory results cannot be accepted as instructions.
  Evidence: [`machine.ml`](../f_model/machine.ml) holds the whole model state and one
  rising edge, with [`program_store.ml`](../f_model/program_store.ml) as the contract
  model of the 1RW port; [`test_cycle.ml`](../test/f_model/test_cycle.ml) asserts each
  listed behavior edge by edge, including set-with-acknowledge and
  event-with-timeout at the same edge. *Carried forward:* the model has no decoder
  (P1.5 chooses the encoding), so an instruction boundary is modeled as a fetched
  word being consumed or a stalling operation completing, and the fetched word is
  checked for validity and discarded. P3.2 may revisit that definition.
- [x] **P1.2 — Model the mechanism interfaces.** Add typed pin commands, timing
  requests, transfer descriptors, events, and FIFO operations. Define validation,
  ownership, blocking/nonblocking behavior, and safe abort results before opcode
  encoding. Evidence: legal examples run and invalid descriptors, conflicts,
  zero delays, and queue boundary cases produce specified outcomes. Evidence:
  [`operation.ml`](../f_model/operation.ml) (the vocabulary and structural
  validation), [`transfer.ml`](../f_model/transfer.ml) (descriptor and its rules),
  [`pin_bank.ml`](../f_model/pin_bank.ml) (masked atomic commits and exclusive drive
  ownership), [`event.ml`](../f_model/event.ml), [`fifo.ml`](../f_model/fifo.ml), and
  [`fault.ml`](../f_model/fault.ml), checked by
  [`test_mechanisms.ml`](../test/f_model/test_mechanisms.ml), which pins down which
  reason each refusal reports rather than only that one occurred. *Carried
  forward:* nothing drains a queue until P2.5's engine or P3.4's host port exists,
  so a blocking queue operation ends only through ABORT, reset, or disable, which
  raises the sticky queue fault; a transfer descriptor is validated and latched but
  not executed, which is P2.5. The module is named `Operation` rather than
  `Command` only because `Core.Command` shadows that name inside the library.
- [x] **P1.3 — Build the first firmware helpers.** Add labels, validation, and
  helpers for UART TX, a mode-0 SPI exchange, and explicit I2C drive/sample/wait
  sequences. Evidence: model traces show the expected transactions and record
  operation counts and response latency. No textual DSL is required.
  Evidence: [`firmware.ml`](../f_model/firmware.ml) is the labeled sequence
  library: steps, label uniqueness, structural validation of every operation
  against the rule the machine applies at acceptance, a board model for the device
  on the other end, and a runner that records each operation's offer, acceptance,
  and completion edges beside a per-edge log of what the bank drove and what the
  input front end presented. [`firmware_uart.ml`](../f_model/firmware_uart.ml)
  builds the 8N1 frame two ways, as one transfer descriptor and as a bit-banged
  sequence; [`firmware_spi.ml`](../f_model/firmware_spi.ml) builds a mode-0 exchange
  against an independent target that launches on the falling edge; and
  [`firmware_i2c.ml`](../f_model/firmware_i2c.ml) builds a single-master write
  transaction from open-drain writes, acknowledge samples, and clock-stretch level
  waits, against a target that acknowledges by address and can hold the clock
  down. [`test_firmware.ml`](../test/f_model/test_firmware.ml) holds the traces and
  the recorded costs, at half and quarter period four:

  | Sequence | Operations | Cycles | Max response |
  | --- | --- | --- | --- |
  | UART 8N1 transmit | 22 | 88 | 7 |
  | SPI mode-0 eight-bit exchange | 36 | 72 | 3 |
  | I2C write, address plus one byte | 105 | 224 | 10 |

  The same UART frame as one `Configure_transfer` is a single operation, and the
  engine then occupies eighty cycles without the core; the bit-banged sequence and
  the descriptor run through [`shift_engine.ml`](../f_model/shift_engine.ml) both
  decode to the transmitted byte under an independent bit-center receiver. That
  pair of numbers is what P1.4 needs to weigh an instruction stream against a
  transfer engine. An I2C acknowledge slot's clock phase costs 14 cycles against
  an ordinary bit slot's 6 while the target stretches for 12, and a target that
  stretches past the timeout produces `Wait_timeout` rather than a blind clock. On
  a bus with no target the pull-ups hold both lines high and every acknowledge
  slot reads a one, so nothing infers a bus level from what it meant to drive.
  *Carried forward:* a label is a program point that structures the trace and its
  per-region counts, not a branch target, because no branch operation exists until
  P1.5 chooses the encoding. Sampling a pin is a trace marker rather than an
  operation, since reading one into a register needs the register file and
  input-read operation of P1.4 and P1.5. The runner offers one operation per edge
  and nothing fetches or decodes, so every cycle count above is a floor that P3.2
  can only raise. The SPI and I2C targets are model-side evidence; independent
  peer hardware and the full baseline modes are P4.
- [x] **P1.4 — Compare instruction and storage candidates.** Evaluate 16-bit
  instructions with extensions against fixed 32-bit instructions using the same
  examples. Use the settled 1RW latency-one memory contract; record memory-word
  width, instruction packing, byte order, extension fetches, register/flag
  semantics, branch paths, and invalid-instruction behavior. Evidence: an initial
  report of encoded program sizes and cycle counts; leave physical area columns
  unmeasured until P5 supplies results.
  Evidence: the [P1.4 encoding study](p1.4-encoding-study.md) carries the tables and
  what they recommend; every number in it is an expect-test output from
  [`test_encoding.ml`](../test/f_model/test_encoding.ml). One operation set
  ([`study_isa.ml`](../f_model/study_isa.ml)) is encoded two ways and stored four ways
  ([`study_encoding.ml`](../f_model/study_encoding.ml)): 16-bit instructions with
  extension words and fixed 32-bit instructions, each in a 16-bit and a 32-bit memory
  word. The same UART, SPI and I2C work P1.3 built out of operations is written once
  as programs ([`study_examples.ml`](../f_model/study_examples.ml)), assembled by every
  candidate, and run by a control core ([`study_core.ml`](../f_model/study_core.ml))
  that fetches real words from a [`Program_store`](../f_model/program_store.ml) through
  the 1RW latency-one port and issues their operations into `Machine`; the SPI and
  I2C runs are answered by P1.3's independent peers and receive `0x3c` and
  acknowledge `0x84`/`0xa5` under all four candidates. At equal memory width the
  16-bit encoding costs 26% to 50% fewer program bits and the same cycles except
  where an extension word is executed, where it costs 9% to 14%; packing two 16-bit
  instructions per 32-bit word is the fastest candidate and the only one whose
  bit-banged timing depends on instruction alignment; 32-bit instructions in a 16-bit
  word are largest and slowest on every example. A 16-bit word is an instruction
  15,518 times in 65,536, against 1.79% of a million sampled 32-bit words, which is
  the fixed-width format's clearest advantage. *Carried forward:* the cycle counts
  belong to one deliberately simple reference core - fetch not overlapped with
  execution, one buffered memory word, one edge per instruction. P1.6 now adopts
  that schedule as the cycle-exact core contract; P3.2 timing changes require an
  explicit architecture revision. Fetch and execute counts remain separate evidence. No engine executes a transfer
  yet (P2.5), so the descriptor programs stop at acceptance and the engine's eighty
  wire cycles are quoted from P1.3. Both encodings are two-address, so the 32-bit
  format is measured without the three-address form its spare bits would allow, and
  neither has a call instruction: 31 of the I2C transaction's 85 instructions are one
  inlined byte loop. P1.5 owns all three decisions, and physical area stays
  unmeasured until P5.
- [x] **P1.5 — Establish shared encoding and independent execution.** Choose a
  provisional encoding through a recorded architecture decision, implement the
  assembler with validation, and expose one instruction specification for the
  assembler and RTL decoder. Keep reference execution independent of RTL logic.
  Evidence: encoding boundary cases and labeled programs have expected bytes,
  decoded meanings, and model execution traces.
  Evidence: the [P1.5 encoding decision](p1.5-encoding-decision.md) records the choice
  and what it gives up. The specification is a library of its own,
  [`isa/`](../isa/dune), below both `lib/` and `f_model/` because an installed library
  cannot depend on a private one: [`instruction.ml`](../isa/instruction.ml) is the
  instruction set, [`encoding.ml`](../isa/encoding.ml) the opcodes and field layout,
  [`descriptor.ml`](../isa/descriptor.ml) the descriptor fields firmware writes, and
  [`assembler.ml`](../isa/assembler.ml) the labels, images and refusals.
  `Encoding.Layout` declares each instruction's fields once; `encode` and `decode` read
  those declarations and `Encoding.forms` publishes the same records, so P3.2's decoder
  is built from the values the assembler encodes with rather than from a transcribed
  table. [`kinds.ml`](../isa/kinds.ml), [`pins.ml`](../isa/pins.ml) and
  [`event_kind.ml`](../isa/event_kind.ml) moved down into it for the same reason: an
  instruction field names them. Reference execution is
  [`control_core.ml`](../f_model/control_core.ml), which shares `Encoding` with the RTL and
  nothing else and has no Hardcaml dependency.
  [`test_isa.ml`](../test/f_model/test_isa.ml) holds the evidence: a 111-instruction
  boundary corpus that round trips, the published layout table, labeled programs as
  instruction words, memory words and transport bytes in both memory layouts, every
  assembler refusal, and the UART, SPI and I2C transactions executed out of a
  [`Program_store`](../f_model/program_store.ml) against the same independent peers P1.3
  and P1.4 used. Sixteen-bit instructions with extension words were chosen on P1.4's
  evidence; the memory word stays a caller's choice with a 16-bit default until P5
  measures it; and the call P1.4 left open was added and measured — the I2C transaction
  is 30% fewer instructions and 29% fewer program bits for 0.9% more cycles.
  *Carried forward:* the committed decoder refuses a zero delay, period or timeout that
  P1.4's 16-bit decoder accepted; across the 55,296 words of the 27 shared opcodes those
  42 words are the only difference and nothing else decodes differently, which is what
  lets P1.4's measurements stand for this encoding. Physical area is still unmeasured
  (P5.1), and a packed 32-bit image still makes a bit-banged region's timing depend on
  slot alignment, which no assembler check enforces because no way to mark a region
  exists.
- [x] **P1.6 — Define the verification harness.** Planning decisions are recorded
  in [verification.md](verification.md), and the harness now exists. Use
  directed expect tests paired with bounded Quickcheck generators and one
  cycle-exact functional-model/core contract, including P1.5's fetch/execute schedule. The
  environment owns drivers, pin-to-item monitors, the independent model, and checker;
  one runner owns simulation time and feeds the same scheduled stimuli to DUT and
  model. Use seed-based replay with recorded configuration, generator settings,
  source/dependency identity, failing/shrunk scenario, first mismatch, and a rerun
  command. Keep unavailable, unspecified, and defined observations distinct.
  Reserve section 6's logical-bit versus physical-symbol distinction and stream
  boundary/error metadata without implementing stretch engines. Testbench guidance
  is in [formatting_guide.md](formatting_guide.md#101-testbench-architecture).
  Evidence: at least one existing primitive uses the shared harness in both a
  directed expect test and a Quickcheck functional-model/Hardcaml comparison; a controlled
  failing case reproduces the same first mismatch from its recorded seed/settings.
  Link ASIC backend conformance separately from emulator consumer checks; compare
  only defined memory outputs across backends and check held outputs within each
  backend. Simulation poison must not become synthesized logic or a required
  physical output value. Whole-suite migration and full-core implementation are
  not required to close this item.
  Evidence: the harness support is under `test/common/` and its first block testbench
  is under `test/primitives/pin_bank/`, described in
  [verification.md current state](verification.md#current-state).
  [`observation.ml`](../test/common/observation.ml) holds the unavailable/unspecified/defined
  distinction and the checker; [`replay.ml`](../test/common/replay.ml) the seed, generator
  settings, failing trial, configuration, source/dependency identity and rerun command;
  [`env.ml`](../test/common/env.ml) the `Device` a block is described by once, the runner that
  alone advances time, the pin-to-item monitor conventions, and the Quickcheck driver,
  shrinker and failure report. A block supplies drivers, an independent model, monitors
  and its required observations; the runner drives, settles, samples pre-edge, takes the
  edge on both sides, samples settled post-edge, and stops at the first difference.
  Section 6's distinctions are reserved in the monitor record — direction, stream
  identity, edge timestamp, stream boundary and error — with no stretch engine
  implemented.
  P2.1 is the first consumer. [`pin_bank_testbench.ml`](../test/primitives/pin_bank/pin_bank_testbench.ml) describes it
  once and the tests under [`test/primitives/pin_bank/`](../test/primitives/pin_bank) plus
  generic fixtures under [`test/common/`](../test/common) use that one
  description four ways: the checker's validity rules, a directed expect transcript, a
  200-trial Quickcheck run against [`f_model/pin_bank.ml`](../f_model/pin_bank.ml) from a
  recorded seed, and a controlled mismatch that is found, shrunk to two items, reported
  with its reproduction record, and found again at the same trial and edge when the
  recorded seed and settings are rerun. The injected defect lives in the environment's
  config, so nothing in `lib/`, `f_model/` or the suite is left intentionally failing.
  *Carried forward:* the harness's first run disagreed with the design about the sticky
  ownership conflict on an edge refused for offering two requests at once; the contract
  was ambiguous and [construction-plan.md section 3](construction-plan.md#3-initial-architecture)
  now states that the sticky bit records the attempt. `reject_reason` is declared
  `Unavailable` on the RTL side: the comparison skips it, and the hole is visible rather
  than absent. Waveform capture is not implemented — the bounded trace and the failing
  scenario are the diagnostics section 4 requires. The remaining tests are now
  structurally block-owned but have not all adopted the shared runner; ASIC backend
  conformance stays linked separately as `hardcaml_asic`'s evidence.

**Exit gate:** UART/SPI/I2C examples execute in the model, execution contracts are
testable, and program sizes and path timing are recorded. The chosen encoding is
usable for P3 while remaining subject to physical evaluation in P5.

## 5. P2 — Implement and verify reusable primitives

**Entry:** the relevant P1 contracts, incrementally. Use P0 generation for emitted
RTL checks and its physical environment for per-block measurements. These are
emulator primitives; small FIFOs/registers remain flop logic, not v0.1 ASIC RAM
resources. Behavioral implementation can proceed before ASIC adapter availability.

- [x] **P2.1 — Atomic pin bank.** Implement eight logical pins with registered
  value/enable, masked commits, ownership, and sticky conflict reporting.
  Evidence: masked writes preserve other pins, overlapping claims are rejected,
  open-drain operations never drive high, and reset/disable/abort release pins
  according to the contract. Evidence: [`pin_bank.ml`](../lib/pin_bank.ml),
  [`test/primitives/pin_bank/`](../test/primitives/pin_bank), and the
  [P2 implementation record](p2-implementation.md).
- [x] **P2.2 — Input and event front end.** Add synchronization, registered
  snapshots, edge detection, latched status, acknowledgement, and overflow
  reporting where applicable. Evidence: asynchronous-phase sweeps, stale-edge
  rejection, set-wins acknowledgement, and reset cases pass. Record the observed
  digital latency range and assumptions about minimum pulse width.
  *Evidence:* [`input_events.ml`](../lib/input_events.ml) and
  [`observed_transfer.ml`](../lib/observed_transfer.ml) pass digital functional-model/Hardcaml
  comparisons. The two-state Evsim pilot under
  [`test/primitives/input_events/`](../test/primitives/input_events) sweeps all integer
  phases, captured/missed sub-period pulses, exact-edge reset, and event interactions;
  it records a 10--19 tick deterministic latency range under its explicit sampling
  convention. See the [P2 implementation record](p2-implementation.md).
  *Verification dependency:* the implemented time-resolved pad driver follows the
  divided cycle/event responsibilities in [verification.md](verification.md#next-state)
  and the [migration guide](verification_migration.md), reusing reference/checking/replay
  conventions behind a separate timed runner. P2.6 can consume the same facilities.
  Four-state properties remain a separate, explicitly modeled obligation; two-state
  Evsim is sufficient for deterministic phase/pulse sweeps. Neither tier establishes
  analog metastability reliability.
- [x] **P2.3 — Timing and waits.** Implement countdown, periodic ticks, level/edge
  waits with timeout, and event-based phase restart. Evidence: exact delay edges,
  zero-delay rejection, immediate level completion, event-over-timeout precedence,
  and waits that leave active engines running match the model.
  Evidence: [`timing.ml`](../lib/timing.ml) matches the reference machine on
  waits and periodic ticks; [`primitive_demo.ml`](../lib/primitive_demo.ml)
  shows a transfer progressing during a wait
  ([`test/integration/primitive_demo/`](../test/integration/primitive_demo)). See the
  [P2 implementation record](p2-implementation.md).
- [x] **P2.4 — Data queues.** Implement configurable small TX/RX FIFOs with
  explicit ready/valid, full/empty, validity reset, and fault behavior. Evidence:
  simultaneous push/pop and boundary cases preserve ordering and occupancy with
  no loss or duplication; starvation/overflow follows the specified policy.
  Evidence: [`byte_fifo.ml`](../lib/byte_fifo.ml),
  [`test/primitives/byte_fifo/`](../test/primitives/byte_fifo), and the
  [P2 implementation record](p2-implementation.md).
- [x] **P2.5 — Internally paced transfers.** Implement the candidate shift lane
  with lengths 1..32, both bit orders, TX-only/RX-only/duplex, initial preload,
  separate launch/sample phases, and latched descriptors. Evidence: first/last
  bit placement, pin conflicts, invalid phase combinations, completion, and
  underrun/overrun safe aborts match the model. Evidence:
  [`shift_lane.ml`](../lib/shift_lane.ml),
  [`shift_engine.ml`](../f_model/shift_engine.ml),
  [`test/primitives/shift_lane/`](../test/primitives/shift_lane), and the
  [P2 implementation record](p2-implementation.md).
- [x] **P2.6 — Observed-event transfers.** Add generic preconfigured arming/start
  and external-edge pacing on top of P2.2/P2.5. Align observed clock, select, and
  data paths. Evidence: phase sweeps measure event-to-engine and event-to-core-
  decision-to-pin latency; externally interrupted transfers release ownership.
  Record limits needed for UART RX and SPI target experiments.
  - [x] **P2.6a -- Primitive and digital envelope.**
    [`observed_transfer.ml`](../lib/observed_transfer.ml) aligns and latches start, pacing,
    optional cancellation/select, and data configuration; falling-edge select withdrawal
    aborts armed or active work and releases ownership. The
    [P2 implementation record](p2-implementation.md) records the accepted/live input
    contract, priority, recovery, measured limits, and UART RX/SPI target implications.
    The timed suite under
    [`test/primitives/observed_transfer/`](../test/primitives/observed_transfer) composes
    independent input and shift-engine models, checks reconstructed pin transactions and
    RX/fault state for multi-bit directed and generated schedules, and measures 10--19
    ticks external-to-synchronized-event, 10 ticks event-to-engine, and 20--29 ticks
    start/launch-to-pin or cancellation-to-release. The audited envelope separates
    10/10-tick input capture and RX-only operation from TX/duplex wire behavior. An
    independent external peer verifies every bit of idle-low 8- and 32-bit TX/duplex at
    all phases when the launch-to-sample half is at least 30 ticks and the opposite half
    is at least 10 ticks, with one tick of peer setup. At an assumed 48 MHz system clock
    this is 24 MHz for capture/RX-only, 12 MHz for asymmetric TX/duplex, or 8 MHz for
    symmetric TX/duplex. The earlier unqualified 24 MHz statement was not TX wire evidence;
    P2.6a remains complete on the corrected, explicitly restricted digital envelope.
    *Supplementary preparation:* the peer sweep now also verifies idle-high, both physical
    preload-first/launch-first mappings, and 1/8/32-bit boundaries. Wire claims use an
    alternating `Either` clock initialized to the declared idle level; rise-only/fall-only
    event streams remain functional tests rather than all-mode wire evidence.
  - [x] **P2.6b -- Real core path.** P3.3 now composes
    P3.1a's safe load/fetch boundary, P3.2 decode/execution, the shared event front end,
    mechanism adapter and registered pin bank. The loaded program timestamps the external
    event, synchronized event, actual core decision, bank request/commit and boundary pin;
    it is not a sequencer or direct event-to-pin substitute.
     *Preparation completed:* [`observed_transfer_bank.ml`](../lib/observed_transfer_bank.ml)
     reserves the output at arm acceptance, commits lane writes through the real bank,
     clears output enable before release, and explicitly arbitrates software offers.
     [`test/integration/observed_transfer_bank/`](../test/integration/observed_transfer_bank)
     measures 20--29 ticks external-to-lane, 10 ticks for ordinary lane-to-bank data
     commits, and 30--39 ticks
     external-to-committed-bank output. The bank-boundary peer requires 40 ticks
     launch-to-sample plus a 10-tick opposite half: 9.6 MHz asymmetric or 6 MHz symmetric
     at an assumed 48 MHz system clock; 39 ticks fails some phases. Cancellation clears
     bank output enable in 20--29 ticks and releases ownership in 30--39. The sweep covers
     idle-low/high, both mappings and orders, TX/RX/duplex, 1/8/32 bits, conflicts,
     symmetric/asymmetric duty cycles, interruption and rearming. This boundary is the
     bank's registered outputs, not a chip wrapper or pad.
     The prepared `wait_start_then_drive` program is assembled and executed now by the
     independent core/store model: default-memory words `7804 0000 a300 7804 0001 0000`
     predrive software-owned pin 0 low, wait for pin 3 rising, drive pin 0 high, and halt
     in 13 model edges. The exact future timestamps, initial state, finite limit, diagnostics
     and P3 observation points are in the
     [P2 implementation record](p2-implementation.md#real-core-scenario-and-measurement).
      The prepared image now runs through [`integrated_core.ml`](../lib/integrated_core.ml).
      [`core_engine_timing_tests.ml`](../test/integration/core_engine/core_engine_timing_tests.ml)
      sweeps all ten integer phases and measures 10--19 ticks external-to-synchronized,
      20 ticks synchronized-to-core-decision, 30 ticks decision-to-bank-request, and 60--69
      ticks external-to-registered-bank commit. The request commits after the same clock
      boundary. Compared with the direct 30--39-tick engine/bank path, this loaded program
      adds exactly 30 ticks. The boundary remains the bank outputs, not wrapper/pad or
      physical timing. P2.6b and parent P2.6 are complete; see the
      [P3.3 record](p3.3-implementation.md).
- [x] **P2.7 — Close the first UART TX demonstration.** Connect P1.3's sequence
  to the pin/timer hardware and the emitted-RTL harness. Evidence: an independent
  monitor checks idle, start, data, stop, bit periods, and reset/disable during
  transmission. Save matching model and RTL traces for the first working slice.
  *Evidence:* [`uart_slice.ml`](../lib/uart_slice.ml) takes the 8N1 frame through the
  pin and timer hardware instead of straight out of the lane: the lane is claimed as the
  engine in [`pin_bank.ml`](../lib/pin_bank.ml), [`timing.ml`](../lib/timing.ml) counts
  out one bit period of idle before the start edge — the leading idle phase P1.3's
  sequence spends two operations on — and every bit is committed by a masked engine write,
  so what leaves the design leaves through an owner. Four producers are then decoded by
  one independent receiver that is told nothing but the expected bit period: P1.3's
  bit-banged [`tx_sequence`](../f_model/firmware_uart.ml) on the reference machine, the
  same frame as one typed descriptor on [`shift_engine.ml`](../f_model/shift_engine.ml),
  the Hardcaml slice, and the emitted Verilog under
  [`p2_uart_slice_tb.v`](../tinytapeout/test/p2_uart_slice_tb.v), whose receiver is
  written a second time in Verilog so that the two monitors cannot share a mistake. All
  four agree on
  [`uart_frame.trace`](../test/integration/uart_slice/uart_frame.trace), which is the
  saved matching model and RTL trace: `@runtest` writes it only after the two model
  producers and the Hardcaml slice agree and diffs it against the committed copy, and
  `@rtl` diffs the emitted-RTL copy against the same file. Reset, disable, and abort part
  way through a frame release the pin and the engine's claim on the next edge, checked in
  both harnesses; only the selected pin is ever driven; the bank raises no rejection or
  conflict. The monitor and the tests are in
  [`test/integration/uart_slice/`](../test/integration/uart_slice). See the
  [P2 implementation record](p2-implementation.md).
  *Carried forward:* the bank's registered write puts the pin one cycle behind the lane,
  uniformly, so bit periods are unchanged and only the frame's absolute position moves.
  The sequencer is the demonstration harness this section allows, issuing the one typed
  command the slice needs. Fetch, decode, and runtime loading have since landed in
  P3.1/P3.2; a firmware *program* reaching the same pins remains P3.3 integration and
  P2.6b timing evidence, not this item's. The receiver
  measures the bit period as the greatest common divisor of the frame's transition
  intervals, which equals the bit period only for a byte that puts a bit between two
  unlike neighbours; `0xa6` is such a byte and the vectors keep it. The bounded generated
  regression adds 96 fresh-state trials at seed `20260920` across bytes, all eight pins,
  half-periods 2--12, and normal or interrupted frames. It uses the shared replay/source
  identity conventions while keeping the established frame monitor and Cyclesim loops.
  Its producer comparisons are frame-relative after each start edge is detected, not a
  claim of equal request-to-start latency. The generated period range records coverage,
  not a change to the supported-input contract: zero encounters primitive refusal and
  values at or above 32768 overflow the doubled 16-bit leading-idle countdown. Slice-level
  handling of those requests, half-period 1, and the wider positive non-overflowing range
  remain unverified. Generated-failure diagnostic and controlled-replay gaps are tracked
  separately in verification.md.
- [ ] **P2.8 — Record primitive costs and invariants.** Measure mapped sequential
  and combinational area per block/configuration using P0's flow. Exercise pin
  ownership, open-drain, FIFO, handshake, reset, and wait invariants; apply formal
  checks where useful and record environmental assumptions and checks not run.
  Before a flow run is worthwhile, record per-block yowasp-yosys estimates (generic
  or liberty-mapped tiers,
  [construction-plan.md §1](construction-plan.md#decoupling-rtl-from-the-asic-tooling))
  labeled with their tier. Estimates alone do not satisfy this item. Evidence:
  mapped costs from a flow run. Before adoption, legacy runs of the existing
  scripts are acceptable when labeled legacy and linked to exact source/tool
  revisions and block parameters. After adoption, use declared configurations and
  link costs to build/selection and execution identities. P5.1 reruns the
  comparisons that feed configuration decisions; P2.8 is not reopened.
  *Progress:* standalone per-block RTL emission is available through
  [`generate_p2.ml`](../bin/generate_p2.ml); mapped costs and formal evidence
  remain. See the [P2 implementation record](p2-implementation.md).

**Exit gate:** primitives agree with the model on normal and fault paths, the
first UART TX slice works, and initial per-block area and latency evidence exists.
Filtering, extra descriptor slots, and extra lanes remain measured decisions.

## 6. P3 — Make the system reloadable

**Entry:** P1 execution/encoding and the required P2 primitives. Only P3.1b uses
P0.6/P0.7's adopted ASIC path; the rest of P3 proceeds against the memory contract
before adoption (see [non-linear sequencing](#non-linear-sequencing-rtl-decoupled-from-asic-adoption)).

- [x] **P3.1 — Program store and load validity.** Split at the adoption boundary.
  - [x] **P3.1a — Contract-port consumer logic.** In the core, drive the store's 1RW
    latency-one port without instantiating it. Keep program/loaded-image
    validity and bounds enforcement in the emulator. Gate both host writes and
    readback on halted-and-engines-idle; reject requests during execution without
    consuming a fetch cycle. Require verified load-complete before RUN. Evidence,
    against the testbench contract model: partial loads, reset,
    out-of-image/out-of-range fetches, and attempted live accesses cannot start or
    corrupt execution; post-write and unwritten outputs are never valid
    instructions; nothing depends on bulk reset or initialization.
    *Done:* [`protocol_core.ml`](../lib/protocol_core.ml) implements the 256x16 default
    P1.5-layout consumer, sequential bounded replacement loads, full-word ordered
    readback comparison, verified completion, halted-and-idle host gating, explicit
    fetch ownership/validity, and bounds checks before address narrowing. The independent
    [`program_access.ml`](../f_model/program_access.ml) model and
  [`test/core/protocol_core/`](../test/core/protocol_core) cover directed boundary and
    interruption cases plus 240 generated scenarios at seed `20260920`, against three
    legal choices for unspecified RAM output. Standalone emitted RTL passes Verilator
    lint and generic Yosys synthesis under `@rtl`. Contracts, commands, results, and
    limitations are in the [P3.1a implementation record](p3.1a-implementation.md).
    P3.1a's original record predates P3.1b; parent P3.1 is now complete.
  - [x] **P3.1b — Context-registered store at the project top.** After P0.6/P0.7,
    instantiate `hardcaml_asic.Single_port_ram` in the project design constructor
    and connect P3.1a's port. Evidence: P3.1a's checks rerun against the library's
    behavioral model and emitted RTL; selection and any allowed fallback are
    recorded in the build.
    *Done:* P0.7 provides the exact connection and mapped evidence linked above; the
    manifest records explicit flops, not fallback or macro selection. The
    [P3.1b verification closure](p3.1b-verification.md) reruns P3.1a's twelve directed
    scenarios and 240 fixed-seed generated scenarios against both the context-registered
    behavioral backend and selected flop circuit. Separate emitted simulation and
    implementation RTL pass full-interface directed checks for every audited gap. Fresh
    production RTL and flow inputs are byte-identical to the archived P0.7 inputs, so its
    mapped-cost evidence remains applicable. P3.1a, P3.1b, and parent P3.1 are complete.
- [x] **P3.2 — Minimal control execution.** Implement fetch/decode, registers,
  flags, state operations, branches/loops, and halt for the provisional ISA.
  Evidence: independent-model comparisons cover each implemented instruction,
  taken/untaken paths, latency-one fetches, stalled fetch/output hold, pipeline
   validity, extension-word fetches, invalid instructions, and cycle counts.
   *Done:* [`instruction_decoder.ml`](../lib/instruction_decoder.ml) derives legality and
    fields from the shared encoding specification;
    [`control_execution.ml`](../lib/control_execution.ml)
   implements fresh RUN state, every local state/control instruction, exact `m16`
   fetch/execute/extension timing, wide target checks, observable retirement/fault state,
   and a retained handshake for every delegated mechanism instruction.
   [`executable_core.ml`](../lib/executable_core.ml) composes it with P3.1a while keeping
   the RAM external. The block suite exhaustively compares all 65,536 base words' legality
   and extension classification with the procedural decoder, compares directed and 96 fixed-seed generated programs with the
   independent control model, and covers mechanism and fault paths. Emitted RTL loads and
   runs a representative image in nine fetch plus seven execute cycles under `@rtl`.
   Contracts, commands, results, and limitations are in the
   [P3.2 implementation record](p3.2-implementation.md). P3.3 has since supplied its real
   mechanism/event/pin-bank consumer and closed P2.6b.
- [x] **P3.3 — Core-to-engine integration.** Connect pin, time, transfer, event,
  and FIFO instructions. Add boundary STOP, prompt ABORT, and single-step with
  engines idle. Evidence: engines continue through ordinary core waits; completion,
   faults, ownership, queue pressure, and interruption match reference traces.
   *Required follow-up:* once P3.2 and this integration provide the executable
   event-to-core-to-pin path, return immediately to P2.6b as the next slice. Measure
   event, core decision, pin-bank commit, and boundary pin through a real loaded
   program, update the boundary timing envelope, and resolve P2.6b/parent P2.6
   before moving on to P4 protocol acceptance. If the path is still unavailable,
   record the exact missing prerequisite beside P2.6b rather than dropping the return.
   *Done:* [`core_mechanisms.ml`](../lib/core_mechanisms.ml) connects all fifteen delegated
   kinds to the shared event front end, timing block, two byte FIFOs, shift lane and central
   registered pin bank. [`integrated_core.ml`](../lib/integrated_core.ml) adds boundary
   STOP, prompt ABORT, idle-only single-step and real engine-idle gating while preserving
   P3.1a/P3.2 ownership. Seventeen loaded-program/timed tests plus emitted-Verilog simulation
   cover completion, faults, ownership, pressure, background progress and interruption.
   P2.6b was immediately measured and closed above. Contracts, timing, commands and limits
   are in the [P3.3 implementation record](p3.3-implementation.md).
- [x] **P3.4 — Host API and simulator backend.** Define version/capability
  discovery, program load/readback, pin configuration, data queues, execution
  control, register/engine inspection, and bounded timestamped trace retrieval.
  Add CLI operations over a simulator backend. Evidence: a scripted CLI workflow
  loads, verifies, runs, exchanges data, and retrieves status; trace overflow is
  observable and capability/ISA mismatches have defined errors. Advertise memory
  width/depth and image format; active-execution program-access requests have a
  defined rejection. Keep ordinary status/data-queue operations separate.
  *Done:* [`host_api.ml`](../host/host_api.ml) defines the versioned discovery, image,
  structured-error, program, control, queue, pin, inspection and trace boundary;
  [`simulator_backend.ml`](../host/simulator_backend.ml) drives one live
  [`Integrated_core`](../lib/integrated_core.ml) and an external contract RAM with explicit
  cycle advancement. [`sim_cli.ml`](../bin/sim_cli.ml) adds machine-readable `sim info`,
  image generation and stateful script commands. The checked
  [`p3.4-workflow.sim`](../examples/p3.4-workflow.sim) loads and independently reads the
  three-word queue-echo image, uses real RX/core/TX paths, exercises STOP, ABORT and step,
  observes live-access and full/empty refusals, and proves bounded trace loss/clear state.
  API/backend tests and actual-executable Dune rules live under
  [`test/host/`](../test/host) and
  [`test/integration/host_simulator/`](../test/integration/host_simulator). Contracts,
  commands, results, limitations and the P3.5/P3.6 handoff are recorded in the
  [P3.4 implementation and CLI guide](p3.4-host-api.md). This completes P3.4 only; no
  physical transport, independent hardware loader, P4 protocol acceptance, or P3 exit gate
  is claimed. *Review follow-up:* the bounded P3.4 cleanup added all-or-error logical-image
  read bounds with structured unexpected-progress failures, authoritative refusal reasons,
  distinct transfer timeout codes, explicit capabilities and backend signature conformance,
  post-edge ABORT completion, current-request pin-conflict reporting, and focused queue,
  fault/recovery, trace-order/loss and CLI regressions. It also confirmed and enforced the
  latency-one response invariant and corrected post-RAM settling for concurrent FIFO
  readiness. The API remains 1.0 because this cleanup precedes the first P3.5 transport and
  removes unused reviewed-draft reasons rather than preserving an already released backend.
- [x] **P3.5 — Independent hardware loader.** Specify the dedicated serial link's
  framing, pin allocation, host clock envelope, acknowledgement, length/error
  checks, byte order/word assembly, and flow control before implementation.
  Issue only complete configured memory words; reject incomplete trailing words
  without declaring the image valid. Add fixed loader logic and
  wrapper integration independent of firmware execution. Evidence: malformed or
  interrupted loads are rejected and a halted/broken program remains recoverable.
  *Done:* [`hardware_loader.ml`](../lib/hardware_loader.ml) implements the fixed
  synchronized host-clock parser, CRC-8/ATM validation, bounded four-byte command
  payload, one-shot core dispatch, completion waits, and retained/restartable response.
  [`loader_core.ml`](../lib/loader_core.ml) connects it only through the real
  `Integrated_core` program/control requests. The adopted `loader` project in
  [`asic_bundle.ml`](../bin/asic_bundle.ml) supplies the context-registered 256x16
  `program` RAM and maps `ui[0]` select, `ui[1]` clock, `ui[2]` input data,
  `uo[0]` output data, and `uo[1]` ready while preserving all eight `uio` protocol
  pads. [`p3_loader_tb.v`](../tinytapeout/test/p3_loader_tb.v) is an independent
  serial peer run against both emitted `Loader_core` plus a contract store and the
  actual wrapper/behavioral adopted memory source. It covers discovery/status,
  complete-word load/read/verify/complete/RUN, framing/version/command/CRC/length/
  address errors, interrupted requests and responses, reset/disable, all ten phases
  at the four-system-clock half-period boundary, asymmetric duties, deterministic
  generated corruption seed `20260921`, active-execution refusal, ABORT of an
  infinite loop, and replacement loading. Protocol, result/retry/recovery rules,
  resource bounds, measured 6 MHz digital envelope, verification, limitations, and
  the exact P3.6 handoff are in the [P3.5 record](p3.5-hardware-loader.md). P3.6,
  board verification, current mapped cost, and the P3 exit gate remain open.
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
