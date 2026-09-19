(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "uart_slice_testbench.ml" *)
(* The three producers of one UART frame, each reduced to the same thing: what one pin
   did, cycle by cycle, as [Uart_frame_monitor] would see it from outside the chip.

   - [firmware_samples] is P1.3's bit-banged sequence run on the reference machine, whose
     pin bank and countdowns are the model of the hardware this slice connects.
   - [descriptor_samples] is the same frame as one typed transfer descriptor, run on the
     reference transfer engine.
   - [slice_samples] is [Uart_slice] in Hardcaml, sampled at the pin bank's registered
     outputs - the far side of the claim, the countdown and the masked commit.

   The point of reducing all three to a pin trace is that the monitor cannot tell them
   apart, and neither can the emitted RTL testbench, which writes the same trace from
   Verilog.
*)

open! Core
open! Hardcaml
open! Hardcaml_protemu
module F_model = Protemu_f_model
module Sim = Cyclesim.With_interface (Uart_slice.I) (Uart_slice.O)

let bits width n = Bits.of_int_trunc ~width n
let bit_of value ~pin = Bits.to_int_trunc !value land (1 lsl pin) <> 0

(* The vector the whole slice is demonstrated on. 0xa6 is the byte P1.3 and P2.7 already
   use, and it is worth keeping: least significant bit first it is 0,1,1,0,0,1,0,1, so the
   frame contains single-bit runs and the monitor can measure the bit period from the
   waveform rather than being told it. *)
let byte = 0xa6
let half_period = 4
let tx_pin = 0
let bit_cycles = 2 * half_period

(* P1.3's bit-banged sequence, on the reference machine. *)
let firmware_samples ?(byte = byte) ?(half_period = half_period) ?(pin = tx_pin) () =
  let firmware =
    match F_model.Firmware_uart.tx_sequence ~pin ~half_period ~byte with
    | Ok firmware -> firmware
    | Error invalid ->
      raise_s
        [%message "UART firmware did not build" (invalid : F_model.Firmware.Invalid.t)]
  in
  let trace =
    match F_model.Firmware.run F_model.Firmware.Board.quiet firmware with
    | Ok trace -> trace
    | Error invalid ->
      raise_s
        [%message "UART firmware did not run" (invalid : F_model.Firmware.Invalid.t)]
  in
  (* [wave] is 'z' for a released pin and '0'/'1' for a driven level, which is exactly the
     distinction the monitor needs. The run ends on the stop bit, so the trailing idle the
     monitor asks for is appended here: the line rests where the sequence left it. *)
  let driven =
    String.to_list (F_model.Firmware.Trace.wave trace ~pin)
    |> List.map ~f:(function
      | 'z' -> Uart_frame_monitor.Sample.released
      | '0' -> { level = false; driven = true }
      | '1' -> { level = true; driven = true }
      | c -> raise_s [%message "unexpected wave character" (c : char)])
  in
  Array.of_list
    (driven @ List.init (2 * bit_cycles) ~f:(fun _ -> Uart_frame_monitor.Sample.idle_high))
;;

(* The same frame as one typed descriptor, on the reference transfer engine. The engine
   drives nothing when it is not active, so the wrapper's resting level is supplied here
   exactly as [Uart_tx] supplies it in hardware: idle high while enabled. *)
let descriptor_samples ?(byte = byte) ?(half_period = half_period) ?(pin = tx_pin) () =
  let descriptor =
    match F_model.Firmware_uart.tx_8n1 ~pin ~half_period ~byte with
    | Ok descriptor -> descriptor
    | Error _ -> failwith "valid UART descriptor rejected"
  in
  let bit_cycles = 2 * half_period in
  let model = ref F_model.Shift_engine.idle in
  let leading = List.init bit_cycles ~f:(fun _ -> Uart_frame_monitor.Sample.idle_high) in
  let frame = Queue.create () in
  (* An explicit loop: [List.init] is free to evaluate in any order, and every step here
     depends on the one before it. *)
  for cycle = 0 to (Uart_frame_monitor.frame_bits * bit_cycles) + (2 * bit_cycles) - 1 do
    let command = if cycle = 0 then Some (descriptor, false) else None in
    model
    := F_model.Shift_engine.step
         !model
         ~enable:true
         ~abort:false
         ~command
         ~start_event:false
         ~observed_edge:false
         ~pin_in:0
         ~occupied:0
         ~tx_valid:true
         ~rx_ready:true;
    Queue.enqueue
      frame
      (if !model.active
       then
         { Uart_frame_monitor.Sample.level = !model.pins land (1 lsl pin) <> 0
         ; driven = !model.output_enable land (1 lsl pin) <> 0
         }
       else Uart_frame_monitor.Sample.idle_high)
  done;
  Array.of_list (leading @ Queue.to_list frame)
;;

(* [Uart_slice] in Hardcaml, sampled where the pins leave the bank. [f] runs beside the
   capture so a test can pull enable, reset or abort partway through the frame. *)
let slice_samples
  ?(byte = byte)
  ?(half_period = half_period)
  ?(pin = tx_pin)
  ?(extra_cycles = 0)
  ?(f = fun ~cycle:_ ~i:_ ~o:_ -> ())
  ()
  =
  let sim = Sim.create (Uart_slice.create (Scope.create ~flatten_design:true ())) in
  let i = Cyclesim.inputs sim in
  let o = Cyclesim.outputs sim in
  let bit_cycles = 2 * half_period in
  i.reset_i := Bits.vdd;
  i.enable_i := Bits.vdd;
  i.byte_i := bits 8 byte;
  i.half_period_i := bits 16 half_period;
  i.tx_pin_i := bits 3 pin;
  Cyclesim.cycle sim;
  i.reset_i := Bits.gnd;
  i.start_i := Bits.vdd;
  Cyclesim.cycle sim;
  i.start_i := Bits.gnd;
  (* One claim edge, one bit period of timed idle, the ten-bit frame, the release, and a
     bit period of rest after it, with room for the bank's one-cycle commit. *)
  let cycles = (13 * bit_cycles) + 16 + extra_cycles in
  let samples = Queue.create () in
  for cycle = 0 to cycles - 1 do
    f ~cycle ~i ~o;
    Cyclesim.cycle sim;
    Queue.enqueue
      samples
      { Uart_frame_monitor.Sample.level = bit_of o.pins_o ~pin
      ; driven = bit_of o.pin_oe_o ~pin
      }
  done;
  Queue.to_array samples, o
;;

let decode samples ~half_period =
  Uart_frame_monitor.decode_exn samples ~bit_cycles:(2 * half_period)
;;

let trace_of samples ~byte ~half_period ~tx_pin =
  Uart_frame_monitor.to_trace (decode samples ~half_period) ~byte ~half_period ~tx_pin
;;
