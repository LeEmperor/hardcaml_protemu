#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/../.." && pwd)
output="$repo_root/tinytapeout/src/p0_observable.v"

cd "$repo_root"
dune exec bin/generate.exe -- -output "$output" -module-name p0_observable
