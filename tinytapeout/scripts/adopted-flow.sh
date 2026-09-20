#!/usr/bin/env bash
#
# The protemu ASIC flow: the one orchestration implementation behind ./flow.sh.
#
# It drives an emitted hardcaml_asic bundle through the adopted path. Every step
# is explicit; only "run" starts LibreLane, and only "postcheck" runs physical
# postchecks. The steps themselves live in adopted_phase4.py,
# adopted_report.py and adopted_archive.py, which own their arguments and exit
# codes.
#
# ./flow.sh at the repository root is the canonical entry point and is what the
# documentation names. It is a thin wrapper: with no steps it calls this script
# with --full, and otherwise passes its steps through unchanged. The difference
# between the two spellings is the no-argument case, and only that: this script
# still prints help when called with no arguments, because it predates ./flow.sh
# and a bare invocation must not turn into a multi-hour physical run.
#
# Nothing here provisions tools. Bootstrapping is ./bootstrap.sh (or the
# "bootstrap" step, kept for the transition); the flow consumes what it left.
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
tt_dir="$repo_root/tinytapeout"
runner="$script_dir/adopted_phase4.py"
reporter="$script_dir/adopted_report.py"
archiver="$script_dir/adopted_archive.py"

# The default sequence, in order. "bootstrap" is deliberately not in it: a flow
# invocation never provisions.
readonly default_steps=(build emit preflight run postcheck collect report archive)

usage() {
    cat <<'USAGE'
Usage: ./flow.sh [STEP ...]                 (tinytapeout/scripts/adopted-flow.sh)

With no steps, ./flow.sh runs the whole adopted flow in a fresh output
directory, which includes hardening and can take hours. Name steps to run only
those, in the order given; no step ever runs an earlier one for you.

Steps:
  build       dune build and dune runtest, through the pinned opam switch
  emit        write the immutable adopted bundle into $PROTEMU_FLOW_OUT/bundle
  preflight   validate bundle, collateral, versions, image, and configuration
  run         harden: start LibreLane and create a new run under $PROTEMU_RUNS
  postcheck   TT precheck and gate-level wrapper simulation after a full run
  collect     write results.json for a run
  report      print the physical/timing summary for a run
  archive     promote the run's records and reports into flow_results/
  bootstrap   provision flow tools (transitional; prefer ./bootstrap.sh)
  --full      the default sequence above, in a fresh output directory. This is
              what ./flow.sh runs when given no steps.

Output:
  A run directory under PROTEMU_FLOW_OUT is scratch: it is ~240 MB, gitignored,
  and disposable. "archive" promotes the ~1 MB a reader actually checks into
  flow_results/<date>-<run id>/, which is kept and committed. Curate it by
  writing a README.md beside the records; re-archiving never deletes one.

  PROTEMU_FLOW_OUT holds one bundle and its runs. --full allocates a fresh one
  under tinytapeout/build/ unless PROTEMU_FLOW_OUT names the experiment; named
  steps default to tinytapeout/build/adopted. Emission refuses a bundle
  directory that already has files: choose a new PROTEMU_FLOW_OUT rather than
  deleting one.

Resuming:
  A step after "run" uses the run this invocation produced. A separate
  invocation must name it: PROTEMU_RUN=/path/to/run ./flow.sh report. The run
  directory is never guessed from the newest one under PROTEMU_RUNS.

Environment:
  PROTEMU_FLOW_OUT  output directory for this experiment
  PROTEMU_BUNDLE    the emitted bundle             ($PROTEMU_FLOW_OUT/bundle)
  PROTEMU_RUNS      run storage, one per attempt   ($PROTEMU_FLOW_OUT/runs)
  PROTEMU_RUN       an existing run, for steps after "run"
  PROTEMU_FLOW_RESULTS  kept archives, one per run        (./flow_results)
  PROTEMU_ARCHIVE   exact archive directory for this run
  PROTEMU_STAGE     full | synthesis, how far "run" goes             (full)
  PROTEMU_DESIGN    observable | memory, bundle design          (observable)
  PROTEMU_TT        tt-support-tools checkout
  PROTEMU_PDK_ROOT  PDK root (IHP sg13cmos5l)
  PROTEMU_FLOW_PY   python of the LibreLane venv
  PROTEMU_PRECHECK_PY  python of the TT precheck venv
  PROTEMU_ALLOW_PYTHON_MISMATCH  0 to require the bundle's exact minor  (1)
  Collateral defaults come from this repository's bootstrap.

PROTEMU_STAGE=synthesis stops after mapped synthesis. Use it with
"build emit preflight run collect report": postcheck needs a completed full
run, and mapped synthesis alone is not physical closure.
USAGE
}

