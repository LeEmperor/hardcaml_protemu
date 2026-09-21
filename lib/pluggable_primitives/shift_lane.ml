(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "shift_lane.ml" *)
(* One 1..32-bit transfer lane. A descriptor is checked and latched at acceptance.
   Internally paced work toggles its clock each half-period; observed work consumes
   aligned edge pulses. The lane owns its drive pins until completion or abort. *)

open! Core
open! Hardcaml
open! Signal

module I = struct
  type 'a t =
    { clock_i : 'a
    ; reset_i : 'a
    ; enable_i : 'a
    ; abort_i : 'a
    ; start_valid_i : 'a
    ; arm_i : 'a
    ; start_event_i : 'a
    ; bit_count_i : 'a [@bits 6]
    ; tx_value_i : 'a [@bits 32]
    ; tx_valid_i : 'a
    ; rx_ready_i : 'a
    ; tx_enable_i : 'a
    ; rx_enable_i : 'a
    ; lsb_first_i : 'a
    ; output_pin_i : 'a [@bits 3]
    ; input_pin_i : 'a [@bits 3]
    ; clock_pin_i : 'a [@bits 3]
    ; clock_enable_i : 'a
    ; idle_output_i : 'a
    ; idle_clock_i : 'a
    ; initial_delay_i : 'a [@bits 16]
    ; half_period_i : 'a [@bits 16]
    ; launch_trailing_i : 'a
    ; sample_trailing_i : 'a
    ; observed_i : 'a
    ; observed_edge_i : 'a
    ; pin_in_i : 'a [@bits 8]
    ; occupied_i : 'a [@bits 8]
    }
  [@@deriving hardcaml]
end

module O = struct
  type 'a t =
    { ready_o : 'a
    ; busy_o : 'a
    ; armed_o : 'a
    ; claim_mask_o : 'a [@bits 8]
    ; pin_value_o : 'a [@bits 8]
    ; pin_oe_o : 'a [@bits 8]
    ; done_o : 'a
    ; rx_valid_o : 'a
    ; rx_data_o : 'a [@bits 32]
    ; rejected_o : 'a
    ; underrun_o : 'a
    ; overrun_o : 'a
    }
  [@@deriving hardcaml]
end

module I_Regs = struct
  (* Registered descriptor, transfer progress, pins, and one-cycle result pulses. *)
  type 'a t =
    { busy : 'a
    ; armed : 'a
    ; bit_count : 'a [@bits 6]
    ; bit_index : 'a [@bits 6]
    ; tx_value : 'a [@bits 32]
    ; rx_value : 'a [@bits 32]
    ; rx_data : 'a [@bits 32]
    ; tx_enable : 'a
    ; rx_enable : 'a
    ; lsb_first : 'a
    ; output_pin : 'a [@bits 3]
    ; input_pin : 'a [@bits 3]
    ; clock_pin : 'a [@bits 3]
    ; clock_enable : 'a
    ; idle_clock : 'a
    ; launch_trailing : 'a
    ; sample_trailing : 'a
    ; observed : 'a
    ; half_period : 'a [@bits 16]
    ; remaining : 'a [@bits 16]
    ; trailing : 'a
    ; claim_mask : 'a [@bits 8]
    ; prepared_mask : 'a [@bits 8]
    ; prepared_pin_value : 'a [@bits 8]
    ; pin_value : 'a [@bits 8]
    ; pin_oe : 'a [@bits 8]
    ; done_ : 'a
    ; rx_valid : 'a
    ; rejected : 'a
    ; underrun : 'a
    ; overrun : 'a
    }
  [@@deriving hardcaml]
end

let pin_mask pin = mux pin (List.init 8 ~f:(fun n -> of_int_trunc ~width:8 (1 lsl n)))
let selected word pin = mux pin (List.init 8 ~f:(fun n -> bit word ~pos:n))
let data_bit word index = mux index (List.init 32 ~f:(fun n -> bit word ~pos:n))
let data_mask index = mux index (List.init 32 ~f:(fun n -> of_int_trunc ~width:32 (1 lsl n)))

