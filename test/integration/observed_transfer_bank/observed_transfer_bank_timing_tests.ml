(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "observed_transfer_bank_timing_tests.ml" *)

open! Core
open! Observed_transfer_timing_testbench
open! Observed_transfer_bank_timing_testbench

let peer_setup_ticks = 1

let config ~idle_clock ~direction ~bit_count ~bit_order ~tx_value ~launch ~sample =
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
      ; idle_clock
      ; initial_delay = None
      ; launch
      ; sample
      ; pacing = Observed_edge { pin = 1; edge = Kinds.Edge.Either }
      }
  ; start_pin = 3
  ; start_edge = Kinds.Edge.Rising
  ; cancel = None
  }
;;

let wire_cases ~idle_clock =
  if idle_clock
  then
    [ Kinds.Clock_phase.On_rising, Kinds.Clock_phase.On_falling, 40, 40, 10
    ; Kinds.Clock_phase.On_rising, Kinds.Clock_phase.On_falling, 40, 40, 40
    ; On_falling, On_rising, 10, 10, 40
    ; On_falling, On_rising, 10, 40, 40
    ]
  else
    [ Kinds.Clock_phase.On_falling, Kinds.Clock_phase.On_rising, 40, 10, 40
    ; Kinds.Clock_phase.On_falling, Kinds.Clock_phase.On_rising, 40, 40, 40
    ; On_rising, On_falling, 10, 40, 10
    ; On_rising, On_falling, 10, 40, 40
    ]
;;

let cancellation_scenario_for ~idle_clock phase =
  if not idle_clock
  then cancellation_scenario phase
  else (
    let config =
      { (config
           ~idle_clock:true
           ~direction:Kinds.Direction.Tx_only
           ~bit_count:1
           ~bit_order:Kinds.Bit_order.Lsb_first
           ~tx_value:1
           ~launch:Kinds.Clock_phase.On_rising
           ~sample:Kinds.Clock_phase.On_falling)
        with
        Config.cancel = Some (4, Kinds.Edge.Falling)
      }
    in
    scenario
      ~config
      ~edges:15
      [ Transition.create 0 (Pad 18)
      ; Transition.create 0 (Reset true)
      ; Transition.create 16 (Reset false)
      ; Transition.create 26 (Arm true)
      ; Transition.create 36 (Arm false)
      ; Transition.create 46 (Pad 26)
      ; Transition.create (76 + phase) (Pad 10)
      ])
;;

let%test_unit "bank adds exactly one clock to the observed lane response" =
  let lane_latencies = ref [] in
  let bank_latencies = ref [] in
  for phase = 0 to period - 1 do
    let config =
      config
        ~idle_clock:false
        ~direction:Kinds.Direction.Tx_only
        ~bit_count:1
        ~bit_order:Kinds.Bit_order.Lsb_first
        ~tx_value:1
        ~launch:Kinds.Clock_phase.On_falling
        ~sample:Kinds.Clock_phase.On_rising
    in
    let run =
      run (paced_scenario ~config ~phase ~lead:40 ~high_width:10 ~low_width:40 ~rx_word:0)
    in
    let start_time = 46 + phase in
    lane_latencies
    := ((first_driven run.lane_transactions).time - start_time) :: !lane_latencies;
    bank_latencies
    := ((first_driven run.bank_transactions).time - start_time) :: !bank_latencies
  done;
  [%test_result: int * int]
    ~expect:(20, 29)
    ( List.min_elt !lane_latencies ~compare:Int.compare |> Option.value_exn
    , List.max_elt !lane_latencies ~compare:Int.compare |> Option.value_exn );
  [%test_result: int * int]
    ~expect:(30, 39)
    ( List.min_elt !bank_latencies ~compare:Int.compare |> Option.value_exn
    , List.max_elt !bank_latencies ~compare:Int.compare |> Option.value_exn );
  List.iter2_exn !lane_latencies !bank_latencies ~f:(fun lane bank ->
    [%test_result: int] ~message:"lane-to-bank commit" ~expect:period (bank - lane))
;;

