`default_nettype none

module uart_tx #(
    parameter integer CLK_HZ = 50_000_000,
    parameter integer BAUD   = 115_200
) (
    input  wire       clk,
    input  wire       reset_n,
    input  wire       start,
    input  wire [7:0] data,
    output reg        tx,
    output reg        busy
);
    localparam integer BIT_TICKS =
        (BAUD <= 0) ? 1 : ((CLK_HZ + (BAUD / 2)) / BAUD);
    localparam integer BIT_LIMIT =
        (BIT_TICKS <= 0) ? 1 : BIT_TICKS;

    reg [31:0] bit_timer;
    reg [3:0]  bit_index;
    reg [9:0]  shifter;

    initial begin
        tx        = 1'b1;
        busy      = 1'b0;
        bit_timer = 32'd0;
        bit_index = 4'd0;
        shifter   = 10'h3ff;
    end

    always @(posedge clk) begin
        if (!reset_n) begin
            tx        <= 1'b1;
            busy      <= 1'b0;
            bit_timer <= 32'd0;
            bit_index <= 4'd0;
            shifter   <= 10'h3ff;
        end else if (!busy) begin
            tx        <= 1'b1;
            bit_timer <= 32'd0;
            bit_index <= 4'd0;

            if (start) begin
                shifter   <= {1'b1, data, 1'b0};
                tx        <= 1'b0;
                busy      <= 1'b1;
                bit_timer <= BIT_LIMIT[31:0] - 1'b1;
            end
        end else if (bit_timer != 32'd0) begin
            bit_timer <= bit_timer - 1'b1;
        end else if (bit_index == 4'd9) begin
            tx        <= 1'b1;
            busy      <= 1'b0;
            bit_index <= 4'd0;
        end else begin
            bit_index <= bit_index + 1'b1;
            tx        <= shifter[bit_index + 1'b1];
            bit_timer <= BIT_LIMIT[31:0] - 1'b1;
        end
    end
endmodule

`default_nettype wire
