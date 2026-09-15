open! Core
open! Hardcaml
open! Signal

module Protocol_data_feed_type = struct
  type t =
    | Serial
    | Protocol
end

module Protocol_clock_source = struct
  type t =
    | Internal
    | External
end

module Config = struct
  let protocol_kind : Protocol_data_feed_type.t = Serial
  let clock_type : Protocol_clock_source.t = Internal
end

(* take in a clock, reset, and general enable *)
module I = struct
  type 'a t =
    { clock_i : 'a
    ; reset_i : 'a
    ; en_i : 'a
    }
  [@@deriving hardcaml]
end

(* use a basic output bank of 8 pins for now *)
module O = struct
  type 'a t = { pins_o : 'a [@bits 8] } [@@deriving hardcaml]
end
(* This example circuit will present a generic pin interface programming layer for UART as
   an example

   UART : https://en.wikipedia.org/wiki/Universal_asynchronous_receiver-transmitter

   We need to generate an internal clock for this typing.
*)

(* standard instruction pipeline parsing and execution *)
module States = struct
  type t =
    | Idle_s
    | Fetch_s
    | Decode_s
    | Execute_s
  [@@deriving sexp_of, compare ~localize, enumerate]
end

(* Registers. Obey-ant to my standard I_Wires I_Regs dichotomy that I like to use. *)
module I_Regs = struct
  type 'a t =
    { pc : 'a [@bits 8]
    ; i_mem_waddr : 'a [@bits 8]
    ; i_mem_wren : 'a
    ; i_mem_wrdata : 'a [@bits 8]
    }
  [@@deriving hardcaml]
end

(* Combinational (Moore) strobes — default 0, raised in-state *)
module I_Wires = struct
  type 'a t = { pc_inc : 'a } [@@deriving hardcaml]
end

[@@@ocamlformat "disable"]
let create (scope : Scope.t) (i : _ I.t) : _ O.t =
  let open Always in
  (* spec *)
  let spec = Reg_spec.create ~clock:i.clock_i ~clear:i.reset_i () in
  (* tagging helper in named scope *)
  let ( -- ) = Scope.naming scope in

  (* state machine assignment *)
  let sm = State_machine.create (module States) ~enable:i.en_i spec in

  (* regs *)
  let r  = I_Regs.Of_always.reg ~enable:i.en_i spec in
  I_Regs.Of_always.apply_names ~prefix:"reg_" ~naming_op:(Scope.naming scope) r;

  (* wires *)
  let w  = I_Wires.Of_always.wire Signal.zero in
  I_Wires.Of_always.apply_names ~prefix:"wire_" ~naming_op:(Scope.naming scope) w;

  (* aliases *)
  let pc            = r.pc in
  let i_mem_waddr   = r.i_mem_waddr in
  let i_mem_wren    = r.i_mem_wren in
  let i_mem_wrdata  = r.i_mem_wrdata in

  (* actual FSM transitions *)
  compile
    [ (* registered defaults: hold address/data, write-enable is a one-cycle pulse *)
      i_mem_waddr  <-- i_mem_waddr.value
    ; i_mem_wrdata <-- i_mem_wrdata.value
    ; i_mem_wren   <--. 0
    ; when_ w.pc_inc.value [ pc <-- pc.value +:. 1 ]
    ; (* Moore outputs per state *)
      sm.switch ~default:[]
        [ Fetch_s, [ w.pc_inc <--. 1 ] ]
    ; (* next-state logic *)
      sm.switch ~default:[ sm.set_next Idle_s ]
        [ Idle_s,    [ sm.set_next Fetch_s ]
        ; Fetch_s,   [ sm.set_next Decode_s ]
        ; Decode_s,  [ sm.set_next Execute_s ]
        ; Execute_s, [ sm.set_next Fetch_s ]
        ]
    ];

  (* let instruction_mem_write_port =  *)
  (*   { write_clock =  *)

  (*   } in *)

  (* memory for the fetch stage to read from *)
  let i_mem =
    memory 256
      ~write_port:{
        write_clock = i.clock_i
        ; write_address = i_mem_waddr.value
        ; write_enable = i_mem_wren.value
        ; write_data = i_mem_wrdata.value
      }
      ~read_address:pc.value
  in

  { O.pins_o = Signal.zero 8 }
[@@@ocamlformat "enable"]