let create (scope : Scope.t) (i : _ I.t) : _ O.t =
  let open Always in
  let spec = Reg_spec.create ~clock:i.clock_i ~clear:i.reset_i () in
  let r = I_Regs.Of_always.reg spec in
  I_Regs.Of_always.apply_names ~prefix:"reg_" ~naming_op:(Scope.naming scope) r;
  let output_mask = pin_mask i.output_pin_i in
  let clock_mask = pin_mask i.clock_pin_i in
  let driven =
    (mux2 i.tx_enable_i output_mask (zero 8))
    |: (mux2 i.clock_enable_i clock_mask (zero 8))
  in
  let structural_invalid =
    (i.bit_count_i ==:. 0)
    |: (i.bit_count_i >:. 32)
    |: ((log_shift ~f:srl i.tx_value_i ~by:i.bit_count_i) <>:. 0)
    |: (i.tx_enable_i &: i.clock_enable_i &: (i.output_pin_i ==: i.clock_pin_i))
    |: (i.rx_enable_i &: i.clock_enable_i &: (i.input_pin_i ==: i.clock_pin_i))
    |: (i.observed_i &: i.clock_enable_i)
    |: (~:(i.observed_i) &: (i.half_period_i ==:. 0))
    |: (i.launch_trailing_i ==: i.sample_trailing_i)
    |: (~:(i.tx_enable_i) &: ~:(i.rx_enable_i))
  in
  let preload_value =
