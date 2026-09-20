# P0.7 registered-memory synthesis

This archive is synthesis-only evidence for protemu P0.7 / `hardcaml_asic` P5.3.
It is not a physical run, timing result, SRAM result, or clean-tree reproduction.

## Identity and configuration

- Consumer revision: `fbe0a982fce99fe4cb1718167445ad496d46bde2` with declared
  inputs dirty as recorded in [`manifest.json`](manifest.json):
  `bin/asic_bundle.ml`, `bin/dune`, and `lib/protocol_core.ml`.
- Build identity: `7ce444837068766c01129de10ab2b2f45688a2103e7edc7e9578c9b23ff97ba3`.
- Run ID: `a538212c80fb407bb01fd904b7081702`.
- Library pin: `hardcaml_asic` `a257424c3ae31fd6ee10cea052cc7577f15d2677`,
  built into an isolated prefix and selected through `OCAMLPATH`.
- Memory resource: `program`, 256x16 whole-word 1RW, latency one, hold on
  disable, unspecified output after writes, explicit `Flops` / `Explicit_flops`.
- Flow: LibreLane `3.1.0.dev3`, Yosys `0.66`, IHP CMOS5L PDK
  `2bbec755dc67ca3db0261c3d6163e15735d66710`, support tools
  `da63c9927411e3aca350977d653d24bbf5bca972`.

## Result

[`results.json`](results.json) records a completed `Yosys.Synthesis` stage:

- 16,294 mapped standard cells.
- 349,314.9408 um^2 mapped standard-cell area.
- 205,557.0048 um^2 sequential-cell area.
- 4,196 `sg13cmos5l_dfrbpq_1` cells.
- Zero inferred latches, synthesis-check errors, and unmapped instances.

The standard physical reporter returned nonzero because setup/hold, antenna,
DRC, and LVS are correctly unavailable in a synthesis-only run. No checks were
weakened and no physical result is claimed. `archive.json` records the absent
physical artifacts explicitly.

## Commands

```sh
OCAMLPATH=/tmp/opencode/asic-prefix-a257-pinned/lib \
  PROTEMU_DESIGN=memory PROTEMU_STAGE=synthesis \
  PROTEMU_FLOW_OUT="$PWD/tinytapeout/build/p0.7-memory-synthesis-20260920-1" \
  ./flow.sh build emit preflight run collect report

PROTEMU_RUN="$PWD/tinytapeout/build/p0.7-memory-synthesis-20260920-1/runs/a538212c80fb407bb01fd904b7081702" \
  PROTEMU_ARCHIVE="$PWD/flow_results/20260920-071538-a538212c" \
  ./flow.sh archive
```

The run record contains the exact LibreLane invocation and environment; the
archive verifies the staged manifest hash and preserves the raw synthesis
reports and netlist in `reports.tar.gz`.

## Complete input bundle

[`input-bundle.tar.gz`](input-bundle.tar.gz) is a separate, manually added
evidence artifact containing the complete original `bundle/`, including both
generated RTL source sets, configuration, SDC, metadata, manifest, and all eight
copied source inputs. It is deliberately not listed in `archive.json`: the
existing archive tool did not create it, and the historical archive metadata,
manifest, run record, reports, and logs remain unchanged.

The archive SHA-256 is recorded in [`input-bundle.sha256`](input-bundle.sha256):
`e9221b06d1af65a7826ad6c65d37d1e6467e52edb50c825c2ea5bdcf1aca9fd0`.
Restore and verify it without the scratch experiment or source tree from this
directory:

```sh
sha256sum --check input-bundle.sha256
restore=$(mktemp -d)
tar -xzf input-bundle.tar.gz -C "$restore"
python3 -c 'import hashlib,json,pathlib,sys; b=pathlib.Path(sys.argv[1])/"bundle"; m=json.loads((b/"manifest.json").read_text()); bad=[e["path"] for e in m["files"] if hashlib.sha256((b/e["path"]).read_bytes()).hexdigest()!=e["sha256"]]; assert not bad, bad; assert m["identity"]=="7ce444837068766c01129de10ab2b2f45688a2103e7edc7e9578c9b23ff97ba3"; print("verified", len(m["files"]), "bundle files")' "$restore"
```

