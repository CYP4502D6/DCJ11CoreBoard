`default_nettype none
`timescale 1ns/1ps

module tb_task7_sram_2kb_hello;
    localparam [3:0] AIO_GPREAD       = 4'b1110;
    localparam [3:0] AIO_DREAD        = 4'b1001;
    localparam [3:0] AIO_BUSWORDWRITE = 4'b0001;

    reg clk50;
    reg [21:16] dcj_dal_hi;
    reg [3:0] dcj_aio;
    reg [1:0] dcj_bs;
    reg dcj_ale_n;
    reg dcj_sctl_n;
    reg dcj_bufctl_n;
    reg dcj_strb_n;
    reg dcj_clk2;
    reg uart_rx;
    reg cpu_drive_dal;
    reg [15:0] cpu_dal_out;

    wire [15:0] dcj_dal;
    tri1 dcj_init_n;
    wire dcj_cont_n;
    wire dcj_abort_n;
    wire [1:0] dcj_irq;
    wire dcj_event_n;
    tri1 dcj_dv;
    tri1 dcj_miss_n;
    wire [20:0] sram_addr;
    wire [7:0] sram_dq_lo;
    wire [7:0] sram_dq_hi;
    wire sram_ce1_n;
    wire sram_oe_n;
    wire sram_we_lo_n;
    wire sram_we_hi_n;
    wire uart_tx;
    wire led_run;
    wire led_halt;
    wire led_fetch;
    wire led_read;
    wire led_write;
    wire led_inack;
    wire led_io_space;
    wire led_err;
    tri1 led_i2c_scl;
    tri1 led_i2c_sda;
    wire led_addr_en;
    wire led_data_en;

    assign dcj_dal = cpu_drive_dal ? cpu_dal_out : 16'hzzzz;

    initial clk50 = 1'b0;
    always #10 clk50 = ~clk50;

    initial dcj_clk2 = 1'b0;
    always #13 dcj_clk2 = ~dcj_clk2;

    top #(
        .INIT_HOLD_CYCLES(4),
        .POWER_ON_RESET_CYCLES(3),
        .SRAM_READ_WAIT_CYCLES(2),
        .SRAM_WRITE_WAIT_CYCLES(2),
        .NXM_ABORT_PULSE_CYCLES(16),
        .NXM_ABORT_LED_PULSE_CYCLES(128),
        .LED_POWERUP_DELAY_CYCLES(4),
        .LED_OSC_DELAY_CYCLES(4)
    ) dut (
        .clk50(clk50),
        .dcj_dal(dcj_dal),
        .dcj_dal_hi(dcj_dal_hi),
        .dcj_aio(dcj_aio),
        .dcj_bs(dcj_bs),
        .dcj_ale_n(dcj_ale_n),
        .dcj_sctl_n(dcj_sctl_n),
        .dcj_bufctl_n(dcj_bufctl_n),
        .dcj_strb_n(dcj_strb_n),
        .dcj_clk2(dcj_clk2),
        .dcj_init_n(dcj_init_n),
        .dcj_cont_n(dcj_cont_n),
        .dcj_abort_n(dcj_abort_n),
        .dcj_irq(dcj_irq),
        .dcj_event_n(dcj_event_n),
        .dcj_dv(dcj_dv),
        .dcj_miss_n(dcj_miss_n),
        .sram_addr(sram_addr),
        .sram_dq_lo(sram_dq_lo),
        .sram_dq_hi(sram_dq_hi),
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
        .led_i2c_scl(led_i2c_scl),
        .led_i2c_sda(led_i2c_sda),
        .led_addr_en(led_addr_en),
        .led_data_en(led_data_en)
    );

    cy62167_x8_model #(
        .ADDR_WIDTH(10)
    ) sram_lo (
        .addr(sram_addr[9:0]),
        .dq(sram_dq_lo),
        .ce1_n(sram_ce1_n),
        .oe_n(sram_oe_n),
        .we_n(sram_we_lo_n)
    );

    cy62167_x8_model #(
        .ADDR_WIDTH(10)
    ) sram_hi (
        .addr(sram_addr[9:0]),
        .dq(sram_dq_hi),
        .ce1_n(sram_ce1_n),
        .oe_n(sram_oe_n),
        .we_n(sram_we_hi_n)
    );

    task latch_cycle;
        input [3:0] aio;
        input [1:0] bs;
        input [21:16] addr_hi;
        input [15:0] dal_value;
        begin
            dcj_aio = aio;
            dcj_bs = bs;
            dcj_dal_hi = addr_hi;
            cpu_dal_out = dal_value;
            cpu_drive_dal = 1'b1;
            #15;
            dcj_ale_n = 1'b0;
            #40;
            dcj_ale_n = 1'b1;
            #80;
        end
    endtask

    task memory_read_cycle;
        input [21:0] addr;
        output [15:0] data;
        begin
            latch_cycle(AIO_DREAD, 2'b00, addr[21:16], addr[15:0]);
            cpu_drive_dal = 1'b0;
            wait (dcj_cont_n === 1'b1);
            wait (dcj_cont_n === 1'b0);
            #20;
            dcj_bufctl_n = 1'b0;
            #60;
            data = dcj_dal;
            dcj_bufctl_n = 1'b1;
            #80;
        end
    endtask

    task io_read_cycle;
        input [21:0] addr;
        output [15:0] data;
        begin
            latch_cycle(AIO_DREAD, 2'b10, addr[21:16], addr[15:0]);
            cpu_drive_dal = 1'b0;
            #40;
            dcj_bufctl_n = 1'b0;
            #80;
            data = dcj_dal;
            dcj_bufctl_n = 1'b1;
            #20;
            dcj_sctl_n = 1'b0;
            #60;
            dcj_sctl_n = 1'b1;
            #80;
        end
    endtask

    task io_write_cycle;
        input [21:0] addr;
        input [15:0] data;
        begin
            latch_cycle(AIO_BUSWORDWRITE, 2'b10, addr[21:16], addr[15:0]);
            cpu_dal_out = data;
            cpu_drive_dal = 1'b1;
            #40;
            dcj_sctl_n = 1'b0;
            #80;
            dcj_sctl_n = 1'b1;
            #80;
            cpu_drive_dal = 1'b0;
        end
    endtask

    task pup_read_cycle;
        output [15:0] data;
        begin
            latch_cycle(AIO_GPREAD, 2'b01, 6'h00, 16'h0000);
            cpu_drive_dal = 1'b0;
            #20;
            dcj_bufctl_n = 1'b0;
            #80;
            data = dcj_dal;
            dcj_bufctl_n = 1'b1;
            #80;
        end
    endtask

    task nxm_read_cycle;
        input [21:0] addr;
        begin
            latch_cycle(AIO_DREAD, 2'b00, addr[21:16], addr[15:0]);
            cpu_drive_dal = 1'b0;
            #100;
        end
    endtask

    task uart_get_byte;
        output [7:0] ch;
        integer bitn;
        begin
            if (uart_tx === 1'b1) begin
                @(negedge uart_tx);
            end
            repeat (651) @(posedge clk50);
            for (bitn = 0; bitn < 8; bitn = bitn + 1) begin
                ch[bitn] = uart_tx;
                repeat (434) @(posedge clk50);
            end
        end
    endtask

    initial begin
        dcj_dal_hi = 6'h00;
        dcj_aio = 4'hf;
        dcj_bs = 2'b00;
        dcj_ale_n = 1'b1;
        dcj_sctl_n = 1'b1;
        dcj_bufctl_n = 1'b1;
        dcj_strb_n = 1'b1;
        uart_rx = 1'b1;
        cpu_drive_dal = 1'b0;
        cpu_dal_out = 16'h0000;

        #1;
        if (dcj_init_n !== 1'b0) begin
            $fatal(1, "FPGA did not hold INIT low during preload");
        end

        wait (dcj_init_n === 1'b1);
        repeat (8) @(posedge clk50);

        if (dcj_cont_n !== 1'b0 || dcj_abort_n !== 1'b1 ||
            dcj_event_n !== 1'b1 || dcj_irq !== 2'b00) begin
            $fatal(1, "safe control defaults are wrong");
        end

        begin
            reg [15:0] data;
            reg [7:0] txch;

            memory_read_cycle(22'o001000, data);
            if (data !== 16'o105737) begin
                $fatal(1, "HELLO program first word mismatch: %h", data);
            end

            memory_read_cycle(22'o001002, data);
            if (data !== 16'o177564) begin
                $fatal(1, "HELLO first XCSR address mismatch: %h", data);
            end

            memory_read_cycle(22'o001004, data);
            if (data !== 16'o100375) begin
                $fatal(1, "HELLO first BPL mismatch: %h", data);
            end

            memory_read_cycle(22'o001006, data);
            if (data !== 16'o112737) begin
                $fatal(1, "HELLO first MOVB mismatch: %h", data);
            end

            memory_read_cycle(22'o001010, data);
            if (data !== 16'o000110) begin
                $fatal(1, "HELLO first immediate char mismatch: %h", data);
            end

            memory_read_cycle(22'o001012, data);
            if (data !== 16'o177566) begin
                $fatal(1, "HELLO first XBUF address mismatch: %h", data);
            end

            pup_read_cycle(data);
            if (data !== 16'b0000000_0_0000_0_01_1) begin
                $fatal(1, "PUP word mismatch: %h", data);
            end

            io_read_cycle(22'o17777564, data);
            if (data[7] !== 1'b1) begin
                $fatal(1, "KL11 XCSR did not report TX ready: %h", data);
            end

            io_write_cycle(22'o17777566, 16'h005a);
            uart_get_byte(txch);
            if (txch !== 8'h5a) begin
                $fatal(1, "KL11 TX byte mismatch: %h", txch);
            end

            io_write_cycle(22'o17777566, 16'h0048);
            io_write_cycle(22'o17777566, 16'h0045);
            io_write_cycle(22'o17777566, 16'h004c);
            io_write_cycle(22'o17777566, 16'h004c);
            io_write_cycle(22'o17777566, 16'h004f);
            io_write_cycle(22'o17777566, 16'h0057);
            io_write_cycle(22'o17777566, 16'h004f);
            io_write_cycle(22'o17777566, 16'h0052);
            io_write_cycle(22'o17777566, 16'h004c);
            io_write_cycle(22'o17777566, 16'h0044);
            uart_get_byte(txch);
            if (txch !== 8'h48) begin
                $fatal(1, "KL11 burst TX byte H mismatch: %h", txch);
            end
            uart_get_byte(txch);
            if (txch !== 8'h45) begin
                $fatal(1, "KL11 burst TX byte E mismatch: %h", txch);
            end
            uart_get_byte(txch);
            if (txch !== 8'h4c) begin
                $fatal(1, "KL11 burst TX byte L0 mismatch: %h", txch);
            end
            uart_get_byte(txch);
            if (txch !== 8'h4c) begin
                $fatal(1, "KL11 burst TX byte L1 mismatch: %h", txch);
            end
            uart_get_byte(txch);
            if (txch !== 8'h4f) begin
                $fatal(1, "KL11 burst TX byte O0 mismatch: %h", txch);
            end
            uart_get_byte(txch);
            if (txch !== 8'h57) begin
                $fatal(1, "KL11 burst TX byte W mismatch: %h", txch);
            end
            uart_get_byte(txch);
            if (txch !== 8'h4f) begin
                $fatal(1, "KL11 burst TX byte O1 mismatch: %h", txch);
            end
            uart_get_byte(txch);
            if (txch !== 8'h52) begin
                $fatal(1, "KL11 burst TX byte R mismatch: %h", txch);
            end
            uart_get_byte(txch);
            if (txch !== 8'h4c) begin
                $fatal(1, "KL11 burst TX byte L2 mismatch: %h", txch);
            end
            uart_get_byte(txch);
            if (txch !== 8'h44) begin
                $fatal(1, "KL11 burst TX byte D mismatch: %h", txch);
            end

            nxm_read_cycle(22'o004000);
            if (dcj_abort_n !== 1'b0) begin
                $fatal(1, "NXM did not assert ABORT_N");
            end
            repeat (24) @(posedge clk50);
            if (dcj_abort_n !== 1'b1) begin
                $fatal(1, "NXM ABORT_N did not release after pulse");
            end
            if (led_err !== 1'b0) begin
                $fatal(1, "ERR LED did not pulse on NXM");
            end
            repeat (140) @(posedge clk50);
            if (led_err !== 1'b1) begin
                $fatal(1, "ERR LED did not release after NXM pulse");
            end
        end

        $display("tb_task7_sram_2kb_hello PASS");
        $finish;
    end

    /* verilator lint_off UNUSEDSIGNAL */
    wire [14:0] unused_outputs = {
        dcj_dv,
        dcj_miss_n,
        sram_addr[20:10],
        led_i2c_scl,
        led_i2c_sda
    };
    wire [6:0] unused_leds = {
        led_run,
        led_halt,
        led_fetch,
        led_read,
        led_write,
        led_inack,
        led_io_space
    };
    wire unused_panel_en = led_addr_en | led_data_en;
    /* verilator lint_on UNUSEDSIGNAL */
endmodule

`default_nettype wire
