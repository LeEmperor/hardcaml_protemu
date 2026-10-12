(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "byte_fifo.ml" *)
(* A small flop-backed byte queue with separate push and pop handshakes.

   Protocol blocks can use [push_ready_o] and [pop_valid_o] to transfer one byte per
   edge. The default depth is eight; [create] also accepts four or sixteen entries.

   A pop from a full queue frees a slot for a push on the same edge. Reset clears the
   control registers; disabling the queue clears its occupancy and indices. Neither
   operation clears the data flops, whose contents are ignored while the queue is empty.
   This block does not interpret bytes or decide when a producer should retry.
*)

open! Core
open! Hardcaml
open! Signal

(* Inputs to the queue; both handshakes use [clock_i]'s rising edge. *)
module I = struct
  type 'a t =
    { (* Synchronous, active-high reset; [enable_i] gates both handshakes. *)
      clock_i : 'a
    ; reset_i : 'a
    ; enable_i : 'a
    ; (* Producer -> queue. A byte enters when valid and ready are both high. *)
      push_valid_i : 'a
    ; push_data_i : 'a [@bits 8]
    ; (* Consumer -> queue. The oldest byte leaves when ready and valid are high. *)
      pop_ready_i : 'a
    }
  [@@deriving hardcaml]
end

(* Queue status and the two handshake responses. *)
module O = struct
  type 'a t =
    { push_ready_o : 'a
    ; pop_valid_o : 'a
    ; pop_data_o : 'a [@bits 8]
    ; count_o : 'a [@bits 5]
    ; (* Sticky attempted-handshake faults; reset clears them. *)
      overflow_o : 'a
    ; starvation_o : 'a
    }
  [@@deriving hardcaml]
end

[@@@ocamlformat "disable"]
(* Registered queue control; [compile] gives each field a hold value before updates.

   read_index  : address of the oldest byte;
   write_index : address of the next free slot;
   count       : number of valid bytes, independent of the data flop contents;
   overflow    : a push was attempted while [push_ready_o] was low;
   starvation  : a pop was attempted while [pop_valid_o] was low;
*)
module I_Regs = struct
  type 'a t =
    { read_index    : 'a [@bits 4]
    ; write_index   : 'a [@bits 4]
    ; count         : 'a [@bits 5]
    ; overflow      : 'a
    ; starvation    : 'a
    }
  [@@deriving hardcaml]
end

(* Build the queue and its edge-level handshakes;

   Only depths 4, 8 and 16 are supported; the indices are four bits and the output
   mux has sixteen entries. 
   An invalid depth raises at circuit construction time.

   A full queue reports ready when a pop fires on this edge. 
   In that case the pop observes the old head, then the push writes the newly free slot; 
   the occupancy stays constant. Neither handshake fires while [enable_i] is low.
*)
let create ?(depth = 8) (scope : Scope.t) (i : _ I.t) : _ O.t =
  (* arg validator *)
  if not (List.mem [ 4; 8; 16 ] depth ~equal:Int.equal)
  then invalid_arg "byte FIFO depth must be 4, 8, or 16";

  (* i am a shadow ninja *)
  let open Always in

  (* spec *)
  (* also reg block setup *)
  let spec = Reg_spec.create ~clock:i.clock_i ~clear:i.reset_i () in
  let r = I_Regs.Of_always.reg spec in
  I_Regs.Of_always.apply_names ~prefix:"reg_" ~naming_op:(Scope.naming scope) r;

  (* spot deriveable items *)
  let nonempty    = r.count.value <>:. 0 in
  let pop_valid   = i.enable_i &: nonempty in
  let pop_fire    = pop_valid &: i.pop_ready_i in
  let push_ready  =
    i.enable_i &: 
      ((r.count.value <: of_int_trunc ~width:5 depth) 
      |: pop_fire)
  in
  let push_fire = i.push_valid_i &: push_ready in

  (* Data has no reset; occupancy determines which stored bytes are valid. *)
  let data_spec = Reg_spec.create ~clock:i.clock_i () in

  (* Reg-based mem cells; adding a later validation against large sizing for flop-based may be an issue;
    A fifo that creates from hardcaml_asic backed memory primitives might be nicer.
   *)
  let cells =
    List.init depth ~f:(fun n ->
      reg
        data_spec
        ~enable:(push_fire &: (r.write_index.value ==:. n))
        i.push_data_i)
  in

  (* [mux] needs one input for every four-bit index, even at smaller depths. *)
  let padded_cells = 
    cells @ 
    List.init (16 - depth) ~f:(fun _ -> zero 8) 
  in

  (* Explicit wrap handles depths that use less than the full index range. *)
  let next_index index =
    mux2 
    (* index == depth - 1? wrap bit accounting *)
    (index ==:. depth - 1) 

    (* yes - then zero out *)
    (zero 4) 

    (* no - increm*)
    (index +:. 1)
  in

  (* Hold by default; disabling drops queued bytes, while fault flags remain sticky
     until reset. Push and pop together advance both indices without changing count. 
  *)
  compile
    [ r.read_index  <-- r.read_index.value
    ; r.write_index <-- r.write_index.value
    ; r.count       <-- r.count.value
    ; r.overflow    <-- r.overflow.value
    ; r.starvation  <-- r.starvation.value
    ; if_
        ~:(i.enable_i) (* kid named enable who doesn't like timing *)
        (* zero out from default *)
        [ r.read_index  <--. 0
        ; r.write_index <--. 0
        ; r.count       <--. 0
        ]
        [ when_
            pop_fire (* pop *)
            [ r.read_index <-- next_index r.read_index.value ]
        ; when_
            push_fire (* push *)
            [ r.write_index <-- next_index r.write_index.value ]
        ; when_
            (push_fire &: ~:pop_fire) (* 01 *)
            [ r.count <-- r.count.value +:. 1 ]
        ; when_
            (pop_fire &: ~:push_fire) (* 10*)
            [ r.count <-- r.count.value -:. 1 ]
        ; when_
            (i.push_valid_i &: ~:push_ready) (* push but we of *)
            [ r.overflow <--. 1 ]
        ; when_
            (i.pop_ready_i &: ~:pop_valid) (* pop but we have nothing *)
            [ r.starvation <--. 1 ]
        ]
    ];

  { O.push_ready_o  = push_ready
  ; pop_valid_o     = pop_valid

  (* spot derivating for empty declarator affecting the actaul fanned data; we could aruge that pop_valid being low solves this but zero'ing out is probably fine here; *)
  ; pop_data_o      = mux2 
                        nonempty 
                        (mux r.read_index.value padded_cells) 
                        (zero 8)

  ; count_o         = r.count.value
  ; overflow_o      = r.overflow.value
  ; starvation_o    = r.starvation.value
  }
;;
[@@@ocamlformat "enable"]
