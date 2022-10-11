module irq
(
    input clk,
    input clk_ce,
    input reset,
    input bus_write,
    input bus_read,
    input [31:0] irqs,
    input cpu_iack,
    input [23:0] bus_address_in,
    input [7:0] bus_data_in,
    output logic [23:0] bus_address_out,
    output logic [7:0] bus_data_out,
    output logic [3:0] cpu_irq
);

    localparam bit[3:0] irq_group[0:31] = '{
        0, 0, 0,                // NMI
        3, 3,                   // Blitter Group
        2, 2,                   // Tim3/2
        1, 1,                   // Tim1/0
        0, 0,                   // Tim5/4
        7, 7, 7, 7,             // 256hz clock
        8, 8, 8, 8,             // IR / Shock sensor
        6, 6,                   // K1x
        5, 5, 5, 5, 5, 5, 5, 5, // K0x
        4, 4, 4                 // Unknown ($1D ~ $1F?)
    };

    //   7       6       5       4       3       2       1       0
    // $03     $04     $05     $06     $07     $08     $09     $0A
    // $11     $12     $0B     $0C     $0D     $0E     $13     $14
    // $15     $16     $17     $18     $19     $1A     $1B     $1C
    // $0F     $10     $00     $01     $02     $1D     $1E     $1F
    localparam bit[4:0] irq_reg_map[0:31] = '{
        29, 28, 27, 7, 6, 5, 4, 3, 2, 1, 0,
        13, 12, 11, 10, 31, 30, 15, 14, 9, 8,
        23, 22, 21, 20, 19, 18, 17, 16, 26, 25, 24
    };

    reg [17:0] reg_irq_priority;
    reg [31:0] reg_irq_active;
    reg [31:0] reg_irq_enabled;

    reg [4:0] next_irq;
    reg [4:0] next_irq_latch;
    reg [1:0] next_priority;

    reg write_latch;
    always_ff @ (negedge clk)
    begin
        if(clk_ce)
        begin
            if(reset)
            begin
                next_irq_latch <= 0;
            end
            else
            begin
                for(int i = 0; i < 32; ++i)
                begin
                    if(irqs[i])
                        reg_irq_active[irq_reg_map[i]] <= 1;
                end

                if(next_priority > 0)
                    next_irq_latch <= next_irq;

                if(write_latch)
                begin
                    if(bus_address_in == 24'h2020)
                        reg_irq_priority[7:0] <= bus_data_in;

                    if(bus_address_in == 24'h2021)
                        reg_irq_priority[15:8] <= bus_data_in;

                    if(bus_address_in == 24'h2022)
                        reg_irq_priority[17:16] <= bus_data_in[1:0];

                    if(bus_address_in == 24'h2023)
                        reg_irq_enabled[7:0] <= bus_data_in;

                    if(bus_address_in == 24'h2024)
                        reg_irq_enabled[15:8] <= bus_data_in;

                    if(bus_address_in == 24'h2025)
                        reg_irq_enabled[23:16] <= bus_data_in;

                    if(bus_address_in == 24'h2026)
                        reg_irq_enabled[31:24] <= bus_data_in;

                    if(bus_address_in == 24'h2027)
                        reg_irq_active[7:0] <= reg_irq_active[7:0] & ~bus_data_in;

                    if(bus_address_in == 24'h2028)
                        reg_irq_active[15:8] <= reg_irq_active[15:8] & ~bus_data_in;

                    if(bus_address_in == 24'h2029)
                        reg_irq_active[23:16] <= reg_irq_active[23:16] & ~bus_data_in;

                    if(bus_address_in == 24'h202A)
                        reg_irq_active[31:24] <= reg_irq_active[31:24] & ~bus_data_in;
                end
            end
        end
    end

    always_ff @ (posedge clk)
    begin
        if(clk_ce)
        begin
            write_latch <= 0;
            if(bus_write) write_latch <= 1;
        end
    end

    // @todo: Handle NMI.
    // if(
    //     irqs[i] < 5'h03 &&
    //     reg_irq_enabled[irq_reg_map[i]] &&
    //     reg_irq_active[irq_reg_map[i]] &&
    // )
    // begin
    //     cpu_irq[0] = 1;
    // end
    always_comb
    begin
        next_irq        = 5'd0;
        next_priority   = 2'd0;
        for(int i = 0; i < 32; ++i)
        begin
            if(
                reg_irq_enabled[irq_reg_map[i]] &&
                reg_irq_active[irq_reg_map[i]] &&
                reg_irq_priority[2*irq_group[i]+:2] > next_priority
            )
            begin
                next_irq      = i[4:0];
                next_priority = reg_irq_priority[2*irq_group[i]+:2];
            end
        end
    end


    // @todo: Check if IRQ_ENA1[7:6]
    always_comb
    begin
        bus_data_out = 8'd0;
        cpu_irq      = 4'd0;

        if(next_priority > 0)
            cpu_irq[next_priority-1] = 1;

        if(cpu_iack)
            bus_data_out = {2'd0, next_irq_latch, 1'd0};
        else
        begin
            case(bus_address_in)
                24'h2020:
                    bus_data_out = reg_irq_priority[7:0];

                24'h2021:
                    bus_data_out = reg_irq_priority[15:8];

                24'h2022:
                    bus_data_out = {6'd0, reg_irq_priority[17:16]};

                24'h2023:
                    bus_data_out = reg_irq_enabled[7:0];

                24'h2024:
                    bus_data_out = reg_irq_enabled[15:8];

                24'h2025:
                    bus_data_out = reg_irq_enabled[23:16];

                24'h2026:
                    bus_data_out = reg_irq_enabled[31:24];

                24'h2027:
                    bus_data_out = reg_irq_active[7:0];

                24'h2028:
                    bus_data_out = reg_irq_active[15:8];

                24'h2029:
                    bus_data_out = reg_irq_active[23:16];

                24'h202A:
                    bus_data_out = reg_irq_active[31:24];

                default:
                begin
                end
            endcase
        end
    end

endmodule
