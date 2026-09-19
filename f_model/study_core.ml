(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "study_core.ml" *)
(* A control core that fetches, decodes and executes an assembled [Study_encoding] image
   against the reference machine, and counts what that cost.

   WHY A CORE AT ALL. P1.4 has to report cycle counts, and a cycle count that is computed
   rather than run is an estimate. This one runs: it reads real encoded words out of a
   [Program_store] through the contract port, decodes them with the candidate's own
   decoder, and issues the resulting operations into [Machine] through the same
   ready/valid port [Firmware] uses. The pins in a trace were driven by the program in the
   store, and the independent peers in [Firmware_spi] and [Firmware_i2c] answer it without
   knowing anything but the wire.

   THE REFERENCE MICROARCHITECTURE. Deliberately the simplest thing that respects the
   memory contract, because the comparison must not depend on cleverness that P3.2 has not
   committed to:

   1. Fetch is not overlapped with execution. Each memory word an instruction needs costs
      one edge, on which the read is driven into the port; its data is consumed at the
      next edge, which is latency one (program_store.ml).
   2. One memory word is buffered. A second instruction slot living in the same word is
      therefore free, which is the whole of what packing buys, and a taken branch throws
      the buffer away.
   3. Execution is one edge per instruction, on which any operation is offered to the
      machine. An operation that stalls the core adds its own edges and nothing else runs
      - which is precisely a core wait: engines, had any existed yet, would keep going
        (construction-plan.md section 3, rule 6).

   Every candidate runs on this same core, so the differences between the reported cycle
   counts are differences of encoding: how many words an instruction needs, and how many
   reads reach them. An overlapped fetch would lower every number here; [Counts.t] reports
   fetch and execute edges separately so that a reader can bound that without rerunning
   anything.

   WHAT THE COUNTS DO NOT INCLUDE. Loading the image is host work (P3.1a), so the writes
   that fill the store are not cycles of the run. The machine is left halted throughout:
   its own fetch path is P3.2's and would otherwise drive the same port this core is
   using.

   AN INVALID INSTRUCTION HALTS. A reserved opcode, a reserved bit set, a field naming
   nothing, and a word the store leaves unspecified all end the run at the slot that
   produced them, with the pins left as they were. That is P1.1's rule for a bad fetch - a
   program error is not an abort, and what to do about it is the host's decision - and it
   is applied here to decoded words as well as unspecified ones.
*)

open! Core
open! Kinds
open Study_isa

module Flags = struct
  (* Three flags, the "simple flags" of construction-plan.md section 4. [carry] is a carry
     out of an addition and a borrow out of a subtraction, and the bit shifted out of a
     shift; the logical operations clear it. [Ldi], [Mov], [Read_pins] and [Read_status]
     leave all three alone, so a value can be fetched between a comparison and the branch
     that uses it. *)
  type t =
    { zero : bool
    ; carry : bool
    ; negative : bool
    }
  [@@deriving sexp_of, compare, equal]

  let cleared = { zero = false; carry = false; negative = false }

  let of_result ~result ~carry =
    { zero = result land Register.mask = 0
    ; carry
    ; negative = result land (1 lsl (Register.width - 1)) <> 0
    }
  ;;

  let test t (cond : Cond.t) =
    match cond with
    | Zero -> t.zero
    | Not_zero -> not t.zero
    | Carry -> t.carry
    | Not_carry -> not t.carry
    | Negative -> t.negative
    | Not_negative -> not t.negative
  ;;
end

module Counts = struct
  (* Edges, by what the core was doing on them. [cycles] is their sum, and a test asserts
     that it is. [memory_reads] is the number of reads driven into the program store's
     port, which is the same as [fetch_cycles] by construction and is reported separately
     because it is the number that a memory's energy and port contention are counted in.
     [buffer_hits] is the slots that needed no read at all. *)
  type t =
    { cycles : int
    ; fetch_cycles : int
    ; execute_cycles : int
    ; stall_cycles : int
    ; instructions : int
    ; extension_fetches : int
    ; memory_reads : int
    ; buffer_hits : int
    }
  [@@deriving sexp_of, compare, equal]

  let zero =
    { cycles = 0
    ; fetch_cycles = 0
    ; execute_cycles = 0
    ; stall_cycles = 0
    ; instructions = 0
    ; extension_fetches = 0
    ; memory_reads = 0
    ; buffer_hits = 0
    }
  ;;
end

