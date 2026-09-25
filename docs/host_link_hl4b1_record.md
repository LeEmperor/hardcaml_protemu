# HL4b1 implementation record: `Serial_phy` extraction (2026-09-24)

Status: HL4b1 (`Serial_phy` extraction) and its HL4c1 focused tests are implemented and
verified by an agent in the working tree. **Not committed:** nothing is committed or
staged; the repository owner commits. This is the first child of
[HL4b](host_link_migration.md#hl4--link-decomposition). `Frame_rx`, `Command_dispatch`, and
`Frame_tx` are not extracted, so HL4b and HL4c remain open.

**Accepted by the owning planning session on 2026-09-24**, including the reviewed
generic-synthesis increase from 25 108 to 25 192 cells (+84, about 0.33%). Every functional
gate passed; emitted `loader_core` has recorded sequential-equivalence evidence, and
flip-flop counts are identical. This is a case-specific migration acceptance, not a claim
of unchanged implementation cost. See [the acceptance decision](#planning-acceptance-decision).

The [P3.5 record](p3.5-hardware-loader.md) remains the wire and timing authority. No wire
value, port, timing requirement, or HL4a expectation changed.

## Starting revision and local diff

- `HEAD` = `89a3fe88d7dc0381e1817d44e4a40c481a9868af` ("re-org phase 1", HL2), branch
  `bpurtell/scaf`. The owner had not committed since the handoff. The stash list was empty
  and nothing was staged.
- **Pre-existing, not HL4b1:** the uncommitted HL3 and HL4a work. That is 18 modified
  tracked files and 10 untracked files (the three HL3 files, `docs/host_link_hl4a_record.md`,
  and the six files in `test/host_link/`). Its `git diff` (tracked files) had SHA-256
  `46af281f57021df75249a7f3510a596a0938388242bb0792ba6823125d4c941b`. The production and
  peer hashes equal the HL4a record's baseline: `hardware_loader.ml` `29b38a5f…`,
  `loader_core.ml` `ea0a8bf4…`, `control_port.ml` `07d8af08…`, `integrated_core.ml`
  `169c0484…`, and `p3_loader_tb.v` `40d9341f…` (blob `2ffc20f0`). A tar of every
  pre-existing changed file was kept in the session scratchpad for comparison.

  Starting SHA-256 of the files HL4b1 touches, or must leave unchanged:

  | File | SHA-256 at start |
  | --- | --- |
  | `lib/host_link/hardware_loader.ml` | `29b38a5f141553b2f5aa22e8cb6a507562cc45534a9b10a4978e485ee144239a` |
  | `bin/asic_bundle.ml` | `ab69de320622cde7e7c8b45b249527fe70a46b48421e988b8af1eeb9f89fcf23` |
  | `tinytapeout/scripts/check-adopted-bundle.py` | `d490111f80f7d2db0edbf9e07f32439cdf88c7d84b338c55c2d2dff9372978d8` |
  | `docs/host_link_migration.md` | `3b6d3691493b2dc114105f3d20b7b83ff23c993643ecf5d4971445700b868620` |
  | `docs/verification.md` | `d4cf257166ae5d920cfcaa707f34fd33a54791ee7f8a2624885c56c250b149ff` |
  | `docs/README.md` | `08c914f889fbb92922d95e398cdeb56522ec6c9daaa52b5a9bad60fe887fb4a5` |
  | `docs/p3.5-hardware-loader.md` | `76adac076946501795ad91cdf9f96f530ae4d2484f781d30963e5031fb9c317e` |
  | `docs/construction-plan.md` | `6aa00b99aeec2fbae21beb3bd71d6d0437c95ca46d62363354a3224a790a0137` |
  | `test/host_link/dune` (unchanged) | `bc0ff5df082b703c2f2600282fdf78a67b0c99eae88510f230aa6a393ff4bc60` |
  | `test/host_link/hardware_loader_testbench.ml` (unchanged) | `70d473fc6d907d38df5b99cf27ed145e70b49b6959d071dc6c1d09530426c101` |
  | `test/host_link/hardware_loader_transaction_tests.ml` (unchanged) | `72d894cf60f4ea479bdaf040e65195c61a1cafa9aca480518dd7b83840670ac3` |
  | `test/host_link/hardware_loader_framing_tests.ml` (unchanged) | `4f9df46f12ba4e62483f3a5d90b369c73f074f2e7f27931c1728dac033c7fa46` |
  | `test/host_link/hardware_loader_cancellation_tests.ml` (unchanged) | `35362003d08759170f123cfb43ddd8a3bd7bfc5944fe51372daf949dc70e71f6` |
  | `test/host_link/hardware_loader_diagnostics_tests.ml` (unchanged) | `cb9bf2c6dcb63489fc171c8fe9d943e13854e50c49e17bc0a38949aec2ad7558` |

- HL4b1 diff (uncommitted, unstaged). Final SHA-256 of each non-doc file, frozen before
  the final runs and unchanged after them:

  | Path | Change | SHA-256 |
  | --- | --- | --- |
  | `lib/host_link/serial_phy.ml` (new) | The PHY | `c82d32b859d6621f7e1dc0d9c43927a31075aba8013e0f45e281c8be311dbe23` |
  | `lib/host_link/hardware_loader.ml` | Composes `Serial_phy`; nine registers and their assignments removed | `856e0cfa1e663635338c0a4c328969c100bf8a69bea5723e08b7641cde98a774` |
  | `bin/asic_bundle.ml` | Loader source inventory adds `lib/host_link/serial_phy.ml` | `1afb1d17ac796089dc47c29f23a4c5b9577288cd6dd7c92f391f9d64f9ba98d2` |
  | `tinytapeout/scripts/check-adopted-bundle.py` | Loader check requires that input | `b6ea1561e920cc8bab3e04a32056941a18469d69889887d24c947f99f7b6d230` |
  | `test/host_link/serial_phy/dune` (new) | Library `protemu_serial_phy_tests`, in `@runtest` | `2c1bdea8aa7680a24a51d5680778c5d4620e789404899c140b48ece17cbd5923` |
  | `test/host_link/serial_phy/serial_phy_testbench.ml` (new) | Cycle owner, sampling, checks, diagnostics | `dbe26fe6a94270f765d0bbd2e5147fe4fc37b5b529256986d287b25a1ef78bc8` |
  | `test/host_link/serial_phy/serial_phy_tests.ml` (new) | 8 timing tests | `bd7da6e6e8ce767037857f7319254cdb5f659a11176eacefb0efb4e19411d9d3` |
  | `test/host_link/serial_phy/serial_phy_diagnostics_tests.ml` (new) | 3 negatives | `b427cc3a3db545b0e6fd6c97f4fe4bf47f4a0913bebcfce0424efea4828a1550` |
  | `docs/` | This record; [host_link_migration.md](host_link_migration.md), [verification.md](verification.md), [p3.5-hardware-loader.md](p3.5-hardware-loader.md), [construction-plan.md](construction-plan.md), [README.md](README.md) | — |

  The HL4a harness, including its `dune` file, is byte-identical to the start (hashes
  above). The focused suite lives in its own directory, so no HL4a test-source change,
  even a mechanical one, was needed.

## Tool identity

opam switch `5.2.0+ox` (OCaml 5.2.0+ox), Dune 3.24.2; `hardcaml`, `ppx_hardcaml`, `core`,
`ppx_jane`, `ppx_expect`, `ppx_inline_test` `v0.18~preview.130.106+341`; `ocamlformat`
0.26.2+ox2; `hardcaml_asic` 0.1.0; host Verilator 5.020, Icarus Verilog 12.0, Yosys 0.33
(git sha1 `2584903a060`), Python 3.12.3. The loader checker's synthesis runs in
`ghcr.io/librelane/librelane:3.1.0.dev3` (the lock's `librelane_version`), image
`sha256:d109140b8f17fc54f4fca998beb8124f4949404ec52e339eebd2250854a18b5a`, whose Yosys is
0.66 (git sha1 `86f2ddebce7e98ce7cacc27e8a5c14cb53b51b51`). The same switch, host tools,
and image served every baseline and final run.

## Extraction contract

Recorded before any logic was edited. Derived from `lib/host_link/hardware_loader.ml` at
SHA-256 `29b38a5f…239a` (the HL4a baseline). Cycle *n* is the interval before edge *n*,
as in the HL4a record; a register assigned at edge *n* has its new value in cycle *n* + 1.

### State ownership

Every register is in `Hardware_loader.I_Regs` before the extraction and is assigned in its
one `compile`. Reset is the synchronous `clear` of the shared `Reg_spec`, to 0 for every
field. "Disable" means `enable_i` low in that cycle; the loader's final `when_ ~enable_i`
overrides every earlier assignment to the fields it names.

| Register | Purpose | Owner after | Next value at each edge | Reset | Disable | Read by |
| --- | --- | --- | --- | --- | --- | --- |
| `select_meta` | Stage 1 of `~serial_select_n_i` | `Serial_phy` | `~serial_select_n_i` | 0 | No effect | `select_sync` |
| `select_sync` | Stage 2: synchronized selection level (1 = selected) | `Serial_phy` | `select_meta` | 0 (deselected) | No effect | `select_previous`, select events, `select_high_count`, loader `receiving` |
| `select_previous` | Edge-detection history | `Serial_phy` | `select_sync` | 0 | No effect | Select events |
| `select_high_count` (3 bits) | Deselected cycles, saturating at 4 | `Serial_phy` | 0 if `select_sync`; else +1 if below 4; else hold | 0 | Cleared to 0, overriding both | Response arming (`>= 4`) |
| `clock_meta` | Stage 1 of `serial_clock_i` | `Serial_phy` | `serial_clock_i` | 0 | No effect | `clock_sync` |
| `clock_sync` | Stage 2: synchronized `LCLK` | `Serial_phy` | `clock_meta` | 0 | No effect | `clock_previous`, clock events |
| `clock_previous` | Edge-detection history | `Serial_phy` | `clock_sync` | 0 | No effect | Clock events |
| `data_meta` | Stage 1 of `serial_data_i` | `Serial_phy` | `serial_data_i` | 0 | No effect | `data_sync` |
| `data_sync` | Stage 2: synchronized `LDI` | `Serial_phy` | `data_meta` | 0 | No effect | Loader `completed_byte` |

The remaining 22 `I_Regs` fields stay in `Hardware_loader`, unchanged: `byte_shift` and
`bit_count` (byte assembly), `byte_count`, `request_active`, `request_overrun`, the
header, payload, and CRC fields, `crc_match`, `dispatch`, `wait_read`, `wait_abort`,
`response_pending`, `response_active`, `response_store`, `response_shift`,
`response_length`, and `response_bits`. Byte assembly is `Frame_rx` work, not PHY work,
even though the ledger's context table once listed "bit shifting" under the PHY.

### Events and observations

All are combinational functions of the PHY registers only. None depends combinationally on
a pin, `enable_i`, or `reset_i`, so reset and disable affect them only through a later edge.

| Signal | Before (loader local) | Definition | Visible |
| --- | --- | --- | --- |
| Selected level | `r.select_sync.value` | `select_sync` | `LSEL_N` low in cycle *a* is 1 from cycle *a* + 2 |
| Data level | `r.data_sync.value` | `data_sync` | `LDI` in cycle *n* is visible in cycle *n* + 2 |
| Select assert | `select_assert` | `select_sync & ~select_previous` | Exactly cycle *a* + 2 for `LSEL_N` low from cycle *a* |
| Select release | `select_release` | `~select_sync & select_previous` | Exactly cycle *s* + 2 for `LSEL_N` high from cycle *s* |
| Clock rise | `clock_rise` | `clock_sync & ~clock_previous` | Exactly cycle *r* + 2 for `LCLK` high from cycle *r* |
| Clock fall | `clock_fall` | `~clock_sync & clock_previous` | Exactly cycle *f* + 2 for `LCLK` low from cycle *f* |
| Deselect qualified | `r.select_high_count.value >=:. 4` | `select_high_count >= 4` | In cycle *c* iff `select_sync` was low, `enable_i` high, and reset low in each of cycles *c* − 4 … *c* − 1 |

Each event lasts one cycle and cannot repeat while its input is stable. The qualification
compares the registered count, so in the select-assert cycle it still describes the cycles
before the selection; the count clears at that edge.

### Consumers after extraction (all in `Hardware_loader`, unchanged)

| Consumer | Uses | Same-cycle terms (loader-owned) |
| --- | --- | --- |
| Request start | Select assert | `enable_i`, `request_idle` |
| Bit receive | Clock rise, selected level, data level | `enable_i`, `request_active`, `bit_count`, `byte_count` |
| Frame validation and dispatch arming | Select release | `request_active`, `parser_error` |
| Response arming | Select assert, deselect qualified | `enable_i`, `response_pending` |
| Response shift | Clock fall | `response_active`, `response_drained` |
| Response release and commit | Select release | `response_active`, `response_drained` |

### Interface decisions

- `Serial_phy` takes clock, reset, enable, and the three pins, and has seven outputs: the
  two levels, the four events, and the qualification. It exposes no count, no clock
  level, and no metastable stage, because no consumer reads them.
- The qualification is a boolean at the existing threshold, so the count's width and
  saturation stay private.
- `enable_i` enters the PHY only because disable clears the count. Disable does not touch
  the synchronizers or edge history, as today.
- The PHY depends on nothing but Hardcaml: not `Wire`, `Control_port`, the dispatcher, or
  response state. Request and response arming, parsing, dispatch, waits, response storage,
  shifting, replay, and commit stay in `Hardware_loader`.
- No register, stage, handshake, or pulse delay is added. The registers keep their `Always`
  form, statement order, and `reg_` names so the priority muxes are rebuilt the same way.
  `Hardware_loader` composes the PHY under `Scope.sub_scope scope "serial_phy"`, the
  repository's composition convention; only the flattened register names gain that level.
- The contract was implemented as recorded; no boundary issue or dependency cycle arose.

## What moved and what remained

| | Before | After |
| --- | --- | --- |
| Synchronizers, edge history, qualification count (9 registers) | `Hardware_loader.I_Regs` | [`Serial_phy.I_Regs`](../lib/host_link/serial_phy.ml), same names, widths, and assignments |
| `selected_async`, the four edge expressions, `>= 4` | Locals in `Hardware_loader.create` | `Serial_phy` outputs; the loader keeps local aliases (`select_assert`, `select_release`, `clock_rise`, `clock_fall`, `deselect_qualified`) |
| Count's disable clear | Line in the loader's disable `when_` | The PHY's own final `when_ ~enable_i` |
| Byte assembly, frame receive, dispatch, waits, response store/shift/commit, request and response arming (22 registers) | `Hardware_loader` | `Hardware_loader`, unchanged |

`Hardware_loader`'s public `I`/`O` did not change. Its only other edits are three
references (`receiving`, `completed_byte`, the arming condition) and the header comment.
The threshold literal `4` became `Serial_phy.deselect_qualification = 4`.

## PHY interface and temporal contract

`Serial_phy.I`: `clock_i`, `reset_i`, `enable_i` (system domain, synchronous active-high
reset), `serial_select_n_i`, `serial_clock_i`, `serial_data_i` (asynchronous pins).

| `Serial_phy.O` | Meaning | Timing |
| --- | --- | --- |
| `selected_o` | Synchronized selection, active high | `LSEL_N` in cycle *n* appears in *n* + 2 |
| `data_o` | Synchronized `LDI` | `LDI` in cycle *n* appears in *n* + 2 |
| `select_assert_o`, `select_release_o` | Selection edges | One cycle, in the first cycle the new level is visible |
| `clock_rise_o`, `clock_fall_o` | `LCLK` edges | Same |
| `deselect_qualified_o` | Four prior deselected, enabled, unreset cycles | Registered: in a select-assert cycle it still describes the cycles before it |

All outputs depend only on PHY registers. The focused testbench checks this every cycle:
the post-edge sample, taken with the old inputs, must equal the next pre-edge sample, taken
after new inputs settle.

### Reset, disable, and qualification semantics

- **Reset** (synchronous) clears all nine registers at its edge: the levels read as
  deselected, `LCLK` low, and `LDI` low, the history is cleared, and so is the count. The reset
  cycle's own outputs still show pre-reset state. A transition still in the first stage is
  discarded, and a pin held through reset is seen again two cycles after reset falls. A
  reset while selected produces no release event.
- **Disable** clears only the count, overriding both the selection clear and the
  increment. Synchronizers and edge history keep running, so events are still produced
  while disabled. `Hardware_loader` gates their use with `enable_i`, exactly as before.
- **Qualification**: at each enabled, unreset edge, a synchronized selection clears the
  count; otherwise the count increments while below 4 and then holds (saturates). Qualified
  means count ≥ 4. The count cannot exceed 4.

### Why the loader's behavior is unchanged

- **Structure.** The nine registers keep the same `Reg_spec` (clock, synchronous clear),
  the same `Always` next-value statements in the same order, and the same reset values. The
  loader's own statements and priorities are untouched. The events feed the same
  expressions the same cycle. Nothing was added between PHY and loader. The formal check below
  proves this at the emitted netlist.
- **A. Response arming** is still
  `select_assert & enable_i & response_pending & deselect_qualified` in the loader, where
  `deselect_qualified` is the old `select_high_count >= 4`. It needs `LRDY` only in the
  arming cycle, not throughout the deselected interval. The HL4a boundary tests (3- and
  4-cycle gaps; the delayed-READ probe at 3 and 2 cycles) pass unchanged.
- **B. Reset/disable during dispatch.** Offers still come from the loader's `dispatch`
  register, ungated. The HL4a "reset or disable in the dispatch cycle" tests pass
  unchanged. No output gating was added.
- **C. Commit** stays in the loader: `select_release & response_active & response_drained`.
  `LRDY` still falls at *d* + 3 (HL4a `ready_cleared_after_deselect`).
- **D. PHY reset/disable** follows the baseline assignments exactly (above). Reset and
  disable differ, and the focused tests pin that difference.

## Focused tests (HL4c1)

[`test/host_link/serial_phy/`](../test/host_link/serial_phy/serial_phy_testbench.ml)
(library `protemu_serial_phy_tests`, in ordinary `@runtest`) follows the per-module
convention: the testbench owns the only simulator loop (`cycle`), pre-/post-edge sampling,
finite waits (`wait_for`, default budget 100 cycles), checks, and `Phy_failure` reports
(scenario, cycle, phase, what, expected, actual, and the inputs and high outputs of recent
cycles). Every expected cycle is hand-written from the contract. The testbench's
`latency = 2` and `threshold = 4` are literals, deliberately not read from `Serial_phy`.

| Test | Covers |
| --- | --- |
| "each pin reaches its synchronized level two cycles after it changes" | Select and data latency, both directions; one-cycle pulses unfiltered |
| "each pin change is one event ... and a stable pin repeats nothing" | All four events at exactly *n* + 2, one cycle each, no repeat over 50 stable cycles; one-cycle pulses give consecutive events |
| "deselect qualification: below, at, and above four cycles, saturating ..." | Qualified from exactly reset + 4; 5000-cycle intervals (a wrapping count would fail); the assert cycle still qualified, cleared the cycle after; restart from zero after release (below/at/above) |
| "a selection is qualified exactly when LSEL_N was high for at least four cycles before it" | Gaps 1, 2, 3 → not qualified; 4, 5, 8, 100 → qualified. This is the PHY half of the HL4a arming boundary |
| "short deselected gaps do not accumulate toward qualification" | Five 3-cycle gaps separated by one-cycle selections |
| "coincident select, clock, and data changes ..." | Simultaneous select/clock/data changes, release with rise, and assert with fall: each reported in the same cycle on its own output |
| "reset clears the synchronizers, edge history, and qualification at its edge" | Event visible in the reset cycle; no release after reset; a held pin re-asserts two cycles after reset; a pulse in flight is discarded (control run without reset reports it); the count restarts after reset |
| "disable clears only the qualification; synchronizers and events keep running" | Events and data while disabled; qualification returns four enabled cycles after enable; a selection driven just before disable is still seen; disable wins over the increment at the threshold edge |
| Diagnostics (3) | A one-cycle-late event expectation raises (expect test prints the report); a one-cycle-early qualification expectation raises; a 25-cycle wait stops exactly at its budget |

These are synchronous digital tests: every pin changes at a cycle boundary. They make no
claim about asynchronous phase, metastability, physical setup/hold, or board timing.

### Sensitivity

Temporary production mutations to `lib/host_link/serial_phy.ml`, each run with
`./scripts/with-switch.sh dune build -j 5 @test/host_link/runtest` (both suites) and then
restored by copying the saved file. The SHA-256 was checked after each restore:

| Mutation | PHY suite failures | HL4a suite failures |
| --- | --- | --- |
| M1. Threshold 3 (`deselect_qualification = 3`) | 5 of 8, plus the threshold negative (its wrong expectation now holds) | 2 (arming boundary; early selection in dispatch) |
| M2. Select assert one cycle early (from `select_meta`) | 6 of 8 | 10 |
| M3. Disable does not clear the count | 1 (the disable test) | **0** |
| M4. Count wraps (no saturation) | 5 of 8 | 5 |

M3 shows the focused tests are not redundant: the HL4a suite has no case that observes
the count's disable clear, and the new disable test does.

A separate check covers the new checker assertion. With `serial_phy.ml` temporarily
removed from the loader inventory, `check-adopted-bundle.py --kind loader --metadata-only`
failed on `assert "lib/host_link/serial_phy.ml" in source_paths`. The inventory was
restored and its hash checked.

## Verification

Every Dune command used `-j 5` and ran strictly one after another; no two heavy jobs
overlapped. `@loader-rtl`'s rules and the checker were re-inspected first: they run
Verilator (`-j 1`), Yosys, iverilog, Docker, and peer binaries, and make no nested Dune
call. The capture scripts call Dune only with `-j 5`.

| Check | Result |
| --- | --- |
| Baseline, before any edit: `dune runtest test/host_link --force -j 5` | PASS (32 HL4a tests) |
| Baseline full loader checker `check-adopted-bundle.py --kind loader` | PASS, 5 min 7 s; identity `c9a45a83…` (equal to HL3's recorded working-tree identity) |
| `./scripts/with-switch.sh dune runtest test/host_link --force -j 5` | PASS, freshly executed, 9 s: 32 HL4a tests and 11 Serial_phy tests |
| `./scripts/with-switch.sh dune build @install @lint -j 5` | PASS |
| `./scripts/with-switch.sh dune build @runtest -j 5` | PASS, 28 s, no output |
| `./scripts/with-switch.sh dune build @loader-rtl --force -j 5` | PASS, 7 min 39 s, all three peer tiers freshly executed (reusable core, behavioral wrapper, production synthesis wrapper). Each printed `PASS p3.5 serial loader repair: timing, overrun rejection, replay/commit, status, recovery, production paths; 3/3 sensitivity phases=10, excluded 1/1 failures=10` |
| `./scripts/with-switch.sh dune build @rtl -j 5` | PASS, after the forced loader run. Other benches reused earlier results; their generated inputs are byte-identical (below) |
| Full loader checker `check-adopted-bundle.py --kind loader` | PASS, 5 min 9 s (repeatable bundle and metadata, both wrapper roles against the peer, lint, and synthesis in the pinned image); identity `edb36d27…` |
| `check-adopted-bundle.py --kind observable/memory/loader --metadata-only`, run separately | PASS, PASS, PASS |
| `./scripts/with-switch.sh dune build -j 5 @lib/host_link/fmt @test/host_link/fmt` | PASS. The four new files were formatted with `dune promote <file>` one at a time; `hardware_loader.ml` needed no change. The repository `@fmt` backlog was not swept |
| `git diff --check`, tab/trailing-whitespace scan of new files | PASS |
| `tinytapeout/test/p3_loader_tb.v` | Unchanged: no diff against `HEAD`, blob `2ffc20f0f302c5bad5fd9189056b22c8d8cc175d`, SHA-256 `40d9341f32ad02202f78784dbf4c6f9a7685691d8f7da78a50c2303cd2e2c9c9` |
| HL4a harness and expectations | Byte-identical to the start; `Latency`, cycles, counts, bytes, and arming expectations untouched |
| `git diff --cached` | Empty; nothing staged |

## RTL and port comparison

The captures, before (`pre`) and after (`post`), ran the HL3 generation commands with
identical options:

```sh
for mode in access executable integrated loader; do
  ./scripts/with-switch.sh dune exec -j 5 bin/generate_core.exe -- "$mode" "$dir/$mode.v"
done
./scripts/with-switch.sh dune exec -j 5 bin/generate.exe -- -output "$dir/p0.v" -module-name p0_observable
for block in pin_bank input_events timing byte_fifo_8 shift_lane observed_transfer \
  observed_transfer_bank primitive_demo uart_tx uart_slice; do
  ./scripts/with-switch.sh dune exec -j 5 bin/generate_p2.exe -- "$block" "$dir/$block.v"
done
./scripts/with-switch.sh dune build -j 5 bin/asic_bundle.exe
for kind in observable memory loader; do
  ./_build/default/bin/asic_bundle.exe "$kind" "$bundles/$kind" "$PWD"
done
```

**Generator outputs.** 14 of 15 are byte-identical. The pre list digest is
`29831c119d353a19205b015394a7be871c54eaced350fe03c0421cbc1aa87d21`, equal to the HL2 and HL3
digests, so the baseline was the accepted one. The post list digest is
`af7802af6dea77e3e6281f5864bc0760d2d40157500b1a31f73dd85016cbc7c1`. Complete post list;
only `loader.v` differs, and its pre value is
`dfb870cf40267029fb3bc3ddd78b4f9ec31a625c5602716aed3c2d894005c035`:

```text
66c91d2f44524fa9c38c8a1b38528f5789c32465cd52782ca05ac6075171b8a8  access.v
5d8062004e3919e2ddc140f7af2785d0f9a09e3ee495bd83620029c58693eeaf  byte_fifo_8.v
7473662697c0b1636f77bad7ac35b547b38c10919fc4d6e2c87e0100d8be9116  executable.v
626be0dc9fdab61b9fedffe59e527d6f2e37b4c2474d79d8bd69aaa18f817e92  input_events.v
3af601b6b7ce88a58bacba1c58a9e69435098d846d9eb687670046b9786eadec  integrated.v
6f7aac12c816a9e55f7e4463d183c103e86ae4315e25ec952ffecc3c21f9129d  loader.v
5f9ebeae9e51bec5399e439bfcf8ce7e060595f3a2afbb0c3f0277e4ad973e50  observed_transfer_bank.v
f65f7442539548cb3d55cbaf3d47358c2bc7d5c09ca5862037c06965c636e800  observed_transfer.v
c9f5e31aa3845c32810245b0ed568af67dcf253cf86ffc76ba66a704b59b7042  p0.v
0090a95846b9ef01fd508c59f9dd998d35d8fabaef2f0aec7d7d7454475a43c8  pin_bank.v
49d138686f7688cd0b2fd19144b567bc43243a3c448221352a7437f9d31c70a8  primitive_demo.v
d837339ab1f762592a2211032c9d4ae0fff20c0d30f7834d18a4e5515581ef04  shift_lane.v
fc0dbed78ff5ecf3f32f5e6e3ae7aa1e332dc154b1e7b69847616b643f74584c  timing.v
e7d3886907003a8376961e695f227b5f3398fefc7cfc9d033721a39c27016cb0  uart_slice.v
ce4454c0b15fe20e6b22eb290f0b029b11625e0e4c8188d0a109450affd9dd72  uart_tx.v
```

**Bundle Verilog.** 4 of 6 are byte-identical: the `src/` and `simulation/` roles of
observable and memory. `info.yaml`, `constraints/top.sdc`, and `src/config.json` are
identical for all three bundles (list digest
`42e943a74c4d93ec1744e785a799fb3311109fbbf1c9bba3cba3e01247d86702` before and after).

| Loader bundle file | Pre SHA-256 | Post SHA-256 |
| --- | --- | --- |
| `src/tt_um_leemperor_hardcaml_protemu_loader.v` | `c8f92f762d1044dde0bb7a1071a4b41a43c4fe33c4a2cdd10dc4ed31ab213d9c` | `6c03b88f53d6fba6c20b60da803bdb039e4d1e242fc36c00155dd3e9964a9817` |
| `simulation/tt_um_leemperor_hardcaml_protemu_loader.v` | `7678aedb9d5b35c5e9fbf7e0e31e489609a47f9fddc79ed3acf1139ef5168b28` | `316698b26c1efc79db1932c7d21c6bb15f33d47fe5f39cd8799908e44dc071e2` |

Unchanged (both roles, pre and post): memory `a6c3ad27c175d89571ae393dfb7a2044253a6a6f1a1d0201b6a022c8c3ce0d95`
(`src`) and `8b21fa31a7a309c5f573ac60549b4f3bbb119a25bc4d0e613b1d31012c743762`
(`simulation`); observable `c275808a7279c617c460c3706cdfd69c0d580b7c3356ec224b66d8730b7b0cb1`
(both roles).

**External ports.** A parser read each module header and its declarations: index,
direction, width, name. The inventories are identical before and after:
`loader_core` 17 ports (SHA-256 of the inventory
`9f992fb76b76795f8125e16d80f9a1750562f218927874e34961680b4d188dbb`), both loader wrapper roles
8 ports (`7eee010b09143a2db3f925b69cc1e23f1a4d62378b7dbc7aa437364e9ac9bc6f`), and
`integrated_core` 109 ports (`cccfece6e90079f2edc39a82e6efac54f633e79fc8c3043ec43a0c0785102b04`).
`Serial_phy` is flattened; it adds no module or port.

**Every difference in the three changed files**, classified mechanically:

1. The nine PHY registers are renamed `loader$reg_*` → `loader$serial_phy$reg_*`: the
   `Scope.sub_scope` level.
2. One extra 1-bit `wire`/`assign`: a second `~enable_i`. The PHY builds its own inverter
   for its disable clause; Hardcaml does not share common subexpressions, so the inverter
   count of `enable_i` goes from 11 to 12. This is the +2 lines in every changed file (`loader.v`
   20 495 → 20 497 lines; wrapper 24 312 → 24 314 and 20 778 → 20 780).
3. Hardcaml's anonymous `signal_<op>_<n>` names are renumbered where creation order
   changed. The 30 anonymous registers keep identical names and widths.

After undoing (1), `loader.v` differs in 1 370 lines and each wrapper role in 82, all of
kinds (2) and (3). Counting declarations by kind, with anonymous numbers masked, gives one
difference only: one more 1-bit `signal_not`.

**Formal sequential equivalence** (host Yosys 0.33). For emitted `loader_core`, the
following script proves every paired point equal:

```text
read_verilog gold.v; rename loader_core gold      # pre
read_verilog gate.v; rename loader_core gate      # post, loader$serial_phy$reg_ -> loader$reg_
proc -norom; opt_clean                            # -norom: keep the core's case tables as logic
rename -hide w:signal_* w:signal_reg_* %d         # hide renumbered anonymous nets, keep registers
opt_clean
equiv_make gold gate equiv; hierarchy -top equiv
equiv_simple -seq 2; equiv_induct -seq 2; equiv_status -assert
```

Result: **1 331 of 1 331 `$equiv` cells proven** (175 matched names: every port, every
named and anonymous register including the nine PHY registers, and named wires). The
nine registers were paired by name after the rename. It ran in 5 min 45 s.
Non-vacuity: against a `loader.v` generated from the M1 (threshold 3) source, the same
script fails. The unproven cells are `loader$reg_select_high_count` and the
response-arming state downstream of it.

The same flow on the loader wrapper's synthesis source proved 5 423 of 5 425 cells. The
two unproven cells are the wrapper's own 2-bit reset synchronizer (`signal_reg_288`, the
two `$_DFF_PN1_` cells). It is outside the loader and textually identical in both files:
an asynchronous preset to `2'b11` on `~rst_n`, shifting `{reg[0], 1'b0}`. The induction
flow does not model the asynchronous preset. With `async2sync` added after `proc` on
both sides (modelling that preset as synchronous, identically for gold and gate), the
wrapper proof is complete under that transformed model: **5 425 of 5 425 cells proven**,
in 20 min. This is not an unrestricted proof of asynchronous reset assertion/release or
physical reset behavior. The untransformed wrapper flow still has the two unproven reset
bits; the wrapper reset circuitry is textually unchanged, and independent peer checks
remain separate evidence.

## Generic synthesis

The configuration is the loader checker's own, unchanged: the pinned image above, `docker
run --rm --pull=never --network none`, and the command
`yosys -p 'read_verilog /bundle/src/tt_um_leemperor_hardcaml_protemu_loader.v; hierarchy
-check -top tt_um_leemperor_hardcaml_protemu_loader; synth -top
tt_um_leemperor_hardcaml_protemu_loader; stat'`. That is the production synthesis source,
including the explicit-flop `program` RAM. The checker discards stdout, so the counts
were captured by running the identical container and command on the loader bundle emitted
by the capture; the checker itself was also run, and passed, before and after. A
supplementary count ran the `@loader-core-rtl` rule's host-Yosys command, without `-q`,
on `loader_core` alone.

**Checker path, `tt_um_leemperor_hardcaml_protemu_loader`** (Yosys 0.66):

| Cell type | Before | After | Delta |
| --- | ---: | ---: | ---: |
| `$_ANDNOT_` | 496 | 485 | −11 |
| `$_AND_` | 7 907 | 8 025 | +118 |
| `$_DFFE_PP_` | 4 240 | 4 240 | 0 |
| `$_DFF_PN1_` | 2 | 2 | 0 |
| `$_DFF_P_` | 13 | 13 | 0 |
| `$_MUX_` | 592 | 588 | −4 |
| `$_NAND_` | 8 370 | 8 347 | −23 |
| `$_NOR_` | 491 | 430 | −61 |
| `$_NOT_` | 84 | 84 | 0 |
| `$_ORNOT_` | 456 | 469 | +13 |
| `$_OR_` | 554 | 631 | +77 |
| `$_SDFFE_PP0N_` | 3 | 3 | 0 |
| `$_SDFFE_PP0P_` | 804 | 804 | 0 |
| `$_SDFFE_PP1P_` | 6 | 6 | 0 |
| `$_SDFF_PP0_` | 315 | 315 | 0 |
| `$_XNOR_` | 552 | 525 | −27 |
| `$_XOR_` | 223 | 225 | +2 |
| **Cells** | **25 108** | **25 192** | **+84** |
| Wires / wire bits | 25 450 / 66 614 | 25 534 / 66 698 | +84 / +84 |
| Public wires / bits | 7 041 / 48 205 | 7 041 / 48 205 | 0 |
| Ports / port bits | 8 / 43 | 8 / 43 | 0 |

`stat` report SHA-256: before `a452d38c1645ff4c367c419fdb2474d52223bb51839cb0ed2230a2820f769087`,
after `5068db2556b9eb12597ba65d4a6773ff07a83b0bf04a34b16c03ceb596879810`.

**Supplementary, `loader_core` with host Yosys 0.33:** identical before and after,
16 194 cells (report SHA-256 `e11a9974782dbf21aa40bb00064d89b4cbd8f85af4ba3c7234b53f2b9add7fc0`
both times, including the same 1 269 flip-flops).

### Investigation of the +84

Every flip-flop count is unchanged, and the netlists are proven equivalent (above), so
the delta is entirely in combinational mapping. The controlled experiments below used the
checker's container and command on name-only variants:

| Input | Cells |
| --- | ---: |
| Baseline wrapper, two runs | 25 108, 25 108 (deterministic) |
| Post wrapper | 25 192 |
| Post, the nine PHY register names mapped back to `loader$reg_*` | 25 192 |
| Baseline, the nine register names mapped forward to `loader$serial_phy$reg_*` | 25 108 |
| Baseline, every anonymous `signal_<op>_<n>` renumbered in reverse (same logic, same statement order) | 25 191 |
| Baseline, random consistent renumbering, seeds 1/2/3 | 25 151, 25 123, 25 062 |
| Post, random consistent renumbering, seeds 1/2/3 | 25 159, 25 242, 25 034 |
| `loader_core` alone, pre → post, checker Yosys 0.66 | 12 094 → 12 190 |
| `loader_core` alone, pre → post, host Yosys 0.33 | 16 194 → 16 194 |

Flip-flop counts are identical in every variant (5 383). Findings:

- The register renames have no effect.
- In the checker's Yosys, renaming anonymous nets alone, with no logic change, moves the
  count of the unchanged baseline by −46 to +83. Name-only variants of the baseline span
   25 062–25 191 and of the post 25 034–25 242. The actual post count, 25 192, is one
   cell above the highest sampled baseline rename, and the two sampled ranges overlap.
   These finite experiments demonstrate sensitivity; they do not establish a statistical
   tolerance or isolate the exact contribution of each emitted-RTL change.
- The one extra `~enable_i` inverter is logically redundant: it is the same function as
  an existing net, and the equivalence proof pairs every register and output across it.
- The host Yosys 0.33 count of `loader_core` is unchanged.

The best-supported explanation is synthesis sensitivity to the changed anonymous naming
and equivalent emitted structure. Name-only variants demonstrate that raw cell-count
equality is not a reliable invariant of equivalent logic in this configuration. They do
not prove that every renaming changes the count or that the exact +84 is caused only by
names; the redundant inverter is also an emitted structural difference.

### Planning acceptance decision

The owning planning session accepts HL4b1 and its +84-cell delta on 2026-09-24, based on
review of this record, the extracted source, and matching current hashes for the PHY,
loader, HL4a testbench, and independent peer. The session did not rerun synthesis,
formal proofs, or regression suites; those results are the implementation evidence above.

The decision rests on the combination of:

- unchanged register ownership semantics, external ports, and HL4a cycle expectations;
- all required functional suites and independent peer tiers passing;
- complete recorded `loader_core` sequential equivalence, including the moved state,
  with a threshold mutant demonstrating proof sensitivity;
- unchanged sequential-cell counts and a reviewed emitted diff limited to names and
  one logically redundant inverter;
- controlled name-only experiments showing that combinational mapping counts vary
  without a behavior change, plus the unchanged supplementary host-Yosys count.

The actual checker result remains **25 192 cells**, not 25 108 or "no increase". No
mapped-area, timing, power, or physical equivalence claim follows. The wrapper proof is
qualified by its `async2sync` model as described above.

For later slices, preserve the functional gates, external interfaces, state/timing
contract, and unchanged existing test expectations. When emitted RTL changes, record
sequential-equivalence scope, state correspondence, assumptions, preprocessing, and
unproven points; escalate an incomplete proof rather than calling it complete. Continue
to report exact same-tool total/per-type synthesis counts and compare both with the
previous accepted slice and the original unsplit baseline (25 108 in this configuration).
Every nonzero delta still needs investigation and planning review. Formal equivalence
plus equal flip-flop counts does not by itself bound combinational cost. There is no
automatic percentage allowance, and this acceptance does not authorize later increases.

## Bundle metadata and source identity

`source_revision` is `89a3fe8` in every bundle. Only `identity`, `source_inputs`, and
the loader's two Verilog roles changed; `info.yaml`, constraints, and `config.json` did not.

| Bundle | Identity before | Identity after | Source-input changes |
| --- | --- | --- | --- |
| observable | `8fc12d74c1a2216ff2c10c7723174572fecb5dda7747ac6ef5d06cc28f22061a` | `7450eb5809862027878a0dca28b357b44da3f51c54a86f9dd01a93c8032a1320` | `bin/asic_bundle.ml` content |
| memory | `3c1282de95ea4d813b22fab39b9804a400925a717ec53c6e94d33374cc1ebb0e` | `057c56215f519968d3b76a1e8d3dd8082da77b81f6b6313d4ce98ba964e846d7` | the same input |
| loader | `c9a45a838f28b7206536857d46ecdf52406737c576a443da15d11494524cd780` | `edb36d270ab71a001751ea74075beea0909f09163f040138697d81c12021424d` | the same, plus `hardware_loader.ml` content; added `lib/host_link/serial_phy.ml` (git status `??`), 34 → 35 inputs |

`Serial_phy` belongs only to the loader's closure (`Loader_core` → `Hardware_loader` →
`Serial_phy`). `P0_observable` and `Protocol_core` do not reach it, so the observable and
memory checker expectations did not change. No Dune change was needed. The
loader-wrapper rule depends on `(source_tree ../../lib)`, and the `generate_core` rules
depend on the executable, whose library closure includes the new module. An edit to
`serial_phy.ml` therefore invalidates every relevant generation rule. These working-tree
identities will change again when the owner commits.

## Blockers, follow-ups, and remaining work

- **Resolved:** the +84-cell generic-synthesis delta is accepted for HL4b1 by the planning
  decision above. Retain 25 108 as the unsplit baseline and 25 192 as this slice's actual
  result for cumulative comparisons during later extractions.
- No functional blocker. No pre-existing defect was found. HL4a findings stand as recorded.
- Style note, not changed: `formatting_guide.md` §8.2 would write pure delay registers
  with plain `reg`. The PHY keeps the baseline's `Always` form to rebuild identical
  structure. Converting it is optional later cleanup.
- Remaining HL4b work: `Frame_rx`, `Command_dispatch`, and `Frame_tx`, each with its HL4c
  tests. HL4b and HL4c stay open.
- Unchanged and out of scope: the `observed_transfer.ml` loader manifest entry, the
  host-simulator CLI stdout comparison gap, and the `@fmt` backlog.
- This is RTL-identity, formal-equivalence, Cyclesim, emitted-RTL peer, and generic
  synthesis evidence. It is not physical, timing, or mapped-area evidence. No physical
  flow was run.
