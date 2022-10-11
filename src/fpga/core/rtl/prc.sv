module prc
(
    input clk,
    input clk_ce,
    input clk_ce_cpu,
    input reset,
    input bus_write,
    input bus_read,
    input [23:0] bus_address_in,
    input [7:0] bus_data_in,
    output logic [7:0] bus_data_out,
    output logic [23:0] bus_address_out,
    output logic [1:0]  bus_status,
    output logic write,
    output logic read,
    output logic bus_request,
    input bus_ack,
    output logic irq_copy_complete,
    output logic irq_render_done,
    output logic frame_complete
);

// @todo: What about page 8?

// @note: For the sprite rendering basically implemented the following as
// a finite-state machine:
//
//     if ((X < -7) || (X >= 96)) return;
//     if ((Y < -7) || (Y >= 64)) return;
//
//     // Pre calculate
//     vaddr = 0x1000 + ((Y >> 3) * 96) + X;
//
//     // Process top columns
//     for (xC=0; xC<8; xC++, X++) {
//         if ((X >= 0) && (X < 96)) {
//             xP = (cfg & 0x01) ? (7 - xC) : xC;
//
//             sdata = MinxPRC_OnRead(0, MinxPRC.PRCSprBase + (DrawT * 8) + xP);
//             smask = MinxPRC_OnRead(0, MinxPRC.PRCSprBase + (MaskT * 8) + xP);
//
//             if (cfg & 0x02) {
//                 sdata = PRCInvertBit[sdata];
//                 smask = PRCInvertBit[smask];
//             }
//             if (cfg & 0x04) sdata = ~sdata;
//
//             if (Y >= 0) {
//                 vdata = MinxPRC_OnRead(0, vaddr + xC);
//                 data = vdata & ((smask << (Y & 7)) | (0xFF >> (8 - (Y & 7))));
//                 data |= (sdata & ~smask) << (Y & 7);
//
//                 MinxPRC_OnWrite(0, vaddr + xC, data);
//             }
//             if ((Y < 56) && (Y & 7)) {
//                 vdata = MinxPRC_OnRead(0, vaddr + 96 + xC);
//                 data = vdata & ((smask >> (8-(Y & 7))) | (0xFF << (Y & 7)));
//                 data |= (sdata & ~smask) >> (8-(Y & 7));
//
//                 MinxPRC_OnWrite(0, vaddr + 96 + xC, data);
//             }
//         }
//     }
//

reg [7:0] data_out;
reg [7:0] reg_data_out;
assign bus_data_out = bus_ack? data_out: reg_data_out;

localparam [1:0]
    PRC_STATE_IDLE       = 2'd0,
    PRC_STATE_MAP_DRAW   = 2'd1,
    PRC_STATE_SPR_DRAW   = 2'd2,
    PRC_STATE_FRAME_COPY = 2'd3;

localparam [2:0]
    FRAME_COPY_STATE_COLUMN_SET1 = 3'd0,
    FRAME_COPY_STATE_COLUMN_SET2 = 3'd1,
    FRAME_COPY_STATE_PAGE_SET    = 3'd2,
    FRAME_COPY_STATE_MEM_READ    = 3'd3,
    FRAME_COPY_STATE_LCD_WRITE   = 3'd4;

localparam [2:0]
    SPRITE_DRAW_STATE_READ_TILE_INFO     = 3'd0,
    SPRITE_DRAW_STATE_READ_TILE_ADDRESS  = 3'd1,
    SPRITE_DRAW_STATE_READ_POS_Y         = 3'd2,
    SPRITE_DRAW_STATE_READ_POS_X         = 3'd3,
    SPRITE_DRAW_STATE_READ_SPRITE_DATA   = 3'd4,
    SPRITE_DRAW_STATE_READ_SPRITE_MASK   = 3'd5,
    SPRITE_DRAW_STATE_READ_COLUMN        = 3'd6,
    SPRITE_DRAW_STATE_DRAW_SPRITE_COLUMN = 3'd7;

