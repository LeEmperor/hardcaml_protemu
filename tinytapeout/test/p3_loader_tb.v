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
  reg [7:0] request [0:127];
  reg [7:0] response [0:31];
  integer write_count = 0;
  integer host_low = 40;
  integer host_high = 40;
  integer phase;
  integer generated_trial;
  reg [31:0] generated_state;
  integer pin_drive_events = 0;
  reg pin_driven_previous = 0;
  integer saved_write_count;
  integer saved_pin_drive_events;
  integer excluded_failures;
  reg [15:0] fixture [0:31];

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

  always @(posedge clock_i) begin
    if (!pin_driven_previous && pin_oe_o[1])
      pin_drive_events <= pin_drive_events + 1;
    pin_driven_previous <= pin_oe_o[1];
  end

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
      for (index = 0; index < count; index = index + 1) send_byte(request[index]);
      #(host_low);
      serial_select_n_i = 1;
      serial_data_i = 0;
      #(host_low);
    end
  endtask

  task automatic send_request_without_release_wait(input integer count);
    integer index;
    begin
      serial_select_n_i = 0;
      for (index = 0; index < count; index = index + 1) send_byte(request[index]);
      #(host_low);
      serial_select_n_i = 1;
      serial_data_i = 0;
    end
  endtask

  /* An out-of-contract early selection with real clock traffic is ignored as a
     request and cannot alter the operation moving through dispatch/completion. */
  task automatic disturb_inflight(input [7:0] marker);
    integer bit_index;
    begin
      @(posedge clock_i);
      #0.001;
      serial_select_n_i = 0;
      serial_data_i = 1;
      for (bit_index = 7; bit_index >= 0; bit_index = bit_index - 1) begin
        #(host_low);
        serial_clock_i = 1;
        #0.001;
        if (serial_data_o !== 0)
          $fatal(1, "in-flight selection %02x incorrectly armed a response", marker);
        #(host_high - 0.001);
        serial_clock_i = 0;
      end
      #(host_low);
      serial_select_n_i = 1;
      serial_data_i = 0;
      #(host_low);
    end
  endtask

  task automatic send_prefixed_request(
    input integer prefix_length,
    input [7:0] tag,
    input [7:0] command,
    input integer payload_length,
    input [39:0] payload
  );
    integer index;
    integer frame_length;
    begin
      build_request(tag, command, payload_length, payload, 0);
      frame_length = 7 + payload_length;
      for (index = frame_length - 1; index >= 0; index = index - 1)
        request[prefix_length + index] = request[index];
      for (index = 0; index < prefix_length; index = index + 1)
        request[index] = 0;
      send_request_bytes(prefix_length + frame_length);
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
        #0.001;
        value[bit_index] = serial_data_o;
        #(host_high - 0.001);
        serial_clock_i = 0;
      end
    end
  endtask

  /* Read the final byte but leave LCLK high after its final sampling edge. */
  task automatic read_final_byte(output [7:0] value);
    integer bit_index;
    begin
      value = 0;
      for (bit_index = 7; bit_index > 0; bit_index = bit_index - 1) begin
        #(host_low);
        serial_clock_i = 1;
        #0.001;
        value[bit_index] = serial_data_o;
        #(host_high - 0.001);
        serial_clock_i = 0;
      end
      #(host_low);
      serial_clock_i = 1;
      #0.001;
      value[0] = serial_data_o;
    end
  endtask

  task automatic receive_response_mode(
    input [7:0] expected_tag,
    input [7:0] expected_command,
    input [7:0] expected_result,
    input integer expected_payload_length,
    input [15:0] expected_word,
    input integer check_word,
    input integer reject_after_validation
  );
    reg [7:0] crc;
    integer index;
    integer payload_length;
    integer total;
    begin
      wait_ready();
      serial_select_n_i = 0;
      for (index = 0; index < 7; index = index + 1) read_byte(response[index]);
      if (^response[5] === 1'bx || ^response[6] === 1'bx)
        $fatal(1, "unknown response payload length");
      payload_length = response[5] | (response[6] << 8);
      if (payload_length > 13) $fatal(1, "oversized response payload length %0d", payload_length);
      total = 8 + payload_length;
      for (index = 7; index < total - 1; index = index + 1) read_byte(response[index]);
      read_final_byte(response[total - 1]);
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
      if (reject_after_validation) begin
        /* Model a peer-side CRC rejection after the full frame is available. Deselecting
           before the final falling edge preserves the retained response for replay. */
        response[total - 1] = response[total - 1] ^ 8'h01;
        if (response[total - 1] === crc)
          $fatal(1, "forced peer-side response corruption did not change CRC");
        serial_select_n_i = 1;
        #(host_low);
        serial_clock_i = 0;
        #(host_low);
        if (!serial_ready_o) $fatal(1, "rejected response was consumed");
      end else begin
        /* Validation succeeded while LCLK was high. Its final falling edge followed by
           deselection is the explicit response commit. */
        #(host_high - 0.001);
        serial_clock_i = 0;
        #(host_low);
        serial_select_n_i = 1;
        #(host_low);
        repeat (6) @(posedge clock_i);
        if (serial_ready_o) $fatal(1, "committed response did not drain");
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
    begin
      receive_response_mode(expected_tag, expected_command, expected_result,
                            expected_payload_length, expected_word, check_word, 0);
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

  task automatic check_status(
    input [7:0] tag,
    input [15:0] expected_flags,
    input [15:0] flags_mask,
    input [15:0] expected_length,
    input [15:0] expected_written,
    input [15:0] expected_verified,
    input [7:0] expected_fault,
    input [7:0] expected_phase
  );
    reg [15:0] flags;
    begin
      transaction(tag, 8'h01, 0, 0, 8'h00, 12, 0, 0);
      flags = {response[8], response[7]};
      if ((flags & flags_mask) !== (expected_flags & flags_mask))
        $fatal(1, "STATUS flags got=%04x expected=%04x mask=%04x",
               flags, expected_flags, flags_mask);
      if ({response[10], response[9]} !== expected_length)
        $fatal(1, "STATUS length got=%04x expected=%04x",
               {response[10], response[9]}, expected_length);
      if ({response[12], response[11]} !== expected_written)
        $fatal(1, "STATUS written got=%04x expected=%04x",
               {response[12], response[11]}, expected_written);
      if ({response[14], response[13]} !== expected_verified)
        $fatal(1, "STATUS verified got=%04x expected=%04x",
               {response[14], response[13]}, expected_verified);
      if (response[17] !== expected_fault || response[18] !== expected_phase)
        $fatal(1, "STATUS fault/phase got=%02x/%02x expected=%02x/%02x",
               response[17], response[18], expected_fault, expected_phase);
    end
  endtask

  task automatic load_words_start(input [7:0] tag, input integer count);
    begin
      transaction(tag, 8'h10, 2, count[15:0], 8'h00, 0, 0, 0);
    end
  endtask

  task automatic write_word(input [7:0] tag, input [15:0] address, input [15:0] word);
    begin
      transaction(tag, 8'h11, 4, {word[15:8], word[7:0], address[15:8], address[7:0]},
                  8'h00, 0, 0, 0);
    end
  endtask

  task automatic verify_word(input [7:0] tag, input [15:0] address, input [15:0] word);
    begin
      transaction(tag, 8'h13, 4, {word[15:8], word[7:0], address[15:8], address[7:0]},
                  8'h00, 2, word, 1);
    end
  endtask

  task automatic load_fixture(input [7:0] first_tag, input integer count);
    integer index;
    begin
      load_words_start(first_tag, count);
      for (index = 0; index < count; index = index + 1)
        write_word(first_tag + 1 + index, index[15:0], fixture[index]);
      for (index = 0; index < count; index = index + 1)
        verify_word(first_tag + 1 + count + index, index[15:0], fixture[index]);
      transaction(first_tag + 1 + 2 * count, 8'h14, 0, 0, 8'h00, 0, 0, 0);
    end
  endtask

  /* Fixed-length INFO probe used only to characterize the excluded 3/3-cycle point.
     It deliberately avoids fatal checks so every integer phase is measured. */
  task automatic probe_info_timing(input [7:0] tag, output integer passed);
    integer index;
    integer budget;
    reg [7:0] crc;
    begin : probe
      passed = 0;
      build_request(tag, 8'h00, 0, 0, 0);
      send_request_bytes(7);
      budget = 0;
      while (!serial_ready_o && budget < 200) begin
        @(posedge clock_i);
        budget = budget + 1;
      end
      if (!serial_ready_o) disable probe;
      serial_select_n_i = 0;
      for (index = 0; index < 20; index = index + 1) read_byte(response[index]);
      read_final_byte(response[20]);
      crc = 0;
      for (index = 0; index < 20; index = index + 1)
        crc = crc8_byte(crc, response[index]);
      if (response[0] === 8'h5a && response[1] === 8'h10 &&
          response[2] === tag && response[3] === 8'h00 &&
          response[4] === 8'h00 && response[5] === 8'h0d &&
          response[6] === 8'h00 && response[20] === crc)
        passed = 1;
      #(host_high - 0.001);
      serial_clock_i = 0;
      #(host_low);
      serial_select_n_i = 1;
      #(host_low);
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

    check_status(8'hf0, 16'h0007, 16'h0fff, 0, 0, 0, 0, 0);
    transaction(8'hf1, 8'h21, 0, 0, 8'h01, 0, 0, 0);

    /* Every integer phase at the exact 4/4-cycle boundary. The 1 ps offset makes
       external transitions deterministic and just after any coincident system edge. */
    for (phase = 0; phase < 10; phase = phase + 1) begin
      @(posedge clock_i);
      #(phase + 0.001);
      transaction(phase[7:0], 8'h00, 0, 0, 8'h00, 13, 0, 0);
    end
    if (response[7] !== 8'h01 || response[8] !== 8'h00 ||
        response[9] !== 8'h01 || response[10] !== 8'h01 ||
        {response[12], response[11]} !== 16'h007f ||
        {response[14], response[13]} !== 16'h0010 ||
        {response[16], response[15]} !== 16'h0100 ||
        {response[18], response[17]} !== 16'h0004 || response[19] !== 8'h08)
      $fatal(1, "INFO payload encoding mismatch");

    /* Selection one to two system cycles too early is unsupported, but it must not
       overwrite the INFO command context while that command dispatches. */
    build_request(8'h0a, 8'h00, 0, 0, 0);
    send_request_without_release_wait(7);
    disturb_inflight(8'h0a);
    receive_response(8'h0a, 8'h00, 8'h00, 13, 0, 0);
    host_low = 40;
    host_high = 50;
    transaction(8'h10, 8'h00, 0, 0, 8'h00, 13, 0, 0);
    host_low = 50;
    host_high = 40;
    transaction(8'h11, 8'h00, 0, 0, 8'h00, 13, 0, 0);
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
    read_byte(response[0]);
    read_byte(response[1]);
    #(host_low);
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
      build_request(generated_state[7:0], 8'h00, 0, 0, generated_trial[0:0]);
      case (generated_trial % 4)
        0: begin
          request[6] = request[6] ^ 8'h80;
          send_request_bytes(7);
          receive_response(generated_state[7:0], 8'h00, 8'h13, 0, 0, 0);
        end
        1: begin
          send_request_bytes(6);
          receive_response(generated_state[7:0], 8'h00, 8'h15, 0, 0, 0);
        end
        2: begin
          request[7] = generated_state[15:8];
          send_request_bytes(8);
          receive_response(generated_state[7:0], 8'h00, 8'h15, 0, 0, 0);
        end
        default: begin
          request[5] = 8'h01;
          send_request_bytes(7);
          receive_response(generated_state[7:0], 8'h00, 8'h15, 0, 0, 0);
        end
      endcase
    end

    /* Establish a valid image, then prove long malformed LOAD_START suffixes cannot
       invalidate it. Prefixes cross one and multiple former four-bit counter wraps. */
    load_one(8'h30, 16'h0000);
    check_status(8'h34, 16'h000f, 16'h0fff, 1, 1, 1, 0, 0);
    send_prefixed_request(15, 8'h35, 8'h10, 2, 40'h1);
    receive_response(0, 0, 8'h12, 0, 0, 0);
    send_prefixed_request(16, 8'h36, 8'h10, 2, 40'h1);
    receive_response(0, 0, 8'h12, 0, 0, 0);
    send_prefixed_request(32, 8'h37, 8'h10, 2, 40'h1);
    receive_response(0, 0, 8'h12, 0, 0, 0);
    send_prefixed_request(48, 8'h38, 8'h10, 2, 40'h1);
    receive_response(0, 0, 8'h12, 0, 0, 0);
    check_status(8'h39, 16'h000f, 16'h0fff, 1, 1, 1, 0, 0);
    transaction(8'h3a, 8'h12, 2, 0, 8'h00, 2, 16'h0000, 1);

    /* A selection during the delayed READ completion cannot corrupt its correlation. */
    build_request(8'h3a, 8'h12, 2, 0, 0);
    send_request_without_release_wait(9);
    disturb_inflight(8'h3a);
    receive_response(8'h3a, 8'h12, 8'h00, 2, 16'h0000, 1);

    /* In an active load, a maximum-size WRITE_WORD frame is legal. One extra byte,
       and valid-looking suffixes after long prefixes, cannot dispatch or write RAM. */
    load_words_start(8'h3b, 1);
    check_status(8'h3c, 16'h0017, 16'h0fff, 1, 0, 0, 0, 0);
`ifndef LOADER_WRAPPER
    saved_write_count = write_count;
`endif
    send_prefixed_request(16, 8'h3d, 8'h11, 4, 40'hbeef0000);
    receive_response(0, 0, 8'h12, 0, 0, 0);
    send_prefixed_request(32, 8'h3e, 8'h11, 4, 40'hbeef0000);
    receive_response(0, 0, 8'h12, 0, 0, 0);
    build_request(8'h3f, 8'h11, 4, 40'hbeef0000, 0);
    request[11] = 0;
    send_request_bytes(12);
    receive_response(8'h3f, 8'h11, 8'h12, 0, 0, 0);
    check_status(8'h40, 16'h0017, 16'h0fff, 1, 0, 0, 0, 0);
`ifndef LOADER_WRAPPER
    if (write_count !== saved_write_count)
      $fatal(1, "overlength WRITE_WORD changed RAM write count");
`endif
    write_word(8'h41, 0, 16'hbeef);
    check_status(8'h42, 16'h0017, 16'h0fff, 1, 1, 0, 0, 0);

    /* A valid but wrong expected value fails verification in both wrapper source roles. */
    transaction(8'h43, 8'h13, 4, 40'hcafe0000, 8'h24, 2, 16'hbeef, 1);
    check_status(8'h44, 16'h0037, 16'h0fff, 1, 1, 0, 0, 0);
    transaction(8'h45, 8'h14, 0, 0, 8'h23, 0, 0, 0);
    transaction(8'h46, 8'h20, 0, 0, 8'h22, 0, 0, 0);

`ifndef LOADER_WRAPPER

    /* A transport-valid load still needs actual RAM readback verification. */
    transaction(8'h47, 8'h10, 2, 40'h1, 8'h00, 0, 0, 0);
    transaction(8'h48, 8'h11, 4, 40'h00cafe0000, 8'h00, 0, 0, 0);
    memory[0] = 16'hbeef;
    transaction(8'h49, 8'h13, 4, 40'h00cafe0000, 8'h24, 2, 16'hbeef, 1);
`endif

    /* A looping program refuses program access, but fixed ABORT remains reachable. */
    load_one(8'h50, 16'h5fff);
    transaction(8'h54, 8'h20, 0, 0, 8'h00, 0, 0, 0);
    repeat (20) @(posedge clock_i);
    check_status(8'h55, 16'h004d, 16'h01ff, 1, 1, 1, 0, 2);
    transaction(8'h56, 8'h12, 2, 40'h0, 8'h20, 0, 0, 0);
    transaction(8'h57, 8'h22, 0, 0, 8'h00, 0, 0, 0);
    if (pin_oe_o !== 0) $fatal(1, "ABORT did not release protocol outputs");

    /* A side-effecting RUN starts one long active transfer. A peer-side CRC rejection
       replays the retained response without reissuing RUN or repeating the pin effect. */
    fixture[0] = 16'hb820; /* control: TX, LSB first, falling launch/rising sample */
    fixture[1] = 16'hb8a0; /* 32 bits */
    fixture[2] = 16'hb90b; /* TX value */
    fixture[3] = 16'hb981; /* output pin 1 */
    fixture[4] = 16'hba09; /* no input pin */
    fixture[5] = 16'hba89; /* no clock pin */
    fixture[6] = 16'hbb00; /* no initial delay */
    fixture[7] = 16'hbbbf; /* 63-cycle half period */
    fixture[8] = 16'hbc00; /* internal pacing */
    fixture[9] = 16'hc000; /* issue transfer */
    load_fixture(8'h60, 10);
    saved_pin_drive_events = pin_drive_events;
    build_request(8'h75, 8'h20, 0, 0, 0);
    send_request_bytes(7);
    receive_response_mode(8'h75, 8'h20, 8'h00, 0, 0, 0, 1);
    repeat (40) @(posedge clock_i);
    if (pin_drive_events !== saved_pin_drive_events + 1)
      $fatal(1, "side-effecting RUN count got=%0d baseline=%0d pins=%02x oe=%02x",
             pin_drive_events, saved_pin_drive_events, pins_o, pin_oe_o);
    receive_response(8'h75, 8'h20, 8'h00, 0, 0, 0);
    repeat (20) @(posedge clock_i);
    if (pin_drive_events !== saved_pin_drive_events + 1)
      $fatal(1, "response replay repeated RUN side effects");
    if (pin_oe_o[1] !== 1'b1)
      $fatal(1, "active transfer did not drive its configured pin");
    build_request(8'h76, 8'h22, 0, 0, 0);
    send_request_without_release_wait(7);
    disturb_inflight(8'h76);
    receive_response(8'h76, 8'h22, 8'h00, 0, 0, 0);
    if (pin_oe_o !== 0) $fatal(1, "ABORT did not release active transfer pins");
    repeat (20) @(posedge clock_i);
    if (pin_oe_o !== 0) $fatal(1, "stale transfer write reasserted a pin");

    /* A blocking empty RX pop remains recoverable through the same serial ABORT path. */
    fixture[0] = 16'hd400; /* blocking FIFO pop from RX into r0 */
    fixture[1] = 16'h0000;
    load_fixture(8'h80, 2);
    transaction(8'h85, 8'h20, 0, 0, 8'h00, 0, 0, 0);
    repeat (30) @(posedge clock_i);
    check_status(8'h86, 16'h0049, 16'h01ff, 2, 2, 2, 0, 5);
    transaction(8'h87, 8'h22, 0, 0, 8'h00, 0, 0, 0);
    check_status(8'h88, 16'h000f, 16'h0c47, 2, 2, 2, 0, 0);

    /* Invalid-instruction fault state is decoded directly, then ABORT and replacement
       loading prove that recovery never depends on functioning firmware. */
    load_one(8'h90, 16'hf800);
    transaction(8'h94, 8'h20, 0, 0, 8'h00, 0, 0, 0);
    repeat (20) @(posedge clock_i);
    check_status(8'h95, 16'h010f, 16'h0fff, 1, 1, 1, 1, 6);
    transaction(8'h96, 8'h22, 0, 0, 8'h00, 0, 0, 0);

    /* Replacement load, readback, and Halt execution use the same serial pins. */
    load_one(8'ha0, 16'h0000);
    transaction(8'ha4, 8'h12, 2, 40'h0, 8'h00, 2, 16'h0000, 1);
    transaction(8'ha5, 8'h20, 0, 0, 8'h00, 0, 0, 0);
    repeat (20) @(posedge clock_i);
    check_status(8'ha6, 16'h008f, 16'h0fff, 1, 1, 1, 0, 0);

    /* Disable cancels a partial frame and releases all visible outputs. */
    build_request(8'hb0, 8'h10, 2, 40'h1, 0);
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
    if (serial_ready_o) $fatal(1, "disable release produced a stale response");
    transaction(8'hb1, 8'h00, 0, 0, 8'h00, 13, 0, 0);

    /* Reset also cancels a partial command and returns with no executable image. */
    serial_select_n_i = 0;
    #(host_low);
    send_byte(8'ha5);
    reset_i = 1;
    repeat (3) @(posedge clock_i);
    serial_select_n_i = 1;
    reset_i = 0;
    repeat (6) @(posedge clock_i);
    transaction(8'hb2, 8'h20, 0, 0, 8'h22, 0, 0, 0);

    /* Properly sweep the symmetric 3/3-cycle point outside the supported envelope.
       Even an all-phase digital pass cannot broaden the 4-cycle setup/hold contract. */
    host_low = 30;
    host_high = 30;
    excluded_failures = 0;
    for (phase = 0; phase < 10; phase = phase + 1) begin
      reset_i = 1;
      serial_select_n_i = 1;
      serial_clock_i = 0;
      repeat (4) @(posedge clock_i);
      reset_i = 0;
      repeat (4) @(posedge clock_i);
      @(posedge clock_i);
      #(phase + 0.001);
      probe_info_timing(8'hc0 + phase[7:0], generated_trial);
      if (!generated_trial) excluded_failures = excluded_failures + 1;
    end
    if (excluded_failures != 0)
      $fatal(1, "3/3-cycle sensitivity probe failed %0d phases", excluded_failures);
    host_low = 10;
    host_high = 10;
    excluded_failures = 0;
    for (phase = 0; phase < 10; phase = phase + 1) begin
      reset_i = 1;
      serial_select_n_i = 1;
      serial_clock_i = 0;
      repeat (4) @(posedge clock_i);
      reset_i = 0;
      repeat (4) @(posedge clock_i);
      @(posedge clock_i);
      #(phase + 0.001);
      probe_info_timing(8'hd0 + phase[7:0], generated_trial);
      if (!generated_trial) excluded_failures = excluded_failures + 1;
    end
    if (excluded_failures == 0)
      $fatal(1, "1/1-cycle excluded probe unexpectedly passed every phase");

    $display("PASS p3.5 serial loader repair: timing, overrun rejection, replay/commit, status, recovery, production paths; 3/3 sensitivity phases=10, excluded 1/1 failures=%0d",
             excluded_failures);
    $finish;
  end
endmodule
