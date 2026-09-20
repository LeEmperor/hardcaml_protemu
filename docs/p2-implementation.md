# Phase 2 primitive implementation record

Date: 2026-09-18, verification re-run 2026-09-20, P2.7 closed 2026-09-19,
P2.6b real-core measurement completed 2026-09-20.
Baseline revision: `626ece9`.
The original P2 sources described here were uncommitted working-tree changes when the
record was written and are committed as of `9fd703d`. The 2026-09-20 P2.6b preparation
described below is uncommitted work on `fbe0a982`. This record is functional evidence, not
a mapped CMOS5L cost report.

## Blocks and contracts

| Block | Interface and behavior | Evidence |
| --- | --- | --- |
| [`Pin_bank`](../lib/pin_bank.ml) | Eight registered value/enable pins; masked commits; software and one engine claim masks; conflicting claims/writes are refused with sticky conflict status. Open-drain writes force data low regardless of supplied data. Reset, abort, and disable release outputs and claims. | [`test/primitives/pin_bank/`](../test/primitives/pin_bank): model comparison, masking, open drain, conflict, reset/disable/abort. |
| [`Input_events`](../lib/input_events.ml) | Two synchronizer stages, one registered snapshot, rise/fall pulses, six sticky event bits, set-wins acknowledgement, and per-bit overflow. | Model comparison over 100 deterministic cycles plus a two-state Evsim integer-phase/pulse/reset sweep and 160 generated timed trials. |
| [`Timing`](../lib/timing.ml) | 16-bit delay, level/edge wait with optional timeout, and a free-running periodic tick with phase restart. A delay accepted at edge `k` completes at `k+n`; zero is rejected. Immediate level success does not produce a delayed completion event, matching the model. | Reference-machine comparison, exact delay, stale edge, event-over-timeout, periodic activity during waits, and phase restart tests. |
| [`Primitive_demo`](../lib/primitive_demo.ml) | Composes a wait and an independent transfer lane on the same clock without gating the lane on timer busy. | Transfer output changes and completes while the core wait remains active. |
| [`Byte_fifo`](../lib/byte_fifo.ml) | Eight-bit flop queue, selectable depth 4/8/16, explicit ready/valid, simultaneous full pop/push, sticky overflow/starvation. Reset and disable clear occupancy without clearing data cells. Instantiate separately for TX and RX. | Reference-model comparison and boundary tests at all three depths. |
| [`Shift_lane`](../lib/shift_lane.ml) | Validated 1..32-bit descriptor, LSB/MSB order, TX/RX/duplex, first-bit preload, separate launch/sample half-edges, internal or observed pacing, arming, and safe release on abort/underrun/overrun. Drive claims are exposed as a mask; conflicts are checked at direct start or at the event that starts an armed transfer. | [`Shift_engine`](../f_model/shift_engine.ml) comparison for internal and observed schedules, both bit orders, and both clock idle levels; direction, width, conflict, fault, and abort tests. |
| [`Observed_transfer`](../lib/observed_transfer.ml) | Connects asynchronous start, pacing, cancellation/select, and data pins to one input snapshot. Start, pacing, and optional cancellation selectors latch with an accepted arm; descriptor fields latch in the lane. `arm_valid_i` and `tx_valid_i` are acceptance handshakes, while `rx_ready_i`, `occupied_i`, explicit abort/disable, and asynchronous pads remain live. Rise, fall, or either edge may be selected. A synchronized cancellation, including falling-edge select withdrawal, aborts armed or active work without completion. | Directed wrapper tests cover stale-event rejection, selector/descriptor latching, invalid selectors and pacing-role conflicts, start-time ownership conflicts, queue faults, cancellation priority, release, and recovery. The timed suite covers lengths 1 and 32, both orders, all directions and edge kinds, both launch/sample arrangements, phase/width/data boundaries, 48 generated trials at seed `20260920`, reconstructed pins, and an independent external peer that samples every TX/duplex bit. |
| [`Observed_transfer_bank`](../lib/observed_transfer_bank.ml) | Reserves the configured output pin in the real [`Pin_bank`](../lib/pin_bank.ml) when an arm is accepted, forwards lane writes as masked engine commits, clears output enable before releasing ownership, and arbitrates one software request port. Internal requests have priority; a simultaneous software request is explicitly refused. Local synchronized cancellation affects only the engine mask, while reset, disable, and explicit abort retain the bank's global-release contract. | [`test/integration/observed_transfer_bank/`](../test/integration/observed_transfer_bank) observes lane and bank boundaries separately and compares every timed bank transaction with an independent `Input_pins`/`Shift_engine`/`Pin_bank` composition. It covers idle-low/high wire mappings, all integer phases, lengths 1/8/32, both orders, TX/RX/duplex, ownership conflict/retry, unrelated software state, normal cleanup, cancellation/rearm, reset/disable/abort, and 24 generated scenarios at seed `20260920`. |
| [`Firmware_uart`](../f_model/firmware_uart.ml) | Typed, validated 8N1 TX descriptor used as the independent model-side sequence for the first slice. The same module's bit-banged sequence is P1.3 evidence and is not part of this record. | Its cycle trace matches the UART hardware transmitter for the same byte and timing. |
| [`Uart_tx`](../lib/uart_tx.ml) | One clockless 10-bit lane transaction per 8N1 frame: start 0, byte LSB first, stop 1. Each bit is `2 * half_period_i` clocks. Idle is driven high while enabled; reset/disable/abort release the pin. | Independent bit-center receiver test, back-to-back start, and disable test. [`p2_uart_tb.v`](../tinytapeout/test/p2_uart_tb.v) covers emitted Verilog when HDL tools are available. |
| [`Uart_slice`](../lib/uart_slice.ml) | P2.7's first working slice. A six-state harness claims the transmit pin for the engine, spends one bit period of [`Timing`](../lib/timing.ml) countdown driving the resting level, offers the byte to `Uart_tx`, commits every bit through a masked [`Pin_bank`](../lib/pin_bank.ml) engine write, and releases the claim after the stop bit. The pin therefore lags the lane by exactly one cycle, uniformly. Reset, disable, and abort release pin and claim together. | One independent receiver decodes four producers to the same frame; [`uart_frame.trace`](../test/integration/uart_slice/uart_frame.trace) is the saved trace. [`p2_uart_slice_tb.v`](../tinytapeout/test/p2_uart_slice_tb.v) repeats the receiver in Verilog and diffs the same file. |

