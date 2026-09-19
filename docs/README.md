# Documentation index

| Document | What it covers |
| --- | --- |
| [protemu.pdf](protemu.pdf) | Architecture planning brief: problem framing for the protocol emulator ASIC, proposed cores and primitives, protocol mapping (UART, SPI, I²C, USB, Ethernet), and open architecture questions. Start here for the "why". |
| [construction-plan.md](construction-plan.md) | Construction plan built on the brief: scope, what exists today, stack ownership, primitive and shared-port memory contracts, ISA study, protocol milestones, host control, ASIC/Workbench integration, build sequence, verification, and open decisions. |
| [phase_plan.md](phase_plan.md) | Actionable breakdown of the construction plan: stable work-item IDs, phase dependencies, deliverables, completion evidence, the first working UART transmit slice, and the parallel ASIC project/memory adoption track. Use this to select and track implementation work. |
| [p2-implementation.md](p2-implementation.md) | Phase 2 primitive interfaces, model/RTL evidence, digital latency observations, and remaining verification and physical measurements. |
| [asic-adoption.md](asic-adoption.md) | P0.6 project declaration, pinned ASIC dependency, bundle emission, and adopted-wrapper checks. |
| [flow_migration.md](flow_migration.md) | The canonical `./flow.sh` entry point: the migration to one adopted implementation path, run artifacts, compatibility decisions, and what the acceptance checks did and did not verify. |
| [environment.md](environment.md) | Entry points and environment layers: `./bootstrap.sh`, `source env.sh`, `./flow.sh`, `dune exec protemu -- <command>`, and what to run on a new machine, a fresh clone or worktree, a new shell, or after a lockfile change. |
| [bootstrap-toolchain-plan.md](bootstrap-toolchain-plan.md) | Contract and open acceptance checks for the implemented CMOS5L bootstrap script: host prerequisites, project-local dependencies, pinned inputs, staging, safety, idempotence, and completion checks. |
| [formatting_guide.md](formatting_guide.md) | Hardware structure: file headers, `_i`/`_o` port naming, module layout, the `I_Regs`/`I_Wires` paradigm, the `Always` vs `Signal` split, and (later) testbench architecture. |
| [comment_guidelines.md](comment_guidelines.md) | Repo-specific examples for explanatory comments and hand formatting in hardware and model source. |

## Reading order

1. **protemu.pdf** — the design problem and proposed direction.
2. **construction-plan.md** — how the repository gets from scaffold to working system.
3. **phase_plan.md** — select the next implementation slice and its completion checks.
4. **bootstrap-toolchain-plan.md** — before implementing or reproducing the local ASIC flow.
5. **formatting_guide.md** — before writing or editing any Hardcaml module.
6. **comment_guidelines.md** — for comments and manually aligned source.

## Related project authorities

- [`hardcaml_asic` architecture](../../hardcaml_asic/docs/architecture.md): accepted
  project/resource/target ownership, generated build bundles, and flow integration.
- [Program-memory contract](../../hardcaml_asic/docs/program-memory-contract.md):
  authoritative `Single_port_ram` behavior and backend verification obligations.
- [Workbench architecture](../../workbench/docs/hardcaml_workbench_architecture.md):
  independent projects, optional versioned driver integration, jobs, and artifacts.
- [Tiny Tapeout integration guide](../tinytapeout/README.md) and
  [experiment record format](../tinytapeout/reports/README.md): current scripts,
  migration to ASIC-generated inputs, and build/execution evidence.

These sibling links refer to the current workspace checkout names; standalone
clones may need the related repositories opened separately. They are not build
paths. The protocol brief PDF and historical experiment records retain their
original scope; current decisions and execution status live in the Markdown plans.

When adding a document to `docs/`, add a row to the table above.
