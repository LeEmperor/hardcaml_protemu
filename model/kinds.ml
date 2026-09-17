(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "kinds.ml" *)
(* The small direction-neutral enumerations shared across the reference model.

   These name mechanisms, not protocols: a descriptor says which generated edge launches a
   bit and which one samples, never "SPI mode 0". Protocol names belong in the firmware
   helpers (P1.3) and in tests, as construction-plan.md section 3 requires.

   They live in one module because each is a handful of constructors used by several
   others; splitting them into single-type files would say nothing extra.
*)

open! Core

module Edge = struct
  (* Which transition of an observed input a wait or an external pacing source reacts to. *)
  type t =
    | Rising
    | Falling
    | Either
  [@@deriving sexp, compare, equal, enumerate]
end

module Owner = struct
  (* Who holds a protocol pin's drive rights. [Software] is the control core executing
     firmware pin writes. Engines are numbered so that a justified second lane (P5.2) can
     claim pins without changing this type or the ownership rules.

     Inputs are not owned: construction-plan.md section 3 allows several consumers to
     observe the same input, and only drive rights are exclusive. *)
  type t =
    | Software
    | Engine of int
  [@@deriving sexp, compare, equal]
end

module Pin_role = struct
  (* How a descriptor uses a pin. Carried in rejection reasons so a conflict says which
     two roles collided rather than only which pin number was duplicated. *)
  type t =
    | Output
    | Input
    | Clock
    | Paced_edge
  [@@deriving sexp, compare, equal, enumerate]
end

module Bit_order = struct
  type t =
    | Lsb_first
    | Msb_first
  [@@deriving sexp, compare, equal, enumerate]
end

module Direction = struct
  (* A transfer may shift out, shift in, or both. [Duplex] is one shared bit schedule, not
     two independently timed channels; see construction-plan.md section 3. *)
  type t =
    | Tx_only
    | Rx_only
    | Duplex
  [@@deriving sexp, compare, equal, enumerate]
end

module Blocking = struct
  (* Whether an operation that cannot complete now stalls the control core or is refused
     immediately. Fixed here, before opcode encoding, as construction-plan.md section 4
     requires of the data family. *)
  type t =
    | Blocking
    | Nonblocking
  [@@deriving sexp, compare, equal, enumerate]
end

module Clock_phase = struct
  (* An edge of the transfer's own bit clock. A descriptor names the launch phase and the
     sample phase separately; they must differ. *)
  type t =
    | On_rising
    | On_falling
  [@@deriving sexp, compare, equal, enumerate]
end

module Fifo_id = struct
  type t =
    | Tx
    | Rx
  [@@deriving sexp, compare, equal, enumerate]
end