# Help and step validation come before anything that reads the environment, so
# --help answers on a machine with no OCaml and no flow toolchain.
full=0
if [[ $# -eq 0 ]]; then usage; exit 0; fi
if [[ $1 == --full ]]; then
    full=1
    shift
    if [[ $# -gt 0 ]]; then
        echo "flow: --full is the whole default sequence; it takes no steps" >&2
        exit 2
    fi
    set -- "${default_steps[@]}"
fi
for step in "$@"; do
    case $step in
        build|emit|preflight|run|postcheck|collect|report|archive|bootstrap) ;;
        -h|--help) usage; exit 0 ;;
        *) echo "flow: unknown step: $step (try --help)" >&2; exit 2 ;;
    esac
done

# Output location. A full run with nothing chosen gets a fresh directory, so two
# of them never land in one bundle; named steps keep the fixed default, which is
# what makes "./flow.sh postcheck collect report" find yesterday's work.
mkdir -p "$tt_dir/build"
if [[ -n ${PROTEMU_FLOW_OUT:-} ]]; then
    out=$PROTEMU_FLOW_OUT
elif [[ $full -eq 1 ]]; then
    out=$(mktemp -d "$tt_dir/build/flow-$(date +%Y%m%d-%H%M%S)-XXXXXX")
else
    out=$tt_dir/build/adopted
fi
bundle=${PROTEMU_BUNDLE:-$out/bundle}
runs=${PROTEMU_RUNS:-$out/runs}
run_dir=${PROTEMU_RUN:-}
for name in out bundle runs run_dir; do
    value=${!name}
    if [[ -n $value && $value != /* ]]; then printf -v "$name" '%s' "$PWD/$value"; fi
done
allow_python_mismatch=${PROTEMU_ALLOW_PYTHON_MISMATCH:-1}

mismatch_args=()
case $allow_python_mismatch in
    0) ;;
    1) mismatch_args=(--allow-python-mismatch) ;;
    *) echo "flow: PROTEMU_ALLOW_PYTHON_MISMATCH must be 0 or 1" >&2; exit 2 ;;
esac

say() { printf '\n== %s\n' "$*" >&2; }

# ---------------------------------------------------------------------------
# Summary. Whatever happens, the last thing printed is how long each step took
# and where its records are, because a seven-step flow's scrollback is not a
# place to go looking for either.
# ---------------------------------------------------------------------------
step_names=()
step_seconds=()

# 1h 02m 03s / 23m 47s / 12s: the leading unit is dropped until it is nonzero,
# because a seven-hour hardening run and a one-second collect share this column.
format_duration() {
    local total=$1
    if [[ $total -ge 3600 ]]; then
        printf '%dh %02dm %02ds' $((total / 3600)) $((total % 3600 / 60)) $((total % 60))
    elif [[ $total -ge 60 ]]; then
        printf '%dm %02ds' $((total / 60)) $((total % 60))
    else
        printf '%ds' "$total"
    fi
}

# A path is listed only when it exists: a failed run has no results.json, and
# naming a file that was never written reads as an instruction to go open it.
summary_path() {
    [[ -e $2 ]] || return 0
    printf '  %-18s %s\n' "$1" "$2" >&2
}

summary() {
    local status=$1
    [[ ${#step_names[@]} -gt 0 ]] || return 0

    say "summary"
    local index
    for index in "${!step_names[@]}"; do
        if [[ ${step_seconds[index]} -lt 0 ]]; then
            printf '  %-18s %10s\n' "${step_names[index]}" 'did not finish' >&2
        else
            printf '  %-18s %10s\n' "${step_names[index]}" \
                "$(format_duration "${step_seconds[index]}")" >&2
        fi
    done
    printf '  %-18s %10s\n' 'end to end' "$(format_duration $SECONDS)" >&2

    printf '\n' >&2
    summary_path 'output' "$out"
    summary_path 'bundle' "$bundle"
    summary_path 'preflight' "$out/preflight.json"
    if [[ -n $run_dir ]]; then
        summary_path 'run' "$run_dir"
        summary_path 'run record' "$run_dir/run.json"
        summary_path 'execution log' "$run_dir/execution.log"
        summary_path 'results' "$run_dir/results.json"
        summary_path 'flow outputs' "$run_dir/project/runs/asic"
        local check
        for check in "$run_dir"/checks/*/; do
            summary_path 'postcheck' "${check}postcheck.json"
            summary_path 'postcheck log' "${check}postcheck.log"
            summary_path 'precheck reports' "${check}tt/precheck/reports/results.md"
        done
    fi
    [[ -z $archive_dir ]] || summary_path 'archive' "$archive_dir"

    if [[ -n $failed_step ]]; then
        printf '\n  %s\n' "failed at step: $failed_step" >&2
    fi
    printf '  %s\n' "exit status $status" >&2
}

failed_step=
archive_dir=

# Ctrl-C and SIGTERM during a hardening run are ordinary: the run directory is
# still evidence. Print the summary, then re-raise with the default handler so
# the caller sees the conventional 128+n rather than a status we invented.
on_signal() {
    local signal=$1
    trap - EXIT "$signal"
    [[ -n $failed_step ]] || failed_step="${step_names[-1]:-} (interrupted by SIG$signal)"
    summary $((128 + $2))
    kill -s "$signal" $$
}
trap 'on_signal INT 2' INT
trap 'on_signal TERM 15' TERM
trap 'summary $?' EXIT

# Every step goes through here, so the summary has a row even for the step that
# failed: its duration is how long it ran before giving up.
run_step() {
    local step=$1 started=$SECONDS status=0
    step_names+=("$step")
    step_seconds+=(-1)
    "step_$step" || status=$?
    step_seconds[${#step_seconds[@]} - 1]=$((SECONDS - started))
    if [[ $status -ne 0 ]]; then failed_step=$step; fi
    return "$status"
}

# ---------------------------------------------------------------------------
# Steps
# ---------------------------------------------------------------------------

# Dune goes through with-switch.sh rather than a bare `dune`, so the flow works
# in a shell that never sourced env.sh. Nothing after "emit" needs OCaml at all.
dune_() {
    (cd "$repo_root" && "$repo_root/scripts/with-switch.sh" dune "$@")
}

load_toolchain() {
    local env_file="$tt_dir/build/toolchain-env.sh"
    if [[ -f $env_file ]]; then
        # Generated by this repository's bootstrap, never by a sibling checkout.
        # shellcheck disable=SC1090
        source "$env_file"
    fi
    tool_tt=${PROTEMU_TT:-${TT_SUPPORT_TOOLS_DIR:-$tt_dir/tt}}
    tool_pdk=${PROTEMU_PDK_ROOT:-${PDK_ROOT:-$tt_dir/pdk}}
    tool_python=${PROTEMU_FLOW_PY:-$repo_root/.venv/bin/python}
    tool_precheck_python=${PROTEMU_PRECHECK_PY:-$repo_root/.venv-precheck/bin/python}
    if [[ ! -d $tool_tt || ! -d $tool_pdk || ! -x $tool_python ]]; then
        echo "flow: flow tools are not provisioned; run ./bootstrap.sh" >&2
        echo "flow: (./bootstrap.sh --check names what is missing)" >&2
        echo "flow: or set PROTEMU_TT, PROTEMU_PDK_ROOT, and PROTEMU_FLOW_PY" >&2
        return 2
    fi
}

need_run() {
    if [[ -z $run_dir || ! -f $run_dir/run.json ]]; then
        echo "flow: set PROTEMU_RUN to the run directory printed by 'run'" >&2
        echo "flow: runs are under $runs; the newest is not assumed to be yours" >&2
        return 2
    fi
}

step_bootstrap() {
    say "provision flow tools"
    "$script_dir/bootstrap-toolchain.sh" --adopted-only
}

step_build() {
    say "build and tests"
    dune_ build || return $?
    dune_ runtest
}

step_emit() {
    say "emit bundle into $bundle"
    # Bundle.write refuses a nonempty directory. Say so here rather than letting
    # the emitter fail with its own message partway down a seven-step run.
    if [[ -d $bundle && -n $(ls -A "$bundle" 2>/dev/null) ]]; then
        echo "flow: bundle is not empty: $bundle" >&2
        echo "flow: choose a new PROTEMU_FLOW_OUT" >&2
        return 2
    fi
    mkdir -p "$out"
    dune_ build bin/asic_bundle.exe || return $?
    local design=${PROTEMU_DESIGN:-observable}
    [[ $design == observable || $design == memory ]] || {
        echo "flow: PROTEMU_DESIGN must be observable or memory" >&2; return 2;
    }
    "$repo_root/_build/default/bin/asic_bundle.exe" "$design" "$bundle" "$repo_root"
}

step_preflight() {
    load_toolchain || return $?
    say "preflight"
    mkdir -p "$out"
    # --output as well as stdout: the preflight report is the record of why this
    # run was allowed to start, and scrollback does not survive as evidence.
    python3 "$runner" preflight "$bundle" \
        --support-tools "$tool_tt" --pdk-root "$tool_pdk" \
        --python "$tool_python" "${mismatch_args[@]}" \
        --output "$out/preflight.json"
}

step_run() {
    load_toolchain || return $?
    local stage=${PROTEMU_STAGE:-full} record status=0
    [[ $stage == full || $stage == synthesis ]] || {
        echo "flow: PROTEMU_STAGE must be full or synthesis" >&2; return 2;
    }
    mkdir -p "$runs"
    say "run --stage $stage (hardening; this is the long one)"
    echo "flow: results will be under $runs" >&2
    # adopted_phase4.py sends LibreLane's output to the run's execution.log and
    # prints the run.json path as its last stdout line, on failure too.
    record=$(python3 "$runner" run "$bundle" \
        --support-tools "$tool_tt" --pdk-root "$tool_pdk" \
        --python "$tool_python" "${mismatch_args[@]}" \
        --runs "$runs" --stage "$stage") || status=$?
    record=${record##*$'\n'}
    if [[ -f $record ]]; then
        run_dir=$(dirname "$record")
        # The one record phase4 cannot write itself: preflight ran before the run
        # directory existed. Copying it in makes the attempt self-contained.
        [[ ! -f $out/preflight.json ]] || cp "$out/preflight.json" "$run_dir/preflight.json"
        echo "flow: run directory $run_dir" >&2
    else
        echo "flow: no run record returned: $record" >&2
    fi
    return "$status"
}

step_postcheck() {
    need_run || return $?
    load_toolchain || return $?
    [[ -x $tool_precheck_python ]] || {
        echo "flow: precheck Python missing: $tool_precheck_python" >&2; return 2;
    }
    say "postcheck: TT precheck and gate-level simulation"
    python3 "$runner" postcheck "$run_dir" \
        --support-tools "$tool_tt" --pdk-root "$tool_pdk" \
        --precheck-python "$tool_precheck_python" \
        --testbench "$tt_dir/test/tb.v"
}

# collect and report read recorded artifacts with the system python3 only. They
# work on a failed run, and on a machine with no opam switch and no PDK, which
# is what makes an old run inspectable from anywhere.
step_collect() {
    need_run || return $?
    say "collect"
    python3 "$runner" collect "$run_dir" --output "$run_dir/results.json" || return $?
    echo "flow: results $run_dir/results.json" >&2
}

step_report() {
    need_run || return $?
    say "report"
    python3 "$reporter" "$run_dir"
}

# The run directory is scratch and gitignored; this is what makes a finished run
# survive it. The destination is named from the run's own start time and id
# rather than from anything this invocation chose, so archiving the same run
# twice lands in the same place and a directory name sorts chronologically.
# --force replaces the files this writes and nothing else: a curated README.md
# beside them is left alone.
step_archive() {
    need_run || return $?
    local results=${PROTEMU_FLOW_RESULTS:-$repo_root/flow_results}
    local dest=${PROTEMU_ARCHIVE:-} name
    if [[ -z $dest ]]; then
        name=$(python3 - "$run_dir/run.json" <<'PY'
import json, sys
record = json.load(open(sys.argv[1]))
stamp = record["started_at"][:19].replace("-", "").replace(":", "").replace("T", "-")
print(f'{stamp}-{record["run_id"][:8]}')
PY
        ) || return $?
        dest=$results/$name
    fi
    [[ $dest == /* ]] || dest=$PWD/$dest
    say "archive into $dest"
    python3 "$archiver" "$run_dir" --output "$dest" --force || return $?
    archive_dir=$dest
    echo "flow: archive $dest" >&2
}

echo "flow: output directory $out" >&2
for step in "$@"; do run_step "$step"; done
