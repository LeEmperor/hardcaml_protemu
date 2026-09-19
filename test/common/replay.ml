(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "replay.ml" *)
(* Everything needed to run a generated failure again, recorded beside the failure.

   Seed-based replay is this repository's reproduction path (verification.md section 4):
   there is no stimulus journal and no replay-file format, so a report that omits one of
   these fields is a failure nobody can reproduce. A seed reproduces within the code and
   environment it was recorded in, which is why the source revision, the local diff and
   the tool versions are part of the record rather than assumed.

   The fields divide into two kinds, and the difference matters for expect tests:

   [Settings] and [Trial] are deterministic. The same seed, trial count and size produce
   the same scenarios, so an expect test may snapshot them.

   [Source_identity] is not. It describes the checkout the run happened in, so it changes
   with every commit. [to_string_hum ~redact_source:true] replaces it with a fixed line,
   which is what the controlled-failure fixture snapshots; a real failure prints it.

   Overrides let one recorded seed be rerun, and let a sweep run many, without editing a
   test: PROTEMU_SEED, PROTEMU_TRIALS and PROTEMU_SIZE replace the recorded settings,
   PROTEMU_ARTIFACTS names the directory failure artifacts are written to, and
   PROTEMU_SOURCE_REVISION supplies the revision when git cannot be asked for it.
*)

(* Bound before [Core] is opened, which shadows [Unix] in favour of [Core_unix]. Only
   three calls are needed - run a command, the process id, and one directory - and none of
   them wants the wrapped behaviour, so the plain library is enough. *)
module Posix = Unix
open! Core

(* The generator settings a trial sequence is a function of. A test writes these down
   explicitly, so the regression runs the same cases on every machine. *)
module Settings = struct
  type t =
    { seed : int
    ; trials : int
    ; (* The largest generator size used. Trial [n] is generated at size [n mod (size+1)],
         so a run starts with the smallest cases and grows; this is how a short scenario
         gets tried before a long one rather than by luck. *)
      size : int
    }
  [@@deriving sexp_of, compare, equal, fields ~getters]

  let create ~seed ~trials ~size = { seed; trials; size }
  let size_of_trial t ~trial = trial % (t.size + 1)

  (* An environment override replaces the whole field, never part of it, so a sweep cannot
     end up reporting settings it did not run. *)
  let override t =
    let int_env name ~default =
      match Sys.getenv name with
      | None -> default
      | Some value ->
        (match Int.of_string_opt value with
         | Some value -> value
         | None -> raise_s [%message "not an integer" (name : string) (value : string)])
    in
    { seed = int_env "PROTEMU_SEED" ~default:t.seed
    ; trials = int_env "PROTEMU_TRIALS" ~default:t.trials
    ; size = int_env "PROTEMU_SIZE" ~default:t.size
    }
  ;;
end

(* The checkout and toolchain a recorded seed is only meaningful within.

   [git] is asked for the revision and for whether the working tree differs from it, in
   the source tree rather than in the build directory: dune runs an inline test inside a
   sandbox whose parent holds a stub [.git], so a plain [git rev-parse] there fails by
   design. DUNE_SOURCEROOT points back at the checkout and is what the commands are aimed
   at; PROTEMU_SOURCE_REVISION overrides the answer outright, for a build that knows its
   own provenance better than git does.

   All of it is best effort. A run outside a checkout, or without git, records
   [unavailable] rather than inventing a revision: a reproduction record that guessed
   would be worse than one that admits the gap. *)
