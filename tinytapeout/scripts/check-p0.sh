#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/../.." && pwd)
tmp_dir=$(mktemp -d /tmp/scaf-p0-check.XXXXXX)
trap 'rm -rf "$tmp_dir"' EXIT

cd "$repo_root"
dune build @all
dune runtest
dune exec bin/generate.exe -- -output "$tmp_dir/first.v" -module-name p0_observable
dune exec bin/generate.exe -- -output "$tmp_dir/second.v" -module-name p0_observable
cmp "$tmp_dir/first.v" "$tmp_dir/second.v"
cmp "$tmp_dir/first.v" tinytapeout/src/p0_observable.v
make -C tinytapeout/test rtl
verilator --lint-only --top-module tt_um_leemperor_hardcaml_protemu \
    -Wno-DECLFILENAME \
    tinytapeout/src/p0_observable.v tinytapeout/src/project.v
yosys -q -p \
    "read_verilog tinytapeout/src/p0_observable.v tinytapeout/src/project.v; hierarchy -check -top tt_um_leemperor_hardcaml_protemu; synth -top tt_um_leemperor_hardcaml_protemu; stat"
"$repo_root/tinytapeout/scripts/stage-project.sh"

echo "PASS deterministic generation, Hardcaml tests, wrapper RTL simulation, lint, and generic synthesis"
