(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "descriptor.ml" *)
(* The transfer descriptor as firmware writes it: nine writable fields, the bit layout of
   the one packed field, and how a field value names a pin or a pacing source.

   WHY THIS IS SPECIFICATION AND NOT MODEL. construction-plan.md section 4 allows that
   "configuration can take several instructions". This module says how many, by naming the
   pieces, and every number in it is programmer-visible: a [Config] instruction carries a
   field index, and the value it writes is interpreted by the rules below. An RTL decoder
   and the reference model must agree about all of it, so it is written once, here.

   WHAT IS NOT HERE. Validation, and the typed descriptor the machine latches. A
   descriptor is checked at acceptance by model/transfer.ml, which is where an impossible
   phase combination or a pin used twice is refused; the control core turns a [Parsed.t]
   into that typed value. Nothing in this module rejects anything, deliberately: an
   unconfigured descriptor reaches acceptance as one with no pins and a zero half period
   and comes back refused, rather than being quietly repaired here.
*)

open! Core
open! Kinds

(* One writable piece of the descriptor. [Control] is the one packed field: everything
   that is a choice between two or three alternatives travels together, so a descriptor
   costs nine writes rather than fourteen. *)
module Field = struct
  type t =
    | Control
    | Bit_count
    | Tx_value
    | Output_pin
    | Input_pin
    | Clock_pin
    | Initial_delay
    | Half_period
    | Pacing
  [@@deriving sexp, compare, equal, enumerate]

  let count = List.length all
  let index t = Enum.index all ~equal t
  let of_index index = Enum.of_index all index
end

(* Nine, one past the last pin: a pin field means "pin n" for every value the bank has, so
   "no pin" has to be a value it does not. Zero could not serve, because then a descriptor
   that never wrote a pin field would quietly drive pin zero. *)
let no_pin = Pins.count + 1

module Control = struct
  (* Bits, low to high. Seven of them, which is one more than a sixteen-bit [Config]
     instruction's inline immediate holds, so a control write costs an extension word.
     That is deliberate and measured rather than overlooked: widening the inline field
     would have to come out of the field index beside it. *)
  let direction = 0, 2
  let bit_order = 2, 1
  let idle_output = 3, 1
  let idle_clock = 4, 1
  let launch = 5, 1
  let sample = 6, 1
  let bits = 7
  let field value (pos, width) = (value lsr pos) land ((1 lsl width) - 1)
  let flag value spec = field value spec = 1

  (* A phase bit set means the falling edge. *)
  let phase value spec = if flag value spec then Clock_phase.On_falling else On_rising

  let parse_direction value =
    match field value direction with
    | 0 -> Direction.Tx_only
    | 1 -> Direction.Rx_only
    | _ -> Direction.Duplex
  ;;

  (* The control word for a set of choices, so that a firmware builder never writes a
     magic number and the bit positions above have exactly one reader. *)
  let of_choices
    ~(direction : Direction.t)
    ~(bit_order : Bit_order.t)
    ~idle_output:idle_output_value
    ~idle_clock:idle_clock_value
    ~(launch : Clock_phase.t)
    ~(sample : Clock_phase.t)
    =
    let put (pos, _) value = value lsl pos in
    let bool (pos, _) condition = Bool.to_int condition lsl pos in
    let falling : Clock_phase.t -> bool = function
      | On_falling -> true
      | On_rising -> false
    in
    put
      (0, 2)
      (match direction with
       | Tx_only -> 0
       | Rx_only -> 1
       | Duplex -> 2)
    lor bool
          (2, 1)
          (match bit_order with
           | Msb_first -> true
           | Lsb_first -> false)
    lor bool (3, 1) idle_output_value
    lor bool (4, 1) idle_clock_value
    lor bool (5, 1) (falling launch)
    lor bool (6, 1) (falling sample)
  ;;
end

module Pacing = struct
  (* Zero is the engine's own schedule; any other value selects an observed pin and edge,
     encoded as 1 + pin * 3 + the edge's position in [Edge.all]. One field rather than two
     because a descriptor that costs nine writes should not cost ten to say the ordinary
     thing, and internal pacing is the ordinary thing. *)
  type t =
    | Internal
    | Observed_edge of
        { pin : int
        ; edge : Edge.t
        }
  [@@deriving sexp, compare, equal]

  let edges = List.length Edge.all
  let internal = 0
  let observed ~pin ~edge = 1 + (pin * edges) + Enum.index Edge.all ~equal:Edge.equal edge

  let parse value =
    if value = 0
    then Internal
    else (
      let index = value - 1 in
      let edge =
        Option.value (Enum.of_index Edge.all (index % edges)) ~default:Edge.Rising
      in
      Observed_edge { pin = index / edges; edge })
  ;;
end

(* The nine fields as written, before anything interprets them. Every field zero is the
   state after reset and is deliberately not a legal descriptor. *)
type t =
  { control : int
  ; bit_count : int
  ; tx_value : int
  ; output_pin : int
  ; input_pin : int
  ; clock_pin : int
  ; initial_delay : int
  ; half_period : int
  ; pacing : int
  }
[@@deriving sexp, compare, equal]

let cleared =
  { control = 0
  ; bit_count = 0
  ; tx_value = 0
  ; output_pin = no_pin
  ; input_pin = no_pin
  ; clock_pin = no_pin
  ; initial_delay = 0
  ; half_period = 0
  ; pacing = 0
  }
;;

let set t (field : Field.t) value =
  match field with
  | Control -> { t with control = value }
  | Bit_count -> { t with bit_count = value }
  | Tx_value -> { t with tx_value = value }
  | Output_pin -> { t with output_pin = value }
  | Input_pin -> { t with input_pin = value }
  | Clock_pin -> { t with clock_pin = value }
  | Initial_delay -> { t with initial_delay = value }
  | Half_period -> { t with half_period = value }
  | Pacing -> { t with pacing = value }
;;

module Parsed = struct
  (* The descriptor with every field read according to the rules above, and still with no
     judgement passed on it. The control core turns one of these into the typed descriptor
     the machine validates at acceptance. *)
  type t =
    { direction : Direction.t
    ; bit_count : int
    ; bit_order : Bit_order.t
    ; tx_value : int
    ; output_pin : int option
    ; input_pin : int option
    ; clock_pin : int option
    ; idle_output : bool
    ; idle_clock : bool
    ; initial_delay : int option
    ; launch : Clock_phase.t
    ; sample : Clock_phase.t
    ; half_period : int
    ; pacing : Pacing.t
    }
  [@@deriving sexp, compare, equal]
end

(* A pin field names a pin only if the bank has one by that number; anything else,
   [no_pin] included, means the role is unused. *)
let pin_option value = if Pins.is_valid_pin value then Some value else None

let parse t : Parsed.t =
  { direction = Control.parse_direction t.control
  ; bit_count = t.bit_count
  ; bit_order =
      (if Control.flag t.control Control.bit_order then Msb_first else Lsb_first)
  ; tx_value = t.tx_value
  ; output_pin = pin_option t.output_pin
  ; input_pin = pin_option t.input_pin
  ; clock_pin = pin_option t.clock_pin
  ; idle_output = Control.flag t.control Control.idle_output
  ; idle_clock = Control.flag t.control Control.idle_clock
  ; initial_delay = (if t.initial_delay = 0 then None else Some t.initial_delay)
  ; launch = Control.phase t.control Control.launch
  ; sample = Control.phase t.control Control.sample
  ; half_period = t.half_period
  ; pacing = Pacing.parse t.pacing
  }
;;
