(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "firmware.ml" *)
(* Labelled operation sequences, their validation, and a runner that records what a
   sequence did on the wire.

   P1.3 asks for firmware helpers before an ISA exists, and construction-plan.md section 4
   asks for them in this order: an OCaml library with labels and validation first, with
   helpers such as [uart_tx] expanding into it, so that P1.4 compares encodings of a
   settled set of operations rather than inventing operations and an encoding at once.
   Nothing here has an opcode; a sequence is a list of [Operation.t] values.

   WHAT A LABEL IS TODAY. There is no branch operation and no decoder, so a label cannot
   yet be a jump target. It names a program point: the trace carries it, and
   [Trace.regions] attributes operations and cycles to the region it opens, which is how a
   start bit, a SPI bit slot, or an I2C acknowledge is identified in the evidence. P1.5
   gives the same names to branch targets in the assembler, and the uniqueness check here
   is the one that will matter then.

   WHAT THE RUNNER IS NOT. It is not the control core. It offers one operation per edge
   through the same ready/valid port the model tests use, so a reported cycle count is the
   cost of the mechanisms plus one acceptance edge per operation, never the cost of
   fetching and decoding an instruction. P3.2 adds fetch; these numbers are a floor, and
   [Firmware_uart] builds one frame both ways - bit-banged and as a single transfer
   descriptor - so that the size of the floor can be measured rather than assumed.

   SAMPLING. [Step.Sample] is not an operation. Reading a pin into a register needs a
   register file and an input-read operation, which are P1.4 and P1.5; until then a
   sequence marks where it would have sampled and the runner records the synchronized
   input level at that point, so an acknowledge bit or a received word appears in the
   trace with the synchronizer delay that firmware will really see.
*)

open! Core
open! Kinds

module Step = struct
  type t =
    | (* Names the program point that follows. Consumes no cycle. *)
      At of string
    | Do of Operation.t
    | (* Record the synchronized level of [pin] under [name]. Consumes no cycle. *)
      Sample of
        { pin : int
        ; name : string
        }
  [@@deriving sexp, compare, equal]
end

type t =
  { name : string
  ; steps : Step.t list
  }
[@@deriving sexp, compare, equal]

module Invalid = struct
  (* Why a sequence could not be built or is not runnable. Distinct from [Fault.Reject.t],
     which says why the machine refused a command at an edge: everything here is decided
     before the first edge. *)
  type t =
    | Empty
    | Duplicate_label of string
    | Unnamed_step of int
    | Invalid_operation of
        { index : int
        ; operation : Operation.t
        ; reason : Fault.Reject.t
        }
    | Invalid_sample of
        { index : int
        ; pin : int
        }
    | (* A bit-banged phase shorter than three cycles cannot be expressed: see [phase]. *)
      Phase_too_short of
        { label : string
        ; cycles : int
        }
    | (* A builder argument a sequence could not be made from at all, such as a byte wider
         than the frame that would carry it. *)
      Out_of_range of
        { what : string
        ; value : int
        }
  [@@deriving sexp, compare, equal]
end

let labels t =
  List.filter_map t.steps ~f:(function
    | Step.At label -> Some label
    | Do _ | Sample _ -> None)
;;

let operations t =
  List.filter_map t.steps ~f:(function
    | Step.Do operation -> Some operation
    | At _ | Sample _ -> None)
;;

(* How many operations a sequence issues, which is the count P1.3 asks to record. It is
   known without running: nothing here is data dependent. *)
let operation_count t = List.length (operations t)

(* Structural validation of the whole sequence. Every operation must pass the same
   [Operation.validate] the machine applies at acceptance, so a sequence that builds
   cannot be refused for a structural reason; what remains at run time are the stateful
   refusals - ownership, queue occupancy - which depend on the machine. *)
let validate t =
  let ( >>= ) result f = Result.bind result ~f in
  let duplicate =
    List.find_a_dup (labels t) ~compare:String.compare
    |> Option.map ~f:(fun label -> Invalid.Duplicate_label label)
  in
  let step_error index (step : Step.t) =
    match step with
    | At "" -> Some (Invalid.Unnamed_step index)
    | At _ -> None
    | Sample { pin; name } ->
      if String.is_empty name
      then Some (Invalid.Unnamed_step index)
      else if not (Pin_bank.is_valid_pin pin)
      then Some (Invalid.Invalid_sample { index; pin })
      else None
    | Do operation ->
      (match Operation.validate operation with
       | Ok () -> None
       | Error reason -> Some (Invalid.Invalid_operation { index; operation; reason }))
  in
  (if List.is_empty t.steps then Error Invalid.Empty else Ok ())
  >>= fun () ->
  (match duplicate with
   | Some error -> Error error
   | None -> Ok ())
  >>= fun () ->
  match List.filter_mapi t.steps ~f:step_error with
  | [] -> Ok ()
  | error :: _ -> Error error
