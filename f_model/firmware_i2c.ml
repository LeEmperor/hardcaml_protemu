(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "firmware_i2c.ml" *)
(* Explicit I2C drive, sample, and wait sequences, with an independent target to talk to.

   I2C is the protocol that needs all three of P1.3's verbs in one sequence, which is why
   the phase plan names it that way. Every write is open drain: the master drives a zero
   or releases to the board pull-up and never drives a one, so [Pin_bank.Write.open_drain]
   is the only write form used here. Every acknowledge is a sample of the wire, because
   the master released SDA and cannot know what the target did with it. Every clock high
   phase begins with a level wait, because the target may hold SCL low - clock stretching
   - and a master that assumed its own release took effect would clock a bit the target
     never saw.

   PHASE LENGTHS. A bit is four quarter periods: SDA settles while the clock is low, the
   clock is released and observed high, the level is held, and the clock is pulled low
   again. A high phase therefore lasts [quarter_period] cycles measured from the edge at
   which the master observed SCL high, not from its own release; two synchronizer stages
   and any stretching sit in between, and the trace shows both.

   WHAT IS BUILT. One complete single-master write transaction and the byte-level pieces
   it is built from. A read transaction, a repeated start, multi-master arbitration, and
   ten-bit addressing are P4 work; [Direction] names the read bit now because it is part
   of the address byte either way.
*)

open! Core
open! Kinds

module Direction = struct
  (* The bit that follows the seven address bits. *)
  type t =
    | Write
    | Read
  [@@deriving sexp, compare, equal, enumerate]

  let bit = function
    | Write -> 0
    | Read -> 1
  ;;
end

(* One open-drain commit of both lines, and then [cycles] edges before the next one. [low]
   lists the lines held at zero; everything else in the pair is released. *)
let commit ~label ~scl ~sda ~low ~cycles =
  let mask = (1 lsl scl) lor (1 lsl sda) in
  Firmware.phase
    ~label
    ~write:(Pin_bank.Write.open_drain ~mask ~drive_low:(low land mask))
    ~cycles
;;

(* The clock-high phase of any slot: release SCL, wait until the wire really is high, then
   hold it there. The level wait is the clock-stretch tolerance, and its recorded latency
   is how long the target held the bus. *)
let clock_high ~label ~scl ~sda ~sda_low ~quarter ~stretch_timeout =
  let ( >>= ) result f = Result.bind result ~f in
  commit ~label ~scl ~sda ~low:sda_low ~cycles:quarter
  >>= fun release ->
  (* [Firmware.phase] puts the countdown last; the stretch wait belongs before it, so the
     high phase is measured from the edge at which SCL was observed high. *)
  match List.rev release with
  | countdown :: rest ->
    Ok
      (List.rev rest
       @ [ Firmware.Step.Do
             (Operation.Wait_level
                { pin = scl; level = true; timeout = Some stretch_timeout })
         ; countdown
         ])
  | [] -> Ok release
;;

(* One bit slot driven by the master: set SDA while the clock is low, then clock it. *)
let bit_slot ~label ~scl ~sda ~quarter ~stretch_timeout ~level =
  let ( >>= ) result f = Result.bind result ~f in
  let sda_low = if level then 0 else 1 lsl sda in
  commit
    ~label:(label ^ ".setup")
    ~scl
    ~sda
    ~low:((1 lsl scl) lor sda_low)
    ~cycles:quarter
  >>= fun setup ->
  clock_high ~label:(label ^ ".clock") ~scl ~sda ~sda_low ~quarter ~stretch_timeout
  >>= fun high -> Ok (setup @ high)
;;

(* The ninth slot: the master releases SDA and reads what the target does with it. A
   sample of [false] is an acknowledge, since the target acknowledges by pulling low. *)
let acknowledge_slot ~label ~scl ~sda ~quarter ~stretch_timeout =
  let ( >>= ) result f = Result.bind result ~f in
  commit ~label:(label ^ ".release") ~scl ~sda ~low:(1 lsl scl) ~cycles:quarter
  >>= fun release ->
  clock_high ~label:(label ^ ".clock") ~scl ~sda ~sda_low:0 ~quarter ~stretch_timeout
  >>= fun high ->
  Ok (release @ high @ [ Firmware.Step.Sample { pin = sda; name = "ack" } ])
;;

