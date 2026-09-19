# Comment and manual formatting guidelines

These conventions are based on the edited examples in this repository. Use
[formatting_guide.md](formatting_guide.md) for hardware module layout, port names,
and the `Always`/`Signal` split. This document covers explanatory comments and
the hand formatting used within those modules and in the plain OCaml model.

## Reference files

| For | Read |
| --- | --- |
| Hardware state, handshakes, a mux, and an `Always.compile` block | [byte_fifo.ml](../lib/byte_fifo.ml) |
| A small hardware wrapper and an aligned lane descriptor | [uart_tx.ml](../lib/uart_tx.ml) |
| Plain OCaml state, accessors, and a step algorithm | [fifo.ml](../model/fifo.ml) |
| A larger circuit with an FSM and memory-port timing | [protocol_core.ml](../lib/protocol_core.ml) |
| A larger model with edge ordering and lifecycle notes | [machine.ml](../model/machine.ml) |

These examples show different amounts of detail. Give a short wrapper less
commentary than a state machine. Add a comment when it answers a question that
the type and expression alone leave open.

## File headers

Start each OCaml source file with four separate comments: university, author,
quoted filename, and a module description.

```ocaml
(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "byte_fifo.ml" *)
(* A small byte queue with separate push and pop handshakes.

   Describe who uses it, the timing or ordering contract, and the boundary of
   its responsibility here.
*)
```

The fourth comment should let a reader understand the module without first
reading its callers. State what it represents, who owns or calls it, the main
timing or data contract, and any important exclusion. Include a design reason
when it affects the whole file. For example, `model/fifo.ml` explains why depth
is an argument and why a paired pop makes room for a push.

Keep header facts current. Phase references and cross-module claims are useful
only when they describe the code as it exists.

## Comments beside definitions

Put a comment directly above each module, type, and nontrivial function. A short
accessor can have one line; an algorithm can have a paragraph or numbered steps.

For a state record, describe what each field means beyond its type. Align
field names in a table when it makes the relationship easier to scan:

```ocaml
(* Registered queue control;

   read_index  : address of the oldest byte;
   write_index : address of the next free slot;
   count       : number of valid bytes;
*)
module I_Regs = struct
  ...
end
```

For `I` and `O` records, group related ports with a comment at the first field
of the group. Name the clock domain, reset behavior, producer and consumer,
or handshake rule where those facts matter. Keep complete `_i` and `_o` names
when referring to a specific port. The OCaml record separator belongs before
the comment for a new group:

```ocaml
{ clock_i : 'a
; reset_i : 'a
; (* Producer -> queue; transfers when valid and ready are high. *)
  push_valid_i : 'a
; push_data_i : 'a [@bits 8]
}
```

A function comment should explain the outcome and the reason for a surprising
choice: why a check raises, why data is not reset, how simultaneous operations
are ordered, or which values are deliberately unspecified. For a sequence of
decisions, list the steps in execution order and include failure cases. Use a
small table when combinations of inputs determine distinct outcomes.

Within a function, add brief comments at meaningful stages: validation,
register setup, derived conditions, storage construction, a mux branch, or
result propagation. A short informal note is fine when its meaning is clear.
A comment that describes a nearby condition should stay beside that condition;
a longer explanation belongs above the expression.

## Comment punctuation and layout

- Use `(* ... *)` for implementation comments. Use `(** ... *)` for public
  declarations in an `.mli`, if one is added.
- A one-line comment may close on that line. In a multi-line comment, put
  `*)` on its own line, including comments inside functions.
- Separate paragraphs, tables, and numbered steps with a blank line.
- Use semicolons freely to connect clauses, end table rows and step lines,
  or close short summary lines. Ordinary prose can end with a period.
- Reference local values and fields as `[step]` or `[entries]`; name another
  module's function as `Machine.create`. Link to a repository document or test
  when it supports a claim.
- Comments are allowed beside an argument, match arm, or assignment when
  they identify a case. Keep them short enough to see the code they annotate.
- Avoid stale phase claims and comments that merely repeat a field name or
  expression.

### Interfaces, pitfalls, and failures

In an `.mli`, use odoc comments to state what callers may rely on: accepted
inputs, ordering, visible state, and failure behavior. Put implementation
mechanics in the `.ml`. Document record fields or variant constructors when
their meanings are not evident from the types.

Start a warning about easy misuse with `Careful:` and give a concrete case.
For example, `model/program_store.ml` distinguishes an unspecified output from
an out-of-range address: one is a modeled value, while the other raises.
Explain unreachable branches and the invariant that makes them unreachable.

