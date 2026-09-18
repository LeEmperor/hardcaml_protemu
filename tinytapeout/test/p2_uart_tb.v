`timescale 1ns/1ps

module p2_uart_tb;
  reg clock_i = 0;
  reg reset_i = 1;
  reg enable_i = 1;
  reg abort_i = 0;
  reg byte_valid_i = 0;
  reg [7:0] byte_i = 8'h00;
  reg [15:0] half_period_i = 16'd4;
  reg [2:0] tx_pin_i = 3'd0;
  wire byte_ready_o;
  wire [7:0] pins_o;
  wire [7:0] pin_oe_o;
  wire busy_o;
  wire done_o;
  wire rejected_o;
  integer cycle;
  integer bit_index;
  reg expected_bit;

  uart_tx dut (
    .clock_i(clock_i),
    .reset_i(reset_i),
    .enable_i(enable_i),
    .abort_i(abort_i),
    .byte_valid_i(byte_valid_i),
    .byte_i(byte_i),
    .half_period_i(half_period_i),
    .tx_pin_i(tx_pin_i),
    .byte_ready_o(byte_ready_o),
    .pins_o(pins_o),
    .pin_oe_o(pin_oe_o),
    .busy_o(busy_o),
    .done_o(done_o),
    .rejected_o(rejected_o)
  );

  always #5 clock_i = ~clock_i;

  task step;
    begin
      @(posedge clock_i);
      #1;
    end
  endtask

  initial begin
    step();
    reset_i = 0;
    step();
    if (pins_o !== 8'h01 || pin_oe_o !== 8'h01)
      $fatal(1, "UART idle value/enable");

    byte_i = 8'ha6;
    byte_valid_i = 1;
    step();
    byte_valid_i = 0;
    if (pins_o !== 8'h00 || pin_oe_o !== 8'h01)
      $fatal(1, "UART start bit");

    for (cycle = 1; cycle <= 80; cycle = cycle + 1) begin
      step();
      if (cycle <= 76 && (cycle - 4) % 8 == 0) begin
        bit_index = (cycle - 4) / 8;
        if (bit_index == 0)
          expected_bit = 0;
        else if (bit_index == 9)
          expected_bit = 1;
        else
          expected_bit = byte_i[bit_index - 1];
        if (pins_o[0] !== expected_bit || pin_oe_o[0] !== 1'b1)
          $fatal(1, "UART bit %0d at cycle %0d", bit_index, cycle);
      end
    end
    if (done_o !== 1'b1 || pins_o[0] !== 1'b1)
      $fatal(1, "UART completion/idle");

    byte_valid_i = 1;
    step();
    byte_valid_i = 0;
    if (pins_o[0] !== 1'b0)
      $fatal(1, "second UART start");
    enable_i = 0;
    step();
    if (pin_oe_o !== 8'h00 || busy_o !== 1'b0)
      $fatal(1, "disable release");
    $display("PASS P2 UART emitted RTL");
    $finish;
  end
endmodule