[`generate_p2.ml`](../bin/generate_p2.ml) emits standalone Verilog for every
block in the table. It does not change the P0 wrapper or its committed RTL. The
`@rtl` Dune alias now includes the UART testbench and the UART slice testbench.

## Timing observed in digital simulation

The time-resolved input-front-end sweep uses abstract integer ticks, a ten-tick clock,
and a deterministic convention that settles an exact-edge pad transition before the
clock. Across all ten integer phases, the synchronized edge indication appeared 10--19
ticks after the external transition: a value sampled at one edge reaches the registered
snapshot after the following edge. A two-tick pulse crossing a sampling edge was captured;
an eight-tick pulse wholly between edges was missed. A pulse must cover a sampling point;
a full-period pulse guarantees that in this digital model, while no sub-period width does
independently of phase. These are digital pipeline results, not setup/hold, metastability,
analog pulse, or physical timing evidence. No input filter has been selected.

In the composed observed transfer, a start transition sampled at edge `k` appears
as a snapshot and edge pulse after edge `k+1`. The armed lane consumes that pulse
and drives its preloaded output after edge `k+2`. Pacing, cancellation/select, and data
use that same snapshot and the lane consumes their edge indication one clock later.
The timestamped suite under
[`test/primitives/observed_transfer/`](../test/primitives/observed_transfer) records:

| Path | Measured digital latency |
| --- | --- |
| External transition to synchronized event | 10--19 ticks, or 1.0--1.9 system-clock periods |
| Synchronized event to engine action | 10 ticks, or one system-clock period |
| External start to driven preload | 20--29 ticks, or 2.0--2.9 system-clock periods |
| External cancellation/select withdrawal to release | 20--29 ticks, or 2.0--2.9 system-clock periods |
| Explicit abort, disable, or reset to release | The next rising system-clock edge; the directed between-edge case is 9 ticks |
| Ordinary lane preload/data output to `Pin_bank` commit | 10 ticks, or one system-clock period, in `Observed_transfer_bank` |
| External start/launch to committed bank output | 30--39 ticks, or 3.0--3.9 system-clock periods |
| External cancellation to committed output-enable clear | 20--29 ticks; ownership release follows one clock later, at 30--39 ticks |
| Event to core decision to committed pin | 60--69 ticks external-to-bank: 10--19 external-to-synchronized, 20 synchronized-to-core-decision, and 30 decision-to-bank-request; the registered bank commits after that request edge |