module Source_identity = struct
  type t =
    { revision : string
    ; local_diff : string
    ; ocaml_version : string
    }
  [@@deriving sexp_of, compare, equal]

  let unavailable = "unavailable"

  (* One short command, read to end of output. Anything at all going wrong - no git, not a
     checkout, a non-zero exit - reports [unavailable]; a reproduction record must never
     be the reason a test run dies. *)
  let read_command command =
    try
      let channel = Posix.open_process_in command in
      let output = In_channel.input_lines channel in
      match Posix.close_process_in channel with
      | Posix.WEXITED 0 -> Some output
      | _ -> None
    with
    | _ -> None
  ;;

  let git arguments =
    let directory =
      match Sys.getenv "DUNE_SOURCEROOT" with
      | None -> ""
      | Some root -> [%string "-C %{Filename.quote root} "]
    in
    read_command [%string "git %{directory}%{arguments} 2>/dev/null"]
  ;;

  let current () =
    let revision =
      match Sys.getenv "PROTEMU_SOURCE_REVISION" with
      | Some revision -> revision
      | None ->
        (match git "rev-parse HEAD" with
         | Some (revision :: _) -> revision
         | _ -> unavailable)
    in
    let local_diff =
      match git "status --porcelain" with
      | None -> unavailable
      | Some [] -> "clean"
      | Some changes ->
        let modified = List.length changes in
        [%string "%{modified#Int} modified paths"]
    in
    { revision; local_diff; ocaml_version = Sys.ocaml_version }
  ;;

  let to_lines t =
    [ [%string "  source revision:  %{t.revision}"]
    ; [%string "  working tree:     %{t.local_diff}"]
    ; [%string "  ocaml:            %{t.ocaml_version}"]
    ]
  ;;

  (* What an expect test prints instead. The fixture is asserting that the record is
     produced and reproduces, not which commit produced it. *)
  let redacted_lines = [ "  source identity:  <recorded; redacted in expect output>" ]
end

type t =
  { test : string
  ; source_file : string
  ; settings : Settings.t
  ; (* The failing trial's index within the run, which is its identity: the scenario is a
       function of the seed, the trial index and that trial's size. *)
    trial : int option
  ; config : Sexp.t
  ; source : Source_identity.t
  ; rerun : string
  }
[@@deriving sexp_of]

(* [dune runtest] rather than the inline test runner directly: dune's runner needs flags
   and a working directory it sets up itself, so a command naming the executable would be
   one that does not work. The recorded settings ride in front of it as overrides, and
   [--force] is what makes dune rerun a test it already believes passed. The directory is
   the one the failing test's source lives in, so the rerun is the smallest one that
   includes it. *)
let rerun_command ~source_file ~(settings : Settings.t) =
  let directory = Filename.dirname source_file in
  String.concat
    [ [%string "PROTEMU_SEED=%{settings.seed#Int} "]
    ; [%string "PROTEMU_TRIALS=%{settings.trials#Int} "]
    ; [%string "PROTEMU_SIZE=%{settings.size#Int} "]
    ; [%string "dune runtest %{directory} --force"]
    ]
;;

let create ~test ~source_file ~settings ~trial ~config =
  { test
  ; source_file
  ; settings
  ; trial
  ; config
  ; source = Source_identity.current ()
  ; rerun = rerun_command ~source_file ~settings
  }
;;

let to_lines ?(redact_source = false) t =
  let trial =
    match t.trial with
    | None -> "none"
    | Some trial -> Int.to_string trial
  in
  List.concat
    [ [ [%string "  test:             %{t.test}"]
      ; [%string "  test file:        %{t.source_file}"]
      ; [%string "  seed:             %{t.settings.seed#Int}"]
      ; [%string "  trials:           %{t.settings.trials#Int}"]
      ; [%string "  max size:         %{t.settings.size#Int}"]
      ; [%string "  failing trial:    %{trial}"]
      ; [%string "  configuration:    %{t.config#Sexp}"]
      ]
    ; (if redact_source
       then Source_identity.redacted_lines
       else Source_identity.to_lines t.source)
    ; [ [%string "  rerun:            %{t.rerun}"] ]
    ]
;;

(* Where a failure writes its report. Documented here and printed with every artifact, so
   a reader never has to guess; concurrent trials are kept apart by the trial index and
   the process id in the file name. *)
module Artifacts = struct
  let directory () =
    Option.value (Sys.getenv "PROTEMU_ARTIFACTS") ~default:"protemu-artifacts"
  ;;

  let write_to ~directory ~test ~(settings : Settings.t) ~trial ~contents =
    let pid = Posix.getpid () in
    let seed = settings.seed in
    let path =
      Filename.concat
        directory
        [%string "%{test}-seed%{seed#Int}-trial%{trial#Int}-pid%{pid#Int}.txt"]
    in
    try
      if not (Stdlib.Sys.file_exists directory) then Posix.mkdir directory 0o755;
      Out_channel.write_all path ~data:contents;
      Some path
    with
    | _ -> None
  ;;

  let write ~test ~settings ~trial ~contents =
    write_to ~directory:(directory ()) ~test ~settings ~trial ~contents
  ;;
end
