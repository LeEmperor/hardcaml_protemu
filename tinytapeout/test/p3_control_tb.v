`timescale 1ns/1ps

module p3_control_tb;
  reg clock_i = 0;
  always #5 clock_i = ~clock_i;

  reg reset_i = 0;
  reg en_i = 1;
  reg engines_idle_i = 1;
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
  reg mechanism_accepted_i = 0;
  reg mechanism_refused_i = 0;
  reg [7:0] mechanism_refusal_reason_i = 0;
  reg mechanism_completion_valid_i = 0;
  reg [15:0] mechanism_completion_result_i = 0;
  reg mechanism_completion_fault_i = 0;
  reg [7:0] mechanism_completion_reason_i = 0;

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
  wire halted_o;
  wire image_valid_o;
  wire normal_halt_o;
  wire execution_fault_o;
  wire [16:0] pc_o;
  wire [127:0] registers_o;
  wire zero_o;
  wire carry_o;
  wire negative_o;
  wire [31:0] fetch_cycles_o;
  wire [31:0] execute_cycles_o;
  wire [31:0] stall_cycles_o;
  wire [31:0] instruction_count_o;
  wire [31:0] extension_fetches_o;
  wire [31:0] total_cycles_o;

  executable_core dut (
    .clock_i(clock_i),
    .reset_i(reset_i),
    .en_i(en_i),
    .engines_idle_i(engines_idle_i),
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
    .prog_mem_read_data_i(prog_mem_read_data_i),
    .mechanism_accepted_i(mechanism_accepted_i),
    .mechanism_refused_i(mechanism_refused_i),
    .mechanism_refusal_reason_i(mechanism_refusal_reason_i),
    .mechanism_completion_valid_i(mechanism_completion_valid_i),
    .mechanism_completion_result_i(mechanism_completion_result_i),
    .mechanism_completion_fault_i(mechanism_completion_fault_i),
    .mechanism_completion_reason_i(mechanism_completion_reason_i),
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
    .halted_o(halted_o),
    .image_valid_o(image_valid_o),
    .normal_halt_o(normal_halt_o),
    .execution_fault_o(execution_fault_o),
    .pc_o(pc_o),
    .registers_o(registers_o),
    .zero_o(zero_o),
    .carry_o(carry_o),
    .negative_o(negative_o),
    .fetch_cycles_o(fetch_cycles_o),
    .execute_cycles_o(execute_cycles_o),
    .stall_cycles_o(stall_cycles_o),
    .instruction_count_o(instruction_count_o),
    .extension_fetches_o(extension_fetches_o),
    .total_cycles_o(total_cycles_o)
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

  integer program_cycles;
  initial begin
    reset_i = 1;
    tick;
    reset_i = 0;

    load_start_valid_i = 1;
    load_length_i = 9;
    #1;
    if (!load_start_accepted_o) $fatal(1, "load start was not accepted");
    tick;
    load_start_valid_i = 0;

    write_word(0, 16'h0880);
    write_word(1, 16'h1234);
    write_word(2, 16'h3080);
    write_word(3, 16'h1234);
    write_word(4, 16'h6001);
    write_word(5, 16'h0a63);
    write_word(6, 16'h0902);
    write_word(7, 16'h71ff);
    write_word(8, 16'h0000);

    verify_word(0, 16'h0880);
    verify_word(1, 16'h1234);
    verify_word(2, 16'h3080);
    verify_word(3, 16'h1234);
    verify_word(4, 16'h6001);
    verify_word(5, 16'h0a63);
    verify_word(6, 16'h0902);
    verify_word(7, 16'h71ff);
    verify_word(8, 16'h0000);

    load_complete_valid_i = 1;
    #1;
    if (!load_complete_accepted_o) $fatal(1, "load completion was not accepted");
    tick;
    if (!image_valid_o) $fatal(1, "load completion failed");
    load_complete_valid_i = 0;

    run_valid_i = 1;
    #1;
    if (!run_accepted_o) $fatal(1, "RUN was not accepted");
    tick;
    if (halted_o) $fatal(1, "RUN failed");
    run_valid_i = 0;

    program_cycles = 0;
    while (!halted_o && program_cycles < 40) begin
      tick;
      program_cycles = program_cycles + 1;
    end

    if (!halted_o || !normal_halt_o || execution_fault_o) $fatal(1, "execution did not halt normally");
    if (program_cycles != 16) $fatal(1, "expected 16 program cycles, got %0d", program_cycles);
    if (registers_o[15:0] != 16'h1234) $fatal(1, "r0 mismatch");
    if (registers_o[31:16] != 16'h0000) $fatal(1, "r1 mismatch");
    if (registers_o[47:32] != 16'h0000) $fatal(1, "skipped r2 write executed");
    if (!zero_o || carry_o || negative_o) $fatal(1, "flag mismatch");
    if (pc_o != 8) $fatal(1, "halt PC mismatch");
    if (fetch_cycles_o != 9 || execute_cycles_o != 7 || stall_cycles_o != 0)
      $fatal(1, "cycle-class mismatch");
    if (instruction_count_o != 7 || extension_fetches_o != 2 || total_cycles_o != 16)
      $fatal(1, "counter mismatch");

    $display("P3.2 emitted RTL PASS: 9 fetch + 7 execute = 16 cycles");
    $finish;
  end
endmodule
