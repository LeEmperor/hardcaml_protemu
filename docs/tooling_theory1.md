# Tooling theory 1: why the boundary sits at the bundle

This records why the ASIC path is split between OCaml and Python where it is,
so the next person to feel the seam knows which side of it to push on. It is a
rationale document, not a specification: `flow.md` describes what the flow
does, `asic-adoption.md` the bundle it consumes, and
`hardcaml_asic/docs/architecture.md` the library.

## The split

```
declaration ──OCaml──▶ bundle ──Python──▶ run records ──▶ results
   (.ml)               (hashed)           (LibreLane)      (.json)
```

OCaml owns everything up to the bundle. Python owns everything after it. The
bundle is the interface, and nothing crosses it except files.

## Why OCaml before the bundle

The declaration is a program, not a config file. `bin/asic_bundle.ml` computes
its pin descriptions with `List.mapi`, derives its I/O delays from a port list,
and instantiates the design through the same `Elaboration_context` that
simulation uses. A YAML file cannot do that, and every project that starts with
one eventually grows a generator that writes it.

More to the point, the design and its build inputs are the same artifact. The
top-level module's `I`/`O` signature *is* the Tiny Tapeout wrapper contract:
`Resolved_build.validate_interface` checks the declared ports against the TT
user-module ports and refuses to emit if they disagree. There is no hand-written
Verilog wrapper anywhere in the path — the bundle's `src/tt_um_*.v` is generated
from the `Design` module. Keeping the declaration in the same language as the
design is what makes that check possible at all.

## Why Python after the bundle

Because that is what the tools are. LibreLane is a Python package; the TT
support tools are Python; the PDK ships KLayout decks and Magic scripts. An
OCaml flow driver would be a process spawner wrapping Python in a container,
parsing `metrics.csv` on the way back out. The types would buy nothing: by the
time a run is over, the interesting values are strings in a CSV a container
wrote.

## The invariant that decides it

`collect` and `report` read recorded artifacts with the system `python3` only.
A finished or failed run is inspectable on a machine with no opam switch, no
PDK, and no Docker. That property is worth more than any consistency argument
about using one language, and every proposal to move the boundary should be
checked against it first.

It is also why **OCaml must not emit the Python tooling**, an idea that comes up
because it would collapse the two halves into one distributable. Four things go
wrong:

1. It breaks the invariant above. Inspecting an old run would need an opam
   switch to regenerate the inspector.
2. Generated Python cannot be tested as Python — no pytest, no linting, no
   stack trace pointing at reviewable source.
3. Python-in-OCaml-string-literals gets neither language's checking. The
   compiler sees a string; Python finds the error at runtime, inside a
   container, partway into a hardening run.
4. It poisons bundle identity. Identity is a content hash over declared inputs.
   If the tooling is an emitted artifact, a tooling bugfix changes the identity
   of every bundle, for a change that touched no design input.

The same reasoning rules out driving LibreLane from OCaml: it would put the
opam switch back on the critical path for reading a run.

## Why the bundle is a good interface

It is not just a directory. It is:

- **content-addressed** — `identity` is a SHA-256 over the manifest, and the
  manifest hashes every emitted file and every declared source input;
- **self-describing** — target, clock, flow settings, requested tool revisions,
  and the source git revision all travel inside it;
- **honest about provenance** — each input records its `git_status`, so a
  bundle emitted from a dirty tree says so rather than implying a clean commit;
- **tool-agnostic** — nothing in it names OCaml. A different front end could
  emit one, and the Python side would not notice.

An interface with those four properties can absorb a change on either side
without coordination, which is the actual test of a boundary.

## Batteries or hooks: the `reason` field settles it

The library already has the right pattern and it is worth naming. Every raw
LibreLane override carries a mandatory `reason`:

```ocaml
{ Flow.Librelane.Override.key; value; reason }
```

and a small set of settings — `CLOCK_PERIOD`, `VERILOG_FILES`, `DIE_AREA` — are
protected outright, because they are derived from the declaration and an
override would make the bundle lie about itself.

That is the resolution of "batteries-included versus a big set of hooks": a
default that works, an escape hatch beside it, and a toll booth on the escape
hatch. Not a pile of hooks — five consumers with five divergent override sets
and no way to tell which divergences were deliberate is the failure mode that
`reason` exists to prevent.

The defaults half of that pattern now exists on the library side:
`Tt_cmos5l.template_overrides` is the template's twenty LibreLane settings, each
carrying its own `reason` and the template revision it was taken from, and
`Tt_cmos5l.overrides` composes them — `~extra` to replace a default, `~without`
to drop one and let LibreLane choose. A consumer reads the defaults without
running the flow, and a deliberate divergence is spelled as one of those two
arguments rather than as an edited copy of the list.

## What is actually wrong right now

Not the boundary. The **delivery** of the Python side.

The OCaml library is installable: one versioned opam package, pinned by
revision in `tinytapeout/asic-dependencies.lock`, proven by the library's own
`test/package_consumer_smoke.sh`. The Python tooling is not distributed at all
— it lives as scripts in the library's repository, so a consumer copies it:

| protemu file | copied from | lines | local delta |
|---|---|---|---|
| `adopted_phase4.py` | `phase4.py` | 617 | 79 |
| `adopted_report.py` | `report.py` | 233 | 11 |
| `adopted_archive.py` | `archive.py` | 259 | 27 |

Roughly 1,100 vendored lines carrying 117 lines of drift, re-synced by hand
whenever the lock moves. Only the `adopted_phase4.py` delta is real — it uses
this repository's `tinytapeout/test/tb.v` for the gate-level check. The other
two deltas are an import line and a docstring.

The declaration used to show the same disease — twenty LibreLane overrides
byte-identical to the ones in the library's own `examples/tt_bundle_example.ml`,
two copies with one real consumer. That one is fixed: `bin/asic_bundle.ml` is
153 lines, takes its settings from `Tt_cmos5l.overrides ()`, and its wrapper
ports, reset and pad gating come from `Tt_cmos5l` as well. The fix was the
pattern above — defaults in the library, a named escape hatch beside them — and
it is the shape the Python side still needs.

This is a maintenance and adoption problem, not a reproducibility problem.
Reproducibility is already handled by content hashing and the lock; the copies
are committed here and pinned by this repository's history. The cost lands
when the library fixes a bug and every consumer re-syncs by hand, and when a
second design has to copy ~4,000 lines of `tinytapeout/scripts/` before it can
harden anything.

The fix keeps the architecture and changes only delivery: ship the Python as a
package pinned by revision, exactly as the OCaml package already is, and add it
to the lock file that already pins the other four things. Provisioning
(`bootstrap-toolchain.sh`, 1,123 lines, the largest single file in
`tinytapeout/scripts/`) belongs in that package too, with this repository's
`bootstrap.sh` reduced to a shim that picks a lock file and calls it — handmade
rather than generated, so an odd environment stays fixable.

## Summary

Keep the boundary at the bundle. Keep OCaml out of the flow and Python out of
the declaration. Template defaults on the OCaml side are done; the remaining
work is packaging on the Python side, and it does not require moving the line.
