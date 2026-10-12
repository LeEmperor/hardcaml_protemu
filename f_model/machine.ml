(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "machine.ml" *)
(* The reference machine: all of the model's state, and one rising clock edge.

   This is the independent execution model construction-plan.md section 9 requires. It is
   plain OCaml with no Hardcaml dependency, so a disagreement between it and the RTL is
   evidence rather than a shared mistake.

   WHAT IT IS NOT, YET. There is no decoder. P1.5 chooses the encoding and P3.2 implements
   fetch/decode/execute, so until then commands arrive from the harness rather than from
   the program store, which is exactly how the phase plan's first working slice describes
   the UART transmit demonstration. Fetch itself is modelled - the port, latency one, the
   held output, and the rule that an unspecified word can never be an instruction -
   because those are P1.1 deliverables and the RTL scaffold already drives that port. The
   fetched word is checked and then discarded.

   Transfers are latched and validated but never executed; see transfer.ml.

   STATE AND TIME. [t] holds the values registered at the end of an edge, so
   [step t input] applies the inputs sampled at the next rising edge and returns the state
   after it. Nothing is mutable: a test can keep an old [t] and compare.

   READY IS A MOORE OUTPUT. [command_ready t] is computed from the state before the edge,
   which is what a registered ready signal does in hardware. A wait that finishes at edge
   k therefore raises ready after k, and the next command is accepted at k+1, not at k. A
   command offered at an edge where ready was low is refused with [Not_ready]; it is not
   queued.

   ORDER WITHIN ONE EDGE. Everything below happens at the same edge; the order is only how
   the model resolves what depends on what.

   1. Reset, if asserted, wins over everything else and returns the reset state.
   2. The input synchronizers advance, producing this edge's snapshot and its edges.
   3. ABORT, or the design being disabled, is decided next, because it discards the work
      that steps 4 to 7 would otherwise resolve.
   4. The read issued at the previous edge is consumed: latency one.
   5. The active core wait and the periodic tick resolve, producing this edge's events.
      The tick resolves whether or not the core is waiting, which is what "a core wait
      stalls control, not engines" means.
   6. The execution request (RUN, STOP, ABORT, single step) is applied.
   7. A command is accepted if ready, validated, and applied. Its parameters are latched
      here, at acceptance.
   8. The store port for the next edge is driven, and the store samples it.
   9. Latched status takes this edge's events and acknowledgements, set-wins.

   REJECTED IS NOT FAULTED. A refused command reports a reason in [last.command] and is
   not latched anywhere. Only conditions a program cannot legitimately provoke set sticky
   bits in [faults]; see fault.ml.
*)

open! Core
open! Kinds

module Request = struct
  (* Execution control from the host. STOP asks for a boundary stop; ABORT does not wait
     for one (construction-plan.md section 3, rule 6). *)
  type t =
    | Run
    | Stop
    | Abort
    | Step
  [@@deriving sexp, compare, equal, enumerate]
end

module Exec = struct
  type t =
    | Halted
    | Running
    | (* STOP accepted; halting at the next instruction boundary. *)
      Stopping
    | (* One single step in flight. Reached only from [Halted] with engines idle. *)
      Stepping
  [@@deriving sexp, compare, equal, enumerate]
end

module Fifo_operation = struct
  type t =
    | Push of int
    | Pop
  [@@deriving sexp, compare, equal]
end

module Core_wait = struct
  (* Why the control core is stalled. Deadlines are absolute cycle numbers: a command
     accepted at edge k with delay n has deadline k + n, so it fires at k + n. *)
  type t =
    | Delay of { deadline : int }
    | Level of
        { pin : int
        ; level : bool
        ; deadline : int option
        }
    | Edge of
        { pin : int
        ; edge : Edge.t
        ; deadline : int option
        }
    | (* A blocking queue operation retried at every edge until it fits. *)
      Fifo of
        { fifo : Fifo_id.t
        ; operation : Fifo_operation.t
        }
  [@@deriving sexp, compare, equal]
end

