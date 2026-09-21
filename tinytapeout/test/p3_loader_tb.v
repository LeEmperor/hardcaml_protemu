`timescale 1ns/1ps

module p3_loader_tb;
  reg clock_i = 0;
  reg reset_i = 1;
  reg enable_i = 1;
  reg serial_select_n_i = 1;
  reg serial_clock_i = 0;
  reg serial_data_i = 0;
  reg [15:0] prog_mem_read_data_i = 16'hdead;
  reg [7:0] pin_async_i = 0;
  reg [7:0] occupied_i = 0;
  wire serial_data_o;
  wire serial_ready_o;
  wire prog_mem_enable_o;
  wire prog_mem_write_enable_o;
  wire [7:0] prog_mem_address_o;
  wire [15:0] prog_mem_write_data_o;
  wire [7:0] pins_o;
  wire [7:0] pin_oe_o;

  reg [15:0] memory [0:255];
  reg [7:0] request [0:15];
  reg [7:0] response [0:31];
  integer write_count = 0;
  integer host_low = 40;
  integer host_high = 40;
  integer phase;
  integer generated_trial;
  reg [31:0] generated_state;

`ifdef LOADER_WRAPPER
  wire [7:0] wrapper_ui_in = {5'b00000, serial_data_i, serial_clock_i, serial_select_n_i};
  wire [7:0] wrapper_uo_out;
  wire [7:0] wrapper_uio_out;
  wire [7:0] wrapper_uio_oe;
  assign serial_data_o = wrapper_uo_out[0];
  assign serial_ready_o = wrapper_uo_out[1];
  assign prog_mem_enable_o = 0;
  assign prog_mem_write_enable_o = 0;
  assign prog_mem_address_o = 0;
  assign prog_mem_write_data_o = 0;
  assign pins_o = wrapper_uio_out;
  assign pin_oe_o = wrapper_uio_oe;
  tt_um_leemperor_hardcaml_protemu_loader dut (
    .ui_in(wrapper_ui_in),
    .uio_in(pin_async_i),
    .ena(enable_i),
    .clk(clock_i),
    .rst_n(~reset_i),
    .uo_out(wrapper_uo_out),
    .uio_out(wrapper_uio_out),
    .uio_oe(wrapper_uio_oe)
  );
`else
  loader_core dut (
    .clock_i(clock_i),
    .reset_i(reset_i),
    .enable_i(enable_i),
    .serial_select_n_i(serial_select_n_i),
    .serial_clock_i(serial_clock_i),
    .serial_data_i(serial_data_i),
    .prog_mem_read_data_i(prog_mem_read_data_i),
    .pin_async_i(pin_async_i),
    .occupied_i(occupied_i),
    .serial_data_o(serial_data_o),
    .serial_ready_o(serial_ready_o),
    .prog_mem_enable_o(prog_mem_enable_o),
    .prog_mem_write_enable_o(prog_mem_write_enable_o),
    .prog_mem_address_o(prog_mem_address_o),
    .prog_mem_write_data_o(prog_mem_write_data_o),
    .pins_o(pins_o),
    .pin_oe_o(pin_oe_o)
  );
`endif

  always #5 clock_i = ~clock_i;

`ifndef LOADER_WRAPPER
  always @(posedge clock_i) begin
    if (prog_mem_enable_o) begin
      if (prog_mem_write_enable_o) begin
        memory[prog_mem_address_o] <= prog_mem_write_data_o;
        write_count <= write_count + 1;
      end else begin
        prog_mem_read_data_i <= memory[prog_mem_address_o];
      end
    end
  end
`endif

  function automatic [7:0] crc8_byte(input [7:0] crc_in, input [7:0] data);
    reg [7:0] crc;
    integer bit_index;
    begin
      crc = crc_in;
      for (bit_index = 7; bit_index >= 0; bit_index = bit_index - 1) begin
        if (crc[7] ^ data[bit_index]) crc = (crc << 1) ^ 8'h07;
        else crc = crc << 1;
      end
      crc8_byte = crc;
    end
  endfunction

  task automatic send_byte(input [7:0] value);
    integer bit_index;
    begin
      for (bit_index = 7; bit_index >= 0; bit_index = bit_index - 1) begin
        serial_data_i = value[bit_index];
        #(host_low);
        serial_clock_i = 1;
        #(host_high);
        serial_clock_i = 0;
      end
    end
  endtask

  task automatic build_request(
    input [7:0] tag,
    input [7:0] command,
    input integer payload_length,
    input [39:0] payload,
    input integer corrupt_crc
  );
    reg [7:0] crc;
    integer index;
    integer total;
    begin
      request[0] = 8'ha5;
      request[1] = 8'h10;
      request[2] = tag;
      request[3] = command;
      request[4] = payload_length[7:0];
      request[5] = payload_length[15:8];
      for (index = 0; index < payload_length; index = index + 1)
        request[6 + index] = payload >> (8 * index);
      crc = 0;
      total = 6 + payload_length;
      for (index = 0; index < total; index = index + 1)
        crc = crc8_byte(crc, request[index]);
      request[total] = corrupt_crc ? (crc ^ 8'h80) : crc;
    end
  endtask

  task automatic send_request_bytes(input integer count);
    integer index;
    begin
      serial_select_n_i = 0;
      #(host_low);
      for (index = 0; index < count; index = index + 1) send_byte(request[index]);
      #(host_low);
      serial_select_n_i = 1;
      serial_data_i = 0;
      #(host_low);
    end
  endtask

  task automatic wait_ready;
    integer budget;
    begin
      budget = 0;
      while (!serial_ready_o && budget < 200) begin
        @(posedge clock_i);
        budget = budget + 1;
      end
      if (!serial_ready_o) $fatal(1, "loader response timeout");
    end
  endtask

  task automatic read_byte(output [7:0] value);
    integer bit_index;
    begin
      value = 0;
      for (bit_index = 7; bit_index >= 0; bit_index = bit_index - 1) begin
        #(host_low);
        serial_clock_i = 1;
        #1;
        value[bit_index] = serial_data_o;
        #(host_high - 1);
        serial_clock_i = 0;
      end
    end
  endtask

  task automatic receive_response(
    input [7:0] expected_tag,
    input [7:0] expected_command,
    input [7:0] expected_result,
    input integer expected_payload_length,
    input [15:0] expected_word,
    input integer check_word
  );
    reg [7:0] crc;
    integer index;
    integer payload_length;
    integer total;
    begin
      wait_ready();
      serial_select_n_i = 0;
      #(host_low);
      for (index = 0; index < 7; index = index + 1) read_byte(response[index]);
      if (^response[5] === 1'bx || ^response[6] === 1'bx)
        $fatal(1, "unknown response payload length");
      payload_length = response[5] | (response[6] << 8);
      if (payload_length > 13) $fatal(1, "oversized response payload length %0d", payload_length);
      total = 8 + payload_length;
      for (index = 7; index < total; index = index + 1) read_byte(response[index]);
      #(host_low);
      serial_select_n_i = 1;
      #(host_low);
      if (response[0] !== 8'h5a || response[1] !== 8'h10)
        $fatal(1, "bad response header %02x %02x", response[0], response[1]);
      if (response[2] !== expected_tag || response[3] !== expected_command)
        $fatal(1, "response correlation mismatch tag=%02x command=%02x", response[2], response[3]);
      if (response[4] !== expected_result)
        $fatal(1, "response result got=%02x expected=%02x", response[4], expected_result);
      if (payload_length !== expected_payload_length)
        $fatal(1, "response length got=%0d expected=%0d", payload_length, expected_payload_length);
      crc = 0;
      for (index = 0; index < total - 1; index = index + 1)
        crc = crc8_byte(crc, response[index]);
      if (response[total - 1] !== crc)
        $fatal(1, "response CRC got=%02x expected=%02x", response[total - 1], crc);
      if (check_word && {response[8], response[7]} !== expected_word)
        $fatal(1, "response word got=%04x expected=%04x", {response[8], response[7]}, expected_word);
      repeat (6) @(posedge clock_i);
      if (serial_ready_o) $fatal(1, "response did not drain");
    end
  endtask

  task automatic transaction(
    input [7:0] tag,
    input [7:0] command,
    input integer payload_length,
    input [39:0] payload,
    input [7:0] expected_result,
    input integer expected_payload_length,
    input [15:0] expected_word,
    input integer check_word
  );
    begin
      build_request(tag, command, payload_length, payload, 0);
      send_request_bytes(7 + payload_length);
      receive_response(tag, command, expected_result, expected_payload_length, expected_word, check_word);
    end
  endtask

  task automatic load_one(input [7:0] first_tag, input [15:0] word);
    begin
      transaction(first_tag, 8'h10, 2, 40'h0000000001, 8'h00, 0, 0, 0);
      transaction(first_tag + 1, 8'h11, 4, {word[15:8], word[7:0], 16'h0000}, 8'h00, 0, 0, 0);
      transaction(first_tag + 2, 8'h13, 4, {word[15:8], word[7:0], 16'h0000}, 8'h00, 2, word, 1);
      transaction(first_tag + 3, 8'h14, 0, 0, 8'h00, 0, 0, 0);
    end
  endtask

  initial begin
    repeat (4) @(posedge clock_i);
    reset_i = 0;
    repeat (4) @(posedge clock_i);

    /* Every integer phase at the 40 ns half-period boundary. */
    for (phase = 0; phase < 10; phase = phase + 1) begin
      #(phase);
      transaction(phase[7:0], 8'h00, 0, 0, 8'h00, 13, 0, 0);
    end
    host_low = 40;
    host_high = 50;
    transaction(8'h10, 8'h00, 0, 0, 8'h00, 13, 0, 0);
    host_low = 50;
    host_high = 40;
    transaction(8'h11, 8'h00, 0, 0, 8'h00, 13, 0, 0);
    /* Three-cycle halves are the measured point just outside the four-cycle contract. */
    host_low = 30;
    host_high = 30;
    transaction(8'h12, 8'h00, 0, 0, 8'h00, 13, 0, 0);
    host_low = 40;
    host_high = 40;

    /* Clocking may pause indefinitely while selection remains asserted. */
    build_request(8'h13, 8'h00, 0, 0, 0);
    serial_select_n_i = 0;
    #(host_low);
    send_byte(request[0]);
    send_byte(request[1]);
    send_byte(request[2]);
    #500;
    send_byte(request[3]);
    send_byte(request[4]);
    send_byte(request[5]);
    send_byte(request[6]);
    #(host_low);
    serial_select_n_i = 1;
    #(host_low);
    receive_response(8'h13, 8'h00, 8'h00, 13, 0, 0);

    /* A response may be abandoned and restarted without repeating the request. */
    build_request(8'h20, 8'h01, 0, 0, 0);
    send_request_bytes(7);
    wait_ready();
    serial_select_n_i = 0;
    #(host_low);
    read_byte(response[0]);
    read_byte(response[1]);
    serial_select_n_i = 1;
    #(host_low);
    if (!serial_ready_o) $fatal(1, "interrupted response was discarded");
    receive_response(8'h20, 8'h01, 8'h00, 12, 0, 0);

    /* Corrupt and interrupted requests have no write side effect. */
    build_request(8'h21, 8'h10, 2, 40'h1, 1);
    send_request_bytes(9);
    receive_response(8'h21, 8'h10, 8'h13, 0, 0, 0);
    build_request(8'h22, 8'h11, 4, 40'h0000123400, 0);
    send_request_bytes(8);
    receive_response(8'h22, 8'h11, 8'h15, 0, 0, 0);
    transaction(8'h23, 8'h11, 3, 40'h00123400, 8'h12, 0, 0, 0);
    build_request(8'h24, 8'h00, 0, 0, 0);
    request[0] = 8'h00;
    send_request_bytes(7);
    receive_response(8'h24, 8'h00, 8'h10, 0, 0, 0);
    build_request(8'h25, 8'h00, 0, 0, 0);
    request[1] = 8'h20;
    request[6] = 0;
    request[6] = crc8_byte(request[6], request[0]);
    request[6] = crc8_byte(request[6], request[1]);
    request[6] = crc8_byte(request[6], request[2]);
    request[6] = crc8_byte(request[6], request[3]);
    request[6] = crc8_byte(request[6], request[4]);
    request[6] = crc8_byte(request[6], request[5]);
    send_request_bytes(7);
    receive_response(8'h25, 8'h00, 8'h11, 0, 0, 0);
    transaction(8'h26, 8'hff, 0, 0, 8'h14, 0, 0, 0);
    transaction(8'h27, 8'h11, 4, 40'h12340100, 8'h23, 0, 0, 0);
    transaction(8'h28, 8'h00, 5, 40'h5544332211, 8'h12, 0, 0, 0);
`ifndef LOADER_WRAPPER
    if (write_count !== 0) $fatal(1, "malformed request wrote program RAM");
`endif

    /* Replayable bounded malformed-frame generation, seed 20260921, 16 trials. */
    generated_state = 32'd20260921;
    for (generated_trial = 0; generated_trial < 16; generated_trial = generated_trial + 1) begin
      generated_state = {generated_state[30:0],
                         generated_state[31] ^ generated_state[21] ^ generated_state[1] ^ generated_state[0]};
      build_request(generated_state[7:0], 8'h00, 0, 0, 1);
      send_request_bytes(7);
      receive_response(generated_state[7:0], 8'h00, 8'h13, 0, 0, 0);
    end

`ifndef LOADER_WRAPPER

    /* A transport-valid load still needs actual RAM readback verification. */
    transaction(8'h30, 8'h10, 2, 40'h1, 8'h00, 0, 0, 0);
    transaction(8'h31, 8'h11, 4, 40'h00cafe0000, 8'h00, 0, 0, 0);
    memory[0] = 16'hbeef;
    transaction(8'h32, 8'h13, 4, 40'h00cafe0000, 8'h24, 2, 16'hbeef, 1);
    transaction(8'h33, 8'h14, 0, 0, 8'h23, 0, 0, 0);
    transaction(8'h34, 8'h20, 0, 0, 8'h22, 0, 0, 0);
`endif

    /* A looping program refuses program access, but fixed ABORT remains reachable. */
    load_one(8'h40, 16'h5fff);
    transaction(8'h44, 8'h20, 0, 0, 8'h00, 0, 0, 0);
    repeat (20) @(posedge clock_i);
    transaction(8'h45, 8'h12, 2, 40'h0, 8'h20, 0, 0, 0);
    transaction(8'h46, 8'h22, 0, 0, 8'h00, 0, 0, 0);
    if (pin_oe_o !== 0) $fatal(1, "ABORT did not release protocol outputs");

    /* Replacement load, readback, and Halt execution use the same serial pins. */
    load_one(8'h50, 16'h0000);
    transaction(8'h54, 8'h12, 2, 40'h0, 8'h00, 2, 16'h0000, 1);
    transaction(8'h55, 8'h20, 0, 0, 8'h00, 0, 0, 0);
    repeat (20) @(posedge clock_i);
    transaction(8'h56, 8'h01, 0, 0, 8'h00, 12, 0, 0);

    /* Disable cancels a partial frame and releases all visible outputs. */
    build_request(8'h60, 8'h10, 2, 40'h1, 0);
    serial_select_n_i = 0;
    #(host_low);
    send_byte(request[0]);
    enable_i = 0;
    repeat (4) @(posedge clock_i);
    if (serial_ready_o || serial_data_o || pin_oe_o !== 0)
      $fatal(1, "disable did not release loader/protocol outputs");
    serial_select_n_i = 1;
    enable_i = 1;
    repeat (6) @(posedge clock_i);

    /* Reset also cancels a partial command and returns with no executable image. */
    serial_select_n_i = 0;
    #(host_low);
    send_byte(8'ha5);
    reset_i = 1;
    repeat (3) @(posedge clock_i);
    serial_select_n_i = 1;
    reset_i = 0;
    repeat (6) @(posedge clock_i);
    transaction(8'h61, 8'h20, 0, 0, 8'h22, 0, 0, 0);

    $display("PASS p3.5 serial loader: phase sweep, malformed/interrupted rejection, verification, recovery, reset/disable");
    $finish;
  end
endmodule