Independent verification restored the archive at
`/tmp/opencode/p07-bundle-restore.AV5v5t/bundle`, checked all 13 manifest file
hashes, and found no byte difference from the original bundle. The restored
manifest SHA-256 is
`3b72dfe6ac6179ca0081266acebba1b7c9a8093c3461b19d250db2ea6eaff398`,
which is the value linked by `run.json`.

## ABC diagnostic disposition

The raw synthesis log is not clean despite the zero structured synthesis-check
count. LibreLane generated `synthesis.abc.sdc` with
`set_driving_cell sg13cmos5l_buf_4/X`; ABC accepted the token but could not find
that name in its cell library. The pinned PDK defines cell
`sg13cmos5l_buf_4` and output pin `X` separately. Its legacy LibreLane config
also supplies them separately, after which LibreLane's compatibility layer forms
the documented OpenSTA/config spelling `sg13cmos5l_buf_4/X`.

Pinned LibreLane `3.1.0.dev3` writes that combined value verbatim in
`scripts/pyosys/synthesize.py` when making ABC's two-command constraint file.
ABC commit `28d955ca97a1c4be3aed4062aec0241a734fac5d` parses
`set_driving_cell` as one token and `Abc_SclCellFind` looks up that token as a
cell name; it does not implement OpenSTA's separate `-lib_cell` and `-pin`
syntax. The narrow fix therefore belongs at that LibreLane translation point:
retain `{cell}/{port}` in configuration and pass only its cell component to
ABC. A bare value in the emitted `SYNTH_DRIVING_CELL` would violate LibreLane's
configuration contract and its fallback SDC, so no library or consumer
workaround was applied and no pinned installation was modified.

For this exact run, `SYNTH_STRATEGY` was `AREA 0`, `SYNTH_ABC_DFF` was false,
and ABC used the driving-cell value only in the final post-map `stime -p`.
Consequently the PI driver slew/delay contribution was absent from ABC's printed
10,013.10 ps path estimate. The output-load assumption was found and applied.
The lookup did not participate in this script's mapping commands, so it did not
change the mapped cells or area and does not invalidate comparisons of those
metrics. The ABC delay estimate is explicitly not timing evidence; this
synthesis-only run has no physical timing verdict.

The preceding `Error: The network is combinational.` comes from `scleanup` in
LibreLane's generated `AREA_0.abc`. Yosys had already mapped flops with
`dfflibmap` and, because `SYNTH_ABC_DFF` was false, passed only combinational
logic to ABC. `scleanup` therefore returned without sequential cleanup; both
generated `retime` commands were likewise no-ops. ABC continued through mapping,
`stime`, and `write_blif`. This diagnostic is benign for the selected script and
does not indicate a latch or unmapped sequential element.

## Formatted-source provenance

After preserving the original bundle, `bin/asic_bundle.ml` was formatted with
the repository's Jane Street `ocamlformat` profile. A fresh emission from current
revision `ed33c42a08c3b9addeb12284c77432ab66645e04` has build identity
`ea8c341b263df8110356beffb0344e7882ef856251f6ed6bc1ba31f664d56236`.
Among the eight declared inputs, only `bin/asic_bundle.ml` differs from the
historical copies; its new SHA-256 is
`26f0e5d8ac410ceba6fce6ebf16f719b243681e80fca7780aa0314ba66b2739c`.
The current source revision is also newer than the historical `fbe0a982...`, so
both facts are correctly visible in the new manifest rather than being folded
into the old provenance.

The generated synthesis RTL, simulation RTL, `src/config.json`,
`constraints/top.sdc`, and `info.yaml` are byte-identical to the historical
inputs, with hashes matching `manifest.json`. Formatting therefore changed
provenance identity but no tool input. No second mapped synthesis was run solely
for formatting.

The consumer remains pinned to `hardcaml_asic`
`a257424c3ae31fd6ee10cea052cc7577f15d2677`; no library code or dependency pin
changed. Fixing the ABC translation belongs in a future explicitly pinned
LibreLane version and is required only before treating ABC's own delay estimate
as evidence. Physical timing and the adopted physical-path P5.4 work remain
separate.
