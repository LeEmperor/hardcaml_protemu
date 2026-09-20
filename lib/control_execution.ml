(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "control_execution.ml" *)
(* Minimal P3.2 execution client for the P1.5 ISA.

   This block owns architectural state but not program-memory validity or bounds. It uses
   Protocol_core's accepted RUN and latency-one fetch completion, executes core-local
   instructions, and presents all mechanism instructions on one retained command port.
*)

open! Core
open! Hardcaml
open! Signal
open! Protemu_isa

module Config = struct
  let pc_bits = 17
  let count_bits = 32
  let mechanism_kind_bits = 4
  let mechanism_reason_bits = 8
  let descriptor_bits = Descriptor.Field.count * Instruction.Register.width
end

module Execution_config = Config

module Mechanism_kind = struct
  let read_pins = 0
  let read_status = 1
  let ack_status = 2
  let branch_pin = 3
  let write_pins_imm = 4
  let write_pins_reg = 5
  let wait_cycles_imm = 6
  let wait_cycles_reg = 7
  let wait_level = 8
  let wait_edge = 9
  let start_periodic = 10
  let stop_periodic = 11
  let issue_transfer = 12
  let fifo_push = 13
  let fifo_pop = 14
end

module Fault = struct
  let width = 4
  let none = 0
  let invalid_base = 1
  let invalid_extension = 2
  let fetch_bounds = 3
  let truncated_extension = 4
  let target_unrepresentable = 5
  let mechanism_refused = 6
  let mechanism_completion = 7
  let unsolicited_completion = 8
  let mechanism_protocol = 9
end

module Phase = struct
  let width = 3
  let halted = 0
  let fetch = 1
  let base_wait = 2
  let extension_wait = 3
  let mechanism_offer = 4
  let mechanism_wait = 5
  let fault = 6
end

module I = struct
  type 'a t =
    { clock_i : 'a
    ; reset_i : 'a
    ; en_i : 'a
    ; run_accepted_i : 'a
    ; fetch_accepted_i : 'a
    ; fetch_rejected_i : 'a
    ; fetch_fault_i : 'a
    ; fetch_completion_valid_i : 'a
    ; fetch_completion_data_i : 'a [@bits Encoding.instruction_bits]
    ; mechanism_accepted_i : 'a
    ; mechanism_refused_i : 'a
    ; mechanism_refusal_reason_i : 'a [@bits Config.mechanism_reason_bits]
    ; mechanism_completion_valid_i : 'a
    ; mechanism_completion_result_i : 'a [@bits Instruction.Register.width]
    ; mechanism_completion_fault_i : 'a
    ; mechanism_completion_reason_i : 'a [@bits Config.mechanism_reason_bits]
    }
  [@@deriving hardcaml]
end

module O = struct
  type 'a t =
    { fetch_valid_o : 'a
    ; fetch_address_o : 'a [@bits Protocol_core.Config.request_address_bits]
    ; execution_halt_o : 'a
    ; mechanism_request_valid_o : 'a
    ; mechanism_kind_o : 'a [@bits Config.mechanism_kind_bits]
    ; mechanism_arg0_o : 'a [@bits Instruction.Register.width]
    ; mechanism_arg1_o : 'a [@bits Instruction.Register.width]
    ; mechanism_arg2_o : 'a [@bits Instruction.Register.width]
    ; mechanism_timeout_enable_o : 'a
    ; mechanism_descriptor_o : 'a [@bits Config.descriptor_bits]
    ; active_o : 'a
    ; normal_halt_o : 'a
    ; execution_fault_o : 'a
    ; fault_kind_o : 'a [@bits Fault.width]
    ; fault_instruction_slot_o : 'a [@bits Config.pc_bits]
    ; fault_address_o : 'a [@bits Config.pc_bits]
    ; fault_reason_o : 'a [@bits Config.mechanism_reason_bits]
    ; instruction_boundary_o : 'a
    ; retired_o : 'a
    ; pc_o : 'a [@bits Config.pc_bits]
    ; registers_o : 'a [@bits Instruction.Register.count * Instruction.Register.width]
    ; zero_o : 'a
    ; carry_o : 'a
    ; negative_o : 'a
    ; descriptor_o : 'a [@bits Config.descriptor_bits]
    ; phase_o : 'a [@bits Phase.width]
    ; fetch_cycles_o : 'a [@bits Config.count_bits]
    ; execute_cycles_o : 'a [@bits Config.count_bits]
    ; stall_cycles_o : 'a [@bits Config.count_bits]
    ; instruction_count_o : 'a [@bits Config.count_bits]
    ; extension_fetches_o : 'a [@bits Config.count_bits]
    ; total_cycles_o : 'a [@bits Config.count_bits]
    }
  [@@deriving hardcaml]
end