module Periodic = struct
  (* A free-running tick generator. It is not a wait: it never stalls the core, and it
     keeps running while the core is stalled on something else. *)
  type t =
    { period : int
    ; next : int
    }
  [@@deriving sexp, compare, equal]
end

module Load = struct
  (* A host program write. Accepted only while halted (construction-plan.md section 4);
     P3.1a adds the rest of the gating, including engines idle and load-complete. *)
  type t =
    { address : int
    ; data : int
    }
  [@@deriving sexp, compare, equal]
end

module Command_result = struct
  type t =
    | Not_offered
    | Accepted of Operation.t
    | Rejected of
        { command : Operation.t
        ; reason : Fault.Reject.t
        }
  [@@deriving sexp, compare, equal]
end

module Input = struct
  type t =
    { (* Synchronous, active high, and dominant over every other input. *)
      reset : bool
    ; (* Low aborts work in flight and releases the protocol pins. *)
      enable : bool
    ; (* The asynchronous pad value, before synchronization. *)
      pin_in : int
    ; request : Request.t option
    ; (* Offered with valid high; accepted only when [command_ready] was high. *)
      command : Operation.t option
    ; acknowledge : Event.Kind.t list
    ; load : Load.t option
    }
  [@@deriving sexp, compare, equal]

  let idle =
    { reset = false
    ; enable = true
    ; pin_in = 0
    ; request = None
    ; command = None
    ; acknowledge = []
    ; load = None
    }
  ;;
end

module Last = struct
  (* Everything about the most recent edge that the registered state does not already
     show. Kept in [t] so that one value describes the whole edge and a test never has to
     reconstruct what happened from a side channel. *)
  type t =
    { (* What the core drove into the store at this edge. *)
      port : Program_store.Port.t
    ; command : Command_result.t
    ; request : (unit, Fault.Reject.t) Result.t option
    ; load : (unit, Fault.Reject.t) Result.t option
    ; (* The word consumed at this edge, if a read was in flight. *)
      fetched : Program_store.Word.t option
    ; popped : int option
    ; events : Event.Kind.t list
    }
  [@@deriving sexp, compare, equal]

  let none =
    { port = Program_store.Port.idle
    ; command = Command_result.Not_offered
    ; request = None
    ; load = None
    ; fetched = None
    ; popped = None
    ; events = []
    }
  ;;
end

type t =
  { time : int
  ; exec : Exec.t
  ; pins : Pin_bank.t
  ; inputs : Input_pins.t
  ; events : Event.t
  ; faults : Fault.t
  ; tx_fifo : Fifo.t
  ; rx_fifo : Fifo.t
  ; store : Program_store.t
  ; (* Latched at [Configure_transfer] and held until replaced. *)
    descriptor : Transfer.t option
  ; wait : Core_wait.t option
  ; periodic : Periodic.t option
  ; pc : int
  ; (* The address of the read issued at the previous edge, whose data is readable now. *)
    fetch_pending : int option
  ; last : Last.t
  }
[@@deriving sexp_of, equal]

let create ?(program_depth = 256) ?(program_width = 8) ?(fifo_depth = 8) () =
  { time = 0
  ; exec = Exec.Halted
  ; pins = Pin_bank.released
  ; inputs = Input_pins.cleared
  ; events = Event.cleared
  ; faults = Fault.none
  ; tx_fifo = Fifo.create ~id:Fifo_id.Tx ~depth:fifo_depth
  ; rx_fifo = Fifo.create ~id:Fifo_id.Rx ~depth:fifo_depth
  ; store = Program_store.create ~depth:program_depth ~width:program_width
  ; descriptor = None
  ; wait = None
  ; periodic = None
  ; pc = 0
  ; fetch_pending = None
  ; last = Last.none
  }
;;

(* Observation helpers, so tests read the model the way a testbench reads a DUT. *)
let pin_out t = t.pins.value
let pin_output_enable t = t.pins.output_enable
let pin_snapshot t = Input_pins.snapshot t.inputs
let is_halted t = Exec.equal t.exec Exec.Halted
let event_is_set t kind = Event.is_set t.events kind
let waiting t = Option.is_some t.wait

