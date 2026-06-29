`default_nettype none

module dcj11_bus_frontend #(
    parameter integer READ_WAIT_CYCLES = 0
) (
    input  wire        clk,
    input  wire        reset_n,
    input  wire        init_n,
    input  wire        preload_done,

    input  wire [21:0] raw_addr,
    input  wire [3:0]  raw_aio,
    input  wire [1:0]  raw_bs,
    input  wire        ale_n,
    input  wire        sctl_n,
    input  wire        bufctl_n,

    input  wire [7:0]  sram_dq_lo,
    input  wire [7:0]  sram_dq_hi,

    output wire [15:0] dal_out,
    output wire        dal_oe,
    output wire        cont_n,

    output wire        sram_owns,
    output wire [20:0] sram_addr,
    output wire        sram_ce1_n,
    output wire        sram_oe_n,
    output wire        sram_we_lo_n,
    output wire        sram_we_hi_n
);
    localparam [3:0] AIO_NONIO        = 4'b1111;
    localparam [3:0] AIO_GPREAD       = 4'b1110;
    localparam [3:0] AIO_INTACK       = 4'b1101;
    localparam [3:0] AIO_IREADRQ      = 4'b1100;
    localparam [3:0] AIO_RMWNBL       = 4'b1011;
    localparam [3:0] AIO_RMWBL        = 4'b1010;
    localparam [3:0] AIO_DREAD        = 4'b1001;
    localparam [3:0] AIO_IREADDM      = 4'b1000;
    localparam [3:0] AIO_ODTREAD      = 4'b0110;
    localparam [3:0] AIO_GPWRITE      = 4'b0101;
    localparam [3:0] AIO_BUSBYTEWRITE = 4'b0011;
    localparam [3:0] AIO_BUSWORDWRITE = 4'b0001;

    localparam [2:0] ST_IDLE      = 3'd0;
    localparam [2:0] ST_RAM_READ  = 3'd1;
    localparam [2:0] ST_RAM_WRITE = 3'd2;
    localparam [2:0] ST_IO        = 3'd3;
    localparam [2:0] ST_CONTROL   = 3'd4;
    localparam [2:0] ST_NXM       = 3'd5;

    reg [2:0]  state;
    reg [21:0] cycle_addr;
    reg [3:0]  cycle_aio;
    reg [1:0]  cycle_bs;
    reg        read_seq;
    reg        read_seq_meta;
    reg        read_seq_sync;
    reg        read_seq_seen;
    reg        read_seq_ready;
    reg        read_wait_active;
    reg [31:0] read_wait_count;

    wire raw_ram_space = (raw_addr[21:16] == 6'b000000) &&
        (raw_addr[15:0] < 16'o160000);
    wire raw_io_page = (raw_addr[15:0] >= 16'o160000);
    wire raw_read = is_read_aio(raw_aio);
    wire raw_write = is_write_aio(raw_aio);
    wire raw_control =
        (raw_aio == AIO_NONIO) ||
        (raw_aio == AIO_GPREAD) ||
        (raw_aio == AIO_GPWRITE) ||
        (raw_aio == AIO_INTACK);

    localparam integer READ_WAIT_LIMIT =
        (READ_WAIT_CYCLES <= 0) ? 0 : READ_WAIT_CYCLES;

    wire ram_read_active = (state == ST_RAM_READ);
    wire ram_read_wait_enabled = (READ_WAIT_LIMIT != 0);
    wire ram_read_ready =
        ram_read_active &&
        (!ram_read_wait_enabled ||
         ((read_seq == read_seq_ready) && !read_wait_active));
    wire ram_read_wait = ram_read_wait_enabled && ram_read_active && !ram_read_ready;

    initial begin
        state            = ST_IDLE;
        cycle_addr       = 22'h000000;
        cycle_aio        = AIO_NONIO;
        cycle_bs         = 2'b00;
        read_seq         = 1'b0;
        read_seq_meta    = 1'b0;
        read_seq_sync    = 1'b0;
        read_seq_seen    = 1'b0;
        read_seq_ready   = 1'b0;
        read_wait_active = 1'b0;
        read_wait_count  = 32'd0;
    end

    always @(negedge ale_n or negedge reset_n or negedge init_n) begin
        if (!reset_n || !init_n) begin
            state      <= ST_IDLE;
            cycle_addr <= 22'h000000;
            cycle_aio  <= AIO_NONIO;
            cycle_bs   <= 2'b00;
            read_seq   <= 1'b0;
        end else begin
            cycle_addr <= raw_addr;
            cycle_aio  <= raw_aio;
            cycle_bs   <= raw_bs;

            if (!preload_done) begin
                state <= ST_IDLE;
            end else if (raw_ram_space && raw_read) begin
                state <= ST_RAM_READ;
                read_seq <= ~read_seq;
            end else if (raw_ram_space && raw_write) begin
                state <= ST_RAM_WRITE;
            end else if (raw_io_page) begin
                state <= ST_IO;
            end else if (raw_control) begin
                state <= ST_CONTROL;
            end else begin
                state <= ST_NXM;
            end
        end
    end

    always @(posedge clk or negedge reset_n or negedge init_n) begin
        if (!reset_n || !init_n) begin
            read_seq_meta    <= 1'b0;
            read_seq_sync    <= 1'b0;
            read_seq_seen    <= 1'b0;
            read_seq_ready   <= 1'b0;
            read_wait_active <= 1'b0;
            read_wait_count  <= 32'd0;
        end else begin
            read_seq_meta <= read_seq;
            read_seq_sync <= read_seq_meta;

            if (read_seq_sync != read_seq_seen) begin
                read_seq_seen <= read_seq_sync;
                if (READ_WAIT_LIMIT == 0) begin
                    read_wait_active <= 1'b0;
                    read_wait_count  <= 32'd0;
                    read_seq_ready   <= read_seq_sync;
                end else begin
                    read_wait_active <= 1'b1;
                    read_wait_count  <= READ_WAIT_LIMIT[31:0] - 1'b1;
                end
            end else if (read_wait_active) begin
                if (read_wait_count == 32'd0) begin
                    read_wait_active <= 1'b0;
                    read_seq_ready   <= read_seq_seen;
                end else begin
                    read_wait_count <= read_wait_count - 1'b1;
                end
            end
        end
    end

    assign dal_out = {sram_dq_hi, sram_dq_lo};
    assign dal_oe = ram_read_ready && !bufctl_n;
    assign cont_n = ram_read_wait ? 1'b1 : sctl_n;

    assign sram_owns = ram_read_active;
    assign sram_addr = cycle_addr[21:1];
    assign sram_ce1_n = ram_read_active ? 1'b0 : 1'b1;
    assign sram_oe_n = ram_read_active ? 1'b0 : 1'b1;
    assign sram_we_lo_n = 1'b1;
    assign sram_we_hi_n = 1'b1;

    function is_read_aio;
        input [3:0] aio;
        begin
            case (aio)
                AIO_IREADRQ,
                AIO_RMWNBL,
                AIO_RMWBL,
                AIO_DREAD,
                AIO_IREADDM,
                AIO_ODTREAD: is_read_aio = 1'b1;
                default:     is_read_aio = 1'b0;
            endcase
        end
    endfunction

    function is_write_aio;
        input [3:0] aio;
        begin
            case (aio)
                AIO_BUSBYTEWRITE,
                AIO_BUSWORDWRITE: is_write_aio = 1'b1;
                default:           is_write_aio = 1'b0;
            endcase
        end
    endfunction

    /* verilator lint_off UNUSEDSIGNAL */
    wire unused_cycle_aio = |cycle_aio;
    wire unused_cycle_bs = |cycle_bs;
    wire unused_cycle_addr_bit0 = cycle_addr[0];
    /* verilator lint_on UNUSEDSIGNAL */
endmodule

`default_nettype wire
