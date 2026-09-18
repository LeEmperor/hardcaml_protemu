#!/usr/bin/env bash
#
# The one command for a fresh clone or worktree. Safe to rerun at any time: every
# layer is checked and only what is missing or out of date is changed.
#
#   1. OCaml layer   scripts/ocaml-deps.sh           switch + opam dependencies
#   2. Flow layer    dune exec protemu -- bootstrap  .venv, PDK, support tools
#   3. Shell layer   source env.sh                   (printed; a script cannot do it)
#
# Only step 1 lives here, because nothing can go through dune before it exists.
# Once it does, `dune exec protemu -- bootstrap` converges layer 2 on its own.
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
# Each layer is checked exactly once per invocation. The OCaml layer is checked
# here, so protemu is told not to check it a second time.
#
# See docs/environment.md.

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
  --no-container   Skip the Docker/Podman prerequisite.
  --install-deps   Accepted for compatibility; installing is the default now.
  -h, --help       Show this message.
USAGE
}

check=0
install_deps=0
offline=0
no_container=0

while [[ $# -gt 0 ]]; do
    case $1 in
        --check) check=1 ;;
        --install-deps) install_deps=1 ;;
        --offline) offline=1 ;;
        --no-container) no_container=1 ;;
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

protemu_args=(-skip-ocaml-check)
[[ $check -eq 0 ]] || protemu_args+=(-check)
[[ $offline -eq 0 ]] || protemu_args+=(-offline)
[[ $no_container -eq 0 ]] || protemu_args+=(-no-container)

"$repo_root/scripts/ocaml-deps.sh" "${deps_args[@]}"

cd "$repo_root"
exec "$repo_root/scripts/with-switch.sh" \
    dune exec --display quiet protemu -- bootstrap "${protemu_args[@]}"
