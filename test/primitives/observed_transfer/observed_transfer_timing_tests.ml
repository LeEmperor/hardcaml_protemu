(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "observed_transfer_timing_tests.ml" *)

open! Core
open! Observed_transfer_timing_testbench

let require_passed run = [%test_result: Outcome.t] ~expect:Passed run.Run.outcome

let config ~direction ~bit_count ~bit_order ~tx_value ~launch ~sample ~pacing_edge =
  let output_pin, input_pin =
    match direction with
    | Kinds.Direction.Tx_only -> Some 0, None
    | Rx_only -> None, Some 2
    | Duplex -> Some 0, Some 2
  in
  { Config.descriptor =
      { F_model.Transfer.direction
      ; bit_count
      ; bit_order
      ; tx_value
      ; output_pin
      ; input_pin
      ; clock_pin = None
      ; idle_output = false
      ; idle_clock = false
      ; initial_delay = None
      ; launch
      ; sample
      ; pacing = Observed_edge { pin = 1; edge = pacing_edge }
      }
  ; start_pin = 3
  ; start_edge = Kinds.Edge.Rising
  ; cancel = None
  }
;;

let%expect_test "timestamped event-to-engine-to-pin transactions match the independent \
                 model"
  =
  let run = run (phase_scenario 0) in
  require_passed run;
  List.iter run.actual ~f:(fun sample ->
    if sample.start_edge <> 0 || sample.pacing_edge <> 0 || sample.done_ <> 0
    then print_endline (Sample.to_line sample));
  print_endline "pin transactions:";
  List.iter run.actual_transactions ~f:(fun transaction ->
    print_endline (Pin_transaction.to_line transaction));
  [%expect
    {|
    edge 3 t=35 sample=36 snapshot=8 start=1 pace=0 armed=1 busy=0 claim=0 pins=0 oe=0 done=0 rx_valid=0 rx=0 rejected=0 underrun=0 overrun=0
    edge 6 t=65 sample=66 snapshot=10 start=0 pace=1 armed=0 busy=1 claim=1 pins=1 oe=1 done=0 rx_valid=0 rx=0 rejected=0 underrun=0 overrun=0
    edge 9 t=95 sample=96 snapshot=8 start=0 pace=1 armed=0 busy=1 claim=1 pins=1 oe=1 done=0 rx_valid=0 rx=0 rejected=0 underrun=0 overrun=0
    edge 10 t=105 sample=106 snapshot=8 start=0 pace=0 armed=0 busy=0 claim=0 pins=0 oe=0 done=1 rx_valid=0 rx=0 rejected=0 underrun=0 overrun=0
    pin transactions:
    t=45 claim=1 pins=1 oe=1
    t=105 claim=0 pins=0 oe=0
    |}]
;;

let%test_unit "all integer phases have the predicted event-to-pin latency" =
  let latencies =
    List.init period ~f:(fun phase ->
      let run = run (phase_scenario phase) in
      require_passed run;
      let first = List.hd_exn run.actual_transactions in
      first.time - (16 + phase))
  in
  [%test_result: int]
    ~message:"minimum timestamped latency"
    ~expect:20
    (List.min_elt latencies ~compare:Int.compare |> Option.value_exn);
  [%test_result: int]
    ~message:"maximum timestamped latency"
    ~expect:29
    (List.max_elt latencies ~compare:Int.compare |> Option.value_exn)
;;

let%test_unit "a timestamped interruption releases the externally visible pin" =
  let run = run abort_scenario in
  require_passed run;
  [%test_result: Pin_transaction.t list]
    ~expect:
      [ { time = 45; claim = 1; pins = 1; pin_oe = 1 }
      ; { time = 75; claim = 0; pins = 0; pin_oe = 0 }
      ]
    run.actual_transactions
;;

let%test_unit "reset, disable, and explicit abort have next-edge release priority" =
  List.iter [ Action.Reset true; Enable false; Abort true ] ~f:(fun action ->
    let run = run (control_interruption_scenario action) in
    require_passed run;
    [%test_result: Pin_transaction.t list]
      ~expect:
        [ { time = 45; claim = 1; pins = 1; pin_oe = 1 }
        ; { time = 75; claim = 0; pins = 0; pin_oe = 0 }
        ]
      run.actual_transactions;
    [%test_result: bool]
      ~message:"interruption is not completion"
      ~expect:false
      (completed run))
;;

let%test_unit "synchronized events take one clock period to reach the engine" =
  let latencies =
    List.init period ~f:(fun phase ->
      let run = run (phase_scenario phase) in
      require_passed run;
      let event = List.find_exn run.actual ~f:(fun sample -> sample.start_edge <> 0) in
      let drive = List.hd_exn run.actual_transactions in
      drive.time - event.time)
  in
  [%test_result: int list] ~expect:(List.init period ~f:(fun _ -> period)) latencies
;;

