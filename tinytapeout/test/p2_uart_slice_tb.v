// University of Florida
// Author: Bohdan Purtell
// Module: "p2_uart_slice_tb.v"
//
// P2.7's first working slice at the emitted-RTL boundary.
//
// This testbench is the independent receiver the phase plan asks for, written a second
// time in a second language so that the OCaml monitor and this one cannot share a
// mistake. It is told the byte and the bit period it expects and nothing else about the
// design: it finds the start edge itself, checks every cycle of every bit slot, recovers
// the byte from the waveform, and measures the period the frame was drawn on.
//
// It then writes the frame out in the format test/integration/uart_slice/uart_frame.trace
// holds, and the dune rule beside this file diffs the two. That diff is the saved
// matching model and RTL trace: the committed file is written only when the reference
// machine, the reference transfer engine and the Hardcaml slice already agree on it.

`timescale 1ns/1ps

module p2_uart_slice_tb;
  localparam integer BYTE_VALUE = 8'ha6;
  localparam integer HALF_PERIOD = 4;
  localparam integer BIT_CYCLES = 2 * HALF_PERIOD;
  localparam integer FRAME_BITS = 10;
  localparam integer TX_PIN = 0;
  localparam integer SAMPLES = 200;
  // Part way into the data bits, with the line low, so a pin left driven after an
  // interruption shows up as a stuck start bit rather than as idle.
  localparam integer INTERRUPT_CYCLE = 30;

  reg clock_i = 0;
  reg reset_i = 1;
  reg enable_i = 1;
  reg abort_i = 0;
  reg start_i = 0;
  reg [7:0] byte_i = BYTE_VALUE[7:0];
  reg [15:0] half_period_i = HALF_PERIOD[15:0];
  reg [2:0] tx_pin_i = TX_PIN[2:0];
  wire ready_o;
  wire busy_o;
  wire frame_done_o;
  wire gap_busy_o;
  wire [7:0] pins_o;
  wire [7:0] pin_oe_o;
  wire [7:0] engine_claim_o;
  wire [7:0] software_claim_o;
  wire bank_rejected_o;
  wire bank_conflict_o;

  reg level [0:SAMPLES-1];
  reg driven [0:SAMPLES-1];
  reg other_pins_touched = 0;
  reg bank_clean = 1;
  reg saw_gap = 0;
  reg saw_claim = 0;
  reg saw_done = 0;

  integer cycle;
  integer slot;
  integer offset;
  integer start_edge;
  integer leading_idle;
  integer frame_end;
  integer measured_period;
  integer interval;
  integer previous_transition;
  integer received;
  integer trace;
  reg slot_level [0:FRAME_BITS-1];
  reg current;

  uart_slice dut (
    .clock_i(clock_i),
    .reset_i(reset_i),
    .enable_i(enable_i),
    .abort_i(abort_i),
    .start_i(start_i),
    .byte_i(byte_i),
    .half_period_i(half_period_i),
    .tx_pin_i(tx_pin_i),
    .ready_o(ready_o),
    .busy_o(busy_o),
    .frame_done_o(frame_done_o),
    .gap_busy_o(gap_busy_o),
    .pins_o(pins_o),
    .pin_oe_o(pin_oe_o),
    .engine_claim_o(engine_claim_o),
    .software_claim_o(software_claim_o),
    .bank_rejected_o(bank_rejected_o),
    .bank_conflict_o(bank_conflict_o)
  );

  always #5 clock_i = ~clock_i;

  // One clock edge, settled.
  task step;
    begin
      @(posedge clock_i);
      #1;
    end
  endtask

  // Greatest common divisor, for measuring the period the frame was drawn on.
  function integer gcd;
    input integer a;
    input integer b;
    integer x;
    integer y;
    integer t;
    begin
      x = a;
      y = b;
      while (y != 0) begin
        t = y;
        y = x % y;
        x = t;
      end
      gcd = x;
    end
  endfunction

  // Run one frame from reset and record what the selected pin did, cycle by cycle.
  task capture_frame;
    begin
      reset_i = 1;
      enable_i = 1;
      abort_i = 0;
      start_i = 0;
      step();
      reset_i = 0;
      start_i = 1;
      step();
      start_i = 0;
      for (cycle = 0; cycle < SAMPLES; cycle = cycle + 1) begin
        step();
        level[cycle] = pins_o[TX_PIN];
        driven[cycle] = pin_oe_o[TX_PIN];
        if (gap_busy_o) saw_gap = 1;
        if (engine_claim_o[TX_PIN]) saw_claim = 1;
        if (frame_done_o) saw_done = 1;
        if (bank_rejected_o || bank_conflict_o) bank_clean = 0;
        if (((pins_o | pin_oe_o) & ~(8'h01 << TX_PIN)) != 8'h00) other_pins_touched = 1;
      end
    end
  endtask

  // The receiver: start edge, leading idle, one constant level per bit slot, the byte,
  // the measured period, and the return to idle.
  task decode_frame;
    begin
      start_edge = -1;
      for (cycle = 1; cycle < SAMPLES; cycle = cycle + 1)
        if (start_edge < 0 && driven[cycle-1] && level[cycle-1] && driven[cycle] && !level[cycle])
          start_edge = cycle;
      if (start_edge < 0)
        $fatal(1, "no start edge: the line never fell from a driven idle");

      leading_idle = 0;
      cycle = start_edge - 1;
      while (cycle >= 0 && driven[cycle] && level[cycle]) begin
        leading_idle = leading_idle + 1;
        cycle = cycle - 1;
      end
      if (leading_idle < BIT_CYCLES)
        $fatal(1, "idle of %0d cycles before the start edge is shorter than one bit period of %0d",
               leading_idle, BIT_CYCLES);

      frame_end = start_edge + FRAME_BITS * BIT_CYCLES;
      if (frame_end + BIT_CYCLES > SAMPLES)
        $fatal(1, "trace ends at %0d, before the frame and its return to idle at %0d",
               SAMPLES, frame_end + BIT_CYCLES);

      for (slot = 0; slot < FRAME_BITS; slot = slot + 1) begin
        current = level[start_edge + slot * BIT_CYCLES];
        for (offset = 0; offset < BIT_CYCLES; offset = offset + 1) begin
          cycle = start_edge + slot * BIT_CYCLES + offset;
          if (!driven[cycle])
            $fatal(1, "pin released at cycle %0d, inside bit slot %0d", cycle, slot);
          if (level[cycle] !== current)
            $fatal(1, "level changed at cycle %0d, %0d cycles into bit slot %0d",
                   cycle, offset, slot);
        end
        slot_level[slot] = current;
      end

      if (slot_level[0] !== 1'b0) $fatal(1, "start bit is not low");
      if (slot_level[FRAME_BITS-1] !== 1'b1) $fatal(1, "stop bit is not high");

      received = 0;
      for (slot = 1; slot <= 8; slot = slot + 1)
        if (slot_level[slot]) received = received | (1 << (slot - 1));
      if (received !== BYTE_VALUE)
        $fatal(1, "received 0x%02h, expected 0x%02h", received[7:0], BYTE_VALUE[7:0]);

      // The largest period the frame's own transitions could have been drawn on.
      measured_period = FRAME_BITS * BIT_CYCLES;
      previous_transition = 0;
      for (slot = 1; slot < FRAME_BITS; slot = slot + 1)
        if (slot_level[slot] !== slot_level[slot-1]) begin
          interval = slot * BIT_CYCLES - previous_transition;
          measured_period = gcd(measured_period, interval);
          previous_transition = slot * BIT_CYCLES;
        end
      if (measured_period !== BIT_CYCLES)
        $fatal(1, "measured bit period %0d, expected %0d", measured_period, BIT_CYCLES);

      for (cycle = frame_end; cycle < frame_end + BIT_CYCLES; cycle = cycle + 1)
        if (!driven[cycle] || !level[cycle])
          $fatal(1, "the line did not return to a driven idle at cycle %0d", cycle);
    end
  endtask

  // The same text test/integration/uart_slice/uart_frame.trace holds.
  task write_trace;
    begin
      trace = $fopen("uart_slice_rtl.trace", "w");
      if (trace == 0) $fatal(1, "could not open the trace file");
      $fwrite(trace, "# protemu P2.7 first working slice -- UART 8N1 transmit frame\n");
      $fwrite(trace, "# byte=0x%02h half_period=%0d bit_cycles=%0d tx_pin=%0d\n",
              BYTE_VALUE[7:0], HALF_PERIOD, BIT_CYCLES, TX_PIN);
      $fwrite(trace, "# slot label level start end\n");
      for (slot = 0; slot < FRAME_BITS; slot = slot + 1) begin
        if (slot == 0)
          $fwrite(trace, "%0d start %0d %0d %0d\n", slot, slot_level[slot],
                  slot * BIT_CYCLES, (slot + 1) * BIT_CYCLES);
        else if (slot == FRAME_BITS - 1)
          $fwrite(trace, "%0d stop %0d %0d %0d\n", slot, slot_level[slot],
                  slot * BIT_CYCLES, (slot + 1) * BIT_CYCLES);
        else
          $fwrite(trace, "%0d d%0d %0d %0d %0d\n", slot, slot - 1, slot_level[slot],
                  slot * BIT_CYCLES, (slot + 1) * BIT_CYCLES);
      end
      $fclose(trace);
    end
  endtask

  // A frame interrupted part way through must release the pin and its ownership, not
  // finish quietly. [what] selects which of the three release conditions is applied.
  task check_release;
    input [1:0] what;
    integer released;
    begin
      released = -1;
      reset_i = 1;
      enable_i = 1;
      abort_i = 0;
      start_i = 0;
      step();
      reset_i = 0;
      start_i = 1;
      step();
      start_i = 0;
      for (cycle = 0; cycle < SAMPLES; cycle = cycle + 1) begin
        if (cycle == INTERRUPT_CYCLE) begin
          if (what == 2'd0) reset_i = 1;
          else if (what == 2'd1) enable_i = 0;
          else abort_i = 1;
        end
        step();
        if (cycle > INTERRUPT_CYCLE && released < 0 && pin_oe_o == 8'h00 && pins_o == 8'h00)
          released = cycle;
      end
      if (released < 0)
        $fatal(1, "an interrupted frame (%0d) left the transmit pin driven", what);
      if (released != INTERRUPT_CYCLE + 1)
        $fatal(1, "an interrupted frame (%0d) released at cycle %0d, not %0d",
               what, released, INTERRUPT_CYCLE + 1);
      if (engine_claim_o != 8'h00)
        $fatal(1, "an interrupted frame (%0d) kept its claim", what);
    end
  endtask

  initial begin
    capture_frame();
    decode_frame();
    write_trace();

    if (!saw_gap) $fatal(1, "the timer never ran the idle phase");
    if (!saw_claim) $fatal(1, "the engine never owned the transmit pin");
    if (!saw_done) $fatal(1, "the frame never reported completion");
    if (!bank_clean) $fatal(1, "the pin bank rejected a request or flagged a conflict");
    if (other_pins_touched) $fatal(1, "a pin other than the transmit pin was driven");
    if (engine_claim_o != 8'h00) $fatal(1, "the claim was not released after the frame");
    if (pins_o[TX_PIN] !== 1'b1 || pin_oe_o[TX_PIN] !== 1'b1)
      $fatal(1, "the line was not left resting idle high");

    check_release(2'd0);
    check_release(2'd1);
    check_release(2'd2);

    $display("PASS P2.7 UART slice emitted RTL: 0x%02h received, %0d cycle bit period",
             received[7:0], measured_period);
    $finish;
  end
endmodule