The independent external peer reconstructs its sampling schedule from pad transitions
only and samples `pin_value_o`/`pin_oe_o` strictly before each scheduled edge. The stated
wire envelope assumes at least one simulator tick of peer setup: a lane output update at
the same timestamp as the peer edge is too late. The measured 20--29 tick external-launch
to pin response includes the lane's registered output update. The standalone number does
not include a `Pin_bank` commit; the separately measured integration below adds it.

| Use | Verified digital requirement | 48 MHz implication |
| --- | --- | --- |
| Input edge capture only | High and low each at least 10 ticks; 9 misses some phases | Equal halves permit 24 MHz capture |
| RX-only wire transfer | Capture rule above, plus data valid by the pacing transition and held through the next system sampling edge (conservatively 10 ticks over all phases) | Equal 10-tick halves permit 24 MHz digital RX |
| Standalone TX/duplex, preloaded first bit | Select to first sample at least 30 ticks; every later launch-to-sample interval at least 30 ticks; opposite half at least 10 ticks | Asymmetric 10/30 halves permit 12 MHz; symmetric halves require 30/30 and permit 8 MHz |
| Standalone TX/duplex, first bit launched | Select to first launch at least 10 ticks, then at least 30 ticks to sample; opposite half at least 10 ticks | Asymmetric operation permits 12 MHz; symmetric 30/30 permits 8 MHz |
| Bank-integrated TX/duplex, preloaded first bit | Select to first sample at least 40 ticks; every later launch-to-sample interval at least 40 ticks; opposite half at least 10 ticks | Asymmetric 10/40 halves permit 9.6 MHz; symmetric 40/40 permits 6 MHz |
| Bank-integrated TX/duplex, first bit launched | Select to first launch at least 10 ticks, then at least 40 ticks to sample; opposite half at least 10 ticks | Asymmetric operation permits 9.6 MHz; symmetric 40/40 permits 6 MHz |

Thus the former unqualified 24 MHz external-clock statement was only an input-capture and
RX-only limit. It was not a multi-bit TX/duplex wire limit: 10/10-tick pacing completes
inside the engine but the independent peer observes stale subsequent bits. At the supported
30-tick launch-to-sample boundary, first and subsequent bits each have a minimum measured
setup of one tick; 29 ticks fails at some phases. The standalone peer sweep covers 1-, 8-,
and 32-bit TX and duplex, both bit orders, idle-low and idle-high, both preload-first and
launch-first arrangements, all ten integer phases, and asymmetric high/low values at and
above the boundary. The bank-integrated sweep repeats that matrix at the committed bank
outputs; 40 ticks gives one tick of setup and 39 fails at some phases. RX-only repeats the
1/32-bit, order, idle-level, and phase matrix at 10/10 ticks and never claims an output.

The physical mappings are explicit. Idle-low preload-first is falling-edge launch with
rising-edge sample; idle-low launch-first is rising launch with falling sample. Idle-high
reverses the meanings: rising launch/falling sample is preload-first, and falling
launch/rising sample is launch-first. These wire claims require `pacing_edge=Either`, an
alternating clock initialized to `idle_clock`, and the first transition to be the physical
leading edge. A rise-only or fall-only event stream is still functionally covered as an
ordinal event source, but the lane alternates its internal leading/trailing phase for every
selected event; it is not evidence for an alternating physical clock or all SPI modes.

Start/select still precedes the first pacing event by at least 10 ticks to keep synchronized
events distinct; nine ticks can merge them. Normal completion and interruption release
ownership. The earliest rearm acceptance is the following rising edge, and start must be
a subsequent synchronized event. These are digital capture/pipeline limits, not analog
setup/hold closure or metastability evidence.

At an assumed 48 MHz system clock, one period is 20.833 ns and one simulator tick is
2.083 ns. A future UART RX at 1 Mbaud has 48 system clocks per bit, so the 2.0--2.9-clock
start path is small relative to a bit but its phase-dependent offset must be compensated
before center sampling. This wrapper is externally paced; P4 UART RX still needs a fixture
that restarts internal timing from the synchronized start event. An idle-low SPI target
experiment may use the measured 12 MHz asymmetric or 8 MHz symmetric TX/duplex limits;
the standalone path supports the measured idle-low and idle-high mappings above. The
bank-integrated boundary supports 9.6 MHz asymmetric or 6 MHz symmetric TX/duplex under
the same digital assumptions. Neither boundary includes the Tiny Tapeout wrapper, pad,
board delay, analog setup/hold, or metastability behavior.

