module hdmi_tx_config(input clk,rst_n,output init_over,iic_scl,inout iic_sda);
wire [7:0] device_id,data_in,data_out;wire trig,wr,busy,byte_over;wire [15:0] address;
ms7210_ctl tx(.clk(clk),.rstn(rst_n),.init_over(init_over),.device_id(device_id),.iic_trig(trig),
 .w_r(wr),.addr(address),.data_in(data_in),.busy(busy),.data_out(data_out),.byte_over(byte_over));
wire sda_in,sda_out,sda_en;
iic_dri #(.CLK_FRE(27'd10000000),.IIC_FREQ(20'd400000),.T_WR(10'd1),.ADDR_BYTE(2'd2),.LEN_WIDTH(8'd3),.DATA_BYTE(2'd1)) driver(
 .clk(clk),.rstn(rst_n),.device_id(device_id),.pluse(trig),.w_r(wr),.byte_len(4'd1),
 .addr(address),.data_in(data_in),.busy(busy),.byte_over(byte_over),.data_out(data_out),
 .scl(iic_scl),.sda_in(sda_in),.sda_out(sda_out),.sda_out_en(sda_en));
assign iic_sda=sda_en?sda_out:1'bz;assign sda_in=iic_sda;
endmodule
