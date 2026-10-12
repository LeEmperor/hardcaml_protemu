# HL4b4 implementation record: `Frame_tx` extraction and final helper/check ownership (2026-09-25)

Status: HL4b4 (`Frame_tx` extraction, shared CRC ownership, and standalone elaboration
checks) and its HL4c4 focused tests are implemented and verified by an agent in the working
tree. **Not committed:** nothing is committed or staged; the repository owner commits. This
is the fourth and last planned child of [HL4b](host_link_migration.md#hl4--link-decomposition).
**Accepted by the owning planning session on 2026-09-25**, together with parent HL4b,
HL4c, and the migration exit gate. See [the acceptance decision](#planning-acceptance-decision)
and the handoff checklist below. Implementation completion is separate from the owner's
remaining commit.

Every functional, RTL, formal, and synthesis gate passed. The helper/check move (stage 1)
left all emitted RTL byte-identical; the `Frame_tx` move (stage 2) changed emitted
`loader_core` only by six register renames, one 1-bit forward wire, and anonymous
renumbering, and it is proven sequentially equivalent to the accepted HL4b3 implementation
(1 505/1 505). External ports are identical. The loader checker's generic synthesis is
**24 431 cells, every per-type count unchanged, and 5 318 mapped flip-flops**, and the
mapped flip-flop inventory is bit-for-bit identical after the rename: a zero incremental
delta, and −677 cells / −65 flip-flops cumulatively against the unsplit 25 108 / 5 383
(HL4b3's accepted change). No mapped-area, timing, or power claim follows.

The [P3.5 record](p3.5-hardware-loader.md) remains the wire and timing authority. No wire
value, codec policy, public port, timing requirement, `Control_port` field or contract, or
HL4a/HL4c1/HL4c2/HL4c3 stimulus or expectation changed.

## Starting revision and local diff

- `HEAD` = `89a3fe88d7dc0381e1817d44e4a40c481a9868af` ("re-org phase 1", HL2), branch
  `bpurtell/scaf`. The owner had not committed since the HL4b3 review. The stash list was
  empty and nothing was staged.
- **Pre-existing, not HL4b4:** the uncommitted HL3, HL4a, HL4b1–HL4b3, and HL4c1–HL4c3 work:
  18 modified tracked files and 33 untracked files (51 paths). Its `git diff` (tracked
  files) had SHA-256 `74d384c5e6eaae3b9fc6d7ac913b8718aca36a03ba1c535c391a037444b0b71f`.
  Every production, test, and peer hash equalled the HL4b3 record's final value
  (`command_dispatch.ml` `8abb80e0…`, `hardware_loader.ml` `bb4e8794…`, `frame_rx.ml`
  `9d927f9a…`, `asic_bundle.ml` `21a3cc86…`, checker `658ada0d…`, and every HL4a,
  `serial_phy/`, `frame_rx/`, and `command_dispatch/` test file). A tar and SHA-256 list of
  all 51 pre-existing changed paths were kept in the session scratchpad; at the end, every
  one that HL4b4 did not intentionally edit still had its starting hash
  ([Verification](#verification)).

  Starting SHA-256 of the files HL4b4 edits:

  | File | SHA-256 at start |
  | --- | --- |
  | `lib/host_link/hardware_loader.ml` | `bb4e8794e2e3011999c7451d50995fc3e9c5e4d77520de1bab56264c8ce0bc8e` |
  | `lib/host_link/frame_rx.ml` | `9d927f9af8bbddcae2b91a6616e3f4178121c81ca8064114b9c53a1ef6a572d1` |
  | `lib/host_link/command_dispatch.ml` | `8abb80e03e02e144b736925151d28600674339fc81cb09f2c8d0b82a52dea3fe` |
  | `lib/host_link/serial_phy.ml` (comment only) | `c82d32b859d6621f7e1dc0d9c43927a31075aba8013e0f45e281c8be311dbe23` |
  | `host_link_wire/wire.ml` (comments only; unmodified against `HEAD` at start) | `04e04a44dbcdc28d233946a426ea9fb38cf9dc4ee540ed3004f3e97ad8519068` |
  | `bin/asic_bundle.ml` | `21a3cc864f9f59ff16d0625f1940caaf8a82d9bf23f9ac8349e046340a741b60` |
  | `tinytapeout/scripts/check-adopted-bundle.py` | `658ada0d8eaa89b4da3df4a9fb88156a71e2484a27b20df5f02a439363a9b6a6` |
  | `docs/host_link_migration.md` | `94fba56d99a7d0adb5523bb15c77ed2df9f67c0886c2c1a66c138591c3db6a0d` |
  | `docs/verification.md` | `ea2f0f69c577506da1daf2c5a3f4430a761339d85338c3ff3295d4317bcdf6c4` |
  | `docs/p3.5-hardware-loader.md` | `abd8aa0101b34845ec5a377a793fd668fee4b70adca29d00e32963161c104964` |
  | `docs/construction-plan.md` | `60ea95530159b495b027b7593ef148f7adffe8bd7125a2999159de04cfa6f10f` |
  | `docs/README.md` | `75e786f7ae8c2f944e45d071a7483be2f99e7e8a6fba0c485eab8dc04d7302ca` |

  Unchanged and required to stay so: `loader_core.ml` `ea0a8bf4…`, `control_port.ml`
  `07d8af08…`, `p3_loader_tb.v` `40d9341f…` (blob `2ffc20f0…`), and the HL4a harness and the
  HL4c1–HL4c3 suites, including their `dune` files.

- HL4b4 diff (uncommitted, unstaged). Final SHA-256 of each non-doc file, frozen before the final
  runs (the one later edit, a formatter rewrap of one comment in `frame_tx.ml`, is noted):

  | Path | Change | SHA-256 |
  | --- | --- | --- |
  | `lib/host_link/frame_tx.ml` (new) | The transmitter | `045f6149f63cd24c97747b296632760ee06d997cb4090b5b35040348cb6be0fd` |
  | `lib/host_link/wire_crc.ml` (new) | Shared `crc8_byte` and its parameter check | `40a15744ea3c7c878306c960cd707e4cc4ee2f95dd7a6fbdf5cc7365406a8bdf` |
  | `lib/host_link/wire_layout.ml` (new) | Shared tiling check and the request-payload layout | `adaaefeef062b5469eb0c3480bddf37fb5e14ce911630e7b91caa1150b6e4ac7` |
  | `lib/host_link/hardware_loader.ml` | Composition only: six registers, their statements, `Config`, and all checks removed | `66e5e47c6c902c175328b63db1949a24a8f7dd10e7d6a774085a8cd0b0601f35` |
  | `lib/host_link/frame_rx.ml` | Uses `Wire_crc`; own `check_wire_encodings`; header comment | `01429905e24b199a601c25e7219c0af679c523befbfbca8fa29ce863c46d0fd0` |
  | `lib/host_link/command_dispatch.ml` | Uses `Wire_crc`; fault/phase mapping and own `check_wire_encodings`; header comment | `74623d6eae9aac49d68dbe551bc9ba57e036370e3c0e560ccaef8faf49ee0623` |
  | `lib/host_link/serial_phy.ml` | Header comment only | `b384a0116a7f56308603a0b6e2862963080a43a12817743e454427448d0546d7` |
  | `host_link_wire/wire.ml` | Two comments only | `09ff477c1d57825d6665e48344a44c2a338bf1ec037b5e9100e0fa314f52555a` |
  | `bin/asic_bundle.ml` | Loader inventory adds `frame_tx.ml`, `wire_crc.ml`, `wire_layout.ml` | `08fda53913007d736ddfaeb1eb571a0d57c4b477b571d590f621c91393524cd4` |
  | `tinytapeout/scripts/check-adopted-bundle.py` | Loader check requires those three inputs | `76ecaf7d70a357dca596b8a05b45a1b6da14c0c3933b0480beea285d48e8ad0f` |
  | `test/host_link/frame_tx/dune` (new) | Library `protemu_frame_tx_tests`, in `@runtest` | `0d78f7e11a359aea7850e8334234dad235ae17ed7e7f724c552db4433d8cbe0c` |
  | `test/host_link/frame_tx/frame_tx_testbench.ml` (new) | Cycle owner, drivers, sampling, checks, diagnostics | `02a56ad6b806a2357de391f733fe0c992860098d799e9516e394e47f65be10a1` |
  | `test/host_link/frame_tx/frame_tx_publication_tests.ml` (new) | 6 tests | `88f516c0eb24b7439e1ba89f1f326daa444833207ce530433e22d541c367a5bb` |
  | `test/host_link/frame_tx/frame_tx_read_tests.ml` (new) | 12 tests | `773b283fff87396ecf0ed7839823760e22171fa2d0980f8d7b81a2d49bcd302b` |
  | `test/host_link/frame_tx/frame_tx_lifecycle_tests.ml` (new) | 6 tests | `d68080213cb22304eb935835810acaaf5f79e462ef724fa27f8aa35189e7c796` |
  | `test/host_link/frame_tx/frame_tx_diagnostics_tests.ml` (new) | 5 negatives | `c148d260719134f181edd5457b47c393c65ad23df68055f63dc266067e53903e` |
  | `docs/` | This record; [host_link_migration.md](host_link_migration.md), [verification.md](verification.md), [p3.5-hardware-loader.md](p3.5-hardware-loader.md), [construction-plan.md](construction-plan.md), [README.md](README.md) | — |

  No existing test source changed, even mechanically: the new suite lives in its own
  directory. `loader_core.ml`, `control_port.ml`, and `p3_loader_tb.v` are unchanged.
  `frame_tx.ml` was `8a311576…5769` during the mutation runs and `b9c590c3…548d` during
  the forced `@loader-rtl`, full checker, and first final runs; both later versions differ
  from those only in the header comment's `Careful:` paragraph and its rewrapping, and the
  recapture after each shows byte-identical emitted RTL.

## Tool identity

opam switch `5.2.0+ox` (OCaml 5.2.0+ox), Dune 3.24.2; `hardcaml`, `ppx_hardcaml`, `core`,
`ppx_jane`, `ppx_expect`, `ppx_inline_test` `v0.18~preview.130.106+341`; `ocamlformat`
0.26.2+ox2; `hardcaml_asic` 0.1.0; host Verilator 5.020, Icarus Verilog 12.0, Yosys 0.33
(git sha1 `2584903a060`), Python 3.12.3. The loader checker's synthesis runs in
`ghcr.io/librelane/librelane:3.1.0.dev3` (the lock's `librelane_version`), image
`sha256:d109140b8f17fc54f4fca998beb8124f4949404ec52e339eebd2250854a18b5a`, whose Yosys is
0.66 (git sha1 `86f2ddebce7e98ce7cacc27e8a5c14cb53b51b51`). These are identical to HL4b3's
and served every baseline and final run.

## Pre-extraction baseline

Captured on the starting source, before any edit, with the HL4b2/HL4b3 evidence scripts
extracted mechanically from those records' appendices (their SHA-256 values are listed in
the [appendix](#appendix-evidence-scripts)):

| Baseline item | Result |
| --- | --- |
| `./scripts/with-switch.sh dune runtest test/host_link --force -j 5` | PASS, 7.8 s, freshly executed (32 HL4a, 11 Serial_phy, 26 Frame_rx, 39 Command_dispatch tests) |
| All 15 generator outputs (`capture.sh`) | List digest `ab499eb0801a5adfc2dd7c8265e1add061c489119de7793bdb95b0478d3d15a3`, HL4b3's recorded post digest; `loader.v` `07f154d9fe22b5ce2cb4b9726b397969fd10d6b3481cb031a6ffaaef99655fdd` |
| Six bundle Verilog roles | Loader `src` `0c748fed…8770`, `simulation` `f37cb851…2a70`; memory `a6c3ad27…0d95`, `8b21fa31…3762`; observable `c275808a…0cb1` (both): all HL4b3's post values. Metadata list digest `42e943a7…6702` |
| Bundle identities | observable `d4182035…5f64`, memory `0c9a836e…ec29`, loader `dc5da573…c50`: HL4b3's post values |
| Port inventories (`ports.py`) | `loader_core` 17 ports `8df49008…0b97`; both loader wrapper roles 8 ports `aff782f7…9707`; `integrated_core` 109 ports `37849295…4f12`: HL4b3's listings |
| Checker synthesis (`synth_stat.sh`) | **24 431 cells, 5 318 mapped flip-flops**; `stat` block digest (first 31 lines, up to Yosys's run-time line) `68632e9109afcb875e7435d5e23f48ca9bc9ff27543b2ac228d6ffdf95a83194`, HL4b3's recorded "after" digest |
| Mapped flip-flop inventory (`ff_bits.sh`) | 5 318 lines, SHA-256 `a0391a88…0856738`; the six transmitter registers map to 1 + 1 + 104 + 168 + 4 + 8 flip-flops (pending, active, store, shift, length, bits) |

So the baseline is exactly the accepted HL4b3 result, with no source, tool, or
configuration difference. The original unsplit **25 108 cells / 5 383 flip-flops** are kept
for the cumulative comparison.

## Extraction contract

Recorded in this file before any production logic was edited. Derived from
`lib/host_link/hardware_loader.ml` at SHA-256
`bb4e8794e2e3011999c7451d50995fc3e9c5e4d77520de1bab56264c8ce0bc8e` (HL4b3 final and
accepted), `command_dispatch.ml` `8abb80e0…`, `serial_phy.ml` `c82d32b8…`, the P3.5 record,
and the unchanged HL4a suite. Cycle *n* is the interval before edge *n*; a register
assigned at edge *n* has its new value in cycle *n* + 1. At the block boundary, *p* is a
publication cycle (`response_publish_i` high), *a* a select-assert event cycle, *f* a clock
fall event cycle, *r* a select-release event cycle, and *d* a disabled cycle.

### State ownership

Before the extraction, `Hardware_loader.I_Regs` holds exactly these six fields, all
synchronous-clear to 0 through the one shared `Reg_spec`, and all assigned in the loader's
one `compile`. After it, all six are `Frame_tx.I_Regs`, with the same names, widths, reset
values, and per-register statement order. `Hardware_loader` keeps no register.

| Register | Width | Meaning | Writers, in statement order | Read by (before) | Owner after |
| --- | ---: | --- | --- | --- | --- |
| `response_pending` | 1 | A retained response exists | T0 hold; P ← 1; R ← 0 if drained; D ← 0 | A, `serial_ready_o`, request eligibility, `busy_o` | `Frame_tx`; exported ungated as `pending_o` |
| `response_active` | 1 | An armed read is in progress | T0; A ← 1; R ← 0; D ← 0 | S, R, `serial_data_o` | `Frame_tx` |
| `response_store` | 168 (`Wire.Response.max_length` × 8) | The complete published frame, MSB-first, zero-padded | T0; P ← frame | A | `Frame_tx` |
| `response_shift` | 168 | The copy being shifted out | T0; A ← store; S ← shift ≪ 1 | S, `serial_data_o` (MSB) | `Frame_tx` |
| `response_length` | 5 | The published frame's byte count | T0; P ← length | `drained` | `Frame_tx` |
| `response_bits` | 8 | Falls taken in the current read | T0; A ← 0; S ← +1; R ← 0 if drained; D ← 0 | `drained` | `Frame_tx` |

`drained` is `response_bits == response_length × 8` (8-bit compare of the old values).

The loader's `compile` statements, in order, move verbatim:

| # | Statement | Assigns |
| --- | --- | --- |
| T0 | Hold defaults | all six |
| P | `when_ publish`: store ← frame, length ← length, pending ← 1 | store, length, pending |
| A | `when_ (select_assert & enable & pending & deselect_qualified)`: shift ← store, bits ← 0, active ← 1 | shift, bits, active |
| S | `when_ (clock_fall & active & ~drained)`: shift ← shift ≪ 1, bits ← bits + 1 | shift, bits |
| R | `when_ (select_release & active)`: active ← 0; `if_ drained` pending ← 0, bits ← 0 | active, pending, bits |
| D | `when_ ~enable` (last): pending ← 0, active ← 0, bits ← 0 | pending, active, bits |

Every condition reads registered (old) values. So a register's same-cycle priority is its
last writer that fires:

| Register | Priority, highest first |
| --- | --- |
| `response_pending` | reset clear > D > R commit > P > hold |
| `response_active` | reset > D > R > A > hold |
| `response_store`, `response_length` | reset > P > hold (disable does not write them) |
| `response_shift` | reset > S > A > hold |
| `response_bits` | reset > D > R commit > S > A > hold |

### Ownership of everything else

| Item | Owner after | Why |
| --- | --- | --- |
| Capture of a published frame and length; pending; arming; restart from byte zero; shifting and bit count; drained detection; replay/abandon; commit; `serial_data_o`, `serial_ready_o`; own reset/disable | `Frame_tx` | The transmitter contract, moved verbatim |
| Response construction (including CRC), selection, publication; offers and waits | `Command_dispatch`, unchanged | HL4b3 |
| Synchronization, events, deselect qualification | `Serial_phy`, unchanged | HL4b1 |
| Receive state and retained request fields | `Frame_rx`, unchanged | HL4b2 |
| Request eligibility `~dispatch.busy_o & ~tx.pending_o` | `Hardware_loader` | Composition of dispatcher and transmitter state |
| `busy_o = rx.active_o \| dispatch.busy_o \| tx.pending_o` | `Hardware_loader` | Composition |
| Wiring of the four blocks and the `Control_port` records | `Hardware_loader` | Composition |

Eligibility reads **retained `response_pending`**, not the enable-gated `serial_ready_o`.
The two differ exactly in a disabled cycle (`serial_ready_o` low, `pending_o` still high
until the disable edge). `Frame_tx` therefore exports both.

### Interface

`Frame_tx.I`: `clock_i`, `reset_i` (synchronous, active high), `enable_i`;
from `Serial_phy`: `select_assert_i`, `select_release_i`, `clock_fall_i`,
`deselect_qualified_i`; from `Command_dispatch`: `response_publish_i`,
`response_frame_i` (168), `response_length_i` (5).

`Frame_tx.O`: `serial_data_o`, `serial_ready_o`, `pending_o`.

| Output | Definition (unchanged) | Timing |
| --- | --- | --- |
| `serial_data_o` | `enable & active & ~drained ? msb shift : 0` | Registers plus combinational `enable_i` gating |
| `serial_ready_o` | `enable & pending` | Registers plus combinational `enable_i` gating |
| `pending_o` | `pending` | Registered only |

No output depends combinationally on an event or publication input. The publication is
the existing one-cycle combinational handoff, captured by P at edge *p*: no ready, queue,
acknowledgment, or pipeline register is added.

Composition order: `Frame_rx` is created before `Command_dispatch` and `Frame_tx`, whose
outputs its eligibility needs, so `Hardware_loader` joins `pending_o` to the eligibility
expression with a second 1-bit `Signal.wire`, as it already does for `busy_o`. Both are
register expressions; no combinational loop results. The wire is one emitted net with no
logic.

### Temporal contract (preserved)

| Behavior | Cycle at the `Frame_tx` boundary |
| --- | --- |
| Capture | P at edge *p*; `pending_o` and `serial_ready_o` high from *p* + 1 |
| Arming | A at edge *a* only if `pending_o` was already high in *a*, `deselect_qualified_i` is high in *a*, and enable is high. A publication in *a* itself does not arm: A reads the old pending |
| First bit | `serial_data_o` = frame bit 167 (byte 0's MSB) from *a* + 1, before any fall |
| Shift | Each fall event with the read active and not drained advances one bit at edge *f*; the next bit is presented from *f* + 1. Nothing else advances it; selected pauses hold it |
| Drained | After 8 × length falls; `serial_data_o` is low from then on |
| Release without the final fall | Edge *r*: active ← 0, pending stays, bits keep their count (unobservable). The next armed selection reloads the shifter from the store and restarts at byte zero |
| Release after the final fall (commit) | Edge *r*: active ← 0, pending ← 0, bits ← 0. `pending_o` low from *r* + 1 (the HL4a *d* + 3 observation, with *r* = *d* + 2) |
| Disable | Outputs gated low in *d* itself; pending, active, bits cleared at edge *d*; `pending_o` high in *d* if it was. Store, shift, and length keep their values. They cannot be observed again: re-arming needs pending, which only P sets, and P rewrites store and length |
| Reset | All six cleared at the reset edge, including a coincident publication; `serial_ready_o` and `pending_o` still show the old pending in the first reset cycle |

### Simultaneous events

Priorities are per register, as in the table above; the statement order is kept exactly,
not reduced to a mutually exclusive subset.

| Coincidence | Result | Presented by the composed loader? |
| --- | --- | --- |
| P with A, pending low | No arm (A reads old pending); frame stored and pending from *p* + 1. The selection stays unarmed through its release | Yes: an early selection's assert event in the publication cycle |
| P with A, pending high | Arms with the **old** store; the new frame is stored for the next read. *Amended after HL4c4:* the length is not copied into the read, so this read drains at the **new** length, and a release after that commits, consuming the new frame unread | No: nothing publishes while a response is retained |
| P with S (read active) | The read continues from the shifter; the store takes the new frame. *Amended after HL4c4:* the read also drains at the new length; a release before that retains, and the replay presents the new frame | No |
| P with R commit | Pending ends low (R wins); store and length take the new frame, unreachable | No |
| P with D | Store and length written; pending low (D wins) | Yes: HL4b3's ungated publication in a disabled cycle |
| P with reset | Nothing stored; every register cleared | Yes |
| S with R, final fall | S advances to drained, R reads the old (not drained) count: no commit; retained | Only outside the P3.5 envelope (last fall to `LSEL_N` high ≥ 4 cycles) |
| S with R, already drained | S does not fire; R commits | Yes |
| S with D | Bits and active cleared; shifter shifted (unobservable) | Yes |
| R with D | Pending cleared whether or not drained | Yes |
| A with D | A needs enable, so only D acts | Yes |
| A with R, A while active | Not presentable by `Serial_phy` (assert and release alternate) | No; not driven |

The two amendments above were added after the focused robustness test exposed them; the
rows as first written omitted that `response_length` is shared between the store and the
read. The code was moved verbatim either way, and neither coincidence is reachable in the
composed loader.

### Legal publications

`Command_dispatch` publishes only complete frames, MSB-first from bit 167 and zero-padded,
with lengths 8 (every empty-payload response, including framing errors), 10 (READ/VERIFY
word), 20 (STATUS), and 21 (INFO). Its frame and length outputs are zero when it does not
publish. It publishes at most once per request and never while a response is retained.
`Frame_tx` does not validate any of this and this slice adds no validation. Lengths 0 and
22 to 31, nonzero padding, nonzero frame/length inputs without the strobe, and publication
while pending are out-of-contract robustness probes only.

### Shared CRC and elaboration checks

Kept separate from the state move and applied first, so that its emitted RTL can be shown
byte-identical on its own:

- `crc8_byte` moves verbatim from `Frame_rx` to a new `Wire_crc` module under
  `lib/host_link/`, taking its parameters from `Wire.Crc`. `Frame_rx` and
  `Command_dispatch.crc8` call `Wire_crc.crc8_byte`; neither references the other. The
  software `Wire.Crc` is untouched.
- `Hardware_loader.check_wire_encodings` is split to its owners and run from each owner's
  own elaboration:

  | Check | Owner after |
  | --- | --- |
  | Fault kinds and phases equal the execution unit's (`execution_fault`, `execution_phase`) | `Command_dispatch` |
  | STATUS flags in bit order; fault and phase fit their STATUS bytes | `Command_dispatch` |
  | Response header, INFO, and STATUS layouts; response payload follows its header | `Command_dispatch` |
  | Response length fits 5 bits | `Command_dispatch` (its `response_length_o`) and `Frame_tx` (its register) |
  | Response bit count fits 8 bits | `Frame_tx` |
  | Request header layout; request payload follows its header | `Frame_rx` |
  | Request payload layout (two u16 fields tiling four bytes) | Both `Frame_rx` (positional payload register) and `Command_dispatch` (field selects), through one shared definition |
  | CRC parameters supported by the shift-register implementation | `Wire_crc`, at every use |
  | **New:** the CRC initial value is zero | `Frame_rx` |

  The one new check closes a gap the inventory found: `Frame_rx` clears its CRC
  accumulator to literal zero at every start, where `Command_dispatch.crc8` uses
  `Wire.Crc.initial`. Nothing checked that they agree. It is plain OCaml and creates no
  logic.

  The generic layout-tiling helper, used by two owners, moves to a small `Wire_layout`
  module with the one shared request-payload check. The publication widths between
  `Command_dispatch` and `Frame_tx` are already enforced by Hardcaml's
  `Always.(<--)` width check, so no composition-level check remains in `Hardware_loader`.

## Implementation, in two separately reviewed stages

### Stage 1: shared CRC and standalone elaboration checks (no state moved)

- New [`wire_crc.ml`](../lib/host_link/wire_crc.ml): `crc8_byte` moved verbatim from
  `Frame_rx` (the formatter removed the redundant parentheses around `sll crc ~by:1`;
  function application binds tighter than `^:.`, so the expression is the same). It takes
  `Wire.Crc.polynomial` and checks `Wire.Crc.width`, `reflected`, and `final_xor` every time
  it is called, which is during elaboration of whichever block uses it. The software
  `Wire.Crc` is untouched and not used by it. It is not a general CRC generator.
- New [`wire_layout.ml`](../lib/host_link/wire_layout.ml): the loader's `check_layout`,
  now `Wire_layout.check ~owner`, and `check_request_payload ~owner`, the one layout two
  blocks rely on. Plain OCaml, no Hardcaml dependency.
- `Frame_rx`: calls `Wire_crc.crc8_byte`; gains `check_wire_encodings` (request header,
  payload position, shared request payload, and the new CRC-start check), called first in
  `create`. No other code change.
- `Command_dispatch`: `crc8` folds `Wire_crc.crc8_byte`; gains `execution_fault`,
  `execution_phase`, and `check_wire_encodings` (fault/phase mapping, STATUS flag order and
  byte widths, 5-bit `response_length_o`, shared request payload, response header, INFO,
  STATUS), called first in `create`. No other code change.
- `Hardware_loader`: kept only the two store-sizing checks at this stage, since it still
  owned the store.
- `wire.ml`: two comments that named `Hardware_loader` as the hardware user and fault
  checker now name the host-link hardware and `Command_dispatch`. Comments only; the
  library still depends only on `core` and `ppx_jane`.
- Loader bundle inventory and checker: `lib/host_link/wire_crc.ml` and
  `lib/host_link/wire_layout.ml` added.

**Stage 1 result:** all 15 generator outputs, all six bundle Verilog roles, and all bundle
metadata are **byte-identical** to the baseline (`gen.sha256`, `bundle-verilog.sha256`, and
`bundle-meta.sha256` compare equal). Only the bundle identities moved (observable
`4f275fec…2c77`, memory `585281cd…c708`, loader `2db6d9ee…57b2`), because `asic_bundle.ml`
changed and the loader gained two inputs (37 → 39) and five changed inputs. A fresh
`dune runtest test/host_link test/host_link_wire --force -j 5` passed. Stage 1 therefore
changed no emitted logic, and synthesis input is byte-identical, so it has no synthesis
effect. Stage 1 source SHA-256: `frame_rx.ml` `01429905…0fd0`, `command_dispatch.ml`
`74623d6e…0623`, `hardware_loader.ml` `3ede2ccc…318b`, `wire_crc.ml` `40a15744…8bdf`,
`wire_layout.ml` `adaaefee…4ac7`, `wire.ml` `09ff477c…555a` (final).

### Stage 2: `Frame_tx` extraction

- New [`frame_tx.ml`](../lib/host_link/frame_tx.ml): the six registers, `response_drained`,
  and statements T0, P, A, S, R, D, moved verbatim (the loader's `set_response` helper is
  inlined as P's three assignments), plus the loader's two sizing checks, now
  `Frame_tx.check_wire_encodings`, and `Config` (response sizing). Registered under
  `Scope.sub_scope scope "frame_tx"` with the `reg_` prefix, so the registers keep their
  names below the new scope level.
- `Hardware_loader`: no `I_Regs`, no `Always`, no `Wire`, no `Config`, no checks. It
  composes `Serial_phy`, `Frame_rx`, `Command_dispatch`, and `Frame_tx`, joins
  `dispatch.busy_o` and `tx.pending_o` into `Frame_rx`'s eligibility through two 1-bit
  forward wires, forms `busy_o`, and passes the `Control_port` records and the two serial
  outputs through. Its public `I`/`O` did not change.
- `Serial_phy`: its header comment no longer says the loader owns arming and commit.
  Comment only.
- Loader bundle inventory and checker: `lib/host_link/frame_tx.ml` added.

## What moved and `Hardware_loader`'s final responsibilities

| | Before | After |
| --- | --- | --- |
| `response_pending`, `response_active`, `response_store`, `response_shift`, `response_length`, `response_bits` | `Hardware_loader.I_Regs` | `Frame_tx.I_Regs`: same names, widths, reset values, and per-register statement order |
| Publication capture P, arming A, shift S, release/commit R, disable D; `response_drained`; `serial_data_o`, `serial_ready_o` definitions | Loader `compile` and output record | `Frame_tx`, textually unchanged apart from `i.` port references |
| Store sizing checks (5-bit length, 8-bit bit counter) | `Hardware_loader.check_wire_encodings` | `Frame_tx.check_wire_encodings` |
| Fault/phase mapping, STATUS, response, INFO checks | `Hardware_loader` | `Command_dispatch` |
| Request header and payload checks | `Hardware_loader` | `Frame_rx` (payload check shared through `Wire_layout`, also run by `Command_dispatch`) |
| CRC parameter check | `Hardware_loader` | `Wire_crc`, at every use |
| `crc8_byte` | `Frame_rx` | `Wire_crc` |
| Request eligibility, `busy_o`, block wiring, `Control_port` pass-through | `Hardware_loader` | `Hardware_loader` (reads `tx.pending_o` instead of its own register) |

`Hardware_loader` now holds **no register, no `compile`, and no parsing, dispatch, or
transmit logic**; a review of its final source found only the four `create` calls, the
two forward wires, the eligibility expression `~dispatch_busy & ~response_pending`, and
`busy_o = rx.active_o | dispatch.busy_o | tx.pending_o`.

One composition fact the review confirmed: because `Frame_rx` starts a request only in an
enabled cycle, using the enable-gated `serial_ready_o` for eligibility would be
functionally equivalent inside the composed loader. It would still differ at `busy_o`,
which the HL4a harness observes, and the contract keeps eligibility on the retained state,
so the retained `pending_o` is what the loader uses.

## `Frame_tx` interface, state, and temporal contract

As recorded in the [extraction contract](#extraction-contract) and implemented without
change, apart from the two coincidence rows amended there (a description correction, not a
design change). In summary:

- **Inputs:** `clock_i`, `reset_i` (synchronous), `enable_i`; `Serial_phy`'s one-cycle
  `select_assert_i`, `select_release_i`, `clock_fall_i`, and `deselect_qualified_i`;
  `Command_dispatch`'s one-cycle `response_publish_i` with `response_frame_i` (168) and
  `response_length_i` (5).
- **Outputs:** `serial_data_o` and `serial_ready_o`, functions of the registers gated
  combinationally by `enable_i`; `pending_o`, the retained state, ungated.
- **Timing:** capture at the publication edge, pending from the next cycle; arming at a
  qualified assert that finds pending already high (never a same-cycle publication); first
  bit from the cycle after the assert; one bit per fall edge; drained after 8 × length
  falls; commit only at a release after the final fall, `pending_o` low from the next cycle
  (HL4a's *d* + 3); any other release retains, and the next armed read restarts at byte
  zero.
- **Priorities:** per register, in statement order P, A, S, R, D; commit and disable
  override a coincident publication's `response_pending`; reset clears everything,
  including a coincident publication; disable leaves store, shifter, and length, which
  nothing can read again.

## Shared CRC and elaboration-check ownership

Final ownership of every check that was in `Hardware_loader.check_wire_encodings`, all
still present:

| Check | Owner | Runs when |
| --- | --- | --- |
| Every fault kind and phase equals the execution unit's | `Command_dispatch.check_wire_encodings` | `Command_dispatch.create` |
| STATUS flags in bit order; fault and phase fit a byte | `Command_dispatch` | same |
| Response header layout; response payload follows it; INFO layout; STATUS layout | `Command_dispatch` | same |
| Response length fits 5 bits | `Command_dispatch` (output) and `Frame_tx` (register) | each `create` |
| Response bit count fits 8 bits | `Frame_tx.check_wire_encodings` | `Frame_tx.create` |
| Request header layout; request payload follows it | `Frame_rx.check_wire_encodings` | `Frame_rx.create` |
| Request payload layout | `Wire_layout.check_request_payload`, run by `Frame_rx` and `Command_dispatch` | both `create`s |
| CRC width 8, no reflection, no final XOR | `Wire_crc.check_parameters` | every `crc8_byte` call (elaboration of `Frame_rx` and `Command_dispatch`) |
| **New:** CRC initial value 0 | `Frame_rx` | `Frame_rx.create` |
| Existing, unchanged: INFO and STATUS payload list lengths, u16 constants | `Command_dispatch` (`check_payload`, `high_byte`) | `Command_dispatch.create` |

No composition-level wire check remains in `Hardware_loader`. The one composition-level
assumption, that the dispatcher's published frame and length are as wide as the
transmitter's store and length, is enforced by Hardcaml's `Always.(<--)` width check
(negative N8 below). There is no dependency cycle: `Wire_crc` and `Wire_layout` depend only
on `Wire` (and Hardcaml for `Wire_crc`); neither block depends on the other's internals;
`host_link_wire/` still depends only on `core` and `ppx_jane`.

**Standalone enforcement.** Each negative temporarily changed one constant, ran all five
`test/host_link` suites (`dune build -j 5 @test/host_link/runtest`), and restored the file by
copy with a SHA-256 check (`check_negative.py`, `run_check_negative.sh`). Counts are failing
tests per suite; each focused suite elaborates only its own block.

| Negative | Serial_phy | Frame_rx | Command_dispatch | Frame_tx | HL4a | Message |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| N1. `Wire.Crc.final_xor` 0 → 1 | 0 | 25 | 38 | 0 | 30 | `Wire_crc: CRC parameters are not supported by crc8_byte` (both CRC users) |
| N2. `Wire.Crc.initial` 0 → 1 | 0 | 25 | 1 | 0 | 30 | `Frame_rx: request CRC does not start from zero`. The dispatcher uses `initial` consistently, so needs no check; its one failure is the in-test independent CRC byte (functional detection) |
| N3. Request `Offset.tag` 2 → 3 | 0 | 25 | 0 | 0 | 30 | `Frame_rx: request header field at 3, expected 2` |
| N4. Request `Payload_offset.word` 2 → 1 | 0 | 25 | 38 | 0 | 30 | `Frame_rx: …` and `Command_dispatch: request payload field at 1, expected 2` |
| N5. Response `Offset.result` 4 → 5 | 0 | 0 | 38 | 0 | 30 | `Command_dispatch: response header field at 5, expected 4` |
| N6. `Fault_kind` `Mechanism_protocol` 9 → 10 | 0 | 0 | 38 | 0 | 30 | `Command_dispatch: fault kind 10 differs from the execution unit` |
| N7. `Info.length` 13 → 25 (33-byte responses) | 0 | 0 | 38 | 28 | 30 | `Command_dispatch: response length output too narrow`; `Frame_tx: response length register too narrow` |
| N8. `Frame_tx.Config.max_response_bytes` + 1 | 0 | 0 | 0 | 28 | 30 | Composed: Hardcaml's `attempt to assign expression to [Always.variable] of different width`. Standalone `Frame_tx` elaborates; its suite fails only on the testbench's own 21-byte port assertion |

The "failing" counts include suites' diagnostics negatives only where they elaborate the
block. After the eight runs, `wire.ml` and `frame_tx.ml` had their pre-run hashes.

## Focused tests (HL4c4)

[`test/host_link/frame_tx/`](../test/host_link/frame_tx/frame_tx_testbench.ml) (library
`protemu_frame_tx_tests`, in ordinary `@runtest`, 29 tests, about 3 s) follows the
per-module convention. The testbench owns the only simulator loop (`cycle`), pre-/post-edge
sampling, and finite waits (`wait_for`, default budget 100 cycles). It raises `Tx_failure`
with scenario, cycle, phase, what was checked, expected and actual values, and a transcript
of recent cycles' inputs and outputs. Every cycle it also checks that the post-edge sample
equals the next pre-edge sample whenever enable is unchanged (and `pending_o` always): no
output depends on an event or publication input.

Stimulus is PHY-level events (`select`, `deselect`, `fall`, with qualification presented
only in the assert cycle) and publications (`publish`: a complete frame, zero-padded, with
the strobe for one cycle; frame and length return to zero after, as the dispatcher drives
them). Legal frames are written from the P3.5 layouts (magic `5a`, version `10`, tag,
command, result, length, payload), with `Wire.Crc.compute` supplying the CRC byte as
stimulus only. Expected bits come from the test's own transcription of the wire order
(bytes in order, MSB first); nothing is computed from `Frame_tx`. Every read helper checks
that the assert cycle presents nothing, the first bit is presented from the next cycle
before any fall, each bit is unchanged for its whole interval and changes only at its fall's
edge, the output is low after the final fall, and `pending_o` and `serial_ready_o` fall
exactly in the cycle after a committing release.

| Test | Covers |
| --- | --- |
| publication: "each legal response length is captured ..." | 8, 10, 20, 21 bytes: pending/ready from *p* + 1, not in *p*; full MSB-first read; commit edge; quiet 200 cycles after |
| publication: "a retained frame is unchanged by time and by other inputs ..." | 5 000 idle cycles, an unqualified selection with 30 falls, qualification held 50 cycles without a selection, deselected falls; then a full read |
| publication: "the store and the shifted copy are independent ..." | Partial reads of 1, 8, 57, and 167 bits of INFO, then a full read from byte zero |
| publication: "consecutive publications and commits ..." | Eight transactions, each length twice, each delivering its own frame |
| publication: "robustness: frame and length inputs without the strobe ..." | Labelled: nonzero unstrobed inputs while idle and while retained are ignored |
| publication: "robustness: out-of-contract lengths and nonzero padding" | Labelled: `ff` padding never presented; length 0 commits with no fall; length 31 presents the store then zeros, retains after 247 falls, commits after 248 |
| read: "an unqualified selection is not armed ..." | 80 falls and a release under an unqualified selection change nothing |
| read: "a publication in the select-assert cycle does not arm ...; one a cycle earlier does" | The same-cycle coincidence (reachable in the loader) is not armed and cannot shift or consume; published one cycle before a qualified assert, it is armed |
| read: "an early selection before the publication cannot shift or consume it" | Selection, publication during it, 200 falls, release: retained; the next read is complete |
| read: "each fall advances exactly one bit, at its edge, at any spacing" | Fall spacings of 2, 8, 22, and an irregular 2–17 pattern |
| read: "falls outside an armed read are ignored ..." | 50 deselected falls, then a full read from bit zero |
| read: "a selected pause holds the presented bit indefinitely" | Pauses of 10 000, 5 000, and 7 000 cycles inside and between bytes |
| read: "the final bit, the drained boundary, and the output after it" | Last bit held to the final fall's edge, low after; 20 extra falls change nothing; the release commits |
| read: "a release before the final fall retains ...; the next read restarts at byte zero" | Empty and INFO, after 0, 1, 5, 8, and all-but-the-final-fall bits; retained 200 cycles; full replay |
| read: "the final bit presented without the final fall is a replay ..." | P3.5's replay sequence: last bit held until the release, then retained, then replayed and committed |
| read: "a committed response is consumed exactly once ..." | Three later qualified selections with 90 falls each and 1 000 cycles: nothing presented; next publication read in full |
| read: "repeated replays leave the retained frame unchanged" | Seven partial reads of varied length, then a full read |
| read: "robustness: frame content is not interpreted; a first bit of one ..." | Labelled: a pattern frame starting `80`, exercising every bit position, first bit from *a* + 1 |
| lifecycle: "reset and disable at each point discard the response; a fresh one follows" | Reset and disable × pending, armed, partial (13 bits), drained: outputs in the cancelling cycle (reset: unchanged; disable: pins low, `pending_o` high), then quiet despite further falls, releases, and a new qualified read; a fresh response after |
| lifecycle: "a publication in a reset or disabled cycle leaves nothing to read" | Both reachable in the loader; nothing pending, and a qualified read presents nothing; fresh response after |
| lifecycle: "disable coinciding with an assert, a fall, or a release ..." | Disable with a qualified assert (not armed), a fall, a partial release, and a committing release |
| lifecycle: "a release coinciding with a fall after the read is drained commits" | Extra clocking past the frame's end |
| lifecycle: "robustness: a final fall coinciding with the release does not commit" | Labelled (outside the P3.5 envelope): retained, then replayed |
| lifecycle: "robustness: a publication while a response is retained" | Labelled: arming-cycle publication reads the old frame to the new length and commits it; publication during a read then an early release replays the new frame; publication during a read then read on drains at the new length; publication with a committing release leaves nothing |
| Diagnostics (5) | A wrong second byte prints the full report (expect test, 4-cycle transcript); a first bit expected in the assert cycle, a commit expected one cycle early, and a replay expected to continue from byte one each raise; a 25-cycle wait stops exactly at its budget |

The suite exercises `Frame_tx`'s boundary alone. It is synchronous digital evidence only:
not the PHY's synchronizers, not asynchronous phase, and not the composed loader, which the
unchanged HL4a harness and the independent peer cover.

### Sensitivity

Temporary production mutations to `lib/host_link/frame_tx.ml`, each applied by exact
asserted substitutions (`mutate.py`), run with
`./scripts/with-switch.sh dune build -j 5 @test/host_link/runtest` (all five suites), and
restored by copy (`run_mutation.sh`). After each restore the SHA-256 was again
`8a311576…5769` (the source at that point; the later final hash differs by one comment
paragraph only). Counts are failing tests per suite (`tally5.sh`).

| Mutation | Frame_tx suite | HL4a | Others |
| --- | ---: | ---: | --- |
| T1. **Arming** sees a same-cycle publication as pending | 1 (publication in the assert cycle) | **0** | 0 |
| T2. **Arming** ignores qualification | 2 (unqualified selection; retention) | 2 | 0 |
| T3. **Replay** broken: any release commits | 8 (every replay test, the coincident-fall probe, store/shift independence) | 4 | 0 |
| T4. **Final-fall commit** broken: drained one fall early | 16 | 19 | 0 |
| T5. **Event priority:** publication after release and disable, so it wins for pending | 2 (publication in reset/disabled cycles; retained-publication probe) | 1 | 0 |
| T6. Disable does not clear pending | 3 | 2 | 0 |
| T7. Arming does not restart the bit count | 7 | 4 | 0 |
| T8. Arming reloads the shifter from the publication input, not the store | 25 | 28 | 0 |
| T9. `serial_ready_o` not gated by enable | 2 | 1 | 0 |

T1 is detected only by this suite: in the composed loader it needs a qualified assert in
the exact publication cycle, which no HL4a scenario lands on. T5 is the formal
non-vacuity mutant below.

## Verification

Every Dune command used `-j 5`, and heavy jobs (builds, tests, generation, synthesis,
proofs, checkers, and mutation runs) ran one after another. Proofs ran in the background
with no other tool command started until they finished. `@loader-rtl`'s rules and the
checker were re-inspected first: they run Verilator, Yosys, Docker, and peer binaries and
make no nested Dune call; the checker uses the prebuilt `_build/default/bin/asic_bundle.exe`,
built with `-j 5` before each checker run. `capture.sh` calls Dune only with `-j 5`.

| Check | Result |
| --- | --- |
| Baseline, before any edit | See [Pre-extraction baseline](#pre-extraction-baseline) |
| Stage 1: `dune runtest test/host_link test/host_link_wire --force -j 5` and capture | PASS; emitted RTL byte-identical |
| `./scripts/with-switch.sh dune runtest test/host_link --force -j 5` | PASS, freshly executed on the final source, 15 s: 32 HL4a, 11 Serial_phy, 26 Frame_rx, 39 Command_dispatch, and 29 Frame_tx tests |
| `./scripts/with-switch.sh dune runtest test/host_link_wire --force -j 5` | PASS (the inline runner executed; `--display short` shows it) |
| `./scripts/with-switch.sh dune build @install @lint -j 5` | PASS, and again on the final source |
| `./scripts/with-switch.sh dune build @runtest -j 5` | PASS, no output, 29 s; again on the final source. It includes the core-engine, host-simulator, and host suites, whose library changed |
| `./scripts/with-switch.sh dune build @loader-rtl --force -j 5` | PASS, 7 min 46 s, all three peer tiers freshly executed (reusable core, behavioral wrapper, production synthesis wrapper). Each printed `PASS p3.5 serial loader repair: timing, overrun rejection, replay/commit, status, recovery, production paths; 3/3 sensitivity phases=10, excluded 1/1 failures=10` |
| `./scripts/with-switch.sh dune build @rtl -j 5` | PASS, after the forced loader run; other benches reused earlier results, their generated inputs byte-identical |
| `check-adopted-bundle.py --kind observable/memory/loader --metadata-only`, run separately | PASS, PASS, PASS; loader again on the final source |
| Checker assertion negative | With `frame_tx.ml` removed from the loader inventory, the loader metadata check failed on `assert "lib/host_link/frame_tx.ml" in source_paths`; restored (`08fda539…24cd4`), rebuilt, PASS |
| Full loader checker `check-adopted-bundle.py --kind loader` | PASS, 5 min 4 s: repeatable bundle and metadata, conflicts, both wrapper roles against the peer, lint, and synthesis in the pinned image |
| Standalone elaboration checks | Negatives N1–N8 ([above](#shared-crc-and-elaboration-check-ownership)) |
| Formatting: `dune build -j 5 @lib/host_link/fmt @host_link_wire/fmt @test/host_link/fmt`, and `@bin/fmt` | PASS. Changed files were formatted with `dune promote <file>` (comment rewrapping, one parenthesization in `wire_crc.ml`, and the new test files); the repository `@fmt` backlog was not swept |
| `git diff --check`; tab/trailing-whitespace scan of the new files | PASS |
| Final capture after the last source edit | All 15 generator outputs, all 6 bundle Verilog files, and bundle metadata identical to the analysed and proven post RTL |
| `host_link_wire/` Hardcaml-free | Its `dune` lists `core` only (with `ppx_jane`); `ocamlobjinfo` of `protemu_host_link_wire.cma` imports no Hardcaml module |
| Block dependencies | `Command_dispatch`, `Frame_tx`, `Wire_crc`, and `Wire_layout` reference no `Frame_rx` item; only `Loader_core` references `Hardware_loader` |
| Pre-existing files | The 40 of 51 not intentionally edited keep their starting SHA-256, including every HL4a, HL4c1, HL4c2, and HL4c3 test file and `dune` |
| `tinytapeout/test/p3_loader_tb.v` | Unchanged: no diff against `HEAD` (blob `2ffc20f0…`), SHA-256 `40d9341f…c9c9` |
| `git diff --cached`; `HEAD`; stash | Empty, nothing staged; `HEAD` still `89a3fe8`; stash list empty |

Evidence tiers stay separate. Focused and HL4a Cyclesim results are synchronous digital
evidence; RAM effects, the verified-image lifecycle, real core refusal and recovery, and
asynchronous phase sweeps remain the independent peer's (three tiers above) and the HL3
core suites'.

## RTL and port comparison

`capture.sh` (HL4b2's, unchanged) ran the same generation commands with identical options
before and after, and emitted all three bundles.

**Generator outputs.** 14 of 15 are byte-identical. Pre list digest `ab499eb0…d15a3`
(HL4b3's post); post list digest
`4caf33d9e8f78c5472fe570357e564a69b211b4da3cb9b361c690ff56b087d26`. Only `loader.v` differs:
`07f154d9fe22b5ce2cb4b9726b397969fd10d6b3481cb031a6ffaaef99655fdd` →
`2bf67bdc0e741e3abf1563d07f2f6117d66e02f2db78d0d3ddeff2717bc00bc9`.

**Bundle Verilog.** 4 of 6 are byte-identical (memory and observable, both roles).
`info.yaml`, `constraints/top.sdc`, and `src/config.json` are identical for all three
bundles (list digest `42e943a7…6702` before and after).

| Loader bundle file | Pre SHA-256 | Post SHA-256 |
| --- | --- | --- |
| `src/tt_um_leemperor_hardcaml_protemu_loader.v` | `0c748fed19afa11026dff603d8d85382aa279a34decd81418c53dcf81fa38770` | `aafcfdba610ce04d11015c6963acbf21bfa3721ee4643371b49f64d735f1168a` |
| `simulation/tt_um_leemperor_hardcaml_protemu_loader.v` | `f37cb851b7dc582d358cd8436bbf185690a8bbd3889eedce326c4bb9142b4e5a` | `b28f20430ce5d97f692efc61fb65a22b7c415342cd3f20736760363572648a70` |

**External ports.** `ports.py` inventories are identical before and after: `loader_core` 17
ports (`8df49008…0b97`), both loader wrapper roles 8 ports (`aff782f7…9707`), and
`integrated_core` 109 ports (`37849295…4f12`): names, directions, widths, and order.
`Frame_tx` is flattened and adds no module or port.

**State.** After the register rename below, every `reg` declaration named `…reg_…` or
`signal_reg_…` (156 by this count, which is not the same pattern HL4b3 used for its 163) is
identical in name and width before and after, and both files have 157 clocked blocks.

**Every difference in the three changed files**, classified by `classify.py` (HL4b3's, with
the scope level under test changed to `frame_tx`; same classes in `loader.v` and both
wrapper roles):

1. The 6 transmitter registers are renamed `loader$reg_response_*` →
   `loader$frame_tx$reg_response_*`: the `Scope.sub_scope` level.
2. One new 1-bit wire, `signal_wire_29 = loader$frame_tx$reg_response_pending` in
   `loader.v`: the forward wire joining `Frame_tx.pending_o` to eligibility.
3. The eligibility inverter reads that wire instead of the register:
   `signal_not_31 = ~signal_wire_29` (was `~loader$reg_response_pending`), still feeding
   the same `signal_and_343` with the same other operand.
4. Anonymous `signal_<op>_<n>` renumbering where creation order changed (1 966 differing
   lines in `loader.v` after the rename; most anonymous numbers, including those around the
   eligibility AND, are unchanged).

Declarations go 8 377 → 8 378 (+1 wire), assignment shapes 8 171 → 8 172; no other kind
changes count. There is no logic restructuring: the transmitter's statements, muxes, and
output expressions are emitted with the same shapes. `loader.v` grows 20 515 → 20 517
lines; the wrapper roles 24 332 → 24 334 and 20 798 → 20 800.

## Formal equivalence

Host Yosys 0.33, HL4b2's scripts unchanged ([appendix](#appendix-evidence-scripts)).

- **Emitted `loader_core`.** Gold: pre `loader.v`
  (`07f154d9fe22b5ce2cb4b9726b397969fd10d6b3481cb031a6ffaaef99655fdd`, the accepted HL4b3
  implementation). Gate: post `loader.v` with
  `sed 's/loader\$frame_tx\$reg_/loader$reg_/g'` (result
  `cfd9bbac53111119425544c3598218d6e925e64ca30949e40cade1959266b4ec`); the rename only
  restores register names. `proc -norom`; `rename -hide w:signal_* w:signal_reg_* %d`
  hides renumbered anonymous nets and keeps anonymous registers paired by name. No
  assumption or constraint is added; the reset is synchronous in `loader_core`.
  **Result: 1 505 of 1 505 `$equiv` cells proven** (169 groups), 4 min 44 s, no unproven
  point. Matched by name: every port; all 31 loader registers, including all six moved
  ones with all 168 bits of both `response_store` and `response_shift`; the 95 core
  registers; the 30 anonymous registers; and the three `Command_dispatch` publication
  wires (168 + 5 + 1 bits). Those wires existed only in HL4b3's gate, so they were not
  matched then; now both sides have them, which accounts exactly for 1 505 − 1 331 = 174.
- **Non-vacuity.** The same script without `-assert`, against a `loader.v` generated from
  the T5 priority mutant (publication after release and disable; `c51cc6e9…9d75`, renamed
  `ab27dc6c…f109`), leaves **exactly 1 cell unproven: `loader$reg_response_pending`**, the
  one register whose priority changed; the other 1 504 prove (4 min 11 s). The mutant was
  generated with `dune exec -j 5 bin/generate_core.exe -- loader`, and the source was
  restored and hash-checked (`8a311576…5769`) before anything else ran.
- **Loader wrapper, production synthesis source role, untransformed.** Gold: pre `src/tt_um_leemperor_hardcaml_protemu_loader.v`
  (`0c748fed…8770`); gate: post, renamed the same way (`46625b83…d663`). **5 597 of 5 599
  cells proven** (7 min 15 s). The 2 unproven are the wrapper's own 2-bit reset
  synchronizer `signal_reg_288` (asynchronous preset to `2'b11` from `~rst_n`), which the
  induction flow does not model. It is outside the loader and textually identical in both
  files apart from anonymous numbers (clock wire `195` → `196`, data wire `196` → `197`;
  the preset inverter is `signal_not_229` in both), the same result as HL4b2 and HL4b3.
  5 599 − 5 425 = 174, the publication wires again.
- **Same wrapper with `async2sync`** after `proc` on both sides. **5 599 of 5 599 proven** (17 min 23 s). This is a
  proof under that transformed reset model only, not unrestricted asynchronous reset
  assertion/release or physical reset equivalence; the untransformed result and its two
  unproven reset bits stand beside it.

These prove the emitted RTL, not the post-synthesis netlist. No separate netlist
equivalence proof of the mapped cells was run.

### Proof chain back to the unsplit loader

Each HL4b slice proved its emitted `loader_core` against the immediately preceding one with
the same flow. The identities connect: each gold is the previous slice's post `loader.v`.

| Slice | Gold `loader.v` | Gate `loader.v` (before its rename) | Result |
| --- | --- | --- | --- |
| HL4b1 | `dfb870cf…c035`: unsplit, from `hardware_loader.ml` `29b38a5f…` (HL4a baseline) | `6f7aac12…129d` | 1 331 / 1 331 ([record](host_link_hl4b1_record.md#rtl-and-port-comparison)) |
| HL4b2 | `6f7aac12…129d` | `026ea6e9…26cd` | 1 331 / 1 331 ([record](host_link_hl4b2_record.md#rtl-and-port-comparison)) |
| HL4b3 | `026ea6e9…26cd` | `07f154d9…5fdd` | 1 331 / 1 331 ([record](host_link_hl4b3_record.md#rtl-and-port-comparison)) |
| HL4b4 | `07f154d9…5fdd` (regenerated fresh here; byte-identical to HL4b3's post) | `2bf67bdc…00bc9` | 1 505 / 1 505 (above) |

So the final emitted `loader_core` is related to the unsplit loader by four successive
name-matched sequential-equivalence proofs whose source identities connect, each covering
every port. This is a chain of recorded results, not a fresh direct proof: no end-to-end
proof between `dfb870cf…` and the final `loader.v` was run, and the unsplit source
(`hardware_loader.ml` `29b38a5f…`) is not present in this working tree to regenerate it. The
earlier three links are recorded evidence, not rerun here. Each wrapper-level link is
complete only under `async2sync`, with the wrapper's own two reset-synchronizer bits
unproven untransformed.

## Generic synthesis

The configuration is the loader checker's own, unchanged: the pinned image above,
`docker run --rm --pull=never --network none`, and
`yosys -p 'read_verilog /bundle/src/tt_um_leemperor_hardcaml_protemu_loader.v; hierarchy
-check -top tt_um_leemperor_hardcaml_protemu_loader; synth -top
tt_um_leemperor_hardcaml_protemu_loader; stat'` on the production synthesis source,
through `synth_stat.sh`. The full checker also passed afterwards.

**Checker path, `tt_um_leemperor_hardcaml_protemu_loader`** (Yosys 0.66):

| Cell type | Unsplit | HL4b3 accepted = HL4b4 before | HL4b4 after | Δ vs HL4b3 | Δ vs unsplit |
| --- | ---: | ---: | ---: | ---: | ---: |
| `$_ANDNOT_` | 496 | 440 | 440 | 0 | −56 |
| `$_AND_` | 7 907 | 7 848 | 7 848 | 0 | −59 |
| `$_DFFE_PP_` | 4 240 | 4 240 | 4 240 | 0 | 0 |
| `$_DFF_PN1_` | 2 | 2 | 2 | 0 | 0 |
| `$_DFF_P_` | 13 | 13 | 13 | 0 | 0 |
| `$_MUX_` | 592 | 543 | 543 | 0 | −49 |
| `$_NAND_` | 8 370 | 7 959 | 7 959 | 0 | −411 |
| `$_NOR_` | 491 | 458 | 458 | 0 | −33 |
| `$_NOT_` | 84 | 94 | 94 | 0 | +10 |
| `$_ORNOT_` | 456 | 401 | 401 | 0 | −55 |
| `$_OR_` | 554 | 611 | 611 | 0 | +57 |
| `$_SDFFE_PP0N_` | 3 | 3 | 3 | 0 | 0 |
| `$_SDFFE_PP0P_` | 804 | 912 | 912 | 0 | +108 |
| `$_SDFFE_PP1P_` | 6 | 6 | 6 | 0 | 0 |
| `$_SDFF_PP0_` | 315 | 142 | 142 | 0 | −173 |
| `$_XNOR_` | 552 | 542 | 542 | 0 | −10 |
| `$_XOR_` | 223 | 217 | 217 | 0 | −6 |
| **Cells** | **25 108** | **24 431** | **24 431** | **0** | **−677** |
| Flip-flops (sum of `DFF` types) | 5 383 | 5 318 | 5 318 | 0 | −65 |
| Wires / wire bits | 25 450 / 66 614 | 24 959 / 69 019 | 24 960 / 69 020 | +1 / +1 | −490 / +2 406 |
| Public wires / bits | 7 041 / 48 205 | 7 097 / 51 157 | 7 098 / 51 158 | +1 / +1 | +57 / +2 953 |
| Ports / port bits | 8 / 43 | 8 / 43 | 8 / 43 | 0 | 0 |

`stat` block digest (first 31 lines): before `68632e91…3194` (HL4b3's), after
`73e2bd610b6c4c11e5c3892fd3803e6cb8a6f0e4e2cbcf59329c327ca6c7f477`. The digests differ only
because of the wire lines.

**Investigation.** Every cell count, every per-type count, and the flip-flop total are
unchanged. The only `stat` differences are one wire and one public wire of one bit: the
new named forward wire (`signal_wire_29` in `loader.v`) that joins `Frame_tx.pending_o` to
eligibility, a net with no cell. Because equal counts do not by themselves show equal
mapped state, `ff_bits.sh` listed every mapped flip-flop with the register bit it drives,
before and after: after renaming `loader$frame_tx$reg_` to `loader$reg_`, the two 5 318-line
inventories are **identical line for line** (type and register bit), and the six transmitter
registers map exactly as before (pending 1 `$_SDFF_PP0_`, bits 8 `$_SDFF_PP0_`, active 1,
length 4, store 104, and shift 168 `$_SDFFE_PP0P_`; post inventory SHA-256 `76f5b4d1…`).
So the same state bits are kept, merged, or dropped as in the accepted HL4b3 result.

Limitation: combinational cells were compared by count per type, not cell by cell; equal
counts are not proof of an identical netlist, and no post-synthesis equivalence proof was
run. There is no nonzero delta to attribute. No production naming was changed to influence
the count, and no mapped-area, timing, or power claim follows.

## Bundle metadata and source identity

`source_revision` is `89a3fe8` in every bundle. Only `identity`, `source_inputs`, the
copied inputs, and the loader's two Verilog roles changed; `info.yaml`, constraints, and
`config.json` did not.

| Bundle | Identity before | Identity after | Source-input changes |
| --- | --- | --- | --- |
| observable | `d4182035733aef58158d8b7bdfef17e5ed4c9e041eed6b6008640e91a1725f64` | `5a8f523bfe0e20f91c04cbb319403992a65904be3cce723971c687e398312210` | `bin/asic_bundle.ml` content |
| memory | `0c9a836e91cb04ee5af004d1b6ad9213feed5ad33aa2d100b21c878c7f47ec29` | `fd5227fa3cd5e2cfe0df2065586eeea00a513d59ebbe273a61f00844f5d339f0` | the same input |
| loader | `dc5da5730cb9c6eada2ec271e7408d213d5e1f8dd25208dfc1104601839ccc50` | `e374455229755bf682cb45bb33194a8c6a1189929f40af2c5c2884d8a4357b1e` | the same, plus `host_link_wire/wire.ml`, `command_dispatch.ml`, `frame_rx.ml`, `hardware_loader.ml`, and `serial_phy.ml` content; added `lib/host_link/frame_tx.ml`, `wire_crc.ml`, and `wire_layout.ml` (git status `??`), 37 → 40 inputs |

The three new modules belong only to the loader's closure (`Loader_core` →
`Hardware_loader` → the blocks → `Wire_crc`/`Wire_layout`), so the observable and memory
checker expectations did not change. No Dune change was needed: `lib/dune` includes
subdirectories, the `generate_core` rules depend on the executable whose closure includes
the new modules, and the loader-wrapper rule depends on `(source_tree ../../lib)`. The stray
`lib/staging/observed_transfer.ml` loader manifest entry was left untouched. These
working-tree identities will change again when the owner commits.

## Findings

- **Contract description correction (not a code change):** the two coincidence rows for a
  publication while a response is retained originally omitted that `response_length` is
  shared between the store and the read in progress. The focused robustness test exposed
  it; the rows are amended in place, marked as such, and a `Careful:` note in
  `frame_tx.ml`'s header states it. Neither coincidence is reachable in the composed loader.
- **New check:** `Frame_rx` cleared its CRC accumulator to a literal zero while
  `Command_dispatch` used `Wire.Crc.initial`; nothing checked that they agree. `Frame_rx`
  now checks `Wire.Crc.initial = 0` at elaboration (negative N2).
- Pinned current behavior, not changed: disable does not clear the store, shifter, or
  length (unobservable afterwards); reset in its own cycle leaves the outputs showing the
  old state; the `active` term in the shift condition is functionally redundant at the
  boundary, because arming restarts the bit count and a commit needs an active read; nonzero
  padding is never presented because the output is gated once drained; a length-0
  publication commits at the first release after arming.
- No pre-existing defect was found.

## Process deviations

- None of the execution rules was broken: every Dune command used `-j 5`, and builds, tests,
  generation, formatting, proofs, synthesis, checkers, and mutation runs ran one at a time.
  While a proof ran in the background, only source and document files were edited; no
  Dune, Yosys, Docker, or checker command was started until it finished.
- The first HL4c4 run failed because `read_bits` performed its side-effecting reads inside
  `List.init`, whose evaluation order is unspecified; the bits came back reversed. The
  testbench now reads in an explicit loop. No production code was involved.

## Migration exit-gate checklist

The table preserves the implementation agent's handoff status before planning review.
The decision below accepts all migration-scoped evidence gates; P3.6 and the explicitly
deferred unrelated items remain open.

| Gate | Evidence | Status |
| --- | --- | --- |
| Four extracted blocks, each with focused tests | `Serial_phy`/HL4c1 (11), `Frame_rx`/HL4c2 (26), `Command_dispatch`/HL4c3 (39), `Frame_tx`/HL4c4 (29), all in `@runtest` | Evidence complete; HL4b4/HL4c4 acceptance pending |
| `Hardware_loader` reduced to composition and glue | No register or `compile`; four `create` calls, two forward wires, eligibility, `busy_o`, pass-through ([above](#what-moved-and-hardware_loaders-final-responsibilities)) | Evidence complete; pending review |
| `Loader_core` uses the typed core-control boundary | Three `Control_port` records (HL3, accepted); `loader_core.ml` unchanged since (`ea0a8bf4…`) | Done (HL3) |
| Pure shared wire definitions and codec | `host_link_wire/` depends on `core` and `ppx_jane` only (verified, [Verification](#verification)); HL2 codec tests pass | Done (HL2); this slice changed two comments |
| No receiver-owned helper used by dispatch or transmit | `crc8_byte` is `Wire_crc`'s; `Command_dispatch` and `Frame_tx` reference no `Frame_rx` item (grep, [Verification](#verification)) | Evidence complete; pending review |
| Relevant checks enforced on standalone block elaboration | Each block's `check_wire_encodings` and `Wire_crc`; negatives N1–N8 | Evidence complete; pending review |
| Preserved HL4a baseline | 32 HL4a tests unchanged and passing after every slice; byte-identical sources | Evidence complete |
| Independent peer, all three tiers | Forced `@loader-rtl` passed after every slice, including this one; `p3_loader_tb.v` unchanged | Evidence complete |
| Source identity and proof chain across all extractions | [Chain](#proof-chain-back-to-the-unsplit-loader) connects `dfb870cf…` → `2bf67bdc…`; no fresh direct end-to-end proof; wrapper links qualified by `async2sync` | Open for planning: accept the chain as recorded, or request a direct proof |
| Synthesis deltas reviewed, each slice | HL4b1–HL4b3 accepted; HL4b4 0 cells and 0 mapped flip-flops incremental; bit-identical flip-flop inventory; +1 one-bit wire | Evidence complete; zero delta, pending review |
| P3.6 obligations open and separate | Queue transport (additional RTL), physical `Host_api.Device` backend, unsupported step/pin/trace mapping, STATUS/inspection reconciliation, transport-failure strategy, physical time and polling budgets, refusal error mapping | Open; not migration work |
| Deferred unrelated items tracked | `lib/staging/observed_transfer.ml` loader-manifest entry (left untouched); host-simulator CLI stdout comparison gap; repository `@fmt` backlog; module renames/qualified namespaces ([organization_migration.md](organization_migration.md#later-steps)); removing redundant rejection decisions (HL3 follow-up) | Open; tracked |

## Planning acceptance decision

The owning planning session accepts HL4b4, HL4c4, parent HL4b/HL4c, and the migration exit
gate on 2026-09-25. All planned migration implementation is complete in the working tree.
The owner still commits; no agent commit or staging is authorized.

The recorded four-link emitted-`loader_core` equivalence chain is sufficient for this
migration. Consecutive gold/gate artifact identities connect, all links cover every
external port under the same synchronous-core proof flow, and the final link's additional
174 points are the publication wires now present on both sides, not omitted earlier
state. A fresh direct unsplit-to-final proof is optional, not a remaining acceptance gate.
This accepts the recorded chain; it does not claim a new direct proof or a rerun of earlier
links. Wrapper equivalence retains its `async2sync` qualification and two unproven reset
bits in each untransformed flow. No mapped-netlist or physical equivalence is claimed.

The final synthesis result, 24 431 cells / 5 318 mapped flip-flops, has zero incremental
cell/state delta and retains HL4b3's accepted cumulative change. The existing harness,
four focused block suites (137 tests total including the harness), standalone check
negatives, pure Wire boundary, and independent peer tiers satisfy the recorded exit
obligations. `Hardware_loader` is state-free composition; shared CRC/check ownership is
resolved. The transmitter's no-publication-while-pending requirement is explicit; the
out-of-contract shared-length finding does not require changing composed behavior.

Review in this planning session covered the record, proof-chain identities, and final
composition source, with current hashes of Frame_tx, Wire_crc, Wire_layout,
Hardware_loader, the HL4a testbench, and independent peer matching the record. The session
did not rerun tests, synthesis, or formal proofs. Their results remain the implementation
evidence recorded above.

## Blockers, follow-ups, and remaining work

- **Resolved:** HL4b4/HL4c4, parent HL4b/HL4c, and the migration exit gate are accepted.
  No migration implementation or proof gate remains. Owner commit is still outstanding.
- No functional blocker. No pre-existing defect was found.
- Optional follow-up, not required by any recorded gate: a direct end-to-end equivalence
  proof between the unsplit `loader.v` and the final one would need the unsplit source
  regenerated from the committed history plus the HL3 diff.
- Out of scope and unchanged: the `observed_transfer.ml` manifest entry, the CLI stdout
  comparison gap, the `@fmt` backlog, and all P3.6 work.
- This is RTL-identity, formal-equivalence (emitted RTL), Cyclesim, emitted-RTL peer, and
  generic-synthesis evidence. It is not physical, timing, power, or mapped-area evidence.
  No physical flow was run.

## Appendix: evidence scripts

These ran from the repository root; pre/post outputs lived in the session scratchpad, and
their checksums and counts are recorded above.

`capture.sh`, `ports.py`, `synth_stat.sh`, `core.ys`, `wrapper_plain.ys`, and
`wrapper_a2s.ys` are byte-for-byte the scripts in the
[HL4b2 record's appendix](host_link_hl4b2_record.md#appendix-evidence-scripts), and
`ff_bits.sh` and `tally.sh` those in the
[HL4b3 record's appendix](host_link_hl4b3_record.md#appendix-evidence-scripts). They were
extracted mechanically (the first fenced block after each script's heading); their SHA-256
values are in the table below. Derived scripts, each a mechanical edit shown exactly:

- `classify.py`: HL4b3's, with `sed -e 's/Command_dispatch scope level/Frame_tx scope
  level/' -e 's/\$command_dispatch\$reg_/$frame_tx$reg_/g'`.
- `tally5.sh`: HL4b3's `tally.sh` with `frame_tx` added first to its suite list.
- `core_nonvacuity.ys`: `core.ys` with `equiv_status -assert` replaced by `equiv_status`.
- Every gate rename: `sed 's/loader\$frame_tx\$reg_/loader$reg_/g'`.
- `stat` digests: the first 31 lines of the `stat` block (`sed '/^End of script/,$d'`),
  which excludes Yosys's run-time line.

| Script | SHA-256 |
| --- | --- |
| `capture.sh` | `cb8d6d44bf8e19c48820affabc30496445fc80edd20f01e628e2280f69a9ac8d` |
| `ports.py` | `1348f5f5dc52953e775fca0c62b00645105821e25324a7b6cfa38d7e0ada6d9f` |
| `synth_stat.sh` | `be2a92f4e11ebd27c64157d684dd51202fa15f8b9cef6d98dd33504996433855` |
| `core.ys` | `5bd63856b3e963dd5b5f8be66819ab9f0ee381246268fc4d9939f9d62abe0534` |
| `wrapper_plain.ys` | `50945f29e51397c3ebe63f561bacb285a50960d1b369999abe90a0a49869e75d` |
| `wrapper_a2s.ys` | `f31b8026208d3cf8c95c9d23b50a914ed801003b50d7063c51a71546766d96a1` |
| `ff_bits.sh` | `39135c3032cb3eeca1dfa5dc7ca49d49c7fe3409a37fbc82e9de4a916db0f82d` |
| `tally.sh` | `28478397a941ebdda0f7bae453b7feced9b8654b0350dc7d628f7ab9244a742a` |
| `classify.py` | `4f0b1730a87db68889d5d62389b24017f1f88fb1d1921af95fe6c60c2bdfddee` |
| `tally5.sh` | `92b0ec55db524916e453e28f2232eba9a9beee4984fbe424f9ebd4580552a273` |
| `mutate.py` | `92729e7b71f905029dfe439713e7c4fa3addc5bbe717869782f50c22bef6b236` |
| `run_mutation.sh` | `b7dafdadf69420dd8ad48288795c21343db89560007588435013c67e256ab16c` |
| `check_negative.py` | `91447d7037a6a6a3b0b27412d4336536e42848d4424725355405ad65d37574ef` |
| `run_check_negative.sh` | `d6b2411a19ddfa4e0ed0678ba795c37ed5c484fe9e74e61238cc1004e4a46e60` |
| `core_nonvacuity.ys` | `9c9be65b1161147eacb51db4e1caff57eb67c80be926227ff368bc144ed4146a` |

### `mutate.py`

```python
#!/usr/bin/env python3
"""Apply one named sensitivity mutation to lib/host_link/frame_tx.ml (in place).

Each mutation is a list of exact, unique text substitutions; the restore is a copy of the
saved file followed by a SHA-256 check (see run_mutation.sh).
"""
import sys

PATH = "lib/host_link/frame_tx.ml"

PUBLISH = (
    "    ; (* A handoff error, an immediate response, or a completion, in the cycle\n"
    "         [Command_dispatch] decides it. Not gated by enable: disable below still wins for\n"
    "         [response_pending]. *)\n"
    "      when_ i.response_publish_i\n"
    "        [ r.response_store <-- i.response_frame_i\n"
    "        ; r.response_length <-- i.response_length_i\n"
    "        ; r.response_pending <--. 1\n"
    "        ]\n"
)

MUTATIONS = {
    # T1. Arming sees a publication in its own cycle as already pending.
    "T1": [(
        "         &: r.response_pending.value\n         &: i.deselect_qualified_i)\n",
        "         &: (r.response_pending.value |: i.response_publish_i)\n"
        "         &: i.deselect_qualified_i)\n",
    )],
    # T2. Arming ignores deselect qualification.
    "T2": [(
        "         &: r.response_pending.value\n         &: i.deselect_qualified_i)\n",
        "         &: r.response_pending.value)\n",
    )],
    # T3. Any release commits: no replay.
    "T3": [("        ; if_ response_drained\n", "        ; if_ vdd\n")],
    # T4. Drained one fall early: commit without the final fall.
    "T4": [(
        "    r.response_bits.value ==: sll (uresize r.response_length.value ~width:8) ~by:3\n",
        "    r.response_bits.value +:. 1 ==: sll (uresize r.response_length.value ~width:8) ~by:3\n",
    )],
    # T5. Publication moved after release and disable: it wins for pending.
    "T5": [
        (PUBLISH + "\n", ""),
        ("        ; r.response_bits <--. 0\n        ]\n    ];\n",
         "        ; r.response_bits <--. 0\n        ]\n" + PUBLISH + "    ];\n"),
    ],
    # T6. Disable does not clear pending (outputs still gated).
    "T6": [(
        "        [ r.response_pending <--. 0\n        ; r.response_active <--. 0\n",
        "        [ r.response_active <--. 0\n",
    )],
    # T7. Arming does not restart the bit count.
    "T7": [(
        "        ; r.response_bits <--. 0\n        ; r.response_active <--. 1\n",
        "        ; r.response_active <--. 1\n",
    )],
    # T8. Arming reloads the shifter from the publication input instead of the store.
    "T8": [(
        "        [ r.response_shift <-- r.response_store.value\n",
        "        [ r.response_shift <-- i.response_frame_i\n",
    )],
    # T9. Ready not gated by enable.
    "T9": [(
        "  ; serial_ready_o = i.enable_i &: r.response_pending.value\n",
        "  ; serial_ready_o = r.response_pending.value\n",
    )],
}

name = sys.argv[1]
text = open(PATH).read()
for old, new in MUTATIONS[name]:
    assert text.count(old) == 1, (name, old[:60], text.count(old))
    text = text.replace(old, new)
open(PATH, "w").write(text)
print(f"applied {name}")
```

### `run_mutation.sh`

```sh
#!/usr/bin/env bash
# Apply mutation $1 to frame_tx.ml, run all five host_link suites with -j 5, and restore
# the file exactly (SHA-256 checked). Output to $2.
set -uo pipefail
ev="$(dirname "$0")"
file=lib/host_link/frame_tx.ml
saved="$(mktemp)"
cp "$file" "$saved"
want="$(sha256sum < "$file" | cut -d' ' -f1)"
python3 "$ev/mutate.py" "$1" || { cp "$saved" "$file"; rm -f "$saved"; exit 1; }
./scripts/with-switch.sh dune build -j 5 @test/host_link/runtest > "$2" 2>&1
echo "exit $?" >> "$2"
cp "$saved" "$file"
rm -f "$saved"
got="$(sha256sum < "$file" | cut -d' ' -f1)"
[ "$want" = "$got" ] || { echo "RESTORE FAILED $1"; exit 1; }
echo "$1 restored $got"
```

### `check_negative.py`

```python
#!/usr/bin/env python3
"""Apply one temporary constant mutation for the standalone elaboration-check negatives.

Usage: check_negative.py NAME. Each is an exact, unique substitution in one source file;
run_check_negative.sh restores the file by copy and checks its SHA-256.
"""
import sys

MUTATIONS = {
    # CRC parameters the shift register cannot implement: Wire_crc, at each use.
    "N1": ("host_link_wire/wire.ml", "  let final_xor = 0x00\n", "  let final_xor = 0x01\n"),
    # A nonzero CRC start: Frame_rx's new check.
    "N2": ("host_link_wire/wire.ml", "  let initial = 0x00\n", "  let initial = 0x01\n"),
    # Request header tag moved: Frame_rx's request-header layout.
    "N3": ("host_link_wire/wire.ml", "    let tag = 2\n    let command = 3\n    let payload_length = 4\n    let payload = 6\n",
           "    let tag = 3\n    let command = 3\n    let payload_length = 4\n    let payload = 6\n"),
    # Request payload word overlapping the address: the shared payload layout (both).
    "N4": ("host_link_wire/wire.ml", "    let address = 0\n    let word = 2\n", "    let address = 0\n    let word = 1\n"),
    # Response result moved: Command_dispatch's response-header layout.
    "N5": ("host_link_wire/wire.ml", "    let result = 4\n", "    let result = 5\n"),
    # A fault kind renumbered: Command_dispatch's fault mapping.
    "N6": ("host_link_wire/wire.ml", "    | Mechanism_protocol -> 9\n  ;;\n", "    | Mechanism_protocol -> 10\n  ;;\n"),
    # INFO grown to 25 bytes (33-byte responses): Frame_tx's and Command_dispatch's 5-bit lengths.
    "N7": ("host_link_wire/wire.ml", "  let length = 13\n", "  let length = 25\n"),
    # Frame_tx's store one byte wider than the dispatcher's frame: composition width.
    "N8": ("lib/host_link/frame_tx.ml", "  let max_response_bytes = Wire.Response.max_length\n",
           "  let max_response_bytes = Wire.Response.max_length + 1\n"),
}

path, old, new = MUTATIONS[sys.argv[1]]
text = open(path).read()
assert text.count(old) == 1, (sys.argv[1], text.count(old))
open(path, "w").write(text.replace(old, new))
print(path)
```

### `run_check_negative.sh`

```sh
#!/usr/bin/env bash
# Apply standalone-check negative $1 (check_negative.py), run all five host_link suites
# with -j 5 into log $2, then restore the mutated file exactly (SHA-256 checked).
set -uo pipefail
ev="$(dirname "$0")"
path="$(python3 - "$1" "$ev/check_negative.py" <<'PY'
import sys
ns = {}
exec(open(sys.argv[2]).read().split("path, old, new")[0], ns)
print(ns["MUTATIONS"][sys.argv[1]][0])
PY
)"
saved="$(mktemp)"
cp "$path" "$saved"
want="$(sha256sum < "$path" | cut -d' ' -f1)"
python3 "$ev/check_negative.py" "$1" > /dev/null || { cp "$saved" "$path"; rm -f "$saved"; exit 1; }
./scripts/with-switch.sh dune build -j 5 @test/host_link/runtest > "$2" 2>&1
echo "exit $?" >> "$2"
cp "$saved" "$path"
rm -f "$saved"
got="$(sha256sum < "$path" | cut -d' ' -f1)"
[ "$want" = "$got" ] || { echo "RESTORE FAILED $1 $path"; exit 1; }
echo "$1 restored $path $got"
```
