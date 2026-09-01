`default_nettype none

module dcj11_bus_core #(
    parameter integer READ_SETUP_CYCLES = 3,
    parameter integer DV_RELEASE_CYCLES = 5,
    parameter integer ABORT_SETUP_CYCLES = 4,
    parameter integer ABORT_LED_CYCLES = 1000000
) (
    input  wire         clk,
    input  wire         reset_n,
    input  wire         enable,

    input  wire [21:0]  raw_address,
    input  wire [15:0]  raw_dal,
    input  wire [3:0]   raw_aio,
    input  wire [1:0]   raw_bs,
    input  wire         ale_n,
    input  wire         sctl_n,
    input  wire         strb_n,
    input  wire         bufctl_n,
    input  wire         dv_sense,
    input  wire         abort_sense_n,

    input  wire         peripheral_hit,
    input  wire [15:0]  peripheral_data,
    output wire [21:0]  peripheral_address,
    output reg  [21:0]  peripheral_read_address,
    output reg  [21:0]  peripheral_write_address,
    output reg          peripheral_read_pulse,
    output reg          peripheral_write_pulse,
    output reg  [15:0]  peripheral_write_data,
    output reg  [1:0]   peripheral_byte_enable,

    input  wire [1:0]   interrupt_requests,
    input  wire [15:0]  interrupt_vector0,
    input  wire [15:0]  interrupt_vector1,
    output reg  [1:0]   interrupt_ack,
    output reg  [15:0]  interrupt_ack_vector,
    output reg          event_ack,
    output reg          bus_reset,

    output reg          cpu_mem_request_valid,
    input  wire         cpu_mem_request_ready,
    output reg          cpu_mem_request_write,
    output reg  [21:0]  cpu_mem_request_address,
    output reg  [15:0]  cpu_mem_request_data,
    output reg  [1:0]   cpu_mem_request_byte_enable,
    input  wire         cpu_mem_response_valid,
    input  wire [15:0]  cpu_mem_response_data,
    input  wire         cpu_mem_response_error,
    output wire         cpu_rmw_lock,

    output wire [15:0]  dal_out,
    output wire         dal_oe,
    output wire         cont_n,
    output wire         abort_n,
    output wire         dv_drive_low,
    output wire         miss_drive_low,
    output wire         abort_led_n,
    output reg          odt_seen,
    output reg  [21:0]  last_address,
    output reg  [15:0]  last_data,
    output reg  [3:0]   last_aio
);
    localparam [3:0] AIO_NIO        = 4'b1111;
    localparam [3:0] AIO_GP_READ    = 4'b1110;
    localparam [3:0] AIO_INTACK     = 4'b1101;
    localparam [3:0] AIO_RMW_LOCKED = 4'b1010;
    localparam [3:0] AIO_ODT_READ   = 4'b0110;
    localparam [3:0] AIO_GP_WRITE   = 4'b0101;
    localparam [3:0] AIO_BYTE_WRITE = 4'b0011;
    localparam [3:0] AIO_WORD_WRITE = 4'b0001;
    localparam [21:0] IO_PAGE_BASE  = 22'o17760000;
    localparam [15:0] POWER_UP_WORD = 16'o000003;

    localparam [3:0] ST_IDLE          = 4'd0;
    localparam [3:0] ST_DECODE        = 4'd1;
    localparam [3:0] ST_MEM_REQUEST   = 4'd2;
    localparam [3:0] ST_MEM_RESPONSE  = 4'd3;
    localparam [3:0] ST_WAIT_SCTL     = 4'd4;
    localparam [3:0] ST_COMMIT_WRITE  = 4'd5;
    localparam [3:0] ST_DATA_SETUP    = 4'd6;
    localparam [3:0] ST_DV_HOLD_LOW   = 4'd7;
    localparam [3:0] ST_DV_VALID      = 4'd8;
    localparam [3:0] ST_RESPOND       = 4'd9;
    localparam [3:0] ST_ABORT         = 4'd10;
    localparam [3:0] ST_RETIRE        = 4'd11;
    localparam [3:0] ST_ABORT_SETUP   = 4'd12;

    function is_read_aio;
        input [3:0] aio;
        begin
            is_read_aio = (((aio[3] == 1'b1) && (aio != AIO_NIO)) ||
                           (aio == AIO_ODT_READ));
        end
    endfunction

    function is_write_aio;
        input [3:0] aio;
        begin
            is_write_aio = (aio == AIO_GP_WRITE) ||
                           (aio == AIO_BYTE_WRITE) ||
                           (aio == AIO_WORD_WRITE);
        end
    endfunction

    function [1:0] byte_lanes;
        input [3:0] aio;
        input       address_bit_zero;
        begin
            if (aio == AIO_BYTE_WRITE)
                byte_lanes = address_bit_zero ? 2'b10 : 2'b01;
            else
                byte_lanes = 2'b11;
        end
    endfunction

    reg [21:0] ale_address;
    reg [15:0] ale_dal;
    reg [3:0]  ale_aio;
    reg [1:0]  ale_bs;
    reg        ale_latched_valid;
    reg        ale_capture_toggle;
    reg        ale_started_idle;
    reg        ale_started_before_completion;
    reg        ale_cpu_abort;
    reg [15:0] sctl_write_data;

    reg [3:0]  state;
    reg        transaction_owned;
    reg        transaction_completion_issued;

    always @(negedge ale_n or negedge reset_n) begin
        if (!reset_n) begin
            ale_address <= 22'd0;
            ale_dal <= 16'd0;
            ale_aio <= AIO_NIO;
            ale_bs <= 2'b00;
            ale_latched_valid <= 1'b0;
            ale_capture_toggle <= 1'b0;
            ale_started_idle <= 1'b1;
            ale_started_before_completion <= 1'b0;
            ale_cpu_abort <= 1'b0;
        end else begin
            ale_address <= raw_address;
            ale_dal <= raw_dal;
            ale_aio <= raw_aio;
            ale_bs <= raw_bs;
            ale_latched_valid <= 1'b1;
            ale_capture_toggle <= ~ale_capture_toggle;
            ale_started_idle <= sctl_n && strb_n;
            ale_started_before_completion <= transaction_owned &&
                !transaction_completion_issued;
            ale_cpu_abort <= !abort_sense_n;
        end
    end

    always @(negedge sctl_n or negedge reset_n) begin
        if (!reset_n)
            sctl_write_data <= 16'd0;
        else
            sctl_write_data <= raw_dal;
    end

    (* async_reg = "true", altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    reg ale_capture_meta;
    (* async_reg = "true", altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    reg ale_capture_sync;
    reg ale_capture_seen;
    (* async_reg = "true", altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    reg sctl_meta;
    (* async_reg = "true", altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    reg sctl_sync;
    reg sctl_previous;
    (* async_reg = "true", altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    reg strb_meta;
    (* async_reg = "true", altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    reg strb_sync;
    (* async_reg = "true", altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    reg bufctl_meta;
    (* async_reg = "true", altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    reg bufctl_sync;
    (* async_reg = "true", altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    reg dv_meta;
    (* async_reg = "true", altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    reg dv_sync;

    wire ale_capture_pending = ale_capture_sync != ale_capture_seen;
    wire sctl_falling = sctl_previous && !sctl_sync;

    reg        transaction_token;
    reg [21:0] transaction_address;
    reg [15:0] transaction_address_dal;
    reg [3:0]  transaction_aio;
    reg [1:0]  transaction_bs;
    reg        transaction_read;
    reg        transaction_write;
    reg        transaction_memory;
    reg        transaction_has_data;
    reg        transaction_cpu_abort;
    reg [15:0] read_data;
    reg [7:0] phase_count;
    reg       memory_outstanding;
    reg       rmw_reservation;
    reg [21:0] rmw_address;
    reg [31:0] abort_led_count;
    reg [1:0] intack_source;
    reg [15:0] intack_vector;
    reg        intack_valid;

    assign peripheral_address = transaction_address;

    wire registry_read_registered;
    wire registry_write_registered;
    wire registry_read_peripheral;
    wire registry_write_peripheral;
    wire registry_internal_cycle;
    wire registry_write_sink;
    wire [15:0] registry_read_data;

    dcj11_address_registry registry (
        .address(transaction_address),
        .aio(transaction_aio),
        .bs(transaction_bs),
        .peripheral_hit(peripheral_hit),
        .peripheral_data(peripheral_data),
        .read_registered(registry_read_registered),
        .write_registered(registry_write_registered),
        .read_peripheral(registry_read_peripheral),
        .write_peripheral(registry_write_peripheral),
        .internal_cycle(registry_internal_cycle),
        .registered_write_sink(registry_write_sink),
        .read_data(registry_read_data)
    );

    wire transaction_token_current =
        (ale_capture_toggle == transaction_token);
    wire ale_is_successor = ale_started_idle &&
                            !ale_started_before_completion;
    wire current_owns_physical_phase = transaction_owned &&
        (transaction_token_current || !ale_is_successor);

    wire response_state = (state == ST_RESPOND);
    wire abort_completion_state = (state == ST_ABORT);
    wire abort_setup_state = (state == ST_ABORT_SETUP);
    wire abort_state = abort_setup_state || abort_completion_state;

    wire cpu_abort_pin_low = !abort_sense_n && !abort_state;
    wire read_drive_state = transaction_has_data &&
        ((state == ST_DATA_SETUP) || (state == ST_DV_HOLD_LOW) ||
         (state == ST_DV_VALID) || response_state);
    wire physical_response = enable && current_owns_physical_phase && !sctl_n;

    assign dal_out = read_data;
    assign dal_oe = physical_response && !bufctl_n && read_drive_state &&
                    !transaction_cpu_abort;

    assign cont_n = ~(physical_response &&
                      (response_state || abort_completion_state));

    assign abort_n = ~(physical_response && abort_state);

    wire ale_memory_read = is_read_aio(ale_aio) &&
                           (ale_aio != AIO_GP_READ) &&
                           (ale_aio != AIO_INTACK) &&
                           (ale_bs == 2'b00) &&
                           (ale_address < IO_PAGE_BASE);
    wire ale_memory_write = is_write_aio(ale_aio) &&
                            (ale_bs == 2'b00) &&
                            (ale_address < IO_PAGE_BASE);
    assign miss_drive_low = enable && ale_latched_valid && !ale_n &&
                            strb_n && sctl_n && ale_memory_read &&
                            abort_sense_n;

    wire ale_internal_read = is_read_aio(ale_aio) &&
        ((ale_bs == 2'b11) ||
         ((ale_bs == 2'b01) && (ale_address == 22'o17777746)));
    wire ale_external_read = is_read_aio(ale_aio) && !ale_internal_read;
    wire transaction_internal_read = transaction_read &&
        ((transaction_bs == 2'b11) ||
         ((transaction_bs == 2'b01) &&
          (transaction_address == 22'o17777746)));
    wire transaction_external_read = transaction_read &&
                                     !transaction_internal_read;
    wire physical_cycle_envelope = !ale_n || !strb_n;
    wire dv_released_for_data = ale_n && current_owns_physical_phase &&
        ((state == ST_DV_VALID) || response_state ||
         (state == ST_RETIRE));
    wire physical_external_read = current_owns_physical_phase ?
                                  transaction_external_read :
                                  ale_external_read;
    assign dv_drive_low = enable && ale_latched_valid &&
                          physical_cycle_envelope && physical_external_read &&
                          !dv_released_for_data && abort_sense_n &&
                          !transaction_cpu_abort;

    assign cpu_rmw_lock = rmw_reservation;
    assign abort_led_n = ~((physical_response && abort_state) ||
                           (abort_led_count != 0));

    wire can_adopt_ale = (state == ST_IDLE) && !transaction_owned;

    wire in_cycle_ale_pending = ale_capture_pending && !ale_is_successor;
    wire pending_ale_for_adoption = ale_capture_pending && ale_is_successor;

    wire physical_orphan_memory_read = enable &&
        !ale_capture_pending && ale_latched_valid && ale_n &&
        !sctl_sync && !strb_sync && !bufctl_sync && ale_memory_read &&
        can_adopt_ale;
    wire physical_orphan_memory_write = enable &&
        !ale_capture_pending && ale_latched_valid && ale_n &&
        !sctl_sync && !strb_sync && bufctl_sync && ale_memory_write &&
        can_adopt_ale;
    wire ale_adopt_request = pending_ale_for_adoption ||
                             physical_orphan_memory_read ||
                             physical_orphan_memory_write;
    wire physical_orphan_memory_cycle = physical_orphan_memory_read ||
                                        physical_orphan_memory_write;

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            ale_capture_meta <= 1'b0;
            ale_capture_sync <= 1'b0;
            ale_capture_seen <= 1'b0;
            sctl_meta <= 1'b1;
            sctl_sync <= 1'b1;
            sctl_previous <= 1'b1;
            strb_meta <= 1'b1;
            strb_sync <= 1'b1;
            bufctl_meta <= 1'b1;
            bufctl_sync <= 1'b1;
            dv_meta <= 1'b1;
            dv_sync <= 1'b1;
            state <= ST_IDLE;
            transaction_owned <= 1'b0;
            transaction_completion_issued <= 1'b0;
            transaction_token <= 1'b0;
            transaction_address <= 22'd0;
            transaction_address_dal <= 16'd0;
            transaction_aio <= AIO_NIO;
            transaction_bs <= 2'b00;
            transaction_read <= 1'b0;
            transaction_write <= 1'b0;
            transaction_memory <= 1'b0;
            transaction_has_data <= 1'b0;
            transaction_cpu_abort <= 1'b0;
            read_data <= 16'd0;
            phase_count <= 8'd0;
            memory_outstanding <= 1'b0;
            rmw_reservation <= 1'b0;
            rmw_address <= 22'd0;
            abort_led_count <= 32'd0;
            intack_source <= 2'b00;
            intack_vector <= 16'd0;
            intack_valid <= 1'b0;
            peripheral_read_address <= 22'd0;
            peripheral_write_address <= 22'd0;
            peripheral_read_pulse <= 1'b0;
            peripheral_write_pulse <= 1'b0;
            peripheral_write_data <= 16'd0;
            peripheral_byte_enable <= 2'b00;
            interrupt_ack <= 2'b00;
            interrupt_ack_vector <= 16'd0;
            event_ack <= 1'b0;

            bus_reset <= 1'b0;
            cpu_mem_request_valid <= 1'b0;
            cpu_mem_request_write <= 1'b0;
            cpu_mem_request_address <= 22'd0;
            cpu_mem_request_data <= 16'd0;
            cpu_mem_request_byte_enable <= 2'b00;
            odt_seen <= 1'b0;
            last_address <= 22'd0;
            last_data <= 16'd0;
            last_aio <= AIO_NIO;
        end else begin
            ale_capture_meta <= ale_capture_toggle;
            ale_capture_sync <= ale_capture_meta;
            sctl_meta <= sctl_n;
            sctl_sync <= sctl_meta;
            sctl_previous <= sctl_sync;
            strb_meta <= strb_n;
            strb_sync <= strb_meta;
            bufctl_meta <= bufctl_n;
            bufctl_sync <= bufctl_meta;
            dv_meta <= dv_sense;
            dv_sync <= dv_meta;

            peripheral_read_pulse <= 1'b0;
            peripheral_write_pulse <= 1'b0;
            interrupt_ack <= 2'b00;
            event_ack <= 1'b0;

            if (!enable)
                transaction_completion_issued <= 1'b0;

            if (abort_led_count != 0)
                abort_led_count <= abort_led_count - 1'b1;
            if (physical_response && abort_state)
                abort_led_count <= ABORT_LED_CYCLES[31:0];

            if (enable && transaction_owned &&
                !transaction_completion_issued && !abort_state &&
                cpu_abort_pin_low)
                transaction_cpu_abort <= 1'b1;

            if (!enable) begin
                state <= ST_IDLE;
                cpu_mem_request_valid <= 1'b0;
                memory_outstanding <= 1'b0;
                transaction_has_data <= 1'b0;
                transaction_cpu_abort <= 1'b0;
                transaction_owned <= 1'b0;
                transaction_completion_issued <= 1'b0;
                phase_count <= 8'd0;
                ale_capture_seen <= ale_capture_sync;
            end else if (ale_adopt_request && can_adopt_ale) begin
                ale_capture_seen <= physical_orphan_memory_cycle ?
                                    ale_capture_toggle :
                                    ale_capture_sync;
                transaction_owned <= 1'b1;
                transaction_completion_issued <= (ale_aio == AIO_NIO);
                transaction_token <= physical_orphan_memory_cycle ?
                                     ale_capture_toggle :
                                     ale_capture_sync;
                transaction_address <= ale_address;
                transaction_address_dal <= ale_dal;
                transaction_aio <= ale_aio;
                transaction_bs <= ale_bs;
                transaction_read <= is_read_aio(ale_aio);
                transaction_write <= is_write_aio(ale_aio);
                transaction_memory <= (ale_bs == 2'b00) &&
                                      (ale_address < IO_PAGE_BASE) &&
                                      (ale_aio != AIO_GP_READ) &&
                                      (ale_aio != AIO_INTACK);
                transaction_has_data <= 1'b0;
                transaction_cpu_abort <= ale_cpu_abort || cpu_abort_pin_low;
                phase_count <= 8'd0;
                last_address <= ale_address;
                last_aio <= ale_aio;

                intack_valid <= 1'b0;
                intack_source <= 2'b00;
                intack_vector <= 16'd0;
                if (ale_aio == AIO_INTACK) begin
                    case (ale_dal[3:0])
                        4'b0001: begin
                            intack_valid <= interrupt_requests[0];
                            intack_source <= interrupt_requests[0] ?
                                             2'b01 : 2'b00;
                            intack_vector <= interrupt_vector0;
                        end
                        4'b0010: begin
                            intack_valid <= interrupt_requests[1];
                            intack_source <= interrupt_requests[1] ?
                                             2'b10 : 2'b00;
                            intack_vector <= interrupt_vector1;
                        end
                        default: ;
                    endcase
                end

                if (rmw_reservation &&
                    !((ale_aio == AIO_BYTE_WRITE ||
                       ale_aio == AIO_WORD_WRITE) &&
                      (ale_address == rmw_address)) &&
                    (ale_aio != AIO_NIO)) begin
                    rmw_reservation <= 1'b0;
                end

                state <= (ale_aio == AIO_NIO) ? ST_RETIRE : ST_DECODE;
            end else begin
                if (in_cycle_ale_pending) begin
                    ale_capture_seen <= ale_capture_sync;
                    transaction_token <= ale_capture_sync;
                end else if (ale_capture_pending && !can_adopt_ale) begin

                end
                case (state)
                    ST_IDLE: ;

                    ST_DECODE: begin
                        if (transaction_cpu_abort || cpu_abort_pin_low) begin
                            transaction_cpu_abort <= 1'b1;
                            transaction_has_data <= 1'b0;
                            state <= ST_WAIT_SCTL;
                        end else if (transaction_aio == AIO_GP_READ) begin
                            read_data <=
                                ((transaction_address_dal[7:0] == 8'o000) ||
                                 (transaction_address_dal[7:0] == 8'o002)) ?
                                POWER_UP_WORD : 16'd0;
                            last_data <=
                                ((transaction_address_dal[7:0] == 8'o000) ||
                                 (transaction_address_dal[7:0] == 8'o002)) ?
                                POWER_UP_WORD : 16'd0;
                            transaction_has_data <= 1'b1;
                            if ((transaction_address_dal[7:0] == 8'o000) ||
                                (transaction_address_dal[7:0] == 8'o002))
                                odt_seen <= 1'b1;
                            state <= ST_WAIT_SCTL;
                        end else if (transaction_aio == AIO_GP_WRITE) begin
                            state <= ST_WAIT_SCTL;
                        end else if (transaction_aio == AIO_INTACK) begin
                            if (intack_valid) begin
                                read_data <= intack_vector;
                                last_data <= intack_vector;
                                transaction_has_data <= 1'b1;
                                interrupt_ack <= intack_source;
                                interrupt_ack_vector <= intack_vector;
                                state <= ST_WAIT_SCTL;
                            end else begin
                                state <= ST_WAIT_SCTL;
                            end
                        end else if (transaction_read && transaction_memory) begin
                            cpu_mem_request_write <= 1'b0;
                            cpu_mem_request_address <= transaction_address;
                            cpu_mem_request_data <= 16'd0;
                            cpu_mem_request_byte_enable <= 2'b11;
                            cpu_mem_request_valid <= 1'b1;
                            state <= ST_MEM_REQUEST;
                            if (transaction_aio == AIO_RMW_LOCKED) begin
                                rmw_reservation <= 1'b1;
                                rmw_address <= transaction_address;
                            end
                        end else if (transaction_read &&
                                     registry_read_registered) begin
                            read_data <= registry_read_data;
                            last_data <= registry_read_data;
                            transaction_has_data <=
                                !registry_internal_cycle;
                            if (registry_read_peripheral) begin
                                peripheral_read_address <= transaction_address;
                                peripheral_read_pulse <= 1'b1;
                            end
                            state <= ST_WAIT_SCTL;
                        end else if (transaction_write &&
                                     (transaction_memory ||
                                      registry_write_registered)) begin
                            state <= ST_WAIT_SCTL;
                        end else begin
                            state <= ST_WAIT_SCTL;
                        end
                    end

                    ST_MEM_REQUEST: begin
                        if ((transaction_cpu_abort || cpu_abort_pin_low) &&
                            cpu_mem_request_valid) begin
                            transaction_cpu_abort <= 1'b1;
                            cpu_mem_request_valid <= 1'b0;
                            state <= ST_WAIT_SCTL;
                        end else if (cpu_mem_request_valid &&
                            cpu_mem_request_ready) begin
                            cpu_mem_request_valid <= 1'b0;
                            memory_outstanding <= 1'b1;
                            state <= ST_MEM_RESPONSE;
                        end
                    end

                    ST_MEM_RESPONSE: begin
                        if (cpu_mem_response_valid && memory_outstanding) begin
                            memory_outstanding <= 1'b0;
                            if (cpu_mem_response_error) begin
                                transaction_has_data <= 1'b0;
                                if (transaction_write) begin
                                    phase_count <= 8'd0;
                                    state <= ST_ABORT_SETUP;
                                end else begin
                                    state <= ST_WAIT_SCTL;
                                end
                            end else if (transaction_cpu_abort ||
                                         cpu_abort_pin_low) begin
                                transaction_cpu_abort <= 1'b1;
                                transaction_has_data <= 1'b0;
                                state <= ST_WAIT_SCTL;
                            end else if (transaction_read) begin
                                read_data <= cpu_mem_response_data;
                                last_data <= cpu_mem_response_data;
                                transaction_has_data <= 1'b1;
                                state <= ST_WAIT_SCTL;
                            end else begin
                                if (rmw_reservation &&
                                    (transaction_address == rmw_address))
                                    rmw_reservation <= 1'b0;
                                transaction_completion_issued <= 1'b1;
                                state <= ST_RESPOND;
                            end
                        end
                    end

                    ST_WAIT_SCTL: begin
                        if (!sctl_sync || sctl_falling) begin
                            if (transaction_cpu_abort || cpu_abort_pin_low) begin
                                transaction_cpu_abort <= 1'b1;
                                transaction_has_data <= 1'b0;
                                cpu_mem_request_valid <= 1'b0;
                                if (rmw_reservation &&
                                    (transaction_address == rmw_address))
                                    rmw_reservation <= 1'b0;
                                transaction_completion_issued <= 1'b1;
                                state <= ST_RESPOND;
                            end else if (transaction_aio == AIO_GP_WRITE) begin
                                last_data <= transaction_address_dal;
                                case (transaction_address_dal[7:0])
                                    8'o014: bus_reset <= 1'b1;
                                    8'o034: odt_seen <= 1'b0;
                                    8'o100: event_ack <= 1'b1;
                                    8'o214: bus_reset <= 1'b0;
                                    8'o234: odt_seen <= 1'b1;
                                    default: ;
                                endcase
                                state <= ST_COMMIT_WRITE;
                            end else if (transaction_aio == AIO_INTACK &&
                                         !intack_valid) begin
                                phase_count <= 8'd0;
                                state <= ST_ABORT_SETUP;
                            end else if (transaction_write &&
                                         transaction_memory) begin
                                peripheral_write_data <= sctl_write_data;
                                peripheral_byte_enable <= byte_lanes(
                                    transaction_aio,
                                    transaction_address[0]);
                                last_data <= sctl_write_data;
                                cpu_mem_request_write <= 1'b1;
                                cpu_mem_request_address <= transaction_address;
                                cpu_mem_request_data <= sctl_write_data;
                                cpu_mem_request_byte_enable <= byte_lanes(
                                    transaction_aio,
                                    transaction_address[0]);
                                cpu_mem_request_valid <= 1'b1;
                                state <= ST_MEM_REQUEST;
                            end else if (transaction_write &&
                                         registry_write_registered) begin
                                peripheral_write_address <= transaction_address;
                                peripheral_write_data <= sctl_write_data;
                                peripheral_byte_enable <= byte_lanes(
                                    transaction_aio,
                                    transaction_address[0]);
                                last_data <= sctl_write_data;
                                if (registry_write_peripheral)
                                    peripheral_write_pulse <= 1'b1;
                                if (rmw_reservation &&
                                    (transaction_address == rmw_address))
                                    rmw_reservation <= 1'b0;
                                state <= ST_COMMIT_WRITE;
                            end else if (transaction_read &&
                                         transaction_has_data) begin
                                if (!bufctl_sync) begin
                                    phase_count <= 8'd0;
                                    state <= ST_DATA_SETUP;
                                end
                            end else if (transaction_read &&
                                         registry_internal_cycle) begin
                                transaction_completion_issued <= 1'b1;
                                state <= ST_RESPOND;
                            end else if (transaction_write &&
                                         registry_write_sink) begin
                                state <= ST_COMMIT_WRITE;
                            end else begin
                                phase_count <= 8'd0;
                                state <= ST_ABORT_SETUP;
                            end
                        end
                    end

                    ST_COMMIT_WRITE: begin
                        transaction_completion_issued <= 1'b1;
                        state <= ST_RESPOND;
                    end

                    ST_DATA_SETUP: begin
                        if (bufctl_sync || sctl_sync) begin
                            state <= ST_WAIT_SCTL;
                            phase_count <= 8'd0;
                        end else if (phase_count + 1'b1 >=
                                     READ_SETUP_CYCLES[7:0]) begin
                            phase_count <= 8'd0;
                            state <= ST_DV_HOLD_LOW;
                        end else begin
                            phase_count <= phase_count + 1'b1;
                        end
                    end

                    ST_DV_HOLD_LOW: begin
                        if (bufctl_sync || sctl_sync) begin
                            state <= ST_WAIT_SCTL;
                            phase_count <= 8'd0;
                        end else if (phase_count + 1'b1 >=
                                     READ_SETUP_CYCLES[7:0]) begin
                            phase_count <= 8'd0;
                            state <= ST_DV_VALID;
                        end else begin
                            phase_count <= phase_count + 1'b1;
                        end
                    end

                    ST_DV_VALID: begin
                        if (bufctl_sync || sctl_sync) begin
                            state <= ST_WAIT_SCTL;
                            phase_count <= 8'd0;
                        end else begin
                            if (phase_count < DV_RELEASE_CYCLES[7:0])
                                phase_count <= phase_count + 1'b1;
                            if (dv_sync &&
                                (phase_count >= DV_RELEASE_CYCLES[7:0])) begin
                                transaction_completion_issued <= 1'b1;
                                state <= ST_RESPOND;
                            end
                        end
                    end

                    ST_ABORT_SETUP: begin
                        if (sctl_sync) begin
                            phase_count <= 8'd0;
                            state <= ST_RETIRE;
                        end else if (phase_count + 1'b1 >=
                                     ABORT_SETUP_CYCLES[7:0]) begin
                            phase_count <= 8'd0;
                            transaction_completion_issued <= 1'b1;
                            state <= ST_ABORT;
                        end else begin
                            phase_count <= phase_count + 1'b1;
                        end
                    end

                    ST_RESPOND,
                    ST_ABORT: begin
                        if (sctl_sync)
                            state <= ST_RETIRE;
                    end

                    ST_RETIRE: begin
                        if (strb_sync && sctl_sync) begin
                            state <= ST_IDLE;
                            transaction_owned <= 1'b0;
                            transaction_cpu_abort <= 1'b0;
                        end
                    end

                    default: begin
                        state <= ST_IDLE;
                        transaction_owned <= 1'b0;
                        transaction_completion_issued <= 1'b0;
                        transaction_cpu_abort <= 1'b0;
                        cpu_mem_request_valid <= 1'b0;
                        memory_outstanding <= 1'b0;
                    end
                endcase
            end
        end
    end
endmodule

`default_nettype wire
