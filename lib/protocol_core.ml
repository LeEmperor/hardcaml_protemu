(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "protocol_core.ml" *)
(* Control-core scaffold: Idle/Fetch/Decode/Execute over an external program store.

   The program store is NOT instantiated here. The core drives the port of a single-port
   1RW synchronous RAM that follows hardcaml_asic's program-memory contract: one shared
   address, one enable and one write-enable describe either a read or a write at each
   rising edge, and read data lands one cycle later. While disabled the output holds;
   after a write, or for a never-written word, it is unspecified.

   Keeping the RAM outside lets every core module stay independent of hardcaml_asic. The
   project top instantiates [Single_port_ram] with its elaboration context and connects
   this port; testbenches use a contract model instead.

   Port rules this module keeps:
   - a read is issued in [Fetch_s] and consumed only in [Decode_s], the next cycle;
   - host writes are accepted only while halted ([Idle_s]), so they never take a fetch;
   - read and write never share a cycle.

   Not yet present (P3.1): readback, loaded-image validity and bounds, and a load-complete
   condition before RUN. Decode and Execute are placeholders; the word width and depth
   below are study points, not an ISA decision.
*)

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

  (* Program store shape: a study point for the memory/encoding sweep. *)
  let program_width = 8
  let program_depth = 256
  let program_address_bits = Int.ceil_log2 program_depth
end

module I = struct
  type 'a t =
    { (* System clock domain. Synchronous active-high reset. *)
      clock_i : 'a
    ; reset_i : 'a
    ; en_i : 'a
    ; (* Execution control, level-sensitive. High leaves [Idle_s]; low returns to it at
         the next instruction boundary. *)
      run_i : 'a
    ; (* Host loader -> program store. A word is written when [load_valid_i] and
         [load_ready_o] are both high. *)
      load_valid_i : 'a
    ; load_address_i : 'a [@bits Config.program_address_bits]
    ; load_data_i : 'a [@bits Config.program_width]
    ; (* Program store -> core. Valid one cycle after an enabled read. *)
      prog_mem_read_data_i : 'a [@bits Config.program_width]
    }
  [@@deriving hardcaml]
end

module O = struct
  type 'a t =
    { (* use a basic output bank of 8 pins for now *)
      pins_o : 'a [@bits 8]
    ; (* Core -> program store 1RW port. *)
      prog_mem_enable_o : 'a
    ; prog_mem_write_enable_o : 'a
    ; prog_mem_address_o : 'a [@bits Config.program_address_bits]
    ; prog_mem_write_data_o : 'a [@bits Config.program_width]
    ; (* Host loader handshake. High only while halted. *)
      load_ready_o : 'a
    ; (* Observation. *)
      halted_o : 'a
    ; pc_o : 'a [@bits Config.program_address_bits]
    ; instruction_o : 'a [@bits Config.program_width]
    }
  [@@deriving hardcaml]
end

(* standard instruction pipeline parsing and execution *)
module States = struct
  type t =
    | Idle_s
    | Fetch_s
    | Decode_s
    | Execute_s
  [@@deriving sexp_of, compare ~localize, enumerate]
end

(* Registered state. Every field is assigned inside [compile]. *)
module I_Regs = struct
  type 'a t =
    { pc : 'a [@bits Config.program_address_bits]
    ; instruction : 'a [@bits Config.program_width]
    }
  [@@deriving hardcaml]
end

(* Combinational (Moore) strobes and program-store port drive -- default 0, raised
   in-state. *)
module I_Wires = struct
  type 'a t =
    { pc_inc : 'a
    ; load_ready : 'a
    ; mem_enable : 'a
    ; mem_write_enable : 'a
    ; mem_address : 'a [@bits Config.program_address_bits]
    ; mem_write_data : 'a [@bits Config.program_width]
    }
  [@@deriving hardcaml]
end

let create (scope : Scope.t) (i : _ I.t) : _ O.t =
  let open Always in
  (* spec *)
  let spec = Reg_spec.create ~clock:i.clock_i ~clear:i.reset_i () in
  (* state machine *)
  let sm = State_machine.create (module States) ~enable:i.en_i spec in
  (* regs *)
  let r = I_Regs.Of_always.reg ~enable:i.en_i spec in
  I_Regs.Of_always.apply_names ~prefix:"reg_" ~naming_op:(Scope.naming scope) r;
  (* wires *)
  let w = I_Wires.Of_always.wire Signal.zero in
  I_Wires.Of_always.apply_names ~prefix:"wire_" ~naming_op:(Scope.naming scope) w;
  (* The state machine and registers only advance with [en_i], so port operations are
     gated the same way: a disabled core issues no read or write. *)
  let accepting_load = i.en_i &: i.load_valid_i in
  compile
    [ (* registered defaults *)
      r.pc <-- r.pc.value
    ; r.instruction <-- r.instruction.value
    ; when_ w.pc_inc.value [ r.pc <-- r.pc.value +:. 1 ]
    ; (* Moore outputs per state *)
      sm.switch
        ~default:[]
        [ ( Idle_s
          , [ w.load_ready <-- i.en_i
            ; when_
                accepting_load
                [ w.mem_enable <--. 1
                ; w.mem_write_enable <--. 1
                ; w.mem_address <-- i.load_address_i
                ; w.mem_write_data <-- i.load_data_i
                ]
            ] )
        ; ( Fetch_s
          , [ w.mem_enable <-- i.en_i; w.mem_address <-- r.pc.value; w.pc_inc <--. 1 ] )
        ; (* The read issued in [Fetch_s] is valid now. *)
          Decode_s, [ r.instruction <-- i.prog_mem_read_data_i ]
        ]
    ; (* next-state logic *)
      sm.switch
        ~default:[ sm.set_next Idle_s ]
        [ Idle_s, [ when_ i.run_i [ sm.set_next Fetch_s ] ]
        ; Fetch_s, [ sm.set_next Decode_s ]
        ; Decode_s, [ sm.set_next Execute_s ]
        ; Execute_s, [ if_ i.run_i [ sm.set_next Fetch_s ] [ sm.set_next Idle_s ] ]
        ]
    ];
  { O.pins_o = Signal.zero 8
  ; prog_mem_enable_o = w.mem_enable.value
  ; prog_mem_write_enable_o = w.mem_write_enable.value
  ; prog_mem_address_o = w.mem_address.value
  ; prog_mem_write_data_o = w.mem_write_data.value
  ; load_ready_o = w.load_ready.value
  ; halted_o = sm.is Idle_s
  ; pc_o = r.pc.value
  ; instruction_o = r.instruction.value
  }
;;
