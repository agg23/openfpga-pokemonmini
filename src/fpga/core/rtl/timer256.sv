module timer256
(
    input clk,
    input clk_ce,
    input clk_rt,
    input clk_rt_ce,
    input reset,
    input bus_write,
    input bus_read,
    input [23:0] bus_address_in,
    input [7:0] bus_data_in,
    output logic [7:0] bus_data_out,
    output logic [3:0] irqs,
    input osc256
);

reg reg_enabled;
reg reg_reset;
reg [7:0] timer;

//assign irqs = {4{reg_enabled}} & {timer == 255, timer[7], timer[5], timer[3]};

reg write_latch;
always_ff @ (negedge clk)
begin
    if(clk_ce)
    begin
        if(reset)
        begin
            reg_enabled <= 1'd0;
            reg_reset   <= 1'd0;
        end
        else
        begin
            if(reg_reset && timer == 0)
                reg_reset <= 0;

            if(write_latch)
            begin
                if(bus_address_in == 24'h2040)
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
        24'h2040:
            bus_data_out = {7'd0, reg_enabled};
        24'h2041:
            bus_data_out = timer;
        default:
            bus_data_out = 8'd0;
    endcase
end

// @todo: rt_clock is 32768Hz. We first need to make a 256Hz signal clock.
// This means we have to divide the clock by 128, or we need to provide the
// correct frequency. We need to divide the clock anyway for timer.sv so
// perhaps we can take the 256Hz frequency as output from there.
always_ff @ (posedge clk_rt)
begin
    irqs <= 4'd0;

    if(reset || reg_reset)
    begin
        timer <= 8'd0;
    end
    else if(clk_rt_ce && reg_enabled && osc256)
    begin
        timer <= timer + 8'd1;

        if(timer == 8'd255)
            irqs[3] <= 1;
        if(timer[6:0] == 7'd127)
            irqs[2] <= 1;
        if(timer[4:0] == 5'd31)
            irqs[1] <= 1;
        if(timer[2:0] == 3'd7)
            irqs[0] <= 1;
    end
end

endmodule
