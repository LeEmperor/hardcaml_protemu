#!/usr/bin/env bash
#
# Mapped CMOS5L synthesis and place-and-route for the staged Tiny Tapeout
# project, per section 8 of docs/bootstrap-toolchain-plan.md.
#
# This is a wrapper around one underlying command, which tt-support-tools builds
# in Project.harden():
#
#   python -m librelane --pdk-root $PDK_ROOT --docker-no-tty --dockerized \
#          --pdk ihp-sg13cmos5l --manual-pdk \
#          --run-tag wokwi --force-run-dir runs/wokwi src/config_merged.json
#
# The wrapper exists because that command alone is neither reproducible nor
# trustworthy on its own:
#
#   * Project.harden() runs shutil.rmtree("runs/wokwi") unconditionally, and
#     stage-project.sh removes the whole staged directory. Between them, every
#     previous result is destroyed on each invocation. This script preserves the
#     prior run before anything is removed.
#   * LibreLane's exit status reports step failures. It does not necessarily
#     fail the build on negative slack, and tt-support-tools checks no timing
#     metric anywhere. The timing gate here is the only one in the pipeline.
#   * An experiment record needs machine-readable results, not scrollback.
#
# Run tinytapeout/scripts/bootstrap-toolchain.sh first.

set -euo pipefail

readonly EX_GENERAL=1
readonly EX_PREREQ=2
readonly EX_MISMATCH=5
readonly EX_TOOL=7
readonly EX_TIMING=8     # the flow completed but the design does not close

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

no_docker=0
run_tag=""

usage() {
    cat <<'USAGE'
Usage: tinytapeout/scripts/harden-cmos5l.sh [options]

Regenerates RTL, re-stages the Tiny Tapeout project, runs mapped CMOS5L
synthesis and place-and-route, and gates the result on timing.

Options:
  --no-docker    Use a native LibreLane instead of the dockerized one.
  --tag NAME     Label for the archived previous run. Default: a timestamp.
  -h, --help     Show this message.

Exit codes:
  0  flow completed and timing closed
  2  environment not prepared; run bootstrap-toolchain.sh
  5  environment no longer matches toolchain.lock
  7  a tool ran and failed
  8  the flow completed but the design does not meet timing

Artifacts are preserved on every outcome, including a timing failure.
USAGE
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --no-docker) no_docker=1 ;;
        --tag) shift; [[ $# -gt 0 ]] || die "$EX_GENERAL" "--tag needs a value"; run_tag=$1 ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; die "$EX_GENERAL" "unknown option: $1" ;;
    esac
    shift
done

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
readonly script_dir repo_root

readonly tt_dir="$repo_root/tinytapeout"
readonly lock_file="$tt_dir/toolchain.lock"
readonly venv_dir="$repo_root/.venv"
readonly stage_dir="$tt_dir/build/p0-staged"
readonly env_file="$tt_dir/build/toolchain-env.sh"
readonly runs_archive="$tt_dir/runs"
readonly run_dir="$stage_dir/runs/wokwi"

: "${run_tag:=$(date +%Y%m%d-%H%M%S)}"

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

    # tt_tool.py shells out by bare name: `yowasp-yosys` during configuration and
    # `python -m librelane` for the flow itself. Without the venv leading PATH the
    # first is not found and the second resolves to a system python (or none).
    export PATH="$venv_dir/bin:$PATH"

    info "PDK_ROOT $PDK_ROOT"
    info "support tools $TT_SUPPORT_TOOLS_DIR"
}

# Re-verify before spending an hour. A stale environment that produces a
# plausible-looking result is worse than a refusal.
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

    local have want_ll
    want_ll=$(lock librelane_version)
    have=$("$venv_dir/bin/python" -c \
        'from importlib.metadata import version; print(version("librelane"))' 2>/dev/null) \
        || die "$EX_PREREQ" "librelane is not installed in $venv_dir"
    [[ $have == "$want_ll" ]] || die "$EX_MISMATCH" \
        "librelane $have installed, lockfile wants $want_ll"

    info "support tools, PDK and librelane $have all match"
}

