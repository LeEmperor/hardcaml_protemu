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
    ; working_tree : string
    ; local_patch : string
    ; ocaml_version : string
    ; dependencies : string list
    ; tools : string list
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

  let source_root () = Option.value (Sys.getenv "DUNE_SOURCEROOT") ~default:"."

  let git arguments =
    read_command
      [%string "git -C %{Filename.quote (source_root ())} %{arguments} 2>/dev/null"]
  ;;

  (* [git diff] returns one when it successfully found a difference. That is data here,
     not a command failure. This separate reader preserves the ordinary [git] helper's
     stricter zero-only behavior. *)
  let git_diff arguments =
    try
      let command =
        [%string "git -C %{Filename.quote (source_root ())} %{arguments} 2>/dev/null"]
      in
      let channel = Posix.open_process_in command in
      let output = In_channel.input_lines channel in
      match Posix.close_process_in channel with
      | Posix.WEXITED (0 | 1) -> Some output
      | _ -> None
    with
    | _ -> None
  ;;

  let local_patch () =
    match git_diff "diff --binary --no-ext-diff HEAD -- ." with
    | None -> unavailable
    | Some tracked ->
      let untracked =
        match git "ls-files --others --exclude-standard" with
        | None -> [ "# untracked files: unavailable" ]
        | Some paths ->
          List.concat_map paths ~f:(fun path ->
            match
              git_diff
                [%string "diff --binary --no-index /dev/null %{Filename.quote path}"]
            with
            | Some patch -> patch
            | None -> [ [%string "# could not capture untracked file: %{path}"] ])
      in
      String.concat ~sep:"\n" (tracked @ untracked)
  ;;

  let command_identity name command =
    match read_command [%string "%{command} 2>/dev/null"] with
    | Some (version :: _) -> [%string "%{name}: %{version}"]
    | Some [] | None -> [%string "%{name}: %{unavailable}"]
  ;;

  let dependencies () =
    let packages =
      String.concat
        ~sep:" "
        [ "ocaml"
        ; "dune"
        ; "core"
        ; "core_unix"
        ; "base_quickcheck"
        ; "splittable_random"
        ; "hardcaml"
        ; "hardcaml_asic"
        ; "hardcaml_event_driven_sim"
        ; "hardcaml_step_testbench"
        ; "ppx_expect"
        ; "ppx_hardcaml"
        ; "ppx_jane"
        ; "ppx_js_style"
        ; "ocamlformat"
        ]
    in
    match
      read_command
        [%string
          "opam list --installed --short --columns=name,version %{packages} 2>/dev/null"]
    with
    | Some versions -> if List.is_empty versions then [ unavailable ] else versions
    | None -> [ unavailable ]
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
    let working_tree =
      match git "status --porcelain" with
      | None -> unavailable
      | Some [] -> "clean"
      | Some changes ->
        let modified = List.length changes in
        [%string "%{modified#Int} modified paths"]
    in
    { revision
    ; working_tree
    ; local_patch = local_patch ()
    ; ocaml_version = Sys.ocaml_version
    ; dependencies = dependencies ()
    ; tools =
        [ command_identity "dune" "dune --version"
        ; command_identity "iverilog" "iverilog -V"
        ; command_identity "verilator" "verilator --version"
        ; command_identity "yosys" "yosys -V"
        ]
    }
  ;;

  let digest text = Md5.digest_string text |> Md5.to_hex

  let to_lines t =
    let patch_digest = digest t.local_patch in
    let patch_lines = String.count t.local_patch ~f:(Char.equal '\n') + 1 in
    let dependency_digest = digest (String.concat ~sep:"\n" t.dependencies) in
    let dependency_entries = List.length t.dependencies in
    [ [%string "  source revision:  %{t.revision}"]
    ; [%string "  working tree:     %{t.working_tree}"]
    ; [%string
        "  local patch:      %{patch_digest} (%{patch_lines#Int} lines; in artifact)"]
    ; [%string "  ocaml:            %{t.ocaml_version}"]
    ; [%string
        "  dependencies:     %{dependency_digest} (%{dependency_entries#Int} entries; in \
         artifact)"]
    ]
    @ List.map t.tools ~f:(fun tool -> [%string "  tool:             %{tool}"])
  ;;

  let artifact_appendix t =
    String.concat
      ~sep:"\n"
      ([ ""; "reproduction dependency manifest:" ]
       @ List.map t.dependencies ~f:(fun dependency -> "  " ^ dependency)
       @ [ ""; "reproduction tool manifest:" ]
       @ List.map t.tools ~f:(fun tool -> "  " ^ tool)
       @ [ ""
         ; "reproduction local patch (apply from the recorded source revision):"
         ; t.local_patch
         ; ""
         ])
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

let artifact_appendix t = Source_identity.artifact_appendix t.source

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
