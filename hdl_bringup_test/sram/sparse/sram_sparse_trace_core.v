`default_nettype none

module sram_sparse_trace_core #(
    parameter integer CLK_HZ                  = 50_000_000,
    parameter integer UART_BAUD               = 115_200,
    parameter integer READ_WAIT_CYCLES        = 3,
    parameter integer WRITE_WAIT_CYCLES       = 3,
    parameter integer POST_WRITE_DELAY_CYCLES = 250_000
) (
    input  wire       clk,
    input  wire       reset_n,

    output reg [20:0] sram_addr,
    input  wire [7:0] sram_dq_lo_in,
    input  wire [7:0] sram_dq_hi_in,
    output reg [7:0]  sram_dq_lo_out,
    output reg [7:0]  sram_dq_hi_out,
    output reg        sram_dq_lo_drive,
    output reg        sram_dq_hi_drive,
    output reg        sram_ce1_n,
    output reg        sram_oe_n,
    output reg        sram_we_lo_n,
    output reg        sram_we_hi_n,

    output wire       uart_tx,
    output reg        test_done,
    output reg        test_error
);
    localparam [5:0] TRACE_COUNT = 6'd32;
    localparam integer READ_LIMIT =
        (READ_WAIT_CYCLES <= 0) ? 1 : READ_WAIT_CYCLES;
    localparam integer WRITE_LIMIT =
        (WRITE_WAIT_CYCLES <= 0) ? 1 : WRITE_WAIT_CYCLES;
    localparam integer DELAY_LIMIT =
        (POST_WRITE_DELAY_CYCLES <= 0) ? 1 : POST_WRITE_DELAY_CYCLES;

    localparam [0:0] LANE_LO = 1'b0;
    localparam [0:0] LANE_HI = 1'b1;

    localparam [1:0] OP_WRITE = 2'd1;
    localparam [1:0] OP_READ  = 2'd2;

    localparam [4:0] ST_START_LOG       = 5'd0;
    localparam [4:0] ST_LOG             = 5'd1;
    localparam [4:0] ST_LANE_BEGIN      = 5'd2;
    localparam [4:0] ST_PREP_WRITE      = 5'd3;
    localparam [4:0] ST_MEM_SETUP       = 5'd4;
    localparam [4:0] ST_MEM_WAIT        = 5'd5;
    localparam [4:0] ST_MEM_END         = 5'd6;
    localparam [4:0] ST_LOG_WRITE       = 5'd7;
    localparam [4:0] ST_POST_WRITE_WAIT = 5'd8;
    localparam [4:0] ST_PREP_READ       = 5'd9;
    localparam [4:0] ST_LOG_READ        = 5'd10;
    localparam [4:0] ST_NEXT_ITEM       = 5'd11;
    localparam [4:0] ST_LANE_DONE       = 5'd12;
    localparam [4:0] ST_FINISH_LOG      = 5'd13;
    localparam [4:0] ST_DONE            = 5'd14;
    localparam [4:0] ST_SWITCH_LANE     = 5'd15;

    localparam [2:0] LOG_START      = 3'd0;
    localparam [2:0] LOG_LANE_BEGIN = 3'd1;
    localparam [2:0] LOG_WRITE      = 3'd2;
    localparam [2:0] LOG_READ       = 3'd3;
    localparam [2:0] LOG_LANE_DONE  = 3'd4;
    localparam [2:0] LOG_SUMMARY    = 3'd5;

    reg [4:0]  state;
    reg [4:0]  resume_state;
    reg [4:0]  mem_return_state;
    reg [1:0]  mem_op;
    reg        lane;
    reg        mem_lane;
    reg [5:0]  trace_index;
    reg [20:0] current_addr;
    reg [7:0]  current_wdata;
    reg [7:0]  current_rdata;
    reg [31:0] wait_count;
    reg [2:0]  log_kind;
    reg [5:0]  log_index;
    reg        log_ok;
    reg        uart_start;
    reg [7:0]  uart_data;
    wire       uart_busy;

    uart_tx #(
        .CLK_HZ(CLK_HZ),
        .BAUD(UART_BAUD)
    ) debug_uart (
        .clk(clk),
        .reset_n(reset_n),
        .start(uart_start),
        .data(uart_data),
        .tx(uart_tx),
        .busy(uart_busy)
    );

    initial begin
        state             = ST_START_LOG;
        resume_state      = ST_LANE_BEGIN;
        mem_return_state  = ST_LOG_WRITE;
        mem_op            = 2'd0;
        lane              = LANE_LO;
        mem_lane          = LANE_LO;
        trace_index       = 6'd0;
        current_addr      = 21'd0;
        current_wdata     = 8'd0;
        current_rdata     = 8'd0;
        wait_count        = 32'd0;
        log_kind          = LOG_START;
        log_index         = 6'd0;
        log_ok            = 1'b1;
        uart_start        = 1'b0;
        uart_data         = 8'd0;
        sram_addr         = 21'd0;
        sram_dq_lo_out    = 8'd0;
        sram_dq_hi_out    = 8'd0;
        sram_dq_lo_drive  = 1'b0;
        sram_dq_hi_drive  = 1'b0;
        sram_ce1_n        = 1'b1;
        sram_oe_n         = 1'b1;
        sram_we_lo_n      = 1'b1;
        sram_we_hi_n      = 1'b1;
        test_done         = 1'b0;
        test_error        = 1'b0;
    end

    always @(posedge clk) begin
        uart_start <= 1'b0;

        if (!reset_n) begin
            state             <= ST_START_LOG;
            resume_state      <= ST_LANE_BEGIN;
            mem_return_state  <= ST_LOG_WRITE;
            mem_op            <= 2'd0;
            lane              <= LANE_LO;
            mem_lane          <= LANE_LO;
            trace_index       <= 6'd0;
            current_addr      <= 21'd0;
            current_wdata     <= 8'd0;
            current_rdata     <= 8'd0;
            wait_count        <= 32'd0;
            log_kind          <= LOG_START;
            log_index         <= 6'd0;
            log_ok            <= 1'b1;
            uart_data         <= 8'd0;
            sram_addr         <= 21'd0;
            sram_dq_lo_out    <= 8'd0;
            sram_dq_hi_out    <= 8'd0;
            sram_dq_lo_drive  <= 1'b0;
            sram_dq_hi_drive  <= 1'b0;
            sram_ce1_n        <= 1'b1;
            sram_oe_n         <= 1'b1;
            sram_we_lo_n      <= 1'b1;
            sram_we_hi_n      <= 1'b1;
            test_done         <= 1'b0;
            test_error        <= 1'b0;
        end else begin
            case (state)
                ST_START_LOG: begin
                    log_kind     <= LOG_START;
                    log_index    <= 6'd0;
                    resume_state <= ST_LANE_BEGIN;
                    state        <= ST_LOG;
                end

                ST_LOG: begin
                    if (!uart_busy && !uart_start) begin
                        uart_data  <= log_char(log_kind, log_index);
                        uart_start <= 1'b1;
                        if (log_index == (log_length(log_kind) - 1'b1)) begin
                            log_index <= 6'd0;
                            state     <= resume_state;
                        end else begin
                            log_index <= log_index + 1'b1;
                        end
                    end
                end

                ST_LANE_BEGIN: begin
                    trace_index  <= 6'd0;
                    log_kind     <= LOG_LANE_BEGIN;
                    log_index    <= 6'd0;
                    resume_state <= ST_PREP_WRITE;
                    state        <= ST_LOG;
                end

                ST_PREP_WRITE: begin
                    current_addr      <= trace_addr(trace_index);
                    current_wdata     <= trace_data(lane,
                                                    trace_index,
                                                    trace_addr(trace_index));
                    mem_lane          <= lane;
                    mem_op            <= OP_WRITE;
                    mem_return_state  <= ST_LOG_WRITE;
                    state             <= ST_MEM_SETUP;
                end

                ST_MEM_SETUP: begin
                    sram_addr        <= current_addr;
                    sram_ce1_n       <= 1'b0;
                    sram_oe_n        <= (mem_op == OP_READ) ? 1'b0 : 1'b1;
                    sram_we_lo_n     <= ((mem_op == OP_WRITE) &&
                                          (mem_lane == LANE_LO)) ? 1'b0 : 1'b1;
                    sram_we_hi_n     <= ((mem_op == OP_WRITE) &&
                                          (mem_lane == LANE_HI)) ? 1'b0 : 1'b1;
                    sram_dq_lo_drive <= ((mem_op == OP_WRITE) &&
                                          (mem_lane == LANE_LO));
                    sram_dq_hi_drive <= ((mem_op == OP_WRITE) &&
                                          (mem_lane == LANE_HI));
                    sram_dq_lo_out   <= current_wdata;
                    sram_dq_hi_out   <= current_wdata;
                    wait_count       <= 32'd0;
                    state            <= ST_MEM_WAIT;
                end

                ST_MEM_WAIT: begin
                    if (wait_count >= (((mem_op == OP_READ) ?
                                        READ_LIMIT[31:0] :
                                        WRITE_LIMIT[31:0]) - 1'b1)) begin
                        state <= ST_MEM_END;
                    end else begin
                        wait_count <= wait_count + 1'b1;
                    end
                end

                ST_MEM_END: begin
                    if (mem_op == OP_READ) begin
                        current_rdata <= (mem_lane == LANE_LO) ?
                                         sram_dq_lo_in : sram_dq_hi_in;
                    end
                    sram_ce1_n       <= 1'b1;
                    sram_oe_n        <= 1'b1;
                    sram_we_lo_n     <= 1'b1;
                    sram_we_hi_n     <= 1'b1;
                    sram_dq_lo_drive <= 1'b0;
                    sram_dq_hi_drive <= 1'b0;
                    state            <= mem_return_state;
                end

                ST_LOG_WRITE: begin
                    log_kind     <= LOG_WRITE;
                    log_index    <= 6'd0;
                    resume_state <= ST_POST_WRITE_WAIT;
                    state        <= ST_LOG;
                end

                ST_POST_WRITE_WAIT: begin
                    if (wait_count >= (DELAY_LIMIT[31:0] - 1'b1)) begin
                        wait_count <= 32'd0;
                        state      <= ST_PREP_READ;
                    end else begin
                        wait_count <= wait_count + 1'b1;
                    end
                end

                ST_PREP_READ: begin
                    mem_lane         <= lane;
                    mem_op           <= OP_READ;
                    mem_return_state <= ST_LOG_READ;
                    state            <= ST_MEM_SETUP;
                end

                ST_LOG_READ: begin
                    log_ok <= (current_rdata == current_wdata);
                    if (current_rdata != current_wdata) begin
                        test_error <= 1'b1;
                    end
                    log_kind     <= LOG_READ;
                    log_index    <= 6'd0;
                    resume_state <= ST_NEXT_ITEM;
                    state        <= ST_LOG;
                end

                ST_NEXT_ITEM: begin
                    if (trace_index == (TRACE_COUNT - 1'b1)) begin
                        state <= ST_LANE_DONE;
                    end else begin
                        trace_index <= trace_index + 1'b1;
                        state       <= ST_PREP_WRITE;
                    end
                end

                ST_LANE_DONE: begin
                    log_kind     <= LOG_LANE_DONE;
                    log_index    <= 6'd0;
                    if (lane == LANE_LO) begin
                        resume_state <= ST_SWITCH_LANE;
                    end else begin
                        resume_state <= ST_FINISH_LOG;
                    end
                    state <= ST_LOG;
                end

                ST_SWITCH_LANE: begin
                    lane  <= LANE_HI;
                    state <= ST_LANE_BEGIN;
                end

                ST_FINISH_LOG: begin
                    log_kind     <= LOG_SUMMARY;
                    log_index    <= 6'd0;
                    resume_state <= ST_DONE;
                    state        <= ST_LOG;
                end

                ST_DONE: begin
                    test_done         <= 1'b1;
                    sram_ce1_n        <= 1'b1;
                    sram_oe_n         <= 1'b1;
                    sram_we_lo_n      <= 1'b1;
                    sram_we_hi_n      <= 1'b1;
                    sram_dq_lo_drive  <= 1'b0;
                    sram_dq_hi_drive  <= 1'b0;
                end

                default: begin
                    state <= ST_START_LOG;
                end
            endcase
        end
    end

    function [20:0] trace_addr;
        input [5:0] index;
        begin
            case (index)
                6'd0:  trace_addr = 21'h000000;
                6'd1:  trace_addr = 21'h000001;
                6'd2:  trace_addr = 21'h000002;
                6'd3:  trace_addr = 21'h000003;
                6'd4:  trace_addr = 21'h000010;
                6'd5:  trace_addr = 21'h000055;
                6'd6:  trace_addr = 21'h0000aa;
                6'd7:  trace_addr = 21'h000100;
                6'd8:  trace_addr = 21'h001234;
                6'd9:  trace_addr = 21'h008000;
                6'd10: trace_addr = 21'h00abcd;
                6'd11: trace_addr = 21'h010000;
                6'd12: trace_addr = 21'h01f00f;
                6'd13: trace_addr = 21'h024680;
                6'd14: trace_addr = 21'h03579b;
                6'd15: trace_addr = 21'h055555;
                6'd16: trace_addr = 21'h07aaaa;
                6'd17: trace_addr = 21'h080000;
                6'd18: trace_addr = 21'h0a5a5a;
                6'd19: trace_addr = 21'h0c3c3c;
                6'd20: trace_addr = 21'h0f0f0f;
                6'd21: trace_addr = 21'h100000;
                6'd22: trace_addr = 21'h123456;
                6'd23: trace_addr = 21'h13579b;
                6'd24: trace_addr = 21'h155555;
                6'd25: trace_addr = 21'h17aaaa;
                6'd26: trace_addr = 21'h180001;
                6'd27: trace_addr = 21'h1a5a5a;
                6'd28: trace_addr = 21'h1c3c3c;
                6'd29: trace_addr = 21'h1e0001;
                6'd30: trace_addr = 21'h1ffffe;
                default: trace_addr = 21'h1fffff;
            endcase
        end
    endfunction

    function [7:0] trace_data;
        input        lane_sel;
        input [5:0]  index;
        input [20:0] addr;
        reg [7:0] folded;
        reg [7:0] index_mix;
        reg [7:0] salt;
        begin
            folded = addr[7:0] ^ addr[15:8] ^ {3'b000, addr[20:16]};
            index_mix = {index[3:0], index[5:2]} ^
                        {2'b10, index[5:0]};
            salt = lane_sel == LANE_LO ? 8'h3c : 8'h6d;
            trace_data = rotl8(folded ^ index_mix ^ salt,
                               index[2:0]) ^
                         (lane_sel == LANE_LO ? 8'ha5 : 8'hc7);
        end
    endfunction

    function [7:0] rotl8;
        input [7:0] value;
        input [2:0] amount;
        begin
            case (amount)
                3'd0: rotl8 = value;
                3'd1: rotl8 = {value[6:0], value[7]};
                3'd2: rotl8 = {value[5:0], value[7:6]};
                3'd3: rotl8 = {value[4:0], value[7:5]};
                3'd4: rotl8 = {value[3:0], value[7:4]};
                3'd5: rotl8 = {value[2:0], value[7:3]};
                3'd6: rotl8 = {value[1:0], value[7:2]};
                default: rotl8 = {value[0], value[7:1]};
            endcase
        end
    endfunction

    function [7:0] log_char;
        input [2:0] kind;
        input [5:0] index;
        begin
            case (kind)
                LOG_START: log_char = start_char(index);
                LOG_LANE_BEGIN: log_char = lane_begin_char(index);
                LOG_WRITE: log_char = write_char(index);
                LOG_READ: log_char = read_char(index);
                LOG_LANE_DONE: log_char = lane_done_char(index);
                default: log_char = summary_char(index);
            endcase
        end
    endfunction

    function [5:0] log_length;
        input [2:0] kind;
        begin
            case (kind)
                LOG_START:      log_length = 6'd25;
                LOG_LANE_BEGIN: log_length = 6'd10;
                LOG_WRITE:      log_length = 6'd27;
                LOG_READ:       log_length = 6'd39;
                LOG_LANE_DONE:  log_length = 6'd9;
                default:        log_length = 6'd17;
            endcase
        end
    endfunction

    function [7:0] lane_char;
        input        lane_sel;
        input [0:0]  which;
        begin
            if (lane_sel == LANE_LO) begin
                lane_char = which ? "o" : "l";
            end else begin
                lane_char = which ? "i" : "h";
            end
        end
    endfunction

    function [7:0] start_char;
        input [5:0] index;
        begin
            case (index)
                6'd0:  start_char = "s";
                6'd1:  start_char = "r";
                6'd2:  start_char = "a";
                6'd3:  start_char = "m";
                6'd4:  start_char = "_";
                6'd5:  start_char = "s";
                6'd6:  start_char = "p";
                6'd7:  start_char = "a";
                6'd8:  start_char = "r";
                6'd9:  start_char = "s";
                6'd10: start_char = "e";
                6'd11: start_char = "_";
                6'd12: start_char = "t";
                6'd13: start_char = "r";
                6'd14: start_char = "a";
                6'd15: start_char = "c";
                6'd16: start_char = "e";
                6'd17: start_char = "_";
                6'd18: start_char = "s";
                6'd19: start_char = "t";
                6'd20: start_char = "a";
                6'd21: start_char = "r";
                6'd22: start_char = "t";
                6'd23: start_char = 8'h0d;
                default: start_char = 8'h0a;
            endcase
        end
    endfunction

    function [7:0] lane_begin_char;
        input [5:0] index;
        begin
            case (index)
                6'd0: lane_begin_char = lane_char(lane, 1'b0);
                6'd1: lane_begin_char = lane_char(lane, 1'b1);
                6'd2: lane_begin_char = "_";
                6'd3: lane_begin_char = "b";
                6'd4: lane_begin_char = "e";
                6'd5: lane_begin_char = "g";
                6'd6: lane_begin_char = "i";
                6'd7: lane_begin_char = "n";
                6'd8: lane_begin_char = 8'h0d;
                default: lane_begin_char = 8'h0a;
            endcase
        end
    endfunction

    function [7:0] lane_done_char;
        input [5:0] index;
        begin
            case (index)
                6'd0: lane_done_char = lane_char(lane, 1'b0);
                6'd1: lane_done_char = lane_char(lane, 1'b1);
                6'd2: lane_done_char = "_";
                6'd3: lane_done_char = "d";
                6'd4: lane_done_char = "o";
                6'd5: lane_done_char = "n";
                6'd6: lane_done_char = "e";
                6'd7: lane_done_char = 8'h0d;
                default: lane_done_char = 8'h0a;
            endcase
        end
    endfunction

    function [7:0] write_char;
        input [5:0] index;
        begin
            case (index)
                6'd0:  write_char = lane_char(lane, 1'b0);
                6'd1:  write_char = lane_char(lane, 1'b1);
                6'd2:  write_char = "_";
                6'd3:  write_char = "w";
                6'd4:  write_char = "r";
                6'd5:  write_char = "_";
                6'd6:  write_char = "a";
                6'd7:  write_char = "d";
                6'd8:  write_char = "d";
                6'd9:  write_char = "r";
                6'd10: write_char = ":";
                6'd11: write_char = hex_digit({3'b000, current_addr[20]});
                6'd12: write_char = hex_digit(current_addr[19:16]);
                6'd13: write_char = hex_digit(current_addr[15:12]);
                6'd14: write_char = hex_digit(current_addr[11:8]);
                6'd15: write_char = hex_digit(current_addr[7:4]);
                6'd16: write_char = hex_digit(current_addr[3:0]);
                6'd17: write_char = "_";
                6'd18: write_char = "d";
                6'd19: write_char = "a";
                6'd20: write_char = "t";
                6'd21: write_char = "a";
                6'd22: write_char = ":";
                6'd23: write_char = hex_digit(current_wdata[7:4]);
                6'd24: write_char = hex_digit(current_wdata[3:0]);
                6'd25: write_char = 8'h0d;
                default: write_char = 8'h0a;
            endcase
        end
    endfunction

    function [7:0] read_char;
        input [5:0] index;
        begin
            case (index)
                6'd0:  read_char = lane_char(lane, 1'b0);
                6'd1:  read_char = lane_char(lane, 1'b1);
                6'd2:  read_char = "_";
                6'd3:  read_char = "r";
                6'd4:  read_char = "d";
                6'd5:  read_char = "_";
                6'd6:  read_char = "a";
                6'd7:  read_char = "d";
                6'd8:  read_char = "d";
                6'd9:  read_char = "r";
                6'd10: read_char = ":";
                6'd11: read_char = hex_digit({3'b000, current_addr[20]});
                6'd12: read_char = hex_digit(current_addr[19:16]);
                6'd13: read_char = hex_digit(current_addr[15:12]);
                6'd14: read_char = hex_digit(current_addr[11:8]);
                6'd15: read_char = hex_digit(current_addr[7:4]);
                6'd16: read_char = hex_digit(current_addr[3:0]);
                6'd17: read_char = "_";
                6'd18: read_char = "d";
                6'd19: read_char = "a";
                6'd20: read_char = "t";
                6'd21: read_char = "a";
                6'd22: read_char = ":";
                6'd23: read_char = hex_digit(current_rdata[7:4]);
                6'd24: read_char = hex_digit(current_rdata[3:0]);
                6'd25: read_char = "_";
                6'd26: read_char = "e";
                6'd27: read_char = "x";
                6'd28: read_char = "p";
                6'd29: read_char = ":";
                6'd30: read_char = hex_digit(current_wdata[7:4]);
                6'd31: read_char = hex_digit(current_wdata[3:0]);
                6'd32: read_char = "_";
                6'd33: read_char = "o";
                6'd34: read_char = "k";
                6'd35: read_char = ":";
                6'd36: read_char = log_ok ? "1" : "0";
                6'd37: read_char = 8'h0d;
                default: read_char = 8'h0a;
            endcase
        end
    endfunction

    function [7:0] summary_char;
        input [5:0] index;
        begin
            case (index)
                6'd0:  summary_char = "s";
                6'd1:  summary_char = "r";
                6'd2:  summary_char = "a";
                6'd3:  summary_char = "m";
                6'd4:  summary_char = "_";
                6'd5:  summary_char = "t";
                6'd6:  summary_char = "r";
                6'd7:  summary_char = "a";
                6'd8:  summary_char = "c";
                6'd9:  summary_char = "e";
                6'd10: summary_char = "_";
                6'd11: summary_char = test_error ? "f" : "p";
                6'd12: summary_char = test_error ? "a" : "a";
                6'd13: summary_char = test_error ? "i" : "s";
                6'd14: summary_char = test_error ? "l" : "s";
                6'd15: summary_char = 8'h0d;
                default: summary_char = 8'h0a;
            endcase
        end
    endfunction

    function [7:0] hex_digit;
        input [3:0] value;
        reg [3:0] digit;
        begin
            digit = value;
            hex_digit = (digit < 4'd10) ?
                        (8'h30 + {4'b0000, digit}) :
                        (8'h41 + {4'b0000, digit - 4'd10});
        end
    endfunction
endmodule

`default_nettype wire
