#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/../.." && pwd)

cd "$repo_root"
# Taken before the dune build so a check started during hardening fails at once
# instead of after the build. stage-project.sh inherits it.
# shellcheck source=stage-lock.sh
source "$repo_root/tinytapeout/scripts/stage-lock.sh"
acquire_stage_lock "$repo_root" || exit 1

# runtest: Hardcaml tests, plus committed RTL matches deterministic generation
#          (tinytapeout/src/dune).
# rtl:     wrapper simulation, Verilator lint, generic Yosys synthesis
#          (tinytapeout/test/dune).
dune build @all @runtest @rtl
"$repo_root/tinytapeout/scripts/stage-project.sh"

echo "PASS deterministic generation, Hardcaml tests, wrapper RTL simulation, lint, and generic synthesis"