(* An engine holds a transaction open. A periodic tick generator is not a transaction: it
   has no state to leave half finished, so it does not block a single step. *)
let engines_idle t =
  Option.is_none t.wait
  && List.for_all t.pins.claims ~f:(fun (owner, mask) ->
    match owner with
    | Owner.Software -> true
    | Owner.Engine _ -> mask = 0)
;;

(* Moore: computed from the state before the edge. *)
let command_ready t = Option.is_none t.wait

(* Synchronous reset. Protocol pins are released, queue validity and event state are
   cleared, and execution halts. The program store keeps both its contents and its output
   register: its contract has no reset, and nothing may depend on uninitialized memory
   (construction-plan.md sections 3 and 4). *)
let reset t =
  { t with
    time = 0
  ; exec = Exec.Halted
  ; pins = Pin_bank.released
  ; inputs = Input_pins.cleared
  ; events = Event.cleared
  ; faults = Fault.none
  ; tx_fifo = Fifo.clear t.tx_fifo
  ; rx_fifo = Fifo.clear t.rx_fifo
  ; descriptor = None
  ; wait = None
  ; periodic = None
  ; pc = 0
  ; fetch_pending = None
  ; last = Last.none
  }
;;

(* Work that an ABORT, or the design being disabled, would abandon. *)
let has_work_in_flight t =
  Option.is_some t.wait
  || Option.is_some t.fetch_pending
  || not (Exec.equal t.exec Exec.Halted)
;;

(* Disabling aborts work and releases the protocol pins. Latched status survives, so
   disabling hides no evidence; the store port is idle, so its output holds. *)
let disabled t ~time ~inputs =
  let aborted = has_work_in_flight t in
  let events = if aborted then [ Event.Kind.Aborted ] else [] in
  let faults =
    match t.wait with
    | Some (Core_wait.Fifo _) -> Fault.set_fifo_fault t.faults
    | _ -> t.faults
  in
  { t with
    time
  ; inputs
  ; exec = Exec.Halted
  ; pins = Pin_bank.released
  ; wait = None
  ; periodic = None
  ; fetch_pending = None
  ; faults
  ; events = Event.step t.events ~set:events ~ack:[]
  ; last = { Last.none with events }
  }
;;

(* The mutable-looking parts of an edge, threaded through command application. *)
module Acc = struct
  type t =
    { pins : Pin_bank.t
    ; tx_fifo : Fifo.t
    ; rx_fifo : Fifo.t
    ; descriptor : Transfer.t option
    ; wait : Core_wait.t option
    ; periodic : Periodic.t option
    ; faults : Fault.t
    ; popped : int option
    }

  let fifo t = function
    | Fifo_id.Tx -> t.tx_fifo
    | Fifo_id.Rx -> t.rx_fifo
  ;;

  let set_fifo t id fifo =
    match (id : Fifo_id.t) with
    | Tx -> { t with tx_fifo = fifo }
    | Rx -> { t with rx_fifo = fifo }
  ;;
end

(* Try a queue operation once. Used both for a freshly accepted command and for retrying a
   blocking one the core is already stalled on, so the two cannot drift apart. *)
let try_fifo (acc : Acc.t) ~fifo ~(operation : Fifo_operation.t) =
  let queue = Acc.fifo acc fifo in
  match operation with
  | Push data ->
    Result.map (Fifo.push queue data) ~f:(fun queue -> Acc.set_fifo acc fifo queue)
  | Pop ->
    Result.map (Fifo.pop queue) ~f:(fun (queue, data) ->
      { (Acc.set_fifo acc fifo queue) with popped = Some data })
;;

(* A queue operation that cannot complete now either stalls the core or is refused. *)
let issue_fifo (acc : Acc.t) ~fifo ~operation ~(blocking : Blocking.t) =
  match try_fifo acc ~fifo ~operation with
  | Ok acc -> Ok acc
  | Error reason ->
    (match blocking with
     | Nonblocking -> Error reason
     | Blocking -> Ok { acc with wait = Some (Core_wait.Fifo { fifo; operation }) })