## Real-core scenario and measurement

The P2.6b fixture uses one concrete existing-ISA program,
`wait_start_then_drive`, in [`test_isa.ml`](../test/f_model/test_isa.ml). The fixture begins
with pin 0 claimed by `Owner.Software`; this uses the existing bank initialization contract
because the current ISA has no claim/release instruction. The loaded program then establishes
the observable initial level itself, waits for the selected external event, makes the
instruction-driven write, and halts:

```text
write_pins_imm push_pull, mask=0x01, value=0x00
wait_edge pin=3, rising, no timeout
write_pins_imm push_pull, mask=0x01, value=0x01
halt
```

In the default 16-bit store the exact words are `0x7804 0x0000 0xa300 0x7804 0x0001
0x0000`, with little-endian transport bytes `04 78 00 00 00 a3 04 78 01 00 00 00`.
It is four instructions, six slots, two extension words, six memory words, and 96 program
bits. The independent `Control_core` loads those words through `Program_store`, executes
the event after the wait has armed, drives pin 0 low then high, and halts in 13 edges:
six fetch, four execute, and three wait-stall edges. Its recorded waveform is
`zz00000000111`. This remains the independent model schedule used to prepare the RTL
measurement.

The P2.6b fixture uses this exact image first, then sweeps the external pin-3
transition through every integer phase after `Wait_edge` acceptance. Record:

| Timestamp | Definition |
| --- | --- |
| External pad | The scheduled pin-3 boundary transition before any synchronizer |
| Synchronized event | The post-edge timestamp where the shared `Input_events.rising_o` for pin 3 is visible |
| Instruction decision | The pre-edge acceptance where the active `Wait_edge` consumes that event, event-over-timeout precedence is resolved, and fetch may resume; report PC/slot and decoded operation with it |
| Bank request | The pre-edge software `Write_pins_imm` request and independently predicted acceptance |
| Bank commit | The post-edge change of registered `Pin_bank.pins_o`/`pin_oe_o` |
| Observable boundary | The post-settle system output carrying those bank signals; add a separate wrapper/pad timestamp if P3 introduces another register |

Use program name, exact words/bytes, memory layout `m16`, depth, initial software claim,
initial pin state, the P1.5 non-overlapped fetch/execute schedule, event phase relative to
both the ten-tick clock and the wait's execute edge, and a finite limit of 256 system edges.
The first mismatch must report external time, edge index, slot/PC, decoded instruction,
expected/actual acceptance, event state, bank request, ownership, value/enable, nearby
samples, source/configuration identity, and an executable fixed-seed replay command.

[`test/integration/core_engine/`](../test/integration/core_engine) activates that contract:
it loads and reads back the exact image while halted and engines idle, asserts
load-complete, applies RUN, waits until the real edge wait is armed, schedules every integer
phase of pin 3, and runs to `Halt` within the finite bound. The resulting external-to-bank
range is 60--69 ticks. The synchronized event is 10--19 ticks after the pad transition, the
core decision is 20 ticks later, and the decoded bank request is another 30 ticks later;
the bank commits after that request edge. The direct observed-engine/bank path remains
30--39 ticks, so the loaded core path adds 30 ticks for this program. This is the real
P3.1a/P3.2/P3.3 path, not a sequencer or direct event-to-pin substitute.

## Verification run

The P2.6b real-core measurement was run on 2026-09-20 from `61384c3` plus the preserved
dirty P3.2 fixes and uncommitted P3.3 implementation. The deterministic phase sweep and
loaded-program integration pass under
`./scripts/with-switch.sh dune runtest test/integration/core_engine --force`; emitted RTL
passes under `./scripts/with-switch.sh dune build @tinytapeout/test/rtl --force`. Full
repository results and remaining non-P2.6 limitations are in the
[P3.3 record](p3.3-implementation.md).

