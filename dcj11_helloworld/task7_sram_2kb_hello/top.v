`default_nettype none

module top #(
    parameter integer CLK_HZ = 50_000_000,
    parameter integer INIT_HOLD_CYCLES = 12_500_000,
    parameter integer POWER_ON_RESET_CYCLES = 16,
    parameter integer SRAM_READ_WAIT_CYCLES = 4,
    parameter integer SRAM_WRITE_WAIT_CYCLES = 4,
    parameter integer SRAM_LIVE_DAL_SETTLE_CYCLES = 2,
    parameter integer NXM_ABORT_PULSE_CYCLES = 64,
    parameter integer NXM_ABORT_LED_PULSE_CYCLES = 1_000_000,
    parameter integer LED_I2C_HZ = 100_000,
    parameter integer LED_POWERUP_DELAY_CYCLES = 100_000,
    parameter integer LED_OSC_DELAY_CYCLES = 10_000,
    parameter         FPGA_DRIVE_INIT = 1'b1,
    parameter         DRIVE_MEM_READ_WITHOUT_BUFCTL = 1'b1
) (
    input  wire        clk50,

    inout  wire [15:0] dcj_dal,
    input  wire [21:16] dcj_dal_hi,
    input  wire [3:0]  dcj_aio,
    input  wire [1:0]  dcj_bs,
    input  wire        dcj_ale_n,
    input  wire        dcj_sctl_n,
    input  wire        dcj_bufctl_n,
    input  wire        dcj_strb_n,
    input  wire        dcj_clk2,
    inout  wire        dcj_init_n,
    output wire        dcj_cont_n,
    output wire        dcj_abort_n,
    output wire [1:0]  dcj_irq,
    output wire        dcj_event_n,
    inout  wire        dcj_dv,
    inout  wire        dcj_miss_n,

    output wire [20:0] sram_addr,
    inout  wire [7:0]  sram_dq_lo,
    inout  wire [7:0]  sram_dq_hi,
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
    inout  wire        led_i2c_scl,
    inout  wire        led_i2c_sda,
    output wire        led_addr_en,
    output wire        led_data_en
);
    localparam integer POR_LIMIT =
        (POWER_ON_RESET_CYCLES <= 0) ? 1 : POWER_ON_RESET_CYCLES;

    reg [31:0] por_count;
    reg        fpga_reset_n;
    reg [31:0] init_count;
    reg        init_drive_low;
    reg [21:0] latched_addr;
    reg [15:0] latched_dal;
    reg [15:0] write_dal;
    reg [3:0]  latched_aio;
    reg [1:0]  latched_bs;
    reg        ale_toggle;
    reg        sctl_toggle;

    wire [15:0] core_dal_out;
    wire        core_dal_oe;
    wire        core_cont_n;
    wire        core_abort_n;
    wire [1:0]  core_irq;
    wire        core_event_n;
    wire        core_miss_drive_low;
    wire [7:0]  core_sram_dq_lo_out;
    wire [7:0]  core_sram_dq_hi_out;
    wire        core_sram_dq_lo_drive;
    wire        core_sram_dq_hi_drive;
    wire        preload_done;
    wire [21:0] led_addr_value;
    wire [15:0] led_data_value;
    wire        led_i2c_scl_drive_low;
    wire        led_i2c_sda_drive_low;

    initial begin
        por_count      = 32'd0;
        fpga_reset_n   = 1'b0;
        init_count     = 32'd0;
        init_drive_low = FPGA_DRIVE_INIT;
        latched_addr   = 22'h000000;
        latched_dal    = 16'h0000;
        write_dal      = 16'h0000;
        latched_aio    = 4'hf;
        latched_bs     = 2'b00;
        ale_toggle     = 1'b0;
        sctl_toggle    = 1'b0;
    end

    always @(posedge clk50) begin
        if (!fpga_reset_n) begin
            if (por_count >= (POR_LIMIT[31:0] - 1'b1)) begin
                fpga_reset_n <= 1'b1;
            end else begin
                por_count <= por_count + 1'b1;
            end
        end
    end

    always @(posedge clk50) begin
        if (!fpga_reset_n) begin
            init_count     <= 32'd0;
            init_drive_low <= FPGA_DRIVE_INIT;
        end else if (!FPGA_DRIVE_INIT) begin
            init_count     <= 32'd0;
            init_drive_low <= 1'b0;
        end else if (!preload_done) begin
            init_count     <= 32'd0;
            init_drive_low <= 1'b1;
        end else if (init_count < INIT_HOLD_CYCLES[31:0]) begin
            init_count     <= init_count + 1'b1;
            init_drive_low <= 1'b1;
        end else begin
            init_drive_low <= 1'b0;
        end
    end

    // The falling edge is the board-proven latch point for PUP/ODT entry. A
    // rising-edge experiment made the CPU repeat power-up GPREAD cycles and
    // prevented ODT entry, so memory timing fixes must stay downstream of this.
    always @(negedge dcj_ale_n or negedge fpga_reset_n or negedge dcj_init_n) begin
        if (!fpga_reset_n || !dcj_init_n) begin
            latched_addr <= 22'h000000;
            latched_dal  <= 16'h0000;
            latched_aio  <= 4'hf;
            latched_bs   <= 2'b00;
            ale_toggle   <= 1'b0;
        end else begin
            latched_addr <= {dcj_dal_hi, dcj_dal};
            latched_dal  <= dcj_dal;
            latched_aio  <= dcj_aio;
            latched_bs   <= dcj_bs;
            ale_toggle   <= ~ale_toggle;
        end
    end

    always @(negedge dcj_sctl_n or negedge fpga_reset_n or negedge dcj_init_n) begin
        if (!fpga_reset_n || !dcj_init_n) begin
            write_dal   <= 16'h0000;
            sctl_toggle <= 1'b0;
        end else begin
            write_dal   <= dcj_dal;
            sctl_toggle <= ~sctl_toggle;
        end
    end

    assign dcj_dal    = core_dal_oe ? core_dal_out : 16'hzzzz;
    assign dcj_init_n = (FPGA_DRIVE_INIT && init_drive_low) ? 1'b0 : 1'bz;

    assign dcj_cont_n  = core_cont_n;
    assign dcj_abort_n = core_abort_n;
    assign dcj_irq     = core_irq;
    assign dcj_event_n = core_event_n;

    assign dcj_dv     = 1'bz;
    assign dcj_miss_n = core_miss_drive_low ? 1'b0 : 1'bz;
    assign sram_dq_lo = core_sram_dq_lo_drive ? core_sram_dq_lo_out : 8'hzz;
    assign sram_dq_hi = core_sram_dq_hi_drive ? core_sram_dq_hi_out : 8'hzz;
    assign led_i2c_scl = led_i2c_scl_drive_low ? 1'b0 : 1'bz;
    assign led_i2c_sda = led_i2c_sda_drive_low ? 1'b0 : 1'bz;

    dcj11_sram_2kb_hello_core #(
        .CLK_HZ(CLK_HZ),
        .SRAM_READ_WAIT_CYCLES(SRAM_READ_WAIT_CYCLES),
        .SRAM_WRITE_WAIT_CYCLES(SRAM_WRITE_WAIT_CYCLES),
        .DRIVE_MEM_READ_WITHOUT_BUFCTL(DRIVE_MEM_READ_WITHOUT_BUFCTL),
        .SRAM_LIVE_DAL_SETTLE_CYCLES(SRAM_LIVE_DAL_SETTLE_CYCLES),
        .NXM_ABORT_PULSE_CYCLES(NXM_ABORT_PULSE_CYCLES),
        .NXM_ABORT_LED_PULSE_CYCLES(NXM_ABORT_LED_PULSE_CYCLES)
    ) core (
        .clk(clk50),
        .reset_n(fpga_reset_n),
        .init_n_sense(dcj_init_n),
        .ale_toggle(ale_toggle),
        .sctl_toggle(sctl_toggle),
        .bus_addr(latched_addr),
        .bus_dal_in(latched_dal),
        .bus_write_data(write_dal),
        .bus_aio(latched_aio),
        .bus_bs(latched_bs),
        .bufctl_n(dcj_bufctl_n),
        .dal_out(core_dal_out),
        .dal_oe(core_dal_oe),
        .cont_n(core_cont_n),
        .abort_n(core_abort_n),
        .irq(core_irq),
        .event_n(core_event_n),
        .miss_drive_low(core_miss_drive_low),
        .sram_addr(sram_addr),
        .sram_dq_lo_in(sram_dq_lo),
        .sram_dq_hi_in(sram_dq_hi),
        .sram_dq_lo_out(core_sram_dq_lo_out),
        .sram_dq_hi_out(core_sram_dq_hi_out),
        .sram_dq_lo_drive(core_sram_dq_lo_drive),
        .sram_dq_hi_drive(core_sram_dq_hi_drive),
        .sram_ce1_n(sram_ce1_n),
        .sram_oe_n(sram_oe_n),
        .sram_we_lo_n(sram_we_lo_n),
        .sram_we_hi_n(sram_we_hi_n),
        .uart_rx(uart_rx),
        .uart_tx(uart_tx),
        .led_run(led_run),
        .led_halt(led_halt),
        .led_fetch(led_fetch),
        .led_read(led_read),
        .led_write(led_write),
        .led_inack(led_inack),
        .led_io_space(led_io_space),
        .led_err(led_err),
        .led_addr_value(led_addr_value),
        .led_data_value(led_data_value),
        .preload_done(preload_done)
    );

    aw21024_led_panel led_panel (
        .clk(clk50),
        .reset_n(fpga_reset_n),
        .addr_value(led_addr_value),
        .data_value(led_data_value),
        .i2c_scl_drive_low(led_i2c_scl_drive_low),
        .i2c_sda_drive_low(led_i2c_sda_drive_low),
        .addr_en(led_addr_en),
        .data_en(led_data_en)
    );

    /* verilator lint_off UNUSEDSIGNAL */
    wire [2:0] unused_dcj_inputs = {dcj_strb_n, dcj_clk2, dcj_dv};
    wire unused_led_params = |{
        LED_I2C_HZ[31:0],
        LED_POWERUP_DELAY_CYCLES[31:0],
        LED_OSC_DELAY_CYCLES[31:0]
    };
    /* verilator lint_on UNUSEDSIGNAL */
endmodule

`default_nettype wire
