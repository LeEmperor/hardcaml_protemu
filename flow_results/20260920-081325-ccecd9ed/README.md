# P0.5c clean-staging adopted physical reproduction, 2026-09-20

The committed protemu observable design was restored outside the active consumer
tree, built against its locked `hardcaml_asic` revision through an isolated
package prefix, emitted without dirty inputs, and completed the full adopted
physical flow in one attempt. Build identity
`85729c18ca404a4b45dd8b1e97ea5833ad3677614b2064b222b38e9c17f575fe`
links to run ID `ccecd9edc8e342b2b28f1a88d5c4e7ac` through
[`run.json`](run.json). This is the clean-staging evidence for `hardcaml_asic`
P5.4.

## Inputs and environment

- Consumer: clean detached worktree at
  `8d3ada1571e07ff21e4c8707dcc3ce917d6037b3`. That revision was selected because
  it was current protemu HEAD when staging began and is the requested P5.3
  implementation/evidence cleanup commit. All eight manifest `source_inputs`
  have empty `git_status`.
- Library: clean detached source at the consumer lock's
  `a257424c3ae31fd6ee10cea052cc7577f15d2677`, installed to a fresh isolated
  prefix. `OCAMLPATH` resolved that prefix rather than the shared opam path pin,
  which points at the active sibling worktree.
- Target: Tiny Tapeout `6x4`, IHP `ihp-sg13cmos5l`, 48 MHz. Support tools are
  `da63c9927411e3aca350977d653d24bbf5bca972`; IHP Open PDK is
  `2bbec755dc67ca3db0261c3d6163e15735d66710`.
- Consumer lock collateral also records template `b86a2a781484bcab7ba522dc5de540086695a430`
  and GDS action `3412659307918422f3f0727917cf9b499aaca588`; the 6x4 floorplan
  hash is `b46d9a0ee8352160e48dbc8312f092f985629061df736c7f46d58686535a76f4`.
  The support-tools checkout was clean. The PDK resolved the locked revision and
  passed bootstrap/preflight view hashes; it contained the bootstrap-generated
  untracked `ihp-sg13cmos5l/SOURCES` marker.
- LibreLane: `3.1.0.dev3`, Docker image
  `sha256:d109140b8f17fc54f4fca998beb8124f4949404ec52e339eebd2250854a18b5a`;
  Docker server 29.8.1; host flow Python 3.12.3; container Python 3.13.13.
- Version waiver: the bundle requests Python 3.11. The already provisioned and
  validated host/container versions above were accepted with
  `PROTEMU_ALLOW_PYTHON_MISMATCH=1`; both differences are recorded in
  [`preflight.json`](preflight.json). TT precheck used KLayout 0.30.4, its
  Python environment used KLayout 0.28.17.post1, gate simulation used Icarus
  13.0, adoption lint used Verilator 5.046, synthesis used Yosys 0.66
  (`86f2ddebce`), and precheck ran through Nix 2.18.1.
- Source sets are one generated module each and were never mixed: synthesis
  `src/tt_um_leemperor_hardcaml_protemu.v` and simulation
  `simulation/tt_um_leemperor_hardcaml_protemu.v`, both SHA-256
  `c275808a7279c617c460c3706cdfd69c0d580b7c3356ec224b66d8730b7b0cb1`.
  `ocamlfind query` resolved the isolated prefix; its installed package matched
  the locked source's `@install` output except for `dune-package` rewriting its
  section paths to the absolute install prefix.

The staging paths were `/tmp/opencode/p54-scaf-8d3ada1-20260920` and
`/tmp/opencode/hardcaml-asic-a257`; the isolated prefix was
`/tmp/opencode/p54-hardcaml-prefix-a257424-20260920`. These paths are historical
execution details, not restoration dependencies.

The relevant setup was:

```sh
git -C /home/wayne/devel/jane/scaf worktree add --detach \
  /tmp/opencode/p54-scaf-8d3ada1-20260920 \
  8d3ada1571e07ff21e4c8707dcc3ce917d6037b3
(cd /tmp/opencode/hardcaml-asic-a257 && \
  opam exec --switch=5.2.0+ox -- dune build @install)
(cd /tmp/opencode/hardcaml-asic-a257 && \
  opam exec --switch=5.2.0+ox -- dune install \
    --prefix /tmp/opencode/p54-hardcaml-prefix-a257424-20260920 hardcaml_asic)

export OCAMLPATH=/tmp/opencode/p54-hardcaml-prefix-a257424-20260920/lib
export PROTEMU_DESIGN=observable PROTEMU_STAGE=full
export PROTEMU_FLOW_OUT=/tmp/opencode/p54-scaf-8d3ada1-20260920/tinytapeout/build/p54-clean-observable-20260920
export PROTEMU_TT=/home/wayne/devel/jane/scaf/tinytapeout/tt
export PROTEMU_PDK_ROOT=/home/wayne/devel/jane/scaf/tinytapeout/pdk
export PROTEMU_FLOW_PY=/home/wayne/devel/jane/scaf/.venv/bin/python
export PROTEMU_PRECHECK_PY=/home/wayne/devel/jane/scaf/.venv-precheck/bin/python
export PROTEMU_ALLOW_PYTHON_MISMATCH=1
```

The commands, in order, were:

```sh
./flow.sh build
python3 tinytapeout/scripts/check-adopted-bundle.py --kind observable
./flow.sh emit preflight
./flow.sh run
PROTEMU_RUN="$PROTEMU_FLOW_OUT/runs/ccecd9edc8e342b2b28f1a88d5c4e7ac" \
  ./flow.sh postcheck collect report archive
```

[`build.log`](build.log), [`adoption-check.log`](adoption-check.log),
[`emit-preflight.log`](emit-preflight.log), [`run-driver.log`](run-driver.log),
and [`postcheck-driver.log`](postcheck-driver.log) preserve the command results.
No generated RTL, configuration, SDC, metadata, manifest, or flow input was
edited.

## Acceptance result

LibreLane completed the full flow in 26m50s; postcheck took 8m24s. The existing
reporter returned `all reported checks passed`.

- STA passes all reported modes: worst setup slack is +15.589 ns at
  `nom_slow_1p08V_125C`; worst hold slack is +0.147 ns at
  `nom_fast_1p32V_m40C`. Fast, slow, and typical corners report zero setup/hold
  violations, and their final `checks.rpt` files report no unconstrained paths
  or max-slew/max-cap/max-fanout violations.
- Yosys mapped 94 standard cells at 1,319.031 um^2. Inferred latches, synthesis
  check errors, and unmapped instances are all zero. Final standard-cell area is
  2,228.08 um^2 at 0.247% utilization.
- Antenna nets/pins, routed DRC, Magic DRC, and LVS error counts are zero.
  LibreLane's declared `RUN_KLAYOUT_DRC=0` avoids duplicate coverage; TT
  precheck supplied KLayout SG13CMOS5L DRC coverage and passed all nine rows
  with zero report items.
- Gate-level simulation compiled the final netlist against the observable
  [`tinytapeout/test/tb.v`](../../tinytapeout/test/tb.v), printed `PASS p0
  wrapper reset/disable/pin/timer trace`, and finished at 144000 ps. Testbench
  SHA-256 is `377c79829755c4e75e2370261112f8fb87ed954c5c0e81b837f09eeccf661dee`.

The pinned synthesis log repeats the known ABC cell/pin lookup diagnostic for
`sg13cmos5l_buf_4/X`. Mapping still completed with the counts above. That ABC
print is not used as timing evidence; the accepted timing values come from the
three post-route OpenSTA reports archived in [`reports.tar.gz`](reports.tar.gz).

## Preservation and restoration

The standard archive contains the records, execution/postcheck logs, synthesis
reports, three-corner post-route STA, final GDS/netlist/SDC, TT-precheck reports,
and the exact copied observable testbench. Because it intentionally omits the
original generated RTL and source-input copies,
[`input-bundle.tar.gz`](input-bundle.tar.gz) preserves the complete immutable
bundle separately.

Key SHA-256 values:

| Artifact | SHA-256 |
| --- | --- |
| `input-bundle.tar.gz` | `a159f110b25f88d649a317425ac8d5a736bb6ef80c56ad530fab793cb7bb5da3` |
| `reports.tar.gz` | `6f8ba879a1c1db10c0bef7ed6ff3faea202b488ddc3058c6835890dcc5019d51` |
| `manifest.json` | `adc6edfd3ba8b34edd799b0c31f76bb5f477f128447ebc2ab255be7abe7ab922` |
| final GDS | `55e2ab218a4cef0bd402508506f93b9be5e4071999d524f90289f3ec0db0d878` |
| final netlist | `7931a2d02dfb1a5c1ae97e9758309911a3f077ca224c3145e68973156f0061c8` |
| observable testbench | `377c79829755c4e75e2370261112f8fb87ed954c5c0e81b837f09eeccf661dee` |

Restore independently of the scratch experiment:

```sh
mkdir /tmp/protemu-p54-bundle
tar -xzf input-bundle.tar.gz -C /tmp/protemu-p54-bundle
python3 ../../tinytapeout/scripts/adopted_phase4.py preflight \
  /tmp/protemu-p54-bundle/bundle \
  --support-tools /path/to/tt-support-tools \
  --pdk-root /path/to/IHP-Open-PDK \
  --python /path/to/librelane-venv/bin/python \
  --allow-python-mismatch
```

The restoration performed for this record reproduced every manifest file hash,
an empty `git_status` for every source input, identity `85729c18...`, manifest
hash `adc6edfd...`, and the link to run `ccecd9ed...`; restored preflight was
`ready: true`. See [`restored-preflight.json`](restored-preflight.json),
[`restore-preflight.log`](restore-preflight.log), and
[`restore-validation.log`](restore-validation.log). The consumer source and
original testbench are also retrievable from committed revision
`8d3ada1571e07ff21e4c8707dcc3ce917d6037b3`.

## Comparison with the prior run

The 2026-09-18 P0.5b run remains useful physical evidence, but its five dirty or
untracked declared inputs prevent revision-only restoration. This run starts
from committed protemu `8d3ada1`, pins the newer locked library `a257424`, and
preserves the complete input bundle. Its identity therefore changes from
`5edf30f9...` to `85729c18...`, and its run ID changes from `05f65042...` to
`ccecd9ed...`.

The generated RTL, final netlist, observable testbench, mapped counts/area,
final area/utilization, timing values, and every verdict are unchanged. The GDS
hash changed between independent physical executions (`752bb8eb...` to
`55e2ab21...`); this record does not claim byte-reproducible physical output and
pins the accepted result by its new hash. The provenance change is intentional:
unlike the prior build identity, this one describes a committed clean source
state and an independently restorable input bundle.
