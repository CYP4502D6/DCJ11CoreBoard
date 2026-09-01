`default_nettype none

module dcj11_address_registry (
    input  wire [21:0] address,
    input  wire [3:0]  aio,
    input  wire [1:0]  bs,
    input  wire         peripheral_hit,
    input  wire [15:0] peripheral_data,

    output wire         read_registered,
    output wire         write_registered,
    output wire         read_peripheral,
    output wire         write_peripheral,
    output wire         internal_cycle,
    output wire         registered_write_sink,
    output wire [15:0]  read_data
);
    localparam [21:0] IO_PAGE_BASE = 22'o17760000;
    localparam [21:0] SWITCH_REG   = 22'o17777570;
    localparam [21:0] MSER_REG     = 22'o17777744;
    localparam [21:0] CCR_REG      = 22'o17777746;
    localparam [21:0] STACK_LIMIT  = 22'o17777774;

    localparam [3:0] AIO_ODT_READ   = 4'b0110;
    localparam [3:0] AIO_GP_WRITE   = 4'b0101;
    localparam [3:0] AIO_BYTE_WRITE = 4'b0011;
    localparam [3:0] AIO_WORD_WRITE = 4'b0001;

    wire kl11_range;
    wire kw11_range;
    wire rh11_range;
    wire switch_range;
    wire mser_range;
    wire ccr_range;
    wire stack_limit_range;

    wire registered_peripheral_range;
    dcj11_peripheral_address_map peripheral_map (
        .address(address),
        .kl11_range(kl11_range),
        .kw11_range(kw11_range),
        .rh11_range(rh11_range),
        .any_range(registered_peripheral_range)
    );
    dcj11_address_entry #(.BASE(SWITCH_REG), .LAST(SWITCH_REG)) switch_registration (
        .address(address), .hit(switch_range));
    dcj11_address_entry #(.BASE(MSER_REG), .LAST(MSER_REG)) mser_registration (
        .address(address), .hit(mser_range));
    dcj11_address_entry #(.BASE(CCR_REG), .LAST(CCR_REG)) ccr_registration (
        .address(address), .hit(ccr_range));
    dcj11_address_entry #(.BASE(STACK_LIMIT), .LAST(STACK_LIMIT)) stack_limit_registration (
        .address(address), .hit(stack_limit_range));

    wire aio_read = ((aio[3] == 1'b1) && (aio != 4'b1111)) ||
                    (aio == AIO_ODT_READ);
    wire aio_write = (aio == AIO_GP_WRITE) ||
                     (aio == AIO_BYTE_WRITE) ||
                     (aio == AIO_WORD_WRITE);
    wire external_io = ((bs == 2'b10) && (address >= IO_PAGE_BASE)) ||
                       ((bs == 2'b00) && (aio == AIO_ODT_READ) &&
                        (address >= IO_PAGE_BASE));
    wire valid_peripheral = external_io && registered_peripheral_range && peripheral_hit;

    assign internal_cycle = (bs == 2'b11) ||
                            ((bs == 2'b01) && ccr_range);

    wire fixed_zero_read = aio_read &&
        (((bs == 2'b01) && mser_range) ||
         (external_io && switch_range));
    wire fixed_zero_write = aio_write &&
        (((bs == 2'b01) && mser_range) ||
         (external_io && switch_range));

    wire compatibility_write_sink =
        (bs == 2'b10) && stack_limit_range &&
        (aio == AIO_WORD_WRITE);

    assign registered_write_sink = fixed_zero_write ||
                                   compatibility_write_sink ||
                                   (aio_write && internal_cycle);

    assign read_peripheral = aio_read && valid_peripheral;
    assign write_peripheral = aio_write && valid_peripheral;
    assign read_registered = read_peripheral || fixed_zero_read ||
                             (aio_read && internal_cycle);
    assign write_registered = write_peripheral || registered_write_sink;
    assign read_data = read_peripheral ? peripheral_data : 16'h0000;

endmodule

`default_nettype wire