[@@@ocamlformat "disable"]

module I_Regs = struct
  type 'a t =
    { phase                  : 'a [@bits Phase.width]
    ; pc                     : 'a [@bits Config.pc_bits]
    ; base_word              : 'a [@bits Encoding.instruction_bits]
    ; extension_word         : 'a [@bits Encoding.instruction_bits]
    ; has_extension          : 'a
    ; last_instruction_slot  : 'a [@bits Config.pc_bits]
    ; r0                     : 'a [@bits Instruction.Register.width]
    ; r1                     : 'a [@bits Instruction.Register.width]
    ; r2                     : 'a [@bits Instruction.Register.width]
    ; r3                     : 'a [@bits Instruction.Register.width]
    ; r4                     : 'a [@bits Instruction.Register.width]
    ; r5                     : 'a [@bits Instruction.Register.width]
    ; r6                     : 'a [@bits Instruction.Register.width]
    ; r7                     : 'a [@bits Instruction.Register.width]
    ; zero                   : 'a
    ; carry                  : 'a
    ; negative               : 'a
    ; desc_control           : 'a [@bits Instruction.Register.width]
    ; desc_bit_count         : 'a [@bits Instruction.Register.width]
    ; desc_tx_value          : 'a [@bits Instruction.Register.width]
    ; desc_output_pin        : 'a [@bits Instruction.Register.width]
    ; desc_input_pin         : 'a [@bits Instruction.Register.width]
    ; desc_clock_pin         : 'a [@bits Instruction.Register.width]
    ; desc_initial_delay     : 'a [@bits Instruction.Register.width]
    ; desc_half_period       : 'a [@bits Instruction.Register.width]
    ; desc_pacing            : 'a [@bits Instruction.Register.width]
    ; normal_halt            : 'a
    ; execution_fault        : 'a
    ; fault_kind             : 'a [@bits Fault.width]
    ; fault_instruction_slot : 'a [@bits Config.pc_bits]
    ; fault_address          : 'a [@bits Config.pc_bits]
    ; fault_reason           : 'a [@bits Config.mechanism_reason_bits]
    ; boundary               : 'a
    ; retired                : 'a
    ; fetch_cycles           : 'a [@bits Config.count_bits]
    ; execute_cycles         : 'a [@bits Config.count_bits]
    ; stall_cycles           : 'a [@bits Config.count_bits]
    ; instruction_count      : 'a [@bits Config.count_bits]
    ; extension_fetches      : 'a [@bits Config.count_bits]
    ; total_cycles           : 'a [@bits Config.count_bits]
    }
  [@@deriving hardcaml]
end

let const ~width value = of_int_trunc ~width value
let field = Instruction_decoder.field

let enum_index all ~equal value = Protemu_isa.Enum.index all ~equal value

