# ASIC flow entry-point migration

Status: implemented, 2026-09-18. The root `flow.sh` interface described below
exists; [the handoff](#implementation-handoff) at the end of this document records
what changed, what was verified, and what was not. Everything before that section
is the plan as written, kept as the statement of intent it was judged against.

## Objective

Make `./flow.sh` the canonical command for protemu's ASIC implementation flow.
Use Dune underneath it for compilation, development tests, and bundle emission.
Use the existing `hardcaml_asic` bundle path as the implementation authority.

Keep `./bootstrap.sh` as the command that prepares and validates the environment.
Keep orchestration owned by protemu while `hardcaml_asic` is early in development.
Its example runner provides a useful pattern, but normal consumer operation must
not depend on scripts or paths in a sibling library checkout.

This work changes flow integration and command ergonomics. It does not expand the
hardware design beyond the current adopted P0 observable circuit, change timing
constraints, upgrade dependencies, or establish that the design physically closes.

## Why this interface

`dune exec protemu -- harden` is technically valid: `dune exec` builds and launches
an executable, and does not make its physical run a cached Dune build rule.
However, the current executable mostly dispatches to shell scripts. A direct flow
entry point gives the scripts a simple public interface and allows inspection of
existing results without first compiling OCaml tooling.

The important migration is to one implementation path. A CLI alias is acceptable
provided that it delegates to the same runner and preserves its behavior and exit
status. Physical runs should remain explicit invocations with durable run records;
ordinary `dune build` and `dune runtest` must not start physical implementation.

## Repository state before this migration

| Component | Current behavior |
| --- | --- |
| [`bootstrap.sh`](../bootstrap.sh) | Converges OCaml dependencies, then invokes the `protemu bootstrap` command for flow tools. |
| [`bin/protemu.ml`](../bin/protemu.ml) | Provides environment commands and wrappers around legacy staging, hardening, and precheck scripts. |
| [`bin/asic_bundle.ml`](../bin/asic_bundle.ml) | Declares the adopted P0 design and emits its `hardcaml_asic` bundle. |
| [`adopted-flow.sh`](../tinytapeout/scripts/adopted-flow.sh) | Runs explicit `bootstrap`, `emit`, `preflight`, `run`, `postcheck`, `collect`, and `report` steps. No arguments printed help. |
| [`adopted_phase4.py`](../tinytapeout/scripts/adopted_phase4.py) | Implements bundle preflight, physical execution, postchecks, and result collection. |
| [`adopted_report.py`](../tinytapeout/scripts/adopted_report.py) | Reads run results and reports physical/timing verdicts. |

At that point, `dune exec protemu -- harden` selected the legacy staged project,
whereas `adopted-flow.sh run` selected the emitted bundle. These are different input paths,
not interchangeable spellings of the same operation. The default bootstrap also
staged the legacy project; its `--adopted-only` mode already skipped that work.

Read [asic-adoption.md](asic-adoption.md) for the bundle contract and current
commands, and [environment.md](environment.md) and
[bootstrap-toolchain-plan.md](bootstrap-toolchain-plan.md) for environment
ownership. The library's [example runner](../../hardcaml_asic/scripts/flow.sh)
is a reference for stage sequencing, duration reporting, and failure summaries.
That sibling link is for development reference only.

## Intended command contract

| Command | Responsibility |
| --- | --- |
| `./bootstrap.sh` | Prepare the pinned OCaml and flow tools, validate them, and print the next commands. |
| `./bootstrap.sh --check` | Validate the environment without provisioning or generating design artifacts. |
| `dune build`, `dune runtest` | Compile tooling and perform development checks. |
| `./flow.sh` | Run the complete adopted flow in a fresh output directory. |
| `./flow.sh STEP [STEP ...]` | Execute the requested stages in order. |
| `./flow.sh --help` | Explain stages, environment overrides, output selection, and how to resume. |

The default full sequence is:

```text
build/test → emit bundle → preflight → run → postcheck → collect → report
```

Keep the existing stage name `run` for the physical operation; describe it as
hardening in help text. Provide a `build` stage for compilation and development
tests. Explicit stage selection must not silently invoke earlier expensive stages.
The runner may validate prerequisites needed by a selected stage.

The no-argument command intentionally starts a full physical run. State that
clearly in help and bootstrap output. Bootstrap remains a separate operation;
neither full flow execution nor bundle emission should implicitly provision tools.

Use the existing `PROTEMU_*` overrides where practical. These examples describe
the proposed interface:

```sh
./bootstrap.sh
source env.sh
./flow.sh

# Prepare one named experiment without starting physical implementation.
export PROTEMU_FLOW_OUT="$PWD/tinytapeout/build/my-experiment"
./flow.sh build emit preflight
./flow.sh run postcheck collect report

# Inspect or finish checks on a specific existing run.
PROTEMU_RUN=/absolute/path/to/run ./flow.sh postcheck collect report
PROTEMU_RUN=/absolute/path/to/run ./flow.sh report
```

Preserve the existing synthesis-only selection (`PROTEMU_STAGE=synthesis`).
Document an appropriate stage sequence for it; do not automatically run postchecks
that require a full physical result or present synthesis success as physical closure.

## Artifact and failure behavior

- Allocate a fresh output directory for a default full invocation. Use a collision
  resistant name and print its absolute path before starting work.
- An explicit `PROTEMU_FLOW_OUT` identifies the chosen experiment. Refuse to
  overwrite a nonempty bundle; never delete it automatically to make emission pass.
- Emit once, then consume that immutable bundle for the attempt. Preserve the
  manifest, input provenance, configuration, constraints, and source sets.
- Create a unique run directory for each physical attempt. Preserve failed runs
  and logs as well as successful ones.
- Carry the exact run returned by the runner through later stages in the same
  invocation. Separate invocations use explicit `PROTEMU_RUN`; do not guess the
  intended run by choosing the newest directory.
- A normal stage failure stops dependent stages and returns a nonzero status.
  Always print a final summary with elapsed stage times, overall time, failed or
  interrupted stage, and paths to records and logs that actually exist. Handle
  ordinary termination signals without hiding the failure status.
- Retain the ability to collect or report on a failed run separately. Distinguish
  missing evidence from a passing check. Reporting must preserve the existing
  required physical/timing verdicts.
- `collect` and `report` should require only their existing Python/runtime inputs
  and recorded artifacts. They must not rebuild the design, require an activated
  opam switch, or trigger provisioning.

## Implementation work

1. Promote the adopted runner behind a root `flow.sh` entry point. It may remain
   implemented under `tinytapeout/scripts/`; keep exactly one orchestration
   implementation. Reuse the existing Python runner and reporter.
2. Add the full-run default, `build` stage, fresh output allocation, and final
   summary. Resolve repository and tool paths from the script location. Reuse
   `scripts/with-switch.sh` where needed for Dune operations so an activated
   interactive shell is not a hidden requirement.
3. Make bootstrap's normal flow-tool path use the adopted provisioning mode.
   Remove legacy design staging/config generation from normal bootstrap and
   doctor/check paths. Preserve existing environment validation and supported
   bootstrap options. Audit the root bootstrap's current Dune dispatch so
   `--check` does not need to build an executable just to validate flow tools.
4. Remove ambiguity from `protemu` commands. If retaining `harden` or a new
   `flow` alias, delegate to the canonical runner. Preserve legacy access under
   explicitly named legacy commands during transition. Do not silently accept
   old flags such as `-tag` or `-no-docker` with changed meanings: translate them
   accurately or return a clear migration diagnostic. Audit `check`, `stage`,
   and `precheck` as well so their help identifies which inputs they use.
5. Keep legacy scripts available until the adopted route is validated. The old
   `adopted-flow.sh` path may remain as a compatibility wrapper; document any
   difference in its no-argument behavior rather than duplicating orchestration.
6. Update `docs/environment.md`, `docs/asic-adoption.md`, the bootstrap guide,
   `tinytapeout/README.md`, command help, and bootstrap summaries to recommend the
   canonical flow. Update phase tracking where appropriate without marking
   physical milestones complete from interface work alone.

Keep the current lockfile authority and bundle/collateral mismatch checks. Avoid
introducing a new shared cache, a generic workflow framework, or a reusable runner
package in this migration. Do not copy the example runner's machine-specific
defaults or automatic latest-run selection. Leave existing user changes intact;
this checkout contains concurrent design and tooling work.

## Acceptance and verification

The migration is complete when the documented commands select one adopted
implementation path and the following behavior has been verified:

- Help works without the OCaml or physical toolchain. Commands invoked from a
  different working directory resolve the correct repository and artifacts.
- Bootstrap prepares tools without staging a design or starting hardening;
  `--check` performs validation without building or generating artifacts.
- The default flow sequences the intended stages. Explicit preparation stages
  do not start LibreLane. Existing metadata/bundle checks pass, including source
  hashes, configuration conflicts, and simulation/synthesis source separation.
- Output allocation does not collide or overwrite existing bundles. Multiple
  attempts retain distinct run records, and later stages target the selected run.
- A failed stage and an interrupted run retain diagnostics, print the summary,
  and return a failure status. Exercise orchestration failures with lightweight
  stubs or fixtures rather than repeatedly running physical implementation.
- Existing-run reporting works with OCaml tooling unavailable. Any retained CLI
  alias reaches the same runner and propagates its exit status.
- Perform an adopted end-to-end smoke run when the provisioned environment is
  available, preserving its evidence. Report separately whether orchestration
  worked and whether physical/timing/postcheck gates passed. If the environment
  prevents that run, record the specific unverified acceptance item.

Use existing bundle and wrapper regressions where relevant, plus focused checks
for the new orchestration behavior. The implementation handoff should list changed
entry points, compatibility decisions, checks performed, and remaining limitations.

The bootstrap output mentioned in the discussion was not available as actual text;
this plan is grounded in the repository scripts and documentation, and makes no
claim that the user's bootstrap or a physical run has passed.


## Implementation handoff

### Changed entry points

| Entry point | What it is now |
| --- | --- |
| [`flow.sh`](../flow.sh) | New. The canonical flow command. With no steps it calls the runner with `--full`; otherwise it passes steps through. It resolves the repository from its own location and execs the runner, so exit status is the runner's. |
| [`adopted-flow.sh`](../tinytapeout/scripts/adopted-flow.sh) | The one orchestration implementation, extended with the `build` stage, `--full` (the default sequence plus fresh output allocation), per-stage timing, the final summary, and signal handling. Dune now runs through `scripts/with-switch.sh`, so no activated shell is required. |
| [`bootstrap.sh`](../bootstrap.sh) | Calls `bootstrap-toolchain.sh` directly instead of `dune exec protemu -- bootstrap`, so neither mode compiles an executable. Provisioning defaults to the adopted path; `--legacy-project` is the new opt-in for legacy staging. |
| [`bootstrap-toolchain.sh`](../tinytapeout/scripts/bootstrap-toolchain.sh) | Adopted provisioning is the default (`adopted_only=1`); `--legacy-project` restores staging and user-configuration generation, and `--adopted-only` is accepted as a no-op. Both summaries name `./flow.sh` and separate it from the legacy commands. |
| [`bin/protemu.ml`](../bin/protemu.ml) | `flow` is a new alias that execs `./flow.sh`. `harden` now means `./flow.sh run`. `legacy-harden` is the old staged-project hardening. `check`, `stage` and `precheck` keep their behavior and say in their help which inputs they read. |
| [`check-flow.sh`](../tinytapeout/scripts/check-flow.sh) | New. Orchestration checks with a stub in place of dune. |

### Compatibility decisions

- `adopted-flow.sh` still prints help when called with no arguments. Only
  `./flow.sh` turns a bare invocation into a full physical run; the runner is not
  given that meaning, because anything already calling it bare would start
  hardening. `--full` is the explicit spelling, and the two differ in nothing else.
- `protemu harden` rejects `-tag` and `-no-docker` with a diagnostic naming
  `legacy-harden`, rather than translating them. The adopted runner is dockerized
  with the pinned image and archives nothing — every attempt already gets its own
  run directory — so neither flag has an honest equivalent.
- Named steps keep the previous default output directory,
  `tinytapeout/build/adopted`. Only a full default invocation allocates a fresh
  one, so `./flow.sh postcheck collect report` still finds an existing experiment.
- `--adopted-only` is still accepted by `bootstrap-toolchain.sh` so the commands
  recorded in earlier documents and notes keep working.
- `--adopted-only` combined with `--no-container` was previously a hard error.
  It is now a warning that skips resolving the pinned image, so `--no-container`
  remains usable with the default provisioning mode for someone supplying a
  native LibreLane.
- The legacy scripts, the staged project, and `dune build @rtl` are untouched.

### Checks performed

- `tinytapeout/scripts/check-flow.sh`: 14 checks, 0 failures. Help without OCaml
  or flow tools (`env -i`); the runner's own no-argument help; unknown-step and
  `--full`-with-steps rejection; resolution from another working directory;
  `report`/`collect` refusing to guess a run, including with a decoy run
  directory present; reaching the reporter for an existing run under `env -i`;
  emission refusing a nonempty bundle and leaving it intact; fresh output
  allocation, twice, without collision; a failed stage stopping the ones after
  it, with no later stage reached; and SIGTERM giving exit 143, a
  `did not finish` row, and the summary.
- `./flow.sh build emit preflight` on this checkout: build 10s, emit 1s,
  preflight 0s, `"ready": true`, no run directory created and LibreLane not
  started.
- `python3 tinytapeout/scripts/check-adopted-bundle.py`: passes, including the
  repeatable-manifest, conflict, wrapper-trace, lint and synthesis checks.
- `./bootstrap.sh --check`: validates every layer, changes nothing, stages
  nothing, and compiles no executable.
- `dune exec protemu -- doctor`: both layers ok. `protemu flow report` reaches
  the runner and returns its exit status (2). `protemu harden -tag NAME` and
  `-no-docker` produce the migration diagnostic and exit 2.

### Remaining limitations

- **No end-to-end physical run was performed**, so the acceptance item asking for
  an adopted smoke run with preserved evidence is unverified. Orchestration is
  checked; `run` and `postcheck` have been exercised only as far as `preflight`.
  Nothing here says the design closes.
- Reporting on a failed or interrupted run is therefore also unverified against a
  real failed run; only the missing-run and stub paths were exercised.
- A SIGTERM sent to the flow alone (rather than to the process group, as Ctrl-C
  does) is acted on after the running stage's command returns, because bash defers
  a trap until the foreground command completes. The status and the summary are
  correct; the wait is not shortened.
- `PROTEMU_STAGE=synthesis` is documented and passed through, but has not been
  run since this change.