(* START: with the bus free, pull SDA low while SCL is high, then pull SCL low. The
   leading bus-free check is a wait, not a delay: after reset the input front end reports
   both lines low until the pull-ups have crossed the synchronizers. *)
let start_condition ~label ~scl ~sda ~quarter ~stretch_timeout =
  let ( >>= ) result f = Result.bind result ~f in
  commit ~label:(label ^ ".free") ~scl ~sda ~low:0 ~cycles:quarter
  >>= fun free ->
  commit ~label:(label ^ ".sda") ~scl ~sda ~low:(1 lsl sda) ~cycles:quarter
  >>= fun sda_low ->
  commit
    ~label:(label ^ ".scl")
    ~scl
    ~sda
    ~low:((1 lsl scl) lor (1 lsl sda))
    ~cycles:quarter
  >>= fun scl_low ->
  let bus_free =
    [ Firmware.Step.Do
        (Operation.Wait_level { pin = sda; level = true; timeout = Some stretch_timeout })
    ; Firmware.Step.Do
        (Operation.Wait_level { pin = scl; level = true; timeout = Some stretch_timeout })
    ]
  in
  match free with
  | at :: write :: rest -> Ok (((at :: write :: bus_free) @ rest) @ sda_low @ scl_low)
  | _ -> Ok (free @ sda_low @ scl_low)
;;

(* STOP: with SDA held low, release SCL, then release SDA while the clock is high. *)
let stop_condition ~label ~scl ~sda ~quarter ~stretch_timeout =
  let ( >>= ) result f = Result.bind result ~f in
  commit
    ~label:(label ^ ".low")
    ~scl
    ~sda
    ~low:((1 lsl scl) lor (1 lsl sda))
    ~cycles:quarter
  >>= fun low ->
  clock_high
    ~label:(label ^ ".scl")
    ~scl
    ~sda
    ~sda_low:(1 lsl sda)
    ~quarter
    ~stretch_timeout
  >>= fun high ->
  commit ~label:(label ^ ".sda") ~scl ~sda ~low:0 ~cycles:quarter
  >>= fun release -> Ok (low @ high @ release)
;;

(* Eight data bits, most significant first, followed by the acknowledge slot. *)
let write_byte ~label ~scl ~sda ~quarter ~stretch_timeout ~byte =
  let ( >>= ) result f = Result.bind result ~f in
  if byte < 0 || byte > 255
  then Error (Firmware.Invalid.Out_of_range { what = "byte"; value = byte })
  else
    List.fold_result (List.init 8 ~f:Fn.id) ~init:[] ~f:(fun acc index ->
      let position = 7 - index in
      bit_slot
        ~label:(sprintf "%s.b%d" label position)
        ~scl
        ~sda
        ~quarter
        ~stretch_timeout
        ~level:(byte land (1 lsl position) <> 0)
      >>= fun slot -> Ok (slot :: acc))
    >>= fun bits ->
    acknowledge_slot ~label:(label ^ ".ack") ~scl ~sda ~quarter ~stretch_timeout
    >>= fun ack -> Ok (List.concat (List.rev bits) @ ack)
;;

(* One single-master write transaction: START, the addressed write, the payload, STOP. *)
let write_transaction ?(stretch_timeout = 64) ~scl ~sda ~quarter_period ~address ~bytes ()
  =
  let ( >>= ) result f = Result.bind result ~f in
  let quarter = quarter_period in
  if address < 0 || address > 0x7f
  then Error (Firmware.Invalid.Out_of_range { what = "address"; value = address })
  else
    start_condition ~label:"start" ~scl ~sda ~quarter ~stretch_timeout
    >>= fun start ->
    write_byte
      ~label:"addr"
      ~scl
      ~sda
      ~quarter
      ~stretch_timeout
      ~byte:((address lsl 1) lor Direction.bit Direction.Write)
    >>= fun addr ->
    List.fold_result
      (List.mapi bytes ~f:(fun i byte -> i, byte))
      ~init:[]
      ~f:(fun acc (index, byte) ->
        write_byte ~label:(sprintf "w%d" index) ~scl ~sda ~quarter ~stretch_timeout ~byte
        >>= fun steps -> Ok (steps :: acc))
    >>= fun payload ->
    stop_condition ~label:"stop" ~scl ~sda ~quarter ~stretch_timeout
    >>= fun stop ->
    Firmware.create
      ~name:(sprintf "i2c_write_0x%02x_x%d" address (List.length bytes))
      (start @ addr @ List.concat (List.rev payload) @ stop)
