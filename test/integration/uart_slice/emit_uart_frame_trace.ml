(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "emit_uart_frame_trace.ml" *)
(* Write the first working slice's saved frame trace.

   Three producers are decoded by the same independent receiver: P1.3's bit-banged
   sequence on the reference machine, the same frame as one typed descriptor on the
   reference transfer engine, and [Uart_slice] in Hardcaml with the frame taken through
   the pin bank and the timer. They must agree bit for bit and period for period before a
   line is printed; the emitted RTL testbench writes the same file from Verilog, and the
   `@rtl` alias diffs it against this one.
*)

open! Core
open! Uart_slice_testbench

let () =
  let traces =
    [ "reference machine, bit-banged", firmware_samples ()
    ; "reference engine, typed descriptor", descriptor_samples ()
    ; "Hardcaml slice, through the pin bank", fst (slice_samples ())
    ]
    |> List.map ~f:(fun (name, samples) ->
      name, trace_of samples ~byte ~half_period ~tx_pin)
  in
  match traces with
  | [] -> failwith "no producers"
  | (first_name, first) :: rest ->
    List.iter rest ~f:(fun (name, trace) ->
      if not (String.equal trace first)
      then
        raise_s
          [%message
            "UART frame traces disagree"
              (first_name : string)
              (first : string)
              (name : string)
              (trace : string)]);
    print_string first
;;
