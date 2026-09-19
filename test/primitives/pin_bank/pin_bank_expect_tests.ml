let directed_scenario =
  [ Item.reset
  ; Item.write ~engine:false ~mask:0x0f ~value:0x05 ~output_enable:0x0f ()
  ; Item.write ~engine:false ~mask:0xf0 ~value:0xa0 ~output_enable:0x50 ()
  ; Item.claim ~engine:true ~mask:0x20
  ; Item.write ~engine:false ~mask:0x30 ~value:0x30 ~output_enable:0x30 ()
  ; Item.release ~engine:false ~mask:0x01
  ; Item.also_write
      ~engine:false
      ~mask:0x01
      ~value:0x01
      ~output_enable:0x01
      (Item.claim ~engine:false ~mask:0x01)
  ; Item.write
      ~open_drain:true
      ~engine:false
      ~mask:0x03
      ~value:0x03
      ~output_enable:0x03
      ()
  ; Item.abort
  ]
;;

(* The settings the regression runs. They are written down rather than drawn from the
let%expect_test "a directed pin-bank scenario, edge by edge" =
  let (_ : Run.t) = directed Config.default ~scenario:directed_scenario in
  [%expect
    {|
    edge 0  item ((reset)(enable true))
      before  held.pins=0 held.pin_oe=0 held.software_claim=0 held.engine_claim=0 held.rejected=0
              held.conflict=0
      after   pins=0 pin_oe=0 software_claim=0 engine_claim=0 rejected=0 conflict=0
              reject_reason=- bus0=? bus1=? bus2=? bus3=? bus4=? bus5=? bus6=? bus7=?
    edge 1  item ((enable true)(write((engine false)(mask 15)(value 5)(output_enable 15)(open_drain false))))
      before  held.pins=0 held.pin_oe=0 held.software_claim=0 held.engine_claim=0 held.rejected=0
              held.conflict=0
      after   pins=5 pin_oe=15 software_claim=0 engine_claim=0 rejected=0 conflict=0
              reject_reason=- bus0=1 bus1=0 bus2=1 bus3=0 bus4=? bus5=? bus6=? bus7=?
      item    @1 pins/Outbound/Complete ((driven 15)(high 5))
    edge 2  item ((enable true)(write((engine false)(mask 240)(value 160)(output_enable 80)(open_drain false))))
      before  held.pins=5 held.pin_oe=15 held.software_claim=0 held.engine_claim=0 held.rejected=0
              held.conflict=0
      after   pins=165 pin_oe=95 software_claim=0 engine_claim=0 rejected=0 conflict=0
              reject_reason=- bus0=1 bus1=0 bus2=1 bus3=0 bus4=0 bus5=? bus6=0 bus7=?
      item    @2 pins/Outbound/Complete ((driven 95)(high 5))
    edge 3  item ((enable true)(claim((engine true)(mask 32))))
      before  held.pins=165 held.pin_oe=95 held.software_claim=0 held.engine_claim=0
              held.rejected=0 held.conflict=0
      after   pins=165 pin_oe=95 software_claim=0 engine_claim=32 rejected=0 conflict=0
              reject_reason=- bus0=1 bus1=0 bus2=1 bus3=0 bus4=0 bus5=? bus6=0 bus7=?
      item    @3 ownership.engine/Outbound/Start (mask 32)
    edge 4  item ((enable true)(write((engine false)(mask 48)(value 48)(output_enable 48)(open_drain false))))
      before  held.pins=165 held.pin_oe=95 held.software_claim=0 held.engine_claim=32
              held.rejected=0 held.conflict=0
      after   pins=165 pin_oe=95 software_claim=0 engine_claim=32 rejected=1 conflict=1
              reject_reason=- bus0=1 bus1=0 bus2=1 bus3=0 bus4=0 bus5=? bus6=0 bus7=?
      item    @4 ownership/Outbound/Complete conflict error=a request touched a pin another owner holds
    edge 5  item ((enable true)(release((engine false)(mask 1))))
      before  held.pins=165 held.pin_oe=95 held.software_claim=0 held.engine_claim=32
              held.rejected=1 held.conflict=1
      after   pins=165 pin_oe=95 software_claim=0 engine_claim=32 rejected=1 conflict=1
              reject_reason=- bus0=1 bus1=0 bus2=1 bus3=0 bus4=0 bus5=? bus6=0 bus7=?
    edge 6  item ((enable true)(claim((engine false)(mask 1)))(write((engine false)(mask 1)(value 1)(output_enable 1)(open_drain false))))
      before  held.pins=165 held.pin_oe=95 held.software_claim=0 held.engine_claim=32
              held.rejected=1 held.conflict=1
      after   pins=165 pin_oe=95 software_claim=0 engine_claim=32 rejected=1 conflict=1
              reject_reason=- bus0=1 bus1=0 bus2=1 bus3=0 bus4=0 bus5=? bus6=0 bus7=?
    edge 7  item ((enable true)(write((engine false)(mask 3)(value 3)(output_enable 3)(open_drain true))))
      before  held.pins=165 held.pin_oe=95 held.software_claim=0 held.engine_claim=32
              held.rejected=1 held.conflict=1
      after   pins=164 pin_oe=95 software_claim=0 engine_claim=32 rejected=0 conflict=1
              reject_reason=- bus0=0 bus1=0 bus2=1 bus3=0 bus4=0 bus5=? bus6=0 bus7=?
      item    @7 pins/Outbound/Complete ((driven 95)(high 4))
    edge 8  item ((abort)(enable true))
      before  held.pins=164 held.pin_oe=95 held.software_claim=0 held.engine_claim=32
              held.rejected=0 held.conflict=1
      after   pins=0 pin_oe=0 software_claim=0 engine_claim=0 rejected=0 conflict=1
              reject_reason=- bus0=? bus1=? bus2=? bus3=? bus4=? bus5=? bus6=? bus7=?
      item    @8 ownership.engine/Outbound/End (mask 0)
      item    @8 pins/Outbound/Complete ((driven 0)(high 0))
    model and design agreed on all 9 edges
    |}]
;;
open! Core
open! Pin_bank_testbench
