module sound
(
    input clk,
    input clk_ce,
    input reset,
    input bus_write,
    input [23:0] bus_address_in,
    input [7:0] bus_data_in,
    output logic [7:0] bus_data_out,
    output [1:0] sound_volume
);

reg [2:0] reg_sound_control;
reg [2:0] reg_sound_volume;

assign sound_volume = reg_sound_volume[1:0];

reg write_latch;
always_ff @ (negedge clk)
begin
    if(clk_ce)
    begin
        if(reset)
        begin
            reg_sound_control <= 3'd0;
            reg_sound_volume  <= 3'd0;
        end
        else
        begin
            if(write_latch)
            begin
                if(bus_address_in == 24'h2070)
                    reg_sound_control <= bus_data_in[2:0];
                else if(bus_address_in == 24'h2071)
                    reg_sound_volume <= bus_data_in[2:0];
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
        24'h2070:
            bus_data_out = {5'd0, reg_sound_control};
        24'h2071:
            bus_data_out = {5'd0, reg_sound_volume};
        default:
            bus_data_out = 8'd0;
    endcase
end

endmodule
