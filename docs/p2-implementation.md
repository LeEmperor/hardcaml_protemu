# Phase 2 primitive implementation record

Date: 2026-09-18, verification re-run 2026-09-19. Baseline revision: `626ece9`.
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
| [`Observed_transfer`](../lib/observed_transfer.ml) | Connects asynchronous start, pacing, and data pins to one input snapshot before the lane consumes them. Rise, fall, or either edge can start or pace a transaction. | Synchronized start/data/pace and response-latency test. |
| [`Firmware_uart`](../f_model/firmware_uart.ml) | Typed, validated 8N1 TX descriptor used as the independent model-side sequence for the first slice. The same module's bit-banged sequence is P1.3 evidence and is not part of this record. | Its cycle trace matches the UART hardware transmitter for the same byte and timing. |
| [`Uart_tx`](../lib/uart_tx.ml) | One clockless 10-bit lane transaction per 8N1 frame: start 0, byte LSB first, stop 1. Each bit is `2 * half_period_i` clocks. Idle is driven high while enabled; reset/disable/abort release the pin. | Independent bit-center receiver test, back-to-back start, and disable test. [`p2_uart_tb.v`](../tinytapeout/test/p2_uart_tb.v) covers emitted Verilog when HDL tools are available. |

[`generate_p2.ml`](../bin/generate_p2.ml) emits standalone Verilog for every
block in the table. It does not change the P0 wrapper or its committed RTL. The
`@rtl` Dune alias now includes the UART testbench.

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
and drives its preloaded output after edge `k+2`: one additional edge from the
visible event to the engine output. Pacing edges and data pass through the same
snapshot, then the lane consumes them one edge later. The path through a control
instruction and back to a pin has not been measured. These numbers are simulation
results for the current digital topology, not a supported external clock envelope.

## Verification run

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
```

`@runtest` and `@lint` pass. **`@fmt` fails**: now that `ocamlformat` is
installed it can run for the first time, and it reports diffs across the P2 RTL/model
sources, the block-owned suites under `test/primitives/`, `bin/generate_p2.ml`, and
`bin/asic_bundle.ml`. The
P2 sources have never been through the formatter. That is unrelated to their
behavior, but it is an open cleanup, not a passing check.

`@rtl` passes with host Icarus Verilog 12.0 (including `vvp`), Verilator 5.020,
and Yosys 0.33. It passes the P0 wrapper and P2 UART emitted-RTL simulations,
wrapper lint, and a generic synthesis smoke test. The generic Yosys result is not
CMOS5L-mapped evidence; the pinned LibreLane image remains authoritative for the
adopted physical flow.

The first working slice remains open: its typed UART descriptor matches the
model and Hardcaml transmitter, and the emitted UART RTL passes its independent
testbench, but the firmware sequence is not yet connected through the complete
hardware path and matching model/RTL traces have not been saved.
The rest of P1.3's helpers and labels also remain. P2.8 remains open because no generic or liberty-mapped Yosys estimate,
CMOS5L flow run, mapped sequential/combinational area, or formal check has been
recorded. P2.2's time-resolved two-state pilot records a 10--19 tick deterministic
capture latency and phase-dependent sub-period pulse capture; it is not analog
metastability or physical CDC evidence. P2.6 still needs the event-to-core-decision-to-pin measurement and a
measured external timing envelope. The lane's claim mask and pin outputs have
not yet been connected through the integrated pin-bank arbitration at a project
top.