let%test_unit "every ordinary lane data transition commits one clock later" =
  List.iter [ false; true ] ~f:(fun idle_clock ->
    List.iter
      (wire_cases ~idle_clock)
      ~f:(fun (launch, sample, lead, high_width, low_width) ->
        for phase = 0 to period - 1 do
          let config =
            config
              ~idle_clock
              ~direction:Kinds.Direction.Tx_only
              ~bit_count:8
              ~bit_order:Kinds.Bit_order.Lsb_first
              ~tx_value:0x55
              ~launch
              ~sample
          in
          let run =
            run (paced_scenario ~config ~phase ~lead ~high_width ~low_width ~rx_word:0)
          in
          let driven transactions =
            List.filter transactions ~f:(fun transaction ->
              transaction.Pin_transaction.pin_oe <> 0)
          in
          let lane = driven run.lane_transactions in
          let bank = driven run.bank_transactions in
          [%test_result: int] ~expect:(List.length lane) (List.length bank);
          List.iter2_exn lane bank ~f:(fun lane bank ->
            [%test_result: int] ~expect:lane.pins bank.pins;
            [%test_result: int] ~expect:lane.pin_oe bank.pin_oe;
            [%test_result: int]
              ~message:"registered bank commit"
              ~expect:period
              (bank.time - lane.time))
        done))
;;

let%test_unit "external peer receives every bank-committed TX and duplex bit" =
  List.iter [ Kinds.Direction.Tx_only; Duplex ] ~f:(fun direction ->
    List.iter [ Kinds.Bit_order.Lsb_first; Msb_first ] ~f:(fun bit_order ->
      List.iter [ false; true ] ~f:(fun idle_clock ->
        List.iter [ 1; 8; 32 ] ~f:(fun bit_count ->
          List.iter
            (wire_cases ~idle_clock)
            ~f:(fun (launch, sample, lead, high_width, low_width) ->
              let mask = if bit_count = 32 then -1 else (1 lsl bit_count) - 1 in
              let tx_value = 0x5aa5a55a land mask in
              let rx_word = 0xa55a5aa5 land mask in
              let config =
                config
                  ~idle_clock
                  ~direction
                  ~bit_count
                  ~bit_order
                  ~tx_value
                  ~launch
                  ~sample
              in
              for phase = 0 to period - 1 do
                let scenario =
                  paced_scenario ~config ~phase ~lead ~high_width ~low_width ~rx_word
                in
                let run = run scenario in
                let samples = peer_samples scenario run.bank_transactions in
                [%test_result: int] ~expect:bit_count (List.length samples);
                List.iter samples ~f:(fun sample ->
                  [%test_result: bool]
                    ~message:"bank boundary bit and setup"
                    ~expect:true
                    (Peer_sample.valid sample ~minimum_setup:peer_setup_ticks));
                if not (Kinds.Direction.equal direction Tx_only)
                then [%test_result: int option] ~expect:(Some rx_word) (received run);
                [%test_result: bool] ~expect:true (completed run);
                let final = List.last_exn run.samples in
                [%test_result: int]
                  ~message:"ownership released"
                  ~expect:0
                  final.engine_claim;
                [%test_result: int]
                  ~message:"output enable released"
                  ~expect:0
                  final.bank_oe
              done)))))
;;

let%test_unit "RX-only retains the standalone capture envelope and claims no output" =
  List.iter [ false; true ] ~f:(fun idle_clock ->
    List.iter [ 1; 32 ] ~f:(fun bit_count ->
      List.iter [ Kinds.Bit_order.Lsb_first; Msb_first ] ~f:(fun bit_order ->
        let mask = if bit_count = 32 then -1 else (1 lsl bit_count) - 1 in
        let rx_word = 0x5aa5a55a land mask in
        let config =
          config
            ~idle_clock
            ~direction:Kinds.Direction.Rx_only
            ~bit_count
            ~bit_order
            ~tx_value:0
            ~launch:Kinds.Clock_phase.On_falling
            ~sample:Kinds.Clock_phase.On_rising
        in
        for phase = 0 to period - 1 do
          let run =
            run
              (paced_scenario
                 ~config
                 ~phase
                 ~lead:10
                 ~high_width:10
                 ~low_width:10
                 ~rx_word)
          in
          [%test_result: int option] ~expect:(Some rx_word) (received run);
          [%test_result: bool] ~expect:true (completed run);
          [%test_result: bool]
            ~message:"RX-only never acquires engine ownership"
            ~expect:true
            (List.for_all run.samples ~f:(fun sample -> sample.Sample.engine_claim = 0))
        done)))
