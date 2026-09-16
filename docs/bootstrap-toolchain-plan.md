# ASIC toolchain bootstrap plan

Status: specification, 2026-09-15. Implemented the same day as
[`tinytapeout/scripts/bootstrap-toolchain.sh`](../tinytapeout/scripts/bootstrap-toolchain.sh).
No machine has yet completed a full run: the acceptance criteria in section 10
remain open, and the PDK install mechanism in step 8 is still unconfirmed.
[`tinytapeout/toolchain.lock`](../tinytapeout/toolchain.lock) is the version
authority; examples in this document must not override it.

## 1. Purpose

Add a reproducible, project-local bootstrap command for preparing the tools needed
to take generated Verilog through the Tiny Tapeout CMOS5L flow. A fresh clone on a
supported machine should be able to fetch and validate the pinned support tools,
Python environment, LibreLane release, and IHP PDK without copying physical files
into tracked design directories.

Proposed entry point:

```sh
tinytapeout/scripts/bootstrap-toolchain.sh
```

Bootstrapping prepares the environment; it does not prove that the design passes
hardening or submission checks. Keep hardening, gate-level testing, physical
verification, and precheck as explicit later commands with their own results.

## 2. Ownership model

Keep three categories separate:

| Category | Examples | Ownership |
| --- | --- | --- |
| Host prerequisites | Git, Python, a container runtime, basic shell utilities | Installed by the user or operating-system administrator |
| Project-local toolchain | Python virtual environment, support-tools checkout, IHP PDK | Ignored paths under `tinytapeout/` |
| Tracked design inputs | Hardcaml source, wrapper, metadata, flow configuration, lockfile, scripts | This repository |

The bootstrap must not install host packages with `sudo`, modify global Python
packages, or silently configure a container daemon. Host setup varies across
Linux distributions and macOS and requires authority outside this repository.
Detect missing prerequisites and print a precise remediation message instead.

The default local layout should be:

```text
scaf/
  .venv/                   ignored Python environment for the ASIC flow
  tinytapeout/
    pdk/                   ignored IHP Open PDK checkout
    tt/                    ignored pinned support-tools checkout
    build/p0-staged/       ignored generated Tiny Tapeout project
    runs/                  ignored physical-flow output
    toolchain.lock         tracked version authority
```

An external support-tools checkout remains supported through
`TT_SUPPORT_TOOLS_DIR`. For example, the current development layout uses the
sibling `../tt-support-tools-cmos5l` Git worktree. The staged project receives an
ephemeral `tt` symlink; neither the symlink nor an absolute developer path is
committed. Do not copy individual DEF files into the design repository and do not
add the PDK as a Git submodule.

## 3. Host prerequisites

The script must check these before downloading or installing anything:

- POSIX-like shell environment with Bash.
- Git.
- Python 3.11 or newer, with virtual-environment support.
- A recent Docker-compatible container runtime installed, running, and usable by
  the current user.
- Common utilities used by the scripts: `awk`, `grep`, `sha256sum`, `realpath`,
  `make`, and a downloader if required by the pinned upstream installer.
- Enough free disk space for the PDK, Python environment, container images, and
  physical-design runs. The implementation should measure free space and publish
  a conservative minimum only after observing a successful clean bootstrap.

Icarus Verilog, Verilator, and a host Yosys are useful for fast local checks but
are not substitutes for the versions used by the pinned physical flow. The
bootstrap may report their presence without requiring them when the containerized
flow supplies the necessary implementations.

## 4. Locked inputs

Read values from [`tinytapeout/toolchain.lock`](../tinytapeout/toolchain.lock)
rather than duplicating revisions in the script. Required keys are:

- Template repository, branch, and revision.
- GDS action repository, branch, and revision.
- Support-tools repository, branch, and revision.
- PDK name, repository, and revision.
- LibreLane version.
- Python version expectation.
- Current tile allocation, `6x4`.
- Floorplan DEF relative path, SHA-256, die area, and validation status.

Reject a malformed lockfile, duplicate keys, missing required keys, unsupported
process, or an allocation other than the explicitly supported target. Do not use
`source toolchain.lock`; parse it as data so a modified lockfile cannot execute
shell code.

## 5. Proposed command behavior

The default command should perform these steps in order:

1. Resolve the repository root from the script location rather than the caller's
   current directory.
2. Parse and validate `toolchain.lock`.
3. Check host prerequisites without making changes.
4. Create `.venv` at the repository root if absent and verify that an existing
   environment uses a compatible Python. It lives at the root, not under
   `tinytapeout/`, because LibreLane and precheck are ASIC-flow tools rather than
   Tiny Tapeout ones.
5. Obtain support tools:
   - Use `TT_SUPPORT_TOOLS_DIR` when supplied.
   - Otherwise clone into `tinytapeout/tt`.
   - Fetch and check out the exact locked revision in detached-HEAD state.
   - Reject unexpected tracked or untracked changes before use.
6. Install the support-tools Python requirements inside `.venv`. Note that
   `precheck/requirements.txt` pins `klayout` and `gdstk` differently and cannot
   share this environment; precheck needs its own.
7. Install the exact locked LibreLane version inside `.venv` and verify the
   resolved installed version.
8. Obtain the IHP Open PDK under `tinytapeout/pdk` using the installer and revision
   selected by the pinned CMOS5L GDS action.
9. Verify the PDK identity and revision from its `SOURCES` record, plus the
   required standard-cell Liberty, LEF, GDS, and gate-level Verilog views.
10. Verify the support-tools process selection, `6x4` tile-size entry, floorplan
    DEF path, DEF SHA-256, and die area against the lockfile.
