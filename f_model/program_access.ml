(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "program_access.ml" *)
(* Independent model of the P3.1a load, readback, and fetch consumer.

   This model predicts acceptance and response ownership from external requests. It does
   not consume DUT ready/valid outputs and has no Hardcaml dependency. Program_store is
   stepped separately by the caller so tests can vary every output the RAM contract leaves
   unspecified without changing this control model.
*)

open! Core

let depth = 256
let width = 16

module Input = struct
  type t =
    { reset : bool
    ; enable : bool
    ; engines_idle : bool
    ; load_start : int option
    ; load_write : (int * int) option
    ; load_complete : bool
    ; readback : (int * bool * int) option
    ; run : bool
    ; execution_halt : bool
    ; fetch : int option
    }
  [@@deriving sexp_of, compare, equal]

  let idle =
    { reset = false
    ; enable = true
    ; engines_idle = true
    ; load_start = None
    ; load_write = None
    ; load_complete = false
    ; readback = None
    ; run = false
    ; execution_halt = false
    ; fetch = None
    }
  ;;
end

module Decisions = struct
  type t =
    { port : Program_store.Port.t
    ; load_start_accepted : bool
    ; load_write_accepted : bool
    ; load_complete_accepted : bool
    ; readback_accepted : bool
    ; run_accepted : bool
    ; fetch_accepted : bool
    }
  [@@deriving sexp_of, compare, equal]
end

module Response = struct
  type t =
    { readback : (int * bool) option
    ; fetch : int option
    }
  [@@deriving sexp_of, compare, equal]

  let none = { readback = None; fetch = None }
end

type t =
  { running : bool
  ; image_valid : bool
  ; load_active : bool
  ; image_length : int
  ; words_written : int
  ; words_verified : int
  ; verification_failed : bool
  ; host_read_pending : (bool * int) option
  ; fetch_pending : bool
  ; fetch_fault : bool
  ; response : Response.t
  }
[@@deriving sexp_of, compare, equal]

let create =
  { running = false
  ; image_valid = false
  ; load_active = false
  ; image_length = 0
  ; words_written = 0
  ; words_verified = 0
  ; verification_failed = false
  ; host_read_pending = None
  ; fetch_pending = false
  ; fetch_fault = false
  ; response = Response.none
  }
;;

let halted t = not t.running

(* Combinational decisions and port drive from pre-edge state. Request classes use the
   documented host priority even when a higher-priority offer is malformed. *)
let decisions t (input : Input.t) =
  let host_allowed = input.enable && halted t && input.engines_idle && not input.reset in
  let no_start = Option.is_none input.load_start in
  let no_write = no_start && Option.is_none input.load_write in
  let no_read = no_write && Option.is_none input.readback in
  let no_complete = no_read && not input.load_complete in
  let load_start_accepted =
    host_allowed
    && Option.exists input.load_start ~f:(fun length -> length > 0 && length <= depth)
  in
  let load_write_accepted =
    host_allowed
    && no_start
    && Option.exists input.load_write ~f:(fun (address, _) ->
      t.load_active && address = t.words_written && address < t.image_length)
  in
  let readback_accepted =
    host_allowed
    && no_write
    && Option.is_none t.host_read_pending
    && Option.exists input.readback ~f:(fun (address, verify, _) ->
      if verify
      then
        t.load_active
        && t.words_written = t.image_length
        && (not t.verification_failed)
        && address = t.words_verified
        && address < t.image_length
      else (
        let limit = if t.load_active then t.words_written else t.image_length in
        (t.load_active || t.image_valid) && address >= 0 && address < limit))
  in
  let load_complete_accepted =
    host_allowed
    && no_read
    && input.load_complete
    && t.load_active
    && t.words_written = t.image_length
    && t.words_verified = t.image_length
    && (not t.verification_failed)
    && Option.is_none t.host_read_pending
  in
  let run_accepted =
    host_allowed
    && no_complete
    && input.run
    && t.image_valid
    && Option.is_none t.host_read_pending
  in
  let fetch_accepted =
    let completion = input.enable && t.fetch_pending && not input.reset in
    input.enable
    && t.running
    && (not input.reset)
    && (not input.execution_halt)
    && ((not t.fetch_pending) || completion)
    && Option.exists input.fetch ~f:(fun address ->
      address >= 0 && address < depth && address < t.image_length)
  in
  let port =
    if load_write_accepted
    then (
      let address, data = Option.value_exn input.load_write in
      Program_store.Port.write ~address ~data)
    else if readback_accepted
    then (
      let address, _, _ = Option.value_exn input.readback in
      Program_store.Port.read ~address)
    else if fetch_accepted
    then Program_store.Port.read ~address:(Option.value_exn input.fetch)
    else Program_store.Port.idle
  in
  { Decisions.port
  ; load_start_accepted
  ; load_write_accepted
  ; load_complete_accepted
  ; readback_accepted
  ; run_accepted
  ; fetch_accepted
  }
;;

(* Advance one edge using only the independently predicted decisions and the memory value
   presented for a read issued on the preceding edge. *)
let step t input ~read_data =
  if input.Input.reset
  then create
  else if not input.enable
  then
    { t with
      running = false
    ; load_active = false
    ; host_read_pending = None
    ; fetch_pending = false
    ; response = Response.none
    }
  else (
    let d = decisions t input in
    let invalid_fetch =
      let completion = input.enable && t.fetch_pending && not input.reset in
      input.enable
      && t.running
      && ((not t.fetch_pending) || completion)
      && Option.exists input.fetch ~f:(fun address ->
        address < 0 || address >= depth || address >= t.image_length)
    in
    let cancel_host_response = d.load_start_accepted in
    let response, words_verified, verification_failed =
      match t.host_read_pending with
      | Some (verify, expected) when not cancel_host_response ->
        let matches = Int.equal read_data expected in
        ( { Response.none with readback = Some (read_data, verify && matches) }
        , (if verify && matches then t.words_verified + 1 else t.words_verified)
        , t.verification_failed || (verify && not matches) )
      | Some _ | None -> Response.none, t.words_verified, t.verification_failed
    in
    let response =
      if t.fetch_pending && not input.execution_halt
      then { response with Response.fetch = Some read_data }
      else response
    in
    let t =
      { t with
        words_verified
      ; verification_failed
      ; host_read_pending = None
      ; fetch_pending = false
      ; response
      }
    in
    let t =
      if input.execution_halt
      then
        { t with
          running = false
        ; fetch_pending = false
        ; response = { t.response with fetch = None }
        }
      else t
    in
    let t =
      if d.load_start_accepted
      then
        { t with
          image_valid = false
        ; load_active = true
        ; image_length = Option.value_exn input.load_start
        ; words_written = 0
        ; words_verified = 0
        ; verification_failed = false
        ; host_read_pending = None
        ; response = Response.none
        ; fetch_fault = false
        }
      else t
    in
    let t =
      if d.load_write_accepted then { t with words_written = t.words_written + 1 } else t
    in
    let t =
      if d.readback_accepted
      then (
        let _, verify, expected = Option.value_exn input.readback in
        { t with host_read_pending = Some (verify, expected) })
      else t
    in
    let t =
      if d.load_complete_accepted
      then { t with load_active = false; image_valid = true }
      else t
    in
    let t =
      if d.run_accepted then { t with running = true; fetch_fault = false } else t
    in
    let t =
      if invalid_fetch
      then
        { t with
          running = false
        ; fetch_pending = false
        ; fetch_fault = true
        ; response = { t.response with fetch = None }
        }
      else t
    in
    if d.fetch_accepted then { t with fetch_pending = true } else t)
;;
