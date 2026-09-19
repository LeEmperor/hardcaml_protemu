(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "pin_bank_testbench.ml" *)
(* The P2.1 pin bank described once for the shared harness.

   This is the first block to go through [Env] (phase_plan.md P1.6). It is deliberately
   the smallest one: eight registered pins, masked commits, exclusive drive ownership and
   a sticky conflict bit, with no internal sequencing to get in the way of reading the
   conventions. A directed expect test and a bounded Quickcheck run both use what is here,
   and neither adds a runner of its own.

   Where the independence lies. The bank's state - value, output enable, and which owner
   holds which pins - comes from [Protemu_f_model.Pin_bank], which has no Hardcaml
   dependency and was written from construction-plan.md section 3 rather than from
   [Hardcaml_protemu.Pin_bank]. What that module does not own is the interface around it:
   the port offers up to three requests per edge and accepts at most one, refusal is a
   one-edge [rejected] pulse, and an ownership refusal also sets a sticky [conflict] bit.
   Those are properties of this block's port contract, so [F_model] below states them
   once, from the contract. It calls nothing in [lib/].

   What the design does not expose. The model knows why a request was refused; the RTL
   publishes only that one was. That is recorded as [reject_reason], [Unavailable] on the
   design's side, rather than dropped: it is an observation the comparison is skipping,
   and listing it in [required_post_edge] is the one change that would make the RTL's
   silence a failure instead of a hole.
*)

open! Core
open! Hardcaml
open! Hardcaml_protemu
module Kinds = Protemu_isa.Kinds
module Pins = Protemu_isa.Pins
module Reference = Protemu_f_model.Pin_bank
module Pin_sim = Cyclesim.With_interface (Pin_bank.I) (Pin_bank.O)

let bits width n = Bits.of_int_trunc ~width n

let check label signal expected =
  [%test_result: int] ~message:label ~expect:expected (Bits.to_int_trunc !signal)
;;

let name = "pin_bank"

