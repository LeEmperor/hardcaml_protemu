# Phase 2 primitive implementation record

Date: 2026-09-18. Baseline revision: `626ece9`. The sources described here are
uncommitted working-tree changes. This record is functional evidence, not a mapped
CMOS5L cost report.

## Blocks and contracts

| Block | Interface and behavior | Evidence |
| --- | --- | --- |
| [`Pin_bank`](../lib/pin_bank.ml) | Eight registered value/enable pins; masked commits; software and one engine claim masks; conflicting claims/writes are refused with sticky conflict status. Open-drain writes force data low regardless of supplied data. Reset, abort, and disable release outputs and claims. | [`test_primitives.ml`](../test/test_primitives.ml): model comparison, masking, open drain, conflict, reset/disable/abort. |
| [`Input_events`](../lib/input_events.ml) | Two synchronizer stages, one registered snapshot, rise/fall pulses, six sticky event bits, set-wins acknowledgement, and per-bit overflow. | Model comparison over 100 deterministic cycles, set/ack/overflow and reset tests. |
| [`Timing`](../lib/timing.ml) | 16-bit delay, level/edge wait with optional timeout, and a free-running periodic tick with phase restart. A delay accepted at edge `k` completes at `k+n`; zero is rejected. Immediate level success does not produce a delayed completion event, matching the model. | Reference-machine comparison, exact delay, stale edge, event-over-timeout, periodic activity during waits, and phase restart tests. |
| [`Primitive_demo`](../lib/primitive_demo.ml) | Composes a wait and an independent transfer lane on the same clock without gating the lane on timer busy. | Transfer output changes and completes while the core wait remains active. |
| [`Byte_fifo`](../lib/byte_fifo.ml) | Eight-bit flop queue, selectable depth 4/8/16, explicit ready/valid, simultaneous full pop/push, sticky overflow/starvation. Reset and disable clear occupancy without clearing data cells. Instantiate separately for TX and RX. | Reference-model comparison and boundary tests at all three depths. |
| [`Shift_lane`](../lib/shift_lane.ml) | Validated 1..32-bit descriptor, LSB/MSB order, TX/RX/duplex, first-bit preload, separate launch/sample half-edges, internal or observed pacing, arming, and safe release on abort/underrun/overrun. Drive claims are exposed as a mask; conflicts are checked at direct start or at the event that starts an armed transfer. | [`Shift_engine`](../model/shift_engine.ml) comparison for internal and observed schedules, both bit orders, and both clock idle levels; direction, width, conflict, fault, and abort tests. |
| [`Observed_transfer`](../lib/observed_transfer.ml) | Connects asynchronous start, pacing, and data pins to one input snapshot before the lane consumes them. Rise, fall, or either edge can start or pace a transaction. | Synchronized start/data/pace and response-latency test. |
| [`Firmware_uart`](../model/firmware_uart.ml) | Typed, validated 8N1 TX descriptor used as the independent model-side sequence for the first slice. The same module's bit-banged sequence is P1.3 evidence and is not part of this record. | Its cycle trace matches the UART hardware transmitter for the same byte and timing. |
| [`Uart_tx`](../lib/uart_tx.ml) | One clockless 10-bit lane transaction per 8N1 frame: start 0, byte LSB first, stop 1. Each bit is `2 * half_period_i` clocks. Idle is driven high while enabled; reset/disable/abort release the pin. | Independent bit-center receiver test, back-to-back start, and disable test. [`p2_uart_tb.v`](../tinytapeout/test/p2_uart_tb.v) covers emitted Verilog when HDL tools are available. |

[`generate_p2.ml`](../bin/generate_p2.ml) emits standalone Verilog for every
block in the table. It does not change the P0 wrapper or its committed RTL. The
`@rtl` Dune alias now includes the UART testbench.

## Timing observed in digital simulation

The input front end presents a transition after two sampling edges when it arrives
before the first edge. If it arrives just after one edge, the first usable sample
is the next edge, giving up to three clock periods from that earlier edge. These
are digital pipeline bounds; metastability can add uncertainty, and no analog
reliability or minimum pulse width has been measured. A pulse must be present at
a sampling edge and survive the two-stage path to be observed. No input filter
has been selected.

In the composed observed transfer, a start transition sampled at edge `k` appears
as a snapshot and edge pulse after edge `k+1`. The armed lane consumes that pulse
and drives its preloaded output after edge `k+2`: one additional edge from the
visible event to the engine output. Pacing edges and data pass through the same
snapshot, then the lane consumes them one edge later. The path through a control
instruction and back to a pin has not been measured. These numbers are simulation
results for the current digital topology, not a supported external clock envelope.

## Verification run

The repository's selected `5.2.0+ox` switch lacks `hardcaml_circuits`,
`core_unix`, `alcotest`, and `ocamlformat`. It also lacks `iverilog`,
`verilator`, and `yosys`. The full repository build and `@fmt` therefore could
not run; `@lint` passed. To compile and test the P2 sources without altering the
repository's declared dependencies, a temporary Dune project under `/tmp` used
the installed `core`, `hardcaml`, `ppx_hardcaml`, `ppx_jane`, and `jane_rope` packages.
It copied the new RTL modules and the separate `model/` library. Its `dune runtest`
passed all 24 tests from `test/test_primitives.ml`. Each block's Verilog was
emitted twice and compared byte for byte. `git diff --check` passed.

Reproduction in a fully provisioned checkout:

```sh
./scripts/with-switch.sh dune build @fmt
./scripts/with-switch.sh dune build @lint
./scripts/with-switch.sh dune build @runtest @rtl
./scripts/with-switch.sh dune exec bin/generate_p2.exe -- uart_tx /tmp/uart_tx.v
```

The first working slice remains open: its typed UART descriptor matches the
model and Hardcaml transmitter, but emitted RTL simulation has not run here.
The rest of P1.3's helpers and labels also remain. P2.8 remains open because no generic or liberty-mapped Yosys estimate,
CMOS5L flow run, mapped sequential/combinational area, or formal check has been
recorded. P2.2 still needs asynchronous-phase sweeps with a time-resolved pad
driver; P2.6 still needs the event-to-core-decision-to-pin measurement and a
measured external timing envelope. The lane's claim mask and pin outputs have
not yet been connected through the integrated pin-bank arbitration at a project
top.