;;

(* Apply an already structurally validated command. What remains are the checks that need
   machine state: pin ownership and queue occupancy. Firmware pin operations act as
   [Owner.Software]. *)
let apply_command (acc : Acc.t) (command : Operation.t) ~time ~inputs =
  let ownership_fault (acc : Acc.t) reason =
    Error (reason, { acc with faults = Fault.set_pin_ownership acc.faults })
  in
  let plain (acc : Acc.t) reason = Error (reason, acc) in
  match command with
  | Write_pins write ->
    (match Pin_bank.commit acc.pins write ~owner:Owner.Software with
     | Ok pins -> Ok { acc with pins }
     | Error reason -> ownership_fault acc reason)
  | Claim_pins { owner; mask } ->
    (match Pin_bank.claim acc.pins ~owner ~mask with
     | Ok pins -> Ok { acc with pins }
     | Error reason -> ownership_fault acc reason)
  | Release_pins { owner; mask } ->
    (match Pin_bank.release acc.pins ~owner ~mask with
     | Ok pins -> Ok { acc with pins }
     | Error reason -> ownership_fault acc reason)
  | Wait_cycles { delay } ->
    Ok { acc with wait = Some (Core_wait.Delay { deadline = time + delay }) }
  | Wait_level { pin; level; timeout } ->
    (* A level wait completes immediately when the synchronized condition already holds
       (construction-plan.md section 3, rule 3), so it never enters a stall. *)
    if Bool.equal (Input_pins.level inputs ~pin) level
    then Ok acc
    else
      Ok
        { acc with
          wait =
            Some
              (Core_wait.Level
                 { pin; level; deadline = Option.map timeout ~f:(fun n -> time + n) })
        }
  | Wait_edge { pin; edge; timeout } ->
    (* An edge wait always stalls: it arms for transitions first visible after this edge,
       so an edge already in this snapshot is stale and does not count. *)
    Ok
      { acc with
        wait =
          Some
            (Core_wait.Edge
               { pin; edge; deadline = Option.map timeout ~f:(fun n -> time + n) })
      }
  | Start_periodic { period } ->
    Ok { acc with periodic = Some { Periodic.period; next = time + period } }
  | Stop_periodic -> Ok { acc with periodic = None }
  | Configure_transfer descriptor ->
    (* Structural validation already passed; ownership of the pins it would drive is
       checked at issue (P2.5), not here, because configuring is not yet driving. *)
    Ok { acc with descriptor = Some descriptor }
  | Fifo_push { fifo; data; blocking } ->
    (match issue_fifo acc ~fifo ~operation:(Push data) ~blocking with
     | Ok acc -> Ok acc
     | Error reason -> plain acc reason)
  | Fifo_pop { fifo; blocking } ->
    (match issue_fifo acc ~fifo ~operation:Pop ~blocking with
     | Ok acc -> Ok acc
     | Error reason -> plain acc reason)
;;

(* Resolve a timing wait at this edge. The order of the two tests is the
   event-over-timeout precedence of construction-plan.md section 3, rule 3: a matching
   condition and an expiring deadline at the same edge complete the wait, they do not time
   it out. *)
let resolve_timing_wait wait ~time ~inputs =
  let expired deadline = Option.exists deadline ~f:(fun deadline -> time >= deadline) in
  match (wait : Core_wait.t) with
  | Delay { deadline } ->
    if time >= deadline then [ Event.Kind.Delay_expired ], None else [], Some wait
  | Level { pin; level; deadline } ->
    if Bool.equal (Input_pins.level inputs ~pin) level
    then [ Event.Kind.Wait_complete ], None
    else if expired deadline
    then [ Event.Kind.Wait_timeout ], None
    else [], Some wait
  | Edge { pin; edge; deadline } ->
    if Input_pins.has_edge inputs ~pin ~edge
    then [ Event.Kind.Wait_complete ], None
    else if expired deadline
    then [ Event.Kind.Wait_timeout ], None
    else [], Some wait
  | Fifo _ -> [], Some wait
