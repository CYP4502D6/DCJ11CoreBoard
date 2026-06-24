`default_nettype none

module uart_rx #(
    parameter integer CLK_HZ = 50_000_000,
    parameter integer BAUD   = 115_200
) (
    input  wire       clk,
    input  wire       reset_n,
    input  wire       rx,
    output reg [7:0]  data,
    output reg        valid,
    output reg        framing_error
);
    localparam integer BIT_TICKS =
        (BAUD <= 0) ? 1 : ((CLK_HZ + (BAUD / 2)) / BAUD);
    localparam integer BIT_LIMIT =
        (BIT_TICKS <= 0) ? 1 : BIT_TICKS;
    localparam integer HALF_BIT_TICKS =
        (BIT_LIMIT <= 1) ? 1 : (BIT_LIMIT / 2);

    localparam [1:0] ST_IDLE  = 2'd0;
    localparam [1:0] ST_START = 2'd1;
    localparam [1:0] ST_DATA  = 2'd2;
    localparam [1:0] ST_STOP  = 2'd3;

    reg [1:0]  state;
    reg [31:0] bit_timer;
    reg [2:0]  bit_index;
    reg [7:0]  shifter;
    reg        rx_meta;
    reg        rx_sync;

    initial begin
        data          = 8'h00;
        valid         = 1'b0;
        framing_error = 1'b0;
        state         = ST_IDLE;
        bit_timer     = 32'd0;
        bit_index     = 3'd0;
        shifter       = 8'h00;
        rx_meta       = 1'b1;
        rx_sync       = 1'b1;
    end

    always @(posedge clk) begin
        rx_meta <= rx;
        rx_sync <= rx_meta;
    end

    always @(posedge clk) begin
        valid         <= 1'b0;
        framing_error <= 1'b0;

        if (!reset_n) begin
            data          <= 8'h00;
            state         <= ST_IDLE;
            bit_timer     <= 32'd0;
            bit_index     <= 3'd0;
            shifter       <= 8'h00;
            valid         <= 1'b0;
            framing_error <= 1'b0;
        end else begin
            case (state)
                ST_IDLE: begin
                    bit_timer <= 32'd0;
                    bit_index <= 3'd0;
                    if (!rx_sync) begin
                        bit_timer <= HALF_BIT_TICKS[31:0] - 1'b1;
                        state     <= ST_START;
                    end
                end

                ST_START: begin
                    if (bit_timer != 32'd0) begin
                        bit_timer <= bit_timer - 1'b1;
                    end else if (!rx_sync) begin
                        bit_timer <= BIT_LIMIT[31:0] - 1'b1;
                        bit_index <= 3'd0;
                        state     <= ST_DATA;
                    end else begin
                        state <= ST_IDLE;
                    end
                end

                ST_DATA: begin
                    if (bit_timer != 32'd0) begin
                        bit_timer <= bit_timer - 1'b1;
                    end else begin
                        shifter[bit_index] <= rx_sync;
                        bit_timer <= BIT_LIMIT[31:0] - 1'b1;
                        if (bit_index == 3'd7) begin
                            state <= ST_STOP;
                        end else begin
                            bit_index <= bit_index + 1'b1;
                        end
                    end
                end

                ST_STOP: begin
                    if (bit_timer != 32'd0) begin
                        bit_timer <= bit_timer - 1'b1;
                    end else begin
                        if (rx_sync) begin
                            data  <= shifter;
                            valid <= 1'b1;
                        end else begin
                            framing_error <= 1'b1;
                        end
                        state <= ST_IDLE;
                    end
                end

                default: begin
                    state <= ST_IDLE;
                end
            endcase
        end
    end
endmodule

`default_nettype wire