# ---------------------------------------------------------------------------
# 2. Preserve the previous run BEFORE anything destroys it.
# ---------------------------------------------------------------------------
archive_previous_run() {
    step "Preserving any previous run"

    if [[ ! -d $run_dir ]]; then
        info "no previous run to preserve"
        return
    fi

    local dest="$runs_archive/$run_tag"
    [[ ! -e $dest ]] || die "$EX_GENERAL" \
        "archive destination already exists: $dest" "Choose another --tag."

    mkdir -p "$runs_archive"
    # Same filesystem, so this is a rename rather than a copy.
    mv "$run_dir" "$dest"
    info "previous run moved to $dest"
}

# ---------------------------------------------------------------------------
# 3. Regenerate, re-stage, reconfigure
# ---------------------------------------------------------------------------
restage() {
    step "Regenerating RTL and re-staging"
    # stage-project.sh regenerates the Verilog from Hardcaml first, so what is
    # hardened is provably what the generator produces, not an edited src/.
    TT_SUPPORT_TOOLS_DIR="$TT_SUPPORT_TOOLS_DIR" "$script_dir/stage-project.sh" \
        || die "$EX_TOOL" "stage-project.sh failed"
}

reconfigure() {
    step "Regenerating the LibreLane configuration"
    # create_merged_config() resolves "src/config" relative to the process
    # working directory, so tt_tool.py must run from the project directory.
    ( cd "$stage_dir" \
      && "$venv_dir/bin/python" "$TT_SUPPORT_TOOLS_DIR/tt_tool.py" \
           --project-dir "$stage_dir" --create-user-config --ihp ) \
        || die "$EX_TOOL" "tt_tool.py --create-user-config failed"
}

# ---------------------------------------------------------------------------
# 4. The flow itself
# ---------------------------------------------------------------------------
harden() {
    step "Running mapped synthesis and place-and-route"
    info "this takes tens of minutes; the full log is written under $run_dir"

    local extra=()
    [[ $no_docker -eq 1 ]] && extra+=(--no-docker)

    ( cd "$stage_dir" \
      && "$venv_dir/bin/python" "$TT_SUPPORT_TOOLS_DIR/tt_tool.py" \
           --project-dir "$stage_dir" --ihp --harden "${extra[@]}" ) \
        || die "$EX_TOOL" "hardening failed" \
               "The run directory is preserved at $run_dir" \
               "Inspect the failing step's log there."
}

