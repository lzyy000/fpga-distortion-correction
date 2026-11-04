// 100Pro+ / PG2L100H-6FBG676. Native memory bus, 27 MHz, 64 KiB BRAM, split code/data address windows.
module image_cpu_r22 #(parameter RESET_BITS=16, parameter CLK_HZ=27000000, parameter FIRMWARE_FILE="firmware.hex")(
 input wire clk, input wire [4:0] key_n, input wire uart_rx,
 output wire uart_tx, output wire [7:0] led,
 output wire reset_out, output wire ext_valid, output wire [31:0] ext_addr,ext_wdata,
 output wire [3:0] ext_wstrb, input wire ext_ready, input wire [31:0] ext_rdata
);
 reg [1:0] reset_sync=0;
 always @(posedge clk or negedge key_n[0])
   if (!key_n[0]) reset_sync<=0;
   else reset_sync<={reset_sync[0],1'b1};
 reg [RESET_BITS-1:0] reset_count=0;
 always @(posedge clk)
   if (!reset_sync[1]) reset_count<=0;
   else if (!(&reset_count)) reset_count<=reset_count+1'b1;
 wire resetn=&reset_count;
 assign reset_out=resetn;
 reg rx_meta=1, rx_sync=1;
 reg [4:0] key_meta=5'b11111, key_sync=5'b11111;
 always @(posedge clk) begin
   rx_meta<=uart_rx; rx_sync<=rx_meta;
   key_meta<=key_n; key_sync<=key_meta;
 end
 wire mem_valid,mem_instr,mem_ready,trap;
 wire [31:0] mem_addr,mem_wdata,mem_rdata;
 wire [3:0] mem_wstrb;
 picorv32 #(.STACKADDR(32'h2000),.PROGADDR_RESET(32'h10000),
   .BARREL_SHIFTER(1),.COMPRESSED_ISA(1),.ENABLE_MUL(1),.ENABLE_DIV(1),
   .ENABLE_IRQ(0)) cpu(.clk(clk),.resetn(resetn),.trap(trap),
   .mem_valid(mem_valid),.mem_instr(mem_instr),.mem_ready(mem_ready),
   .mem_addr(mem_addr),.mem_wdata(mem_wdata),.mem_wstrb(mem_wstrb),
   .mem_rdata(mem_rdata),.irq(32'b0));
 reg [31:0] memory[0:16383] /* synthesis syn_ramstyle = "block_ram" */;
 initial $readmemh(FIRMWARE_FILE,memory);
 wire code_sel=mem_addr>=32'h10000&&mem_addr<32'h1e000;
 wire ram_sel=mem_valid && (mem_addr<32'h2000||code_sel);
 wire [13:0] ram_index=code_sel ? 14'd2048+((mem_addr-32'h10000)>>2) : {3'b0,mem_addr[12:2]};
 reg ram_ready=0; reg [31:0] ram_rdata;
 always @(posedge clk) begin
   ram_ready<=0;
   if (!resetn) ram_ready<=0;
   else if (ram_sel && !ram_ready) begin
     ram_ready<=1;
     ram_rdata<=memory[ram_index];
     if(mem_wstrb[0]) memory[ram_index][7:0]<=mem_wdata[7:0];
     if(mem_wstrb[1]) memory[ram_index][15:8]<=mem_wdata[15:8];
     if(mem_wstrb[2]) memory[ram_index][23:16]<=mem_wdata[23:16];
     if(mem_wstrb[3]) memory[ram_index][31:24]<=mem_wdata[31:24];
   end
 end
 wire div_sel=mem_valid && mem_addr[31:2]==(32'h8000>>2);
 wire dat_sel=mem_valid && mem_addr[31:2]==(32'h8010>>2);
 wire led_sel=mem_valid && mem_addr[31:2]==(32'h8020>>2);
 wire key_sel=mem_valid && mem_addr[31:2]==(32'h8030>>2);
 wire time_sel=mem_valid && mem_addr[31:2]==(32'h8040>>2);
 wire id_sel=mem_valid && mem_addr[31:2]==(32'h8050>>2);
 wire fault_sel=mem_valid && mem_addr[31:2]==(32'h8060>>2);
 wire ext_sel=mem_valid && ((mem_addr>=32'h9000 && mem_addr<32'hb800) || (mem_addr>=32'h10000000 && mem_addr<32'h18000000));
 assign ext_valid=ext_sel; assign ext_addr=mem_addr; assign ext_wdata=mem_wdata; assign ext_wstrb=mem_wstrb;
 wire tx_sel=mem_valid&&mem_addr[31:2]==(32'h8070>>2);
 wire tx_busy,tx_active;wire [9:0] tx_pending;
 wire mapped=tx_sel|ext_sel|ram_sel|div_sel|dat_sel|led_sel|key_sel|time_sel|id_sel|fault_sel;
 wire dat_wait;
 wire [31:0] div_data,uart_data;
 uart_tx_buffered uart(.clk(clk),.resetn(resetn),.ser_tx(uart_tx),.ser_rx(rx_sync),
   .reg_div_we(div_sel ? mem_wstrb : 4'b0),.reg_div_di(mem_wdata),.reg_div_do(div_data),
   .reg_dat_we(dat_sel && |mem_wstrb),.reg_dat_re(dat_sel && !(|mem_wstrb)),
   .reg_dat_di(mem_wdata),.reg_dat_do(uart_data),.reg_dat_wait(dat_wait),.tx_busy(tx_busy),.tx_active(tx_active),.tx_pending(tx_pending));
 reg [7:0] gpio_led=0;
 reg [31:0] fault_addr=0;
 always @(posedge clk) begin
   if(!resetn) begin gpio_led<=0; fault_addr<=0; end
   else begin
     if(led_sel && mem_wstrb[0]) gpio_led<=mem_wdata[7:0];
     if(mem_valid && !mapped) fault_addr<=mem_addr;
   end
 end
 // trap is exceptional: LED7 only, until KEY0 reset. Normal operation uses all 8 LEDs.
 assign led=trap ? 8'h80 : gpio_led;
 localparam MS_CYCLES=CLK_HZ/1000;
 reg [31:0] ms_count=0;
 localparam MS_DIV_BITS=(MS_CYCLES>1) ? $clog2(MS_CYCLES) : 1;
 reg [MS_DIV_BITS-1:0] ms_div=0;
 always @(posedge clk) begin
   if(!resetn) begin ms_count<=0; ms_div<=0; end
   else if(ms_div==MS_CYCLES-1) begin ms_div<=0; ms_count<=ms_count+1'b1; end
   else ms_div<=ms_div+1'b1;
 end
 assign mem_ready=ram_ready|div_sel|(dat_sel && !dat_wait)|led_sel|key_sel|
                  time_sel|id_sel|fault_sel|tx_sel|(ext_sel && ext_ready)|(mem_valid && !mapped);
 assign mem_rdata=ram_ready ? ram_rdata :
   div_sel ? div_data : dat_sel ? uart_data : led_sel ? {24'b0,gpio_led} :
   key_sel ? {27'b0,key_sync} : time_sel ? ms_count :
   tx_sel ? {20'b0,tx_pending,tx_active,tx_busy} : id_sel ? 32'h52563332 : fault_sel ? fault_addr : ext_sel ? ext_rdata : 32'b0;
endmodule
