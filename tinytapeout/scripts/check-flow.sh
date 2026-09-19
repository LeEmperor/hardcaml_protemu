#!/usr/bin/env bash
#
# Orchestration checks for ./flow.sh: argument handling, output allocation,
# failure propagation, the summary, and signal handling.
#
#   tinytapeout/scripts/check-flow.sh
#
# Nothing here implements anything. Dune is replaced by a stub opam that either
# fails or sleeps, so a failed or interrupted flow can be exercised in seconds
# and repeatedly; the checks that need real tools are the flow's own steps and
# the end-to-end smoke run, not this. Everything is written under a temporary
# directory that is removed on exit.
set -uo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
flow="$repo_root/flow.sh"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/protemu-check-flow-XXXXXX")
trap 'rm -rf "$tmp"' EXIT

failures=0
checked=0

# Every check compares an exit status and, optionally, text that must appear in
# the combined output. A failure prints the whole output: which of forty lines
# was missing is the only useful thing to say about it.
expect() {
    local name=$1 want_status=$2 output=$3 status=$4
    shift 4
    checked=$((checked + 1))
    local problem=""
    [[ $status -eq $want_status ]] \
        || problem="exit status $status, expected $want_status"
    local text
    for text in "$@"; do
        [[ $output == *"$text"* ]] || problem="output does not contain: $text"
    done
    if [[ -n $problem ]]; then
        failures=$((failures + 1))
        printf 'FAIL %s\n     %s\n' "$name" "$problem"
        printf '%s\n' "$output" | sed 's/^/     | /'
    else
        printf 'ok   %s\n' "$name"
    fi
}

# A stub opam standing in for the pinned switch. MODE picks what `dune` does:
# "fail" for a failing step, "sleep" for one long enough to interrupt.
mkdir -p "$tmp/stub"
cat >"$tmp/stub/opam" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "switch list") echo "${OPAM_SWITCH:-5.2.0+ox}"; exit 0 ;;
esac
shift 3   # opam exec --switch=... --
case "${STUB_MODE:-fail}" in
  sleep) sleep 10 ;;
  *) echo "stub dune: $*" >&2; exit 1 ;;
esac
STUB
chmod +x "$tmp/stub/opam"
stub_path="$tmp/stub:$PATH"

# ---------------------------------------------------------------------------
# Help and argument handling, on a machine with no toolchain at all. env -i
# drops the environment: no opam switch, no PROTEMU_*, no VIRTUAL_ENV.
# ---------------------------------------------------------------------------
out=$(env -i PATH=/usr/bin:/bin HOME="$tmp" "$flow" --help 2>&1); status=$?
expect "--help works with no OCaml and no flow toolchain" 0 "$out" $status \
    "Usage: ./flow.sh" "PROTEMU_RUN" "Resuming:"

out=$(env -i PATH=/usr/bin:/bin HOME="$tmp" "$script_dir/adopted-flow.sh" 2>&1); status=$?
expect "the runner still prints help when called with no steps" 0 "$out" $status \
    "Usage: ./flow.sh"

out=$("$flow" bogus 2>&1); status=$?
expect "an unknown step is rejected before any work" 2 "$out" $status \
    "unknown step: bogus"

out=$("$flow" --full run 2>&1); status=$?
expect "--full takes no steps" 2 "$out" $status "takes no steps"

# Run from another directory: the repository, not the working directory, decides
# where artifacts are looked for.
out=$(cd / && "$flow" report 2>&1); status=$?
expect "invocation from another directory resolves this repository" 2 "$out" $status \
    "$repo_root/tinytapeout/build/adopted"

# ---------------------------------------------------------------------------
# Resuming. A separate invocation names its run; it is never guessed.
# ---------------------------------------------------------------------------
out=$(PROTEMU_FLOW_OUT="$tmp/no-run" "$flow" report 2>&1); status=$?
expect "report without PROTEMU_RUN refuses rather than guessing" 2 "$out" $status \
    "set PROTEMU_RUN" "not assumed to be yours"

