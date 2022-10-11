
enum bit [1:0]
{
    BUS_COMMAND_IDLE      = 2'd0,
    BUS_COMMAND_IRQ_READ  = 2'd1,
    BUS_COMMAND_MEM_WRITE = 2'd2,
    BUS_COMMAND_MEM_READ  = 2'd3
}BusCommand;

module s1c88
(
    input clk,
    input clk_ce,
    input reset,
    input [7:0] data_in,
    input [3:0] irq,
    input [3:0] F,
    output logic pk,
    output logic pl,
    output wire [1:0] i01,

    output logic [7:0] data_out,
    output logic [23:0] address_out,
    output logic [1:0]  bus_status,
    output logic read,
    output logic read_interrupt_vector,
    output wire write,
    output wire sync,
    output logic iack,
    input bus_request,
    output bus_ack
);

    //In the S1C88, the fetching of the first operation code of the
    //instruction is done overlapping the last cycle of the immediately prior
    //instruction.  Consequently, the execution cycle for 1 instruction of the
    //S1C88 begins either from the fetch cycle for the second op-code, the
    //read cycle for the first operand or the first execution cycle (varies
    //depend- ing on the instruction) and terminates with the fetch cycle for
    //the first op-code of the following instruction. 1 cycle instruction only
    //becomes the fetch cycle of the first op-code of the following
    //instruction. In addition, there are also instances where it shifts to
    //the fetch cycle of the first op-code rather than interposing an execute
    //cycle after an operand read cycle.

    // After having been stored in the 16-bit temporary register TEMP 2, the
    // operation result is either stored in the register/memory or used as
    // address data according to the operation instruction.

    // It seems like SC is set only by the ALU on the manual. This means that
    // if you want to set SC you have to go through the ALU. Perhaps there is
    // a specific ALU operation for this. Indeed, SC is modified through
    // these instructions:
    //
    // AND SC,#nn (Resets the optional flag) OR SC,#nn (Sets the optional flag)
    // XOR SC,#nn (Inverts the optional flag) LD SC,#nn (Flag write) LD SC,A
    // (Flag write) POP SC (Flag return) RETE (Flag evacuation)
    //
    // note that the LD ops take 1 cycle longer than normal, I guess because
    // in microcode it's calling one of the ALU operations above.  The ALU
    // operations are 2 bytes and take 3 cycles, which means 2 microcode
    // cycles. I would guess that 1 cycle is for setting up the operands (SC,
    // nn), and the second one is for writing to SC. Perhaps in microcode you
    // could have a flag to write straight to SC.
    //
    // In our implementation we don't need to impose this limitation and we
    // can instead write straight to SC.

    // The most significant bit of the PC indicates the common area at '0' and
    // the bank area at '1', and this content determines whether or not it
    // will output CB to the address bus. In the case of the common area, 00H
    // is output to A15–A22 of the address bus and in the case of the bank
    // area, the content 8 bits of the CB are output. A23 of the address bus
    // is for the exclusive use of data memory area and it always outputs '0'
    // at the time of maximum 8M byte program memory access.

    // @note: The original implementation would probably have implemented
    // reading of the immediates in microcode, allowing it to put the
    // immediates into the ALU registers at that stage already. It would
    // probably also allow to calculate addresses for data operations.

    // Microinstruction Design Notes:
    //
    // Currently we allow all microinstructions to set the alu operation.
    // Perhaps it would be better to have microinstructions for the reading of
    // the immediate values too, then you can write the immediate straight
    // where you need it in the next microinstructions.  Alternatively, we
    // could have convert bus micros into simple move micros with
    // MICRO_MOV_MEM, but where would we put the addressing mode? In 8086, the
    // address is explicitly set by the microinstructions. Perhaps this could
    // also be a possibility here, but we would need to run the
    // microinstructions on both positive and negative edges, with the
    // negative edge logic indexing into the rom with a 0 offset, while the
    // positive edge logic indexing with an offset of +1.

    //
    // I guess we will see at a later point if we need to change where PC is
    // being set again. Note, though that we still have to set PC in the
    // last micro, and since we want to overlap instructions, the window
    // that is left for PC to change on time for an opcode fetch is narrow,
    // leaving (I think) only the possibility of updating PC at PL == 1.
    //
    //
    // "Interrupts are disabled while the instruction to modify the contents of
    // NB or SC is being executed. The exception processing of the interrupt
    // generated during that period is started after the following instruction
    // has been executed."

    // @todo:
    //
    // * Implement EXCEPTION_TYPE_DIVZERO.
    // * Bus wait states (not really required for mister).

    // For jump instruction we need: condition, offset (TA1/TA2). I think
    // we'll leave the mov instructions in there as common to all
    // instructions.
    // We can infer rr/qqrr from imm_size (not sure if we need to latch it).
    // 2-byte instructions use TA1, 3-byte instructions use TA2. So either we
    // set it in the micro since we have space, or infer by looking if
    // imm_size == 1 or extended_opcode[9:8] != 0. That would mean we don't
    // even need the offset, only the condition. We do save logic, though, by
    // putting that in the micro.
    //
    // Conditions:
    //     __cc2__
    //     * N^V=1      ; Less
    //     * N^V=0      ; Greater
    //     * Z|[N^V]=1  ; Less or equal
    //     * Z|[N^V]=0  ; Greater or equal
    //     * V=1        ; Overflow
    //     * V=0        ; No Overflow
    //     * N=1        ; Minus
    //     * N=0        ; Plus
    //     * F0=1       ; F0 is set
    //     * F0=0       ; F0 is reset
    //     * F1=1       ; F1 is set
    //     * F1=0       ; F1 is reset
    //     * F2=1       ; F2 is set
    //     * F2=0       ; F2 is reset
    //     * F3=1       ; F3 is set
    //     * F3=0       ; F3 is reset
    //
    //     __cc1__
    //     * C=1        ; Carry
    //     * C=0        ; Non Carry
    //     * Z=1        ; Zero
    //     * Z=0        ; Non Zero
    //
    //     __other__
    //     * B=0
    //
    // Total 21 conditions, 5 bits are enough.
    //
    // @note: Perhaps MICRO_MOV_TA1/2 are not required after implementing the
    // jump micro.
    //
    //
    // Different possibilities for correctly implementing conditional calls:
    //
    // 1. The jump instruction has quite a few unused bits. We can introduce
    //    a new jump type for branching within the microprogram. Alternatively,
    //    we have space to introduce a new local jump microinstruction. This
    //    would look something like the following:
    //
    //    TYPE_LJMP 2'd0 ALU_OP_NONE 7'd1 JMP_SHORT COND_ZERO NOT_DONE MOV_IMML MOV_DATA
    //    TYPE_JMP  2'd0 ALU_OP_NONE 7'd0 JMP_SHORT COND_FALSE DONE MOV_IMML MOV_DATA
    //    TYPE_BUS  2'd0 ALU_OP_NONE BUS_MEM_WRITE ADD_SP MOV_CB NOT_DONE MOV_NONE MOV_NONE
    //    TYPE_BUS  2'd0 ALU_OP_NONE BUS_MEM_WRITE ADD_SP MOV_PCH NOT_DONE MOV_NONE MOV_NONE
    //    TYPE_BUS  2'd0 ALU_OP_NONE BUS_MEM_WRITE ADD_SP MOV_PCL NEARLY_DONE MOV_NONE MOV_NONE
    //    TYPE_JMP  2'd0 ALU_OP_NONE 6'd0 JMP_SHORT COND_NONE DONE MOV_NONE MOV_NONE
    //
    //    Here we kinda abuse the normal jump by making it take either one of the
    //    branches explicitly using COND_TRUE/FALSE. If we don't do that, shorter
    //    instructions like conditional jumps would need to be 3
    //    microinstructions instead of 2. Btw, we can completely avoid
    //    introducing a TYPE_LJMP; when a jump instruction is NOT_DONE, skip
    //    the next micro when the condition is true.
    //
    //    TYPE_JMP  2'd0 ALU_OP_NONE 7'd0 JMP_SHORT COND_ZERO NOT_DONE MOV_IMML MOV_DATA
    //    TYPE_JMP  2'd0 ALU_OP_NONE 7'd0 JMP_SHORT COND_ZERO DONE MOV_IMML MOV_DATA
    //    TYPE_BUS  2'd0 ALU_OP_NONE BUS_MEM_WRITE ADD_SP MOV_CB NOT_DONE MOV_NONE MOV_NONE
    //    TYPE_BUS  2'd0 ALU_OP_NONE BUS_MEM_WRITE ADD_SP MOV_PCH NOT_DONE MOV_NONE MOV_NONE
    //    TYPE_BUS  2'd0 ALU_OP_NONE BUS_MEM_WRITE ADD_SP MOV_PCL NEARLY_DONE MOV_NONE MOV_NONE
    //    TYPE_JMP  2'd0 ALU_OP_NONE 7'd0 JMP_SHORT COND_ZERO DONE MOV_NONE MOV_NONE
    //
    // 2. Do the jump like following:
    //
    //    TYPE_MISC 2'd0 ALU_OP_NONE 6'd0 MOV_NONE MOV_NONE DONE MOV_IMML MOV_DATA
    //    TYPE_JMP 2'd0 ALU_OP_NONE 7'd0 JMP_SHORT COND_ZERO NOT_DONE MOV_NONE MOV_NONE
    //    TYPE_BUS 2'd0 ALU_OP_NONE BUS_MEM_WRITE ADD_SP MOV_CB NOT_DONE MOV_NONE MOV_NONE
    //    TYPE_BUS 2'd0 ALU_OP_NONE BUS_MEM_WRITE ADD_SP MOV_PCH NEARLY_DONE MOV_NONE MOV_NONE
    //    TYPE_BUS 2'd0 ALU_OP_NONE BUS_MEM_WRITE ADD_SP MOV_PCL DONE MOV_NONE MOV_NONE
    //
    //    during the jump, if the micro is done it does the jump like
    //    currently, but if it's not done, it terminates the micro if the
    //    condition is not true, otherwise it continues running micros and
    //    sets a flag branch_taken. Problem is that PC needs to modified at
    //    the end, but the last micro writes the PC to memory. Alternatively,
    //    we setup the micros like this:
    //
    //    TYPE_JMP 2'd0 ALU_OP_NONE 7'd0 JMP_SHORT COND_ZERO NOT_DONE MOV_IMML MOV_DATA
    //    TYPE_MISC 2'd0 ALU_OP_NONE 6'd0 MOV_NONE MOV_NONE DONE MOV_NONE MOV_NONE
    //    TYPE_BUS 2'd0 ALU_OP_NONE BUS_MEM_WRITE ADD_SP MOV_CB NOT_DONE MOV_NONE MOV_NONE
    //    TYPE_BUS 2'd0 ALU_OP_NONE BUS_MEM_WRITE ADD_SP MOV_PCH NEARLY_DONE MOV_NONE MOV_NONE
    //    TYPE_BUS 2'd0 ALU_OP_NONE BUS_MEM_WRITE ADD_SP MOV_PCL DONE MOV_NONE MOV_NONE
    //    TYPE_MISC 2'd0 ALU_OP_NONE 6'd0 MOV_NONE MOV_NONE DONE MOV_NONE MOV_NONE
    //
    //    in which case, if the jump micro is NOT_DONE, and if the condition
    //    is true, it skips the following micro and sets branch_taken, or we
    //    make the second and last micros do the cleanup? All jumps could be
    //    written like this, but that would increase the micros form 2 to 3.
    //    This is very similar to the first suggestion!


    reg bus_ack_negedge, bus_ack_posedge, bus_request_latch;
    assign bus_ack = bus_ack_negedge & bus_ack_posedge;
    assign i01 = SC[7:6];


    localparam [2:0]
        STATE_IDLE         = 3'd0,
        STATE_OPEXT_READ   = 3'd1,
        STATE_EXECUTE      = 3'd2,
        STATE_EXC_PROCESS  = 3'd3,
        STATE_HALT         = 3'd4;

    localparam [2:0]
        EXCEPTION_TYPE_NONE    = 3'd0,
        EXCEPTION_TYPE_IRQ1    = 3'd1,
        EXCEPTION_TYPE_IRQ2    = 3'd2,
        EXCEPTION_TYPE_IRQ3    = 3'd3,
        EXCEPTION_TYPE_NMI     = 3'd4,
        EXCEPTION_TYPE_DIVZERO = 3'd5,
        EXCEPTION_TYPE_RESET   = 3'd6;

    localparam [1:0]
        MICRO_TYPE_MISC = 2'd0,
        MICRO_TYPE_BUS  = 2'd1,
        MICRO_TYPE_JMP  = 2'd2;

    localparam [2:0]
        MICRO_NOT_DONE    = 3'b00,
        MICRO_DONE        = 3'b01,
        MICRO_NEARLY_DONE = 3'b10;

    localparam
        MICRO_BUS_MEM_READ  = 1'd0,
        MICRO_BUS_MEM_WRITE = 1'd1;

    localparam [5:0]
        MICRO_MOV_NONE     = 6'h00,
        MICRO_MOV_A        = 6'h01,
        MICRO_MOV_B        = 6'h02,
        MICRO_MOV_BA       = 6'h03,
        MICRO_MOV_H        = 6'h04,
        MICRO_MOV_L        = 6'h05,
        MICRO_MOV_HL       = 6'h06,
        MICRO_MOV_IX       = 6'h07,
        MICRO_MOV_IXH      = 6'h08,
        MICRO_MOV_IXL      = 6'h09,
        MICRO_MOV_IY       = 6'h0A,
        MICRO_MOV_IYH      = 6'h0B,
        MICRO_MOV_IYL      = 6'h0C,
        MICRO_MOV_SP       = 6'h0D,
        MICRO_MOV_SPH      = 6'h0E,
        MICRO_MOV_SPL      = 6'h0F,
        MICRO_MOV_BR       = 6'h10,
        MICRO_MOV_PC       = 6'h11,
        MICRO_MOV_PCL      = 6'h12,
        MICRO_MOV_PCH      = 6'h13,
        MICRO_MOV_DATA     = 6'h14,
        MICRO_MOV_NB       = 6'h15,
        MICRO_MOV_CB       = 6'h16,
        MICRO_MOV_SC       = 6'h17,
        MICRO_MOV_EP       = 6'h18,
        MICRO_MOV_XP       = 6'h19,
        MICRO_MOV_YP       = 6'h1A,
        MICRO_MOV_ALU_R    = 6'h1B,
        MICRO_MOV_ALU_A    = 6'h1C,
        MICRO_MOV_ALU_AH   = 6'h1D,
        MICRO_MOV_ALU_AL   = 6'h1E,
        MICRO_MOV_ALU_B    = 6'h1F,
        MICRO_MOV_ALU_BH   = 6'h20,
        MICRO_MOV_ALU_BL   = 6'h21,
        MICRO_MOV_IMM      = 6'h22,
        MICRO_MOV_IMML     = 6'h23,
        MICRO_MOV_IMMH     = 6'h24,
        MICRO_MOV_ZERO     = 6'h25,
        MICRO_MOV_FFFF     = 6'h26;

    // @note: Can probably reduce some resource usage by making all *1 address
    // micros be at an odd address.
    // @todo_maybe: Investigate if we can perhaps use the alu to calculate the
    // XX+dd, XX+L addresses. It seems weird to me that the microinstructions
    // using these all have the same number of clock cycles. I think they need
    // to be using the ALU to calculate the addresses. Current implementation is
    // simpler, though, if we don't care too much about resources used by the
    // FPGA.
    localparam [5:0]
        MICRO_ADD_HL     = 6'h00,
        MICRO_ADD_HL1    = 6'h01,
        MICRO_ADD_IX     = 6'h02,
        MICRO_ADD_IX1    = 6'h03,
        MICRO_ADD_IX_DD  = 6'h04,
        MICRO_ADD_IX_L   = 6'h05,
        MICRO_ADD_IY     = 6'h06,
        MICRO_ADD_IY1    = 6'h07,
        MICRO_ADD_IY_DD  = 6'h08,
        MICRO_ADD_IY_L   = 6'h09,
        MICRO_ADD_BR     = 6'h0A,
        MICRO_ADD_BR1    = 6'h0B,
        MICRO_ADD_HH_LL  = 6'h0C,
        MICRO_ADD_HH_LL1 = 6'h0D,
        MICRO_ADD_KK     = 6'h0E,
        MICRO_ADD_KK1    = 6'h0F,
        MICRO_ADD_SP     = 6'h10,
        MICRO_ADD_SP_DD  = 6'h11,
        MICRO_ADD_SP_DD1 = 6'h12;

    localparam [4:0]
        MICRO_ALU_OP_NONE  = 5'h00,
        MICRO_ALU_OP_XOR   = 5'h01,
        MICRO_ALU_OP_AND   = 5'h02,
        MICRO_ALU_OP_OR    = 5'h03,
        MICRO_ALU_OP_ADD   = 5'h04,
        MICRO_ALU_OP_ADC   = 5'h05,
        MICRO_ALU_OP_SUB   = 5'h06,
        MICRO_ALU_OP_SBC   = 5'h07,
        MICRO_ALU_OP_CMP   = 5'h08,
        MICRO_ALU_OP_INC   = 5'h09,
        MICRO_ALU_OP_DEC   = 5'h0A,
        MICRO_ALU_OP_NEG   = 5'h0B,
        MICRO_ALU_OP_RL    = 5'h0C,
        MICRO_ALU_OP_RLC   = 5'h0D,
        MICRO_ALU_OP_RR    = 5'h0E,
        MICRO_ALU_OP_RRC   = 5'h0F,
        MICRO_ALU_OP_SLL   = 5'h10,
        MICRO_ALU_OP_SLA   = 5'h11,
        MICRO_ALU_OP_SRL   = 5'h12,
        MICRO_ALU_OP_SRA   = 5'h13,
        MICRO_ALU_OP_CPL   = 5'h14,
        MICRO_ALU_OP_DIV   = 5'h15,
        MICRO_ALU_OP_MUL   = 5'h16,
        MICRO_ALU_OP_PACK  = 5'h17,
        MICRO_ALU_OP_UPACK = 5'h18,
        MICRO_ALU_OP_SEP   = 5'h19,
        MICRO_ALU_OP_SWAP  = 5'h1A;

    localparam
        MICRO_ALU8  = 1'b0,
        MICRO_ALU16 = 1'b1;

    localparam
        MICRO_ALU_FLAG_NONE  = 1'b0,
        MICRO_ALU_FLAG_WRITE = 1'b1;

    localparam [4:0]
        MICRO_COND_NONE          = 5'h00,
        MICRO_COND_LESS          = 5'h01,
        MICRO_COND_GREATER       = 5'h02,
        MICRO_COND_LESS_EQUAL    = 5'h03,
        MICRO_COND_GREATER_EQUAL = 5'h04,
        MICRO_COND_OVERFLOW      = 5'h05,
        MICRO_COND_NON_OVERFLOW  = 5'h06,
        MICRO_COND_MINUS         = 5'h07,
        MICRO_COND_PLUS          = 5'h08,
        MICRO_COND_CARRY         = 5'h09,
        MICRO_COND_NON_CARRY     = 5'h0A,
        MICRO_COND_ZERO          = 5'h0B,
        MICRO_COND_NON_ZERO      = 5'h0C,
        MICRO_COND_F0_SET        = 5'h0D,
        MICRO_COND_F0_RST        = 5'h0E,
        MICRO_COND_F1_SET        = 5'h0F,
        MICRO_COND_F1_RST        = 5'h10,
        MICRO_COND_F2_SET        = 5'h11,
        MICRO_COND_F2_RST        = 5'h12,
        MICRO_COND_F3_SET        = 5'h13,
        MICRO_COND_F3_RST        = 5'h14;

    localparam
        MICRO_JMP_SHORT = 1'b0,
        MICRO_JMP_LONG  = 1'b1;

    // @todo: When we convert code from using both pos/neg edges to just using
    // posedge with separate positive and negative ce, we might be able to
    // revisit the romstyle to use synchronous bram, e.g. romstyle=no_rw_check.
    reg [10:0] translation_rom[0:767];
    reg [35:0] rom[0:2047];

    assign write = pl && pk &&
          (exception != EXCEPTION_TYPE_RESET) &&
        (((state == STATE_EXECUTE) &&
          (micro_op_type == MICRO_TYPE_BUS) &&
          (micro_bus_op == MICRO_BUS_MEM_WRITE)) ||

         ((exception != EXCEPTION_TYPE_NONE) &&
          (exception_process_step > 0 && exception_process_step < 5))
        );

    initial
    begin
        $readmemh("rom/translation_rom.mem", translation_rom);
        $readmemh("rom/rom.mem", rom);
    end

    reg [15:0] BA;
    reg [7:0] EP;
    reg [7:0] XP;
    reg [7:0] YP;
    reg [7:0] BR;
    reg [7:0] SC;
    reg [7:0] CB;
    reg [7:0] NB;
    reg [15:0] SP;
    reg [15:0] HL;
    reg [15:0] IX;
    reg [15:0] IY;
    wire [7:0] A = BA[7:0];
    wire [7:0] B = BA[15:8];
    wire [7:0] L = HL[7:0];
    wire [7:0] H = HL[15:8];

    wire flag_zero     = SC[0];
    wire flag_carry    = SC[1];
    wire flag_overflow = SC[2];
    wire flag_negative = SC[3];
    wire flag_decimal  = SC[4];
    wire flag_unpack   = SC[5];
    wire flag_i0       = SC[6];
    wire flag_i1       = SC[7];

    reg [4:0] alu_op;
    reg alu_flag_update;
    reg alu_size;
    reg [15:0] alu_A;
    reg [15:0] alu_B;
    wire [15:0] alu_R;
    wire [3:0] alu_flags;

    alu alu
    (
        alu_op,
        alu_size,
        alu_A, alu_B,
        flag_carry, flag_decimal,
        alu_R,
        alu_flags
    );

    // @todo: At some point we can reduce the microcode size. For example, we
    // can reduce the size of secondary mov operations, as well as the mov_add
    // and possibly mov_reg. Also we don't seem to use the nearly done flag so
    // we could potentially save another bit from that.
    //
    // TYPE_MISC
    //  2         1            1       5   1    6       6     2    6   6
    //  36        34          33      32   27  26      20     14  12   6
    // type alu_flag_write alu_size alu_op 0 mov_sec mov_sec done mov mov
    //
    // TYPE_BUS
    //  2         1            1       5    1     6       6     2    6   6
    //  36        34          33      32    27   26      20     14  12   6
    // type alu_flag_write alu_size alu_op r/w mov_add mov_reg done mov mov
    //
    // TYPE_JMP
    //  2         1            1       5   7     1         5    2    6   6
    //  36        34          33      32   27   20        19    14  12   6
    // type alu_flag_write alu_size alu_op 0 jmp_size jmp_cond done mov mov

    // @todo: Checked and at least the rom can alrady be made synchronous.
    wire [35:0] micro_op = rom[microaddress + {7'd0, microprogram_counter}];

    wire [1:0] micro_op_type = micro_op[35:34];

    wire [5:0] micro_mov_src = micro_op[5:0];
    wire [5:0] micro_mov_dst = micro_op[11:6];
    wire [5:0] micro_mov_src_sec = micro_op[19:14];
    wire [5:0] micro_mov_dst_sec = micro_op[25:20];

    wire microinstruction_done = micro_op[12];
    wire microinstruction_nearly_done = micro_op[13];

    wire [5:0] micro_bus_reg = micro_op[19:14];
    wire [5:0] micro_bus_add = micro_op[25:20];
    wire micro_bus_op = micro_op[26];

    wire [4:0] micro_alu_op = micro_op[31:27];
    wire micro_alu_size = micro_op[32];
    wire micro_alu_flag_update = micro_op[33];

    wire [4:0] micro_jmp_condition = micro_op[18:14];
    wire micro_jmp_long = micro_op[19];

    // @todo: We shouldn't need top_address. I think we can just add the
    // offset to PC.
    wire [15:0] jump_dest = top_address +
        (16'd1 << (micro_jmp_long | (extended_opcode[9:8] != 0))) +
        (micro_jmp_long? imm: {{8{imm[7]}}, imm[7:0]});

    reg [3:0] microprogram_counter;
    reg [10:0] microaddress;

    // @todo: Bundle all errors into one wide register.

    task map_microinstruction_register(input [5:0] reg_id, output logic [15:0] register, output logic not_implemented_error);
        not_implemented_error = 0;
        case(reg_id)
            MICRO_MOV_NONE:
                register = 0;

            MICRO_MOV_A:
                register = {8'd0, s1c88.A};

            MICRO_MOV_B:
                register = {8'd0, s1c88.B};

            MICRO_MOV_BA:
                register = s1c88.BA;

            MICRO_MOV_IX:
                register = s1c88.IX;

            MICRO_MOV_IXL:
                register = {8'd0, s1c88.IX[7:0]};

            MICRO_MOV_IXH:
                register = {8'd0, s1c88.IX[15:8]};

            MICRO_MOV_IY:
                register = s1c88.IY;

            MICRO_MOV_IYL:
                register = {8'd0, s1c88.IY[7:0]};

            MICRO_MOV_IYH:
                register = {8'd0, s1c88.IY[15:8]};

            MICRO_MOV_ALU_A:
                register = s1c88.alu_A;

            MICRO_MOV_ALU_AL:
                register = {8'd0, s1c88.alu_A[7:0]};

            MICRO_MOV_ALU_AH:
                register = {8'd0, s1c88.alu_A[15:8]};

            MICRO_MOV_ALU_B:
                register = s1c88.alu_B;

            MICRO_MOV_ALU_BL:
                register = {8'd0, s1c88.alu_B[7:0]};

            MICRO_MOV_ALU_BH:
                register = {8'd0, s1c88.alu_B[15:8]};

            MICRO_MOV_IMM:
                register = s1c88.imm;

            MICRO_MOV_IMML:
                register = {8'd0, s1c88.imm_low};

            MICRO_MOV_IMMH:
                register = {8'd0, s1c88.imm_high};

            MICRO_MOV_ALU_R:
                register = s1c88.alu_R;

            MICRO_MOV_H:
                register = {8'd0, s1c88.H};

            MICRO_MOV_L:
                register = {8'd0, s1c88.L};

            MICRO_MOV_HL:
                register = s1c88.HL;

            MICRO_MOV_SP:
                register = s1c88.SP;

            MICRO_MOV_SPL:
                register = {8'd0, s1c88.SP[7:0]};

            MICRO_MOV_SPH:
                register = {8'd0, s1c88.SP[15:8]};

            MICRO_MOV_SC:
                register = {8'd0, s1c88.SC};

            MICRO_MOV_BR:
                register = {8'd0, s1c88.BR};

            MICRO_MOV_PC:
                register = s1c88.PC;

            MICRO_MOV_DATA:
                register = {8'd0, s1c88.data_in};

            MICRO_MOV_NB:
                register = {8'd0, s1c88.NB};

            MICRO_MOV_CB:
                register = {8'd0, s1c88.CB};

            MICRO_MOV_EP:
                register = {8'd0, s1c88.EP};

            MICRO_MOV_XP:
                register = {8'd0, s1c88.XP};

            MICRO_MOV_YP:
                register = {8'd0, s1c88.YP};

            MICRO_MOV_ZERO:
                register = 16'd0;

            MICRO_MOV_FFFF:
                register = 16'hFFFF;

            default:
            begin
                not_implemented_error = 1;
                register = 0;
            end
        endcase
    endtask

    reg [15:0] src_reg;
    reg [15:0] src_reg_sec;
    reg not_implemented_mov_src_error;
    reg temp_not_implemented_mov_src_sec_error;
    wire not_implemented_mov_src_sec_error = (micro_op_type == MICRO_TYPE_MISC)? temp_not_implemented_mov_src_sec_error: 1'd0;
    always_comb
    begin
        map_microinstruction_register(micro_mov_src, src_reg, not_implemented_mov_src_error);
        map_microinstruction_register(micro_mov_src_sec, src_reg_sec, temp_not_implemented_mov_src_sec_error);
    end


    reg [2:0] state = STATE_IDLE;

    wire [2:0] next_state =
        (state == STATE_IDLE)?
            (exception != EXCEPTION_TYPE_NONE ? STATE_EXC_PROCESS:
                                                STATE_EXECUTE):

        (state == STATE_EXC_PROCESS) ?          STATE_EXECUTE:

        (state == STATE_EXECUTE) ?
            (iack ?                             STATE_EXC_PROCESS:
            (need_opext ?                       STATE_OPEXT_READ:
                                                STATE_EXECUTE)):
        (state == STATE_OPEXT_READ) ?
            (opext == 8'hAE ?                   STATE_HALT:
                                                STATE_EXECUTE):
                                                STATE_EXC_PROCESS;

    reg [15:0] PC = 16'hFACE;
    reg [15:0] top_address;

    reg [7:0] opcode;
    reg [7:0] opext;
    reg [7:0] imm_low;
    reg [7:0] imm_high;
    wire [15:0] imm = {imm_high, imm_low};

    reg [1:0] reset_counter;
    reg [2:0] exception = EXCEPTION_TYPE_NONE;

    reg [3:0] exception_process_step;
    reg [7:0] irq_vector_address;

    wire need_opext = (opcode == 8'hCE) | (opcode == 8'hCF);

    assign sync = fetch_opcode;
    reg fetch_opcode;
    wire opcode_error = (microaddress == 0 && state == STATE_EXECUTE);
    wire [7:0] opcode_extension = opcode - 8'hCD;
    wire [9:0] extended_opcode = need_opext?
        {opcode_extension[1:0], opext}:
        {2'd0, opcode};

    reg postpone_exception;
    always_comb
    begin
        case(extended_opcode)
            10'h9C, 10'h9D, 10'h9E, 10'h9F,
            10'hAF, 10'hF9, 10'h1CC, 10'h1C3, 10'h1C4:
                postpone_exception = 1;
            default:
                postpone_exception = 0;
        endcase
    end

    reg alu_op_error;
    reg not_implemented_divzero_error;
    always_ff @ (negedge clk)
    begin
        if(clk_ce)
        begin
            if(reset)
            begin
            end
            else if(pk == 0)
            begin
                alu_op_error <= 0;
                not_implemented_divzero_error <= 0;
                alu_size <= micro_alu_size;
                alu_flag_update <= micro_alu_flag_update;

                case(micro_alu_op)
                    MICRO_ALU_OP_AND:
                        alu_op <= ALUOP_AND;

                    MICRO_ALU_OP_OR:
                        alu_op <= ALUOP_OR;

                    MICRO_ALU_OP_XOR:
                        alu_op <= ALUOP_XOR;

                    MICRO_ALU_OP_ADD:
                        alu_op <= ALUOP_ADD;

                    MICRO_ALU_OP_ADC:
                        alu_op <= ALUOP_ADC;

                    MICRO_ALU_OP_SUB:
                        alu_op <= ALUOP_SUB;

                    MICRO_ALU_OP_SBC:
                        alu_op <= ALUOP_SBC;

                    MICRO_ALU_OP_INC:
                        alu_op <= ALUOP_INC;

                    MICRO_ALU_OP_DEC:
                        alu_op <= ALUOP_DEC;

                    MICRO_ALU_OP_NEG:
                        alu_op <= ALUOP_NEG;

                    MICRO_ALU_OP_DIV:
                    begin
                        alu_op <= ALUOP_DIV;
                        if(A == 0)
                            not_implemented_divzero_error <= 1;
                    end

                    MICRO_ALU_OP_MUL:
                        alu_op <= ALUOP_MUL;

                    MICRO_ALU_OP_RL:
                        alu_op <= ALUOP_RL;

                    MICRO_ALU_OP_RR:
                        alu_op <= ALUOP_RR;

                    MICRO_ALU_OP_RLC:
                        alu_op <= ALUOP_RLC;

                    MICRO_ALU_OP_RRC:
                        alu_op <= ALUOP_RRC;

                    MICRO_ALU_OP_SLL:
                        alu_op <= ALUOP_SLL;

                    MICRO_ALU_OP_SRL:
                        alu_op <= ALUOP_SRL;

                    MICRO_ALU_OP_SLA:
                        alu_op <= ALUOP_SLA;

                    MICRO_ALU_OP_SRA:
                        alu_op <= ALUOP_SRA;

                    MICRO_ALU_OP_PACK:
                        alu_op <= ALUOP_PACK;

                    MICRO_ALU_OP_UPACK:
                        alu_op <= ALUOP_UPACK;

                    MICRO_ALU_OP_SEP:
                        alu_op <= ALUOP_SEP;

                    MICRO_ALU_OP_SWAP:
                        alu_op <= ALUOP_SWAP;

                    default:
                    begin
                        alu_op <= ALUOP_ADD;
                        if(micro_alu_op != MICRO_ALU_OP_NONE)
                            alu_op_error <= 1;
                    end

                endcase
            end
        end
    end


    reg not_implemented_write_error;
    task write_data_to_register(input [5:0] reg_id, input [15:0] data);
        case(reg_id)
            MICRO_MOV_IX:
                IX <= data;

            MICRO_MOV_IXL:
                IX[7:0] <= data[7:0];

            MICRO_MOV_IXH:
                IX[15:8] <= data[7:0];

            MICRO_MOV_IY:
                IY <= data;

            MICRO_MOV_IYL:
                IY[7:0] <= data[7:0];

            MICRO_MOV_IYH:
                IY[15:8] <= data[7:0];

            MICRO_MOV_EP:
                EP <= data[7:0];

            MICRO_MOV_XP:
                XP <= data[7:0];

            MICRO_MOV_YP:
                YP <= data[7:0];

            MICRO_MOV_BR:
                BR <= data[7:0];

            MICRO_MOV_SC:
                SC <= data[7:0];

            MICRO_MOV_SP:
                SP <= data;

            MICRO_MOV_SPL:
                SP[7:0] <= data[7:0];

            MICRO_MOV_SPH:
                SP[15:8] <= data[7:0];

            MICRO_MOV_L:
                HL[7:0]  <= data[7:0];

            MICRO_MOV_H:
                HL[15:8] <= data[7:0];

            MICRO_MOV_IMM:
                {imm_low, imm_high} <= data;

            MICRO_MOV_IMML:
                imm_low <= data[7:0];

            MICRO_MOV_IMMH:
                imm_high <= data[7:0];

            MICRO_MOV_HL:
                HL <= data;

            MICRO_MOV_PCL:
                PC[7:0] <= data[7:0];

            MICRO_MOV_PCH:
                PC[15:8] <= data[7:0];

            MICRO_MOV_CB:
                CB <= data[7:0];

            MICRO_MOV_NB:
                NB <= data[7:0];

            MICRO_MOV_A:
                BA[7:0] <= data[7:0];

            MICRO_MOV_B:
                BA[15:8] <= data[7:0];

            MICRO_MOV_BA:
                BA <= data;

            MICRO_MOV_ALU_A:
                alu_A <= data;

            MICRO_MOV_ALU_B:
                alu_B <= data;

            MICRO_MOV_ALU_BL:
                alu_B[7:0] <= data[7:0];

            MICRO_MOV_ALU_BH:
                alu_B[15:8] <= data[7:0];

            default:
            begin
                if(reg_id != MICRO_MOV_NONE && reg_id != MICRO_MOV_PC)
                    not_implemented_write_error <= 1;
            end
        endcase
    endtask

    wire [2:0] exception_factor =
         (irq[3])?                    3'd4: // NMI
        ((irq[2] && SC[7:6] < 2'd3)?  3'd3:
        ((irq[1] && SC[7:6] < 2'd2)?  3'd2:
         (irq[0] && SC[7:6] == 2'd0)? 3'd1:
                                      3'd0));

    reg jump_condition_true;
    reg not_implemented_jump_error;
    always_comb
    begin
        jump_condition_true = 0;
        not_implemented_jump_error = 0;
        case(micro_jmp_condition)
            // Unconditional jump
            MICRO_COND_NONE:
            begin
                jump_condition_true = 1;
            end

            MICRO_COND_LESS, MICRO_COND_GREATER_EQUAL:
            begin
                if(flag_negative ^ flag_overflow == micro_jmp_condition[0])
                    jump_condition_true = 1;
            end
            MICRO_COND_GREATER, MICRO_COND_LESS_EQUAL:
            begin
                if((flag_zero | (flag_negative ^ flag_overflow)) == micro_jmp_condition[0])
                    jump_condition_true = 1;
            end
            MICRO_COND_OVERFLOW, MICRO_COND_NON_OVERFLOW:
            begin
                if(flag_overflow == micro_jmp_condition[0])
                    jump_condition_true = 1;
            end
            MICRO_COND_MINUS, MICRO_COND_PLUS:
            begin
                if(flag_negative == micro_jmp_condition[0])
                    jump_condition_true = 1;
            end
            MICRO_COND_CARRY, MICRO_COND_NON_CARRY:
            begin
                if(flag_carry == micro_jmp_condition[0])
                    jump_condition_true = 1;
            end
            MICRO_COND_ZERO, MICRO_COND_NON_ZERO:
            begin
                if(flag_zero == micro_jmp_condition[0])
                    jump_condition_true = 1;
            end
            MICRO_COND_F0_SET, MICRO_COND_F0_RST:
            begin
                if(F[0] == micro_jmp_condition[0])
                    jump_condition_true = 1;
            end
            MICRO_COND_F1_SET, MICRO_COND_F1_RST:
            begin
                if(F[1] == micro_jmp_condition[0])
                    jump_condition_true = 1;
            end
            MICRO_COND_F2_SET, MICRO_COND_F2_RST:
            begin
                if(F[2] == micro_jmp_condition[0])
                    jump_condition_true = 1;
            end
            MICRO_COND_F3_SET, MICRO_COND_F3_RST:
            begin
                if(F[3] == micro_jmp_condition[0])
                    jump_condition_true = 1;
            end
            default:
            begin
                if(micro_op_type == MICRO_TYPE_JMP)
                    not_implemented_jump_error = 1;
            end
        endcase
    end

    reg not_implemented_addressing_error;
    reg not_implemented_alu_pack_ops_error;
    reg halt_counter;
    always_ff @ (negedge clk)
    begin
        if(clk_ce)
        begin
            not_implemented_addressing_error <= 0;
            not_implemented_alu_pack_ops_error <= 0;

            if(reset)
            begin
                iack                 <= 1'd0;
                state                <= STATE_IDLE;
                address_out          <= ~24'd0;
                pl                   <= 1'd0;
                bus_status           <= BUS_COMMAND_IDLE;
                reset_counter        <= 2'd0;
                exception            <= EXCEPTION_TYPE_RESET;
                irq_vector_address   <= 8'd0;
                fetch_opcode         <= 1'd0;
                top_address          <= 16'd0;
                not_implemented_write_error <= 1'd0;

                SC <= 8'hC0;
                NB <= 8'h01;
                EP <= 8'h0;
                IX <= 16'h0;
                IY <= 16'h0;
            end
            else if(reset_counter < 2)
            begin
                reset_counter <= reset_counter + 2'd1;
                if(reset_counter == 1)
                begin
                    // Output dummy address
                    address_out <= 24'hDEFACE;
                end
            end
            else
            begin
                bus_request_latch <= bus_request;
                bus_ack_negedge   <= (pk == 0)? bus_request: bus_request_latch;

                if((pk == 0) && bus_ack_posedge)
                begin
                    pl           <= 1'd0;
                    address_out  <= 24'd0;
                end
                else if(!bus_ack)
                begin
                    pl <= pk;
                    if(pk == 1)
                    begin
                        if(exception_factor != 0 && exception != EXCEPTION_TYPE_RESET)
                            exception <= exception_factor;

                        not_implemented_write_error <= 1'd0;

                        if(fetch_opcode && !iack)
                        begin
                            opcode <= data_in;
                            top_address <= PC;
                            PC <= PC + 16'h1;
                        end
                    end
                    else if(pk == 0)
                    begin
                        address_out  <= {1'd0, (PC[15]? CB: 8'd0), PC[14:0]};
                        bus_status   <= BUS_COMMAND_MEM_READ;
                        fetch_opcode <= 0;
                        //bus_status <= BUS_COMMAND_IRQ_READ;

                        // @note: Do we need to restrict the state setting here?
                        //if(exception == EXCEPTION_TYPE_NONE || iack == 1)
                        //    state <= next_state;

                        state <= next_state;

                        if(next_state == STATE_EXC_PROCESS && exception_process_step == 0 && iack == 1)
                            bus_status <= (exception < EXCEPTION_TYPE_NMI)? BUS_COMMAND_IRQ_READ: BUS_COMMAND_MEM_READ;
                        else if(exception == EXCEPTION_TYPE_RESET && iack == 0)
                        begin
                            fetch_opcode           <= 1;
                            iack                   <= 1;
                            address_out            <= 24'hDEFACE;
                            exception_process_step <= 4;
                        end

                        if(
                            ((state == STATE_EXECUTE && !fetch_opcode) ||
                             (next_state == STATE_EXECUTE && state != STATE_EXC_PROCESS)) &&
                            microinstruction_done
                        )
                        begin
                            fetch_opcode <= 1;

                            if(exception != EXCEPTION_TYPE_NONE && iack == 0 && postpone_exception == 0)
                            begin
                                iack                   <= 1;
                                exception_process_step <= 0;
                            end
                        end

                        if(next_state == STATE_HALT)
                            halt_counter <= 0;
                    end


                    if(state == STATE_EXC_PROCESS)
                    begin
                        state <= STATE_EXC_PROCESS;

                        if(pk == 1)
                        begin
                            if(exception_process_step == 0)
                            begin
                                irq_vector_address <=
                                    (exception == EXCEPTION_TYPE_NMI)?     8'h4:
                                    (exception == EXCEPTION_TYPE_DIVZERO)? 8'h2:
                                                                           data_in;
                            end
                            else if(exception_process_step == 5)
                            begin
                                PC[7:0] <= data_in;
                            end
                            else if(exception_process_step == 6)
                            begin
                                PC[15:8] <= data_in;
                            end
                            else if(exception_process_step == 7)
                            begin
                                state <= next_state;
                            end
                        end
                        else
                        begin
                            exception_process_step <= exception_process_step + 4'd1;

                            if(exception_process_step == 0)
                            begin
                                bus_status <= BUS_COMMAND_MEM_WRITE;
                                address_out <= {8'b0, SP - 16'd1};
                                SP <= SP - 16'd1;
                            end
                            else if(exception_process_step == 1)
                            begin
                                bus_status <= BUS_COMMAND_MEM_WRITE;
                                address_out <= {8'b0, SP - 16'd1};
                                SP <= SP - 16'd1;
                            end
                            else if(exception_process_step == 2)
                            begin
                                bus_status <= BUS_COMMAND_MEM_WRITE;
                                address_out <= {8'b0, SP - 16'd1};
                                SP <= SP - 16'd1;
                            end
                            else if(exception_process_step == 3)
                            begin
                                bus_status <= BUS_COMMAND_MEM_WRITE;
                                address_out <= {8'b0, SP - 16'd1};
                                SP <= SP - 16'd1;
                            end
                            else if(exception_process_step == 4)
                            begin
                                address_out <= {16'd0, irq_vector_address};
                                // @important: in the CPU manual, it shows that i0,i1
                                // are being set at pk == 0. Here we set all registers
                                // at pl cycles to make it slightly easier, otherwise
                                // we need to treat SC separately.
                                SC[7:6] <= (exception < EXCEPTION_TYPE_NMI)? exception[1:0]: 2'h3;
                            end
                            else if(exception_process_step == 5)
                            begin
                                address_out <= {16'd0, irq_vector_address + 8'd1};
                                iack        <= 0;
                                exception   <= EXCEPTION_TYPE_NONE;
                            end
                            else if(exception_process_step == 6)
                            begin
                                fetch_opcode <= 1;
                            end
                        end
                    end
                    else if(state == STATE_OPEXT_READ)
                    begin
                        if(pk == 1)
                        begin
                            opext <= data_in;
                            PC <= PC + 16'd1;
                        end
                    end
                    else if(state == STATE_HALT)
                    begin
                        // @hack: because I'm checking for opext == hAE for
                        // next state.
                        opext      <= 0;
                        state      <= STATE_HALT;
                        bus_status <= BUS_COMMAND_IDLE;
                        halt_counter <= halt_counter + 1;
                        if(halt_counter)
                        begin
                            if(exception_factor != 0 && exception != EXCEPTION_TYPE_RESET)
                            begin
                                bus_status             <= BUS_COMMAND_MEM_READ;
                                state                  <= STATE_IDLE;
                                exception              <= exception_factor;
                                iack                   <= 1;
                                exception_process_step <= 0;
                            end
                        end
                    end
                    else if(state == STATE_EXECUTE)
                    begin
                        if(pk == 0)
                        begin
                            if(!fetch_opcode)
                            begin
                                state <= STATE_EXECUTE;

                                if(micro_op_type == MICRO_TYPE_JMP && jump_condition_true)
                                begin
                                    if(microinstruction_done)
                                    begin
                                        //$display("%d, %x, %x, %x, %x: 0x%x", PC[15], PC, top_address, jump_dest, NB, {1'd0, (jump_dest[15]? NB: 8'd0), jump_dest[14:0]});
                                        address_out <= {1'd0, (jump_dest[15]? NB: 8'd0), jump_dest[14:0]};
                                    end
                                end
                            end
                        end
                        else
                        begin
                            if(alu_flag_update)
                            begin
                                case(alu_op)
                                    ALUOP_AND, ALUOP_OR, ALUOP_XOR:
                                    begin
                                        SC[0] <= alu_flags[ALU_FLAG_Z];
                                        SC[3] <= alu_flags[ALU_FLAG_S];
                                    end
                                    ALUOP_RLC, ALUOP_RRC, ALUOP_RL, ALUOP_RR, ALUOP_SLL, ALUOP_SRL:
                                    begin
                                        SC[0] <= alu_flags[ALU_FLAG_Z];
                                        SC[1] <= alu_flags[ALU_FLAG_C];
                                        SC[3] <= alu_flags[ALU_FLAG_S];
                                    end
                                    ALUOP_ADD, ALUOP_ADC, ALUOP_SUB, ALUOP_SBC, ALUOP_NEG, ALUOP_SLA, ALUOP_SRA, ALUOP_DIV, ALUOP_MUL:
                                    begin
                                        if(flag_unpack && (
                                            alu_op == ALUOP_ADD ||
                                            alu_op == ALUOP_ADC ||
                                            alu_op == ALUOP_SUB ||
                                            alu_op == ALUOP_SBC ||
                                            alu_op == ALUOP_NEG
                                        ))
                                        begin
                                            not_implemented_alu_pack_ops_error <= 1;
                                        end
                                        SC[0] <= alu_flags[ALU_FLAG_Z];
                                        SC[1] <= alu_flags[ALU_FLAG_C];
                                        SC[2] <= alu_flags[ALU_FLAG_V];
                                        SC[3] <= alu_flags[ALU_FLAG_S];
                                    end
                                    ALUOP_INC, ALUOP_DEC:
                                    begin
                                        SC[0] <= alu_flags[ALU_FLAG_Z];
                                    end
                                    default:
                                    begin
                                    end
                                endcase
                            end

                            if(micro_mov_dst == MICRO_MOV_PC)
                            begin
                                PC <= src_reg;
                            end

                            if(micro_mov_src == MICRO_MOV_DATA)
                            begin
                                PC <= PC + 16'd1;
                            end

                            if(micro_op_type == MICRO_TYPE_JMP)
                            begin
                                if(microinstruction_done)
                                begin
                                    if(jump_condition_true)
                                    begin
                                        CB <= NB;
                                        // @note: Don't pre-increment PC when
                                        // interrupt acknowledged.
                                        PC <= iack? jump_dest: jump_dest + 16'd1;
                                        top_address <= jump_dest;
                                    end
                                    else NB <= CB;
                                end
                            end

                            if(micro_op_type == MICRO_TYPE_BUS && micro_bus_op == MICRO_BUS_MEM_READ)// && !fetch_opcode)
                            begin
                                write_data_to_register(micro_bus_reg, {8'd0, data_in});
                            end
                            else if(micro_op_type == MICRO_TYPE_MISC)
                            begin
                                write_data_to_register(micro_mov_dst_sec, src_reg_sec);
                            end
                            write_data_to_register(micro_mov_dst, src_reg);
                        end
                    end

                    if(micro_op_type == MICRO_TYPE_BUS && pk == 0)
                    begin
                        if((state == STATE_EXECUTE || (next_state == STATE_EXECUTE && state != STATE_EXC_PROCESS)) && !microinstruction_done)
                        begin
                            // Don't do any bus ops on the last microinstruction
                            // step.
                            if(micro_bus_op == MICRO_BUS_MEM_WRITE)
                                bus_status <= BUS_COMMAND_MEM_WRITE;

                            case(micro_bus_add)
                                MICRO_ADD_HL:
                                begin
                                    address_out <= {EP, HL};
                                end

                                MICRO_ADD_IX:
                                begin
                                    address_out <= {XP, IX};
                                end

                                MICRO_ADD_IX1:
                                begin
                                    address_out <= {XP, IX+16'd1};
                                end

                                MICRO_ADD_IX_DD:
                                begin
                                    address_out <= {XP, IX+{{8{imm_low[7]}}, imm_low}};
                                end

                                MICRO_ADD_IX_L:
                                begin
                                    address_out <= {XP, IX+{{8{L[7]}}, L}};
                                end

                                MICRO_ADD_IY:
                                begin
                                    address_out <= {YP, IY};
                                end

                                MICRO_ADD_IY1:
                                begin
                                    address_out <= {YP, IY+16'd1};
                                end

                                MICRO_ADD_IY_DD:
                                begin
                                    address_out <= {YP, IY+{{8{imm_low[7]}}, imm_low}};
                                end

                                MICRO_ADD_IY_L:
                                begin
                                    address_out <= {YP, IY+{{8{L[7]}}, L}};
                                end

                                MICRO_ADD_HL1:
                                begin
                                    address_out <= {EP, HL+16'd1};
                                end

                                MICRO_ADD_HH_LL:
                                begin
                                    address_out <= {EP, imm};
                                end

                                MICRO_ADD_HH_LL1:
                                begin
                                    address_out <= {EP, imm+16'd1};
                                end

                                MICRO_ADD_KK:
                                begin
                                    address_out <= {16'd0, imm[7:0]};
                                end

                                MICRO_ADD_KK1:
                                begin
                                    address_out <= {8'd0, {8'd0, imm[7:0]}+16'd1};
                                end

                                MICRO_ADD_SP:
                                begin
                                    if(micro_bus_op == MICRO_BUS_MEM_WRITE)
                                    begin
                                        address_out <= {8'b0, SP-16'd1};
                                        SP <= SP - 16'd1;
                                    end
                                    else
                                    begin
                                        address_out <= {8'b0, SP};
                                        SP <= SP + 16'd1;
                                    end
                                end

                                MICRO_ADD_SP_DD:
                                begin
                                    address_out <= {8'd0, SP+{{8{imm_low[7]}}, imm_low}};
                                end

                                MICRO_ADD_SP_DD1:
                                begin
                                    address_out <= {8'd0, SP+{{8{imm_low[7]}}, imm_low}+16'd1};
                                end

                                MICRO_ADD_BR:
                                begin
                                    address_out <= {EP, BR, imm_low};
                                end

                                default:
                                begin
                                    not_implemented_addressing_error <= 1;
                                end
                            endcase
                        end
                    end
                end
            end
        end
    end

    reg not_implemented_data_out_error;
    always_ff @ (posedge clk)
    begin
        if(clk_ce)
        begin
            if(reset)
            begin
                data_out      <= ~8'd0;
                read          <= 0;
                pk            <= 0;
                microaddress  <= 0;
                microprogram_counter <= 0;
                not_implemented_data_out_error <= 0;
            end
            else if(reset_counter >= 2)
            begin
                bus_ack_posedge <= bus_request;

                if(!bus_ack && state != STATE_HALT)
                begin
                    pk <= ~pk;
                    read <= 0;
                    read_interrupt_vector <= 0;
                    not_implemented_data_out_error <= 0;

                    // @todo: Remove all code that sets read <= 1 and replace
                    // with below code.
                    //if(pk == 0 && bus_status == BUS_COMMAND_MEM_READ)
                    //    read <= 1;

                    // @temp solution
                    if(state == STATE_IDLE && exception != EXCEPTION_TYPE_NONE && pk == 0)
                        read <= 1;

                    if(fetch_opcode)
                    begin
                        if(pk == 0)
                        begin
                            read <= 1;
                        end
                    end

                    if(next_state == STATE_EXECUTE)
                    begin
                        if(pk == 1)
                        begin
                            microprogram_counter <= 0;
                            microaddress <= translation_rom[extended_opcode];
                        end
                        else
                        begin
                        end
                    end

                    case(state)
                        STATE_IDLE:
                        begin
                        end

                        STATE_EXC_PROCESS:
                        begin
                            if(pk == 0)
                            begin
                                if(exception_process_step == 0 && exception < EXCEPTION_TYPE_NMI)
                                    read_interrupt_vector <= 1;
                                else if(exception_process_step == 1)
                                    data_out <= CB;
                                else if(exception_process_step == 2)
                                    data_out <= PC[15:8];
                                else if(exception_process_step == 3)
                                    data_out <= PC[7:0];
                                else if(exception_process_step == 4)
                                begin
                                    data_out <= SC;
                                    if(exception == EXCEPTION_TYPE_RESET)
                                        read <= 1;
                                end
                                else if(exception_process_step >= 5)
                                begin
                                    read <= 1;
                                end
                            end
                            else
                            begin
                            end
                        end

                        STATE_OPEXT_READ:
                        begin
                            if(pk == 0)
                            begin
                                read <= 1;
                            end
                        end

                        STATE_EXECUTE:
                        begin
                            // Don't increment if the microinstruction is done or if
                            // fetching next opcode.
                            // @todo: Check if we can just remove the condition on
                            // microinstruction_done.
                            if(pk == 1 && !microinstruction_done && !fetch_opcode)
                            begin
                                microprogram_counter <= microprogram_counter + 4'd1;
                                if(micro_op_type == MICRO_TYPE_JMP && jump_condition_true)
                                begin
                                    microprogram_counter <= microprogram_counter + 4'd2;
                                end
                            end

                            if(micro_mov_src == MICRO_MOV_DATA && pk == 0)
                                read <= 1;

                            if(micro_op_type == MICRO_TYPE_BUS)
                            begin
                                if(micro_bus_op == MICRO_BUS_MEM_READ)
                                begin
                                    if(pk == 0)
                                    begin
                                        read <= 1;
                                    end
                                end
                                else // MICRO_BUS_MEM_WRITE
                                begin
                                    if(pk == 0)
                                    begin
                                        case(micro_bus_reg)
                                            MICRO_MOV_A:
                                                data_out <= BA[7:0];

                                            MICRO_MOV_B:
                                                data_out <= BA[15:8];

                                            MICRO_MOV_L:
                                                data_out <= L;

                                            MICRO_MOV_H:
                                                data_out <= H;

                                            MICRO_MOV_IXL:
                                                data_out <= IX[7:0];

                                            MICRO_MOV_IXH:
                                                data_out <= IX[15:8];

                                            MICRO_MOV_IYL:
                                                data_out <= IY[7:0];

                                            MICRO_MOV_IYH:
                                                data_out <= IY[15:8];

                                            MICRO_MOV_ALU_A:
                                                data_out <= alu_A[7:0];

                                            MICRO_MOV_ALU_B:
                                                data_out <= alu_B[7:0];

                                            MICRO_MOV_IMML:
                                                data_out <= imm_low;

                                            MICRO_MOV_IMMH:
                                                data_out <= imm_high;

                                            MICRO_MOV_ALU_R:
                                                data_out <= alu_R[7:0];

                                            MICRO_MOV_PCL:
                                                data_out <= PC[7:0];

                                            MICRO_MOV_PCH:
                                                data_out <= PC[15:8];

                                            MICRO_MOV_CB:
                                                data_out <= CB;

                                            MICRO_MOV_EP:
                                                data_out <= EP;

                                            MICRO_MOV_BR:
                                                data_out <= BR;

                                            MICRO_MOV_SC:
                                                data_out <= SC;

                                            MICRO_MOV_XP:
                                                data_out <= XP;

                                            MICRO_MOV_YP:
                                                data_out <= YP;

                                            default:
                                            begin
                                                not_implemented_data_out_error <= 1;
                                            end
                                        endcase
                                    end
                                end
                            end
                        end

                        default:
                        begin
                        end
                    endcase
                end
                else
                begin
                    pk   <= 0;
                    read <= 0;
                end
            end
        end
    end

endmodule
