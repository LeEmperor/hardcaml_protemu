# P0.6 ASIC bundle adoption

`bin/asic_bundle.ml` declares the current P0 observable circuit and its Tiny
Tapeout wrapper as one `hardcaml_asic.Project.Design`. It preserves the existing
`tinytapeout/src/project.v` pin map, two-edge reset release, and immediate pad
release on reset or disable. The Verilog wrapper and hand-maintained
`tinytapeout/info.yaml` and `src/config.json` remain the legacy P0 path; use an
emitted bundle for the adopted path.

## Dependency and emission

`tinytapeout/asic-dependencies.lock` records the full `hardcaml_asic` source
revision used for the package and the matching collateral revisions. Install
that revision into the selected opam switch as described in
[`hardcaml_asic`'s consumer guide](../../hardcaml_asic/docs/consumer-installation.md),
or build that source revision to an isolated prefix and set `OCAMLPATH` to its
`lib` directory. This repository's `tinytapeout/toolchain.lock` provisions the
flow tools; the bundle manifest records the library's requested revisions, and
adopted preflight refuses a mismatch. The package
currently comes from an unreleased Git revision, so update the lock deliberately
when upgrading it. The example commands below assume `hardcaml_asic` is already
installed or visible through `OCAMLPATH`.

```sh
./scripts/with-switch.sh dune build bin/asic_bundle.exe
./scripts/with-switch.sh dune exec bin/asic_bundle.exe -- \
  /tmp/protemu-adopted-bundle "$PWD"
```

The output directory must be new or empty. The emitter lists its own OCaml,
Dune, package, and dependency inputs explicitly and passes this repository as
`Bundle.render`'s source root. The manifest copies and hashes those files. It
also records the source Git revision, generated files, separate simulation and
synthesis RTL paths, target references, flow settings, and the dependency lock.
Use `src/<top>.v` for synthesis and `simulation/<top>.v` for simulation; never
compile both together. The generated `info.yaml`, `src/config.json`, and
`constraints/top.sdc` are the adopted flow inputs.

The typed project declaration fixes TT `6x4` / CMOS5L, a 48 MHz primary clock,
the current pin meanings, minimum/maximum I/O delays, and a default flop
resource policy. Raw LibreLane overrides carry their template revision as a
reason. Clock, RTL source list, and target-derived settings remain protected by
the library. `tinytapeout/toolchain.lock` is the consumer-owned tool provisioning
record for both paths. The hand-maintained `info.yaml` and `src/config.json`
are legacy inputs only; the adopted bundle gets its configuration from the
declaration.

The I/O delays are provisional P0 harness assumptions: 0 ns minimum models an
input change at the clock edge for hold analysis, 1 ns maximum models input
arrival, and 2 ns maximum models output loading at the receiving side. Review
them against the actual board and host timing before physical closure.

## Checks

```sh
./scripts/with-switch.sh dune build bin/asic_bundle.exe
python3 tinytapeout/scripts/check-adopted-bundle.py
```

The check emits twice, compares manifest identity and bytes, checks source
copies and hashes, generated metadata/configuration/SDC, rejects conflicting
`CLOCK_PERIOD`, `VERILOG_FILES`, and `DIE_AREA` overrides, and runs the existing
`tinytapeout/test/tb.v` wrapper trace on emitted RTL. It also runs Verilator
lint and generic Yosys synthesis inside the pinned LibreLane Docker image.
The full check needs an accessible Docker daemon and that image. The consumer
can populate the image cache independently with
`docker pull ghcr.io/librelane/librelane:3.1.0.dev3`; the check itself never
pulls. It does not require the `hardcaml_asic` source checkout or host installs
of the HDL binaries. `--metadata-only` runs the
bundle and declaration checks without Docker. Physical flow execution and
registered program memory remain separate P0.5b/P0.7 work.

## The flow

[`./flow.sh`](../flow.sh) is the canonical command for the ASIC implementation
flow, and the only one. Its orchestration lives in the consumer-owned
[`adopted-flow.sh`](../tinytapeout/scripts/adopted-flow.sh), which drives
[`adopted_phase4.py`](../tinytapeout/scripts/adopted_phase4.py): that runner
stages the emitted bundle, checks its hashes and requested revisions against the
actual collateral, runs LibreLane, and preserves run records. `adopted_report.py`
reads the collected result. They use no path into a `hardcaml_asic` source
checkout. The Python runner is adapted from the library's phase 4 runner at the
revision recorded in `asic-dependencies.lock`; this consumer copy uses protemu's
own `tb.v` for the gate-level wrapper test.

The stages, in the order a bare `./flow.sh` runs them:

```text
build → emit → preflight → run → postcheck → collect → report → archive
```

`build` compiles the tooling and runs the development tests through the pinned
switch. `emit` writes the immutable bundle. `preflight` checks the bundle and
the environment without running LibreLane. `run` is the physical step —
hardening — and creates a unique run directory and `run.json`; failed runs
retain their logs. `postcheck` uses the support-tools Nix precheck and the
pinned LibreLane image's Icarus for gate-level simulation. `collect` writes
`results.json`, `report` fails if the required physical or timing verdicts do
not pass, and `archive` promotes the run into `flow_results/`.

A bare `./flow.sh` allocates a fresh output directory, prints its absolute path,
and runs all of that, hardening included. Prepare a named experiment without
starting a physical run by naming the stages:

```sh
./bootstrap.sh
source env.sh
export PROTEMU_FLOW_OUT="$PWD/tinytapeout/build/my-experiment"
./flow.sh build emit preflight
./flow.sh run postcheck collect report
```

No stage runs an earlier one for you, so `./flow.sh run` hardens the bundle that
is already in `$PROTEMU_FLOW_OUT`. Emission refuses a bundle directory that has
any file in it: choose a new `PROTEMU_FLOW_OUT` rather than deleting one.

`./bootstrap.sh` provisions support tools, PDK, the LibreLane Python
environments, and the matching Docker image from this repository's lock. It does
not stage the legacy P0 project. If those exact tools are already available
elsewhere, set `PROTEMU_TT`, `PROTEMU_PDK_ROOT`, and `PROTEMU_FLOW_PY` instead;
`./flow.sh --help` lists every override.

Each `run` gets its own directory, and the stages after it in the same
invocation use the one that invocation produced. A separate invocation must name
it — the newest run under `PROTEMU_RUNS` is never assumed to be the intended
one:

```sh
PROTEMU_RUN=/absolute/path/to/run ./flow.sh postcheck collect report
PROTEMU_RUN=/absolute/path/to/run ./flow.sh report
```

`collect` and `report` read recorded artifacts with the system `python3` only,
so a finished or failed run can be inspected on a machine with no opam switch
and no PDK.

`PROTEMU_STAGE=synthesis` stops `run` after mapped synthesis. Use it with
`build emit preflight run collect report`: `postcheck` requires a completed full
run, and mapped synthesis is not physical closure.

## Where results are kept

A run directory is scratch: roughly 240 MB of tool output under the gitignored
`tinytapeout/build/`, most of it intermediate stage state that nothing reads
again. `archive` copies out the records and reports an acceptance decision is
actually read from — about 1 MB — into `flow_results/<date>-<run id>/`, which
is committed. It re-verifies every hash the run's own records pin, so the
archive stands in for the run directory: the bytes it carries are provably the
bytes that passed.

The directory name comes from the run's own start time and ID, not from
anything the invocation chose, so archiving one run twice lands in the same
place and names sort chronologically. What the run *meant* goes in a
`README.md` written beside the records; re-archiving replaces only the files
the tool writes and leaves that note alone. `PROTEMU_FLOW_RESULTS` moves the
tree; `PROTEMU_ARCHIVE` names one destination outright.

[`adopted_archive.py`](../tinytapeout/scripts/adopted_archive.py) is a consumer
copy of the library's `scripts/archive.py` at the revision in
`asic-dependencies.lock`, differing only in which phase4 module it loads. A run
that did not reach `completed` is refused rather than archived: the flow summary
still names its directory, and that directory is where a failed run is read.

Whatever happens, the last thing printed is a summary — each stage's elapsed
time, the end-to-end time, the stage that failed or was interrupted, and the
absolute path of every record and log that actually exists, including the
archive when one was made. The first adopted physical run is archived at
[`flow_results/20260918-230920-05f65042`](../flow_results/20260918-230920-05f65042/README.md);
it is the P0.5b record.

### Orchestration checks

[`check-flow.sh`](../tinytapeout/scripts/check-flow.sh) exercises the
orchestration itself — argument handling, output allocation, resuming, stage
failure, the summary, and signal handling — with a stub in place of dune, so it
runs in seconds and implements nothing:

```sh
tinytapeout/scripts/check-flow.sh
```

It is not part of `dune runtest`: no ordinary build or test starts a physical
run, and this check writes outside the source tree.