//localparam [1:0]
//    BUS_COMMAND_IDLE      = 2'd0,
//    BUS_COMMAND_IRQ_READ  = 2'd1,
//    BUS_COMMAND_MEM_WRITE = 2'd2,
//    BUS_COMMAND_MEM_READ  = 2'd3;

reg [5:0] reg_mode;
reg [7:0] reg_rate;
reg [23:0] reg_map_base;
reg [23:0] reg_sprite_base;
reg [6:0] reg_scroll_x;
reg [6:0] reg_scroll_y;
reg [6:0] reg_counter;
reg [6:0] map_scroll_x;
reg [6:0] map_scroll_y;

reg [1:0] state;
wire [1:0] next_state =
     (state == PRC_STATE_IDLE     && reg_mode[1])? PRC_STATE_MAP_DRAW:
    ((state <= PRC_STATE_MAP_DRAW && reg_mode[2])? PRC_STATE_SPR_DRAW:
    ((state <= PRC_STATE_SPR_DRAW && reg_mode[3])? PRC_STATE_FRAME_COPY:
                                                   PRC_STATE_IDLE));

reg [21:0] prc_osc_counter;
reg bus_cycle;
reg [8:0] execution_step;
reg bus_write_latch;
reg [1:0] sprite_tile_index;

reg [4:0] map_width;
reg [4:0] map_height;
always_comb
begin
    case(reg_mode[5:4])
        2'd0:
        begin
            map_width = 12;
            map_height = 16;
        end

        2'd1:
        begin
            map_width = 16;
            map_height = 12;
        end

        2'd2:
        begin
            map_width = 24;
            map_height = 8;
        end

        2'd3:
        begin
            map_width = 24;
            map_height = 16;
        end
    endcase
end

reg [3:0] rate_match;
always_comb
begin
    case(reg_rate[3:1])
        3'h0: rate_match = 4'h2; // Rate /3
        3'h1: rate_match = 4'h5; // Rate /6
        3'h2: rate_match = 4'h8; // Rate /9
        3'h3: rate_match = 4'hB; // Rate /12
        3'h4: rate_match = 4'h1; // Rate /2
        3'h5: rate_match = 4'h3; // Rate /4
        3'h6: rate_match = 4'h5; // Rate /6
        3'h7: rate_match = 4'h7; // Rate /8
    endcase
end

reg [2:0] frame_copy_state;
reg [2:0] sprite_draw_state;
reg [2:0] sprite_draw_state_current;
reg [1:0] sprite_draw_tile_index;
// @todo: Reuse execution_step? Rename to something else e.g.
// prc_stage_state.
task init_next_state(input [1:0] prc_state);
    case(prc_state)
        PRC_STATE_MAP_DRAW:
            execution_step <= 0;

        PRC_STATE_FRAME_COPY:
            frame_copy_state <= FRAME_COPY_STATE_COLUMN_SET1;

        PRC_STATE_SPR_DRAW:
        begin
            sprite_draw_state         <= SPRITE_DRAW_STATE_READ_TILE_INFO;
            sprite_draw_state_current <= SPRITE_DRAW_STATE_READ_TILE_INFO;
            current_sprite_id         <= 5'd23;
            sprite_tile_index         <= 2'd0;
        end

        default:
        begin
        end
    endcase
endtask