# ---------------------------------------------------------------------------
# 5. Results and the timing gate.
#
# metrics.csv is a two-column key/value file; tt-support-tools reads it with
# dict(csv.reader(fh)) at runs/wokwi/final/metrics.csv.
#
# Metric names are matched by prefix because LibreLane suffixes timing metrics
# with the corner, for example timing__setup__ws__corner:nom_typ_1p20V_25C.
# If no timing metric is found at all the script FAILS rather than passing:
# "could not verify timing" must never read as "timing passed".
# ---------------------------------------------------------------------------
report_and_gate() {
    step "Reading results and checking timing"

    local metrics="$run_dir/final/metrics.csv"
    [[ -f $metrics ]] || die "$EX_TOOL" \
        "no metrics file at $metrics" \
        "The flow reported success but produced no final metrics."

    local summary="$run_dir/harden-summary.json"

    RUN_TAG="$run_tag" \
    LOCK_PDK="$(lock pdk)" \
    LOCK_TILES="$(lock tiles)" \
    LOCK_LIBRELANE="$(lock librelane_version)" \
    SOURCE_COMMIT="$(git -C "$repo_root" rev-parse HEAD 2>/dev/null || echo unknown)" \
    SOURCE_DIRTY="$(test -n "$(git -C "$repo_root" status --porcelain 2>/dev/null)" && echo true || echo false)" \
    "$venv_dir/bin/python" - "$metrics" "$summary" <<'PY'
import csv, json, os, sys

metrics_path, summary_path = sys.argv[1], sys.argv[2]
with open(metrics_path) as fh:
    rows = {k: v for k, v in csv.reader(fh) if k}

def matching(prefix):
    return {k: v for k, v in rows.items() if k.startswith(prefix)}

def as_float(value):
    try:
        return float(value)
    except (TypeError, ValueError):
        return None

def worst(prefix):
    """Smallest numeric value among metrics whose key starts with prefix."""
    found = {k: as_float(v) for k, v in matching(prefix).items()}
    found = {k: v for k, v in found.items() if v is not None}
    if not found:
        return None, {}
    key = min(found, key=lambda k: found[k])
    return found[key], found

setup_ws, setup_all = worst("timing__setup__ws")
hold_ws, hold_all = worst("timing__hold__ws")
setup_tns, _ = worst("timing__setup__tns")

def first(*names):
    for n in names:
        if n in rows:
            return rows[n]
    return None

area = first("design__instance__area")
count = first("design__instance__count")
util = first("design__instance__utilization", "design__core__utilization")
wirelength = first("route__wirelength", "detailedroute__route__wirelength")

drc = {k: v for k, v in rows.items()
       if "drc" in k.lower() and ("error" in k.lower() or "violation" in k.lower())}

summary = {
    "run_tag": os.environ["RUN_TAG"],
    "source_commit": os.environ["SOURCE_COMMIT"],
    "source_dirty": os.environ["SOURCE_DIRTY"] == "true",
    "pdk": os.environ["LOCK_PDK"],
    "tiles": os.environ["LOCK_TILES"],
    "librelane": os.environ["LOCK_LIBRELANE"],
    "area_um2": as_float(area),
    "instance_count": as_float(count),
    "utilization": as_float(util),
    "wirelength_um": as_float(wirelength),
    "setup_ws_ns": setup_ws,
    "setup_tns_ns": setup_tns,
    "hold_ws_ns": hold_ws,
    "setup_ws_by_corner": setup_all,
    "hold_ws_by_corner": hold_all,
    "drc": drc,
}

with open(summary_path, "w") as fh:
    json.dump(summary, fh, indent=2, sort_keys=True)
    fh.write("\n")

def show(label, value, unit=""):
    print(f"    {label:<22} {'not reported' if value is None else f'{value}{unit}'}")

show("cell area", area, " um^2")
show("instances", count)
show("utilization", util)
show("wire length", wirelength, " um")
show("worst setup slack", setup_ws, " ns")
show("total negative slack", setup_tns, " ns")
show("worst hold slack", hold_ws, " ns")
for k, v in sorted(drc.items()):
    print(f"    {k:<22} {v}")

# --- the gate ---
# stdout is block-buffered when piped while stderr is not, so flush first to
# keep the measurements above the verdict rather than after it.
sys.stdout.flush()

if setup_ws is None and hold_ws is None:
    print("\nerror: no timing metric found in the flow's metrics", file=sys.stderr)
    print("       Looked for keys beginning timing__setup__ws / timing__hold__ws.",
          file=sys.stderr)
    print(f"       Confirm the metric names produced by this LibreLane release in",
          file=sys.stderr)
    print(f"       {metrics_path} and update this script.", file=sys.stderr)
    sys.exit(3)

violations = []
if setup_ws is not None and setup_ws < 0:
    violations.append(f"setup slack {setup_ws} ns")
if hold_ws is not None and hold_ws < 0:
    violations.append(f"hold slack {hold_ws} ns")
for k, v in drc.items():
    n = as_float(v)
    if n is not None and n > 0:
        violations.append(f"{k} = {v}")

if violations:
    print("\nerror: the design does not close:", file=sys.stderr)
    for v in violations:
        print(f"       {v}", file=sys.stderr)
    sys.exit(2)
PY
    local rc=$?
    case $rc in
        0) info "timing and physical checks pass" ;;
        2) die "$EX_TIMING" "the flow completed but the design does not close" \
               "Artifacts are preserved at $run_dir" \
               "Machine-readable results: $summary" ;;
        3) die "$EX_TOOL" "could not verify timing from the flow's metrics" \
               "Artifacts are preserved at $run_dir" ;;
        *) die "$EX_TOOL" "result analysis failed" ;;
    esac
    info "summary written to $summary"
}

summary_text() {
    cat <<EOF

================================================================================
Hardening complete.

  run directory     $run_dir
  summary           $run_dir/harden-summary.json
  archived previous $runs_archive/$run_tag

Next:
  Record the result:   tinytapeout/reports/  (see reports/README.md)
  Gate-level test:     make -C tinytapeout/test gate PDK_ROOT=$PDK_ROOT \\
                         NETLIST=$run_dir/final/nl/*.nl.v
  Precheck:            not yet scripted; needs the .venv-precheck environment
                       and native klayout/magic

This ran the physical flow and checked timing. It did not run DRC or LVS:
src/config.json sets RUN_KLAYOUT_DRC=0 and RUN_KLAYOUT_XOR=0, so design-rule
checking happens in precheck, not here.
================================================================================
EOF
}

main() {
    load_environment
    verify_environment
    archive_previous_run
    restage
    reconfigure
    harden
    report_and_gate
    summary_text
}

main
