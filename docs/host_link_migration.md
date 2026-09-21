# Host link migration

Status: planned, reviewed 2026-09-21. HL0 is resolved: the baseline was committed as
`9f6ed2d`, and the repository owner confirmed the commit prerequisite is satisfied.
HL1 implementation and agent-side verification are complete in the working tree,
pending the owner's commit and `git log --follow` check (see [HL1](#hl1--move)).
HL2–HL4 implementation is not started; the HL2b independence policy is recorded.
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
control requests. It lives in two files:

| Piece | Location | Role |
| --- | --- | --- |
| Wire definitions: magic, version, command codes, result codes, capability bits, CRC-8 | `Config`, `Command`, `Result`, `Capability`, `crc8_byte` in [`hardware_loader.ml`](../lib/host_link/hardware_loader.ml) | Protocol |
| Serial PHY: two-stage synchronizers on `LSEL_N`/`LCLK`/`LDI`, edge detection, bit shifting, select-high qualification | `hardware_loader.ml`, inside `create` | Transport |
| Frame receive: byte count, saturation and sticky overrun, header capture, CRC accumulation, deselect validation | `hardware_loader.ml`, inside `create` | Framing |
| Command dispatch: one-shot core offers, READ/ABORT completion waits, refusal classification | `hardware_loader.ml`, inside `create` | Adapter onto the core |
| Response build and transmit: frame construction, retained store, restartable shifter, commit on drain | `hardware_loader.ml`, inside `create` | Framing and transport |
| Composition with the core | [`loader_core.ml`](../lib/host_link/loader_core.ml) | Glue |

All five roles in `hardware_loader.ml` share one `I_Regs` record and one `compile` block
of about 680 lines.

### Who consumes it

| Consumer | What it uses |
| --- | --- |
| [`loader_core.ml`](../lib/host_link/loader_core.ml) | `Hardware_loader.create`, wired field by field to `Integrated_core` |
| [`bin/asic_bundle.ml`](../bin/asic_bundle.ml) `Loader_design` | `Loader_core.I`/`O`, pins `ui[2:0]` and `uo[1:0]` |
| [`bin/generate_core.ml`](../bin/generate_core.ml) | `Loader_core` for the `loader` RTL mode |
| [`p3_loader_tb.v`](../tinytapeout/test/p3_loader_tb.v) | Emitted `loader_core` top-level ports only. It builds frames and CRC itself. |
| [`check-adopted-bundle.py`](../tinytapeout/scripts/check-adopted-bundle.py) | Source paths of both files in the loader manifest |

[`simulator_backend.ml`](../host/simulator_backend.ml) does not use the host link. It
drives the same `Integrated_core` request ports directly (`drive_request`), which makes
it a second producer of the same contract.

## 3. Boundary weaknesses

These are the reasons a directory move alone does not produce a clean subsystem.

### W1. No named contract between the link and the core

`Hardware_loader.I` repeats 35 of `Integrated_core.O`'s fields with `_o` renamed to
`_i`, and `Hardware_loader.O` repeats the 13-field program/control request half of
`Integrated_core.I`. `Loader_core` connects the two with 13 `wire`/`assign` pairs for
the requests and 35 record fields for the decisions and status. If a request type is added to the core, three files change by
hand. The compiler checks record completeness, but no shared type expresses the
correspondence between these interfaces or establishes correct field-to-field wiring.

### W2. Two producers of one port, with no shared type

`Hardware_loader` (over serial) and `Simulator_backend` (directly in Cyclesim) both
produce load, readback, run, stop, and abort requests and both consume the
accept/reject decisions and status. The real abstraction is a **core control port**.
The serial link and the simulator are two transports over it, but neither the code nor
the documents name the port.

### W3. The wire format has no OCaml host-side definition

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

