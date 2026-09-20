# Phase 2 primitive implementation record

Date: 2026-09-18, verification re-run 2026-09-20, P2.7 closed 2026-09-19,
P2.6 primitive envelope completed 2026-09-20.
Baseline revision: `626ece9`.
The sources described here were uncommitted working-tree changes when the record
was written; they are committed as of `9fd703d`. This record is functional
evidence, not a mapped CMOS5L cost report.

## Blocks and contracts

| Block | Interface and behavior | Evidence |
| --- | --- | --- |
| [`Pin_bank`](../lib/pin_bank.ml) | Eight registered value/enable pins; masked commits; software and one engine claim masks; conflicting claims/writes are refused with sticky conflict status. Open-drain writes force data low regardless of supplied data. Reset, abort, and disable release outputs and claims. | [`test/primitives/pin_bank/`](../test/primitives/pin_bank): model comparison, masking, open drain, conflict, reset/disable/abort. |
| [`Input_events`](../lib/input_events.ml) | Two synchronizer stages, one registered snapshot, rise/fall pulses, six sticky event bits, set-wins acknowledgement, and per-bit overflow. | Model comparison over 100 deterministic cycles plus a two-state Evsim integer-phase/pulse/reset sweep and 160 generated timed trials. |
| [`Timing`](../lib/timing.ml) | 16-bit delay, level/edge wait with optional timeout, and a free-running periodic tick with phase restart. A delay accepted at edge `k` completes at `k+n`; zero is rejected. Immediate level success does not produce a delayed completion event, matching the model. | Reference-machine comparison, exact delay, stale edge, event-over-timeout, periodic activity during waits, and phase restart tests. |
| [`Primitive_demo`](../lib/primitive_demo.ml) | Composes a wait and an independent transfer lane on the same clock without gating the lane on timer busy. | Transfer output changes and completes while the core wait remains active. |
| [`Byte_fifo`](../lib/byte_fifo.ml) | Eight-bit flop queue, selectable depth 4/8/16, explicit ready/valid, simultaneous full pop/push, sticky overflow/starvation. Reset and disable clear occupancy without clearing data cells. Instantiate separately for TX and RX. | Reference-model comparison and boundary tests at all three depths. |
| [`Shift_lane`](../lib/shift_lane.ml) | Validated 1..32-bit descriptor, LSB/MSB order, TX/RX/duplex, first-bit preload, separate launch/sample half-edges, internal or observed pacing, arming, and safe release on abort/underrun/overrun. Drive claims are exposed as a mask; conflicts are checked at direct start or at the event that starts an armed transfer. | [`Shift_engine`](../f_model/shift_engine.ml) comparison for internal and observed schedules, both bit orders, and both clock idle levels; direction, width, conflict, fault, and abort tests. |
| [`Observed_transfer`](../lib/observed_transfer.ml) | Connects asynchronous start, pacing, cancellation/select, and data pins to one input snapshot. Start, pacing, and optional cancellation selectors latch with an accepted arm; descriptor fields latch in the lane. `arm_valid_i` and `tx_valid_i` are acceptance handshakes, while `rx_ready_i`, `occupied_i`, explicit abort/disable, and asynchronous pads remain live. Rise, fall, or either edge may be selected. A synchronized cancellation, including falling-edge select withdrawal, aborts armed or active work without completion. | Directed wrapper tests cover stale-event rejection, selector/descriptor latching, invalid selectors and pacing-role conflicts, start-time ownership conflicts, queue faults, cancellation priority, release, and recovery. The timed suite covers lengths 1 and 32, both orders, all directions and edge kinds, both launch/sample arrangements, phase/width/data boundaries, 48 generated trials at seed `20260920`, and reconstructed pins. |
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
| Additional pin-bank commit | Not included: this primitive exposes lane pins directly |
| Event to core decision to committed pin | Not measurable: P3.2 decode and P3.3 core/engine integration do not exist |

The verified external envelope uses abstract ticks and a ten-tick system-clock period.
Every external high and low interval is at least 10 ticks; a nine-tick schedule misses
events at some phases. Start/select precedes the first pacing event by at least 10 ticks
to keep the two synchronized events distinct; nine ticks can merge them. For TX or duplex
target traffic, the peer's first sampling clock instead waits at least 30 ticks after
start/select, so the 20--29 tick registered preload is already visible; 29 ticks can
coincide with that update and has no digital margin. Data is valid no later than the
pacing transition and remains stable through the next system sampling edge. Coincident
data is captured under the suite's exact-edge-before-clock convention, data one tick
later is not, and the conservative all-phase hold rule is 10 ticks. Selected-only rise
or fall pacing therefore needs both high and low intervals of at least 10 ticks; either-edge
pacing may consume each transition at those same minimum widths. Normal completion and
interruption release ownership. The earliest rearm acceptance is the following rising
edge (one system-clock period after the completion/interruption edge); an event coincident
with that acceptance is stale, so start must be a subsequent synchronized event.

At an assumed 48 MHz system clock, one period is 20.833 ns: the verified 10-tick high/low
minimum permits at most a 24 MHz external clock with equal minimum halves, the preload
response is 41.7--60.4 ns, and the conservative first sampling edge is at least 62.5 ns
after select. These are digital capture/pipeline limits, not analog setup/hold closure or
metastability evidence. A future UART RX at 1 Mbaud has 48 system clocks per bit, so the
2.0--2.9-clock start path is small relative to a bit but its phase-dependent offset must
be compensated before center sampling. This wrapper is externally paced; P4 UART RX still
needs a fixture that restarts internal timing from the synchronized start event. SPI
target experiments must enforce the 30-tick first-sample lead, 10-tick high/low and data
stability rules and may not claim higher rates without new phase evidence.

## Verification run

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
metastability or physical CDC evidence. P2.6's primitive digital envelope is recorded
above; the parent remains open only for the real event-to-core-decision-to-committed-pin
measurement after P3.2/P3.3. The
lane's claim mask and pin outputs now run through
pin-bank arbitration in [`uart_slice.ml`](../lib/uart_slice.ml), for one engine and one
claimed pin; a project top that arbitrates between engines, and the Tiny Tapeout wrapper
that would carry it, are still P3 and P0.7 work.
