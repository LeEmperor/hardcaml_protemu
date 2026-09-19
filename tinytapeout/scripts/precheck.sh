#!/usr/bin/env bash
#
# Tiny Tapeout precheck for the current legacy CMOS5L hardening run; see
# docs/flow.md#the-legacy-path. The adopted path runs precheck in ./flow.sh's
# postcheck stage.
#
# This mirrors the precheck job of the pinned tt-gds-action:
#
#   ./tt/tt_tool.py --create-tt-submission --ihp
#   cd tt/precheck && nix-shell --run \
#       "python precheck.py --gds tt_submission/*.gds --tech ihp-sg13cmos5l"
#
# with these differences:
#
#   * precheck.py writes its reports beside itself and resolves tech-files/,
#     magic_drc.tcl and ../tech/<pdk>/def relative to its working directory.
#     It therefore runs from a per-run copy under runs/wokwi/precheck/, so the
#     shared support-tools checkout stays clean (bootstrap and harden refuse a
#     dirty one) and the reports move with the run when harden-cmos5l.sh
#     archives it.
#   * The interpreter is .venv-precheck's, named explicitly: its klayout/gdstk
#     pins conflict with .venv, so neither environment can stand in for the other.
#   * The native tools come from upstream's precheck/default.nix, and their
#     versions are checked against precheck/tool-versions.json before any check
#     runs. For ihp-sg13cmos5l precheck.py runs KLayout only; magic is provided
#     by the same shell but no CMOS5L check invokes it.
#
# Run tinytapeout/scripts/harden-cmos5l.sh first. A timing failure (exit 8)
# still leaves a complete run that can be prechecked.

set -euo pipefail

readonly EX_GENERAL=1
readonly EX_PREREQ=2
readonly EX_MISMATCH=5
readonly EX_TOOL=7
readonly EX_PRECHECK=9   # precheck ran and at least one check failed

step() { printf '\n==> %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '    warning: %s\n' "$*" >&2; }

die() {
    local code=$1
    shift
    printf '\nerror: %s\n' "$1" >&2
    shift
    local line
    for line in "$@"; do printf '       %s\n' "$line" >&2; done
    exit "$code"
}

usage() {
    cat <<'USAGE'
Usage: tinytapeout/scripts/precheck.sh [options]

Builds the Tiny Tapeout submission from the current hardening run and runs the
upstream precheck against it, using the Nix-pinned KLayout.

Options:
  -h, --help     Show this message.

Exit codes:
  0  every precheck check passed
  2  environment not prepared, no hardening run, or Nix unusable
  5  environment no longer matches toolchain.lock or tool-versions.json
  7  a tool failed before precheck could report results
  9  precheck ran and at least one check failed

Reports are written to tinytapeout/build/p0-staged/runs/wokwi/precheck/reports
and are preserved on every outcome.
USAGE
}

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help) usage; exit 0 ;;
        *) usage >&2; die "$EX_GENERAL" "unknown option: $1" ;;
    esac
    shift
done

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
readonly script_dir repo_root

# shellcheck source=nix-pin.sh
source "$script_dir/nix-pin.sh"

readonly tt_dir="$repo_root/tinytapeout"
readonly lock_file="$tt_dir/toolchain.lock"
readonly venv_dir="$repo_root/.venv"
readonly precheck_venv_dir="$repo_root/.venv-precheck"
readonly stage_dir="$tt_dir/build/p0-staged"
readonly env_file="$tt_dir/build/toolchain-env.sh"
readonly run_dir="$stage_dir/runs/wokwi"
readonly work_dir="$run_dir/precheck"