11. Run `tinytapeout/scripts/stage-project.sh` using the validated support-tools
    path.
12. Generate the staged LibreLane user configuration with the equivalent of:

    ```sh
    python tinytapeout/tt/tt_tool.py \
      --project-dir tinytapeout/build/p0-staged \
      --create-user-config \
      --ihp
    ```

13. Inspect the generated configuration and confirm its design name, explicit
    RTL source list, `ihp-sg13cmos5l` PDK, `6x4` die area, clock port/period, top
    routing layer, and `tt_block_6x4_pgvdd.def` reference.
14. Print a concise environment summary and the exact next commands for RTL
    regression, hardening, report inspection, gate-level simulation, and precheck.

Network operations should be explicit in the output. Support `--offline` to
validate and reuse an already populated environment without fetching or installing
anything. A useful later extension is `--check`, which performs every validation
but makes no changes.

## 6. Idempotence and update policy

Running the bootstrap repeatedly with the same lockfile must converge on the same
environment without recloning valid repositories or reinstalling unchanged
packages unnecessarily.

- Reuse a valid checkout at the locked revision.
- Never discard local changes automatically. Stop with an actionable error.
- Never switch an external checkout supplied by `TT_SUPPORT_TOOLS_DIR`; validate
  it and ask the user to select the required revision themselves.
- A managed checkout under `tinytapeout/tt` may fetch missing objects and move to
  the locked detached revision only when it is clean.
- Do not update to branch heads implicitly. Updating tools is a reviewed change to
  `toolchain.lock`, followed by a clean bootstrap and regression.
- Do not delete PDKs, environments, runs, or caches automatically. A separate
  cleanup command must name exact ignored targets and explain their recoverability.

Record enough state to diagnose partial installations. A failed bootstrap should
be safe to rerun after correcting the reported problem.

## 7. Environment handoff

The bootstrap cannot permanently export variables into its caller's shell. It
should generate an ignored activation file, for example:

```text
tinytapeout/build/toolchain-env.sh
```

That file may export only project-specific values such as:

```sh
export PDK=ihp-sg13cmos5l
export PDK_ROOT=/absolute/path/to/scaf/tinytapeout/pdk
export TT_SUPPORT_TOOLS_DIR=/absolute/path/to/scaf/tinytapeout/tt
```

Users would activate the Python environment and flow variables with an explicit
command printed by the bootstrap. Do not modify shell startup files.

## 8. Follow-on commands

After bootstrap succeeds, provide repository scripts rather than requiring users
to reconstruct long commands:

```text
tinytapeout/scripts/check-p0.sh          existing RTL/model/generic synthesis checks
tinytapeout/scripts/harden-cmos5l.sh     future mapped synthesis and place-and-route
tinytapeout/scripts/test-gates.sh        future flow-netlist wrapper simulation
tinytapeout/scripts/precheck.sh          future required Tiny Tapeout checks
tinytapeout/scripts/report-run.sh        future artifact hashes and experiment summary
```

Each command must consume the same lockfile and activation data. The hardening
script should preserve the complete LibreLane run directory and return a failing
status when required steps or timing checks fail. Gate-level testing must use the
IHP unpowered netlist and PDK Verilog models expected by the selected flow.

## 9. Safety and failure messages

The implementation must:

- Restrict writes to ignored paths beneath `tinytapeout/` unless the user supplies
  an external checkout explicitly.
- Resolve and validate paths before any recursive removal or replacement.
- Avoid `sudo`, global `pip`, global environment changes, and implicit Docker
  configuration.
- Never overwrite a dirty checkout, existing non-virtual-environment directory,
  or mismatched PDK installation.
- Verify downloaded Git objects by revision and physical inputs by hash.
- Distinguish a missing host prerequisite, network failure, revision mismatch,
  unsupported floorplan, incomplete PDK, flow failure, and design failure.
- Avoid reporting generic Yosys synthesis as CMOS5L mapped synthesis or physical
  closure.

## 10. Acceptance criteria

The bootstrap implementation is complete when all of these are demonstrated:

- A clean clone with documented host prerequisites can populate all ignored
  project-local dependencies using one bootstrap command.
- A second invocation performs no unnecessary downloads and produces the same
  validated result.
- `--offline` succeeds with a complete cache and fails clearly when an artifact is
  missing.
- A wrong support-tools branch, dirty checkout, modified DEF, wrong PDK revision,
  wrong LibreLane version, or missing container runtime is detected before the
  physical flow starts.
- The staged `info.yaml` requests `6x4`, and generated LibreLane configuration
  resolves the locked CMOS5L `6x4` DEF and exact RTL sources.
- The existing P0 regression remains green.
- The prepared environment reaches synthesis using the intended CMOS5L Liberty
  files; record mapped area and tool versions.
- A full P0 physical run can subsequently complete placement/routing, timing,
  required physical checks, precheck, and gate-level wrapper simulation without
  untracked manual setup.
- A reproduction record identifies the source revision, lockfile hash, generated
  RTL hash, support-tools/PDK/LibreLane revisions, commands, and artifact paths.

## 11. Work not delegated to bootstrap

Keep these decisions and actions outside the bootstrap command:

- Installing or administering Docker and host operating-system packages.
- Selecting a different tile allocation, PDK, template, or clock target.
- Accepting future `8x4` support before an explicit competition update and a
  reviewed lockfile change.
- Editing RTL, wrapper pins, timing constraints, or flow configuration.
- Deleting physical runs or submission artifacts.
- Uploading artifacts, enabling CI, or submitting the design.