;;

let%test_unit "thirty-nine-tick bank deadlines fail at some phases" =
  let fails ~idle_clock ~launch ~sample ~lead ~high_width ~low_width =
    List.exists (List.init period ~f:Fn.id) ~f:(fun phase ->
      let config =
        config
          ~idle_clock
          ~direction:Kinds.Direction.Tx_only
          ~bit_count:8
          ~bit_order:Kinds.Bit_order.Lsb_first
          ~tx_value:0x5a
          ~launch
          ~sample
      in
      let scenario =
        paced_scenario ~config ~phase ~lead ~high_width ~low_width ~rx_word:0
      in
      peer_samples scenario (run scenario).bank_transactions
      |> List.exists ~f:(fun sample ->
        not (Peer_sample.valid sample ~minimum_setup:peer_setup_ticks)))
  in
  [%test_result: bool]
    ~expect:true
    (fails
       ~idle_clock:false
       ~launch:Kinds.Clock_phase.On_falling
       ~sample:Kinds.Clock_phase.On_rising
       ~lead:39
       ~high_width:10
       ~low_width:40);
  [%test_result: bool]
    ~expect:true
    (fails
       ~idle_clock:true
       ~launch:Kinds.Clock_phase.On_rising
       ~sample:Kinds.Clock_phase.On_falling
       ~lead:39
       ~high_width:40
       ~low_width:10);
  [%test_result: bool]
    ~message:"idle-low subsequent launch-to-sample deadline"
    ~expect:true
    (fails
       ~idle_clock:false
       ~launch:Kinds.Clock_phase.On_falling
       ~sample:Kinds.Clock_phase.On_rising
       ~lead:40
       ~high_width:10
       ~low_width:39);
  [%test_result: bool]
    ~message:"idle-high subsequent launch-to-sample deadline"
    ~expect:true
    (fails
       ~idle_clock:true
       ~launch:Kinds.Clock_phase.On_rising
       ~sample:Kinds.Clock_phase.On_falling
       ~lead:40
       ~high_width:39
       ~low_width:10)
;;

let%test_unit "cancellation clears the bank before releasing ownership" =
  let clear_latencies = ref [] in
  let release_latencies = ref [] in
  List.iter [ false; true ] ~f:(fun idle_clock ->
    for phase = 0 to period - 1 do
      let run = run (cancellation_scenario_for ~idle_clock phase) in
      let driven = first_driven run.bank_transactions in
      let clear =
        List.find_exn run.bank_transactions ~f:(fun transaction ->
          transaction.Pin_transaction.time > driven.time
          && transaction.pin_oe = 0
          && transaction.claim <> 0)
      in
      let release = List.last_exn run.bank_transactions in
      [%test_result: int] ~expect:0 clear.pin_oe;
      [%test_result: int] ~expect:1 clear.claim;
      [%test_result: int] ~expect:0 release.claim;
      [%test_result: int] ~expect:period (release.time - clear.time);
      [%test_result: bool]
        ~message:"cancellation is cleanup, not lane completion"
        ~expect:false
        (List.exists run.samples ~f:(fun sample -> sample.Sample.done_ <> 0));
      clear_latencies := (clear.time - (76 + phase)) :: !clear_latencies;
      release_latencies := (release.time - (76 + phase)) :: !release_latencies
    done);
  [%test_result: int * int]
    ~expect:(20, 29)
    ( List.min_elt !clear_latencies ~compare:Int.compare |> Option.value_exn
    , List.max_elt !clear_latencies ~compare:Int.compare |> Option.value_exn );
  [%test_result: int * int]
    ~expect:(30, 39)
    ( List.min_elt !release_latencies ~compare:Int.compare |> Option.value_exn
    , List.max_elt !release_latencies ~compare:Int.compare |> Option.value_exn )
;;

let%test_unit "reset, disable, and explicit abort release bank drive and ownership" =
  List.iter [ Action.Reset true; Enable false; Abort true ] ~f:(fun action ->
    let run = run (control_interruption_scenario action) in
    let final = List.last_exn run.samples in
    [%test_result: int] ~expect:0 final.bank_oe;
    [%test_result: int] ~expect:0 final.engine_claim;
    [%test_result: bool]
      ~message:"global interruption is not normal completion"
      ~expect:false
      (List.exists run.samples ~f:(fun sample -> sample.Sample.done_ <> 0)))
