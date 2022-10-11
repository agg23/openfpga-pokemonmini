module key_input
(
    input clk,
    input clk_ce,
    input reset,
    input [8:0] keys_active,
    input [23:0] bus_address_in,
    output logic [7:0] bus_data_out,
    output logic [8:0] key_irqs
);

wire [7:0] reg_keys = reset ? 8'hFF: ~keys_active[7:0];

reg [8:0] key_latches;
always @ (posedge clk)
begin
    if(clk_ce)
    begin
        for(int i = 0; i < 9; ++i)
        begin
            key_irqs[i]    <= 0;
            key_latches[i] <= keys_active[i];

            if(~key_latches[i] & keys_active[i])
                key_irqs[i]    <= 1;
        end
    end
end


always_comb
begin
    bus_data_out = 0;
    if(bus_address_in == 24'h2052)
        bus_data_out = reg_keys;
end

endmodule
