# HL4a implementation record: serial Cyclesim harness for the unsplit loader (2026-09-24)

Status: HL4a implemented and verified by an agent in the working tree. **Not committed:**
nothing is committed or staged; the repository owner commits. This is the implementation
record for [HL4a](host_link_migration.md#hl4--link-decomposition). HL4b and HL4c are not
started. The [P3.5 record](p3.5-hardware-loader.md) remains the wire and timing authority
and [`control_port.ml`](../lib/emulator_core/control_port.ml) the temporal contract. No
production source, wire value, codec policy, timing requirement, or existing test changed.

## Starting revision and local diff

- `HEAD` = `89a3fe8` ("re-org phase 1", HL2), branch `bpurtell/scaf`. The stash list was
  empty.
- **Pre-existing, not HL4a:** the owner had not committed HL3. The working tree carried
  the complete HL3 diff described in [the HL3 record](host_link_hl3_record.md): 18 modified
  tracked files and 3 untracked files (`docs/host_link_hl3_record.md`,
  `lib/emulator_core/control_port.ml`,
  `test/integration/core_engine/core_engine_control_port_tests.ml`). Nothing was staged.
  Its `git diff` output had SHA-256
  `7dfae0cf9d594aea21e29c3dbe2950bae4fb75d80eaa14b8f81140e79a1b95f6`. Selected baseline
  file hashes (SHA-256), which are unchanged at the end of HL4a:

  | File | SHA-256 |
  | --- | --- |
  | `lib/host_link/hardware_loader.ml` | `29b38a5f141553b2f5aa22e8cb6a507562cc45534a9b10a4978e485ee144239a` |
  | `lib/host_link/loader_core.ml` | `ea0a8bf41c0dcf74f812b820218cc0cf0a5a64ac9776251cb5dc9742e5c8bfc1` |
  | `lib/emulator_core/control_port.ml` | `07d8af088cac01ab2b865efbed4da14dab7f2ff80284f951541f66223ffbb2b6` |
  | `lib/emulator_core/integrated_core.ml` | `169c0484e1f6bab3070f6eaad67ec58c7f5abd97f52dc4245cbbcc8774c89a71` |
  | `tinytapeout/test/p3_loader_tb.v` | `40d9341f32ad02202f78784dbf4c6f9a7685691d8f7da78a50c2303cd2e2c9c9` |

- Baseline check before any HL4a edit: `@install`, `@lint`, `@runtest`, and the focused
  `test/host_link_wire`, `test/integration/core_engine`,
  `test/integration/host_simulator`, and `test/host` suites all passed (up to date from
  the HL3 verification of the same inputs). No pre-existing failure was found.
- HL4a diff (uncommitted, unstaged):

  | Path | Change |
  | --- | --- |
  | `test/host_link/dune` (new) | Library `protemu_host_link_tests` with inline tests, part of ordinary `@runtest` |
  | `test/host_link/hardware_loader_testbench.ml` (new) | Cycle owner, core stub, serial driver and monitor, checks and diagnostics |
  | `test/host_link/hardware_loader_transaction_tests.ml` (new) | 10 tests: legal transactions, timing, pauses, replay/commit, arming |
  | `test/host_link/hardware_loader_framing_tests.ml` (new) | 7 tests: framing, overrun, prefixes, truncation, correlation threshold |
  | `test/host_link/hardware_loader_cancellation_tests.ml` (new) | 10 tests: early selection, correlation, reset and disable |
  | `test/host_link/hardware_loader_diagnostics_tests.ml` (new) | 5 tests: controlled negatives and the report format |
  | `docs/` | This record; [host_link_migration.md](host_link_migration.md), [verification.md](verification.md), [p3.5-hardware-loader.md](p3.5-hardware-loader.md) (one sentence), and [README.md](README.md) |

## Tool identity

opam switch `5.2.0+ox` (OCaml 5.2.0+ox), Dune 3.24.2; `hardcaml`, `ppx_hardcaml`, `core`,
`ppx_jane`, `ppx_expect`, `ppx_inline_test` `v0.18~preview.130.106+341`; `ocamlformat`
0.26.2+ox2; Verilator 5.020, Icarus Verilog 12.0, Yosys 0.33, Python 3.12.3. The same
switch served the baseline and final runs.

## Harness structure

[`hardware_loader_testbench.ml`](../test/host_link/hardware_loader_testbench.ml) follows
[verification.md](verification.md)'s per-module convention: the testbench owns the
simulator loop, stub, driver, monitor, and checks, and the four test files only compose
scenarios. It is not a generic framework and does not use `Env`, whose one-item-per-edge
scheduling does not fit a multi-thousand-cycle serial transaction.

| Piece | Role |
| --- | --- |
| `Sim` | `Cyclesim.With_interface (Hardware_loader.I) (Hardware_loader.O)` over the real, flattened `Hardware_loader.create` |
| `cycle` | The only function that advances the simulator |
| `Core_stub` | Test-only core behind `Control_port`: decisions, READBACK response, status, offer and response records |
| `Timing`, `send`, `begin_frame`/`end_frame`, `send_frame` | Serial request driver in whole cycles |
| `read_bit`, `read_response`, `finish_response`, `read_prefix` | Response monitor: bit sampling, byte reconstruction, validation, commit or replay |
| `receive`, `exchange`, `transact` | One complete transaction with its timeline (`Exchange.t`) |
| `Raw` | Test-local malformed frames; the codec builds only legal ones |
| `Latency` | The unsplit loader's cycle latencies, each explained |
| `Harness_failure`, `check`, transcript | Failure reports |

Legal requests use `Wire.Request.encode`; responses use `Wire.Response.decode_correlated`
(or `decode` where no correlation is expected). Sharing `Wire` is intentional here; the
independent Verilog peer remains the separate protocol oracle.

## Scheduling and sampling contract

1. **Units.** Time is counted in system clock cycles. Cycle *n* is the interval before
   edge *n*. Every delay, budget, and timestamp in the suite is in cycles.
2. **Reset sequence.** Pins idle (`LSEL_N` high, `LCLK` and `LDI` low), enable high, the
   stub's status halted and idle. Reset is high for four cycles (0 to 3) and then low for
   four idle cycles, so the first host action is in cycle 8. Reset is synchronous.
3. **One owner.** `cycle` is the only function that calls Cyclesim. Host steps set pin
   values and then call `cycle` or `hold` in sequence; the stub runs inside `cycle`.
   Neither advances time on its own.
4. **Order within cycle *n*.**
   1. Apply reset, enable, `LSEL_N`/`LCLK`/`LDI`, the stub's `Status`, and the stub's
      registered READBACK response for cycle *n*. Decisions are low.
   2. `cycle_check`, `cycle_before_clock_edge`; read the offered `Control_port.Request`.
      More than one valid is a failure.
   3. Compute the stub's combinational decision for that offer, apply it, and settle
      again. The request must not change; this checks that no offer depends
      combinationally on its decision.
   4. Pre-edge observation: `LRDY`, `LDO`, `busy_o`, the offer, and the response pulse.
      These are logged when they change.
   5. `cycle_at_clock_edge`, `cycle_after_clock_edge`.
   6. Stub post-edge work for edge *n*: record a delivered response, apply reset/disable
      cancellation, schedule accepted READBACK and ABORT completions, and apply a
      scheduled cleanup.
5. **Pin timing.** A pin set for cycle *n* is sampled at edge *n*, as the peer's pin
   change 1 ps after edge *n−1* would be. The host keeps the P3.5 envelope in whole
   cycles, each field at least four (`Timing.validate` refuses less): `LSEL_N` low
   `select_lead` cycles before the first `LCLK` rise; `LCLK` low `clock_low` and high
   `clock_high`; `LDI` changes only with the preceding fall (or at selection for the first
   bit), which gives `clock_low` setup and `clock_high` hold; `select_trail` cycles from
   the last fall to `LSEL_N` high; `deselect_gap` cycles high between frames. The default
   is 4 for each; 4/5, 5/4, and a slower 9/13 host are also tested.
6. **Response sampling.** The host samples `LDO` in the cycle it raises `LCLK`, pre-edge.
   It reads the 7-byte header, takes the length from it, and reads through the final
   bit's rise. It validates the whole frame with `LCLK` still high. **Commit:** hold the
   rest of the high time, supply the final fall, wait `select_trail`, raise `LSEL_N`.
   **Replay:** raise `LSEL_N` with `LCLK` high, hold `clock_high` more cycles, then lower
   `LCLK`. **Abandon:** stop after a fall, wait `select_trail`, raise `LSEL_N`.
7. **While sending a request**, `LDO` must be low at every host rise.
8. **Budgets and failure.** Every wait has a finite cycle budget (20 000 by default for
   `LRDY`). An exhausted budget or failed check raises `Harness_failure`; see
   [Diagnostics](#diagnostics-and-non-vacuity).

This is synchronous digital evidence. It does not establish asynchronous phase behavior,
metastability, board timing, or physical setup/hold margins.

## The core stub

`Core_stub` is not a RAM or execution model. Acceptance comes from a test-set `accept`
function, READBACK data from a test-set `memory` array, and status from a test-set
`Status` record. It never reads the loader's refusal or dispatch logic. Offers (every
valid, with cycle and accepted flag) and delivered response pulses are recorded
separately, so raw offers and accepted side effects can be counted separately.

**Contract-faithful behavior** (the default), from `control_port.ml`:

- Decisions are combinational in the offer cycle. With no offer both decisions are low; a
  refusal is `valid & ~accepted` (item 3).
- Reset or disable refuses every offer and cancels a pending READBACK response (item 8).
- An accepted READBACK has its response valid only in the cycle two cycles after the offer
  cycle (item 5). A second READBACK is refused while one is outstanding, and an accepted
  ABORT or LOAD_START cancels it.
- An accepted ABORT makes the cleaned status (halted, engines idle, no output enable, no
  claim) visible from the cycle after its accepting edge (item 6).
- `readback_response_match` compares the word with the expected operand for VERIFY. For
  READ the stub drives it low; it is meaningless there, and the loader must ignore it.

**Robustness probes** exercise the loader's waits and context retention, not the current
`Integrated_core`, whose completions are prompt. Every test that uses one says so in its
name or comment:

- `Completion.Delayed n`: the READBACK response or ABORT cleanup arrives *n* cycles later
  than the contract.
- `Completion.Never`: no completion until the test changes the status; used for staged
  ABORT cleanup and for cancellation during an unbounded wait.
- `inject_readback_response`: a response pulse no accepted READBACK requested.
- A stub that refuses STOP or ABORT (the real core accepts both whenever enabled and out
  of reset).

A stub offer count is evidence about loader dispatch only. It is not evidence about RAM
writes, core cleanup, or pin behavior.

## Exact cycle observations

These are the unsplit loader's latencies, asserted exactly and fixed as the HL4b baseline.
P3.5 constrains only the host envelope; each value below is explained from the loader's
structure or the `Control_port` contract (`Latency` in the testbench). *s* is the cycle in
which the host drives `LSEL_N` high after a request; *o* the offer cycle.

| Observation | Cycle | Explanation |
| --- | --- | --- |
| Offer of a valid command | *o* = *s* + 3 | Two synchronizer stages (edges *s*, *s*+1), release seen in *s*+2, dispatch armed at edge *s*+2 |
| Immediate response (INFO, STATUS, LOAD_*, WRITE, RUN, STOP, refusals, dispatch-stage errors) | `LRDY` from *o* + 1 | Response stored at the offer's edge |
| Deselect-validation error (overrun, incomplete, magic, version, length > 4, CRC) | `LRDY` from *s* + 3 | Stored at the release edge, one cycle before a valid frame's dispatch cycle |
| READ/VERIFY response pulse (contract stub) | *o* + 2 | Contract item 5 |
| READ/VERIFY `LRDY` | response cycle + 1 | Stored at the edge of the response cycle; with a delayed stub, *o* + 2 + delay + 1 |
| ABORT cleanup visible (contract stub) | *o* + 1 | Contract item 6 |
| ABORT `LRDY` | cleanup-visible cycle + 1 | With staged cleanup, one cycle after the last of the five conditions becomes visible |
| Commit | `LRDY` falls at *d* + 3 | *d* is the `LSEL_N` rise after a synchronized final fall; release seen in *d*+2 |
| Replay (final fall absent) or abandoned read | `LRDY` stays high | Checked for 100 to 200 cycles after *d* |
| Response arming | `LSEL_N` low in cycle *a* is seen in *a* + 2 | Arms only if four deselected cycles have been counted and `LRDY` is high in *a* + 2 |
| Disable | `LRDY` falls in the disabled cycle itself | `serial_ready_o` is gated by `enable_i`; the retained response is gone when enable returns |
| Reset | `LRDY` falls in the cycle after the first reset edge | Synchronous clear |
| Reset or disable in the dispatch cycle | The offer is visible in that cycle and refused | The offer is not gated by enable or reset; the core refuses every offer under either (item 8) |

The arming boundary is pinned in both directions: with a 3-cycle gap after an INFO request
the first byte read is `00` (not armed), with 4 it is `5a`; with a READ response delayed
by 20 cycles (robustness), selecting 3 cycles before `LRDY` is ignored and 2 cycles before
is armed.

## Case-to-obligation map

Every case in [`p3_loader_tb.v`](../tinytapeout/test/p3_loader_tb.v), in order. "Ported"
means the loader-side obligation is checked here; the peer still runs every case on all
three tiers.

| Peer case (lines) | Obligation | HL4a | Remains full-core or RTL-only |
| --- | --- | --- | --- |
| STATUS after reset, `0x0007` (480) | STATUS encoding | Ported: "INFO and STATUS ..." (plus four more status vectors) | The real core's reset state |
| STOP → `0x01` (481) | STOP `Accepted_pending` | Ported, halted and running: "each shared command ..." | — |
| INFO at ten 4/4 phases, INFO payload (483–496) | INFO descriptor; phase independence | Descriptor decoded, and raw bytes checked against an independent CRC | All-phase sweep (asynchronous): RTL-only |
| Early selection during INFO dispatch (498–503) | Dispatch context protected | Ported, offsets 1–3, INFO and WRITE | Sub-cycle phase of the early selection: RTL-only |
| Asymmetric 4/5, 5/4 (504–511) | Envelope duty | Ported in whole cycles, plus a slower host | Sub-cycle phase: RTL-only |
| Request pause (513–528) | No inactivity timeout | Ported: 10 000-cycle pauses between bytes, within a byte, with `LCLK` high | An unbounded pause cannot be shown by a finite test |
| Interrupted response replay (530–541) | Replay from byte zero | Ported with RUN, no re-offer | — |
| Bad CRC LOAD_START; truncated WRITE (543–549) | `0x13`, `0x15`, no side effect | Ported; no offer | RAM write count (reusable-core tier) |
| WRITE length 3 → `0x12` (550) | Wrong fixed length | Ported for every command | — |
| Bad magic (551–554), bad version (555–565), unknown command (566) | `0x10`, `0x11`, `0x14` | Ported; three unknown codes | — |
| WRITE to address `0x100` → `0x23` (567) | Device bounds | Ported, with length/address matrix | — |
| INFO with a 5-byte payload → `0x12` (568) | Overrun | Ported | — |
| `write_count == 0` after the malformed set (569–571) | No RAM write | Replaced by no offer (dispatch evidence) | Actual RAM writes: reusable-core tier |
| 16 LFSR trials, seed `20260921` (573–600) | Bounded malformed set | Ported with the same LFSR, seed, and mutations | — |
| Valid image, then 15/16/32/48-byte prefixes before LOAD_START; status and READ unchanged (602–616) | Counter-wrap attacks cannot dispatch | Ported: `Bad_length`, zero echo, no offer | Image preserved in status/RAM: full-core |
| Early selection during READ (617–621) | READ context protected | Ported, contract and delayed (robustness) | — |
| Active load; 16/32-byte prefixed WRITE; twelfth byte; status and write count unchanged; legal WRITE (623–644) | Overrun and prefixes cannot write | Ported: no offer; the 11-byte maximum is offered | Load progress counters and RAM: full-core |
| VERIFY mismatch; status `0x0037`; LOAD_COMPLETE `0x23`; RUN `0x22` (646–650) | Mismatch carries the actual word; refusal classes | Ported: mismatch word; refusal classes derived from stub status | `verification_failed` and the core's own refusal: full-core |
| VERIFY against overwritten RAM (652–659) | Verification reads actual RAM | Not portable | Reusable-core tier only |
| Looping program: status phase 2, READ `0x20`, ABORT, outputs released (661–668) | Refusal while executing; ABORT reachable | Refusal class `0x20` from status; ABORT waits for cleanup | Real execution and pin release: full-core |
| Side-effecting RUN, peer-side CRC rejection, replay; pin-drive count unchanged (670–696) | Replay does not repeat RUN | Ported: one RUN offer across two rejections and a commit | Pin-drive event count: full-core |
| Early selection during ABORT; pins released; no stale reassertion (697–703) | ABORT context protected | Ported, contract and staged cleanup (robustness) | Pin release and no stale reassertion: full-core |
| Blocked RX pop recovered by ABORT (705–713) | Recovery from a blocked queue | Not portable | Full-core |
| Invalid-instruction fault: status `0x010f`, fault 1, phase 6; ABORT (715–721) | Fault decoding | STATUS encoding of the fault fields | The fault itself: full-core |
| Replacement load, READ, RUN (723–728) | Recovery by reload | Not portable | Full-core |
| Disable cancels a partial frame; outputs released; no stale response; INFO (730–743) | Disable cancellation | Ported: `LRDY`, `LDO`, `busy_o` low, no offer, fresh INFO | Protocol-pin release (`pin_oe_o`): full-core/wrapper |
| Reset cancels a partial frame; RUN then `0x22` (745–754) | Reset cancellation | Ported: partial frame cancelled, fresh INFO | Image invalidation by reset: full-core |
| 3/3 sweep, 1/1 excluded probe (756–791) | Sensitivity outside the envelope | Not portable | Asynchronous, RTL-only |
| Wrapper and production synthesis tiers | Pin mapping, explicit-flop RAM | Not portable | RTL-only |

Checked here but not by the peer: exact latencies above; offer-once with exact operands
for every core command; the full refusal-class matrix; the wrong-length matrix for every
command; device-bound matrix; truncation matrix, empty selection, and partial final byte;
the tag-0 zero-echo ambiguity; response pauses; the arming boundary; reset or disable in
the dispatch cycle; READ-wait and ABORT-wait cancellation, including a stray response
pulse; staged ABORT cleanup; disable discarding a retained response; reset during a
response read.

### HL4a required coverage

| Item | Tests |
| --- | --- |
| 1. INFO/STATUS observations | transaction: "INFO and STATUS report the fixed descriptor and the core's status" |
| 1. Exact request and operands, at most one offer | transaction: "each shared command is offered once ..." (eleven cases, then 200 quiet cycles each) |
| 1. Refusals without side effect | transaction: "a refused command reports the status-derived class ..." |
| 1. STOP `Accepted_pending`; READ/VERIFY data and match | transaction: "each shared command ...", "VERIFY reports a mismatch ..." |
| 1. ABORT waits for cleanup | transaction: "each shared command ..."; cancellation: "an early selection during an ABORT wait ..." (staged) |
| 2. Maximum frame, twelfth byte, extra bytes | framing: "the maximum legal frame dispatches; a twelfth byte latches overrun" |
| 2. Long prefixes and valid-looking suffixes | framing: "long zero prefixes and valid-looking suffixes cannot dispatch" |
| 2. CRC, magic, version, length, unknown command | framing: "bad magic, version, CRC, command, and payload length are rejected", "device bounds ..." |
| 2. Truncation, partial bytes, four-byte echo threshold | framing: "truncated frames and partial bytes ...", "a zeroed echo can match INFO with tag 0 ..." |
| 2. No malformed offer; later legal transaction | every framing case (`expect_rejected`) |
| 3. Request and response pauses | transaction: "a selected request may pause ...", "a selected response may pause ..." |
| 4. Partial read replay; final-bit rejection; later commit; LRDY boundaries; no re-offer | transaction: "an abandoned partial read replays ...", "final-bit validation rejection ..." |
| 5. Early selection during dispatch, READ wait, ABORT wait | cancellation: the three "an early selection during ..." tests |
| 5. Distinct tags detect stale correlation | cancellation: every early-selection test checks the answer does not correlate with the intruder frame; "consecutive distinct tags and commands ..." |
| 6. Cancel partial request, in-flight dispatch and waits, retained or partly read response; fresh work | cancellation: "reset and disable cancel a partial request", "... in the dispatch cycle ...", "... during a READ wait ...", "robustness: ... during an ABORT wait ...", "disable discards a retained response ...", "reset discards a partially read response" |

The tag-0 case follows the HL2 decision. Two bytes of an INFO with tag 0 get a zeroed
`Incomplete` echo that `decode_correlated` accepts as INFO/tag 0; the test requires the
result to be `Incomplete`, not success. For tag `0x33` the same answer is a
`Correlation_mismatch`, which the host replays. The test then reads it without a
correlation check and commits it itself to clean up. That is test housekeeping, not a
recovery policy, and no command is retried.

## Diagnostics and non-vacuity

A failure raises `Harness_failure` with the scenario name, cycle, sampling phase
(`Settle`, `Pre_edge`, `Host_sample`, or `Post_run`), what was checked, the expected and
actual values as S-expressions, and a transcript of the last 48 public-boundary events.
Events are logged only when they happen: reset, enable, select, bytes sent, offers and
decisions, response pulses, status changes, `LRDY` and busy changes, and responses read.
When the transcript is truncated it reports how many earlier events were omitted. No
waveform is produced or required.

In-suite negatives ([`hardware_loader_diagnostics_tests.ml`](../test/host_link/hardware_loader_diagnostics_tests.ml)),
which each require a check to raise:

- The retention check applied after the host commits (an expect test that prints the full
  report, with the transcript limited to 12 events to show truncation).
- An offer expectation one cycle late, which stands in for an added pipeline stage.
- The quiet check applied to a response that was not cancelled.
- A 100-cycle `LRDY` wait on a READ that never completes, which stops exactly at its
  budget.
- A 3-cycle `LCLK` low, which `Timing.validate` refuses.

Temporary production mutations, each applied to `lib/host_link/hardware_loader.ml`, run
with `./scripts/with-switch.sh dune build -j 5 @test/host_link/runtest`, and then
restored by copying a saved file. After each, the file's SHA-256 was again
`29b38a5f…239a`:

| Mutation | Result |
| --- | --- |
| A. Dispatch never clears (`r.dispatch <--. 1` in the dispatch branch) | 23 tests failed, reported per file as framing 7/7, cancellation 6/10, and transaction 10/10. The offer checks listed the repeated offers. The diagnostics negatives still raised, as designed |
| B. Response arming after three deselected cycles (`>=:. 3`) | 2 failed: the arming boundary ("first response byte after a 3-cycle deselected gap", expected `00`) and early selection 3 cycles into dispatch (`LDO` high while clocking) |
| C. Commit on any deselection (`if_ vdd` for `if_ response_drained`) | 4 failed: partial-read replay, final-bit rejection, the arming probe, and the zero-echo replay, each at "retained response keeps LRDY high" |

## Verification

Every Dune command used `-j 5` and ran strictly one after another. The new sources were
frozen (SHA-256 recorded) before the final runs and were unchanged afterwards; only
documents changed later, and no Dune rule reads `docs/`.

| Check | Result |
| --- | --- |
| `./scripts/with-switch.sh dune runtest test/host_link --force -j 5` | PASS, freshly executed, 7 s; 32 tests |
| `./scripts/with-switch.sh dune build @install @lint -j 5` | PASS |
| `./scripts/with-switch.sh dune build @runtest -j 5` | PASS, no output. Up to date after the forced run: every other suite's inputs are unchanged from the baseline |
| `./scripts/with-switch.sh dune build @loader-rtl --force -j 5` | PASS, 7 min 43 s, all three peer tiers freshly executed (reusable core, behavioral wrapper, production synthesis wrapper). Each printed `PASS p3.5 serial loader repair: timing, overrun rejection, replay/commit, status, recovery, production paths; 3/3 sensitivity phases=10, excluded 1/1 failures=10` |
| `./scripts/with-switch.sh dune build @rtl -j 5` | PASS, run after the forced loader run and up to date. No RTL input changed, so Dune reused the earlier passing results |
| `./scripts/with-switch.sh dune build -j 5 @test/host_link/fmt` | PASS. The new files were formatted with `dune promote <file>` one at a time; the repository `@fmt` backlog was not swept |
| `git diff --check`, and a whitespace scan of the new files | PASS; no tab or trailing whitespace in any untracked file |
| Production source and `p3_loader_tb.v` against the starting baseline | Unchanged. The 11 pre-existing non-doc tracked diffs are byte-identical to the starting `git diff`, the three pre-existing untracked HL3 files are byte-identical, and every baseline file hash in the table above matches. `p3_loader_tb.v` has no diff against `HEAD` (blob `2ffc20f0f302c5bad5fd9189056b22c8d8cc175d`) |
| `git diff --cached` | Empty; nothing staged |

The helper rules behind `@loader-rtl` were inspected first: they run Verilator (`-j 1`),
Yosys, and the peer binaries, and make no nested Dune call.

## Findings

No implementation defect was found. None of these is a defect; each is current
behavior that the suite now pins for HL4b:

- A frame that fails deselect validation is answered one cycle before a valid frame would
  be offered (`LRDY` at *s* + 3 against *s* + 4).
- In a cycle with reset high or enable low, a pending dispatch still drives its offer
  valid; the core refuses it by contract, and no response follows.
- An empty selection (select and deselect with no clock) is answered with a zero-echo
  `Incomplete`. So is any frame of fewer than four bytes.
- An extra byte after a shorter valid frame is `Incomplete`; only a twelfth byte is
  overrun (`Bad_length`). This matches the peer's expectations.
- STATUS reports the low 16 bits of the 17-bit PC, as the HL3 record states.
- `busy_o` is a public `Hardware_loader` output that `Loader_core` leaves unconnected, so
  only this suite observes it.

## Remaining obligations

The independent peer, with its three tiers, still owns every row marked full-core or
RTL-only above: actual RAM effects and write counts, the verified-image lifecycle, real
refusal decisions and status, execution and engine behavior, pin release and pin-drive
counts, recovery from looping, blocked, faulting, and transferring programs, replacement
loading, wrapper and production integration, and asynchronous phase and sensitivity
sweeps. The HL3 core-engine and host-simulator suites own the `Control_port` contract at
the real core.

HL4b (block extraction) and HL4c (per-block tests) are pending. Each HL4b extraction
must keep this suite passing unchanged, with the same exact latencies. No physical flow,
mapped area, or timing analysis was run; this is Cyclesim evidence only.
