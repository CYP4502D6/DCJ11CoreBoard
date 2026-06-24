`default_nettype none

module aw21024_panel_driver #(
    parameter integer CLK_HZ                   = 50_000_000,
    parameter integer I2C_HZ                   = 100_000,
    parameter integer POWERUP_DELAY_CYCLES     = 100_000,
    parameter integer SOFT_RESET_DELAY_CYCLES  = 100_000,
    parameter [6:0]   ADDR_DEVICE_ADDR         = 7'h30,
    parameter [6:0]   DATA_DEVICE_ADDR         = 7'h31,
    parameter [7:0]   GLOBAL_CURRENT           = 8'h0f,
    parameter [7:0]   CHANNEL_CURRENT          = 8'hff,
    parameter [7:0]   LED_ON_BRIGHTNESS        = 8'hff,
    parameter [7:0]   LED_OFF_BRIGHTNESS       = 8'h00
) (
    input  wire        clk,
    input  wire        reset_n,
    input  wire [21:0] addr_value,
    input  wire [15:0] data_value,
    input  wire        i2c_sda_in,
    output wire        i2c_scl_drive_low,
    output wire        i2c_sda_drive_low,
    output reg         addr_en,
    output reg         data_en,
    output reg         ready,
    output reg         i2c_ack_error
);
    localparam [7:0] REG_GCR    = 8'h00;
    localparam [7:0] REG_BR0    = 8'h01;
    localparam [7:0] REG_UPDATE = 8'h49;
    localparam [7:0] REG_COL0   = 8'h4a;
    localparam [7:0] REG_GCCR   = 8'h6e;
    localparam [7:0] REG_RESET  = 8'h7f;

    localparam [7:0] GCR_CHIP_ENABLE = 8'h01;

    localparam [2:0] ST_POWERUP_WAIT = 3'd0;
    localparam [2:0] ST_START_WRITE  = 3'd1;
    localparam [2:0] ST_WAIT_WRITE   = 3'd2;
    localparam [2:0] ST_RESET_WAIT   = 3'd3;
    localparam [2:0] ST_IDLE         = 3'd4;

    localparam [1:0] PHASE_RESET     = 2'd0;
    localparam [1:0] PHASE_INIT      = 2'd1;
    localparam [1:0] PHASE_REFRESH   = 2'd2;

    localparam integer POWERUP_LIMIT =
        (POWERUP_DELAY_CYCLES <= 0) ? 1 : POWERUP_DELAY_CYCLES;
    localparam integer RESET_DELAY_LIMIT =
        (SOFT_RESET_DELAY_CYCLES <= 0) ? 1 : SOFT_RESET_DELAY_CYCLES;

    reg [2:0]  state;
    reg [1:0]  phase;
    reg [5:0]  seq_index;
    reg [31:0] delay_count;
    reg [21:0] refresh_addr_value;
    reg [15:0] refresh_data_value;
    reg [21:0] displayed_addr_value;
    reg [15:0] displayed_data_value;
    reg        display_valid;

    reg        write_start;
    reg [6:0]  write_dev_addr;
    reg [7:0]  write_reg_addr;
    reg [7:0]  write_reg_data;
    wire       write_busy;
    wire       write_done;
    wire       write_ack_error;

    wire [5:0] phase_count =
        (phase == PHASE_RESET) ? 6'd2 :
        (phase == PHASE_INIT) ? 6'd52 :
        6'd50;

    wire seq_done = (seq_index >= phase_count);

    aw21024_i2c_write #(
        .CLK_HZ(CLK_HZ),
        .I2C_HZ(I2C_HZ)
    ) i2c_writer (
        .clk(clk),
        .reset_n(reset_n),
        .start(write_start),
        .dev_addr(write_dev_addr),
        .reg_addr(write_reg_addr),
        .reg_data(write_reg_data),
        .sda_in(i2c_sda_in),
        .scl_drive_low(i2c_scl_drive_low),
        .sda_drive_low(i2c_sda_drive_low),
        .busy(write_busy),
        .done(write_done),
        .ack_error(write_ack_error)
    );

    initial begin
        state                = ST_POWERUP_WAIT;
        phase                = PHASE_RESET;
        seq_index            = 6'd0;
        delay_count          = 32'd0;
        refresh_addr_value   = 22'h000001;
        refresh_data_value   = 16'h0001;
        displayed_addr_value = 22'h000000;
        displayed_data_value = 16'h0000;
        display_valid        = 1'b0;
        write_start          = 1'b0;
        write_dev_addr       = 7'h00;
        write_reg_addr       = 8'h00;
        write_reg_data       = 8'h00;
        addr_en              = 1'b0;
        data_en              = 1'b0;
        ready                = 1'b0;
        i2c_ack_error        = 1'b0;
    end

    always @(posedge clk) begin
        write_start <= 1'b0;

        if (!reset_n) begin
            state                <= ST_POWERUP_WAIT;
            phase                <= PHASE_RESET;
            seq_index            <= 6'd0;
            delay_count          <= 32'd0;
            refresh_addr_value   <= 22'h000001;
            refresh_data_value   <= 16'h0001;
            displayed_addr_value <= 22'h000000;
            displayed_data_value <= 16'h0000;
            display_valid        <= 1'b0;
            write_dev_addr       <= 7'h00;
            write_reg_addr       <= 8'h00;
            write_reg_data       <= 8'h00;
            addr_en              <= 1'b0;
            data_en              <= 1'b0;
            ready                <= 1'b0;
            i2c_ack_error        <= 1'b0;
        end else begin
            if (write_ack_error) begin
                i2c_ack_error <= 1'b1;
            end

            case (state)
                ST_POWERUP_WAIT: begin
                    addr_en <= 1'b1;
                    data_en <= 1'b1;
                    ready   <= 1'b0;
                    if (delay_count >= (POWERUP_LIMIT[31:0] - 1'b1)) begin
                        delay_count <= 32'd0;
                        phase       <= PHASE_RESET;
                        seq_index   <= 6'd0;
                        state       <= ST_START_WRITE;
                    end else begin
                        delay_count <= delay_count + 1'b1;
                    end
                end

                ST_START_WRITE: begin
                    if (seq_done) begin
                        if (phase == PHASE_RESET) begin
                            delay_count <= 32'd0;
                            state       <= ST_RESET_WAIT;
                        end else if (phase == PHASE_INIT) begin
                            ready         <= 1'b1;
                            display_valid <= 1'b0;
                            state         <= ST_IDLE;
                        end else begin
                            displayed_addr_value <= refresh_addr_value;
                            displayed_data_value <= refresh_data_value;
                            display_valid        <= 1'b1;
                            state                <= ST_IDLE;
                        end
                    end else if (!write_busy) begin
                        write_dev_addr <= sequence_device(phase, seq_index);
                        write_reg_addr <= sequence_register(phase, seq_index);
                        write_reg_data <= sequence_data(phase, seq_index,
                                                        refresh_addr_value,
                                                        refresh_data_value);
                        write_start    <= 1'b1;
                        state          <= ST_WAIT_WRITE;
                    end
                end

                ST_WAIT_WRITE: begin
                    if (write_done) begin
                        seq_index <= seq_index + 1'b1;
                        state     <= ST_START_WRITE;
                    end
                end

                ST_RESET_WAIT: begin
                    if (delay_count >= (RESET_DELAY_LIMIT[31:0] - 1'b1)) begin
                        delay_count <= 32'd0;
                        phase       <= PHASE_INIT;
                        seq_index   <= 6'd0;
                        state       <= ST_START_WRITE;
                    end else begin
                        delay_count <= delay_count + 1'b1;
                    end
                end

                ST_IDLE: begin
                    if (!display_valid ||
                        (addr_value != displayed_addr_value) ||
                        (data_value != displayed_data_value)) begin
                        refresh_addr_value <= addr_value;
                        refresh_data_value <= data_value;
                        phase              <= PHASE_REFRESH;
                        seq_index          <= 6'd0;
                        state              <= ST_START_WRITE;
                    end
                end

                default: begin
                    state <= ST_POWERUP_WAIT;
                end
            endcase
        end
    end

    function [6:0] sequence_device;
        input [1:0] phase_sel;
        input [5:0] index;
        begin
            if (phase_sel == PHASE_RESET) begin
                sequence_device = (index == 6'd0) ? ADDR_DEVICE_ADDR :
                                                   DATA_DEVICE_ADDR;
            end else if (phase_sel == PHASE_INIT) begin
                if ((index == 6'd0) || (index == 6'd2) ||
                    ((index >= 6'd4) && (index <= 6'd27))) begin
                    sequence_device = ADDR_DEVICE_ADDR;
                end else begin
                    sequence_device = DATA_DEVICE_ADDR;
                end
            end else begin
                sequence_device = (index <= 6'd24) ? ADDR_DEVICE_ADDR :
                                                     DATA_DEVICE_ADDR;
            end
        end
    endfunction

    function [7:0] sequence_register;
        input [1:0] phase_sel;
        input [5:0] index;
        begin
            if (phase_sel == PHASE_RESET) begin
                sequence_register = REG_RESET;
            end else if (phase_sel == PHASE_INIT) begin
                if (index <= 6'd1) begin
                    sequence_register = REG_GCR;
                end else if (index <= 6'd3) begin
                    sequence_register = REG_GCCR;
                end else if (index <= 6'd27) begin
                    sequence_register = REG_COL0 + {2'b00, (index - 6'd4)};
                end else begin
                    sequence_register = REG_COL0 + {2'b00, (index - 6'd28)};
                end
            end else begin
                if (index <= 6'd23) begin
                    sequence_register = REG_BR0 + {2'b00, index};
                end else if (index == 6'd24) begin
                    sequence_register = REG_UPDATE;
                end else if (index <= 6'd48) begin
                    sequence_register = REG_BR0 + {2'b00, (index - 6'd25)};
                end else begin
                    sequence_register = REG_UPDATE;
                end
            end
        end
    endfunction

    function [7:0] sequence_data;
        input [1:0]  phase_sel;
        input [5:0]  index;
        input [21:0] addr_bits;
        input [15:0] data_bits;
        reg [5:0]    channel;
        begin
            channel = 6'd0;

            if (phase_sel == PHASE_RESET) begin
                sequence_data = 8'h00;
            end else if (phase_sel == PHASE_INIT) begin
                if (index <= 6'd1) begin
                    sequence_data = GCR_CHIP_ENABLE;
                end else if (index <= 6'd3) begin
                    sequence_data = GLOBAL_CURRENT;
                end else if (index <= 6'd27) begin
                    channel = index - 6'd4;
                    sequence_data = (channel < 6'd22) ? CHANNEL_CURRENT : 8'h00;
                end else begin
                    channel = index - 6'd28;
                    sequence_data = (channel < 6'd16) ? CHANNEL_CURRENT : 8'h00;
                end
            end else begin
                if (index <= 6'd23) begin
                    channel = index;
                    if ((channel < 6'd22) && addr_bits[channel[4:0]]) begin
                        sequence_data = LED_ON_BRIGHTNESS;
                    end else begin
                        sequence_data = LED_OFF_BRIGHTNESS;
                    end
                end else if (index == 6'd24) begin
                    sequence_data = 8'h00;
                end else if (index <= 6'd48) begin
                    channel = index - 6'd25;
                    if ((channel < 6'd16) && data_bits[channel[3:0]]) begin
                        sequence_data = LED_ON_BRIGHTNESS;
                    end else begin
                        sequence_data = LED_OFF_BRIGHTNESS;
                    end
                end else begin
                    sequence_data = 8'h00;
                end
            end
        end
    endfunction
endmodule

`default_nettype wire