((mux2
                              i.tx_enable_i
                              (mux2
                                 i.launch_trailing_i
                                 (mux2
                                    (data_bit
                                       i.tx_value_i
                                       (mux2
                                          i.lsb_first_i
                                          (zero 6)
                                          (i.bit_count_i -:. 1)))
                                    output_mask
                                    (zero 8))
                                 (mux2 i.idle_output_i output_mask (zero 8)))
                              (zero 8))
                           |: (mux2
                                 (i.clock_enable_i &: i.idle_clock_i)
                                 clock_mask
                                 (zero 8))) in
  let accept = i.start_valid_i &: ~:(r.busy.value) &: ~:(r.armed.value) in
  let occupied = (driven &: i.occupied_i) <>:. 0 in
  let advance =
    r.busy.value
    &: (mux2 r.observed.value i.observed_edge_i (r.remaining.value ==:. 1))
  in
  let bit_position =
    mux2
      r.lsb_first.value
      r.bit_index.value
      (r.bit_count.value -:. 1 -: r.bit_index.value)
  in
  let launch_position =
    mux2
      r.launch_trailing.value
      (mux2
         r.lsb_first.value
         (r.bit_index.value +:. 1)
         (r.bit_count.value -:. 2 -: r.bit_index.value))
      bit_position
  in
  let tx_bit = data_bit r.tx_value.value launch_position in
  let input_bit = selected i.pin_in_i r.input_pin.value in
  let rx_mask = data_mask bit_position in
  let next_rx =
    (r.rx_value.value &: ~:rx_mask) |: (mux2 input_bit rx_mask (zero 32))
  in
  let phase_launch = r.trailing.value ==: r.launch_trailing.value in
  let phase_sample = r.trailing.value ==: r.sample_trailing.value in
  let finishing = r.trailing.value &: (r.bit_index.value ==: (r.bit_count.value -:. 1)) in
  let output_mask = pin_mask r.output_pin.value in
  let clock_updated =
    mux2
      r.clock_enable.value
      (r.pin_value.value ^: pin_mask r.clock_pin.value)
      r.pin_value.value
  in
  let phase_pin_value =
    mux2
      (phase_launch &: r.tx_enable.value &: ~:(finishing))
      ((clock_updated &: ~:output_mask) |: (mux2 tx_bit output_mask (zero 8)))
      clock_updated
  in
  compile
    [ r.busy <-- r.busy.value
    ; r.armed <-- r.armed.value
    ; r.bit_count <-- r.bit_count.value
    ; r.bit_index <-- r.bit_index.value
    ; r.tx_value <-- r.tx_value.value
    ; r.rx_value <-- r.rx_value.value
    ; r.rx_data <-- r.rx_data.value
    ; r.tx_enable <-- r.tx_enable.value
    ; r.rx_enable <-- r.rx_enable.value
    ; r.lsb_first <-- r.lsb_first.value
    ; r.output_pin <-- r.output_pin.value
    ; r.input_pin <-- r.input_pin.value
    ; r.clock_pin <-- r.clock_pin.value
    ; r.clock_enable <-- r.clock_enable.value
    ; r.idle_clock <-- r.idle_clock.value
    ; r.launch_trailing <-- r.launch_trailing.value
    ; r.sample_trailing <-- r.sample_trailing.value
    ; r.observed <-- r.observed.value
    ; r.half_period <-- r.half_period.value
    ; r.remaining <-- r.remaining.value
    ; r.trailing <-- r.trailing.value
    ; r.claim_mask <-- r.claim_mask.value
    ; r.prepared_mask <-- r.prepared_mask.value
    ; r.prepared_pin_value <-- r.prepared_pin_value.value
    ; r.pin_value <-- r.pin_value.value
    ; r.pin_oe <-- r.pin_oe.value
    ; r.done_ <--. 0
    ; r.rx_valid <--. 0
    ; r.rejected <--. 0
    ; r.underrun <--. 0
    ; r.overrun <--. 0
    ; if_
        (~:(i.enable_i) |: i.abort_i)
        [ r.busy <--. 0
        ; r.armed <--. 0
        ; r.claim_mask <--. 0
        ; r.pin_value <--. 0
        ; r.pin_oe <--. 0
        ; r.remaining <--. 0
        ]
        [ if_
            accept
            [ if_
                (structural_invalid |: (~:(i.arm_i) &: occupied))
                [ r.rejected <--. 1 ]
                [ if_
                    (i.tx_enable_i &: ~:(i.tx_valid_i))
                    [ r.underrun <--. 1 ]
                    [ r.busy <-- ~:(i.arm_i)
                    ; r.armed <-- i.arm_i
                    ; r.bit_count <-- i.bit_count_i
                    ; r.bit_index <--. 0
                    ; r.tx_value <-- i.tx_value_i
                    ; r.rx_value <--. 0
                    ; r.tx_enable <-- i.tx_enable_i
                    ; r.rx_enable <-- i.rx_enable_i
                    ; r.lsb_first <-- i.lsb_first_i
                    ; r.output_pin <-- i.output_pin_i
                    ; r.input_pin <-- i.input_pin_i
                    ; r.clock_pin <-- i.clock_pin_i
                    ; r.clock_enable <-- i.clock_enable_i
                    ; r.idle_clock <-- i.idle_clock_i
                    ; r.launch_trailing <-- i.launch_trailing_i
                    ; r.sample_trailing <-- i.sample_trailing_i
                    ; r.observed <-- i.observed_i
                    ; r.half_period <-- i.half_period_i
                    ; r.remaining
                      <-- (mux2
                             (i.initial_delay_i ==:. 0)
                             i.half_period_i
                             i.initial_delay_i)
                    ; r.trailing <--. 0
                    ; r.prepared_mask <-- driven
                    ; r.claim_mask <-- (mux2 i.arm_i (zero 8) driven)
                    ; r.pin_oe <-- (mux2 i.arm_i (zero 8) driven)
                    ; r.prepared_pin_value <-- preload_value
                    ; r.pin_value <-- (mux2 i.arm_i (zero 8) preload_value)
                    ]
                ]
            ]
            [ when_
                (r.armed.value &: i.start_event_i)
                [ r.armed <--. 0
                ; if_
                    ((r.prepared_mask.value &: i.occupied_i) <>:. 0)
                    [ r.rejected <--. 1 ]
                    [ r.busy <--. 1
                    ; r.claim_mask <-- r.prepared_mask.value
                    ; r.pin_oe <-- r.prepared_mask.value
                    ; r.pin_value <-- r.prepared_pin_value.value
                    ]
                ]
            ; when_
                r.busy.value
                [ when_
                    (~:(r.observed.value) &: ~:advance)
                    [ r.remaining <-- r.remaining.value -:. 1 ]
                ; when_
                    advance
                    [ when_
                        ~:(r.observed.value)
                        [ r.remaining <-- r.half_period.value ]
                    ; r.pin_value <-- phase_pin_value
                    ; when_ phase_sample [ r.rx_value <-- next_rx ]
                    ; if_
                        finishing
                        [ if_
                            (r.rx_enable.value &: ~:(i.rx_ready_i))
                            [ r.overrun <--. 1 ]
                            [ r.done_ <--. 1
                            ; when_
                                r.rx_enable.value
                                [ r.rx_data
                                  <-- (mux2 phase_sample next_rx r.rx_value.value)
                                ; r.rx_valid <--. 1
                                ]
                            ]
                        ; r.busy <--. 0
                        ; r.claim_mask <--. 0
                        ; r.pin_oe <--. 0
                        ]
                        [ if_
                            r.trailing.value
                            [ r.trailing <--. 0
                            ; r.bit_index <-- r.bit_index.value +:. 1
                            ]
                            [ r.trailing <--. 1 ]
                        ]
                    ]
                ]
            ]
        ]
    ];
  { O.ready_o = i.enable_i &: ~:(r.busy.value) &: ~:(r.armed.value)
  ; busy_o = r.busy.value
  ; armed_o = r.armed.value
  ; claim_mask_o = r.claim_mask.value
  ; pin_value_o = r.pin_value.value
  ; pin_oe_o = r.pin_oe.value
  ; done_o = r.done_.value
  ; rx_valid_o = r.rx_valid.value
  ; rx_data_o = r.rx_data.value
  ; rejected_o = r.rejected.value
  ; underrun_o = r.underrun.value
  ; overrun_o = r.overrun.value
  }
;;