;;

module Peer = struct
  (* An independent I2C target. It follows the two wires and nothing else: START and STOP
     are SDA transitions while SCL is high, a bit is captured on each rising edge, and the
     acknowledge is driven low across the ninth slot. It may hold SCL low for a fixed
     number of cycles after each byte, which is how a real target buys itself time and is
     the case a master that skipped the level wait would get wrong.

     [received] is in arrival order, address byte first, so a test can assert what reached
     the other end rather than what the sequence intended to send. *)
  module Phase = struct
    type t =
      | (* Between a STOP and the next START. *)
        Idle
      | (* [n] bits of the current byte captured. *)
        Bits of int
      | (* The ninth slot. *)
        Ack
    [@@deriving sexp, compare, equal]
  end

  type t =
    { phase : Phase.t
    ; shift : int
    ; received : int list
    ; (* True until the address byte has been acknowledged. *)
      addressing : bool
    ; selected : bool
    ; (* The target is pulling SDA low for an acknowledge. *)
      ack : bool
    ; (* Cycles of SCL still held low. *)
      stretch : int
    ; (* Wire levels at the previous edge, for edge detection. *)
      scl : bool
    ; sda : bool
    }
  [@@deriving sexp_of]

  let initial =
    { phase = Phase.Idle
    ; shift = 0
    ; received = []
    ; addressing = false
    ; selected = false
    ; ack = false
    ; stretch = 0
    ; scl = true
    ; sda = true
    }
  ;;

  let board ?(stretch_cycles = 0) ~scl ~sda ~address () =
    let scl_bit = 1 lsl scl
    and sda_bit = 1 lsl sda in
    { Firmware.Board.initial
    ; next =
        (fun t (machine : Machine.t) ->
          let master_low bit =
            machine.pins.output_enable land bit <> 0 && machine.pins.value land bit = 0
          in
          let target_low bit =
            (bit = sda_bit && t.ack) || (bit = scl_bit && t.stretch > 0)
          in
          let wire bit = not (master_low bit || target_low bit) in
          let scl_now = wire scl_bit
          and sda_now = wire sda_bit in
          let rising = scl_now && not t.scl in
          let falling = t.scl && not scl_now in
          let t =
            if t.scl && scl_now && t.sda && not sda_now
            then
              (* START. *)
              { t with
                phase = Phase.Bits 0
              ; shift = 0
              ; received = []
              ; addressing = true
              ; selected = false
              ; ack = false
              }
            else if t.scl && scl_now && (not t.sda) && sda_now
            then
              (* STOP. *)
              { t with
                phase = Phase.Idle
              ; addressing = false
              ; selected = false
              ; ack = false
              }
            else if rising
            then (
              match t.phase with
              | Phase.Bits n when n < 8 ->
                { t with
                  shift = (t.shift lsl 1) lor Bool.to_int sda_now
                ; phase = Phase.Bits (n + 1)
                }
              | Phase.Bits _ | Ack | Idle -> t)
            else if falling
            then (
              match t.phase with
              | Phase.Bits 8 ->
                let byte = t.shift in
                let acknowledged =
                  if t.addressing then byte lsr 1 = address else t.selected
                in
                { t with
                  phase = Phase.Ack
                ; (* A target that was never addressed ignores the rest of the
                     transaction; only the address byte itself is recorded. *)
                  received =
                    (if t.addressing || t.selected
                     then t.received @ [ byte ]
                     else t.received)
                ; addressing = false
                ; selected = acknowledged
                ; ack = acknowledged
                ; (* Set one high so the decrement below leaves exactly [stretch_cycles]. *)
                  stretch = (if acknowledged then stretch_cycles + 1 else 0)
                }
              | Phase.Ack -> { t with phase = Phase.Bits 0; shift = 0; ack = false }
              | Phase.Bits _ | Idle -> t)
            else t
          in
          let t =
            { t with stretch = Int.max 0 (t.stretch - 1); scl = scl_now; sda = sda_now }
          in
          (* The pads see the wired-AND of both ends against the board pull-ups. Every pin
             outside the pair is pulled high too, which no sequence here observes. *)
          let driven_low =
            machine.pins.output_enable
            land lnot machine.pins.value
            lor (if t.ack then sda_bit else 0)
            lor if t.stretch > 0 then scl_bit else 0
          in
          t, Pin_bank.all_pins land lnot driven_low)
    }
  ;;
end
