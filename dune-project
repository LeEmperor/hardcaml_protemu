(lang dune 3.17)

(name hardcaml_protemu)

(generate_opam_files true)

(source
 (github LeEmperor/hardcaml_protemu))

(authors "Bohdan Purtell <bohdanpurtell@gmail.com>")

(maintainers "Bohdan Purtell <bohdanpurtell@gmail.com>")

(package
 (name hardcaml_protemu)
 (synopsis "Protocol emulator ASIC written in Hardcaml")
 (description
  "Synthesizable protocol emulator blocks written in Hardcaml. Installs as one wrapped\nlibrary named hardcaml_protemu.")
 (depends
  (ocaml
   (>= 5.1))
  (dune
   (>= 3.17))
  ; The installed library surface (lib/). Everything below is test or repo tooling
  ; and must not be forced on a consumer.
  core
  hardcaml
  hardcaml_circuits
  ppx_hardcaml
  ppx_jane
  ; Test frameworks: test/ only.
  (hardcaml_step_testbench :with-test)
  (hardcaml_waveterm :with-test)
  (ppx_expect :with-test)
  (base_quickcheck :with-test)
  (alcotest :with-test)
  ; Repo tooling: bin/generate.exe. Never installed, but needed for a root
  ; `dune build`, so they ride with-test rather than being dropped.
  (core_unix :with-test)
  (jane_rope :with-test)
  (ppx_js_style :with-dev-setup)
  (ocamlformat :with-dev-setup)
  (ocaml-lsp-server :with-dev-setup)))