let%test_unit "external cancellation clears armed and active transactions at every phase" =
  let active_latencies =
    List.init period ~f:(fun phase ->
      let run = run (cancellation_scenario phase) in
      require_passed run;
      [%test_result: bool]
        ~message:"cancel is not completion"
        ~expect:false
        (completed run);
      let release = List.last_exn run.actual_transactions in
      [%test_result: int]
        ~message:"active cancellation releases claim"
        ~expect:0
        release.claim;
      release.time - (76 + phase))
  in
  [%test_result: int]
    ~expect:20
    (List.min_elt active_latencies ~compare:Int.compare |> Option.value_exn);
  [%test_result: int]
    ~expect:29
    (List.max_elt active_latencies ~compare:Int.compare |> Option.value_exn);
  List.iter (List.init period ~f:Fn.id) ~f:(fun phase ->
    let run = run (armed_cancellation_scenario phase) in
    require_passed run;
    [%test_result: Pin_transaction.t list]
      ~message:"armed cancellation never acquires ownership"
      ~expect:[]
      run.actual_transactions;
    [%test_result: int]
      ~message:"armed cancellation clears arm"
      ~expect:0
      (List.last_exn run.actual).armed)
;;

let%test_unit "multi-bit external transfers cover directions, orders, phases, and edges" =
  let cases =
    [ Kinds.Direction.Tx_only, 1, Kinds.Bit_order.Lsb_first, Kinds.Edge.Rising, 0
    ; Rx_only, 4, Msb_first, Falling, 3
    ; Duplex, 7, Lsb_first, Either, 6
    ; Tx_only, 32, Msb_first, Either, 9
    ; Rx_only, 32, Lsb_first, Rising, 2
    ; Duplex, 32, Msb_first, Falling, 8
    ]
  in
  List.iter cases ~f:(fun (direction, bit_count, bit_order, pacing_edge, phase) ->
    List.iter
      [ Kinds.Clock_phase.On_falling, Kinds.Clock_phase.On_rising; On_rising, On_falling ]
      ~f:(fun (launch, sample) ->
        let mask = if bit_count = 32 then -1 else (1 lsl bit_count) - 1 in
        let tx_value = 0xa5a55a5a land mask in
        let rx_word = 0x5aa5a55a land mask in
        let config =
          config ~direction ~bit_count ~bit_order ~tx_value ~launch ~sample ~pacing_edge
        in
        let run =
          run
            (paced_scenario
               ~config
               ~phase
               ~lead:(if Kinds.Direction.equal direction Rx_only then 10 else 30)
               ~high_width:10
               ~low_width:17
               ~rx_word)
        in
        require_passed run;
        [%test_result: bool] ~message:"transfer completed" ~expect:true (completed run);
        if not (Kinds.Direction.equal direction Tx_only)
        then [%test_result: int option] ~expect:(Some rx_word) (received run)))
;;

let%test_unit "all phases support ten-tick pulses and ten-tick start lead" =
  let config =
    config
      ~direction:Kinds.Direction.Rx_only
      ~bit_count:4
      ~bit_order:Kinds.Bit_order.Lsb_first
      ~tx_value:0x9
      ~launch:Kinds.Clock_phase.On_falling
      ~sample:Kinds.Clock_phase.On_rising
      ~pacing_edge:Kinds.Edge.Either
  in
  for phase = 0 to period - 1 do
    let run =
      run
        (paced_scenario ~config ~phase ~lead:10 ~high_width:10 ~low_width:10 ~rx_word:0x6)
    in
    require_passed run;
    [%test_result: bool]
      ~message:"boundary transfer completed"
      ~expect:true
      (completed run)
  done;
  let width_nine_misses =
    List.exists (List.init period ~f:Fn.id) ~f:(fun phase ->
      let run =
        run
          (paced_scenario ~config ~phase ~lead:10 ~high_width:9 ~low_width:9 ~rx_word:0x6)
      in
      require_passed run;
      not (completed run))
  in
  [%test_result: bool]
    ~message:"a sub-period pulse schedule is outside the guaranteed envelope"
    ~expect:true
    width_nine_misses;
  let lead_nine_loses_first_pace =
    List.exists (List.init period ~f:Fn.id) ~f:(fun phase ->
      let run =
        run
          (paced_scenario
             ~config
             ~phase
             ~lead:9
             ~high_width:10
             ~low_width:10
             ~rx_word:0x6)
      in
      require_passed run;
      not (completed run))
  in
  [%test_result: bool]
    ~message:"nine-tick start lead can merge start and first pace"
    ~expect:true
    lead_nine_loses_first_pace
;;

let%test_unit "every start and pacing edge selection passes every integer phase" =
  let edge_kinds = [ Kinds.Edge.Rising; Falling; Either ] in
  List.iter edge_kinds ~f:(fun start_edge ->
    List.iter edge_kinds ~f:(fun pacing_edge ->
      let config =
        { (config
             ~direction:Kinds.Direction.Rx_only
             ~bit_count:1
             ~bit_order:Kinds.Bit_order.Msb_first
             ~tx_value:0
             ~launch:Kinds.Clock_phase.On_falling
             ~sample:Kinds.Clock_phase.On_rising
             ~pacing_edge)
          with
          Config.start_edge
        }
      in
      for phase = 0 to period - 1 do
        let run =
          run
            (paced_scenario
               ~config
               ~phase
               ~lead:10
               ~high_width:10
               ~low_width:13
               ~rx_word:1)
        in
        require_passed run;
        [%test_result: int option] ~expect:(Some 1) (received run)
      done))