let create (scope : Scope.t) (i : _ I.t) : _ O.t =
  let open Always in
  let open Encoding.Layout in
  let spec = Reg_spec.create ~clock:i.clock_i ~clear:i.reset_i () in
  let r = I_Regs.Of_always.reg spec in
  I_Regs.Of_always.apply_names ~prefix:"reg_" ~naming_op:(Scope.naming scope) r;
  let in_phase value = r.phase.value ==:. value in

  let registers = [ r.r0.value; r.r1.value; r.r2.value; r.r3.value;
                    r.r4.value; r.r5.value; r.r6.value; r.r7.value ] in
  let read_reg index = mux index registers in
  let descriptor =
    concat_msb
      [ r.desc_pacing.value; r.desc_half_period.value; r.desc_initial_delay.value;
        r.desc_clock_pin.value; r.desc_input_pin.value; r.desc_output_pin.value;
        r.desc_tx_value.value; r.desc_bit_count.value; r.desc_control.value ]
  in

  let in_base_wait = in_phase Phase.base_wait in
  let in_extension_wait = in_phase Phase.extension_wait in
  let in_mechanism_offer = in_phase Phase.mechanism_offer in
  let in_mechanism_wait = in_phase Phase.mechanism_wait in
  let base_completion = in_base_wait &: i.fetch_completion_valid_i in
  let extension_completion = in_extension_wait &: i.fetch_completion_valid_i in
  let decode_word = mux2 in_base_wait i.fetch_completion_data_i r.base_word.value in
  let decode_extension = mux2 in_extension_wait i.fetch_completion_data_i r.extension_word.value in
  let decode_extension_valid =
    (in_extension_wait &: i.fetch_completion_valid_i)
    |: ((in_mechanism_offer |: in_mechanism_wait) &: r.has_extension.value)
  in
  let decoded =
    Instruction_decoder.create
      (Scope.sub_scope scope "decoder")
      { Instruction_decoder.I.word_i = decode_word
      ; extension_valid_i = decode_extension_valid
      ; extension_i = decode_extension
      }
  in
  let extension_needed =
    base_completion &: decoded.base_valid_o &: decoded.needs_extension_o
  in
  let ordinary_ready =
    base_completion &: decoded.base_valid_o &: ~:(decoded.needs_extension_o)
  in
  let extended_ready = extension_completion &: decoded.valid_o in
  let instruction_ready = ordinary_ready |: extended_ready in
  let instruction_slots = mux2 decoded.needs_extension_o (const ~width:Execution_config.pc_bits 2) (const ~width:Execution_config.pc_bits 1) in
  let sequential_pc = r.pc.value +: instruction_slots in
  let opcode_is value = decoded.opcode_o ==:. value in

  let local_opcode =
    opcode_is Halt.opcode
    |: opcode_is Ldi.opcode
    |: opcode_is Mov.opcode
    |: opcode_is Alu.opcode
    |: opcode_is Alu_imm.opcode
    |: opcode_is Cmp.opcode
    |: opcode_is Cmp_imm.opcode
    |: opcode_is Shift.opcode
    |: opcode_is Jump.opcode
    |: opcode_is Branch.opcode
    |: opcode_is Dbnz.opcode
    |: opcode_is Call.opcode
    |: opcode_is Jump_reg.opcode
    |: opcode_is Config.opcode
  in
  let local_execute = instruction_ready &: local_opcode in
  let mechanism_initial = instruction_ready &: ~:local_opcode in
  let mechanism_request = mechanism_initial |: in_mechanism_offer in

  let rd = field decode_word Ldi.rd in
  let mov_rs = field decode_word Mov.rs in
  let alu_rd = field decode_word Alu.rd in
  let alu_rs = field decode_word Alu.rs in
  let alu_op = field decode_word Alu.op in
  let alu_imm_rd = field decode_word Alu_imm.rd in
  let alu_imm_op = field decode_word Alu_imm.op in
  let cmp_ra = field decode_word Cmp.ra in
  let cmp_rb = field decode_word Cmp.rb in
  let cmp_imm_ra = field decode_word Cmp_imm.ra in
  let shift_rd = field decode_word Shift.rd in
  let shift_amount = field decode_word Shift.amount in

  let add_result a b =
    let wide = uresize a ~width:17 +: uresize b ~width:17 in
    select wide ~high:15 ~low:0, bit wide ~pos:16
  in
  let sub_result a b = a -: b, a <: b in
  let alu_result op a b =
    let add, add_carry = add_result a b in
    let sub, sub_borrow = sub_result a b in
    let result = mux op [ add; sub; a &: b; a |: b; a ^: b; zero 16; zero 16; zero 16 ] in
    let carry = mux op [ add_carry; sub_borrow; gnd; gnd; gnd; gnd; gnd; gnd ] in
    result, carry
  in
  let alu_a = read_reg alu_rd in
  let alu_b = read_reg alu_rs in
  let alu_value, alu_carry = alu_result alu_op alu_a alu_b in
  let alu_imm_a = read_reg alu_imm_rd in
  let alu_imm_value, alu_imm_carry = alu_result alu_imm_op alu_imm_a decoded.immediate_o in
  let cmp_value, cmp_carry = sub_result (read_reg cmp_ra) (read_reg cmp_rb) in
  let cmp_imm_value, cmp_imm_carry = sub_result (read_reg cmp_imm_ra) decoded.immediate_o in
  let shift_source = read_reg shift_rd in
  let shift_left = log_shift ~f:sll shift_source ~by:shift_amount in
  let shift_right = log_shift ~f:srl shift_source ~by:shift_amount in
  let shift_left_carry =
    mux shift_amount (gnd :: List.init 15 ~f:(fun n -> bit shift_source ~pos:(15 - n)))
  in
  let shift_right_carry =
    mux shift_amount (gnd :: List.init 15 ~f:(fun n -> bit shift_source ~pos:n))
  in
  let shift_is_right = field decode_word Shift.dir in
  let shift_value = mux2 shift_is_right shift_right shift_left in
  let shift_carry = mux2 shift_is_right shift_right_carry shift_left_carry in

  let flag_zero value = value ==:. 0 in
  let flag_negative value = bit value ~pos:15 in
  let condition =
    mux
      (field decode_word Branch.cond)
      [ r.zero.value; ~:(r.zero.value); r.carry.value; ~:(r.carry.value);
        r.negative.value; ~:(r.negative.value); gnd; gnd ]
  in
  let signed_field f = sresize (field decode_word f) ~width:Execution_config.pc_bits in
  let jump_target f = r.pc.value +: const ~width:Execution_config.pc_bits 1 +: signed_field f in
  let branch_pc = mux2 condition (jump_target Branch.disp) sequential_pc in
  let dbnz_rd = field decode_word Dbnz.rd in
  let dbnz_value = read_reg dbnz_rd -:. 1 in
  let dbnz_pc = mux2 (dbnz_value <>:. 0) (jump_target Dbnz.disp) sequential_pc in

  let mechanism_kind =
    mux
      decoded.opcode_o
      (List.init Encoding.opcode_count ~f:(fun op ->
         let value =
           if op = Read_pins.opcode then Mechanism_kind.read_pins
           else if op = Read_status.opcode then Mechanism_kind.read_status
           else if op = Ack_status.opcode then Mechanism_kind.ack_status
           else if op = Branch_pin.opcode then Mechanism_kind.branch_pin
           else if op = Write_pins_imm.opcode then Mechanism_kind.write_pins_imm
           else if op = Write_pins_reg.opcode then Mechanism_kind.write_pins_reg
           else if op = Wait_cycles_imm.opcode then Mechanism_kind.wait_cycles_imm
           else if op = Wait_cycles_reg.opcode then Mechanism_kind.wait_cycles_reg
           else if op = Wait_level.opcode then Mechanism_kind.wait_level
           else if op = Wait_edge.opcode then Mechanism_kind.wait_edge
           else if op = Start_periodic.opcode then Mechanism_kind.start_periodic
           else if op = Stop_periodic.opcode then Mechanism_kind.stop_periodic
           else if op = Issue_transfer.opcode then Mechanism_kind.issue_transfer
           else if op = Fifo_push.opcode then Mechanism_kind.fifo_push
           else if op = Fifo_pop.opcode then Mechanism_kind.fifo_pop
           else 0
         in
         const ~width:Execution_config.mechanism_kind_bits value))
  in
  let timeout_enable =
    mux2
      (opcode_is Wait_level.opcode)
      (field decode_word Wait_level.timed)
      (mux2 (opcode_is Wait_edge.opcode) (field decode_word Wait_edge.timed) gnd)
  in
  let mechanism_arg0 =
    mux
      decoded.opcode_o
      (List.init Encoding.opcode_count ~f:(fun op ->
         if op = Read_pins.opcode then uresize (field decode_word Read_pins.rd) ~width:16
         else if op = Read_status.opcode then uresize (field decode_word Read_status.rd) ~width:16
         else if op = Ack_status.opcode then uresize (field decode_word Ack_status.mask) ~width:16
         else if op = Branch_pin.opcode then uresize (field decode_word Branch_pin.pin) ~width:16
         else if op = Write_pins_imm.opcode then uresize (field decode_word Write_pins_imm.mode) ~width:16
         else if op = Write_pins_reg.opcode then uresize (field decode_word Write_pins_reg.mode) ~width:16
         else if op = Wait_cycles_imm.opcode then decoded.immediate_o
         else if op = Wait_cycles_reg.opcode then read_reg (field decode_word Wait_cycles_reg.rd)
         else if op = Wait_level.opcode then uresize (field decode_word Wait_level.pin) ~width:16
         else if op = Wait_edge.opcode then uresize (field decode_word Wait_edge.pin) ~width:16
         else if op = Start_periodic.opcode then decoded.immediate_o
         else if op = Fifo_push.opcode then uresize (field decode_word Fifo_push.fifo) ~width:16
         else if op = Fifo_pop.opcode then uresize (field decode_word Fifo_pop.fifo) ~width:16
         else zero 16))
  in
  let mechanism_arg1 =
    mux
      decoded.opcode_o
      (List.init Encoding.opcode_count ~f:(fun op ->
         if op = Branch_pin.opcode then uresize (field decode_word Branch_pin.level) ~width:16
         else if op = Write_pins_imm.opcode then uresize (field decode_word Write_pins_imm.mask) ~width:16
         else if op = Write_pins_reg.opcode then read_reg (field decode_word Write_pins_reg.mask_reg)
         else if op = Wait_level.opcode then uresize (field decode_word Wait_level.level) ~width:16
         else if op = Wait_edge.opcode then uresize (field decode_word Wait_edge.edge) ~width:16
         else if op = Fifo_push.opcode then uresize (field decode_word Fifo_push.blocking) ~width:16
         else if op = Fifo_pop.opcode then uresize (field decode_word Fifo_pop.blocking) ~width:16
         else zero 16))
  in
  let mechanism_arg2 =
    mux
      decoded.opcode_o
      (List.init Encoding.opcode_count ~f:(fun op ->
         if op = Write_pins_imm.opcode then decoded.immediate_o
         else if op = Write_pins_reg.opcode then read_reg (field decode_word Write_pins_reg.value_reg)
         else if op = Wait_level.opcode || op = Wait_edge.opcode then decoded.immediate_o
         else if op = Fifo_push.opcode then read_reg (field decode_word Fifo_push.reg)
         else zero 16))
  in

  let mechanism_decision_conflict =
    mechanism_request &: i.mechanism_accepted_i &: i.mechanism_refused_i
  in
  let mechanism_accepted =
    mechanism_request &: i.mechanism_accepted_i &: ~:(i.mechanism_refused_i)
  in
  let mechanism_refused =
    mechanism_request &: i.mechanism_refused_i &: ~:(i.mechanism_accepted_i)
  in
  let immediate_completion = mechanism_accepted &: i.mechanism_completion_valid_i in
  let delayed_completion = in_mechanism_wait &: i.mechanism_completion_valid_i in
  let completion_success =
    (immediate_completion |: delayed_completion) &: ~:(i.mechanism_completion_fault_i)
  in
  let completion_fault =
    (immediate_completion |: delayed_completion) &: i.mechanism_completion_fault_i
  in
  let unsolicited_completion =
    i.mechanism_completion_valid_i
    &: ~:immediate_completion
    &: ~:delayed_completion
  in
  let mechanism_execute_edge =
    mechanism_decision_conflict |: mechanism_accepted |: mechanism_refused
  in
  let mechanism_stall_edge =
    (mechanism_request &: ~:(i.mechanism_accepted_i) &: ~:(i.mechanism_refused_i))
    |: in_mechanism_wait
  in

  let mechanism_result_rd =
    mux2
      (opcode_is Read_pins.opcode)
      (field decode_word Read_pins.rd)
      (mux2
         (opcode_is Read_status.opcode)
         (field decode_word Read_status.rd)
         (field decode_word Fifo_pop.reg))
  in
  let branch_pin_taken = bit i.mechanism_completion_result_i ~pos:0 in
  let mechanism_next_pc =
    mux2
      (opcode_is Branch_pin.opcode &: branch_pin_taken)
      (jump_target Branch_pin.disp)
      sequential_pc
  in
  let mechanism_writes_result =
    completion_success
    &: (opcode_is Read_pins.opcode |: opcode_is Read_status.opcode |: opcode_is Fifo_pop.opcode)
  in

  let pc_representable = select r.pc.value ~high:16 ~low:9 ==:. 0 in
  let in_fetch = in_phase Phase.fetch in
  let base_fetch_valid = in_fetch &: pc_representable in
  let extension_address = r.pc.value +:. 1 in
  let fetch_valid = base_fetch_valid |: extension_needed in
  let fetch_address_wide = mux2 extension_needed extension_address r.pc.value in
  let fetch_address = select fetch_address_wide ~high:8 ~low:0 in
  let unrepresentable_target = in_fetch &: ~:pc_representable in
  let base_fetch_rejected = base_fetch_valid &: i.fetch_fault_i in
  let extension_fetch_rejected = extension_needed &: i.fetch_fault_i in
  let invalid_base = base_completion &: ~:(decoded.base_valid_o) in
  let invalid_extension = extension_completion &: ~:(decoded.valid_o) in

  let halt_execute = local_execute &: opcode_is Halt.opcode in
  let local_success = local_execute &: ~:(opcode_is Halt.opcode) in
  let local_retire = local_execute in
  let mechanism_retire = completion_success in
  let execute_edge = local_execute |: mechanism_execute_edge in
  let retire_event = local_retire |: mechanism_retire in
  let fault_event =
    unrepresentable_target
    |: base_fetch_rejected
    |: extension_fetch_rejected
    |: invalid_base
    |: invalid_extension
    |: mechanism_refused
    |: completion_fault
    |: unsolicited_completion
    |: mechanism_decision_conflict
  in
  let boundary_event = retire_event |: fault_event in
  let execution_halt = halt_execute |: fault_event in

  let write_reg_valid =
    (local_execute
     &: (opcode_is Ldi.opcode
         |: opcode_is Mov.opcode
         |: opcode_is Alu.opcode
         |: opcode_is Alu_imm.opcode
         |: opcode_is Shift.opcode
         |: opcode_is Dbnz.opcode
         |: opcode_is Call.opcode))
    |: mechanism_writes_result
  in
  let write_reg_index =
    mux2
      mechanism_writes_result
      mechanism_result_rd
      (mux2
         (opcode_is Mov.opcode)
         (field decode_word Mov.rd)
         (mux2
            (opcode_is Alu.opcode)
            alu_rd
            (mux2
               (opcode_is Alu_imm.opcode)
               alu_imm_rd
               (mux2
                  (opcode_is Shift.opcode)
                  shift_rd
                  (mux2
                     (opcode_is Dbnz.opcode)
                     dbnz_rd
                     (mux2 (opcode_is Call.opcode) (field decode_word Call.link) rd))))))
  in
  let write_reg_data =
    mux2
      mechanism_writes_result
      i.mechanism_completion_result_i
      (mux2
         (opcode_is Ldi.opcode)
         decoded.immediate_o
         (mux2
            (opcode_is Mov.opcode)
            (read_reg mov_rs)
            (mux2
               (opcode_is Alu.opcode)
               alu_value
               (mux2
                   (opcode_is Alu_imm.opcode)
                   alu_imm_value
                   (mux2
                      (opcode_is Shift.opcode)
                      shift_value
                      (mux2
                         (opcode_is Dbnz.opcode)
                         dbnz_value
                         (uresize (r.pc.value +:. 1) ~width:16)))))))
  in
  let flag_write =
    local_execute
    &: (opcode_is Alu.opcode
        |: opcode_is Alu_imm.opcode
        |: opcode_is Cmp.opcode
        |: opcode_is Cmp_imm.opcode
        |: opcode_is Shift.opcode)
  in
  let flag_result =
    mux2
      (opcode_is Alu.opcode)
      alu_value
      (mux2
         (opcode_is Alu_imm.opcode)
         alu_imm_value
         (mux2
            (opcode_is Cmp.opcode)
            cmp_value
            (mux2 (opcode_is Cmp_imm.opcode) cmp_imm_value shift_value)))
  in
  let flag_carry =
    mux2
      (opcode_is Alu.opcode)
      alu_carry
      (mux2
         (opcode_is Alu_imm.opcode)
         alu_imm_carry
         (mux2
            (opcode_is Cmp.opcode)
            cmp_carry
            (mux2 (opcode_is Cmp_imm.opcode) cmp_imm_carry shift_carry)))
  in
  let local_next_pc =
    mux2
      (opcode_is Jump.opcode)
      (jump_target Jump.disp)
      (mux2
         (opcode_is Branch.opcode)
         branch_pc
         (mux2
            (opcode_is Dbnz.opcode)
            dbnz_pc
            (mux2
               (opcode_is Call.opcode)
               (jump_target Call.disp)
               (mux2
                   (opcode_is Jump_reg.opcode)
                   (uresize (read_reg (field decode_word Jump_reg.rs)) ~width:Execution_config.pc_bits)
                   sequential_pc))))
  in

  let set_fault kind instruction_slot address reason =
    [ r.phase <--. Phase.fault
    ; r.execution_fault <--. 1
    ; r.normal_halt <--. 0
    ; r.fault_kind <-- kind
    ; r.fault_instruction_slot <-- instruction_slot
    ; r.fault_address <-- address
    ; r.fault_reason <-- reason
    ; r.boundary <--. 1
    ]
  in
  let clear_architecture =
    [ r.pc <--. 0
    ; r.base_word <--. 0
    ; r.extension_word <--. 0
    ; r.has_extension <--. 0
    ; r.last_instruction_slot <--. 0
    ; r.r0 <--. 0; r.r1 <--. 0; r.r2 <--. 0; r.r3 <--. 0
    ; r.r4 <--. 0; r.r5 <--. 0; r.r6 <--. 0; r.r7 <--. 0
    ; r.zero <--. 0; r.carry <--. 0; r.negative <--. 0
    ; r.desc_control <--. 0
    ; r.desc_bit_count <--. 0
    ; r.desc_tx_value <--. 0
    ; r.desc_output_pin <--. Descriptor.no_pin
    ; r.desc_input_pin <--. Descriptor.no_pin
    ; r.desc_clock_pin <--. Descriptor.no_pin
    ; r.desc_initial_delay <--. 0
    ; r.desc_half_period <--. 0
    ; r.desc_pacing <--. 0
    ; r.normal_halt <--. 0
    ; r.execution_fault <--. 0
    ; r.fault_kind <--. Fault.none
    ; r.fault_instruction_slot <--. 0
    ; r.fault_address <--. 0
    ; r.fault_reason <--. 0
    ; r.boundary <--. 0
    ; r.retired <--. 0
    ; r.fetch_cycles <--. 0
    ; r.execute_cycles <--. 0
    ; r.stall_cycles <--. 0
    ; r.instruction_count <--. 0
    ; r.extension_fetches <--. 0
    ; r.total_cycles <--. 0
    ]
  in

  compile
    [ r.phase <-- r.phase.value
    ; r.pc <-- r.pc.value
    ; r.base_word <-- r.base_word.value
    ; r.extension_word <-- r.extension_word.value
    ; r.has_extension <-- r.has_extension.value
    ; r.last_instruction_slot <-- r.last_instruction_slot.value
    ; r.r0 <-- r.r0.value; r.r1 <-- r.r1.value; r.r2 <-- r.r2.value; r.r3 <-- r.r3.value
    ; r.r4 <-- r.r4.value; r.r5 <-- r.r5.value; r.r6 <-- r.r6.value; r.r7 <-- r.r7.value
    ; r.zero <-- r.zero.value; r.carry <-- r.carry.value; r.negative <-- r.negative.value
    ; r.desc_control <-- r.desc_control.value
    ; r.desc_bit_count <-- r.desc_bit_count.value
    ; r.desc_tx_value <-- r.desc_tx_value.value
    ; r.desc_output_pin <-- r.desc_output_pin.value
    ; r.desc_input_pin <-- r.desc_input_pin.value
    ; r.desc_clock_pin <-- r.desc_clock_pin.value
    ; r.desc_initial_delay <-- r.desc_initial_delay.value
    ; r.desc_half_period <-- r.desc_half_period.value
    ; r.desc_pacing <-- r.desc_pacing.value
    ; r.normal_halt <-- r.normal_halt.value
    ; r.execution_fault <-- r.execution_fault.value
    ; r.fault_kind <-- r.fault_kind.value
    ; r.fault_instruction_slot <-- r.fault_instruction_slot.value
    ; r.fault_address <-- r.fault_address.value
    ; r.fault_reason <-- r.fault_reason.value
    ; r.boundary <--. 0
    ; r.retired <--. 0
    ; r.fetch_cycles <-- r.fetch_cycles.value
    ; r.execute_cycles <-- r.execute_cycles.value
    ; r.stall_cycles <-- r.stall_cycles.value
    ; r.instruction_count <-- r.instruction_count.value
    ; r.extension_fetches <-- r.extension_fetches.value
    ; r.total_cycles <-- r.total_cycles.value

    ; if_ ~:(i.en_i)
        [ r.phase <--. Phase.halted; r.has_extension <--. 0 ]
        [ when_ i.run_accepted_i (clear_architecture @ [ r.phase <--. Phase.fetch ])
        ; when_ (fetch_valid &: i.fetch_accepted_i)
            [ r.fetch_cycles <-- r.fetch_cycles.value +:. 1
            ; r.total_cycles <-- r.total_cycles.value +:. 1
            ; if_
                extension_needed
                [ r.phase <--. Phase.extension_wait
                ; r.base_word <-- i.fetch_completion_data_i
                ; r.has_extension <--. 1
                ; r.extension_fetches <-- r.extension_fetches.value +:. 1
                ]
                [ r.phase <--. Phase.base_wait; r.has_extension <--. 0 ]
            ]
        ; when_ base_completion [ r.base_word <-- i.fetch_completion_data_i ]
        ; when_ extension_completion [ r.extension_word <-- i.fetch_completion_data_i ]

        ; when_ execute_edge
            [ r.execute_cycles <-- r.execute_cycles.value +:. 1
            ; r.total_cycles <-- r.total_cycles.value +:. 1
            ]
        ; when_ mechanism_stall_edge
            [ r.stall_cycles <-- r.stall_cycles.value +:. 1
            ; r.total_cycles <-- r.total_cycles.value +:. 1
            ]
        ; when_ retire_event
            [ r.retired <--. 1
            ; r.boundary <--. 1
            ; r.last_instruction_slot <-- r.pc.value
            ; r.instruction_count <-- r.instruction_count.value +:. 1
            ]

        ; when_ write_reg_valid
            [ when_ (write_reg_index ==:. 0) [ r.r0 <-- write_reg_data ]
            ; when_ (write_reg_index ==:. 1) [ r.r1 <-- write_reg_data ]
            ; when_ (write_reg_index ==:. 2) [ r.r2 <-- write_reg_data ]
            ; when_ (write_reg_index ==:. 3) [ r.r3 <-- write_reg_data ]
            ; when_ (write_reg_index ==:. 4) [ r.r4 <-- write_reg_data ]
            ; when_ (write_reg_index ==:. 5) [ r.r5 <-- write_reg_data ]
            ; when_ (write_reg_index ==:. 6) [ r.r6 <-- write_reg_data ]
            ; when_ (write_reg_index ==:. 7) [ r.r7 <-- write_reg_data ]
            ]
        ; when_ flag_write
            [ r.zero <-- flag_zero flag_result
            ; r.carry <-- flag_carry
            ; r.negative <-- flag_negative flag_result
            ]
        ; when_ (local_execute &: opcode_is Config.opcode)
            [ when_ (field decode_word Config.field ==:. 0) [ r.desc_control <-- decoded.immediate_o ]
            ; when_ (field decode_word Config.field ==:. 1) [ r.desc_bit_count <-- decoded.immediate_o ]
            ; when_ (field decode_word Config.field ==:. 2) [ r.desc_tx_value <-- decoded.immediate_o ]
            ; when_ (field decode_word Config.field ==:. 3) [ r.desc_output_pin <-- decoded.immediate_o ]
            ; when_ (field decode_word Config.field ==:. 4) [ r.desc_input_pin <-- decoded.immediate_o ]
            ; when_ (field decode_word Config.field ==:. 5) [ r.desc_clock_pin <-- decoded.immediate_o ]
            ; when_ (field decode_word Config.field ==:. 6) [ r.desc_initial_delay <-- decoded.immediate_o ]
            ; when_ (field decode_word Config.field ==:. 7) [ r.desc_half_period <-- decoded.immediate_o ]
            ; when_ (field decode_word Config.field ==:. 8) [ r.desc_pacing <-- decoded.immediate_o ]
            ]

        ; when_ local_success [ r.pc <-- local_next_pc; r.phase <--. Phase.fetch ]
        ; when_ halt_execute [ r.phase <--. Phase.halted; r.normal_halt <--. 1 ]
        ; when_ (mechanism_initial &: ~:(i.mechanism_accepted_i) &: ~:(i.mechanism_refused_i))
            [ r.phase <--. Phase.mechanism_offer ]
        ; when_ (mechanism_accepted &: ~:(i.mechanism_completion_valid_i))
            [ r.phase <--. Phase.mechanism_wait ]
        ; when_ completion_success
            [ r.pc <-- mechanism_next_pc; r.phase <--. Phase.fetch ]

        ; when_ unrepresentable_target
            (set_fault
               (const ~width:Fault.width Fault.target_unrepresentable)
               r.last_instruction_slot.value r.pc.value (zero Execution_config.mechanism_reason_bits))
        ; when_ base_fetch_rejected
            (set_fault
               (const ~width:Fault.width Fault.fetch_bounds)
               r.last_instruction_slot.value r.pc.value (zero Execution_config.mechanism_reason_bits))
        ; when_ extension_fetch_rejected
            (set_fault
               (const ~width:Fault.width Fault.truncated_extension)
               r.pc.value extension_address (zero Execution_config.mechanism_reason_bits))
        ; when_ invalid_base
            (set_fault
               (const ~width:Fault.width Fault.invalid_base)
               r.pc.value r.pc.value (uresize decoded.error_o ~width:Execution_config.mechanism_reason_bits))
        ; when_ invalid_extension
            (set_fault
               (const ~width:Fault.width Fault.invalid_extension)
               r.pc.value extension_address (uresize decoded.error_o ~width:Execution_config.mechanism_reason_bits))
        ; when_ mechanism_refused
            (set_fault
               (const ~width:Fault.width Fault.mechanism_refused)
               r.pc.value r.pc.value i.mechanism_refusal_reason_i)
        ; when_ completion_fault
            (set_fault
               (const ~width:Fault.width Fault.mechanism_completion)
               r.pc.value r.pc.value i.mechanism_completion_reason_i)
        ; when_ unsolicited_completion
            (set_fault
               (const ~width:Fault.width Fault.unsolicited_completion)
               r.pc.value r.pc.value i.mechanism_completion_reason_i)
        ; when_ mechanism_decision_conflict
            (set_fault
               (const ~width:Fault.width Fault.mechanism_protocol)
               r.pc.value r.pc.value i.mechanism_refusal_reason_i)
        ]
    ];

  { O.fetch_valid_o = fetch_valid
  ; fetch_address_o = fetch_address
  ; execution_halt_o = execution_halt
  ; mechanism_request_valid_o = mechanism_request
  ; mechanism_kind_o = mechanism_kind
  ; mechanism_arg0_o = mechanism_arg0
  ; mechanism_arg1_o = mechanism_arg1
  ; mechanism_arg2_o = mechanism_arg2
  ; mechanism_timeout_enable_o = timeout_enable
  ; mechanism_descriptor_o = descriptor
  ; active_o = ~:(in_phase Phase.halted) &: ~:(in_phase Phase.fault)
  ; normal_halt_o = r.normal_halt.value
  ; execution_fault_o = r.execution_fault.value
  ; fault_kind_o = r.fault_kind.value
  ; fault_instruction_slot_o = r.fault_instruction_slot.value
  ; fault_address_o = r.fault_address.value
  ; fault_reason_o = r.fault_reason.value
  ; instruction_boundary_o = r.boundary.value
  ; retired_o = r.retired.value
  ; pc_o = r.pc.value
  ; registers_o = concat_msb (List.rev registers)
  ; zero_o = r.zero.value
  ; carry_o = r.carry.value
  ; negative_o = r.negative.value
  ; descriptor_o = descriptor
  ; phase_o = r.phase.value
  ; fetch_cycles_o = r.fetch_cycles.value
  ; execute_cycles_o = r.execute_cycles.value
  ; stall_cycles_o = r.stall_cycles.value
  ; instruction_count_o = r.instruction_count.value
  ; extension_fetches_o = r.extension_fetches.value
  ; total_cycles_o = r.total_cycles.value
  }
;;
[@@@ocamlformat "enable"]
