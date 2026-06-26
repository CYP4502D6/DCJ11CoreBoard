`default_nettype none

module dcj11_sram_2kb_hello_core #(
    parameter integer CLK_HZ = 50_000_000,
    parameter integer UART_BAUD = 115_200,
    parameter integer SRAM_READ_WAIT_CYCLES = 4,
    parameter integer SRAM_WRITE_WAIT_CYCLES = 4,
    parameter         DRIVE_MEM_READ_WITHOUT_BUFCTL = 1'b1,
    parameter integer SRAM_LIVE_DAL_SETTLE_CYCLES = 2,
    parameter integer NXM_ABORT_PULSE_CYCLES = 64,
    parameter integer NXM_ABORT_LED_PULSE_CYCLES = 1_000_000
) (
    input  wire        clk,
    input  wire        reset_n,
    input  wire        init_n_sense,
    input  wire        ale_toggle,
    input  wire        sctl_toggle,
    input  wire [21:0] bus_addr,
    input  wire [15:0] bus_dal_in,
    input  wire [15:0] bus_write_data,
    input  wire [3:0]  bus_aio,
    input  wire [1:0]  bus_bs,
    input  wire        bufctl_n,

    output wire [15:0] dal_out,
    output wire        dal_oe,
    output wire        cont_n,
    output wire        abort_n,
    output wire [1:0]  irq,
    output wire        event_n,
    output wire        miss_drive_low,

    output wire [20:0] sram_addr,
    input  wire [7:0]  sram_dq_lo_in,
    input  wire [7:0]  sram_dq_hi_in,
    output wire [7:0]  sram_dq_lo_out,
    output wire [7:0]  sram_dq_hi_out,
    output wire        sram_dq_lo_drive,
    output wire        sram_dq_hi_drive,
    output wire        sram_ce1_n,
    output wire        sram_oe_n,
    output wire        sram_we_lo_n,
    output wire        sram_we_hi_n,

    input  wire        uart_rx,
    output wire        uart_tx,

    output wire        led_run,
    output wire        led_halt,
    output wire        led_fetch,
    output wire        led_read,
    output wire        led_write,
    output wire        led_inack,
    output wire        led_io_space,
    output wire        led_err,
    output wire [21:0] led_addr_value,
    output wire [15:0] led_data_value,
    output reg         preload_done
);
    localparam [3:0] AIO_GPREAD       = 4'b1110;
    localparam [3:0] AIO_INTACK       = 4'b1101;
    localparam [3:0] AIO_IREADRQ      = 4'b1100;
    localparam [3:0] AIO_RMWNBL       = 4'b1011;
    localparam [3:0] AIO_RMWBL        = 4'b1010;
    localparam [3:0] AIO_DREAD        = 4'b1001;
    localparam [3:0] AIO_IREADDM      = 4'b1000;
    localparam [3:0] AIO_GPWRITE      = 4'b0101;
    localparam [3:0] AIO_BUSBYTEWRITE = 4'b0011;
    localparam [3:0] AIO_BUSWORDWRITE = 4'b0001;

    localparam [7:0] GP_PUP          = 8'o000;
    localparam [7:0] GP_PUP2         = 8'o002;
    localparam [7:0] GP_BUSRESET     = 8'o014;
    localparam [7:0] GP_EXIT_ODT     = 8'o034;
    localparam [7:0] GP_ACK_EVENT    = 8'o100;
    localparam [7:0] GP_NEG_BUSRESET = 8'o214;
    localparam [7:0] GP_TEST1        = 8'o220;
    localparam [7:0] GP_TEST2        = 8'o224;
    localparam [7:0] GP_TEST3        = 8'o230;
    localparam [7:0] GP_ENTRY_ODT    = 8'o234;

    localparam [21:0] MEM_BYTES = 22'd2048;
    localparam [21:0] HELLO_START_BYTE = 22'o001000;
    localparam [5:0]  HELLO_LAST_INDEX = 6'd60;
    localparam integer NXM_ABORT_PULSE_LIMIT =
        (NXM_ABORT_PULSE_CYCLES <= 0) ? 1 : NXM_ABORT_PULSE_CYCLES;
    localparam integer NXM_ABORT_LED_PULSE_LIMIT =
        (NXM_ABORT_LED_PULSE_CYCLES <= 0) ? 1 : NXM_ABORT_LED_PULSE_CYCLES;

    localparam [2:0] PRE_CLEAR      = 3'd0;
    localparam [2:0] PRE_CLEAR_WAIT = 3'd1;
    localparam [2:0] PRE_PROG       = 3'd2;
    localparam [2:0] PRE_PROG_WAIT  = 3'd3;
    localparam [2:0] PRE_DONE       = 3'd4;

    reg [2:0]  preload_state;
    reg [10:0] preload_word;
    reg [5:0]  preload_index;

    reg [1:0] ale_sync;
    reg [2:0] sctl_sync;
    wire ale_strobe = ale_sync[0] ^ ale_sync[1];
    wire sctl_strobe = sctl_sync[1] ^ sctl_sync[2];

    reg        ctrl_start;
    reg        ctrl_write;
    reg [1:0]  ctrl_byte_en;
    reg [21:0] ctrl_addr;
    reg [15:0] ctrl_wdata;
    wire [15:0] ctrl_rdata;
    wire        ctrl_done;
    wire        ctrl_busy;

    reg        mem_read_pending;
    reg        mem_read_ready;
    reg        mem_read_bufctl_seen;
    reg [2:0]  mem_read_live_settle;
    reg [15:0] mem_read_data;
    reg        mem_write_armed;
    reg        mem_write_pending;
    reg [21:0] mem_write_addr;
    reg [3:0]  mem_write_aio;

    reg        bus_reset;
    reg        odt_seen;
    reg        abort_active;
    reg [31:0] abort_pulse_count;
    reg        abort_led_active;
    reg [31:0] abort_led_pulse_count;
    reg [21:0] last_addr;
    reg [15:0] last_data_phase;
    reg [3:0]  last_aio;
    reg [1:0]  last_bs;
    reg        diag1_seen;
    reg        diag2_seen;
    reg        diag3_seen;
    reg        event_ack_seen;

    wire [7:0] gp_code = bus_dal_in[7:0];
    wire [15:0] pup_word = 16'b0000000_0_0000_0_01_1;
    wire gp_powerup_read =
        (bus_aio == AIO_GPREAD) &&
        ((gp_code == GP_PUP) || (gp_code == GP_PUP2));
    wire gp_write = (bus_aio == AIO_GPWRITE);
    wire mem_space = (bus_bs == 2'b00);
    wire io_space = (bus_bs != 2'b00);
    wire bus_read = is_read_aio(bus_aio);
    wire bus_write = is_write_aio(bus_aio);
    wire mem_read_cycle = mem_space && bus_read;
    wire mem_write_cycle = mem_space && bus_write;
    wire mem_addr_hit = (bus_addr < MEM_BYTES);

    wire kl11_bus_hit;
    wire [15:0] kl11_rdata;
    wire kl11_irq;
    wire kl11_tx_start;
    wire [7:0] kl11_tx_data;
    wire uart_tx_ready;
    wire io_read = io_space && bus_read;
    wire io_write = io_space && bus_write;
    wire kl11_read = io_read && kl11_bus_hit;

    wire sram_live_read_active =
        mem_read_pending && !sram_ce1_n && !sram_oe_n &&
        sram_we_hi_n && sram_we_lo_n;
    wire mem_read_live_valid =
        (mem_read_live_settle >= SRAM_LIVE_DAL_SETTLE_CYCLES[2:0]);
    wire mem_read_live_dal_oe =
        DRIVE_MEM_READ_WITHOUT_BUFCTL && sram_live_read_active &&
        mem_read_live_valid && !bufctl_n;
    wire cont_wait = (mem_read_pending && !mem_read_ready) || mem_write_pending;
    wire mem_read_sample_window = !bufctl_n || mem_read_bufctl_seen;
    wire mem_read_ready_dal_oe = (mem_read_pending && mem_read_ready) &&
        mem_read_sample_window;
    wire mem_read_dal_oe = mem_read_live_dal_oe || mem_read_ready_dal_oe;

    assign dal_out =
        gp_powerup_read ? pup_word :
        kl11_read ? kl11_rdata :
        mem_read_live_dal_oe ? {sram_dq_hi_in, sram_dq_lo_in} :
        mem_read_data;
    assign dal_oe =
        (!bufctl_n && (gp_powerup_read || kl11_read)) ||
        mem_read_dal_oe;

    assign cont_n = cont_wait ? 1'b1 : 1'b0;
    assign abort_n = abort_active ? 1'b0 : 1'b1;
    assign irq = {1'b0, kl11_irq};
    assign event_n = 1'b1;
    assign miss_drive_low = 1'b0;

    assign led_run = !(init_n_sense && !bus_reset);
    assign led_halt = !odt_seen;
    assign led_fetch = !((last_aio == AIO_IREADRQ) || (last_aio == AIO_IREADDM));
    assign led_read = !is_read_aio(last_aio);
    assign led_write = !(is_write_aio(last_aio) || (last_aio == AIO_GPWRITE));
    assign led_inack = !(last_aio == AIO_INTACK);
    assign led_io_space = !(last_bs != 2'b00);
    assign led_err = !abort_led_active;
    assign led_addr_value = last_addr;
    assign led_data_value = last_data_phase;

    sram_dual_x8_bus16 #(
        .READ_WAIT_CYCLES(SRAM_READ_WAIT_CYCLES),
        .WRITE_WAIT_CYCLES(SRAM_WRITE_WAIT_CYCLES)
    ) sram_ip (
        .clk(clk),
        .reset_n(reset_n),
        .start(ctrl_start),
        .write(ctrl_write),
        .byte_en(ctrl_byte_en),
        .addr(ctrl_addr),
        .wdata(ctrl_wdata),
        .rdata(ctrl_rdata),
        .done(ctrl_done),
        .busy(ctrl_busy),
        .sram_addr(sram_addr),
        .sram_dq_lo_in(sram_dq_lo_in),
        .sram_dq_hi_in(sram_dq_hi_in),
        .sram_dq_lo_out(sram_dq_lo_out),
        .sram_dq_hi_out(sram_dq_hi_out),
        .sram_dq_lo_drive(sram_dq_lo_drive),
        .sram_dq_hi_drive(sram_dq_hi_drive),
        .sram_ce1_n(sram_ce1_n),
        .sram_oe_n(sram_oe_n),
        .sram_we_lo_n(sram_we_lo_n),
        .sram_we_hi_n(sram_we_hi_n)
    );

    Kl11Lite kl11 (
        .clock(clk),
        .reset(!reset_n),
        .io_busStrobe(sctl_strobe),
        .io_busRead(io_read),
        .io_busWrite(io_write),
        .io_busAddr(bus_addr),
        .io_busWdata(bus_write_data),
        .io_busHit(kl11_bus_hit),
        .io_busRdata(kl11_rdata),
        .io_irq(kl11_irq),
        .io_uartRx(uart_rx),
        .io_txReady(uart_tx_ready),
        .io_txStart(kl11_tx_start),
        .io_txData(kl11_tx_data)
    );

    UartTx tx (
        .clock(clk),
        .reset(!reset_n),
        .io_start(kl11_tx_start),
        .io_data(kl11_tx_data),
        .io_tx(uart_tx),
        .io_ready(uart_tx_ready)
    );

    function is_read_aio;
        input [3:0] aio;
        begin
            case (aio)
                AIO_INTACK,
                AIO_IREADRQ,
                AIO_RMWNBL,
                AIO_RMWBL,
                AIO_DREAD,
                AIO_IREADDM: is_read_aio = 1'b1;
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

    function [1:0] byte_enable_for_write;
        input [3:0] aio;
        input       addr_bit0;
        begin
            if (aio == AIO_BUSBYTEWRITE) begin
                byte_enable_for_write = addr_bit0 ? 2'b10 : 2'b01;
            end else begin
                byte_enable_for_write = 2'b11;
            end
        end
    endfunction

    function [15:0] data_for_write;
        input [3:0] aio;
        input       addr_bit0;
        input [15:0] data;
        begin
            if (aio == AIO_BUSBYTEWRITE) begin
                data_for_write = addr_bit0 ? {data[7:0], 8'h00} : {8'h00, data[7:0]};
            end else begin
                data_for_write = data;
            end
        end
    endfunction

    function [15:0] hello_char_word;
        input [3:0] index;
        begin
            case (index)
                4'd0: hello_char_word = 16'o000110; // 'H'
                4'd1: hello_char_word = 16'o000105; // 'E'
                4'd2: hello_char_word = 16'o000114; // 'L'
                4'd3: hello_char_word = 16'o000114; // 'L'
                4'd4: hello_char_word = 16'o000117; // 'O'
                4'd5: hello_char_word = 16'o000127; // 'W'
                4'd6: hello_char_word = 16'o000117; // 'O'
                4'd7: hello_char_word = 16'o000122; // 'R'
                4'd8: hello_char_word = 16'o000114; // 'L'
                4'd9: hello_char_word = 16'o000104; // 'D'
                default: hello_char_word = 16'o000000;
            endcase
        end
    endfunction

    function [15:0] hello_program_word;
        input [5:0] index;
        begin
            case (index)
                6'd0,  6'd6,  6'd12, 6'd18, 6'd24,
                6'd30, 6'd36, 6'd42, 6'd48, 6'd54:
                    hello_program_word = 16'o105737; // TSTB @#177564
                6'd1,  6'd7,  6'd13, 6'd19, 6'd25,
                6'd31, 6'd37, 6'd43, 6'd49, 6'd55:
                    hello_program_word = 16'o177564; // KL11 XCSR
                6'd2,  6'd8,  6'd14, 6'd20, 6'd26,
                6'd32, 6'd38, 6'd44, 6'd50, 6'd56:
                    hello_program_word = 16'o100375; // BPL back to TSTB
                6'd3,  6'd9,  6'd15, 6'd21, 6'd27,
                6'd33, 6'd39, 6'd45, 6'd51, 6'd57:
                    hello_program_word = 16'o112737; // MOVB #imm,@#177566
                6'd4:  hello_program_word = hello_char_word(4'd0);
                6'd10: hello_program_word = hello_char_word(4'd1);
                6'd16: hello_program_word = hello_char_word(4'd2);
                6'd22: hello_program_word = hello_char_word(4'd3);
                6'd28: hello_program_word = hello_char_word(4'd4);
                6'd34: hello_program_word = hello_char_word(4'd5);
                6'd40: hello_program_word = hello_char_word(4'd6);
                6'd46: hello_program_word = hello_char_word(4'd7);
                6'd52: hello_program_word = hello_char_word(4'd8);
                6'd58: hello_program_word = hello_char_word(4'd9);
                6'd5,  6'd11, 6'd17, 6'd23, 6'd29,
                6'd35, 6'd41, 6'd47, 6'd53, 6'd59:
                    hello_program_word = 16'o177566; // KL11 XBUF
                6'd60: hello_program_word = 16'o000000; // HALT
                default: hello_program_word = 16'o000000;
            endcase
        end
    endfunction

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            ale_sync <= 2'b00;
            sctl_sync <= 3'b000;
        end else begin
            ale_sync <= {ale_sync[0], ale_toggle};
            sctl_sync <= {sctl_sync[1:0], sctl_toggle};
        end
    end

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            preload_state <= PRE_CLEAR;
            preload_word <= 11'd0;
            preload_index <= 6'd0;
            preload_done <= 1'b0;
            ctrl_start <= 1'b0;
            ctrl_write <= 1'b0;
            ctrl_byte_en <= 2'b00;
            ctrl_addr <= 22'h000000;
            ctrl_wdata <= 16'h0000;
            mem_read_pending <= 1'b0;
            mem_read_ready <= 1'b0;
            mem_read_bufctl_seen <= 1'b0;
            mem_read_live_settle <= 3'd0;
            mem_read_data <= 16'h0000;
            mem_write_armed <= 1'b0;
            mem_write_pending <= 1'b0;
            mem_write_addr <= 22'h000000;
            mem_write_aio <= AIO_BUSWORDWRITE;
            bus_reset <= 1'b0;
            odt_seen <= 1'b0;
            abort_active <= 1'b0;
            abort_pulse_count <= 32'd0;
            abort_led_active <= 1'b0;
            abort_led_pulse_count <= 32'd0;
            last_addr <= 22'h000000;
            last_data_phase <= 16'h0000;
            last_aio <= 4'hf;
            last_bs <= 2'b00;
            diag1_seen <= 1'b0;
            diag2_seen <= 1'b0;
            diag3_seen <= 1'b0;
            event_ack_seen <= 1'b0;
        end else begin
            ctrl_start <= 1'b0;

            if (!preload_done) begin
                mem_read_pending <= 1'b0;
                mem_read_ready <= 1'b0;
                mem_read_bufctl_seen <= 1'b0;
                mem_read_live_settle <= 3'd0;
                mem_write_armed <= 1'b0;
                mem_write_pending <= 1'b0;
                abort_active <= 1'b0;
                abort_pulse_count <= 32'd0;
                abort_led_active <= 1'b0;
                abort_led_pulse_count <= 32'd0;
                last_addr <= {10'd0, preload_word, 1'b0};
                last_data_phase <= (preload_state == PRE_PROG || preload_state == PRE_PROG_WAIT) ?
                    hello_program_word(preload_index) : 16'h0000;

                case (preload_state)
                    PRE_CLEAR: begin
                        if (!ctrl_busy) begin
                            ctrl_write <= 1'b1;
                            ctrl_byte_en <= 2'b11;
                            ctrl_addr <= {10'd0, preload_word, 1'b0};
                            ctrl_wdata <= 16'h0000;
                            ctrl_start <= 1'b1;
                            preload_state <= PRE_CLEAR_WAIT;
                        end
                    end

                    PRE_CLEAR_WAIT: begin
                        if (ctrl_done) begin
                            if (preload_word == 11'd1023) begin
                                preload_index <= 6'd0;
                                preload_state <= PRE_PROG;
                            end else begin
                                preload_word <= preload_word + 1'b1;
                                preload_state <= PRE_CLEAR;
                            end
                        end
                    end

                    PRE_PROG: begin
                        if (!ctrl_busy) begin
                            ctrl_write <= 1'b1;
                            ctrl_byte_en <= 2'b11;
                            ctrl_addr <= HELLO_START_BYTE + {15'd0, preload_index, 1'b0};
                            ctrl_wdata <= hello_program_word(preload_index);
                            ctrl_start <= 1'b1;
                            preload_state <= PRE_PROG_WAIT;
                        end
                    end

                    PRE_PROG_WAIT: begin
                        if (ctrl_done) begin
                            if (preload_index == HELLO_LAST_INDEX) begin
                                preload_done <= 1'b1;
                                preload_state <= PRE_DONE;
                            end else begin
                                preload_index <= preload_index + 1'b1;
                                preload_state <= PRE_PROG;
                            end
                        end
                    end

                    default: begin
                        preload_done <= 1'b1;
                        preload_state <= PRE_DONE;
                    end
                endcase
            end else if (!init_n_sense) begin
                mem_read_pending <= 1'b0;
                mem_read_ready <= 1'b0;
                mem_read_bufctl_seen <= 1'b0;
                mem_read_live_settle <= 3'd0;
                mem_write_armed <= 1'b0;
                mem_write_pending <= 1'b0;
                bus_reset <= 1'b0;
                odt_seen <= 1'b0;
                abort_active <= 1'b0;
                abort_pulse_count <= 32'd0;
                abort_led_active <= 1'b0;
                abort_led_pulse_count <= 32'd0;
                last_addr <= 22'h000000;
                last_data_phase <= 16'h0000;
                last_aio <= 4'hf;
                last_bs <= 2'b00;
            end else begin
                if (abort_active) begin
                    if (abort_pulse_count == 32'd0) begin
                        abort_active <= 1'b0;
                    end else begin
                        abort_pulse_count <= abort_pulse_count - 1'b1;
                    end
                end

                if (abort_led_active) begin
                    if (abort_led_pulse_count == 32'd0) begin
                        abort_led_active <= 1'b0;
                    end else begin
                        abort_led_pulse_count <= abort_led_pulse_count - 1'b1;
                    end
                end

                if (sram_live_read_active) begin
                    if (mem_read_live_settle < 3'd7) begin
                        mem_read_live_settle <= mem_read_live_settle + 1'b1;
                    end
                end else begin
                    mem_read_live_settle <= 3'd0;
                end

                if (ctrl_done) begin
                    if (mem_read_pending) begin
                        mem_read_data <= ctrl_rdata;
                        mem_read_ready <= 1'b1;
                        mem_read_bufctl_seen <= !bufctl_n;
                        last_data_phase <= ctrl_rdata;
                    end
                    if (mem_write_pending) begin
                        mem_write_pending <= 1'b0;
                    end
                end

                if (mem_read_pending && mem_read_ready) begin
                    if (!bufctl_n) begin
                        mem_read_bufctl_seen <= 1'b1;
                    end else if (mem_read_bufctl_seen) begin
                        mem_read_pending <= 1'b0;
                        mem_read_ready <= 1'b0;
                        mem_read_bufctl_seen <= 1'b0;
                    end
                end

                if (ale_strobe) begin
                    last_addr <= bus_addr;
                    last_aio <= bus_aio;
                    last_bs <= bus_bs;
                    abort_active <= 1'b0;
                    abort_pulse_count <= 32'd0;
                    mem_read_pending <= 1'b0;
                    mem_read_ready <= 1'b0;
                    mem_read_bufctl_seen <= 1'b0;
                    mem_read_live_settle <= 3'd0;
                    mem_write_armed <= 1'b0;

                    if (gp_powerup_read) begin
                        last_data_phase <= pup_word;
                    end

                    if (mem_read_cycle) begin
                        if (mem_addr_hit) begin
                            ctrl_write <= 1'b0;
                            ctrl_byte_en <= 2'b11;
                            ctrl_addr <= bus_addr;
                            ctrl_wdata <= 16'h0000;
                            ctrl_start <= 1'b1;
                            mem_read_pending <= 1'b1;
                        end else begin
                            abort_active <= 1'b1;
                            abort_pulse_count <= NXM_ABORT_PULSE_LIMIT[31:0] - 1'b1;
                            abort_led_active <= 1'b1;
                            abort_led_pulse_count <= NXM_ABORT_LED_PULSE_LIMIT[31:0] - 1'b1;
                        end
                    end else if (mem_write_cycle) begin
                        if (mem_addr_hit) begin
                            mem_write_armed <= 1'b1;
                            mem_write_addr <= bus_addr;
                            mem_write_aio <= bus_aio;
                        end else begin
                            abort_active <= 1'b1;
                            abort_pulse_count <= NXM_ABORT_PULSE_LIMIT[31:0] - 1'b1;
                            abort_led_active <= 1'b1;
                            abort_led_pulse_count <= NXM_ABORT_LED_PULSE_LIMIT[31:0] - 1'b1;
                        end
                    end
                end

                if (sctl_strobe) begin
                    if (gp_write) begin
                        last_data_phase <= bus_dal_in;
                        case (gp_code)
                            GP_BUSRESET:     bus_reset <= 1'b1;
                            GP_NEG_BUSRESET: bus_reset <= 1'b0;
                            GP_TEST1:        diag1_seen <= 1'b1;
                            GP_TEST2:        diag2_seen <= 1'b1;
                            GP_TEST3:        diag3_seen <= 1'b1;
                            GP_ENTRY_ODT:    odt_seen <= 1'b1;
                            GP_EXIT_ODT:     odt_seen <= 1'b0;
                            GP_ACK_EVENT:    event_ack_seen <= 1'b1;
                            default: ;
                        endcase
                    end

                    if (io_write) begin
                        last_data_phase <= bus_write_data;
                    end

                    if (mem_write_armed && !ctrl_busy) begin
                        ctrl_write <= 1'b1;
                        ctrl_byte_en <= byte_enable_for_write(mem_write_aio, mem_write_addr[0]);
                        ctrl_addr <= mem_write_addr;
                        ctrl_wdata <= data_for_write(mem_write_aio, mem_write_addr[0], bus_write_data);
                        ctrl_start <= 1'b1;
                        mem_write_armed <= 1'b0;
                        mem_write_pending <= 1'b1;
                        last_data_phase <= data_for_write(mem_write_aio, mem_write_addr[0], bus_write_data);
                    end
                end

                if (kl11_read && !bufctl_n) begin
                    last_data_phase <= kl11_rdata;
                end
            end
        end
    end

    /* verilator lint_off UNUSED */
    wire unused_diag_seen = diag1_seen & diag2_seen & diag3_seen & event_ack_seen;
    wire unused_uart_params = |{CLK_HZ[31:0], UART_BAUD[31:0]};
    /* verilator lint_on UNUSED */
endmodule

`default_nettype wire
