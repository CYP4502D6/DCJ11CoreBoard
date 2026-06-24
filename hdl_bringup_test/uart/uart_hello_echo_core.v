`default_nettype none

module uart_hello_echo_core #(
    parameter integer CLK_HZ                = 50_000_000,
    parameter integer BAUD                  = 115_200,
    parameter integer HELLO_INTERVAL_CYCLES = CLK_HZ,
    parameter integer LINE_BUFFER_SIZE      = 128
) (
    input  wire clk,
    input  wire reset_n,
    input  wire uart_rx_pin,
    output wire uart_tx_pin,
    output reg  hello_done,
    output reg  line_overflow,
    output wire rx_framing_error
);
    localparam integer HELLO_INTERVAL_LIMIT =
        (HELLO_INTERVAL_CYCLES <= 0) ? 1 : HELLO_INTERVAL_CYCLES;
    localparam integer LINE_LIMIT =
        (LINE_BUFFER_SIZE < 2) ? 2 : LINE_BUFFER_SIZE;

    localparam [7:0] CHAR_CR = 8'h0d;

    localparam [1:0] MODE_HELLO_WAIT = 2'd0;
    localparam [1:0] MODE_HELLO_SEND = 2'd1;
    localparam [1:0] MODE_ECHO       = 2'd2;

    reg [1:0]  mode;
    reg [31:0] interval_count;
    reg [2:0]  hello_count;
    reg [3:0]  hello_index;
    reg        tx_start;
    reg [7:0]  tx_data;
    wire       tx_busy;
    wire [7:0] rx_data;
    wire       rx_valid;

    reg [7:0] line_buf [0:LINE_LIMIT-1];
    reg [7:0] echo_buf [0:LINE_LIMIT-1];
    reg [7:0] line_len;
    reg [7:0] echo_len;
    reg [7:0] echo_index;
    reg       echo_pending;
    reg       dropping_line;

    integer i;

    uart_tx #(
        .CLK_HZ(CLK_HZ),
        .BAUD(BAUD)
    ) tx_inst (
        .clk(clk),
        .reset_n(reset_n),
        .start(tx_start),
        .data(tx_data),
        .tx(uart_tx_pin),
        .busy(tx_busy)
    );

    uart_rx #(
        .CLK_HZ(CLK_HZ),
        .BAUD(BAUD)
    ) rx_inst (
        .clk(clk),
        .reset_n(reset_n),
        .rx(uart_rx_pin),
        .data(rx_data),
        .valid(rx_valid),
        .framing_error(rx_framing_error)
    );

    initial begin
        mode           = MODE_HELLO_WAIT;
        interval_count = 32'd0;
        hello_count    = 3'd0;
        hello_index    = 4'd0;
        tx_start       = 1'b0;
        tx_data        = 8'h00;
        hello_done     = 1'b0;
        line_overflow  = 1'b0;
        line_len       = 8'd0;
        echo_len       = 8'd0;
        echo_index     = 8'd0;
        echo_pending   = 1'b0;
        dropping_line  = 1'b0;
        for (i = 0; i < LINE_LIMIT; i = i + 1) begin
            line_buf[i] = 8'h00;
            echo_buf[i] = 8'h00;
        end
    end

    always @(posedge clk) begin
        tx_start <= 1'b0;

        if (!reset_n) begin
            mode           <= MODE_HELLO_WAIT;
            interval_count <= 32'd0;
            hello_count    <= 3'd0;
            hello_index    <= 4'd0;
            tx_data        <= 8'h00;
            hello_done     <= 1'b0;
            line_overflow  <= 1'b0;
            line_len       <= 8'd0;
            echo_len       <= 8'd0;
            echo_index     <= 8'd0;
            echo_pending   <= 1'b0;
            dropping_line  <= 1'b0;
        end else begin
            line_overflow <= 1'b0;

            if (mode == MODE_ECHO) begin
                handle_received_byte();
                send_echo_byte();
            end

            case (mode)
                MODE_HELLO_WAIT: begin
                    if (interval_count >= (HELLO_INTERVAL_LIMIT[31:0] - 1'b1)) begin
                        interval_count <= 32'd0;
                        hello_index    <= 4'd0;
                        mode           <= MODE_HELLO_SEND;
                    end else begin
                        interval_count <= interval_count + 1'b1;
                    end
                end

                MODE_HELLO_SEND: begin
                    if (!tx_busy && !tx_start) begin
                        tx_data  <= hello_byte(hello_index);
                        tx_start <= 1'b1;

                        if (hello_index == 4'd10) begin
                            hello_index <= 4'd0;
                            if (hello_count == 3'd4) begin
                                hello_count  <= 3'd5;
                                hello_done   <= 1'b1;
                                mode         <= MODE_ECHO;
                                line_len     <= 8'd0;
                                echo_len     <= 8'd0;
                                echo_index   <= 8'd0;
                                echo_pending <= 1'b0;
                            end else begin
                                hello_count <= hello_count + 1'b1;
                                mode        <= MODE_HELLO_WAIT;
                            end
                        end else begin
                            hello_index <= hello_index + 1'b1;
                        end
                    end
                end

                MODE_ECHO: begin
                    hello_done <= 1'b1;
                end

                default: begin
                    mode <= MODE_HELLO_WAIT;
                end
            endcase
        end
    end

    task handle_received_byte;
        begin
            if (rx_valid) begin
                if (dropping_line) begin
                    if (rx_data == CHAR_CR) begin
                        dropping_line <= 1'b0;
                        line_len      <= 8'd0;
                    end
                end else if (rx_data == CHAR_CR) begin
                    if ((line_len < LINE_LIMIT[7:0]) && !echo_pending) begin
                        for (i = 0; i < LINE_LIMIT; i = i + 1) begin
                            echo_buf[i] <= line_buf[i];
                        end
                        echo_buf[line_len[6:0]] <= CHAR_CR;
                        echo_len           <= line_len + 1'b1;
                        echo_index         <= 8'd0;
                        echo_pending       <= 1'b1;
                        line_len           <= 8'd0;
                    end else begin
                        line_overflow <= 1'b1;
                        line_len      <= 8'd0;
                    end
                end else if (line_len < (LINE_LIMIT[7:0] - 1'b1)) begin
                    line_buf[line_len[6:0]] <= rx_data;
                    line_len           <= line_len + 1'b1;
                end else begin
                    line_overflow <= 1'b1;
                    dropping_line <= 1'b1;
                    line_len      <= 8'd0;
                end
            end
        end
    endtask

    task send_echo_byte;
        begin
            if (echo_pending && !tx_busy && !tx_start) begin
                tx_data  <= echo_buf[echo_index[6:0]];
                tx_start <= 1'b1;

                if (echo_index == (echo_len - 1'b1)) begin
                    echo_pending <= 1'b0;
                    echo_index   <= 8'd0;
                    echo_len     <= 8'd0;
                end else begin
                    echo_index <= echo_index + 1'b1;
                end
            end
        end
    endtask

    function [7:0] hello_byte;
        input [3:0] index;
        begin
            case (index)
                4'd0:  hello_byte = "h";
                4'd1:  hello_byte = "e";
                4'd2:  hello_byte = "l";
                4'd3:  hello_byte = "l";
                4'd4:  hello_byte = "o";
                4'd5:  hello_byte = " ";
                4'd6:  hello_byte = "w";
                4'd7:  hello_byte = "o";
                4'd8:  hello_byte = "r";
                4'd9:  hello_byte = "l";
                4'd10: hello_byte = "d";
                default: hello_byte = 8'h00;
            endcase
        end
    endfunction
endmodule

`default_nettype wire
