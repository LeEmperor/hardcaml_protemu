# Tiny Tapeout ASIC flow

This directory owns the project's ASIC wrapper, flow configuration, testbench,
and physical-design results. The phase-P0 RTL generation, wrapper simulation,
lint, generic synthesis smoke test, and staging paths are working; there is no
completed CMOS5L hardening run or generated GDS yet.
See the [construction plan](../docs/construction-plan.md) for the architecture.

## Target and upstream starting point

Use the competition-linked
[Tiny Tapeout CMOS5L template](https://github.com/TinyTapeout/ttihp-verilog-template/tree/cmos5l).
The [competition rules](https://blog.janestreet.com/protocol-emulator-asic-competition/)
request `tiles: "6x4"`. Jane Street may expand the maximum to `8x4` later, but
6x4 remains authoritative until that is announced.

The following were inspected and pinned on 2026-09-14. Exact revisions are in
[`toolchain.lock`](toolchain.lock):

| Item | Observed selection |
| --- | --- |
| Template branch | `TinyTapeout/ttihp-verilog-template`, `cmos5l`, `b86a2a781484bcab7ba522dc5de540086695a430` |
| GDS/precheck/gate-level actions | `TinyTapeout/tt-gds-action`, `ihp-cmos5l`, `3412659307918422f3f0727917cf9b499aaca588` |
| PDK identifier | `ihp-sg13cmos5l` |
| Support tools default ref | `TinyTapeout/tt-support-tools`, `ihp-sg13cmos5l`, `da63c9927411e3aca350977d653d24bbf5bca972` |
| LibreLane default in that action | `3.1.0.dev3` |

Sources: [CMOS5L workflow](https://github.com/TinyTapeout/ttihp-verilog-template/blob/cmos5l/.github/workflows/gds.yaml)
and [build action](https://github.com/TinyTapeout/tt-gds-action/blob/ihp-cmos5l/action.yml).
The action pins IHP-Open-PDK revision
`2bbec755dc67ca3db0261c3d6163e15735d66710` and uses GitHub's `ubuntu-24.04`
runner with Python 3.11. At the first successful build, record the resolved
container identity as well. This action includes a CMOS5L PDK installation step. Follow that path;
the general IHP guide's `ihp-sg13g2` setting is a different target.

## From Hardcaml to silicon layout

```text
OCaml source + parameters
  -> Dune builds the Hardcaml generator
  -> generator emits synthesizable Verilog RTL
  -> Yosys/ABC maps logic to cells from the selected PDK
  -> OpenROAD places cells, builds the clock tree, and routes wires
  -> timing analysis and physical verification check the result
  -> GDS layout + netlist + reports + Tiny Tapeout submission package
```

LibreLane coordinates these tools. The PDK (process design kit) supplies the
foundry-specific cell models, timing libraries, geometry, and physical rules.
Hardcaml's simulator verifies digital behavior; it does not establish that the
layout fits, meets timing, or passes fabrication checks.
[LibreLane introduction](https://librelane.readthedocs.io/en/stable/getting_started/newcomers/index.html)

| Tool/layer | Purpose | When needed |
| --- | --- | --- |
| OCaml, opam, Dune, Hardcaml | Build the circuit generator, model, and tests | Now; repository dependencies already declared |
| Verilator and/or Icarus Verilog | Lint/simulate emitted RTL and wrapper | First generated circuit |
| Python + cocotb | Drive the template's HDL tests and protocol peers | Wrapper integration |
| Yosys + ABC | Synthesis, technology mapping, area estimates | Early primitive and memory comparisons |
| LibreLane + Tiny Tapeout support tools | Reproducible RTL-to-GDS orchestration and submission packaging | First small hardening run |
| CMOS5L PDK and cell libraries | Physical/timing target for synthesis and layout | Mapped synthesis and hardening |
| OpenROAD / OpenSTA | Placement, clock tree, routing, setup/hold timing analysis | Supplied through the selected flow environment |
| KLayout, Magic, Netgen as selected by the flow | Layout viewing, design-rule checks, extraction and layout-versus-schematic checks | Use the flow's process-supported steps and versions |
| Compatible container runtime | Run the local hardening environment | Local full-flow work; hosted CI is another route |
| SymbiYosys plus a supported solver | Optional formal checks for critical primitives | Once contracts and small RTL blocks exist |

The exact verification tools enabled depend on the process/flow configuration;
inspect the CMOS5L run rather than requiring every tool manually.
[LibreLane step reference](https://librelane.readthedocs.io/en/stable/reference/step_config_vars.html)

### Host prerequisites

These must be installed by the user or an administrator. The bootstrap script
checks for them and refuses to continue without them; it never installs host
packages, never uses `sudo`, and never configures a container daemon.

```sh
sudo apt install git make gawk python3 python3-venv \
                 docker.io libcairo2 \
                 iverilog verilator yosys
sudo usermod -aG docker "$USER"   # then log out and back in
```

| Package | Why it is needed | Required |
| --- | --- | --- |
| `git` | every checkout and revision check | yes |
| `python3` >= 3.11 | support tools, LibreLane, flow scripts | yes |
| `python3-venv` | `ensurepip`; without it `python3 -m venv` fails partway | yes |
| `make`, `gawk`, `grep`, `coreutils` | scripts and `test/Makefile` | yes |
| `docker.io` or `podman` | LibreLane runs dockerized by default | yes, unless a native LibreLane is supplied |
| `libcairo2` | `cairocffi`/`cairosvg` in the support-tools requirements | yes |
| `iverilog` | RTL and gate-level wrapper simulation | yes |
| `verilator` | lint in `check-p0.sh` | yes |
| `yosys` | the generic synthesis smoke test only | no; the authoritative Yosys comes from LibreLane |

Do **not** install `openroad`, `magic`, `netgen`, or `opensta` from the host
package manager. The pinned flow supplies them, and a separately installed copy
would be an unpinned version that does not match what fabricates the design.

OCaml, Dune and Hardcaml come from the `5.2.0+ox` opam switch, not from apt.
Python packages come from the repository-root `.venv` created by
[`scripts/bootstrap-toolchain.sh`](scripts/bootstrap-toolchain.sh). Precheck
needs a second environment: `precheck/requirements.txt` pins `klayout` and
`gdstk` differently from the top-level requirements, and upstream supplies
`precheck/default.nix` for the native `klayout` and `magic` binaries it shells
out to.

A PATH inspection on this machine found `opam`, `dune`, `yosys`, `verilator`, and
`iverilog`. It did not find `openroad`, `klayout`, `magic`, `netgen`, `docker`, or
`nix`. This is only executable discovery, not version validation or an inventory
of all installed environments.

The pinned CMOS5L support-tools revision contains the competition's current
`6x4` tile-size entry and `tt_block_6x4_pgvdd.def`. The staging script validates
the checkout revision, clean state, tile dimensions, and DEF hash before linking
it. A possible future `8x4` allocation is not part of the current build.

Prefer the matched upstream tool environment over installing unrelated latest
versions individually. The [local hardening guide](https://tinytapeout.com/guides/local-hardening/)
explains the general workflow; adapt it to the CMOS5L action above. Gate-level
simulation, timing analysis, and DRC/LVS are distinct checks, all with useful roles.

## Directory ownership

The implemented P0 paths are:

```text
tinytapeout/
  README.md                 this flow plan
  .gitignore                generated outputs and local tool/PDK caches
  reports/                  experiment format and P0 record
  info.yaml                 project metadata and explicit source list
  src/                      generated RTL, thin wrapper, and flow configuration
  test/                     wrapper HDL test
  docs/info.md              Tiny Tapeout user documentation
  scripts/                  generation, tests, checks, and staging
  toolchain.lock            selected upstream flow/PDK revisions
  constraints/              future reviewed timing overrides, if needed
  build/                    ignored staged template project and intermediates
  runs/                     ignored physical-design runs
  artifacts/                ignored downloaded/exported build packages
```

Keep Hardcaml source in `lib/` and its emitter in `bin/`. Generated RTL is
reproducible output: never hand-edit it. Decide whether CI regenerates it or a
submission snapshot tracks it, and check generated-source consistency either way.
Large layouts and logs belong in build artifacts; commit small experiment records.

### Local support-tools checkout

Support tools remain a separate pinned repository rather than copied physical
files or a submodule of this repository. For local work, the default checkout is
`../tt-support-tools-cmos5l`. Override it when necessary:

```sh
TT_SUPPORT_TOOLS_DIR=/absolute/path/to/tt-support-tools-cmos5l \
  tinytapeout/scripts/stage-project.sh
```

The ignored staged project receives an ephemeral `tt` symlink to that checkout.
This matches the path expected by `tt_tool.py` while keeping the design repository
small. A hosted flow should check out the revision from `toolchain.lock` into the
staged project's `tt/` path rather than relying on a developer's local symlink.

GitHub discovers workflow YAML at the repository root's `.github/workflows/`.
The inspected upstream composite action also assumes root-relative `src/`,
`info.yaml`, `tt/`, and `runs/` paths. Merely placing its workflow under
`tinytapeout/.github/` or setting a shell default working directory is insufficient.

Proposed integration: maintain design inputs here, generate a self-contained
template-shaped staging project under `tinytapeout/build/`, and run the pinned
support tools there. A future root workflow calls our staging/run script and
uploads results explicitly. If submission requires a template-root repository,
export the same staged project to that shape. Validate GDS, precheck, and
gate-level test paths together before calling CI complete.

## Wrapper and constraint decisions

The [template interface](https://github.com/TinyTapeout/ttihp-verilog-template/blob/cmos5l/src/project.v)
has `ui_in[7:0]`, `uo_out[7:0]`, `uio_in[7:0]`, `uio_out[7:0]`,
`uio_oe[7:0]`, `clk`, `rst_n`, and `ena`. Output enables are active high.
Use a unique `tt_um_...` top name and assign every output.

Proposed allocation: the eight `uio` pins form the programmable protocol bank;
some dedicated `ui`/`uo` pins carry the host loader and status. Document each bit
in `info.yaml` after the loader format is decided. Connect output enables
explicitly so I2C can release lines and the device can recover safely from reset.

Use the official floorplan, pin placement, power connections, and constraint
defaults. Add a realistic system clock and I/O assumptions for the chosen board.
Review asynchronous input paths, synchronizer constraints, reset release, and
output delays. A broad false-path exception can hide an actual timing problem.
Keep clock values consistent across `info.yaml`, timing constraints, firmware,
and tests. Do not infer a maximum protocol frequency from core clock alone.

## First flow work items

- [ ] Select and record exact CMOS5L template/action/support-tool revisions.
- [ ] Make `bin/generate.ml` emit an observable pin/timer circuit.
- [ ] Add wrapper, actual source list, pinout metadata, and a reset/output test.
- [x] Confirm the chosen 6x4 floorplan exists and matches the pinned flow inputs.
- [ ] Stage and run emitted-RTL tests, then synthesis with the selected libraries.
- [ ] Run full placement/routing, timing analysis, physical checks, and precheck.
- [ ] Run the gate-level wrapper test using the flow-generated netlist/models.
- [ ] Save a first experiment record with the real area and timing results.
- [ ] Automate generation/staging/build with deterministic inputs and artifact paths.

Run `tinytapeout/scripts/check-p0.sh` for deterministic generation, Hardcaml
tests, wrapper RTL simulation, Verilator lint, generic Yosys synthesis, and
staging. Generic synthesis does not satisfy P0.4: the official CMOS5L flow still
needs to reach synthesis using the intended PDK libraries.
