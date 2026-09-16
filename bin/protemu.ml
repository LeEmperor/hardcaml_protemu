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

let bootstrap =
  Command.basic
    ~summary:"Converge the OCaml and flow environments on the lockfile"
    ~readme:(fun () ->
      "Checks the opam switch and dependencies, then creates or updates .venv, \
       .venv-precheck, the PDK and the support-tools checkout. Rerun after a pull that \
       changes toolchain.lock or the opam file. Installing into the opam switch itself \
       needs ./bootstrap.sh --install-deps.")
    (let%map_open.Command offline =
       flag "offline" no_arg ~doc:" reuse the environment; fetch and install nothing"
     and check = flag "check" no_arg ~doc:" validate and change nothing"
     and no_container =
       flag "no-container" no_arg ~doc:" skip the Docker/Podman prerequisite"
     in
     fun () ->
       if not (run ocaml_deps []) then exit 2;
       exec
         bootstrap_toolchain
         (flag_arg "offline" offline
          @ flag_arg "check" check
          @ flag_arg "no-container" no_container))
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

let check =
  Command.basic
    ~summary:"RTL regression: dune build, tests, RTL checks, staging"
    (Command.Param.return (fun () -> exec "tinytapeout/scripts/check-p0.sh" []))
;;

let stage =
  Command.basic
    ~summary:"Regenerate RTL and stage the Tiny Tapeout project"
    (Command.Param.return (fun () -> exec "tinytapeout/scripts/stage-project.sh" []))
;;

let harden =
  Command.basic
    ~summary:"Mapped CMOS5L synthesis and place-and-route, gated on timing"
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

let precheck =
  Command.basic
    ~summary:"Tiny Tapeout precheck on the current hardening run (needs Nix)"
    (Command.Param.return (fun () -> exec "tinytapeout/scripts/precheck.sh" []))
;;

let command =
  Command.group
    ~summary:"Environment and ASIC flow commands for hardcaml_protemu"
    ~readme:(fun () ->
      "First time on a machine or clone: ./bootstrap.sh\n\
       Each new shell: source env.sh\n\
       See docs/environment.md.")
    [ "bootstrap", bootstrap
    ; "doctor", doctor
    ; "check", check
    ; "stage", stage
    ; "harden", harden
    ; "precheck", precheck
    ]
;;

let () = Command_unix.run command
