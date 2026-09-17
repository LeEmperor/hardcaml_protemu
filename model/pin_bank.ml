(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "pin_bank.ml" *)
(* The eight-pin output bank: registered value and output enable, masked atomic commits,
   and exclusive drive ownership.

   Tri-state behaviour is two signals, never a third logic level. Releasing a pin is
   [output_enable = 0]; a board pull-up supplies the high level, which is why nothing here
   reports a "high" that was not read back through [Input_pins]. Open drain is value 0
   with the enable carrying the drive, so [Write.open_drain] cannot express a driven high.

   Ownership is exclusive per pin and changes only at a clock edge, by way of [claim] and
   [release]. A transfer engine will claim its configured output and clock pins for the
   length of a transaction (P2.5); until then the harness drives the same mechanism
   directly, which is what makes the conflict rules testable now.

   Inputs are deliberately not owned: construction-plan.md section 3 lets several
   consumers observe the same input.
*)

open! Core
open! Kinds

(* The first logical bank (construction-plan.md section 3). Wider banks are a later
   decision, so nothing outside this module assumes the number eight. *)
let count = 8
let all_pins = (1 lsl count) - 1
let is_valid_pin pin = pin >= 0 && pin < count
let bit mask pin = mask land (1 lsl pin) <> 0
let pins_of_mask mask = List.filter (List.init count ~f:Fn.id) ~f:(bit mask)

module Write = struct
  (* One atomic commit. Every pin selected by [mask] takes its [value] and [output_enable]
     bit at the same edge; unselected pins keep both of theirs. Value and enable are never
     committed on separate edges, so a pin cannot briefly drive the old level with the new
     enable. *)
  type t =
    { mask : int
    ; value : int
    ; output_enable : int
    }
  [@@deriving sexp, compare, equal]

  let push_pull ~mask ~value = { mask; value = value land mask; output_enable = mask }

  (* Drive low or release, never drive high. [drive_low] selects the pins held at zero;
     every other pin in [mask] is released to the pull-up. *)
  let open_drain ~mask ~drive_low =
    { mask; value = 0; output_enable = mask land drive_low }
  ;;

  let release ~mask = { mask; value = 0; output_enable = 0 }
end

type t =
  { value : int
  ; output_enable : int
  ; (* Disjoint claim masks. A pin missing from every mask is free. Stored as a list
       rather than an array so the whole model stays immutable and a test can keep old
       states. *)
    claims : (Owner.t * int) list
  }
[@@deriving sexp, compare, equal]

(* Reset releases every protocol pin and drops every claim (construction-plan.md section
   3: "On reset, release protocol pins"). It is also the abort and disable state. *)
let released = { value = 0; output_enable = 0; claims = [] }

let owner_of t ~pin =
  List.find_map t.claims ~f:(fun (owner, mask) ->
    if bit mask pin then Some owner else None)
;;

let claimed_mask t = List.fold t.claims ~init:0 ~f:(fun acc (_, mask) -> acc lor mask)

let mask_owned_by t ~owner =
  List.find_map t.claims ~f:(fun (o, mask) ->
    if Owner.equal o owner then Some mask else None)
  |> Option.value ~default:0
;;

(* A mask may only select pins this bank has. The reported number is the lowest offending
   bit, so the reason names a pin rather than repeating the mask. *)
let validate_mask mask =
  let out_of_range = mask land lnot all_pins in
  if out_of_range = 0
  then Ok ()
  else (
    let rec lowest_bit n =
      if out_of_range land (1 lsl n) <> 0 then n else lowest_bit (n + 1)
    in
    Error (Fault.Reject.Pin_out_of_range (lowest_bit 0)))
;;

(* The first pin in [mask] that some owner other than [owner] holds. *)
let conflicting_pin t ~owner ~mask =
  List.find_map (pins_of_mask mask) ~f:(fun pin ->
    match owner_of t ~pin with
    | Some held when not (Owner.equal held owner) -> Some (pin, held)
    | _ -> None)
;;

let set_claim t ~owner ~mask =
  let others = List.filter t.claims ~f:(fun (o, _) -> not (Owner.equal o owner)) in
  if mask = 0
  then { t with claims = others }
  else { t with claims = (owner, mask) :: others }
;;

let claim t ~owner ~mask =
  match validate_mask mask with
  | Error _ as error -> error
  | Ok () ->
    (match conflicting_pin t ~owner ~mask with
     | Some (pin, held) -> Error (Fault.Reject.Pin_owned { pin; owner = held })
     | None -> Ok (set_claim t ~owner ~mask:(mask_owned_by t ~owner lor mask)))
;;

let release t ~owner ~mask =
  match validate_mask mask with
  | Error _ as error -> error
  | Ok () ->
    let held = mask_owned_by t ~owner in
    (match List.hd (pins_of_mask (mask land lnot held)) with
     | Some pin ->
       Error (Fault.Reject.Pin_not_owned { pin; claimed_by = owner_of t ~pin })
     | None -> Ok (set_claim t ~owner ~mask:(held land lnot mask)))
;;

let release_all t = { t with claims = [] }

(* Commit [write] on behalf of [owner]. Every selected pin must be free or already held by
   [owner]; an overlap with another owner's claim is refused and, at the machine level,
   also raises the sticky ownership fault. *)
let commit t (write : Write.t) ~owner =
  match validate_mask write.mask with
  | Error _ as error -> error
  | Ok () ->
    (match conflicting_pin t ~owner ~mask:write.mask with
     | Some (pin, held) -> Error (Fault.Reject.Pin_owned { pin; owner = held })
     | None ->
       let keep = lnot write.mask in
       Ok
         { t with
           value = t.value land keep lor (write.value land write.mask)
         ; output_enable =
             t.output_enable land keep lor (write.output_enable land write.mask)
         })
;;
