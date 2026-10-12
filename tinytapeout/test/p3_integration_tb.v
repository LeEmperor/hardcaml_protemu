`timescale 1ns/1ps

module p3_integration_tb;
  reg clock_i = 0;
  always #5 clock_i = ~clock_i;

  reg reset_i = 0;
  reg en_i = 1;
  reg load_start_valid_i = 0;
  reg [8:0] load_length_i = 0;
  reg load_write_valid_i = 0;
  reg [8:0] load_address_i = 0;
  reg [15:0] load_data_i = 0;
  reg load_complete_valid_i = 0;
  reg readback_valid_i = 0;
  reg [8:0] readback_address_i = 0;
  reg readback_verify_i = 0;
  reg [15:0] readback_expected_i = 0;
  reg run_valid_i = 0;
  reg stop_valid_i = 0;
  reg abort_valid_i = 0;
  reg step_valid_i = 0;
  reg [7:0] pin_async_i = 0;
  reg [7:0] occupied_i = 0;
  reg software_claim_valid_i = 0;
  reg [7:0] software_claim_mask_i = 0;
  reg software_release_valid_i = 0;
  reg [7:0] software_release_mask_i = 0;
  reg tx_ready_i = 0;
  reg rx_valid_i = 0;
  reg [7:0] rx_data_i = 0;
  reg transfer_rx_ready_i = 1;

  reg [15:0] memory [0:255];
  reg [15:0] prog_mem_read_data_i = 16'ha5a5;
  wire prog_mem_enable_o;
  wire prog_mem_write_enable_o;
  wire [7:0] prog_mem_address_o;
  wire [15:0] prog_mem_write_data_o;
  wire load_start_accepted_o;
  wire load_write_accepted_o;
  wire load_complete_accepted_o;
  wire readback_response_valid_o;
  wire readback_response_match_o;
  wire run_accepted_o;
  wire abort_accepted_o;
  wire halted_o;
  wire engines_idle_o;
  wire normal_halt_o;
  wire execution_fault_o;
  wire timing_busy_o;
  wire [7:0] pins_o;
  wire [7:0] pin_oe_o;
  wire [7:0] software_claim_o;
  wire [5:0] status_o;

  integrated_core dut (
    .clock_i(clock_i),
    .reset_i(reset_i),
    .en_i(en_i),
    .load_start_valid_i(load_start_valid_i),
    .load_length_i(load_length_i),
    .load_write_valid_i(load_write_valid_i),
    .load_address_i(load_address_i),
    .load_data_i(load_data_i),
    .load_complete_valid_i(load_complete_valid_i),
    .readback_valid_i(readback_valid_i),
    .readback_address_i(readback_address_i),
    .readback_verify_i(readback_verify_i),
    .readback_expected_i(readback_expected_i),
    .run_valid_i(run_valid_i),
    .stop_valid_i(stop_valid_i),
    .abort_valid_i(abort_valid_i),
    .step_valid_i(step_valid_i),
    .prog_mem_read_data_i(prog_mem_read_data_i),
    .pin_async_i(pin_async_i),
    .occupied_i(occupied_i),
    .software_claim_valid_i(software_claim_valid_i),
    .software_claim_mask_i(software_claim_mask_i),
    .software_release_valid_i(software_release_valid_i),
    .software_release_mask_i(software_release_mask_i),
    .tx_ready_i(tx_ready_i),
    .rx_valid_i(rx_valid_i),
    .rx_data_i(rx_data_i),
    .transfer_rx_ready_i(transfer_rx_ready_i),
    .prog_mem_enable_o(prog_mem_enable_o),
    .prog_mem_write_enable_o(prog_mem_write_enable_o),
    .prog_mem_address_o(prog_mem_address_o),
    .prog_mem_write_data_o(prog_mem_write_data_o),
    .load_start_accepted_o(load_start_accepted_o),
    .load_write_accepted_o(load_write_accepted_o),
    .load_complete_accepted_o(load_complete_accepted_o),
    .readback_response_valid_o(readback_response_valid_o),
    .readback_response_match_o(readback_response_match_o),
    .run_accepted_o(run_accepted_o),
    .abort_accepted_o(abort_accepted_o),
    .halted_o(halted_o),
    .engines_idle_o(engines_idle_o),
    .normal_halt_o(normal_halt_o),
    .execution_fault_o(execution_fault_o),
    .timing_busy_o(timing_busy_o),
    .pins_o(pins_o),
    .pin_oe_o(pin_oe_o),
    .software_claim_o(software_claim_o),
    .status_o(status_o)
  );

  always @(posedge clock_i) begin
    if (prog_mem_enable_o) begin
      if (prog_mem_write_enable_o) begin
        memory[prog_mem_address_o] <= prog_mem_write_data_o;
        prog_mem_read_data_i <= 16'hdead;
      end else begin
        prog_mem_read_data_i <= memory[prog_mem_address_o];
      end
    end
  end

  task tick;
    begin
      @(posedge clock_i);
      #1;
    end
  endtask

  task write_word(input integer address, input [15:0] data);
    begin
      load_write_valid_i = 1;
      load_address_i = address;
      load_data_i = data;
      #1;
      if (!load_write_accepted_o) $fatal(1, "write %0d was not accepted", address);
      tick;
      load_write_valid_i = 0;
    end
  endtask

  task verify_word(input integer address, input [15:0] data);
    begin
      readback_valid_i = 1;
      readback_verify_i = 1;
      readback_address_i = address;
      readback_expected_i = data;
      tick;
      readback_valid_i = 0;
      readback_verify_i = 0;
      tick;
      if (!readback_response_valid_o || !readback_response_match_o)
        $fatal(1, "verification %0d failed", address);
    end
  endtask

  integer cycles;
  initial begin
    reset_i = 1;
    tick;
    reset_i = 0;

    software_claim_valid_i = 1;
    software_claim_mask_i = 8'h01;
    tick;
    software_claim_valid_i = 0;
    if (software_claim_o != 8'h01) $fatal(1, "software claim failed");

    load_start_valid_i = 1;
    load_length_i = 6;
    #1;
    if (!load_start_accepted_o) $fatal(1, "load start was not accepted");
    tick;
    load_start_valid_i = 0;
    write_word(0, 16'h7804);
    write_word(1, 16'h0000);
    write_word(2, 16'ha300);
    write_word(3, 16'h7804);
    write_word(4, 16'h0001);
    write_word(5, 16'h0000);
    verify_word(0, 16'h7804);
    verify_word(1, 16'h0000);
    verify_word(2, 16'ha300);
    verify_word(3, 16'h7804);
    verify_word(4, 16'h0001);
    verify_word(5, 16'h0000);
    load_complete_valid_i = 1;
    #1;
    if (!load_complete_accepted_o) $fatal(1, "load completion was not accepted");
    tick;
    load_complete_valid_i = 0;

    run_valid_i = 1;
    #1;
    if (!run_accepted_o) $fatal(1, "RUN was not accepted");
    tick;
    run_valid_i = 0;
    cycles = 0;
    while (!timing_busy_o && cycles < 40) begin tick; cycles = cycles + 1; end
    if (!timing_busy_o || pins_o[0] || !pin_oe_o[0])
      $fatal(1, "program did not establish its waiting low state");
    pin_async_i = 8'h08;
    cycles = 0;
    while (!halted_o && cycles < 80) begin tick; cycles = cycles + 1; end
    if (!halted_o || !normal_halt_o || execution_fault_o || !pins_o[0] || !pin_oe_o[0])
      $fatal(1, "event-to-core-to-pin program failed");

    pin_async_i = 0;
    repeat (3) tick;
    run_valid_i = 1;
    tick;
    run_valid_i = 0;
    cycles = 0;
    while (!timing_busy_o && cycles < 40) begin tick; cycles = cycles + 1; end
    abort_valid_i = 1;
    #1;
    if (!abort_accepted_o) $fatal(1, "ABORT was not accepted");
    tick;
    abort_valid_i = 0;
    if (!halted_o || pin_oe_o != 0 || software_claim_o != 0 || !status_o[4])
      $fatal(1, "ABORT did not halt, release, and report interruption");

    $display("P3.3 emitted RTL PASS: loaded wait/event/pin path and ABORT release");
    $finish;
  end
endmodule
