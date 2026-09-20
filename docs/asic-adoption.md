# P0.6/P0.7 ASIC bundle adoption

`bin/asic_bundle.ml` declares selectable `observable` and `memory` Tiny Tapeout
designs. The observable design preserves the existing
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
./scripts/with-switch.sh dune exec bin/asic_bundle.exe -- \
  memory /tmp/protemu-memory-bundle "$PWD"
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
python3 tinytapeout/scripts/check-adopted-bundle.py --kind memory
```

The check emits twice, compares manifest identity and bytes, checks source
copies and hashes, generated metadata/configuration/SDC, rejects conflicting
`CLOCK_PERIOD`, `VERILOG_FILES`, and `DIE_AREA` overrides, and runs the existing
the applicable observable or memory wrapper trace on both emitted RTL source
sets. It also runs Verilator
lint and generic Yosys synthesis inside the pinned LibreLane Docker image.
The full check needs an accessible Docker daemon and that image. The consumer
can populate the image cache independently with
`docker pull ghcr.io/librelane/librelane:3.1.0.dev3`; the check itself never
pulls. It does not require the `hardcaml_asic` source checkout or host installs
of the HDL binaries. `--metadata-only` runs the
bundle and declaration checks without Docker. Memory mode additionally checks
the exact RAM identity, 256x16 shape, explicit flop selection,
behavioral/implementation source roles, and absence of initialization in
implementation RTL. Its mapped-synthesis evidence is the
[P0.7 record](../tinytapeout/reports/2026-09-20-p0.7-memory-synthesis.md).

## Running the flow

The emitted bundle is consumed by [`./flow.sh`](../flow.sh), the canonical and
only entry point for the implementation flow. Its stages, environment overrides,
resuming rules, failure behavior, archiving, and verification status are in
**[flow.md](flow.md)**, which is the source of truth for all of it.

The first adopted physical run is archived at
[`flow_results/20260918-230920-05f65042`](../flow_results/20260918-230920-05f65042/README.md).
The qualifying clean-staging reproduction is
[`flow_results/20260920-081325-ccecd9ed`](../flow_results/20260920-081325-ccecd9ed/README.md):
committed source, isolated locked library prefix, complete preserved input
bundle, full hardening, TT precheck, and observable gate-level simulation all
pass. Its experiment record is
[`2026-09-20-p0.5c-clean-staging-physical.md`](../tinytapeout/reports/2026-09-20-p0.5c-clean-staging-physical.md).

Note that `adopted-flow.sh` does not invoke `check-adopted-bundle.py`. A physical
run is physical evidence only; the adoption invariants above are checked
separately.