(* A refusal reason as a small code, so the model can publish one through an observation.
   Only the reasons this block's port can produce are listed. *)
module Reject_code = struct
  let accepted = 0
  let multiple_requests = 1
  let pin_owned = 2
  let pin_not_owned = 3
  let out_of_range = 4

  (* An eight-bit mask port cannot name a ninth pin and the port offers no other refusable
     operation, so the last two are unreachable through this interface. They are listed
     rather than folded into one code: a refusal the port contract does not predict should
     be visible as itself in a report. *)
  let unexpected = 5

  let of_reject (reject : Protemu_f_model.Fault.Reject.t) =
    match reject with
    | Pin_owned _ -> pin_owned
    | Pin_not_owned _ -> pin_not_owned
    | Pin_out_of_range _ -> out_of_range
    | _ -> unexpected
  ;;
end

(* A fault injected into the reference, for the failure-reproduction exercise of
   verification.md section 4. It exists so a controlled mismatch can be produced without
   an intentionally wrong test in the suite and without touching [lib/] or [f_model/]:
   [Ignore_open_drain] makes this environment expect a driven high where the open-drain
   rule says the pin is released, which the design correctly refuses to do. *)
module Defect = struct
  type t =
    | No_defect
    | Ignore_open_drain
  [@@deriving sexp_of, compare, equal, enumerate]
end

module Config = struct
  type t =
    { (* Which engine number the non-software owner uses. The bank's rules are per owner,
         not per engine, so one engine is enough to exercise them. *)
      engine : int
    ; defect : Defect.t
    }
  [@@deriving sexp_of]

  let default = { engine = 0; defect = No_defect }
  let with_defect defect = { default with defect }
end

(* One edge's stimulus, shaped like the port rather than like an intention: the three
   request channels are independent, so a scenario can offer two at once and the "at most
   one request per edge" rule is exercised rather than assumed away. *)
module Item = struct
  module Ownership = struct
    type t =
      { engine : bool
      ; mask : int
      }
    [@@deriving sexp_of]
  end

  module Write_request = struct
    type t =
      { engine : bool
      ; mask : int
      ; value : int
      ; output_enable : int
      ; open_drain : bool
      }
    [@@deriving sexp_of]
  end

  type t =
    { reset : bool [@sexp.bool]
    ; abort : bool [@sexp.bool]
    ; enable : bool
    ; claim : Ownership.t option [@sexp.option]
    ; release : Ownership.t option [@sexp.option]
    ; write : Write_request.t option [@sexp.option]
    }
  [@@deriving sexp_of]

  let idle =
    { reset = false
    ; abort = false
    ; enable = true
    ; claim = None
    ; release = None
    ; write = None
    }
  ;;

  let reset = { idle with reset = true }
  let disabled = { idle with enable = false }
  let abort = { idle with abort = true }
  let claim ~engine ~mask = { idle with claim = Some { Ownership.engine; mask } }
  let release ~engine ~mask = { idle with release = Some { Ownership.engine; mask } }

  let write ?(open_drain = false) ~engine ~mask ~value ~output_enable () =
    { idle with
      write = Some { Write_request.engine; mask; value; output_enable; open_drain }
    }
  ;;

  (* A second request added to an item that already carries one. The port allows it and
     refuses it; a scenario has to be able to say so. *)
  let also_write ~engine ~mask ~value ~output_enable item =
    { item with
      write =
        Some { Write_request.engine; mask; value; output_enable; open_drain = false }
    }
  ;;

  let requests t =
    List.count
      [ Option.is_some t.claim; Option.is_some t.release; Option.is_some t.write ]
      ~f:Fn.id
  ;;
end

(* The observation names, written once. Both sides build their sets from these, so an
   adapter cannot drift into publishing a name the other side does not. *)
let held_names =
  [ "held.pins"
  ; "held.pin_oe"
  ; "held.software_claim"
  ; "held.engine_claim"
  ; "held.rejected"
  ; "held.conflict"
  ]
;;

let registered_names =
  [ "pins"; "pin_oe"; "software_claim"; "engine_claim"; "rejected"; "conflict" ]
;;

let bus_name pin = [%string "bus%{pin#Int}"]

(* What the board would see: a pin's level is defined only while this block drives it.
   Released pins are [Unspecified] here because the level then comes from a pull-up, which
   is outside the bank's contract - reporting a released pin as zero would be a defined
   value the design never promised. *)
let bus_observations ~value ~output_enable =
  List.init Pins.count ~f:(fun pin ->
    let driven = Pins.bit output_enable pin in
    bus_name pin, Observation.when_defined ~defined:driven ((value lsr pin) land 1))
;;

let held_observations
  ~value
  ~output_enable
  ~software_claim
  ~engine_claim
  ~rejected
  ~conflict
  =
  [ "held.pins", Observation.int value
  ; "held.pin_oe", Observation.int output_enable
  ; "held.software_claim", Observation.int software_claim
  ; "held.engine_claim", Observation.int engine_claim
  ; "held.rejected", Observation.bool rejected
  ; "held.conflict", Observation.bool conflict
  ]
;;

let post_observations
  ~value
  ~output_enable
  ~software_claim
  ~engine_claim
  ~rejected
  ~conflict
  ~reject_reason
  =
  [ "pins", Observation.int value
  ; "pin_oe", Observation.int output_enable
  ; "software_claim", Observation.int software_claim
  ; "engine_claim", Observation.int engine_claim
  ; "rejected", Observation.bool rejected
  ; "conflict", Observation.bool conflict
  ; "reject_reason", reject_reason
  ]
  @ bus_observations ~value ~output_enable
;;

(* The Hardcaml side. Nothing here advances the simulation except the runner's two calls:
   [settle] is the pre-edge combinational update, [edge] is the edge and the update after
   it. Splitting [Cyclesim.cycle] this way is what makes a pre-edge observation possible. *)
module Dut = struct
  module Sim = Cyclesim.With_interface (Pin_bank.I) (Pin_bank.O)

  type t =
    { sim : Sim.t
    ; inputs : Bits.t ref Pin_bank.I.t
    ; before : Bits.t ref Pin_bank.O.t
    ; after : Bits.t ref Pin_bank.O.t
    }

  let create (_ : Config.t) =
    let sim = Sim.create (Pin_bank.create (Scope.create ~flatten_design:true ())) in
    { sim
    ; inputs = Cyclesim.inputs sim
    ; before = Cyclesim.outputs ~clock_edge:Hardcaml.Side.Before sim
    ; after = Cyclesim.outputs ~clock_edge:Hardcaml.Side.After sim
    }
  ;;

  let flag b = if b then Bits.vdd else Bits.gnd
  let bits value = Bits.of_int_trunc ~width:Pins.count value
  let port signal = Bits.to_int_trunc !signal

  (* Every port is written on every edge. A driver that left a port at its previous value
     would make a scenario's meaning depend on the item before it. *)
  let drive t (item : Item.t) =
    let i = t.inputs in
    i.reset_i := flag item.reset;
    i.enable_i := flag item.enable;
    i.abort_i := flag item.abort;
    let claim =
      Option.value item.claim ~default:{ Item.Ownership.engine = false; mask = 0 }
    in
    i.claim_valid_i := flag (Option.is_some item.claim);
    i.claim_engine_i := flag claim.engine;
    i.claim_mask_i := bits claim.mask;
    let release =
      Option.value item.release ~default:{ Item.Ownership.engine = false; mask = 0 }
    in
    i.release_valid_i := flag (Option.is_some item.release);
    i.release_engine_i := flag release.engine;
    i.release_mask_i := bits release.mask;
    let write =
      Option.value
        item.write
        ~default:
          { Item.Write_request.engine = false
          ; mask = 0
          ; value = 0
          ; output_enable = 0
          ; open_drain = false
          }
    in
    i.write_valid_i := flag (Option.is_some item.write);
    i.write_engine_i := flag write.engine;
    i.write_mask_i := bits write.mask;
    i.write_value_i := bits write.value;
    i.write_oe_i := bits write.output_enable;
    i.write_open_drain_i := flag write.open_drain
  ;;

  let settle t =
    Cyclesim.cycle_check t.sim;
    Cyclesim.cycle_before_clock_edge t.sim
  ;;

  let edge t =
    Cyclesim.cycle_at_clock_edge t.sim;
    Cyclesim.cycle_after_clock_edge t.sim
  ;;

  let pre_edge t =
    let o = t.before in
    held_observations
      ~value:(port o.pins_o)
      ~output_enable:(port o.pin_oe_o)
      ~software_claim:(port o.software_claim_o)
      ~engine_claim:(port o.engine_claim_o)
      ~rejected:(port o.rejected_o = 1)
      ~conflict:(port o.conflict_o = 1)
  ;;

  let post_edge t =
    let o = t.after in
    post_observations
      ~value:(port o.pins_o)
      ~output_enable:(port o.pin_oe_o)
      ~software_claim:(port o.software_claim_o)
      ~engine_claim:(port o.engine_claim_o)
      ~rejected:(port o.rejected_o = 1)
      ~conflict:(port o.conflict_o = 1)
        (* The design reports that a request was refused, not why. *)
      ~reject_reason:Observation.Unavailable
  ;;
end

(* The independent reference. [bank] is [Protemu_f_model.Pin_bank]; the three fields
   beside it are the port contract this environment owns. *)
module F_model = struct
  type t =
    { config : Config.t
    ; bank : Reference.t
    ; rejected : bool
    ; conflict : bool
    ; reason : int
    }

  let create config =
    { config
    ; bank = Reference.released
    ; rejected = false
    ; conflict = false
    ; reason = Reject_code.accepted
    }
  ;;

  let owner t ~engine =
    if engine then Kinds.Owner.Engine t.config.engine else Kinds.Owner.Software
  ;;

  let claim_masks t =
    ( Reference.mask_owned_by t.bank ~owner:Kinds.Owner.Software
    , Reference.mask_owned_by t.bank ~owner:(Kinds.Owner.Engine t.config.engine) )
  ;;

  (* Did either of this item's drive requests name a pin some other owner holds? This is a
     question about what was offered, not about what was accepted, which is what makes the
     sticky conflict bit survive an edge refused for another reason. A release is not
     asking to drive anything, so it is not counted. *)
  let reaches_another_owner t (item : Item.t) =
    let touches ~engine ~mask =
      Option.is_some (Reference.conflicting_pin t.bank ~owner:(owner t ~engine) ~mask)
    in
    let claim =
      Option.value_map item.claim ~default:false ~f:(fun claim ->
        touches ~engine:claim.engine ~mask:claim.mask)
    in
    let write =
      Option.value_map item.write ~default:false ~f:(fun write ->
        touches ~engine:write.engine ~mask:write.mask)
    in
    claim || write
  ;;

  (* Refused: the pulse is set for this edge and the bank is untouched. An ownership
     refusal is also a sticky conflict; a release of a pin the owner never held is
     ordinary flow control and is not. *)
  let refuse t ~reason ~sticky =
    { t with rejected = true; reason; conflict = t.conflict || sticky }
  ;;

  let accept t bank = { t with bank; rejected = false; reason = Reject_code.accepted }

  let apply_result t result =
    match result with
    | Ok bank -> accept t bank
    | Error reject ->
      let reason = Reject_code.of_reject reject in
      refuse t ~reason ~sticky:(reason = Reject_code.pin_owned)
  ;;

  let edge t (item : Item.t) =
    (* Reset clears everything, including the sticky conflict. Disable and abort release
       the pins and drop every claim but leave the conflict bit alone: it records that a
       conflict happened, and aborting is not an acknowledgement. *)
    if item.reset
    then
      { t with
        bank = Reference.released
      ; rejected = false
      ; conflict = false
      ; reason = Reject_code.accepted
      }
    else if (not item.enable) || item.abort
    then
      { t with
        bank = Reference.released
      ; rejected = false
      ; reason = Reject_code.accepted
      }
    else if Item.requests item > 1
    then
      (* Two requests at one edge leave ownership ambiguous, so both are refused. The
         sticky bit is still set if either of them reached for a pin another owner holds:
         it records that software went somewhere it may not, and losing that because the
         same edge was also malformed would make the status depend on an unrelated fault.
         The harness found this case; see the P1.6 note in docs/verification.md. *)
      { (refuse t ~reason:Reject_code.multiple_requests ~sticky:false) with
        conflict = t.conflict || reaches_another_owner t item
      }
    else (
      match item.claim, item.release, item.write with
      | None, None, None -> accept t t.bank
      | Some claim, _, _ ->
        apply_result
          t
          (Reference.claim t.bank ~owner:(owner t ~engine:claim.engine) ~mask:claim.mask)
      | _, Some release, _ ->
        apply_result
          t
          (Reference.release
             t.bank
             ~owner:(owner t ~engine:release.engine)
             ~mask:release.mask)
      | _, _, Some write ->
        (* Open drain drives low or releases; it can never express a driven high. The
           injected defect forgets exactly that. *)
        let value =
          match write.open_drain, t.config.defect with
          | false, _ -> write.value
          | true, Ignore_open_drain -> write.value
          | true, No_defect -> 0
        in
        apply_result
          t
          (Reference.commit
             t.bank
             { Reference.Write.mask = write.mask
             ; value
             ; output_enable = write.output_enable
             }
             ~owner:(owner t ~engine:write.engine)))
  ;;

  (* This block has no combinational acceptance output: every port that says anything is
     registered. The pre-edge check therefore asserts the other half of that statement -
     that offering a request changes no output before the edge - which is what a
     combinational path from a request to a pin would break. *)
  let pre_edge t (_ : Item.t) =
    let software_claim, engine_claim = claim_masks t in
    held_observations
      ~value:t.bank.value
      ~output_enable:t.bank.output_enable
      ~software_claim
      ~engine_claim
      ~rejected:t.rejected
      ~conflict:t.conflict
  ;;

  let post_edge t =
    let software_claim, engine_claim = claim_masks t in
    post_observations
      ~value:t.bank.value
      ~output_enable:t.bank.output_enable
      ~software_claim
      ~engine_claim
      ~rejected:t.rejected
      ~conflict:t.conflict
      ~reject_reason:(Observation.int t.reason)
  ;;
end

(* Pin-to-item monitor. It reads observations and nothing else: it does not know what the
   scenario asked for, so a refused write cannot be reported as a commit.

   Two streams. "pins" is the driven bus, reconstructed from the per-pin observations, so
   a released pin contributes nothing rather than a zero. "ownership" is the claim spans,
   with [Start] and [End] at the edges where an owner acquires and drops its last pin, and
   an error item at the edge a conflict first becomes visible. *)
module Monitor = struct
  type t =
    { driven : int
    ; high : int
    ; software : int
    ; engine : int
    ; conflict : bool
    }

  let create (_ : Config.t) =
    { driven = 0; high = 0; software = 0; engine = 0; conflict = false }
  ;;

  let defined set name =
    match Observation.Set.find set name with
    | Some (Observation.Defined value) -> value
    | other ->
      raise_s
        [%message
          "monitor: an observation it needs is not defined"
            (name : string)
            (other : Observation.t option)]
  ;;

  let span ~edge ~stream ~previous ~current =
    if previous = current
    then []
    else (
      let boundary =
        if previous = 0
        then Env.Boundary.Start
        else if current = 0
        then Env.Boundary.End
        else Env.Boundary.Continue
      in
      [ { Env.Observed_item.edge
        ; stream
        ; direction = Env.Direction.Outbound
        ; boundary
        ; payload = [%message "" ~mask:(current : int)]
        ; error = None
        }
      ])
  ;;

  let observe t ~edge set =
    let driven, high =
      List.init Pins.count ~f:Fn.id
      |> List.fold ~init:(0, 0) ~f:(fun (driven, high) pin ->
        match Observation.Set.find set (bus_name pin) with
        | Some (Observation.Defined level) ->
          driven lor (1 lsl pin), if level = 1 then high lor (1 lsl pin) else high
        | Some Observation.Unspecified -> driven, high
        | other ->
          raise_s
            [%message
              "monitor: a pin's level is neither defined nor unspecified"
                (pin : int)
                (other : Observation.t option)])
    in
    let software = defined set "software_claim" in
    let engine = defined set "engine_claim" in
    let conflict = defined set "conflict" = 1 in
    let bus =
      if driven = t.driven && high = t.high
      then []
      else
        [ { Env.Observed_item.edge
          ; stream = "pins"
          ; direction = Env.Direction.Outbound
          ; boundary = Env.Boundary.Complete
          ; payload = [%message "" ~driven:(driven : int) ~high:(high : int)]
          ; error = None
          }
        ]
    in
    let conflicts =
      if conflict && not t.conflict
      then
        [ { Env.Observed_item.edge
          ; stream = "ownership"
          ; direction = Env.Direction.Outbound
          ; boundary = Env.Boundary.Complete
          ; payload = [%message "conflict"]
          ; error = Some "a request touched a pin another owner holds"
          }
        ]
      else []
    in
    ( { driven; high; software; engine; conflict }
    , List.concat
        [ span ~edge ~stream:"ownership.software" ~previous:t.software ~current:software
        ; span ~edge ~stream:"ownership.engine" ~previous:t.engine ~current:engine
        ; bus
        ; conflicts
        ] )
  ;;
end

(* Every registered output must be comparable on both sides. The bus levels are not
   required, because a released pin has no level this block defines; [reject_reason] is
   not required, because the design cannot expose it. *)
let required_pre_edge = held_names
let required_post_edge = registered_names

(* Bounded scenarios. Masks are drawn from a small overlapping set most of the time, so
   claims and writes actually collide; a quarter of them are uniform, so nothing in the
   bank's mask handling is only ever seen through those eight values. *)
module Generator = struct
  module G = Base_quickcheck.Generator
  open G.Let_syntax

  let chance p = G.of_weighted_list [ p, true; 1.0 -. p, false ]
  let byte = G.int_uniform_inclusive 0 Pins.all_pins

  let mask =
    let overlapping =
      G.of_weighted_list
        [ 3.0, 0x01
        ; 3.0, 0x03
        ; 2.0, 0x0f
        ; 2.0, 0x30
        ; 2.0, 0xf0
        ; 1.0, 0xff
        ; 1.0, 0x81
        ; 1.0, 0x18
        ; 1.0, 0x00
        ]
    in
    G.union [ overlapping; overlapping; overlapping; byte ]
  ;;

  let ownership =
    let%map engine = chance 0.5
    and mask in
    { Item.Ownership.engine; mask }
  ;;

  let write_request =
    let%map engine = chance 0.5
    and mask
    and value = byte
    and output_enable = mask
    and open_drain = chance 0.3 in
    { Item.Write_request.engine; mask; value; output_enable; open_drain }
  ;;

  let item =
    let%bind reset = chance 0.04
    and abort = chance 0.05
    and enable = chance 0.95
    and shape =
      G.of_weighted_list
        [ 2.0, `Idle; 4.0, `Claim; 3.0, `Release; 8.0, `Write; 1.0, `Claim_and_write ]
    in
    let base =
      { Item.reset; abort; enable; claim = None; release = None; write = None }
    in
    match shape with
    | `Idle -> G.return base
    | `Claim ->
      let%map claim = ownership in
      { base with claim = Some claim }
    | `Release ->
      let%map release = ownership in
      { base with release = Some release }
    | `Write ->
      let%map write = write_request in
      { base with write = Some write }
    | `Claim_and_write ->
      let%map claim = ownership
      and write = write_request in
      { base with claim = Some claim; write = Some write }
  ;;

  (* Every scenario starts from a reset edge. That is the prerequisite shrinking has to
     preserve: a scenario that no longer resets is not a smaller version of the failure,
     it is a test of an uninitialised design. *)
  let scenario =
    let%bind size = G.size in
    let%bind length = G.int_uniform_inclusive 1 (Int.max 1 size) in
    let%map items = G.list_with_length item ~length in
    Item.reset :: items
  ;;

  let begins_with_reset scenario =
    match scenario with
    | [] -> false
    | (item : Item.t) :: _ -> item.reset
  ;;
end

module Device = struct
  let name = name

  module Config = Config
  module Item = Item
  module Dut = Dut
  module F_model = F_model
  module Monitor = Monitor

  let required_pre_edge = required_pre_edge
  let required_post_edge = required_post_edge
end

include Env.Make (Device)