reg [6:0] sprite_abs_x;
reg [6:0] sprite_abs_y;
always_comb
begin
    case(sprite_tile_index)
        0:
        begin
            sprite_abs_x = sprite_x + {2'd0, sprite_info[0], 3'd0};
            sprite_abs_y = sprite_y + {2'd0, sprite_info[1], 3'd0};
        end
        1:
        begin
            sprite_abs_x = sprite_x + {2'd0,  sprite_info[0], 3'd0};
            sprite_abs_y = sprite_y + {2'd0, ~sprite_info[1], 3'd0};
        end
        2:
        begin
            sprite_abs_x = sprite_x + {2'd0, ~sprite_info[0], 3'd0};
            sprite_abs_y = sprite_y + {2'd0,  sprite_info[1], 3'd0};
        end
        3:
        begin
            sprite_abs_x = sprite_x + {2'd0, ~sprite_info[0], 3'd0};
            sprite_abs_y = sprite_y + {2'd0, ~sprite_info[1], 3'd0};
        end
    endcase
    //sprite_abs_x = sprite_abs_x - 7'd16;
    //sprite_abs_y = sprite_abs_y - 7'd16;
end
wire [7:0] sprite_row_x = {1'b0, sprite_abs_x} + {1'b0, xC};

reg [2:0] yC;
reg [6:0] xC;
reg top_or_bottom;
reg [7:0] column_data;
reg [7:0] sprite_data;
reg [7:0] sprite_mask;
reg [4:0] current_sprite_id;
reg [6:0] sprite_x;
reg [6:0] sprite_y;
reg [7:0] sprite_tile_address;
reg [3:0] sprite_info;

reg [7:0] tile_address;
reg [7:0] tile_data;