;;

let%test_unit "synchronized cancellation can rearm and complete a fresh transfer" =
  let config =
    { (config
         ~idle_clock:true
         ~direction:Kinds.Direction.Tx_only
         ~bit_count:1
         ~bit_order:Kinds.Bit_order.Lsb_first
         ~tx_value:1
         ~launch:Kinds.Clock_phase.On_rising
         ~sample:Kinds.Clock_phase.On_falling)
      with
      Config.cancel = Some (4, Kinds.Edge.Falling)
    }
  in
  let scenario =
    scenario
      ~config
      ~edges:34
      [ Transition.create 0 (Pad 18)
      ; Transition.create 0 (Reset true)
      ; Transition.create 16 (Reset false)
      ; Transition.create 26 (Arm true)
      ; Transition.create 36 (Arm false)
      ; Transition.create 46 (Pad 26)
      ; Transition.create 96 (Pad 10)
      ; Transition.create 116 (Pad 2)
      ; Transition.create 146 (Arm true)
      ; Transition.create 156 (Arm false)
      ; Transition.create 186 (Pad 10)
      ; Transition.create 226 (Pad 8)
      ; Transition.create 266 (Pad 10)
      ]
  in
  let run = run scenario in
  [%test_result: bool]
    ~message:"freshly armed transfer completes"
    ~expect:true
    (List.exists run.samples ~f:(fun sample -> sample.Sample.done_ <> 0));
  let final = List.last_exn run.samples in
  [%test_result: int] ~expect:0 final.engine_claim;
  [%test_result: int] ~expect:0 final.bank_oe
;;

let%test_unit "bounded generated bank-boundary schedules meet the peer contract" =
  let settings =
    Replay.Settings.create ~seed:20260920 ~trials:24 ~size:32 |> Replay.Settings.override
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
    let idle_clock = Random.State.bool random in
    let cases = wire_cases ~idle_clock in
    let launch, sample, lead, high_width, low_width =
      List.nth_exn cases (Random.State.int random (List.length cases))
    in
    let mask = if bit_count = 32 then -1 else (1 lsl bit_count) - 1 in
    let tx_value = Random.State.bits random land mask in
    let rx_word = Random.State.bits random land mask in
    let config =
      config ~idle_clock ~direction ~bit_count ~bit_order ~tx_value ~launch ~sample
    in
    let lead, high_width, low_width =
      if Kinds.Direction.equal direction Rx_only
      then 10, 10, 10
      else
        ( lead
        , high_width + Random.State.int random 9
        , low_width + Random.State.int random 9 )
    in
    let scenario =
      paced_scenario
        ~config
        ~phase:(Random.State.int random period)
        ~lead
        ~high_width
        ~low_width
        ~rx_word
    in
    let run = run scenario in
    let peer_ok =
      Kinds.Direction.equal direction Rx_only
      ||
      let samples = peer_samples scenario run.bank_transactions in
      List.length samples = bit_count
      && List.for_all samples ~f:(fun sample ->
        Peer_sample.valid sample ~minimum_setup:peer_setup_ticks)
    in
    let rx_ok =
      Kinds.Direction.equal direction Tx_only
      || Option.equal Int.equal (received run) (Some rx_word)
    in
    let final = List.last_exn run.samples in
    if not
         (peer_ok && rx_ok && completed run && final.engine_claim = 0 && final.bank_oe = 0)
    then (
      let replay =
        Replay.create
          ~test:"observed-transfer-bank-timing"
          ~source_file:
            "test/integration/observed_transfer_bank/observed_transfer_bank_timing_tests.ml"
          ~settings
          ~trial:(Some trial)
          ~config:
            [%sexp
              (config : Config.t)
              , (scenario : Scenario.t)
              , (run : Run.t)
              , (peer_ok : bool)
              , (rx_ok : bool)]
      in
      raise_s
        [%message
          "generated observed-transfer bank mismatch"
            (Replay.to_lines replay : string list)])
  done
;;
