(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "invalid.ml" *)
(* Why a program could not be assembled.

   Everything here is decided before the first edge: a value out of range, a label that is
   not there, a branch that cannot reach, an image that does not fit the store. None of it
   is a run-time fault. A word that is not an instruction is [Encoding.Word_error.t] and
   arrives during a fetch; an operation the machine refuses is [Fault.Reject.t] in the
   model and arrives at acceptance. Three separate types because they are answerable at
   three separate times, and a reader of one of them should not have to wonder which.
*)

open! Core

type t =
  | (* A program with no instructions in it. *)
    Empty
  | Duplicate_label of string
  | Undefined_label of string
  | Register_out_of_range of int
  | Pin_out_of_range of int
  | Immediate_out_of_range of
      { what : string
      ; value : int
      }
  | (* The target is reachable in the program but not from this instruction's displacement
       field. The assembler refuses it rather than rewriting it as a jump island: a branch
       that silently became two instructions would make the program's measured size a
       function of something the author cannot see. *)
    Displacement_out_of_range of
      { target : string
      ; displacement : int
      ; bits : int
      }
  | (* The last instruction is one execution can fall off the end of. The word after the
       image was never written, so fetching it faults (P1.1); the assembler says so while
       the author can still do something about it. *)
    Runs_off_the_end of { last : string }
  | (* The assembled image needs more memory words than the store has. *)
    Program_too_large of
      { words : int
      ; depth : int
      }
[@@deriving sexp, compare, equal]
