(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "shift_engine.ml" *)
(* An independent cycle model of one transfer descriptor. It uses typed transfer
   values and integer pin masks, with no Hardcaml or synthesized helper logic. *)

open! Core
open! Kinds

type t =
  { descriptor : Transfer.t option
  ; armed : bool
  ; active : bool
  ; phase : int
  ; index : int
  ; remaining : int
  ; rx : int
  ; rx_data : int
  ; pins : int
  ; output_enable : int
  ; claim : int
  ; done_ : bool
  ; rx_valid : bool
  ; rejected : bool
  ; underrun : bool
  ; overrun : bool
  }
[@@deriving sexp_of]

let idle =
  { descriptor = None
  ; armed = false
  ; active = false
  ; phase = 0
  ; index = 0
  ; remaining = 0
  ; rx = 0
  ; rx_data = 0
  ; pins = 0
  ; output_enable = 0
  ; claim = 0
  ; done_ = false
  ; rx_valid = false
  ; rejected = false
  ; underrun = false
  ; overrun = false
  }
;;

let bit n = 1 lsl n
let pin_mask = function None -> 0 | Some pin -> bit pin
let at word index = word land bit index <> 0
let set word mask value = if value then word lor mask else word land lnot mask
let ordinal descriptor index =
  match descriptor.Transfer.bit_order with
  | Lsb_first -> index
  | Msb_first -> descriptor.bit_count - 1 - index
;;

let phase_kind descriptor phase =
  let high = if phase = 0 then not descriptor.Transfer.idle_clock else descriptor.idle_clock in
  if high then Clock_phase.On_rising else On_falling
;;

let preload descriptor =
  let output = pin_mask descriptor.Transfer.output_pin in
  let clock = pin_mask descriptor.clock_pin in
  let output_value =
    if not (Direction.equal descriptor.direction Rx_only)
    then (
      let first =
        if Clock_phase.equal descriptor.launch (phase_kind descriptor 1)
        then at descriptor.tx_value (ordinal descriptor 0)
        else descriptor.idle_output
      in
      if first then output else 0)
    else 0
  in
  let clock_value = if descriptor.idle_clock then clock else 0 in
  output_value lor clock_value
;;

let start t descriptor =
  let claim = Transfer.driven_mask descriptor in
  let remaining =
    match descriptor.initial_delay, descriptor.pacing with
    | Some delay, _ -> delay
    | None, Internal { half_period } -> half_period
    | None, Observed_edge _ -> 0
  in
  { t with
    armed = false
  ; active = true
  ; phase = 0
  ; index = 0
  ; remaining
  ; rx = 0
  ; pins = preload descriptor
  ; output_enable = claim
  ; claim
  }
;;

let release t =
  { t with active = false; armed = false; pins = 0; output_enable = 0; claim = 0 }
;;

let advance t descriptor ~pin_in ~rx_ready =
  let phase = t.phase in
  let kind = phase_kind descriptor phase in
  let output = pin_mask descriptor.output_pin in
  let clock = pin_mask descriptor.clock_pin in
  let pins =
    if clock = 0 then t.pins else set t.pins clock (if descriptor.idle_clock then phase = 1 else phase = 0)
  in
  let next_index = if phase = 1 then t.index + 1 else t.index in
  let pins =
    if output <> 0
       && Clock_phase.equal descriptor.launch kind
       && next_index < descriptor.bit_count
    then set pins output (at descriptor.tx_value (ordinal descriptor next_index))
    else pins
  in
  let rx =
    if not (Direction.equal descriptor.direction Tx_only)
       && Clock_phase.equal descriptor.sample kind
    then (
      let position = ordinal descriptor t.index in
      set t.rx (bit position) (at pin_in (Option.value_exn descriptor.input_pin)))
    else t.rx
  in
  let finishing = phase = 1 && t.index + 1 = descriptor.bit_count in
  if finishing
  then (
    let t = release { t with rx } in
    if Direction.equal descriptor.direction Rx_only
       || Direction.equal descriptor.direction Duplex
    then if rx_ready then { t with done_ = true; rx_valid = true; rx_data = rx }
    else { t with overrun = true }
    else { t with done_ = true })
  else
    { t with
      pins
    ; rx
    ; phase = 1 - phase
    ; index = next_index
    ; remaining =
        (match descriptor.pacing with
         | Internal { half_period } -> half_period
         | Observed_edge _ -> 0)
    }
;;

let step
      t
      ~enable
      ~abort
      ~command
      ~start_event
      ~observed_edge
      ~pin_in
      ~occupied
      ~tx_valid
      ~rx_ready
  =
  let t =
    { t with done_ = false; rx_valid = false; rejected = false; underrun = false; overrun = false }
  in
  if not enable || abort
  then release t
  else (
    match command with
    | Some (descriptor, arm) when not t.active && not t.armed ->
      let collision = Transfer.driven_mask descriptor land occupied <> 0 in
      (match Transfer.validate descriptor with
       | Error _ -> { t with rejected = true }
       | Ok () when collision && not arm -> { t with rejected = true }
       | Ok () when not tx_valid && not (Direction.equal descriptor.direction Rx_only) ->
         { t with underrun = true }
       | Ok () ->
         if arm
         then { t with descriptor = Some descriptor; armed = true }
         else start { t with descriptor = Some descriptor } descriptor)
    | _ when t.armed && start_event ->
      let descriptor = Option.value_exn t.descriptor in
      if Transfer.driven_mask descriptor land occupied <> 0
      then { t with armed = false; rejected = true }
      else start t descriptor
    | _ when t.active ->
      let descriptor = Option.value_exn t.descriptor in
      let edge =
        match descriptor.pacing with
        | Internal _ -> t.remaining = 1
        | Observed_edge _ -> observed_edge
      in
      if edge
      then advance t descriptor ~pin_in ~rx_ready
      else (
        match descriptor.pacing with
        | Internal _ -> { t with remaining = t.remaining - 1 }
        | Observed_edge _ -> t)
    | _ -> t)
;;