# ---------------------------------------------------------------------------
# Lockfile, parsed as data rather than sourced.
# ---------------------------------------------------------------------------
lock() {
    local key=$1 value
    value=$(awk -F= -v k="$key" '
        $0 ~ /^[[:space:]]*(#|$)/ { next }
        substr($0, 1, length(k) + 1) == k "=" { print substr($0, length(k) + 2); found = 1 }
        END { if (!found) exit 1 }' "$lock_file") \
        || die "$EX_MISMATCH" "missing lockfile key: $key"
    printf '%s' "$value"
}

# ---------------------------------------------------------------------------
# 1. Environment
# ---------------------------------------------------------------------------
load_environment() {
    step "Loading the prepared environment"

    [[ -f $env_file ]] || die "$EX_PREREQ" \
        "no activation file: $env_file" \
        "Run tinytapeout/scripts/bootstrap-toolchain.sh first."
    # shellcheck disable=SC1090
    source "$env_file"

    [[ -n ${PDK_ROOT:-} ]] || die "$EX_PREREQ" "PDK_ROOT not set by $env_file"
    [[ -n ${PDK:-} ]] || die "$EX_PREREQ" "PDK not set by $env_file"
    [[ -n ${TT_SUPPORT_TOOLS_DIR:-} ]] || die "$EX_PREREQ" "TT_SUPPORT_TOOLS_DIR not set"
    [[ -x $venv_dir/bin/python ]] || die "$EX_PREREQ" \
        "no python environment at $venv_dir" "Run bootstrap-toolchain.sh first."
    [[ -x $precheck_venv_dir/bin/python ]] || die "$EX_PREREQ" \
        "no precheck environment at $precheck_venv_dir" "Run bootstrap-toolchain.sh first."

    # tt_tool.py shells out by bare name; see harden-cmos5l.sh.
    export PATH="$venv_dir/bin:$PATH"

    info "PDK_ROOT $PDK_ROOT"
    info "support tools $TT_SUPPORT_TOOLS_DIR"
}

verify_environment() {
    step "Re-verifying the environment against the lockfile"

    local want head
    want=$(lock support_tools_revision)
    head=$(git -C "$TT_SUPPORT_TOOLS_DIR" rev-parse HEAD 2>/dev/null) \
        || die "$EX_MISMATCH" "not a git checkout: $TT_SUPPORT_TOOLS_DIR"
    [[ $head == "$want" ]] || die "$EX_MISMATCH" \
        "tt-support-tools is at $head, lockfile wants $want" \
        "Rerun bootstrap-toolchain.sh."
    [[ -z $(git -C "$TT_SUPPORT_TOOLS_DIR" status --porcelain) ]] || die "$EX_MISMATCH" \
        "tt-support-tools checkout is dirty: $TT_SUPPORT_TOOLS_DIR"

    want=$(lock pdk_revision)
    head=$(git -C "$PDK_ROOT" rev-parse HEAD 2>/dev/null) \
        || die "$EX_MISMATCH" "PDK_ROOT is not a git checkout: $PDK_ROOT"
    [[ $head == "$want" ]] || die "$EX_MISMATCH" \
        "PDK is at $head, lockfile wants $want"

    # The precheck environment exists because of this pin; confirm it held.
    local have
    have=$("$precheck_venv_dir/bin/python" -c \
        'from importlib.metadata import version; print(version("klayout"))' 2>/dev/null) \
        || die "$EX_PREREQ" "klayout is not installed in $precheck_venv_dir"
    [[ $have == 0.28.* ]] || die "$EX_MISMATCH" \
        "$precheck_venv_dir has klayout $have; precheck pins 0.28.x" \
        "Rerun bootstrap-toolchain.sh."

    info "support tools and PDK match; precheck klayout module $have"
}

# ---------------------------------------------------------------------------
# 2. Nix and the pinned native tools
# ---------------------------------------------------------------------------
check_nix() {
    step "Checking Nix"

    command -v nix-shell >/dev/null 2>&1 || die "$EX_PREREQ" \
        "nix-shell not found" \
        "Precheck takes KLayout from $TT_SUPPORT_TOOLS_DIR/precheck/default.nix." \
        "Install Nix, then rerun."

    # Installed is not the same as usable: with a daemon install, a user outside
    # the daemon's allowed group gets "Permission denied" on every command.
    local out
    if ! out=$(nix-instantiate --eval --expr 'builtins.nixVersion' 2>&1); then
        die "$EX_PREREQ" "Nix is installed but this user cannot use it" \
            "$(printf '%s' "$out" | head -n 1)" \
            "Ubuntu's nix-bin package limits the daemon to the nix-users group:" \
            "  sudo usermod -aG nix-users \$USER" \
            "then log out and back in, and rerun."
    fi
    info "nix $(printf '%s' "$out" | tr -d '"')"
}

verify_native_tools() {
    step "Providing and verifying the pinned precheck tools"

    local nix_file="$TT_SUPPORT_TOOLS_DIR/precheck/default.nix"
    local pins="$TT_SUPPORT_TOOLS_DIR/precheck/tool-versions.json"
    [[ -f $nix_file ]] || die "$EX_MISMATCH" "not found: $nix_file"
    [[ -f $pins ]] || die "$EX_MISMATCH" "not found: $pins"

    local want_klayout want_magic
    want_klayout=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["klayout"])' "$pins")
    want_magic=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["magic"])' "$pins")

    info "the first run downloads KLayout and Magic into /nix/store"
    # Nix's own progress goes to stderr and stays visible; only the tools'
    # version output is captured.
    local versions pin
    pin=$(nixpkgs_pin "$nix_file")
    versions=$(NIX_PATH="${pin:-${NIX_PATH:-}}" \
        nix-shell "$nix_file" --run 'klayout -v; magic --version 2>&1 || true' </dev/null) \
        || die "$EX_TOOL" "nix-shell could not provide the precheck tools" \
               "Try it directly: nix-shell $nix_file --run 'klayout -v'"

    local have_klayout
    have_klayout=$(printf '%s\n' "$versions" | awk '$1 == "KLayout" { print $2; exit }')
    [[ -n $have_klayout ]] || die "$EX_TOOL" \
        "could not read the KLayout version" "output was: $versions"
    [[ $have_klayout == "$want_klayout" ]] || die "$EX_MISMATCH" \
        "Nix provided KLayout $have_klayout; $pins pins $want_klayout"
    info "klayout $have_klayout"

    # Reported, not gated: no ihp-sg13cmos5l check runs magic.
    if printf '%s\n' "$versions" | grep -qF "$want_magic"; then
        info "magic $want_magic (unused for $PDK)"
    else
        warn "magic version not confirmed as $want_magic (unused for $PDK)"
    fi

    tool_klayout=$have_klayout
}

