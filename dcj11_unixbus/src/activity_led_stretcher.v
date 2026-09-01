`default_nettype none

module activity_led_stretcher #(
    parameter integer HOLD_CYCLES = 2500000
) (
    input  wire clk,
    input  wire reset_n,
    input  wire active,
    output wire led_n
);
    localparam integer HOLD_LIMIT =
        (HOLD_CYCLES < 1) ? 1 : HOLD_CYCLES;

    reg [31:0] hold_count;

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n)
            hold_count <= 32'd0;
        else if (active)
            hold_count <= HOLD_LIMIT[31:0];
        else if (hold_count != 0)
            hold_count <= hold_count - 1'b1;
    end

    assign led_n = ~(active || (hold_count != 0));
endmodule

`default_nettype wire
