(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "program_store.ml" *)
(* A contract model of the single-port program store.

   This is not an implementation of hardcaml_asic's [Single_port_ram]; it is the normative
   behaviour its consumers are allowed to rely on, written so that the emulator's model
   can be tested before, and independently of, adopting that library. Backend conformance
   stays in hardcaml_asic (construction-plan.md section 1, decoupling).

   The contract, from construction-plan.md section 4:

   - One shared address, one enable, one write enable. An enabled operation is a read or a
     write, never both, and there is no second read port and no byte enable.
   - Read latency is one: data driven into the port at edge k is readable at edge k+1.
   - While disabled the output holds its previous value.
   - After a write, and for a word never written, the output is unspecified.
   - There is no initialisation and no reset of contents.
   - Out-of-range accesses are outside the contract.

   [Word.Unspecified] is how this model says "unspecified". It is a modelling marker, not
   a poison value a backend must produce: formatting_guide.md section 10.1 forbids
   requiring physical memory to match simulation poison. Tests compare contract-defined
   values across backends and check held outputs within one backend. Because it is a
   distinct constructor rather than an integer, no test can accidentally accept it as
   data.

   Out-of-range accesses raise rather than returning [Unspecified]. The contract does not
   define them, so the consumer is at fault, and a raise stops a test from quietly
   building on behaviour no backend promises.
*)

open! Core

module Word = struct
  type t =
    | Specified of int
    | Unspecified
  [@@deriving sexp, compare, equal]

  let to_int_exn = function
    | Specified value -> value
    | Unspecified ->
      raise_s [%message "an unspecified program-store output was used as data"]
  ;;
end

module Port = struct
  (* What the consumer drives into the store at one edge. *)
  type t =
    { enable : bool
    ; write_enable : bool
    ; address : int
    ; write_data : int
    }
  [@@deriving sexp, compare, equal]

  let idle = { enable = false; write_enable = false; address = 0; write_data = 0 }
  let read ~address = { idle with enable = true; address }

  let write ~address ~data =
    { enable = true; write_enable = true; address; write_data = data }
  ;;
end

type t =
  { depth : int
  ; width : int
  ; (* Absent means never written. *)
    words : int Map.M(Int).t
  ; (* The registered output port. *)
    read_data : Word.t
  }
[@@deriving sexp, compare, equal]

let create ~depth ~width =
  if depth < 1
  then raise_s [%message "program store depth must be positive" (depth : int)];
  { depth; width; words = Map.empty (module Int); read_data = Word.Unspecified }
;;

let read_data t = t.read_data
let word t ~address = Map.find t.words address

let check_address t ~address =
  if address < 0 || address >= t.depth
  then
    raise_s
      [%message
        "program-store access outside the contract" (address : int) ~depth:(t.depth : int)]
;;

let check_data t ~data =
  if data < 0 || data >= 1 lsl t.width
  then
    raise_s
      [%message
        "program-store write wider than the word" (data : int) ~width:(t.width : int)]
;;

(* One rising edge. Contents survive reset, so there is no reset function: the machine
   rebuilds its own state and keeps this store as it was. *)
let step t (port : Port.t) =
  if not port.enable
  then (* Disabled: the output holds. *) t
  else (
    check_address t ~address:port.address;
    if port.write_enable
    then (
      check_data t ~data:port.write_data;
      { t with
        words = Map.set t.words ~key:port.address ~data:port.write_data
      ; read_data = Word.Unspecified
      })
    else
      { t with
        read_data =
          (match Map.find t.words port.address with
           | Some value -> Word.Specified value
           | None -> Word.Unspecified)
      })
;;
