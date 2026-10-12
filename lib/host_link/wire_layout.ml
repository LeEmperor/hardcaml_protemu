(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "wire_layout.ml" *)
(* Elaboration-time checks that the host-link hardware's fixed byte layouts follow [Wire].

   The hardware builds and parses frames from literal byte lists and fixed byte counts,
   not from [Wire]'s offsets, so each block checks at elaboration that the layout it
   assumes still tiles [Wire]'s. Each block owns the checks for the layouts it alone
   relies on; this module holds the tiling check itself and the one layout two blocks
   share. Plain OCaml: a failed check raises at circuit construction and nothing here
   creates logic.
*)

open! Core
module Wire = Protemu_host_link_wire.Wire

(* Byte fields, as (offset, width), in the order [owner] uses them. They must tile the
   layout exactly: each field starts where the previous one ended, and the last ends at
   [length].
*)
let check ~owner name ~length fields =
  let next =
    List.fold fields ~init:0 ~f:(fun expected (offset, width) ->
      if offset <> expected
      then invalid_argf "%s: %s field at %d, expected %d" owner name offset expected ();
      offset + width)
  in
  if next <> length
  then invalid_argf "%s: %s layout is %d bytes, expected %d" owner name next length ()
;;

(* The request payload is two little-endian u16 fields filling [max_payload_length].
   [Frame_rx] stores the payload bytes positionally and [Command_dispatch] selects each
   field at [Wire]'s offset, so both rely on it.
*)
let check_request_payload ~owner =
  check
    ~owner
    "request payload"
    ~length:Wire.Request.max_payload_length
    Wire.Request.Payload_offset.[ address, 2; word, 2 ]
;;
