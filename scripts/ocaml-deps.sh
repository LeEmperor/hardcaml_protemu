#!/usr/bin/env bash
#
# The OCaml layer of the bootstrap: the opam switch and this repository's opam
# dependencies. Everything else needs dune, and dune needs this, so it is plain
# shell with no dependency on the repository having been built.
#
# The switch is shared with every other Hardcaml checkout on the machine, so the
# default is to check and print commands. Changes happen only with --install.
#
# `opam install . --deps-only` is deliberately not used, not even as a dry run:
# against a shared switch it proposes recompiling packages other repositories
# depend on. Dependencies are checked and installed by name instead.

set -euo pipefail

readonly EX_PREREQ=2

SWITCH="${OPAM_SWITCH:-5.2.0+ox}"
readonly SWITCH
readonly OX_REPOSITORY=git+https://github.com/oxcaml/opam-repository.git

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
readonly repo_root
readonly opam_file="$repo_root/hardcaml_protemu.opam"

install=0

usage() {
    cat <<'USAGE'
Usage: scripts/ocaml-deps.sh [--install]

Checks that the OxCaml opam switch exists and has this repository's opam
dependencies. Changes nothing unless --install is given.

Options:
  --install    Create the switch if it is missing (about 30 minutes) and install
               missing dependencies into it. Installed packages are never
               upgraded, downgraded, or recompiled.
  -h, --help   Show this message.

Environment:
  OPAM_SWITCH  Switch to use. Default: 5.2.0+ox

Exit codes:
  0  switch present with every dependency
  2  something is missing; the commands that fix it are printed
USAGE
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --install) install=1 ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; exit 1 ;;
    esac
    shift
done

step() { printf '\n==> %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }

die() {
    local code=$1
    shift
    printf '\nerror: %s\n' "$1" >&2
    shift
    local line
    for line in "$@"; do printf '       %s\n' "$line" >&2; done
    exit "$code"
}

step "Checking the OCaml layer (opam switch $SWITCH)"

command -v opam >/dev/null 2>&1 || die "$EX_PREREQ" "opam is not installed" \
    "Install it with your package manager (apt install opam), then run:" \
    "  opam init --bare --no-setup"

opam var root >/dev/null 2>&1 || die "$EX_PREREQ" "opam is not initialised" \
    "Run: opam init --bare --no-setup"

if ! opam switch list --short 2>/dev/null | grep -qx "$SWITCH"; then
    create=(opam switch create "$SWITCH" "ocaml-variants.5.2.0+ox"
            --repos "ox=$OX_REPOSITORY,default" --yes)
    if [[ $install -eq 0 ]]; then
        die "$EX_PREREQ" "opam switch '$SWITCH' does not exist" \
            "Rerun with --install to create it (about 30 minutes), or run:" \
            "  ${create[*]}"
    fi
    info "creating switch $SWITCH; this takes about 30 minutes"
    "${create[@]}"
fi

version=$(opam exec --switch="$SWITCH" -- ocamlc -version)
case $version in
    5.2.0+ox*) info "OCaml $version" ;;
    *) die "$EX_PREREQ" "switch '$SWITCH' has OCaml $version, expected 5.2.0+ox" ;;
esac

# Every dependency in the opam file except documentation. opam 2.1 has no
# --with-dev-setup, so filtered entries are read by name rather than resolved.
mapfile -t wanted < <(
    opam show --just-file --raw -f depends "$opam_file" \
        | grep -v 'with-doc' \
        | awk -F'"' 'NF > 1 { print $2 }')
[[ ${#wanted[@]} -gt 0 ]] || die "$EX_PREREQ" "could not read depends from $opam_file"

mapfile -t installed < <(opam list --switch="$SWITCH" --installed --short "${wanted[@]}" 2>/dev/null)
missing=()
for pkg in "${wanted[@]}"; do
    printf '%s\n' "${installed[@]}" | grep -qx "$pkg" || missing+=("$pkg")
done

if [[ ${#missing[@]} -eq 0 ]]; then
    info "all ${#wanted[@]} opam dependencies installed"
    exit 0
fi

if [[ $install -eq 0 ]]; then
    die "$EX_PREREQ" "missing opam packages: ${missing[*]}" \
        "Rerun with --install, or run:" \
        "  opam install --switch=$SWITCH ${missing[*]}"
fi

info "installing ${missing[*]}"
opam install --switch="$SWITCH" --yes "${missing[@]}"
