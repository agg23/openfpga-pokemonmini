module pokemonmini (
    input wire clk_sys_32,
    input wire clk_mem_40,
    input wire clk_rt_4_195,

    input wire reset_n,
    input wire pll_core_locked,

    // Data in
    input wire        ioctl_wr,
    input wire [24:0] ioctl_addr,
    input wire [ 7:0] ioctl_dout,
    input wire        ioctl_download,

    // SDRAM
    output wire [12:0] dram_a,
    output wire [ 1:0] dram_ba,
    inout  wire [15:0] dram_dq,
    output wire [ 1:0] dram_dqm,
    output wire        dram_clk,
    output wire        dram_cke,
    output wire        dram_ras_n,
    output wire        dram_cas_n,
    output wire        dram_we_n,

    // Video
    output wire hsync,
    output wire vsync,
    output wire hblank,
    output wire vblank,
    output wire [7:0] video_r,
    output wire [7:0] video_g,
    output wire [7:0] video_b,

    // Audio
    output wire [15:0] audio
);
  wire [127:0] status = 0;
  wire [ 64:0] rtc_timestamp = 0;

  reg  [ 31:0]                    sd_lba;
  reg                             sd_rd = 0;
  reg                             sd_wr = 0;
  wire                            sd_ack;
  wire [ 13:0]                    sd_buff_addr;
  wire [  7:0]                    sd_buff_dout;
  wire [  7:0]                    sd_buff_din;
  wire                            sd_buff_wr;
  wire                            img_mounted;
  wire                            img_readonly;
  wire [ 63:0]                    img_size;

  ///////////////////////   CLOCKS   ///////////////////////////////

  reg  [  6:0]                    clk_rt_prescale = 0;
  always_ff @(posedge clk_rt_4_195) clk_rt_prescale <= clk_rt_prescale + 1;

  reg [3:0] clk_prescale = 0;
  reg [2:0] minx_clk_prescale = 0;
  always_ff @(posedge clk_sys_32) begin
    clk_prescale <= clk_prescale + 1;
    if (clk_prescale == 3'd4) clk_prescale <= 0;
    minx_clk_prescale <= minx_clk_prescale + 1;
  end

  //reg sdram_read = 0;
  //always_ff @ (posedge clk_sys) sdram_read <= ~sdram_read;

  wire reset = ~reset_n | cart_download | bios_download | bk_loading;
  reg [3:0] reset_counter;
  always_ff @(posedge clk_sys_32) begin
    if (reset) reset_counter <= 4'hF;
    else if (reset_counter > 4'd0 && &minx_clk_prescale) reset_counter <= reset_counter - 4'd1;
  end

  //////////////////////////////////////////////////////////////////

  wire ce_pix = (clk_prescale == 3'd4);
  wire [7:0] video;

  reg hs, vs, hbl, vbl;

  assign hsync  = hs;
  assign vsync  = vs;
  assign hblank = hbl;
  assign vblank = vbl;

  localparam H_WIDTH = 9'd407;
  localparam V_HEIGHT = 9'd262;
  localparam LCD_XSIZE = 9'd96;
  localparam LCD_YSIZE = 9'd64;
  localparam LCD_COLS = LCD_YSIZE >> 3;

  localparam HS_WIDTH = 9'd24;
  localparam HS_START = H_WIDTH - 9'd24;
  localparam HS_END = H_WIDTH + HS_WIDTH - 9'd1 - 9'd24;

  wire [8:0] active_xsize = !zoom_enable ? 9'd96 : 9'd288;
  wire [8:0] active_ysize = !zoom_enable ? 9'd64 : 9'd192;
  wire [8:0] h_start = (H_WIDTH - active_xsize) >> 1;
  wire [8:0] v_start = (V_HEIGHT - active_ysize) >> 1;

  // These are in the original img (lcd screen) coordinates.
  wire [8:0] img_start_x = (!zoom_enable || zoom_mode == 2)? 9'd0: (zoom_mode == 0 ? 9'd96: 9'd24);
  wire [8:0] img_start_y = (!zoom_enable || zoom_mode == 2)? 9'd0: (zoom_mode == 0 ? 9'd64: 9'd16);
  wire [8:0] img_xpos = xpos - img_start_x;
  wire [8:0] img_ypos = ypos - img_start_y;
  wire [8:0] img_active_xsize = (zoom_mode == 0) ? 9'd288 : (zoom_mode == 1) ? 9'd144 : 9'd96;

  // 401 x 258
  // 224 x 144

  reg frame_complete_latch;
  (* ramstyle = "no_rw_check" *) reg [7:0] fb0[768];
  (* ramstyle = "no_rw_check" *) reg [7:0] fb1[768];
  (* ramstyle = "no_rw_check" *) reg [7:0] fb2[768];
  (* ramstyle = "no_rw_check" *) reg [7:0] fb3[768];
  reg [1:0] fb_write_index = 0;
  reg [1:0] fb_read_index = 0;
  wire [9:0] fb_read_address = {1'b0, LCD_XSIZE} * {5'b0, img_ypos[6:3]} + img_xpos;
  wire [9:0] fb_write_address = {1'b0, LCD_XSIZE} * {5'b0, lcd_read_ypos} + {1'b0, lcd_read_xpos};
  reg [7:0] fb0_read;
  reg [7:0] fb1_read;
  reg [7:0] fb2_read;
  reg [7:0] fb3_read;
  wire [7:0] fb_read[0:3];
  assign fb_read = '{fb0_read, fb1_read, fb2_read, fb3_read};
  reg [5:0] lcd_contrast_latch[0:3];

  reg [7:0] lcd_read_xpos;
  reg [3:0] lcd_read_ypos;
  always @(posedge clk_sys_32) begin
    if (reset) begin
      fb_read_index <= 0;
      fb_write_index <= 1;
      frame_complete_latch <= 0;
      lcd_read_xpos <= 0;
      lcd_read_ypos <= 0;
    end else begin
      if (frame_complete) frame_complete_latch <= 1;

      // Need to wait 2 clocks for data from lcd?
      if (frame_complete_latch && &minx_clk_prescale) begin
        lcd_contrast_latch[fb_write_index] <= lcd_contrast;
        case (fb_write_index)
          0: fb0[fb_write_address] <= lcd_read_column;
          1: fb1[fb_write_address] <= lcd_read_column;
          2: fb2[fb_write_address] <= lcd_read_column;
          3: fb3[fb_write_address] <= lcd_read_column;
        endcase

        lcd_read_xpos <= lcd_read_xpos + 1;
        if (lcd_read_xpos == LCD_XSIZE - 1) begin
          lcd_read_xpos <= 0;
          lcd_read_ypos <= lcd_read_ypos + 1;
          if (lcd_read_ypos == LCD_COLS - 1) begin
            fb_write_index <= fb_write_index + 1;
            fb_read_index <= fb_write_index;
            frame_complete_latch <= 0;
            lcd_read_ypos <= 0;
          end
        end
      end
    end

    fb0_read <= fb0[fb_read_address];
    fb1_read <= fb1[fb_read_address];
    fb2_read <= fb2[fb_read_address];
    fb3_read <= fb3[fb_read_address];
  end

  reg [8:0] hpos, vpos;
  reg [7:0] pixel_value_red;
  reg [7:0] pixel_value_green;
  reg [7:0] pixel_value_blue;

  assign video_r = pixel_value_red;
  assign video_g = pixel_value_green;
  assign video_b = pixel_value_blue;

  wire blend_mode = status[98];

  localparam bit [7:0] OFF_COLOR[0:2] = '{8'hB7, 8'hCA, 8'hB7};
  localparam bit [7:0] ON_COLOR[0:2] = '{8'h04, 8'h16, 8'h04};

  // Contrast level on light and dark pixel
  localparam bit [7:0] contrast_level_map[128] = '{
      8'd0,
      8'd4,  //  0 (0x00)
      8'd0,
      8'd4,  //  1 (0x01)
      8'd0,
      8'd4,  //  2 (0x02)
      8'd0,
      8'd4,  //  3 (0x03)
      8'd0,
      8'd6,  //  4 (0x04)
      8'd0,
      8'd11,  //  5 (0x05)
      8'd0,
      8'd17,  //  6 (0x06)
      8'd0,
      8'd24,  //  7 (0x07)
      8'd0,
      8'd31,  //  8 (0x08)
      8'd0,
      8'd40,  //  9 (0x09)
      8'd0,
      8'd48,  // 10 (0x0A)
      8'd0,
      8'd57,  // 11 (0x0B)
      8'd0,
      8'd67,  // 12 (0x0C)
      8'd0,
      8'd77,  // 13 (0x0D)
      8'd0,
      8'd88,  // 14 (0x0E)
      8'd0,
      8'd99,  // 15 (0x0F)
      8'd0,
      8'd110,  // 16 (0x10)
      8'd0,
      8'd122,  // 17 (0x11)
      8'd0,
      8'd133,  // 18 (0x12)
      8'd0,
      8'd146,  // 19 (0x13)
      8'd0,
      8'd158,  // 20 (0x14)
      8'd0,
      8'd171,  // 21 (0x15)
      8'd0,
      8'd184,  // 22 (0x16)
      8'd0,
      8'd198,  // 23 (0x17)
      8'd0,
      8'd212,  // 24 (0x18)
      8'd0,
      8'd226,  // 25 (0x19)
      8'd0,
      8'd240,  // 26 (0x1A)
      8'd0,
      8'd255,  // 27 (0x1B)
      8'd2,
      8'd255,  // 28 (0x1C)
      8'd5,
      8'd255,  // 29 (0x1D)
      8'd10,
      8'd255,  // 30 (0x1E)
      8'd15,
      8'd255,  // 31 (0x1F)
      8'd21,
      8'd255,  // 32 (0x20)
      8'd27,
      8'd255,  // 33 (0x21)
      8'd34,
      8'd255,  // 34 (0x22)
      8'd41,
      8'd255,  // 35 (0x23)
      8'd48,
      8'd255,  // 36 (0x24)
      8'd56,
      8'd255,  // 37 (0x25)
      8'd64,
      8'd255,  // 38 (0x26)
      8'd73,
      8'd255,  // 39 (0x27)
      8'd81,
      8'd255,  // 40 (0x28)
      8'd90,
      8'd255,  // 41 (0x29)
      8'd100,
      8'd255,  // 42 (0x2A)
      8'd109,
      8'd255,  // 43 (0x2B)
      8'd119,
      8'd255,  // 44 (0x2C)
      8'd129,
      8'd255,  // 45 (0x2D)
      8'd139,
      8'd255,  // 46 (0x2E)
      8'd149,
      8'd255,  // 47 (0x2F)
      8'd160,
      8'd255,  // 48 (0x30)
      8'd171,
      8'd255,  // 49 (0x31)
      8'd182,
      8'd255,  // 50 (0x32)
      8'd193,
      8'd255,  // 51 (0x33)
      8'd204,
      8'd255,  // 52 (0x34)
      8'd216,
      8'd255,  // 53 (0x35)
      8'd228,
      8'd255,  // 54 (0x36)
      8'd240,
      8'd255,  // 55 (0x37)
      8'd240,
      8'd255,  // 56 (0x38)
      8'd240,
      8'd255,  // 57 (0x39)
      8'd240,
      8'd255,  // 58 (0x3A)
      8'd240,
      8'd255,  // 59 (0x3B)
      8'd240,
      8'd255,  // 60 (0x3C)
      8'd240,
      8'd255,  // 61 (0x3D)
      8'd240,
      8'd255,  // 62 (0x3E)
      8'd240,
      8'd255  // 63 (0x3F)
  };

  function [7:0] get_pixel_intensity(input px, input [5:0] contrast);
    get_pixel_intensity = px?
        contrast_level_map[{contrast,1'b1}]:
        contrast_level_map[{contrast,1'b0}];
  endfunction

  // 5-shades
  wire [9:0] pixel_4frame_blend = {2'b0, get_pixel_intensity(
      fb_read[fb_read_index-0][img_ypos[2:0]], lcd_contrast_latch[fb_read_index-0]
  )} + {2'b0, get_pixel_intensity(
      fb_read[fb_read_index-1][img_ypos[2:0]], lcd_contrast_latch[fb_read_index-1]
  )} + {2'b0, get_pixel_intensity(
      fb_read[fb_read_index-2][img_ypos[2:0]], lcd_contrast_latch[fb_read_index-2]
  )} + {2'b0, get_pixel_intensity(
      fb_read[fb_read_index-3][img_ypos[2:0]], lcd_contrast_latch[fb_read_index-3]
  )};

  wire [7:0] pixel_intensity = (blend_mode == 0) ? get_pixel_intensity(
      fb_read[fb_read_index][img_ypos[2:0]], lcd_contrast_latch[fb_read_index]
  ) : pixel_4frame_blend[9:2];

  wire zoom_enable = !status[30];
  wire [1:0] zoom_mode = 2'd2 - status[29:28];
  reg [8:0] xpos, ypos;
  // 3x integer scaling
  reg [1:0] subpixel_x;
  reg [1:0] subpixel_y;
  always @(posedge clk_sys_32) begin
    if (ce_pix) begin
      if (hpos == h_start + active_xsize) hbl <= 1;
      if (hpos == h_start) hbl <= 0;
      if (vpos >= v_start + active_ysize) vbl <= 1;
      if (vpos == v_start) vbl <= 0;

      if (hpos == HS_START) begin
        hs <= 1;
        if (vpos == 1) vs <= 1;
        if (vpos == 4) vs <= 0;
      end

      if (hpos == HS_END) hs <= 0;

      hpos <= hpos + 1;
      if (hpos == H_WIDTH - 1'd1) begin
        hpos <= 0;
        vpos <= vpos + 1;

        if (vpos == V_HEIGHT - 1'd1) vpos <= 0;
      end

      if (vbl) begin
        ypos       <= 0;
        xpos       <= 0;
        subpixel_x <= 0;
        subpixel_y <= 0;
      end else if (!hbl) begin
        // Active area
        if (zoom_enable) begin
          subpixel_x <= subpixel_x + 1;
          if (subpixel_x == zoom_mode) begin
            subpixel_x <= 0;
            xpos <= xpos + 1;

            if (xpos == img_active_xsize - 1) begin
              xpos       <= 0;
              subpixel_y <= subpixel_y + 1;

              if (subpixel_y == zoom_mode) begin
                subpixel_y <= 0;
                ypos       <= ypos + 1;
              end

            end
          end
        end else begin
          xpos <= xpos + 1;

          if (xpos == LCD_XSIZE - 1) begin
            xpos <= 0;
            ypos <= ypos + 1;
          end
        end
      end

    end

    // @todo: Perhaps make intensity go to 256 instead of 255. Then we can just
    // shift the final color result instead of dividing by 255.
    if(xpos >= img_start_x && ypos >= img_start_y && xpos < img_start_x + LCD_XSIZE && ypos < img_start_y + LCD_YSIZE)
    begin
      pixel_value_red   <= ({8'h0, 8'hFF - pixel_intensity} * OFF_COLOR[0] + {8'h0, pixel_intensity} * ON_COLOR[0]) / 16'd255;
      pixel_value_green <= ({8'h0, 8'hFF - pixel_intensity} * OFF_COLOR[1] + {8'h0, pixel_intensity} * ON_COLOR[1]) / 16'd255;
      pixel_value_blue  <= ({8'h0, 8'hFF - pixel_intensity} * OFF_COLOR[2] + {8'h0, pixel_intensity} * ON_COLOR[2]) / 16'd255;
    end else begin
      pixel_value_red   <= 8'd0;
      pixel_value_green <= 8'd0;
      pixel_value_blue  <= 8'd0;
    end
  end

  // in:  {select, R, b, a, up, down, left, right}
  // out: {power, right, left, down, up, c, b, a}
  // wire [8:0] keys_active = {
  //   joystick_0[7],  //      (L) Shock
  //   joystick_0[8],  // (select) Power
  //   joystick_0[0],  //  (right) right
  //   joystick_0[1],  //   (left) left
  //   joystick_0[2],  //   (down) down
  //   joystick_0[3],  //     (up) up
  //   joystick_0[6],  //      (R) C
  //   joystick_0[5],  //      (B) B
  //   joystick_0[4]  //      (A) A
  // };
  wire [8:0] keys_active = 0;

  wire [5:0] lcd_contrast;
  wire [7:0] minx_data_in;
  wire [7:0] minx_data_out;
  wire [23:0] minx_address_out;

  wire bus_request;
  wire bus_ack;
  wire minx_we;
  wire [1:0] bus_status;
  wire [7:0] lcd_read_column;
  wire frame_complete;

  // @todo: Need access to eeprom for initialization. While initializing it, we
  // can set clk_ce to low so that the cpu is paused.
  wire sound_pulse;
  wire [1:0] sound_volume;
  wire eeprom_internal_we;
  wire eeprom_we = eeprom_we_rtc | bk_wr;
  wire [12:0] eeprom_address = eeprom_we_rtc ? eeprom_write_address_rtc : bk_addr;
  wire [7:0] eeprom_write_data = eeprom_we_rtc ? eeprom_write_data_rtc : bk_data;
  wire minx_rumble;
  minx minx (
      .clk        (clk_sys_32),
      .clk_ce_4mhz(&minx_clk_prescale),
      .clk_rt     (clk_rt_4_195),
      .clk_rt_ce  (&clk_rt_prescale),
      .reset      (reset | (|reset_counter)),
      .data_in    (minx_data_in),
      .keys_active(keys_active),
      //.pk                    (pk),
      //.pl                    (pl),
      //.i01                   (i01),
      .data_out   (minx_data_out),
      .address_out(minx_address_out),
      .bus_status (bus_status),
      //.read                  (read),
      //.read_interrupt_vector (read_interrupt_vector),
      .write      (minx_we),
      //.sync                  (sync),
      //.iack                  (iack),

      .lcd_contrast   (lcd_contrast),
      .lcd_read_x     (lcd_read_xpos),
      .lcd_read_y     (lcd_read_ypos),
      .lcd_read_column(lcd_read_column),
      .frame_complete (frame_complete),

      .sound_pulse (sound_pulse),
      .sound_volume(sound_volume),
      .rumble      (minx_rumble),

      .validate_rtc      (validate_rtc),
      .eeprom_internal_we(eeprom_internal_we),
      .eeprom_we         (eeprom_we),
      .eeprom_address    (eeprom_address),
      .eeprom_write_data (eeprom_write_data),
      .eeprom_read_data  (bk_q)
  );

  assign audio = sound_pulse ? {2'h0, sound_volume, 12'h0} : 16'h0;

  wire [7:0] bios_data_out;
  spram #(
      .init_file("freebios.hex"),
      .widthad_a(12),
      .width_a  (8)
  ) bios (
      .clock  (clk_sys_32),
      .address(bios_download ? ioctl_addr[11:0] : minx_address_out[11:0]),
      .q      (bios_data_out),

      .wren(bios_download & ioctl_wr),
      .data(ioctl_dout)
  );

  wire [7:0] ram_data_out;
  spram #(
      .widthad_a(12),
      .width_a  (8)
  ) minx_ram (
      .clock(clk_sys_32),
      .address(minx_address_out[11:0]),
      .q(ram_data_out),
      .data(minx_data_out),
      .wren(
        minx_we &&
        (bus_status == BUS_COMMAND_MEM_WRITE) &&
        (minx_address_out >= 24'h1000) &&
        (minx_address_out < 24'h2000)
    )
  );

  /////////////   EEPROM saving/loading/RTC   //////////////////////
  reg eeprom_we_rtc;
  reg [12:0] eeprom_write_address_rtc;
  reg [7:0] eeprom_write_data_rtc;
  reg validate_rtc;


  function [7:0] bcd2bin(input [7:0] bcd);
    bcd2bin = {4'd0, bcd[7:4]} * 8'd10 + {4'd0, bcd[3:0]};
  endfunction

  wire [7:0] rtc_year = bcd2bin(rtc_timestamp[47:40]);
  wire [7:0] rtc_month = bcd2bin(rtc_timestamp[39:32]);
  wire [7:0] rtc_day = bcd2bin(rtc_timestamp[31:24]);
  wire [7:0] rtc_hour = bcd2bin(rtc_timestamp[23:16]);
  wire [7:0] rtc_min = bcd2bin(rtc_timestamp[15:8]);
  wire [7:0] rtc_sec = bcd2bin(rtc_timestamp[7:0]);

  wire [7:0] rtc_checksum = rtc_year + rtc_month + rtc_day + rtc_hour + rtc_min + rtc_sec;

  localparam bit [7:0] eeprom_data_array[0:10] = '{
      8'h47,
      8'h42,
      8'h4D,
      8'h4E,
      8'h01,
      8'h03,
      8'h01,
      8'h1F,
      8'h00,
      8'h00,
      8'h00
  };
  localparam bit [12:0] eeprom_address_array[0:10] = '{
      13'h0000,
      13'h0001,
      13'h0002,
      13'h0003,
      13'h1FF2,
      13'h1FF3,
      13'h1FF4,
      13'h1FF5,
      13'h1FF6,
      13'h1FF7,
      13'h1FF8
  };
  reg [4:0] eeprom_write_stage;
  always_ff @(posedge clk_sys_32) begin
    if (minx_address_out == 24'hAB) eeprom_write_stage <= 1;

    if (eeprom_write_stage > 0) begin
      eeprom_write_stage <= eeprom_write_stage + 1;

      if (eeprom_write_stage < 5'd12) begin
        eeprom_write_address_rtc <= eeprom_address_array[eeprom_write_stage[3:0]-4'd1];
        eeprom_write_data_rtc    <= eeprom_data_array[eeprom_write_stage[3:0]-4'd1];
      end

      case (eeprom_write_stage)
        'd1: begin
          eeprom_we_rtc <= 1;
          validate_rtc  <= 1;
        end
        'd12: begin
          eeprom_write_address_rtc <= 13'h1FF9;
          eeprom_write_data_rtc    <= rtc_year;
        end
        'd13: begin
          eeprom_write_address_rtc <= 13'h1FFA;
          eeprom_write_data_rtc    <= rtc_month;
        end
        'd14: begin
          eeprom_write_address_rtc <= 13'h1FFB;
          eeprom_write_data_rtc    <= rtc_day;
        end
        'd15: begin
          eeprom_write_address_rtc <= 13'h1FFC;
          eeprom_write_data_rtc    <= rtc_hour;
        end
        'd16: begin
          eeprom_write_address_rtc <= 13'h1FFD;
          eeprom_write_data_rtc    <= rtc_min;
        end
        'd17: begin
          eeprom_write_address_rtc <= 13'h1FFE;
          eeprom_write_data_rtc    <= rtc_sec;
        end
        'd18: begin
          eeprom_write_address_rtc <= 13'h1FFF;
          eeprom_write_data_rtc    <= rtc_checksum;
        end
        'd19: begin
          validate_rtc       <= 0;
          eeprom_we_rtc      <= 0;
          eeprom_write_stage <= 0;
        end
        default: begin
        end
      endcase
    end
  end

  /////////////////////////  BRAM SAVE/LOAD  /////////////////////////////

  // @note: Since bk_loading is taken into account in the reset signal, this
  // means that rtc setting will always come after the eeprom is already loaded.
  wire [12:0] bk_addr = {sd_lba[3:0], sd_buff_addr[8:0]};
  wire bk_wr = sd_buff_wr & sd_ack;
  wire [7:0] bk_data = sd_buff_dout;
  wire [7:0] bk_q;

  assign sd_buff_din = bk_q;
  wire downloading = cart_download;

  reg                                                        bk_ena = 0;
  reg                                                        new_load = 0;
  reg                                                        old_downloading = 0;
  reg                                                        sav_pending = 0;
  reg                                                        cart_ready = 0;

  wire downloading_negedge = old_downloading & ~downloading;
  wire downloading_posedge = ~old_downloading & downloading;
  always @(posedge clk_sys_32) begin
    old_downloading <= downloading;
    if (downloading_posedge) bk_ena <= 0;

    //Save file always mounted in the end of downloading state.
    if (downloading && img_mounted && !img_readonly) bk_ena <= 1;

    // Load eeprom after loading a rom.
    if (downloading_negedge & bk_ena) begin
      new_load   <= 1'b1;
      cart_ready <= 1'b1;
    end else if (bk_state) new_load <= 1'b0;

    // This enables a save whenever a write was done to the eeprom.
    if (eeprom_internal_we & bk_ena) sav_pending <= 1'b1;
    else if (bk_state) sav_pending <= 1'b0;
  end

  wire bk_load    = status[9] | new_load;
  wire bk_save    = status[10] | (sav_pending & status[11]);
  reg  bk_loading = 0;
  reg  bk_state   = 0;


  reg old_load = 0, old_save = 0, old_ack;
  wire load_posedge = ~old_load & bk_load;
  wire save_posedge = ~old_save & bk_save;
  wire ack_posedge = ~old_ack & sd_ack;
  wire ack_negedge = old_ack & ~sd_ack;
  // always @(posedge clk_sys_32) begin
  //   old_load <= bk_load;
  //   old_save <= bk_save;
  //   old_ack  <= sd_ack;

  //   if (ack_posedge) {sd_rd, sd_wr} <= 0;

  //   if (!bk_state) begin
  //     if (bk_ena & (load_posedge | save_posedge)) begin
  //       bk_state   <= 1;
  //       bk_loading <= bk_load;
  //       sd_lba     <= 32'd0;
  //       sd_rd      <= bk_load;
  //       sd_wr      <= ~bk_load;
  //     end
  //     if (bk_ena & downloading_negedge & |img_size) begin
  //       bk_state   <= 1;
  //       bk_loading <= 1;
  //       sd_lba     <= 0;
  //       sd_rd      <= 1;
  //       sd_wr      <= 0;
  //     end
  //   end else if (ack_negedge) begin
  //     if (&sd_lba[3:0]) begin
  //       bk_loading <= 0;
  //       bk_state   <= 0;
  //     end else begin
  //       sd_lba <= sd_lba + 1'd1;
  //       sd_rd  <= bk_loading;
  //       sd_wr  <= ~bk_loading;
  //     end
  //   end
  // end

  //////////////////////////////////////////////////////////////////

  wire [7:0] filetype = 1;

  // @check: Correct filetype?
  wire cart_download = ioctl_download && filetype == 8'h01;
  wire bios_download = ioctl_download && filetype == 8'h00;
  wire [7:0] cartridge_data;
  sdram cartridge_rom (
      // Actual SDRAM interface
      .SDRAM_DQ(dram_dq),
      .SDRAM_A(dram_a),
      .SDRAM_DQML(dram_dqm[0]),
      .SDRAM_DQMH(dram_dqm[1]),
      .SDRAM_BA(dram_ba),
      //   .SDRAM_nCS(),
      .SDRAM_nWE(dram_we_n),
      .SDRAM_nRAS(dram_ras_n),
      .SDRAM_nCAS(dram_cas_n),
      .SDRAM_CLK(dram_clk),
      .SDRAM_CKE(dram_cke),

      .init(~pll_core_locked),
      .clk (clk_mem_40),

      .ch0_addr(cart_download ? ioctl_addr : {4'd0, minx_address_out[20:0]}),
      .ch0_rd  (~cart_download & clk_sys_32),
      .ch0_wr  (cart_download & ioctl_wr),
      .ch0_din (ioctl_dout),
      .ch0_dout(cartridge_data)
      // .ch0_busy(cart_busy)
  );

  assign minx_data_in =
     (minx_address_out < 24'h1000)? bios_data_out:
    ((minx_address_out < 24'h2000)? ram_data_out:
                                    cartridge_data);


endmodule
