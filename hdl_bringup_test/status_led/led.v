module top #(
    parameter integer CLK_HZ = 50000000,
    parameter integer STEP_HZ = 4,
    parameter LED_ACTIVE_LOW = 1'b0
) (
    input wire clk,
    input wire reset_n,

    output wire [7:0] status_led
);
    localparam integer STEP_DIVIDER = (STEP_HZ <= 0) ? CLK_HZ : (CLK_HZ / STEP_HZ);

    reg [7:0] status;
    reg [31:0] div_count;

    wire [7:0] led_drive = LED_ACTIVE_LOW ? ~status : status;

    assign status_led = led_drive;

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            div_count <= 32'd0;
            status <= 8'h01;
        end else begin
            if (div_count >= (STEP_DIVIDER[31:0] - 1'b1)) begin
                div_count <= 32'd0;
                status <= {status[6:0], status[7]};
            end else begin
                div_count <= div_count + 1'b1;
            end
        end
    end

endmodule
