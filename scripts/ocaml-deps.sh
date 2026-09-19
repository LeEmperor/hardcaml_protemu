#!/usr/bin/env bash
#
# The OCaml layer of the bootstrap: the opam switch and this repository's opam
# dependencies. Everything else needs dune, and dune needs this, so it is plain
# shell with no dependency on the repository having been built.
#
# The switch is shared with every other Hardcaml checkout on the machine, so this
# script's own default is to check and print commands; changes happen only with
# --install, and only ever add. ./bootstrap.sh passes --install unless it was given
# --check, so the converging and the reporting mode both have one obvious spelling.
#
# `opam install . --deps-only` is deliberately not used, not even as a dry run:
# against a shared switch it proposes recompiling packages other repositories
# depend on. Dependencies are checked and installed by name instead.
#
# A dependency no opam repository carries is a sibling checkout in this workspace
# (hardcaml_asic today). Those are pinned to the checkout rather than installed by
# name; see the pinning block below for why the pin kind matters.

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
  --install    Create the switch if it is missing (about 30 minutes), pin any
               dependency that lives in this workspace rather than an opam
               repository, install what is still missing, then verify it all
               arrived. Installed packages are never upgraded or downgraded.
  -h, --help   Show this message.

Environment:
  OPAM_SWITCH  Switch to use. Default: 5.2.0+ox

Exit codes:
  0  switch present with every dependency
  2  something is missing or opam failed; the commands that fix it are printed
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

# Fills [missing] with the wanted packages the switch does not have.
#
# Careful: opam's exit status is checked rather than dropped, and its stderr is kept.
# `opam list` exits nonzero with EMPTY stdout when it fails at all (a stale lock, an
# unreadable root, a switch that vanished mid-run), and empty stdout read as data means
# "no package is installed" -- which would report every dependency as missing and send
# the reader off to reinstall a switch that was fine. An opam failure is reported as an
# opam failure instead.
find_missing() {
    local listing status pkg
    listing=$(opam list --switch="$SWITCH" --installed --short "${wanted[@]}" 2>&1) || {
        status=$?
        die "$EX_PREREQ" "could not list installed packages in switch '$SWITCH'" \
            "opam exited $status and said:" "$listing"
    }
    mapfile -t installed <<<"$listing"
    missing=()
    for pkg in "${wanted[@]}"; do
        printf '%s\n' "${installed[@]}" | grep -qx "$pkg" || missing+=("$pkg")
    done
}

find_missing

# A missing package that no opam repository carries cannot be installed by name, and
# opam fails the whole transaction over it, so every other missing package stays
# missing too. The cause here is a workspace sibling (~/devel/jane/<pkg>, see the
# workspace CLAUDE.md) that is built from a checkout rather than published, so it is
# pinned to that checkout instead of installed by name.
#
# The pin is --kind=path, not the git kind opam picks by default for a directory that
# happens to be a git repository: path follows the working tree, so uncommitted work in
# the sibling is what this switch builds against. That is the point of having the
# checkout. It also means opam wants a rebuild after edits there, which is the cost.
if [[ ${#missing[@]} -gt 0 ]]; then
    workspace=$(dirname "$repo_root")
    unpublished=()
    for pkg in "${missing[@]}"; do
        opam show --switch="$SWITCH" "$pkg" >/dev/null 2>&1 || unpublished+=("$pkg")
    done

    pinnable=()
    stranded=()
    for pkg in "${unpublished[@]}"; do
        if [[ -f "$workspace/$pkg/$pkg.opam" ]]; then
            pinnable+=("$pkg")
        else
            stranded+=("$pkg")
        fi
    done

    # Nothing to pin them to: neither this script nor opam can proceed.
    if [[ ${#stranded[@]} -gt 0 ]]; then
        lines=()
        for pkg in "${stranded[@]}"; do
            lines+=("  $pkg: no opam repository has it, and $workspace/$pkg is not a checkout of it")
        done
        die "$EX_PREREQ" "cannot resolve: ${stranded[*]}" \
            "Clone them into the workspace (./sync.sh there), or drop them from" \
            "$opam_file:" "${lines[@]}"
    fi

    if [[ ${#pinnable[@]} -gt 0 ]]; then
        pin_cmds=()
        for pkg in "${pinnable[@]}"; do
            pin_cmds+=("  opam pin add --switch=$SWITCH --kind=path --yes $pkg $workspace/$pkg")
        done
        if [[ $install -eq 0 ]]; then
            die "$EX_PREREQ" "not published to any opam repository: ${pinnable[*]}" \
                "Rerun with --install to pin the workspace checkout, or run:" \
                "${pin_cmds[@]}"
        fi
        for pkg in "${pinnable[@]}"; do
            info "pinning $pkg to $workspace/$pkg"
            opam pin add --switch="$SWITCH" --kind=path --yes "$pkg" "$workspace/$pkg"
        done
        # Pinning builds and installs, so the switch has moved on.
        find_missing
    fi
fi

if [[ ${#missing[@]} -gt 0 ]]; then
    if [[ $install -eq 0 ]]; then
        die "$EX_PREREQ" "missing opam packages: ${missing[*]}" \
            "Rerun with --install (./bootstrap.sh does that by default), or run:" \
            "  opam install --switch=$SWITCH ${missing[*]}"
    fi

    info "installing ${missing[*]}"
    opam install --switch="$SWITCH" --yes "${missing[@]}"

    # Read the switch back rather than trusting the exit status: opam can report
    # success having installed less than it was asked for, and a dependency that is
    # still absent here becomes a "Library not found" from dune much later.
    requested=("${missing[@]}")
    find_missing
    [[ ${#missing[@]} -eq 0 ]] || die "$EX_PREREQ" \
        "still missing after installing ${requested[*]}: ${missing[*]}" \
        "opam reported success. Install one of them on its own to see why:" \
        "  opam install --switch=$SWITCH ${missing[0]}"
fi

info "all ${#wanted[@]} opam dependencies installed"
