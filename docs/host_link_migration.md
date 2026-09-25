# Host link migration

Status: migration complete and accepted in the working tree on 2026-09-25; owner commit
of HL3–HL4 remains outstanding. HL0 is resolved: the baseline was committed as
`9f6ed2d`, and the repository owner confirmed the commit prerequisite is satisfied.
HL1 is done: committed as `705e197`, with post-commit history confirmed (see
[HL1](#hl1--move)). HL2 (HL2a, HL2b) is done: the repository owner committed it as
`89a3fe8` (parent `705e197`; see [HL2](#hl2--wire-definitions)). HL3 (HL3a–HL3c) is
done in the working tree on top of `89a3fe8`. It is uncommitted (see
[HL3](#hl3--control-port)). HL4a is done in the working tree on top of `89a3fe8` plus the
uncommitted HL3 diff, and is also uncommitted (see [HL4](#hl4--link-decomposition)).
HL4b1 (`Serial_phy` extraction) and HL4c1 (its focused tests) are done in the working tree
on top of those diffs, also uncommitted. HL4b1's +84-cell generic-synthesis delta was
accepted by the owning planning session on 2026-09-24; see its implementation record.
HL4b2 (`Frame_rx` extraction) and HL4c2 (its focused tests) are implemented in the working
tree on top of those diffs, also uncommitted; planning accepted both on 2026-09-24, including
the +18-cell generic-synthesis delta (+102 against the unsplit baseline). HL4b3
(`Command_dispatch` extraction) and HL4c3 (its focused tests) are implemented in the working
tree on top of those diffs, also uncommitted. Every functional and equivalence gate passed, but
the generic-synthesis count moved 25 210 → 24 431 (−779; −677 against the unsplit baseline)
with 65 fewer mapped flip-flops; **planning accepted HL4b3 and HL4c3 on 2026-09-25**. HL4b4
(`Frame_tx` extraction, shared CRC, standalone checks) and HL4c4 (its focused tests), the last
planned blocks, are implemented in the working tree on top of those diffs, also uncommitted;
**their acceptance, the parent HL4b and HL4c items, and the exit gate are complete**
([HL4b4 record](host_link_hl4b4_record.md), with an
[exit-gate checklist](host_link_hl4b4_record.md#migration-exit-gate-checklist)).
This plan changes structure and verification
only. It adds no loader feature and does not change the P3.5 wire protocol.

## 1. Purpose and use

This plan separates the serial host link from the emulator core. Today the link works
and has P3.5 evidence, but its code is mixed into `lib/` with everything else and its
contract with the core exists only as matching field names. The goal is a `host_link/`
subsystem with a named boundary, a single OCaml definition of the wire format, and
blocks that can be simulated one at a time.

Use this document the same way as [phase_plan.md](phase_plan.md):

- IDs such as `HL2` are stable. Split a large item into suffixed IDs (`HL2a`) and keep
  the parent's goal.
- An item is done when its deliverable and evidence exist. Link them beside the checked
  item.
- Record a blocker beside an item and leave it unchecked.
- The wire protocol, pin map, and timing envelope in the
  [P3.5 record](p3.5-hardware-loader.md) remain authoritative. If a migration step
  needs to change any of them, update that record first and treat the change as P3
  work, not migration work.

The whole-`lib/` reorganization is specified in
[organization_migration.md](organization_migration.md). HL1 carries out that plan; this
document covers what has to happen after the files move.

### Planning ownership

This document owns migration scope, stable work IDs, decisions, blockers, and acceptance
evidence. `organization_migration.md` owns HL1's procedure; the P3.5 record owns wire and
timing behavior; `verification.md` owns enduring verification conventions; and
`phase_plan.md` owns product milestones.

The owning planning session prepares each implementation handoff with its work ID,
scope, decisions, affected files, prerequisites, and acceptance checks. Review returned
source changes and evidence before checking an implementation item. Record the tested
revision and local diff, tool/configuration identity, commands, results, and blockers.
Planning decisions below are not implementation evidence.

### Agent execution rules

- Every `dune build` and `dune runtest` invocation must include `-j 5`, including
  focused checks, forced reruns, and commands invoked through scripts. This server has
  experienced crashes under heavy workloads. Run build/test commands sequentially so
  concurrent invocations do not multiply the workload. Use `-j 5` for `dune exec`
  generation commands as well, since they can trigger builds.
- Agents must not create, amend, or otherwise make commits. Only the repository owner
  commits. References to a "commit" below describe intended owner-created review units;
  agents prepare the changes and evidence, then hand them back uncommitted. Do not stage
  changes unless the owner explicitly requests staging. `git mv`/`git rm` index updates
  required by the documented mechanical move are permitted; report them in the handoff.

## 2. Context

### What the host link is today

"Host link" means everything between the three serial pins and the core's program and
control requests. Since HL2 its wire definitions live in their own library, and the
hardware lives in two files:

| Piece | Location | Role |
| --- | --- | --- |
| Wire definitions: magic, version, command/result codes, capability bits, INFO/STATUS layouts, fault/phase values, CRC-8 parameters, software codec | `Wire` in [`host_link_wire/wire.ml`](../host_link_wire/wire.ml), library `hardcaml_protemu.host_link_wire` (no Hardcaml) | Protocol |
| Synthesizable CRC-8 and elaboration-time wire consistency checks | `Wire_crc.crc8_byte` in [`wire_crc.ml`](../lib/host_link/wire_crc.ml), used by `Frame_rx` and `Command_dispatch` and checking its CRC parameters at every use; each block's own `check_wire_encodings`, with the shared layout check in [`wire_layout.ml`](../lib/host_link/wire_layout.ml) (HL4b4) | Protocol, hardware side |
| Serial PHY: two-stage synchronizers on `LSEL_N`/`LCLK`/`LDI`, edge detection, select-high (deselect) qualification | `Serial_phy` in [`serial_phy.ml`](../lib/host_link/serial_phy.ml), composed by `Hardware_loader` (HL4b1) | Transport |
| Frame receive: bit shifting and byte assembly, byte count, saturation and sticky overrun, header and payload capture, CRC accumulation, deselect validation, retained request fields | `Frame_rx` in [`frame_rx.ml`](../lib/host_link/frame_rx.ml), composed by `Hardware_loader`, which supplies request eligibility (HL4b2) | Framing |
| Command dispatch: command legality, fixed lengths and device bounds, one-shot core offers, refusal classification, READ/ABORT completion waits, response frame construction and selection, combinational publication | `Command_dispatch` in [`command_dispatch.ml`](../lib/host_link/command_dispatch.ml), composed by `Hardware_loader`, which stores what it publishes (HL4b3) | Adapter onto the core |
| Core control port: `Request`, `Decision`, and `Status` records and their temporal contract | `Control_port` in [`control_port.ml`](../lib/emulator_core/control_port.ml), owned by the core (HL3) | Contract |
| Response transmit: retained store, response arming, restartable shifter, replay, commit on drain | `Frame_tx` in [`frame_tx.ml`](../lib/host_link/frame_tx.ml), composed by `Hardware_loader`, which reads its retained state for request eligibility (HL4b4) | Framing and transport |
| Composition: the four blocks, request eligibility, `busy_o` | [`hardware_loader.ml`](../lib/host_link/hardware_loader.ml), with no state of its own | Glue |
| Composition with the core: the three `Control_port` records | [`loader_core.ml`](../lib/host_link/loader_core.ml) | Glue |

HL4b1 moved the PHY into `Serial_phy`, HL4b2 the request receiver into `Frame_rx`, HL4b3
command dispatch into `Command_dispatch`, and HL4b4 the response path into `Frame_tx`, with
the shared CRC step and the wire checks given to their owners. `Hardware_loader` is now
only their composition. HL2 changed where their constants come from, not their structure.

### Who consumes it

| Consumer | What it uses |
| --- | --- |
| [`loader_core.ml`](../lib/host_link/loader_core.ml) | `Hardware_loader.create`, connected to `Integrated_core` by the `Control_port` request, decision, and status records |
| [`bin/asic_bundle.ml`](../bin/asic_bundle.ml) `Loader_design` | `Loader_core.I`/`O`, pins `ui[2:0]` and `uo[1:0]` |
| [`bin/generate_core.ml`](../bin/generate_core.ml) | `Loader_core` for the `loader` RTL mode |
| [`p3_loader_tb.v`](../tinytapeout/test/p3_loader_tb.v) | Emitted `loader_core` top-level ports only. It builds frames and CRC itself. |
| [`check-adopted-bundle.py`](../tinytapeout/scripts/check-adopted-bundle.py) | Source paths of both files, of `host_link_wire/`, of `control_port.ml`, of `serial_phy.ml`, of `frame_rx.ml`, of `frame_tx.ml`, of `command_dispatch.ml`, and of `wire_crc.ml` and `wire_layout.ml` in the loader manifest |
| [`test/host_link_wire/`](../test/host_link_wire/wire_tests.ml) | The `Wire` codec only, with fixed vectors from the P3.5 record |
| [`test/host_link/`](../test/host_link/hardware_loader_testbench.ml) | `Hardware_loader.create` in Cyclesim, through its serial pins and `Control_port` records, with the `Wire` codec and a test-only core stub (HL4a) |
| [`test/host_link/serial_phy/`](../test/host_link/serial_phy/serial_phy_testbench.ml) | `Serial_phy.create` alone in Cyclesim, through its public ports (HL4c1) |
| [`test/host_link/frame_rx/`](../test/host_link/frame_rx/frame_rx_testbench.ml) | `Frame_rx.create` alone in Cyclesim, through its public ports with explicit PHY-level events (HL4c2) |
| [`test/host_link/command_dispatch/`](../test/host_link/command_dispatch/command_dispatch_testbench.ml) | `Command_dispatch.create` alone in Cyclesim, through explicit `Frame_rx` handoffs and a test-only `Control_port` stub (HL4c3) |
| [`test/host_link/frame_tx/`](../test/host_link/frame_tx/frame_tx_testbench.ml) | `Frame_tx.create` alone in Cyclesim, through explicit PHY-level events and published frames (HL4c4) |

[`simulator_backend.ml`](../host/simulator_backend.ml) does not use the host link. It
drives the same `Control_port.Request` on `Integrated_core` directly (`drive_request`) and
consumes the same `Decision` and `Status` records, which makes it a second transport over
the same port.

## 3. Boundary weaknesses

These are the reasons a directory move alone does not produce a clean subsystem.

### W1. No named contract between the link and the core

*Addressed by HL3:* `Control_port` names the contract, and `Loader_core` connects three
records. The paragraph below describes the pre-HL3 state.

`Hardware_loader.I` repeats 35 of `Integrated_core.O`'s fields with `_o` renamed to
`_i`, and `Hardware_loader.O` repeats the 13-field program/control request half of
`Integrated_core.I`. `Loader_core` connects the two with 13 `wire`/`assign` pairs for
the requests and 35 record fields for the decisions and status. If a request type is added to the core, three files change by
hand. The compiler checks record completeness, but no shared type expresses the
correspondence between these interfaces or establishes correct field-to-field wiring.

### W2. Two producers of one port, with no shared type

*Addressed by HL3:* both producers use the `Control_port` records. The paragraph below
describes the pre-HL3 state.

`Hardware_loader` (over serial) and `Simulator_backend` (directly in Cyclesim) both
produce load, readback, run, stop, and abort requests and both consume the
accept/reject decisions and status. The real abstraction is a **core control port**.
The serial link and the simulator are two transports over it, but neither the code nor
the documents name the port.

### W3. The wire format has no OCaml host-side definition

*Addressed by HL2:* `Wire` is now the one OCaml definition, with a software codec. The
paragraphs below describe the pre-HL2 state. HL4a closed the Cyclesim gap:
[`test/host_link/`](../test/host_link/hardware_loader_testbench.ml) drives the unsplit
loader through its serial pins.

The only encoder and decoder outside the hardware are written by hand in Verilog in
`p3_loader_tb.v` (its own `crc8_byte`, literal `8'ha5`, fixed response offsets). No
OCaml code can build or parse a frame, so:

- there is no Cyclesim test of `Hardware_loader`; every protocol question is answered
  in iverilog against emitted RTL;
- P3.6's device backend has no codec to build on.

The Verilog peer's independence is deliberate: it is P3.5's independent serial peer,
and sharing code with the RTL would let one mistake pass both. That stays. The OCaml
codec added here is for OCaml tests and the P3.6 backend. It is not a replacement for
the peer.

### W4. The link's interface is wider than what it uses

*Partly addressed by HL3:* the link's core-facing interface is now the named contract.
By decision, the seven rejection fields remain in `Decision` and remain unread by the link.

The seven `*_rejected_i` inputs of `Hardware_loader.I` are declared and connected but
never read, because the loader treats "not accepted" as refused. The port was copied
from the core rather than designed for the link. W1's contract should contain only what
a transport needs. Rejection is currently `request_valid & ~accepted`, not the
unconditional complement of acceptance. Both decisions are low when there is no offer.
HL3 retains the explicit decisions while establishing their timing contract.

### W5. One monolithic block

The PHY, frame receiver, dispatcher, and response path share one register record and one
`compile`. None can be simulated or reviewed on its own, and a change to one (such as
the P3.5 overrun repair) touches the same block as all the others.

## 4. Phase map

| Phase | Outcome | Prerequisites | Addresses | Changes emitted RTL |
| --- | --- | --- | --- | --- |
| HL0 — Clean baseline | Committed tree | none | — | no |
| HL1 — Move | `lib/host_link/` exists; files moved | HL0 | layout | no (byte-identical) |
| HL2 — Wire definitions | One OCaml definition of the wire format, plus a software codec | HL1 | W3 | no |
| HL3 — Control port | Named request/decision/status contract shared by the link, the core, and the simulator backend | HL1 | W1, W2, W4 | port names only, if at all |
| HL4 — Link decomposition | PHY, frame receive, dispatch, and response blocks with Cyclesim tests | HL2, HL3 | W5, W3 | internal structure/names may change; cycle behavior must not |

HL2 and HL3 are independent and can be done in either order; the default execution order
is HL1, HL2, HL3, then HL4. HL4 needs both: its tests
use the HL2 codec, and its dispatcher speaks the HL3 port.

## 5. Items

### HL0 — Clean baseline

- [x] **HL0 — Commit in-flight loader work — resolved.** The P3.5 repair edits to
  `hardware_loader.ml`, `loader_core.ml`, the checker, and the testbench are committed,
  so the move commit contains only the move. *Done:* `9f6ed2d`; repository owner
  confirmed on 2026-09-21 that the prerequisite is satisfied. Planning-document updates
  do not reopen HL0; record their diff separately from the implementation baseline.

### HL1 — Move

- [x] **HL1 — Carry out the `lib/` reorganization.** Follow
  [organization_migration.md](organization_migration.md) steps 1–5, which place
  `hardware_loader.ml` and `loader_core.ml` in `lib/host_link/` and switch `lib/dune` to
  `(include_subdirs unqualified)`. No module is renamed and no identifier changes.
  Evidence: the verification table in that document passes, including the byte-identical
  RTL diff against the step 1 baseline and pre-commit rename detection. The owner checks
  `git log --follow` on a moved file after committing; the agent records that check as
  pending owner commit rather than claiming it passed. The
  bundle identity hashes change because `source_inputs` paths change; the commit message
  says so.
  *Done:* `705e197` (parent `9f6ed2d`); every check in the procedure's verification
  table passed. See
  [the implementation record](organization_migration.md#implementation-record-2026-09-21).
  The repository owner committed the move on 2026-09-21 and confirmed
  `git log --follow lib/emulator_core/integrated_core.ml` shows pre-move history
  (`bb8fdb0`, `a0e47ce`, ...).

### HL2 — Wire definitions

- [x] **HL2a — Pure wire module.** Move `Config`, `Command`, `Result`, and `Capability`
  out of `hardware_loader.ml` into a Hardcaml-free `Wire` module with a software
  `crc8`, a request encoder, and a response decoder. It must be its own Dune library
  at `host_link_wire/` beside `isa/`, separating serial framing from instruction encoding
  and from `lib/`'s single-library subtree. Host software must not depend on Hardcaml.
  Include header/payload layouts, lengths, byte order, INFO capabilities, STATUS flag
  positions, and wire fault/phase values. Define explicit mappings from execution-unit
  fault/phase values to stable wire values without making the pure library depend on
  execution-unit code. For today's identical numeric encodings, use elaboration-time
  consistency checks and direct signal wiring so documenting this mapping does not
  introduce decode/re-encode logic or violate the byte-identical RTL gate.
  Hardware CRC logic remains synthesizable and uses shared CRC
  parameters; the software CRC is a separate implementation. Update bundle source-input
  inventories/checker expectations so source identity covers the new definitions.
  Evidence: hardware takes wire constants from `Wire`; emitted RTL is byte-identical;
  unit tests check CRC-8/ATM (`123456789` gives `0xf4`), fixed request vectors for every
  command, and response vectors covering every result and payload shape. Check bad
  magic/version, truncation, extra bytes, inconsistent/oversized lengths, CRC failure,
  and unknown codes with explicit decoder outcomes. Validate tag/command correlation
  at a named codec or caller boundary. Round trips may supplement these vectors, but
  are not their only oracle. Preserve mismatch responses carrying the actual word.
  The pure library must build without Hardcaml dependencies.
  *Done in the working tree, uncommitted; the owner has not committed it.* Tested
  revision `705e197` plus the local diff. `Hardware_loader` takes its wire constants from
  `Wire`, and elaboration checks cover the fault/phase mapping and CRC parameters. All 15
  generator outputs and all six bundle Verilog source roles are byte-identical, and 26
  fixed-vector codec tests pass. The library's dependency closure contains no Hardcaml.
  The loader bundle inventory and checker now cover `host_link_wire/`. Decoder policy and
  one recorded correlation ambiguity are in
  [the HL2 implementation record](host_link_hl2_record.md), with complete evidence.
- [x] **HL2b — Record and preserve the independence rule.** State in the P3.5 record and in
  [verification.md](verification.md) that `p3_loader_tb.v` stays independent of `Wire`,
  in the same way `f_model/` stays independent of the RTL. Evidence: the documents say
  so, and `p3_loader_tb.v` is unchanged. The rule is already recorded in those
  authorities; check this item when HL2's implementation preserves it.
  *Done in the working tree, uncommitted.* `p3_loader_tb.v` has no diff against
  `705e197` (blob `2ffc20f0`) and shares nothing with `Wire`. A forced
  `@loader-rtl --force -j 5` run passed all three peer tiers. Both authorities now name the
  existing library. See [the HL2 record](host_link_hl2_record.md#verification).

### HL3 — Control port

- [x] **HL3a — Define `Control_port`.** Add direction-neutral interface types (see
  [formatting_guide.md §5](formatting_guide.md#5-direction-neutral-types)) in
  `emulator_core/`: `Request` (load start/write/complete, readback, run, stop, abort,
  with operands), `Decision` (accept/reject per request plus the readback response), and
  `Status` (the fields the link reports in STATUS and uses to classify refusals).
  **Decision:** preserve separate acceptance/rejection signals for the initial adoption.
  Rejection means `request_valid & ~accepted`; it is only complementary during an
  offer. Removing redundant decisions is a separate follow-up.
  Specify offer/operand stability and sampling edge, decision observation timing,
  one-shot offer versus any permitted stall, simultaneous-request arbitration, READ
  response validity/data timing, ABORT cleanup completion, STOP acceptance versus eventual
  halt, and reset/disable cancellation. Derive these from the existing implementation
  and preserve behavior; record the enduring temporal contract beside the types.
  Keep pin-claim operations, queues, and step outside this common request subset. Status
  observations of pin enables/claims remain included where the link needs them; they are
  not pin-control operations. Evidence: types and temporal contract exist, with focused
  checks for idle decisions, offers/refusals, arbitration, delayed completion, and
  cancellation, reusing existing tests where they already establish those obligations.
  *Done in the working tree, uncommitted.* Tested revision `89a3fe8` plus the local diff.
  [`control_port.ml`](../lib/emulator_core/control_port.ml) holds `Request` (13 fields),
  `Decision` (17), and `Status` (18) at their existing widths, with the temporal contract
  beside them. It depends only on width definitions. Five new contract tests exercise the
  real `Integrated_core`, and existing suites are reused for the remaining obligations. The
  mapping, derivation, and test-to-obligation table are in
  [the HL3 record](host_link_hl3_record.md).
- [x] **HL3b — Adopt it in `Integrated_core` and `Hardware_loader`.** Embed the records
  in both modules' `I`/`O` and reduce `Loader_core` to connecting three records. Choose
  the embedding's naming (`[@rtlprefix]`/`[@rtlmangle]`) so `Integrated_core`'s emitted
  port names do not change, because `p3_integration_tb.v` and `p3_control_tb.v` drive
  them by name. If names must change, update those testbenches in the same commit per
  [formatting_guide.md §10](formatting_guide.md#10-tests-and-documentation). Evidence:
  `@runtest` and `@rtl` pass, `loader_core.v` is byte-identical or differs only in
  internal names, and the three loader peer tiers pass.
  *Done in the working tree, uncommitted.* Planning decision
  [D1](host_link_hl3_record.md#d1-status-is-a-projection-in-integrated_core-accepted),
  accepted 2026-09-24: `Integrated_core` exposes `Status` through a typed projection
  rather than an embedded field.
  `Hardware_loader` embeds all three records, and `Integrated_core` embeds `Request` and
  `Decision` with unchanged port names, widths, and order
  (`[@@deriving hardcaml ~rtlmangle:false]` plus `[@rtlsuffix]`). `Integrated_core`'s status
  ports are not contiguous, and embedding them would reorder its emitted ports. They are
  therefore exposed as the typed projection `Integrated_core.control_status`. `Loader_core`
  connects three records. All 15 generator outputs and all six bundle Verilog files are
  byte-identical, `@runtest` and `@rtl` pass, and a forced `@loader-rtl` passed all three
  peer tiers. See [the HL3 record](host_link_hl3_record.md#verification).
- [x] **HL3c — Adopt it in `Simulator_backend`.** Rewrite the common portion of
  `clear_inputs` and `drive_request` over `Control_port.Request`, and consume the shared
  decision/status records. Preserve simulator-specific controls and its pre-edge
  decision/post-edge state observation convention. Evidence: `test/host/` and
  `test/integration/host_simulator/` pass with no expect-test diffs.
  *Done in the working tree, uncommitted.* The common part of `clear_inputs` and
  `drive_request` uses `Control_port.Request`. `view` holds the shared `Decision` record, and
  status, loaded-image, fault, and trace observations read `Control_port.Status`.
  Simulator-specific controls and the sampling points are unchanged. Both suites and the
  CLI expectation diffs pass unchanged. One added test pins the control-offer trace
  outcomes, which no test previously asserted. See
  [the HL3 record](host_link_hl3_record.md#test-to-obligation-coverage).

### HL4 — Link decomposition

- [x] **HL4a — Cyclesim harness first.** Before splitting anything, add a Cyclesim
  testbench under `test/host_link/` that drives `Hardware_loader` through its serial
  pins using the HL2 codec, with a stub core behind the HL3 port. Port the directed
  P3.5 cases that do not need the full core (framing, overrun, CRC, replay, correlation).
  Evidence: the harness passes against the unsplit block. This is the baseline for
  HL4b. Include cycle observations for offer count/timing, delayed completions,
  cancellation, early selection, retained-response replay, and final-fall commit.
  Record which P3.5 cases remain full-core/RTL-only; porting must not silently retire
  any existing obligation.
  *Done in the working tree, uncommitted.* Tested revision `89a3fe8` plus the
  uncommitted HL3 diff, recorded separately. [`test/host_link/`](../test/host_link/hardware_loader_testbench.ml)
  (library `protemu_host_link_tests`, in ordinary `@runtest`) has 32 tests against the
  real, unsplit `Hardware_loader`, driven only through its serial pins with `Wire` and
  answered by a test-only `Control_port` stub. Contract-faithful cases and labelled
  robustness probes (delayed, stalled, or stray completions) are kept apart. The suite
  asserts exact cycles for offers, READ and ABORT completion, cancellation, `LRDY`, response
  arming, and final-fall commit. Three temporary production mutations were each detected
  and then reverted. No production source or `p3_loader_tb.v` changed, and a forced
  `@loader-rtl` passed all three peer tiers. The scheduling contract, stub, case-to-obligation
  map (including what stays full-core or RTL-only), exact latencies, and evidence are in
  [the HL4a record](host_link_hl4a_record.md). HL4b must keep this suite passing
  unchanged.
- [x] **HL4b — Split the block.** Extract `Serial_phy` (synchronizers, edges,
  select-high count), `Frame_rx` (byte assembly, overrun, header and CRC), `Command_dispatch`
  (offers, waits, refusal classification, response selection), and `Frame_tx` (retained
  store, shifter, commit). Before extraction, record each block's input/output timing,
  register ownership, and reset/disable behavior. Assign exactly one owner to selection
  qualification, request/response arming, retained tag/command, dispatch and completion
  waits, response retention, and commit. Define boundary events without adding pipeline
  stages or changing same-cycle priorities. `Hardware_loader` becomes their composition.
  Split one block per commit, adding its HL4c tests in that slice. Evidence: after each
  extraction the HL4a cycle observations and all three `p3_loader_tb.v` tiers pass.
  Compare emitted RTL against the pre-extraction baseline; explain structural differences
  and establish unchanged cycle behavior rather than assuming every difference is a rename.
  Capture the loader checker's pre-split generic synthesis count and exact tool/configuration
  identity; rerun identically and report total and per-cell-type deltas against both the
  previous accepted slice and the unsplit baseline. HL4b1 demonstrates that name-only
  changes can alter this tool's combinational mapping, so count equality is not a reliable
  invariant of equivalent logic. Investigate and explicitly review any nonzero delta
  before acceptance; there is no unspecified "within noise" or percentage allowance.
  For changed RTL, include sequential-equivalence evidence with state correspondence,
  proof scope, preprocessing/reset assumptions, and any unproven points. An incomplete
  proof needs planning review, not a claim of complete equivalence. Equal flip-flop
  counts and functional equivalence do not by themselves establish unchanged cost.
  *Done in the working tree, uncommitted. All four children and this parent were accepted
  by planning; final exit review completed on 2026-09-25.*
- [x] **HL4b1 — `Serial_phy` extraction.** Move the synchronizers, edge history, events,
  and select-high qualification into [`serial_phy.ml`](../lib/host_link/serial_phy.ml);
  `Hardware_loader` composes it and keeps arming, framing, dispatch, and the response path.
  *Done in the working tree, uncommitted; accepted by planning on 2026-09-24.*
  Tested revision `89a3fe8` plus the uncommitted HL3 and HL4a diffs, recorded separately.
  The ownership and interface contract was recorded before editing. All 32 HL4a tests pass
  unchanged, and a forced `@loader-rtl` passed all three peer tiers. `@runtest`, `@rtl`,
  the full loader checker, and all three metadata checks pass. 14 of 15 generator outputs
  and 4 of 6 bundle Verilog files are byte-identical. External ports are identical, and
  emitted `loader_core` is formally proven sequentially equivalent to the baseline
  (1 331/1 331 points). **Reviewed delta:** the checker's generic-synthesis count moved
  25 108 → 25 192 cells (+84) with identical flip-flops. The source/RTL review, equivalence,
  regressions, and controlled name-sensitivity experiments support accepting this specific
  increase. It remains a real count increase, not proof of unchanged area or a blanket
  allowance for later slices. The wrapper proof uses an `async2sync` model; it does not
  establish unrestricted asynchronous reset equivalence. See
  [the acceptance decision](host_link_hl4b1_record.md#planning-acceptance-decision).
- [x] **HL4b2 — `Frame_rx` extraction.** Move byte assembly, the saturating byte count and
  sticky overrun, header/payload capture, CRC accumulation, deselect validation, and the
  retained request fields into [`frame_rx.ml`](../lib/host_link/frame_rx.ml);
  `Hardware_loader` composes it, supplies request eligibility, and keeps dispatch,
  completion waits, and the response path.
  *Done in the working tree, uncommitted; accepted by planning on 2026-09-24.*
  Tested revision `89a3fe8` plus the uncommitted HL3, HL4a, and HL4b1 diffs, recorded
  separately. The ownership and timing contract was recorded before editing and implemented
  unchanged. All 32 HL4a and 11 HL4c1 tests pass unchanged, and a forced `@loader-rtl` passed
  all three peer tiers. `@install`, `@lint`, `@runtest`, `@rtl`, the full loader checker, and
  all three metadata checks pass. 14 of 15 generator outputs and 4 of 6 bundle Verilog files
  are byte-identical, and external ports are identical. Emitted `loader_core` is proven
  sequentially equivalent to HL4b1 (1 331/1 331 points; a precedence mutant fails). The
  wrapper proof is complete only under `async2sync` (5 425/5 425); untransformed, the
  wrapper's own reset synchronizer leaves 2 points unproven. **Reviewed delta:** the checker's
  generic-synthesis count moved 25 192 → 25 210 (+18; +102 against the unsplit 25 108) with
  identical flip-flops. The emitted differences are 13 register renames, one redundant
  `~enable_i`, and one reassociated AND. Controlled variants show count movement of the same
  size from naming alone, without isolating the exact cause of +18. Planning accepts this
  specific result based on the combined structural, equivalence, regression, and synthesis
  evidence; no blanket allowance follows. See
  [the acceptance decision](host_link_hl4b2_record.md#planning-acceptance-decision).
- [x] **HL4b3 — `Command_dispatch` extraction.** Move command recognition, fixed lengths,
  operand bounds, one-shot offers, refusal classification, READ/VERIFY and ABORT waits, and
  response construction and selection into
  [`command_dispatch.ml`](../lib/host_link/command_dispatch.ml); `Hardware_loader` composes
  it, supplies eligibility, and stores the response it publishes.
  *Done in the working tree, uncommitted; accepted by planning on 2026-09-25.*
  Tested revision `89a3fe8` plus the uncommitted HL3, HL4a, HL4b1, and HL4b2 diffs, recorded
  separately. The ownership and timing contract was recorded before editing and implemented
  unchanged: the dispatcher reads `Frame_rx`'s retained fields directly and exports the
  complete response frame, length, and a publish strobe combinationally in the existing
  cycle. All 32 HL4a, 11 HL4c1, and 26 HL4c2 tests pass unchanged, and a forced
  `@loader-rtl` passed all three peer tiers. `@install`, `@lint`, `@runtest`, `@rtl`, the full
  loader checker, and all three metadata checks pass. 14 of 15 generator outputs and 4 of 6
  bundle Verilog files are byte-identical, external ports are identical, and the 163 state
  registers keep their names (after the scope rename) and widths. Emitted `loader_core` is
  proven sequentially equivalent to HL4b2 (1 331/1 331 points; a refusal-order mutant leaves
  6 unproven). The wrapper proof is complete only under `async2sync`; untransformed, the
  wrapper's own reset synchronizer leaves 2 points unproven, as in HL4b2. **Reviewed delta:** the
  checker's generic-synthesis count moved 25 210 → 24 431 (−779; −677 against the unsplit
  25 108), and mapped flip-flops 5 383 → 5 318. The flop change is localized to the retained
  response store and length: the new publish strobe becomes a clock enable, and the tool
  then drops or merges 65 store/length bits that are constant or duplicated across every
  frame. Cross-over variants attribute most of the cell change to that update form.
  Planning accepts this specific optimization of equivalent RTL state, with the remaining
  total-cell attribution limitation recorded. It is not a physical-cost claim or a
  blanket allowance for further mapped-state changes. See
  [the acceptance decision](host_link_hl4b3_record.md#planning-acceptance-decision).
- [x] **HL4b4 — `Frame_tx` extraction and final helper/check ownership.** Move the retained
  store, arming, shifter, replay, and commit into [`frame_tx.ml`](../lib/host_link/frame_tx.ml);
  move `crc8_byte` to [`wire_crc.ml`](../lib/host_link/wire_crc.ml); give each block its own
  elaboration-time `Wire` checks, sharing the tiling check through
  [`wire_layout.ml`](../lib/host_link/wire_layout.ml). `Hardware_loader` becomes composition.
  *Done in the working tree, uncommitted; accepted by planning on 2026-09-25.*
  Tested revision `89a3fe8` plus the uncommitted HL3, HL4a, and HL4b1–HL4b3 diffs, recorded
  separately. The ownership and timing contract was recorded before editing; the
  helper/check move was applied and checked first, on its own, and left all 15 generator
  outputs and all six bundle Verilog files byte-identical. After the state move, all 32
  HL4a, 11 HL4c1, 26 HL4c2, and 39 HL4c3 tests pass unchanged, and a forced `@loader-rtl`
  passed all three peer tiers. `@install`, `@lint`, `@runtest`, `@rtl`, the full loader
  checker, and all three metadata checks pass. 14 of 15 generator outputs and 4 of 6 bundle
  Verilog files are byte-identical, external ports are identical, and the only RTL changes
  are the six register renames, one forward wire, and anonymous renumbering. Emitted
  `loader_core` is proven sequentially equivalent to HL4b3 (1 505/1 505 points; a
  priority mutant leaves exactly `response_pending` unproven). The wrapper proof is
  complete only under `async2sync`; untransformed, the wrapper's own reset synchronizer
  leaves 2 points unproven, as before. The recorded proof chain connects the unsplit
  `loader.v` to the final one; no direct end-to-end proof was run. Standalone negatives
  show every relocated check enforced when its block is elaborated alone. **Synthesis:** the checker's generic synthesis is unchanged at 24 431 cells (every per-type
  count equal; −677 against the unsplit 25 108) and 5 318 mapped flip-flops, with a
  bit-for-bit identical mapped flip-flop inventory; the only `stat` change is one 1-bit
  wire. Planning accepted this result and the recorded proof chain; no direct end-to-end
  rerun is required. It is not a physical-cost claim. See
  [the HL4b4 record](host_link_hl4b4_record.md) and its
  [exit-gate checklist](host_link_hl4b4_record.md#migration-exit-gate-checklist).
- [x] **HL4c — Per-block tests.** Add a focused Cyclesim test for each extracted block,
  following [verification.md](verification.md)'s per-module testbench convention.
  Evidence: the tests exist and pass. Each block's tests land with its extraction and
  cover its boundary obligations, including relevant malformed input, cancellation,
  and retained-state behavior. HL4c completes when all extracted blocks are covered.
  *Done: all four blocks have accepted focused tests; parent accepted on 2026-09-25.*
- [x] **HL4c1 — `Serial_phy` tests.** *Done in the working tree, uncommitted.*
  [`test/host_link/serial_phy/`](../test/host_link/serial_phy/serial_phy_testbench.ml)
  (library `protemu_serial_phy_tests`, in `@runtest`) has 8 timing tests and 3 diagnostics
  negatives against hand-written cycles: synchronizer latency, one-cycle events without
  repeats, the qualification threshold, saturation and restart, coincident transitions,
  and the different reset and disable behavior. Four temporary PHY mutations were each
  detected, one of them (disable not clearing qualification) only by this suite. See
  [the HL4b1 record](host_link_hl4b1_record.md#focused-tests-hl4c1).
- [x] **HL4c2 — `Frame_rx` tests.** *Done in the working tree, uncommitted; accepted with
  HL4b2 on 2026-09-24.*
  [`test/host_link/frame_rx/`](../test/host_link/frame_rx/frame_rx_testbench.ml) (library
  `protemu_frame_rx_tests`, in `@runtest`) has 22 tests and 4 diagnostics negatives. They
  drive the receiver with explicit PHY-level events and check hand-written results, fields,
  and cycles: every legal request, bit order and sample cycle, pauses, truncation, partial
  and extra bytes, sticky overrun and prefix attacks, declared-length disagreement,
  validation precedence, the four-byte echo threshold, retention while ineligible,
  eligibility edges, and reset/disable at each boundary. Robustness probes are labelled. Six
  temporary mutations were each detected; the magic/version precedence swap only by this
  suite. See [the HL4b2 record](host_link_hl4b2_record.md#focused-tests-hl4c2).
- [x] **HL4c3 — `Command_dispatch` tests.** *Done in the working tree,
  uncommitted; accepted with HL4b3 on 2026-09-25.*
  [`test/host_link/command_dispatch/`](../test/host_link/command_dispatch/command_dispatch_testbench.ml)
  (library `protemu_command_dispatch_tests`, in `@runtest`) has 34 tests and 5 diagnostics
  negatives. They drive the dispatcher with explicit `Frame_rx` handoffs and a test-only
  core stub and check hand-written offers, full request records, responses, and cycles:
  every command and operand, unknown commands, every wrong fixed length, full-width device
  bounds, result precedence, INFO/STATUS contents and sampling cycle, refusal classes,
  STOP `Accepted_pending`, framing-error bypass and zero echo, correlation, READ/VERIFY and
  ABORT waits with each missing cleanup condition, stray completions, reset/disable at every
  boundary, and same-cycle priorities. Robustness probes are labelled. Twelve temporary
  mutations were each detected; three (rejected-signal use, 8-bit length compare, narrowed
  LOAD_START bound) only by this suite. See
  [the HL4b3 record](host_link_hl4b3_record.md#focused-tests-hl4c3).
- [x] **HL4c4 — `Frame_tx` tests.** *Done in the working tree, uncommitted;
  accepted by planning with HL4b4 on 2026-09-25.*
  [`test/host_link/frame_tx/`](../test/host_link/frame_tx/frame_tx_testbench.ml) (library
  `protemu_frame_tx_tests`, in `@runtest`) has 24 tests and 5 diagnostics negatives. They
  drive the transmitter with explicit PHY-level events and published frames and check
  hand-written bits and cycles: every legal length, the capture edge, retention, store and
  shifter independence, qualified and unqualified arming, a publication coinciding with the
  assert, early selections, MSB-first shifting at any fall spacing, pauses, the drained
  boundary, replay after every partial read including the final bit without the final fall,
  commit exactly once, reset/disable at each point, and same-cycle priorities. Robustness
  probes are labelled. Nine temporary mutations targeting arming, replay, final-fall
  commit, and event priority were each detected; one (arming on a same-cycle publication)
  only by this suite. See [the HL4b4 record](host_link_hl4b4_record.md#focused-tests-hl4c4).

**Exit gate — accepted 2026-09-25:** `lib/host_link/` holds the link; `Loader_core` connects typed records
rather than individual fields; the wire format has one OCaml definition used by the
hardware and the OCaml tests; the link has OCaml simulation tests; and the independent
Verilog peer still passes on all three tiers. At that point P3.6 can build its device
backend for existing commands on `Wire` and `Host_api.Device` without changing their
RTL behavior. Full P3.6 still requires queue transport, including additional RTL support,
and its recorded API/error/time decisions; migration completion does not close those
product obligations.

## 6. Non-goals

- Changing the wire protocol, pin map, timing envelope, or result codes.
- The module renames and qualified namespaces listed under
  [organization_migration.md, Later steps](organization_migration.md#later-steps). They
  can follow at any point after HL1.
- P3.6 itself: the physical transport backend, queue transport, and board work.
