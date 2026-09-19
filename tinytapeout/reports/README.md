# ASIC experiment records

Commit one short Markdown record per useful architecture/physical-flow experiment.
Keep raw logs, layouts, and tool caches in ignored output directories or CI
artifacts. A local artifact path is temporary; preserve the underlying package
when a result becomes a design decision.

After ASIC adoption, reference the immutable `hardcaml_asic` build manifest and a
separate execution record. Do not mutate a build manifest to add run results or
substitute a Workbench job ID for either identity. A Workbench job may reference
both. Earlier records remain valid historical evidence with unavailable fields
labeled `legacy/not recorded`; do not backfill invented provenance.

The build captures requested tool/dependency revisions, content/source sets,
target, resource selections, constraints, and resolved settings. The execution
captures actual environment/tool versions, commands, completion state, and outputs.
Keep simulation models separate from synthesis/black-box sources. Preserve dirty
or untracked input contents and referenced collateral with consequential results;
hashes identify inputs but do not make them retrievable.

Suggested record:

```markdown
# <experiment name and date>

Question: <the decision this run informs>

- Build manifest identity/hash and preserved input bundle location:
- Execution record identity/status (distinct from build emission):
- Optional Workbench generating job/artifact IDs:
- Source/dependency revisions and dirty/untracked input hashes/content location:
- Generated RTL hash, declared configuration, and generator parameters:
- Simulation/synthesis source sets and collateral hashes/locations:
- Resolved harness/technology revisions, settings, and override reasons:
- Template/action/support-tools revisions:
- Requested and actual LibreLane/container/PDK revisions:
- Program-memory instance identity, requested width/depth/latency, selected
  implementation, selection policy, and any fallback reason:
- Core/register/engine configuration; FIFO widths/depths:
- Tile allocation, clock period, timing corners and I/O assumptions:
- Firmware/image format and hashes; tests, protocol fixtures, and random seeds:
- Reproduction command and artifact location:

| Measurement | Result |
| --- | --- |
| Mapped cell area and sequential/combinational split | |
| Placed/routed utilization and routing issues | |
| Worst setup and hold slack, with corner | |
| Unconstrained paths and reviewed exceptions | |
| DRC/LVS/antenna/precheck results | |
| Gate-level test result | |
| Program words per protocol | |
| Observed input-to-output latency range | |
| Verified protocol rates and external pulse-width limits | |
| FIFO service budget and sustained host throughput | |

Conclusion: <what to keep/change and why>

Limitations: <checks not run, model assumptions, missing board evidence>
```

Use `not run` or `unknown` for missing measurements. A synthesis-only result
cannot establish routed timing, usable die area, or successful tapeout checks.
