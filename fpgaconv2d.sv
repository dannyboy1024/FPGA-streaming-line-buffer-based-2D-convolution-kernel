// This module implements 2D covolution between a 3x3 filter and a 512-pixel-wide image of any height.
// It is assumed that the input image is padded with zeros such that the input and output images have
// the same size. The filter coefficients are symmetric in the x-direction (i.e. f[0][0] = f[0][2], 
// f[1][0] = f[1][2], f[2][0] = f[2][2] for any filter f) and their values are limited to integers
// (but can still be positive of negative). The input image is grayscale with 8-bit pixel values ranging
// from 0 (black) to 255 (white).
module lab2 (
	input  clk,			// Operating clock
	input  reset,			// Active-high reset signal (reset when set to 1)
	input  [71:0] i_f,		// Nine 8-bit signed convolution filter coefficients in row-major format (i.e. i_f[7:0] is f[0][0], i_f[15:8] is f[0][1], etc.)
	input  i_valid,			// Set to 1 if input pixel is valid
	input  i_ready,			// Set to 1 if consumer block is ready to receive a new pixel
	input  [7:0] i_x,		// Input pixel value (8-bit unsigned value between 0 and 255)
	output o_valid,			// Set to 1 if output pixel is valid
	output o_ready,			// Set to 1 if this block is ready to receive a new pixel
	output [7:0] o_y		// Output pixel value (8-bit unsigned value between 0 and 255)
);

localparam FILTER_SIZE = 3;	// Convolution filter dimension (i.e. 3x3)
localparam PIXEL_DATAW = 8;	// Bit width of image pixels and filter coefficients (i.e. 8 bits)

// The following code is intended to show you an example of how to use paramaters and
// for loops in SytemVerilog. It also arrages the input filter coefficients for you
// into a nicely-arranged and easy-to-use 2D array of registers. However, you can ignore
// this code and not use it if you wish to.

logic signed [PIXEL_DATAW-1:0] r_f [FILTER_SIZE-1:0][FILTER_SIZE-1:0]; // 2D array of registers for filter coefficients
integer signed col, row; // variables to use in the for loop
always_ff @ (posedge clk) begin
	// If reset signal is high, set all the filter coefficient registers to zeros
	// We're using a synchronous reset, which is recommended style for recent FPGA architectures
	if(reset)begin
		for(row = 0; row < FILTER_SIZE; row = row + 1) begin
			for(col = 0; col < FILTER_SIZE; col = col + 1) begin
				r_f[row][col] <= 0;
			end
		end
	// Otherwise, register the input filter coefficients into the 2D array signal
	end else begin
		for(row = 0; row < FILTER_SIZE; row = row + 1) begin
			for(col = 0; col < FILTER_SIZE; col = col + 1) begin
				// Rearrange the 72-bit input into a 3x3 array of 8-bit filter coefficients.
				// signal[a +: b] is equivalent to signal[a+b-1 : a]. You can try to plug in
				// values for col and row from 0 to 2, to understand how it operates.
				// For example at row=0 and col=0: r_f[0][0] = i_f[0+:8] = i_f[7:0]
				//	       at row=0 and col=1: r_f[0][1] = i_f[8+:8] = i_f[15:8]
				r_f[row][col] <= i_f[(row * FILTER_SIZE * PIXEL_DATAW)+(col * PIXEL_DATAW) +: PIXEL_DATAW];
			end
		end
	end
end

// Start of your code
localparam IMAGE_WIDTH = 512;
localparam BOARD_WIDTH = IMAGE_WIDTH+2;
localparam OFFSET = (FILTER_SIZE-1)>>1;
localparam RESULT_WIDTH = 2*PIXEL_DATAW;
logic signed [RESULT_WIDTH-1:0] dep_window [FILTER_SIZE-1:0][FILTER_SIZE-1:0];
logic signed [RESULT_WIDTH-1:0] products [FILTER_SIZE-1:0][FILTER_SIZE-1:0];
logic signed [RESULT_WIDTH-1:0] products_buf [FILTER_SIZE-1:0][FILTER_SIZE-1:0];
logic [2*RESULT_WIDTH-1:0] mem[0:IMAGE_WIDTH-1];
logic signed [RESULT_WIDTH-1:0] wr_upper, rd_upper;
logic signed [RESULT_WIDTH-1:0] wr_lower, rd_lower;
logic unsigned [8:0] wr_addr, rd_addr;
logic unsigned [9:0] i_pixel_col, i_pixel_row;
logic i_valid_buf;
logic i_valid_dbuf;
logic unsigned [PIXEL_DATAW-1:0] i_x_buf;
logic o_valid_buf;
logic unsigned [RESULT_WIDTH-1:0] o_y_buf;
logic signed [RESULT_WIDTH-1:0] signed_x;
logic signed [RESULT_WIDTH-1:0] signed_f;
logic signed [RESULT_WIDTH-1:0] conv_result;
logic rd_en_c1;
logic wr_en;
integer signed r,c;
// generate 3 DSP blocks
genvar i;
generate
	for(i=0; i<FILTER_SIZE; i++) begin : gen_dsp_blocks
		mult multDSP (
			.ax      (i_x_buf),          
			.bx      (i_x_buf),     
			.ay      (r_f[FILTER_SIZE-1-i][FILTER_SIZE-1-0]),      
			.by      (r_f[FILTER_SIZE-1-i][FILTER_SIZE-1-1]),     
			.resulta (products[i][0]),
			.resultb (products[i][1])
		);
	end
