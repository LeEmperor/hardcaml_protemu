# ASIC experiment records

Commit one short Markdown record per useful architecture/physical-flow experiment.
Keep raw logs, layouts, and tool caches in ignored output directories or CI
artifacts. A local artifact path is temporary; preserve the underlying package
when a result becomes a design decision.

Suggested record:

```markdown
# <experiment name and date>

Question: <the decision this run informs>

- Source commit and any uncommitted patch/input hash:
- Generated RTL hash and generator parameters:
- Template/action/support-tools revisions:
- LibreLane/container/PDK revisions:
- Program memory implementation, width/depth and read latency:
- Core/register/engine configuration; FIFO widths/depths:
- Tile allocation, clock period, timing corners and I/O assumptions:
- Tests, protocol fixtures and random seeds:
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
