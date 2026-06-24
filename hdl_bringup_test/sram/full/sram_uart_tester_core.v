`default_nettype none

module sram_uart_tester_core #(
    parameter integer CLK_HZ            = 50_000_000,
    parameter integer UART_BAUD         = 115_200,
    parameter integer READ_WAIT_CYCLES  = 3,
    parameter integer WRITE_WAIT_CYCLES = 3,
    parameter integer TEST_ADDR_BITS    = 21
) (
    input  wire        clk,
    input  wire        reset_n,

    output reg [20:0]  sram_addr,
    input  wire [7:0]  sram_dq_lo_in,
    input  wire [7:0]  sram_dq_hi_in,
    output reg [7:0]   sram_dq_lo_out,
    output reg [7:0]   sram_dq_hi_out,
    output reg         sram_dq_lo_drive,
    output reg         sram_dq_hi_drive,
    output reg         sram_ce1_n,
    output reg         sram_oe_n,
    output reg         sram_we_lo_n,
    output reg         sram_we_hi_n,

    output wire        uart_tx,
    output reg         test_done,
    output reg         test_error
);
    localparam integer READ_LIMIT =
        (READ_WAIT_CYCLES <= 0) ? 1 : READ_WAIT_CYCLES;
    localparam integer WRITE_LIMIT =
        (WRITE_WAIT_CYCLES <= 0) ? 1 : WRITE_WAIT_CYCLES;
    localparam integer ADDR_BITS =
        (TEST_ADDR_BITS < 1) ? 1 :
        ((TEST_ADDR_BITS > 21) ? 21 : TEST_ADDR_BITS);
    localparam [20:0] LAST_ADDR =
        (ADDR_BITS >= 21) ? 21'h1fffff : ((21'd1 << ADDR_BITS) - 1'b1);

    localparam [0:0] LANE_LO = 1'b0;
    localparam [0:0] LANE_HI = 1'b1;

    localparam [1:0] MEM_WRITE = 2'd1;
    localparam [1:0] MEM_READ  = 2'd2;

    localparam [4:0] ST_START_LOG       = 5'd0;
    localparam [4:0] ST_LOG             = 5'd1;
    localparam [4:0] ST_MEM_SETUP       = 5'd2;
    localparam [4:0] ST_MEM_WAIT        = 5'd3;
    localparam [4:0] ST_MEM_END         = 5'd4;
    localparam [4:0] ST_DATA_INIT       = 5'd5;
    localparam [4:0] ST_DATA_WRITE_DONE = 5'd6;
    localparam [4:0] ST_DATA_CHECK      = 5'd7;
    localparam [4:0] ST_ADDR_CLEAR_INIT = 5'd8;
    localparam [4:0] ST_ADDR_CLEAR_NEXT = 5'd9;
    localparam [4:0] ST_ADDR_WRITE_NEXT = 5'd10;
    localparam [4:0] ST_ADDR_CHECK_BASE = 5'd11;
    localparam [4:0] ST_ADDR_READ_NEXT  = 5'd12;
    localparam [4:0] ST_ADDR_CHECK_TAG  = 5'd13;
    localparam [4:0] ST_PATTERN_INIT    = 5'd14;
    localparam [4:0] ST_PATTERN_WRITE   = 5'd15;
    localparam [4:0] ST_PATTERN_WRITE_D = 5'd16;
    localparam [4:0] ST_PATTERN_READ    = 5'd17;
    localparam [4:0] ST_PATTERN_CHECK   = 5'd18;
    localparam [4:0] ST_LANE_DONE       = 5'd19;
    localparam [4:0] ST_FAIL_SUMMARY    = 5'd20;
    localparam [4:0] ST_DONE            = 5'd21;
    localparam [4:0] ST_PATTERN_WRITE_L = 5'd22;

    localparam [3:0] LOG_START     = 4'd0;
    localparam [3:0] LOG_DATA_OK   = 4'd1;
    localparam [3:0] LOG_ADDR_OK   = 4'd2;
    localparam [3:0] LOG_PAT_WRITE = 4'd3;
    localparam [3:0] LOG_PAT_READ  = 4'd4;
    localparam [3:0] LOG_PAT_OK    = 4'd5;
    localparam [3:0] LOG_LANE_PASS = 4'd6;
    localparam [3:0] LOG_FAIL      = 4'd7;
    localparam [3:0] LOG_SUM_PASS  = 4'd8;
    localparam [3:0] LOG_SUM_FAIL  = 4'd9;

    reg [4:0]  state;
    reg [4:0]  resume_state;
    reg [4:0]  mem_return_state;
    reg [1:0]  mem_op;
    reg        mem_lane;
    reg [20:0] mem_addr;
    reg [7:0]  mem_wdata;
    reg [7:0]  mem_rdata;
    reg [31:0] wait_count;

    reg        lane;
    reg [4:0]  data_step;
    reg [4:0]  addr_bit;
    reg [20:0] addr_counter;
    reg [1:0]  pattern_id;

    reg [3:0]  log_kind;
    reg [5:0]  log_index;
    reg        log_lane;
    reg [1:0]  log_pattern;
    reg [20:0] fail_addr;
    reg        fail_lane;
    reg [7:0]  fail_expected;
    reg [7:0]  fail_got;

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
        resume_state      = ST_DATA_INIT;
        mem_return_state  = ST_DATA_INIT;
        mem_op            = 2'd0;
        mem_lane          = LANE_LO;
        mem_addr          = 21'd0;
        mem_wdata         = 8'h00;
        mem_rdata         = 8'h00;
        wait_count        = 32'd0;
        lane              = LANE_LO;
        data_step         = 5'd0;
        addr_bit          = 5'd0;
        addr_counter      = 21'd0;
        pattern_id        = 2'd0;
        log_kind          = LOG_START;
        log_index         = 6'd0;
        log_lane          = LANE_LO;
        log_pattern       = 2'd0;
        fail_addr         = 21'd0;
        fail_lane         = LANE_LO;
        fail_expected     = 8'h00;
        fail_got          = 8'h00;
        uart_start        = 1'b0;
        uart_data         = 8'h00;
        sram_addr         = 21'd0;
        sram_dq_lo_out    = 8'h00;
        sram_dq_hi_out    = 8'h00;
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
            resume_state      <= ST_DATA_INIT;
            mem_return_state  <= ST_DATA_INIT;
            mem_op            <= 2'd0;
            mem_lane          <= LANE_LO;
            mem_addr          <= 21'd0;
            mem_wdata         <= 8'h00;
            mem_rdata         <= 8'h00;
            wait_count        <= 32'd0;
            lane              <= LANE_LO;
            data_step         <= 5'd0;
            addr_bit          <= 5'd0;
            addr_counter      <= 21'd0;
            pattern_id        <= 2'd0;
            log_kind          <= LOG_START;
            log_index         <= 6'd0;
            log_lane          <= LANE_LO;
            log_pattern       <= 2'd0;
            fail_addr         <= 21'd0;
            fail_lane         <= LANE_LO;
            fail_expected     <= 8'h00;
            fail_got          <= 8'h00;
            uart_data         <= 8'h00;
            sram_addr         <= 21'd0;
            sram_dq_lo_out    <= 8'h00;
            sram_dq_hi_out    <= 8'h00;
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
                    resume_state <= ST_DATA_INIT;
                    log_index    <= 6'd0;
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

                ST_MEM_SETUP: begin
                    sram_addr        <= mem_addr;
                    sram_ce1_n       <= 1'b0;
                    sram_oe_n        <= (mem_op == MEM_READ) ? 1'b0 : 1'b1;
                    sram_we_lo_n     <= ((mem_op == MEM_WRITE) &&
                                          (mem_lane == LANE_LO)) ? 1'b0 : 1'b1;
                    sram_we_hi_n     <= ((mem_op == MEM_WRITE) &&
                                          (mem_lane == LANE_HI)) ? 1'b0 : 1'b1;
                    sram_dq_lo_drive <= ((mem_op == MEM_WRITE) &&
                                          (mem_lane == LANE_LO));
                    sram_dq_hi_drive <= ((mem_op == MEM_WRITE) &&
                                          (mem_lane == LANE_HI));
                    sram_dq_lo_out   <= mem_wdata;
                    sram_dq_hi_out   <= mem_wdata;
                    wait_count       <= 32'd0;
                    state            <= ST_MEM_WAIT;
                end

                ST_MEM_WAIT: begin
                    if (wait_count >= (((mem_op == MEM_READ) ?
                                        READ_LIMIT[31:0] :
                                        WRITE_LIMIT[31:0]) - 1'b1)) begin
                        state <= ST_MEM_END;
                    end else begin
                        wait_count <= wait_count + 1'b1;
                    end
                end

                ST_MEM_END: begin
                    if (mem_op == MEM_READ) begin
                        mem_rdata <= (mem_lane == LANE_LO) ? sram_dq_lo_in :
                                                               sram_dq_hi_in;
                    end
                    sram_ce1_n       <= 1'b1;
                    sram_oe_n        <= 1'b1;
                    sram_we_lo_n     <= 1'b1;
                    sram_we_hi_n     <= 1'b1;
                    sram_dq_lo_drive <= 1'b0;
                    sram_dq_hi_drive <= 1'b0;
                    state            <= mem_return_state;
                end

                ST_DATA_INIT: begin
                    data_step        <= 5'd0;
                    mem_lane         <= lane;
                    mem_addr         <= 21'd0;
                    mem_wdata        <= data_pattern(5'd0);
                    mem_op           <= MEM_WRITE;
                    mem_return_state <= ST_DATA_WRITE_DONE;
                    state            <= ST_MEM_SETUP;
                end

                ST_DATA_WRITE_DONE: begin
                    mem_lane         <= lane;
                    mem_addr         <= 21'd0;
                    mem_op           <= MEM_READ;
                    mem_return_state <= ST_DATA_CHECK;
                    state            <= ST_MEM_SETUP;
                end

                ST_DATA_CHECK: begin
                    if (mem_rdata != data_pattern(data_step)) begin
                        fail_lane     <= lane;
                        fail_addr     <= 21'd0;
                        fail_expected <= data_pattern(data_step);
                        fail_got      <= mem_rdata;
                        test_error    <= 1'b1;
                        log_kind      <= LOG_FAIL;
                        resume_state  <= ST_FAIL_SUMMARY;
                        log_index     <= 6'd0;
                        state         <= ST_LOG;
                    end else if (data_step == 5'd15) begin
                        log_kind     <= LOG_DATA_OK;
                        log_lane     <= lane;
                        resume_state <= ST_ADDR_CLEAR_INIT;
                        log_index    <= 6'd0;
                        state        <= ST_LOG;
                    end else begin
                        data_step        <= data_step + 1'b1;
                        mem_lane         <= lane;
                        mem_addr         <= 21'd0;
                        mem_wdata        <= data_pattern(data_step + 1'b1);
                        mem_op           <= MEM_WRITE;
                        mem_return_state <= ST_DATA_WRITE_DONE;
                        state            <= ST_MEM_SETUP;
                    end
                end

                ST_ADDR_CLEAR_INIT: begin
                    addr_bit         <= 5'd0;
                    mem_lane         <= lane;
                    mem_addr         <= 21'd0;
                    mem_wdata        <= 8'h00;
                    mem_op           <= MEM_WRITE;
                    mem_return_state <= ST_ADDR_CLEAR_NEXT;
                    state            <= ST_MEM_SETUP;
                end

                ST_ADDR_CLEAR_NEXT: begin
                    if (addr_bit < ADDR_BITS[4:0]) begin
                        mem_lane         <= lane;
                        mem_addr         <= addr_from_bit(addr_bit);
                        mem_wdata        <= 8'h00;
                        mem_op           <= MEM_WRITE;
                        mem_return_state <= ST_ADDR_CLEAR_NEXT;
                        addr_bit         <= addr_bit + 1'b1;
                        state            <= ST_MEM_SETUP;
                    end else begin
                        addr_bit <= 5'd0;
                        state    <= ST_ADDR_WRITE_NEXT;
                    end
                end

                ST_ADDR_WRITE_NEXT: begin
                    if (addr_bit < ADDR_BITS[4:0]) begin
                        mem_lane         <= lane;
                        mem_addr         <= addr_from_bit(addr_bit);
                        mem_wdata        <= addr_tag(addr_bit);
                        mem_op           <= MEM_WRITE;
                        mem_return_state <= ST_ADDR_WRITE_NEXT;
                        addr_bit         <= addr_bit + 1'b1;
                        state            <= ST_MEM_SETUP;
                    end else begin
                        mem_lane         <= lane;
                        mem_addr         <= 21'd0;
                        mem_op           <= MEM_READ;
                        mem_return_state <= ST_ADDR_CHECK_BASE;
                        state            <= ST_MEM_SETUP;
                    end
                end

                ST_ADDR_CHECK_BASE: begin
                    if (mem_rdata != 8'h00) begin
                        fail_lane     <= lane;
                        fail_addr     <= 21'd0;
                        fail_expected <= 8'h00;
                        fail_got      <= mem_rdata;
                        test_error    <= 1'b1;
                        log_kind      <= LOG_FAIL;
                        resume_state  <= ST_FAIL_SUMMARY;
                        log_index     <= 6'd0;
                        state         <= ST_LOG;
                    end else begin
                        addr_bit <= 5'd0;
                        state    <= ST_ADDR_READ_NEXT;
                    end
                end

                ST_ADDR_READ_NEXT: begin
                    if (addr_bit < ADDR_BITS[4:0]) begin
                        mem_lane         <= lane;
                        mem_addr         <= addr_from_bit(addr_bit);
                        mem_op           <= MEM_READ;
                        mem_return_state <= ST_ADDR_CHECK_TAG;
                        state            <= ST_MEM_SETUP;
                    end else begin
                        log_kind     <= LOG_ADDR_OK;
                        log_lane     <= lane;
                        resume_state <= ST_PATTERN_INIT;
                        log_index    <= 6'd0;
                        state        <= ST_LOG;
                    end
                end

                ST_ADDR_CHECK_TAG: begin
                    if (mem_rdata != addr_tag(addr_bit)) begin
                        fail_lane     <= lane;
                        fail_addr     <= addr_from_bit(addr_bit);
                        fail_expected <= addr_tag(addr_bit);
                        fail_got      <= mem_rdata;
                        test_error    <= 1'b1;
                        log_kind      <= LOG_FAIL;
                        resume_state  <= ST_FAIL_SUMMARY;
                        log_index     <= 6'd0;
                        state         <= ST_LOG;
                    end else begin
                        addr_bit <= addr_bit + 1'b1;
                        state    <= ST_ADDR_READ_NEXT;
                    end
                end

                ST_PATTERN_INIT: begin
                    pattern_id   <= 2'd0;
                    addr_counter <= 21'd0;
                    log_kind     <= LOG_PAT_WRITE;
                    log_lane     <= lane;
                    log_pattern  <= 2'd0;
                    resume_state <= ST_PATTERN_WRITE;
                    log_index    <= 6'd0;
                    state        <= ST_LOG;
                end

                ST_PATTERN_WRITE_L: begin
                    log_kind     <= LOG_PAT_WRITE;
                    log_lane     <= lane;
                    log_pattern  <= pattern_id;
                    resume_state <= ST_PATTERN_WRITE;
                    log_index    <= 6'd0;
                    state        <= ST_LOG;
                end

                ST_PATTERN_WRITE: begin
                    mem_lane         <= lane;
                    mem_addr         <= addr_counter;
                    mem_wdata        <= mem_pattern(pattern_id,
                                                    lane,
                                                    addr_counter);
                    mem_op           <= MEM_WRITE;
                    mem_return_state <= ST_PATTERN_WRITE_D;
                    state            <= ST_MEM_SETUP;
                end

                ST_PATTERN_WRITE_D: begin
                    if (addr_counter == LAST_ADDR) begin
                        addr_counter <= 21'd0;
                        log_kind     <= LOG_PAT_READ;
                        log_lane     <= lane;
                        log_pattern  <= pattern_id;
                        resume_state <= ST_PATTERN_READ;
                        log_index    <= 6'd0;
                        state        <= ST_LOG;
                    end else begin
                        addr_counter <= addr_counter + 1'b1;
                        state        <= ST_PATTERN_WRITE;
                    end
                end

                ST_PATTERN_READ: begin
                    mem_lane         <= lane;
                    mem_addr         <= addr_counter;
                    mem_op           <= MEM_READ;
                    mem_return_state <= ST_PATTERN_CHECK;
                    state            <= ST_MEM_SETUP;
                end

                ST_PATTERN_CHECK: begin
                    if (mem_rdata != mem_pattern(pattern_id,
                                                 lane,
                                                 addr_counter)) begin
                        fail_lane     <= lane;
                        fail_addr     <= addr_counter;
                        fail_expected <= mem_pattern(pattern_id,
                                                     lane,
                                                     addr_counter);
                        fail_got      <= mem_rdata;
                        test_error    <= 1'b1;
                        log_kind      <= LOG_FAIL;
                        resume_state  <= ST_FAIL_SUMMARY;
                        log_index     <= 6'd0;
                        state         <= ST_LOG;
                    end else if (addr_counter == LAST_ADDR) begin
                        log_kind     <= LOG_PAT_OK;
                        log_lane     <= lane;
                        log_pattern  <= pattern_id;
                        log_index    <= 6'd0;
                        if (pattern_id == 2'd3) begin
                            resume_state <= ST_LANE_DONE;
                        end else begin
                            pattern_id   <= pattern_id + 1'b1;
                            addr_counter <= 21'd0;
                            resume_state <= ST_PATTERN_WRITE_L;
                        end
                        state <= ST_LOG;
                    end else begin
                        addr_counter <= addr_counter + 1'b1;
                        state        <= ST_PATTERN_READ;
                    end
                end

                ST_LANE_DONE: begin
                    log_kind     <= LOG_LANE_PASS;
                    log_lane     <= lane;
                    log_index    <= 6'd0;
                    if (lane == LANE_LO) begin
                        lane         <= LANE_HI;
                        resume_state <= ST_DATA_INIT;
                    end else begin
                        resume_state <= ST_DONE;
                    end
                    state <= ST_LOG;
                end

                ST_FAIL_SUMMARY: begin
                    log_kind     <= LOG_SUM_FAIL;
                    resume_state <= ST_DONE;
                    log_index    <= 6'd0;
                    state        <= ST_LOG;
                end

                ST_DONE: begin
                    sram_ce1_n       <= 1'b1;
                    sram_oe_n        <= 1'b1;
                    sram_we_lo_n     <= 1'b1;
                    sram_we_hi_n     <= 1'b1;
                    sram_dq_lo_drive <= 1'b0;
                    sram_dq_hi_drive <= 1'b0;
                    if (!test_done && !test_error) begin
                        log_kind     <= LOG_SUM_PASS;
                        resume_state <= ST_DONE;
                        log_index    <= 6'd0;
                        test_done    <= 1'b1;
                        state        <= ST_LOG;
                    end else begin
                        test_done <= 1'b1;
                    end
                end

                default: begin
                    state <= ST_START_LOG;
                end
            endcase
        end
    end

    function [7:0] data_pattern;
        input [4:0] step;
        begin
            if (step < 5'd8) begin
                data_pattern = 8'h01 << step[2:0];
            end else begin
                data_pattern = ~(8'h01 << (step[2:0]));
            end
        end
    endfunction

    function [20:0] addr_from_bit;
        input [4:0] bit_index;
        begin
            addr_from_bit = 21'd1 << bit_index;
        end
    endfunction

    function [7:0] addr_tag;
        input [4:0] bit_index;
        begin
            addr_tag = 8'h31 + {3'b000, bit_index};
        end
    endfunction

    function [7:0] mem_pattern;
        input [1:0]  pattern;
        input        lane_sel;
        input [20:0] addr;
        reg [7:0] mix;
        begin
            mix = addr[7:0] ^ addr[15:8] ^ {3'b000, addr[20:16]} ^
                  (lane_sel == LANE_LO ? 8'ha5 : 8'h5a);
            case (pattern)
                2'd0: mem_pattern = 8'h00;
                2'd1: mem_pattern = 8'hff;
                2'd2: mem_pattern = mix;
                default: mem_pattern = ~mix;
            endcase
        end
    endfunction

    function [7:0] hex_digit;
        input [3:0] value;
        begin
            if (value < 4'd10) begin
                hex_digit = "0" + {4'd0, value};
            end else begin
                hex_digit = "a" + {4'd0, (value - 4'd10)};
            end
        end
    endfunction

    function [7:0] hex_addr_char;
        input [20:0] addr;
        input [2:0]  index;
        reg [23:0] padded;
        begin
            padded = {3'b000, addr};
            case (index)
                3'd0: hex_addr_char = hex_digit(padded[23:20]);
                3'd1: hex_addr_char = hex_digit(padded[19:16]);
                3'd2: hex_addr_char = hex_digit(padded[15:12]);
                3'd3: hex_addr_char = hex_digit(padded[11:8]);
                3'd4: hex_addr_char = hex_digit(padded[7:4]);
                default: hex_addr_char = hex_digit(padded[3:0]);
            endcase
        end
    endfunction

    function [7:0] hex_byte_char;
        input [7:0] value;
        input       high_nibble;
        begin
            hex_byte_char = high_nibble ? hex_digit(value[7:4]) :
                                          hex_digit(value[3:0]);
        end
    endfunction

    function [5:0] log_length;
        input [3:0] kind;
        begin
            case (kind)
                LOG_START:     log_length = 6'd16;
                LOG_DATA_OK:   log_length = 6'd15;
                LOG_ADDR_OK:   log_length = 6'd15;
                LOG_PAT_WRITE: log_length = 6'd14;
                LOG_PAT_READ:  log_length = 6'd13;
                LOG_PAT_OK:    log_length = 6'd11;
                LOG_LANE_PASS: log_length = 6'd13;
                LOG_FAIL:      log_length = 6'd34;
                LOG_SUM_PASS:  log_length = 6'd15;
                default:       log_length = 6'd15;
            endcase
        end
    endfunction

    function [7:0] lane_char;
        input lane_sel;
        input second_char;
        begin
            if (lane_sel == LANE_LO) begin
                lane_char = second_char ? "o" : "l";
            end else begin
                lane_char = second_char ? "i" : "h";
            end
        end
    endfunction

    function [7:0] log_char;
        input [3:0] kind;
        input [5:0] index;
        begin
            case (kind)
                LOG_START: begin
                    case (index)
                        6'd0:  log_char = "s";
                        6'd1:  log_char = "r";
                        6'd2:  log_char = "a";
                        6'd3:  log_char = "m";
                        6'd4:  log_char = "_";
                        6'd5:  log_char = "t";
                        6'd6:  log_char = "e";
                        6'd7:  log_char = "s";
                        6'd8:  log_char = "t";
                        6'd9:  log_char = "_";
                        6'd10: log_char = "s";
                        6'd11: log_char = "t";
                        6'd12: log_char = "a";
                        6'd13: log_char = "r";
                        6'd14: log_char = "t";
                        default: log_char = 8'h0a;
                    endcase
                end

                LOG_DATA_OK, LOG_ADDR_OK: begin
                    case (index)
                        6'd0:  log_char = lane_char(log_lane, 1'b0);
                        6'd1:  log_char = lane_char(log_lane, 1'b1);
                        6'd2:  log_char = "_";
                        6'd3:  log_char = (kind == LOG_DATA_OK) ? "d" : "a";
                        6'd4:  log_char = (kind == LOG_DATA_OK) ? "a" : "d";
                        6'd5:  log_char = (kind == LOG_DATA_OK) ? "t" : "d";
                        6'd6:  log_char = (kind == LOG_DATA_OK) ? "a" : "r";
                        6'd7:  log_char = "_";
                        6'd8:  log_char = "b";
                        6'd9:  log_char = "u";
                        6'd10: log_char = "s";
                        6'd11: log_char = "_";
                        6'd12: log_char = "o";
                        6'd13: log_char = "k";
                        default: log_char = 8'h0a;
                    endcase
                end

                LOG_PAT_WRITE, LOG_PAT_READ, LOG_PAT_OK: begin
                    case (index)
                        6'd0: log_char = lane_char(log_lane, 1'b0);
                        6'd1: log_char = lane_char(log_lane, 1'b1);
                        6'd2: log_char = "_";
                        6'd3: log_char = "p";
                        6'd4: log_char = "a";
                        6'd5: log_char = "t";
                        6'd6: log_char = "0" + {6'd0, log_pattern};
                        6'd7: log_char = (kind == LOG_PAT_OK) ? "_" : "_";
                        6'd8: begin
                            if (kind == LOG_PAT_WRITE) log_char = "w";
                            else if (kind == LOG_PAT_READ) log_char = "r";
                            else log_char = "o";
                        end
                        6'd9: begin
                            if (kind == LOG_PAT_WRITE) log_char = "r";
                            else if (kind == LOG_PAT_READ) log_char = "e";
                            else log_char = "k";
                        end
                        6'd10: begin
                            if (kind == LOG_PAT_WRITE) log_char = "i";
                            else if (kind == LOG_PAT_READ) log_char = "a";
                            else log_char = 8'h0a;
                        end
                        6'd11: begin
                            if (kind == LOG_PAT_WRITE) log_char = "t";
                            else if (kind == LOG_PAT_READ) log_char = "d";
                            else log_char = 8'h0a;
                        end
                        6'd12: begin
                            if (kind == LOG_PAT_WRITE) log_char = "e";
                            else log_char = 8'h0a;
                        end
                        default: log_char = 8'h0a;
                    endcase
                end

                LOG_LANE_PASS: begin
                    case (index)
                        6'd0:  log_char = lane_char(log_lane, 1'b0);
                        6'd1:  log_char = lane_char(log_lane, 1'b1);
                        6'd2:  log_char = "_";
                        6'd3:  log_char = "l";
                        6'd4:  log_char = "a";
                        6'd5:  log_char = "n";
                        6'd6:  log_char = "e";
                        6'd7:  log_char = "_";
                        6'd8:  log_char = "p";
                        6'd9:  log_char = "a";
                        6'd10: log_char = "s";
                        6'd11: log_char = "s";
                        default: log_char = 8'h0a;
                    endcase
                end

                LOG_FAIL: begin
                    case (index)
                        6'd0:  log_char = "f";
                        6'd1:  log_char = "a";
                        6'd2:  log_char = "i";
                        6'd3:  log_char = "l";
                        6'd4:  log_char = "_";
                        6'd5:  log_char = lane_char(fail_lane, 1'b0);
                        6'd6:  log_char = lane_char(fail_lane, 1'b1);
                        6'd7:  log_char = "_";
                        6'd8:  log_char = "a";
                        6'd9:  log_char = "d";
                        6'd10: log_char = "d";
                        6'd11: log_char = "r";
                        6'd12: log_char = ":";
                        6'd13: log_char = hex_addr_char(fail_addr, 3'd0);
                        6'd14: log_char = hex_addr_char(fail_addr, 3'd1);
                        6'd15: log_char = hex_addr_char(fail_addr, 3'd2);
                        6'd16: log_char = hex_addr_char(fail_addr, 3'd3);
                        6'd17: log_char = hex_addr_char(fail_addr, 3'd4);
                        6'd18: log_char = hex_addr_char(fail_addr, 3'd5);
                        6'd19: log_char = "_";
                        6'd20: log_char = "e";
                        6'd21: log_char = "x";
                        6'd22: log_char = "p";
                        6'd23: log_char = ":";
                        6'd24: log_char = hex_byte_char(fail_expected, 1'b1);
                        6'd25: log_char = hex_byte_char(fail_expected, 1'b0);
                        6'd26: log_char = "_";
                        6'd27: log_char = "g";
                        6'd28: log_char = "o";
                        6'd29: log_char = "t";
                        6'd30: log_char = ":";
                        6'd31: log_char = hex_byte_char(fail_got, 1'b1);
                        6'd32: log_char = hex_byte_char(fail_got, 1'b0);
                        default: log_char = 8'h0a;
                    endcase
                end

                LOG_SUM_PASS, LOG_SUM_FAIL: begin
                    case (index)
                        6'd0:  log_char = "s";
                        6'd1:  log_char = "r";
                        6'd2:  log_char = "a";
                        6'd3:  log_char = "m";
                        6'd4:  log_char = "_";
                        6'd5:  log_char = "t";
                        6'd6:  log_char = "e";
                        6'd7:  log_char = "s";
                        6'd8:  log_char = "t";
                        6'd9:  log_char = "_";
                        6'd10: log_char = (kind == LOG_SUM_PASS) ? "p" : "f";
                        6'd11: log_char = (kind == LOG_SUM_PASS) ? "a" : "a";
                        6'd12: log_char = (kind == LOG_SUM_PASS) ? "s" : "i";
                        6'd13: log_char = (kind == LOG_SUM_PASS) ? "s" : "l";
                        default: log_char = 8'h0a;
                    endcase
                end

                default: begin
                    log_char = 8'h0a;
                end
            endcase
        end
    endfunction
endmodule

`default_nettype wire