When documenting failure, say when it occurs and what the caller receives.
This repo uses different mechanisms for different boundaries: `invalid_arg`
at hardware circuit construction, `Fault.Reject.t` for refused model
operations, `raise_s [%message ...]` for invalid model setup, and status or
fault signals in a circuit. Describe the mechanism present in that function;
do not copy the imported guide's `Or_error` rule into unrelated code.

Write TODOs with the missing behavior, the intended fix, and any dependent
test or interface change. Include the phase or work item when it is known.
Keep a test or document path in a comment only while it points to relevant
evidence.

The edited files sometimes use long inline notes. Prefer wrapping prose when
it improves reading, but do not force a hard line limit that breaks useful
alignment or separates a note from the code it explains.

## Hand formatting and `ocamlformat`

For hardware implementation files, let `ocamlformat` handle the header,
opens, and interface declarations, then disable it for the bulk of the
manually arranged implementation. Re-enable it at the end of the file.

```ocaml
module O = struct
  ...
end

[@@@ocamlformat "disable"]

(* Registered state; ... *)
module I_Regs = struct
  ...
end

let create ... =
  ...
;;

[@@@ocamlformat "enable"]
```

The exact boundary may move when a file has more configuration or interface
types. Use one broad disabled region rather than scattered switches when most
of the circuit needs hand alignment. Plain OCaml model files can keep the
formatter enabled unless manual layout is useful. Keep `.mli` files formatted
with the repository's `janestreet` profile.

A disabled region still needs consistent indentation and valid OCaml syntax.
The formatter checks only enabled regions; review disabled code by eye and
parse or build it after editing.

### Space between bindings

Leave a blank line after a function's `=` when the body has multiple stages.
For a multi-line `let ... in`, leave a blank line before the comment or binding
and after the `in`. A group of short related bindings can stay together.
Separate accessors and other independent one-line definitions with blank lines
when each has its own comment.

```ocaml
let step t ~push ~pop =

  (* Resolve the pre-edge pop. *)
  let popped, pop_result, after_pop =
    ...
  in

  (* Validate and append the offered byte. *)
  let push_result, entries =
    ...
  in

  { t with entries }, popped, push_result, pop_result
;;
```

### Alignment

Align `=` signs for consecutive related bindings, and align field names,
colons, values, or assignment operators in a multi-line record or statement
group. Keep each alignment local to one visual group.

```ocaml
let nonempty   = r.count.value <>:. 0 in
let pop_valid  = i.enable_i &: nonempty in
let pop_fire   = pop_valid &: i.pop_ready_i in
```

```ocaml
{ Shift_lane.I.clock_i = i.clock_i
; reset_i              = i.reset_i
; enable_i             = i.enable_i
}
```

A short record that fits on one line does not need alignment. Keep blank lines
between logical groups of fields when that helps distinguish control from
data or status.

### Muxes and other multi-argument expressions

Expand a `mux2` or larger mux when its condition and alternatives have
different meanings. Give the condition and each branch their own line; a short
comment may label each branch. Parentheses and indentation should make the
choice readable without mentally counting arguments.

```ocaml
let next_index index =
  mux2
    (* The final slot wraps to zero. *)
    (index ==:. depth - 1)
    (zero 4)
    (index +:. 1)
in
```

Compact muxes are fine when both alternatives are obvious. Do not expand an
expression solely to satisfy a template.

### The `compile` call

Put a brief explanatory comment just before `compile` describing its default
assignments, priority, and any hold or pulse behavior. Add short notes inside
the statement list at decisions a reader might misread, especially a reset,
enable, simultaneous handshake, or rejected operation.

```ocaml
(* Hold state by default; disabling drops queued bytes. Faults stay sticky
   until reset.
*)
compile
  [ r.count <-- r.count.value
  ; if_
      ~:(i.enable_i) (* discard queued entries *)
      [ r.count <--. 0 ]
      [ when_ (push_fire &: ~:pop_fire) [ r.count <-- r.count.value +:. 1 ] ]
  ]
```

The code order is significant: later `Always` assignments override earlier
ones. Comments should make that priority visible. Every `I_Regs` and
`I_Wires` variable still needs an assignment in `compile`, as explained in
[formatting_guide.md](formatting_guide.md), section 8.

## Verification

After changing comments or manual formatting, check that the file parses and
that comments still match the behavior. For behavior or interface changes, run
the affected tests and the build. `dune build @fmt` checks formatter-managed
regions but cannot judge the layout inside `[@@@ocamlformat "disable"]`.
