`default_nettype none

module top #(
    parameter integer CLK_HZ                = 50_000_000,
    parameter integer UART_BAUD             = 115_200,
    parameter integer READ_WAIT_CYCLES      = 3,
    parameter integer WRITE_WAIT_CYCLES     = 3,
    parameter integer TEST_ADDR_BITS        = 21,
    parameter integer POWER_ON_RESET_CYCLES = 16
) (
    input  wire        clk50,
    output wire        uart_tx,

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
    localparam integer POR_LIMIT =
        (POWER_ON_RESET_CYCLES <= 0) ? 1 : POWER_ON_RESET_CYCLES;

    reg [31:0] por_count;
    reg        reset_n;
    wire [7:0] sram_dq_lo_out;
    wire [7:0] sram_dq_hi_out;
    wire       sram_dq_lo_drive;
    wire       sram_dq_hi_drive;

    initial begin
        por_count = 32'd0;
        reset_n   = 1'b0;
    end

    always @(posedge clk50) begin
        if (!reset_n) begin
            if (por_count >= (POR_LIMIT[31:0] - 1'b1)) begin
                reset_n <= 1'b1;
            end else begin
                por_count <= por_count + 1'b1;
            end
        end
    end

    assign sram_dq_lo = sram_dq_lo_drive ? sram_dq_lo_out : 8'hzz;
    assign sram_dq_hi = sram_dq_hi_drive ? sram_dq_hi_out : 8'hzz;

    sram_uart_tester_core #(
        .CLK_HZ(CLK_HZ),
        .UART_BAUD(UART_BAUD),
        .READ_WAIT_CYCLES(READ_WAIT_CYCLES),
        .WRITE_WAIT_CYCLES(WRITE_WAIT_CYCLES),
        .TEST_ADDR_BITS(TEST_ADDR_BITS)
    ) tester (
        .clk(clk50),
        .reset_n(reset_n),
        .sram_addr(sram_addr),
        .sram_dq_lo_in(sram_dq_lo),
        .sram_dq_hi_in(sram_dq_hi),
        .sram_dq_lo_out(sram_dq_lo_out),
        .sram_dq_hi_out(sram_dq_hi_out),
        .sram_dq_lo_drive(sram_dq_lo_drive),
        .sram_dq_hi_drive(sram_dq_hi_drive),
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
