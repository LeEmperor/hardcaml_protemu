# HL3 implementation record: the core control port (2026-09-24)

Status: HL3a, HL3b, and HL3c implemented and verified by an agent in the working tree.
**Not committed:** nothing is committed or staged; the repository owner commits. Planning
decision [D1](#d1-status-is-a-projection-in-integrated_core-accepted) was accepted on 2026-09-24.
This is the implementation record for [HL3](host_link_migration.md#hl3--control-port). The
[P3.5 record](p3.5-hardware-loader.md) remains the wire and timing authority; no wire value,
protocol behavior, pin, or timing requirement changed.

## Starting revision and local diff

- `HEAD` = `89a3fe8` ("re-org phase 1", parent `705e197`), branch `bpurtell/scaf`.
- The handoff described HL2 as `705e197` plus an uncommitted diff. At the start of HL3 the
  owner had committed that diff: `89a3fe8` contains every HL2 file listed in
  [the HL2 record](host_link_hl2_record.md) (`host_link_wire/`, `test/host_link_wire/`,
  `hardware_loader.ml`, `lib/dune`, `bin/asic_bundle.ml`, the checker,
  `tinytapeout/src/dune`, and the HL2 documents).
- Local diff before any HL3 edit: **none**. `git status --porcelain` and `git diff` were
  empty, and the stash list was empty. The pre-change baseline below is `89a3fe8`'s
  sources, and there was no uncommitted owner work to preserve.
- HL3 diff (uncommitted, unstaged):

  | Path | Change |
  | --- | --- |
  | `lib/emulator_core/control_port.ml` (new) | `Control_port.Request`, `Decision`, `Status` and the temporal contract |
  | `lib/emulator_core/integrated_core.ml` | `I` embeds `control_request_i`; `O` embeds `control_decision_o`; new `control_status` projection; `create` reads and builds the records |
  | `lib/host_link/hardware_loader.ml` | `I` embeds `control_decision_i` and `control_status_i`; `O` embeds `control_request_o`; references renamed |
  | `lib/host_link/loader_core.ml` | Three record connections replace 13 wires/assigns and 35 fields |
  | `host/simulator_backend.ml` | Common `clear_inputs`/`drive_request` over `Control_port.Request`; `view` holds the `Decision` record; status, loaded image, fault, and trace read `Control_port.Status` |
  | `test/integration/core_engine/core_engine_testbench.ml` | Field paths updated; new `Together` request for same-cycle offers |
  | `test/integration/core_engine/core_engine_tests.ml`, `core_engine_timing_tests.ml` | Field paths only |
  | `test/integration/core_engine/core_engine_control_port_tests.ml` (new), `dune` | Five contract tests |
  | `test/integration/host_simulator/host_simulator_tests.ml` | One added test |
  | `bin/asic_bundle.ml`, `tinytapeout/scripts/check-adopted-bundle.py` | Loader source inventory and checker include `control_port.ml` |
  | `docs/` | This record and the current-reference updates under [Documentation](#documentation) |

## Tool identity

opam switch `5.2.0+ox` (OCaml 5.2.0+ox), Dune 3.24.2; `hardcaml`, `ppx_hardcaml`, `core`,
`ppx_jane` `v0.18~preview.130.106+341`; `ocamlformat` 0.26.2+ox2; `hardcaml_asic` 0.1.0;
Verilator 5.020, Icarus Verilog 12.0, Yosys 0.33, Python 3.12.3. The same installed switch
served every pre- and post-change run.

## The port

[`control_port.ml`](../lib/emulator_core/control_port.ml) holds three direction-neutral
records with `[@@deriving hardcaml]`. The module depends only on the width definitions of
`Protocol_core.Config`, `Control_execution`, and `Protemu_isa.Pins`, which do not depend
on it. It depends on no consumer, so there is no cycle. Every field keeps its previous
width. Nothing was merged, compressed, or removed.

### Field mapping

`Request` (13 fields) is produced by `Hardware_loader` and `Simulator_backend` and
consumed by `Integrated_core`:

| Field | Width | `Integrated_core` port | `Hardware_loader` port | Simulator request |
| --- | ---: | --- | --- | --- |
| `load_start_valid`, `load_length` | 1, 9 | `load_start_valid_i`, `load_length_i` | `load_start_valid_o`, `load_length_o` | `Load_start length` |
| `load_write_valid`, `load_address`, `load_data` | 1, 9, 16 | `load_write_valid_i`, `load_address_i`, `load_data_i` | `*_o` of the same names | `Load_write (address, data)` |
| `load_complete_valid` | 1 | `load_complete_valid_i` | `load_complete_valid_o` | `Load_complete` |
| `readback_valid`, `readback_address`, `readback_verify`, `readback_expected` | 1, 9, 1, 16 | `readback_*_i` | `readback_*_o` | `Readback { address; verify; expected }` |
| `run_valid`, `stop_valid`, `abort_valid` | 1 each | `run_valid_i`, `stop_valid_i`, `abort_valid_i` | `*_o` of the same names | `Run`, `Stop`, `Abort` |

`Decision` (17 fields) is produced by `Integrated_core` and consumed by both transports:
`load_start_`, `load_write_`, `load_complete_`, `readback_`, `run_`, `stop_`, and
`abort_` each with `accepted` and `rejected` (1 bit each); plus `readback_response_valid`
(1), `readback_response_data` (16), and `readback_response_match` (1). The ports are
`<field>_o` on `Integrated_core` and `<field>_i` on `Hardware_loader`, in the same order as
before. `Hardware_loader` still reads only acceptance and the response; the seven
`*_rejected` fields stay unread by decision.

`Status` (18 fields) is observed from `Integrated_core` and consumed by both transports:

| Field | Width | Loader use | Simulator use |
| --- | ---: | --- | --- |
| `halted` | 1 | STATUS flag; refusal class `0x20`; ABORT cleanup | `Api.Status.halted`, refusal |
| `engines_idle` | 1 | STATUS flag; refusal class `0x21`; ABORT cleanup | `Engine_status.idle`, refusal |
| `image_valid` | 1 | STATUS flag; RUN refusal class `0x22` | `Loaded_image.valid`, refusal |
| `load_active`, `verification_failed` | 1 each | STATUS flags | `Loaded_image` |
| `image_length`, `words_written`, `words_verified` | 9 each | STATUS u16 fields | `Loaded_image` |
| `fetch_fault`, `execution_active`, `normal_halt`, `execution_fault` | 1 each | STATUS flags | `Api.Status`, `Api.Fault`, refusal |
| `fault_kind` | 4 | STATUS byte | `Api.Fault.kind` |
| `pc` | 17 | STATUS u16 (`uresize`, unchanged) | `Api.Status.pc`, trace |
| `phase` | 3 | STATUS byte | `Api.Status.phase` |
| `pin_oe` | 8 | STATUS `Pin_output_enabled`; ABORT cleanup | `pin_output_enable`, trace |
| `software_claim`, `engine_claim` | 8 each | STATUS `Pin_claimed`; ABORT cleanup | `Engine_status` claims |

`Hardware_loader`'s own `enable_i` feeds the STATUS `Enabled` flag. It is the loader's
input, not a core observation, so it is not in `Status`.

Outside the shared subset, and unchanged: `step_valid_i`, `step_accepted_o`/`_rejected_o`,
software claim/release, queues, pads, program RAM, and every other `Integrated_core`
observation. `Loader_core` ties the unused ones off exactly as before.

### Naming: how the flat port names survive

The installed `ppx_hardcaml` (`hardcaml/ppx_hardcaml0/deriving_hardcaml_records.ml`) names
a nested interface field's ports `rtlprefix ^ mangle(field, inner) ^ rtlsuffix`. By
default `mangle` joins with `$`, which would give `control_request_i$load_start_valid`.
The type-level option `[@@deriving hardcaml ~rtlmangle:false]` makes `mangle` return the
inner name alone, and the field-level `[@rtlsuffix "_i"]` (or `"_o"`) appends the
direction. The result is `load_start_valid_i`, exactly the old name. A field-level
`[@rtlmangle false]` is not usable: the PPX takes that attribute's expression verbatim as
the separator string. All four affected `I`/`O` records use the type-level option. Their
other fields are plain `'a`, which mangling does not affect.

Hardcaml emits module ports in interface field order. `Request` occupies the same 13
contiguous positions in `Integrated_core.I` (between `en_i` and `step_valid_i`), and
`Decision` the same 17 in `Integrated_core.O` (between `prog_mem_write_data_o` and
`step_accepted_o`), so neither the names nor the order changed. The evidence is the
byte-identical `integrated.v` and `loader.v` and the identical port inventories below.

### D1. `Status` is a projection in `Integrated_core` (accepted)

`Hardware_loader.I` embeds `Status` directly. Its 18 status ports were already contiguous
and in `Status` order, and `Hardware_loader` is never a generated top. `Integrated_core.O`
does not embed it. Its status ports are not contiguous: `fault_instruction_slot_o` through
`retired_o` precede `pc_o`; `registers_o` through `descriptor_o` precede `phase_o`; and
sixteen fields (`fetch_cycles_o` through `pins_o`) precede `pin_oe_o`,
`software_claim_o`, and `engine_claim_o`. An embedded record is one contiguous run, so
embedding would move those five ports and change `integrated_core`'s emitted port order.
Names and widths would stay the same, and the named-connection `p3_integration_tb.v` would
be unaffected. It is still a change to external RTL beyond internal names, and it breaks
`integrated.v`'s byte identity. The handoff says to return that to planning rather than
relax the gate.

The implementation therefore keeps those ports flat and adds a typed projection:

```ocaml
Integrated_core.control_status : 'a Integrated_core.O.t -> 'a Control_port.Status.t
```

`Loader_core` passes `Integrated_core.control_status core` as `control_status_i`, and
`Simulator_backend` reads status through it, so both transports consume the shared record.
Nothing is emitted for it.

**Decision (accepted 2026-09-24):** the projection is HL3b's form of the `Status`
adoption for `Integrated_core`. The planning session accepted it over a real embedding, so
`integrated.v`'s port order and byte identity are preserved. The alternative that was
considered and not taken: embed `Status` and re-baseline `integrated.v` with the five
moved ports.

### Other implementation decisions

- `Protocol_core` keeps its own flat request/decision ports. It is the program-access
  sub-block, and the memory project drives it directly. Adopting the records there is not
  part of HL3.
- `Loader_core` uses `Control_port.Request.Of_signal.wires ()` and `Of_signal.assign` for the
  request loop, and passes `Decision`/`Status` as records. No register, stage, buffer, or
  handshake was added.
- `Simulator_backend.view` stores `Bits.t Control_port.Decision.t` (`Bits.t` is immutable),
  read with `Control_port.Decision.map o.control_decision_o ~f:( ! )` at the same sampling
  point as before. `clear_inputs` zeroes every `Request` field with `Request.iter`; a 1-bit
  `set_int 0` equals the old `set_bool false`.
- The core testbench gained `Together of request list` to offer several requests in one
  cycle. `Together [ Enable false ]` lowers `en_i` for that cycle only.

## Temporal contract

The enduring text is beside the types in
[`control_port.ml`](../lib/emulator_core/control_port.ml). Summary, with where each
statement comes from:

| Item | Contract | Derived from |
| --- | --- | --- |
| Offers | Each edge with a valid high is one offer, decided that cycle. No ready, stall, or held offer. Both producers pulse a valid for exactly one cycle per operation. | `Protocol_core` and `Integrated_core` accept expressions; `Hardware_loader`'s one-cycle `dispatch` register; `Simulator_backend.cycle` |
| Operands | Meaningful only with their valid. Stable before that cycle's sampling edge. The core registers what it needs later. | `Protocol_core` registers `image_length`, `host_read_verify`, `host_read_expected` on acceptance; the simulator zeroes operands after the offer cycle |
| Decisions | Combinational, observed in the offer cycle before the edge; effects after it. `rejected = valid & ~accepted`; both low with no offer. | `Protocol_core` and `Integrated_core` output expressions |
| Arbitration | ABORT (enabled, not reset) always accepted and refuses everything else via execution halt. STOP accepted unless ABORT is offered; it refuses RUN, not program requests, unless it pauses at a boundary that cycle. Program requests: LOAD_START > LOAD_WRITE > READBACK > LOAD_COMPLETE, by validity. RUN is refused by any program request, STOP/ABORT offer, or step request. | `Integrated_core` `abort_offer`/`stop_offer`/`run_offer`/`pause`; `Protocol_core` `host_allowed`, `no_*` chain, `run_accept` |
| READBACK completion | Registered response valid for exactly the cycle between edges E+1 and E+2 after acceptance at E. Cancelled by reset, disable, accepted ABORT, or accepted LOAD_START in the cycle between E and E+1. A second READBACK is refused meanwhile. | `Protocol_core` `host_read_response` and `readback_response_*` registers |
| ABORT completion | Cleanup is `halted & engines_idle & pin_oe = 0 & software_claim = 0 & engine_claim = 0`, established at the accepting edge. The loader waits with no bound; the simulator reports the first post-edge observation. | P3.3 control contract; P3.4 prompt completion boundary; `Hardware_loader` `abort_clean`; `Simulator_backend.abort` |
| STOP completion | Acceptance is not halt. A pending STOP halts at the next instruction boundary, unbounded. A STOP accepted while halted leaves nothing pending. | `Integrated_core` `stop_pending` update (`stop_accepted & ~halted`) |
| Reset/disable | Every offer is refused. Both cancel an outstanding READBACK and a pending STOP; disable preserves a completed image, reset invalidates it. | `abort_offer`/`stop_offer` and `host_allowed` terms; `Protocol_core` and `Integrated_core` `~en_i` branches |
| Status | Live observations with no valid qualifier. The loader samples before an edge, in the dispatch or ABORT-wait cycle. The simulator samples after an edge and classifies a refusal from the status seen before it drives the offer. | `Hardware_loader` `refusal_result`, `status_response`, `abort_clean`; `Simulator_backend.offer`/`refusal` |

No statement conflicted with an authoritative record. The P3.5 record's "`0x2f` ... normal
traffic does not emit it" and "Rejection is `request_valid & ~accepted`" agree with item 3.

## Test-to-obligation coverage

Existing tests reused, unchanged except field paths:

| Obligation | Existing evidence |
| --- | --- |
| Program-request decisions every edge (including both-low with no offer), priority among program requests, READBACK latency, cancellation across reset/disable/execution halt/reload | `test/core/protocol_core/`: twelve directed scenarios and 240 generated scenarios, compared per edge with the independent `f_model/program_access.ml` |
| ABORT > STOP > step > RUN in one cycle | `core_engine_tests.ml` "ABORT, STOP, single-step, and RUN obey simultaneous priority" |
| STOP waits for a boundary; ABORT releases pins and claims at once | `core_engine_tests.ml` "STOP waits for a boundary, ABORT releases, and step retires exactly one" |
| ABORT cleanup: all five status conditions in the first post-edge observation | `host_simulator_tests.ml` "engine pin ownership rejects host changes and ABORT observes release" and "STOP timeout preserves accepted work; step and ABORT recover" (`completed = true`) |
| STOP accepted before halt; accepted-operation timeout | `host_simulator_tests.ml` "STOP timeout preserves accepted work; ..." |
| Disable/reset engine cleanup and image preservation | `core_engine_tests.ml` "disable clears blocked and active engines while reset also invalidates image" |
| Serial end-to-end: one-shot offers, READ/ABORT waits, refusal classes, reset/disable cancellation | `p3_loader_tb.v`, three tiers (unchanged) |

Added, exercising the real `Integrated_core` through `Control_port.Decision`, with every
expectation written by hand:

| Test | Obligation |
| --- | --- |
| `core_engine_control_port_tests.ml` "with no offer every shared decision is low" | No-offer decisions (and no response) in six states: after reset, loaded, mid-load, running, with reset asserted, and disabled |
| "reset and disable refuse every shared offer" | For each of the eight offers (four program requests, verify, RUN, STOP, ABORT), a prepared state where it is accepted alone; the same offer with reset or disable in the same cycle gives `(false, true)` |
| "ABORT, STOP, RUN, and program requests arbitrate across groups" | ABORT refuses LOAD_START; STOP and LOAD_START are both accepted while halted; READBACK refuses RUN; a refused LOAD_START still refuses a legal write (priority by validity) |
| "READBACK responds once, one edge after acceptance, unless cancelled" | The response appears only after the second edge, with the offered address's data even though operands were zeroed after the offer; a second READBACK is refused and the first still completes; reset, disable, ABORT, and LOAD_START each cancel it |
| "STOP acceptance is not a halt, and a STOP accepted while halted is not kept" | Running: STOP accepted, still running after the edge, halts at the boundary. Halted: STOP accepted, then RUN retires all three instructions to a normal halt |
| `host_simulator_tests.ml` "control offer trace outcomes follow the pre-edge decision" | The simulator's trace labels for every shared offer kind come from the pre-edge `Decision`: refused RUN, the full load, RUN, STOP, and ABORT |

No stub core was used. The new tests exercise the actual core boundary.

Mutation checks. Each edit was temporary and reverted, then the file was compared with a
saved copy:

- `Integrated_core`: `run_rejected` changed to the unconditional `~run_accepted`. "with no
  offer every shared decision is low" failed.
- `Simulator_backend`: `accepted` inverted. 14 host-simulator failures.
- `Simulator_backend`: `request_outcome` swapped accepted and rejected. Before the new
  test this mutation passed every existing suite, because no test asserted control-offer
  trace labels. With the new test, it fails.

The new host-simulator test was also run against an untouched `git archive` of `89a3fe8`
with only that test file added. It passed, so the labels it asserts are baseline behavior.

## Verification

Every Dune command used `-j 5`, and commands ran strictly one after another.

The final source was frozen before the final runs. The SHA-256 of every changed non-doc
file was recorded, and the same list was re-checked after the last run with no difference.
Only documents changed after the freeze. An earlier pass of every check below also passed
on source that differed only in two comment rewraps (`control_port.ml`, `loader_core.ml`).
The results reported here are from the final pass.

**Pre-change baseline at `89a3fe8`**, captured before any source edit, used the same
generation script. Its checksum lists equal the HL1 and HL2 digests.

**Final checks** (the `HEAD` above plus the uncommitted HL3 diff):

| Check | Result |
| --- | --- |
| Focused: `./scripts/with-switch.sh dune build -j 5 @test/host/runtest @test/integration/host_simulator/runtest @test/integration/core_engine/runtest @test/host_link_wire/runtest` | PASS |
| `./scripts/with-switch.sh dune build @install @lint -j 5` | PASS |
| `./scripts/with-switch.sh dune build @runtest -j 5` | PASS, 28 s, no output: no expect-test diffs and no diffs against the committed `p3.4-*` CLI expectations or `uart_frame.trace` |
| `./scripts/with-switch.sh dune build @loader-rtl --force -j 5` | PASS, 7 min 47 s, all three peer tiers freshly executed (reusable core, behavioral wrapper, production synthesis wrapper). Each printed `PASS p3.5 serial loader repair: timing, overrun rejection, replay/commit, status, recovery, production paths; 3/3 sensitivity phases=10, excluded 1/1 failures=10` |
| `./scripts/with-switch.sh dune build @rtl -j 5` | PASS, run after the forced loader run and up to date. Every other bench's RTL input is byte-identical, so Dune reused its earlier passing results |
| 15 generator outputs, identical options, compared with the baseline | Identical, 15 of 15 |
| Bundle Verilog, pre vs post | Identical for the `src/` and `simulation/` roles of observable, memory, and loader. `info.yaml` and `constraints/` are also identical |
| External port inventories (name, direction, width, order) | Identical: `integrated_core` 109 ports, `loader_core` 17, both loader wrapper roles 8 |
| `python3 tinytapeout/scripts/check-adopted-bundle.py --kind observable/memory/loader --metadata-only`, run separately | PASS, PASS, PASS |
| `tinytapeout/test/p3_loader_tb.v` | Unchanged: no diff against `HEAD`; blob `2ffc20f0f302c5bad5fd9189056b22c8d8cc175d`, SHA-256 `40d9341f32ad02202f78784dbf4c6f9a7685691d8f7da78a50c2303cd2e2c9c9`. It shares nothing with `Wire` or `Control_port` |
| `./scripts/with-switch.sh dune build @fmt -j 5` | Only the known 13-file backlog (`f_model/fifo.ml`, `f_model/shift_engine.ml`, `isa/descriptor.ml`, `lib/pluggable_primitives/{byte_fifo,input_events,pin_bank,shift_lane,timing}.ml`, `lib/staging/{primitive_demo,uart_tx}.ml`, `test/common/backend_conformance.ml`, `test/common/dune`, `test/primitives/pin_bank/dune`). HL3 files were formatted with `dune promote <file>` one at a time; the backlog was not swept |
| `git diff --check`, plus a tab/trailing-whitespace scan of untracked files | PASS |
| `git diff --cached` | Empty; nothing staged |

### RTL comparison

Generation commands, run identically before (`pre/`) and after (`post/`), with `$dir` and
`$bundles` in the session scratchpad:

```sh
for mode in access executable integrated loader; do
  ./scripts/with-switch.sh dune exec -j 5 bin/generate_core.exe -- "$mode" "$dir/$mode.v"
done
./scripts/with-switch.sh dune exec -j 5 bin/generate.exe -- -output "$dir/p0.v" -module-name p0_observable
for block in pin_bank input_events timing byte_fifo_8 shift_lane observed_transfer \
  observed_transfer_bank primitive_demo uart_tx uart_slice; do
  ./scripts/with-switch.sh dune exec -j 5 bin/generate_p2.exe -- "$block" "$dir/$block.v"
done
./scripts/with-switch.sh dune build -j 5 bin/asic_bundle.exe
for kind in observable memory loader; do
  ./_build/default/bin/asic_bundle.exe "$kind" "$bundles/$kind" "$PWD"
done
```

There are no internal-name differences to classify. Every file is byte-identical, including
`loader.v`, whose `Of_signal.wires` request loop and nested decision/request literals
replaced explicit wires and flat records without changing a signal's creation order or
name. The raw directories were temporary. The checksum lists are the durable evidence. Both
list digests (`sha256sum` of `sha256sum *.v` output) are unchanged:
`29831c119d353a19205b015394a7be871c54eaced350fe03c0421cbc1aa87d21` for the 15 outputs and
`cbd0dc8df2d2547af8671cc868a94fd4336aae1fe63836ab35d5abe94d2e5cec` for the six bundle
files. The per-file lists are therefore exactly those in
[the HL2 record](host_link_hl2_record.md#rtl-baseline-and-byte-identity). The two
port-inventory files hash to `c48788286c6c084d8410028016f990203023ee2bd721c34ea474b0105e0a79a9`
(`integrated_core`) and `fc478f4df393287c4acb7f37d234a6f1a6ba5a9ee6d74d232ff0e1674c0b7661`
(`loader_core`) before and after.

### Bundle metadata and source identity

Only `identity`, `source_inputs`, and the `inputs/` entries of `files` changed. The emitted
Verilog, `info.yaml`, and constraints did not. `source_revision` is `89a3fe8` in both.

| Bundle | Identity at `89a3fe8` | Identity with the HL3 working tree | Source-input changes |
| --- | --- | --- | --- |
| observable | `f39592977c1f066032b474157838d5da01de97e2a53d70a7aad6147c847707dc` | `8fc12d74c1a2216ff2c10c7723174572fecb5dda7747ac6ef5d06cc28f22061a` | `bin/asic_bundle.ml` content and git status |
| memory | `92f1238ca1b408f67e63f78d974380cb3c59bfb3546950b4e17fd44fa6b689e9` | `3c1282de95ea4d813b22fab39b9804a400925a717ec53c6e94d33374cc1ebb0e` | the same input |
| loader | `3ac604ce51c49f157fbdb22f4dedf071bad6237553396a15f7ba83bcf722edd9` | `c9a45a838f28b7206536857d46ecdf52406737c576a443da15d11494524cd780` | the same, plus `integrated_core.ml`, `hardware_loader.ml`, and `loader_core.ml`; added `lib/emulator_core/control_port.ml` (git status `??`, 33 → 34 inputs) |

These are expected identity changes, not design changes. `bin/asic_bundle.ml` is an input to
all three bundles, and its loader inventory gained one path. `control_port.ml` belongs only
in the loader's closure: `Protocol_core` (memory) and `P0_observable` (observable) do not
reference `Control_port`. Every input records content hash and git status, so these
working-tree identities will change again when the owner commits. The observable and memory
checker expectations did not change. No Dune dependency change was needed: the
loader-wrapper rule in `tinytapeout/src/dune` already depends on `(source_tree ../../lib)`,
and the `generate_core` rules depend on the executable, whose library closure includes the
new module. An edit to `control_port.ml` therefore invalidates every relevant generation
rule.

## Documentation

- [host_link_migration.md](host_link_migration.md): status; HL3a, HL3b, and HL3c checked, with
  D1 recorded; context and consumer tables; W1, W2, and W4 notes.
- [p3.5-hardware-loader.md](p3.5-hardware-loader.md), [p3.4-host-api.md](p3.4-host-api.md),
  [p3.3-implementation.md](p3.3-implementation.md): current interface text names the port.
  Historical results are not rewritten.
- [verification.md](verification.md): suite counts and descriptions.
- [construction-plan.md](construction-plan.md) and [README.md](README.md): inventory and
  index entries.

## Non-claims and follow-ups

- D1 is resolved: the `control_status` projection was accepted on 2026-09-24.
- W4 is only partly addressed. The seven `*_rejected` decision fields remain in the port
  and unread by the loader, by decision. Removing them is a separate follow-up.
- Pre-existing and not changed: `test/integration/host_simulator/dune` generates
  `p3.4-workflow.stdout` but diffs only its stderr against empty, so the stateful workflow's
  stdout is not an expectation. HL3 did not add one; that would be a separate verification
  change.
- `observed_transfer.ml` in the loader manifest: unchanged and still deferred.
- This is RTL-identity, Cyclesim, and emitted-RTL peer evidence. It is not physical,
  timing, or mapped-area evidence. The full (non-metadata) bundle checker and generic
  synthesis were not rerun beyond `@rtl`; synthesis inputs are byte-identical.