;;

let resolve_periodic periodic ~time =
  match (periodic : Periodic.t option) with
  | None -> [], None
  | Some { period; next } ->
    if time >= next
    then [ Event.Kind.Tick ], Some { Periodic.period; next = next + period }
    else [], periodic
;;

let step t (input : Input.t) =
  if input.reset
  then reset t
  else (
    let time = t.time + 1 in
    let inputs = Input_pins.step t.inputs ~pin_in:input.pin_in in
    if not input.enable
    then disabled t ~time ~inputs
    else (
      let aborting =
        match input.request with
        | Some Request.Abort -> true
        | _ -> false
      in
      let abort_events =
        if aborting && has_work_in_flight t then [ Event.Kind.Aborted ] else []
      in
      (* Step 4: latency one. The read issued at the previous edge is readable now. A word
         the contract leaves unspecified can never be accepted as an instruction, so it
         raises a sticky fault and halts. An abort at this edge discards it instead. *)
      let fetched =
        if aborting
        then None
        else Option.map t.fetch_pending ~f:(fun _ -> t.store.read_data)
      in
      let fetch_invalid =
        match fetched with
        | Some Program_store.Word.Unspecified -> true
        | Some (Specified _) | None -> false
      in
      (* Step 5. Both resolve even while the other is stalled. *)
      let wait_events, wait_after =
        match t.wait with
        | None -> [], None
        | Some _ when aborting -> [], None
        | Some wait -> resolve_timing_wait wait ~time ~inputs
      in
      let tick_events, periodic_after =
        if aborting then [], None else resolve_periodic t.periodic ~time
      in
      let acc =
        { Acc.pins = (if aborting then Pin_bank.released else t.pins)
        ; tx_fifo = t.tx_fifo
        ; rx_fifo = t.rx_fifo
        ; descriptor = t.descriptor
        ; wait = wait_after
        ; periodic = periodic_after
        ; faults =
            (let faults =
               if fetch_invalid then Fault.set_fetch_invalid t.faults else t.faults
             in
             match t.wait with
             | Some (Core_wait.Fifo _) when aborting -> Fault.set_fifo_fault faults
             | _ -> faults)
        ; popped = None
        }
      in
      (* Retry a blocking queue operation the core is already stalled on, so that one edge
         both frees the slot and completes the operation waiting for it. *)
      let acc =
        match acc.wait with
        | Some (Core_wait.Fifo { fifo; operation }) ->
          (match try_fifo { acc with wait = None } ~fifo ~operation with
           | Ok acc -> acc
           | Error _ -> acc)
        | _ -> acc
      in
      (* An instruction boundary is the edge on which the instruction in progress
         finishes. Consuming a fetched word is one; so is a stalling operation completing,
         because a stalled core issues no fetch and would otherwise never reach a boundary
         again. With nothing in flight at all, every edge is a boundary. This is what STOP
         waits for and what ABORT does not. *)
      let boundary =
        Option.is_some fetched
        || (Option.is_some t.wait && Option.is_none acc.wait)
        || (Option.is_none t.fetch_pending && Option.is_none t.wait)
      in
      (* Step 6: the execution request. *)
      let engines_were_idle = engines_idle t in
      let request_result, exec_after =
        match input.request with
        | Some Request.Abort -> Some (Ok ()), Exec.Halted
        | _ when fetch_invalid ->
          (* The fault halts the core and any request at this edge loses to it. The pins
             keep whatever they were driving: a program error is not an abort, and the
             host decides whether to abort, reset, or inspect. Recovery is P3. *)
          Option.map input.request ~f:(fun _ -> Error Fault.Reject.Faulted), Exec.Halted
        | Some Request.Run ->
          (match t.exec with
           (* P3.1a adds the load-complete precondition on RUN. *)
           | Halted | Stopping -> Some (Ok ()), Exec.Running
           | Running -> Some (Ok ()), Exec.Running
           | Stepping -> Some (Ok ()), Exec.Running)
        | Some Request.Stop ->
          (match t.exec with
           | Running -> Some (Ok ()), if boundary then Exec.Halted else Exec.Stopping
           | Stopping -> Some (Ok ()), if boundary then Exec.Halted else Exec.Stopping
           | Stepping -> Some (Ok ()), Exec.Halted
           | Halted -> Some (Ok ()), Exec.Halted)
        | Some Request.Step ->
          (match t.exec with
           | Halted when engines_were_idle -> Some (Ok ()), Exec.Stepping
           | Halted -> Some (Error Fault.Reject.Engines_not_idle), Exec.Halted
           | Running | Stopping | Stepping -> Some (Error Fault.Reject.Not_halted), t.exec)
        | None ->
          (match t.exec with
           | Halted -> None, Exec.Halted
           | Running -> None, Exec.Running
           | Stopping -> None, if boundary then Exec.Halted else Exec.Stopping
           | Stepping -> None, Exec.Halted)
      in
      (* Step 7: command acceptance. [command_ready] was computed before this edge. *)
      let command_result, acc =
        match input.command with
        | None -> Command_result.Not_offered, acc
        | Some command ->
          let reject reason acc = Command_result.Rejected { command; reason }, acc in
          if aborting
          then reject Fault.Reject.Aborting acc
          else if not (command_ready t)
          then reject Fault.Reject.Not_ready acc
          else (
            match Operation.validate command with
            | Error reason -> reject reason acc
            | Ok () ->
              (match apply_command acc command ~time ~inputs with
               | Ok acc -> Command_result.Accepted command, acc
               | Error (reason, acc) -> reject reason acc))
      in
      (* Step 8: drive the store port for the next edge. A fetch is issued only while
         running and not stalled, so a core wait stops instruction fetch without touching
         any engine. Host writes are accepted only while halted, so a write and a fetch
         can never want the single port at the same edge. *)
      let load_result, port, pc =
        if aborting
        then None, Program_store.Port.idle, t.pc
        else (
          match exec_after with
          | (Exec.Running | Exec.Stepping) when Option.is_none acc.wait ->
            let load_result =
              Option.map input.load ~f:(fun _ -> Error Fault.Reject.Not_halted)
            in
            ( load_result
            , Program_store.Port.read ~address:t.pc
              (* The program counter wraps at the store depth so the model never issues an
                 address outside the memory contract. Refusing a fetch outside the loaded
                 image is P3.1a. *)
            , (t.pc + 1) % t.store.depth )
          | Exec.Halted ->
            (match input.load with
             | Some { address; data } ->
               Some (Ok ()), Program_store.Port.write ~address ~data, t.pc
             | None -> None, Program_store.Port.idle, t.pc)
          | Exec.Running | Exec.Stepping | Exec.Stopping ->
            let load_result =
              Option.map input.load ~f:(fun _ -> Error Fault.Reject.Not_halted)
            in
            load_result, Program_store.Port.idle, t.pc)
      in
      let store = Program_store.step t.store port in
      (* Step 9: latched status. A newly set sticky fault raises its own event. *)
      let fault_events =
        if Fault.any acc.faults && not (Fault.equal acc.faults t.faults)
        then [ Event.Kind.Fault ]
        else []
      in
      let set = abort_events @ wait_events @ tick_events @ fault_events in
      { time
      ; exec = exec_after
      ; pins = acc.pins
      ; inputs
      ; events = Event.step t.events ~set ~ack:input.acknowledge
      ; faults = acc.faults
      ; tx_fifo = acc.tx_fifo
      ; rx_fifo = acc.rx_fifo
      ; store
      ; descriptor = acc.descriptor
      ; wait = acc.wait
      ; periodic = acc.periodic
      ; pc
      ; fetch_pending =
          (if port.enable && not port.write_enable then Some port.address else None)
      ; last =
          { Last.port
          ; command = command_result
          ; request = request_result
          ; load = load_result
          ; fetched
          ; popped = acc.popped
          ; events = set
          }
      }))
;;
