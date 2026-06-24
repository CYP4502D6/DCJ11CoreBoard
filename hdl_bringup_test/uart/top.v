`default_nettype none

module top #(
    parameter integer CLK_HZ                = 50_000_000,
    parameter integer BAUD                  = 115_200,
    parameter integer HELLO_INTERVAL_CYCLES = CLK_HZ,
    parameter integer POWER_ON_RESET_CYCLES = 16
) (
    input  wire clk50,
    input  wire uart_rx,
    output wire uart_tx,
    output wire uart_hello_done,
    output wire uart_error
);
    localparam integer POR_LIMIT =
        (POWER_ON_RESET_CYCLES <= 0) ? 1 : POWER_ON_RESET_CYCLES;

    reg [31:0] por_count;
    reg        reset_n;
    wire       line_overflow;
    wire       rx_framing_error;

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

    assign uart_error = line_overflow | rx_framing_error;

    uart_hello_echo_core #(
        .CLK_HZ(CLK_HZ),
        .BAUD(BAUD),
        .HELLO_INTERVAL_CYCLES(HELLO_INTERVAL_CYCLES),
        .LINE_BUFFER_SIZE(128)
    ) core (
        .clk(clk50),
        .reset_n(reset_n),
        .uart_rx_pin(uart_rx),
        .uart_tx_pin(uart_tx),
        .hello_done(uart_hello_done),
        .line_overflow(line_overflow),
        .rx_framing_error(rx_framing_error)
    );
endmodule

`default_nettype wire
