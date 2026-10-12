(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "transfer.ml" *)
(* The transfer descriptor as a typed value, with validation, before any opcode encoding.

   construction-plan.md section 3 asks for exactly this order: model descriptors as typed
   OCaml values first, validate pin conflicts and impossible phase combinations on issue,
   and only then design an encoding. Field names describe mechanisms - launch edge, sample
   edge, drive mask - so that SPI modes and UART framing stay in firmware builders.

   Scope note. This module is the descriptor and its rules. Executing one - shifting bits,
   driving the clock pin, underrun and overrun aborts - is P2.5, and deliberately absent:
   a machine that pretended to run a transfer would produce timing numbers nothing has
   measured. What exists now is enough to check that illegal descriptors are refused and
   that a legal one is latched unchanged at acceptance, which is the parameter-latching
   behaviour P1.1 asks for.
*)

open! Core
open! Kinds

(* The maximum shift length under study (construction-plan.md section 3). A sweep point,
   not a decision. *)
let max_bit_count = 32

module Pacing = struct
  (* Where the bit schedule comes from. [Internal] generates the clock on [clock_pin];
     [Observed_edge] follows an external one, which is how a target mode and UART
     start-bit alignment reuse the same lane (construction-plan.md section 3). *)
  type t =
    | Internal of { half_period : int }
    | Observed_edge of
        { pin : int
        ; edge : Edge.t
        }
  [@@deriving sexp, compare, equal]
end

type t =
  { direction : Direction.t
  ; (* 1..[max_bit_count]. *)
    bit_count : int
  ; bit_order : Bit_order.t
  ; (* Initial output preload: the word shifted out, and the source of the first bit
       placed on the wire before any launch edge. *)
    tx_value : int
  ; output_pin : int option
  ; input_pin : int option
  ; (* Absent when the pacing source supplies the clock externally. *)
    clock_pin : int option
  ; (* What the output and clock pins hold between transactions. *)
    idle_output : bool
  ; idle_clock : bool
  ; (* Cycles between acceptance and the first launch edge. [None] starts at the first
       opportunity; [Some n] requires n >= 1, the same rule timed commands follow. *)
    initial_delay : int option
  ; launch : Clock_phase.t
  ; sample : Clock_phase.t
  ; pacing : Pacing.t
  }
[@@deriving sexp, compare, equal]

(* Which pins the descriptor asks to drive. Input and pacing pins are observed, not
   driven, so they are not claimed: several consumers may watch one input. *)
let driven_mask t =
  let bit = function
    | None -> 0
    | Some pin -> 1 lsl pin
  in
  let output =
    match t.direction with
    | Tx_only | Duplex -> bit t.output_pin
    | Rx_only -> 0
  in
  output lor bit t.clock_pin
;;

let roles t =
  let role name pin = Option.map pin ~f:(fun pin -> name, pin) in
  let paced =
    match t.pacing with
    | Pacing.Internal _ -> None
    | Pacing.Observed_edge { pin; edge = _ } -> Some (Pin_role.Paced_edge, pin)
  in
  List.filter_opt
    [ role Pin_role.Output t.output_pin
    ; role Pin_role.Input t.input_pin
    ; role Pin_role.Clock t.clock_pin
    ; paced
    ]
;;

let check condition reason = if condition then Ok () else Error reason
let need role pin = check (Option.is_some pin) (Fault.Reject.Missing_pin role)
let forbid role pin = check (Option.is_none pin) (Fault.Reject.Unexpected_pin role)

let pin_in_range pin =
  match pin with
  | None -> Ok ()
  | Some pin -> check (Pin_bank.is_valid_pin pin) (Fault.Reject.Pin_out_of_range pin)
;;

(* A pin may carry only one role, with one deliberate exception: a half-duplex open-drain
   bus drives and samples the same wire, and construction-plan.md section 3 requires
   sampling the actual input while driving. So Output and Input may coincide; no other
   pair may. In particular a lane may not observe its own generated clock. *)
let shared_roles_allowed first second =
  match (first : Pin_role.t), (second : Pin_role.t) with
  | Output, Input | Input, Output -> true
  | _ -> false
;;

let distinct_roles t =
  let assigned = roles t in
  let collision =
    List.find_map assigned ~f:(fun (first, pin) ->
      List.find_map assigned ~f:(fun (second, other) ->
        if pin = other
           && Pin_role.compare first second < 0
           && not (shared_roles_allowed first second)
        then Some (pin, first, second)
        else None))
  in
  match collision with
  | None -> Ok ()
  | Some (pin, first, second) -> Error (Fault.Reject.Duplicate_pin { pin; first; second })
;;

let required_pins t =
  match t.direction with
  | Tx_only ->
    Result.bind (need Pin_role.Output t.output_pin) ~f:(fun () ->
      forbid Pin_role.Input t.input_pin)
  | Rx_only ->
    Result.bind (need Pin_role.Input t.input_pin) ~f:(fun () ->
      forbid Pin_role.Output t.output_pin)
  | Duplex ->
    Result.bind (need Pin_role.Output t.output_pin) ~f:(fun () ->
      need Pin_role.Input t.input_pin)
;;

let validate_pacing t =
  match t.pacing with
  | Pacing.Internal { half_period } ->
    (* Generating a bit schedule without a pin to show it on is legal - a UART bit period
       has no clock wire - so [clock_pin] stays optional here. *)
    check (half_period >= 1) (Fault.Reject.Half_period_out_of_range half_period)
  | Pacing.Observed_edge { pin; edge = _ } ->
    (* A lane cannot both generate and follow a clock. *)
    Result.bind (forbid Pin_role.Clock t.clock_pin) ~f:(fun () -> pin_in_range (Some pin))
;;

(* Structural validation: everything decidable from the descriptor alone. Ownership is not
   checked here, because it depends on the machine; [Machine] adds it at acceptance.

   The checks run in a fixed order and stop at the first failure, so a descriptor with two
   problems always reports the same one. *)
let validate t =
  let ( >>= ) result f = Result.bind result ~f in
  check
    (t.bit_count >= 1 && t.bit_count <= max_bit_count)
    (Fault.Reject.Bit_count_out_of_range t.bit_count)
  >>= fun () ->
  (* The preload may not carry bits the transfer will never shift out. *)
  check
    (t.tx_value >= 0 && t.tx_value < 1 lsl t.bit_count)
    (Fault.Reject.Data_out_of_range t.tx_value)
  >>= fun () ->
  pin_in_range t.output_pin
  >>= fun () ->
  pin_in_range t.input_pin
  >>= fun () ->
  pin_in_range t.clock_pin
  >>= fun () ->
  required_pins t
  >>= fun () ->
  distinct_roles t
  >>= fun () ->
  (* A bit launched and sampled on the same edge has no setup time. This is the
     "impossible phase combination" the construction plan names. *)
  check
    (not (Clock_phase.equal t.launch t.sample))
    (Fault.Reject.Launch_equals_sample t.launch)
  >>= fun () ->
  (match t.initial_delay with
   | None -> Ok ()
   | Some delay -> check (delay >= 1) Fault.Reject.Zero_delay)
  >>= fun () -> validate_pacing t
;;
