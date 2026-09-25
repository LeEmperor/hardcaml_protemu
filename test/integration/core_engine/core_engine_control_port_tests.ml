(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "core_engine_control_port_tests.ml" *)
(* Focused checks of the [Control_port] temporal contract at the real [Integrated_core]
   boundary.

   These cover obligations that no earlier suite checks at this boundary: idle decisions,
   refusal under reset and disable, cross-group arbitration, READBACK response timing and
   cancellation, and STOP acceptance versus halting. Program-request decisions are also
   compared every edge against the independent model in [test/core/protocol_core]. ABORT
   cleanup is checked in [core_engine_tests.ml] and through [Simulator_backend] in
   [test/integration/host_simulator]. Every expectation here is written out by hand from
   the contract; none is computed from the core's acceptance expressions.
*)

open! Core
open! Hardcaml
open! Hardcaml_protemu
open! Protemu_isa
open! Core_engine_testbench

let halt_program = program "halt" [ Instruction.Halt ]

(* Offer [request] for one cycle and return the decisions sampled before its edge. *)
let decide t request =
  let sampled = ref None in
  step
    ~before:(fun _ o ->
      sampled := Some (Control_port.Decision.map o.control_decision_o ~f:( ! )))
    t
    request;
  Option.value_exn !sampled
;;

(* The accepted/rejected pair a single shared request receives. *)
let pair (d : Bits.t Control_port.Decision.t) request =
  let accepted, rejected =
    match request with
    | Start _ -> d.load_start_accepted, d.load_start_rejected
    | Write _ -> d.load_write_accepted, d.load_write_rejected
    | Read _ | Verify _ -> d.readback_accepted, d.readback_rejected
    | Complete -> d.load_complete_accepted, d.load_complete_rejected
    | Run -> d.run_accepted, d.run_rejected
    | Stop -> d.stop_accepted, d.stop_rejected
    | Abort -> d.abort_accepted, d.abort_rejected
    | _ -> raise_s [%message "not a shared control request"]
  in
  Bits.to_bool accepted, Bits.to_bool rejected
;;

(* Names of the decision fields that are high, ignoring the response data word. *)
let raised (d : Bits.t Control_port.Decision.t) =
  Control_port.Decision.(map2 port_names d ~f:(fun name value -> name, value) |> to_list)
  |> List.filter_map ~f:(fun (name, value) ->
    if (not (String.equal name "readback_response_data")) && Bits.to_int_trunc value <> 0
    then Some name
    else None)
;;

let words = [| 0x1234; 0xabcd |]

(* One core per prepared state, each chosen so the named request alone is accepted. *)
let fresh () = create ()

let started () =
  let t = create () in
  step t (Start 2);
  t
;;

let written () =
  let t = started () in
  Array.iteri words ~f:(fun address data -> step t (Write (address, data)));
  t
;;

let verified () =
  let t = written () in
  Array.iteri words ~f:(fun address expected ->
    step t (Verify (address, expected));
    step t Idle);
  t
;;

let loaded () =
  let t = create () in
  ignore (load_program t halt_program : Assembler.Assembled.t);
  t
;;

let acceptable_offers =
  [ "load-start", fresh, Start 2
  ; "load-write", started, Write (0, words.(0))
  ; "readback", written, Read 0
  ; "verify", written, Verify (0, words.(0))
  ; "load-complete", verified, Complete
  ; "run", loaded, Run
  ; "stop", loaded, Stop
  ; "abort", loaded, Abort
  ]
;;

let%test_unit "with no offer every shared decision is low" =
  let running () =
    let t = create () in
    ignore
      (load_program
         t
         (program "wait" [ Instruction.Wait_cycles_imm { delay = 20 }; Halt ])
       : Assembler.Assembled.t);
    step t Run;
    step t Idle;
    step t Idle;
    [%test_result: bool] (bool (outputs t).halted_o) ~expect:false;
    t
  in
  List.iter
    [ "reset core", fresh (), Idle
    ; "loaded image", loaded (), Idle
    ; "load session", written (), Idle
    ; "running", running (), Idle
    ; "reset asserted", loaded (), Reset
    ; "disabled", loaded (), Together [ Enable false ]
    ]
    ~f:(fun (state, t, request) ->
      [%test_result: string list] ~message:state (raised (decide t request)) ~expect:[])
;;

let%test_unit "reset and disable refuse every shared offer" =
  List.iter acceptable_offers ~f:(fun (name, prepare, offer) ->
    [%test_result: bool * bool]
      ~message:(name ^ " alone")
      (pair (decide (prepare ()) offer) offer)
      ~expect:(true, false);
    [%test_result: bool * bool]
      ~message:(name ^ " in reset")
      (pair (decide (prepare ()) (Together [ Reset; offer ])) offer)
      ~expect:(false, true);
    (* [Together] lowers [en_i] for this cycle only. *)
    [%test_result: bool * bool]
      ~message:(name ^ " while disabled")
      (pair (decide (prepare ()) (Together [ Enable false; offer ])) offer)
      ~expect:(false, true))
;;

