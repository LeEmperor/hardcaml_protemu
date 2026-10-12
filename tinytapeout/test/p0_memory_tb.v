`timescale 1ns/1ps
`default_nettype none

module tb;
    reg        clk = 1'b0;
    reg        rst_n = 1'b1;
    reg        ena = 1'b1;
    reg  [7:0] ui_in = 8'b0;
    reg  [7:0] uio_in = 8'b0;
    wire [7:0] uo_out;
    wire [7:0] uio_out;
    wire [7:0] uio_oe;

    tt_um_leemperor_hardcaml_protemu_memory dut (
        .ui_in(ui_in),
        .uo_out(uo_out),
        .uio_in(uio_in),
        .uio_out(uio_out),
        .uio_oe(uio_oe),
        .ena(ena),
        .clk(clk),
        .rst_n(rst_n)
    );

    task tick;
        begin
            #5 clk = 1'b1;
            #1;
            #4 clk = 1'b0;
        end
    endtask

    task request;
        input [2:0] opcode;
        input [7:0] address;
        begin
            ui_in = address;
            uio_in = {opcode, 5'b0};
            tick;
            ui_in = 8'b0;
            uio_in = 8'b0;
        end
    endtask

    task stage_word;
        input [15:0] data;
        begin
            request(7, data[15:8]);
            request(6, data[7:0]);
        end
    endtask

    task check8;
        input [255:0] label;
        input [7:0] actual;
        input [7:0] expected;
        begin
            if (actual !== expected) begin
                $display("FAIL %0s: got %02x expected %02x", label, actual, expected);
                $fatal(1);
            end
        end
    endtask

    task verify_word;
        input [7:0] address;
        input [15:0] data;
        begin
            stage_word(data);
            request(3, address);
            tick;
            check8("verification response high byte", uo_out, data[15:8]);
            check8("verification response low byte", uio_out, data[7:0]);
            check8("verification response enables", uio_oe, 8'hff);
            tick;
            check8("verification response is one cycle", uio_oe, 8'h00);
        end
    endtask

    initial begin
        // Consumer reset invalidates metadata; it makes no assertion about RAM contents.
        #1 rst_n = 1'b0;
        tick;
        rst_n = 1'b1;
        tick;
        tick;
        check8("released reset has no response", uio_oe, 8'h00);

        // Declare three words and write each as a complete 16-bit {data, ~data} value.
        request(1, 8'd3);
        stage_word(16'h12ed);
        request(2, 8'd0);
        stage_word(16'ha55a);
        request(2, 8'd1);
        stage_word(16'hf00f);
        request(2, 8'd2);

        // Post-write output is intentionally ignored. Fresh reads verify all words.
        verify_word(8'd0, 16'h12ed);
        verify_word(8'd1, 16'ha55a);
        verify_word(8'd2, 16'hf00f);
        request(4, 8'd0);
        tick;
        if (!uo_out[5]) begin
            $display("FAIL completed image is not valid");
            $fatal(1);
        end

        // Ordinary readback has exactly one-cycle validity and survives a disabled RAM
        // cycle because the primitive's registered read output holds while disabled.
        request(5, 8'd1);
        check8("read request has no response", uio_oe, 8'h00);
        tick;
        check8("readback high byte", uo_out, 8'ha5);
        check8("readback low byte", uio_out, 8'h5a);
        check8("readback enables", uio_oe, 8'hff);
        tick;
        check8("held data is not consumed twice", uio_oe, 8'h00);

        // Address 4 is physically representable but beyond this three-word image. The
        // consumer rejects it before the RAM and never emits response validity.
        request(5, 8'd4);
        check8("out-of-image read has no response", uio_oe, 8'h00);
        if (!uo_out[1]) begin
            $display("FAIL out-of-image read was not rejected");
            $fatal(1);
        end
        tick;
        check8("rejected read remains without response", uio_oe, 8'h00);

        // Disable gates all access and pads. Re-enable preserves the completed image.
        ena = 1'b0;
        ui_in = 8'd0;
        uio_in = {3'd2, 5'b0};
        #1;
        check8("disable masks status", uo_out, 8'h00);
        check8("disable releases data bus", uio_oe, 8'h00);
        tick;
        ena = 1'b1;
        ui_in = 8'b0;
        uio_in = 8'b0;
        tick;
        request(5, 8'd0);
        tick;
        check8("readback after disable high byte", uo_out, 8'h12);
        check8("readback after disable low byte", uio_out, 8'hed);

        $display("PASS p0.7 whole-word load/readback, validity, bounds, and gating");
        $finish;
    end
endmodule

`default_nettype wire
