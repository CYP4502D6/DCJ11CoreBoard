`default_nettype none

module dcj11_sram_subsystem #(
    parameter integer CLOCK_PERIOD_NS = 20,
    parameter integer SRAM_ACCESS_NS = 45,
    parameter integer SRAM_EXTRA_WAIT_CYCLES = 0
) (
    input  wire         clk,
    input  wire         reset_n,

    input  wire         cpu_request_valid,
    output wire         cpu_request_ready,
    input  wire         cpu_request_write,
    input  wire [21:0]  cpu_request_address,
    input  wire [15:0]  cpu_request_data,
    input  wire [1:0]   cpu_request_byte_enable,
    output reg          cpu_response_valid,
    output reg  [15:0]  cpu_response_data,
    output reg          cpu_response_error,
    input  wire         cpu_rmw_lock,

    input  wire         rh_request_valid,
    output wire         rh_request_ready,
    input  wire         rh_request_write,
    input  wire [21:0]  rh_request_address,
    input  wire [15:0]  rh_request_data,
    input  wire [1:0]   rh_request_byte_enable,
    output reg          rh_response_valid,
    output reg  [15:0]  rh_response_data,
    output reg          rh_response_error,

    output reg  [20:0]  sram_address,
    input  wire [15:0]  sram_data_in,
    output reg  [15:0]  sram_data_out,
    output reg  [1:0]   sram_data_drive,
    output reg          sram_ce_n,
    output reg          sram_oe_n,
    output reg  [1:0]   sram_we_n,

    output reg          preload_done,
    output reg          preload_error
);
    localparam integer ACCESS_BASE =
        (SRAM_ACCESS_NS + CLOCK_PERIOD_NS - 1) / CLOCK_PERIOD_NS;
    localparam integer ACCESS_CYCLES =
        ((ACCESS_BASE < 1) ? 1 : ACCESS_BASE) + SRAM_EXTRA_WAIT_CYCLES;
    localparam [7:0] ACCESS_COUNT = ACCESS_CYCLES[7:0];

    localparam [3:0] ST_IDLE             = 4'd0;
    localparam [3:0] ST_READ             = 4'd1;
    localparam [3:0] ST_WRITE_SETUP      = 4'd2;
    localparam [3:0] ST_WRITE_PULSE      = 4'd3;
    localparam [3:0] ST_WRITE_HOLD       = 4'd4;
    localparam [3:0] ST_TURNAROUND       = 4'd5;

    localparam [1:0] OWNER_NONE = 2'd0;
    localparam [1:0] OWNER_CPU  = 2'd1;
    localparam [1:0] OWNER_RH   = 2'd2;
    localparam [1:0] OWNER_BOOT = 2'd3;

    localparam integer BOOT_WORDS = 36;
    localparam [5:0] BOOT_LAST_WORD = BOOT_WORDS[5:0] - 1'b1;

    function [15:0] boot_word;
        input [5:0] index;
        begin
            case (index)
                6'd0:  boot_word = 16'o012706;
                6'd1:  boot_word = 16'o002000;
                6'd2:  boot_word = 16'o012700;
                6'd3:  boot_word = 16'o000000;
                6'd4:  boot_word = 16'o012701;
                6'd5:  boot_word = 16'o176700;
                6'd6:  boot_word = 16'o012761;
                6'd7:  boot_word = 16'o000040;
                6'd8:  boot_word = 16'o000010;
                6'd9:  boot_word = 16'o010061;
                6'd10: boot_word = 16'o000010;
                6'd11: boot_word = 16'o012711;
                6'd12: boot_word = 16'o000021;
                6'd13: boot_word = 16'o012761;
                6'd14: boot_word = 16'o010000;
                6'd15: boot_word = 16'o000032;
                6'd16: boot_word = 16'o012761;
                6'd17: boot_word = 16'o177000;
                6'd18: boot_word = 16'o000002;
                6'd19: boot_word = 16'o005061;
                6'd20: boot_word = 16'o000004;
                6'd21: boot_word = 16'o005061;
                6'd22: boot_word = 16'o000006;
                6'd23: boot_word = 16'o005061;
                6'd24: boot_word = 16'o000034;
                6'd25: boot_word = 16'o012711;
                6'd26: boot_word = 16'o000071;
                6'd27: boot_word = 16'o105711;
                6'd28: boot_word = 16'o100376;
                6'd29: boot_word = 16'o005002;
                6'd30: boot_word = 16'o005003;
                6'd31: boot_word = 16'o012704;
                6'd32: boot_word = 16'o002020;
                6'd33: boot_word = 16'o005005;
                6'd34: boot_word = 16'o105011;
                6'd35: boot_word = 16'o005007;
                default: boot_word = 16'o000000;
            endcase
        end
    endfunction

    reg [3:0] state;
    reg [1:0] owner;
    reg [21:0] operation_address;
    reg [15:0] operation_data;
    reg [1:0] operation_lanes;
    reg operation_write;
    reg [7:0] access_count;
    reg [5:0] preload_index;

    wire rh_eligible = preload_done && rh_request_valid && !cpu_rmw_lock;

    wire cpu_eligible = preload_done && cpu_request_valid;

    wire choose_cpu = cpu_eligible &&
                      (!rh_eligible || (owner == OWNER_RH));
    wire choose_rh = rh_eligible && !choose_cpu;
    assign rh_request_ready = (state == ST_IDLE) && choose_rh;
    assign cpu_request_ready = (state == ST_IDLE) && choose_cpu;

    always @* begin
        sram_address = operation_address[21:1];
        sram_data_out = operation_data;
        sram_data_drive = 2'b00;
        sram_ce_n = 1'b1;
        sram_oe_n = 1'b1;
        sram_we_n = 2'b11;

        case (state)
            ST_READ: begin
                sram_ce_n = 1'b0;
                sram_oe_n = 1'b0;
            end
            ST_WRITE_SETUP,
            ST_WRITE_PULSE,
            ST_WRITE_HOLD: begin
                sram_ce_n = 1'b0;
                sram_data_drive = operation_lanes;
                if (state == ST_WRITE_PULSE) begin
                    sram_we_n[0] = ~operation_lanes[0];
                    sram_we_n[1] = ~operation_lanes[1];
                end
            end
            default: ;
        endcase
    end

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            state <= ST_IDLE;
            owner <= OWNER_NONE;
            operation_address <= 22'd0;
            operation_data <= 16'd0;
            operation_lanes <= 2'b00;
            operation_write <= 1'b0;
            access_count <= 8'd0;
            preload_index <= 6'd0;
            preload_done <= 1'b0;
            preload_error <= 1'b0;
            cpu_response_valid <= 1'b0;
            cpu_response_data <= 16'd0;
            cpu_response_error <= 1'b0;
            rh_response_valid <= 1'b0;
            rh_response_data <= 16'd0;
            rh_response_error <= 1'b0;
        end else begin
            case (state)
                ST_IDLE: begin
                    owner <= OWNER_NONE;
                    access_count <= 8'd0;
                    if (!preload_done) begin
                        owner <= OWNER_BOOT;
                        operation_address <= 22'o002000 + {15'd0, preload_index, 1'b0};
                        operation_data <= boot_word(preload_index);
                        operation_lanes <= 2'b11;
                        operation_write <= 1'b1;
                        state <= ST_WRITE_SETUP;
                    end else if (choose_rh) begin
                        rh_response_valid <= 1'b0;
                        rh_response_error <= 1'b0;
                        owner <= OWNER_RH;
                        operation_address <= rh_request_address;
                        operation_data <= rh_request_data;
                        operation_lanes <= rh_request_byte_enable;
                        operation_write <= rh_request_write;
                        state <= rh_request_write ? ST_WRITE_SETUP : ST_READ;
                    end else if (choose_cpu) begin
                        cpu_response_valid <= 1'b0;
                        cpu_response_error <= 1'b0;
                        owner <= OWNER_CPU;
                        operation_address <= cpu_request_address;
                        operation_data <= cpu_request_data;
                        operation_lanes <= cpu_request_byte_enable;
                        operation_write <= cpu_request_write;
                        state <= cpu_request_write ? ST_WRITE_SETUP : ST_READ;
                    end
                end

                ST_READ: begin
                    if (access_count + 1'b1 >= ACCESS_COUNT) begin
                        access_count <= 0;
                        if (owner == OWNER_CPU) begin
                            cpu_response_data <= sram_data_in;
                            cpu_response_valid <= 1'b1;
                        end else if (owner == OWNER_RH) begin
                            rh_response_data <= sram_data_in;
                            rh_response_valid <= 1'b1;
                        end
                        state <= ST_TURNAROUND;
                    end else begin
                        access_count <= access_count + 1'b1;
                    end
                end

                ST_WRITE_SETUP: begin
                    access_count <= 0;
                    state <= ST_WRITE_PULSE;
                end

                ST_WRITE_PULSE: begin
                    if (access_count + 1'b1 >= ACCESS_COUNT) begin
                        access_count <= 0;
                        state <= ST_WRITE_HOLD;
                    end else begin
                        access_count <= access_count + 1'b1;
                    end
                end

                ST_WRITE_HOLD: begin
                    if (owner == OWNER_BOOT) begin
                        if (preload_index == BOOT_LAST_WORD) begin
                            preload_done <= 1'b1;
                        end else begin
                            preload_index <= preload_index + 1'b1;
                        end
                    end else if (owner == OWNER_CPU) begin
                        cpu_response_data <= operation_data;
                        cpu_response_valid <= 1'b1;
                    end else if (owner == OWNER_RH) begin
                        rh_response_valid <= 1'b1;
                    end else begin
                        preload_error <= 1'b1;
                    end
                    state <= ST_TURNAROUND;
                end

                ST_TURNAROUND: begin
                    state <= ST_IDLE;
                end

                default: begin
                    preload_error <= 1'b1;
                    state <= ST_IDLE;
                end
            endcase
        end
    end
endmodule

`default_nettype wire
