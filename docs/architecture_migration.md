# Architecture migration

Status: agreed direction, documented 2026-09-25; implementation not started under
this plan. All AM work items below are open. The repository owner selects and prompts
implementation agents; this document is their handoff, not evidence that source names,
interfaces, or layouts have changed.

## Authority and order of work

This document owns the architectural naming and responsibility migration. Complete
AM0–AM6 before starting the verification-infrastructure changes in
[verification.md](verification.md#verification-overhaul-sequence). Existing tests remain
the preservation baseline throughout the architectural work. Mechanical updates to test
imports and paths are part of a rename; replacing drivers, assertions, or scenarios is
part of the later verification overhaul.

- [construction-plan.md](construction-plan.md) and the P3 records own hardware behavior.
- [verification.md](verification.md) owns enduring verification architecture and the VO
  implementation sequence, including functional coverage, memory verification, and formal.
- [host_link_migration.md](host_link_migration.md) records the completed HL decomposition;
  [organization_migration.md](organization_migration.md) records the earlier directory move.
  Their historical names and results are not current rename instructions.
- [history/verification_migration.md](history/verification_migration.md) records the
  previous verification refactor; it does not sequence this migration.
- [flow.md](flow.md) owns build-bundle and physical-flow execution.

### Execution rules

Record the starting revision and all relevant dirty/untracked inputs. Preserve unrelated
working-tree changes. Only the repository owner commits; implementation agents return
unstaged changes and evidence unless the owner explicitly requests otherwise.

Every `dune build`, `dune runtest`, and generation/verification `dune exec` invocation
must include `-j 5`. Run them sequentially; concurrent heavy builds have caused server
failures. A tool that could not run is recorded as unavailable/not run, never as passing.

## Accepted decisions

1. Use names describing the hardware's role, not its construction phase or one historical
   feature such as loading firmware.
2. Decompose by responsibility, state ownership, and useful interface contracts. Thin
   composition files are appropriate; a module is not split merely to increase file count.
3. Retain flat OCaml module names and the current `lib/` unqualified namespace for this
   migration. Broader library/namespace enforcement is deferred. The separate package
   integration library is needed to keep `hardcaml_asic` out of the reusable hardware library.
4. Keep program storage separate from its access controller and from the system using it.
5. Keep protocol definitions and software byte conversion separate from the hardware
   endpoint and physical transaction scheduling.
6. Preserve behavior, cycle contracts, resource selection, and the existing package ABI.
   This migration adds no capture memory, payload cache, transport, or memory arbitration feature.

## Current implementation and naming map

These source paths exist at planning time. Target paths are planned, not current links.

| Current owner | Target owner/path | Responsibility |
| --- | --- | --- |
| `lib/host_link/hardware_loader.ml`, `Hardware_loader` | `lib/host_link/host_link.ml`, `Host_link` | Complete serial host-control endpoint |
| `lib/host_link/loader_core.ml`, `Loader_core` | `lib/system/protemu_top.ml`, `Protemu_top` | Endpoint connected to the emulator core; external program-memory port |
| `lib/memory_control/protocol_core.ml`, `Protocol_core` | `lib/memory/program_memory_controller.ml`, `Program_memory_controller` | Load/readback/verify, image validity, and fetch/access arbitration |
| `lib/emulator_core/control_execution.ml`, `Control_execution` | `lib/emulator_core/execution_unit.ml`, `Execution_unit` | Instruction execution, architectural state, run/stop/abort/step |
| `lib/emulator_core/core_mechanisms.ml`, `Core_mechanisms` | `lib/emulator_core/primitive_dispatch.ml`, `Primitive_dispatch` | Execution-command dispatch to mechanisms and their composition |
| `lib/emulator_core/integrated_core.ml`, `Integrated_core` | `lib/emulator_core/emulator_core.ml`, `Emulator_core` | Program-memory controller + execution + mechanisms |
| Production `Loader_design` inside `bin/asic_bundle.ml` | `chip_top/package_top.ml`, `Package_top` | Target-specific system/resource/pin/reset composition |
| `Single_port_ram.create` at production top | `chip_top/program_memory.ml`, `Program_memory` | Chip-owned configuration/binding of the program storage resource |
| `host_link_wire/`, `Protemu_host_link_wire.Wire` | `host_link_protocol/`, `Host_link_protocol`, with `Host_link_protocol.Codec` | Pure protocol vocabulary/layouts and software encoding/decoding |

The protocol API spelling above is the intended consumer-facing grouping. AM3 must record
the concrete Dune library/root-module arrangement; avoid accidentally introducing
`Host_link_protocol.Host_link_protocol`. Internal/public Dune names and packaging must be
enumerated in the rename map before editing dependencies.

`Loader_core` is currently a 92-line wiring module, not an implementation of all its
children. `Hardware_loader` is already stateless composition of `Serial_phy`, `Frame_rx`,
`Command_dispatch`, and `Frame_tx`. Preserve those extracted boundaries. The needed change
is clear ownership and naming, followed by justified extraction of remaining mixed roles,
not repeating HL4 or inventing additional pipeline stages.

## Target hierarchy and ownership

```text
Package_top                       target-specific package integration
├── Protemu_top                   reusable emulator system, no RAM implementation
│   ├── Host_link
│   │   ├── Serial_phy            input synchronization and edge events
│   │   ├── Frame_rx              receive, validation, retained request fields
│   │   ├── Command_dispatch      control offers, waits, response construction
│   │   └── Frame_tx              retained response, arming, shifting, replay/commit
│   └── Emulator_core
│       ├── Program_memory_controller
│       ├── Execution_unit
│       └── Primitive_dispatch    existing mechanism composition and primitives
└── Program_memory                selected resource binding, currently explicit flops
```

The diagram describes semantic containment; emitted RTL may be flattened. It does not
require one Verilog module per OCaml module.

### Host endpoint and downstream control

`Host_link` exposes physical-side serial inputs/outputs and a downstream `Control_port`.
The PHY produces synchronized observations, not core commands. RX produces validated
handoffs consumed by dispatch; dispatch produces core requests consumed by `Emulator_core`.
The core produces decisions/status consumed by dispatch. TX consumes published responses
and PHY events. PHY clock/select events may fan out to both RX and TX.

`Control_port` remains the core-owned request/decision/status contract. A single producer
and consumer at a transaction boundary does not imply a FIFO or a ready/valid conversion.
Retained fields, eligibility, one-shot offers, completion waits, and same-cycle priorities
retain their existing contracts. The serial clock remains sampled data, not a logic clock.

`Protemu_top` connects those components, exposes the program-memory and protocol-pin
boundaries, and records unused interface tie-offs. It does not decode frames or own RAM.
`Package_top` supplies memory, maps package pins, and adapts reset/output enables. Package
choices do not leak into `Host_link` or `Emulator_core`.

### Memory: controller, storage, and implementation

- `lib/memory/` owns target-independent memory-facing logic and contracts. Its first
  implementation is `Program_memory_controller`; a directory rename does not add storage.
- `Program_memory_controller` owns legal access, image metadata, and instruction/readback
  validity. It does not implement a vendor SRAM or select a physical backend.
- `Program_memory` in the package library binds the existing width/depth/latency requirement
  to `hardcaml_asic.Single_port_ram`. Backend primitives and their generic conformance remain
  owned by `hardcaml_asic`; this is not a second memory backend implementation.
- The system boundary remains the existing latency-one single-port contract. The package
  selects the implementation; a test fixture may supply a contract model instead.

Capture buffers, TX/RX payload buffers, and shared-memory arbitration require separate
feature contracts if introduced. Name buffers by purpose. Do not create a `Memory_system`
owner until there is actual shared coordination to own. Simulator-side trace storage is
not evidence of an implemented hardware capture buffer.

### Pure protocol and codec

`Host_link_protocol` owns version, commands/results, layouts, capability/status encodings,
and CRC parameters. `Host_link_protocol.Codec` owns typed request encoding and response
decoding/correlation. A codec serializes/parses bytes; it does not compress data, clock
pins, poll ready, retry commands, or commit responses.

Keep the library free of Hardcaml and emulator implementation dependencies. Preserve fixed
vectors, validation precedence, range checks, and the distinction between malformed bytes
and a well-formed refusal. Software CRC computation can be a pure helper; the hardware
`Wire_crc` remains a hardware helper, not the software reference implementation.

### Responsibility-based submodules

Every further extraction starts with a short ownership table: state, writers, readers,
reset/disable behavior, inputs/outputs, handoff timing, and dependencies. A leaf should have
a meaningful standalone contract. Composition modules primarily wire children and expose
interfaces; package composition additionally selects resources and target adaptation.

Do not split `I`, `O`, and `create` into separate files as a blanket convention. Keep them
with their owner when cohesive. Keep shared interface definitions in named modules when
multiple owners use the same contract. Preserve independently useful existing children
such as `Instruction_decoder`; additional execution/dispatch splitting must have its own
approved ownership analysis before implementation.

### Grouped interfaces

Use nested Hardcaml interface records for meaningful groups: serial inputs/outputs,
`Control_port` request/decision/status, program-memory request/read data, and protocol-pin
signals. Separate incoming and outgoing directions in `I` and `O`; mixed logical
interfaces within one `I` record are normal. Clock/reset/enable may remain direct fields.

`Control_port` already demonstrates nested interfaces. This is OCaml-level grouping,
not a requirement to emit SystemVerilog interfaces or modports. AM5 must inventory derived
flat names, widths, order, and directions and preserve external names with explicit naming
attributes/adaptation. No ready/ack handshake, queue, or latency is added just for grouping.

## Planned source layout and dependency ownership

```text
host_link_protocol/              pure protocol definitions + Codec
lib/                            one wrapped Hardcaml library, flat module namespace
  host_link/                    endpoint, PHY, RX, dispatch, TX, hardware wire helpers
  emulator_core/                execution, decoder, primitive dispatch, core, Control_port
  memory/                       program-memory controller and target-independent interfaces
  system/                       Protemu_top composition
  pluggable_primitives/          existing leaf mechanisms
  staging/                      existing experimental compositions
  legacy/                       historical compositions still exercised by existing checks
chip_top/                       separate package/resource integration library
  package_top.ml
  program_memory.ml
  ...                           observable/memory bring-up tops, project declaration
bin/                            CLI/emission entry points consuming those libraries
```

The package library may depend on `hardcaml_asic`, `hardcaml_protemu`, and target adapters.
`lib/` must not acquire an ASIC-library dependency. Move reusable top/project construction
out of command-line initialization so an OCaml integration fixture can elaborate the same
production composition. Preserve the observable/memory bring-up modes and give each
extracted top a distinct module name in the package library.

Review architectural dependencies despite the flat namespace: system depends on endpoint
and emulator; endpoint depends on the control contract and shared configuration, not the
emulator implementation constructor; core depends on memory control and primitives;
package depends on the reusable system and resource/target layer. Existing width/INFO
dependencies on core configuration must be inventoried before moving their ownership.
Broader Dune-enforced subsystem libraries and qualified namespaces are deferred.

## Implementation sequence

Each item is a separate handoff/review unit; the owner may subdivide it further. All boxes
are initially unchecked. Do not mark an item complete on documentation or intended work.

### AM0 — Baseline and change inventory

- [ ] Record source/diff, dependency/tool identities, existing regression results, and
  generated standalone/bundle RTL for both source roles.
- [ ] Enumerate OCaml modules, test imports/paths, Dune dependencies, generator selectors,
  emitted module/port names, manifests/source-input lists, scripts, CI, and active docs
  affected by the migration. Record the root `loader_core.v` snapshot's provenance and
  consumers; do not assume it is an input to active Dune tests or delete it incidentally.
- [ ] Record the accepted HL4 exit baseline and remaining product/physical obligations.

Exit: a reproducible baseline and explicit old-to-new map. Existing failures are identified
before renames, not silently attributed to them.

### AM1 — Core and memory-controller naming

Prerequisite: AM0.

- [ ] Rename `Protocol_core`, `Control_execution`, `Core_mechanisms`, and `Integrated_core`
  as listed above; move controller source into `lib/memory/`.
- [ ] Update all live consumers, tests, generators, metadata inputs, and active references.
  Preserve Config values and control-port ownership; do not redesign memory or execution.

Exit: unchanged functional expectations and reviewed generated-output comparison. Old names
remain only in explicitly historical material or recorded compatibility surfaces.

### AM2 — Endpoint and system ownership

Prerequisite: AM1.

- [ ] Rename `Hardware_loader` to `Host_link`; keep its four children and shared helpers.
- [ ] Move/rename `Loader_core` to `lib/system/protemu_top.ml`, `Protemu_top`.
- [ ] Document logical interfaces, unused tie-offs, and the external memory boundary.

Exit: the top remains thin composition; endpoint behavior and every existing exact-cycle
assertion remain unchanged. This stage does not move scenario ownership or rebuild agents.

### AM3 — Protocol library and Codec separation

Prerequisite: AM2.

- [ ] Inventory and implement the `Host_link_protocol` root API and `Codec` grouping;
  separate definitions/layouts from software byte conversion by responsibility.
- [ ] Update hardware constants, host code, codec tests, Dune declarations, and bundle
  input manifests together. Keep independent expected vectors and HDL peer independent.

Exit: pure library dependency boundary, unchanged encoding/decoding behavior and wire bytes,
and reviewed hardware-output comparison. Record any transitional aliases and their removal.

### AM4 — Package and program-memory binding extraction

Prerequisite: AM3.

- [ ] Create the separate `chip_top/` library and extract `Package_top`, `Program_memory`,
  bring-up tops, and reusable project construction from `bin/asic_bundle.ml` as appropriate.
- [ ] Leave executable argument parsing and emission in `bin/`; tests must not need to
  import a CLI module with top-level side effects to elaborate a production top.
- [ ] Preserve resource policy (currently Flops), source roles, target constraints, package
  pin ABI, reset/output gating, and all existing flow modes.

Exit: the same package can be constructed by the emitter and an OCaml fixture; `lib/` stays
ASIC-independent. Manifest path/identity changes are explained; hardware changes are not
accepted merely because bundle metadata changed.

### AM5 — Grouped interfaces and responsibility review

Prerequisite: AM4.

- [ ] Specify ownership and flattened-port maps for the serial, memory, and protocol-pin
  groups; adopt nested interfaces without timing or package-ABI changes.
- [ ] Review the renamed hierarchy for remaining mixed responsibilities. Record justified
  extraction candidates or that the existing boundary is sufficient; implement only
  separately specified extractions with state/timing ownership and preservation checks.

Exit: interface grouping and dependency review are complete. No required split exists
solely because a composition is one file. Unresolved behavioral changes are separate work,
not hidden conditions on this migration.

### AM6 — Architecture acceptance and verification handoff

Prerequisite: AM1–AM5 accepted.

- [ ] Re-run the relevant existing build/lint, ordinary regression, emitted-RTL tiers,
  and bundle checks against the final source state; record exact commands/results.
- [ ] Review module/port/resource inventories and cumulative RTL/synthesis deltas.
- [ ] Update active docs, source lists, and invocation examples; retain historical records.
- [ ] Publish final paths/APIs and map every old verification suite to its renamed DUT.
  Hand that baseline to VO0 in `verification.md`.

Exit: architecture accepted, current evidence located, and no test obligation silently
removed. This gate authorizes the verification restructuring; it does not complete it.

## Preservation and evidence rules

An OCaml rename does not require renaming emitted tops, CLI modes, or package ports.
Initially preserve those compatibility surfaces. Any proposed change to them requires an
explicit consumer map and a separately reviewed transition; names in historical commands
stay as recorded. New verification alias names belong to VO6, not an incidental AM rename.

For each stage, record touched source and test paths, commands, tools, result status, and
unresolved differences. Compare emitted outputs under identical options. Prefer byte
identity when names and construction order are preserved; otherwise classify port, name,
logic, and resource differences. For changed logic, record equivalence scope, state mapping,
preprocessing/reset assumptions, and unproven points. Refactor equivalence is not general
design correctness or proof of the Verilog emitter.

Retain the existing independent serial peer and all three configurations during AM work.
Do not update expectations to make a rename pass. Existing synthesis-delta review rules
still apply: report exact same-tool per-type counts and investigate differences; neither
name-only edits nor equivalent RTL guarantee equal mapping. Generic synthesis is not
physical timing or mapped signoff evidence.

Suggested existing entry points (run sequentially, after verifying current aliases):

```sh
./scripts/with-switch.sh dune build @install @lint -j 5
./scripts/with-switch.sh dune runtest -j 5
./scripts/with-switch.sh dune build @rtl -j 5
```

Use focused/forced runs where needed to demonstrate fresh execution and the existing
bundle checker for affected source roles. Record tool prerequisites rather than weakening
checks. No checks in this section have been run merely by creating this plan.

## Deferred decisions

- Qualified namespaces and general subsystem library/dependency enforcement.
- Renaming emitted package tops/ports, public CLI selectors, and historical artifact names.
- SRAM selection and vendor-model integration; new capture/payload storage and arbitration.
- Additional execution/dispatch decomposition without a reviewed responsibility contract.
- Shared external packaging of verification support; VO begins with project-local libraries.

## Implementation records

None yet under AM0–AM6. Add dated records naming the work item, source/diff, delivered
changes, exact checks, assumptions, deviations, and remaining work. Historical HL evidence
is baseline context, not a fresh result for this migration.
