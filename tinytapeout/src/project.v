`default_nettype none

module tt_um_leemperor_hardcaml_protemu (
    input  wire [7:0] ui_in,
    output wire [7:0] uo_out,
    input  wire [7:0] uio_in,
    output wire [7:0] uio_out,
    output wire [7:0] uio_oe,
    input  wire       ena,
    input  wire       clk,
    input  wire       rst_n
);

    // Asynchronous assertion prevents a reset edge from leaving pads driven. The
    // internal active-high reset is released only after two rising clock edges.
    reg [1:0] reset_sync;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            reset_sync <= 2'b11;
        else
            reset_sync <= {reset_sync[0], 1'b0};
    end

    wire       core_reset = reset_sync[1];
    wire [7:0] core_pins;
    wire [7:0] core_pin_oe;
    wire [3:0] core_timer;
    wire       core_ready;
    wire       core_busy;
    wire       core_done;
    wire       core_rejected;

    // P0 harness input map:
    //   ui_in[3:0] delay (1..15), ui_in[4] pin-0 value,
    //   ui_in[5] pin-0 output enable, ui_in[6] command valid, ui_in[7] reserved.
    p0_observable observable (
        .clock_i(clk),
        .reset_i(core_reset),
        .enable_i(ena),
        .command_valid_i(ui_in[6]),
        .delay_i(ui_in[3:0]),
        .pin_value_i({7'b0, ui_in[4]}),
        .pin_oe_i({7'b0, ui_in[5]}),
        .pins_o(core_pins),
        .pin_oe_o(core_pin_oe),
        .timer_o(core_timer),
        .ready_o(core_ready),
        .busy_o(core_busy),
        .done_o(core_done),
        .rejected_o(core_rejected)
    );

    // Gate enables at the wrapper boundary for immediate release on reset/disable.
    assign uio_out = (rst_n && ena) ? core_pins : 8'b0;
    assign uio_oe  = {8{rst_n && ena}} & core_pin_oe;
    assign uo_out  = (rst_n && ena && !core_reset) ? {
        core_rejected,
        core_done,
        core_busy,
        core_ready,
        core_timer
    } : 8'b0;

    // P0 does not sample the protocol bank yet, but all wrapper inputs and outputs
    // remain explicit for the Tiny Tapeout interface.
    wire _unused = &{ui_in[7], uio_in, 1'b0};

endmodule

`default_nettype wire
