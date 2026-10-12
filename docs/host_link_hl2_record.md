# HL2 implementation record: wire definitions and software codec (2026-09-23)

Status: HL2a and HL2b implemented and verified by an agent in the working tree. **Not
committed:** the repository owner has not committed this change, and nothing is staged.
This is the implementation record for [HL2](host_link_migration.md#hl2--wire-definitions);
the [P3.5 record](p3.5-hardware-loader.md) remains the wire-protocol authority. No wire
value, layout, command/result meaning, pin, or timing requirement changed.

## Tested revision and local diff

- `HEAD` = `705e197` (HL1, parent `9f6ed2d`), branch `bpurtell/scaf`.
- Local diff before any HL2 edit: only the owner's HL1-completion updates to
  `docs/host_link_migration.md` and `docs/organization_migration.md`. They are preserved.
  No source, Dune, script, or test file was modified, so the baseline below is `705e197`'s
  sources.
- HL2 diff (uncommitted):

  | Path | Change |
  | --- | --- |
  | `host_link_wire/dune`, `host_link_wire/wire.ml` | New library `protemu_host_link_wire` (public `hardcaml_protemu.host_link_wire`), module `Wire` |
  | `test/host_link_wire/dune`, `test/host_link_wire/wire_tests.ml` | New pure codec tests |
  | `lib/dune` | `hardcaml_protemu` also depends on `protemu_host_link_wire` |
  | `lib/host_link/hardware_loader.ml` | `Config`/`Command`/`Result`/`Capability` removed; wire constants taken from `Wire`; elaboration-time checks added |
  | `bin/asic_bundle.ml` | Loader `input_paths` gains `host_link_wire/dune` and `host_link_wire/wire.ml` |
  | `tinytapeout/scripts/check-adopted-bundle.py` | Loader metadata check requires those two inputs |
  | `tinytapeout/src/dune` | Loader-wrapper bundle rule depends on `host_link_wire/` |
  | `docs/` | This record plus current-reference updates listed under [Documentation](#documentation) |

## Tool identity

opam switch `5.2.0+ox` (OCaml 5.2.0+ox), Dune 3.24.2; `hardcaml`, `ppx_hardcaml`, `core`,
`base`, `ppx_jane`, `ppx_js_style`, `ppx_expect` `v0.18~preview.130.106+341`; `ocamlformat`
0.26.2+ox2; `hardcaml_asic` 0.1.0 (rsync pin of `~/devel/jane/hardcaml_asic`, checkout
`037e670`, whose local changes are documentation only); Verilator 5.020, Icarus Verilog
12.0, Yosys 0.33, Python 3.12.3. The same installed switch served every pre- and
post-change run.

## What changed

### `host_link_wire/`: the wire definitions

One module, [`Wire`](../host_link_wire/wire.ml), transcribing the P3.5 record. Its only
library dependency is `core`; it has no Hardcaml, `hardcaml_protemu`, simulator, ISA, or
ASIC dependency. Following the repository convention (no `.mli` files), its API is
documented in the `.ml`.

| Module | Contents |
| --- | --- |
| `Version` | major 1, minor 0, version byte `0x10` |
| `Crc` | CRC-8/ATM parameters (`width`, `polynomial`, `initial`, `reflected`, `final_xor`, `length`) and the software `update`/`compute` |
| `Command` | Variant, `to_int`/`of_int`, `request_payload_length` |
| `Result_code` | Variant, `to_int`/`of_int` (named to avoid shadowing `Core.Result`) |
| `Capability` | INFO capability variant, `bit`, `mask` |
| `Fault_kind`, `Phase` | Stable STATUS values, `to_int`/`of_int`; phase 7 is reserved |
| `Info`, `Status` | Payload `Offset`s, `length`, decoded records; `Status.Flag` bit positions; `Info.memory_layout_m16` |
| `Correlation` | Echoed `{ tag; command }`, with `command` as the raw byte |
| `Request` | `magic`, header `Offset`s, `header_length`, `max_payload_length`, `min_length`/`max_length`, `Payload_offset`, the request variant, `encode`, `correlation` |
| `Response` | `magic`, header `Offset`s, lengths, `Payload`, the decoded `t`, `Decode_error`, `decode`, `decode_correlated` |

Public codec API:

```ocaml
Wire.Crc.compute : string -> int
Wire.Request.encode : tag:int -> Wire.Request.t -> (string, Wire.Request.Encode_error.t) Result.t
Wire.Request.correlation : tag:int -> Wire.Request.t -> Wire.Correlation.t
Wire.Response.decode : string -> (Wire.Response.t, Wire.Response.Decode_error.t) Result.t
Wire.Response.decode_correlated :
  expected:Wire.Correlation.t -> string -> (Wire.Response.t, Wire.Response.Decode_error.t) Result.t
```

`Request.t` has one constructor per command, with its u16 operands (`Load_start { length }`,
`Write_word { address; word }`, `Read_word { address }`, `Verify_word { address; expected }`).
A decoded `Response.t` is `{ tag; command; result; payload }`, where `payload` is `Empty`,
`Word`, `Info`, or `Status`. The codec is bytes only. It does not clock pins, poll `LRDY`,
commit or replay a response, retry, or apply a timeout.

### Hardware adoption

`Hardware_loader` binds `module Wire = Protemu_host_link_wire.Wire` and takes from it the
magic bytes, version, command and result codes, capability mask, request/response header
lengths, request payload offsets and per-command payload lengths, maximum request/response
lengths, the correlation-echo threshold, the STATUS flag order, and the CRC polynomial and
initial value. Its `Config` now holds only implementation sizing (`max_request_bytes`,
`request_byte_count_bits`, `max_response_bytes`, `response_bits`) and the INFO device facts
this design reports (`isa_version = 1`, `memory_layout`, `capabilities = Wire.Capability.all`);
memory width/depth and pin count still come from `Protocol_core.Config` and
`Protemu_isa.Pins`.

The synthesizable `crc8_byte` shift register remains separate from `Wire.Crc.compute`. It
uses `Wire.Crc.polynomial` and `Wire.Crc.initial`. `check_wire_encodings`, called first in
`create`, refuses to elaborate unless `Wire.Crc` is 8 bits wide, non-reflected, and has no
final XOR, which is what the shift register implements.

`check_wire_encodings` is plain OCaml and creates no logic. It also checks:

- every `Wire.Fault_kind`/`Wire.Phase` value equals the execution-unit value it reports;
- `Control_execution.Fault.width` and `Phase.width` fit their STATUS bytes;
- `Wire.Status.Flag.all` is in bit order;
- the request header, request payload, response header, INFO, and STATUS offsets tile their
  layouts in the order the hardware emits bytes;
- the 5-bit response-length register and 8-bit response-bit counter cover the maximum response.

`create` also checks that the literal INFO and STATUS byte lists have `Wire.Info.length`
and `Wire.Status.length` bytes. A u16 constant too wide for its two INFO bytes raises
instead of being truncated.

Fault/phase mapping. STATUS wires `fault_kind_i` and `phase_i` directly, with no
decode/re-encode logic and no added stages:

| Wire value | `Wire.Fault_kind` | `Control_execution.Fault` | `Wire.Phase` | `Control_execution.Phase` |
| ---: | --- | --- | --- | --- |
| 0 | `No_fault` | `none` | `Halted` | `halted` |
| 1 | `Invalid_base` | `invalid_base` | `Fetch` | `fetch` |
| 2 | `Invalid_extension` | `invalid_extension` | `Base_wait` | `base_wait` |
| 3 | `Fetch_bounds` | `fetch_bounds` | `Extension_wait` | `extension_wait` |
| 4 | `Truncated_extension` | `truncated_extension` | `Mechanism_offer` | `mechanism_offer` |
| 5 | `Target_unrepresentable` | `target_unrepresentable` | `Mechanism_wait` | `mechanism_wait` |
| 6 | `Mechanism_refused` | `mechanism_refused` | `Fault` | `fault` |
| 7 | `Mechanism_completion` | `mechanism_completion` | reserved | none |
| 8 | `Unsolicited_completion` | `unsolicited_completion` | — | — |
| 9 | `Mechanism_protocol` | `mechanism_protocol` | — | — |

The mapping functions are `Hardware_loader.execution_fault` and `execution_phase`.
`Control_execution.Fault`/`Phase` are integer constants with no enumeration, so the check
covers every wire value but cannot detect a new internal value; adding one is P3 protocol
work that must add its `Wire` value first.

Two checks showed that the hardware reads these definitions. Both edits were temporary and
reverted afterwards. Changing `Wire.Response.magic` changed the emitted `loader.v`, and
changing `Wire.Fault_kind.Mechanism_protocol` to 11 stopped `generate_core.exe loader` with
`Invalid_argument "Hardware_loader: fault kind 11 differs from the execution unit"`.

### Bundle source inputs

`host_link_wire/` is now a hardware-relevant source input, so the loader manifest lists
`host_link_wire/dune` and `host_link_wire/wire.ml`. The checker requires them, and
`tinytapeout/src/dune`'s loader-wrapper rule depends on the directory. The observable and
memory inventories do not gain them. Their designs do not use `Wire`, just as they do not
list `isa/`. The stray `lib/staging/observed_transfer.ml` loader entry is unchanged; its
cleanup remains separately deferred.

## Decoder policy decisions

The P3.5 record defines the device's behavior; it does not define a host decoder. These
decisions are the codec's, recorded here instead of being written into the protocol:

1. **Check order.** Length ≥ 8, magic, version byte, declared payload length ≤ 13 (so a
   nonzero high length byte always fails as `Payload_length_too_large`), exact frame length
   (`Truncated` or `Extra_bytes`), CRC, defined result code, command/result/payload shape,
   and INFO/STATUS field values. The first failure is reported.
2. **Malformed versus refusal.** A `Decode_error` means the bytes are not a valid v1
   response. The transaction owner should replay rather than commit. Well-formed refusals
   (`0x20`–`0x24`, `0x2f`) and device-reported framing errors (`0x10`–`0x15`) decode
   successfully as the device's answer.
3. **Command/result shapes.** Framing errors `0x10`–`0x13` and `0x15` accept any echoed
   command byte, including zeroed correlation, with an empty payload. `Bad_command` accepts
   only an unnamed command byte, which is kept raw. Refusals accept any named command with
   an empty payload; the record does not restrict which commands may be refused.
   `Accepted_pending` is valid only for STOP, and `Complete` is valid for every command
   except STOP. INFO returns 13 bytes, STATUS 12, and READ_WORD/VERIFY_WORD 2 (the actual
   word). `Verification_mismatch` is valid only for VERIFY_WORD and carries the actual word.
   Any other combination is `Unexpected_result`. A payload length other than the shape's is
   `Payload_length_mismatch`.
4. **Unknown and reserved values.** An undefined result code is `Unknown_result`. A set
   reserved INFO capability bit (7–15) or STATUS flag bit (12–15), fault kind 10–255,
   phase 7–255, or INFO wire major/minor disagreeing with the frame version is
   `Invalid_field`. INFO's ISA version, memory layout, word bits, depth, maximum payload,
   and pin count are decoded as data, so a host can report an unfamiliar device as
   incompatible instead of failing to decode it.
5. **Encoder inputs.** The tag must be 0–255 and every u16 operand 0–65535. Anything else is
   `Out_of_range`, and the first bad field in wire order is reported; nothing is masked.
   Device bounds, such as an address beyond 255 or an image length of 0, are legal wire
   values that the device refuses. The codec does not pre-empt them.
6. **Correlation boundary.** `Response.decode_correlated ~expected`, with `expected` from
   `Request.correlation`, is the named boundary. A decodable response echoing another tag
   or command is `Correlation_mismatch` and carries the decoded response.

**Planning decision — preserve the existing zero-echo behavior.** A device that received
fewer than four request bytes zeroes the echoed tag and command. For a request with tag 0
and command INFO (`0x00`), that zeroed framing error cannot be told apart from a real echo,
so `decode_correlated` returns it as the answer; for any other request it is a
`Correlation_mismatch`. In both cases the result is not success. Keep this behavior for
HL2; no codec or wire change is required. Correlation-field equality does not prove that
the device received the full request header. A host may avoid tag 0 to avoid this
specific collision, but doing so does not recover missing correlation information.
P3.6 must define bounded recovery for a valid retained error response whose correlation
cannot be established: replaying the same retained response cannot repair its zeroed
fields. This decision does not authorize automatic command retry or prescribe response
commit policy. Distinguishing the two cases on the wire would be a P3.5 protocol change.

## Tests added

[`test/host_link_wire/wire_tests.ml`](../test/host_link_wire/wire_tests.ml), library
`protemu_host_link_wire_tests`, depends only on `core` and `protemu_host_link_wire`. It has
26 `%test_unit` cases. Every expected byte and decoded field is written out from the P3.5
tables. Expected CRC bytes come from the independent bitwise script below, which was checked
against the standard check value, never from `Wire`.

- Constants: frame magic, version, lengths, INFO/STATUS lengths, and the m16 layout ID;
  CRC-8/ATM parameters, `"123456789"` → `0xf4`, and single-byte values (`00`, `07`, `89`,
  `f3`).
- Code tables in both directions: commands, results, fault kinds, and phases, with every
  byte outside the table checked to decode to `None` (phase 7 included). Capability masks,
  STATUS flag bits, and fixed request payload lengths.
- Fixed request vectors for all ten commands, plus u16 boundaries: length 0, 256, and
  `0xffff`; address `0xffff`; a little-endian address above the memory. Tags range over
  `0x00`–`0xff`.
- Encoder rejections: tag -1 and 256; length, address, word, and expected values at -1 and
  65536; first-bad-field reporting.
- Response vectors for every result code and payload shape. INFO decodes every field. STATUS
  decodes a mixed flag set and counters, plus all flags with `0xffff` counters. READ and
  VERIFY carry the actual word, as does a VERIFY mismatch (`0x1233` against an expected
  `0x1234`). Empty successes cover STOP `Accepted_pending`. All five framing errors decode,
  with echoed and zeroed correlation, as do `Bad_command` echoing raw `0x7e` and all five
  refusals.
- Malformed input: empty and 7-byte frames, a missing payload byte, extra bytes, bad magic,
  bad version, declared lengths of 14 and `0x0100`, two CRC failures, unknown results
  `0x02`/`0x30`, six impossible command/result pairs, four payload-length mismatches, and
  five reserved/undefined INFO/STATUS values.
- Correlation: matching, tag mismatch, command mismatch, zeroed correlation, the tag-0 INFO
  ambiguity, CRC failure under an expectation, and raw unknown-command correlation.
- Supplementary: encoded frames have a zero CRC residue. The fixed vectors remain the oracle.

A temporary mutation (CRC polynomial `0x09`) made the suite fail with CRC mismatches, which
shows the inline tests execute. It was reverted.

Independent CRC oracle used for the vectors (Python, written from the P3.5 record):

```python
def crc8(data):
    crc = 0
    for byte in data:
        for bit in range(7, -1, -1):
            feedback = ((crc >> 7) ^ (byte >> bit)) & 1
            crc = (crc << 1) & 0xFF
            if feedback:
                crc ^= 0x07
    return crc

assert crc8(b"123456789") == 0xF4
```

## Verification

Every Dune command used `-j 5`, and commands ran strictly one after another.

**Pre-change baseline at `705e197`**, before any source edit:

| Check | Result |
| --- | --- |
| `./scripts/with-switch.sh dune build @install @lint -j 5` | PASS, up to date (no actions) |
| `./scripts/with-switch.sh dune build @runtest -j 5` | PASS, up to date (no output) |
| `./scripts/with-switch.sh dune build @rtl -j 5` | PASS, up to date (no actions) |
| `check-adopted-bundle.py --kind observable/memory/loader --metadata-only`, run separately | PASS, PASS, PASS |
| `./scripts/with-switch.sh dune build @fmt -j 5` | The known 13-file backlog: `f_model/fifo.ml`, `f_model/shift_engine.ml`, `isa/descriptor.ml`, `lib/pluggable_primitives/{byte_fifo,input_events,pin_bank,shift_lane,timing}.ml`, `lib/staging/{primitive_demo,uart_tx}.ml`, `test/common/backend_conformance.ml`, `test/common/dune`, `test/primitives/pin_bank/dune` |

**Post-change** (the `HEAD` above plus the uncommitted HL2 diff):

| Check | Result |
| --- | --- |
| `./scripts/with-switch.sh dune build -j 5 @test/host_link_wire/runtest` (focused) | PASS |
| `./scripts/with-switch.sh dune build @install @lint -j 5` | PASS |
| `./scripts/with-switch.sh dune build @runtest -j 5` | PASS, no output and no expect-test diffs (29 s; dependent tests re-ran) |
| `./scripts/with-switch.sh dune build @loader-rtl --force -j 5` | PASS, 470 s, all three peer tiers freshly executed (reusable core, behavioral wrapper, production synthesis wrapper); each printed `PASS p3.5 serial loader repair ... 3/3 sensitivity phases=10, excluded 1/1 failures=10` |
| `./scripts/with-switch.sh dune build @rtl -j 5` | PASS, up to date after the forced loader run; every other bench's RTL input is byte-identical |
| 15 generator outputs regenerated with identical options, `diff -r` against the baseline | Identical, 15 of 15. Rerun on the final source, after the last comment and format edits to `hardware_loader.ml`: identical again. |
| Bundle Verilog, pre vs post | Identical for the `src/` (synthesis) and `simulation/` (behavioral) roles of observable, memory, and loader. `info.yaml` and `constraints/` are also identical. |
| `check-adopted-bundle.py --kind observable/memory/loader --metadata-only`, run separately | PASS, PASS, PASS |
| `dune describe workspace host_link_wire test/host_link_wire`: transitive closure of `hardcaml_protemu.host_link_wire` | 75 libraries, none Hardcaml, `hardcaml_protemu`, simulator, or ASIC. Direct requirement: `core` plus ppx runtime libraries. |
| `tinytapeout/test/p3_loader_tb.v` | Unchanged: no diff against `HEAD`; git blob `2ffc20f0f302c5bad5fd9189056b22c8d8cc175d`, SHA-256 `40d9341f32ad02202f78784dbf4c6f9a7685691d8f7da78a50c2303cd2e2c9c9` before and after |
| `./scripts/with-switch.sh dune build @fmt -j 5` | Same 13-file backlog as the baseline; no HL2-touched file listed. New and edited files were formatted file by file (`dune promote <file>`); the backlog was not swept. |
| `git diff --check`, plus a trailing-whitespace/tab scan of untracked files | PASS |

### RTL baseline and byte identity

Generation commands, run identically before (`pre/`) and after (`post/`):

```sh
for mode in access executable integrated loader; do
  ./scripts/with-switch.sh dune exec -j 5 bin/generate_core.exe -- "$mode" "$dir/$mode.v"
done
./scripts/with-switch.sh dune exec -j 5 bin/generate.exe -- -output "$dir/p0.v" -module-name p0_observable
for block in pin_bank input_events timing byte_fifo_8 shift_lane observed_transfer \
  observed_transfer_bank primitive_demo uart_tx uart_slice; do
  ./scripts/with-switch.sh dune exec -j 5 bin/generate_p2.exe -- "$block" "$dir/$block.v"
done
./scripts/with-switch.sh dune build -j 5 bin/asic_bundle.exe
for kind in observable memory loader; do
  ./_build/default/bin/asic_bundle.exe "$kind" "$bundles/$kind" "$PWD"
done
```

The raw directories were in the agent's session scratchpad, which is temporary. The
complete checksum lists below are the durable evidence. Each list is byte-identical before
and after. The list digests (`sha256sum` of `sha256sum *.v` output, as HL1 computed them)
are `29831c119d353a19205b015394a7be871c54eaced350fe03c0421cbc1aa87d21` for the 15 outputs
and `cbd0dc8df2d2547af8671cc868a94fd4336aae1fe63836ab35d5abe94d2e5cec` for the six bundle
files. Both match the HL1 record's digests.

```text
66c91d2f44524fa9c38c8a1b38528f5789c32465cd52782ca05ac6075171b8a8  access.v
5d8062004e3919e2ddc140f7af2785d0f9a09e3ee495bd83620029c58693eeaf  byte_fifo_8.v
7473662697c0b1636f77bad7ac35b547b38c10919fc4d6e2c87e0100d8be9116  executable.v
626be0dc9fdab61b9fedffe59e527d6f2e37b4c2474d79d8bd69aaa18f817e92  input_events.v
3af601b6b7ce88a58bacba1c58a9e69435098d846d9eb687670046b9786eadec  integrated.v
dfb870cf40267029fb3bc3ddd78b4f9ec31a625c5602716aed3c2d894005c035  loader.v
5f9ebeae9e51bec5399e439bfcf8ce7e060595f3a2afbb0c3f0277e4ad973e50  observed_transfer_bank.v
f65f7442539548cb3d55cbaf3d47358c2bc7d5c09ca5862037c06965c636e800  observed_transfer.v
c9f5e31aa3845c32810245b0ed568af67dcf253cf86ffc76ba66a704b59b7042  p0.v
0090a95846b9ef01fd508c59f9dd998d35d8fabaef2f0aec7d7d7454475a43c8  pin_bank.v
49d138686f7688cd0b2fd19144b567bc43243a3c448221352a7437f9d31c70a8  primitive_demo.v
d837339ab1f762592a2211032c9d4ae0fff20c0d30f7834d18a4e5515581ef04  shift_lane.v
fc0dbed78ff5ecf3f32f5e6e3ae7aa1e332dc154b1e7b69847616b643f74584c  timing.v
e7d3886907003a8376961e695f227b5f3398fefc7cfc9d033721a39c27016cb0  uart_slice.v
ce4454c0b15fe20e6b22eb290f0b029b11625e0e4c8188d0a109450affd9dd72  uart_tx.v
```

```text
7678aedb9d5b35c5e9fbf7e0e31e489609a47f9fddc79ed3acf1139ef5168b28  ./loader/simulation/tt_um_leemperor_hardcaml_protemu_loader.v
c8f92f762d1044dde0bb7a1071a4b41a43c4fe33c4a2cdd10dc4ed31ab213d9c  ./loader/src/tt_um_leemperor_hardcaml_protemu_loader.v
8b21fa31a7a309c5f573ac60549b4f3bbb119a25bc4d0e613b1d31012c743762  ./memory/simulation/tt_um_leemperor_hardcaml_protemu_memory.v
a6c3ad27c175d89571ae393dfb7a2044253a6a6f1a1d0201b6a022c8c3ce0d95  ./memory/src/tt_um_leemperor_hardcaml_protemu_memory.v
c275808a7279c617c460c3706cdfd69c0d580b7c3356ec224b66d8730b7b0cb1  ./observable/simulation/tt_um_leemperor_hardcaml_protemu.v
c275808a7279c617c460c3706cdfd69c0d580b7c3356ec224b66d8730b7b0cb1  ./observable/src/tt_um_leemperor_hardcaml_protemu.v
```

### Bundle metadata and source identity

Only `identity`, `source_inputs`, and the `inputs/` entries of `files` changed. The
emitted Verilog, `info.yaml`, and constraints did not.

| Bundle | Identity at `705e197` | Identity with the HL2 working tree | Source-input changes |
| --- | --- | --- | --- |
| observable | `0fd551e077523c210b8caf202c098d8262a045f9be3c1980e53bf7e0d700d870` | `9e26006d6293fbfb72f1b1ab58ec3af378b9d7844b0dc532f772f90ecc49dc9e` | `bin/asic_bundle.ml`, `lib/dune` content and git status |
| memory | `eb9c8bcdb05ff1164621738d0a81da47918bbba9800d8d2ac7f83872078cc52d` | `648c4eb5a2a1d1824d57fcbf9ab1523e81cc356d3f773c2b780e9b2a1d952cb6` | same two inputs |
| loader | `66d74d192f9b185bd994dba129b52f9b441d4c8096637ae622d1f4b4615d5b26` | `f704c282430571136e777573a923a65cfbe529d6e4829bc37c8d3f3ef91c6e25` | the same two, plus `lib/host_link/hardware_loader.ml`; added `host_link_wire/dune` and `host_link_wire/wire.ml` (31 → 33 inputs) |

These are expected identity changes, not design changes. Every manifest input records its
content hash and git status, and the manifest records the source revision. The working-tree
identities above therefore will change again when the owner commits, because the committed
tree has clean status and a new revision. For the same reason, the `705e197` identities
above differ from the HL1 record's post-move values: those were taken at `9f6ed2d` with the
move uncommitted. That explanation is consistent with the manifest fields, but it was not
re-derived.

## Documentation

- [host_link_migration.md](host_link_migration.md): status, HL2a/HL2b checked with links
  here, and the "what the host link is today" and consumer tables.
- [p3.5-hardware-loader.md](p3.5-hardware-loader.md): capability, fault, and phase values
  are defined in `Wire`, and the implementation and independence text names the library.
- [verification.md](verification.md): the preservation rule names the existing `Wire`, and
  the new codec suite is listed.
- [organization_migration.md](organization_migration.md): `host_link/` also depends on the
  external `host_link_wire/` library. Separately, the owner's uncommitted HL1-completion edit
  left the `git log --follow` verification-table row without its cell separator. HL2 added
  the missing `|` and kept the owner's wording.
- [construction-plan.md](construction-plan.md) §2 and [README.md](README.md): inventory
  and index entries.

## Non-claims and follow-ups

- This is OCaml codec evidence plus byte-identical RTL and the unchanged emitted-RTL peer.
  It is not physical, board, timing-closure, or mapped-area evidence. The full
  (non-metadata) bundle checker and generic synthesis were not rerun; the synthesis inputs
  are byte-identical.
- There is no OCaml simulation of `Hardware_loader` through its pins yet. That is HL4a's
  harness, which will use this codec.
- The tag-0 INFO collision is accepted as an existing wire limitation for HL2. P3.6 owns
  bounded recovery for valid retained responses with unavailable/mismatched correlation,
  as recorded in the decoder policy decision above.
- `observed_transfer.ml` in the loader manifest: unchanged and still deferred.
- STATUS wires the 17-bit `Control_execution` PC into its u16 field with `uresize`. This
  predates HL2, is unchanged, and is noted only because the codec decodes that field as u16.