module Outcome = struct
  type t =
    | (* [Halt] executed. Every example program ends this way. *)
      Halted
    | (* A word that is not an instruction, at the slot that produced it. *)
      Faulted of
        { slot : int
        ; reason : Study_encoding.Word_error.t
        }
    | (* The machine refused an operation for a reason only it could decide. *)
      Refused of
        { slot : int
        ; instr : int Instr.t
        ; reason : Fault.Reject.t
        }
    | Out_of_cycles of
        { slot : int
        ; limit : int
        }
  [@@deriving sexp_of, compare, equal]
end

(* The core's own registered state, beside the machine's. *)
module Running = struct
  type 'state t =
    { machine : Machine.t
    ; peer : 'state
    ; pin_in : int
    ; store : Program_store.t
    ; (* The one buffered memory word: its address and contents. *)
      buffer : (int * int) option
    ; regs : int array
    ; flags : Flags.t
    ; descriptor : Descriptor.t
    ; pc : int
    ; counts : Counts.t
    ; edges : Firmware.Edge_log.t list (* reversed *)
    }
end

module Trace = struct
  type 'state t =
    { name : string
    ; candidate : Study_encoding.Candidate.t
    ; size : Study_encoding.Size.t
    ; counts : Counts.t
    ; outcome : Outcome.t
    ; regs : int list
    ; flags : Flags.t
    ; final : Machine.t
    ; peer : 'state
    ; edges : Firmware.Edge_log.t list
    }

  let reg t ~index = List.nth_exn t.regs index

  (* One character per edge for a driven pin, as [Firmware.Trace.wave] defines it: '1' and
     '0' are driven levels and 'z' is released. *)
  let wave t ~pin =
    let bit word = word land (1 lsl pin) <> 0 in
    String.of_char_list
      (List.map t.edges ~f:(fun (e : Firmware.Edge_log.t) ->
         if not (bit e.output_enable) then 'z' else if bit e.value then '1' else '0'))
  ;;
end

(* One rising edge: the machine, the board, and the program store all advance together.
   The store's port is driven only on a fetch edge; on every other edge it is idle and its
   output holds, which is the contract's own rule and the reason a buffered word stays
   readable. *)