;;

let create ~name steps =
  let t = { name; steps } in
  Result.map (validate t) ~f:(fun () -> t)
;;

(* One driven phase of a bit-banged protocol: commit [write], then stall so that the next
   write lands [cycles] edges after this one.

   The arithmetic is the visible cost of issuing operations one per edge. The write takes
   its own acceptance edge; [Wait_cycles n] takes one more to be accepted and then fires n
   edges later, and ready is a Moore output, so the next write is accepted one edge after
   that. Consecutive writes are therefore n + 2 edges apart. Nothing can express a phase
   shorter than three cycles this way, which is precisely the gap a transfer engine
   closes. *)
let phase ~label ~write ~cycles =
  if cycles < 3
  then Error (Invalid.Phase_too_short { label; cycles })
  else
    Ok
      [ Step.At label
      ; Step.Do (Operation.Write_pins write)
      ; Step.Do (Operation.Wait_cycles { delay = cycles - 2 })
      ]
;;

module Board = struct
  (* What the pads present, given what the design drives. The peer keeps its own state, so
     a target that answers - a SPI slave shifting out, an I2C target acknowledging or
     stretching the clock - is expressible without making the machine mutable.

     [next state machine] is applied to the state after an edge and returns the peer state
     and the asynchronous pad value sampled at the next edge. Two synchronizer stages sit
     between that value and anything firmware can observe. *)
  type 'state t =
    { initial : 'state
    ; next : 'state -> Machine.t -> 'state * int
    }

  let stateless pin_in = { initial = (); next = (fun () machine -> (), pin_in machine) }

  (* Every pad low. Enough for a transmit-only sequence, which observes nothing. *)
  let quiet = stateless (fun _ -> 0)

  (* An open-drain bus. [lines] are the pins a board pull-up holds high; a line is low
     only while the design pulls it low. Pull-ups are the reason nothing may infer a high
     level from the value it intended to transmit (construction-plan.md section 3). *)
  let pulled_up ~lines =
    stateless (fun (m : Machine.t) ->
      let driven_low = m.pins.output_enable land lnot m.pins.value in
      lines land lnot driven_low)
  ;;
end

