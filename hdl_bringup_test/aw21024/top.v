`default_nettype none

module top #(
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
    input  wire clk50,
    inout  wire led_i2c_scl,
    inout  wire led_i2c_sda,
    output wire led_addr_en,
    output wire led_data_en,
    output wire led_status_ready,
    output wire led_status_i2c_error
);
    wire i2c_scl_drive_low;
    wire i2c_sda_drive_low;

    assign led_i2c_scl = i2c_scl_drive_low ? 1'b0 : 1'bz;
    assign led_i2c_sda = i2c_sda_drive_low ? 1'b0 : 1'bz;

    aw21024_led_walk_core #(
        .CLK_HZ(CLK_HZ),
        .STEP_HZ(STEP_HZ),
        .I2C_HZ(I2C_HZ),
        .POWERUP_DELAY_CYCLES(POWERUP_DELAY_CYCLES),
        .SOFT_RESET_DELAY_CYCLES(SOFT_RESET_DELAY_CYCLES),
        .POWER_ON_RESET_CYCLES(POWER_ON_RESET_CYCLES),
        .GLOBAL_CURRENT(GLOBAL_CURRENT),
        .CHANNEL_CURRENT(CHANNEL_CURRENT),
        .LED_ON_BRIGHTNESS(LED_ON_BRIGHTNESS)
    ) core (
        .clk50(clk50),
        .i2c_sda_in(led_i2c_sda),
        .i2c_scl_drive_low(i2c_scl_drive_low),
        .i2c_sda_drive_low(i2c_sda_drive_low),
        .led_addr_en(led_addr_en),
        .led_data_en(led_data_en),
        /* verilator lint_off PINCONNECTEMPTY */
        .debug_addr_value(),
        .debug_data_value(),
        /* verilator lint_on PINCONNECTEMPTY */
        .panel_ready(led_status_ready),
        .i2c_ack_error(led_status_i2c_error)
    );
endmodule

`default_nettype wire
