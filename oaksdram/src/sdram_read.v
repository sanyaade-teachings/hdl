/*
 Distributed under the MIT license.
 Copyright (c) 2011 Dave McCoy (dave.mccoy@cospandesign.com)

 Permission is hereby granted, free of charge, to any person obtaining a copy of
 this software and associated documentation files (the "Software"), to deal in 
 the Software without restriction, including without limitation the rights to 
 use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies 
 of the Software, and to permit persons to whom the Software is furnished to do 
 so, subject to the following conditions:

 The above copyright notice and this permission notice shall be included in all 
 copies or substantial portions of the Software.

 THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR 
 IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, 
 FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE 
 AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER 
 LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, 
 OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE 
 SOFTWARE.
 */


`timescale 1 ns/100 ps
`include "sdram_include.v"


module sdram_read (
		   rst,
		   //sdram clock
		   clk,

		   reading,
		   command,
		   addr,
		   bank,
		   data_in,
		   data_mask,


		   //sdram controller
		   en,
		   address,
		   ready,
		   auto_refresh,

		   //FIFO
		   fifo_data,
		   fifo_full,
		   fifo_wr
		   );

   input				rst;
   input				clk;
   output reg 				reading;
   output	reg [2:0] 		command;
   output	reg [11:0] 		addr;
   output	reg [1:0] 		bank;
   output [1:0] 			data_mask;
   input [15:0] 			data_in;
   input				auto_refresh;

   //sdram controller
   input				en;
   output				ready;

   //21:20 = Bank		(2)
   //19:08 = Row		(12)
   //07:00 = Column	(8)

   input [21:0] 			address;

   //FIFO
   output	reg [31:0] 		fifo_data;
   input				fifo_full;
   output	reg			fifo_wr;

   //states
   parameter	IDLE				=	8'h0;
   parameter	ACTIVATE			=	8'h1;
   parameter	READ_COMMAND		=	8'h2;
   parameter	READ_TOP_WORD		=	8'h3;
   parameter	READ_BOTTOM_WORD	=	8'h4;
   parameter	PRECHARGE			=	8'h5;
   parameter	FIFO_FULL_WAIT		=	8'h6;
   parameter	RESTART				=	8'h7;

   reg [7:0] 				state;

   wire [1:0] 				r_bank;
   wire [11:0] 				row;
   wire [7:0] 				column;

   reg [7:0] 				delay;

   //temporary FIFO data when the FIFO is full
   reg					lauto_refresh;
   reg					lfifo_full;
   reg					len;
   reg [21:0] 				laddress;
   reg					read_bottom;


   //XXX: data mask is always high
   assign	data_mask	=	2'b00;
   assign	ready		=	((delay == 0) & (state == IDLE));

   assign	r_bank		=	laddress[21:20];
   assign	row			=	laddress[19:8];
   assign	column		=	laddress[7:0];

   //HOW DO i HANDLE A FULL FIFO??
   //introduce wait states, and don't write
   //till the FIFO is not full
   //SHOULD THE AUTO_REFERESH be handled in here?
   //or should the main interrupt me?
   //the auto refresh should happen in here cause
   //then I'll know exactly where it is

   always @ (negedge clk) begin
      if (rst) begin

	 reading <= 0;
	 command			<=	`SDRAM_CMD_NOP; 
	 addr			<=	12'h0;
	 bank			<=	2'h0;

	 fifo_wr			<=	0;

	 state			<=	IDLE;
	 laddress		<=	12'h0;

	 delay			<=	8'h0;

	 lfifo_full		<=	0;
	 lauto_refresh	<=	0;
	 len				<=	0;
	 laddress		<=	22'h0;
      end
      else begin
	 //auto refresh only goes high for one clock cycle,
	 //so capture it
	 if (auto_refresh & en) begin
	    //because en is high it is my responsibility
	    lauto_refresh	<= 1;
	 end
	 fifo_wr		<= 0;
	 if (delay > 0) begin
	    delay <= delay - 1;
	    //during delays always send NOP's
	    command	<=	`SDRAM_CMD_NOP; 
	 end 
	 else begin 
	    case (state)
	      IDLE: begin
		 len	<= en;
		 if (en & ~fifo_full) begin
		    //initiate a read cycle by calling
		    //ACTIVATE function here,
		    //normally this would be issued in the
		    //ACTIVATE state but that would waste a 
		    //clock cycle

		    //store variables into local registers so
		    //I can modify them
		    reading <= 1;
		    laddress	<= address;
		    state		<= ACTIVATE;
		 end
		 else if (lauto_refresh) begin
		    reading <= 0;
		    
		 end
		 else begin
		    state <= IDLE;
		    reading <= 0;
		 end
	      end
	      ACTIVATE: begin
		 $display ("sdram_read: ACTIVATE: %b", `SDRAM_CMD_ACT);
		 command			<=	`SDRAM_CMD_ACT;
		 delay			<=	`T_RCD - 1; 

		 addr			<=	row; 
		 bank			<=	r_bank;

		 state			<=	READ_COMMAND;
	      end
	      READ_COMMAND: begin
		 $display ("sdram_read: READ_COMMAND: %b", `SDRAM_CMD_READ);
		 command			<=	`SDRAM_CMD_READ;
		 state			<=	READ_TOP_WORD;
		 addr			<=	{4'b0000, column};
		 delay			<=	`T_CAS - 1;
		 //delay			<=	`T_CAS;
		 laddress		<= laddress + 2;
	      end
	      READ_TOP_WORD: begin
		 $display ("sdram_read: READ_TOP_WORD");
		 //because the enable can switch inbetween the
		 //read of the top and the bottom I need to remember
		 //the state of the system here
		 len					<= en;
		 state				<= READ_BOTTOM_WORD;
		 //here is where I can issue the next
		 //READ_COMMAND for consecutive reads
		 //lfifo_full			<= fifo_full;
		 //check if this is the end of a column, 
		 //if so I need to activate a new ROW
		 if (en & !fifo_full & !auto_refresh) begin
		    //check if this is the end of a column

		    if (column	== 8'h00) begin
		       $display("sdram_read: reached end of column Issue PRECHARGE: %b", `SDRAM_CMD_PRE);
		       
		       //need to activate a new row to 
		       //start reading from there
		       //close this row with a precharge
		       command	<= `SDRAM_CMD_PRE;
		       addr[10]	<=	1;
		       //							delay		<= `T_RP - 1;

		       //next state will activate a new row
		       //but that's gonna wait until
		       //READ_BOTTOM_WORD is done
		    end
		    else begin
		       //don't need to activate a new row, 
		       //just continue reading
		       //$display ("sdram_read: read command: %b", `SDRAM_CMD_READ);
		       //							command		<= `SDRAM_CMD_READ;
		       command	<=	`SDRAM_CMD_PRE;
		       addr[10]	<=	1;
		       //						delay		<= `T_RP - 1;
		    end
		 end
		 else begin
		    //issue the precharge command here
		    //after reading the next word and then to  
		    $display ("sdram_read: precharge: %b", `SDRAM_CMD_PRE);
		    command		<= `SDRAM_CMD_PRE;
		    addr[10]	<=	1;
		    //the bank select is already selected right now
		    //						delay		<= `T_RP - 1;
		 end
	      end
	      READ_BOTTOM_WORD: begin
		 $display ("sdram_read: READ_BOTTOM_WORD");
		 //tell the FIFO that we have new data
		 //if were not waiting for the fifo then
		 //write the data to the FIFO immediately
		 command		<= `SDRAM_CMD_NOP;
		 //if the FIFO isn't full and were 
		 //not done continue on with our reading
		 if (!read_bottom) begin
		    if (!fifo_full) begin
		       fifo_wr	<= 1;
		    end

		    if (len & !fifo_full & !lauto_refresh) begin
		       //check if this is the end of a column
		       //						if (column	== 8'h00) begin
		       //next state will activate a new row
		       //							$display ("sdram_read: go to ACTIVATE state");
		       state	<= IDLE;
		       //						end
		       //						else begin
		       //the command for read has already
		       //been issued by the time I reach
		       //READ_TOP_WORD we'll be ready for
		       //the next incomming word
		       //							state	<= READ_TOP_WORD;
		       //							laddress	<=	laddress + 2;
		       //						end
		    end
		    else if (fifo_full) begin
		       //the fifo was full, 
		       //wait for until we see the all clear
		       //from the FIFO
		       state		<= FIFO_FULL_WAIT; 
		    end
		    else if (lauto_refresh) begin
		       state		<= 	RESTART;
		       $display("sdram_read: auto refresh command: %b", `SDRAM_CMD_AR);
		       command		<=	`SDRAM_CMD_AR;
		       delay		<=	`T_RFC - 1;
		    end
		    else begin
		       state		<= IDLE;
		    end
		 end

	      end
	      FIFO_FULL_WAIT: begin
		 $display ("sdram_read: FIFO full waiting...");
		 //	fifo_full	<= fifo_full;
		 if (!en) begin
		    state	<= IDLE;
		 end
		 else if (!fifo_full) begin
		    $display ("\tdone waiting for the FIFO");
		    $display ("\tstart a new read cycle");
		    fifo_wr		<= 1;
		    state		<= ACTIVATE;
		 end
	      end
	      RESTART: begin
		 if (!en) begin
		    state	<= IDLE;
		 end
		 else begin
		    state	<= ACTIVATE;
		 end
	      end
	      default: begin
		 $display ("sdram_read: got to an unknown state");
		 state	<= IDLE;
	      end
	    endcase
	 end
      end
   end


   reg	en_read;
   always @ (posedge clk) begin
      if (rst) begin
	 fifo_data	<=	0;
	 read_bottom	<=	0;
	 en_read		<=	1;
	 fifo_data[31:0]	<=	32'hFFFFFFFF;


      end
      else begin
	 if (state == READ_BOTTOM_WORD && en_read && !read_bottom) begin
	    fifo_data[31:16]	<=	data_in;
	    read_bottom			<=	1;
	    en_read	<=	0;
	 end
	 else if (read_bottom) begin
	    fifo_data[15:0]		<=	data_in;
	    read_bottom			<=	0;
	 end
	 if (state != READ_BOTTOM_WORD) begin
	    en_read	<=	1;
	 end
      end
   end
endmodule
