`include "camera_mode_keys.vh"
module camera_1080p_top #(parameter KEY_MS_CYCLES=125000, KEY_DEBOUNCE_MS=20, KEY_LONG_MS=800)(input sys_clk,clk_p,clk_n,input [4:0] key_n,input uart_rx,imu_rx,output uart_tx,
 output [7:0] led,
 output mem_rst_n,mem_ck,mem_ck_n,mem_cke,mem_cs_n,mem_ras_n,mem_cas_n,mem_we_n,mem_odt,
 output [14:0] mem_a,output [2:0] mem_ba,inout [3:0] mem_dqs,mem_dqs_n,
 inout [31:0] mem_dq,output [3:0] mem_dm,
 output rstn_out,hd_scl,inout hd_sda,output pix_clk,
 output vs_out,hs_out,de_out,output [7:0] r_out,g_out,b_out,
 input rgmii_rxc,rgmii_rx_ctl,input [3:0] rgmii_rxd,
 output rgmii_txc,rgmii_tx_ctl,output [3:0] rgmii_txd,
 input ov1_pclk,ov1_vsync,ov1_href,input [7:0] ov1_data,
 inout ov1_scl,ov1_sda,output ov1_resetn,ov1_pwdn,ov2_resetn,ov2_pwdn);
wire cpu_resetn,ext_valid,ext_ready;wire [31:0] ext_addr,ext_wdata,ext_rdata;wire [3:0] ext_wstrb;
image_cpu_r22 #(.FIRMWARE_FILE("firmware_camera.hex")) cpu_system(.clk(sys_clk),.key_n(key_n),.uart_rx(1'b1),.uart_tx(uart_tx),.led(led),
 .reset_out(cpu_resetn),.ext_valid(ext_valid),.ext_addr(ext_addr),.ext_wdata(ext_wdata),
 .ext_wstrb(ext_wstrb),.ext_ready(ext_ready),.ext_rdata(ext_rdata));
wire locked,cfg_clk;reg [15:0] cfg_delay=0;
camera_pll pll_gen_clk(.clkin1(sys_clk),.clkout0(pix_clk),.lock(locked));
cfg_pll cfg_pll_inst(.clkin1(sys_clk),.clkout0(cfg_clk),.lock());
always @(posedge cfg_clk)if(!locked || !key_n[0])cfg_delay<=0;else if(cfg_delay<16'h2710)cfg_delay<=cfg_delay+1;
assign rstn_out=(cfg_delay==16'h2710);
wire init_over;
hdmi_tx_config video_config(.clk(cfg_clk),.rst_n(rstn_out),.init_over(init_over),.iic_scl(hd_scl),.iic_sda(hd_sda));
wire core_clk,ddr_init_done,pll_lock,clk_125Mhz,phy_pll_lock,gpll_lock,rst_gpll_lock,ddrphy_cpd_lock;
wire core_resetn,pix_resetn;
reset_release cr(.clk(core_clk),.arstn(cpu_resetn && ddr_init_done),.resetn(core_resetn));
reset_release pr(.clk(pix_clk),.arstn(cpu_resetn && locked),.resetn(pix_resetn));
wire [27:0] axi_awaddr,axi_araddr;wire [3:0] axi_awuser_id,axi_awlen,axi_aruser_id,axi_arlen;
wire axi_awvalid,axi_awready,axi_wready,axi_arvalid,axi_arready,axi_rvalid,axi_rlast,axi_wusero_last;
wire [3:0] axi_wusero_id,axi_rid;wire [255:0] axi_wdata,axi_rdata;wire [31:0] axi_wstrb;
wire axi_wvalid;
GTP_INBUFGDS #(
    .IOSTANDARD("DEFAULT"),
    .TERM_DIFF("ON")
) u_gtp (
    .O(clk_125Mhz), // OUTPUT  
    .I(clk_p), // INPUT  
    .IB(clk_n) // INPUT  
);

//ddr    
        ddr3_test u_ddr3_test_h (
             .ref_clk                   (clk_125Mhz            ),
             .resetn                    (rstn_out           ),// input
             .ddr_init_done             (ddr_init_done      ),// output

             .pll_lock                  (pll_lock           ),// output

             .core_clk                  (core_clk),                                  // output

             .phy_pll_lock              (phy_pll_lock),                          // output
             .gpll_lock                 (gpll_lock),                                // output
             .rst_gpll_lock             (rst_gpll_lock),                        // output
             .ddrphy_cpd_lock           (ddrphy_cpd_lock),                    // output
             //.ddr_init_done             (ddr_init_done),                        // output


             .axi_awaddr                (axi_awaddr         ),// input [27:0]
             .axi_awuser_ap             (1'b0               ),// input
             .axi_awuser_id             (axi_awuser_id      ),// input [3:0]
             .axi_awlen                 (axi_awlen          ),// input [3:0]
             .axi_awready               (axi_awready        ),// output
             .axi_awvalid               (axi_awvalid        ),// input
             .axi_wdata                 (axi_wdata          ),
             .axi_wstrb                 (axi_wstrb          ),// input [31:0]
             .axi_wready                (axi_wready         ),// output
             .axi_wusero_id             (                   ),// output [3:0]
             .axi_wusero_last           (axi_wusero_last    ),// output
             .axi_araddr                (axi_araddr         ),// input [27:0]
             .axi_aruser_ap             (1'b0               ),// input
             .axi_aruser_id             (axi_aruser_id      ),// input [3:0]
             .axi_arlen                 (axi_arlen          ),// input [3:0]
             .axi_arready               (axi_arready        ),// output
             .axi_arvalid               (axi_arvalid        ),// input
             .axi_rdata                 (axi_rdata          ),// output [255:0]
             .axi_rid                   (axi_rid            ),// output [3:0]
             .axi_rlast                 (axi_rlast          ),// output
             .axi_rvalid                (axi_rvalid         ),// output

             .apb_clk                   (1'b0               ),// input
             .apb_rst_n                 (1'b1               ),// input
             .apb_sel                   (1'b0               ),// input
             .apb_enable                (1'b0               ),// input
             .apb_addr                  (8'b0               ),// input [7:0]
             .apb_write                 (1'b0               ),// input
             .apb_ready                 (                   ), // output
             .apb_wdata                 (16'b0              ),// input [15:0]
             .apb_rdata                 (                   ),// output [15:0]
//             .apb_int                   (                   ),// output

             .mem_rst_n                 (mem_rst_n          ),// output
             .mem_ck                    (mem_ck             ),// output
             .mem_ck_n                  (mem_ck_n           ),// output
             .mem_cke                   (mem_cke            ),// output
             .mem_cs_n                  (mem_cs_n           ),// output
             .mem_ras_n                 (mem_ras_n          ),// output
             .mem_cas_n                 (mem_cas_n          ),// output
             .mem_we_n                  (mem_we_n           ),// output
             .mem_odt                   (mem_odt            ),// output
             .mem_a                     (mem_a              ),// output [14:0]
             .mem_ba                    (mem_ba             ),// output [2:0]
             .mem_dqs                   (mem_dqs            ),// inout [3:0]
             .mem_dqs_n                 (mem_dqs_n          ),// inout [3:0]
             .mem_dq                    (mem_dq             ),// inout [31:0]
             .mem_dm                    (mem_dm             ),// output [3:0]
             //debug

  .dbg_gate_start(1'b0),                      // input
  .dbg_cpd_start(1'b0),                        // input
  .dbg_ddrphy_rst_n(1'b1),                  // input
  .dbg_gpll_scan_rst(1'b0),                // input
  .samp_position_dyn_adj(1'b0),        // input
  .init_samp_position_even(32'd0),    // input [31:0]
  .init_samp_position_odd(32'd0),      // input [31:0]
  .wrcal_position_dyn_adj(1'b0),      // input
  .init_wrcal_position(32'd0),            // input [31:0]
  .force_read_clk_ctrl(1'b0),            // input
  .init_slip_step(16'd0),                      // input [15:0]
  .init_read_clk_ctrl(12'd0),              // input [11:0]
  .debug_calib_ctrl(),                  // output [33:0]
  .dbg_slice_status(),                  // output [67:0]
  .dbg_slice_state(),                    // output [87:0]
  .debug_data(),                              // output [275:0]
  .dbg_dll_upd_state(),                // output [1:0]
  .debug_gpll_dps_phase(),          // output [8:0]
  .dbg_rst_dps_state(),                // output [2:0]
  .dbg_tran_err_rst_cnt(),          // output [5:0]
  .dbg_ddrphy_init_fail(),          // output
  .debug_cpd_offset_adj(1'b0),          // input
  .debug_cpd_offset_dir(1'b0),          // input
  .debug_cpd_offset(10'd0),                  // input [9:0]
  .debug_dps_cnt_dir0(),              // output [9:0]
  .debug_dps_cnt_dir1(),              // output [9:0]
  .ck_dly_en(1'b0),                                // input
  .init_ck_dly_step(8'h0),                  // input [7:0]
  .ck_dly_set_bin(),                      // output [7:0]
  .align_error(),                            // output
  .debug_rst_state(),                    // output [3:0]
  .debug_cpd_state()                     // output [3:0]
       );



wire ddr_sel=ext_valid&&ext_addr>=32'h10000000&&ext_addr<32'h18000000;
wire ctrl_sel=ext_valid&&ext_addr>=32'hb000&&ext_addr<32'hb800;
wire mb_sel=ext_valid&&((ext_addr>=32'h9000&&ext_addr<32'h9040)||(ext_addr>=32'h9800&&ext_addr<32'ha800));
wire serial_sel=ext_valid&&ext_addr>=32'hac00&&ext_addr<32'hae00;
wire [31:0] serial_data,imu_clock_us_gray;
camera_eis_serial_r22 serial_control(.clk(sys_clk),.resetn(cpu_resetn),.imu_rx(imu_rx),.host_rx(uart_rx),
 .sel(serial_sel),.address(ext_addr[8:0]),.wdata(ext_wdata),.wstrb(ext_wstrb),.rdata(serial_data),.clock_us_gray(imu_clock_us_gray));
(* ASYNC_REG="TRUE" *) reg [31:0] eis_time_meta=0,eis_time_sync=0;
always @(posedge core_clk or negedge core_resetn)
 if(!core_resetn)begin eis_time_meta<=0;eis_time_sync<=0;end
 else begin eis_time_meta<=imu_clock_us_gray;eis_time_sync<=eis_time_meta;end
wire gpio_sel=ext_valid&&(ext_addr==32'haff0||ext_addr==32'haff4);
reg [4:0] camera_gpio=5'b01000;
(* ASYNC_REG="TRUE" *) reg [1:0] sda_sync=3,scl_sync=3;
always @(posedge sys_clk or negedge cpu_resetn)begin
 if(!cpu_resetn)begin camera_gpio<=5'b01000;sda_sync<=3;scl_sync<=3;end
 else begin
  sda_sync<={sda_sync[0],ov1_sda};scl_sync<={scl_sync[0],ov1_scl};
  if(gpio_sel&&ext_addr==32'haff0&&ext_wstrb[0])camera_gpio<=ext_wdata[4:0];
 end
end
assign ov1_scl=camera_gpio[0]?1'b0:1'bz;
assign ov1_sda=camera_gpio[1]?1'b0:1'bz;
assign ov1_resetn=camera_gpio[2];assign ov1_pwdn=camera_gpio[3];
assign ov2_resetn=1'b0;assign ov2_pwdn=1'b1;
wire cpu_bus_ready,cw_req,cw_ready;wire [31:0] cpu_bus_data,cw_addr,cw_data,cw_result;wire [3:0] cw_strb;
word_cdc bridge(.cpu_clk(sys_clk),.cpu_rstn(cpu_resetn),.cpu_valid(ddr_sel||ctrl_sel),
 .cpu_addr(ctrl_sel?32'hf0000000|{20'b0,ext_addr[11:0]}:ext_addr-32'h10000000),
 .cpu_wdata(ext_wdata),.cpu_wstrb(ext_wstrb),.cpu_ready(cpu_bus_ready),.cpu_rdata(cpu_bus_data),
 .mem_clk(core_clk),.mem_rstn(core_resetn),.mem_valid(cw_req),.mem_addr(cw_addr),.mem_wdata(cw_data),
 .mem_wstrb(cw_strb),.mem_ready(cw_ready),.mem_rdata(cw_result));
wire [3:0] eis_slot_flags,lens_slot_flags,fisheye_slot_flags,rotation_slot_flags;wire display_eis,display_fisheye,display_rotation;
reg [3:0] night_slot_curve[0:3];reg [8:0] night_slot_strength[0:3];
wire snapshot_sel;
wire snap_lock_req,snap_lock_release,snap_locked,snap_req,snap_write,snap_accept,snap_done,snap_valid,snap_take,snap_cpu_ready;
wire [1:0] snap_slot;wire [31:0] snap_frame,snap_addr,snap_cpu_data;wire [15:0] snap_beats;wire [255:0] snap_rdata,snap_wdata;
camera_snapshot_eis_r22 #(.FISHEYE_ENABLE(1),.ROTATION_ENABLE(1)) snapshot(.clk(core_clk),.resetn(core_resetn),.cpu_sel(cw_req&&snapshot_sel),.cpu_addr(cw_addr[11:0]),.cpu_wdata(cw_data),.cpu_wstrb(cw_strb),
 .cpu_ready(snap_cpu_ready),.cpu_rdata(snap_cpu_data),.lock_request(snap_lock_req),.lock_release(snap_lock_release),.locked(snap_locked),.locked_slot(snap_slot),.locked_frame(snap_frame),.locked_eis(eis_slot_flags[snap_slot]),.locked_lens(lens_slot_flags[snap_slot]),.locked_fisheye(fisheye_slot_flags[snap_slot]),.locked_rotation(rotation_slot_flags[snap_slot]),.locked_night_curve(night_slot_curve[snap_slot]),.locked_night_strength(night_slot_strength[snap_slot]),
 .req(snap_req),.write(snap_write),.addr(snap_addr),.beats(snap_beats),.accept(snap_accept),.rdata(snap_rdata),.rvalid(snap_valid),.mem_done(snap_done),.wdata(snap_wdata),.take(snap_take));
wire mb_ready;wire [31:0] mb_data;wire [7:0] rx_delay_step,net_rx_data,tx_byte;
wire [31:0] net_rx_diag,net_tx_diag,net_state_diag,net_head0_diag,net_head1_diag;
(* ASYNC_REG="TRUE" *) reg [159:0] net_diag_meta=0,net_diag_sync=0;
always @(posedge sys_clk or negedge cpu_resetn)
 if(!cpu_resetn)begin net_diag_meta<=0;net_diag_sync<=0;end
 else begin net_diag_meta<={net_rx_diag,net_tx_diag,net_state_diag,net_head0_diag,net_head1_diag};net_diag_sync<=net_diag_meta;end
wire net_diag_sel=ext_addr>=32'h9020&&ext_addr<=32'h9034;
wire [31:0] net_diag_data=ext_addr==32'h9020 ? net_diag_sync[159:128]:
 ext_addr==32'h9024 ? net_diag_sync[127:96]:ext_addr==32'h9028 ? net_diag_sync[95:64]:
 ext_addr==32'h902c ? net_diag_sync[63:32]:ext_addr==32'h9030 ? net_diag_sync[31:0]:32'h4e443136;
wire net_clk,net_resetn,net_lock,rx_valid,tx_req,tx_done;wire [15:0] rx_length,tx_length;wire [10:0] tx_index;
camera_snapshot_network net(.rx_delay_step(rx_delay_step),.resetn(cpu_resetn),.rgmii_rxc(rgmii_rxc),.rgmii_rx_ctl(rgmii_rx_ctl),.rgmii_rxd(rgmii_rxd),
 .rgmii_txc(rgmii_txc),.rgmii_tx_ctl(rgmii_tx_ctl),.rgmii_txd(rgmii_txd),.phy_rstn(),.net_clk(net_clk),.net_resetn(net_resetn),.net_lock(net_lock),
 .rx_valid(rx_valid),.rx_data(net_rx_data),.rx_length(rx_length),.ack_req(tx_req),.tx_length(tx_length),.tx_index(tx_index),.tx_byte(tx_byte),.ack_done(tx_done),
 .diag_rx_gray(net_rx_diag),.diag_tx_gray(net_tx_diag),.diag_state(net_state_diag),.diag_head0(net_head0_diag),.diag_head1(net_head1_diag));
snapshot_mailbox mailbox(.cpu_clk(sys_clk),.cpu_rstn(cpu_resetn),.sel(mb_sel),.addr(ext_addr),.wdata(ext_wdata),.wstrb(ext_wstrb),.ready(mb_ready),.rdata(mb_data),.rx_delay_step(rx_delay_step),
 .net_clk(net_clk),.net_rstn(net_resetn),.rx_valid(rx_valid),.rx_data(net_rx_data),.rx_length(rx_length),.tx_req(tx_req),.tx_length(tx_length),.tx_index(tx_index),.tx_byte(tx_byte),.tx_done(tx_done),.net_lock(net_lock));
wire ctrl=cw_addr[31:28]==4'hf;
assign snapshot_sel=ctrl&&((cw_addr[11:0]>=12'h100&&cw_addr[11:0]<12'h180)||cw_addr[11:0]>=12'h400);
wire eis_ctrl=ctrl&&cw_addr[11:8]==4'h2;
wire legacy_ctrl=ctrl&&!snapshot_sel&&!eis_ctrl;
reg map_ready=0;
always @(posedge core_clk or negedge core_resetn)begin
 if(!core_resetn)map_ready<=0;
 else if(cw_req&&legacy_ctrl&&cw_strb[0]&&cw_addr[7:0]==0&&cw_data[0])map_ready<=1;
end
wire vs_i,hs_i,de_i;wire [11:0] act_x,act_y;
// R5 1920x1080p60: 2200 x 1125 at 148.5MHz; repeat complete ~30fps frames.
sync_vg #(.X_BITS(12),.Y_BITS(12),.V_TOTAL(1125),.V_FP(4),.V_BP(36),.V_SYNC(5),.V_ACT(1080),
 .H_TOTAL(2200),.H_FP(88),.H_BP(148),.H_SYNC(44),.H_ACT(1920)) timing(
 .clk(pix_clk),.rstn(pix_resetn),.vs_out(vs_i),.hs_out(hs_i),.de_out(de_i),.x_act(act_x),.y_act(act_y));
reg [2:0] vs_sync=0;
always @(posedge core_clk or negedge core_resetn)if(!core_resetn)vs_sync<=0;else vs_sync<={vs_sync[1:0],vs_i};
// Count the actual 1080p timing frames independently of unique image updates.
reg [31:0] hdmi_frames=0;
always @(posedge core_clk or negedge core_resetn)
 if(!core_resetn)hdmi_frames<=0;
 else if(vs_sync[1]&&!vs_sync[2])hdmi_frames<=hdmi_frames+1;
wire cam_clk,input_resetn,camera_medium_clk,delayed_pclk;
// R10 RAW84: bypass programmable PCLK delay; both paths see the same raw clock.
assign delayed_pclk=ov1_pclk;
// Multi-region vertical clock keeps capture logic in the IO-side clock column,
// reducing the skew between the IO sampler and its fabric bridge.
GTP_CLKBUFM camera_clock(.CLKIN(delayed_pclk),.CLKOUT(camera_medium_clk));
GTP_CLKBUFR camera_region_clock(.CLKIN(camera_medium_clk),.CLKOUT(cam_clk));
reset_release ir(.clk(cam_clk),.arstn(core_resetn&&camera_gpio[4]),.resetn(input_resetn));
// v7 0x4740=0x00: opposite PCLK polarity, HREF high during valid bytes,
// VS high during frame blank. Register the entire DVP bus together.
// Falling IO sample -> rising regional bridge -> rising regional register.
wire camera_io_clk;
GTP_IOCLKBUF #(.GATE_EN("FALSE")) camera_io_clock(.CLKIN(delayed_pclk),.CLKOUT(camera_io_clk),.DI(1'b0));
wire divided_pclk,probe_clk,probe_resetn;
wire [23:0] probe_ticks256;
GTP_IOCLKDIV_E2 #(.DIV_FACTOR("2")) camera_clock_divider(.CLKIN(ov1_pclk),.CLKDIVOUT(divided_pclk),.CE(1'b1),.RST_N(core_resetn&&camera_gpio[4]));
GTP_CLKBUFG camera_probe_clock(.CLKIN(divided_pclk),.CLKOUT(probe_clk));
reset_release clock_probe_release(.clk(probe_clk),.arstn(core_resetn&&camera_gpio[4]),.resetn(probe_resetn));
camera_clock_probe clock_probe(.half_clk(probe_clk),.half_resetn(probe_resetn),.clk(core_clk),.resetn(core_resetn),.ticks256(probe_ticks256));
wire [9:0] sampled_dvp;
camera_dvp_input input_sampler(.io_clk(camera_io_clk),.clk(cam_clk),
 .pins({ov1_vsync,ov1_href,ov1_data}),.data(sampled_dvp));
wire [9:0] qualified_dvp;wire [15:0] vs_glitch_gray,href_glitch_gray;
camera_dvp_qualifier #(.N(16)) input_qualifier(.clk(cam_clk),.resetn(input_resetn),.raw(sampled_dvp),
 .qualified(qualified_dvp),.vs_glitch_gray(vs_glitch_gray),.href_glitch_gray(href_glitch_gray));
wire rx_vs=qualified_dvp[9],rx_href=qualified_dvp[8];wire [7:0] rx_data=qualified_dvp[7:0];
// Passive monitor remains active before acquisition qualifies a frame.
wire [23:0] dvp_ticks256;
wire [15:0] dvp_vs_edges,dvp_href_edges;
wire [12:0] dvp_last_line;
wire [2:0] dvp_levels;
camera_dvp_monitor dvp_monitor(.pclk(cam_clk),.p_resetn(input_resetn),.vs(sampled_dvp[9]),.href(sampled_dvp[8]),
 .clk(core_clk),.resetn(core_resetn),.ticks256(dvp_ticks256),.vs_edges(dvp_vs_edges),
 .href_edges(dvp_href_edges),.last_line_bytes(dvp_last_line),.levels(dvp_levels));
wire [15:0] pin_high,pin_period,pin_href_edges,pin_vs_edges;
wire pin_high_valid,pin_period_valid;
camera_pin_monitor pin_monitor(.clk(core_clk),.resetn(core_resetn),.href(ov1_href),.vs(ov1_vsync),
 .last_high(pin_high),.last_period(pin_period),.href_edges(pin_href_edges),.vs_edges(pin_vs_edges),
 .high_valid(pin_high_valid),.period_valid(pin_period_valid));
wire pattern_active;
(* ASYNC_REG="TRUE" *) reg pattern_meta=1,pattern_sync=1;
always @(posedge core_clk or negedge core_resetn)
 if(!core_resetn)begin pattern_meta<=1;pattern_sync<=1;end
 else begin pattern_meta<=pattern_active;pattern_sync<=pattern_meta;end
wire [31:0] camera_frame_gray;
(* ASYNC_REG="TRUE" *) reg [31:0] fg1=0,fg2=0;
always @(posedge core_clk or negedge core_resetn)begin
 if(!core_resetn)begin fg1<=0;fg2<=0;end
 else begin fg1<=camera_frame_gray;fg2<=fg1;end
end
function [31:0] ungray;input [31:0] g;integer k;
 begin ungray[31]=g[31];for(k=30;k>=0;k=k-1)ungray[k]=ungray[k+1]^g[k];end
endfunction
wire rgb_vs,rgb_de,raw_bad;wire [15:0] rgb_pixel;wire [23:0] rgb_full;
// Configuration is written by the CPU before acquisition and locked on enable.
reg [1:0] denoise_config=0;
wire denoise_history_valid;wire [31:0] denoise_fused,denoise_pixels,denoise_frames;
always @(posedge core_clk or negedge core_resetn)
 if(!core_resetn)denoise_config<=0;
 else if(cw_req&&legacy_ctrl&&cw_strb[0]&&cw_addr[7:0]==180&&!map_ready)
  denoise_config<=cw_data[1:0];
// Keep the original falling-IO/regional DVP sampler and demosaic unchanged.
// Transfer RGB pixels/control transitions coherently; empty FIFO cycles are clock
// enables, not false HREF edges. Large row RAMs live on global core_clk.
wire filter_resetn;
reset_release filter_release(.clk(core_clk),.arstn(core_resetn&&camera_gpio[4]),.resetn(filter_resetn));
wire denoise_requested,denoise_frame_start,night_requested;
reg [7:0] mode_request=0;
assign denoise_requested=mode_request[2];
assign night_requested=mode_request[3];
wire [7:0] key_mode_toggle;
camera_mode_keys #(.MS_CYCLES(KEY_MS_CYCLES),.DEBOUNCE_MS(KEY_DEBOUNCE_MS),.LONG_MS(KEY_LONG_MS)) mode_keys(
 .clk(core_clk),.resetn(core_resetn),.key_n({key_n[4],key_n[3],key_n[1],key_n[2]}),.toggle(key_mode_toggle));
wire host_mode_write=cw_req&&legacy_ctrl&&(&cw_strb)&&cw_addr[7:0]==228&&cw_data[31:8]==0;
reg [7:0] next_mode;
always @* begin
 next_mode=host_mode_write ? {cw_data[7],cw_data[6],(cw_data[5]&&!cw_data[7]),cw_data[4:1],(cw_data[0]&&!cw_data[6])} : mode_request;
 // A coincident key gesture applies after the host write. Toggle OFF does not
 // enable its mutually exclusive peer. Other bits and all parameters survive.
 if(key_mode_toggle[0])begin next_mode[0]=!next_mode[0];if(next_mode[0])next_mode[6]=0;end
 if(key_mode_toggle[6])begin next_mode[6]=!next_mode[6];if(next_mode[6])next_mode[0]=0;end
 if(key_mode_toggle[7])begin next_mode[7]=!next_mode[7];if(next_mode[7])next_mode[5]=0;end
 if(key_mode_toggle[5])begin next_mode[5]=!next_mode[5];if(next_mode[5])next_mode[7]=0;end
 next_mode[3]=next_mode[3]^key_mode_toggle[3];next_mode[4]=next_mode[4]^key_mode_toggle[4];
 next_mode[2]=next_mode[2]^key_mode_toggle[2];next_mode[1]=next_mode[1]^key_mode_toggle[1];
end
always @(posedge core_clk or negedge core_resetn)
 if(!core_resetn)mode_request<=0;
 else mode_request<=next_mode;
reg denoise_active=0;
reg [8:0] night_strength=256,denoise_strength=256,ghe_strength=256;
reg [8:0] frame_night_strength=256,frame_denoise_strength=256;
reg frame_night_enabled=0,frame_ghe_enabled=0;reg [8:0] frame_ghe_strength=256;

always @(posedge core_clk or negedge core_resetn)
 if(!core_resetn)begin night_strength<=256;denoise_strength<=256;ghe_strength<=256;end
 else if(cw_req&&legacy_ctrl&&(&cw_strb))begin
  if(cw_addr[7:0]==216&&cw_data<=256)night_strength<=cw_data[8:0];
  if(cw_addr[7:0]==220&&cw_data<=256)denoise_strength<=cw_data[8:0];
  if(cw_addr[7:0]==236&&cw_data<=256)ghe_strength<=cw_data[8:0];
 end
always @(posedge core_clk or negedge filter_resetn)
 if(!filter_resetn)begin frame_night_strength<=256;frame_denoise_strength<=256;frame_night_enabled<=0;frame_ghe_enabled<=0;frame_ghe_strength<=256;end
 else if(denoise_frame_start)begin frame_night_strength<=night_strength;frame_denoise_strength<=denoise_strength;frame_night_enabled<=night_requested;frame_ghe_enabled<=mode_request[4];frame_ghe_strength<=ghe_strength;end
always @(posedge core_clk or negedge filter_resetn)
 if(!filter_resetn)denoise_active<=0;
 else if(denoise_frame_start)denoise_active<=denoise_requested;
// Host and board keys share one mode register; KEY0 is system reset.
wire night_stats_valid;wire [3:0] night_curve,night_target;
wire [31:0] night_frames,night_sum;
reg night_seen_grant=0;
integer night_i;
wire spatial_enable=denoise_active&&denoise_config[0];
wire temporal_enable=denoise_active&&denoise_config[1];
wire [26:0] raw_cdc_data;wire raw_cdc_full,raw_cdc_empty;wire [9:0] raw_cdc_count;
// Store pixels and all control transitions, not repeated blank clocks.
// A dropped token invalidates its frame until an accepted VS boundary. The
// lifetime overflow diagnostic must never permanently poison later frames.
reg raw_de_d=0,raw_vs_d=0,raw_bad_d=0,raw_frame_loss=0;
wire raw_cdc_push=input_resetn&&(rgb_de||raw_de_d||rgb_vs||raw_vs_d||(raw_bad!=raw_bad_d));
video_async_fifo #(.WIDTH(27),.ABITS(9)) raw_rgb_cdc(
 .wclk(cam_clk),.wrstn(input_resetn),.push(raw_cdc_push),.din({rgb_vs,rgb_de,raw_bad||raw_frame_loss,rgb_full}),.full(raw_cdc_full),
 .rclk(core_clk),.rrstn(filter_resetn),.pop(!raw_cdc_empty),.dout(raw_cdc_data),.empty(raw_cdc_empty),.count(raw_cdc_count));
reg raw_cdc_overflow=0;
always @(posedge cam_clk or negedge input_resetn)
 if(!input_resetn)begin
  raw_cdc_overflow<=0;raw_de_d<=0;raw_vs_d<=0;raw_bad_d<=0;raw_frame_loss<=0;
 end else begin
  raw_de_d<=rgb_de;raw_vs_d<=rgb_vs;raw_bad_d<=raw_bad;
  if(raw_cdc_push&&raw_cdc_full)begin raw_cdc_overflow<=1;raw_frame_loss<=1;end
  else if(raw_cdc_push&&rgb_vs&&!raw_vs_d)raw_frame_loss<=0;
 end
(* ASYNC_REG="TRUE" *) reg raw_overflow_meta=0,raw_overflow_sync=0;
always @(posedge core_clk or negedge filter_resetn)
 if(!filter_resetn)begin raw_overflow_meta<=0;raw_overflow_sync<=0;end
 else begin raw_overflow_meta<=raw_cdc_overflow;raw_overflow_sync<=raw_overflow_meta;end
wire filtered_vs,filtered_de,filtered_bad;wire [15:0] filtered_pixel,original_pixel;
camera_spatial_stream_r21 spatial_denoise(.clk(core_clk),.resetn(filter_resetn),.enable(spatial_enable),.strength(frame_denoise_strength),
 .in_ce(!raw_cdc_empty),.in_vs(raw_cdc_data[26]),.in_de(raw_cdc_data[25]),
 .in_bad(raw_cdc_data[24]),.in_rgb(raw_cdc_data[23:0]),
 .out_vs(filtered_vs),.out_de(filtered_de),.out_bad(filtered_bad),.out_rgb(filtered_pixel),.out_raw(original_pixel),.frame_start(denoise_frame_start));
camera_night_stats night_statistics(.clk(core_clk),.resetn(filter_resetn),
 .in_vs(filtered_vs),.in_de(filtered_de),.in_bad(filtered_bad),.pixel(filtered_pixel),
 .curve(night_curve),.valid(night_stats_valid),.frames(night_frames),.last_sum(night_sum),.target(night_target));
wire ghe_vs,ghe_de,ghe_bad,ghe_active,ghe_ready,ghe_history_change;
wire [15:0] ghe_pixel,ghe_raw;wire [31:0] ghe_frames,ghe_dropped,ghe_updates;
camera_ghe_r21 equalization(.clk(core_clk),.resetn(filter_resetn),.enable(frame_ghe_enabled),.strength(frame_ghe_strength),
 .in_vs(filtered_vs),.in_de(filtered_de),.in_bad(filtered_bad),.pixel(filtered_pixel),.raw_pixel(original_pixel),
 .out_vs(ghe_vs),.out_de(ghe_de),.out_bad(ghe_bad),.result(ghe_pixel),.raw_result(ghe_raw),
 .active(ghe_active),.ready(ghe_ready),.history_clear(ghe_history_change),.frames(ghe_frames),.dropped(ghe_dropped),.updates(ghe_updates));
wire [31:0] raw_good_gray,raw_bad_gray,raw_last_geometry,raw_last_error;
(* ASYNC_REG="TRUE" *) reg [127:0] raw_diag_meta=0,raw_diag_sync=0;
always @(posedge core_clk or negedge core_resetn)
 if(!core_resetn)begin raw_diag_meta<=0;raw_diag_sync<=0;end
 else begin raw_diag_meta<={raw_good_gray,raw_bad_gray,raw_last_geometry,raw_last_error};raw_diag_sync<=raw_diag_meta;end
camera_raw8_rgb demosaic(.clk(cam_clk),.resetn(input_resetn),.vs(rx_vs),.href(rx_href),.raw(rx_data),
 .out_vs(rgb_vs),.out_de(rgb_de),.rgb(rgb_pixel),.rgb888(rgb_full),.bad_frame(raw_bad),
 .good_gray(raw_good_gray),.bad_gray(raw_bad_gray),.diag_last_geometry(raw_last_geometry),.diag_last_error(raw_last_error));
wire cap_request,geometry_ok,cap_fatal,grant_toggle,grant_valid;
wire cap_recovery_hold,manager_recovery_hold,capture_resetn,capture_fifo_resetn,dma_idle;
wire [31:0] recovery_count,recovery_status,recovery_geometry,recovery_pixels,aborted;
wire [3:0] recovery_reason;
reset_release capture_restart_p(.clk(core_clk),.arstn(core_resetn&&camera_gpio[4]&&!cap_recovery_hold),.resetn(capture_resetn));
reset_release capture_restart_r(.clk(core_clk),.arstn(core_resetn&&!cap_recovery_hold),.resetn(capture_fifo_resetn));
wire [3:0] cap_reason,frame_reason;wire [31:0] cap_pixels,cap_geometry,cap_first_geometry;
(* ASYNC_REG="TRUE" *) reg [31:0] glitch_meta=0,glitch_sync=0;
reg [31:0] first_geometry_meta=0,first_geometry_sync=0;
always @(posedge core_clk or negedge core_resetn)begin
 if(!core_resetn)begin glitch_meta<=0;glitch_sync<=0;first_geometry_meta<=0;first_geometry_sync<=0;end
 else begin
  glitch_meta<={vs_glitch_gray,href_glitch_gray};glitch_sync<=glitch_meta;
  first_geometry_meta<=cap_first_geometry;first_geometry_sync<=first_geometry_meta;
 end
end
wire [15:0] filtered_vs_pulses=ungray({16'b0,glitch_sync[31:16]});
wire [15:0] filtered_href_pulses=ungray({16'b0,glitch_sync[15:0]});
reg [67:0] geo_sync_diag1=0,geo_sync_diag2=0;
always @(posedge core_clk or negedge core_resetn)begin
 if(!core_resetn)begin geo_sync_diag1<=0;geo_sync_diag2<=0;end
 else begin geo_sync_diag1<={cap_reason,cap_pixels,cap_geometry};geo_sync_diag2<=geo_sync_diag1;end
end
wire [546:0] cap_head;wire [9:0] cap_count;wire cap_pop,cap_done;
// Keep old temporal history invalid until the first new GHE-configured packet
// is admitted. The previous frame may finish its final DDR write after VS.
reg ghe_history_reset_pending=0;
always @(posedge core_clk or negedge core_resetn)
 if(!core_resetn)ghe_history_reset_pending<=0;
 else if(ghe_history_change)ghe_history_reset_pending<=1;
 else if(cap_pop&&cap_head[533:512]==0)ghe_history_reset_pending<=0;
reg [31:0] cap_beats_written=0;reg [9:0] cap_peak_fifo=0;
always @(posedge core_clk or negedge core_resetn)begin
 if(!core_resetn)begin cap_beats_written<=0;cap_peak_fifo<=0;end
 else begin if(cap_pop)cap_beats_written<=cap_beats_written+1;if(cap_count>cap_peak_fifo)cap_peak_fifo<=cap_count;end
end
wire [1:0] grant_slot,cap_slot,display_slot;
always @(posedge core_clk or negedge core_resetn)
 if(!core_resetn)begin night_seen_grant<=0;for(night_i=0;night_i<4;night_i=night_i+1)begin night_slot_curve[night_i]<=7;night_slot_strength[night_i]<=0;end end
 else begin
  night_seen_grant<=grant_toggle;
  if(grant_toggle!=night_seen_grant&&grant_valid)
   begin night_slot_curve[grant_slot]<=frame_night_enabled&&night_stats_valid?night_curve:4'd7;night_slot_strength[grant_slot]<=frame_night_strength;end
 end

wire eis_sof;wire [1:0] eis_sof_slot;wire [31:0] eis_sof_us,eis_readout_us;
camera_capture_eis_r22 #(.W(1920),.H(1080),.PIXEL_INPUT(1)) capture(.clock_us(ungray(eis_time_sync)),.sof(eis_sof),.sof_slot(eis_sof_slot),.sof_us(eis_sof_us),.readout_us(eis_readout_us),.pclk(core_clk),.prstn(capture_resetn),.stats_resetn(filter_resetn),.vs(ghe_vs),.href(ghe_de),.data(ghe_pixel),.raw_data(ghe_raw),.frame_invalid(ghe_bad),
 .request(cap_request),.geometry_ok(geometry_ok),.grant_toggle(grant_toggle),.grant_valid(grant_valid),.grant_slot(grant_slot),
 .fatal(cap_fatal),.fault_reason(cap_reason),.fault_pixels(cap_pixels),.fault_geometry(cap_geometry),.first_fault_geometry(cap_first_geometry),.frame_gray(camera_frame_gray),
 .head(cap_head),.count(cap_count),.clk(core_clk),.resetn(capture_fifo_resetn),.pop(cap_pop));
camera_recovery recovery(.clk(core_clk),.resetn(core_resetn),.enabled(map_ready),.fault(cap_fatal),
 .reason(geo_sync_diag2[67:64]),.geometry(first_geometry_sync),.pixels(geo_sync_diag2[63:32]),
 .dma_idle(dma_idle),.fifo_count(cap_count),.capture_ready(capture_resetn),.fifo_ready(capture_fifo_resetn),
 .capture_hold(cap_recovery_hold),.manager_hold(manager_recovery_hold),.recoveries(recovery_count),
 .last_geometry(recovery_geometry),.last_pixels(recovery_pixels),.last_reason(recovery_reason),.status(recovery_status));
wire display_valid,display_corrected,fatal;
wire lut_ready,lut_busy,map_req,map_accept,map_dma_done,map_take;wire [31:0] lut_cycles,lut_progress,map_addr;wire [15:0] map_beats;wire [255:0] map_wdata;
wire process_start,process_busy,process_done,process_error;wire [31:0] source_base,result_base,process_cycles,processed,last_process_cycles;
wire remap_req,remap_write,remap_accept,remap_dma_done,remap_valid,remap_take;wire [31:0] remap_addr;wire [15:0] remap_beats;wire [255:0] remap_wdata,shared_rdata;
reg [1:0] view_mode=0;
wire [1:0] view_requested=mode_request[1:0];
always @(posedge core_clk or negedge core_resetn)
 if(!core_resetn)view_mode<=0;
 else if(vs_sync[1]&&!vs_sync[2])view_mode<=view_requested;
camera_map_init #(.PACKED_MAP(1)) map_initializer(.clk(core_clk),.resetn(core_resetn),.start(map_ready&&!lut_ready&&!lut_busy),
 .busy(lut_busy),.ready(lut_ready),.cycles(lut_cycles),.progress(lut_progress),
 .req(map_req),.write(),.addr(map_addr),.beats(map_beats),.accept(map_accept),.wdata(map_wdata),.take(map_take),.mem_done(map_dma_done));
// Both engines share one existing bulk port and run under one manager lease.
wire [31:0] captured,displayed,dropped;
wire process_eis;wire [1:0] process_slot;wire [3:0] eis_config_ready;
wire [895:0] eis_process_config;wire [31:0] eis_cpu_data,eis_fallbacks,eis_rs_fallbacks;
wire static_busy,static_done,static_error,static_req,static_write;
wire [31:0] static_cycles,static_addr;wire [15:0] static_beats;wire [255:0] static_wdata;
wire eis_busy,eis_done,eis_req,eis_write;wire [31:0] eis_cycles,eis_addr;wire [15:0] eis_beats;wire [255:0] eis_wdata;
assign process_busy=static_busy||eis_busy;
assign process_done=static_done||eis_done;
assign process_error=static_error;
assign process_cycles=process_eis?eis_cycles:static_cycles;
assign remap_req=process_eis?eis_req:static_req;
assign remap_write=process_eis?eis_write:static_write;
assign remap_addr=process_eis?eis_addr:static_addr;
assign remap_beats=process_eis?eis_beats:static_beats;
assign remap_wdata=process_eis?eis_wdata:static_wdata;
video_row_remap_r21 #(.MAP_BASE(32'h03000000),.PACKED_MAP(1),.CACHE_ROW_BITS(5)) correction(.clk(core_clk),.resetn(core_resetn),.start(process_start&&!process_eis),.night_curve(night_slot_curve[process_slot]),.night_strength(night_slot_strength[process_slot]),.source_base(source_base),.result_base(result_base),
 .busy(static_busy),.done(static_done),.error(static_error),.cycles(static_cycles),.map_cycles(),.load_cycles(),.pipe_cycles(),.write_cycles(),
 .req(static_req),.write(static_write),.addr(static_addr),.beats(static_beats),.accept(remap_accept&&!process_eis),
 .rdata(shared_rdata),.rvalid(remap_valid&&!process_eis),.mem_done(remap_dma_done&&!process_eis),.wdata(static_wdata),.take(remap_take&&!process_eis));
camera_eis_remap_r22 #(.FISHEYE_ENABLE(1)) shake_remap(.clk(core_clk),.resetn(core_resetn),.start(process_start&&process_eis),.source_base(source_base),.result_base(result_base),.config_words(eis_process_config),
 .night_curve(night_slot_curve[process_slot]),.night_strength(night_slot_strength[process_slot]),
 .busy(eis_busy),.source_done(eis_done),.last_cycles(eis_cycles),.display_valid(),.display_bank(),.completed(),.displayed(),
 .fallbacks(eis_fallbacks),.rs_fallbacks(eis_rs_fallbacks),.display_limited(),.display_compare(),
 .req(eis_req),.write(eis_write),.addr(eis_addr),.beats(eis_beats),.accept(remap_accept&&process_eis),.done(remap_dma_done&&process_eis),.valid(remap_valid&&process_eis),.rdata(shared_rdata),.wdata(eis_wdata),.take(remap_take&&process_eis));
reg eis_seen_grant=0;
always @(posedge core_clk or negedge core_resetn)if(!core_resetn)eis_seen_grant<=0;else eis_seen_grant<=grant_toggle;
camera_eis_jobs_r22 #(.FISHEYE_ENABLE(1),.ROTATION_ENABLE(1)) eis_jobs(.clk(core_clk),.resetn(core_resetn),.grant(grant_toggle!=eis_seen_grant&&grant_valid),.grant_slot(grant_slot),.slot_eis(eis_slot_flags),.slot_lens(lens_slot_flags),.slot_fisheye(fisheye_slot_flags),.slot_rotation(rotation_slot_flags),
 .sof(eis_sof),.sof_slot(eis_sof_slot),.sof_us(eis_sof_us),.readout_us(eis_readout_us),.cap_done(cap_done),.cap_slot(cap_slot),.recover(manager_recovery_hold),
 .cpu_sel(cw_req&&eis_ctrl),.cpu_addr(cw_addr[7:0]),.cpu_data(cw_data),.cpu_strb(cw_strb),.cpu_result(eis_cpu_data),
 .process_slot(process_slot),.process_done(process_done),.processed(processed),.displayed(displayed),.cycles(last_process_cycles),.fallbacks(eis_fallbacks),.rs_fallbacks(eis_rs_fallbacks),.ready(eis_config_ready),.process_config(eis_process_config));

camera_eis_manager_r22 #(.FISHEYE_ENABLE(1),.ROTATION_ENABLE(1)) frames(.clk(core_clk),.resetn(core_resetn),.enabled(map_ready),.lut_ready(lut_ready),.correction_enable(mode_request[0]),.eis_enable(mode_request[5]),.fisheye_enable(mode_request[6]),.rotation_enable(mode_request[7]),.slot_rotation(rotation_slot_flags),.display_rotation(display_rotation),.config_ready(eis_config_ready),.process_slot(process_slot),.process_eis(process_eis),.slot_eis(eis_slot_flags),.slot_lens(lens_slot_flags),.slot_fisheye(fisheye_slot_flags),.display_eis(display_eis),.display_fisheye(display_fisheye),
 .process_start(process_start),.source_base(source_base),.result_base(result_base),.process_busy(process_busy),.process_done(process_done),.process_error(process_error),.process_cycles(process_cycles),.processed(processed),.last_cycles(last_process_cycles),
 .snapshot_request(snap_lock_req),.snapshot_release(snap_lock_release),.snapshot_locked(snap_locked),.snapshot_slot(snap_slot),.snapshot_frame(snap_frame),
 .capture_request(cap_request),.geometry_ok(geometry_ok),.capture_fatal(cap_fatal),.recover(manager_recovery_hold),
 .grant_toggle(grant_toggle),.grant_valid(grant_valid),.grant_slot(grant_slot),.cap_done(cap_done),.cap_slot(cap_slot),
 .display_edge(vs_sync[1]&&!vs_sync[2]),.display_valid(display_valid),.display_slot(display_slot),.display_corrected(display_corrected),
 .captured(captured),.displayed(displayed),.dropped(dropped),.aborted(aborted),.fatal(fatal),.fault_reason(frame_reason));
wire line_req,line_done,line_valid,line_overrun;wire [11:0] line_index;wire [255:0] line_data;
wire [15:0] pixel_data;wire pixel_de;
camera_line_buffer #(.H_NUM(1920),.V_NUM(1080),.DQ_WIDTH(32),.PIX_WIDTH(16),.LINE_ADDR_WIDTH(22),.FRAME_CNT_WIDTH(6),.ADDR_WIDTH(28)) line_buffer(
 .ddr_clk(core_clk),.ddr_rstn(core_resetn),.vout_clk(pix_clk),.rd_fsync(vs_i),.rd_en(de_i),
 .vout_de(pixel_de),.vout_data(pixel_data),.init_done(1'b1),.frame_base(28'b0),
 .ddr_rreq(line_req),.ddr_line_index(line_index),.ddr_raddr(),.ddr_rd_len(),.ddr_rrdy(1'b1),
 .ddr_rdone(line_done),.ddr_rdata(line_data),.ddr_rdata_en(line_valid));
wire disp_req,disp_accept,disp_done,disp_valid;wire [31:0] disp_addr;wire [15:0] disp_beats;wire [255:0] disp_data;
camera_view_reader_eis_r22 splitter(.clk(core_clk),.resetn(core_resetn),.line_req(line_req),.line_index(line_index),
 .mode(view_mode),.display_corrected(display_corrected),.display_valid(display_valid),.display_slot(display_slot),.line_done(line_done),.line_valid(line_valid),.line_data(line_data),
 .req(disp_req),.addr(disp_addr),.beats(disp_beats),.accept(disp_accept),.valid(disp_valid),.done(disp_done),.data(disp_data),.overrun(line_overrun));
wire mem_cpu_ready;wire [31:0] mem_cpu_data;
wire bulk_req,bulk_write,bulk_accept,bulk_done,bulk_valid,bulk_take;wire [31:0] bulk_addr;wire [15:0] bulk_beats;wire [255:0] bulk_wdata;
wire [2:0] bulk_accepts,bulk_valids,bulk_dones,bulk_takes;
camera_engine_arbiter engine_arbiter(.clk(core_clk),.resetn(core_resetn),
 .requests({remap_req,map_req,snap_req}),.writes({remap_write,1'b1,snap_write}),.addresses({remap_addr,map_addr,snap_addr}),.lengths({remap_beats,map_beats,snap_beats}),.payloads({remap_wdata,map_wdata,snap_wdata}),
 .accepts(bulk_accepts),.valids(bulk_valids),.dones(bulk_dones),.takes(bulk_takes),
 .req(bulk_req),.write(bulk_write),.addr(bulk_addr),.beats(bulk_beats),.wdata(bulk_wdata),.accept(bulk_accept),.rvalid(bulk_valid),.done(bulk_done),.take(bulk_take));
assign {remap_accept,map_accept,snap_accept}=bulk_accepts;
assign remap_valid=bulk_valids[2];assign snap_valid=bulk_valids[0];assign snap_rdata=shared_rdata;
assign {remap_dma_done,map_dma_done,snap_done}=bulk_dones;
assign {remap_take,map_take,snap_take}=bulk_takes;
camera_dma_master_r21 #(.CAP_TEMPORAL(1),.HISTORY_IN_CAPTURE(1)) memory_master(.clk(core_clk),.resetn(core_resetn),
 .temporal_enable(temporal_enable),.temporal_strength(frame_denoise_strength),.history_clear(cap_recovery_hold||ghe_history_reset_pending),
 .history_valid(denoise_history_valid),.temporal_fused(denoise_fused),
 .temporal_pixels(denoise_pixels),.history_frames(denoise_frames),
 .cpu_req(cw_req&&!ctrl),.cpu_addr(cw_addr),.cpu_data(cw_data),.cpu_strb(cw_strb),.cpu_ready(mem_cpu_ready),.cpu_result(mem_cpu_data),
 .eng_req(bulk_req),.eng_write(bulk_write),.eng_addr(bulk_addr),.eng_beats(bulk_beats),.eng_accept(bulk_accept),
 .eng_done(bulk_done),.eng_valid(bulk_valid),.eng_rdata(shared_rdata),.eng_wdata(bulk_wdata),.eng_take(bulk_take),
 .disp_req(disp_req),.disp_addr(disp_addr),.disp_beats(disp_beats),.disp_accept(disp_accept),.disp_done(disp_done),.disp_valid(disp_valid),.disp_data(disp_data),
 .cap_head(cap_head),.cap_count(cap_count),.cap_pop(cap_pop),.cap_done(cap_done),.cap_slot(cap_slot),
 .awaddr(axi_awaddr),.awid(axi_awuser_id),.awlen(axi_awlen),.awvalid(axi_awvalid),.awready(axi_awready),
 .araddr(axi_araddr),.arid(axi_aruser_id),.arlen(axi_arlen),.arvalid(axi_arvalid),.arready(axi_arready),
 .wdata(axi_wdata),.wstrb(axi_wstrb),.wready(axi_wready),.rdata(axi_rdata),.rvalid(axi_rvalid),.rlast(axi_rlast),.idle(dma_idle));
reg [1:0] hd_sync=0,geo_sync=0;
always @(posedge core_clk or negedge core_resetn)begin
 if(!core_resetn)begin hd_sync<=0;geo_sync<=0;end
 else begin hd_sync<={hd_sync[0],init_over};geo_sync<={geo_sync[0],geometry_ok};end
end
reg [31:0] control_data;
always @*begin
 control_data=0;
 case(cw_addr[7:0])
  0:control_data={24'b0,line_overrun,fatal,hd_sync[1],geo_sync[1],display_valid,process_busy,map_ready,1'b1};
  4:control_data=captured;8:control_data=processed;12:control_data=displayed;16:control_data=dropped;
  20:control_data=last_process_cycles;24:control_data=32'h07800438;28:control_data=32'h43414d31;
  32:control_data={24'b0,frame_reason,geo_sync_diag2[67:64]};
  36:control_data=geo_sync_diag2[63:32];40:control_data=geo_sync_diag2[31:0];
  44:control_data=cap_beats_written;48:control_data={12'b0,cap_peak_fifo,cap_count};
  72:control_data=ungray(fg2);
  76:control_data={8'b0,dvp_ticks256};
  80:control_data={dvp_vs_edges,dvp_href_edges};
  84:control_data={16'b0,dvp_levels,dvp_last_line};
  88:control_data={16'b0,pin_high};
  92:control_data={16'b0,pin_period};
  96:control_data={pin_vs_edges,pin_href_edges};
  100:control_data={29'b0,pin_period_valid,pin_high_valid,pattern_sync};
  104:control_data=first_geometry_sync;
  108:control_data={filtered_vs_pulses,filtered_href_pulses};
  112:control_data=aborted;116:control_data=recovery_count;120:control_data=recovery_status;
  124:control_data=recovery_geometry;128:control_data=recovery_pixels;
  132:control_data={28'b0,recovery_reason};
  136:control_data=ungray(raw_diag_sync[127:96]);140:control_data=ungray(raw_diag_sync[95:64]);
  144:control_data=raw_diag_sync[63:32];148:control_data=raw_diag_sync[31:0];
  152:control_data={8'b0,probe_ticks256};
  156:control_data={28'b0,process_error,display_corrected,lut_busy,lut_ready};
  160:control_data={28'b0,view_requested,view_mode};
  164:control_data=lut_cycles;168:control_data=lut_progress;
  180:control_data={30'b0,denoise_config};
  184:control_data={25'b0,denoise_active,denoise_requested,raw_overflow_sync,map_ready,denoise_history_valid,(denoise_active?denoise_config:2'b0)};
  188:control_data=denoise_fused;192:control_data=denoise_pixels;196:control_data=denoise_frames;
  200:control_data=32'h52323245; // R22E
  204:control_data={21'b0,night_slot_curve[display_slot],night_target,night_stats_valid,night_requested,(night_slot_curve[display_slot]!=7)};
  208:control_data=night_frames;212:control_data=night_sum;
  216:control_data={23'b0,night_strength};220:control_data={23'b0,denoise_strength};
  224:control_data={7'b0,frame_denoise_strength,7'b0,frame_night_strength};
  228:control_data={25'b0,mode_request};
  232:control_data={24'b0,display_rotation,display_fisheye,display_eis,ghe_active,frame_night_enabled,denoise_active,view_mode[1],(display_corrected&&lens_slot_flags[display_slot])};
  236:control_data={23'b0,ghe_strength};
  240:control_data={29'b0,ghe_ready,ghe_active,mode_request[4]};
  244:control_data=ghe_frames;248:control_data=ghe_dropped;252:control_data=ghe_updates;
  172:control_data=hdmi_frames;176:control_data=32'h52313534; // R15, four frame pairs
 endcase
end
assign cw_ready=eis_ctrl?cw_req:snapshot_sel?snap_cpu_ready:legacy_ctrl?cw_req:mem_cpu_ready;
assign cw_result=eis_ctrl?eis_cpu_data:snapshot_sel?snap_cpu_data:legacy_ctrl?control_data:mem_cpu_data;
// Mode bits select display processing independently. Automatic fallback until a valid frame.
wire base_vs,base_hs,base_de;wire [7:0] base_r,base_g,base_b;
camera_hdmi_output hdmi_output(.clk(pix_clk),.resetn(pix_resetn),.vs(vs_i),.hs(hs_i),.de(de_i),
 .display_valid(display_valid),.force_pattern(1'b0),.pixel_de(pixel_de),.pixel(pixel_data),
 .pattern_active(pattern_active),.vs_out(base_vs),.hs_out(base_hs),.de_out(base_de),
 .r_out(base_r),.g_out(base_g),.b_out(base_b));
camera_night_hdmi_eis_r22 night_hdmi(.clk(pix_clk),.resetn(pix_resetn),
 .slot_curve(night_slot_curve[display_slot]),.slot_strength(night_slot_strength[display_slot]),.view_mode(view_mode),.display_corrected(display_corrected),.pattern_active(pattern_active),
 .vs(base_vs),.hs(base_hs),.de(base_de),.r(base_r),.g(base_g),.b(base_b),
 .vs_out(vs_out),.hs_out(hs_out),.de_out(de_out),.r_out(r_out),.g_out(g_out),.b_out(b_out));

assign ext_ready=serial_sel?1'b1:mb_sel?mb_ready:gpio_sel?1'b1:(ddr_sel||ctrl_sel)?cpu_bus_ready:1'b1;
assign ext_rdata=serial_sel?serial_data:mb_sel?(net_diag_sel?net_diag_data:mb_data):gpio_sel?(ext_addr==32'haff0 ?{27'b0,camera_gpio}:{30'b0,scl_sync[1],sda_sync[1]}):(ddr_sel||ctrl_sel)?cpu_bus_data:32'b0;
endmodule