mkdir -p "$tmp/no-run/runs/decoy"
out=$(PROTEMU_FLOW_OUT="$tmp/no-run" "$flow" collect 2>&1); status=$?
expect "an existing run directory is not adopted by accident" 2 "$out" $status \
    "set PROTEMU_RUN"

# An existing run is reportable with no switch, no PDK and no PROTEMU_*: env -i
# leaves the system python3 and the recorded artifacts, which is all collect and
# report may need. The record here is a stub, so the reporter's own verdict is not
# the check; reaching it is.
mkdir -p "$tmp/existing-run"
printf '%s\n' '{"schema_version": 1, "status": "failed", "run_id": "stub"}' \
    >"$tmp/existing-run/run.json"
out=$(env -i PATH=/usr/bin:/bin HOME="$tmp" PROTEMU_RUN="$tmp/existing-run" \
    "$flow" report 2>&1); status=$?
checked=$((checked + 1))
if [[ $out == *"set PROTEMU_RUN"* || $out != *"== report"* ]]; then
    failures=$((failures + 1))
    printf 'FAIL %s\n' "reporting an existing run needs no OCaml tooling"
    printf '%s\n' "$out" | sed 's/^/     | /'
else
    printf 'ok   %s\n' "reporting an existing run needs no OCaml tooling"
fi

# ---------------------------------------------------------------------------
# Output allocation and emission
# ---------------------------------------------------------------------------
mkdir -p "$tmp/occupied/bundle"
: >"$tmp/occupied/bundle/manifest.json"
out=$(PROTEMU_FLOW_OUT="$tmp/occupied" "$flow" emit 2>&1); status=$?
expect "emit refuses a bundle that already has files" 2 "$out" $status \
    "bundle is not empty" "choose a new PROTEMU_FLOW_OUT"
if [[ ! -f $tmp/occupied/bundle/manifest.json ]]; then
    failures=$((failures + 1))
    printf 'FAIL %s\n' "emit left the existing bundle in place"
fi

# A default full invocation allocates its own directory. The build step fails
# here, which is the point twice over: the allocation is visible, and nothing
# after it runs.
first=$(PATH="$stub_path" "$flow" 2>&1); status=$?
expect "the default invocation allocates a fresh output directory" 1 "$first" $status \
    "$repo_root/tinytapeout/build/flow-" "failed at step: build"
expect "a failed stage stops the ones that depend on it" 1 "$first" $status \
    "end to end"
for later in "emit bundle into" "preflight" "starting LibreLane" "results will be under"; do
    if [[ $first == *"$later"* ]]; then
        failures=$((failures + 1))
        printf 'FAIL %s\n' "a later stage ran after build failed: $later"
    fi
done
checked=$((checked + 1))

second=$(PATH="$stub_path" "$flow" 2>&1)
allocated() { printf '%s\n' "$1" | sed -n 's/^flow: output directory //p'; }
first_dir=$(allocated "$first")
second_dir=$(allocated "$second")
checked=$((checked + 1))
if [[ -z $first_dir || $first_dir == "$second_dir" ]]; then
    failures=$((failures + 1))
    printf 'FAIL %s\n     %s\n' "two default invocations collide" \
        "both allocated ${first_dir:-nothing}"
else
    printf 'ok   %s\n' "two default invocations get different output directories"
fi
rmdir "$first_dir" "$second_dir" 2>/dev/null

# ---------------------------------------------------------------------------
# Signals. An interrupted flow keeps its failure status and still says where its
# diagnostics are.
# ---------------------------------------------------------------------------
log="$tmp/interrupt.log"
PATH="$stub_path" STUB_MODE=sleep PROTEMU_FLOW_OUT="$tmp/interrupted" \
    "$flow" build >"$log" 2>&1 &
flow_pid=$!
sleep 1
kill -TERM "$flow_pid"
wait "$flow_pid"; status=$?
expect "an interrupted flow reports the signal and fails" 143 "$(cat "$log")" $status \
    "did not finish" "interrupted by SIGTERM" "exit status 143"

# ---------------------------------------------------------------------------
printf '\n%d checks, %d failures\n' "$checked" "$failures"
[[ $failures -eq 0 ]] || exit 1
