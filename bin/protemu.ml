open! Core

(* The repository's command front door: [dune exec protemu -- <command>].

   Stateful work (provisioning, staging, hardening, precheck) stays in the scripts under
   scripts/ and tinytapeout/scripts/, which own their options and exit codes; commands
   here exec them so those codes reach the caller unchanged. Pure checks are dune rules
   rather than commands: see tinytapeout/src/dune and tinytapeout/test/dune. *)

let lock_file = "tinytapeout/toolchain.lock"

(* [dune exec] exports DUNE_SOURCEROOT. Running the built executable directly falls back
   to its location, _build/default/bin/protemu.exe. *)
let repo_root =
  lazy
    (let from_env = Sys.getenv "DUNE_SOURCEROOT" in
     let from_exe =
       Filename_unix.realpath Sys_unix.executable_name
       |> Fn.apply_n_times ~n:4 Filename.dirname
     in
     let is_root dir = Sys_unix.file_exists_exn (dir ^/ lock_file) in
     match List.find (List.filter_opt [ from_env; Some from_exe ]) ~f:is_root with
     | Some root -> root
     | None ->
       eprintf "error: cannot find the repository root (no %s)\n" lock_file;
       exit 2)
;;

let script path = force repo_root ^/ path

let exec path args =
  let prog = script path in
  never_returns (Core_unix.exec ~prog ~argv:(prog :: args) ())
;;

(* Runs to completion, for commands that report on several scripts. *)
let run path args =
  let prog = script path in
  let pid = Core_unix.fork_exec ~prog ~argv:(prog :: args) () in
  Result.is_ok (Core_unix.waitpid pid)
;;

let flag_arg name = function
  | true -> [ "--" ^ name ]
  | false -> []
;;

let bootstrap_toolchain = "tinytapeout/scripts/bootstrap-toolchain.sh"
let ocaml_deps = "scripts/ocaml-deps.sh"

(* The canonical ASIC flow. Every command here that implements or hardens goes through
   this one script, so there is a single implementation path and a single set of exit
   codes. See docs/flow.md. *)
let flow_script = "flow.sh"

let bootstrap =
  Command.basic
    ~summary:"Converge the OCaml and flow environments on the lockfile"
    ~readme:(fun () ->
      "Checks the opam switch and dependencies, then creates or updates .venv, \
       .venv-precheck, the PDK, the support-tools checkout and the pinned LibreLane \
       image. Rerun after a pull that changes toolchain.lock or the opam file. This \
       command only reports on the opam switch; ./bootstrap.sh is what installs into it. \
       It prepares an environment and stages no design: the legacy project is \
       -legacy-project, and implementation is ./flow.sh.")
    (let%map_open.Command offline =
       flag "offline" no_arg ~doc:" reuse the environment; fetch and install nothing"
     and check = flag "check" no_arg ~doc:" validate and change nothing"
     and no_container =
       flag "no-container" no_arg ~doc:" skip the Docker/Podman prerequisite"
     and legacy_project =
       flag
         "legacy-project"
         no_arg
         ~doc:
           " also stage and configure the legacy P0 project (./flow.sh does not use it)"
     (* ./bootstrap.sh checks the OCaml layer before it can run dune at all. Without this,
        that check runs a second time here: same opam calls, same output, one invocation.
        Each layer is checked exactly once per bootstrap. *)
     and skip_ocaml_check =
       flag
         "skip-ocaml-check"
         no_arg
         ~doc:" the caller already checked the OCaml layer (./bootstrap.sh does)"
     in
     fun () ->
       if (not skip_ocaml_check) && not (run ocaml_deps []) then exit 2;
       exec
         bootstrap_toolchain
         (flag_arg "offline" offline
          @ flag_arg "check" check
          @ flag_arg "no-container" no_container
          @ flag_arg "legacy-project" legacy_project))
;;

(* Activation is optional for the scripts but is what a new terminal lacks, so it is
   reported rather than failed. *)
let report_shell () =
  let root = force repo_root in
  printf "\n==> This shell\n";
  let expect ~var ~want =
    let status =
      match Sys.getenv var with
      | None -> "not set; source env.sh"
      | Some have when String.equal have want -> "ok"
      | Some have -> sprintf "%s belongs to another checkout; source env.sh here" have
    in
    printf "    %-12s %s\n" var status
  in
  expect ~var:"PDK_ROOT" ~want:(root ^/ "tinytapeout/pdk");
  expect ~var:"VIRTUAL_ENV" ~want:(root ^/ ".venv")
;;

let doctor =
  Command.basic
    ~summary:"Report the state of every environment layer; change nothing"
    (let%map_open.Command no_container =
       flag "no-container" no_arg ~doc:" skip the Docker/Podman prerequisite"
     in
     fun () ->
       let ocaml_ok = run ocaml_deps [] in
       let flow_ok =
         run bootstrap_toolchain ("--check" :: flag_arg "no-container" no_container)
       in
       report_shell ();
       let verdict ok = if ok then "ok" else "needs ./bootstrap.sh" in
       printf "\n==> Summary\n";
       printf "    %-12s %s\n" "OCaml" (verdict ocaml_ok);
       printf "    %-12s %s\n" "flow" (verdict flow_ok);
       if not (ocaml_ok && flow_ok) then exit 2)
;;