let edge board (r : 'state Running.t) ~command ~port ~acknowledge =
  let machine =
    Machine.step
      r.machine
      { Machine.Input.idle with pin_in = r.pin_in; command; acknowledge }
  in
  let peer, pin_in = board.Firmware.Board.next r.peer machine in
  { r with
    Running.machine
  ; peer
  ; pin_in
  ; store = Program_store.step r.store port
  ; counts = { r.counts with cycles = r.counts.cycles + 1 }
  ; edges =
      { Firmware.Edge_log.time = machine.time
      ; value = machine.pins.value
      ; output_enable = machine.pins.output_enable
      ; snapshot = Input_pins.snapshot machine.inputs
      }
      :: r.edges
  }
;;

(* Read one memory word, from the buffer if it is there and from the store otherwise. A
   store read costs the edge it is driven on; its data is consumed here, at the following
   edge, which is latency one. *)
let read_memory board (r : 'state Running.t) ~address =
  match r.buffer with
  | Some (buffered, data) when buffered = address ->
    Ok
      ( { r with
          Running.counts = { r.counts with buffer_hits = r.counts.buffer_hits + 1 }
        }
      , data )
  | _ ->
    let r =
      edge board r ~command:None ~port:(Program_store.Port.read ~address) ~acknowledge:[]
    in
    let r =
      { r with
        Running.counts =
          { r.counts with
            fetch_cycles = r.counts.fetch_cycles + 1
          ; memory_reads = r.counts.memory_reads + 1
          }
      }
    in
    (match Program_store.read_data r.store with
     | Program_store.Word.Specified data ->
       Ok ({ r with Running.buffer = Some (address, data) }, data)
     | Unspecified -> Error (r, Study_encoding.Word_error.Unspecified))
;;

(* Read one instruction slot, which is one memory word or two depending on the packing. *)
let read_slot board candidate r ~slot =
  let addresses = Study_encoding.addresses candidate ~slot in
  let rec go r acc = function
    | [] -> Ok (r, List.rev acc)
    | address :: rest ->
      (match read_memory board r ~address with
       | Error _ as error -> error
       | Ok (r, data) -> go r (data :: acc) rest)
  in
  Result.map (go r [] addresses) ~f:(fun (r, words) ->
    r, Study_encoding.extract candidate ~slot ~words)
;;

let set_reg (r : 'state Running.t) ~index ~value =
  let regs = Array.copy r.regs in
  regs.(index) <- value land Register.mask;
  { r with Running.regs }
;;

(* Sixteen-bit arithmetic with a carry out, and the flags it leaves. *)
let alu (op : Alu_op.t) a b =
  match op with
  | Add ->
    let sum = a + b in
    sum land Register.mask, sum > Register.mask
  | Sub ->
    let difference = a - b in
    difference land Register.mask, a < b
  | And -> a land b, false
  | Or -> a lor b, false
  | Xor -> a lxor b, false
;;

let shift (dir : Shift_dir.t) value ~amount =
  match dir with
  | Left ->
    ( (value lsl amount) land Register.mask
    , value land (1 lsl (Register.width - amount)) <> 0 )
  | Right -> value lsr amount, value land (1 lsl (amount - 1)) <> 0
;;

(* The latched status register as a word, one bit per [Event.Kind.t] in enumeration order,
   and the inverse for an acknowledge mask. *)
let status_word (machine : Machine.t) =
  List.foldi Event.Kind.all ~init:0 ~f:(fun index acc kind ->
    if Event.is_set machine.events kind then acc lor (1 lsl index) else acc)
;;

let acknowledged ~mask =
  List.filteri Event.Kind.all ~f:(fun index _ -> mask land (1 lsl index) <> 0)
;;

(* What executing an instruction does beyond consuming its edge. *)
module Step_result = struct
  type 'state t =
    | Next of 'state Running.t
    | Jump_to of 'state Running.t * int
    | Stop of 'state Running.t
    | Refused of 'state Running.t * Fault.Reject.t
end

(* Execute one decoded instruction. Exactly one edge is taken here; the stall edges an
   accepted operation may add are taken by the caller, so that every instruction costs the
   same execute edge whatever it does. *)
let execute board (r : 'state Running.t) ~slot ~(instr : int Instr.t) =
  let quiet r ~f =
    (* An instruction that touches no mechanism still takes its edge. *)
    let r = edge board r ~command:None ~port:Program_store.Port.idle ~acknowledge:[] in
    Step_result.Next (f r)
  in
  let issue r operation =
    let r =
      edge board r ~command:(Some operation) ~port:Program_store.Port.idle ~acknowledge:[]
    in
    match r.machine.last.command with
    | Machine.Command_result.Accepted _ -> Step_result.Next r
    | Rejected { reason; _ } -> Step_result.Refused (r, reason)
    | Not_offered -> Step_result.Refused (r, Fault.Reject.Not_ready)
  in
  let arithmetic r ~rd ~result ~carry =
    let r = set_reg r ~index:rd ~value:result in
    { r with Running.flags = Flags.of_result ~result ~carry }
  in
  let branch r ~taken ~target =
    if taken then Step_result.Jump_to (r, slot + 1 + target) else Step_result.Next r
  in
  let write_pins ~(mode : Pin_mode.t) ~mask ~value =
    match mode with
    | Push_pull -> Pin_bank.Write.push_pull ~mask ~value
    | Open_drain -> Pin_bank.Write.open_drain ~mask ~drive_low:value
  in
  match instr with
  | Halt ->
    let r = edge board r ~command:None ~port:Program_store.Port.idle ~acknowledge:[] in
    Step_result.Stop r
  | Ldi { rd; value } -> quiet r ~f:(fun r -> set_reg r ~index:rd ~value)
  | Mov { rd; rs } -> quiet r ~f:(fun r -> set_reg r ~index:rd ~value:r.regs.(rs))
  | Alu { op; rd; rs } ->
    quiet r ~f:(fun r ->
      let result, carry = alu op r.regs.(rd) r.regs.(rs) in
      arithmetic r ~rd ~result ~carry)
  | Alu_imm { op; rd; imm } ->
    quiet r ~f:(fun r ->
      let result, carry = alu op r.regs.(rd) imm in
      arithmetic r ~rd ~result ~carry)
  | Cmp { ra; rb } ->
    quiet r ~f:(fun r ->
      let result, carry = alu Alu_op.Sub r.regs.(ra) r.regs.(rb) in
      { r with Running.flags = Flags.of_result ~result ~carry })
  | Cmp_imm { ra; imm } ->
    quiet r ~f:(fun r ->
      let result, carry = alu Alu_op.Sub r.regs.(ra) imm in
      { r with Running.flags = Flags.of_result ~result ~carry })
  | Shift { dir; rd; amount } ->
    quiet r ~f:(fun r ->
      let result, carry = shift dir r.regs.(rd) ~amount in
      arithmetic r ~rd ~result ~carry)
  | Read_pins { rd } ->
    (* The snapshot this edge presented: two synchronizer stages behind the wire, which is
       the delay firmware really sees (input_pins.ml). *)
    quiet r ~f:(fun r ->
      set_reg r ~index:rd ~value:(Input_pins.snapshot r.machine.inputs))
  | Read_status { rd } ->
    quiet r ~f:(fun r -> set_reg r ~index:rd ~value:(status_word r.machine))
  | Ack_status { mask } ->
    let r =
      edge
        board
        r
        ~command:None
        ~port:Program_store.Port.idle
        ~acknowledge:(acknowledged ~mask)
    in
    Step_result.Next r
  | Jump { target } ->
    let r = edge board r ~command:None ~port:Program_store.Port.idle ~acknowledge:[] in
    Step_result.Jump_to (r, slot + 1 + target)
  | Branch { cond; target } ->
    let taken = Flags.test r.flags cond in
    let r = edge board r ~command:None ~port:Program_store.Port.idle ~acknowledge:[] in
    branch r ~taken ~target
  | Branch_pin { pin; level; target } ->
    let r = edge board r ~command:None ~port:Program_store.Port.idle ~acknowledge:[] in
    branch r ~taken:(Bool.equal (Input_pins.level r.machine.inputs ~pin) level) ~target
  | Dbnz { rd; target } ->
    (* Decrement and branch while the count is not zero. It leaves the flags alone: a loop
       counter is bookkeeping, and overwriting a comparison with it would cost the
       instruction the fused form was meant to save. *)
    let value = (r.regs.(rd) - 1) land Register.mask in
    let r = edge board r ~command:None ~port:Program_store.Port.idle ~acknowledge:[] in
    let r = set_reg r ~index:rd ~value in
    branch r ~taken:(value <> 0) ~target
  | Write_pins_imm { mode; mask; value } ->
    issue r (Operation.Write_pins (write_pins ~mode ~mask ~value))
  | Write_pins_reg { mode; mask_reg; value_reg } ->
    issue
      r
      (Operation.Write_pins
         (write_pins ~mode ~mask:r.regs.(mask_reg) ~value:r.regs.(value_reg)))
  | Wait_cycles_imm { delay } -> issue r (Operation.Wait_cycles { delay })
  | Wait_cycles_reg { rd } -> issue r (Operation.Wait_cycles { delay = r.regs.(rd) })
  | Wait_level { pin; level; timeout } ->
    issue r (Operation.Wait_level { pin; level; timeout })
  | Wait_edge { pin; edge = which; timeout } ->
    issue r (Operation.Wait_edge { pin; edge = which; timeout })
  | Start_periodic { period } -> issue r (Operation.Start_periodic { period })
  | Stop_periodic -> issue r Operation.Stop_periodic
  | Config { field; value } ->
    (* Descriptor fields are core state, not an operation: nothing reaches the machine
       until [Issue_transfer] hands it the whole descriptor, which is what makes an
       unconfigured issue a refusal rather than a half-configured transfer. *)
    quiet r ~f:(fun r ->
      { r with Running.descriptor = Descriptor.set r.descriptor field value })
  | Issue_transfer ->
    issue r (Operation.Configure_transfer (Descriptor.to_transfer r.descriptor))
  | Fifo_push { fifo; rs; blocking } ->
    issue r (Operation.Fifo_push { fifo; data = r.regs.(rs); blocking })
  | Fifo_pop { fifo; rd; blocking } ->
    (match issue r (Operation.Fifo_pop { fifo; blocking }) with
     | Step_result.Next r ->
       (match r.machine.last.popped with
        | Some data -> Step_result.Next (set_reg r ~index:rd ~value:data)
        | None -> Step_result.Next r)
     | other -> other)
;;

(* Run the machine on until the accepted operation stops stalling the core. A blocking
   queue operation with nothing to drain it ends at the cycle limit, as it does for
   [Firmware]. *)
let rec settle board (r : 'state Running.t) ~limit =
  if Option.is_none r.machine.wait
  then Ok r
  else if r.counts.cycles >= limit
  then Error r
  else (
    let r = edge board r ~command:None ~port:Program_store.Port.idle ~acknowledge:[] in
    settle
      board
      { r with
        Running.counts = { r.counts with stall_cycles = r.counts.stall_cycles + 1 }
      }
      ~limit)
;;

(* Write the assembled image into the store. These are host writes, not cycles of the run;
   the core is halted while they happen, which is the only state construction-plan.md
   section 4 allows them in. *)
let load_store
  (candidate : Study_encoding.Candidate.t)
  (image : Study_encoding.Image.t)
  ~depth
  =
  Array.foldi
    image.words
    ~init:(Program_store.create ~depth ~width:candidate.memory_bits)
    ~f:(fun address store data ->
      Program_store.step store (Program_store.Port.write ~address ~data))
;;

let run
  ?(machine = Machine.create ())
  ?(max_cycles = 100_000)
  ?(depth = Study_encoding.default_depth)
  ~candidate
  board
  program
  =
  Result.map (Study_encoding.assemble ~depth candidate program) ~f:(fun assembled ->
    let peer, pin_in = board.Firmware.Board.next board.Firmware.Board.initial machine in
    let start =
      { Running.machine
      ; peer
      ; pin_in
      ; store = load_store candidate assembled.image ~depth
      ; buffer = None
      ; regs = Array.create ~len:Register.count 0
      ; flags = Flags.cleared
      ; descriptor = Descriptor.cleared
      ; pc = 0
      ; counts = Counts.zero
      ; edges = []
      }
    in
    let finish (r : 'state Running.t) outcome =
      { Trace.name = program.Study_isa.name
      ; candidate
      ; size = assembled.size
      ; counts = r.counts
      ; outcome
      ; regs = Array.to_list r.regs
      ; flags = r.flags
      ; final = r.machine
      ; peer = r.peer
      ; edges = List.rev r.edges
      }
    in
    (* One instruction: fetch its slot, decode, fetch an extension word if the encoding
       asked for one, execute, then let any stall run out. *)
    let rec go (r : 'state Running.t) =
      let slot = r.pc in
      if r.counts.cycles >= max_cycles
      then finish r (Outcome.Out_of_cycles { slot; limit = max_cycles })
      else (
        match read_slot board candidate r ~slot with
        | Error (r, reason) -> finish r (Outcome.Faulted { slot; reason })
        | Ok (r, word) ->
          (match Study_encoding.decode candidate word with
           | Study_encoding.Decoded.Invalid reason ->
             finish r (Outcome.Faulted { slot; reason })
           | Complete instr -> run_instruction r ~slot ~instr ~slots:1
           | Needs_extension build ->
             (match read_slot board candidate r ~slot:(slot + 1) with
              | Error (r, reason) ->
                finish r (Outcome.Faulted { slot = slot + 1; reason })
              | Ok (r, extension) ->
                let r =
                  { r with
                    Running.counts =
                      { r.counts with extension_fetches = r.counts.extension_fetches + 1 }
                  }
                in
                (match build extension with
                 | Study_encoding.Decoded.Complete instr ->
                   run_instruction r ~slot ~instr ~slots:2
                 | Invalid reason ->
                   finish r (Outcome.Faulted { slot = slot + 1; reason })
                 | Needs_extension _ ->
                   finish
                     r
                     (Outcome.Faulted
                        { slot; reason = Study_encoding.Word_error.Missing_extension })))))
    and run_instruction (r : 'state Running.t) ~slot ~instr ~slots =
      let counted (r : 'state Running.t) =
        { r with
          Running.counts =
            { r.counts with
              execute_cycles = r.counts.execute_cycles + 1
            ; instructions = r.counts.instructions + 1
            }
        }
      in
      match execute board r ~slot ~instr with
      | Step_result.Refused (r, reason) ->
        finish (counted r) (Outcome.Refused { slot; instr; reason })
      | Stop r -> finish (counted r) Outcome.Halted
      | Next r -> after (counted r) ~slot ~pc:(slot + slots)
      | Jump_to (r, target) ->
        (* A taken branch leaves the buffered word behind: the next instruction is
           somewhere else, and nothing promises it shares a memory word with this one. *)
        after { (counted r) with Running.buffer = None } ~slot ~pc:target
    and after (r : 'state Running.t) ~slot ~pc =
      match settle board r ~limit:max_cycles with
      | Error r -> finish r (Outcome.Out_of_cycles { slot; limit = max_cycles })
      | Ok r -> go { r with Running.pc }
    in
    go start)
;;
