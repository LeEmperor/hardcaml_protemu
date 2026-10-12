#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

mkdir -p _build/p3.4-cli
./scripts/with-switch.sh dune exec -j 5 protemu -- sim write-echo-image \
  -output _build/p3.4-cli/p3.4-echo.pimg
cmp examples/p3.4-echo.pimg _build/p3.4-cli/p3.4-echo.pimg
./scripts/with-switch.sh dune exec -j 5 protemu -- sim script \
  examples/p3.4-workflow.sim -trace-capacity 8
./scripts/with-switch.sh dune exec -j 5 protemu -- sim script \
  examples/p3.4-transfer-timeout.sim >_build/p3.4-cli/p3.4-transfer-timeout.output
cmp test/integration/host_simulator/p3.4-transfer-timeout.expected \
  _build/p3.4-cli/p3.4-transfer-timeout.output
