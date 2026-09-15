# Documentation index

| Document | What it covers |
| --- | --- |
| [protemu.pdf](protemu.pdf) | Architecture planning brief: problem framing for the protocol emulator ASIC, proposed cores and primitives, protocol mapping (UART, SPI, I²C, USB, Ethernet), and open architecture questions. Start here for the "why". |
| [construction-plan.md](construction-plan.md) | Construction plan built on the brief: scope, what exists today, initial architecture and primitive contracts, minimum control ISA and memory study, protocol milestones, host control, build sequence, verification, and open decisions. |
| [phase_plan.md](phase_plan.md) | Actionable breakdown of the construction plan: stable work-item IDs, phase dependencies, deliverables, completion evidence, and the first working UART transmit slice. Use this to select and track implementation work. |
| [bootstrap-toolchain-plan.md](bootstrap-toolchain-plan.md) | Specification for a future reproducible CMOS5L bootstrap script: host prerequisites, project-local dependencies, pinned inputs, staging, safety, idempotence, and completion checks. |
| [formatting_guide.md](formatting_guide.md) | Source of truth for coding style: file headers, `_i`/`_o` port naming, module layout, the `I_Regs`/`I_Wires` paradigm, the `Always` vs `Signal` split, and (later) testbench architecture. |

## Reading order

1. **protemu.pdf** — the design problem and proposed direction.
2. **construction-plan.md** — how the repository gets from scaffold to working system.
3. **phase_plan.md** — select the next implementation slice and its completion checks.
4. **bootstrap-toolchain-plan.md** — before implementing or reproducing the local ASIC flow.
5. **formatting_guide.md** — before writing or editing any Hardcaml module.

When adding a document to `docs/`, add a row to the table above.
