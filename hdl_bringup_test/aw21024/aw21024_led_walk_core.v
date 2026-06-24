`default_nettype none

module aw21024_led_walk_core #(
    parameter integer CLK_HZ                  = 50_000_000,
    parameter integer STEP_HZ                 = 4,
    parameter integer I2C_HZ                  = 100_000,
    parameter integer POWERUP_DELAY_CYCLES    = 100_000,
    parameter integer SOFT_RESET_DELAY_CYCLES = 100_000,
    parameter integer POWER_ON_RESET_CYCLES   = 16,
    parameter [7:0]   GLOBAL_CURRENT          = 8'h0f,
    parameter [7:0]   CHANNEL_CURRENT         = 8'hff,
    parameter [7:0]   LED_ON_BRIGHTNESS       = 8'hff
) (
    input  wire        clk50,
    input  wire        i2c_sda_in,
    output wire        i2c_scl_drive_low,
    output wire        i2c_sda_drive_low,
    output wire        led_addr_en,
    output wire        led_data_en,
    output wire [21:0] debug_addr_value,
    output wire [15:0] debug_data_value,
    output wire        panel_ready,
    output wire        i2c_ack_error
);
    localparam integer POR_LIMIT =
        (POWER_ON_RESET_CYCLES <= 0) ? 1 : POWER_ON_RESET_CYCLES;
    localparam integer STEP_DIVIDER =
        (STEP_HZ <= 0) ? CLK_HZ : (CLK_HZ / STEP_HZ);
    localparam integer STEP_LIMIT =
        (STEP_DIVIDER <= 0) ? 1 : STEP_DIVIDER;

    reg [31:0] por_count;
    reg        reset_n;
    reg [31:0] step_count;
    reg [4:0]  addr_index;
    reg [3:0]  data_index;
    reg [21:0] addr_value;
    reg [15:0] data_value;

    initial begin
        por_count  = 32'd0;
        reset_n    = 1'b0;
        step_count = 32'd0;
        addr_index = 5'd0;
        data_index = 4'd0;
        addr_value = 22'h000001;
        data_value = 16'h0001;
    end

    assign debug_addr_value = addr_value;
    assign debug_data_value = data_value;

    always @(posedge clk50) begin
        if (!reset_n) begin
            if (por_count >= (POR_LIMIT[31:0] - 1'b1)) begin
                reset_n <= 1'b1;
            end else begin
                por_count <= por_count + 1'b1;
            end
        end
    end

    always @(posedge clk50) begin
        if (!reset_n) begin
            step_count <= 32'd0;
            addr_index <= 5'd0;
            data_index <= 4'd0;
            addr_value <= 22'h000001;
            data_value <= 16'h0001;
        end else if (!panel_ready) begin
            step_count <= 32'd0;
            addr_index <= 5'd0;
            data_index <= 4'd0;
            addr_value <= 22'h000001;
            data_value <= 16'h0001;
        end else if (step_count >= (STEP_LIMIT[31:0] - 1'b1)) begin
            step_count <= 32'd0;

            if (addr_index == 5'd21) begin
                addr_index <= 5'd0;
                addr_value <= 22'h000001;
            end else begin
                addr_index <= addr_index + 1'b1;
                addr_value <= (22'h000001 << (addr_index + 1'b1));
            end

            if (data_index == 4'd15) begin
                data_index <= 4'd0;
                data_value <= 16'h0001;
            end else begin
                data_index <= data_index + 1'b1;
                data_value <= (16'h0001 << (data_index + 1'b1));
            end
        end else begin
            step_count <= step_count + 1'b1;
        end
    end

    aw21024_panel_driver #(
        .CLK_HZ(CLK_HZ),
        .I2C_HZ(I2C_HZ),
        .POWERUP_DELAY_CYCLES(POWERUP_DELAY_CYCLES),
        .SOFT_RESET_DELAY_CYCLES(SOFT_RESET_DELAY_CYCLES),
        .ADDR_DEVICE_ADDR(7'h30),
        .DATA_DEVICE_ADDR(7'h31),
        .GLOBAL_CURRENT(GLOBAL_CURRENT),
        .CHANNEL_CURRENT(CHANNEL_CURRENT),
        .LED_ON_BRIGHTNESS(LED_ON_BRIGHTNESS),
        .LED_OFF_BRIGHTNESS(8'h00)
    ) panel (
        .clk(clk50),
        .reset_n(reset_n),
        .addr_value(addr_value),
        .data_value(data_value),
        .i2c_sda_in(i2c_sda_in),
        .i2c_scl_drive_low(i2c_scl_drive_low),
        .i2c_sda_drive_low(i2c_sda_drive_low),
        .addr_en(led_addr_en),
        .data_en(led_data_en),
        .ready(panel_ready),
        .i2c_ack_error(i2c_ack_error)
    );
endmodule

`default_nettype wire
