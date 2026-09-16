#!/usr/bin/env bash
#
# The one command for a fresh clone or worktree. Safe to rerun at any time: every
# layer is checked and only what is missing or out of date is changed.
#
#   1. OCaml layer   scripts/ocaml-deps.sh        switch + opam dependencies
#   2. Flow layer    dune exec protemu -- bootstrap  .venv, PDK, support tools
#   3. Shell layer   source env.sh                (printed; a script cannot do it)
#
# Only step 1 lives here, because nothing can go through dune before it exists.
# Once it does, `dune exec protemu -- bootstrap` is the same command.
# See docs/environment.md.

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
readonly repo_root

usage() {
    cat <<'USAGE'
Usage: ./bootstrap.sh [options]

Options:
  --install-deps   Allow changes to the shared opam switch: create it if missing
                   and install missing packages. Without this, the OCaml layer is
                   only checked.
  --offline        Reuse the flow environment; fetch and install nothing.
  --check          Validate every layer and change nothing.
  --no-container   Skip the Docker/Podman prerequisite.
  -h, --help       Show this message.
USAGE
}

deps_args=()
protemu_args=()
while [[ $# -gt 0 ]]; do
    case $1 in
        --install-deps) deps_args+=(--install) ;;
        --offline) protemu_args+=(-offline) ;;
        --check) protemu_args+=(-check) ;;
        --no-container) protemu_args+=(-no-container) ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; exit 1 ;;
    esac
    shift
done

if [[ " ${protemu_args[*]} " == *" -check "* && ${#deps_args[@]} -gt 0 ]]; then
    echo "error: --check and --install-deps contradict each other" >&2
    exit 1
fi

"$repo_root/scripts/ocaml-deps.sh" "${deps_args[@]}"

cd "$repo_root"
exec "$repo_root/scripts/with-switch.sh" \
    dune exec --display quiet protemu -- bootstrap "${protemu_args[@]}"
