module system_control
(
    input clk,
    input clk_ce,
    input reset,
    input bus_write,
    input [23:0] bus_address_in,
    input [7:0] bus_data_in,
    output logic [7:0] bus_data_out,

    input validate_rtc
);

reg [7:0] reg_system_control[0:2];

reg write_latch;
always_ff @ (negedge clk)
begin
    if(clk_ce)
    begin
        if(reset)
        begin
            reg_system_control[0] <= 8'd0;
            reg_system_control[1] <= 8'd0;
            reg_system_control[2] <= 8'd0;
        end
        else
        begin
            if(write_latch)
            begin
                if(bus_address_in >= 24'h2000 && bus_address_in <= 24'h2002)
                begin
                    reg_system_control[bus_address_in[1:0]] <= bus_data_in;
                end
            end

            if(validate_rtc)
                reg_system_control[2][1] <= 1;
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

always_comb
begin
    case(bus_address_in)
        24'h2000, 24'h2001, 24'h2002:
            bus_data_out = reg_system_control[bus_address_in[1:0]];
        default:
            bus_data_out = 8'd0;
    endcase
end

endmodule
