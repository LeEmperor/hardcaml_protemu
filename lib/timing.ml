(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "timing.ml" *)
(* Countdown, level/edge wait, and independent periodic tick. A command accepted at
   edge k with delay n completes at k+n. A matching event wins over timeout. *)

open! Core
open! Hardcaml
open! Signal

module I = struct
  type 'a t =
    { clock_i : 'a
    ; reset_i : 'a
    ; enable_i : 'a
    ; abort_i : 'a
    ; wait_valid_i : 'a
    ; (* 0: cycles, 1: level, 2: rise, 3: fall. *)
      wait_kind_i : 'a [@bits 2]
    ; wait_pin_i : 'a [@bits 3]
    ; wait_level_i : 'a
    ; wait_timeout_enable_i : 'a
    ; wait_delay_i : 'a [@bits 16]
    ; snapshot_i : 'a [@bits 8]
    ; rising_i : 'a [@bits 8]
    ; falling_i : 'a [@bits 8]
    ; periodic_start_i : 'a
    ; periodic_stop_i : 'a
    ; periodic_period_i : 'a [@bits 16]
    ; phase_restart_i : 'a
    }
  [@@deriving hardcaml]
end

module O = struct
  type 'a t =
    { ready_o : 'a
    ; busy_o : 'a
    ; complete_o : 'a
    ; timeout_o : 'a
    ; rejected_o : 'a
    ; tick_o : 'a
    ; remaining_o : 'a [@bits 16]
    }
  [@@deriving hardcaml]
end

module I_Regs = struct
  (* Registered wait and periodic state; status pulses last one cycle. *)
  type 'a t =
    { busy : 'a
    ; kind : 'a [@bits 2]
    ; pin : 'a [@bits 3]
    ; level : 'a
    ; timeout_enable : 'a
    ; remaining : 'a [@bits 16]
    ; periodic_active : 'a
    ; period : 'a [@bits 16]
    ; phase : 'a [@bits 16]
    ; complete : 'a
    ; timeout : 'a
    ; rejected : 'a
    ; tick : 'a
    }
  [@@deriving hardcaml]
end

let create (scope : Scope.t) (i : _ I.t) : _ O.t =
  let open Always in
  let spec = Reg_spec.create ~clock:i.clock_i ~clear:i.reset_i () in
  let r = I_Regs.Of_always.reg spec in
  I_Regs.Of_always.apply_names ~prefix:"reg_" ~naming_op:(Scope.naming scope) r;
  let selected word pin = mux pin (List.init 8 ~f:(fun n -> bit word ~pos:n)) in
  let matched =
    mux
      r.kind.value
      [ gnd
      ; selected i.snapshot_i r.pin.value ==: r.level.value
      ; selected i.rising_i r.pin.value
      ; selected i.falling_i r.pin.value
      ]
  in
  let immediate_level =
    selected i.snapshot_i i.wait_pin_i ==: i.wait_level_i
  in
  let bad_delay =
    (i.wait_kind_i ==:. 0 |: i.wait_timeout_enable_i)
    &: (i.wait_delay_i ==:. 0)
  in
  compile
    [ r.busy <-- r.busy.value
    ; r.kind <-- r.kind.value
    ; r.pin <-- r.pin.value
    ; r.level <-- r.level.value
    ; r.timeout_enable <-- r.timeout_enable.value
    ; r.remaining <-- r.remaining.value
    ; r.periodic_active <-- r.periodic_active.value
    ; r.period <-- r.period.value
    ; r.phase <-- r.phase.value
    ; r.complete <--. 0
    ; r.timeout <--. 0
    ; r.rejected <--. 0
    ; r.tick <--. 0
    ; if_
        (~:(i.enable_i) |: i.abort_i)
        [ r.busy <--. 0
        ; r.remaining <--. 0
        ; r.periodic_active <--. 0
        ; r.phase <--. 0
        ]
        [ if_
            r.busy.value
            [ if_
                matched
                [ r.busy <--. 0; r.remaining <--. 0; r.complete <--. 1 ]
                [ if_
                    ((r.kind.value ==:. 0 |: r.timeout_enable.value)
                     &: (r.remaining.value ==:. 1))
                    [ r.busy <--. 0
                    ; r.remaining <--. 0
                    ; if_
                        (r.kind.value ==:. 0)
                        [ r.complete <--. 1 ]
                        [ r.timeout <--. 1 ]
                    ]
                    [ when_
                        (r.kind.value ==:. 0 |: r.timeout_enable.value)
                        [ r.remaining <-- r.remaining.value -:. 1 ]
                    ]
                ]
            ]
            [ when_
                i.wait_valid_i
                [ if_
                    bad_delay
                    [ r.rejected <--. 1 ]
                    [ if_
                        ((i.wait_kind_i ==:. 1) &: immediate_level)
                        []
                        [ r.busy <--. 1
                        ; r.kind <-- i.wait_kind_i
                        ; r.pin <-- i.wait_pin_i
                        ; r.level <-- i.wait_level_i
                        ; r.timeout_enable <-- i.wait_timeout_enable_i
                        ; r.remaining <-- i.wait_delay_i
                        ]
                    ]
                ]
            ]
        ; when_
            i.periodic_stop_i
            [ r.periodic_active <--. 0; r.phase <--. 0 ]
        ; when_
            i.periodic_start_i
            [ if_
                (i.periodic_period_i ==:. 0)
                [ r.rejected <--. 1 ]
                [ r.periodic_active <--. 1
                ; r.period <-- i.periodic_period_i
                ; r.phase <-- i.periodic_period_i
                ]
            ]
        ; when_
            (r.periodic_active.value
             &: ~:(i.periodic_start_i)
             &: ~:(i.periodic_stop_i))
            [ if_
                i.phase_restart_i
                [ r.phase <-- r.period.value ]
                [ if_
                    (r.phase.value ==:. 1)
                    [ r.tick <--. 1; r.phase <-- r.period.value ]
                    [ r.phase <-- r.phase.value -:. 1 ]
                ]
            ]
        ]
    ];
  { O.ready_o = i.enable_i &: ~:(r.busy.value)
  ; busy_o = r.busy.value
  ; complete_o = r.complete.value
  ; timeout_o = r.timeout.value
  ; rejected_o = r.rejected.value
  ; tick_o = r.tick.value
  ; remaining_o = r.remaining.value
  }
;;
