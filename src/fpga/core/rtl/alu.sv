enum bit[4:0]
{
    ALUOP_ADD   = 5'd00,
    ALUOP_OR    = 5'd01,
    ALUOP_ADC   = 5'd02,
    ALUOP_SBC   = 5'd03,
    ALUOP_AND   = 5'd04,
    ALUOP_SUB   = 5'd05,
    ALUOP_XOR   = 5'd06,

    ALUOP_RLC   = 5'd08,
    ALUOP_RRC   = 5'd09,
    ALUOP_RL    = 5'd10,
    ALUOP_RR    = 5'd11,
    ALUOP_SLL   = 5'd12,
    ALUOP_SRL   = 5'd13,
    ALUOP_SLA   = 5'd14,
    ALUOP_SRA   = 5'd15,

    ALUOP_INC   = 5'd16,
    ALUOP_INC2  = 5'd17,
    ALUOP_DEC   = 5'd18,
    ALUOP_DEC2  = 5'd19,
    ALUOP_NEG   = 5'd20,

    ALUOP_DIV   = 5'd21,
    ALUOP_MUL   = 5'd22,

    ALUOP_PACK  = 5'd23,
    ALUOP_UPACK = 5'd24,
    ALUOP_SWAP  = 5'd25,
    ALUOP_SEP   = 5'd26
} AluOp;

enum bit[1:0]
{
    ALU_FLAG_Z,  // Zero flag
    ALU_FLAG_C,  // Carry flag
    ALU_FLAG_V,  // Overflow flag
    ALU_FLAG_S   // Sign flag
} AluFlags;


