# Environment and entry points

Two commands, and they are the whole interface. One prepares the environment and
is always safe to rerun; the other implements the design:

```sh
./bootstrap.sh          # install whatever is missing in every layer, then verify it
./bootstrap.sh --check  # report the state of every layer and change nothing
source env.sh           # every new shell
./flow.sh               # the ASIC flow: emit, harden, postcheck, collect, report
```

`./bootstrap.sh` prepares tools and stages no design. `./flow.sh` consumes what
it left and never provisions. Nothing else is implied by either: a bare
`./flow.sh` deliberately starts a physical run and takes hours, so read
`./flow.sh --help` first and name the steps when you want only some of them.

This document owns the environment — the layers, what provisions each one, and
what to run when something is missing. The flow itself, its stages, overrides,
artifacts and verification status, is **[flow.md](flow.md)**.

Dune builds and checks the tooling; it never implements:

```sh
dune runtest                     # Hardcaml tests + committed RTL is fresh
dune build @rtl                  # wrapper sim, Verilator lint, generic Yosys
dune exec protemu -- doctor      # read-only report on every layer and this shell
dune exec protemu -- bootstrap   # the flow layer alone, once OCaml exists
dune exec protemu -- flow        # alias for ./flow.sh, same runner and exit status
```

The remaining `protemu` commands (`check`, `stage`, `legacy-harden`, `precheck`)
drive the legacy staged project, which is a different input from the emitted
bundle. They need `./bootstrap.sh --legacy-project`, which is the only way that
project is staged now. See [flow.md](flow.md#the-legacy-path) for that path and
for the aliases `flow`, `harden` and their flag handling.

## Layers

The environment has layers with different owners and lifetimes. The bootstrap is a
single command, but it is layered internally because each layer has a different
lifetime, cost, and authority.

| Layer | Contents | Lifetime | Managed by |
| --- | --- | --- | --- |
| 0. Host | git, python3-venv, docker/podman, iverilog, verilator, nix; group membership | machine | you, with `sudo`; bootstrap only detects and prints commands |
| 1. OCaml | opam switch `5.2.0+ox` and this repository's opam packages | machine, shared by all Hardcaml checkouts | `scripts/ocaml-deps.sh`; adds missing packages, never upgrades or downgrades one another checkout depends on |
| 2. Flow | `.venv`, `.venv-precheck`, `tinytapeout/pdk`, support-tools checkout, pinned LibreLane image, `tinytapeout/build/toolchain-env.sh` | per checkout or worktree | `tinytapeout/scripts/bootstrap-toolchain.sh`, pinned by `toolchain.lock` |
| 3. Shell | opam env, `PDK_ROOT`, `.venv/bin` on `PATH` | one terminal | `source env.sh` |
| 4. Build | `_build/`, emitted bundles, runs | derived from source | dune and `./flow.sh`, never the bootstrap |

A dependency that no opam repository carries is a sibling checkout in the workspace:
`hardcaml_asic` is the one today. Layer 1 pins those to the checkout with
`opam pin --kind=path`, so the switch builds against that working tree, uncommitted
work included. The cost is that opam wants a rebuild after edits there, and that the
pin names a directory which exists only on this machine.

Layers 1 and 2 are both plain shell, called directly by `./bootstrap.sh`: dune cannot
run before layer 1 exists, and making layer 2 wait for a compiled executable would mean
building OCaml just to ask whether a Python environment and a PDK are in place.
`./bootstrap.sh --check` therefore answers on a machine where layer 1 is still missing.
Layer 3 cannot be a command at all, because a child process cannot change its parent
shell. Scripts never depend on layer 3. They locate their own tools — `./flow.sh` runs
dune through the pinned switch itself — so activation only affects commands you type
yourself.

## Scenarios

| Situation | What is missing | Run |
| --- | --- | --- |
| New machine | Everything | Install the host packages that `./bootstrap.sh --check` names, then log out and back in for the docker/nix groups. Then `./bootstrap.sh`, which takes about 30 minutes for the switch plus about 2 GB of downloads. |
| Fresh clone, machine already set up | Layer 2, possibly new opam packages | `./bootstrap.sh`. |
| New worktree | Layer 2 again: it is per checkout (about 1.3 GB PDK and 600 MB of environments) | `./bootstrap.sh`, then `source env.sh` in that worktree. Sourcing switches `PATH` from the previous worktree rather than stacking. |
| New terminal or reboot | Layer 3 only | `source env.sh`. If something still fails, `dune exec protemu -- doctor`. `./flow.sh` works without it. |
| Reading an old run's results | Nothing; `collect` and `report` need only python3 and the run directory | `PROTEMU_RUN=/path/to/run ./flow.sh report`, on any machine that has the run, with no switch and no PDK. |
| Pull or branch switch changed `toolchain.lock` or the opam file | Layer 1 or 2 out of date | `./bootstrap.sh`. `dune exec protemu -- bootstrap` converges layer 2 alone and only reports on layer 1. A changed PDK revision is fetched and checked out in place, and switching back to an older lockfile works offline. It stops only if the PDK checkout has local changes. |
| OS upgrade, new python3 minor, or group membership lost | Layer 0 drift breaks layer 2 | `doctor` reports it. Recreating a venv means removing it yourself and rerunning; the bootstrap never deletes. |
| Interrupted bootstrap | Partial layer 2 | Rerun. Anything it will not repair is named with the path to remove. |
| Offline | Nothing may be fetched | `./bootstrap.sh --offline` validates and reuses what exists. |
| Editor or LSP launched outside a shell | Layer 3 is invisible to it | Point the editor at switch `5.2.0+ox`. `env.sh` only affects terminals. |

## What owns what

Provisioning, design inputs, and generated artifacts stay separate, and the
boundary between them is what keeps a bootstrap from quietly becoming a build:

| Category | Examples | Owner |
| --- | --- | --- |
| Host prerequisites | git, python3, a container runtime, basic shell utilities | you or your OS administrator; the bootstrap only detects and prints |
| Project-local toolchain | `.venv`, `.venv-precheck`, support-tools checkout, IHP PDK | the bootstrap, in the root `.venv` and ignored paths under `tinytapeout/` |
| Tracked design inputs | Hardcaml source, the typed declaration, `toolchain.lock`, integration scripts | this repository |
| Generated bundle | RTL, source sets, constraints, TT metadata/configuration, immutable manifest | `hardcaml_asic`, emitted from the declaration; see [flow.md](flow.md) |

The legacy path's hand-maintained `tinytapeout/info.yaml` and `src/config.json`
are tracked design inputs of that path only; the adopted path derives both.

## Boundaries

The bootstrap does not:

- install host packages, use `sudo`, or edit shell startup files
- build the design, emit a bundle, or run hardening or precheck (layer 4)
- stage the legacy P0 project, unless `--legacy-project` asks for it
- move to newer tools. Changing a version is a reviewed edit to `toolchain.lock` or the opam file.
- delete environments, PDKs, or runs

These stay outside it as well, because each is a decision rather than a step:

- selecting a different tile allocation, PDK, template, or clock target. `8x4`
  in particular is not accepted before an explicit competition update and a
  reviewed `toolchain.lock` change; `6x4` is authoritative until then.
- choosing or editing RTL, wrapper pins, timing assumptions, or flow overrides.
  The declaration owns configuration on the adopted path, and a conflicting
  override is an error rather than a precedence rule.
- deleting physical runs or submission artifacts, uploading them, enabling CI,
  or submitting the design.

Per-worktree duplication of layer 2 is the known cost of this layout. A shared cache
keyed by lockfile revision is deferred until usage justifies it: no reusable
provisioning package or new cache layout is required by the current milestone, and
the long-term home for one is a decision to make from actual use.
