module lcd_controller
(
    input clk,
    input clk_ce,
    input reset,
    input bus_write,
    input bus_read,
    input [23:0] address_in,
    input [7:0] data_in,
    output logic [7:0] data_out,
    output [5:0] lcd_contrast,
    input [7:0] read_x,
    input [3:0] read_y,
    output [7:0] read_column
);
assign lcd_contrast = max_contrast_enabled ? 6'h3F: contrast;

reg [5:0] contrast;
reg contrast_set;
reg display_enabled;
reg segment_driver_direction;
reg read_modify_mode;
reg max_contrast_enabled;
reg all_pixels_on_enabled;
reg invert_pixels_enabled;
reg row_order;
reg [5:0] start_line;
reg [7:0] column;
reg [3:0] page;
reg read_latch;
reg write_latch;

// (0-8, pages 0-7 are 8px high, Page 8 = 1px high)
(* ramstyle = "no_rw_check" *) reg [7:0] lcd_data[9*132];


wire [10:0] pixel_address = page * 11'd132 + (
    (segment_driver_direction)?
        131 - {3'd0, column}:
        {3'd0, column});

reg [7:0] lcd_read;

// @note: Where are these used? Can we test?
assign read_column = display_enabled ?
    (all_pixels_on_enabled ?
        8'hFF:
        (invert_pixels_enabled ? ~column_latch: column_latch)
    ):
    8'h0;

reg [7:0] column_latch;
always_ff @ (posedge clk)
begin
    column_latch <= lcd_data[{7'b0, read_y} * 132 + {3'b0, read_x}];
    lcd_read     <= lcd_data[pixel_address];
end

always_ff @ (posedge clk)
begin
    if(clk_ce)
    begin
        if(reset)
        begin
            contrast_set             <= 0;
            start_line               <= 0;
            display_enabled          <= 0;
            segment_driver_direction <= 0;
            read_modify_mode         <= 0;
            column                   <= 8'd0;
            page                     <= 4'd0;
            read_latch               <= 0;
            write_latch              <= 0;
            contrast                 <= 0;
        end
        else
        begin
            read_latch  <= bus_read;
            write_latch <= bus_write;

            if(bus_write && !write_latch)
            begin
                case(address_in)
                    24'h20FE:
                    begin
                        if(contrast_set)
                        begin
                            contrast_set <= 0;
                            contrast <= data_in[5:0];
                            //$display("Contrast set to %d", data_in[5:0]);
                        end
                        else
                        begin
                            casez(data_in)
                                8'b0000_????:
                                begin
                                    if(!read_modify_mode)
                                        column <= {column[7:4], data_in[3:0]};
                                end
                                8'b0001_????:
                                begin
                                    if(!read_modify_mode)
                                        column <= {data_in[3:0], column[3:0]};
                                end
                                8'b01??_????:
                                    // Set starting LCD scanline (cause warp around)
                                    start_line <= data_in[5:0];

                                8'b1000_0001:
                                    // Set contrast at the next write
                                    contrast_set <= 1;

                                8'b1010_000?:
                                    // Segment Driver Direction Select, Normal
                                    segment_driver_direction <= data_in[0];

                                8'b1010_001?:
                                    // Max Contrast, Disable
                                    max_contrast_enabled <= data_in[0];

                                8'b1010_010?:
                                    // Set All Pixels, Disable
                                    all_pixels_on_enabled <= data_in[0];

                                8'b1010_011?:
                                    // Invert All Pixels, Disable
                                    invert_pixels_enabled <= data_in[0];

                                8'b1010_111?:
                                    // Display Off
                                    display_enabled <= data_in[0];

                                8'b1011_????:
                                    // Set page (0-8, each page is 8px high)
                                    page <= data_in[3:0];

                                8'b1100_????:
                                    // Display rows from top to bottom as 0 to 63
                                    row_order <= data_in[3];

                                8'b1110_0000:
                                    // Start "Read Modify Write"
                                    read_modify_mode <= 1;
                                    //MinxLCD.RMWColumn = MinxLCD.Column;

                                8'b1110_0010:
                                begin
                                    // Reset
                                    contrast_set                 <= 0;
                                    contrast                     <= 6'h20;
                                    column                       <= 0;
                                    start_line                   <= 0;
                                    segment_driver_direction     <= 0;
                                    max_contrast_enabled         <= 0;
                                    all_pixels_on_enabled        <= 0;
                                    invert_pixels_enabled        <= 0;
                                    display_enabled              <= 0;
                                    page                         <= 0;
                                    row_order                    <= 0;
                                    read_modify_mode             <= 0;
                                end

                                8'b1110_1110:
                                    // End "Read Modify Write"
                                    read_modify_mode <= 0;
                                    //MinxLCD.Column = MinxLCD.RMWColumn;

                                default:
                                begin
                                end
                            endcase
                        end
                    end
                    24'h20FF:
                    begin
                        if(contrast_set)
                        begin
                            contrast_set <= 0;
                            contrast <= data_in[5:0];
                        end
                        else
                        begin
                            lcd_data[pixel_address] <= data_in;
                            column <= (column < 8'd131)? column + 8'd1: 8'd131;
                        end
                    end

                endcase
            end
            else if(bus_read && !read_latch)
            begin
                case(address_in)
                    24'h20FE:
                    begin
                        if(contrast_set)
                        begin
                            contrast_set <= 0;
                            contrast <= 6'h3F;
                        end
                    end
                    24'h20FF:
                    begin
                        if(!read_modify_mode)
                        begin
                            column <= (column < 8'd131)? column + 8'd1: 8'd131;
                        end
                    end
                endcase
            end
        end
    end
end

always_comb
begin
    if(contrast_set)
        data_out = 8'd0;
    else
    begin
        case(address_in)
            24'h20FE:
                data_out = 8'h40 | (display_enabled ? 8'h20: 8'h00);

            24'h20FF:
            begin
                data_out = lcd_read;
                if(page >= 8)
                     data_out = {7'd0, data_out[0]};
            end

            default:
                data_out = 8'd0;

        endcase
    end
end

endmodule