# ---------------------------------------------------------------------------
# 3. Submission
# ---------------------------------------------------------------------------
gds_file=""
tool_klayout=""

create_submission() {
    step "Creating the submission from the current run"

    [[ -f $run_dir/final/metrics.csv ]] || die "$EX_PREREQ" \
        "no completed hardening run at $run_dir" \
        "Run tinytapeout/scripts/harden-cmos5l.sh first."

    ( cd "$stage_dir" \
      && "$venv_dir/bin/python" "$TT_SUPPORT_TOOLS_DIR/tt_tool.py" \
           --project-dir "$stage_dir" --ihp --create-tt-submission ) \
        || die "$EX_TOOL" "tt_tool.py --create-tt-submission failed"

    local found=()
    shopt -s nullglob
    found=("$stage_dir"/tt_submission/*.gds)
    shopt -u nullglob
    [[ ${#found[@]} -eq 1 ]] || die "$EX_TOOL" \
        "expected exactly one GDS in $stage_dir/tt_submission, found ${#found[@]}"
    gds_file=${found[0]}
    info "$gds_file"
}

# ---------------------------------------------------------------------------
# 4. Precheck
# ---------------------------------------------------------------------------
prepare_work_dir() {
    step "Preparing the precheck working copy"

    case $work_dir in
        "$stage_dir"/runs/wokwi/precheck) ;;
        *) die "$EX_GENERAL" "refusing unexpected precheck path: $work_dir" ;;
    esac
    rm -rf "$work_dir"
    mkdir -p "$work_dir/tt"

    # A copy rather than a symlink: precheck.py locates its reports through
    # os.path.realpath(__file__), which would resolve back into the checkout.
    cp -R "$TT_SUPPORT_TOOLS_DIR/precheck" "$work_dir/tt/precheck"
    rm -rf "$work_dir/tt/precheck/__pycache__" "$work_dir/tt/precheck/.pytest_cache"
    find "$work_dir/tt/precheck/reports" -mindepth 1 ! -name .gitignore -delete
    # Only read, through ../tech/<pdk>/def, so a link is enough.
    ln -s "$TT_SUPPORT_TOOLS_DIR/tech" "$work_dir/tt/tech"
    ln -s tt/precheck/reports "$work_dir/reports"

    info "$work_dir"
}

run_precheck() {
    step "Running precheck"

    local rc=0 pin
    pin=$(nixpkgs_pin "$work_dir/tt/precheck/default.nix")
    # PYTHONPATH/PYTHONHOME are cleared because a Nix shell may point them at
    # Nix's own Python, which would shadow the environment's pinned packages.
    ( cd "$work_dir/tt/precheck" \
      && PRECHECK_PYTHON="$precheck_venv_dir/bin/python" PRECHECK_GDS="$gds_file" \
         NIX_PATH="${pin:-${NIX_PATH:-}}" \
         nix-shell default.nix --run \
           'exec env -u PYTHONPATH -u PYTHONHOME "$PRECHECK_PYTHON" precheck.py --gds "$PRECHECK_GDS" --tech "$PDK"' \
           </dev/null ) || rc=$?

    local reports="$work_dir/tt/precheck/reports"
    [[ -f $reports/results.md ]] && { printf '\n'; sed 's/^/    /' "$reports/results.md"; printf '\n'; }

    write_summary "$rc"

    if [[ $rc -eq 0 ]]; then
        info "precheck passed"
    elif [[ -f $reports/results.xml ]]; then
        die "$EX_PRECHECK" "precheck ran and at least one check failed" \
            "Reports: $work_dir/reports"
    else
        die "$EX_TOOL" "precheck failed before producing results (exit $rc)" \
            "Its log is above; partial reports, if any: $work_dir/reports"
    fi
}

write_summary() {
    local rc=$1
    PRECHECK_RC="$rc" \
    GDS_FILE="$gds_file" \
    TOOL_KLAYOUT="$tool_klayout" \
    LOCK_PDK="$(lock pdk)" \
    LOCK_PDK_REVISION="$(lock pdk_revision)" \
    LOCK_SUPPORT_TOOLS="$(lock support_tools_revision)" \
    python3 - "$work_dir/tt/precheck/reports/results.xml" "$work_dir/precheck-summary.json" <<'PY' \
        || warn "could not write precheck-summary.json"
import hashlib, json, os, sys
import xml.etree.ElementTree as ET

results_path, summary_path = sys.argv[1], sys.argv[2]
checks = {}
if os.path.exists(results_path):
    for case in ET.parse(results_path).getroot().iter("testcase"):
        error = case.find("error")
        checks[case.get("name")] = "pass" if error is None else error.get("message")

gds = os.environ["GDS_FILE"]
with open(gds, "rb") as fh:
    gds_sha256 = hashlib.sha256(fh.read()).hexdigest()

summary = {
    "passed": os.environ["PRECHECK_RC"] == "0",
    "exit_code": int(os.environ["PRECHECK_RC"]),
    "gds": os.path.basename(gds),
    "gds_sha256": gds_sha256,
    "pdk": os.environ["LOCK_PDK"],
    "pdk_revision": os.environ["LOCK_PDK_REVISION"],
    "support_tools_revision": os.environ["LOCK_SUPPORT_TOOLS"],
    "klayout": os.environ["TOOL_KLAYOUT"],
    "checks": checks,
}
with open(summary_path, "w") as fh:
    json.dump(summary, fh, indent=2, sort_keys=True)
    fh.write("\n")
PY
    info "summary written to $work_dir/precheck-summary.json"
}

main() {
    # The submission and reports are written inside the staged project; a
    # re-stage mid-run would delete them.
    # shellcheck source=stage-lock.sh
    source "$script_dir/stage-lock.sh"
    acquire_stage_lock "$repo_root" || exit "$EX_GENERAL"

    load_environment
    verify_environment
    check_nix
    verify_native_tools
    create_submission
    prepare_work_dir
    run_precheck

    cat <<EOF

================================================================================
Precheck passed.

  gds        $gds_file
  reports    $work_dir/reports
  summary    $work_dir/precheck-summary.json

These reports live inside the run directory, so the next harden-cmos5l.sh
archives them together with the run they describe.
================================================================================
EOF
}

main