// @todo: Need to implement unpack operations.
module alu
(
    input [4:0] alu_op,
    input size,
    input [15:0] A,
    input [15:0] B,
    input C,
    input D,
    output reg [15:0] R,
    output reg [3:0] flags
);

    // @question: When size == 0, do we modify the contents of the upper byte?
    // Does it matter at all if we write back only the lower byte anyway?
    // I would guess not.

    // @question: Is it better to use non-blocking assigns and set flags based
    // strictly on the input data, or using blocking assignments with extended
    // by-1-bit data and use the result for the carry?

    // @todo: What's the correct way to handle 0 shifts?

    wire [3:0] msb = (size == 1)? 4'd15: 4'd7;
    reg [16:0] R_temp;

    wire add_sub = (
        alu_op == ALUOP_INC  ||
        alu_op == ALUOP_INC2 ||
        alu_op == ALUOP_ADD  ||
        alu_op == ALUOP_ADC
    )? 0: 1;

    wire bcd_c;
    wire [7:0] temp_bcd;
    wire [3:0] bcd_flags;
    reg [7:0] bcd_B;
    bcd_addsub bcd(
        add_sub,
        A[7:0], bcd_B,
        (alu_op == ALUOP_ADC || alu_op == ALUOP_SBC)? C: 0,
        temp_bcd,
        bcd_flags
    );

    // @todo: Should we put flags in separate always_comb? It's annoying that we have
    // to check again if it's ADD, INC, etc.
    always_comb
    begin
        R_temp = 0;
        flags = 4'h0;
        bcd_B = B[7:0];
        case(alu_op)

            ALUOP_AND:
            begin
                R = A & B;
                flags[ALU_FLAG_C] = 0;
                flags[ALU_FLAG_V] = 0;
                flags[ALU_FLAG_Z] = (size == 1)? (R == 0): (R[7:0] == 0);
                flags[ALU_FLAG_S] = R[msb];
            end

            ALUOP_OR:
            begin
                R = A | B;
                flags[ALU_FLAG_C] = 0;
                flags[ALU_FLAG_V] = 0;
                flags[ALU_FLAG_Z] = (size == 1)? (R == 0): (R[7:0] == 0);
                flags[ALU_FLAG_S] = R[msb];
            end

            ALUOP_XOR:
            begin
                R = A ^ B;
                flags[ALU_FLAG_C] = 0;
                flags[ALU_FLAG_V] = 0;
                flags[ALU_FLAG_Z] = (size == 1)? (R == 0): (R[7:0] == 0);
                flags[ALU_FLAG_S] = R[msb];
            end

            ALUOP_INC,
            ALUOP_INC2,
            ALUOP_ADD,
            ALUOP_ADC:
            begin
                if(D && size == 0)
                begin
                    if(alu_op == ALUOP_INC)
                        bcd_B = 8'd1;
                    else if(alu_op == ALUOP_INC2)
                        bcd_B = 8'd2;

                    R = {8'd0, temp_bcd};
                    flags = bcd_flags;
                end
                else
                begin
                    if(alu_op == ALUOP_ADD)
                    begin
                        R_temp = {1'b0, A} + {1'b0, B};
                        R = R_temp[15:0];
                        flags[ALU_FLAG_C] = R_temp[{1'b0, msb} + 5'd1];
                    end
                    else if(alu_op == ALUOP_ADC)
                    begin
                        R_temp = {1'b0, A} + {1'b0, B} + {16'd0, C};
                        R = R_temp[15:0];
                        flags[ALU_FLAG_C] = R_temp[{1'b0, msb} + 5'd1];
                    end
                    else if(alu_op == ALUOP_INC)
                        R = A + 16'd1;
                    else
                        R = A + 16'd2;

                    flags[ALU_FLAG_V] = (A[msb] & B[msb] & ~R[msb]) | (~A[msb] & ~B[msb] & R[msb]);
                    // can we do this? flags[ALU_FLAG_V] = (R[msb] == flags[ALU_FLAG_C]);
                    flags[ALU_FLAG_Z] = (size == 1)? (R == 0): (R[7:0] == 0);
                    flags[ALU_FLAG_S] = R[msb];
                end
            end

            ALUOP_DEC,
            ALUOP_DEC2,
            ALUOP_NEG,
            ALUOP_SUB,
            ALUOP_SBC:
            begin
                if(D && size == 0)
                begin
                    if(alu_op == ALUOP_DEC)
                        bcd_B = 8'd1;
                    else if(alu_op == ALUOP_DEC2)
                        bcd_B = 8'd2;

                    R = {8'd0, temp_bcd};
                    flags = bcd_flags;
                end
                else
                begin
                    if(alu_op == ALUOP_DEC)
                        R = A - 16'd1;
                    else if(alu_op == ALUOP_DEC2)
                        R = A - 16'd2;
                    else if(alu_op == ALUOP_SBC)
                    begin
                        R_temp = {1'b0, A} - {1'b0, B} - {16'd0, C};
                        R = R_temp[15:0];
                        flags[ALU_FLAG_C] = R_temp[{1'b0, msb} + 5'd1];
                    end
                    else
                    begin
                        R_temp = {1'b0, A} - {1'b0, B};
                        R = R_temp[15:0];
                        flags[ALU_FLAG_C] = R_temp[{1'b0, msb} + 5'd1];
                    end

                    flags[ALU_FLAG_V] = (A[msb] & ~B[msb] & ~R[msb]) | (~A[msb] & B[msb] & R[msb]);
                    flags[ALU_FLAG_Z] = (size == 1)? (R == 0): (R[7:0] == 0);
                    flags[ALU_FLAG_S] = R[msb];
                end
            end

            ALUOP_DIV:
            begin
                R_temp[15:0] = A / {8'd0, B[7:0]};
                R = flags[ALU_FLAG_V]? A: {A[7:0] % B[7:0], R_temp[7:0]};

                flags[ALU_FLAG_Z] = (B[7:0] != 0)? ((size == 1)? (R == 0): (R[7:0] == 0)): 1'd0;
                flags[ALU_FLAG_C] = 0;
                flags[ALU_FLAG_V] = (B[7:0] != 0)? (R_temp[15:8] != 0): 1'd1;
                flags[ALU_FLAG_S] = (B[7:0] != 0)? R[7]: 1'd1;
            end

            ALUOP_MUL:
            begin
                R = A[7:0] * B[7:0];

                flags[ALU_FLAG_Z] = (size == 1)? (R == 0): (R[7:0] == 0);
                flags[ALU_FLAG_C] = 0;
                flags[ALU_FLAG_V] = 0;
                flags[ALU_FLAG_S] = R[15];
            end

            ALUOP_RLC:
            begin
                R = {A[14:0], A[msb]};
                flags[ALU_FLAG_C] = A[msb];
                flags[ALU_FLAG_Z] = (size == 1)? (R == 0): (R[7:0] == 0);
                flags[ALU_FLAG_S] = R[msb];
            end

            ALUOP_RL:
            begin
                R = {A[14:0], C};
                flags[ALU_FLAG_C] = A[msb];
                flags[ALU_FLAG_Z] = (size == 1)? (R == 0): (R[7:0] == 0);
                flags[ALU_FLAG_S] = R[msb];
            end

            ALUOP_RRC:
            begin
                R = {A[15:8], A[0], A[7:1]};
                flags[ALU_FLAG_C] = A[0];
                flags[ALU_FLAG_Z] = (size == 1)? (R == 0): (R[7:0] == 0);
                flags[ALU_FLAG_S] = R[msb];
            end

            ALUOP_RR:
            begin
                R = {A[15:8], C, A[7:1]};
                flags[ALU_FLAG_C] = A[0];
                flags[ALU_FLAG_Z] = (size == 1)? (R == 0): (R[7:0] == 0);
                flags[ALU_FLAG_S] = R[msb];
            end

            ALUOP_SLL:
            begin
                R = {A[14:0], 1'b0};
                flags[ALU_FLAG_C] = A[msb];
                flags[ALU_FLAG_Z] = (size == 1)? (R == 0): (R[7:0] == 0);
                flags[ALU_FLAG_S] = R[msb];
            end

            ALUOP_SLA:
            begin
                R = {A[14:0], 1'b0};
                flags[ALU_FLAG_C] = A[msb];
                flags[ALU_FLAG_Z] = (size == 1)? (R == 0): (R[7:0] == 0);
                flags[ALU_FLAG_S] = R[msb];
                flags[ALU_FLAG_V] = (A[msb] ^ A[msb-1]);
            end

            ALUOP_SRL:
            begin
                R = {9'b0, A[7:1]};
                flags[ALU_FLAG_C] = A[0];
                flags[ALU_FLAG_Z] = (size == 1)? (R == 0): (R[7:0] == 0);
                flags[ALU_FLAG_S] = R[msb];
            end

            ALUOP_SRA:
            begin
                R = {8'b0, A[7], A[7:1]};
                flags[ALU_FLAG_C] = A[0];
                flags[ALU_FLAG_Z] = (size == 1)? (R == 0): (R[7:0] == 0);
                flags[ALU_FLAG_S] = R[msb];
                flags[ALU_FLAG_V] = 0;
            end

            ALUOP_PACK:
            begin
                R = {8'd0, A[11:8], A[3:0]};
                flags = 4'd0;
            end

            ALUOP_UPACK:
            begin
                R = {4'd0, A[7:4], 4'd0, A[3:0]};
                flags = 4'd0;
            end

            ALUOP_SWAP:
            begin
                R = {8'd0, A[3:0], A[7:4]};
                flags = 4'd0;
            end

            ALUOP_SEP:
            begin
                R = {{8{A[7]}}, A[7:0]};
                flags = 4'd0;
            end

            default:
            begin
                R = 16'hFECA;
                flags = 4'd0;
            end

        endcase
    end

endmodule