The dependency-independent P2.6b preparation was verified on 2026-09-20 from
`fbe0a982fce99fe4cb1718167445ad496d46bde2` plus the preserved dirty working tree.
The primitive generator uses seed `20260920` for 48 scenarios; the bank integration uses
the same fixed seed for 24 scenarios in addition to its exhaustive directed phase matrix.
Results:

```sh
./scripts/with-switch.sh dune runtest test/primitives/observed_transfer test/integration/observed_transfer_bank test/primitives/pin_bank test/primitives/shift_lane test/primitives/input_events test/integration/uart_slice test/f_model --force  # passes
./scripts/with-switch.sh dune build @runtest  # passes
./scripts/with-switch.sh dune build @lint     # passes
./scripts/with-switch.sh dune build @fmt      # fails on the existing repository backlog
./scripts/with-switch.sh dune build @rtl      # passes; no observed-transfer-bank behavioral simulation
./scripts/with-switch.sh dune exec bin/generate_p2.exe -- observed_transfer_bank /tmp/observed_transfer_bank.v  # passes
git diff --check  # passes
```

`ocamlformat --check` passes for every touched OCaml file. The repository-wide `@fmt`
failure remains in untouched files including `tinytapeout/test/dune`, `test/common/dune`,
`test/primitives/pin_bank/dune`, earlier P2/model sources, and `bin/asic_bundle.ml`; the
new composition and tests add no formatter failure. `@rtl` still runs the P0 wrapper,
UART and UART-slice simulations, wrapper lint, and generic Yosys smoke test. It does not
instantiate or behaviorally simulate `Observed_transfer_bank`. Standalone generation
succeeds; a direct Verilator lint exits zero with Hardcaml-generated `COMBDLY` warnings and
one unused `idle_clock_i` warning, but this is syntax/lint evidence rather than behavioral
simulation. The Cyclesim/Evsim integration suite is the behavioral evidence for the changed
composition.

The P2.6 envelope was verified on 2026-09-20 from
`aae22fc15fe2a0e1f8b2a7d990709ef741da2a0a` plus the recorded dirty working tree,
using OCaml `5.2.0+ox`, the pinned switch, and the replay/source identity captured by
[`Replay`](../test/common/replay.ml). The bounded timed run uses seed `20260920` and
48 generated scenarios in addition to directed sweeps. Commands and results were:

```sh
./scripts/with-switch.sh dune runtest test/primitives/observed_transfer --force  # passes
./scripts/with-switch.sh dune runtest test/primitives/shift_lane test/primitives/input_events --force  # passes
./scripts/with-switch.sh dune build @runtest  # passes
./scripts/with-switch.sh dune build @lint     # passes
./scripts/with-switch.sh dune build @fmt      # fails on the pre-existing repository backlog
./scripts/with-switch.sh dune build @rtl      # passes; does not simulate Observed_transfer
./scripts/with-switch.sh dune exec bin/generate_p2.exe -- observed_transfer /tmp/observed_transfer.v  # passes
```

`ocamlformat --check` passes for the four touched implementation/test files, and
`git diff --check` passes. Repository `@fmt` still reports the historical P2/model/test
backlog described below; the P2.6 files add no formatting failure. `@rtl` verifies its
existing P0/UART/UART-slice targets and therefore is not observed-transfer behavioral
evidence. Standalone `Observed_transfer` Verilog emission succeeds, but no emitted-RTL
testbench was added; the block-owned Cyclesim/Evsim suites own the current behavior evidence.

These sources were first tested from a temporary Dune project under `/tmp`,
because the switch then lacked `core_unix`, `alcotest`, and `ocamlformat` and the
repository build could not run. That workaround is obsolete: `./bootstrap.sh`
installs those packages, and the tests now run in place. `hardcaml_circuits` is
not a dependency of anything in this repository.

Re-run in this checkout on 2026-09-19, through the pinned switch:

```sh
./scripts/with-switch.sh dune build @runtest   # passes
./scripts/with-switch.sh dune build @lint      # passes
./scripts/with-switch.sh dune build @fmt       # FAILS; see below
./scripts/with-switch.sh dune build @rtl       # passes with host HDL tools
./scripts/with-switch.sh dune exec bin/generate_p2.exe -- uart_tx /tmp/uart_tx.v
./scripts/with-switch.sh dune exec bin/generate_p2.exe -- uart_slice /tmp/uart_slice.v
```

