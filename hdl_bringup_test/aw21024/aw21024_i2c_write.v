`default_nettype none

module aw21024_i2c_write #(
    parameter integer CLK_HZ = 50_000_000,
    parameter integer I2C_HZ = 100_000
) (
    input  wire       clk,
    input  wire       reset_n,
    input  wire       start,
    input  wire [6:0] dev_addr,
    input  wire [7:0] reg_addr,
    input  wire [7:0] reg_data,
    input  wire       sda_in,
    output reg        scl_drive_low,
    output reg        sda_drive_low,
    output reg        busy,
    output reg        done,
    output reg        ack_error
);
    localparam integer HALF_DIVIDER =
        ((I2C_HZ <= 0) || ((I2C_HZ * 2) >= CLK_HZ)) ? 1 :
        (CLK_HZ / (I2C_HZ * 2));

    localparam [3:0] ST_IDLE      = 4'd0;
    localparam [3:0] ST_START_A   = 4'd1;
    localparam [3:0] ST_START_B   = 4'd2;
    localparam [3:0] ST_START_C   = 4'd3;
    localparam [3:0] ST_LOAD_BYTE = 4'd4;
    localparam [3:0] ST_BIT_SETUP = 4'd5;
    localparam [3:0] ST_BIT_HIGH  = 4'd6;
    localparam [3:0] ST_BIT_LOW   = 4'd7;
    localparam [3:0] ST_ACK_SETUP = 4'd8;
    localparam [3:0] ST_ACK_HIGH  = 4'd9;
    localparam [3:0] ST_ACK_LOW   = 4'd10;
    localparam [3:0] ST_STOP_A    = 4'd11;
    localparam [3:0] ST_STOP_B    = 4'd12;
    localparam [3:0] ST_STOP_C    = 4'd13;

    reg [3:0]  state;
    reg [31:0] tick_count;
    reg [6:0]  latched_dev_addr;
    reg [7:0]  latched_reg_addr;
    reg [7:0]  latched_reg_data;
    reg [7:0]  current_byte;
    reg [1:0]  byte_index;
    reg [2:0]  bit_index;

    initial begin
        state            = ST_IDLE;
        tick_count       = 32'd0;
        latched_dev_addr = 7'h00;
        latched_reg_addr = 8'h00;
        latched_reg_data = 8'h00;
        current_byte     = 8'h00;
        byte_index       = 2'd0;
        bit_index        = 3'd7;
        scl_drive_low    = 1'b0;
        sda_drive_low    = 1'b0;
        busy             = 1'b0;
        done             = 1'b0;
        ack_error        = 1'b0;
    end

    always @(posedge clk) begin
        done <= 1'b0;

        if (!reset_n) begin
            state            <= ST_IDLE;
            tick_count       <= 32'd0;
            latched_dev_addr <= 7'h00;
            latched_reg_addr <= 8'h00;
            latched_reg_data <= 8'h00;
            current_byte     <= 8'h00;
            byte_index       <= 2'd0;
            bit_index        <= 3'd7;
            scl_drive_low    <= 1'b0;
            sda_drive_low    <= 1'b0;
            busy             <= 1'b0;
            ack_error        <= 1'b0;
        end else if (state == ST_IDLE) begin
            tick_count    <= 32'd0;
            scl_drive_low <= 1'b0;
            sda_drive_low <= 1'b0;
            busy          <= 1'b0;
            ack_error     <= 1'b0;

            if (start) begin
                latched_dev_addr <= dev_addr;
                latched_reg_addr <= reg_addr;
                latched_reg_data <= reg_data;
                byte_index       <= 2'd0;
                bit_index        <= 3'd7;
                busy             <= 1'b1;
                state            <= ST_START_A;
            end
        end else if ((tick_count + 32'd1) >= HALF_DIVIDER[31:0]) begin
            tick_count <= 32'd0;

            case (state)
                ST_START_A: begin
                    scl_drive_low <= 1'b0;
                    sda_drive_low <= 1'b0;
                    state         <= ST_START_B;
                end

                ST_START_B: begin
                    scl_drive_low <= 1'b0;
                    sda_drive_low <= 1'b1;
                    state         <= ST_START_C;
                end

                ST_START_C: begin
                    scl_drive_low <= 1'b1;
                    sda_drive_low <= 1'b1;
                    state         <= ST_LOAD_BYTE;
                end

                ST_LOAD_BYTE: begin
                    if (byte_index == 2'd0) begin
                        current_byte <= {latched_dev_addr, 1'b0};
                    end else if (byte_index == 2'd1) begin
                        current_byte <= latched_reg_addr;
                    end else begin
                        current_byte <= latched_reg_data;
                    end
                    bit_index     <= 3'd7;
                    scl_drive_low <= 1'b1;
                    state         <= ST_BIT_SETUP;
                end

                ST_BIT_SETUP: begin
                    scl_drive_low <= 1'b1;
                    sda_drive_low <= !current_byte[bit_index];
                    state         <= ST_BIT_HIGH;
                end

                ST_BIT_HIGH: begin
                    scl_drive_low <= 1'b0;
                    state         <= ST_BIT_LOW;
                end

                ST_BIT_LOW: begin
                    scl_drive_low <= 1'b1;
                    if (bit_index == 3'd0) begin
                        state <= ST_ACK_SETUP;
                    end else begin
                        bit_index <= bit_index - 1'b1;
                        state     <= ST_BIT_SETUP;
                    end
                end

                ST_ACK_SETUP: begin
                    scl_drive_low <= 1'b1;
                    sda_drive_low <= 1'b0;
                    state         <= ST_ACK_HIGH;
                end

                ST_ACK_HIGH: begin
                    scl_drive_low <= 1'b0;
                    if (sda_in != 1'b0) begin
                        ack_error <= 1'b1;
                    end
                    state <= ST_ACK_LOW;
                end

                ST_ACK_LOW: begin
                    scl_drive_low <= 1'b1;
                    if (byte_index == 2'd2) begin
                        sda_drive_low <= 1'b1;
                        state         <= ST_STOP_A;
                    end else begin
                        byte_index <= byte_index + 1'b1;
                        state      <= ST_LOAD_BYTE;
                    end
                end

                ST_STOP_A: begin
                    scl_drive_low <= 1'b1;
                    sda_drive_low <= 1'b1;
                    state         <= ST_STOP_B;
                end

                ST_STOP_B: begin
                    scl_drive_low <= 1'b0;
                    sda_drive_low <= 1'b1;
                    state         <= ST_STOP_C;
                end

                ST_STOP_C: begin
                    scl_drive_low <= 1'b0;
                    sda_drive_low <= 1'b0;
                    busy          <= 1'b0;
                    done          <= 1'b1;
                    state         <= ST_IDLE;
                end

                default: begin
                    state <= ST_IDLE;
                end
            endcase
        end else begin
            tick_count <= tick_count + 1'b1;
        end
    end
endmodule

`default_nettype wire
