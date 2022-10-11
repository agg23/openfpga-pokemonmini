module timer
#(
    parameter TMR_SCALE, TMR_OSC, TMR_CTRL, TMR_PRE, TMR_PVT, TMR_CNT
)
(
    input clk,
    input clk_ce,
    input clk_ce_cpu,
    input clk_rt,
    input clk_rt_ce,
    input reset,
    input bus_write,
    input bus_read,
    input [23:0] bus_address_in,
    input [7:0] bus_data_in,
    output logic [7:0] bus_data_out,
    output logic [2:0] irqs,
    output tout,
    output osc256
);

localparam TMR_CTRL_L = TMR_CTRL;
localparam TMR_CTRL_H = TMR_CTRL+1;
localparam TMR_PRE_L  = TMR_PRE;
localparam TMR_PRE_H  = TMR_PRE+1;
localparam TMR_PVT_L  = TMR_PVT;
localparam TMR_PVT_H  = TMR_PVT+1;
localparam TMR_CNT_L  = TMR_CNT;
localparam TMR_CNT_H  = TMR_CNT+1;

assign osc256 = (osc2_prescaler[6:0] == 7'h7F);
assign tout = ~enabled_l ? 0: (
    mode16 ?
        ((timer < reg_compare)? 0: 1):
        ((timer[7:0] < reg_compare[7:0])? 0: 1)
);

reg [7:0]  reg_scale;
reg [1:0]  reg_osc_control;
reg [15:0] timer;

reg [15:0] reg_control;
reg [15:0] reg_compare;
reg [15:0] reg_preset;

wire reset_l   = reg_control[1];
wire enabled_l = reg_control[2];
wire mode16    = reg_control[7];
wire reset_h   = reg_control[9];
wire enabled_h = reg_control[10];
wire [2:0] prescale_l = reg_scale[2:0];
wire [2:0] prescale_h = reg_scale[6:4];

wire osc_l = reg_osc_control[0];
wire osc_h = reg_osc_control[1];

//localparam [3:0] prescale_osc1[0:7] = '{
//    1, 3, 5, 6, 7, 8, 10, 12
//};
//
//localparam [2:0] prescale_osc2[0:7] = '{
//    0, 1, 2, 3, 4, 5, 6, 7
//};

function tick(input osc, input [2:0] pid);
    if(osc == 0)
    begin
        case(pid)
            3'd0:
                tick = osc1_prescaler[0] == 1'h1;
            3'd1:
                tick = osc1_prescaler[2:0] == 3'h7;
            3'd2:
                tick = osc1_prescaler[4:0] == 5'h1F;
            3'd3:
                tick = osc1_prescaler[5:0] == 6'h3F;
            3'd4:
                tick = osc1_prescaler[6:0] == 7'h7F;
            3'd5:
                tick = osc1_prescaler[7:0] == 8'hFF;
            3'd6:
                tick = osc1_prescaler[9:0] == 10'h3FF;
            3'd7:
                tick = osc1_prescaler[11:0] == 12'hFFF;
        endcase
    end
    else
    begin
        case(pid)
            3'd0:
                tick = 1;
            3'd1:
                tick = osc2_prescaler[0] == 1'h1;
            3'd2:
                tick = osc2_prescaler[1:0] == 2'h3;
            3'd3:
                tick = osc2_prescaler[2:0] == 3'h7;
            3'd4:
                tick = osc2_prescaler[3:0] == 4'hF;
            3'd5:
                tick = osc2_prescaler[4:0] == 5'h1F;
            3'd6:
                tick = osc2_prescaler[5:0] == 6'h3F;
            3'd7:
                tick = osc2_prescaler[6:0] == 7'h7F;
        endcase
    end
endfunction

reg write_latch;
always_ff @ (negedge clk)
begin
    if(reset)
    begin
        reg_control <= 16'd0;
    end
    else if(clk_ce_cpu)
    begin
        if(reset_l)
            reg_control[1] <= 0;

        if(reset_h)
            reg_control[9] <= 0;

        if(write_latch)
        begin
            case(bus_address_in)
                TMR_SCALE:
                    reg_scale         <= bus_data_in;
                TMR_OSC:
                    reg_osc_control   <= bus_data_in[1:0];
                TMR_CTRL_L:
                    reg_control[7:0]  <= bus_data_in;
                TMR_CTRL_H:
                    reg_control[15:8] <= bus_data_in;
                TMR_PRE_L:
                    reg_preset[7:0]   <= bus_data_in;
                TMR_PRE_H:
                    reg_preset[15:8]  <= bus_data_in;
                TMR_PVT_L:
                    reg_compare[7:0]  <= bus_data_in;
                TMR_PVT_H:
                    reg_compare[15:8] <= bus_data_in;
                default:
                begin
                end
            endcase
        end
    end
end

always_ff @ (posedge clk)
begin
    if(clk_ce_cpu)
    begin
        write_latch <= 0;
        if(bus_write) write_latch <= 1;
    end
end

always_comb
begin
    case(bus_address_in)
        TMR_SCALE:
            bus_data_out = reg_scale;
        TMR_OSC:
            bus_data_out = {6'd0, reg_osc_control};
        TMR_CTRL_L:
            bus_data_out = reg_control[7:0];
        TMR_CTRL_H:
            bus_data_out = reg_control[15:8];
        TMR_PRE_L:
            bus_data_out = reg_preset[7:0];
        TMR_PRE_H:
            bus_data_out = reg_preset[15:8];
        TMR_PVT_L:
            bus_data_out = reg_compare[7:0];
        TMR_PVT_H:
            bus_data_out = reg_compare[15:8];
        TMR_CNT_L:
            bus_data_out = timer[7:0];
        TMR_CNT_H:
            bus_data_out = timer[15:8];
        default:
            bus_data_out = 8'd0;
    endcase
end

reg rt_clk_latch;
wire rt_clk_edge = (clk_rt_ce & ~rt_clk_latch);
reg [11:0] osc1_prescaler;
always_ff @ (posedge clk)
begin
    // @note: It's important to zero irqs, only when clk_ce_cpu, otherwise the
    // irq will not be activated in the irq handler, or we need to make the
    // irq handler work off the clk_ce_cpu instead.
    if(clk_ce_cpu)
        irqs <= 0;

    if(clk_ce)
    begin
        osc1_prescaler <= osc1_prescaler + 1;
        rt_clk_latch   <= clk_rt_ce & clk_rt;

        if(reset_l)
            timer <= reg_preset;

        if(mode16)
        begin
            if(enabled_l)
            begin
                //if(osc1_prescaler == 2**prescale_osc1[prescale_l] - 1)
                //begin
                //    osc1_prescaler <= 0;
                if(tick(osc_l, prescale_l))
                begin
                    if(~osc_l || rt_clk_edge)
                    begin
                        if(timer == 0)
                        begin
                            irqs[1] <= 1;
                            timer <= reg_preset;
                        end
                        else
                            timer <= timer - 1;

                        if(timer == reg_compare)
                        begin
                            irqs[2] <= 1;
                        end
                    end
                end
            end
        end
        else
        begin
            if(reset_h)
                timer[15:8] <= reg_preset[15:8];

            if(enabled_l)
            begin
                if(tick(osc_l, prescale_l))
                begin
                    if(~osc_l || rt_clk_edge)
                    begin
                        if(timer[7:0] == 0)
                        begin
                            irqs[0] <= 1;
                            timer[7:0] <= reg_preset[7:0];
                        end
                        else
                            timer[7:0] <= timer[7:0] - 1;

                        if(timer[7:0] == reg_compare[7:0])
                        begin
                            irqs[2] <= 1;
                        end
                    end
                end
            end

            if(enabled_h)
            begin
                if(tick(osc_h, prescale_h))
                begin
                    if(~osc_h || rt_clk_edge)
                    begin
                        if(timer[15:8] == 0)
                        begin
                            irqs[1] <= 1;
                            timer[15:8] <= reg_preset[15:8];
                        end
                        else
                            timer[15:8] <= timer[15:8] - 1;
                    end
                end
            end
        end
    end
end

reg [6:0] osc2_prescaler;
always_ff @ (posedge clk_rt)
begin
    if(clk_rt_ce) osc2_prescaler <= osc2_prescaler + 1;
end

endmodule
