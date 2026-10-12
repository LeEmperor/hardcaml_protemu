# HL4b3 implementation record: `Command_dispatch` extraction (2026-09-25)

Status: HL4b3 (`Command_dispatch` extraction) and its HL4c3 focused tests are implemented and
verified by an agent in the working tree. **Not committed:** nothing is committed or
staged; the repository owner commits. This is the third child of
[HL4b](host_link_migration.md#hl4--link-decomposition). `Frame_tx` is not extracted, so HL4b
and HL4c remain open.

**Accepted by the owning planning session on 2026-09-25.** Every functional gate passed. Emitted
`loader_core` is proven sequentially equivalent to the accepted HL4b2 implementation,
external ports are identical, and the RTL keeps the same 163 state registers with the same
widths. But the loader checker's generic-synthesis count moved **25 210 → 24 431 cells
(−779)** against the accepted HL4b2 slice and **25 108 → 24 431 (−677)** cumulatively against
the unsplit baseline. The mapped flip-flop count also moved, 5 383 → 5 318 (−65). The
[investigation](#investigation-of-the-779) localizes both to the retained response store's
update form (fully for the flip-flop reduction, predominantly for the total count).
The [planning decision](#planning-acceptance-decision) accepts this specific delta.
No mapped-area, timing, or power claim follows.

The [P3.5 record](p3.5-hardware-loader.md) remains the wire and timing authority. No wire
value, codec policy, public port, timing requirement, `Control_port` field or contract, or
HL4a/HL4c1/HL4c2 expectation changed.

## Starting revision and local diff

- `HEAD` = `89a3fe88d7dc0381e1817d44e4a40c481a9868af` ("re-org phase 1", HL2), branch
  `bpurtell/scaf`. The owner had not committed since the HL4b2 review. The stash list was
  empty and nothing was staged.
- **Pre-existing, not HL4b3:** the uncommitted HL3, HL4a, HL4b1/HL4c1, and HL4b2/HL4c2 work:
  18 modified tracked files and 24 untracked files (the HL3, HL4a, HL4b1, and HL4b2
  records; `control_port.ml`, `serial_phy.ml`, `frame_rx.ml`; the HL4a harness and its
  `dune`; the `serial_phy/` and `frame_rx/` suites; and
  `test/integration/core_engine/core_engine_control_port_tests.ml`). Its `git diff`
  (tracked files) had SHA-256
  `600af3f385132ce6511a4c0e0978e22b313add27488c551a5612c1cd387a72cc`. Every production,
  test, and peer hash equalled the HL4b2 record's final value (`frame_rx.ml` `63603e07…`,
  `hardware_loader.ml` `76636744…`, `asic_bundle.ml` `e2931db6…`, checker `58c3adfa…`, all
  HL4a, `serial_phy/`, and `frame_rx/` test files). Only planning documents had changed
  since (the HL4b2 acceptance). A tar and SHA-256 list of all 42 pre-existing changed files
  were kept in the session scratchpad; at the end, every one that HL4b3 did not
  intentionally edit still had its starting hash (checked, [Verification](#verification)).

  Starting SHA-256 of the files HL4b3 touches, or must leave unchanged:

  | File | SHA-256 at start |
  | --- | --- |
  | `lib/host_link/hardware_loader.ml` | `766367444766dbd96376964239177305fa455634cdfd4576a22e9fba8d3c5b02` |
  | `lib/host_link/frame_rx.ml` (comments only) | `63603e078bdbc2fd8f4fe30bc9312abaae4b1b23f45e00a86bbe392f09f9faf9` |
  | `bin/asic_bundle.ml` | `e2931db6ba971718308b3b02dda60042072f7a7d9eac504c4fe14a97a55303c6` |
  | `tinytapeout/scripts/check-adopted-bundle.py` | `58c3adfa1e9c85ef475af6fcf1ebf7fdc8fed62a43fde13c957a31cf4b552a2a` |
  | `docs/host_link_migration.md` | `b195e87cae5da339ffa7eb192f214eeb7d5eec49f77a479d2e93f0fc94062384` |
  | `docs/verification.md` | `28dc5f0d7a33bde7a202c1ccc4f7b476b0eaac37b5021a6407728054bd86bc56` |
  | `docs/README.md` | `d060e21c8bccac8aecd9b550b4a61e64151e7899c95fed1eaf235f8329a35b57` |
  | `docs/p3.5-hardware-loader.md` | `ca749df60211b4be3128a7c7f90e1d618d14104d559adf081a65f0f4a103c4b8` |
  | `docs/construction-plan.md` | `a1f59f2ca8646ed292e5a100880da69d14b6db92b8200e69c0a4d91b3a3a97c9` |
  | `lib/host_link/serial_phy.ml` (unchanged) | `c82d32b859d6621f7e1dc0d9c43927a31075aba8013e0f45e281c8be311dbe23` |
  | `lib/host_link/loader_core.ml` (unchanged) | `ea0a8bf41c0dcf74f812b820218cc0cf0a5a64ac9776251cb5dc9742e5c8bfc1` |
  | `lib/emulator_core/control_port.ml` (unchanged) | `07d8af088cac01ab2b865efbed4da14dab7f2ff80284f951541f66223ffbb2b6` |
  | `test/host_link/dune` (unchanged) | `bc0ff5df082b703c2f2600282fdf78a67b0c99eae88510f230aa6a393ff4bc60` |
  | `test/host_link/hardware_loader_testbench.ml` (unchanged) | `70d473fc6d907d38df5b99cf27ed145e70b49b6959d071dc6c1d09530426c101` |
  | `test/host_link/hardware_loader_transaction_tests.ml` (unchanged) | `72d894cf60f4ea479bdaf040e65195c61a1cafa9aca480518dd7b83840670ac3` |
  | `test/host_link/hardware_loader_framing_tests.ml` (unchanged) | `4f9df46f12ba4e62483f3a5d90b369c73f074f2e7f27931c1728dac033c7fa46` |
  | `test/host_link/hardware_loader_cancellation_tests.ml` (unchanged) | `35362003d08759170f123cfb43ddd8a3bd7bfc5944fe51372daf949dc70e71f6` |
  | `test/host_link/hardware_loader_diagnostics_tests.ml` (unchanged) | `cb9bf2c6dcb63489fc171c8fe9d943e13854e50c49e17bc0a38949aec2ad7558` |
  | `test/host_link/serial_phy/*`, `test/host_link/frame_rx/*` (unchanged) | the final values in the [HL4b1](host_link_hl4b1_record.md) and [HL4b2](host_link_hl4b2_record.md#starting-revision-and-local-diff) records |

- HL4b3 diff (uncommitted, unstaged). Final SHA-256 of each non-doc file, frozen before
  the final runs and unchanged after them:

  | Path | Change | SHA-256 |
  | --- | --- | --- |
  | `lib/host_link/command_dispatch.ml` (new) | The dispatcher | `8abb80e03e02e144b736925151d28600674339fc81cb09f2c8d0b82a52dea3fe` |
  | `lib/host_link/hardware_loader.ml` | Composes `Command_dispatch`; 3 registers, S1–S4, and the dispatch/response-construction logic removed; P added | `bb4e8794e2e3011999c7451d50995fc3e9c5e4d77520de1bab56264c8ce0bc8e` |
  | `lib/host_link/frame_rx.ml` | Two comments name `Command_dispatch`; code unchanged | `9d927f9af8bbddcae2b91a6616e3f4178121c81ca8064114b9c53a1ef6a572d1` |
  | `bin/asic_bundle.ml` | Loader source inventory adds `lib/host_link/command_dispatch.ml` | `21a3cc864f9f59ff16d0625f1940caaf8a82d9bf23f9ac8349e046340a741b60` |
  | `tinytapeout/scripts/check-adopted-bundle.py` | Loader check requires that input | `658ada0d8eaa89b4da3df4a9fb88156a71e2484a27b20df5f02a439363a9b6a6` |
  | `test/host_link/command_dispatch/dune` (new) | Library `protemu_command_dispatch_tests`, in `@runtest` | `985b8c1e6ec18d3f551727842614642c9c00368aacdd7a0e25ba4a3637085572` |
  | `test/host_link/command_dispatch/command_dispatch_testbench.ml` (new) | Cycle owner, core stub, handoff drivers, sampling, checks, diagnostics | `5a464282d5a54126b0194530e4e054bc1296d48b36bcab32c4134d506b2445f3` |
  | `test/host_link/command_dispatch/command_dispatch_command_tests.ml` (new) | 7 tests: offers, operands, lengths, bounds, precedence | `c26d30ac00523325fdd48fb76816a96ca89af10e501d9a98d247f6cd0f948611` |
  | `test/host_link/command_dispatch/command_dispatch_response_tests.ml` (new) | 9 tests: INFO, STATUS, refusals, framing errors, correlation | `b167c7067d42de2a5b0b60f1df97385c54e39d2a2cf8216f657ce7bab4df5b46` |
  | `test/host_link/command_dispatch/command_dispatch_wait_tests.ml` (new) | 11 tests: READ/VERIFY and ABORT waits | `fff72045d6ed3d6886f996193cbb0f4a4c750ed0c8c1cfdbbef8bf0247188aab` |
  | `test/host_link/command_dispatch/command_dispatch_lifecycle_tests.ml` (new) | 7 tests: timelines, cancellation, priorities | `17fcdff775e88671d87fc5852b4f1db4f5384a7fd786264fa0cd568cb99fe855` |
  | `test/host_link/command_dispatch/command_dispatch_diagnostics_tests.ml` (new) | 5 negatives | `3df99087aebdb8483d4148faa9ba9d711c4716e34b32ed45ace0715b4f8b2518` |
  | `docs/` | This record; [host_link_migration.md](host_link_migration.md), [verification.md](verification.md), [p3.5-hardware-loader.md](p3.5-hardware-loader.md), [construction-plan.md](construction-plan.md), [README.md](README.md) | — |

  The HL4a harness and the HL4c1 and HL4c2 suites, including their `dune` files, are
  byte-identical to the start. The focused suite lives in its own directory, so no
  existing test source changed, even mechanically. `serial_phy.ml`, `loader_core.ml`,
  `control_port.ml`, `wire.ml`, and `p3_loader_tb.v` are unchanged. `frame_rx.ml` changed in
  two comments only (they named `Hardware_loader` as the handoff consumer and CRC user); its
  code is byte-identical.

## Tool identity

opam switch `5.2.0+ox` (OCaml 5.2.0+ox), Dune 3.24.2; `hardcaml`, `ppx_hardcaml`, `core`,
`ppx_jane`, `ppx_expect`, `ppx_inline_test` `v0.18~preview.130.106+341`; `ocamlformat`
0.26.2+ox2; `hardcaml_asic` 0.1.0; host Verilator 5.020, Icarus Verilog 12.0, Yosys 0.33
(git sha1 `2584903a060`), Python 3.12.3. The loader checker's synthesis runs in
`ghcr.io/librelane/librelane:3.1.0.dev3` (the lock's `librelane_version`), image
`sha256:d109140b8f17fc54f4fca998beb8124f4949404ec52e339eebd2250854a18b5a`, whose Yosys is
0.66 (git sha1 `86f2ddebce7e98ce7cacc27e8a5c14cb53b51b51`). These are identical to HL4b2's
and served every baseline and final run.


## Extraction contract

Recorded in this file before any production logic was edited, and unchanged since.
Derived from `lib/host_link/hardware_loader.ml` at SHA-256
`766367444766dbd96376964239177305fa455634cdfd4576a22e9fba8d3c5b02` (HL4b2 final and
accepted), `Control_port`, the P3.5 record, and the unchanged HL4a suite. Cycle *n* is the
interval before edge *n*; a register assigned at edge *n* has its new value in cycle
*n* + 1. *s* is the cycle in which the host drives `LSEL_N` high (the HL4a convention);
`Frame_rx.frame_end_o` is high in *h* = *s* + 2.

### Register ownership

Every register below is in `Hardware_loader.I_Regs` before the extraction and assigned in
its one `compile`. Reset is the shared `Reg_spec`'s synchronous clear, to 0. The
statements of that `compile`, in order, are:

| # | Statement | Assigns |
| --- | --- | --- |
| S0 | Hold defaults | all nine |
| S1 | `when_ rx.frame_end_o`: `Complete` → `dispatch <- 1`, else `set_response parser_error_response` | `dispatch`; store, length, pending |
| S2 | `when_ dispatch`: `dispatch <- 0`, then the command tree (below) | `dispatch`, `wait_read`, `wait_abort`; store, length, pending |
| S3 | `when_ (wait_read & readback_response_valid)`: `wait_read <- 0`, `set_response read_completion_response` | `wait_read`; store, length, pending |
| S4 | `when_ (wait_abort & abort_clean)`: `wait_abort <- 0`, `set_response complete_response` | `wait_abort`; store, length, pending |
| S5 | Response selection start (`select_assert & enable_i & response_pending & deselect_qualified`) | shift, bits, active |
| S6 | Shift at `clock_fall & response_active & ~response_drained` | shift, bits |
| S7 | `select_release & response_active`: clear active; if drained, commit (pending, bits ← 0) | active, pending, bits |
| S8 | `when_ ~enable_i` (last) | dispatch, wait_read, wait_abort, pending, active, bits |

`set_response (frame, length)` is `response_store <- frame; response_length <- length;
response_pending <- 1`.

| Register | Width | Owner after | Writers, in statement order | Read by |
| --- | ---: | --- | --- | --- |
| `dispatch` | 1 | `Command_dispatch` | S0 hold; S1 ← 1 for `Complete`; S2 ← 0; S8 ← 0 | every offer, the S2 tree, `busy` |
| `wait_read` | 1 | `Command_dispatch` | S0; S2 ← 1 (READ/VERIFY, fixed length, address in range, `readback_accepted`); S3 ← 0; S8 ← 0 | S3, `busy` |
| `wait_abort` | 1 | `Command_dispatch` | S0; S2 ← 1 (ABORT, fixed length, `abort_accepted`); S4 ← 0; S8 ← 0 | S4, `busy` |
| `response_pending` | 1 | `Hardware_loader` | S0; S1–S4 ← 1 (publication); S7 ← 0 at commit; S8 ← 0 | eligibility, S5, `serial_ready_o`, `busy_o` |
| `response_store` | `response_bits` | `Hardware_loader` | S0; S1–S4, later statement wins | S5 |
| `response_length` | 5 | `Hardware_loader` | S0; S1–S4, later statement wins | `response_drained` |
| `response_active`, `response_shift`, `response_bits` | 1, `response_bits`, 8 | `Hardware_loader` | S0, S5–S8 (unchanged) | response path |

After the extraction, `Command_dispatch`'s `compile` holds S0 (its three registers), S1,
S2, S3, S4, and S8 (its three registers) in that order. `Hardware_loader`'s holds S0 (six
registers), **P** (`when_ response_publish_o (set_response (response_frame_o,
response_length_o))`), S5, S6, S7, and S8 (its three registers). Each register keeps its
writers in the same relative order, so each keeps its same-cycle priority:

- `dispatch`, `wait_read`, `wait_abort`: their statements move unchanged.
- `response_store`, `response_length`: S1–S4 become three combinational `Always` wires in
  the dispatcher (`response_publish`, `response_frame`, `response_length`, default 0),
  assigned by the same statements in the same order. When any publication fires, the
  wires carry the frame of the last statement that fired, exactly the value S1–S4 chose;
  when none fires, P does not fire and the register holds, as before. This does not rely
  on S1–S4 being exclusive.
- `response_pending`: P sets it exactly when one of S1–S4 did; S7 and S8 still follow and
  still win.

S1–S4 are in fact exclusive in reachable states (`frame_end` needs an active request,
which starts only with `dispatch`, both waits, and `response_pending` low, and none can
become set while it is active; `dispatch` sets at most one wait and each wait ends by
publishing), but the construction above does not depend on that. S7 cannot coincide with a
publication either (`response_active` implies `response_pending`, which implies no request,
dispatch, or wait), and its order after P is kept anyway.

### Combinational expressions and helpers

| Item | Owner after | Why |
| --- | --- | --- |
| `payload_u16`, `payload_address`, `payload_word`, `address_in_range`, `length_in_range`, `request_address` | `Command_dispatch` | Operand interpretation and device bounds, checked at dispatch on the full 16-bit operand before narrowing |
| `command_is`, `payload_length_is`, `payload_length_fits`, every `*_offer` | `Command_dispatch` | Command recognition, fixed lengths, one-shot offers |
| `refusal_result`, `verify_mismatch`, `abort_clean` | `Command_dispatch` | Refusal classification, READ/VERIFY result, ABORT cleanup |
| Every response frame (`complete`, `refused`, `bad_length`, `image_bounds`, `bad_command`, `stop`, `read_response`, `info`, `status`, `parser_error`) and the `choose_response` selections | `Command_dispatch` | Response selection; see the handoff decision below |
| `response_frame`, `crc8`, `byte`, `result_code`, `low_byte`, `high_byte`, `check_payload`, `choose_response`; INFO facts (`isa_version`, `memory_layout`, `capabilities`) | `Command_dispatch` | Frame construction helpers; no other user |
| `crc8_byte` | `Frame_rx`, unchanged | Arrangement preserved: `Command_dispatch.crc8` folds `Frame_rx.crc8_byte` as the loader's `crc8` did. Moving it to a shared owner is the recorded `Frame_tx` follow-up |
| `command_busy` | `Command_dispatch`, as `busy_o` | `dispatch \| wait_read \| wait_abort`, the dispatcher's own state |
| Request eligibility `~command_busy & ~response_pending` | `Hardware_loader` | Composition: combines dispatcher and response-store state |
| `busy_o` | `Hardware_loader` | `rx.active_o \| dispatch.busy_o \| response_pending` |
| `response_drained`, `serial_data_o`, `serial_ready_o`, `set_response` | `Hardware_loader` | Response store, shifting, replay, commit |
| `Config.max_response_bytes`, `Config.response_bits` | Both, each from `Wire.Response.max_length` | The loader sizes its store; the dispatcher sizes its frame output. Both derive from the one `Wire` constant |
| `execution_fault`, `execution_phase`, `check_layout`, `check_wire_encodings` | `Hardware_loader`, unchanged checks | Elaboration only. They still cover the layouts `Command_dispatch` builds; comments name it |

### Boundary decisions

- **Handoff and framing errors.** `Command_dispatch` consumes `Frame_rx`'s handoff
  directly: `frame_end_i`, `result_i`, `echo_valid_i`, and the retained `tag_i`,
  `command_i`, `payload_length_i`, `payload_i`. S1 moves verbatim: a `Complete` frame arms
  `dispatch`, and any other result publishes `parser_error_response` combinationally in the
  same cycle *h*. Nothing is registered between `Frame_rx`'s validation and that
  publication, so a framing error is still stored at edge *h* and ready at *s* + 3, one
  cycle before a valid frame's offer.
- **Retained fields.** The dispatcher adds no request register. It reads `Frame_rx`'s
  retained fields combinationally in every cycle it uses them.
- **Response handoff: complete frame, not a description.** The dispatcher exports
  `response_publish_o`, `response_frame_o` (the full padded frame, `response_bits` wide),
  and `response_length_o` (5 bits), combinationally, in the cycle the old statement
  stored it. The loader stores them with P; there is no ready, queue, or pipeline stage.
  Exporting the complete frame moves every frame builder, CRC chain, and selection mux
  verbatim. A smaller description (result code plus payload kind) would require the
  loader to rebuild frames after the selection, merging the per-frame CRC chains into one:
  a different combinational structure. The complete frame is the least restructuring.
  Frame construction therefore moves with the dispatcher; the loader keeps storage,
  arming, shifting, replay, and commit.
- **Retention dependency and eligibility.** `Frame_rx`'s fields are read in *h* (framing
  error echo), the dispatch cycle (operands, bounds, lengths, every response's tag and
  command), and every cycle of a READ or ABORT wait (the completion response's tag and
  command; VERIFY's mismatch rule). The loader keeps eligibility
  `~dispatch.busy_o & ~response_pending`. The handoff edge sets `dispatch` or
  `response_pending`; dispatch sets a wait or `response_pending`; each wait ends by setting
  `response_pending`; only commit, disable, or reset clears it. So eligibility is low from
  *h* + 1 until commit, which covers every cycle the dispatcher reads the fields. In *h*
  itself `Frame_rx`'s own active request prevents a start.
- **Core offers and decisions.** The seven valids are `dispatch & command & fixed length
  & bound`, high only in the dispatch cycle *h* + 1 = *s* + 3; operands are driven
  continuously from the retained fields (READ's `readback_expected` carries
  `payload[31:16]`, which the core ignores without `readback_verify`). Decisions and
  status are sampled before the dispatch edge. Acceptance alone decides the outcome; the
  rejected signals stay unread.
- **Waits.** READ/VERIFY completes at the first cycle of `wait_read` with
  `readback_response_valid`; ABORT at the first cycle of `wait_abort` whose status shows
  cleanup. Neither has a timeout or retry, and a completion observed outside its wait is
  ignored.
- **Reset and disable.** The dispatcher uses the same synchronous-clear `Reg_spec` and ends
  its `compile` with S8 for its three registers. Its offers and publication outputs are not
  gated by enable or reset, exactly as before: an offer in a reset or disabled dispatch
  cycle is still visible and the core refuses it, and a publication in such a cycle is
  still written into `response_store`/`response_length` while the loader's S8 (or the
  reset clear) removes `response_pending`.
- **Dependencies.** `Command_dispatch` depends on Hardcaml, `Wire`, `Control_port`,
  `Protocol_core.Config` and `Protemu_isa.Pins` (widths and INFO facts), and
  `Frame_rx.crc8_byte` (the preserved CRC helper). It does not depend on
  `Hardware_loader`, `Serial_phy`, response storage, or `Frame_rx`'s block. `Frame_rx` and
  `Serial_phy` are unchanged and do not depend on it.
- **Naming.** The three registers keep their names, `reg_` prefix, widths, and statement
  order; the dispatcher is composed under `Scope.sub_scope scope "command_dispatch"`, as
  the PHY and receiver are, so their flattened names gain that level. The publication
  wires are `I_Wires` with the `wire_` prefix.

### Interface

`Command_dispatch.I`: `clock_i`, `reset_i`, `enable_i`; `frame_end_i`, `result_i` (8),
`echo_valid_i`, `tag_i` (8), `command_i` (8), `payload_length_i` (16), `payload_i` (32);
`control_decision_i`, `control_status_i` (the `Control_port` records, as in
`Hardware_loader.I`).

| `Command_dispatch.O` | Width | Definition | Timing |
| --- | ---: | --- | --- |
| `control_request_o` | record | The seven offers and their operands | Valids only in the dispatch cycle *h* + 1 |
| `busy_o` | 1 | `dispatch \| wait_read \| wait_abort` | Registered: 1 from *h* + 1 for a valid frame through the completion cycle |
| `response_publish_o` | 1 | S1–S4 publication | Combinational: *h* (framing error), *h* + 1 (immediate), the completion cycle (READ/ABORT) |
| `response_frame_o` | `response_bits` | The selected frame, MSB-first, zero-padded | Meaningful with `response_publish_o` |
| `response_length_o` | 5 | The selected frame's byte count | Same |

### Timing preserved

| Observation | Cycle (unchanged) |
| --- | --- |
| Framing-error publication | *h* = *s* + 2; stored at edge *s* + 2; `LRDY` from *s* + 3 |
| Core offer of a valid command | *s* + 3 (HL4a `offer_after_deselect = 3`) |
| Immediate publication (INFO, STATUS, LOAD_*, WRITE, RUN, STOP, refusals, dispatch-stage errors) | *s* + 3; `LRDY` from *s* + 4 |
| READ/VERIFY publication | The cycle of `readback_response_valid` in the wait (contract: offer + 2); `LRDY` one cycle later |
| ABORT publication | The first wait cycle showing cleanup (contract: offer + 1); `LRDY` one cycle later |
| Reset/disable in the dispatch cycle | Offer still visible, ungated; refused by the core; state cancelled |

The contract above was implemented as recorded. No boundary change, dependency cycle, or
timing issue arose, and nothing needed escalation. One composition detail follows from it:
`Frame_rx`'s eligibility now depends on `Command_dispatch.busy_o`, and the dispatcher is
created after the receiver it consumes, so `Hardware_loader` joins them with one 1-bit
`Signal.wire`. `busy_o` is a register expression, so the loop is not combinational; the
wire is one extra emitted net with no logic.

## What moved and what remained

| | Before | After |
| --- | --- | --- |
| `dispatch`, `wait_read`, `wait_abort` | `Hardware_loader.I_Regs` | [`Command_dispatch.I_Regs`](../lib/host_link/command_dispatch.ml): same names, widths, reset values, and per-register statement order (hold, S1, S2, S3/S4, disable) |
| Operand decode and bounds, command recognition and fixed lengths, the seven offers, refusal classification, VERIFY mismatch, ABORT cleanup condition | Locals in `Hardware_loader.create` | `Command_dispatch` locals, textually unchanged |
| Every response frame builder and the `choose_response` selections; `byte`, `result_code`, `low_byte`, `high_byte`, `check_payload`, `crc8`, `response_frame`; INFO facts in `Config` | `Hardware_loader` | `Command_dispatch`, textually unchanged apart from the two elaboration-error prefixes (`Command_dispatch:`) |
| S1 (handoff), S2 (dispatch tree), S3 (READ completion), S4 (ABORT completion) | Loader `compile`, calling `set_response` | Dispatcher `compile`, calling `publish`, which assigns the three `I_Wires` (`response_publish`, `response_frame`, `response_length`) instead of the store registers |
| Disable of `dispatch` and both waits | Loader's final `when_ ~enable_i` | Dispatcher's own final `when_ ~enable_i` |
| Response storage (`response_pending`, `response_store`, `response_length`), arming, shifting, replay, commit (6 registers) | `Hardware_loader` | `Hardware_loader`, with S1–S4 replaced by one statement P that stores the published frame |
| Request eligibility, `busy_o`, `serial_data_o`, `serial_ready_o` | `Hardware_loader` | `Hardware_loader`; eligibility and `busy_o` read `Command_dispatch.busy_o`; `control_request_o` passes the dispatcher's record through |
| `check_wire_encodings`, `execution_fault`, `execution_phase` | `Hardware_loader` | `Hardware_loader`, unchanged checks; comments now name `Command_dispatch` |

`Hardware_loader`'s public `I`/`O` did not change, nor did `Serial_phy`, `Frame_rx` (code),
`Loader_core`, `Control_port`, or `Wire`.

## `Command_dispatch` interface and temporal contract

The [interface and timing tables](#interface) above are the implemented interface. In
summary:

- **Inputs:** `clock_i`, `reset_i` (synchronous), `enable_i`; `Frame_rx`'s one-cycle
  `frame_end_i` with `result_i` and `echo_valid_i`; the retained `tag_i`, `command_i`,
  `payload_length_i`, `payload_i`; the `Control_port` `Decision` and `Status` records.
- **Outputs:** the `Control_port.Request` record; `busy_o` (registered: dispatch or a
  wait); `response_publish_o` with `response_frame_o` and `response_length_o`
  (combinational).
- **Response handoff.** The complete padded frame and its length, with a one-bit strobe,
  in the cycle the old statement stored them: *h* for a framing error, *h* + 1 for every
  immediate response, and the completion cycle for READ/VERIFY and ABORT. There is no
  ready: the loader never holds a retained response while a handoff can occur, because
  eligibility excludes it. `response_frame_o` is zero when nothing publishes.
- **Priority.** If several of S1–S4 fire in one cycle, the last one's frame is published,
  exactly as the last `set_response` won before. In the loader, P comes where S1–S4 were,
  so commit (S7) and disable (S8) still override `response_pending` after it. The
  robustness tests pin S3-over-S1 and S2-over-S1; the composed loader cannot present them.
- **Retained-field lifetime.** The dispatcher reads `Frame_rx`'s fields in *h* (error echo),
  in the dispatch cycle (operands, bounds, lengths, correlation), and in each wait cycle
  (correlation, VERIFY's result rule). `busy_o` is high from *h* + 1 through the completion
  cycle; `response_pending` is high from the edge after a publication until commit. So
  `eligible_i = ~busy_o & ~response_pending` is low from *h* + 1 until commit, and in *h*
  `Frame_rx`'s own active request excludes a start.
- **Offers, decisions, completion.** Offers are `dispatch`-qualified, one cycle, never
  repeated. Acceptance alone decides; the rejected signals stay unread. Status is sampled
  before the dispatch edge for classification and STATUS, and every wait cycle for ABORT
  cleanup. READ/VERIFY completes on the first `readback_response_valid` in `wait_read`;
  ABORT on the first `wait_abort` cycle with `halted`, `engines_idle`, and zero `pin_oe`,
  `software_claim`, and `engine_claim`. There is no timeout or retry.
- **Reset and disable** are not gated into the offer or the publication; see the contract.

### Why the loader's behavior is unchanged

- **Per-register statement order.** Every register keeps its writers in the same relative
  order (the contract's register table), and each new statement computes the same
  condition and value as the old one. The one restructuring is S1–S4 → publication wires
  → P, argued in the contract and proven below.
- **One-shot dispatch timing.** `dispatch` is still set at the handoff edge *h* and cleared
  at the next; the publication is combinational. HL4a's `Latency` constants and every cycle
  assertion pass unchanged, and the focused suite pins the same cycles at the dispatcher's
  boundary. Mutation M5 (every publication registered) fails 16 HL4a tests.
- **Correlation.** Every response still reads `Frame_rx`'s one `request_tag` and
  `request_command` registers; the dispatcher keeps no copy, and eligibility still keeps
  them stable. HL4a's early-selection and consecutive-tag tests pass unchanged.
- **Formal.** The emitted `loader_core` is proven sequentially equivalent to the HL4b2
  implementation, with every loader register, including all of `response_store`, paired by
  name ([below](#rtl-and-port-comparison)).

### Findings (current behavior, not changed)

No defect was found. The focused tests pin these existing properties:

- STATUS carries `pc[15:0]` of the 17-bit PC; bit 16 is dropped (the existing projection).
- READ's `readback_expected` operand is `payload[31:16]`, which after a two-byte payload
  holds the CRC byte; the core ignores it without `readback_verify`. The other unused
  operands likewise follow the positional payload.
- Offers and publications are ungated by reset and disable. In a cancelled dispatch cycle
  the dispatcher presents the refusal the core's forced refusal implies (for example
  `Image_bounds` while halted and idle), and a STATUS presents the `Enabled` flag clear
  under disable. The loader's own reset or disable discards that response.
- A READBACK response pulse in the dispatch cycle itself is ignored: the wait starts at
  that cycle's edge. The real core cannot produce it (item 5 puts the pulse at offer + 2).
- A second handoff in the dispatch cycle does not re-arm dispatch, and a failed one there
  does not replace the dispatch response; a failed handoff coinciding with a READ
  completion publishes the completion. None can occur in the composed loader.
- Unknown commands are `Bad_command` whatever their declared length; fixed lengths are
  compared on all 16 bits.

## Focused tests (HL4c3)

[`test/host_link/command_dispatch/`](../test/host_link/command_dispatch/command_dispatch_testbench.ml)
(library `protemu_command_dispatch_tests`, in ordinary `@runtest`, 39 tests, about 3 s)
follows the per-module convention. The testbench owns the only simulator loop (`cycle`),
pre-/post-edge sampling, and finite waits (`wait_for`, default budget 100 cycles). It raises
`Dispatch_failure` with scenario, cycle, phase, what was checked, expected and actual
values, and a transcript of recent cycles' inputs, offers, publications, and status. Every
cycle it also checks that the offer does not change when the stub applies its decision, and
that `busy_o`'s post-edge sample equals the next pre-edge sample.

Stimulus is `Frame_rx`'s handoff: a one-cycle `frame_end_i` with the retained fields, which
stay presented afterwards. Legal handoffs come from `Wire.Request.encode` with the
positional payload register (bytes 6–9, so the CRC byte lands in a short payload); raw
ones supply header values the codec will not build. A test-only `Core_stub` answers the
`Control_port` with contract-faithful decisions, READBACK responses at offer + 2, and ABORT
cleanup at offer + 1; delayed, withheld, injected, and incoherent variants are labelled
robustness probes. Published frames are read with `Wire.Response.decode` (software CRC)
and their padding checked zero; one INFO frame is also checked byte-for-byte against a CRC
computed in the test itself. Expected offers, full request records, responses, and cycles
are written by hand from the P3.5 record, `control_port.ml`, and the contract above.

| Test | Covers |
| --- | --- |
| command: "each immediate command is offered once ..." | INFO/STATUS offer nothing; LOAD_START, WRITE, LOAD_COMPLETE, RUN, STOP: one offer at *h* + 1, the whole request record (all operands, including unused ones), response at *h* + 1, `busy_o` only at *h* + 1 |
| command: "READ, VERIFY, and ABORT are offered once and wait; ..." | One offer each; READ's expected operand is the stimulus CRC byte; READ published at offer + 2, ABORT at offer + 1; busy windows |
| command: "nothing is offered while idle, while waiting, or after completion" | 2 000 idle cycles; a never-completing READ (robustness) keeps one offer; 3 000 cycles after a STOP |
| command: "unknown command bytes publish Bad_command ..." | 0x02, 0x0f, 0x15, 0x23, 0x7f, 0x80, 0xff, and unknown bytes with lengths 2 and 4 |
| command: "every known command with a wrong fixed length ..." | 40 wrong lengths, four for each of the ten commands; robustness: 0x0100, 0x0102, 0x0404, 0xff00 (a matching low byte does not pass) |
| command: "device bounds are checked on the full sixteen-bit operand ..." | LOAD_START 1, 0xff, 0x100 offered (narrowed operand); 0, 0x101, 0x201, 0x300, 0x1000, 0xffff `Image_bounds`; WRITE 0 and 0xff offered; WRITE/READ/VERIFY at 0x100, 0x200, 0x1ff, 0xff00, 0xffff `Image_bounds`, no offer |
| command: "results resolve in the existing precedence ..." | Length before bounds, bounds before the core (which would refuse), then refusal classification |
| response: "INFO reports the fixed descriptor whatever the status" | Decoded descriptor under three statuses; raw bytes of one frame with an in-test CRC |
| response: "STATUS reports the status observed in its dispatch cycle" | Different status in the handoff and following cycles; halted-idle, running, every flag with maximal counters and fault/phase, the 17-bit PC projection, and raw payload bytes |
| response: "accepted immediate operations report Complete; STOP ... Accepted_pending ..." | STOP accepted while halted and while executing |
| response: "a refused command reports the class of the status observed ..." | Six commands × five statuses: 0x20, 0x20 with engines idle, 0x21, 0x22 (RUN) / 0x23, 0x23 with a valid image |
| response: "robustness: a refused STOP or ABORT ..." | Labelled: refusal classes, and a refused ABORT does not wait |
| response: "robustness: acceptance alone decides; ..." | Labelled: both decisions low is a refusal; both high is an acceptance (RUN and READ) |
| response: "framing errors publish in the handoff cycle, ..." | Five results × four raw tag/command pairs: published at *h*, echoed raw, never busy, no offer |
| response: "a framing error without an echo zeroes tag and command, ..." | Retained tag/command bytes masked; INFO with tag 0 remains distinguishable by its result |
| response: "every response carries the handed-off tag and command, ..." | Ten consecutive distinct tags and commands, including 0x00, 0x80, 0xff |
| wait: "READ publishes the word in the response cycle and offers once" | Contract timing, busy window |
| wait: "VERIFY reports a match as Complete and a mismatch with the actual word" | Match, low-bit and high-bit mismatch |
| wait: "robustness: READ ignores readback_response_match" | Labelled: match driven high for READ |
| wait: "robustness: a delayed READ response ..." | Labelled: delays 1, 5, 100, 3 000; one offer; publication follows the pulse |
| wait: "robustness: a READ response that never arrives ..." | Labelled: 5 000 cycles busy with one offer; disable ends it; a later pulse is ignored |
| wait: "robustness: a READBACK response pulse is consumed only in the READ wait" | Labelled: stray pulses while idle, in the dispatch cycle, during an ABORT wait, after completion |
| wait: "inputs the boundary contract leaves free do not disturb ..." | `result_i`, `echo_valid_i`, and status change during a VERIFY wait and an ABORT wait |
| wait: "ABORT completes at the first wait cycle whose status shows cleanup" | From execution; already clean at the offer (first wait cycle, not the offer cycle) |
| wait: "each missing cleanup condition prevents ABORT completion" | Labelled (withheld cleanup): each of the five conditions alone blocks for 50 cycles; unrelated fields (fault, phase, load, PC) do not |
| wait: "robustness: staged and delayed ABORT cleanup ..." | Labelled: four stages, then the last condition; delays 1 and 7 |
| wait: "reset and disable cancel an ABORT wait; ..." | No publication when cleanup appears afterwards |
| lifecycle: "dispatch, waits, and publications follow the handoff at exact cycles" | Framing error, STOP, READ, ABORT timelines; never busy in a handoff cycle |
| lifecycle: "reset or disable in the handoff cycle ..." | Valid frame not armed; framing error presented in that cycle only; fresh INFO afterwards |
| lifecycle: "reset or disable in the dispatch cycle: ..." | LOAD_START, READ, ABORT, STOP: the offer is visible and refused, the refusal is presented, nothing follows; STATUS under disable |
| lifecycle: "reset or disable at each READ wait boundary ..." | First wait cycle (no publication) and response cycle (presented, then nothing) |
| lifecycle: "reset or disable in the ABORT cleanup cycle ..." | Presented, then nothing |
| lifecycle: "robustness: a READ completion coinciding with a framing-error handoff ..." | Labelled: S3 over S1 |
| lifecycle: "robustness: a handoff in the dispatch cycle ..." | Labelled: S2 over S1, and no re-arm |
| Diagnostics (5) | A wrong refusal class prints the full report (expect test); a one-cycle-late publication, a repeated offer, and a wrong tag each raise; a 25-cycle wait stops exactly at its budget |

The suite exercises `Command_dispatch`'s boundary with a stub, not the core's arbitration,
RAM, execution, or cleanup timing, and is synchronous digital evidence only.

### Sensitivity

Temporary production mutations to `lib/host_link/command_dispatch.ml`, each applied by an
exact asserted substitution (`mutate.py` in the [appendix](#appendix-evidence-scripts)),
run with `./scripts/with-switch.sh dune build -j 5 @test/host_link/runtest` (all four
suites), and restored by copying the saved file (`run_mutation.sh`). After each restore
the SHA-256 was again `057254f3…3abb` (the source at that point; later comment-only edits
produced the final hash above). Counts are failing tests per suite, from `tally.sh`.

| Mutation | Command_dispatch suite | HL4a suite | Frame_rx, Serial_phy |
| --- | --- | --- | --- |
| M1. `dispatch` never cleared: repeated offers | 33 | 17 | 0, 0 |
| M2. Refusal checks engines before execution | 3 (refusal matrix, refused STOP/ABORT, precedence) | 1 | 0, 0 |
| M3. ABORT cleanup ignores engine claims | 1 (missing conditions) | 1 | 0, 0 |
| M4. Framing-error tag echoed without `echo_valid` | 1 (zero echo) | 1 | 0, 0 |
| M5. Every publication registered one cycle late | 32 | 16 | 0, 0 |
| M6. Accepted STOP while halted reports `Complete` | 3 | 2 | 0, 0 |
| M7. Address bound checked on the 9-bit narrowed address | 2 (bounds, precedence) | 1 | 0, 0 |
| M8. VERIFY never mismatches | 2 | 1 | 0, 0 |
| M9. READBACK pulse completes outside the READ wait | 2 (stray pulses, never-arriving READ) | 1 | 0, 0 |
| M10. RUN decided from `run_rejected` instead of acceptance | 1 (acceptance alone decides) | **0** | 0, 0 |
| M11. Fixed lengths compared on the low byte only | 1 (wrong fixed lengths) | **0** | 0, 0 |
| M12. LOAD_START bound checked on the 9-bit narrowed length | 1 (device bounds) | **0** | 0, 0 |

M10–M12 show the focused suite is not redundant: the HL4a stub's decisions are coherent,
`Frame_rx` never hands off a `Complete` frame with a length above four, and no HL4a case
uses a LOAD_START length that aliases in nine bits. M5 is the one-cycle
publication-shift risk and M1 the repeated-offer risk; M3, M2, and M4 are premature ABORT
completion, wrong refusal classification, and lost correlation.

A separate check covers the new checker assertion: see [Verification](#verification).

## Verification

Every Dune command used `-j 5`, and heavy jobs (builds, tests, generation, synthesis,
proofs, checkers, mutation runs) ran one after another. One exception is recorded: while
the 21-minute `async2sync` wrapper proof was running, one formatter check
(`dune build -j 5 @lib/host_link/fmt`, two files) was started by mistake. No other Dune,
synthesis, or checker job overlapped a proof. `@loader-rtl`'s rules and the checker were
re-inspected first: they run Verilator (`-j 1`), Yosys, Docker, and peer binaries and make
no nested Dune call; the checker uses the prebuilt `_build/default/bin/asic_bundle.exe`,
built with `-j 5` before each checker run. `capture.sh` calls Dune only with `-j 5`.

| Check | Result |
| --- | --- |
| Baseline, before any edit: `dune runtest test/host_link --force -j 5` | PASS, 7 s (32 HL4a + 11 PHY + 26 receiver tests) |
| Baseline capture and synthesis | Generator digest, bundle hashes, identities, port listings, and 25 210 cells all equal HL4b2's recorded final values ([above](#rtl-and-port-comparison)) |
| `./scripts/with-switch.sh dune runtest test/host_link --force -j 5` | PASS, freshly executed, 14 s: 32 HL4a, 11 Serial_phy, 26 Frame_rx, and 39 Command_dispatch tests |
| `./scripts/with-switch.sh dune build @install @lint -j 5` | PASS |
| `./scripts/with-switch.sh dune build @runtest -j 5` | PASS, 28 s, no output |
| `./scripts/with-switch.sh dune build @loader-rtl --force -j 5` | PASS, 7 min 41 s, all three peer tiers freshly executed (reusable core, behavioral wrapper, production synthesis wrapper). Each printed `PASS p3.5 serial loader repair: timing, overrun rejection, replay/commit, status, recovery, production paths; 3/3 sensitivity phases=10, excluded 1/1 failures=10` |
| `./scripts/with-switch.sh dune build @rtl -j 5` | PASS, after the forced loader run. Other benches reused earlier results; their generated inputs are byte-identical |
| `check-adopted-bundle.py --kind observable/memory/loader --metadata-only`, run separately | PASS, PASS, PASS |
| Full loader checker `check-adopted-bundle.py --kind loader` | PASS, 5 min 20 s (repeatable bundle and metadata, both wrapper roles against the peer, lint, and synthesis in the pinned image) |
| Checker assertion negative | With `command_dispatch.ml` temporarily removed from the loader inventory, `--kind loader --metadata-only` failed on `assert "lib/host_link/command_dispatch.ml" in source_paths`. The inventory was restored (SHA-256 `21a3cc86…9b60`), the emitter rebuilt, and the check passed again |
| `./scripts/with-switch.sh dune build -j 5 @lib/host_link/fmt @test/host_link/fmt` | PASS. The two changed library files and the seven new test files were formatted with `dune promote <file>`; library changes were comment re-wrapping in formatter-managed regions. The repository `@fmt` backlog was not swept |
| `git diff --check`; tab/trailing-whitespace scan of the new files | PASS |
| Final capture after the last (comment-only) source edits | All 15 generator outputs and 6 bundle Verilog files identical to the analysed and proven post RTL |
| Pre-existing files | The 33 of 42 not intentionally edited keep their starting SHA-256 |
| `tinytapeout/test/p3_loader_tb.v` | Unchanged: no diff against `HEAD`, blob `2ffc20f0f302c5bad5fd9189056b22c8d8cc175d`, SHA-256 `40d9341f32ad02202f78784dbf4c6f9a7685691d8f7da78a50c2303cd2e2c9c9` |
| HL4a harness, HL4c1 and HL4c2 suites | Byte-identical to the start; `Latency`, cycles, offers, responses, correlation, precedence, cancellation, arming, replay, and commit expectations untouched |
| `git diff --cached`; `HEAD` | Empty, nothing staged; `HEAD` still `89a3fe8`; stash list empty |

Evidence tiers stay separate. Stub offer counts, in both the HL4a harness and this suite,
are dispatch evidence only, not RAM writes, core cleanup, or execution. Actual RAM effects,
the verified-image lifecycle, and real core refusal and recovery remain the independent
peer's (three tiers above) and the HL3 core suites'.

## RTL and port comparison

`capture.sh` (HL4b2's, unchanged; [appendix](#appendix-evidence-scripts)) ran the same
generation commands with identical options before and after the change, and emitted all
three bundles.

**Generator outputs.** 14 of 15 are byte-identical. The pre list digest is
`dcf4960e44d1be58fe66afd3cccc6a5b475f5ae48a095a7ff8451f69eda2ab0c`, HL4b2's recorded post
digest, so the baseline is the accepted HL4b2 source. The post list digest is
`ab499eb0801a5adfc2dd7c8265e1add061c489119de7793bdb95b0478d3d15a3`. Only `loader.v` differs:
`026ea6e9d4b77c31a271ef1dc7d1f0468b4e9c0ef8f480b9c37005fa353c26cd` →
`07f154d9fe22b5ce2cb4b9726b397969fd10d6b3481cb031a6ffaaef99655fdd`. The other 14 keep the
hashes listed in the [HL4b1 record](host_link_hl4b1_record.md#rtl-and-port-comparison).

**Bundle Verilog.** 4 of 6 are byte-identical: memory `src` `a6c3ad27…0d95`, memory
`simulation` `8b21fa31…3762`, observable `c275808a…0cb1` (both roles). `info.yaml`,
`constraints/top.sdc`, and `src/config.json` are identical for all three bundles (list
digest `42e943a74c4d93ec1744e785a799fb3311109fbbf1c9bba3cba3e01247d86702` before and after).

| Loader bundle file | Pre SHA-256 | Post SHA-256 |
| --- | --- | --- |
| `src/tt_um_leemperor_hardcaml_protemu_loader.v` | `4234f98d3539721a4e3ba55e12b03f549b8539af12db56a48e6485b4e518540f` | `0c748fed19afa11026dff603d8d85382aa279a34decd81418c53dcf81fa38770` |
| `simulation/tt_um_leemperor_hardcaml_protemu_loader.v` | `0ce8cba4af993c7e90d20cb8101e621d4bb4420f0af2dd7546b02e699f12a3a3` | `f37cb851b7dc582d358cd8436bbf185690a8bbd3889eedce326c4bb9142b4e5a` |

**External ports.** `ports.py` inventories are identical before and after: `loader_core` 17
ports (listing SHA-256 `8df490088f44e99e71f8204f5d1222948b38df2ac3092e1a3086b4605e7a0b97`),
both loader wrapper roles 8 ports (`aff782f713562caee6130f6b05de9db35b51b806cb2eb2e875a125d84d099707`),
and `integrated_core` 109 ports (`378492956340c2dacfdd01afb746ef171beddf124674f6d0e28b1485d05a4f12`),
all equal to HL4b2's listings. `Command_dispatch` is flattened and adds no module or port.

**State.** After the register rename below, the 163 state-register declarations of
`loader.v` (named and anonymous `signal_reg_*`) are identical in name and width, and both
files have 157 clocked blocks. (The other 51 `reg` declarations are combinational `case`
temporaries whose anonymous numbers shift.)

**Every difference in the three changed files**, classified by `classify.py` (the same
classes in `loader.v` and both wrapper roles):

1. The 3 dispatcher registers are renamed `loader$reg_*` → `loader$command_dispatch$reg_*`:
   the `Scope.sub_scope` level.
2. The publication interface: three named wires,
   `loader$command_dispatch$wire_response_frame` (168 bits), `..._length` (5), and
   `..._publish` (1), each assigned from the end of its mux chain.
3. The store update form. The first (S1) muxes of the store, length, and pending chains used
   the register's own value as their hold input (`eq ? reg : …`, `and ? … : reg`, six
   assignments). They now use zero, since the chains are the dispatcher's wires. Three new
   muxes, `publish ? wire_frame : reg_response_store`, `publish ? wire_length :
   reg_response_length`, and `publish ? 1 : reg_response_pending`, apply them in the loader
   at P. This is the only logic restructuring, and the formal proof below covers it.
4. One extra 1-bit `~enable_i`: the dispatcher builds its own for its disable clause, as
   `Frame_rx` does; Hardcaml does not share it.
5. One 1-bit `signal_wire` joining `Command_dispatch.busy_o` to `Frame_rx`'s eligibility;
   `~command_busy` becomes `~` of that wire. The `dispatch | wait_read | wait_abort` chain is
   unchanged. (`loader_core` does not export the loader's `busy_o`, so that OR is not emitted
   in either version.)
6. Hardcaml's anonymous `signal_<op>_<n>` names are renumbered where creation order changed.

Declarations go 8 369 → 8 377 in `loader.v` (+3 named wires, +3 muxes, +1 inverter, +1 wire)
and assignment shapes 8 163 → 8 171; `loader.v` grows 20 499 → 20 515 lines, the wrapper
roles 24 316 → 24 332 and 20 782 → 20 798.

**Formal sequential equivalence** (host Yosys 0.33), HL4b2's flow unchanged
([`core.ys`](#appendix-evidence-scripts)):

- Gold: pre `loader.v` (SHA-256 `026ea6e9…26cd`, the HL4b2 implementation). Gate: post
  `loader.v` with `loader$command_dispatch$reg_` → `loader$reg_` (`sed`, SHA-256 of the
  result `45d08caeb7696ccdfa5cdbafa22bf9e9951c4004332b2016e39a8df3d3387339`). The rename only
  restores register names; no logic is edited. The new named publication wires exist only
  in the gate and are not matched; they are internal nets, and every register and port they
  feed is matched.
- `proc -norom`; `rename -hide w:signal_* w:signal_reg_* %d` hides renumbered anonymous
  nets but keeps anonymous registers paired by name. No assumption or constraint is added.
  The reset is synchronous in `loader_core`; no `async2sync` is needed.
- Result: **1 331 of 1 331 `$equiv` cells proven** (166 matched name groups: every port;
  all 31 loader registers, including the 3 moved ones and all 168 bits of
  `response_store`; the 95 core registers; the 30 anonymous registers), 7 min 13 s.
  Unproven points: none.
- Non-vacuity: the same script against a `loader.v` generated from the M2 source (refusal
  checks swapped; SHA-256 `bf7fd297…28c7`) leaves **6 cells unproven**:
  `loader$reg_response_store` bit 128 (bit 0 of the result byte, 0x20 versus 0x21) and bits
  104, 105, 107, 109, 110 (the empty response's CRC byte).
- **Loader wrapper, synthesis source role, untransformed:** 5 423 of 5 425 cells proven
  (8 min 44 s). The 2 unproven are the wrapper's own 2-bit reset synchronizer
  `signal_reg_288` (asynchronous preset to `2'b11` from `~rst_n`), which the induction flow
  does not model. It is outside the loader and textually identical in both files apart from
  anonymous numbers (inverter `signal_not_228` → `229`, clock wire `194` → `195`), the same
  result as HL4b2.
- **Same wrapper with `async2sync`** after `proc` on both sides (modelling that preset as
  synchronous, identically for gold and gate): **5 425 of 5 425 proven** (21 min 21 s). This is a proof under that
  transformed reset model only, not unrestricted asynchronous reset assertion/release or
  physical reset equivalence. The untransformed result and its two unproven reset bits
  stand beside it.

## Generic synthesis

The configuration is the loader checker's own, unchanged: the pinned image above, `docker
run --rm --pull=never --network none`, and
`yosys -p 'read_verilog /bundle/src/tt_um_leemperor_hardcaml_protemu_loader.v; hierarchy
-check -top tt_um_leemperor_hardcaml_protemu_loader; synth -top
tt_um_leemperor_hardcaml_protemu_loader; stat'` on the production synthesis source.
`synth_stat.sh` ran the identical container and command on the loader bundle emitted by
each capture (the checker discards stdout); the full checker also passed after.

**Fresh baseline:** 25 210 cells, with per-type counts, wires, and public wires identical to
HL4b2's recorded "after" column, so the baseline is the accepted HL4b2 result with no
source, tool, or configuration difference. The unsplit 25 108 is kept for the cumulative
comparison. The raw `stat` block ends with Yosys's run-time line, so its hash differs from
run to run; the digests below cover the block up to that line (31 lines).

**Checker path, `tt_um_leemperor_hardcaml_protemu_loader`** (Yosys 0.66):

| Cell type | Unsplit | HL4b2 accepted = HL4b3 before | HL4b3 after | Δ vs HL4b2 | Δ vs unsplit |
| --- | ---: | ---: | ---: | ---: | ---: |
| `$_ANDNOT_` | 496 | 465 | 440 | −25 | −56 |
| `$_AND_` | 7 907 | 8 022 | 7 848 | −174 | −59 |
| `$_DFFE_PP_` | 4 240 | 4 240 | 4 240 | 0 | 0 |
| `$_DFF_PN1_` | 2 | 2 | 2 | 0 | 0 |
| `$_DFF_P_` | 13 | 13 | 13 | 0 | 0 |
| `$_MUX_` | 592 | 566 | 543 | −23 | −49 |
| `$_NAND_` | 8 370 | 8 460 | 7 959 | −501 | −411 |
| `$_NOR_` | 491 | 429 | 458 | +29 | −33 |
| `$_NOT_` | 84 | 87 | 94 | +7 | +10 |
| `$_ORNOT_` | 456 | 420 | 401 | −19 | −55 |
| `$_OR_` | 554 | 641 | 611 | −30 | +57 |
| `$_SDFFE_PP0N_` | 3 | 3 | 3 | 0 | 0 |
| `$_SDFFE_PP0P_` | 804 | 804 | 912 | +108 | +108 |
| `$_SDFFE_PP1P_` | 6 | 6 | 6 | 0 | 0 |
| `$_SDFF_PP0_` | 315 | 315 | 142 | −173 | −173 |
| `$_XNOR_` | 552 | 530 | 542 | +12 | −10 |
| `$_XOR_` | 223 | 207 | 217 | +10 | −6 |
| **Cells** | **25 108** | **25 210** | **24 431** | **−779** | **−677** |
| Flip-flops (sum of `DFF` types) | 5 383 | 5 383 | 5 318 | −65 | −65 |
| Wires / wire bits | 25 450 / 66 614 | 25 551 / 66 715 | 24 959 / 69 019 | −592 / +2 304 | −491 / +2 405 |
| Public wires / bits | 7 041 / 48 205 | 7 041 / 48 205 | 7 097 / 51 157 | +56 / +2 952 | +56 / +2 952 |
| Ports / port bits | 8 / 43 | 8 / 43 | 8 / 43 | 0 | 0 |

`stat` block digest (up to the run-time line): before
`ee2ab6ed3b5188af17035085853ce255a31fa79e9de4bbe36cf177c47797025f`, after
`68632e9109afcb875e7435d5e23f48ca9bc9ff27543b2ac228d6ffdf95a83194`.

**Supplementary, `loader_core` with host Yosys 0.33** (the `@loader-core-rtl` command
without `-q`): 16 194 → 13 752 cells, flip-flops 1 269 → 1 204 (−65; `$_SDFF_PP0_` 314 →
141, `$_SDFFE_PP0P_` 796 → 904), so the other Yosys version moves the same way.

### Investigation of the −779

The emitted RTL keeps every state register, and the netlists are proven equivalent, yet the
mapped flip-flop count fell by 65. `ff_bits.sh` lists every mapped flip-flop with the
register bit its output drives, in the checker's container, before and after:

- Every register bit outside `response_store` and `response_length` maps to the same number
  of flip-flops of the same type in both netlists.
- Before, `response_store` (168 bits) and `response_length` (5) map to 173
  `$_SDFF_PP0_` (synchronous reset, no enable): their next value is a deep priority mux whose
  hold input is at the bottom of the chain. After, the P statement makes the next value
  `publish ? frame : hold`. Yosys extracts `publish` as a clock enable, giving 108
  `$_SDFFE_PP0P_` (104 store bits, 4 length bits). That is exactly the −173/+108 in the
  table.
- The 65 missing bits (64 store, 1 length) are ones that, once they are enable flops with
  the same enable, have a constant or duplicated data input across every response frame.
  Examples: all of frame byte 0 (magic `5a`) and 7 bits of byte 1 (version `10`): the zero
  bits are constant zero from reset, and the one bits merge into one representative. All
  of byte 6 (payload-length high byte, always zero); all of byte 5 (payload-length low
  byte: 0, 2, 12, or 13), whose bits are zero or duplicate `response_length` bits; and
  `response_length[4]`, which equals `response_length[2]` for every frame length (8, 10,
  20, 21). The removed bits, as `response_store` indices (bit 167 is frame byte 0's MSB),
  are 19–23, 28–31, 49–55, 65–71, 81–87, 112–127, 131, 134, 135, 152–155, and 157–167, in
  frame bytes 0, 1, 4, 5, 6, 10, 12, 14, 17, and 18. The same bits are equally redundant
  before; by the equivalence proof, the two designs' store registers hold identical values
  in every reachable state. The tool finds the redundancy only in the enable form.

Controlled variants, each synthesized with the checker's container and command
(`variants.py`, `crossover.py`; each edit an exact asserted substitution on emitted RTL):

| Input | Cells | Flip-flops | What it isolates |
| --- | ---: | ---: | --- |
| Pre (HL4b2 accepted) | 25 210 | 5 383 | — |
| Post (HL4b3) | 24 431 | 5 318 | — |
| Post, 3 register names mapped back to `loader$reg_*` | 24 431 | 5 318 | Register names: no effect |
| Pre, 3 register names mapped forward to `loader$command_dispatch$reg_*` | 25 210 | 5 383 | Same |
| Pre, consistent random anonymous renumbering, seeds 1/2/3 | 25 171, 25 170, 25 147 | 5 383 | Name-only sensitivity |
| Post, same seeds | 24 532, 24 543, 24 484 | 5 318 | Same |
| Post with the store and length chains based on the registers and no publish mux (the pre update form; pending unchanged) | 25 045 | 5 383 (804 `SDFFE`, 315 `SDFF`: pre's mix) | Undoing only the update form |
| Pre with the store and length chains based on zero and a final `pub ? chain : reg` mux (`pub` = OR of the zero-based length chain) | 24 453 | 5 318 (912 / 142: post's mix) | Applying only the update form |

Findings:

- Register names have no effect in either direction. Name-only renumbering moves the pre
  source over 25 147–25 210 and the post source over 24 431–24 543 (finite samples, not a
  tolerance); the bands are about 600 cells apart and never overlap, and the flip-flop
  counts never move.
- Crossing only the store/length update form moves each source to the other's side:
  post → 25 045 with pre's exact flip-flop mix, pre → 24 453 with post's. So the update form
  accounts for all 65 flip-flops and for roughly 590–760 of the 779 cells. The rest of the
  delta (post-as-pre 25 045 against pre 25 210; pre-as-post 24 453 against post 24 431) is
  of the same size as the name-only spread and is not isolated further. It includes the
  other structural differences (separate pending update, one inverter, one wire).
- The cross-over variants are logic-preserving by construction (the post one is the
  literal Verilog undo of statement P, and the pre one's `pub` is nonzero exactly when a
  frame of 8 to 21 bytes is published). They were not separately proven, and serve only
  to attribute the count.

The best-supported explanation is that the combinational publication interface, which the
extraction contract requires, changes the retained store's next-state form from a hold at
the bottom of a priority chain to an explicit enable. The pinned tool then infers an
enable and removes redundant store bits. The logic is proven equivalent, and the RTL state
is unchanged. The actual result is nevertheless **24 431 cells**: −779 against the previous
accepted slice and −677 against the unsplit baseline, with 65 fewer mapped flip-flops.
This nonzero delta received its own planning review and is accepted below. No production
naming was changed to move the count. No mapped-area, timing,
or power claim follows, and a lower generic count is not evidence of lower physical cost.

### Planning acceptance decision

The owning planning session accepts HL4b3 and HL4c3 on 2026-09-25. The accepted checker
result is **24 431 cells and 5 318 mapped flip-flops**, down 779 cells and 65 flip-flops
from HL4b2, and down 677 cells and 65 flip-flops from the original unsplit baseline.

The review covered the recorded proof and synthesis investigations, the dispatch
publication logic, and the loader's retained-store update and priority. Current hashes
for the dispatcher, loader, receiver, HL4a testbench, and independent peer match the record.
The planning session did not rerun regression, synthesis, or formal proofs; their results
remain the implementation evidence above.

This is not accepted merely because the count is lower. The emitted RTL retains the
state widths and behavior; recorded complete `loader_core` equivalence includes all
response-store bits, with a detected refusal-priority mutant. Existing cycle tests and
all independent peer tiers pass unchanged. The mapped-bit inventory localizes all 65
removed/merged flip-flops to redundant store/length bits, and the cross-over experiments
reproduce that exact flip-flop change by changing the update form. The secondary Yosys
version independently exhibits the same 65-flip-flop reduction. These observations
support synthesis optimization of equivalent state, not removal of a protocol obligation.

The cross-over variants are attribution experiments, not separately proven designs.
The remaining total-cell difference is not fully isolated and is accepted with that
limitation. The recorded formal proof compares emitted RTL; it is not a separate
post-synthesis equivalence proof of every mapped cell. The wrapper result remains
qualified by `async2sync`, with two reset bits unproven in the untransformed flow.

For the next slice, use 24 431 cells / 5 318 mapped flip-flops as the previous accepted
baseline, while retaining 25 108 / 5 383 as the original baseline. A mapped-state count
change is not automatically a behavioral change or automatically acceptable: locate the
affected bits, explain their elimination/merging or addition, and review state/timing
equivalence. Every subsequent nonzero synthesis delta still needs individual review.

The overlapping formatter check is a recorded process deviation, not an exception to
the sequential-execution rule. It does not on its own require rerunning the successful
checks against the recorded final source. Future Dune commands, including formatting
checks, must wait for active proofs, synthesis, and other build/test jobs to finish.

## Bundle metadata and source identity

`source_revision` is `89a3fe8` in every bundle. Only `identity`, `source_inputs`, and the
loader's two Verilog roles changed; `info.yaml`, constraints, and `config.json` did not.

| Bundle | Identity before | Identity after | Source-input changes |
| --- | --- | --- | --- |
| observable | `e8bd21709b1fbe900cad57a7e3cb466efa0b25072b289b743f3929bc6650926c` | `d4182035733aef58158d8b7bdfef17e5ed4c9e041eed6b6008640e91a1725f64` | `bin/asic_bundle.ml` content |
| memory | `7f83a38378e07e894d22efec951bd59e13628e092f983fd728f33c7857a14baf` | `0c9a836e91cb04ee5af004d1b6ad9213feed5ad33aa2d100b21c878c7f47ec29` | the same input |
| loader | `e9d72c7872378d9c9cba2db8c09f02e47c6c2dff9069d13596804bea26226f55` | `dc5da5730cb9c6eada2ec271e7408d213d5e1f8dd25208dfc1104601839ccc50` | the same, plus `hardware_loader.ml` and `frame_rx.ml` content; added `lib/host_link/command_dispatch.ml` (git status `??`), 36 → 37 inputs |

`Command_dispatch` belongs only to the loader's closure (`Loader_core` → `Hardware_loader`
→ `Command_dispatch`); no other library module references it, so the observable and memory
checker expectations did not change. No Dune change was needed: `lib/dune` includes
subdirectories, the `generate_core` rules depend on the executable whose closure includes
the new module, and the loader-wrapper rule depends on `(source_tree ../../lib)`. The stray
`lib/staging/observed_transfer.ml` loader manifest entry was left untouched. These
working-tree identities will change again when the owner commits.

## Blockers, follow-ups, and remaining work

- **Resolved:** planning accepted the 25 210 → 24 431-cell delta (−779; −677 cumulative)
  and 5 383 → 5 318 mapped flip-flops for this slice. The remaining total-cell attribution
  limitation and proof scope are recorded in the decision above. HL4b3 and HL4c3 are complete.
- No functional blocker. No pre-existing defect was found; the findings above are pinned
  current behavior.
- Remaining HL4b work: `Frame_tx` (retained store, arming, shifter, replay, commit) with its
  HL4c tests. HL4b and HL4c stay open. Two recorded follow-ups for that slice:
  `crc8_byte` is still owned by `Frame_rx` and now used by `Command_dispatch` (a shared
  owner is the `Frame_tx` follow-up), and `check_wire_encodings` still runs only when
  `Hardware_loader` is elaborated, so the response, INFO, and STATUS layout checks that
  `Command_dispatch` relies on do not run when it is built alone (as in its tests, which
  check those encodings through the decoder and hand-written bytes instead).
- Unchanged and out of scope: the `observed_transfer.ml` loader manifest entry, the
  host-simulator CLI stdout comparison gap, and the `@fmt` backlog.
- This is RTL-identity, formal-equivalence, Cyclesim, emitted-RTL peer, and generic
  synthesis evidence. It is not physical, timing, or mapped-area evidence. No physical flow
  was run.

## Appendix: evidence scripts

These ran from the repository root; pre/post outputs lived in the session scratchpad, and
their checksums and counts are recorded above.

`capture.sh`, `ports.py`, `synth_stat.sh`, `core.ys`, `wrapper_plain.ys`, and
`wrapper_a2s.ys` are byte-for-byte the scripts in the
[HL4b2 record's appendix](host_link_hl4b2_record.md#appendix-evidence-scripts); they were
extracted mechanically from that document for these runs. The non-vacuity run used
`core.ys` with `gate.v` replaced by the M2 `loader.v` (generated with
`./scripts/with-switch.sh dune exec -j 5 bin/generate_core.exe -- loader <file>` while M2
was applied, then restored and hash-checked, then renamed with the same `sed`) and
`equiv_status -assert` replaced by `equiv_status`. The rename for every gate was
`sed 's/loader\$command_dispatch\$reg_/loader$reg_/g'`. The scripts new to this slice follow.

### `mutate.py`

```python
#!/usr/bin/env python3
"""Apply one named sensitivity mutation to lib/host_link/command_dispatch.ml (in place).

Each mutation is an exact, unique text substitution; the restore is a copy of the saved
file followed by a SHA-256 check (see run_mutation.sh).
"""
import sys

PATH = "lib/host_link/command_dispatch.ml"

MUTATIONS = {
    # M1. Dispatch is never cleared after its offer: repeated offers.
    "M1": (
        "      when_ r.dispatch.value\n        [ r.dispatch <--. 0\n",
        "      when_ r.dispatch.value\n        [ r.dispatch <-- r.dispatch.value\n",
    ),
    # M2. Refusal classification checks engines before execution.
    "M2": (
        "    mux2 (~:(status.halted)) (result_code Active_execution)\n"
        "      (mux2 (~:(status.engines_idle)) (result_code Engines_active)\n",
        "    mux2 (~:(status.engines_idle)) (result_code Engines_active)\n"
        "      (mux2 (~:(status.halted)) (result_code Active_execution)\n",
    ),
    # M3. ABORT completes without waiting for engine claims to be released.
    "M3": (
        "    &: (status.engine_claim ==:. 0)\n",
        "    &: vdd\n",
    ),
    # M4. A framing error echoes the tag even when it was not received.
    "M4": (
        "      ~tag:(mux2 i.echo_valid_i request_tag (zero 8))\n",
        "      ~tag:request_tag\n",
    ),
    # M5. Every publication presented one cycle late (registered).
    "M5": (
        "  ; response_publish_o = w.response_publish.value\n"
        "  ; response_frame_o   = w.response_frame.value\n"
        "  ; response_length_o  = w.response_length.value\n",
        "  ; response_publish_o = reg spec w.response_publish.value\n"
        "  ; response_frame_o   = reg spec w.response_frame.value\n"
        "  ; response_length_o  = reg spec w.response_length.value\n",
    ),
    # M6. An accepted STOP while already halted reports Complete.
    "M6": (
        "    choose_response decision.stop_accepted stop_response refused_response\n",
        "    choose_response decision.stop_accepted\n"
        "      (choose_response status.halted complete_response stop_response)\n"
        "      refused_response\n",
    ),
    # M7. Address bound checked after narrowing to the 9-bit request width.
    "M7": (
        "select payload_address ~high:15 ~low:8 ==:. 0",
        "select payload_address ~high:15 ~low:9 ==:. 0",
    ),
    # M8. VERIFY never reports a mismatch.
    "M8": (
        "    command_is Verify_word &: ~:(decision.readback_response_match)\n",
        "    gnd\n",
    ),
    # M9. A READBACK response pulse completes outside the READ wait.
    "M9": (
        "        (r.wait_read.value &: decision.readback_response_valid)\n",
        "        decision.readback_response_valid\n",
    ),
    # M10. RUN's outcome decided from its rejected signal instead of acceptance.
    "M10": (
        "    choose_response decision.run_accepted complete_response refused_response\n",
        "    choose_response (~:(decision.run_rejected)) complete_response refused_response\n",
    ),
    # M11. Fixed payload lengths compared on the low byte only.
    "M11": (
        "  let payload_length_is value = payload_length ==:. value in\n",
        "  let payload_length_is value = sel_bottom payload_length ~width:8 ==:. value in\n",
    ),
    # M12. LOAD_START's length bound checked after narrowing to the 9-bit request width.
    "M12": (
        "    (payload_address >:. 0) &: (payload_address <=:. Protocol_core.Config.program_depth)\n",
        "    (sel_bottom payload_address ~width:9 >:. 0)\n"
        "    &: (sel_bottom payload_address ~width:9 <=:. Protocol_core.Config.program_depth)\n",
    ),
}

name = sys.argv[1]
old, new = MUTATIONS[name]
text = open(PATH).read()
assert text.count(old) == 1, (name, text.count(old))
open(PATH, "w").write(text.replace(old, new))
print(f"applied {name}")
```

### `run_mutation.sh`

```sh
#!/usr/bin/env bash
# Apply mutation $1 to command_dispatch.ml, run all four host_link suites with -j 5, count
# failing tests per suite, and restore the file exactly (SHA-256 checked). Output to $2.
set -uo pipefail
ev="$(dirname "$0")"
file=lib/host_link/command_dispatch.ml
saved="$(mktemp)"
cp "$file" "$saved"
want="$(sha256sum < "$file" | cut -d' ' -f1)"
python3 "$ev/mutate.py" "$1"
./scripts/with-switch.sh dune build -j 5 @test/host_link/runtest > "$2" 2>&1
echo "exit $?" >> "$2"
cp "$saved" "$file"
rm -f "$saved"
got="$(sha256sum < "$file" | cut -d' ' -f1)"
[ "$want" = "$got" ] || { echo "RESTORE FAILED $1"; exit 1; }
echo "$1 restored $got"
```

### `tally.sh`

```sh
#!/usr/bin/env bash
# Failing tests per suite in a mutation log: "threw" lines by directory, expect diffs, and
# the runners' own "FAILED n / m" summaries.
log="$1"
for suite in command_dispatch frame_rx serial_phy hardware_loader; do
  case $suite in
    hardware_loader) pat='^File "test/host_link/hardware_loader_[a-z_]*\.ml".* threw';;
    *) pat="^File \"test/host_link/$suite/.* threw";;
  esac
  n=$(grep -cE "$pat" "$log")
  printf '%s=%s ' "$suite" "$n"
done
echo; grep -E '^File "test/host_link[^"]*", line 1, characters 0-0' "$log" | sed 's/, line.*//' | sort -u | sed 's/^/  expect-diff: /'
grep -E "FAILED [0-9]+ / [0-9]+ tests" "$log" | sed 's/^/  /'
```

### `classify.py`

```python
#!/usr/bin/env python3
"""Classify the differences between a pre and a post emitted Verilog file.

Usage: classify.py PRE POST

1. Undo the Command_dispatch scope level for registers: `$command_dispatch$reg_` ->
   `$reg_` in POST.
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
post = open(sys.argv[2]).read().replace("$command_dispatch$reg_", "$reg_")
diff = [l for l in difflib.unified_diff(pre.splitlines(), post.splitlines(), lineterm="", n=0)
        if l[:1] in "+-" and not l.startswith(("+++", "---"))]
print("lines:", len(pre.splitlines()), "->", len(post.splitlines()))
print("differing lines after the register rename:", len(diff))

mask = lambda text: re.sub(r"\bsignal_([a-z_]+?)_\d+\b", r"signal_\1_#", text)


def decls(text):
    return collections.Counter(
        re.sub(r"\s+", " ", m.group(0)).strip()
        for m in re.finditer(r"^\s*(wire|reg)\s*(\[[^\]]*\])?\s*[^;\s]+;", mask(text), re.M))


def shapes(text):
    return collections.Counter(
        re.sub(r"\s+", " ", m.group(1)).strip()
        for m in re.finditer(r"^\s*assign\s+[^=]+=\s*(.*?);", mask(text), re.M | re.S))


for name, f in (("declarations", decls), ("assignment shapes", shapes)):
    a, b = f(pre), f(post)
    delta = {k: b[k] - a[k] for k in set(a) | set(b) if a[k] != b[k]}
    print(f"{name}: {sum(a.values())} -> {sum(b.values())}; differing kinds: {len(delta)}")
    for k, v in sorted(delta.items()):
        print(f"  {v:+d}  {k[:160]}")
```

### `ff_bits.sh`

The `select -set` in the Yosys command is inert (it names a set without selecting it, so
`write_json -selected` writes the whole design); the Python filter on the cell type is
what picks the flip-flops.

```sh
#!/usr/bin/env bash
# In the loader checker's pinned image, run its generic synthesis on the loader bundle in
# $1 and then list every flip-flop with the wire bit its Q output drives, to $2.
set -euo pipefail
bundle="$(cd "$1" && pwd)"
top=tt_um_leemperor_hardcaml_protemu_loader
image="ghcr.io/librelane/librelane:$(grep '^librelane_version=' tinytapeout/asic-dependencies.lock | cut -d= -f2)"
docker run --rm --pull=never --network none -v "$bundle:/bundle:ro" \
  --entrypoint sh "$image" -ec \
  "yosys -q -p 'read_verilog /bundle/src/$top.v; hierarchy -check -top $top; synth -top $top; select -set ff t:\$_*DFF*; write_json -selected /tmp/ff.json' >/dev/null && cat /tmp/ff.json" \
  > "$2.json"
python3 - "$2.json" > "$2" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))["modules"]
mod = next(iter(m.values()))
names = {}
for name, net in mod["netnames"].items():
    for i, b in enumerate(net["bits"]):
        if isinstance(b, int):
            names.setdefault(b, []).append((name.startswith("$"), name, i))
for cell in (c for c in mod["cells"].values() if "DFF" in c["type"]):
    q = cell["connections"]["Q"][0]
    best = sorted(names.get(q, [(True, "?", 0)]))[0]
    print(cell["type"], f"{best[1]}[{best[2]}]")
PY
```

### `variants.py`

```python
#!/usr/bin/env python3
"""Build name-only variants of the loader wrapper's synthesis source.

Usage: variants.py PRE POST OUTDIR

Writes OUTDIR/<name>/src/tt_um_leemperor_hardcaml_protemu_loader.v for each variant, to be
synthesized with the checker's own container and command (synth_stat.sh). Every edit is a
consistent renaming on emitted RTL; none changes logic.

  post_names_back : POST with loader$command_dispatch$reg_* renamed to loader$reg_*
  pre_names_fwd   : PRE with reg_dispatch, reg_wait_read, reg_wait_abort renamed to
                    loader$command_dispatch$reg_*
  pre_renum_<s>, post_renum_<s> : consistent random renumbering of every anonymous
                    signal_<op>_<n> within its op, seeds 1..3
"""
import pathlib
import random
import re
import sys

TOP = "tt_um_leemperor_hardcaml_protemu_loader"
REGS = ["dispatch", "wait_read", "wait_abort"]
pre = open(sys.argv[1]).read()
post = open(sys.argv[2]).read()
out = pathlib.Path(sys.argv[3])


def write(name, text):
    d = out / name / "src"
    d.mkdir(parents=True, exist_ok=True)
    (d / f"{TOP}.v").write_text(text)


back = post.replace("loader$command_dispatch$reg_", "loader$reg_")
assert "command_dispatch$reg_" not in back
write("post_names_back", back)
fwd = pre
for r in REGS:
    fwd, n = re.subn(r"loader\$reg_" + r + r"\b", "loader$command_dispatch$reg_" + r, fwd)
    assert n > 0, r
write("pre_names_fwd", fwd)


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

### `crossover.py`

```python
#!/usr/bin/env python3
"""Cross the response-store update structure between the pre and post wrapper sources.

Usage: crossover.py PRE POST OUTDIR

  post_store_as_pre : POST with the store and length chains based on the registers' own
                      values (the pre structure) and no publish mux: the loader's P
                      statement undone at the Verilog level. [response_pending] unchanged.
  pre_store_as_post : PRE with the store and length chains based on zero and a final
                      [pub ? chain : register] mux, where pub = |length_chain (every
                      published frame is 8 to 21 bytes, and the zero-based chain is zero
                      when nothing publishes). [response_pending] unchanged.

Both keep the logic of their source; only the store and length next-state structure
changes. Each edit is an exact asserted substitution.
"""
import pathlib
import sys

TOP = "tt_um_leemperor_hardcaml_protemu_loader"
pre = open(sys.argv[1]).read()
post = open(sys.argv[2]).read()
out = pathlib.Path(sys.argv[3])


def sub(text, old, new):
    assert text.count(old) == 1, (old, text.count(old))
    return text.replace(old, new)


def write(name, text):
    d = out / name / "src"
    d.mkdir(parents=True, exist_ok=True)
    (d / f"{TOP}.v").write_text(text)


S, L = "loader$reg_response_store", "loader$reg_response_length"
x = post
x = sub(x, "assign signal_mux_756 = signal_eq_27 ? signal_const_41 : signal_cat_1228;",
        f"assign signal_mux_756 = signal_eq_27 ? {S} : signal_cat_1228;")
x = sub(x, "assign signal_mux_757 = signal_and_861 ? signal_mux_756 : signal_const_41;",
        f"assign signal_mux_757 = signal_and_861 ? signal_mux_756 : {S};")
x = sub(x, "assign signal_wire_16 = signal_mux_761;", "assign signal_wire_16 = signal_mux_760;")
x = sub(x, "assign signal_mux_793 = signal_eq_27 ? signal_const_1232 : signal_const_2311;",
        f"assign signal_mux_793 = signal_eq_27 ? {L} : signal_const_2311;")
x = sub(x, "assign signal_mux_794 = signal_and_861 ? signal_mux_793 : signal_const_1232;",
        f"assign signal_mux_794 = signal_and_861 ? signal_mux_793 : {L};")
x = sub(x, "assign signal_wire_18 = signal_mux_798;", "assign signal_wire_18 = signal_mux_797;")
write("post_store_as_pre", x)

y = pre
y = sub(y, f"assign signal_mux_756 = signal_eq_27 ? {S} : signal_cat_1228;",
        "assign signal_mux_756 = signal_eq_27 ? signal_const_41 : signal_cat_1228;")
y = sub(y, f"assign signal_mux_757 = signal_and_861 ? signal_mux_756 : {S};",
        "assign signal_mux_757 = signal_and_861 ? signal_mux_756 : signal_const_41;")
y = sub(y, "assign signal_mux_792 = signal_eq_27 ? loader$reg_response_length : signal_const_2310;",
        "assign signal_mux_792 = signal_eq_27 ? signal_const_1232 : signal_const_2310;")
y = sub(y, "assign signal_mux_793 = signal_and_861 ? signal_mux_792 : loader$reg_response_length;",
        "assign signal_mux_793 = signal_and_861 ? signal_mux_792 : signal_const_1232;")
y = sub(y, "    assign signal_wire_16 = signal_mux_760;\n",
        "    wire x_pub;\n    assign x_pub = | signal_mux_796;\n"
        f"    assign signal_wire_16 = x_pub ? signal_mux_760 : {S};\n")
y = sub(y, "    assign signal_wire_18 = signal_mux_796;\n",
        f"    assign signal_wire_18 = x_pub ? signal_mux_796 : {L};\n")
write("pre_store_as_post", y)
print("ok")
```
