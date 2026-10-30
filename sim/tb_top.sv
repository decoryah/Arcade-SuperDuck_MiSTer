// Whole-machine bench: sd_core behind sd_mem and a behavioural SDRAM chip, one clock (96 MHz).
// The C++ side preloads the chip (DPI) with the ROM image (through the loader's remap), or pushes it through the loader (dl_*), and can
// preload the RAMs from a MAME state dump (tools/lua/dump_state.lua: <prefix>.{bg,fg,tx,spr,pal1,regs}) with both CPUs held in reset.
// (After the owner's silvmil-mister sim/tb_top.sv.)
`default_nettype none
module tb_top (
    input  logic        clk,
    input  logic        rst,                // the machine (CPUs, sound, renderer)
    input  logic        cpu_hold,           // keep the CPUs in reset
    input  logic        vsnap,              // video RAM snapshot at the start of vertical blank (MAME) / live
    input  logic        init,               // the SDRAM controller

    input  logic        dl_we,
    input  logic [24:0] dl_addr,
    input  logic [7:0]  dl_data,
    output logic        dl_wait,
    output logic        dl_busy,
    output logic        mem_ready,

    input  logic        fl_go,              // +load=fast: sd_fastload reads the image from the DDR3 model below into the loader
    input  logic [24:0] fl_len,
    output logic        fl_done,

    input  logic [15:0] p1p2_in, sys_in, dsw_in,

    output logic        ce_pix,
    output logic        hblank, vblank, hsync, vsync,
    output logic [23:0] rgb,
    output logic signed [13:0] snd_pcm,

    output logic        dbg_ovr, dbg_irq, dbg_halted, dbg_render_busy,
    output logic [23:1] dbg_addr,
    output logic [15:0] dbg_zpc,
    output logic        trc_stb, trc_rw,
    output logic [15:0] trc_data,
    output logic [1:0]  trc_be
);
    wire  [15:0] dram_dq;
    wire  [12:0] dram_a;
    wire  [1:0]  dram_ba;
    wire         dram_dqml, dram_dqmh, dram_ncs, dram_nras, dram_ncas, dram_nwe, dram_cke, dram_clk;

    logic        p_req, t_req, s_req, pcm_req;
    logic [17:4] p_addr;
    logic [24:1] t_addr, s_addr;
    logic [19:0] pcm_addr;
    logic        p_wr, t_wr, s_wr, p_done, t_done, s_done, pcm_ack;
    logic [2:0]  p_idx, t_idx;
    logic [1:0]  s_idx;
    logic [15:0] p_data, t_data, s_data;
    logic [7:0]  pcm_q;
    logic        zr_we;
    logic [14:0] zr_addr;
    logic [7:0]  zr_data;
    logic [13:0] cr_addr;
    logic [15:0] cr_data;

    // the fast load (SuperDuck.sv): its bytes go into the loader's input as the HPS's do
    logic        fl_we;
    logic [24:0] fl_addr;
    logic  [7:0] fl_data;
    logic        ddr_busy, ddr_rd, ddr_dready;
    logic  [7:0] ddr_burst;
    logic [28:0] ddr_addr;
    logic [63:0] ddr_dout;
    sd_fastload u_fl (
        .clk(clk), .rst(init), .go(fl_go), .abort(1'b0), .len(fl_len), .done(fl_done), .busy(),
        .dl_we(fl_we), .dl_addr(fl_addr), .dl_data(fl_data), .dl_wait(dl_wait),
        .DDRAM_BUSY(ddr_busy), .DDRAM_BURSTCNT(ddr_burst), .DDRAM_ADDR(ddr_addr), .DDRAM_DOUT(ddr_dout),
        .DDRAM_DOUT_READY(ddr_dready), .DDRAM_RD(ddr_rd)
    );

    // a DDR3 model (Avalon-MM slave): busy at random and while a burst is going out; the beats of a burst after 20 clocks, with gaps;
    // the data from the image (tb_main.cpp tb_ddr_beat: the image at byte 0x32000000)
    import "DPI-C" function longint tb_ddr_beat(input int beat);
    logic [28:0] dm_addr;
    logic  [7:0] dm_left = 8'd0;
    logic  [5:0] dm_lat;
    logic [15:0] lfsr = 16'hACE1;
    logic        rnd_busy = 1'b0;
    assign ddr_busy = rnd_busy || (dm_left != 8'd0);
    always_ff @(posedge clk) begin
        lfsr       <= {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};
        rnd_busy   <= lfsr[3] & lfsr[7];
        ddr_dready <= 1'b0;
        if (ddr_rd && !ddr_busy) begin dm_addr <= ddr_addr; dm_left <= ddr_burst; dm_lat <= 6'd20; end
        else if (dm_left != 8'd0) begin
            if (dm_lat != 6'd0) dm_lat <= dm_lat - 6'd1;
            else if (!lfsr[0] || lfsr[5]) begin
                ddr_dready <= 1'b1; ddr_dout <= tb_ddr_beat(int'(dm_addr)); dm_addr <= dm_addr + 29'd1; dm_left <= dm_left - 8'd1;
            end
        end
    end

    sd_mem u_mem (
        .clk(clk), .clk_sdram(clk), .init(init), .rd_late(1'b0), .ready(mem_ready),
        .dl_we(dl_we | fl_we), .dl_addr(fl_we ? fl_addr : dl_addr), .dl_data(fl_we ? fl_data : dl_data), .dl_wait(dl_wait),
        .dl_busy(dl_busy),
        .zr_we(zr_we), .zr_addr(zr_addr), .zr_data(zr_data),
        .cr_addr(cr_addr), .cr_data(cr_data),
        .p_req(p_req), .p_addr(p_addr), .p_wr(p_wr), .p_idx(p_idx), .p_data(p_data), .p_done(p_done),
        .t_req(t_req), .t_addr(t_addr), .t_wr(t_wr), .t_idx(t_idx), .t_data(t_data), .t_done(t_done),
        .s_req(s_req), .s_addr(s_addr), .s_wr(s_wr), .s_idx(s_idx), .s_data(s_data), .s_done(s_done),
        .pcm_req(pcm_req), .pcm_addr(pcm_addr), .pcm_ack(pcm_ack), .pcm_q(pcm_q),
        .SDRAM_DQ(dram_dq), .SDRAM_A(dram_a), .SDRAM_DQML(dram_dqml), .SDRAM_DQMH(dram_dqmh), .SDRAM_BA(dram_ba),
        .SDRAM_nCS(dram_ncs), .SDRAM_nWE(dram_nwe), .SDRAM_nRAS(dram_nras), .SDRAM_nCAS(dram_ncas),
        .SDRAM_CKE(dram_cke), .SDRAM_CLK(dram_clk)
    );

    sdram_model #(.PHASE_LAG(0), .AW(23)) chip (
        .clk(clk), .dq(dram_dq), .a(dram_a), .ba(dram_ba), .dqml(dram_dqml), .dqmh(dram_dqmh),
        .cs_n(dram_ncs), .ras_n(dram_nras), .cas_n(dram_ncas), .we_n(dram_nwe), .cke(dram_cke)
    );

    sd_core u_core (
        .clk(clk), .rst(rst), .cpu_hold(cpu_hold), .vsnap(vsnap),
        .cache_inval(init | dl_busy),
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
        .dbg_addr(dbg_addr), .dbg_zpc(dbg_zpc),
        .trc_stb(trc_stb), .trc_rw(trc_rw), .trc_data(trc_data), .trc_be(trc_be)
    );

    // ---------------------------------------------------------------- backdoors for the C++ side
    export "DPI-C" function tb_sdram_write;
    function void tb_sdram_write(input int idx, input int w);
        chip.mem[idx[22:0]] = w[15:0];
    endfunction
    export "DPI-C" function tb_sdram_read;
    function int tb_sdram_read(input int idx);
        return {16'd0, chip.mem[idx[22:0]]};
    endfunction
    // the Z80 program and the characters the loader would have captured (a preloaded image does not go through it)
    export "DPI-C" function tb_zrom;
    function void tb_zrom(input int a, input int v);
        u_core.u_sound.u_rom.mem[a[14:0]] = v[7:0];
    endfunction
    export "DPI-C" function tb_zrom_read;
    function int tb_zrom_read(input int a);
        return {24'd0, u_core.u_sound.u_rom.mem[a[14:0]]};
    endfunction
    export "DPI-C" function tb_chr;
    function void tb_chr(input int a, input int v);
        u_mem.u_chars.mem[a[13:0]] = v[15:0];
    endfunction
    export "DPI-C" function tb_chr_read;
    function int tb_chr_read(input int a);
        return {16'd0, u_mem.u_chars.mem[a[13:0]]};
    endfunction

    // ---------------------------------------------------------------- RAMs from a MAME state dump
    // the CPU's RAMs and the renderer's copies of them (so the first picture after the release of the reset is already the state's),
    // the sprite buffer in both halves, the palette MAME converted the frame with (see tools/lua/dump_state.lua)
    string pre;
    logic [15:0] t8k [0:8191];
    logic [15:0] t4k [0:4095];
    logic [15:0] t2k [0:2047];
    logic [15:0] t1k [0:1023];
    `define LOAD64(R, C, T, N, CN) \
        for (int i = 0; i < N; i++) begin \
            case (i & 3) \
                0: begin R.g_lane[0].u.hi[i >> 2] = T[i][15:8]; R.g_lane[0].u.lo[i >> 2] = T[i][7:0]; end \
                1: begin R.g_lane[1].u.hi[i >> 2] = T[i][15:8]; R.g_lane[1].u.lo[i >> 2] = T[i][7:0]; end \
                2: begin R.g_lane[2].u.hi[i >> 2] = T[i][15:8]; R.g_lane[2].u.lo[i >> 2] = T[i][7:0]; end \
                3: begin R.g_lane[3].u.hi[i >> 2] = T[i][15:8]; R.g_lane[3].u.lo[i >> 2] = T[i][7:0]; end \
            endcase \
        end \
        for (int e = 0; e < CN; e++) C.mem[e] = {T[4 * e + 3], T[4 * e + 2], T[4 * e + 1], T[4 * e]};
    initial begin
        if ($value$plusargs("state=%s", pre)) begin
            $readmemh({pre, ".bg"}, t8k);
            `LOAD64(u_core.u_main.u_bg, u_core.u_main.u_bg_d, t8k, 8192, 2048)
            $readmemh({pre, ".fg"}, t8k);
            `LOAD64(u_core.u_main.u_fg, u_core.u_main.u_fg_d, t8k, 8192, 2048)
            $readmemh({pre, ".tx"}, t2k);
            `LOAD64(u_core.u_main.u_tx, u_core.u_main.u_tx_d, t2k, 2048, 256)
            $readmemh({pre, ".spr"}, t4k);
            for (int i = 0; i < 4096; i++) begin
                case (i & 3)
                    0: begin u_core.u_main.u_spr.g_lane[0].u.hi[i >> 2] = t4k[i][15:8]; u_core.u_main.u_spr.g_lane[0].u.lo[i >> 2] = t4k[i][7:0]; end
                    1: begin u_core.u_main.u_spr.g_lane[1].u.hi[i >> 2] = t4k[i][15:8]; u_core.u_main.u_spr.g_lane[1].u.lo[i >> 2] = t4k[i][7:0]; end
                    2: begin u_core.u_main.u_spr.g_lane[2].u.hi[i >> 2] = t4k[i][15:8]; u_core.u_main.u_spr.g_lane[2].u.lo[i >> 2] = t4k[i][7:0]; end
                    3: begin u_core.u_main.u_spr.g_lane[3].u.hi[i >> 2] = t4k[i][15:8]; u_core.u_main.u_spr.g_lane[3].u.lo[i >> 2] = t4k[i][7:0]; end
                endcase
            end
            for (int e = 0; e < 1024; e++) begin
                u_core.u_main.u_sp_d.mem[e]        = {t4k[4 * e + 3][8:0], t4k[4 * e + 2][8:0], t4k[4 * e + 1][5:0], t4k[4 * e][11:0]};
                u_core.u_main.u_sp_d.mem[1024 + e] = {t4k[4 * e + 3][8:0], t4k[4 * e + 2][8:0], t4k[4 * e + 1][5:0], t4k[4 * e][11:0]};
            end
            $readmemh({pre, ".pal1"}, t1k);
            for (int i = 0; i < 1024; i++) begin u_core.u_main.u_pal.hi[i] = t1k[i][15:8]; u_core.u_main.u_pal.lo[i] = t1k[i][7:0]; end
        end
    end
    // the scroll registers are forced by the C++ side after elaboration (an initial block here would race with the module's own
    // power-up values); a value < 0: never written.  The snapshot copies too, so the first picture uses them.
    export "DPI-C" function tb_regs;
    function void tb_regs(input int r0, input int r1, input int r2, input int r3);
        u_core.u_main.raw[0] = r0[15:0]; u_core.u_main.raw[1] = r1[15:0];
        u_core.u_main.raw[2] = r2[15:0]; u_core.u_main.raw[3] = r3[15:0];
        u_core.u_main.wv = {r3 >= 0, r2 >= 0, r1 >= 0, r0 >= 0};
    endfunction
    export "DPI-C" function tb_regs_snap;
    function void tb_regs_snap();
        u_core.u_main.bg_sx_s = u_core.u_main.bg_sx_l; u_core.u_main.bg_sy_s = u_core.u_main.bg_sy_l;
        u_core.u_main.fg_sx_s = u_core.u_main.fg_sx_l; u_core.u_main.fg_sy_s = u_core.u_main.fg_sy_l;
    endfunction
    // the raster's position at the release of the reset
    export "DPI-C" function tb_raster;
    function void tb_raster(input int v, input int h);
        u_core.u_video.vc = v[8:0];
        u_core.u_video.hc = h[8:0];
        u_core.u_video.ph = 4'd0;
    endfunction
endmodule
`default_nettype wire
