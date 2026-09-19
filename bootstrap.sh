#!/usr/bin/env bash
#
# The one command for a fresh clone or worktree. Safe to rerun at any time: every
# layer is checked and only what is missing or out of date is changed.
#
#   1. OCaml layer   scripts/ocaml-deps.sh                     switch + opam packages
#   2. Flow layer    tinytapeout/scripts/bootstrap-toolchain.sh  .venv, PDK, support
#                                                                tools, LibreLane image
#   3. Shell layer   source env.sh                             (printed; a script
#                                                               cannot do it)
#
# Both layers are shell scripts called directly. Neither needs dune, so --check
# validates the flow tools on a machine where the OCaml layer is still missing,
# and never compiles an executable just to answer a question about Python and a
# PDK. Building OCaml is the flow's own "build" step: ./flow.sh build.
#
# Two modes, and nothing else to remember:
#
#   ./bootstrap.sh           converge: install whatever is missing, then verify it
#   ./bootstrap.sh --check   verify every layer and change nothing
#
# Converging installs missing packages into the opam switch, which is shared with
# every other Hardcaml checkout on the machine. Only ever additions: nothing here
# upgrades, downgrades or recompiles a package another checkout depends on. Use
# --check to see what is missing without touching the switch.
#
# It prepares an environment. It does not stage a design, emit a bundle, or start
# hardening: that is ./flow.sh, and it is always an explicit command.
#
# See docs/environment.md; the flow itself is docs/flow.md.

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
readonly repo_root

usage() {
    cat <<'USAGE'
Usage: ./bootstrap.sh [options]

With no options: installs what is missing in every layer, then verifies it.

Options:
  --check          Validate every layer and change nothing. Missing packages are
                   named with the command that installs them.
  --offline        Reuse the flow environment; fetch and install nothing.
  --no-container   Skip the Docker/Podman prerequisite. The pinned LibreLane
                   image is then not resolved either; supply a native LibreLane.
  --legacy-project Also stage and configure the legacy P0 project, for the
                   legacy hardening scripts. ./flow.sh does not use it.
  --install-deps   Accepted for compatibility; installing is the default now.
  -h, --help       Show this message.

Then:
  source env.sh    every new shell
  ./flow.sh        the ASIC flow (./flow.sh --help first; the bare form hardens)
USAGE
}

check=0
install_deps=0
offline=0
no_container=0
legacy_project=0

while [[ $# -gt 0 ]]; do
    case $1 in
        --check) check=1 ;;
        --install-deps) install_deps=1 ;;
        --offline) offline=1 ;;
        --no-container) no_container=1 ;;
        --legacy-project) legacy_project=1 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "bootstrap: unknown option: $1 (try --help)" >&2; exit 1 ;;
    esac
    shift
done

# --check promises to change nothing, so it cannot be combined with an option whose
# whole purpose is to install. Caught here rather than letting layer 1 install and
# layer 2 then report it would have.
if [[ $check -eq 1 && $install_deps -eq 1 ]]; then
    echo "bootstrap: --check and --install-deps contradict each other" >&2
    exit 1
fi

if [[ $install_deps -eq 1 ]]; then
    echo "bootstrap: --install-deps is the default now; the flag is accepted and ignored" >&2
fi

deps_args=()
[[ $check -eq 1 ]] || deps_args+=(--install)

flow_args=()
[[ $check -eq 0 ]] || flow_args+=(--check)
[[ $offline -eq 0 ]] || flow_args+=(--offline)
[[ $no_container -eq 0 ]] || flow_args+=(--no-container)
[[ $legacy_project -eq 0 ]] || flow_args+=(--legacy-project)

"$repo_root/scripts/ocaml-deps.sh" "${deps_args[@]}"

exec "$repo_root/tinytapeout/scripts/bootstrap-toolchain.sh" ${flow_args[@]+"${flow_args[@]}"}
