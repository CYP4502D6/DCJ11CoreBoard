`default_nettype none

module top #(
    parameter integer CLK_HZ                  = 50_000_000,
    parameter integer UART_BAUD               = 115_200,
    parameter integer READ_WAIT_CYCLES        = 3,
    parameter integer WRITE_WAIT_CYCLES       = 3,
    parameter integer POST_WRITE_DELAY_CYCLES = 250_000
) (
    input  wire       clk50,
    input  wire       reset_n,
    output wire       uart_tx,

    output wire [20:0] sram_addr,
    inout  wire [7:0]  sram_dq_lo,
    inout  wire [7:0]  sram_dq_hi,
    output wire        sram_ce1_n,
    output wire        sram_oe_n,
    output wire        sram_we_lo_n,
    output wire        sram_we_hi_n,

    output wire        test_done,
    output wire        test_error
);
    wire [7:0] dq_lo_out;
    wire [7:0] dq_hi_out;
    wire       dq_lo_drive;
    wire       dq_hi_drive;

    assign sram_dq_lo = dq_lo_drive ? dq_lo_out : 8'hzz;
    assign sram_dq_hi = dq_hi_drive ? dq_hi_out : 8'hzz;

    sram_sparse_trace_core #(
        .CLK_HZ(CLK_HZ),
        .UART_BAUD(UART_BAUD),
        .READ_WAIT_CYCLES(READ_WAIT_CYCLES),
        .WRITE_WAIT_CYCLES(WRITE_WAIT_CYCLES),
        .POST_WRITE_DELAY_CYCLES(POST_WRITE_DELAY_CYCLES)
    ) core (
        .clk(clk50),
        .reset_n(reset_n),
        .sram_addr(sram_addr),
        .sram_dq_lo_in(sram_dq_lo),
        .sram_dq_hi_in(sram_dq_hi),
        .sram_dq_lo_out(dq_lo_out),
        .sram_dq_hi_out(dq_hi_out),
        .sram_dq_lo_drive(dq_lo_drive),
        .sram_dq_hi_drive(dq_hi_drive),
        .sram_ce1_n(sram_ce1_n),
        .sram_oe_n(sram_oe_n),
        .sram_we_lo_n(sram_we_lo_n),
        .sram_we_hi_n(sram_we_hi_n),
        .uart_tx(uart_tx),
        .test_done(test_done),
        .test_error(test_error)
    );
endmodule

`default_nettype wire
