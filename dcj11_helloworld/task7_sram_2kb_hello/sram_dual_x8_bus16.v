`default_nettype none

// Local task7 SRAM bus controller.
// The DQ split interface and CE/OE/WE sequencing follow the board-tested
// sparse trace pattern in ../../sram_uart_sparse_trace/rtl/sram_sparse_trace_core.v.
module sram_dual_x8_bus16 #(
    parameter integer READ_WAIT_CYCLES  = 4,
    parameter integer WRITE_WAIT_CYCLES = 4
) (
    input  wire        clk,
    input  wire        reset_n,

    input  wire        start,
    input  wire        write,
    input  wire [1:0]  byte_en,
    input  wire [21:0] addr,
    input  wire [15:0] wdata,
    output reg  [15:0] rdata,
    output reg         done,
    output wire        busy,

    output reg  [20:0] sram_addr,
    input  wire [7:0]  sram_dq_lo_in,
    input  wire [7:0]  sram_dq_hi_in,
    output reg  [7:0]  sram_dq_lo_out,
    output reg  [7:0]  sram_dq_hi_out,
    output reg         sram_dq_lo_drive,
    output reg         sram_dq_hi_drive,
    output reg         sram_ce1_n,
    output reg         sram_oe_n,
    output reg         sram_we_lo_n,
    output reg         sram_we_hi_n
);
    localparam [1:0] ST_IDLE = 2'd0;
    localparam [1:0] ST_WAIT = 2'd1;
    localparam [1:0] ST_END  = 2'd2;

    localparam integer READ_LIMIT =
        (READ_WAIT_CYCLES <= 0) ? 1 : READ_WAIT_CYCLES;
    localparam integer WRITE_LIMIT =
        (WRITE_WAIT_CYCLES <= 0) ? 1 : WRITE_WAIT_CYCLES;

    reg [1:0]  state;
    reg        latched_write;
    reg [1:0]  latched_byte_en;
    reg [31:0] wait_count;

    assign busy = (state != ST_IDLE);

    initial begin
        state             = ST_IDLE;
        latched_write     = 1'b0;
        latched_byte_en   = 2'b00;
        wait_count        = 32'd0;
        rdata             = 16'h0000;
        done              = 1'b0;
        sram_addr         = 21'h000000;
        sram_dq_lo_out    = 8'h00;
        sram_dq_hi_out    = 8'h00;
        sram_dq_lo_drive  = 1'b0;
        sram_dq_hi_drive  = 1'b0;
        sram_ce1_n        = 1'b1;
        sram_oe_n         = 1'b1;
        sram_we_lo_n      = 1'b1;
        sram_we_hi_n      = 1'b1;
    end

    always @(posedge clk) begin
        done <= 1'b0;

        if (!reset_n) begin
            state             <= ST_IDLE;
            latched_write     <= 1'b0;
            latched_byte_en   <= 2'b00;
            wait_count        <= 32'd0;
            rdata             <= 16'h0000;
            sram_addr         <= 21'h000000;
            sram_dq_lo_out    <= 8'h00;
            sram_dq_hi_out    <= 8'h00;
            sram_dq_lo_drive  <= 1'b0;
            sram_dq_hi_drive  <= 1'b0;
            sram_ce1_n        <= 1'b1;
            sram_oe_n         <= 1'b1;
            sram_we_lo_n      <= 1'b1;
            sram_we_hi_n      <= 1'b1;
        end else begin
            case (state)
                ST_IDLE: begin
                    sram_ce1_n       <= 1'b1;
                    sram_oe_n        <= 1'b1;
                    sram_we_lo_n     <= 1'b1;
                    sram_we_hi_n     <= 1'b1;
                    sram_dq_lo_drive <= 1'b0;
                    sram_dq_hi_drive <= 1'b0;

                    if (start) begin
                        sram_addr       <= addr[21:1];
                        latched_write   <= write;
                        latched_byte_en <= byte_en;
                        wait_count      <= 32'd0;

                        if (write) begin
                            sram_ce1_n       <= ~(|byte_en);
                            sram_oe_n        <= 1'b1;
                            sram_we_lo_n     <= ~byte_en[0];
                            sram_we_hi_n     <= ~byte_en[1];
                            sram_dq_lo_drive <= byte_en[0];
                            sram_dq_hi_drive <= byte_en[1];
                            sram_dq_lo_out   <= wdata[7:0];
                            sram_dq_hi_out   <= wdata[15:8];
                        end else begin
                            sram_ce1_n       <= 1'b0;
                            sram_oe_n        <= 1'b0;
                            sram_we_lo_n     <= 1'b1;
                            sram_we_hi_n     <= 1'b1;
                            sram_dq_lo_drive <= 1'b0;
                            sram_dq_hi_drive <= 1'b0;
                        end

                        state <= ST_WAIT;
                    end
                end

                ST_WAIT: begin
                    if (wait_count >= (((latched_write ? WRITE_LIMIT : READ_LIMIT) & 32'hffff_ffff) - 1'b1)) begin
                        state <= ST_END;
                    end else begin
                        wait_count <= wait_count + 1'b1;
                    end
                end

                ST_END: begin
                    if (!latched_write) begin
                        rdata <= {sram_dq_hi_in, sram_dq_lo_in};
                    end

                    sram_ce1_n       <= 1'b1;
                    sram_oe_n        <= 1'b1;
                    sram_we_lo_n     <= 1'b1;
                    sram_we_hi_n     <= 1'b1;
                    sram_dq_lo_drive <= 1'b0;
                    sram_dq_hi_drive <= 1'b0;
                    done             <= 1'b1;
                    state            <= ST_IDLE;
                end

                default: begin
                    state <= ST_IDLE;
                end
            endcase
        end
    end

    /* verilator lint_off UNUSEDSIGNAL */
    wire unused_addr_bit0 = addr[0];
    wire unused_latched_byte_en = &latched_byte_en;
    /* verilator lint_on UNUSEDSIGNAL */
endmodule

`default_nettype wire
