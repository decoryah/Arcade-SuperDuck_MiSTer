//============================================================================
//
//  Comad "Super Duck" (1992) -- MAME's capcom/supduck.cpp -- for MiSTer.
//
//  Written for MiSTer from MAME 0.289's driver (src/mame/capcom/supduck.cpp) and its sprite chip (src/mame/capcom/tigeroad_spr.cpp).
//  The 68000 is fx68k (Jorge Cwik), the Z80 is TV80 (Guy Hutchison), the OKI M6295 jt6295 (Jose Tejada); the platform layer (SDRAM
//  controller, loader, fast load, CRT adjust, Scale) is the owner's Silver Millennium core's (silvmil-mister).
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 3 of the License, or (at your option)
//  any later version.
//
//  This program is distributed in the hope that it will be useful, but WITHOUT
//  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
//  FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
//  more details.
//
//============================================================================

module emu
(
	`include "sys/emu_ports.vh"
);

///////// Default values for ports not used in this core /////////

assign ADC_BUS  = 'Z;
assign USER_OUT = '1;
assign {UART_RTS, UART_TXD, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;

assign VGA_F1 = 0;
assign VGA_SCALER  = 0;
assign VGA_DISABLE = 0;
assign HDMI_FREEZE = 0;
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = 0;

assign AUDIO_S   = 1;       // signed samples
assign AUDIO_MIX = 0;

assign LED_DISK  = 0;
assign LED_POWER = 0;
assign BUTTONS   = 0;

assign DDRAM_WE   = 1'b0;
assign DDRAM_DIN  = 64'd0;
assign DDRAM_BE   = 8'hFF;

//////////////////////////////////////////////////////////////////

wire [127:0] status;
wire         clk_sys;            // 96 MHz: the machine (enables for the 68000, the Z80, the OKI and the dots)
wire   [1:0] buttons;
wire         forced_scandoubler;
wire         direct_video;
wire  [21:0] gamma_bus;

// Aspect ratio and Scale. Scale's integer modes give the HDMI scaler the exact size in pixels (bit 12 set) for the picture, worked
// out by the framework's video_scale_int (in video_freak) from the picture's size and the aspect ratio.  The menu's order is the
// owner's (as in the Silver Millennium / Monster Maulers / Violent Storm cores); video_scale_int's SCALE input counts 0 Normal,
// 1 V-Integer, 2 Narrower HV-Integer, 3 HV-Integer+ (wider), 4 HV-Integer
reg   [2:0] scale_sel;
always @* case (status[34:32])
	3'd1:    scale_sel = 3'd1;   // V-Integer
	3'd2:    scale_sel = 3'd4;   // HV-Integer
	3'd3:    scale_sel = 3'd2;   // Narrower HV-Integer
	3'd4:    scale_sel = 3'd3;   // HV-Integer+
	default: scale_sel = 3'd0;   // Normal
endcase
// Full Screen is ARX = ARY = 0 ("fill"), which has no proportions for the integer rule to size the width from: it sizes the height
// from the width instead and asks for more rows than the screen has. With an integer Scale the screen's own proportions stand in for
// it, so the picture is a whole-number size in the screen's aspect
wire  [1:0] ar     = status[122:121];
wire        fs_int = (ar == 2'd1) && (scale_sel != 3'd0) && (HDMI_WIDTH != 12'd0) && (HDMI_HEIGHT != 12'd0);
reg  [11:0] arx, ary;
always @(posedge clk_sys) begin
	arx <= fs_int ? HDMI_WIDTH  : (!ar) ? 12'd4 : {10'd0, ar - 2'd1};
	ary <= fs_int ? HDMI_HEIGHT : (!ar) ? 12'd3 : 12'd0;
end

`include "build_id.v"
localparam CONF_STR = {
	"A.SUPDUCK;;",
	"-;",
	"O[122:121],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
	"O[34:32],Scale,Normal,V-Integer,HV-Integer,Narrower HV-Integer,HV-Integer+;",
	"O[5:3],Scandoubler Fx,None,HQ2x,CRT 25%,CRT 50%,CRT 75%;",
	"P1,CRT Adjust;",
	"P1O[101],CRT Adjust,Off,On;",
	"H3P1O[100:96],H-Size,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	"H3P1O[85:79],H-Position,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,+16,+17,+18,+19,+20,+21,+22,+23,+24,+25,+26,+27,+28,+29,+30,+31,+32,+33,+34,+35,+36,+37,+38,+39,+40,+41,+42,+43,+44,+45,+46,+47,+48,-48,-47,-46,-45,-44,-43,-42,-41,-40,-39,-38,-37,-36,-35,-34,-33,-32,-31,-30,-29,-28,-27,-26,-25,-24,-23,-22,-21,-20,-19,-18,-17,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	"H3P1O[78:74],V-Shift,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,+16,+17,+18,+19,+20,+21,+22,+23,-8,-7,-6,-5,-4,-3,-2,-1;",
	"-;",
	"DIP;",
	"-;",
	"O[9:8],Volume,Normal,-6 dB,-12 dB,-18 dB;",
	"O[10],Video RAM,At vblank (MAME),Live (less lag);",
	"-;",
	"R0,Reset;",
	"J1,Button 1,Button 2,Start,Coin;",
	"jn,A,B,Start,Select;",
	"V,v",`BUILD_DATE
};

////////////////////   CLOCKS   ///////////////////

wire clk_sdram;         // 96 MHz, shifted: the SDRAM chip's clock pin
wire pll_locked;

pll pll
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(clk_sys),
	.outclk_1(clk_sdram),
	.outclk_2(),
	.locked(pll_locked)
);

///////////////////////////////////////////////////

wire         ioctl_download;
wire         ioctl_wr;
wire  [15:0] ioctl_index;
wire  [26:0] ioctl_addr;
wire   [7:0] ioctl_dout;
wire         ioctl_wait;

wire  [31:0] joystick_0, joystick_1;
wire  [10:0] ps2_key;

hps_io #(.CONF_STR(CONF_STR)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),
	.EXT_BUS(),

	.buttons(buttons),
	.status(status),
	// H3: the CRT Adjust values only while it is On
	.status_menumask({12'd0, ~status[101], 3'b000}),
	.forced_scandoubler(forced_scandoubler),
	.direct_video(direct_video),
	.gamma_bus(gamma_bus),

	.ioctl_download(ioctl_download),
	.ioctl_index(ioctl_index),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_wait(ioctl_wait),

	.joystick_0(joystick_0),
	.joystick_1(joystick_1),
	.ps2_key(ps2_key)
);

///////////////////////   DIP SWITCHES (from the MRA)   ///////////////////////

// ioctl index 254: byte 0 = DIP-A (MAME's DSW port bits 7:0), byte 1 = DIP-B (bits 15:8); a 1 is "off" (the switches are active low).
// Until the MRA's bytes arrive: MAME's defaults (BF, FF).
reg [7:0] sw[2];
initial begin sw[0] = 8'hBF; sw[1] = 8'hFF; end
always @(posedge clk_sys) begin
	if (ioctl_wr && (ioctl_index[7:0] == 8'd254) && !ioctl_addr[26:1]) sw[ioctl_addr[0]] <= ioctl_dout;
end

///////////////////////   CONTROLS   ///////////////////////

// keyboard: 1/2 start, 5/6 coin (MAME's defaults)
reg key_start1, key_start2, key_coin1, key_coin2;
always @(posedge clk_sys) begin
	reg old_stb;
	old_stb <= ps2_key[10];
	if (old_stb != ps2_key[10]) begin
		case (ps2_key[8:0])
			9'h016: key_start1  <= ps2_key[9];
			9'h01E: key_start2  <= ps2_key[9];
			9'h02E: key_coin1   <= ps2_key[9];
			9'h036: key_coin2   <= ps2_key[9];
			default: ;
		endcase
	end
end

// The joysticks are 4-way (MAME's PORT_4WAY), filtered as MAME's digital_joystick::frame_update does it: opposite directions cancel;
// on a diagonal the direction that has just been added wins (a stick rolled from left to up-left goes up), and a diagonal reached
// at once from the centre (or from the other diagonal) gives the horizontal one.  {up, down, left, right}
function automatic [3:0] lockout(input [3:0] d);
	lockout = {(d[3] & d[2]) ? 2'b00 : d[3:2], (d[1] & d[0]) ? 2'b00 : d[1:0]};
endfunction
reg [3:0] j4_1, j4_2, jp_1, jp_2;
always @(posedge clk_sys) begin
	reg [3:0] c1, c2, n1, n2;
	c1 = lockout({joystick_0[3], joystick_0[2], joystick_0[1], joystick_0[0]});
	c2 = lockout({joystick_1[3], joystick_1[2], joystick_1[1], joystick_1[0]});
	if (c1 != jp_1) begin
		n1 = c1;
		if ((|n1[3:2]) && (|n1[1:0])) n1 = n1 ^ (n1 & jp_1);
		if ((|n1[3:2]) && (|n1[1:0])) n1 = {2'b00, n1[1:0]};
		j4_1 <= n1;
		jp_1 <= c1;
	end
	if (c2 != jp_2) begin
		n2 = c2;
		if ((|n2[3:2]) && (|n2[1:0])) n2 = n2 ^ (n2 & jp_2);
		if ((|n2[3:2]) && (|n2[1:0])) n2 = {2'b00, n2[1:0]};
		j4_2 <= n2;
		jp_2 <= c2;
	end
end

// joystick bits: 0 right, 1 left, 2 down, 3 up, 4 button 1, 5 button 2, 6 start, 7 coin (the MRA's <buttons> list names them).
// MAME's INPUT_PORTS give each player four buttons; the game reads only buttons 1 and 2 (tools/probe.py, docs/status.md), so only
// those are mapped and the other two stay released.  No service button: the test mode is the OSD's Service Mode DIP switch and a
// reset, as in MAME.
wire j1_u = j4_1[3], j1_d = j4_1[2], j1_l = j4_1[1], j1_r = j4_1[0], j1_b1 = joystick_0[4], j1_b2 = joystick_0[5];
wire j2_u = j4_2[3], j2_d = j4_2[2], j2_l = j4_2[1], j2_r = j4_2[0], j2_b1 = joystick_1[4], j2_b2 = joystick_1[5];
wire start1 = joystick_0[6] | key_start1, coin1 = joystick_0[7] | key_coin1;
wire start2 = joystick_1[6] | key_start2, coin2 = joystick_1[7] | key_coin2;

// the board's inputs, active low (MAME's INPUT_PORTS supduck):
//   P1_P2:  bit 0 right, 1 left, 2 down, 3 up, 4..7 buttons 1..4; bits 8..15 the same for player 2
//   SYSTEM: bit 8 start 1, 9 start 2, 10 the vertical blank (sd_main puts it in), 13 service, 14 coin 1, 15 coin 2; the rest high
//   DSW:    DIP-A / DIP-B from the MRA
wire [15:0] p1p2_in = ~{2'b00, j2_b2, j2_b1, j2_u, j2_d, j2_l, j2_r, 2'b00, j1_b2, j1_b1, j1_u, j1_d, j1_l, j1_r};
wire [15:0] sys_in  = ~{coin2, coin1, 4'b0000, start2, start1, 8'h00};
wire [15:0] dsw_in  = {sw[1], sw[0]};

///////////////////////   MEMORY   ///////////////////////

// the ROM image: MRA index 0
wire        rom_dl = ioctl_download && (ioctl_index[7:0] == 8'd0);

wire        mem_init = ~pll_locked | RESET;
wire        mem_ready;
wire        dl_busy;

// Fast load (rtl/sd_fastload.sv): with address= on the MRA's index-0 <rom>, Main_MiSTer puts the image into the DDR3 and sends a
// download without data that starts with ioctl_addr = the image's length (an ordinary one starts at 0; hps_io loads ioctl_addr
// before it raises ioctl_download). When it ends, the image is read back and pushed through the loader; the machine is held until
// the last word is in the SDRAM. An older Main_MiSTer ignores address= and sends the image the ordinary way.
reg         rom_dl_d = 1'b0;
reg         fast_dl = 1'b0;
reg  [24:0] fast_len;
wire        fl_done, fl_we;
wire [24:0] fl_addr;
wire  [7:0] fl_data;
always @(posedge clk_sys) begin
	rom_dl_d <= rom_dl;
	if (rom_dl && !rom_dl_d) begin fast_dl <= (ioctl_addr != 27'd0); fast_len <= ioctl_addr[24:0]; end
	else if (fl_done) fast_dl <= 1'b0;
end
wire        fl_go = fast_dl && rom_dl_d && !rom_dl;              // the empty download has ended

// the loader's byte input: the HPS's bytes, or the fast load's
wire        dl_we   = (rom_dl && ioctl_wr) | fl_we;
wire [24:0] dl_addr = fl_we ? fl_addr : ioctl_addr[24:0];
wire  [7:0] dl_data = fl_we ? fl_data : ioctl_dout;
wire        dl_wait;
assign      ioctl_wait = dl_wait;

// The DDR3's only user is the fast load (reads, while the machine is held)
sd_fastload u_fastload
(
	.clk(clk_sys), .rst(mem_init), .go(fl_go), .abort(rom_dl), .len(fast_len), .done(fl_done), .busy(),
	.dl_we(fl_we), .dl_addr(fl_addr), .dl_data(fl_data), .dl_wait(dl_wait),
	.DDRAM_BUSY(DDRAM_BUSY), .DDRAM_BURSTCNT(DDRAM_BURSTCNT), .DDRAM_ADDR(DDRAM_ADDR), .DDRAM_DOUT(DDRAM_DOUT),
	.DDRAM_DOUT_READY(DDRAM_DOUT_READY), .DDRAM_RD(DDRAM_RD)
);
assign DDRAM_CLK = clk_sys;

wire        p_req, t_req, s_req, pcm_req;
wire [17:4] p_addr;
wire [24:1] t_addr, s_addr;
wire [19:0] pcm_addr;
wire        p_wr, t_wr, s_wr, p_done, t_done, s_done, pcm_ack;
wire  [2:0] p_idx, t_idx;
wire  [1:0] s_idx;
wire [15:0] p_data, t_data, s_data;
wire  [7:0] pcm_q;
wire        zr_we;
wire [14:0] zr_addr;
wire  [7:0] zr_data;
wire [13:0] cr_addr;
wire [15:0] cr_data;

// rd_late = 0: read data at READ+3, the capture the SDRAM clock's PLL phase is built for (rtl/pll/pll_0002.v).  The owner's earlier
// cores offer "Late" (READ+4) in the OSD; it never helped on a board, so it is not offered here.
sd_mem u_mem
(
	.clk(clk_sys), .clk_sdram(clk_sdram), .init(mem_init), .rd_late(1'b0), .ready(mem_ready),
	.dl_we(dl_we), .dl_addr(dl_addr), .dl_data(dl_data), .dl_wait(dl_wait), .dl_busy(dl_busy),
	.zr_we(zr_we), .zr_addr(zr_addr), .zr_data(zr_data),
	.cr_addr(cr_addr), .cr_data(cr_data),
	.p_req(p_req), .p_addr(p_addr), .p_wr(p_wr), .p_idx(p_idx), .p_data(p_data), .p_done(p_done),
	.t_req(t_req), .t_addr(t_addr), .t_wr(t_wr), .t_idx(t_idx), .t_data(t_data), .t_done(t_done),
	.s_req(s_req), .s_addr(s_addr), .s_wr(s_wr), .s_idx(s_idx), .s_data(s_data), .s_done(s_done),
	.pcm_req(pcm_req), .pcm_addr(pcm_addr), .pcm_ack(pcm_ack), .pcm_q(pcm_q),
	.SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A), .SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH), .SDRAM_BA(SDRAM_BA),
	.SDRAM_nCS(SDRAM_nCS), .SDRAM_nWE(SDRAM_nWE), .SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS),
	.SDRAM_CKE(SDRAM_CKE), .SDRAM_CLK(SDRAM_CLK)
);

///////////////////////   THE MACHINE   ///////////////////////

wire        reset_sw = RESET | status[0] | buttons[1];
// the machine is held while a ROM loads (a fast load too) and until the memory is up; registered, it fans out to the whole core
reg         mc_rst = 1'b1;
always @(posedge clk_sys) mc_rst <= reset_sw | rom_dl | fast_dl | dl_busy | ~mem_ready | ~pll_locked;

wire        ce_pix, hblank, vblank, hsync, vsync;
wire [23:0] rgb;
wire signed [13:0] snd_pcm;
wire        dbg_ovr, dbg_irq, dbg_halted, dbg_render_busy;

sd_core u_core
(
	.clk(clk_sys), .rst(mc_rst), .cpu_hold(1'b0), .vsnap(~status[10]),
	.cache_inval(rom_dl | fast_dl | mem_init),
	.p_req(p_req), .p_addr(p_addr), .p_wr(p_wr), .p_idx(p_idx), .p_data(p_data), .p_done(p_done),
	.t_req(t_req), .t_addr(t_addr), .t_wr(t_wr), .t_idx(t_idx), .t_data(t_data), .t_done(t_done),
	.s_req(s_req), .s_addr(s_addr), .s_wr(s_wr), .s_idx(s_idx), .s_data(s_data), .s_done(s_done),
	.pcm_req(pcm_req), .pcm_addr(pcm_addr), .pcm_ack(pcm_ack), .pcm_q(pcm_q),
	.zr_we(zr_we), .zr_addr(zr_addr), .zr_data(zr_data),
	.cr_addr(cr_addr), .cr_data(cr_data),
	.p1p2_in(p1p2_in), .sys_in(sys_in), .dsw_in(dsw_in),
	.ce_pix(ce_pix), .hblank(hblank), .vblank(vblank), .hsync(hsync), .vsync(vsync), .rgb(rgb),
	.snd_pcm(snd_pcm),
	.dbg_ovr(dbg_ovr), .dbg_irq(dbg_irq), .dbg_halted(dbg_halted), .dbg_render_busy(dbg_render_busy),
	.dbg_addr(), .dbg_zpc(), .trc_stb(), .trc_rw(), .trc_data(), .trc_be()
);

///////////////////////   AUDIO   ///////////////////////

// MAME routes the OKI to the one speaker at 1.0.  The OKI's output in MAME's units is 16 times jt6295's 14-bit sum of the voices
// (measured on the owner's ohmygod-mister core), clipped to 16 bits as MAME does.  "Normal" is that level, the others 6 / 12 / 18 dB
// lower (the shift comes before the clip, so the lower settings do not clip).
reg signed [15:0] aud;
wire signed [17:0] aud_sum = $signed({snd_pcm, 4'b0000});
wire signed [17:0] aud_sh  = aud_sum >>> status[9:8];
always @(posedge clk_sys) begin
	if (aud_sh > 18'sd32767)       aud <= 16'sh7FFF;
	else if (aud_sh < -18'sd32768) aud <= 16'sh8000;
	else                           aud <= aud_sh[15:0];
end
assign AUDIO_L = aud;
assign AUDIO_R = aud;

///////////////////////   VIDEO   ///////////////////////

// CRT Adjust (OSD page of the same name): H-Size, H-Position and V-Shift of the picture, through rmonic79's line buffer
// (rtl/sd_crtadj.sv). It is off while the scandoubler is in use (Scandoubler Fx, MiSTer.ini's forced_scandoubler): its output's
// horizontal blank includes the vertical one (the module is given the combined blank), but sys/scandoubler.v takes its line timing
// from HBlank's edges and needs them on every line, the vertical blank's too -- with a blank held through the vertical blank the
// doubled picture has no vertical sync and stands still (found on the owner's Monster Maulers core). Without CRT Adjust the core's
// HBlank (rtl/sd_video.sv) is the horizontal blank alone, as the scandoubler wants. CRT Adjust is for 15 kHz anyway.
wire        crt_sd = (|status[5:3]) | forced_scandoubler;
wire        crt_on = status[101] & ~crt_sd;
wire        ca_ce, ca_hblank, ca_vblank, ca_hs, ca_vs, ca_de_osd;
wire [23:0] vid_rgb;
wire [23:0] rgb_in = mc_rst ? 24'd0 : rgb;
sd_crtadj u_crtadj
(
	.clk(clk_sys), .i_on(crt_on), .i_hsize_f(status[100:96]), .i_hpos_f(status[85:79]), .i_vshift_f(status[78:74]), .i_pdot(5'd16),
	.i_ce(ce_pix), .i_hblank(hblank), .i_vblank(vblank), .i_hs(hsync), .i_vs(vsync), .i_rgb(rgb_in),
	.o_ce(ca_ce), .o_hblank(ca_hblank), .o_vblank(ca_vblank), .o_hs(ca_hs), .o_vs(ca_vs), .o_rgb(vid_rgb), .o_de_osd(ca_de_osd)
);
wire        vga_de_mix;

arcade_video #(.WIDTH(320), .DW(24)) arcade_video
(
	.*,
	.clk_video(clk_sys),
	.ce_pix(ca_ce),
	.RGB_in(vid_rgb),
	.HBlank(ca_hblank),
	.VBlank(ca_vblank),
	.HSync(ca_hs),
	.VSync(ca_vs),
	.fx(status[5:3]),
	.VGA_DE(vga_de_mix)
);

// Scale (see the top): video_freak measures the stream (scandoubler and CRT Adjust included) and works out the size for the
// picture.  Crop is unused.
video_freak video_freak
(
	.CLK_VIDEO(CLK_VIDEO),
	.CE_PIXEL(CE_PIXEL),
	.VGA_VS(VGA_VS),
	.HDMI_WIDTH(HDMI_WIDTH),
	.HDMI_HEIGHT(HDMI_HEIGHT),
	.VGA_DE(VGA_DE),
	.VIDEO_ARX(VIDEO_ARX),
	.VIDEO_ARY(VIDEO_ARY),
	.VGA_DE_IN(crt_on ? ca_de_osd : vga_de_mix),
	.ARX(arx),
	.ARY(ary),
	.CROP_SIZE(12'd0),
	.CROP_OFF(5'd0),
	.SCALE(scale_sel)
);

///////////////////////   LEDs   ///////////////////////

// user LED: on while the machine is held (a ROM loading), blinks once per frame while it runs, blinks fast once a line has not
// been finished in time (since the reset)
reg        led_vbl_toggle, led_ovr;
reg [23:0] led_cnt;
always @(posedge clk_sys) begin
	led_cnt <= led_cnt + 24'd1;
	if (dbg_irq) led_vbl_toggle <= ~led_vbl_toggle;
	if (mc_rst) led_ovr <= 1'b0;
	else if (dbg_ovr) led_ovr <= 1'b1;
end
assign LED_USER = mc_rst ? 1'b1 : led_ovr ? led_cnt[22] : led_vbl_toggle;

endmodule
