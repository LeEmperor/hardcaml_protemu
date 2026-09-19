# P0.5b adopted-bundle physical run, 2026-09-18

The P0 observable design hardened on a Tiny Tapeout 6x4 `ihp-sg13cmos5l` tile
from a `hardcaml_asic`-emitted bundle, and passed LibreLane signoff, TT
precheck, and gate-level wrapper simulation in one attempt. Its build identity
is `5edf30f980c96bdd67aa0b32d1aed806eee1994bb1e1164c2adb8a93504d308f`; the
separate run ID is `05f650428c434d90a5473263a512aa66`. The immutable
[manifest](manifest.json), [preflight report](preflight.json),
[run record](run.json), [postcheck record](postcheck.json), and structured
[results](results.json) are beside this note, with logs and reports in
`reports.tar.gz`. Unpack it with `tar -xzf reports.tar.gz -C <empty-directory>`;
its paths mirror the run directory. The full run directory was 239 MB of tool
output and is not archived; [archive.json](archive.json) records the selection.

This is the run the adopted path existed to produce: the configuration came
from the typed declaration in `bin/asic_bundle.ml`, not from the legacy
hand-maintained `tinytapeout/info.yaml` and `src/config.json`.

## Result

LibreLane `3.1.0.dev3` completed the `full` stage in 24m12s (23:09:20 to
23:33:32 UTC); postcheck took a further 8m08s, for 32m20s end to end. The
design is `tt_um_leemperor_hardcaml_protemu` at 48 MHz, hardened into the
pinned `tt_block_6x4_pgvdd` floorplan.

Timing meets its goal on every reported corner with no violations: worst setup
slack 15.589 ns at `nom_slow_1p08V_125C`, worst hold slack 0.147 ns at
`nom_fast_1p32V_m40C`, and no mode left unconstrained. No setup, hold, max-slew,
or max-cap violations were reported.

Antenna, DRC, and LVS pass with zero counts. Inferred latches, unmapped
instances, and synthesis check errors are all zero. Yosys mapped 94 standard
cells (1,319.031 µm²), dominated by 14 `tielo`, 13 `dfrbpq_1`, 12 `tiehi`, and
10 `a21oi_1`. Final standard-cell area including fill is 2,228.08 µm² at 0.247%
utilization. That number is not a density result: the tile is far larger than a
94-cell design needs, and nothing here exercised placement or routing under
pressure. P0.7 memory is the first thing that will.

TT precheck passes all nine rows (KLayout pin-label, SG13CMOS5L DRC, and
zero-area DRC; pin, boundary, layer, cell-name, and analog-pin checks), with
zero items in each DRC report.

Gate-level simulation passes. Icarus from the run's pinned LibreLane image
compiled the PDK I/O, UDP, and standard-cell models with the final
`final/nl/tt_um_leemperor_hardcaml_protemu.nl.v` and this repository's
`tinytapeout/test/tb.v`, printing `PASS p0 wrapper reset/disable/pin/timer
trace` and finishing at 144000. The GDS, netlist, and testbench hashes are in
the postcheck record.

## Limits of this record

Three things this run does not establish, recorded here so they are not read
into it later:

1. **Emission is not reproducible from `source_revision` alone.** Five of the
   eight recorded source inputs were modified or untracked when the bundle was
   emitted, including `bin/asic_bundle.ml` itself. The manifest hashes the
   copied content and records each input's `git_status`, so the bundle is
   pinned by content — but the recorded revision `d6fb94b` does not describe
   the declaration that produced it. Re-emit from a committed tree and record
   whether `identity` survives the change.
2. **The adoption invariants were not checked here.** Repeatable emission, the
   wrapper regression against emitted RTL, and the configuration-conflict
   rejections live in `tinytapeout/scripts/check-adopted-bundle.py`, which
   `adopted-flow.sh` does not invoke. This run is physical evidence only.
3. **LibreLane skipped its own `KLayout.DRC` step.** `klayout__drc_error__count`
   is absent from `final/metrics.csv` and step 72 warned about it. Magic DRC
   ran in-flow (22m01s, the single longest step) and TT precheck ran the
   KLayout decks against the final GDS afterwards (478.64s), so the layout has
   KLayout coverage — it just comes from precheck rather than from the flow,
   and `collect` therefore has no KLayout metric to read.

## Timing note

Magic DRC at 22m01s is 91% of the hardening wall time for a design this small.
The KLayout SG13CMOS5L deck cost 478.64s on the same GDS in precheck. Both are
fixed costs of the tile and the deck rather than of the design, so they will
not scale down as the design grows.
