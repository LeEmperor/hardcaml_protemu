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

```sh
./flow.sh --help                  # steps, PROTEMU_* overrides, and how to resume
./flow.sh build emit preflight    # prepare and check a bundle; no hardening
./flow.sh run postcheck collect report
PROTEMU_RUN=/path/to/run ./flow.sh report    # inspect a finished run
```

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
bundle: see [the adopted flow guide](asic-adoption.md#the-flow) and
[the migration handoff](flow_migration.md). They need
`./bootstrap.sh --legacy-project`, which is the only way that project is staged
now. `protemu harden` is an alias for `./flow.sh run` and rejects the legacy
`-tag` and `-no-docker` flags rather than reinterpreting them.

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

## Boundaries

The bootstrap does not:

- install host packages, use `sudo`, or edit shell startup files
- build the design, emit a bundle, or run hardening or precheck (layer 4)
- stage the legacy P0 project, unless `--legacy-project` asks for it
- move to newer tools. Changing a version is a reviewed edit to `toolchain.lock` or the opam file.
- delete environments, PDKs, or runs

Per-worktree duplication of layer 2 is the known cost of this layout. A shared cache
keyed by lockfile revision is deferred until usage justifies it; see section 1 of
[bootstrap-toolchain-plan.md](bootstrap-toolchain-plan.md).
