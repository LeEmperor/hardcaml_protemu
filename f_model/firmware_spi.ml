(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "firmware_spi.ml" *)
(* A mode-0 SPI exchange, as a transfer descriptor and as an explicit firmware sequence,
   with an independent target to exchange with.

   Mode 0 is CPOL=0 and CPHA=0: the clock idles low, the master launches a bit on the
   falling edge, and both ends sample on the rising edge. The descriptor says exactly that
   in mechanism terms - [idle_clock = false], [launch = On_falling],
   [sample = On_rising] - and never the words "mode 0", which is the naming rule
   construction-plan.md section 3 sets for the primitive layer. The protocol name belongs
   here, in the firmware builder.

   THE SAMPLE POINT IS NOT THE RISING EDGE. Firmware cannot observe an input until it has
   crossed two synchronizer stages, so [exchange] marks its sample at the end of the high
   phase rather than at the rising edge. It reads the level the target presented around
   the rising edge, because a mode-0 target holds a bit for the whole high phase. That is
   also why a bit-banged exchange needs a half period of at least three cycles while the
   descriptor accepts one: the engine samples in its own clock domain and firmware cannot.

   THE TARGET IS NOT PART OF THE DESIGN. [Peer] is an independent model of the device on
   the other end, used so a trace contains a real received word rather than an assumption.
   It follows the wire, not the model's state.
*)

open! Core
open! Kinds

(* One exchange as a single descriptor: one configure operation instead of four per bit. *)
let mode0 ~sclk ~mosi ~miso ~half_period ~bit_count ~bit_order ~tx_value =
  let descriptor : Transfer.t =
    { direction = Duplex
    ; bit_count
    ; bit_order
    ; tx_value
    ; output_pin = Some mosi
    ; input_pin = Some miso
    ; clock_pin = Some sclk
    ; idle_output = false
    ; idle_clock = false
    ; initial_delay = None
    ; launch = Clock_phase.On_falling
    ; sample = Clock_phase.On_rising
    ; pacing = Transfer.Pacing.Internal { half_period }
    }
  in
  Result.map (Transfer.validate descriptor) ~f:(fun () -> descriptor)
;;

(* The bits of [value] in transmission order. *)
let transmission_order ~(bit_order : Bit_order.t) ~bit_count ~value =
  List.init bit_count ~f:(fun i ->
    let index =
      match bit_order with
      | Lsb_first -> i
      | Msb_first -> bit_count - 1 - i
    in
    value land (1 lsl index) <> 0)
;;

(* The same exchange bit-banged. [cs] is optional because a single-target board may tie it
   low; when given it is held low for the whole exchange and released at the end, so the
   trace shows the framing a target uses to reset its own bit counter. *)
let exchange ?cs ~sclk ~mosi ~miso ~half_period ~bit_count ~bit_order ~tx_value () =
  let ( >>= ) result f = Result.bind result ~f in
  let bit pin = 1 lsl pin in
  let cs_mask = Option.value_map cs ~default:0 ~f:bit in
  let mask = bit sclk lor bit mosi lor cs_mask in
  (* Every phase commits all three pins at once, so chip select and the clock can never
     move on separate edges. [selected] keeps chip select low; releasing it drives high. *)
  let drive ~label ~selected ~clock ~data ~cycles =
    let value =
      (if clock then bit sclk else 0)
      lor (if data then bit mosi else 0)
      lor if selected then 0 else cs_mask
    in
    Firmware.phase ~label ~write:(Pin_bank.Write.push_pull ~mask ~value) ~cycles
  in
  if bit_count < 1 || bit_count > Transfer.max_bit_count
  then Error (Firmware.Invalid.Out_of_range { what = "bit_count"; value = bit_count })
  else if tx_value < 0 || tx_value >= 1 lsl bit_count
  then Error (Firmware.Invalid.Out_of_range { what = "tx_value"; value = tx_value })
  else
    (* Chip select falls a half period before the first launch edge, which is the setup a
       target needs to present its first bit. *)
    drive ~label:"select" ~selected:true ~clock:false ~data:false ~cycles:half_period
    >>= fun select ->
    List.fold_result
      (List.mapi
         (transmission_order ~bit_order ~bit_count ~value:tx_value)
         ~f:(fun i data -> i, data))
      ~init:[]
      ~f:(fun acc (i, data) ->
        drive
          ~label:(sprintf "b%d.launch" i)
          ~selected:true
          ~clock:false
          ~data
          ~cycles:half_period
        >>= fun low ->
        drive
          ~label:(sprintf "b%d.sample" i)
          ~selected:true
          ~clock:true
          ~data
          ~cycles:half_period
        >>= fun high ->
        (* The sample closes the high phase: by then the target's bit has crossed both
           synchronizer stages. *)
        Ok ((low @ high @ [ Firmware.Step.Sample { pin = miso; name = "miso" } ]) :: acc))
    >>= fun bits ->
    drive ~label:"release" ~selected:false ~clock:false ~data:false ~cycles:half_period
    >>= fun release ->
    Firmware.create
      ~name:(sprintf "spi_mode0_x%d_0x%x" bit_count tx_value)
      (select @ List.concat (List.rev bits) @ release)
;;

module Peer = struct
  (* An independent mode-0 target. It launches its next bit on each falling edge of the
     clock it sees on the wire and holds the first bit from the start, which is what
     CPHA=0 requires of a target that is selected before the first edge. After its word
     runs out it holds the last bit; nothing in a mode-0 exchange defines what follows.

     It watches the master's drive rather than the machine's internal state, so it stays
     an outside observer: the only thing it shares with the design under test is the wire. *)
  type t =
    { (* Bits still to send, in transmission order. *)
      pending : bool list
    ; (* The level currently on MISO. *)
      current : bool
    ; (* The clock level at the previous edge, for falling-edge detection. *)
      clock : bool
    }

  let board ~sclk ~miso ~bit_order ~bit_count ~value =
    let bits = transmission_order ~bit_order ~bit_count ~value in
    let first, rest =
      match bits with
      | [] -> false, []
      | first :: rest -> first, rest
    in
    let advance t =
      match t.pending with
      | [] -> t
      | next :: rest -> { t with current = next; pending = rest }
    in
    { Firmware.Board.initial = { pending = rest; current = first; clock = false }
    ; next =
        (fun t (machine : Machine.t) ->
          let driven = machine.pins.value land machine.pins.output_enable in
          let clock = driven land (1 lsl sclk) <> 0 in
          let t = if t.clock && not clock then advance t else t in
          let t = { t with clock } in
          (* MOSI, the clock, and chip select read back as the master drives them; MISO is
             the target's. There are no pull-ups on a push-pull bus. *)
          t, driven lor if t.current then 1 lsl miso else 0)
    }
  ;;
end