- [ ] **HL1 — Carry out the `lib/` reorganization.** Follow
  [organization_migration.md](organization_migration.md) steps 1–5, which place
  `hardware_loader.ml` and `loader_core.ml` in `lib/host_link/` and switch `lib/dune` to
  `(include_subdirs unqualified)`. No module is renamed and no identifier changes.
  Evidence: the verification table in that document passes, including the byte-identical
  RTL diff against the step 1 baseline and pre-commit rename detection. The owner checks
  `git log --follow` on a moved file after committing; the agent records that check as
  pending owner commit rather than claiming it passed. The
  bundle identity hashes change because `source_inputs` paths change; the commit message
  says so.
  *Status 2026-09-21:* implementation and agent-side verification complete, uncommitted
  on top of `9f6ed2d`; every check in the procedure's verification table passed. See
  [the implementation record](organization_migration.md#implementation-record-2026-09-21).
  *Remaining (owner):* commit the move, then confirm
  `git log --follow lib/emulator_core/integrated_core.ml` shows pre-move history.

### HL2 — Wire definitions

- [ ] **HL2a — Pure wire module.** Move `Config`, `Command`, `Result`, and `Capability`
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
- [ ] **HL2b — Record and preserve the independence rule.** State in the P3.5 record and in
  [verification.md](verification.md) that `p3_loader_tb.v` stays independent of `Wire`,
  in the same way `f_model/` stays independent of the RTL. Evidence: the documents say
  so, and `p3_loader_tb.v` is unchanged. The rule is already recorded in those
  authorities; check this item when HL2's implementation preserves it.

### HL3 — Control port

- [ ] **HL3a — Define `Control_port`.** Add direction-neutral interface types (see
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
- [ ] **HL3b — Adopt it in `Integrated_core` and `Hardware_loader`.** Embed the records
  in both modules' `I`/`O` and reduce `Loader_core` to connecting three records. Choose
  the embedding's naming (`[@rtlprefix]`/`[@rtlmangle]`) so `Integrated_core`'s emitted
  port names do not change, because `p3_integration_tb.v` and `p3_control_tb.v` drive
  them by name. If names must change, update those testbenches in the same commit per
  [formatting_guide.md §10](formatting_guide.md#10-tests-and-documentation). Evidence:
  `@runtest` and `@rtl` pass, `loader_core.v` is byte-identical or differs only in
  internal names, and the three loader peer tiers pass.
- [ ] **HL3c — Adopt it in `Simulator_backend`.** Rewrite the common portion of
  `clear_inputs` and `drive_request` over `Control_port.Request`, and consume the shared
  decision/status records. Preserve simulator-specific controls and its pre-edge
  decision/post-edge state observation convention. Evidence: `test/host/` and
  `test/integration/host_simulator/` pass with no expect-test diffs.

### HL4 — Link decomposition

- [ ] **HL4a — Cyclesim harness first.** Before splitting anything, add a Cyclesim
  testbench under `test/host_link/` that drives `Hardware_loader` through its serial
  pins using the HL2 codec, with a stub core behind the HL3 port. Port the directed
  P3.5 cases that do not need the full core (framing, overrun, CRC, replay, correlation).
  Evidence: the harness passes against the unsplit block. This is the baseline for
  HL4b. Include cycle observations for offer count/timing, delayed completions,
  cancellation, early selection, retained-response replay, and final-fall commit.
  Record which P3.5 cases remain full-core/RTL-only; porting must not silently retire
  any existing obligation.
- [ ] **HL4b — Split the block.** Extract `Serial_phy` (synchronizers, edges,
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
  identity; rerun identically and report total and per-cell-type deltas. Exact equality is
  expected for name-only changes. Investigate and explicitly review any nonzero delta
  before acceptance; there is no unspecified "within noise" allowance.
- [ ] **HL4c — Per-block tests.** Add a focused Cyclesim test for each extracted block,
  following [verification.md](verification.md)'s per-module testbench convention.
  Evidence: the tests exist and pass. Each block's tests land with its extraction and
  cover its boundary obligations, including relevant malformed input, cancellation,
  and retained-state behavior. HL4c completes when all extracted blocks are covered.

**Exit gate:** `lib/host_link/` holds the link; `Loader_core` connects typed records
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
