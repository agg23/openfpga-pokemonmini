// MIT License

// Copyright (c) 2022 Eric Lewis

// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:

// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.

// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.
//
////////////////////////////////////////////////////////////////////////////////

module rumble(
    input             clk_74a,
    input             active,

    output reg  [7:4] cart_tran_bank0,
    input       [7:0] cart_tran_bank1,
    input       [7:0] cart_tran_bank2,
    output reg  [7:0] cart_tran_bank3,

    output reg        cart_tran_bank0_dir,
    output reg        cart_tran_bank1_dir,
    output reg        cart_tran_bank2_dir,
    output reg        cart_tran_bank3_dir
);

initial begin
    cart_tran_bank3_dir = 1'b1;
    cart_tran_bank2_dir = 1'b0;
    cart_tran_bank1_dir = 1'b0;
    cart_tran_bank0_dir = 1'b1;
end

reg pulse = 1;
always @(posedge clk_74a) begin
    cart_tran_bank0[6] <= ~active;
    cart_tran_bank3[1] <= pulse;
    pulse              <= ~pulse;
end

endmodule