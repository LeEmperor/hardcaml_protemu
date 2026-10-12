`timescale 1ns/1ps
`default_nettype none

`ifdef BACKEND_SIMULATION
`define BACKEND_ROLE "simulation"
`else
`define BACKEND_ROLE "implementation"
`endif

module p3_memory_backend_tb;
    reg clock_i = 1'b0;
    reg reset_i = 1'b0;
    reg en_i = 1'b1;
    reg engines_idle_i = 1'b1;
    reg load_start_valid_i = 1'b0;
    reg [8:0] load_length_i = 9'b0;
    reg load_write_valid_i = 1'b0;
    reg [8:0] load_address_i = 9'b0;
    reg [15:0] load_data_i = 16'b0;
    reg load_complete_valid_i = 1'b0;
    reg readback_valid_i = 1'b0;
    reg [8:0] readback_address_i = 9'b0;
    reg readback_verify_i = 1'b0;
    reg [15:0] readback_expected_i = 16'b0;
    reg run_valid_i = 1'b0;
    reg execution_halt_i = 1'b0;
    reg fetch_valid_i = 1'b0;
    reg [8:0] fetch_address_i = 9'b0;
    reg [15:0] prog_mem_read_data_i = 16'b0;
    wire prog_mem_enable_o;
    wire prog_mem_write_enable_o;
    wire [7:0] prog_mem_address_o;
    wire [15:0] prog_mem_write_data_o;
    wire load_start_accepted_o, load_start_rejected_o;
    wire load_write_accepted_o, load_write_rejected_o;
    wire load_complete_accepted_o, load_complete_rejected_o;
    wire readback_accepted_o, readback_rejected_o;
    wire run_accepted_o, run_rejected_o;
    wire fetch_accepted_o, fetch_rejected_o;
    wire readback_response_valid_o;
    wire [15:0] readback_response_data_o;
    wire readback_response_match_o;
    wire fetch_completion_valid_o;
    wire [15:0] fetch_completion_data_o;
    wire fetch_response_valid_o;
    wire [15:0] fetch_response_data_o;
    wire halted_o, image_valid_o, load_active_o;
    wire [8:0] image_length_o, words_written_o, words_verified_o;
    wire verification_failed_o, fetch_fault_event_o, fetch_fault_o;
    integer edge_count = 0;

    protemu_program_memory_backend dut (.*);

    task fail;
        input [8*64-1:0] scenario;
        input [8*64-1:0] observation;
        input [31:0] expected;
        input [31:0] actual;
        begin
            $display("FAIL scenario=%0s backend=%0s edge=%0d observation=%0s expected=%0h actual=%0h",
                     scenario, `BACKEND_ROLE, edge_count, observation, expected, actual);
            $fatal(1);
        end
    endtask

    task check1;
        input [8*64-1:0] scenario;
        input [8*64-1:0] observation;
        input actual;
        input expected;
        if (actual !== expected) fail(scenario, observation, expected, actual);
    endtask

    task check16;
        input [8*64-1:0] scenario;
        input [8*64-1:0] observation;
        input [15:0] actual;
        input [15:0] expected;
        if (actual !== expected) fail(scenario, observation, expected, actual);
    endtask

    task clear_requests;
        begin
            load_start_valid_i = 0;
            load_write_valid_i = 0;
            load_complete_valid_i = 0;
            readback_valid_i = 0;
            readback_verify_i = 0;
            run_valid_i = 0;
            execution_halt_i = 0;
            fetch_valid_i = 0;
        end
    endtask

    task tick;
        begin
            #4 clock_i = 1'b1;
            #1;
            edge_count = edge_count + 1;
            #4 clock_i = 1'b0;
            #1;
        end
    endtask

    task reset;
        begin
            clear_requests;
            en_i = 1;
            engines_idle_i = 1;
            reset_i = 1;
            tick;
            reset_i = 0;
            tick;
        end
    endtask

    task start_load;
        input [8:0] length;
        begin
            clear_requests;
            load_length_i = length;
            load_start_valid_i = 1;
            #1;
            check1("load", "load-start accepted", load_start_accepted_o, length > 0 && length <= 256);
            tick;
            clear_requests;
        end
    endtask

    task write_word;
        input [8:0] address;
        input [15:0] data;
        input accepted;
        begin
            clear_requests;
            load_address_i = address;
            load_data_i = data;
            load_write_valid_i = 1;
            #1;
            check1("load", "write accepted", load_write_accepted_o, accepted);
            check1("load", "write memory enable", prog_mem_enable_o, accepted);
            tick;
            clear_requests;
        end
    endtask

    task read_word;
        input [8:0] address;
        input verify;
        input [15:0] expected;
        input accepted;
        begin
            clear_requests;
            readback_address_i = address;
            readback_verify_i = verify;
            readback_expected_i = expected;
            readback_valid_i = 1;
            #1;
            check1("read", "read accepted", readback_accepted_o, accepted);
            check1("read", "read memory enable", prog_mem_enable_o, accepted);
            tick;
            clear_requests;
        end
    endtask

    task expect_read_response;
        input [15:0] expected;
        input matches_expected;
        begin
            tick;
            check1("read", "response valid", readback_response_valid_o, 1);
            check16("read", "response data", readback_response_data_o, expected);
            check1("read", "response match", readback_response_match_o, matches_expected);
            tick;
            check1("read", "held data has no validity", readback_response_valid_o, 0);
        end
    endtask

    task verify_word;
        input [8:0] address;
        input [15:0] expected;
        begin
            read_word(address, 1, expected, 1);
            expect_read_response(expected, 1);
        end
    endtask

    task complete;
        input accepted;
        begin
            clear_requests;
            load_complete_valid_i = 1;
            #1;
            check1("complete", "load-complete accepted", load_complete_accepted_o, accepted);
            tick;
            clear_requests;
        end
    endtask

    task run_core;
        input accepted;
        begin
            clear_requests;
            run_valid_i = 1;
            #1;
            check1("run", "RUN accepted", run_accepted_o, accepted);
            tick;
            clear_requests;
        end
    endtask

    initial begin
        reset;
        run_core(0);

        // Invalid starts preserve the current state and cannot make an image executable.
        start_load(0);
        start_load(257);
        check1("invalid lengths", "image remains invalid", image_valid_o, 0);

        // Sequential coverage rejects missing, duplicate, and out-of-order writes.
        start_load(3);
        write_word(0, 16'h1111, 1);
        write_word(2, 16'h3333, 0);
        write_word(0, 16'haaaa, 0);
        complete(0);
        run_core(0);

        // An interrupted replacement restarts at zero and mismatch blocks completion.
        start_load(2);
        write_word(0, 16'ha55a, 1);
        start_load(2);
        write_word(0, 16'h1357, 1);
        write_word(1, 16'h2468, 1);
        read_word(0, 1, 16'hffff, 1);
        tick;
        check1("mismatch", "response valid", readback_response_valid_o, 1);
        check1("mismatch", "response mismatch", readback_response_match_o, 0);
        check1("mismatch", "failure latched", verification_failed_o, 1);
        complete(0);

        // A fresh complete write/readback sequence authorizes RUN.
        start_load(3);
        write_word(0, 16'h0000, 1);
        write_word(1, 16'h1357, 1);
        write_word(2, 16'hffff, 1);
        verify_word(0, 16'h0000);
        verify_word(1, 16'h1357);
        verify_word(2, 16'hffff);
        complete(1);
        check1("complete", "image valid", image_valid_o, 1);

        read_word(1, 0, 0, 1);
        expect_read_response(16'h1357, 0);
        read_word(3, 0, 0, 0);
        tick;
        check1("bounds", "rejected read has no response", readback_response_valid_o, 0);

        run_core(1);
        clear_requests;
        fetch_address_i = 1;
        fetch_valid_i = 1;
        load_start_valid_i = 1;
        load_write_valid_i = 1;
        readback_valid_i = 1;
        load_complete_valid_i = 1;
        run_valid_i = 1;
        #1;
        check1("live rejection", "fetch accepted", fetch_accepted_o, 1);
        check1("live rejection", "load-start rejected", load_start_rejected_o, 1);
        check1("live rejection", "write rejected", load_write_rejected_o, 1);
        check1("live rejection", "read rejected", readback_rejected_o, 1);
        tick;
        clear_requests;
        tick;
        check1("live rejection", "fetch response valid", fetch_response_valid_o, 1);
        check16("live rejection", "fetch response data", fetch_response_data_o, 16'h1357);
        tick;
        check1("live rejection", "held fetch data invalid", fetch_response_valid_o, 0);

        // Legal final image address works; first out-of-image address faults before RAM.
        fetch_address_i = 2;
        fetch_valid_i = 1;
        #1;
        check1("bounds", "final fetch accepted", fetch_accepted_o, 1);
        tick;
        clear_requests;
        tick;
        check16("bounds", "final fetch data", fetch_response_data_o, 16'hffff);
        fetch_address_i = 3;
        fetch_valid_i = 1;
        #1;
        check1("bounds", "out-of-image fetch rejected", fetch_rejected_o, 1);
        check1("bounds", "out-of-image read suppressed", prog_mem_enable_o, 0);
        tick;
        clear_requests;
        check1("bounds", "fetch fault latched", fetch_fault_o, 1);

        // Busy engines reject every halted host class, including a valid prior image.
        engines_idle_i = 0;
        load_start_valid_i = 1;
        load_length_i = 1;
        load_write_valid_i = 1;
        readback_valid_i = 1;
        load_complete_valid_i = 1;
        run_valid_i = 1;
        #1;
        check1("engine busy", "load-start rejected", load_start_rejected_o, 1);
        check1("engine busy", "RUN rejected", run_rejected_o, 1);
        check1("engine busy", "memory disabled", prog_mem_enable_o, 0);
        tick;
        clear_requests;
        engines_idle_i = 1;

        // A shorter replacement invalidates immediately and cannot expose the old tail.
        start_load(1);
        check1("replacement", "old image invalidated", image_valid_o, 0);
        write_word(0, 16'hbeef, 1);
        verify_word(0, 16'hbeef);
        complete(1);
        run_core(1);
        fetch_address_i = 1;
        fetch_valid_i = 1;
        #1;
        check1("replacement", "old tail rejected", fetch_rejected_o, 1);
        tick;
        clear_requests;

        // Disable and reset cancel pending ownership; held or unwritten data stays invalid.
        reset;
        start_load(1);
        write_word(0, 16'hcafe, 1);
        verify_word(0, 16'hcafe);
        complete(1);
        run_core(1);
        fetch_address_i = 0;
        fetch_valid_i = 1;
        tick;
        clear_requests;
        en_i = 0;
        tick;
        en_i = 1;
        check1("disable cancellation", "stale fetch invalid", fetch_response_valid_o, 0);
        check1("disable cancellation", "image preserved", image_valid_o, 1);
        run_core(1);
        fetch_address_i = 0;
        fetch_valid_i = 1;
        tick;
        clear_requests;
        execution_halt_i = 1;
        tick;
        clear_requests;
        check1("halt cancellation", "stale fetch invalid", fetch_response_valid_o, 0);
        check1("halt cancellation", "halted", halted_o, 1);

        $display("PASS P3.1b emitted %0s directed acceptance", `BACKEND_ROLE);
        $finish;
    end
endmodule

`default_nettype wire