;;

let%test_unit "TX preload precedes a peer sampling clock after a thirty-tick lead" =
  let config =
    config
      ~direction:Kinds.Direction.Tx_only
      ~bit_count:1
      ~bit_order:Kinds.Bit_order.Lsb_first
      ~tx_value:1
      ~launch:Kinds.Clock_phase.On_falling
      ~sample:Kinds.Clock_phase.On_rising
      ~pacing_edge:Kinds.Edge.Either
  in
  for phase = 0 to period - 1 do
    let start_time = 46 + phase in
    let run =
      run (paced_scenario ~config ~phase ~lead:30 ~high_width:10 ~low_width:10 ~rx_word:0)
    in
    require_passed run;
    let first_drive = List.hd_exn run.actual_transactions in
    [%test_result: bool]
      ~message:"preload is driven before the first peer sampling transition"
      ~expect:true
      (first_drive.time < start_time + 30)
  done;
  let lead_twenty_nine_has_no_margin =
    List.exists (List.init period ~f:Fn.id) ~f:(fun phase ->
      let start_time = 46 + phase in
      let run =
        run
          (paced_scenario ~config ~phase ~lead:29 ~high_width:10 ~low_width:10 ~rx_word:0)
      in
      require_passed run;
      (List.hd_exn run.actual_transactions).time >= start_time + 29)
  in
  [%test_result: bool]
    ~message:"twenty-nine ticks can coincide with the registered preload"
    ~expect:true
    lead_twenty_nine_has_no_margin
;;

let%test_unit "data must be present when the pacing transition reaches a sampling edge" =
  let receive pace_time data_time data_clear_time =
    let run = run (rx_data_scenario ~pace_time ~data_time ~data_clear_time) in
    require_passed run;
    received run
  in
  [%test_result: int option]
    ~message:"coincident data and exact-edge pace are captured by the stated convention"
    ~expect:(Some 1)
    (receive 85 85 86);
  [%test_result: int option]
    ~message:"data one tick after an exact-edge pace is too late"
    ~expect:(Some 0)
    (receive 85 86 126);
  [%test_result: int option]
    ~message:"post-edge pace needs data held through the next sampling edge"
    ~expect:(Some 0)
    (receive 86 86 95);
  [%test_result: int option]
    ~message:"changing data after that sampling edge is supported"
    ~expect:(Some 1)
    (receive 86 86 96)
;;

let%test_unit "bounded generated external schedules match the independent model" =
  let settings =
    Replay.Settings.create ~seed:20260920 ~trials:48 ~size:32 |> Replay.Settings.override
  in
  let random = Random.State.make [| Replay.Settings.seed settings |] in
  for trial = 0 to Replay.Settings.trials settings - 1 do
    let direction =
      [| Kinds.Direction.Tx_only; Rx_only; Duplex |].(Random.State.int random 3)
    in
    let bit_count = 1 + Random.State.int random 32 in
    let bit_order =
      if Random.State.bool random then Kinds.Bit_order.Lsb_first else Msb_first
    in
    let pacing_edge =
      [| Kinds.Edge.Rising; Falling; Either |].(Random.State.int random 3)
    in
    let launch, sample =
      if Random.State.bool random
      then Kinds.Clock_phase.On_falling, Kinds.Clock_phase.On_rising
      else On_rising, On_falling
    in
    let mask = if bit_count = 32 then -1 else (1 lsl bit_count) - 1 in
    let tx_value = Random.State.bits random land mask in
    let rx_word = Random.State.bits random land mask in
    let config =
      config ~direction ~bit_count ~bit_order ~tx_value ~launch ~sample ~pacing_edge
    in
    let config =
      { config with
        Config.start_edge =
          [| Kinds.Edge.Rising; Falling; Either |].(Random.State.int random 3)
      }
    in
    let run =
      run
        (paced_scenario
           ~config
           ~phase:(Random.State.int random period)
           ~lead:
             ((if Kinds.Direction.equal direction Rx_only then 10 else 30)
              + Random.State.int random 11)
           ~high_width:(10 + Random.State.int random 9)
           ~low_width:(10 + Random.State.int random 9)
           ~rx_word)
    in
    if not (Run.passed run)
    then (
      let replay =
        Replay.create
          ~test:"observed-transfer-timing"
          ~source_file:
            "test/primitives/observed_transfer/observed_transfer_timing_tests.ml"
          ~settings
          ~trial:(Some trial)
          ~config:[%sexp (config : Config.t), (run.outcome : Outcome.t)]
      in
      raise_s
        [%message
          "generated observed-transfer mismatch" (Replay.to_lines replay : string list)]);
    [%test_result: bool]
      ~message:"generated transfer completed"
      ~expect:true
      (completed run);
    if not (Kinds.Direction.equal direction Tx_only)
    then [%test_result: int option] ~expect:(Some rx_word) (received run)
  done
;;