`@runtest` and `@lint` pass. **`@fmt` fails**: now that `ocamlformat` is
installed it can run for the first time, and it reports diffs across the P2 RTL/model
sources, the block-owned suites under `test/primitives/`, `bin/generate_p2.ml`, and
`bin/asic_bundle.ml`. The
P2 sources have never been through the formatter. That is unrelated to their
behavior, but it is an open cleanup, not a passing check. The P2.7 sources added
afterwards -- [`uart_slice.ml`](../lib/uart_slice.ml) and everything under
[`test/integration/uart_slice/`](../test/integration/uart_slice) -- are formatted, so
they do not add to that pile.

The P2.7 suite remains under its own integration directory with its purpose-built frame
monitor and Cyclesim loops. During the 2026-09-20 verification integration it adopted
`test/common/`'s replay settings, source/dependency identity, and artifact conventions
for a bounded generated property without forcing the directed loops through `Env`.
Seed `20260920` runs 96 fresh-state trials over bytes, all pins, half-periods 2--12,
normal completion, and reset/disable/abort positions. Completed trials compare the
firmware, descriptor, and Hardcaml frames only after each receiver independently finds
its start edge; this is frame-relative evidence, not request-to-start latency evidence.
Interrupted trials check synchronous next-edge release of both pin drive and ownership.
The `firmware_samples` trailing-idle extension now derives from the requested half period
rather than the old module default.

That generated range is bounded test coverage, not a revised supported-input contract. The
firmware producer requires half periods of at least two. Independently, the slice doubles
the 16-bit `half_period_i` into the timer's 16-bit leading-idle countdown: zero and values
at or above 32768 encounter primitive refusal or doubled-countdown overflow respectively.
Slice-level handling of these requests is not established by the suite. Positive inputs
through 32767 avoid that overflow, but the generated 2--12 range does not verify the wider
range or half-period 1. See verification.md for the separate generated-failure reporting
and controlled-replay gaps. The fixed `0xa6` vector remains the exact period-measurement
calibration; arbitrary bytes require only that the transition-interval GCD be a multiple
of the bit period.

`@rtl` passes with host Icarus Verilog 12.0 (including `vvp`), Verilator 5.020,
and Yosys 0.33. It passes the P0 wrapper, the P2 UART, and the P2.7 UART slice
emitted-RTL simulations, wrapper lint, and a generic synthesis smoke test. The generic Yosys result is not
CMOS5L-mapped evidence; the pinned LibreLane image remains authoritative for the
adopted physical flow.

The first working slice is closed. Its frame now runs through the pin and timer
hardware in [`uart_slice.ml`](../lib/uart_slice.ml), and one independent receiver
decodes four producers of it to the same ten-bit table: P1.3's bit-banged sequence on
the reference machine, the same frame as one typed descriptor on the reference transfer
engine, the Hardcaml slice sampled at the bank's pins, and the emitted Verilog. The
receiver is written twice, in OCaml and in Verilog, so that the model side and the RTL
side cannot share a mistake, and both write
[`uart_frame.trace`](../test/integration/uart_slice/uart_frame.trace): `@runtest` emits
it only after the three OCaml producers agree and diffs the committed copy, and `@rtl`
diffs the Verilog copy against the same file. Reset, disable, and abort part way through
a frame release the pin and the engine's claim on the next edge in both harnesses.
What the slice does not establish: the harness is not the control core, so nothing here
measures a fetched-and-decoded instruction reaching a pin, and the physical cost of the
slice is P2.8's and P5's, not this record's.

P2.8 remains open because no generic or liberty-mapped Yosys estimate,
CMOS5L flow run, mapped sequential/combinational area, or formal check has been
recorded. P2.2's time-resolved two-state pilot records a 10--19 tick deterministic
capture latency and phase-dependent sub-period pulse capture; it is not analog
metastability or physical CDC evidence. P2.6's primitive and real-core digital envelopes
are recorded above, and P2.6 is complete. The lane's claim mask and pin
outputs now run through bank
arbitration in both the protocol-specific [`uart_slice.ml`](../lib/uart_slice.ml) and the
generic [`observed_transfer_bank.ml`](../lib/observed_transfer_bank.ml), each for one engine.
The loaded [`Integrated_core`](../lib/integrated_core.ml) now supplies the central core/lane
arbiter and bank boundary. It still does not reach the Tiny Tapeout wrapper or physical
pads; those remain project integration and physical-timing work.
