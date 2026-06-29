`default_nettype none

module dcj11tapebasic_core #(
    parameter integer CLK_HZ = 50_000_000,
    parameter integer UART_BAUD = 115_200,
    parameter integer SRAM_READ_WAIT_CYCLES = 6,
    parameter integer SRAM_WRITE_WAIT_CYCLES = 4,
    parameter integer SRAM_READ_HOLD_CYCLES = 2,
    parameter         ENABLE_CORE_MEM_READS = 1'b1,
    parameter         DRIVE_MEM_READ_WITHOUT_BUFCTL = 1'b0,
    parameter integer SRAM_LIVE_DAL_SETTLE_CYCLES = 1,
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
    input  wire        sctl_n,
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

    input  wire        sd_miso,
    output wire        sd_sck,
    output wire        sd_mosi,
    output wire        sd_cs_n,

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
    localparam [3:0] AIO_NONIO        = 4'b1111;
    localparam [3:0] AIO_GPREAD       = 4'b1110;
    localparam [3:0] AIO_INTACK       = 4'b1101;
    localparam [3:0] AIO_IREADRQ      = 4'b1100;
    localparam [3:0] AIO_RMWNBL       = 4'b1011;
    localparam [3:0] AIO_RMWBL        = 4'b1010;
    localparam [3:0] AIO_DREAD        = 4'b1001;
    localparam [3:0] AIO_IREADDM      = 4'b1000;
    // Board captures of ODT examine cycles have shown this code for memory reads.
    localparam [3:0] AIO_ODTREAD      = 4'b0110;
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

    localparam [15:0] PDP11_IO_PAGE_BASE = 16'o160000;
    localparam [15:0] PDP11_CPU_REG_BASE = 16'o177700;
    localparam [15:0] ADRS_SWR = 16'o177570;
    localparam [15:0] ADRS_PC11_BASE = 16'o177550;
    localparam [15:0] ADRS_KL11_BASE = 16'o177560;
    localparam [15:0] PRELOAD_LAST_WORD = 16'd32767;
    localparam [3:0]  BOOT_LAST_INDEX = 4'd13;
    localparam [7:0]  ASCII_R = 8'h52;
    localparam [7:0]  ASCII_E = 8'h45;
    localparam [7:0]  ASCII_A = 8'h41;
    localparam [7:0]  ASCII_D = 8'h44;
    localparam [7:0]  ASCII_Y = 8'h59;
    localparam integer NXM_ABORT_PULSE_LIMIT =
        (NXM_ABORT_PULSE_CYCLES <= 0) ? 1 : NXM_ABORT_PULSE_CYCLES;
    localparam integer NXM_ABORT_LED_PULSE_LIMIT =
        (NXM_ABORT_LED_PULSE_CYCLES <= 0) ? 1 : NXM_ABORT_LED_PULSE_CYCLES;
    localparam integer SRAM_READ_HOLD_LIMIT =
        (SRAM_READ_HOLD_CYCLES <= 0) ? 0 : SRAM_READ_HOLD_CYCLES;

    localparam [2:0] PRE_CLEAR      = 3'd0;
    localparam [2:0] PRE_CLEAR_WAIT = 3'd1;
    localparam [2:0] PRE_BOOT       = 3'd2;
    localparam [2:0] PRE_BOOT_WAIT  = 3'd3;
    localparam [2:0] PRE_DONE       = 3'd4;

    reg [2:0]  preload_state;
    reg [15:0] preload_word;
    reg [3:0]  preload_index;

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
    reg [31:0] mem_read_hold_count;
    reg [15:0] mem_read_data;
    reg        mem_write_armed;
    reg        mem_write_pending;
    reg [21:0] mem_write_addr;
    reg [3:0]  mem_write_aio;
    reg        mem_write_data_valid;
    reg [15:0] mem_write_data_latched;

    reg        bus_reset;
    reg        odt_seen;
    reg        abort_active;
    reg [31:0] abort_pulse_count;
    reg        abort_led_active;
    reg [31:0] abort_led_pulse_count;
    reg [21:0] last_addr;
    reg [15:0] last_data_phase;
    reg [3:0]  last_aio;
    reg        last_io_space;
    reg        diag1_seen;
    reg        diag2_seen;
    reg        diag3_seen;
    reg        event_ack_seen;
    reg        init_seen_high;

    wire [7:0] gp_code = bus_dal_in[7:0];
    wire [15:0] pup_word = 16'b0000000_0_0000_0_01_1;
    wire gp_read = (bus_aio == AIO_GPREAD);
    wire gp_powerup_read =
        gp_read &&
        ((gp_code == GP_PUP) || (gp_code == GP_PUP2));
    wire gp_write = (bus_aio == AIO_GPWRITE);
    wire [15:0] bus_addr16 = bus_addr[15:0];
    wire [21:0] compat_mem_addr = {6'b000000, bus_addr16};
    wire compat_io_page = (bus_addr16 >= PDP11_IO_PAGE_BASE);
    wire mem_space = (bus_addr[21:16] == 6'b000000) && !compat_io_page;
    wire io_space = compat_io_page;
    wire bus_read = is_read_aio(bus_aio);
    wire bus_write = is_write_aio(bus_aio);
    wire bus_rmw = is_rmw_aio(bus_aio);
    wire mem_read_cycle =
        mem_space && !gp_read && !gp_write && !bus_write &&
        (bus_aio != AIO_INTACK) && (bus_aio != AIO_NONIO);
    wire mem_write_cycle = mem_space && bus_write;
    wire mem_addr_hit = mem_space;
    wire dcj_internal_io_cycle =
        (bus_addr[21:16] == 6'h3f) && (bus_addr16 >= PDP11_CPU_REG_BASE);

    wire kl11_bus_hit;
    wire [15:0] kl11_rdata;
    wire kl11_irq;
    wire kl11_irq_ack;
    wire [15:0] kl11_irq_vector;
    wire kl11_tx_start;
    wire [7:0] kl11_tx_data;
    wire uart_tx_ready;

    wire pc11_bus_hit;
    wire [15:0] pc11_rdata;
    wire pc11_irq;
    wire pc11_irq_ack;
    wire [15:0] pc11_irq_vector;
    wire pc11_tape_valid;
    wire pc11_tape_ready;
    wire [7:0] pc11_tape_data;
    wire pc11_punch_valid;
    wire [7:0] pc11_punch_data;
    wire pc11_punch_ready;
    wire sd_initialized;
    wire sd_active;
    wire sd_done;
    wire sd_error;
    wire peripheral_reset = !reset_n || !init_seen_high;
    reg [15:0] swr_reg;
    reg [2:0]  basic_ready_match;
    reg        basic_ready_seen;
    reg        basic_ready_pulse;

    wire io_read = io_space && bus_read;
    // RMW cycles present a read phase first. The CPU later emits a normal
    // bus write phase for the writeback, so peripherals must not treat the
    // RMW read phase itself as a write.
    wire io_write = io_space && bus_write;
    // Match the Paper Tape BASIC reference design's deliberately small bus
    // error surface. Other unimplemented I/O reads are left as no-op cycles so
    // mixed ALE/AIO captures during PC-relative operand fetches cannot trip NXM.
    wire reference_bus_error =
        io_read &&
        ((bus_addr16 == 16'o177700) ||
         (bus_addr16[15:6] == 10'o1700));
    wire swr_bus_hit = (bus_addr16 == ADRS_SWR);
    wire pc11_addr_hit = (bus_addr16 >= ADRS_PC11_BASE) && (bus_addr16 <= (ADRS_PC11_BASE + 16'd6));
    wire kl11_addr_hit = (bus_addr16 >= ADRS_KL11_BASE) && (bus_addr16 <= (ADRS_KL11_BASE + 16'd6));
    wire kl11_read = io_read && kl11_bus_hit;
    wire pc11_read = io_read && pc11_bus_hit;
    wire swr_read = io_read && swr_bus_hit;
    wire irq0_request = kl11_irq || pc11_irq;
    wire intack_irq0 = (bus_aio == AIO_INTACK) && (bus_dal_in[3:0] == 4'b0001);
    wire intack_read = intack_irq0 && !bufctl_n;
    wire swr_write = io_write && swr_bus_hit;
    // Board captures show some I/O write cycles with correct address/data and
    // BUFCTL_N high, while the AIO code sampled for the core can be ambiguous.
    // For KL11/PC11 writes, BUFCTL_N high during SCTL is a stronger discriminator
    // than AIO alone: reads assert BUFCTL_N low when the FPGA must drive DAL.
    wire kl11_write = io_write || (io_space && kl11_addr_hit && bufctl_n && !bus_read);
    wire pc11_write = io_write || (io_space && pc11_addr_hit && bufctl_n && !bus_read);
    wire dcj_internal_read = io_read && dcj_internal_io_cycle && !reference_bus_error;

    wire sram_live_read_active =
        mem_read_pending && !sram_ce1_n && !sram_oe_n &&
        sram_we_hi_n && sram_we_lo_n;
    wire mem_read_live_valid =
        (mem_read_live_settle >= SRAM_LIVE_DAL_SETTLE_CYCLES[2:0]);
    wire mem_read_live_dal_oe =
        DRIVE_MEM_READ_WITHOUT_BUFCTL && sram_live_read_active &&
        mem_read_live_valid && !bufctl_n;
    wire cont_wait =
        (mem_read_pending && (!mem_read_ready || (mem_read_hold_count != 32'd0))) ||
        mem_write_pending;
    wire mem_read_ready_dal_oe = (mem_read_pending && mem_read_ready) &&
        !bufctl_n;
    wire mem_read_dal_oe = mem_read_live_dal_oe || mem_read_ready_dal_oe;
    reg [15:0] irq0_vector_latched;
    reg        irq0_ack_pulse;
    reg        irq0_ack_kl11;
    reg        irq0_ack_pc11;

    assign kl11_irq_ack = irq0_ack_pulse && irq0_ack_kl11;
    assign pc11_irq_ack = irq0_ack_pulse && irq0_ack_pc11;

    assign dal_out =
        intack_read ? irq0_vector_latched :
        gp_powerup_read ? pup_word :
        kl11_read ? kl11_rdata :
        pc11_read ? pc11_rdata :
        swr_read ? swr_reg :
        dcj_internal_read ? 16'h0000 :
        mem_read_live_dal_oe ? {sram_dq_hi_in, sram_dq_lo_in} :
        mem_read_data;
    assign dal_oe =
        (!bufctl_n && (intack_irq0 || gp_powerup_read || kl11_read || pc11_read || swr_read || dcj_internal_read)) ||
        mem_read_dal_oe;

    assign cont_n = cont_wait ? 1'b1 : sctl_n;
    assign abort_n = abort_active ? 1'b0 : 1'b1;
    assign irq = {1'b0, irq0_request};
    assign event_n = 1'b1;
    assign miss_drive_low = 1'b0;

    assign led_run = !(init_n_sense && !bus_reset);
    assign led_halt = !odt_seen;
    assign led_fetch = !((last_aio == AIO_IREADRQ) || (last_aio == AIO_IREADDM));
    assign led_read = !is_read_aio(last_aio);
    assign led_write = !(is_write_aio(last_aio) || (last_aio == AIO_GPWRITE));
    assign led_inack = !(last_aio == AIO_INTACK);
    assign led_io_space = !last_io_space;
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

    Kl11Console kl11 (
        .clock(clk),
        .reset(peripheral_reset),
        .io_busStrobe(sctl_strobe),
        .io_busRead(io_read),
        .io_busWrite(kl11_write),
        .io_busAddr(bus_addr),
        .io_busWdata(bus_write_data),
        .io_busHit(kl11_bus_hit),
        .io_busRdata(kl11_rdata),
        .io_irq(kl11_irq),
        .io_irqAck(kl11_irq_ack),
        .io_irqVector(kl11_irq_vector),
        .io_uartRx(uart_rx),
        .io_txReady(uart_tx_ready),
        .io_txStart(kl11_tx_start),
        .io_txData(kl11_tx_data)
    );

    UartTx console_tx (
        .clock(clk),
        .reset(peripheral_reset),
        .io_start(kl11_tx_start),
        .io_data(kl11_tx_data),
        .io_tx(uart_tx),
        .io_ready(uart_tx_ready)
    );

    Pc11Reader pc11 (
        .clock(clk),
        .reset(peripheral_reset),
        .io_busStrobe(sctl_strobe),
        .io_busRead(io_read),
        .io_busWrite(pc11_write),
        .io_busAddr(bus_addr),
        .io_busWdata(bus_write_data),
        .io_busHit(pc11_bus_hit),
        .io_busRdata(pc11_rdata),
        .io_irq(pc11_irq),
        .io_irqAck(pc11_irq_ack),
        .io_irqVector(pc11_irq_vector),
        .io_tapeValid(pc11_tape_valid),
        .io_tapeData(pc11_tape_data),
        .io_tapeReady(pc11_tape_ready),
        .io_tapeDone(sd_done),
        .io_tapeError(sd_error),
        .io_punchValid(pc11_punch_valid),
        .io_punchData(pc11_punch_data),
        .io_punchReady(pc11_punch_ready)
    );

    SdTapeStream sd_tape (
        .clock(clk),
        .reset(!reset_n),
        .io_sdMiso(sd_miso),
        .io_sdSck(sd_sck),
        .io_sdMosi(sd_mosi),
        .io_sdCsN(sd_cs_n),
        .io_sessionReset(peripheral_reset),
        .io_forceUserMode(basic_ready_seen),
        .io_flushUserTape(basic_ready_pulse),
        .io_outValid(pc11_tape_valid),
        .io_outReady(pc11_tape_ready),
        .io_outData(pc11_tape_data),
        .io_punchValid(pc11_punch_valid),
        .io_punchData(pc11_punch_data),
        .io_punchReady(pc11_punch_ready),
        .io_initialized(sd_initialized),
        .io_active(sd_active),
        .io_done(sd_done),
        .io_error(sd_error)
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

    function is_rmw_aio;
        input [3:0] aio;
        begin
            case (aio)
                AIO_RMWNBL,
                AIO_RMWBL: is_rmw_aio = 1'b1;
                default:   is_rmw_aio = 1'b0;
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
                data_for_write = addr_bit0 ? {data[15:8], 8'h00} : {8'h00, data[7:0]};
            end else begin
                data_for_write = data;
            end
        end
    endfunction

    function [21:0] boot_addr;
        input [3:0] index;
        begin
            boot_addr = 22'o157744 + {17'd0, index, 1'b0};
        end
    endfunction

    function [15:0] boot_word;
        input [3:0] index;
        begin
            case (index)
                4'd0:  boot_word = 16'o016701;
                4'd1:  boot_word = 16'o000026;
                4'd2:  boot_word = 16'o012702;
                4'd3:  boot_word = 16'o000352;
                4'd4:  boot_word = 16'o005211;
                4'd5:  boot_word = 16'o105711;
                4'd6:  boot_word = 16'o100376;
                4'd7:  boot_word = 16'o116162;
                4'd8:  boot_word = 16'o000002;
                4'd9:  boot_word = 16'o157400;
                4'd10: boot_word = 16'o005267;
                4'd11: boot_word = 16'o177756;
                4'd12: boot_word = 16'o000765;
                4'd13: boot_word = 16'o177550;
                default: boot_word = 16'o000000;
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
            preload_word <= 16'd0;
            preload_index <= 4'd0;
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
            mem_read_hold_count <= 32'd0;
            mem_read_data <= 16'h0000;
            mem_write_armed <= 1'b0;
            mem_write_pending <= 1'b0;
            mem_write_addr <= 22'h000000;
            mem_write_aio <= AIO_BUSWORDWRITE;
            mem_write_data_valid <= 1'b0;
            mem_write_data_latched <= 16'h0000;
            bus_reset <= 1'b0;
            odt_seen <= 1'b0;
            abort_active <= 1'b0;
            abort_pulse_count <= 32'd0;
            abort_led_active <= 1'b0;
            abort_led_pulse_count <= 32'd0;
            last_addr <= 22'h000000;
            last_data_phase <= 16'h0000;
            last_aio <= 4'hf;
            last_io_space <= 1'b0;
            diag1_seen <= 1'b0;
            diag2_seen <= 1'b0;
            diag3_seen <= 1'b0;
            event_ack_seen <= 1'b0;
            init_seen_high <= 1'b0;
            swr_reg <= 16'h0000;
            basic_ready_match <= 3'd0;
            basic_ready_seen <= 1'b0;
            basic_ready_pulse <= 1'b0;
            irq0_vector_latched <= 16'h0000;
            irq0_ack_pulse <= 1'b0;
            irq0_ack_kl11 <= 1'b0;
            irq0_ack_pc11 <= 1'b0;
        end else begin
            ctrl_start <= 1'b0;
            irq0_ack_pulse <= 1'b0;

            if (!preload_done) begin
                init_seen_high <= 1'b0;
                mem_read_pending <= 1'b0;
                mem_read_ready <= 1'b0;
                mem_read_bufctl_seen <= 1'b0;
                mem_read_live_settle <= 3'd0;
                mem_read_hold_count <= 32'd0;
                mem_write_armed <= 1'b0;
                mem_write_pending <= 1'b0;
                mem_write_data_valid <= 1'b0;
                mem_write_data_latched <= 16'h0000;
                abort_active <= 1'b0;
                abort_pulse_count <= 32'd0;
                abort_led_active <= 1'b0;
                abort_led_pulse_count <= 32'd0;
                basic_ready_match <= 3'd0;
                basic_ready_seen <= 1'b0;
                basic_ready_pulse <= 1'b0;
                irq0_vector_latched <= 16'h0000;
                irq0_ack_kl11 <= 1'b0;
                irq0_ack_pc11 <= 1'b0;
                last_addr <= {5'd0, preload_word, 1'b0};
                last_data_phase <= (preload_state == PRE_BOOT || preload_state == PRE_BOOT_WAIT) ?
                    boot_word(preload_index) : 16'h0000;

                case (preload_state)
                    PRE_CLEAR: begin
                        if (!ctrl_busy) begin
                            ctrl_write <= 1'b1;
                            ctrl_byte_en <= 2'b11;
                            ctrl_addr <= {5'd0, preload_word, 1'b0};
                            ctrl_wdata <= 16'h0000;
                            ctrl_start <= 1'b1;
                            preload_state <= PRE_CLEAR_WAIT;
                        end
                    end

                    PRE_CLEAR_WAIT: begin
                        if (ctrl_done) begin
                            if (preload_word == PRELOAD_LAST_WORD) begin
                                preload_index <= 4'd0;
                                preload_state <= PRE_BOOT;
                            end else begin
                                preload_word <= preload_word + 1'b1;
                                preload_state <= PRE_CLEAR;
                            end
                        end
                    end

                    PRE_BOOT: begin
                        if (!ctrl_busy) begin
                            ctrl_write <= 1'b1;
                            ctrl_byte_en <= 2'b11;
                            ctrl_addr <= boot_addr(preload_index);
                            ctrl_wdata <= boot_word(preload_index);
                            ctrl_start <= 1'b1;
                            preload_state <= PRE_BOOT_WAIT;
                        end
                    end

                    PRE_BOOT_WAIT: begin
                        if (ctrl_done) begin
                            if (preload_index == BOOT_LAST_INDEX) begin
                                preload_done <= 1'b1;
                                preload_state <= PRE_DONE;
                            end else begin
                                preload_index <= preload_index + 1'b1;
                                preload_state <= PRE_BOOT;
                            end
                        end
                    end

                    default: begin
                        preload_done <= 1'b1;
                        preload_state <= PRE_DONE;
                    end
                endcase
            end else if (!init_n_sense) begin
                if (init_seen_high) begin
                    preload_state <= PRE_CLEAR;
                    preload_word <= 16'd0;
                    preload_index <= 4'd0;
                    preload_done <= 1'b0;
                end
                init_seen_high <= 1'b0;
                mem_read_pending <= 1'b0;
                mem_read_ready <= 1'b0;
                mem_read_bufctl_seen <= 1'b0;
                mem_read_live_settle <= 3'd0;
                mem_read_hold_count <= 32'd0;
                mem_write_armed <= 1'b0;
                mem_write_pending <= 1'b0;
                mem_write_data_valid <= 1'b0;
                mem_write_data_latched <= 16'h0000;
                bus_reset <= 1'b0;
                odt_seen <= 1'b0;
                abort_active <= 1'b0;
                abort_pulse_count <= 32'd0;
                abort_led_active <= 1'b0;
                abort_led_pulse_count <= 32'd0;
                last_addr <= 22'h000000;
                last_data_phase <= 16'h0000;
                last_aio <= 4'hf;
                last_io_space <= 1'b0;
                swr_reg <= 16'h0000;
                basic_ready_match <= 3'd0;
                basic_ready_seen <= 1'b0;
                basic_ready_pulse <= 1'b0;
                irq0_vector_latched <= 16'h0000;
                irq0_ack_kl11 <= 1'b0;
                irq0_ack_pc11 <= 1'b0;
            end else begin
                init_seen_high <= 1'b1;
                basic_ready_pulse <= 1'b0;
                if (kl11_tx_start) begin
                    case (basic_ready_match)
                        3'd0: begin
                            basic_ready_match <= (kl11_tx_data == ASCII_R) ? 3'd1 : 3'd0;
                        end
                        3'd1: begin
                            if (kl11_tx_data == ASCII_E) begin
                                basic_ready_match <= 3'd2;
                            end else begin
                                basic_ready_match <= (kl11_tx_data == ASCII_R) ? 3'd1 : 3'd0;
                            end
                        end
                        3'd2: begin
                            if (kl11_tx_data == ASCII_A) begin
                                basic_ready_match <= 3'd3;
                            end else begin
                                basic_ready_match <= (kl11_tx_data == ASCII_R) ? 3'd1 : 3'd0;
                            end
                        end
                        3'd3: begin
                            if (kl11_tx_data == ASCII_D) begin
                                basic_ready_match <= 3'd4;
                            end else begin
                                basic_ready_match <= (kl11_tx_data == ASCII_R) ? 3'd1 : 3'd0;
                            end
                        end
                        3'd4: begin
                            if (kl11_tx_data == ASCII_Y) begin
                                basic_ready_seen <= 1'b1;
                                basic_ready_pulse <= 1'b1;
                                basic_ready_match <= 3'd0;
                            end else begin
                                basic_ready_match <= (kl11_tx_data == ASCII_R) ? 3'd1 : 3'd0;
                            end
                        end
                        default: begin
                            basic_ready_match <= 3'd0;
                        end
                    endcase
                end

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

                if (mem_read_hold_count != 32'd0) begin
                    mem_read_hold_count <= mem_read_hold_count - 1'b1;
                end

                if (ctrl_done) begin
                    if (mem_read_pending) begin
                        mem_read_data <= ctrl_rdata;
                        mem_read_ready <= 1'b1;
                        mem_read_hold_count <= SRAM_READ_HOLD_LIMIT[31:0];
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
                    last_io_space <= io_space;
                    abort_active <= 1'b0;
                    abort_pulse_count <= 32'd0;
                    mem_read_pending <= 1'b0;
                    mem_read_ready <= 1'b0;
                    mem_read_bufctl_seen <= 1'b0;
                    mem_read_live_settle <= 3'd0;
                    mem_read_hold_count <= 32'd0;
                    mem_write_armed <= 1'b0;

                    if (intack_irq0) begin
                        irq0_vector_latched <= kl11_irq ? kl11_irq_vector :
                            (pc11_irq ? pc11_irq_vector : 16'h0000);
                        irq0_ack_kl11 <= kl11_irq;
                        irq0_ack_pc11 <= !kl11_irq && pc11_irq;
                        last_data_phase <= kl11_irq ? kl11_irq_vector :
                            (pc11_irq ? pc11_irq_vector : 16'h0000);
                    end

                    if (gp_powerup_read) begin
                        last_data_phase <= pup_word;
                    end

                    if (gp_read) begin
                        if (!gp_powerup_read) begin
                            last_data_phase <= 16'h0000;
                        end
                    end else if (mem_read_cycle) begin
                        if (mem_addr_hit) begin
                            if (ENABLE_CORE_MEM_READS) begin
                                ctrl_write <= 1'b0;
                                ctrl_byte_en <= 2'b11;
                                ctrl_addr <= compat_mem_addr;
                                ctrl_wdata <= 16'h0000;
                                ctrl_start <= 1'b1;
                                mem_read_pending <= 1'b1;
                            end
                            if (bus_rmw) begin
                                mem_write_armed <= 1'b1;
                                mem_write_addr <= compat_mem_addr;
                                mem_write_aio <= AIO_BUSWORDWRITE;
                            end
                        end else begin
                            abort_active <= 1'b1;
                            abort_pulse_count <= NXM_ABORT_PULSE_LIMIT[31:0] - 1'b1;
                            abort_led_active <= 1'b1;
                            abort_led_pulse_count <= NXM_ABORT_LED_PULSE_LIMIT[31:0] - 1'b1;
                        end
                    end else if (mem_write_cycle) begin
                        if (mem_addr_hit) begin
                            mem_write_armed <= 1'b1;
                            mem_write_addr <= compat_mem_addr;
                            mem_write_aio <= bus_aio;
                        end else begin
                            abort_active <= 1'b1;
                            abort_pulse_count <= NXM_ABORT_PULSE_LIMIT[31:0] - 1'b1;
                            abort_led_active <= 1'b1;
                            abort_led_pulse_count <= NXM_ABORT_LED_PULSE_LIMIT[31:0] - 1'b1;
                        end
                    end else if (reference_bus_error) begin
                        abort_active <= 1'b1;
                        abort_pulse_count <= NXM_ABORT_PULSE_LIMIT[31:0] - 1'b1;
                        abort_led_active <= 1'b1;
                        abort_led_pulse_count <= NXM_ABORT_LED_PULSE_LIMIT[31:0] - 1'b1;
                    end
                end

                if (sctl_strobe) begin
                    if (intack_irq0) begin
                        irq0_ack_pulse <= 1'b1;
                    end

                    if (gp_write) begin
                        last_data_phase <= bus_dal_in;
                        case (gp_code)
                            GP_BUSRESET:     bus_reset <= 1'b1;
                            GP_NEG_BUSRESET: bus_reset <= 1'b0;
                            GP_TEST1:        diag1_seen <= 1'b1;
                            GP_TEST2:        diag2_seen <= 1'b1;
                            GP_TEST3:        diag3_seen <= 1'b1;
                            GP_ENTRY_ODT: begin
                                odt_seen <= 1'b1;
                            end
                            GP_EXIT_ODT: begin
                                odt_seen <= 1'b0;
                            end
                            GP_ACK_EVENT:    event_ack_seen <= 1'b1;
                            default: ;
                        endcase
                    end

                    if (io_write) begin
                        last_data_phase <= bus_write_data;
                        if (swr_write) begin
                            swr_reg <= bus_write_data;
                        end
                    end

                    if (mem_write_armed) begin
                        mem_write_data_latched <= data_for_write(mem_write_aio, mem_write_addr[0], bus_write_data);
                        mem_write_data_valid <= 1'b1;
                        mem_write_armed <= 1'b0;
                        last_data_phase <= data_for_write(mem_write_aio, mem_write_addr[0], bus_write_data);
                    end
                end

                if (mem_write_data_valid && !ctrl_busy && !ctrl_start) begin
                    ctrl_write <= 1'b1;
                    ctrl_byte_en <= byte_enable_for_write(mem_write_aio, mem_write_addr[0]);
                    ctrl_addr <= mem_write_addr;
                    ctrl_wdata <= mem_write_data_latched;
                    ctrl_start <= 1'b1;
                    mem_write_data_valid <= 1'b0;
                    mem_write_pending <= 1'b1;
                end

                if (kl11_read && !bufctl_n) begin
                    last_data_phase <= kl11_rdata;
                end
                if (pc11_read && !bufctl_n) begin
                    last_data_phase <= pc11_rdata;
                end
                if (swr_read && !bufctl_n) begin
                    last_data_phase <= swr_reg;
                end
            end
        end
    end

    /* verilator lint_off UNUSED */
    wire unused_diag_seen = diag1_seen & diag2_seen & diag3_seen & event_ack_seen;
    wire unused_sd_status = sd_initialized & sd_active;
    wire unused_uart_params = |{CLK_HZ[31:0], UART_BAUD[31:0]};
    wire unused_bus_bs = |bus_bs;
    /* verilator lint_on UNUSED */
endmodule

`default_nettype wire
