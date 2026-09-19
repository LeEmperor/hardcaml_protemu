# The ASIC flow

This is the source of truth for the implementation flow: what `./flow.sh` is,
what each stage does, what it consumes and writes, how to resume or inspect a
run, and what has actually been verified about it. Other documents link here
rather than restating it.

Scope: everything from OCaml source to an archived physical result. The bundle
*contract* — what the emitter declares and how the manifest is checked — is
[asic-adoption.md](asic-adoption.md). The environment the flow consumes is
[environment.md](environment.md). The reasoning behind the OCaml/Python seam is
[tooling_theory1.md](tooling_theory1.md).

## The one path

[`./flow.sh`](../flow.sh) is the canonical command for the ASIC implementation
flow, and the only one. It consumes an environment and never provisions one;
`./bootstrap.sh` prepares that environment and implements nothing. Ordinary
`dune build` and `dune runtest` never start a physical run.

The flow's input is the emitted `hardcaml_asic` bundle — the typed declaration
in [`bin/asic_bundle.ml`](../bin/asic_bundle.ml) is the only configuration
authority on this path. The hand-maintained `tinytapeout/info.yaml` and
`src/config.json` belong to the [legacy path](#the-legacy-path), which is a
different input, not another spelling of the same one.

## Quick start

```sh
./bootstrap.sh          # once per machine or checkout; prepares, never implements
source env.sh           # every new shell; only affects commands you type
./flow.sh --help        # steps, overrides, and how to resume
./flow.sh               # the whole flow, hardening included — hours
```

A bare `./flow.sh` deliberately starts a physical run. It allocates a fresh
output directory, prints its absolute path, and runs every stage. Name the
stages when you want only part of it.

## Stages

The order a bare `./flow.sh` runs them:

```text
build → emit → preflight → run → postcheck → collect → report → archive
```

| Stage | What it does | Needs | Writes |
| --- | --- | --- | --- |
| `build` | `dune build` and `dune runtest` through the pinned switch | OCaml layer | `_build/` |
| `emit` | Writes the immutable bundle from the declaration | OCaml layer | `$PROTEMU_BUNDLE` |
| `preflight` | Validates bundle, collateral, versions, image, and configuration; starts no tool | bundle, flow tools | `preflight.json` |
| `run` | Hardening: starts LibreLane on the bundle | bundle, PDK, image | a new run under `$PROTEMU_RUNS`, `run.json` |
| `postcheck` | TT precheck (Nix) and gate-level wrapper simulation (the image's Icarus) | a completed full run | `postcheck.json` |
| `collect` | Reads the run's records into one structured result | a run directory | `results.json` |
| `report` | Prints the physical/timing summary; fails if a required verdict does not pass | `results.json` | — |
| `archive` | Promotes the run's records and reports into `flow_results/` | a `completed` run | `flow_results/<date>-<run id>/` |
| `bootstrap` | Provisions flow tools. Transitional; prefer `./bootstrap.sh` | — | flow layer |

`--full` is the explicit spelling of the default sequence, including fresh
output allocation. It is what a bare `./flow.sh` runs.

### Naming steps

Steps run in the order given, and **no step ever runs an earlier one for you**.
`./flow.sh run` hardens whatever bundle is already in `$PROTEMU_FLOW_OUT`; it
does not emit one. A stage may validate the prerequisites it needs, but it will
not produce them.

```sh
export PROTEMU_FLOW_OUT="$PWD/tinytapeout/build/my-experiment"
./flow.sh build emit preflight        # prepare and check a bundle; no LibreLane
./flow.sh run postcheck collect report
```

## Output and artifacts

`PROTEMU_FLOW_OUT` is one experiment: one bundle and the runs made from it.

- A full default invocation allocates a fresh directory under
  `tinytapeout/build/` with a collision-resistant name and prints its absolute
  path before starting work. Setting `PROTEMU_FLOW_OUT` names the experiment
  instead.
- Named steps default to `tinytapeout/build/adopted`, so
  `./flow.sh postcheck collect report` still finds an existing experiment.
- Emission refuses a bundle directory that has any file in it. Choose a new
  `PROTEMU_FLOW_OUT` rather than deleting one; nothing here deletes a bundle to
  make emission pass.
- The bundle is emitted once and consumed immutably for the attempt, with its
  manifest, input provenance, configuration, constraints, and source sets
  preserved.
- Every `run` gets its own directory. Failed runs are preserved with their logs,
  exactly like successful ones.

### Environment

`./flow.sh --help` is authoritative; this is the same list.

| Variable | Meaning | Default |
| --- | --- | --- |
| `PROTEMU_FLOW_OUT` | output directory for this experiment | fresh for `--full`, else `tinytapeout/build/adopted` |
| `PROTEMU_BUNDLE` | the emitted bundle | `$PROTEMU_FLOW_OUT/bundle` |
| `PROTEMU_RUNS` | run storage, one directory per attempt | `$PROTEMU_FLOW_OUT/runs` |
| `PROTEMU_RUN` | an existing run, for steps after `run` | — |
| `PROTEMU_FLOW_RESULTS` | kept archives, one per run | `./flow_results` |
| `PROTEMU_ARCHIVE` | exact archive directory for this run | derived from the run |
| `PROTEMU_STAGE` | `full` or `synthesis`: how far `run` goes | `full` |
| `PROTEMU_TT` | tt-support-tools checkout | from bootstrap |
| `PROTEMU_PDK_ROOT` | PDK root (IHP `sg13cmos5l`) | from bootstrap |
| `PROTEMU_FLOW_PY` | python of the LibreLane venv | from bootstrap |
| `PROTEMU_PRECHECK_PY` | python of the TT precheck venv | from bootstrap |
| `PROTEMU_ALLOW_PYTHON_MISMATCH` | `0` requires the bundle's exact minor | `1` |

If the pinned tools already exist elsewhere, `PROTEMU_TT`, `PROTEMU_PDK_ROOT`
and `PROTEMU_FLOW_PY` point at them instead of provisioning them again.

## Resuming and inspecting a run

Stages after `run` in the *same* invocation use the run that invocation
produced. A separate invocation must name the run: the newest directory under
`PROTEMU_RUNS` is never assumed to be the intended one.

```sh
PROTEMU_RUN=/absolute/path/to/run ./flow.sh postcheck collect report
PROTEMU_RUN=/absolute/path/to/run ./flow.sh report
```

`collect` and `report` read recorded artifacts with the system `python3` only.
A finished or failed run can be inspected on a machine with no opam switch and
no PDK, and neither stage rebuilds the design or triggers provisioning.

## Synthesis only

`PROTEMU_STAGE=synthesis` stops `run` after mapped synthesis. Use it with:

```sh
PROTEMU_STAGE=synthesis ./flow.sh build emit preflight run collect report
```

`postcheck` requires a completed full run, and mapped synthesis is not physical
closure. Do not present it as one.

## Failure, interruption, and the summary

A stage failure stops the stages after it and returns a nonzero status. Whatever
happens, the last thing printed is a summary: each stage's elapsed time, the
end-to-end time, the stage that failed or was interrupted, and the absolute path
of every record and log that actually exists, including the archive when one was
made. Missing evidence is distinguished from a passing check.

Ordinary termination signals are handled without hiding the failure status —
SIGTERM gives exit 143, a `did not finish` row, and the summary. A SIGTERM sent
to the flow alone, rather than to the process group as Ctrl-C does, is acted on
only after the running stage's command returns, because bash defers a trap until
the foreground command completes. The status and summary are correct; the wait is
not shortened.

## Where results are kept

A run directory is scratch: roughly 240 MB of tool output under the gitignored
`tinytapeout/build/`, most of it intermediate stage state that nothing reads
again. `archive` copies out the records and reports an acceptance decision is
actually read from — about 1 MB — into `flow_results/<date>-<run id>/`, which is
committed. It re-verifies every hash the run's own records pin, so the archive
stands in for the run directory: the bytes it carries are provably the bytes that
passed.

The directory name comes from the run's own start time and ID, not from anything
the invocation chose, so archiving one run twice lands in the same place and
names sort chronologically. What the run *meant* goes in a `README.md` written
beside the records; re-archiving replaces only the files the tool writes and
leaves that note alone. `PROTEMU_FLOW_RESULTS` moves the tree; `PROTEMU_ARCHIVE`
names one destination outright.

A run that did not reach `completed` is refused rather than archived. The flow
summary still names its directory, and that directory is where a failed run is
read.

The first adopted physical run is archived at
[`flow_results/20260918-230920-05f65042`](../flow_results/20260918-230920-05f65042/README.md);
its experiment record is
[`2026-09-19-p0.5b-adopted-physical.md`](../tinytapeout/reports/2026-09-19-p0.5b-adopted-physical.md).

## Checking the flow itself

```sh
tinytapeout/scripts/check-flow.sh              # orchestration, seconds, no tools
python3 tinytapeout/scripts/check-adopted-bundle.py   # bundle and declaration
./flow.sh build emit preflight                 # the real bundle, no hardening
```

[`check-flow.sh`](../tinytapeout/scripts/check-flow.sh) exercises the
orchestration itself — argument handling, output allocation, resuming, stage
failure, the summary, and signal handling — with a stub in place of dune, so it
runs in seconds and implements nothing. It is not part of `dune runtest`: no
ordinary build or test starts a physical run, and this check writes outside the
source tree.

`check-adopted-bundle.py` checks the bundle contract, not the orchestration; see
[asic-adoption.md](asic-adoption.md#checks). Note that `adopted-flow.sh` does not
invoke it, so a physical run is physical evidence only.

## Implementation map

There is exactly one orchestration implementation. `flow.sh` is its public name.

| File | Role |
| --- | --- |
| [`flow.sh`](../flow.sh) | The public entry point. Resolves the repository from its own location, supplies the full-run default, and execs the runner, so the exit status is the runner's. |
| [`adopted-flow.sh`](../tinytapeout/scripts/adopted-flow.sh) | The orchestration: stage sequencing, output allocation, timing, the summary, signal handling. Runs dune through `scripts/with-switch.sh`, so no activated shell is required. |
| [`adopted_phase4.py`](../tinytapeout/scripts/adopted_phase4.py) | Bundle preflight, LibreLane execution, postchecks, and collection. |
| [`adopted_report.py`](../tinytapeout/scripts/adopted_report.py) | Reads the collected result and applies the required verdicts. |
| [`adopted_archive.py`](../tinytapeout/scripts/adopted_archive.py) | Promotes a completed run into `flow_results/`. |
| [`bin/asic_bundle.ml`](../bin/asic_bundle.ml) | The declaration the bundle is emitted from. |
| [`check-flow.sh`](../tinytapeout/scripts/check-flow.sh) | Orchestration checks with a stub in place of dune. |

None of these use a path into a `hardcaml_asic` source checkout. The Python
runner and archiver are consumer copies of the library's phase-4 runner and
`scripts/archive.py` at the revision recorded in `asic-dependencies.lock`; the
runner differs in using protemu's own `tb.v` for the gate-level wrapper test, the
archiver in which phase-4 module it loads.

## Aliases and compatibility

| Command | What it is |
| --- | --- |
| `dune exec protemu -- flow` | Alias for `./flow.sh`; same runner, same exit status. |
| `dune exec protemu -- harden` | `./flow.sh run`. |
| `tinytapeout/scripts/adopted-flow.sh` | The runner. Still prints help when called with no arguments. |

Only `./flow.sh` turns a bare invocation into a full physical run. The runner is
not given that meaning, because anything already calling it bare would start
hardening; `--full` is the explicit spelling, and the two differ in nothing else.

`protemu harden` rejects the legacy `-tag` and `-no-docker` flags with a
diagnostic naming `legacy-harden`, rather than translating them. The adopted
runner is dockerized with the pinned image and archives nothing — every attempt
already gets its own run directory — so neither flag has an honest equivalent.

`bootstrap-toolchain.sh` still accepts `--adopted-only` as a no-op, so commands
recorded in earlier documents keep working. `--adopted-only` with `--no-container`
was once a hard error; it is now a warning that skips resolving the pinned image,
so `--no-container` remains usable with the default provisioning mode for someone
supplying a native LibreLane.

### The legacy path

`protemu check`, `stage`, `legacy-harden` and `precheck` drive the legacy staged
project, which reads the committed RTL and the hand-maintained
`tinytapeout/info.yaml` and `src/config.json`. That is a different input from the
emitted bundle. It needs `./bootstrap.sh --legacy-project`, which is now the only
thing that stages it; normal bootstrap does not. The legacy scripts, the staged
project, and `dune build @rtl` are otherwise untouched by the adopted path.

## Verified behavior and known limits

Verified, as of 2026-09-19:

- **End to end.** A bare `./flow.sh` produced the P0.5b run on 2026-09-18 —
  every stage through `archive`, with LibreLane signoff, TT precheck and
  gate-level simulation passing in one attempt. Evidence is the archive linked
  above.
- **Orchestration.** `check-flow.sh`: 14 checks, 0 failures. Help without OCaml
  or flow tools (`env -i`); unknown-step and `--full`-with-steps rejection;
  resolution from another working directory; `report`/`collect` refusing to guess
  a run, including with a decoy run directory present; reaching the reporter for
  an existing run under `env -i`; emission refusing a nonempty bundle and leaving
  it intact; fresh output allocation twice without collision; a failed stage
  stopping the ones after it; SIGTERM giving exit 143 and the summary.
- **Preparation does not implement.** `./flow.sh build emit preflight` reports
  `"ready": true` without creating a run directory or starting LibreLane.
  `./bootstrap.sh --check` validates every layer, stages nothing, and compiles no
  executable.
- **Aliases.** `protemu flow report` reaches the runner and returns its exit
  status; `protemu harden -tag NAME` and `-no-docker` produce the migration
  diagnostic and exit 2.

Not established:

- Reporting on a **failed or interrupted real run** — only the missing-run and
  stub paths have been exercised.
- `PROTEMU_STAGE=synthesis` is passed through and documented, but has not been
  run since the migration.
- Emission is **not reproducible from `source_revision` alone**: the P0.5b bundle
  was emitted from a tree with modified and untracked inputs. The manifest pins
  content by hash and records each input's `git_status`, so the bundle is pinned;
  the recorded revision is not by itself a description of the declaration. See the
  archive's own limits section.

## History

[flow_migration.md](flow_migration.md) records the migration that produced this
interface: the plan as written, and what was checked at the time. It is history.
Where it disagrees with this document, this document is current.
