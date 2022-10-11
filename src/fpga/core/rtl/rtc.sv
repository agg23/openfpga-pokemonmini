module rtc
(
    input clk,
    input clk_ce,
    input clk_rt,
    input clk_rt_ce,
    input reset,
    input bus_write,
    input [23:0] bus_address_in,
    input [7:0] bus_data_in,
    output logic [7:0] bus_data_out
);

reg reg_enabled;
reg reg_reset;
reg [23:0] timer;
reg [14:0] prescale;

reg write_latch;
always_ff @ (negedge clk)
begin
    if(clk_ce)
    begin
        if(reset)
        begin
            reg_enabled <= 1'd0;
        end
        else
        begin
            if(rt_reset)
                reg_reset <= 0;

            if(write_latch)
            begin
                if(bus_address_in == 24'h2008)
                begin
                    reg_enabled <= bus_data_in[0];
                    reg_reset   <= bus_data_in[1];
                end
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

always_comb
begin
    case(bus_address_in)
        24'h2008:
            bus_data_out = {7'd0, reg_enabled};
        24'h2009:
            bus_data_out = timer[7:0];
        24'h200A:
            bus_data_out = timer[15:8];
        24'h200B:
            bus_data_out = timer[23:16];
        default:
            bus_data_out = 8'd0;
    endcase
end

reg rt_reset = 0;
always_ff @ (posedge clk_rt)
begin
    if(reset | reg_reset)
    begin
        timer    <= 0;
        prescale <= 0;
        rt_reset <= 1;
    end
    else if(clk_rt_ce)
    begin
        rt_reset <= 0;
        prescale <= prescale + 15'd1;
        if(prescale == 15'h7FFF)
            timer <= timer + 24'd1;
    end
end

endmodule
