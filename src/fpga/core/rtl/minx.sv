module minx
(
    input clk,
    input clk_ce_4mhz,
    input clk_rt,
    input clk_rt_ce,
    input reset,
    input [7:0] data_in,
    input [8:0] keys_active,
    input [3:0] F,
    output pk,
    output pl,
    output [1:0] i01,
    output [7:0] data_out,
    output [23:0] address_out,
    output [1:0]  bus_status,
    output read,
    output read_interrupt_vector,
    output write,
    output sync,
    output iack,

    output [5:0] lcd_contrast,
    input [7:0] lcd_read_x,
    input [3:0] lcd_read_y,
    output logic [7:0] lcd_read_column,

    output frame_complete,

    output bus_request,
    output bus_ack,

    output sound_pulse,
    output [1:0] sound_volume,
    output rumble,

    input validate_rtc,

    output eeprom_internal_we,
    input eeprom_we,
    input [12:0] eeprom_address,
    input [7:0] eeprom_write_data,
    output [7:0] eeprom_read_data
);

    // @todo: Design question: Move this logic to inside the eeprom module?
    // The idea of putting this logic here is that eeprom is part of the gpio
    // and gpio, as a module is not implemented (yet).
    reg [7:0] reg_io_dir;
    reg [7:0] reg_io_data;
    reg cpu_write_latch;
    wire eeprom_data_out;
    wire [7:0] eeprom_data = {4'h0, reg_io_data[3], (reg_io_dir[2]? reg_io_data[2]: eeprom_data_out), 2'd0};
    always_ff @ (negedge clk)
    begin
        if(clk_ce && cpu_write_latch)
        begin
            if(cpu_address_out == 24'h2060)
                reg_io_dir <= cpu_data_out;

            if(cpu_address_out == 24'h2061)
                reg_io_data <= cpu_data_out;
        end
    end
    assign rumble = reg_io_dir[4] ? reg_io_data[4]: 0;

    wire clk_ce = cpu_clk_prescale & clk_ce_4mhz;
    reg cpu_clk_prescale = 0;
    always_ff @ (posedge clk)
    begin
        if(clk_ce_4mhz)
            cpu_clk_prescale <= cpu_clk_prescale + 1;

        if(clk_ce)
        begin
            cpu_write_latch <= 0;
            if(cpu_write) cpu_write_latch <= 1;
        end
    end

    reg [7:0] io_data_out;
    always_comb
    begin
        case(cpu_address_out)
            24'h2060:
                io_data_out = reg_io_dir;
            24'h2061:
                io_data_out = eeprom_data;
            default:
                io_data_out = 8'd0;
        endcase
    end

    wire [31:0]  irqs;
    assign irqs[5'h03] = irq_copy_complete;
    assign irqs[5'h04] = irq_render_done;
    assign irqs[5'h05] = t2_irqs[1];
    assign irqs[5'h06] = t2_irqs[0];
    assign irqs[5'h07] = t1_irqs[1];
    assign irqs[5'h08] = t1_irqs[0];
    assign irqs[5'h09] = t3_irqs[1];
    assign irqs[5'h0A] = t3_irqs[2];
    assign irqs[5'h0B] = t256_irqs[0];
    assign irqs[5'h0C] = t256_irqs[1];
    assign irqs[5'h0D] = t256_irqs[2];
    assign irqs[5'h0E] = t256_irqs[3];
    assign irqs[5'h10] = key_irqs[8];
    assign irqs[5'h15] = key_irqs[7];
    assign irqs[5'h16] = key_irqs[6];
    assign irqs[5'h17] = key_irqs[5];
    assign irqs[5'h18] = key_irqs[4];
    assign irqs[5'h19] = key_irqs[3];
    assign irqs[5'h1A] = key_irqs[2];
    assign irqs[5'h1B] = key_irqs[1];
    assign irqs[5'h1C] = key_irqs[0];

    wire [23:0] irq_address_out;
    wire [7:0]  irq_data_out;
    wire [3:0]  cpu_irq;
    irq irq
    (
        .clk             (clk),
        .clk_ce          (clk_ce),
        .reset           (reset),
        .bus_write       (write),
        .bus_read        (read),
        .irqs            (irqs),
        .cpu_iack        (iack),
        .bus_address_in  (cpu_address_out),
        .bus_data_in     (cpu_data_out),
        .bus_address_out (irq_address_out),
        .bus_data_out    (irq_data_out),
        .cpu_irq         (cpu_irq)
    );

    wire [7:0] key_data_out;
    wire [8:0] key_irqs;
    key_input key_input
    (
        .clk            (clk),
        .clk_ce         (clk_ce),
        .reset          (reset),
        .keys_active    (keys_active),
        .bus_address_in (cpu_address_out),
        .bus_data_out   (key_data_out),
        .key_irqs       (key_irqs)
    );

    wire [7:0] sc_data_out;
    system_control system_control
    (
        .clk            (clk),
        .clk_ce         (clk_ce),
        .reset          (reset),
        .bus_write      (write),
        .bus_address_in (cpu_address_out),
        .bus_data_in    (cpu_data_out),
        .bus_data_out   (sc_data_out),
        .validate_rtc   (validate_rtc)
    );

    wire [7:0] sound_data_out;

    sound sound
    (
        .clk            (clk),
        .clk_ce         (clk_ce),
        .reset          (reset),
        .bus_write      (write),
        .bus_address_in (cpu_address_out),
        .bus_data_in    (cpu_data_out),
        .bus_data_out   (sound_data_out),
        .sound_volume   (sound_volume)
    );

    wire [2:0] t1_irqs;
    wire [7:0] timer1_data_out;
    wire osc256;
    timer
    #(
        .TMR_SCALE (24'h2018),
        .TMR_OSC   (24'h2019),
        .TMR_CTRL  (24'h2030),
        .TMR_PRE   (24'h2032),
        .TMR_PVT   (24'h2034),
        .TMR_CNT   (24'h2036)
    ) timer1
    (
        .clk            (clk),
        .clk_ce         (clk_ce_4mhz),
        .clk_ce_cpu     (clk_ce),
        .clk_rt         (clk_rt),
        .clk_rt_ce      (clk_rt_ce),
        .reset          (reset),
        .bus_write      (write),
        .bus_read       (read),
        .bus_address_in (cpu_address_out),
        .bus_data_in    (cpu_data_out),
        .bus_data_out   (timer1_data_out),
        .irqs           (t1_irqs),
        .tout           (),
        .osc256         (osc256)
    );

    wire [2:0] t2_irqs;
    wire [7:0] timer2_data_out;
    timer
    #(
        .TMR_SCALE (24'h201A),
        .TMR_OSC   (24'h201B),
        .TMR_CTRL  (24'h2038),
        .TMR_PRE   (24'h203A),
        .TMR_PVT   (24'h203C),
        .TMR_CNT   (24'h203E)
    ) timer2
    (
        .clk            (clk),
        .clk_ce         (clk_ce_4mhz),
        .clk_ce_cpu     (clk_ce),
        .clk_rt         (clk_rt),
        .clk_rt_ce      (clk_rt_ce),
        .reset          (reset),
        .bus_write      (write),
        .bus_read       (read),
        .bus_address_in (cpu_address_out),
        .bus_data_in    (cpu_data_out),
        .bus_data_out   (timer2_data_out),
        .irqs           (t2_irqs),
        .tout           (),
        .osc256         ()
    );

    wire [2:0] t3_irqs;
    wire [7:0] timer3_data_out;
    timer
    #(
        .TMR_SCALE (24'h201C),
        .TMR_OSC   (24'h201D),
        .TMR_CTRL  (24'h2048),
        .TMR_PRE   (24'h204A),
        .TMR_PVT   (24'h204C),
        .TMR_CNT   (24'h204E)
    ) timer3
    (
        .clk            (clk),
        .clk_ce         (clk_ce_4mhz),
        .clk_ce_cpu     (clk_ce),
        .clk_rt         (clk_rt),
        .clk_rt_ce      (clk_rt_ce),
        .reset          (reset),
        .bus_write      (write),
        .bus_read       (read),
        .bus_address_in (cpu_address_out),
        .bus_data_in    (cpu_data_out),
        .bus_data_out   (timer3_data_out),
        .irqs           (t3_irqs),
        .tout           (sound_pulse),
        .osc256         ()
    );

    wire [7:0] rtc_data_out;
    rtc rtc
    (
        .clk            (clk),
        .clk_ce         (clk_ce),
        .clk_rt         (clk_rt),
        .clk_rt_ce      (clk_rt_ce),
        .reset          (reset),
        .bus_write      (write),
        .bus_address_in (cpu_address_out),
        .bus_data_in    (cpu_data_out),
        .bus_data_out   (rtc_data_out)
    );

    wire [3:0] t256_irqs;
    wire [7:0] timer256_data_out;
    timer256 timer256
    (
        .clk            (clk),
        .clk_ce         (clk_ce),
        .clk_rt         (clk_rt),
        .clk_rt_ce      (clk_rt_ce),
        .reset          (reset),
        .bus_write      (write),
        .bus_read       (read),
        .bus_address_in (cpu_address_out),
        .bus_data_in    (cpu_data_out),
        .bus_data_out   (timer256_data_out),
        .irqs           (t256_irqs),
        .osc256         (osc256)
    );

    eeprom eeprom
    (
        .clk      (clk),
        .clk_ce   (clk_ce),
        .reset    (reset),
        .ce       (reg_io_data[3] | ~reg_io_dir[3]),
        .data_in  (reg_io_data[2] | ~reg_io_dir[2]),
        .data_out (eeprom_data_out),
        .we       (eeprom_internal_we),

        .rom_we(eeprom_we),
        .rom_address_in(eeprom_address),
        .rom_data_in(eeprom_write_data),
        .rom_data_out(eeprom_read_data)
    );

    assign data_out    = bus_ack? prc_data_out    : cpu_data_out;
    assign address_out = bus_ack? prc_address_out : cpu_address_out;
    assign write       = bus_ack? prc_write       : cpu_write;
    assign read        = bus_ack? prc_read        : cpu_read;
    assign bus_status  = bus_ack? prc_bus_status  : cpu_bus_status;

    wire [7:0] lcd_data_out;
    wire [6:0] read_x = 0;
    wire [4:0] read_y = 0;
    wire [7:0] read_column;
    lcd_controller lcd
    (
        .clk          (clk),
        .clk_ce       (clk_ce),
        .reset        (reset),
        .bus_write    (write),
        .bus_read     (read),
        .address_in   (address_out),
        .data_in      (data_out),
        .data_out     (lcd_data_out),
        .lcd_contrast (lcd_contrast),
        .read_x       (lcd_read_x),
        .read_y       (lcd_read_y),
        .read_column  (lcd_read_column)
    );

    wire [7:0] prc_data_out;
    wire [23:0] prc_address_out;
    wire [7:0] prc_data_in = bus_ack? data_in: cpu_data_out;
    wire prc_write;
    wire prc_read;
    wire irq_copy_complete;
    wire irq_render_done;
    wire [1:0] prc_bus_status;
    prc prc
    (
        .clk               (clk),
        .clk_ce            (clk_ce_4mhz),
        .clk_ce_cpu        (clk_ce),
        .reset             (reset),
        .bus_write         (write),
        .bus_read          (read),
        .bus_address_in    (address_out),
        .bus_data_in       (prc_data_in),
        .bus_data_out      (prc_data_out),
        .bus_address_out   (prc_address_out),
        .bus_status        (prc_bus_status),
        .write             (prc_write),
        .read              (prc_read),
        .bus_request       (bus_request),
        .bus_ack           (bus_ack),
        .irq_copy_complete (irq_copy_complete),
        .irq_render_done   (irq_render_done),
        .frame_complete    (frame_complete)
    );

    wire [7:0] sys_batt = (address_out == 24'h2010)? 8'h18: 8'h0;
    wire [7:0] reg_data_out = 0
        | lcd_data_out
        | prc_data_out
        | key_data_out
        | io_data_out
        | sc_data_out
        | sound_data_out
        | rtc_data_out
        | timer256_data_out
        | timer1_data_out
        | timer2_data_out
        | timer3_data_out
        | irq_data_out
        | sys_batt;

    wire [7:0] cpu_data_in =
    (
        (address_out >= 24'h2000) &&
        (address_out <  24'h2100) &&
        (bus_status == BUS_COMMAND_MEM_READ)
    )? reg_data_out: data_in;

    wire [7:0] cpu_data_out;
    wire [23:0] cpu_address_out;
    wire cpu_write;
    wire cpu_read;
    wire [1:0] cpu_bus_status;
    s1c88 cpu
    (
        .clk                   (clk),
        .clk_ce                (clk_ce),
        .reset                 (reset),
        .data_in               ((cpu_bus_status == BUS_COMMAND_IRQ_READ)? irq_data_out: cpu_data_in),
        .irq                   (cpu_irq),
        .F                     (F),
        .pk                    (pk),
        .pl                    (pl),
        .i01                   (i01),
        .data_out              (cpu_data_out),
        .address_out           (cpu_address_out),
        .bus_status            (cpu_bus_status),
        .read                  (cpu_read),
        .read_interrupt_vector (read_interrupt_vector),
        .write                 (cpu_write),
        .sync                  (sync),
        .iack                  (iack),
        .bus_request           (bus_request),
        .bus_ack               (bus_ack)
    );

endmodule
