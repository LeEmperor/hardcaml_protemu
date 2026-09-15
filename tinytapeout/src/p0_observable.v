module p0_observable (
    clock_i,
    reset_i,
    enable_i,
    command_valid_i,
    delay_i,
    pin_value_i,
    pin_oe_i,
    pins_o,
    pin_oe_o,
    timer_o,
    ready_o,
    busy_o,
    done_o,
    rejected_o
);

    input clock_i;
    input reset_i;
    input enable_i;
    input command_valid_i;
    input [3:0] delay_i;
    input [7:0] pin_value_i;
    input [7:0] pin_oe_i;
    output [7:0] pins_o;
    output [7:0] pin_oe_o;
    output [3:0] timer_o;
    output ready_o;
    output busy_o;
    output done_o;
    output rejected_o;

    wire signal_const;
    wire signal_const_1;
    wire signal_mux;
    wire signal_mux_1;
    wire signal_mux_2;
    wire signal_mux_3;
    wire signal_wire;
    reg reg_rejected;
    wire signal_mux_4;
    wire signal_mux_5;
    wire signal_mux_6;
    wire signal_wire_1;
    reg reg_done_;
    wire signal_not;
    wire signal_and;
    wire [7:0] signal_const_6;
    wire [7:0] signal_wire_2;
    wire [7:0] signal_mux_7;
    wire [7:0] signal_mux_8;
    wire [7:0] signal_mux_9;
    wire [7:0] signal_mux_10;
    wire [7:0] signal_wire_3;
    reg [7:0] reg_pending_pin_oe;
    wire [7:0] signal_mux_11;
    wire [7:0] signal_mux_12;
    wire [7:0] signal_mux_13;
    wire [7:0] signal_wire_4;
    reg [7:0] reg_pin_oe;
    wire [7:0] signal_wire_5;
    wire [7:0] signal_mux_14;
    wire [7:0] signal_mux_15;
    wire [7:0] signal_mux_16;
    wire [7:0] signal_mux_17;
    wire [7:0] signal_wire_6;
    reg [7:0] reg_pending_pin_value;
    wire [7:0] signal_mux_18;
    wire [3:0] signal_const_15;
    wire [3:0] signal_const_16;
    wire signal_wire_7;
    wire signal_wire_8;
    wire [3:0] signal_sub;
    wire [3:0] signal_mux_19;
    wire [3:0] signal_mux_20;
    wire [3:0] signal_mux_21;
    wire [3:0] signal_mux_22;
    wire [3:0] signal_mux_23;
    wire [3:0] signal_wire_9;
    reg [3:0] reg_timer;
    wire signal_eq;
    wire signal_mux_24;
    wire [3:0] signal_wire_10;
    wire signal_eq_1;
    wire signal_mux_25;
    wire signal_not_1;
    wire signal_wire_11;
    wire signal_and_1;
    wire signal_mux_26;
    wire signal_mux_27;
    wire signal_mux_28;
    wire signal_wire_12;
    reg reg_busy;
    wire [7:0] signal_mux_29;
    wire signal_wire_13;
    wire signal_not_2;
    wire [7:0] signal_mux_30;
    wire [7:0] signal_wire_14;
    reg [7:0] reg_pins;
    assign signal_const = 1'b0;
    assign signal_const_1 = 1'b1;
    assign signal_mux = signal_eq_1 ? signal_const_1 : signal_const;
    assign signal_mux_1 = signal_and_1 ? signal_mux : signal_const;
    assign signal_mux_2 = reg_busy ? signal_const : signal_mux_1;
    assign signal_mux_3 = signal_not_2 ? signal_const : signal_mux_2;
    assign signal_wire = signal_mux_3;
    always @(posedge signal_wire_8) begin
        if (signal_wire_7)
            reg_rejected <= signal_const;
        else
            reg_rejected <= signal_wire;
    end
    assign signal_mux_4 = signal_eq ? signal_const_1 : signal_const;
    assign signal_mux_5 = reg_busy ? signal_mux_4 : signal_const;
    assign signal_mux_6 = signal_not_2 ? signal_const : signal_mux_5;
    assign signal_wire_1 = signal_mux_6;
    always @(posedge signal_wire_8) begin
        if (signal_wire_7)
            reg_done_ <= signal_const;
        else
            reg_done_ <= signal_wire_1;
    end
    assign signal_not = ~ reg_busy;
    assign signal_and = signal_wire_13 & signal_not;
    assign signal_const_6 = 8'b00000000;
    assign signal_wire_2 = pin_oe_i;
    assign signal_mux_7 = signal_eq_1 ? reg_pending_pin_oe : signal_wire_2;
    assign signal_mux_8 = signal_and_1 ? signal_mux_7 : reg_pending_pin_oe;
    assign signal_mux_9 = reg_busy ? reg_pending_pin_oe : signal_mux_8;
    assign signal_mux_10 = signal_not_2 ? reg_pending_pin_oe : signal_mux_9;
    assign signal_wire_3 = signal_mux_10;
    always @(posedge signal_wire_8) begin
        if (signal_wire_7)
            reg_pending_pin_oe <= signal_const_6;
        else
            reg_pending_pin_oe <= signal_wire_3;
    end
    assign signal_mux_11 = signal_eq ? reg_pending_pin_oe : reg_pin_oe;
    assign signal_mux_12 = reg_busy ? signal_mux_11 : reg_pin_oe;
    assign signal_mux_13 = signal_not_2 ? signal_const_6 : signal_mux_12;
    assign signal_wire_4 = signal_mux_13;
    always @(posedge signal_wire_8) begin
        if (signal_wire_7)
            reg_pin_oe <= signal_const_6;
        else
            reg_pin_oe <= signal_wire_4;
    end
    assign signal_wire_5 = pin_value_i;
    assign signal_mux_14 = signal_eq_1 ? reg_pending_pin_value : signal_wire_5;
    assign signal_mux_15 = signal_and_1 ? signal_mux_14 : reg_pending_pin_value;
    assign signal_mux_16 = reg_busy ? reg_pending_pin_value : signal_mux_15;
    assign signal_mux_17 = signal_not_2 ? reg_pending_pin_value : signal_mux_16;
    assign signal_wire_6 = signal_mux_17;
    always @(posedge signal_wire_8) begin
        if (signal_wire_7)
            reg_pending_pin_value <= signal_const_6;
        else
            reg_pending_pin_value <= signal_wire_6;
    end
    assign signal_mux_18 = signal_eq ? reg_pending_pin_value : reg_pins;
    assign signal_const_15 = 4'b0001;
    assign signal_const_16 = 4'b0000;
    assign signal_wire_7 = reset_i;
    assign signal_wire_8 = clock_i;
    assign signal_sub = reg_timer - signal_const_15;
    assign signal_mux_19 = signal_eq ? signal_const_16 : signal_sub;
    assign signal_mux_20 = signal_eq_1 ? reg_timer : signal_wire_10;
    assign signal_mux_21 = signal_and_1 ? signal_mux_20 : reg_timer;
    assign signal_mux_22 = reg_busy ? signal_mux_19 : signal_mux_21;
    assign signal_mux_23 = signal_not_2 ? signal_const_16 : signal_mux_22;
    assign signal_wire_9 = signal_mux_23;
    always @(posedge signal_wire_8) begin
        if (signal_wire_7)
            reg_timer <= signal_const_16;
        else
            reg_timer <= signal_wire_9;
    end
    assign signal_eq = reg_timer == signal_const_15;
    assign signal_mux_24 = signal_eq ? signal_const : reg_busy;
    assign signal_wire_10 = delay_i;
    assign signal_eq_1 = signal_wire_10 == signal_const_16;
    assign signal_mux_25 = signal_eq_1 ? reg_busy : signal_const_1;
    assign signal_not_1 = ~ reg_busy;
    assign signal_wire_11 = command_valid_i;
    assign signal_and_1 = signal_wire_11 & signal_not_1;
    assign signal_mux_26 = signal_and_1 ? signal_mux_25 : reg_busy;
    assign signal_mux_27 = reg_busy ? signal_mux_24 : signal_mux_26;
    assign signal_mux_28 = signal_not_2 ? signal_const : signal_mux_27;
    assign signal_wire_12 = signal_mux_28;
    always @(posedge signal_wire_8) begin
        if (signal_wire_7)
            reg_busy <= signal_const;
        else
            reg_busy <= signal_wire_12;
    end
    assign signal_mux_29 = reg_busy ? signal_mux_18 : reg_pins;
    assign signal_wire_13 = enable_i;
    assign signal_not_2 = ~ signal_wire_13;
    assign signal_mux_30 = signal_not_2 ? signal_const_6 : signal_mux_29;
    assign signal_wire_14 = signal_mux_30;
    always @(posedge signal_wire_8) begin
        if (signal_wire_7)
            reg_pins <= signal_const_6;
        else
            reg_pins <= signal_wire_14;
    end
    assign pins_o = reg_pins;
    assign pin_oe_o = reg_pin_oe;
    assign timer_o = reg_timer;
    assign ready_o = signal_and;
    assign busy_o = reg_busy;
    assign done_o = reg_done_;
    assign rejected_o = reg_rejected;

endmodule
