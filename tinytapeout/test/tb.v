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

    tt_um_leemperor_hardcaml_protemu dut (
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

    initial begin
        // Assert reset asynchronously and verify the wrapper releases every pad.
        #1 rst_n = 1'b0;
        #1;
        check8("reset output enables", uio_oe, 8'h00);
        check8("reset output values", uio_out, 8'h00);
        tick;
        rst_n = 1'b1;
        tick;
        check8("reset held through first release edge", uo_out, 8'h00);
        tick;
        check8("ready after synchronized reset release", uo_out, 8'h10);

        // Delay zero is rejected and never starts the timer.
        ui_in = 8'b0100_0000;
        tick;
        check8("zero-delay rejection", uo_out, 8'h90);
        ui_in = 8'b0;
        tick;
        check8("rejection pulse clears", uo_out, 8'h10);

        // Accept pin-0 value=1, oe=1 with delay=3 at edge k.
        ui_in = 8'b0111_0011;
        tick;
        check8("accepted command status", uo_out, 8'h23);
        check8("pins unchanged at k", uio_out, 8'h00);
        check8("enables unchanged at k", uio_oe, 8'h00);
        ui_in = 8'b0;
        tick;
        check8("timer k+1", uo_out, 8'h22);
        tick;
        check8("timer k+2", uo_out, 8'h21);
        tick;
        check8("timer k+3 and done", uo_out, 8'h50);
        check8("pin value committed", uio_out, 8'h01);
        check8("pin enable committed", uio_oe, 8'h01);
        tick;
        check8("done pulse clears", uo_out, 8'h10);

        // Disable releases pads immediately and clears active state on the next edge.
        ui_in = 8'b0111_0100;
        tick;
        check8("second command active", uo_out, 8'h24);
        ena = 1'b0;
        #1;
        check8("disable immediately releases pins", uio_oe, 8'h00);
        check8("disable forces output low", uio_out, 8'h00);
        check8("disable masks status", uo_out, 8'h00);
        tick;
        check8("disable cancels active timer", uo_out, 8'h00);

        // Reset also releases pads asynchronously after a committed drive.
        ena = 1'b1;
        ui_in = 8'b0111_0001;
        tick;
        ui_in = 8'b0;
        tick;
        check8("one-cycle command drives pin", uio_oe, 8'h01);
        rst_n = 1'b0;
        #1;
        check8("asynchronous reset release", uio_oe, 8'h00);

        $display("PASS p0 wrapper reset/disable/pin/timer trace");
        $finish;
    end
endmodule

`default_nettype wire
