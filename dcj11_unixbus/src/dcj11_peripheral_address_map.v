`default_nettype none

module dcj11_peripheral_address_map (
    input  wire [21:0] address,
    output wire        kl11_range,
    output wire        kw11_range,
    output wire        rh11_range,
    output wire        any_range
);
    localparam [21:0] KL11_BASE = 22'o17777560;
    localparam [21:0] KL11_LAST = 22'o17777566;
    localparam [21:0] KW11_BASE = 22'o17777546;
    localparam [21:0] RH11_BASE = 22'o17776700;
    localparam [21:0] RH11_LAST = 22'o17776752;

    dcj11_address_entry #(.BASE(KL11_BASE), .LAST(KL11_LAST)) kl11 (
        .address(address), .hit(kl11_range));
    dcj11_address_entry #(.BASE(KW11_BASE), .LAST(KW11_BASE)) kw11 (
        .address(address), .hit(kw11_range));
    dcj11_address_entry #(.BASE(RH11_BASE), .LAST(RH11_LAST)) rh11 (
        .address(address), .hit(rh11_range));

    assign any_range = kl11_range || kw11_range || rh11_range;
endmodule

`default_nettype wire
