# HL4b2 implementation record: `Frame_rx` extraction (2026-09-24)

Status: HL4b2 (`Frame_rx` extraction) and its HL4c2 focused tests are implemented and
verified by an agent in the working tree. **Not committed:** nothing is committed or
staged; the repository owner commits. This is the second child of
[HL4b](host_link_migration.md#hl4--link-decomposition). `Command_dispatch` and `Frame_tx`
are not extracted, so HL4b and HL4c remain open.

**Accepted by the owning planning session on 2026-09-24.** Every functional gate passed, emitted
`loader_core` is proven sequentially equivalent to the HL4b1 implementation, and every
flip-flop count is unchanged. The loader checker's generic-synthesis count moved
**25 192 → 25 210 cells (+18)** against the accepted HL4b1 slice, and **25 108 → 25 210
(+102)** cumulatively against the unsplit baseline. This delta has its own
[acceptance decision](#planning-acceptance-decision); HL4b1's acceptance did not
automatically cover it. No unchanged-area or physical-performance claim follows.

The [P3.5 record](p3.5-hardware-loader.md) remains the wire and timing authority. No wire
value, codec policy, public port, timing requirement, `Control_port` field, or HL4a/HL4c1
expectation changed.

## Starting revision and local diff

- `HEAD` = `89a3fe88d7dc0381e1817d44e4a40c481a9868af` ("re-org phase 1", HL2), branch
  `bpurtell/scaf`. The owner had not committed since the HL4b1 review. The stash list was
  empty and nothing was staged.
- **Pre-existing, not HL4b2:** the uncommitted HL3, HL4a, and HL4b1/HL4c1 work: 18 modified
  tracked files and 13 untracked files (`docs/host_link_hl3_record.md`,
  `docs/host_link_hl4a_record.md`, `docs/host_link_hl4b1_record.md`,
  `lib/emulator_core/control_port.ml`, `lib/host_link/serial_phy.ml`, the six HL4a files and
  four `serial_phy/` files under `test/host_link/`, and
  `test/integration/core_engine/core_engine_control_port_tests.ml`). Its `git diff`
  (tracked files) had SHA-256
  `d07c6443f067467cb2a769ca22118e401f8f8cfb2a2c97f4d317e17ef6f16237`. Every production,
  test, and peer hash equals the HL4b1 record's final value (`serial_phy.ml` `c82d32b8…`,
  `hardware_loader.ml` `856e0cfa…`, `asic_bundle.ml` `1afb1d17…`, checker `b6ea1561…`, all
  HL4a and `serial_phy/` test files, `p3_loader_tb.v` `40d9341f…`). Only planning documents
  had changed since. A tar and SHA-256 list of every pre-existing changed file were kept in
  the session scratchpad; at the end, every one of those files that HL4b2 did not
  intentionally edit still had its starting hash.

  Starting SHA-256 of the files HL4b2 touches, or must leave unchanged:

  | File | SHA-256 at start |
  | --- | --- |
  | `lib/host_link/hardware_loader.ml` | `856e0cfa1e663635338c0a4c328969c100bf8a69bea5723e08b7641cde98a774` |
  | `bin/asic_bundle.ml` | `1afb1d17ac796089dc47c29f23a4c5b9577288cd6dd7c92f391f9d64f9ba98d2` |
  | `tinytapeout/scripts/check-adopted-bundle.py` | `b6ea1561e920cc8bab3e04a32056941a18469d69889887d24c947f99f7b6d230` |
  | `docs/host_link_migration.md` | `06342d2e8999c2456ed5c9ae9275cc5eda870433b65492553d457e7300473ac3` |
  | `docs/verification.md` | `23456cb72f33a297e4b2ceb6982291caaa4fdcad9783108cf71e7889c2081a22` |
  | `docs/README.md` | `1874384ee5a51b6438f5d98d941aa986f24066bc78cf751aeb37c18fab675d25` |
  | `docs/p3.5-hardware-loader.md` | `af1a278459d6f8d773f81600e628e25130c8fd4c76e311a986048f1d339410e3` |
  | `docs/construction-plan.md` | `20b29ad5d7a28801cbaff05a8233a158f1bde5269010464fb8229865ca6b94d6` |
  | `lib/host_link/serial_phy.ml` (unchanged) | `c82d32b859d6621f7e1dc0d9c43927a31075aba8013e0f45e281c8be311dbe23` |
  | `test/host_link/dune` (unchanged) | `bc0ff5df082b703c2f2600282fdf78a67b0c99eae88510f230aa6a393ff4bc60` |
  | `test/host_link/hardware_loader_testbench.ml` (unchanged) | `70d473fc6d907d38df5b99cf27ed145e70b49b6959d071dc6c1d09530426c101` |
  | `test/host_link/hardware_loader_transaction_tests.ml` (unchanged) | `72d894cf60f4ea479bdaf040e65195c61a1cafa9aca480518dd7b83840670ac3` |
  | `test/host_link/hardware_loader_framing_tests.ml` (unchanged) | `4f9df46f12ba4e62483f3a5d90b369c73f074f2e7f27931c1728dac033c7fa46` |
  | `test/host_link/hardware_loader_cancellation_tests.ml` (unchanged) | `35362003d08759170f123cfb43ddd8a3bd7bfc5944fe51372daf949dc70e71f6` |
  | `test/host_link/hardware_loader_diagnostics_tests.ml` (unchanged) | `cb9bf2c6dcb63489fc171c8fe9d943e13854e50c49e17bc0a38949aec2ad7558` |
  | `test/host_link/serial_phy/*` (unchanged) | as in the [HL4b1 record](host_link_hl4b1_record.md#starting-revision-and-local-diff) |

- HL4b2 diff (uncommitted, unstaged). Final SHA-256 of each non-doc file, frozen before
  the final runs and unchanged after them:

  | Path | Change | SHA-256 |
  | --- | --- | --- |
  | `lib/host_link/frame_rx.ml` (new) | The receiver | `63603e078bdbc2fd8f4fe30bc9312abaae4b1b23f45e00a86bbe392f09f9faf9` |
  | `lib/host_link/hardware_loader.ml` | Composes `Frame_rx`; 13 registers, their statements, and the receive/validation expressions removed | `766367444766dbd96376964239177305fa455634cdfd4576a22e9fba8d3c5b02` |
  | `bin/asic_bundle.ml` | Loader source inventory adds `lib/host_link/frame_rx.ml` | `e2931db6ba971718308b3b02dda60042072f7a7d9eac504c4fe14a97a55303c6` |
  | `tinytapeout/scripts/check-adopted-bundle.py` | Loader check requires that input | `58c3adfa1e9c85ef475af6fcf1ebf7fdc8fed62a43fde13c957a31cf4b552a2a` |
  | `test/host_link/frame_rx/dune` (new) | Library `protemu_frame_rx_tests`, in `@runtest` | `1a30b1ba93a78896c6b5591839726a2d28bcc7bfc19ac13fdea55d5dab629f24` |
  | `test/host_link/frame_rx/frame_rx_testbench.ml` (new) | Cycle owner, PHY-level drivers, sampling, checks, diagnostics | `32f8545efdc82e62239f69ee0f03faa427d822a1ccc5ccff4bddaa80814a5947` |
  | `test/host_link/frame_rx/frame_rx_receive_tests.ml` (new) | 4 tests: legal receive and handoff | `9a8c3dd4dcacb51460763b52b1d5f6f7ab88fa4ccd838aa7994c6f015813845d` |
  | `test/host_link/frame_rx/frame_rx_validation_tests.ml` (new) | 9 tests: length, overrun, validation, correlation | `65230052ce2baf00004fb0a685bc2cf882e8b3d0b76be75f2ed3ed815d231d0b` |
  | `test/host_link/frame_rx/frame_rx_lifecycle_tests.ml` (new) | 9 tests: eligibility, retention, cancellation, probes | `17f6a5c4233253ab18640e84a536c6ae66873adbf73db42a7942e4d534d11fa6` |
  | `test/host_link/frame_rx/frame_rx_diagnostics_tests.ml` (new) | 4 negatives | `f1b32ba458fef6a3e55060ce67798f3a2e020676d6ffc75e4b4e96f20a992ef2` |
  | `docs/` | This record; [host_link_migration.md](host_link_migration.md), [verification.md](verification.md), [p3.5-hardware-loader.md](p3.5-hardware-loader.md), [construction-plan.md](construction-plan.md), [README.md](README.md) | — |

  The HL4a harness and the HL4c1 PHY suite, including their `dune` files, are
  byte-identical to the start. The focused suite lives in its own directory, so no
  existing test source changed, even mechanically. `serial_phy.ml`, `loader_core.ml`,
  `control_port.ml`, `wire.ml`, and `p3_loader_tb.v` are unchanged.

## Tool identity

opam switch `5.2.0+ox` (OCaml 5.2.0+ox), Dune 3.24.2; `hardcaml`, `ppx_hardcaml`, `core`,
`ppx_jane`, `ppx_expect`, `ppx_inline_test` `v0.18~preview.130.106+341`; `ocamlformat`
0.26.2+ox2; `hardcaml_asic` 0.1.0; host Verilator 5.020, Icarus Verilog 12.0, Yosys 0.33
(git sha1 `2584903a060`), Python 3.12.3. The loader checker's synthesis runs in
`ghcr.io/librelane/librelane:3.1.0.dev3` (the lock's `librelane_version`), image
`sha256:d109140b8f17fc54f4fca998beb8124f4949404ec52e339eebd2250854a18b5a`, whose Yosys is
0.66 (git sha1 `86f2ddebce7e98ce7cacc27e8a5c14cb53b51b51`). These are identical to HL4b1's
and served every baseline and final run.

## Extraction contract

Recorded before any logic was edited, and unchanged since. Derived from
`lib/host_link/hardware_loader.ml` at SHA-256
`856e0cfa1e663635338c0a4c328969c100bf8a69bea5723e08b7641cde98a774` (HL4b1 final).
Cycle *n* is the interval before edge *n*; a register assigned at edge *n* has its new
value in cycle *n* + 1. *a*, *s*: the cycles in which the host drives `LSEL_N` low and
high; the PHY reports them as `select_assert` in *a* + 2 and `select_release` in *s* + 2.

### Receiver state ownership

Every register below is in `Hardware_loader.I_Regs` before the extraction and assigned in
its one `compile`. Reset is the shared `Reg_spec`'s synchronous clear, to 0 for every field.
The same-cycle assignments to these registers come only from five statements, in this
order: the hold default, **start**, **receive**, **deselect**, and **disable** (last, so it
wins). No other loader statement assigns them.

| Register | Width | Purpose | Owner after | Start (`select_assert & enable_i & request_idle`) | Receive (`clock_rise & enable_i & selected & request_active`) | Deselect (`select_release & request_active`) | Disable | Read by |
| --- | ---: | --- | --- | --- | --- | --- | --- | --- |
| `byte_shift` | 8 | Partial byte, MSB first | `Frame_rx` | 0 | `{byte_shift[6:0], data}` | — | 0 | `completed_byte` |
| `bit_count` | 3 | Bits of the partial byte | `Frame_rx` | 0 | 0 at the eighth bit, else +1 | — | 0 | Receive, `request_complete` |
| `byte_count` | 4 | Completed bytes, saturating at 11 | `Frame_rx` | 0 | At a completed byte: 11 if already ≥ 11, else +1 | — | 0 | Header switch, `completed_is_crc`, `request_complete`, `correlation_valid` |
| `request_active` | 1 | A request selection is being received | `Frame_rx` | 1 | — | 0 | 0 | Start (`request_idle`), receive, deselect, `busy_o` |
| `request_overrun` | 1 | Sticky: a byte arrived with the count at 11 | `Frame_rx` | 0 | 1 at a completed byte with count ≥ 11 | — | 0 | `request_complete`, `parser_error` |
| `request_magic` | 8 | Byte 0 | `Frame_rx` | 0 | Completed byte at count 0 | — | 0 | `parser_error` |
| `request_version` | 8 | Byte 1 | `Frame_rx` | 0 | Completed byte at count 1 | — | 0 | `parser_error` |
| `request_tag` | 8 | Byte 2 | `Frame_rx` | 0 | Completed byte at count 2 | — | 0 | Every response's tag (loader) |
| `request_command` | 8 | Byte 3 | `Frame_rx` | 0 | Completed byte at count 3 | — | 0 | Dispatch (`command_is`), every response's command (loader) |
| `payload_length` | 16 | Bytes 4–5, little-endian | `Frame_rx` | 0 | Low byte at count 4 (high cleared), high byte at 5 | — | 0 | `completed_is_crc`, `request_complete`, `parser_error`; dispatch length checks (loader) |
| `payload` | 32 | Bytes 6–9, little-endian | `Frame_rx` | 0 | Byte at count 6 (upper cleared), 7, 8, 9 | — | 0 | Dispatch operands and bounds (loader) |
| `request_crc` | 8 | CRC-8 of the bytes before the CRC position | `Frame_rx` | 0 | `crc8_byte` of each completed byte that is not at the CRC position | — | 0 | `crc_match` update |
| `crc_match` | 1 | The byte at the declared CRC position equalled `request_crc` | `Frame_rx` | 0 | Set to the comparison at the CRC position | — | 0 | `parser_error` |

Start and receive are exclusive (`request_idle` needs `request_active` low, receive needs it
high). Receive and deselect are exclusive (selected high versus low). Start and deselect
are exclusive (the PHY's assert and release events). So each register's value is decided
by at most one of the three events plus the disable override, and keeping that
per-register statement order keeps every same-cycle priority.

These nine registers stay in `Hardware_loader`, unchanged: `dispatch`, `wait_read`,
`wait_abort`, `response_pending`, `response_active`, `response_store`, `response_shift`,
`response_length`, `response_bits`.

### Combinational expressions

| Expression | Owner after | Why |
| --- | --- | --- |
| `receiving`, `completed_byte`, `expected_crc_index`, `completed_byte_index`, `completed_is_crc` | `Frame_rx` | Byte assembly and CRC accumulation |
| `expected_frame_bytes`, `request_bytes`, `request_complete`, `parser_error` | `Frame_rx` | Deselect validation |
| `correlation_valid` (`byte_count >= 4`) | `Frame_rx` | Depends only on the private count |
| `crc8_byte` | `Frame_rx` | The receiver accumulates with it; the loader's response `crc8` calls `Frame_rx.crc8_byte` (the loader may depend on `Frame_rx`, not the reverse) |
| `Config.max_request_bytes`, `Config.request_byte_count_bits` | `Frame_rx` | Receiver sizing; no other user |
| `command_busy`, and the eligibility part of `request_idle` | `Hardware_loader` | Transaction state (dispatch, waits, retained response) |
| `payload_u16`, `payload_address`, `payload_word`, `address_in_range`, `length_in_range`, `request_address` | `Hardware_loader` | Command-specific operand decode and device bounds, checked at dispatch |
| `command_is`, `payload_length_is`, `payload_length_fits`, every `*_offer` | `Hardware_loader` | Command legality and fixed lengths are dispatch-stage decisions |
| `parser_error_response` (echo masked by `correlation_valid`) and every other response | `Hardware_loader` | Response construction |
| `check_wire_encodings` | `Hardware_loader`, unchanged | Elaboration-only; still checks the request header layout and the CRC parameters that `Frame_rx` relies on |

### Boundary decisions

- **Eligibility and arming.** `Hardware_loader` supplies `eligible_i` =
  `~command_busy & ~response_pending` (no command in dispatch or a READ/ABORT wait, and no
  retained response). `Frame_rx` owns arming because it owns `request_active`: a request
  starts at `select_assert_i & enable_i & ~request_active & eligible_i`. That is the
  existing `request_idle` split at its only owner boundary; the terms and their
  combinational timing are unchanged.
- **Request-active state** stays one register in `Frame_rx`, exposed as `active_o` for the
  loader's `busy_o`.
- **Handoff.** `Frame_rx` exposes `frame_end_o` = `select_release_i & request_active`, the
  existing deselect condition, as one signal read by both its own `compile` (clearing
  `request_active`) and the loader's (dispatch or error response). With it: `result_o`,
  the existing `parser_error` (a `Wire` result code, `Complete` for a valid frame), and
  `echo_valid_o`, the existing `correlation_valid`. The loader keeps the
  `result_o == Complete` decision, `dispatch`, and `parser_error_response`. Nothing is
  registered at the boundary: validation, handoff, and the dispatch arm stay in cycle
  *s* + 2.
- **Retained fields.** `tag_o`, `command_o`, `payload_length_o`, and `payload_o` are the
  registers themselves; `Frame_rx` is their only owner and the loader keeps no copy.
  Magic, version, CRC, `crc_match`, the counts, and overrun stay private; the loader sees
  their consequences only through `result_o` and `echo_valid_o`.
- **Stability during dispatch, waits, and a retained response.** After `frame_end_o`,
  `request_active` is 0, so receive cannot fire. Start needs `eligible_i`, which is 0 from
  the next cycle on: the same edge sets `dispatch` or `response_pending`, dispatch always
  leaves one of `wait_read`, `wait_abort`, or `response_pending` set, and each wait ends by
  setting `response_pending`. Eligibility returns only after commit clears
  `response_pending`. Until then only disable or reset can change the fields.
- **Reset and disable.** `Frame_rx` uses the same synchronous-clear `Reg_spec`. Its own
  final `when_ ~enable_i` clears all 13 fields, exactly as the loader's disable statement
  did. `frame_end_o`, like the old condition, is not gated by enable or reset; the loader's
  disable statement still overrides the `dispatch`/response assignment it causes.
- **Dependencies.** `Frame_rx` depends on Hardcaml and `Wire` only: not
  `Hardware_loader`, `Control_port`, response state, or `Serial_phy` (it takes the PHY
  observations as plain inputs). `Serial_phy` is unchanged.
- **Naming.** The 13 registers keep their field names, `reg_` prefix, widths, and
  statement order. `Hardware_loader` composes `Frame_rx` under
  `Scope.sub_scope scope "frame_rx"`, as it does `Serial_phy`, so the flattened register
  names gain that level.

### Interface

`Frame_rx.I`: `clock_i`, `reset_i`, `enable_i`; PHY observations `selected_i`, `data_i`,
`select_assert_i`, `select_release_i`, `clock_rise_i`; `eligible_i`.

| `Frame_rx.O` | Width | Definition | Timing |
| --- | ---: | --- | --- |
| `active_o` | 1 | `request_active` | 1 from *a* + 3 for an eligible start, 0 from *s* + 3 |
| `frame_end_o` | 1 | `select_release_i & request_active` | Exactly the release cycle *s* + 2 of an active request |
| `result_o` | 8 | `parser_error` | A function of the registers; the loader reads it with `frame_end_o` |
| `echo_valid_o` | 1 | `byte_count >= 4` | Same |
| `tag_o`, `command_o` | 8, 8 | Retained bytes 2 and 3 | Held from the completing edge until the next start or disable |
| `payload_length_o` | 16 | Retained bytes 4–5 | Same |
| `payload_o` | 32 | Retained bytes 6–9 | Same |

### Timing preserved

| Observation | Cycle (unchanged) |
| --- | --- |
| Request start | Armed at edge *a* + 2 if eligible then; the selection is ignored otherwise |
| Data sampled | The data level in each `clock_rise` cycle, at that edge |
| Validation and handoff | `frame_end_o` in *s* + 2 |
| Valid frame | `dispatch` set at edge *s* + 2, offer in *s* + 3 (HL4a `offer_after_deselect = 3`) |
| Deselect-validation error | Response stored at edge *s* + 2, `LRDY` from *s* + 3, one cycle before a valid frame's offer (HL4a `validation_error_ready = 3`) |
| Dispatch-stage error | Stored at the dispatch edge *s* + 3, `LRDY` from *s* + 4 |
| Reset/disable in the dispatch cycle | Offer still visible from `dispatch`, ungated, and refused by the core |

The contract above was implemented as recorded. No boundary change, dependency cycle, or
timing issue arose, and nothing needed escalation.

## What moved and what remained

| | Before | After |
| --- | --- | --- |
| 13 receiver registers: `byte_shift`, `bit_count`, `byte_count`, `request_active`, `request_overrun`, `request_magic`, `request_version`, `request_tag`, `request_command`, `payload_length`, `payload`, `request_crc`, `crc_match` | `Hardware_loader.I_Regs` | [`Frame_rx.I_Regs`](../lib/host_link/frame_rx.ml): same names, widths, reset values, and per-register statement order (hold, start, receive, deselect, disable) |
| `receiving`, `completed_byte`, CRC position, `request_complete`, `parser_error`, `correlation_valid` | Locals in `Hardware_loader.create` | `Frame_rx` locals, textually unchanged; exposed as `result_o` and `echo_valid_o` |
| `crc8_byte`; `Config.max_request_bytes`, `Config.request_byte_count_bits` | `Hardware_loader` | `Frame_rx.crc8_byte` (the loader's response `crc8` folds with it); `Frame_rx.Config` |
| Request start condition | `select_assert & enable_i & (~request_active & ~command_busy & ~response_pending)` | `Frame_rx`: `select_assert_i & enable_i & (~request_active & eligible_i)`, with `eligible_i = ~command_busy & ~response_pending` from the loader |
| Deselect | One `when_ (select_release & request_active)` clearing `request_active` and arming dispatch or the error response | `Frame_rx` computes `frame_end` once; its `compile` clears `request_active`, the loader's `when_ rx.frame_end_o` arms dispatch or the error response |
| Receiver clears on disable | In the loader's final `when_ ~enable_i` | `Frame_rx`'s own final `when_ ~enable_i` |
| Dispatch, READ/ABORT waits, refusal classification, every response (including `parser_error_response`), response storage, arming, shifting, replay, commit (9 registers) | `Hardware_loader` | `Hardware_loader`, unchanged |
| `check_wire_encodings` | `Hardware_loader` | `Hardware_loader`, unchanged checks; two comments now name `Frame_rx` |

`Hardware_loader`'s public `I`/`O` did not change. Its other edits: `request_tag`,
`request_command`, and `payload_length` are local aliases of the `Frame_rx` outputs,
`payload_u16` selects from `payload_o`, `busy_o` reads `active_o`, and the header and
`I_Regs` comments describe the new ownership. `Serial_phy` is unchanged.

## `Frame_rx` interface and temporal contract

See the interface and timing tables in the [contract](#interface) above; they are the
implemented interface. In summary:

- **Inputs:** `clock_i`, `reset_i` (synchronous), `enable_i`; the PHY observations
  `selected_i`, `data_i` (levels) and `select_assert_i`, `select_release_i`,
  `clock_rise_i` (one-cycle events); `eligible_i` from the loader.
- **Outputs:** `active_o`; `frame_end_o` (one cycle, the handoff); `result_o` (a
  `Wire.Result_code`: `Complete` or the framing error) and `echo_valid_o`; the retained
  `tag_o`, `command_o`, `payload_length_o`, `payload_o`.
- Every output except `frame_end_o` is a function of `Frame_rx` registers only;
  `frame_end_o` is combinational in `select_release_i`, so validation, handoff, and the
  loader's dispatch arm all happen in the release cycle *s* + 2, as before.
- `frame_end_o` is not gated by `enable_i` or `reset_i`, exactly like the old deselect
  condition. When reset or disable lands in the release cycle, the loader's own
  reset/disable clears the `dispatch` or response it would set.
- **Eligibility** is sampled only in the select-assert cycle. A selection that starts
  while ineligible is ignored until it ends; falling eligibility cannot end a started
  request (the composed loader never drops it while a request is active).
- **Retained fields** are the registers themselves. They hold from their completing edge
  until the next eligible selection's start edge, or disable, or reset. After the handoff,
  eligibility stays low through dispatch, any READ/ABORT wait, and the retained response
  until commit, so no selection can overwrite them while a consumer uses them.

### Why the loader's behavior is unchanged

- **Correlation retention.** `request_tag` and `request_command` are still one register
  each, read by every response. The same start condition, under the same eligibility terms,
  is the only non-cancellation writer after a handoff. HL4a's early-selection tests (dispatch,
  READ wait, ABORT wait; contract and delayed) pass unchanged, and
  [the lifecycle tests](#focused-tests-hl4c2) pin retention at the receiver boundary.
- **Sticky overrun and the bounded count.** The saturating `byte_count` and sticky
  `request_overrun` statements moved verbatim. The overrun branch also stops header and CRC
  capture, so no suffix is recaptured. Mutations M1 and M2 below show the focused and HL4a
  suites both detect a change.
- **Validation precedence.** `parser_error` moved verbatim: overrun (`Bad_length`), then
  incomplete, magic, version, length above four (`Bad_length`), and CRC. Mutation M4, a
  magic/version swap, is detected **only** by the focused suite.
- **One-shot dispatch timing.** The loader still sets `dispatch` at the release edge
  *s* + 2 and clears it at the next edge. `frame_end_o` is a combinational AND, not a
  register, so the offer stays at *s* + 3 and a deselect-validation error is still ready
  at *s* + 3, one cycle before a valid frame's offer. HL4a's `Latency` constants and every
  cycle assertion pass unchanged. Mutation M6 (a registered handoff) fails 22 HL4a tests.
- **Formal.** The emitted `loader_core` is proven sequentially equivalent to the HL4b1
  implementation ([below](#rtl-and-port-comparison)).

### Findings (current behavior, not changed)

No defect was found. The focused tests pin these existing properties:

- `payload_o` is positional: it holds whatever arrived at bytes 6 to 9, little-endian. After
  a shorter payload it includes the CRC byte (for INFO, `payload_o` = CRC; for a two-byte
  payload, bits 23:16 are the CRC). Dispatch uses only the declared bytes, except that
  READ's `readback_expected` operand carries `payload[31:16]`, which the core ignores when
  `readback_verify` is low.
- The `payload_length > 4` → `Bad_length` term of the validation is unreachable. A frame
  that passes the earlier checks has between 7 and 11 whole bytes equal to its length plus
  seven, so its length is at most four. Lengths five to eight are `Bad_length` through
  overrun, as the P3.5 record states. The term was kept, as required.
- A declared length whose high byte is nonzero, including values for which the 16-bit
  "length + 7" wraps to 0, 3, or 6, is `Incomplete`, never valid.
- `result_o` and `echo_valid_o` are also meaningful outside `frame_end_o`; after start,
  disable, or reset they read `Incomplete` with no echo. Only the loader's use in the
  release cycle matters.

## Focused tests (HL4c2)

[`test/host_link/frame_rx/`](../test/host_link/frame_rx/frame_rx_testbench.ml) (library
`protemu_frame_rx_tests`, in ordinary `@runtest`, 26 tests, about 2 s) follows the
per-module convention. The testbench owns the only simulator loop (`cycle`), pre-/post-edge
sampling, and finite waits (`wait_for`, default budget 100 cycles). It raises `Rx_failure`
with scenario, cycle, phase, what was checked, expected and actual values, and a transcript
of recent cycles' inputs and outputs. Every cycle it checks that each registered output's
post-edge sample equals the next pre-edge sample.

Stimulus is PHY-level: the drivers present an assert event with `selected` rising, a
release with it falling, and clock rises at least two cycles apart. Each bit drives its
complement on `data_i` in every non-rise cycle, so only a sample in the rise cycle yields
the frame. Legal frames come from `Wire.Request.encode`; malformed ones from a test-local
`Raw` builder (header bytes plus `Wire.Crc.compute`). Expected results, echoes, fields, and
cycles are written by hand from the P3.5 record; no expectation is computed from receiver
expressions. The one computed value is the CRC byte where it lands in `payload_o`, taken
from the stimulus.

| Test | Covers |
| --- | --- |
| receive: "every legal request is received with its exact fields and handed off once at deselection" | All ten commands, distinct tags including 0x00/0x80/0xff; exact tag, command, length, payload; 11-byte maximum frames; `frame_end_o` in exactly the release cycle; `active_o` exactly from assert + 1 through release; fields cleared by the next start |
| receive: "the short payloads keep their operands in the low bytes" | Operand in bytes 6–7, CRC in the positional payload |
| receive: "each byte is assembled most significant bit first ..." | Asymmetric bytes at rise spacings 2, 3, 8, 37, with complemented data off the rise cycle |
| receive: "a selected request may pause ..." | 10 000-cycle pauses after the assert, within a byte, between bytes, before deselect |
| validation: "truncated header, payload, and CRC ..." | 0–10 bytes of an 11-byte frame; `Incomplete`; echo from 4 bytes; field-by-field retention |
| validation: "a partial final byte ..." | 1–7 extra bits; the CRC byte cut short by 1–7 bits |
| validation: "whole extra bytes ..." | 1–4 extra bytes `Incomplete`; 5 (the twelfth byte) `Bad_length` |
| validation: "overrun is sticky ..." | Maximum frame + 1 byte; maximum frame + a full valid INFO; 12 zeros + INFO; header not recaptured; next eligible request clean |
| validation: "long prefixes of the historical counter-wrap shapes ..." | 11/15/16/32/48 zeros before LOAD_START or WRITE, and 5 000 zeros; `Bad_length` with zero fields |
| validation: "a declared length is checked against the bytes received; ..." | INFO carrying 4 and RUN carrying 2 are `Complete` with raw length; declared/carried mismatch `Incomplete`; lengths 5–8 `Bad_length`; high byte 0x01/0x04/0xff and wrap shapes 0xfff9/0xfffc/0xffff `Incomplete` |
| validation: "bad magic, version, and CRC ...; unknown commands and device bounds ..." | Magic 0xa4/0x5a, versions 0x11/0x00/0x20, all eight single-bit CRC errors; unknown commands 0x7f/0xff/0x15/0x23 and WRITE to 0x100 are `Complete` with raw fields |
| validation: "several defects resolve in the existing precedence" | Eight hand-written multi-defect frames pinning overrun > incomplete > magic > version > CRC |
| validation: "correlation just below and at the four-byte threshold ..." | 3 bytes (tag kept, echo invalid), 4 bytes (echo), INFO/tag 0 zero echo is `Incomplete`, empty selection |
| lifecycle: "a handed-off request's fields hold while ineligible ..." | Early selection in the dispatch cycle with a full frame, an overrunning and an empty selection, 5 000 idle cycles; fields stable every cycle; then a new request |
| lifecycle: "eligibility is sampled only in the select-assert cycle" | Eligible one cycle late: selection ignored, fields kept; eligible in the assert cycle: starts |
| lifecycle: "robustness: eligibility falling after the assert ..." | Labelled: the loader cannot drop eligibility mid-request |
| lifecycle: "reset and disable cancel at every receive and validation boundary" | Reset and disable, one cycle, mid-byte, after the header, after the whole frame, and in the release cycle (handoff still presented, ungated); no stale handoff, cleared fields, later INFO succeeds |
| lifecycle: "reset or disable held across an assert ..." | No start while cancelled; the retained fields are cleared |
| lifecycle: "disable clears a latched overrun ..." | Overrun cleared; no handoff |
| lifecycle: "clock rises while deselected and idle change nothing" | PHY-coherent LCLK activity while deselected |
| lifecycle: "robustness: a clock rise coincident with the assert or the release ..." | Labelled: outside the P3.5 envelope; neither rise is received |
| lifecycle: "robustness: a second assert while active ..." | Labelled: incoherent (the PHY cannot present it); no restart |
| Diagnostics (4) | A wrong result prints the full report (expect test); a one-cycle-late handoff raises; an echo at three bytes raises; a 25-cycle wait stops exactly at its budget |

The suite exercises `Frame_rx`'s boundary, not `Serial_phy`'s synchronizers, and is
synchronous digital evidence only.

### Sensitivity

Temporary production mutations to `lib/host_link/frame_rx.ml`, each applied by an exact
asserted substitution (`mutate.py` in the [appendix](#appendix-evidence-scripts)), run with
`./scripts/with-switch.sh dune build -j 5 @test/host_link/runtest` (all three suites), and
restored by copying the saved file. After each restore the SHA-256 was again
`63603e07…9faf9`.

| Mutation | Frame_rx suite failures | HL4a suite failures |
| --- | --- | --- |
| M1. Count wraps, never overruns (the historical defect: `if_ gnd` for the saturation test) | 4: extra bytes, overrun, prefix attacks, precedence | 2: maximum frame/twelfth byte; long prefixes |
| M2. Overrun never latched (count still saturates) | 5: the M1 four plus declared lengths | 2: the same |
| M3. Echo threshold three bytes | 2 (truncation, correlation), plus the three-byte-echo negative | 1: truncation/echo |
| M4. Version checked before magic | 1: precedence | **0** |
| M5. Eligibility ignored at start | 2: retention while ineligible; eligibility edges | 6: three early-selection tests, replay, final-bit rejection, arming |
| M6. Handoff registered one cycle late | 20 of 22 non-diagnostic tests (all but truncation and prefix attacks, which check only the fields presented in the release cycle), plus the late-handoff negative | 22, plus the offer-timing negative |

M4 shows the focused suite is not redundant: no HL4a case distinguishes the relative order
of the magic and version checks. M2 shows that without the sticky bit, a maximum frame plus
one byte would be handed off `Complete`.

A separate check covers the new checker assertion. With `frame_rx.ml` temporarily removed
from the loader inventory, `check-adopted-bundle.py --kind loader --metadata-only` failed on
`assert "lib/host_link/frame_rx.ml" in source_paths`. The inventory was restored
(SHA-256 `e2931db6…`) and the emitter rebuilt before the final checker run.

## Verification

Every Dune command used `-j 5` and ran strictly one after another; no two heavy jobs
(builds, tests, generation, synthesis, proofs, checkers) overlapped. `@loader-rtl`'s rules
and the checker were re-inspected first: they run Verilator (`-j 1`), Yosys, Docker, and
peer binaries, and make no nested Dune call. The capture script calls Dune only with
`-j 5`.

| Check | Result |
| --- | --- |
| Baseline, before any edit: `dune runtest test/host_link --force -j 5` | PASS, 8 s (32 HL4a + 11 PHY tests) |
| Baseline full loader checker `check-adopted-bundle.py --kind loader` | PASS, 5 min 11 s; identity `edb36d27…` (HL4b1's recorded final) |
| `./scripts/with-switch.sh dune runtest test/host_link --force -j 5` | PASS, freshly executed, 11 s: 32 HL4a, 11 Serial_phy, and 26 Frame_rx tests |
| `./scripts/with-switch.sh dune build @install @lint -j 5` | PASS |
| `./scripts/with-switch.sh dune build @runtest -j 5` | PASS, 28 s, no output |
| `./scripts/with-switch.sh dune build @loader-rtl --force -j 5` | PASS, 7 min 48 s, all three peer tiers freshly executed (reusable core, behavioral wrapper, production synthesis wrapper). Each printed `PASS p3.5 serial loader repair: timing, overrun rejection, replay/commit, status, recovery, production paths; 3/3 sensitivity phases=10, excluded 1/1 failures=10` |
| `./scripts/with-switch.sh dune build @rtl -j 5` | PASS, after the forced loader run. Other benches reused earlier results; their generated inputs are byte-identical (below) |
| `check-adopted-bundle.py --kind observable/memory/loader --metadata-only`, run separately | PASS, PASS, PASS |
| Full loader checker `check-adopted-bundle.py --kind loader` | PASS, 5 min 17 s (repeatable bundle and metadata, both wrapper roles against the peer, lint, and synthesis in the pinned image); identity `e9d72c78…` |
| `./scripts/with-switch.sh dune build -j 5 @lib/host_link/fmt @test/host_link/fmt` | PASS. The two changed library files and the five new test files were formatted with `dune promote <file>` one at a time; the changes were comment re-wrapping in formatter-managed regions. The repository `@fmt` backlog was not swept |
| `git diff --check`; tab/trailing-whitespace scan of the new files | PASS |
| `tinytapeout/test/p3_loader_tb.v` | Unchanged: no diff against `HEAD`, blob `2ffc20f0f302c5bad5fd9189056b22c8d8cc175d`, SHA-256 `40d9341f32ad02202f78784dbf4c6f9a7685691d8f7da78a50c2303cd2e2c9c9` |
| HL4a harness and HL4c1 suite | Byte-identical to the start; `Latency`, cycles, offers, responses, correlation, precedence, cancellation, arming, replay, and commit expectations untouched |
| `git diff --cached` | Empty; nothing staged |

Evidence tiers stay separate. The HL4a stub's offer counts are loader-dispatch evidence
only, not RAM writes or core execution. Actual RAM effects, the verified-image lifecycle,
and real core refusal and recovery remain the independent peer's (three tiers above) and
the HL3 core suites'.

## RTL and port comparison

`capture.sh` ([appendix](#appendix-evidence-scripts)) ran the HL3/HL4b1 generation
commands with identical options before and after the change, and emitted all three
bundles.

**Generator outputs.** 14 of 15 are byte-identical. The pre list digest is
`af7802af6dea77e3e6281f5864bc0760d2d40157500b1a31f73dd85016cbc7c1`, HL4b1's recorded post
digest, so the baseline is the accepted HL4b1 source. The post list digest is
`dcf4960e44d1be58fe66afd3cccc6a5b475f5ae48a095a7ff8451f69eda2ab0c`. Only `loader.v` differs:
`6f7aac12c816a9e55f7e4463d183c103e86ae4315e25ec952ffecc3c21f9129d` →
`026ea6e9d4b77c31a271ef1dc7d1f0468b4e9c0ef8f480b9c37005fa353c26cd`. The other 14 keep the
hashes listed in the [HL4b1 record](host_link_hl4b1_record.md#rtl-and-port-comparison).

**Bundle Verilog.** 4 of 6 are byte-identical: memory `src` `a6c3ad27…0d95`, memory
`simulation` `8b21fa31…3762`, observable `c275808a…0cb1` (both roles). `info.yaml`,
`constraints/top.sdc`, and `src/config.json` are identical for all three bundles (list
digest `42e943a74c4d93ec1744e785a799fb3311109fbbf1c9bba3cba3e01247d86702` before and after).

| Loader bundle file | Pre SHA-256 | Post SHA-256 |
| --- | --- | --- |
| `src/tt_um_leemperor_hardcaml_protemu_loader.v` | `6c03b88f53d6fba6c20b60da803bdb039e4d1e242fc36c00155dd3e9964a9817` | `4234f98d3539721a4e3ba55e12b03f549b8539af12db56a48e6485b4e518540f` |
| `simulation/tt_um_leemperor_hardcaml_protemu_loader.v` | `316698b26c1efc79db1932c7d21c6bb15f33d47fe5f39cd8799908e44dc071e2` | `0ce8cba4af993c7e90d20cb8101e621d4bb4420f0af2dd7546b02e699f12a3a3` |

**External ports.** `ports.py` read each module header and declarations (index, direction,
width, name). The inventories are identical before and after: `loader_core` 17 ports
(SHA-256 of the listing `8df490088f44e99e71f8204f5d1222948b38df2ac3092e1a3086b4605e7a0b97`),
both loader wrapper roles 8 ports (`aff782f713562caee6130f6b05de9db35b51b806cb2eb2e875a125d84d099707`),
and `integrated_core` 109 ports (`378492956340c2dacfdd01afb746ef171beddf124674f6d0e28b1485d05a4f12`).
These listing hashes differ from HL4b1's only because the listing format differs; each is
compared with its own pre listing. `Frame_rx` is flattened and adds no module or port.

**Every difference in the three changed files**, classified by `classify.py`:

1. The 13 receiver registers are renamed `loader$reg_*` → `loader$frame_rx$reg_*`: the
   `Scope.sub_scope` level.
2. One extra 1-bit `~enable_i` (`wire` + `assign`). `Frame_rx` builds its own inverter for
   its disable clause; Hardcaml does not share common subexpressions. `enable_i` inverters go
   from 12 to 13. The loader's former single inverter fed 19 muxes; now 13 (the receiver
   registers) use Frame_rx's and 6 use the loader's. This is the +2 lines in each file
   (`loader.v` 20 497 → 20 499; wrapper 24 314 → 24 316 and 20 780 → 20 782).
3. One reassociated 3-input AND in the request-start term:
   `(~request_active & ~command_busy) & ~response_pending` became
   `~request_active & (~command_busy & ~response_pending)`, the `eligible_i` boundary. Same
   gate count.
4. Hardcaml's anonymous `signal_<op>_<n>` names are renumbered where creation order
   changed. The anonymous registers keep identical names and widths (checked).

After undoing (1), `loader.v` differs in 68 lines and each wrapper role in 92. With
anonymous numbers masked, declarations differ only by one more `wire signal_not`, and
assignment shapes only by the extra `~` and the AND operand order.

**Formal sequential equivalence** (host Yosys 0.33), HL4b1's flow unchanged
([`core.ys`](#appendix-evidence-scripts)):

- Gold: pre `loader.v` (SHA-256 `6f7aac12…129d`, the HL4b1 implementation). Gate: post
  `loader.v` with `loader$frame_rx$reg_` → `loader$reg_` (`sed`, SHA-256 of the result
  `6dd1ceabd19eb2d996ea7a09989784fbec394a4f0ce90b1005fa37eb4b272173`). The rename only
  restores register names; no logic is edited.
- `proc -norom` keeps the core's case tables as logic. `rename -hide w:signal_* w:signal_reg_* %d`
  hides renumbered anonymous nets but keeps anonymous registers paired by name. No
  assumption or constraint is added. The reset is synchronous in `loader_core`; no
  `async2sync` is needed.
- Result: **1 331 of 1 331 `$equiv` cells proven** (166 matched name groups: every port,
  every named and anonymous register including the 13 moved ones, and named wires), 6 min
  34 s. Unproven points: none.
- Non-vacuity: the same script against a `loader.v` generated from the M4 source (magic and
  version checks swapped; SHA-256 `003a539b…e631`) leaves **6 cells unproven**, all in
  `loader$reg_response_store` bits 104–110 and 128 (the error response's result byte and
  CRC).
- **Loader wrapper, synthesis source role, untransformed:** 5 423 of 5 425 cells proven
  (8 min 44 s). The 2 unproven are the wrapper's own 2-bit reset synchronizer
  `signal_reg_288` (asynchronous preset to `2'b11`), which the induction flow does not model.
  It is outside the loader and textually identical in both files apart from its anonymous
  inverter's number (`signal_not_227` → `228`, both `~rst_n`).
- **Same wrapper with `async2sync`** after `proc` on both sides (modelling that preset as
  synchronous, identically for gold and gate): **5 425 of 5 425 proven** (24 min 9 s). This
  is a proof under that transformed reset model only, not unrestricted asynchronous
  reset assertion/release or physical reset equivalence. The untransformed result and its
  two unproven reset bits stand beside it.

## Generic synthesis

The configuration is the loader checker's own, unchanged: the pinned image above, `docker
run --rm --pull=never --network none`, and
`yosys -p 'read_verilog /bundle/src/tt_um_leemperor_hardcaml_protemu_loader.v; hierarchy
-check -top tt_um_leemperor_hardcaml_protemu_loader; synth -top
tt_um_leemperor_hardcaml_protemu_loader; stat'` on the production synthesis source. The
checker discards stdout, so `synth_stat.sh` ran the identical container and command on the
loader bundle emitted by each capture; the checker itself also passed before and after.

**Fresh baseline:** 25 192 cells with per-type counts identical to HL4b1's recorded "after"
column, so the next baseline is the accepted HL4b1 result with no source, tool, or
configuration difference. The unsplit 25 108 is kept for the cumulative comparison.

**Checker path, `tt_um_leemperor_hardcaml_protemu_loader`** (Yosys 0.66):

| Cell type | Unsplit (HL4b1 before) | HL4b1 accepted = HL4b2 before | HL4b2 after | Δ vs HL4b1 | Δ vs unsplit |
| --- | ---: | ---: | ---: | ---: | ---: |
| `$_ANDNOT_` | 496 | 485 | 465 | −20 | −31 |
| `$_AND_` | 7 907 | 8 025 | 8 022 | −3 | +115 |
| `$_DFFE_PP_` | 4 240 | 4 240 | 4 240 | 0 | 0 |
| `$_DFF_PN1_` | 2 | 2 | 2 | 0 | 0 |
| `$_DFF_P_` | 13 | 13 | 13 | 0 | 0 |
| `$_MUX_` | 592 | 588 | 566 | −22 | −26 |
| `$_NAND_` | 8 370 | 8 347 | 8 460 | +113 | +90 |
| `$_NOR_` | 491 | 430 | 429 | −1 | −62 |
| `$_NOT_` | 84 | 84 | 87 | +3 | +3 |
| `$_ORNOT_` | 456 | 469 | 420 | −49 | −36 |
| `$_OR_` | 554 | 631 | 641 | +10 | +87 |
| `$_SDFFE_PP0N_` | 3 | 3 | 3 | 0 | 0 |
| `$_SDFFE_PP0P_` | 804 | 804 | 804 | 0 | 0 |
| `$_SDFFE_PP1P_` | 6 | 6 | 6 | 0 | 0 |
| `$_SDFF_PP0_` | 315 | 315 | 315 | 0 | 0 |
| `$_XNOR_` | 552 | 525 | 530 | +5 | −22 |
| `$_XOR_` | 223 | 225 | 207 | −18 | −16 |
| **Cells** | **25 108** | **25 192** | **25 210** | **+18** | **+102** |
| Wires / wire bits | 25 450 / 66 614 | 25 534 / 66 698 | 25 551 / 66 715 | +17 / +17 | +101 / +101 |
| Public wires / bits | 7 041 / 48 205 | 7 041 / 48 205 | 7 041 / 48 205 | 0 | 0 |
| Ports / port bits | 8 / 43 | 8 / 43 | 8 / 43 | 0 | 0 |

`stat` report SHA-256: before `e690ecba13f76c07237c3ffd8c607cae65d180768f46b9c6f37a7f35d9bd75bf`,
after `e71c591821d26f2df7e5471050d5c7619edf070b0cb0c0a09cf07fb6dbc4157d`. A rerun of the
post source gave 25 210 again.

**Supplementary, `loader_core` with host Yosys 0.33** (the `@loader-core-rtl` command
without `-q`): identical before and after, 16 194 cells with identical per-type counts,
equal to HL4b1's.

### Investigation of the +18

Flip-flop counts are unchanged (5 383 in every variant below) and the netlists are proven
equivalent, so the delta is combinational mapping. `variants.py` builds Verilog-level
variants of the wrapper's synthesis source, each an exact asserted text edit, and
`synth_stat.sh` synthesizes each with the checker's container and command:

| Input | Cells | What it isolates |
| --- | ---: | --- |
| Pre (HL4b1 accepted) | 25 192 | — |
| Post (HL4b2) | 25 210 | — |
| Post, 13 register names mapped back to `loader$reg_*` | 25 210 | Register names: no effect |
| Pre, 13 register names mapped forward to `loader$frame_rx$reg_*` | 25 192 | Same |
| Post with the AND in its pre association | 25 210 | The reassociation: no effect |
| Pre with the AND in its post association | 25 192 | Same |
| Post with the extra inverter merged into the loader's | 25 151 | Removing the redundant inverter: −59 |
| Pre with a second inverter feeding the 13 receiver muxes | 25 180 | Adding it: −12 |
| Post with both reverted (declaration and assignment multisets identical to pre; only anonymous numbers and statement order differ) | 25 151 | Structure equal to pre, count −41 |
| Pre, consistent random anonymous renumbering, seeds 1/2/3 | 25 125, 25 186, 25 169 | Name-only sensitivity |
| Post, same seeds | 25 171, 25 170, 25 147 | Same |

Findings:

- The register renames and the AND reassociation have no effect in either direction.
- The redundant inverter has no consistent effect: removing it from the post source lowers
  the count by 59, and adding it to the pre source also lowers it, by 12.
- With both structural differences reverted, the post source is structurally identical to
  the pre source (checked by `classify.py`) yet maps to 25 151, 41 below it. Only anonymous
  numbering and statement order differ.
- Name-only renumbering moves the unchanged pre source over 25 125–25 192 and the post
  source over 25 147–25 210. In each sample, the actual emitted source is the highest.
  These finite samples demonstrate sensitivity; they do not establish a tolerance, and they
  do not prove that the +18 is caused only by names.

The best-supported explanation is this tool's sensitivity to anonymous naming and emission
order on logically equivalent input, as in HL4b1; the one structural addition, a logically
redundant inverter, is not shown to cost cells. The actual result nevertheless remains
**25 210 cells**, +18 on the previous accepted slice and +102 on the unsplit baseline. It is
accepted specifically for this slice by the planning decision below. No production naming
was changed to lower the count. No mapped-area, timing, or power claim follows.

### Planning acceptance decision

The owning planning session accepts HL4b2 and HL4c2 on 2026-09-24, including the actual
25 210-cell result: +18 (about 0.071%) versus HL4b1 and +102 (about 0.406%) versus the
unsplit baseline. These percentages describe the result, not an acceptance threshold.

The review covered this record and `Frame_rx` source, and confirmed current hashes for
the receiver, loader, PHY, HL4a testbench, and independent peer against the recorded
values. The planning session did not rerun regression, synthesis, or formal proofs;
their results remain the implementation evidence above.

Acceptance is supported by the unchanged receiver state/timing contract, unchanged
existing tests and external ports, passing independent peer tiers, complete recorded
`loader_core` equivalence with a detected precedence mutant, unchanged sequential-cell
counts, and the classified emitted changes (names, redundant inverter, associative AND
regrouping). Controlled experiments show synthesis sensitivity to equivalent inputs;
they do not isolate an exact names-only cause for the +18. The wrapper result remains
qualified by `async2sync`, with two reset points unproven in the untransformed flow.

No remaining functional or synthesis-acceptance blocker is identified for this slice.
Keep the positional payload contents, including CRC in unused payload bytes, and the
existing validation precedence/branch structure unchanged during subsequent extractions.
These are preserved behavior, not new cleanup work. In particular, the command adapter
must not interpret unused payload bytes as additional operands.

The next slice uses 25 210 as its previous accepted synthesis count and retains 25 108
as the original baseline. Every subsequent nonzero delta still requires investigation
and individual planning review. This acceptance does not loosen the existing gates.

## Bundle metadata and source identity

`source_revision` is `89a3fe8` in every bundle. Only `identity`, `source_inputs`, and the
loader's two Verilog roles changed; `info.yaml`, constraints, and `config.json` did not.

| Bundle | Identity before | Identity after | Source-input changes |
| --- | --- | --- | --- |
| observable | `7450eb5809862027878a0dca28b357b44da3f51c54a86f9dd01a93c8032a1320` | `e8bd21709b1fbe900cad57a7e3cb466efa0b25072b289b743f3929bc6650926c` | `bin/asic_bundle.ml` content |
| memory | `057c56215f519968d3b76a1e8d3dd8082da77b81f6b6313d4ce98ba964e846d7` | `7f83a38378e07e894d22efec951bd59e13628e092f983fd728f33c7857a14baf` | the same input |
| loader | `edb36d270ab71a001751ea74075beea0909f09163f040138697d81c12021424d` | `e9d72c7872378d9c9cba2db8c09f02e47c6c2dff9069d13596804bea26226f55` | the same, plus `hardware_loader.ml` content; added `lib/host_link/frame_rx.ml` (git status `??`), 35 → 36 inputs |

`Frame_rx` belongs only to the loader's closure (`Loader_core` → `Hardware_loader` →
`Frame_rx`); no other library module references it, so the observable and memory checker
expectations did not change. No Dune change was needed: `lib/dune` includes
subdirectories, the `generate_core` rules depend on the executable whose closure includes
the new module, and the loader-wrapper rule depends on `(source_tree ../../lib)`. The stray
`lib/staging/observed_transfer.ml` loader manifest entry was left untouched. These
working-tree identities will change again when the owner commits.

## Blockers, follow-ups, and remaining work

- **Resolved:** planning accepted the +18-cell generic-synthesis delta (+102 cumulative)
  for HL4b2; the actual count remains 25 210. See the decision above.
- No functional blocker. No pre-existing defect was found; the findings above are pinned
  current behavior.
- Remaining HL4b work: `Command_dispatch` and `Frame_tx`, each with its HL4c tests. HL4b
  and HL4c stay open. `crc8_byte` now lives in `Frame_rx` and the response path calls it;
  a `Frame_tx` extraction may want to move it to a shared place.
- `check_wire_encodings` still runs only when `Hardware_loader` is elaborated, so the
  request-layout and CRC-parameter checks `Frame_rx` relies on do not run when `Frame_rx`
  is built alone (as in its tests, which exercise those facts directly).
- Unchanged and out of scope: the `observed_transfer.ml` loader manifest entry, the
  host-simulator CLI stdout comparison gap, and the `@fmt` backlog.
- This is RTL-identity, formal-equivalence, Cyclesim, emitted-RTL peer, and generic
  synthesis evidence. It is not physical, timing, or mapped-area evidence. No physical flow
  was run.

## Appendix: evidence scripts

These ran from the repository root. Pre/post outputs lived in the session scratchpad; their
checksums and counts are recorded above. The scripts are reproduced verbatim so each result
can be regenerated.

### `capture.sh`

```sh
#!/usr/bin/env bash
# Capture all generator outputs, all three bundles, and their hashes into $1.
# Every Dune invocation uses -j 5; commands run sequentially.
set -euo pipefail
out="$1"
root="$(pwd)"
mkdir -p "$out/gen" "$out/bundles"
for mode in access executable integrated loader; do
  ./scripts/with-switch.sh dune exec -j 5 bin/generate_core.exe -- "$mode" "$out/gen/$mode.v"
done
./scripts/with-switch.sh dune exec -j 5 bin/generate.exe -- -output "$out/gen/p0.v" -module-name p0_observable
for block in pin_bank input_events timing byte_fifo_8 shift_lane observed_transfer \
  observed_transfer_bank primitive_demo uart_tx uart_slice; do
  ./scripts/with-switch.sh dune exec -j 5 bin/generate_p2.exe -- "$block" "$out/gen/$block.v"
done
./scripts/with-switch.sh dune build -j 5 bin/asic_bundle.exe
for kind in observable memory loader; do
  ./_build/default/bin/asic_bundle.exe "$kind" "$out/bundles/$kind" "$root"
done
(cd "$out/gen" && sha256sum *.v) > "$out/gen.sha256"
sha256sum "$out/gen.sha256" | cut -d' ' -f1 > "$out/gen.list-digest"
(cd "$out/bundles" && sha256sum */src/*.v */simulation/*.v) > "$out/bundle-verilog.sha256"
(cd "$out/bundles" && sha256sum */info.yaml */constraints/top.sdc */src/config.json) > "$out/bundle-meta.sha256"
sha256sum "$out/bundle-meta.sha256" | cut -d' ' -f1 > "$out/bundle-meta.list-digest"
for kind in observable memory loader; do
  printf '%s %s\n' "$kind" "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["identity"])' "$out/bundles/$kind/manifest.json")"
done > "$out/identities"
```

### `ports.py`

```python
#!/usr/bin/env python3
"""Print the port inventory (index, direction, width, name) of one module in a Verilog file.

Usage: ports.py FILE MODULE. Reads the ANSI or non-ANSI header: the port list order comes
from the module header, and each port's direction and width from its declaration.
"""
import re
import sys

text = open(sys.argv[1]).read()
module = sys.argv[2]
match = re.search(r"\bmodule\s+" + re.escape(module) + r"\s*\((.*?)\)\s*;(.*?)\bendmodule", text, re.S)
if not match:
    sys.exit(f"module {module} not found")
header, body = match.group(1), match.group(2)
names = [re.sub(r".*\s", "", p.strip()) for p in header.split(",") if p.strip()]
declared = {}
for direction, width, rest in re.findall(r"\b(input|output|inout)\b\s*(?:wire|reg)?\s*(\[[^\]]*\])?\s*([^;]*);", header + ";" + body):
    for name in rest.split(","):
        name = name.strip()
        if name:
            declared[name] = (direction, width or "[0:0]")
for index, name in enumerate(names):
    direction, width = declared[name]
    print(index, direction, width.replace(" ", ""), name)
```

### `synth_stat.sh`

```sh
#!/usr/bin/env bash
# Run the loader checker's exact generic-synthesis command, in its pinned image with its
# docker options, on the loader bundle in $1 (a directory holding src/<top>.v), and save
# the complete Yosys log to $2. The checker discards stdout; this keeps the stat report.
set -euo pipefail
bundle="$(cd "$1" && pwd)"
log="$2"
root="$(pwd)"
top=tt_um_leemperor_hardcaml_protemu_loader
image="ghcr.io/librelane/librelane:$(grep '^librelane_version=' tinytapeout/asic-dependencies.lock | cut -d= -f2)"
docker run --rm --pull=never --network none \
  -v "$bundle:/bundle:ro" -v "$root/tinytapeout/test:/test:ro" \
  --entrypoint sh "$image" -ec \
  "yosys -p 'read_verilog /bundle/src/$top.v; hierarchy -check -top $top; synth -top $top; stat'" \
  > "$log"
# The final stat block: from its last "Printing statistics." to the end.
awk '/Printing statistics\./ { buf = "" } { buf = buf $0 "\n" } END { printf "%s", buf }' "$log" \
  > "$log.stat"
```

### `classify.py`

```python
#!/usr/bin/env python3
"""Classify the differences between a pre and a post emitted Verilog file.

Usage: classify.py PRE POST

1. Undo the Frame_rx scope level: `$frame_rx$reg_` -> `$reg_` in POST (register names).
2. Report the raw differing-line count after that rename.
3. Mask Hardcaml's anonymous numbering (`signal_<op>_<n>` -> `signal_<op>_#`) and compare
   the multiset of declarations by kind and width, and the multiset of assignment
   right-hand-side shapes, printing only the kinds whose counts differ.
"""
import collections
import difflib
import re
import sys

pre = open(sys.argv[1]).read()
post = open(sys.argv[2]).read().replace("$frame_rx$reg_", "$reg_")
diff = [l for l in difflib.unified_diff(pre.splitlines(), post.splitlines(), lineterm="", n=0)
        if l[:1] in "+-" and not l.startswith(("+++", "---"))]
print("differing lines after the register rename:", len(diff))

mask = lambda text: re.sub(r"\bsignal_([a-z_]+?)_\d+\b", r"signal_\1_#", text)
def decls(text):
    return collections.Counter(
        re.sub(r"\s+", " ", m.group(0)).strip()
        for m in re.finditer(r"^\s*(wire|reg)\s*(\[[^\]]*\])?\s*[^;\s]+;", mask(text), re.M)
        for _ in [0]
        if True
    )
def shapes(text):
    return collections.Counter(
        re.sub(r"\s+", " ", m.group(1)).strip()
        for m in re.finditer(r"^\s*assign\s+[^=]+=\s*(.*?);", mask(text), re.M | re.S)
    )
for name, f in (("declarations", decls), ("assignment shapes", shapes)):
    a, b = f(pre), f(post)
    delta = {k: b[k] - a[k] for k in set(a) | set(b) if a[k] != b[k]}
    print(f"{name}: {sum(a.values())} -> {sum(b.values())}; differing kinds: {len(delta)}")
    for k, v in sorted(delta.items()):
        print(f"  {v:+d}  {k}")
```

### `mutate.py`

```python
#!/usr/bin/env python3
"""Apply one named sensitivity mutation to lib/host_link/frame_rx.ml (in place).

Each mutation is an exact, unique text substitution; the restore is a copy of the saved
file followed by a SHA-256 check (see run_mutation.sh).
"""
import sys

PATH = "lib/host_link/frame_rx.ml"

MUTATIONS = {
    # M1. The count wraps and never overruns: the historical counter-wrap defect.
    "M1": (
        "if_ (r.byte_count.value >=:. Config.max_request_bytes)",
        "if_ gnd",
    ),
    # M2. Overrun is never latched; the count still saturates.
    "M2": (
        "; r.request_overrun <--. 1\n",
        "; r.request_overrun <--. 0\n",
    ),
    # M3. Correlation threshold at three bytes instead of four.
    "M3": (
        "r.byte_count.value >=:. Wire.Request.Offset.command + 1",
        "r.byte_count.value >=:. Wire.Request.Offset.command",
    ),
    # M4. Version checked before magic.
    "M4": (
        "      (mux2 (r.request_magic.value <>:. Wire.Request.magic) (result_code Bad_magic)\n"
        "         (mux2 (r.request_version.value <>:. Wire.Version.byte) (result_code Bad_version)\n",
        "      (mux2 (r.request_version.value <>:. Wire.Version.byte) (result_code Bad_version)\n"
        "         (mux2 (r.request_magic.value <>:. Wire.Request.magic) (result_code Bad_magic)\n",
    ),
    # M5. Eligibility ignored at the start of a request.
    "M5": (
        "let request_idle = ~:(r.request_active.value) &: i.eligible_i in",
        "let request_idle = ~:(r.request_active.value) in",
    ),
    # M6. The handoff registered: validation presented one cycle after the release.
    "M6": (
        "let frame_end = i.select_release_i &: r.request_active.value in",
        "let frame_end = reg spec (i.select_release_i &: r.request_active.value) in",
    ),
}

name = sys.argv[1]
old, new = MUTATIONS[name]
text = open(PATH).read()
assert text.count(old) == 1, (name, text.count(old))
open(PATH, "w").write(text.replace(old, new))
print(f"applied {name}")
```

### `variants.py`

```python
#!/usr/bin/env python3
"""Build name-only and single-change variants of the loader wrapper's synthesis source.

Usage: variants.py PRE POST OUTDIR

Writes OUTDIR/<name>/src/tt_um_leemperor_hardcaml_protemu_loader.v for each variant, to be
synthesized with the checker's own container and command (synth_stat.sh). Every edit is an
exact, asserted text substitution on emitted RTL; none changes logic except where the name
says it adds or removes one of the two HL4b2 structural differences.

  post_names_back   : POST with loader$frame_rx$reg_* renamed to loader$reg_*
  pre_names_fwd     : PRE with the 13 receiver registers renamed to loader$frame_rx$reg_*
  post_one_inverter : post_names_back with Frame_rx's ~enable_i (signal_not_221) merged into
                      the loader's (signal_not_227): removes the redundant inverter
  post_and_pre      : post_names_back with the request-start AND in its pre association
  post_both         : both of the above; differs from PRE only in anonymous numbering and
                      declaration/assignment order
  pre_split_inv     : PRE with a second ~enable_i driving the 13 receiver-register muxes
  pre_and_post      : PRE with the request-start AND in its post association
  pre_renum_<s>, post_renum_<s> : consistent random renumbering of every anonymous
                      signal_<op>_<n> within its op, seeds 1..3 (logic unchanged)
"""
import pathlib
import random
import re
import sys

TOP = "tt_um_leemperor_hardcaml_protemu_loader"
REGS = ["bit_count", "byte_count", "byte_shift", "crc_match", "payload", "payload_length",
        "request_active", "request_command", "request_crc", "request_magic",
        "request_overrun", "request_tag", "request_version"]
pre = open(sys.argv[1]).read()
post = open(sys.argv[2]).read()
out = pathlib.Path(sys.argv[3])


def sub(text, old, new, count=1):
    assert text.count(old) == count, (old, text.count(old))
    return text.replace(old, new)


def write(name, text):
    d = out / name / "src"
    d.mkdir(parents=True, exist_ok=True)
    (d / f"{TOP}.v").write_text(text)


back = post.replace("loader$frame_rx$reg_", "loader$reg_")
write("post_names_back", back)
fwd = pre
for r in REGS:
    fwd = re.sub(r"loader\$reg_" + r + r"\b", "loader$frame_rx$reg_" + r, fwd)
write("pre_names_fwd", fwd)

# The redundant inverter: Frame_rx's (signal_not_221) and the loader's (signal_not_227)
# are both ~signal_wire_196 (enable).
one = sub(back, "    assign signal_not_221 = ~ signal_wire_196;\n", "")
one = sub(one, "    wire signal_not_221;\n", "")
one = one.replace("= signal_not_221 ?", "= signal_not_227 ?")
assert "signal_not_221" not in one
write("post_one_inverter", one)

AND_POST = ("    assign signal_and_857 = signal_not_219 & signal_not_27;\n",
            "    assign signal_and_858 = signal_not_220 & signal_and_857;\n")
AND_PRE = ("    assign signal_and_857 = signal_not_220 & signal_not_219;\n",
           "    assign signal_and_858 = signal_and_857 & signal_not_27;\n")


def and_to(text, src, dst):
    for s, d in zip(src, dst):
        text = sub(text, s, d)
    return text


write("post_and_pre", and_to(back, AND_POST, AND_PRE))
write("post_both", and_to(one, AND_POST, AND_PRE))

# PRE's single ~enable (signal_not_226) feeds 19 muxes; give the 13 that select the
# receiver registers' next values their own inverter, as the post source does.
split = sub(pre, "    wire signal_not_226;\n", "    wire signal_not_226;\n    wire signal_not_x_rx;\n")
split = sub(split, "    assign signal_not_226 = ~ signal_wire_196;\n",
            "    assign signal_not_226 = ~ signal_wire_196;\n    assign signal_not_x_rx = ~ signal_wire_196;\n")
RX_MUXES = ["1546", "1531", "1569", "871", "891", "1538", "1551", "1541", "1555", "753",
            "865", "878", "884"]
for m in RX_MUXES:
    split = re.sub(r"(assign signal_mux_\d+ = )signal_not_226( \? [^;]*: signal_mux_" + m + ";)",
                   r"\1signal_not_x_rx\2", split, count=1)
assert split.count("signal_not_x_rx ?") == 13, split.count("signal_not_x_rx ?")
write("pre_split_inv", split)
write("pre_and_post", and_to(pre, AND_PRE, AND_POST))


def renumber(text, seed):
    rng = random.Random(seed)
    names = sorted(set(re.findall(r"\bsignal_([a-z_]+?)_(\d+)\b", text)))
    by_op = {}
    for op, n in names:
        by_op.setdefault(op, []).append(n)
    mapping = {}
    for op, ns in by_op.items():
        shuffled = ns[:]
        rng.shuffle(shuffled)
        for a, b in zip(ns, shuffled):
            mapping[f"signal_{op}_{a}"] = f"signal_{op}_{b}"
    return re.sub(r"\bsignal_[a-z_]+?_\d+\b", lambda m: mapping.get(m.group(0), m.group(0)), text)


for seed in (1, 2, 3):
    write(f"pre_renum_{seed}", renumber(pre, seed))
    write(f"post_renum_{seed}", renumber(post, seed))
print("ok")
```

### `core.ys`

```text
read_verilog gold.v
rename loader_core gold
read_verilog gate.v
rename loader_core gate
proc -norom
opt_clean
rename -hide w:signal_* w:signal_reg_* %d
opt_clean
equiv_make gold gate equiv
hierarchy -top equiv
equiv_simple -seq 2
equiv_induct -seq 2
equiv_status -assert
```

The non-vacuity run used `core.ys` with `gate.v` replaced by the M4 `loader.v` (generated
with `./scripts/with-switch.sh dune exec -j 5 bin/generate_core.exe -- loader <file>` while
M4 was applied, then renamed with the same `sed`) and `equiv_status -assert` replaced by
`equiv_status`, so it reports the unproven cells instead of stopping.

`wgold.v` and `wgate.v` are the pre and post `src/tt_um_leemperor_hardcaml_protemu_loader.v`,
the gate with the same `sed 's/loader\$frame_rx\$reg_/loader$reg_/g'` rename.

### `wrapper_plain.ys`

```text
read_verilog wgold.v
rename tt_um_leemperor_hardcaml_protemu_loader gold
read_verilog wgate.v
rename tt_um_leemperor_hardcaml_protemu_loader gate
proc -norom
opt_clean
rename -hide w:signal_* w:signal_reg_* %d
opt_clean
equiv_make gold gate equiv
hierarchy -top equiv
equiv_simple -seq 2
equiv_induct -seq 2
equiv_status
```

### `wrapper_a2s.ys`

```text
read_verilog wgold.v
rename tt_um_leemperor_hardcaml_protemu_loader gold
read_verilog wgate.v
rename tt_um_leemperor_hardcaml_protemu_loader gate
proc -norom
async2sync
opt_clean
rename -hide w:signal_* w:signal_reg_* %d
opt_clean
equiv_make gold gate equiv
hierarchy -top equiv
equiv_simple -seq 2
equiv_induct -seq 2
equiv_status
```
