#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/../.." && pwd)

cd "$repo_root"
# runtest: Hardcaml tests, plus committed RTL matches deterministic generation
#          (tinytapeout/src/dune).
# rtl:     wrapper simulation, Verilator lint, generic Yosys synthesis
#          (tinytapeout/test/dune).
dune build @all @runtest @rtl
"$repo_root/tinytapeout/scripts/stage-project.sh"

echo "PASS deterministic generation, Hardcaml tests, wrapper RTL simulation, lint, and generic synthesis"