let flow =
  Command.basic
    ~summary:"Run the adopted ASIC flow (an alias for ./flow.sh)"
    ~readme:(fun () ->
      "Passes the named steps to ./flow.sh and returns its exit status unchanged. With \
       no step it runs the whole flow, hardening included, which takes hours.\n\n\
       ./flow.sh --help is the help for the steps and the PROTEMU_* overrides; this \
       alias cannot show it, because -help is read by this command line first. ./flow.sh \
       is the canonical spelling and the one the documentation uses: the alias exists so \
       a `protemu` habit still reaches the same runner, and it needs neither dune nor an \
       activated switch.")
    (let%map_open.Command steps = anon (sequence ("STEP" %: string)) in
     fun () -> exec flow_script steps)
;;

(* The adopted path and the legacy path both harden, but from different inputs, so one
   name cannot mean both. [harden] is the adopted physical run; the staged-project one
   keeps its script and an explicitly legacy name. *)
let harden =
  Command.basic
    ~summary:"Harden the emitted bundle: an alias for ./flow.sh run"
    ~readme:(fun () ->
      "Runs the adopted flow's physical step on the bundle in $PROTEMU_FLOW_OUT: mapped \
       CMOS5L synthesis and place-and-route, into a new run directory. It does not emit \
       the bundle first, so `./flow.sh build emit preflight` (or the whole `./flow.sh`) \
       comes before it.\n\n\
       This used to harden the legacy staged project, which is a different input. That \
       command is now `legacy-harden`, and its -tag and -no-docker flags belong to it: \
       they are rejected here rather than reinterpreted.")
    (let%map_open.Command no_docker =
       flag "no-docker" no_arg ~doc:" (legacy only) use a native LibreLane"
     and tag =
       flag
         "tag"
         (optional string)
         ~doc:"NAME (legacy only) label for the archived previous run"
     in
     fun () ->
       (* Translating these would be a guess. The adopted runner is dockerized with the
          pinned image, and it never archives a previous run to make room for this one:
          each attempt already gets its own directory under $PROTEMU_RUNS. *)
       let reject flag ~spelling reason =
         eprintf "error: %s is a legacy-harden flag\n" flag;
         eprintf "       %s\n" reason;
         eprintf "       Use: dune exec protemu -- legacy-harden %s\n" spelling;
         exit 2
       in
       if no_docker
       then
         reject
           "-no-docker"
           ~spelling:"-no-docker"
           "the adopted run uses the pinned LibreLane image from toolchain.lock.";
       Option.iter tag ~f:(fun tag ->
         reject
           "-tag"
           ~spelling:(sprintf "-tag %s" tag)
           "the adopted run gives every attempt its own directory; none is archived.");
       exec flow_script [ "run" ])
;;

let legacy_harden =
  Command.basic
    ~summary:"Legacy: harden the staged project (tinytapeout/build/p0-staged)"
    ~readme:(fun () ->
      "The pre-adoption physical path: it hardens the staged legacy P0 project built \
       from the committed RTL and the hand-maintained info.yaml and src/config.json, not \
       an emitted bundle. It needs `./bootstrap.sh --legacy-project` to have staged that \
       project. Kept until the adopted route is validated; new work belongs in \
       ./flow.sh.")
    (let%map_open.Command no_docker =
       flag "no-docker" no_arg ~doc:" use a native LibreLane"
     and tag =
       flag "tag" (optional string) ~doc:"NAME label for the archived previous run"
     in
     fun () ->
       exec
         "tinytapeout/scripts/harden-cmos5l.sh"
         (flag_arg "no-docker" no_docker
          @ Option.value_map tag ~default:[] ~f:(fun tag -> [ "--tag"; tag ])))
;;

let check =
  Command.basic
    ~summary:"RTL regression on the committed RTL: build, tests, lint, staging"
    ~readme:(fun () ->
      "Legacy inputs: the committed tinytapeout/src RTL and the hand-maintained \
       info.yaml and src/config.json. It runs dune build, the Hardcaml tests, the \
       wrapper simulation, Verilator lint and generic Yosys synthesis, then stages the \
       legacy project. The adopted bundle is checked instead by \
       tinytapeout/scripts/check-adopted-bundle.py, and built by ./flow.sh build emit.")
    (Command.Param.return (fun () -> exec "tinytapeout/scripts/check-p0.sh" []))
;;

let stage =
  Command.basic
    ~summary:"Legacy: regenerate RTL and stage the Tiny Tapeout project"
    ~readme:(fun () ->
      "Writes tinytapeout/build/p0-staged from the committed RTL and the hand-maintained \
       metadata and configuration, for legacy-harden and precheck. The adopted flow \
       reads none of it: ./flow.sh emit renders its inputs from the declaration in \
       bin/asic_bundle.ml.")
    (Command.Param.return (fun () -> exec "tinytapeout/scripts/stage-project.sh" []))
;;

let precheck =
  Command.basic
    ~summary:"Legacy: Tiny Tapeout precheck on a legacy hardening run (needs Nix)"
    ~readme:(fun () ->
      "Reads the run left by legacy-harden under tinytapeout/runs. The adopted flow runs \
       the same upstream precheck as part of ./flow.sh postcheck, against its own run \
       directory, and needs no separate command.")
    (Command.Param.return (fun () -> exec "tinytapeout/scripts/precheck.sh" []))
;;

let command =
  Command.group
    ~summary:"Environment and ASIC flow commands for hardcaml_protemu"
    ~readme:(fun () ->
      "First time on a machine or clone: ./bootstrap.sh\n\
       Each new shell: source env.sh\n\
       The ASIC flow: ./flow.sh (./flow.sh --help)\n\
       See docs/environment.md for the environment, docs/flow.md for the flow.")
    [ "bootstrap", bootstrap
    ; "doctor", doctor
    ; "flow", flow
    ; "harden", harden
    ; "check", check
    ; "stage", stage
    ; "precheck", precheck
    ; "legacy-harden", legacy_harden
    ]
;;

let () = Command_unix.run command