endgenerate
always_comb begin
	conv_result = dep_window[0][0] + products_buf[0][0];
	wr_upper = dep_window[1][0] + products_buf[1][0];
	wr_lower = dep_window[2][0] + products_buf[2][0];
end
always_ff @ (posedge clk) begin
	if (reset) begin
		i_valid_buf <= 1'b0;
		i_valid_dbuf <= 1'b0;
		i_x_buf <= '0;
		o_valid_buf <= 1'b0;
		o_y_buf <= '0;
		i_pixel_col <= '0;
		i_pixel_row <= '0;
		wr_en <= 1'b0;
		rd_en_c1 <= 1'b0;
		wr_addr <= '0;
		rd_addr <= '0;
		for(row = 0; row < FILTER_SIZE; row = row + 1) begin
			for(col = 0; col < FILTER_SIZE; col = col + 1) begin
				dep_window[row][col] <= '0;
				products_buf[row][col] <= '0;
			end
		end
	end else begin
		i_valid_buf <= o_ready ? i_valid : i_valid_buf;
		i_x_buf <= o_ready ? i_x : i_x_buf;	
		o_valid_buf <= ((i_pixel_row>1&&i_pixel_col>2)||(i_pixel_row>2&&i_pixel_col==0));
		rd_en_c1 <= i_pixel_row>0&&i_pixel_col<IMAGE_WIDTH;
		i_valid_dbuf <= i_valid_buf;
		if (o_ready) begin
			if (i_valid_buf) begin
				// buffer the products
				for(row = 0; row < FILTER_SIZE; row = row + 1) begin
					for(col = 0; col <= FILTER_SIZE/2; col = col + 1) begin
						products_buf[row][col] <= products[row][col];
					end
					products_buf[row][FILTER_SIZE-1] <= products[row][0];
				end
				// increment column counter, update write and read address
				if (i_pixel_col==BOARD_WIDTH-1) begin
					i_pixel_col <= '0;
					i_pixel_row <= i_pixel_row + 1;
					rd_addr <= '0;
				end else begin
					i_pixel_col <= i_pixel_col + 1;
					rd_addr <= i_pixel_col + 1;
				end
				wr_en <= i_pixel_col!=0&&i_pixel_col!=1;
				wr_addr <= i_pixel_col - 2;
			end
			if (i_valid_dbuf) begin
				// first col
				o_y_buf <= conv_result;
				if (wr_en) begin
					mem[wr_addr] <= {wr_upper,wr_lower};
				end
				// second col
				dep_window[0][0] <= dep_window[0][1] + products_buf[0][1];
				dep_window[1][0] <= dep_window[1][1] + products_buf[1][1];
				dep_window[2][0] <= dep_window[2][1] + products_buf[2][1];
				// third col
				dep_window[0][1] <= (rd_en_c1?rd_upper:'0) + products_buf[0][2];
				dep_window[1][1] <= (rd_en_c1?rd_lower:'0) + products_buf[1][2];
				dep_window[2][1] <= products_buf[2][2];
				// from memory
				{rd_upper, rd_lower} <= mem[rd_addr];
			end
		end
	end
end

assign o_valid = o_valid_buf;
assign o_ready = ~o_valid || i_ready;
assign o_y = (0<=o_y_buf&&o_y_buf<256) ? o_y_buf[PIXEL_DATAW-1:0] : (o_y_buf[RESULT_WIDTH-1]) ? 0 : 255;
// End of your code

endmodule