let%test_unit "ABORT, STOP, RUN, and program requests arbitrate across groups" =
  (* An accepted ABORT halts execution, which refuses a program request. *)
  let t = loaded () in
  let d = decide t (Together [ Abort; Start 2 ]) in
  [%test_result: bool * bool] (pair d Abort) ~expect:(true, false);
  [%test_result: bool * bool] (pair d (Start 2)) ~expect:(false, true);
  [%test_result: bool] (bool (outputs t).image_valid_o) ~expect:true;
  (* STOP does not refuse a program request while halted between instructions. *)
  let t = loaded () in
  let d = decide t (Together [ Stop; Start 2 ]) in
  [%test_result: bool * bool] (pair d Stop) ~expect:(true, false);
  [%test_result: bool * bool] (pair d (Start 2)) ~expect:(true, false);
  [%test_result: bool] (bool (outputs t).image_valid_o) ~expect:false;
  [%test_result: bool] (bool (outputs t).load_active_o) ~expect:true;
  (* A program request refuses RUN. *)
  let t = loaded () in
  let d = decide t (Together [ Run; Read 0 ]) in
  [%test_result: bool * bool] (pair d (Read 0)) ~expect:(true, false);
  [%test_result: bool * bool] (pair d Run) ~expect:(false, true);
  [%test_result: bool] (bool (outputs t).halted_o) ~expect:true;
  (* Program priority is by validity: a refused LOAD_START still refuses a legal write. *)
  let t = started () in
  let d = decide t (Together [ Start 0; Write (0, words.(0)) ]) in
  [%test_result: bool * bool] (pair d (Start 0)) ~expect:(false, true);
  [%test_result: bool * bool] (pair d (Write (0, words.(0)))) ~expect:(false, true);
  [%test_result: bool * bool]
    (pair (decide t (Write (0, words.(0)))) (Write (0, words.(0))))
    ~expect:(true, false)
;;

let%test_unit "READBACK responds once, one edge after acceptance, unless cancelled" =
  let response t =
    let d = (outputs t).control_decision_o in
    bool d.readback_response_valid, int d.readback_response_data
  in
  let accepted_read () =
    let t = verified () in
    step t Complete;
    [%test_result: bool * bool] (pair (decide t (Read 1)) (Read 1)) ~expect:(true, false);
    t
  in
  (* Operands are consumed at the offer edge: the idle cycles below drive them to zero. *)
  let t = accepted_read () in
  [%test_result: bool] (fst (response t)) ~expect:false;
  step t Idle;
  [%test_result: bool * int] (response t) ~expect:(true, words.(1));
  [%test_result: bool]
    (bool (outputs t).control_decision_o.readback_response_match)
    ~expect:false;
  step t Idle;
  [%test_result: bool] (fst (response t)) ~expect:false;
  (* A second READBACK is refused while the first is outstanding, which still completes. *)
  let t = accepted_read () in
  [%test_result: bool * bool] (pair (decide t (Read 0)) (Read 0)) ~expect:(false, true);
  [%test_result: bool * int] (response t) ~expect:(true, words.(1));
  (* Reset, disable, an accepted ABORT, or an accepted LOAD_START cancels it. *)
  List.iter
    [ "reset", Reset, None
    ; "disable", Together [ Enable false ], None
    ; "abort", Abort, Some Abort
    ; "load-start", Start 2, Some (Start 2)
    ]
    ~f:(fun (name, cancel, offer) ->
      let t = accepted_read () in
      let d = decide t cancel in
      Option.iter offer ~f:(fun offer ->
        [%test_result: bool * bool] ~message:name (pair d offer) ~expect:(true, false));
      for _ = 1 to 3 do
        [%test_result: bool] ~message:name (fst (response t)) ~expect:false;
        step t Idle
      done)
;;

let%test_unit "STOP acceptance is not a halt, and a STOP accepted while halted is not \
               kept"
  =
  let two_waits =
    program
      "two_waits"
      [ Instruction.Wait_cycles_imm { delay = 4 }; Wait_cycles_imm { delay = 4 }; Halt ]
  in
  let stopped = create () in
  ignore (load_program stopped two_waits : Assembler.Assembled.t);
  step stopped Run;
  while not (bool (outputs stopped).timing_busy_o) do
    step stopped Idle
  done;
  [%test_result: bool * bool] (pair (decide stopped Stop) Stop) ~expect:(true, false);
  [%test_result: bool] (bool (outputs stopped).halted_o) ~expect:false;
  while not (bool (outputs stopped).halted_o) do
    step stopped Idle
  done;
  [%test_result: int] (int (outputs stopped).instruction_count_o) ~expect:1;
  [%test_result: bool] (bool (outputs stopped).normal_halt_o) ~expect:false;
  let halted = create () in
  ignore (load_program halted two_waits : Assembler.Assembled.t);
  [%test_result: bool * bool] (pair (decide halted Stop) Stop) ~expect:(true, false);
  ignore (run_until_halted halted : int);
  [%test_result: int] (int (outputs halted).instruction_count_o) ~expect:3;
  [%test_result: bool] (bool (outputs halted).normal_halt_o) ~expect:true
;;