module Record = struct
  (* One operation's passage through the command port. *)
  type t =
    { index : int
    ; (* The label region the operation belongs to. *)
      label : string option
    ; operation : Operation.t
    ; (* The first edge at which the operation was offered. *)
      offered : int
    ; accepted : int
    ; (* The edge at which the operation stopped stalling the core. Equal to [accepted]
         for everything that does not wait. *)
      completed : int
    }
  [@@deriving sexp_of, compare, equal]

  (* Edges spent waiting for the port to accept the operation. *)
  let accept_latency t = t.accepted - t.offered

  (* Edges the operation stalled the core after acceptance: a countdown, a level or edge
     wait, or a blocking queue retry. *)
  let service_latency t = t.completed - t.accepted

  (* Every edge the operation occupied, its acceptance edge included. This is the response
     latency P1.3 asks to record. *)
  let cycles t = t.completed - t.offered + 1
end

module Sampled = struct
  type t =
    { time : int
    ; name : string
    ; pin : int
    ; level : bool
    }
  [@@deriving sexp_of, compare, equal]
end

module Entry = struct
  type t =
    | Mark of
        { time : int
        ; label : string
        }
    | Ran of Record.t
    | Read of Sampled.t
  [@@deriving sexp_of]
end

module Outcome = struct
  type t =
    | Completed
    | (* The machine refused an operation for a reason only it could decide: ownership, or
         a nonblocking queue operation that could not complete. *)
      Refused of
        { index : int
        ; label : string option
        ; operation : Operation.t
        ; reason : Fault.Reject.t
        }
    | (* The cycle budget ran out. A blocking queue operation with nothing to drain it,
         and an I2C target that never releases a stretched clock, both end here. *)
      Out_of_cycles of
        { index : int
        ; limit : int
        }
  [@@deriving sexp_of, compare, equal]
end

module Edge_log = struct
  (* One edge of the run: what the bank drove and what the input front end presented. Both
     are registered state, never a recomputed guess. *)
  type t =
    { time : int
    ; value : int
    ; output_enable : int
    ; snapshot : int
    }
  [@@deriving sexp_of, compare, equal]
end

module Region = struct
  type t =
    { label : string
    ; operations : int
    ; cycles : int
    }
  [@@deriving sexp_of, compare, equal]
end

module Summary = struct
  type t =
    { name : string
    ; operations : int
    ; (* Edges from the first offer to the last completion. *)
      cycles : int
    ; (* The largest [Record.cycles] in the run. *)
      max_response : int
    ; samples : int
    }
  [@@deriving sexp_of, compare, equal]
end

module Trace = struct
  (* ['state] is the board's peer state after the last edge. A trace carries it so that
     evidence can assert what the device on the other end actually received, rather than
     only what the design believes it sent. *)
  type 'state t =
    { name : string
    ; entries : Entry.t list
    ; edges : Edge_log.t list
    ; outcome : Outcome.t
    ; (* The machine state after the last edge, so a test can assert on faults and latched
         status without rerunning. *)
      final : Machine.t
    ; peer : 'state
    }

  let records t =
    List.filter_map t.entries ~f:(function
      | Entry.Ran record -> Some record
      | Mark _ | Read _ -> None)
  ;;

  let sampled t =
    List.filter_map t.entries ~f:(function
      | Entry.Read sampled -> Some sampled
      | Mark _ | Ran _ -> None)
  ;;

  (* The levels recorded under one sample name, in the order they were taken. *)
  let samples t ~name =
    List.filter_map (sampled t) ~f:(fun s ->
      if String.equal s.name name then Some s.level else None)
  ;;

  (* Assemble one sample name's bits into a word. [Lsb_first] means the first sample is
     bit zero, which is the order a UART or a mode-0 SPI target sends in when its
     descriptor says so. *)
  let word t ~name ~(order : Bit_order.t) =
    let bits = samples t ~name in
    match order with
    | Lsb_first ->
      List.foldi bits ~init:0 ~f:(fun i acc bit -> if bit then acc lor (1 lsl i) else acc)
    | Msb_first ->
      List.fold bits ~init:0 ~f:(fun acc bit -> (acc lsl 1) lor Bool.to_int bit)
  ;;

  let regions t =
    let records = records t in
    List.map
      (List.filter_map t.entries ~f:(function
        | Entry.Mark { label; _ } -> Some label
        | Ran _ | Read _ -> None))
      ~f:(fun label ->
        let mine =
          List.filter records ~f:(fun r -> Option.exists r.label ~f:(String.equal label))
        in
        { Region.label
        ; operations = List.length mine
        ; cycles = List.sum (module Int) mine ~f:Record.cycles
        })
  ;;

  let summary t =
    let records = records t in
    { Summary.name = t.name
    ; operations = List.length records
    ; cycles = List.length t.edges
    ; max_response =
        List.fold records ~init:0 ~f:(fun acc r -> Int.max acc (Record.cycles r))
    ; samples = List.length (sampled t)
    }
  ;;

  (* One character per edge for a driven pin: '1' and '0' are driven levels, 'z' is
     released. A released pin is never reported as high here, because what a pull-up does
     with it belongs to [snapshot]. *)
  let wave t ~pin =
    let bit word = word land (1 lsl pin) <> 0 in
    String.of_char_list
      (List.map t.edges ~f:(fun e ->
         if not (bit e.output_enable) then 'z' else if bit e.value then '1' else '0'))
  ;;

  (* One character per edge for what the input front end presented, which is the value
     firmware can act on: two synchronizer stages behind the wire. *)
  let input_wave t ~pin =
    String.of_char_list
      (List.map t.edges ~f:(fun e ->
         if e.snapshot land (1 lsl pin) <> 0 then '1' else '0'))
  ;;

  (* A wave as (level, run length) pairs. A UART frame is ten of these plus idle, which is
     shorter to read and to assert on than eighty characters. *)
  let runs string =
    List.map
      (List.group (String.to_list string) ~break:Char.( <> ))
      ~f:(fun group -> List.hd_exn group, List.length group)
  ;;
end

(* The runner's working state. *)
module Running = struct
  type 'state t =
    { machine : Machine.t
    ; peer : 'state
    ; (* The pad value the next edge will sample, produced by the board after the last
         edge. *)
      pin_in : int
    ; label : string option
    ; entries : Entry.t list (* reversed *)
    ; edges : Edge_log.t list (* reversed *)
    ; cycles : int
    }
end

let edge (board : 'state Board.t) (r : 'state Running.t) ~command =
  let machine =
    Machine.step r.machine { Machine.Input.idle with pin_in = r.pin_in; command }
  in
  let peer, pin_in = board.next r.peer machine in
  { r with
    Running.machine
  ; peer
  ; pin_in
  ; cycles = r.cycles + 1
  ; edges =
      { Edge_log.time = machine.time
      ; value = machine.pins.value
      ; output_enable = machine.pins.output_enable
      ; snapshot = Input_pins.snapshot machine.inputs
      }
      :: r.edges
  }
;;

(* Offer one operation until the port takes it. A [Not_ready] refusal is ordinary flow
   control and is retried at the next edge; every other refusal ends the run, because a
   sequence that depends on a refused operation has already gone wrong. *)
let rec offer board (r : 'state Running.t) ~limit ~operation =
  if r.cycles >= limit
  then Error (r, `Out_of_cycles)
  else (
    let r = edge board r ~command:(Some operation) in
    match r.machine.last.command with
    | Machine.Command_result.Accepted _ -> Ok (r, r.machine.time)
    | Rejected { reason = Fault.Reject.Not_ready; _ } -> offer board r ~limit ~operation
    | Rejected { reason; _ } -> Error (r, `Refused reason)
    | Not_offered -> Error (r, `Refused Fault.Reject.Not_ready))
;;

(* Run the machine on until the accepted operation stops stalling the core. *)
let rec settle board (r : 'state Running.t) ~limit =
  if Option.is_none r.machine.wait
  then Ok r
  else if r.cycles >= limit
  then Error (r, `Out_of_cycles)
  else settle board (edge board r ~command:None) ~limit
;;

let run ?(machine = Machine.create ()) ?(max_cycles = 100_000) board t =
  match validate t with
  | Error _ as error -> error
  | Ok () ->
    let peer, pin_in = board.Board.next board.Board.initial machine in
    let start =
      { Running.machine
      ; peer
      ; pin_in
      ; label = None
      ; entries = []
      ; edges = []
      ; cycles = 0
      }
    in
    let rec go (r : 'state Running.t) index steps =
      match steps with
      | [] -> r, Outcome.Completed
      | step :: rest ->
        (match (step : Step.t) with
         | At label ->
           let r =
             { r with
               Running.label = Some label
             ; entries = Entry.Mark { time = r.machine.time; label } :: r.entries
             }
           in
           go r (index + 1) rest
         | Sample { pin; name } ->
           let sampled =
             { Sampled.time = r.machine.time
             ; name
             ; pin
             ; level = Input_pins.level r.machine.inputs ~pin
             }
           in
           go { r with entries = Entry.Read sampled :: r.entries } (index + 1) rest
         | Do operation ->
           let offered = r.machine.time + 1 in
           (match offer board r ~limit:max_cycles ~operation with
            | Error (r, `Out_of_cycles) ->
              r, Outcome.Out_of_cycles { index; limit = max_cycles }
            | Error (r, `Refused reason) ->
              r, Outcome.Refused { index; label = r.label; operation; reason }
            | Ok (r, accepted) ->
              (match settle board r ~limit:max_cycles with
               | Error (r, `Out_of_cycles) ->
                 r, Outcome.Out_of_cycles { index; limit = max_cycles }
               | Ok r ->
                 let record =
                   { Record.index
                   ; label = r.label
                   ; operation
                   ; offered
                   ; accepted
                   ; completed = r.machine.time
                   }
                 in
                 go { r with entries = Entry.Ran record :: r.entries } (index + 1) rest)))
    in
    let r, outcome = go start 0 t.steps in
    Ok
      { Trace.name = t.name
      ; entries = List.rev r.entries
      ; edges = List.rev r.edges
      ; outcome
      ; final = r.machine
      ; peer = r.peer
      }
;;
