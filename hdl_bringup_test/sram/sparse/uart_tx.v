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
    localparam integer RAW_CLKS_PER_BIT =
        (BAUD <= 0) ? 1 : ((CLK_HZ + (BAUD / 2)) / BAUD);
    localparam integer CLKS_PER_BIT =
        (RAW_CLKS_PER_BIT < 1) ? 1 : RAW_CLKS_PER_BIT;

    localparam [1:0] ST_IDLE  = 2'd0;
    localparam [1:0] ST_START = 2'd1;
    localparam [1:0] ST_DATA  = 2'd2;
    localparam [1:0] ST_STOP  = 2'd3;

    reg [1:0]  state;
    reg [31:0] clk_count;
    reg [2:0]  bit_index;
    reg [7:0]  shift;

    initial begin
        tx        = 1'b1;
        busy      = 1'b0;
        state     = ST_IDLE;
        clk_count = 32'd0;
        bit_index = 3'd0;
        shift     = 8'd0;
    end

    always @(posedge clk) begin
        if (!reset_n) begin
            tx        <= 1'b1;
            busy      <= 1'b0;
            state     <= ST_IDLE;
            clk_count <= 32'd0;
            bit_index <= 3'd0;
            shift     <= 8'd0;
        end else begin
            case (state)
                ST_IDLE: begin
                    tx        <= 1'b1;
                    busy      <= 1'b0;
                    clk_count <= 32'd0;
                    bit_index <= 3'd0;
                    if (start) begin
                        shift <= data;
                        busy  <= 1'b1;
                        tx    <= 1'b0;
                        state <= ST_START;
                    end
                end

                ST_START: begin
                    busy <= 1'b1;
                    tx   <= 1'b0;
                    if (clk_count == (CLKS_PER_BIT - 1)) begin
                        clk_count <= 32'd0;
                        tx        <= shift[0];
                        state     <= ST_DATA;
                    end else begin
                        clk_count <= clk_count + 1'b1;
                    end
                end

                ST_DATA: begin
                    busy <= 1'b1;
                    tx   <= shift[0];
                    if (clk_count == (CLKS_PER_BIT - 1)) begin
                        clk_count <= 32'd0;
                        shift     <= {1'b0, shift[7:1]};
                        if (bit_index == 3'd7) begin
                            bit_index <= 3'd0;
                            tx        <= 1'b1;
                            state     <= ST_STOP;
                        end else begin
                            bit_index <= bit_index + 1'b1;
                        end
                    end else begin
                        clk_count <= clk_count + 1'b1;
                    end
                end

                ST_STOP: begin
                    busy <= 1'b1;
                    tx   <= 1'b1;
                    if (clk_count == (CLKS_PER_BIT - 1)) begin
                        clk_count <= 32'd0;
                        busy      <= 1'b0;
                        state     <= ST_IDLE;
                    end else begin
                        clk_count <= clk_count + 1'b1;
                    end
                end

                default: begin
                    tx        <= 1'b1;
                    busy      <= 1'b0;
                    state     <= ST_IDLE;
                    clk_count <= 32'd0;
                    bit_index <= 3'd0;
                end
            endcase
        end
    end
endmodule

`default_nettype wire
