# Environment and entry points

One command prepares a machine or checkout, and it is always safe to rerun:

```sh
./bootstrap.sh                 # check everything, create or update what is missing
./bootstrap.sh --install-deps  # also allow changes to the shared opam switch
source env.sh                  # every new shell
```

After the first run, dune is the entry point:

```sh
dune exec protemu -- bootstrap   # same convergence, once the OCaml layer exists
dune exec protemu -- doctor      # read-only report on every layer and this shell
dune exec protemu -- check       # RTL regression and staging
dune exec protemu -- harden      # CMOS5L synthesis and place-and-route
dune exec protemu -- precheck    # Tiny Tapeout precheck
dune runtest                     # Hardcaml tests + committed RTL is fresh
dune build @rtl                  # wrapper sim, Verilator lint, generic Yosys
```

## Layers

The environment has layers with different owners and lifetimes. The bootstrap is a
single command, but it is layered internally because each layer has a different
lifetime, cost, and authority.

| Layer | Contents | Lifetime | Managed by |
| --- | --- | --- | --- |
| 0. Host | git, python3-venv, docker/podman, iverilog, verilator, nix; group membership | machine | you, with `sudo`; bootstrap only detects and prints commands |
| 1. OCaml | opam switch `5.2.0+ox` and this repository's opam packages | machine, shared by all Hardcaml checkouts | `scripts/ocaml-deps.sh`; changes only with `--install-deps` |
| 2. Flow | `.venv`, `.venv-precheck`, `tinytapeout/pdk`, support-tools checkout, `tinytapeout/build/toolchain-env.sh` | per checkout or worktree | `tinytapeout/scripts/bootstrap-toolchain.sh`, pinned by `toolchain.lock` |
| 3. Shell | opam env, `PDK_ROOT`, `.venv/bin` on `PATH` | one terminal | `source env.sh` |
| 4. Build | `_build/`, staged project, runs | derived from source | dune and the `protemu` flow commands, never the bootstrap |

Layer 1 is plain shell because dune cannot run before it exists. Layer 3 cannot be a
command at all, because a child process cannot change its parent shell. Scripts never
depend on layer 3. They locate their own tools, so activation only affects commands
you type yourself.

## Scenarios

| Situation | What is missing | Run |
| --- | --- | --- |
| New machine | Everything | Install the host packages that `./bootstrap.sh` names, then log out and back in for the docker/nix groups. Then `./bootstrap.sh --install-deps`, which takes about 30 minutes for the switch plus about 2 GB of downloads. |
| Fresh clone, machine already set up | Layer 2, possibly new opam packages | `./bootstrap.sh`. Add `--install-deps` if it reports missing packages. |
| New worktree | Layer 2 again: it is per checkout (about 1.3 GB PDK and 600 MB of environments) | `./bootstrap.sh`, then `source env.sh` in that worktree. Sourcing switches `PATH` from the previous worktree rather than stacking. |
| New terminal or reboot | Layer 3 only | `source env.sh`. If something still fails, `dune exec protemu -- doctor`. |
| Pull or branch switch changed `toolchain.lock` or the opam file | Layer 1 or 2 out of date | `dune exec protemu -- bootstrap`. A changed PDK revision is fetched and checked out in place, and switching back to an older lockfile works offline. It stops only if the PDK checkout has local changes. |
| OS upgrade, new python3 minor, or group membership lost | Layer 0 drift breaks layer 2 | `doctor` reports it. Recreating a venv means removing it yourself and rerunning; the bootstrap never deletes. |
| Interrupted bootstrap | Partial layer 2 | Rerun. Anything it will not repair is named with the path to remove. |
| Offline | Nothing may be fetched | `./bootstrap.sh --offline` validates and reuses what exists. |
| Editor or LSP launched outside a shell | Layer 3 is invisible to it | Point the editor at switch `5.2.0+ox`. `env.sh` only affects terminals. |

## Boundaries

The bootstrap does not:

- install host packages, use `sudo`, or edit shell startup files
- build the design or run hardening or precheck (layer 4)
- move to newer tools. Changing a version is a reviewed edit to `toolchain.lock` or the opam file.
- delete environments, PDKs, or runs

Per-worktree duplication of layer 2 is the known cost of this layout. A shared cache
keyed by lockfile revision is deferred until usage justifies it; see section 1 of
[bootstrap-toolchain-plan.md](bootstrap-toolchain-plan.md).
