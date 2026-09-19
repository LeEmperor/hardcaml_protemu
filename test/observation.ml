(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "observation.ml" *)
(* What a testbench saw at one edge, and whether it saw anything at all.

   Three states, kept apart on purpose (verification.md section 5). [Unavailable] is an
   adapter limitation: this side cannot expose the thing at all, so there is nothing to
   compare. [Unspecified] is a contract statement: the value exists on the wire but the
   contract does not say what it is, so a difference is permitted. [Defined] is a value
   the contract fixes, and a defined zero is an ordinary value rather than "nothing".

   Collapsing the three is the failure this module prevents. An adapter that reported a
   missing signal as zero would turn a silent hole in the comparison into a passing test,
   and a contract's "don't care" compared as an ordinary value would fail for no reason.

   A test declares which observations are [required]. A required observation that is not
   [Defined] on both sides is an error rather than a skipped comparison; an observation
   that is not required and is [Unavailable] on either side is skipped and recorded as
   skipped. Everything else must agree in validity first and in value second.
*)

open! Core

type t =
  | Unavailable
  | Unspecified
  | Defined of int
[@@deriving sexp_of, compare, equal]

let bool b = Defined (if b then 1 else 0)
let int n = Defined n

(* A simulator port. The width is the port's; the value is read as an unsigned int, which
   is what every observation in this repository's primitives fits in. *)
let port signal = Defined (Hardcaml.Bits.to_int_trunc !signal)

(* A value the contract fixes only when [defined] holds; the [Unspecified] case is the
   point of the helper, so callers do not reach for a placeholder value. *)
let when_defined ~defined value = if defined then Defined value else Unspecified

let is_defined = function
  | Defined _ -> true
  | Unavailable | Unspecified -> false
;;

(* Printed in a failure report, where the three cases have to stay apart: "unspecified" and
   "0" must not read the same. *)
let to_string = function
  | Unavailable -> "unavailable"
  | Unspecified -> "unspecified"
  | Defined value -> Int.to_string value
;;

(* Named observations in declaration order. The order is the order the checker reports a
   first mismatch in, so an adapter should list the observations a reader would look at
   first: the handshake, then the data, then the status. Names are unique within a set. *)
module Set = struct
  type nonrec t = (string * t) list [@@deriving sexp_of, compare, equal]

  let find t name = List.Assoc.find t name ~equal:String.equal
  let names t = List.map t ~f:fst

  (* Printed beside a mismatch and in a directed transcript, so it stays on one line:
     [name=value] for a defined observation, [name=?] and [name=-] for the other two. *)
  let to_string t =
    List.map t ~f:(fun (name, observation) ->
      match observation with
      | Defined value -> [%string "%{name}=%{value#Int}"]
      | Unspecified -> [%string "%{name}=?"]
      | Unavailable -> [%string "%{name}=-"])
    |> String.concat ~sep:" "
  ;;
end

(* Why two observation sets did not agree. [Value] is the ordinary mismatch; everything
   else is a statement about validity, which is checked before value. *)
module Reason = struct
  type t =
    | Value
    | Validity
    | Required_unavailable
    | Required_unspecified
    | Undeclared
  [@@deriving sexp_of, compare, equal]
end

module Difference = struct
  type nonrec t =
    { observation : string
    ; reason : Reason.t
    ; expected : t (* the independent model *)
    ; actual : t (* the design under test *)
    }
  [@@deriving sexp_of, compare, equal]
end

(* The first disagreement between the model's observations and the DUT's, in the model's
   declaration order, or [None] when they agree.

   Both sides must declare the same names: an adapter that quietly stopped publishing an
   observation would otherwise shrink the comparison without failing. A name on one side
   only is [Undeclared] and is reported before any value is looked at. *)
let first_difference ~required ~(model : Set.t) ~(dut : Set.t) =
  (* Plain lists: an observation set is a dozen names at most, and [Set] here is this
     module's own, not [Core.Set]. *)
  let missing_from ~these ~those =
    List.find these ~f:(fun name -> not (List.mem those name ~equal:String.equal))
  in
  let model_names = Set.names model
  and dut_names = Set.names dut in
  let undeclared =
    Option.first_some
      (missing_from ~these:model_names ~those:dut_names)
      (missing_from ~these:dut_names ~those:model_names)
  in
  match undeclared with
  | Some observation ->
    Some
      { Difference.observation
      ; reason = Undeclared
      ; expected = Option.value (Set.find model observation) ~default:Unavailable
      ; actual = Option.value (Set.find dut observation) ~default:Unavailable
      }
  | None ->
    List.find_map model ~f:(fun (observation, expected) ->
      let actual = Option.value_exn (Set.find dut observation) in
      let difference reason = Some { Difference.observation; reason; expected; actual } in
      let is_required = List.mem required observation ~equal:String.equal in
      match expected, actual with
      (* A required observation must be comparable on both sides. *)
      | (Unavailable, _ | _, Unavailable) when is_required ->
        difference Required_unavailable
      | (Unspecified, _ | _, Unspecified) when is_required ->
        difference Required_unspecified
      (* Not required, and one side cannot expose it: nothing to compare. *)
      | Unavailable, _ | _, Unavailable -> None
      | Unspecified, Unspecified -> None
      | Unspecified, Defined _ | Defined _, Unspecified -> difference Validity
      | Defined expected, Defined actual ->
        if expected = actual then None else difference Value)
;;
