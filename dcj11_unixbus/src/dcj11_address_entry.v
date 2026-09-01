`default_nettype none

module dcj11_address_entry #(
    parameter [21:0] BASE = 22'o00000000,
    parameter [21:0] LAST = BASE
) (
    input  wire [21:0] address,
    output wire        hit
);
    wire [20:0] word_address = address[21:1];
    assign hit = (word_address >= BASE[21:1]) &&
                 (word_address <= LAST[21:1]);
endmodule

`default_nettype wire
