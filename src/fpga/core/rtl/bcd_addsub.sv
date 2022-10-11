module bcd_addsub
(
    input add_sub,
    input [7:0] a,
    input [7:0] b,
    input carry_in,
    output [7:0] r,
    output [3:0] flags
);

    wire [3:0] sum_low, sum_high;
    wire carry_low, carry_high;
    bcd_addsub4 bcd_low(add_sub, a[3:0], b[3:0], carry_in, sum_low, carry_low);
    bcd_addsub4 bcd_high(add_sub, a[7:4], b[7:4], carry_low, sum_high, carry_high);

    assign r = {sum_high, sum_low};
    assign flags = {2'd0, carry_high, r == 0};

endmodule

module bcd_addsub4
(
    input add_sub,
    input [3:0] a,
    input [3:0] b,
    input carry_in,
    output reg [3:0] r,
    output reg carry_out
);

    wire [4:0] sum_temp = add_sub?
        a - b - {4'd0, carry_in}:
        a + b + {4'd0, carry_in};

    always_comb
    begin
        carry_out = 0;
        r = sum_temp[3:0];

        if(sum_temp > 9)
        begin
            carry_out = 1'b1;
            r = add_sub?
                sum_temp[3:0] - 4'd6:
                sum_temp[3:0] + 4'd6;
        end
    end

endmodule
