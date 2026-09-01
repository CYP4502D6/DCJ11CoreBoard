`default_nettype none

module top #(
    parameter integer POWER_ON_RESET_CYCLES = 16,
    parameter integer INIT_HOLD_CYCLES = 12500000,
    parameter integer SRAM_ACCESS_NS = 45,
    parameter integer SRAM_EXTRA_WAIT_CYCLES = 0,
    parameter integer SD_ACTIVITY_HOLD_CYCLES = 2500000
) (
    input  wire         clk50,
    inout  wire [15:0]  dcj_dal,
    input  wire [21:16] dcj_dal_hi,
    input  wire [3:0]   dcj_aio,
    input  wire [1:0]   dcj_bs,
    input  wire         dcj_ale_n,
    input  wire         dcj_sctl_n,
    input  wire         dcj_bufctl_n,
    input  wire         dcj_strb_n,
    input  wire         dcj_clk2,
    inout  wire         dcj_init_n,
    output wire         dcj_cont_n,
    inout  wire         dcj_abort_n,
    output wire [1:0]   dcj_irq,
    output wire         dcj_event_n,
    inout  wire         dcj_dv,
    inout  wire         dcj_miss_n,
    output wire [20:0]  sram_addr,
    inout  wire [7:0]   sram_dq_lo,
    inout  wire [7:0]   sram_dq_hi,
    output wire         sram_ce1_n,
    output wire         sram_oe_n,
    output wire         sram_we_lo_n,
    output wire         sram_we_hi_n,
    input  wire         uart_rx,
    output wire         uart_tx,
    output wire         sd_spi_sck,
    output wire         sd_spi_mosi,
    input  wire         sd_spi_miso,
    output wire         sd_spi_cs_n,
    output wire         sd_activity_led_n,
    output wire         led_run,
    output wire         led_halt,
    output wire         led_fetch,
    output wire         led_read,
    output wire         led_write,
    output wire         led_inack,
    output wire         led_io_space,
    output wire         led_err,
    inout  wire         led_i2c_scl,
    inout  wire         led_i2c_sda,
    output wire         led_addr_en,
    output wire         led_data_en
);
    localparam integer POR_LIMIT =
        (POWER_ON_RESET_CYCLES < 1) ? 1 : POWER_ON_RESET_CYCLES;

    reg [31:0] por_count = 0;
    reg fpga_reset_n = 1'b0;
    reg [31:0] init_count = 0;
    reg init_drive_low = 1'b1;
    (* async_reg = "true", altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    reg init_meta = 1'b0;
    (* async_reg = "true", altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    reg init_sync = 1'b0;

    wire [21:0] raw_address = {dcj_dal_hi, dcj_dal};
    wire bus_capture_reset_n = fpga_reset_n & dcj_init_n;

    wire [15:0] bus_dal_out;
    wire bus_dal_oe;
    wire bus_cont_n;
    wire bus_abort_n;
    wire bus_dv_drive_low;
    wire bus_miss_drive_low;
    wire bus_abort_led_n;
    wire bus_odt_seen;
    wire bus_reset;
    wire [21:0] last_address;
    wire [15:0] last_data;
    wire [3:0] last_aio;

    wire [21:0] peripheral_address;
    wire [21:0] peripheral_read_address;
    wire [21:0] peripheral_write_address;
    wire peripheral_read_pulse;
    wire peripheral_write_pulse;
    wire [15:0] peripheral_write_data;
    wire [1:0] peripheral_byte_enable;
    wire peripheral_hit;
    wire [15:0] peripheral_data;
    wire [1:0] peripheral_irq;
    wire [15:0] peripheral_vector0;
    wire [15:0] peripheral_vector1;
    wire [1:0] interrupt_ack;
    wire [15:0] interrupt_ack_vector;
    wire event_ack;

    wire cpu_mem_request_valid;
    wire cpu_mem_request_ready;
    wire cpu_mem_request_write;
    wire [21:0] cpu_mem_request_address;
    wire [15:0] cpu_mem_request_data;
    wire [1:0] cpu_mem_request_byte_enable;
    wire cpu_mem_response_valid;
    wire [15:0] cpu_mem_response_data;
    wire cpu_mem_response_error;
    wire cpu_rmw_lock;

    wire rh_mem_request_valid;
    wire rh_mem_request_ready;
    wire rh_mem_request_write;
    wire [21:0] rh_mem_request_address;
    wire [15:0] rh_mem_request_data;
    wire [1:0] rh_mem_request_byte_enable;
    wire rh_mem_response_valid;
    wire [15:0] rh_mem_response_data;
    wire rh_mem_response_error;
    wire sd_active;

    wire [15:0] sram_data_out;
    wire [1:0] sram_data_drive;
    wire [1:0] sram_we_n;
    wire preload_done;
    wire preload_error;
    wire [20:0] memory_sram_address;

    wire led_i2c_scl_drive_low;
    wire led_i2c_sda_drive_low;

    always @(posedge clk50) begin
        if (!fpga_reset_n) begin
            if (por_count == POR_LIMIT - 1)
                fpga_reset_n <= 1'b1;
            else
                por_count <= por_count + 1'b1;
        end
    end

    always @(posedge clk50) begin
        if (!fpga_reset_n || !preload_done || preload_error) begin
            init_count <= 0;
            init_drive_low <= 1'b1;
        end else if (init_count < INIT_HOLD_CYCLES) begin
            init_count <= init_count + 1'b1;
            init_drive_low <= 1'b1;
        end else begin
            init_drive_low <= 1'b0;
        end
    end

    always @(posedge clk50 or negedge fpga_reset_n) begin
        if (!fpga_reset_n) begin
            init_meta <= 1'b0;
            init_sync <= 1'b0;
        end else begin
            init_meta <= dcj_init_n;
            init_sync <= init_meta;
        end
    end

    assign dcj_dal = bus_dal_oe ? bus_dal_out : 16'hzzzz;
    assign dcj_init_n = init_drive_low ? 1'b0 : 1'bz;
    assign dcj_dv = bus_dv_drive_low ? 1'b0 : 1'bz;
    assign dcj_miss_n = bus_miss_drive_low ? 1'b0 : 1'bz;

    assign dcj_abort_n = bus_abort_n ? 1'bz : 1'b0;
    assign dcj_cont_n = bus_cont_n;
    assign dcj_irq = peripheral_irq;

    assign sram_dq_lo = sram_data_drive[0] ? sram_data_out[7:0] : 8'hzz;
    assign sram_dq_hi = sram_data_drive[1] ? sram_data_out[15:8] : 8'hzz;
    assign sram_we_lo_n = sram_we_n[0];
    assign sram_we_hi_n = sram_we_n[1];
    assign sram_addr = memory_sram_address;

    assign led_run = !(dcj_init_n && !bus_reset);
    assign led_halt = !bus_odt_seen;
    assign led_fetch = ~((last_aio == 4'b1100) || (last_aio == 4'b1000));
    assign led_read = ~(((last_aio[3] == 1'b1) && (last_aio != 4'b1111)) ||
                        (last_aio == 4'b0110));
    assign led_write = ~((last_aio == 4'b0101) ||
                         (last_aio == 4'b0011) ||
                         (last_aio == 4'b0001));
    assign led_inack = ~(last_aio == 4'b1101);
    assign led_io_space = ~(last_address >= 22'o17760000);
    assign led_err = bus_abort_led_n;
    assign led_i2c_scl = led_i2c_scl_drive_low ? 1'b0 : 1'bz;
    assign led_i2c_sda = led_i2c_sda_drive_low ? 1'b0 : 1'bz;


    activity_led_stretcher #(
        .HOLD_CYCLES(SD_ACTIVITY_HOLD_CYCLES)
    ) sd_activity_indicator (
        .clk(clk50),
        .reset_n(fpga_reset_n),
        .active(sd_active),
        .led_n(sd_activity_led_n)
    );

    dcj11_bus_core bus (
        .clk(clk50),
        .reset_n(bus_capture_reset_n),
        .enable(preload_done && !preload_error),
        .raw_address(raw_address),
        .raw_dal(dcj_dal),
        .raw_aio(dcj_aio),
        .raw_bs(dcj_bs),
        .ale_n(dcj_ale_n),
        .sctl_n(dcj_sctl_n),
        .strb_n(dcj_strb_n),
        .bufctl_n(dcj_bufctl_n),
        .dv_sense(dcj_dv),
        .abort_sense_n(dcj_abort_n),
        .peripheral_hit(peripheral_hit),
        .peripheral_data(peripheral_data),
        .peripheral_address(peripheral_address),
        .peripheral_read_address(peripheral_read_address),
        .peripheral_write_address(peripheral_write_address),
        .peripheral_read_pulse(peripheral_read_pulse),
        .peripheral_write_pulse(peripheral_write_pulse),
        .peripheral_write_data(peripheral_write_data),
        .peripheral_byte_enable(peripheral_byte_enable),
        .interrupt_requests(peripheral_irq),
        .interrupt_vector0(peripheral_vector0),
        .interrupt_vector1(peripheral_vector1),
        .interrupt_ack(interrupt_ack),
        .interrupt_ack_vector(interrupt_ack_vector),
        .event_ack(event_ack),
        .bus_reset(bus_reset),
        .cpu_mem_request_valid(cpu_mem_request_valid),
        .cpu_mem_request_ready(cpu_mem_request_ready),
        .cpu_mem_request_write(cpu_mem_request_write),
        .cpu_mem_request_address(cpu_mem_request_address),
        .cpu_mem_request_data(cpu_mem_request_data),
        .cpu_mem_request_byte_enable(cpu_mem_request_byte_enable),
        .cpu_mem_response_valid(cpu_mem_response_valid),
        .cpu_mem_response_data(cpu_mem_response_data),
        .cpu_mem_response_error(cpu_mem_response_error),
        .cpu_rmw_lock(cpu_rmw_lock),
        .dal_out(bus_dal_out),
        .dal_oe(bus_dal_oe),
        .cont_n(bus_cont_n),
        .abort_n(bus_abort_n),
        .dv_drive_low(bus_dv_drive_low),
        .miss_drive_low(bus_miss_drive_low),
        .abort_led_n(bus_abort_led_n),
        .odt_seen(bus_odt_seen),
        .last_address(last_address),
        .last_data(last_data),
        .last_aio(last_aio)
    );

    Dcj11PeripheralCore peripherals (
        .clock(clk50),
        .reset(~fpga_reset_n),
        .io_peripheralReset(~init_sync || bus_reset),
        .io_busAddress(peripheral_address),
        .io_busReadAddress(peripheral_read_address),
        .io_busWriteAddress(peripheral_write_address),
        .io_busReadPulse(peripheral_read_pulse),
        .io_busWritePulse(peripheral_write_pulse),
        .io_busDataIn(peripheral_write_data),
        .io_busByteEnable(peripheral_byte_enable),
        .io_busHit(peripheral_hit),
        .io_busDataOut(peripheral_data),
        .io_interruptAck(interrupt_ack),
        .io_interruptAckVector(interrupt_ack_vector),
        .io_eventAck(event_ack),
        .io_irq(peripheral_irq),
        .io_irqVector0(peripheral_vector0),
        .io_irqVector1(peripheral_vector1),
        .io_eventN(dcj_event_n),
        .io_rhMemRequestValid(rh_mem_request_valid),
        .io_rhMemRequestReady(rh_mem_request_ready),
        .io_rhMemRequestWrite(rh_mem_request_write),
        .io_rhMemRequestAddress(rh_mem_request_address),
        .io_rhMemRequestData(rh_mem_request_data),
        .io_rhMemRequestByteEnable(rh_mem_request_byte_enable),
        .io_rhMemResponseValid(rh_mem_response_valid),
        .io_rhMemResponseData(rh_mem_response_data),
        .io_rhMemResponseError(rh_mem_response_error),
        .io_uartRx(uart_rx),
        .io_uartTx(uart_tx),
        .io_sdMiso(sd_spi_miso),
        .io_sdSck(sd_spi_sck),
        .io_sdMosi(sd_spi_mosi),
        .io_sdCsN(sd_spi_cs_n),
        .io_sdActive(sd_active),
        .io_panelAddress(last_address),
        .io_panelData(last_data),
        .io_ledI2cSclDriveLow(led_i2c_scl_drive_low),
        .io_ledI2cSdaDriveLow(led_i2c_sda_drive_low),
        .io_ledAddressEnable(led_addr_en),
        .io_ledDataEnable(led_data_en)
    );

    dcj11_sram_subsystem #(
        .SRAM_ACCESS_NS(SRAM_ACCESS_NS),
        .SRAM_EXTRA_WAIT_CYCLES(SRAM_EXTRA_WAIT_CYCLES)
    ) memory (
        .clk(clk50),
        .reset_n(fpga_reset_n),
        .cpu_request_valid(cpu_mem_request_valid),
        .cpu_request_ready(cpu_mem_request_ready),
        .cpu_request_write(cpu_mem_request_write),
        .cpu_request_address(cpu_mem_request_address),
        .cpu_request_data(cpu_mem_request_data),
        .cpu_request_byte_enable(cpu_mem_request_byte_enable),
        .cpu_response_valid(cpu_mem_response_valid),
        .cpu_response_data(cpu_mem_response_data),
        .cpu_response_error(cpu_mem_response_error),
        .cpu_rmw_lock(cpu_rmw_lock),
        .rh_request_valid(rh_mem_request_valid),
        .rh_request_ready(rh_mem_request_ready),
        .rh_request_write(rh_mem_request_write),
        .rh_request_address(rh_mem_request_address),
        .rh_request_data(rh_mem_request_data),
        .rh_request_byte_enable(rh_mem_request_byte_enable),
        .rh_response_valid(rh_mem_response_valid),
        .rh_response_data(rh_mem_response_data),
        .rh_response_error(rh_mem_response_error),
        .sram_address(memory_sram_address),
        .sram_data_in({sram_dq_hi, sram_dq_lo}),
        .sram_data_out(sram_data_out),
        .sram_data_drive(sram_data_drive),
        .sram_ce_n(sram_ce1_n),
        .sram_oe_n(sram_oe_n),
        .sram_we_n(sram_we_n),
        .preload_done(preload_done),
        .preload_error(preload_error)
    );
endmodule

`default_nettype wire
