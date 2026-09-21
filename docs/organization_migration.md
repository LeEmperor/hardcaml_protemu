# `lib/` organization migration (option A)

Status: implemented and verified in the working tree on 2026-09-21, uncommitted, pending
the owner's commit and post-commit history check; see
[Implementation record](#implementation-record-2026-09-21). The baseline commit
prerequisite (HL0) is resolved at `9f6ed2d`, confirmed by the repository owner. This document is the
procedure for [HL1](host_link_migration.md#hl1--move). No module is renamed, no
identifier changes, and the emitted RTL must stay byte-identical.

## Agent execution rules

Every `dune build` and `dune runtest` invocation must include `-j 5`, including focused
checks and forced reruns through scripts. Heavy workloads have caused server crashes;
run these commands sequentially rather than launching overlapping builds/tests. Also
use `-j 5` on `dune exec` generation commands, which can trigger builds.

Agents must not create or amend commits: only the repository owner commits. Prepare
HL1 and its evidence, then return the changes uncommitted. Commit references below
describe the owner's eventual review unit. Do not stage changes unless requested,
apart from index updates inherent in the documented `git mv`/`git rm` operations.

## Why

`lib/` holds twenty `.ml` files in one flat directory, one layer per construction
phase. Nothing in the listing says which subsystem a file belongs to. `lib/dune`
already declares `(include_subdirs ...)`, so subdirectories are supported and just
unused.

Option A switches that stanza from `qualified` to `unqualified`. Files move into
subsystem directories, but module names stay flat (`Hardcaml_protemu.Pin_bank`),
so no OCaml reference anywhere has to change. Qualified namespaces
(`Pluggable_primitives.Pin_bank`) are a separate, later decision; see
[Later steps](#later-steps).

## Target layout

```
lib/
  dune                    (include_subdirs unqualified)
  pluggable_primitives/   pin_bank shift_lane timing input_events byte_fifo
  memory_control/         protocol_core
  emulator_core/          instruction_decoder control_execution core_mechanisms integrated_core
  host_link/              hardware_loader loader_core
  staging/                uart_tx uart_slice observed_transfer observed_transfer_bank primitive_demo
  legacy/                 p0_observable executable_core
```

`protemu_types.ml` is deleted. It is a 14-line instruction-type enum from before the
ISA library existed, and nothing references it.

### What each directory holds

| Directory | Contents | Depends on |
| --- | --- | --- |
| `pluggable_primitives/` | The leaf mechanisms instructions drive: pin bank, shift lanes, timers, input edge/snapshot front end, byte FIFOs | nothing in `lib/` |
| `memory_control/` | The program-memory controller: load sessions, readback/verify, image validity, fetch arbitration, the 1RW RAM port | nothing in `lib/` |
| `emulator_core/` | The instruction decoder, the execution unit, the dispatcher from the execution unit to the primitives, and the composition of all of it | `pluggable_primitives`, `memory_control` |
| `host_link/` | The serial host link (framing, CRC, command dispatch, response retention) and its glue onto the emulator core | `emulator_core`, `memory_control` |
| `staging/` | P2 blocks that are built and tested but not wired into any chip top | `pluggable_primitives` |
| `legacy/` | Superseded compositions and the P0 bring-up circuit | `memory_control`, `emulator_core` |

Every dependency between directories points in one direction. `core_mechanisms`
belongs in `emulator_core/`, not `pluggable_primitives/`, because it consumes
`Control_execution`'s command port. Putting it with the primitives would make the two
directories depend on each other.

With unqualified modules, these are architectural dependency rules, not Dune-enforced
library boundaries. Review cross-directory references against this table at acceptance
and when adding modules. Stronger namespace/library enforcement is a later decision.

### What the confusing names mean

Option A keeps these names. They are listed here so the layout reads correctly, and
the renames are proposed under [Later steps](#later-steps).

| Module | What it actually is | Where the name came from |
| --- | --- | --- |
| `Protocol_core` | Program-memory controller. It does not decode or execute anything and has nothing to do with the emulated protocols. | "Protocol" is the project (protocol emulator). This was the first core block, P3.1a. |
| `Control_execution` | The execution unit: PC, architectural state, faults, run/stop/abort/step, and the single retained command port toward the primitives. | P3.2 "control-execution client" of the program store. |
| `Core_mechanisms` | The dispatcher that turns execution-unit commands into operations on the primitives, and owns the shared input front end. | P3.3 adapter from "core" commands to the P2 "mechanisms". |
| `Integrated_core` | The complete emulator core: memory control + execution unit + dispatcher + primitives. RAM stays outside it. | P3.3 "integrated" the pieces P3.1a–P3.2 had built separately. |
| `Loader_core` | The emulator core plus the host link. It is the whole chip except the Tiny Tapeout wrapper and the RAM. | P3.5 composition. |
| `Executable_core` | P3.2's memory control + execution unit, without primitives. `Integrated_core` replaced it. | P3.2 composition. |

## Preconditions

1. **Nothing else is editing `lib/`, `bin/asic_bundle.ml`, or the checker.** A move
   of twenty files conflicts with any concurrent feature work in those files. Land or
   pause that work first.
2. **The implementation baseline is committed — resolved (HL0).** The loader sources
   and in-flight repair work are committed at `9f6ed2d`; the owner confirmed this
   prerequisite is satisfied. Before starting HL1, record the current revision and any
   local diff. Planning-document updates do not reopen HL0; distinguish them from the
   mechanical move so the implementation baseline and move remain reviewable.
3. **A baseline of the emitted RTL** exists for the byte-identity check in
   [Verification](#verification).

## Steps

### 1. Capture the RTL baseline

```sh
base=$(mktemp -d)
for mode in access executable integrated loader; do
  ./scripts/with-switch.sh dune exec -j 5 bin/generate_core.exe -- "$mode" "$base/$mode.v"
done
./scripts/with-switch.sh dune exec -j 5 bin/generate.exe -- -output "$base/p0.v" -module-name p0_observable
for block in pin_bank input_events timing byte_fifo_8 shift_lane observed_transfer \
  observed_transfer_bank primitive_demo uart_tx uart_slice; do
  ./scripts/with-switch.sh dune exec -j 5 bin/generate_p2.exe -- "$block" "$base/$block.v"
done
```

Record the baseline directory, revision/local diff, and tool/dependency identity. Generate
the same outputs into a second directory after the move, using identical options. Compare
all three bundles' emitted Verilog source roles as well; changed manifest source paths
and identity hashes are expected, changed RTL bytes are not.

### 2. Move the files

```sh
cd lib
mkdir pluggable_primitives memory_control emulator_core host_link staging legacy
git mv pin_bank.ml shift_lane.ml timing.ml input_events.ml byte_fifo.ml pluggable_primitives/
git mv protocol_core.ml memory_control/
git mv instruction_decoder.ml control_execution.ml core_mechanisms.ml integrated_core.ml emulator_core/
git mv hardware_loader.ml loader_core.ml host_link/
git mv uart_tx.ml uart_slice.ml observed_transfer.ml observed_transfer_bank.ml primitive_demo.ml staging/
git mv p0_observable.ml executable_core.ml legacy/
git rm protemu_types.ml
cd ..
```

### 3. Update `lib/dune`

Change `(include_subdirs qualified)` to `(include_subdirs unqualified)`. Rewrite the
comment above it: it currently promises `<Subdir>.<Module>` access, which will no
longer be true. Say instead that subdirectories are for browsing only and module
names stay flat.

### 4. Fix hard-coded source paths

These are the only non-documentation files that name `lib/*.ml` paths. Both are
manifest source lists for the Tiny Tapeout bundle.

| File | Lines | Change |
| --- | --- | --- |
| `bin/asic_bundle.ml` | `input_paths`, about 15 entries | Rewrite each `lib/<file>.ml` to its new directory |
| `tinytapeout/scripts/check-adopted-bundle.py` | 61–63, 78 | Same rewrite for `expected_source` and the loader source-set assertion |

`tinytapeout/src/dune` depends on `(source_tree ../../lib)`, which already covers
subdirectories, so it needs no change.

One existing oddity: the loader's `input_paths` lists `lib/observed_transfer.ml`,
but nothing on the loader's path references `Observed_transfer`. Keep the entry
during the move (as `lib/staging/observed_transfer.ml`) so the move changes nothing
else, and resolve it in a separate commit.

### 5. Fix documentation links

About 97 `lib/<file>.ml` references across twelve files in `docs/`, most in
`phase_plan.md`, `p2-implementation.md`, and `p3.1a-implementation.md`. A sed pass
per moved file rewrites both `lib/x.ml` and `../lib/x.ml` link forms. For example:

```sh
for pair in \
  pin_bank:pluggable_primitives shift_lane:pluggable_primitives \
  timing:pluggable_primitives input_events:pluggable_primitives \
  byte_fifo:pluggable_primitives protocol_core:memory_control \
  instruction_decoder:emulator_core control_execution:emulator_core \
  core_mechanisms:emulator_core integrated_core:emulator_core \
  hardware_loader:host_link loader_core:host_link \
  uart_tx:staging uart_slice:staging observed_transfer:staging \
  observed_transfer_bank:staging primitive_demo:staging \
  p0_observable:legacy executable_core:legacy
do
  f=${pair%%:*} d=${pair##*:}
  sed -i "s#lib/$f\.ml#lib/$d/$f.ml#g" docs/*.md
done
```

`observed_transfer` is a prefix of `observed_transfer_bank`, but the pattern ends
at `\.ml`, so the two do not collide.

Leave dated evidence in `tinytapeout/reports/` and `flow_results/` alone. They record
the paths as they were at the time.

## Verification

| Check | Expected |
| --- | --- |
| `./scripts/with-switch.sh dune build @install @lint -j 5` | PASS |
| `./scripts/with-switch.sh dune build @runtest -j 5` | PASS, no expect-test diffs |
| `./scripts/with-switch.sh dune build @rtl -j 5` | PASS, including all three P3.5 loader peer tiers (reusable core, behavioral wrapper, production synthesis wrapper) |
| Regenerate step 1's outputs and `diff -r` against the baseline | No differences. Any difference means something other than a move happened. |
| Run `python3 tinytapeout/scripts/check-adopted-bundle.py --kind KIND --metadata-only` separately with `KIND` set to `observable`, `memory`, and `loader` | PASS for all three |
| `git diff HEAD -M --summary` before commit; `git log --follow lib/emulator_core/integrated_core.ml` after the owner commits | Agent verifies rename detection; owner verifies history after committing |
| Compare pre/post bundle Verilog for observable, memory, and loader | Byte-identical for every emitted Verilog source role |
| Review cross-directory OCaml references | Follow the dependency table; unqualified Dune modules do not enforce it |

Expected, not a regression: the bundle manifest's `source_inputs` paths change, so
every bundle's identity hash changes. The emitted Verilog under `src/` must not
change. Note this in the commit message so the new hashes are not read as a design
change.

## Commit

Only the repository owner makes this commit; agents leave the work uncommitted.
One commit containing only steps 2–5. No logic, formatting, or naming changes ride
along, so reviewers can check it with `git diff -M --stat` and rebases onto it stay
mechanical.

## Estimate

About 30 minutes of work plus one full `@runtest @rtl` pass. The risk is low: dune
resolves modules by name, so the only ways to break the build are a missed path
string in step 4 or a file left behind in step 2, and both fail loudly.

## Implementation record (2026-09-21)

Implemented by an agent and left uncommitted for the owner's review unit.

**Tested revision.** `HEAD` = `9f6ed2d`. The local diff before the move held only planning
documents (`docs/README.md`, `organization_migration.md`, `p3.5-hardware-loader.md`,
`phase_plan.md`, `verification.md`, and untracked `host_link_migration.md`); no source,
Dune, script, or test file was modified, so the step 1 baseline is `9f6ed2d`'s sources.

**Tool identity.** opam switch `5.2.0+ox` (OCaml 5.2.0+ox), Dune 3.24.2; `hardcaml`,
`ppx_hardcaml`, `core`, `ppx_jane`, `ppx_js_style` `v0.18~preview.130.106+341`;
`hardcaml_asic` 0.1.0 (rsync pin of `~/devel/jane/hardcaml_asic`, checkout at
`037e670`); Verilator 5.020, Icarus Verilog 12.0, Yosys 0.33, Python 3.12.3. The same
installed switch served the pre- and post-move runs.

**What changed.** Steps 2–5 as written: 19 `git mv` renames and `git rm
lib/protemu_types.ml` (no reference in any `.ml`, `.mli`, or `dune` file); the
`lib/dune` stanza and comment; the paths in `bin/asic_bundle.ml` `input_paths`
(entry order unchanged, loader's `lib/staging/observed_transfer.ml` kept) and the
checker's `expected_source` and loader source-set assertion. A tree-wide search found
no other non-documentation consumer of `lib/*.ml` paths. Documentation: all 63 Markdown
links into `lib/`, the two link texts in `verification.md`, and the current-state
inventory in `construction-plan.md` §2 were rewritten; that inventory's
`protemu_types.ml` bullet was removed with the file. Historical command-result records
keep the paths as they were: the `@fmt` backlog lists in the P3.1a, P3.1b, P3.4, and
P3.5 records, the worktree note in `verification_migration.md`, and dated evidence
under `tinytapeout/reports/` and `flow_results/`.

**Baseline artifacts.** Step 1 outputs (4 core modes, P0, 10 P2 blocks) and the
observable/memory/loader bundles emitted by `_build/default/bin/asic_bundle.exe KIND
DIR ROOT` were captured before the move in the agent's session scratch directory
(`…/scratchpad/hl1/{pre,bundles-pre}`), which is temporary. The durable record is the
checksum lists: the 15 step 1 files hash to list digest `29831c119d353a19…` and the
six bundle Verilog files to `cbd0dc8df2d2547a…`; both lists are identical after the
move.

| Check (run sequentially, post-move) | Result |
| --- | --- |
| `./scripts/with-switch.sh dune build @install @lint -j 5` | PASS |
| `./scripts/with-switch.sh dune build @runtest -j 5` | PASS, no output, no expect-test diffs |
| `./scripts/with-switch.sh dune build @rtl -j 5` | PASS; then `--force -j 5` re-executed every alias action (462 s): PASS for the P0, P2 UART/slice, P3.1b, P3.2, P3.3 benches and all three P3.5 loader tiers (reusable core, behavioral wrapper, production synthesis wrapper) |
| Step 1 outputs regenerated with identical options, `diff -r` against baseline | Identical, 15 of 15 files |
| Bundle Verilog, pre vs post | Identical for `src/` (synthesis) and `simulation/` (behavioral) roles of observable, memory, and loader; `info.yaml`, `config.json`, and SDC also identical |
| Bundle manifests | Only `identity`, `source_inputs`, and the `inputs/` entries of `files` change. Every moved source keeps its content hash; only `bin/asic_bundle.ml` and `lib/dune` content changed. Identities: observable `64fabdc9…` → `ae82eb2c…`, memory `6de12a45…` → `23541abb…`, loader `6d6a8ca1…` → `b29eba38…` |
| `check-adopted-bundle.py --kind KIND --metadata-only` for `observable`, `memory`, `loader` (separately) | PASS, PASS, PASS |
| Cross-directory references | Match the dependency table; no violations |
| Old-path search, `lib/` link resolution | 63 of 63 `lib/` links resolve; remaining old paths are only the historical records listed above |
| `git diff --check` | PASS |
| `git diff HEAD -M --summary` | 19 renames at 100% similarity, one delete |
| `git log --follow lib/emulator_core/integrated_core.ml` | Pending: owner checks after committing |

## Later steps

These are deliberately out of scope. Each is its own commit.

1. **Rename the unclear modules.** Renaming a module changes every reference to it,
   so this is a larger change than the move. Suggested names:

   | Current | Suggested |
   | --- | --- |
   | `Protocol_core` | `Program_memory_controller` |
   | `Control_execution` | `Execution_unit` |
   | `Core_mechanisms` | `Primitive_dispatch` |
   | `Integrated_core` | `Emulator_core` |
   | `Loader_core` | `Emulator_with_host_link` |

2. **`chip_top/` for the Tiny Tapeout tops.** `Observable_design`, `Memory_design`,
   and `Loader_design` live inside `bin/asic_bundle.ml` today. Move them to a
   `chip_top/` library at the repository root, beside `lib/`, and leave
   `asic_bundle.ml` as the command-line entry point. It has to sit outside `lib/`:
   the tops need `hardcaml_asic`, which the synthesizable library does not depend
   on, and `include_subdirs` does not allow a separate library stanza under `lib/`.
3. **Mirror the layout in `test/`.** `test/core/` and `test/primitives/` already
   group some tests; align them with the new directory names.
4. **Qualified namespaces.** Switching back to `(include_subdirs qualified)` makes
   references read `Emulator_core.Execution_unit` and similar. It touches every
   cross-module reference in `lib/`, `bin/`, `test/`, `host/`, and `f_model/`. Watch
   for `Timing`, which already collides with `Hardcaml_asic.Timing` in
   `asic_bundle.ml`.