wire sprite_enabled = sprite_info[3];
wire [7:0] sprite_tile_offset = {5'd0, sprite_tile_index[1], 2'd0} + {7'd0, sprite_tile_index[0]};
wire [7:0] sprite_color = sprite_info[2]? ~sprite_data: sprite_data;
wire [7:0] column_data_masked = column_data & ((top_or_bottom == 0)?
    (sprite_mask << sprite_abs_y[2:0]) | (8'hFF >> (4'd8 - {1'b0, sprite_abs_y[2:0]})):
    (8'hFF << sprite_abs_y[2:0]) | (sprite_mask >> (4'd8 - {1'b0, sprite_abs_y[2:0]})));
wire [7:0] sprite_color_masked_and_shifted = (top_or_bottom == 0)?
    (sprite_color & ~sprite_mask) << sprite_abs_y[2:0]:
    (sprite_color & ~sprite_mask) >> (4'd8 - {1'b0, sprite_abs_y[2:0]});

wire [7:0] map_x = {1'd0, xC} + {1'd0, map_scroll_x};
wire [7:0] map_y = {1'd0, yC, 3'd0} + {1'd0, map_scroll_y};

always_ff @ (negedge clk)
begin
    if(reset)
    begin
        prc_osc_counter <= 22'd0;
        reg_counter     <= 7'd1;
    end
    else if(clk_ce)
    begin
        // 75Hz*65 lines
        prc_osc_counter <= prc_osc_counter + 22'd4875;

        if(prc_osc_counter >= 22'd4000000)
        begin
            prc_osc_counter <= prc_osc_counter - 22'd4000000;
            reg_counter <= reg_counter + 1;
            if(reg_counter == 7'h41)
            begin
                reg_counter <= 7'h1;
            end
        end
    end
end

reg [6:0] reg_counter_old;
reg [31:0] cycle_count;
wire [7:0] column_write_data = (tile_data >> map_y[2:0]) | (bus_data_in << (8 - map_y[2:0]));
always_ff @ (negedge clk)
begin

    cycle_count <= cycle_count + 1;
    if(clk_ce_cpu)
    begin
        if(reset)
        begin
            cycle_count <= 0;
            bus_cycle         <= 1'd0;
            reg_mode          <= 6'h0;
            reg_rate          <= 8'h0;
            reg_map_base      <= 24'h0;
            reg_sprite_base   <= 24'h0;
            reg_scroll_x      <= 7'd0;
            reg_scroll_y      <= 7'd0;
            map_scroll_x      <= 7'd0;
            map_scroll_y      <= 7'd0;
            state             <= PRC_STATE_IDLE;
            yC                <= 0;
            xC                <= 0;
            irq_copy_complete <= 0;
            irq_render_done   <= 0;
            bus_status        <= BUS_COMMAND_IDLE;
        end
        else
        begin
            if(bus_write_latch)
            begin
                case(bus_address_in)
                    24'h2080: // PRC Stage Control
                        reg_mode <= bus_data_in[5:0];

                    24'h2081: // PRC Rate Control
                    begin
                        //$display("0x%x, 0x%x", reg_rate[3:1], bus_data_in[3:1]);
                        // @todo? Reset the reg_counter when changing the divider.
                        reg_rate <= (reg_rate[3:1] != bus_data_in[3:1])?
                            {4'd0, bus_data_in[3:0]}:
                            {reg_rate[7:4], bus_data_in[3:0]};
                    end

                    24'h2082: // PRC Map Tile Base Low
                        reg_map_base[7:3] <= bus_data_in[7:3];
                    24'h2083: // PRC Map Tile Base Middle
                        reg_map_base[15:8] <= bus_data_in;
                    24'h2084: // PRC Map Tile Base High
                        reg_map_base[20:16] <= bus_data_in[4:0];

                    // @todo: These should be set regardless!
                    24'h2085: // PRC Map Vertical Scroll
                    begin
                        //if(bus_data_in[6:0] > 0)
                        //    $display("%d, %d", bus_data_in[6:0], map_height*8-64);
                        reg_scroll_y <= bus_data_in[6:0];
                        if(bus_data_in[6:0] <= (map_height*8-64))
                            map_scroll_y <= bus_data_in[6:0];
                    end
                    24'h2086: // PRC Map Horizontal Scroll
                    begin
                        reg_scroll_x <= bus_data_in[6:0];
                        if(bus_data_in[6:0] <= (map_width*8-96))
                            map_scroll_x <= bus_data_in[6:0];
                    end

                    24'h2087: // PRC Sprite Tile Base Low
                        reg_sprite_base[7:6] <= bus_data_in[7:6];
                    24'h2088: // PRC Sprite Tile Base Middle
                        reg_sprite_base[15:8] <= bus_data_in;
                    24'h2089: // PRC Sprite Tile Base High
                        reg_sprite_base[20:16] <= bus_data_in[4:0];

                    default:
                    begin
                    end
                endcase
            end

            irq_copy_complete  <= 0;
            irq_render_done <= 0;
            frame_complete <= 0;

            reg_counter_old <= reg_counter;
            if(reg_counter != reg_counter_old)
            begin
                if(reg_counter == 7'h41)
                    frame_complete <= 1;

                if(reg_rate[7:4] == rate_match)
                begin
                    // Active frame
                    if(reg_counter < 7'h18)
                    begin
                        state <= PRC_STATE_IDLE;
                    end
                    else if(reg_counter < 7'h41)
                    begin
                        // Draw map/sprite or copy frame
                        if(reg_mode[3:1] > 0 && !bus_ack)
                        begin
                            bus_request <= 1;
                            bus_cycle   <= 0;
                            state       <= next_state;
                            init_next_state(next_state);
                        end
                    end
                    else if(reg_counter == 7'h41)
                    begin
                        //$display("%d", cycle_count);
                        cycle_count     <= 0;
                        bus_request     <= 0;
                        reg_rate[7:4]   <= 4'd0;
                        irq_render_done <= 1;
                    end
                end
                else if(reg_counter == 7'h41)
                begin
                    // Non-active frame
                    reg_rate[7:4] <= reg_rate[7:4] + 4'd1;
                end
            end

            if(bus_ack)
            begin
                bus_cycle <= bus_cycle + 1;

                case(state)
                    PRC_STATE_MAP_DRAW:
                    begin
                        if(!bus_cycle)
                        begin
                            execution_step <= execution_step + 1;

                            if(execution_step % 5 < 4)
                                bus_status <= BUS_COMMAND_MEM_READ;
                            else
                                bus_status <= BUS_COMMAND_MEM_WRITE;

                            if(execution_step % 5 == 0)
                            begin
                                // Read tile address (top)
                                bus_address_out <= 24'h1360 + map_y[7:3] * map_width + {19'd0, map_x[7:3]};
                            end
                            else if(execution_step % 5 == 1)
                            begin
                                // Read tile address (bottom)
                                bus_address_out <= bus_address_out + {19'd0, map_width};
                                tile_address    <= bus_data_in;
                            end
                            else if(execution_step % 5 == 2)
                            begin
                                // Read tile data (top)
                                bus_address_out <= reg_map_base + {13'd0, tile_address, map_x[2:0]};
                                tile_address    <= bus_data_in;
                            end
                            else if(execution_step % 5 == 3)
                            begin
                                // Read tile data (bottom)
                                bus_address_out <= reg_map_base + {13'd0, tile_address, map_x[2:0]};
                                tile_data       <= bus_data_in;
                            end
                            else
                            begin
                                data_out <= reg_mode[0]? ~column_write_data: column_write_data;
                                bus_address_out <= 24'h1000 + yC * 96 + {16'h0, xC};

                                xC <= xC + 1;
                                if(xC == 7'd95)
                                begin
                                    xC <= 0;

                                    if(yC == 3'd7)
                                    begin
                                        yC <= 0;
                                        state <= next_state;
                                        init_next_state(next_state);
                                        execution_step <= 0;
                                    end
                                    else
                                        yC <= yC + 1;
                                end
                            end
                        end
                    end

                    PRC_STATE_SPR_DRAW:
                    begin
                        if(!bus_cycle)
                        begin
                            sprite_draw_state_current <= sprite_draw_state;

                            case(sprite_draw_state)
                                SPRITE_DRAW_STATE_READ_TILE_INFO:
                                begin
                                    bus_address_out   <= 24'h1300 + {17'd0, current_sprite_id, 2'd3};
                                    bus_status        <= BUS_COMMAND_MEM_READ;
                                    sprite_draw_state <= SPRITE_DRAW_STATE_READ_TILE_ADDRESS;
                                end
                                SPRITE_DRAW_STATE_READ_TILE_ADDRESS:
                                begin
                                    bus_address_out   <= 24'h1300 + {17'd0, current_sprite_id, 2'd2};
                                    bus_status        <= BUS_COMMAND_MEM_READ;
                                    sprite_draw_state <= SPRITE_DRAW_STATE_READ_POS_Y;
                                end
                                SPRITE_DRAW_STATE_READ_POS_Y:
                                begin
                                    bus_address_out     <= 24'h1300 + {17'd0, current_sprite_id, 2'd1};
                                    bus_status          <= BUS_COMMAND_MEM_READ;
                                    sprite_draw_state   <= SPRITE_DRAW_STATE_READ_POS_X;
                                end
                                SPRITE_DRAW_STATE_READ_POS_X:
                                begin
                                    bus_address_out   <= 24'h1300 + {17'd0, current_sprite_id, 2'd0};
                                    bus_status        <= BUS_COMMAND_MEM_READ;

                                    if(sprite_enabled)
                                    begin
                                        sprite_draw_state <= SPRITE_DRAW_STATE_READ_SPRITE_DATA;
                                        sprite_draw_tile_index <= 0;
                                    end
                                    else
                                    begin
                                        current_sprite_id <= current_sprite_id - 1;
                                        sprite_draw_state <= SPRITE_DRAW_STATE_READ_TILE_INFO;
                                        xC <= 0;

                                        if(current_sprite_id == 5'd0)
                                        begin
                                            state <= next_state;
                                            init_next_state(next_state);
                                        end
                                    end

                                end
                                SPRITE_DRAW_STATE_READ_SPRITE_DATA:
                                begin
                                    if(
                                        (sprite_abs_x < 9) || (sprite_abs_x >= 112) ||
                                        (sprite_abs_y < 9) || (sprite_abs_y >= 80)
                                    )
                                    begin
                                        bus_status <= BUS_COMMAND_IDLE;
                                        xC <= 0;
                                        // @todo: If any sprite_abs_x/y are
                                        // zero, we can skip completely.
                                        if(sprite_tile_index < 3)
                                            sprite_tile_index <= sprite_tile_index + 1;
                                        else
                                        begin
                                            sprite_tile_index <= 0;
                                            sprite_draw_state <= SPRITE_DRAW_STATE_READ_TILE_INFO;
                                            current_sprite_id <= current_sprite_id - 1;
                                            if(current_sprite_id == 5'd0)
                                            begin
                                                state <= next_state;
                                                init_next_state(next_state);
                                            end
                                        end
                                    end
                                    else
                                    begin
                                        bus_address_out <= reg_sprite_base +
                                            8 * (8 * {16'd0, sprite_tile_address} + {16'd0, sprite_tile_offset} + 24'd2) +
                                            {21'd0, sprite_info[0]? 3'd7 - xC[2:0]: xC[2:0]};
                                        bus_status <= BUS_COMMAND_MEM_READ;
                                        sprite_draw_state <= SPRITE_DRAW_STATE_READ_SPRITE_MASK;
                                    end
                                end
                                SPRITE_DRAW_STATE_READ_SPRITE_MASK:
                                begin
                                    bus_address_out <= reg_sprite_base +
                                        8 * (8 * {16'd0, sprite_tile_address} + {16'd0, sprite_tile_offset}) +
                                        {21'd0, sprite_info[0]? 3'd7 - xC[2:0]: xC[2:0]};
                                    bus_status <= BUS_COMMAND_MEM_READ;
                                    sprite_draw_state <= SPRITE_DRAW_STATE_READ_COLUMN;
                                    top_or_bottom <= 0;
                                end
                                SPRITE_DRAW_STATE_READ_COLUMN:
                                begin
                                    if(
                                        (top_or_bottom == 0) &&
                                        (sprite_abs_y >= 16) &&
                                        (sprite_row_x >= 16) && (sprite_row_x < 112)
                                    )
                                    begin
                                        bus_address_out <= 24'h1000 +
                                            {19'h0, sprite_abs_y[6:3] - 4'd2} * 96 +
                                            {15'h0, sprite_row_x - 8'd16};
                                        bus_status <= BUS_COMMAND_MEM_READ;
                                        sprite_draw_state <= SPRITE_DRAW_STATE_DRAW_SPRITE_COLUMN;
                                    end
                                    else if(
                                        (sprite_abs_y < 72) && (sprite_abs_y[2:0] != 0) &&
                                        (sprite_row_x >= 16) && (sprite_row_x < 112)
                                    )
                                    begin
                                        // @todo: Is it a problem if top_or_bottom == 0?
                                        top_or_bottom <= 1;
                                        bus_address_out <= 24'h1000 +
                                            {19'h0, sprite_abs_y[6:3] - 4'd1} * 96 +
                                            {15'h0, sprite_row_x - 8'd16};
                                        bus_status <= BUS_COMMAND_MEM_READ;
                                        sprite_draw_state <= SPRITE_DRAW_STATE_DRAW_SPRITE_COLUMN;
                                    end
                                    else
                                    begin
                                        // @todo: Can make into task?
                                        if(xC < 7)
                                        begin
                                            xC <= xC + 1;
                                            sprite_draw_state <= SPRITE_DRAW_STATE_READ_SPRITE_DATA;
                                        end
                                        else
                                        begin
                                            xC <= 0;
                                            if(sprite_tile_index < 3)
                                            begin
                                                sprite_draw_state <= SPRITE_DRAW_STATE_READ_SPRITE_DATA;
                                                sprite_tile_index <= sprite_tile_index + 1;
                                            end
                                            else
                                            begin
                                                sprite_tile_index <= 0;
                                                sprite_draw_state <= SPRITE_DRAW_STATE_READ_TILE_INFO;
                                                current_sprite_id <= current_sprite_id - 1;
                                                if(current_sprite_id == 5'd0)
                                                begin
                                                    state <= next_state;
                                                    init_next_state(next_state);
                                                end
                                            end
                                        end
                                    end
                                end
                                SPRITE_DRAW_STATE_DRAW_SPRITE_COLUMN:
                                begin
                                    data_out <= sprite_color_masked_and_shifted | column_data_masked;
                                    bus_address_out <= 24'h1000 +
                                        {19'h0, (sprite_abs_y[6:3] + {3'd0, top_or_bottom}) - 4'd2} * 96 +
                                        {15'h0, sprite_row_x - 8'd16};
                                    bus_status <= BUS_COMMAND_MEM_WRITE;

                                    if(
                                        (top_or_bottom == 0) &&
                                        (sprite_abs_y < 72) && (sprite_abs_y[2:0] != 0) &&
                                        (sprite_row_x >= 16) && (sprite_row_x < 112)
                                    )
                                    begin
                                        top_or_bottom <= 1;
                                        sprite_draw_state <= SPRITE_DRAW_STATE_READ_COLUMN;
                                    end
                                    else
                                    begin
                                        if(xC < 7)
                                        begin
                                            xC <= xC + 1;
                                            sprite_draw_state <= SPRITE_DRAW_STATE_READ_SPRITE_DATA;
                                        end
                                        else
                                        begin
                                            xC <= 0;
                                            if(sprite_tile_index < 3)
                                            begin
                                                sprite_tile_index <= sprite_tile_index + 1;
                                                sprite_draw_state <= SPRITE_DRAW_STATE_READ_SPRITE_DATA;
                                            end
                                            else
                                            begin
                                                sprite_tile_index <= 0;
                                                sprite_draw_state <= SPRITE_DRAW_STATE_READ_TILE_INFO;
                                                current_sprite_id <= current_sprite_id - 1;
                                                if(current_sprite_id == 5'd0)
                                                begin
                                                    state <= next_state;
                                                    init_next_state(next_state);
                                                end
                                            end
                                        end
                                    end
                                end
                                default:
                                begin
                                end
                            endcase
                        end
                    end

                    PRC_STATE_FRAME_COPY:
                    begin
                        //execution_step <= execution_step + 1;
                        if(!bus_cycle)
                        begin
                            case(frame_copy_state)
                                FRAME_COPY_STATE_COLUMN_SET1:
                                begin
                                    frame_copy_state <= FRAME_COPY_STATE_COLUMN_SET2;
                                    data_out        <= 8'h10;
                                    bus_address_out <= 24'h20FE;
                                    bus_status      <= BUS_COMMAND_MEM_WRITE;
                                end
                                FRAME_COPY_STATE_COLUMN_SET2:
                                begin
                                    frame_copy_state <= FRAME_COPY_STATE_PAGE_SET;
                                    data_out        <= 8'h0;
                                    bus_address_out <= 24'h20FE;
                                    bus_status      <= BUS_COMMAND_MEM_WRITE;
                                end
                                FRAME_COPY_STATE_PAGE_SET:
                                begin
                                    frame_copy_state <= FRAME_COPY_STATE_MEM_READ;
                                    data_out        <= {4'hB, 1'h0, yC};
                                    bus_address_out <= 24'h20FE;
                                    bus_status      <= BUS_COMMAND_MEM_WRITE;
                                end
                                FRAME_COPY_STATE_MEM_READ:
                                begin
                                    frame_copy_state <= FRAME_COPY_STATE_LCD_WRITE;
                                    bus_address_out <= 24'h1000 + yC * 96 + {16'h0, xC};
                                    bus_status      <= BUS_COMMAND_MEM_READ;
                                end
                                FRAME_COPY_STATE_LCD_WRITE:
                                begin
                                    frame_copy_state <= FRAME_COPY_STATE_MEM_READ;
                                    // Write the data to lcd
                                    data_out        <= bus_data_in;
                                    bus_address_out <= 24'h20FF;
                                    bus_status      <= BUS_COMMAND_MEM_WRITE;

                                    xC <= xC + 1;
                                    if(xC == 7'd95)
                                    begin
                                        xC <= 0;
                                        frame_copy_state <= FRAME_COPY_STATE_COLUMN_SET1;

                                        if(yC == 3'd7)
                                        begin
                                            irq_copy_complete <= 1;
                                            yC <= 0;
                                            state <= next_state;
                                        end
                                        else
                                            yC <= yC + 1;
                                    end
                                end
                                default:
                                begin
                                end
                            endcase
                        end
                    end

                    default:
                    begin
                    end
                endcase
            end
        end
    end
end

always_ff @ (posedge clk)
begin
    if(clk_ce_cpu)
    begin
        bus_write_latch <= 0;

        read  <= 0;
        write <= 0;

        if(bus_write) bus_write_latch <= 1;


        if(bus_cycle)
        begin
            if(bus_status == BUS_COMMAND_MEM_READ)
                read <= 1;
            else if(bus_status == BUS_COMMAND_MEM_WRITE)
                write <= 1;
        end
        else if(state == PRC_STATE_SPR_DRAW)
        begin
            case(sprite_draw_state_current)
                SPRITE_DRAW_STATE_READ_TILE_INFO:
                    sprite_info <= bus_data_in[3:0];

                SPRITE_DRAW_STATE_READ_TILE_ADDRESS:
                    sprite_tile_address <= bus_data_in;

                SPRITE_DRAW_STATE_READ_POS_Y:
                    sprite_y <= bus_data_in[6:0];

                SPRITE_DRAW_STATE_READ_POS_X:
                    sprite_x <= bus_data_in[6:0];

                SPRITE_DRAW_STATE_READ_COLUMN:
                    column_data <= bus_data_in;

                SPRITE_DRAW_STATE_READ_SPRITE_DATA:
                    begin
                        if(sprite_info[1])
                         begin
                            for(int i = 0; i < 8; ++i)
                               sprite_data[i] <= bus_data_in[7-i];
                         end
                         else
                             sprite_data <= bus_data_in;
                    end

                SPRITE_DRAW_STATE_READ_SPRITE_MASK:
                    begin
                        if(sprite_info[1])
                         begin
                            for(int i = 0; i < 8; ++i)
                               sprite_mask[i] <= bus_data_in[7-i];
                         end
                         else
                             sprite_mask <= bus_data_in;
                    end

                default:
                begin
                end
            endcase
        end
    end
end

always_comb
begin
    case(bus_address_in)
        24'h2080: // PRC Stage Control
            reg_data_out = {2'd0, reg_mode};
        24'h2081: // PRC Rate Control
            reg_data_out = reg_rate;
        24'h2082: // PRC Map Tile Base (Lo)
            reg_data_out = reg_map_base[7:0];
        24'h2083: // PRC Map Tile Base (Med)
            reg_data_out = reg_map_base[15:8];
        24'h2084: // PRC Map Tile Base (Hi)
            reg_data_out = reg_map_base[23:16];
        24'h2085: // PRC Map Vertical Scroll
            reg_data_out = {1'd0, reg_scroll_y};
        24'h2086: // PRC Map Horizontal Scroll
            reg_data_out = {1'd0, reg_scroll_x};
        24'h2087: // PRC Map Sprite Base (Lo)
            reg_data_out = reg_sprite_base[7:0];
        24'h2088: // PRC Map Sprite Base (Med)
            reg_data_out = reg_sprite_base[15:8];
        24'h2089: // PRC Map Sprite Base (Hi)
            reg_data_out = reg_sprite_base[23:16];
        24'h208A: // PRC Counter
            reg_data_out = {1'd0, reg_counter};
        default:
            reg_data_out = 8'd0;

    endcase
end

endmodule
