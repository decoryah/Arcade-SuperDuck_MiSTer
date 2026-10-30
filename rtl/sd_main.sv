// Comad "Super Duck" board (MAME src/mame/capcom/supduck.cpp, supduck_state::main_map): the 68000 side.
//
// The 68000 (fx68k, 8 MHz), its memory map, the RAMs the video reads, the inputs, the scroll registers and the sound latch.
//
//   000000-03FFFF  program ROM (SDRAM, through a cache; writes are ignored)
//   FE0000-FE1FFF  sprite RAM (1024 entries x 4 words), copied into the sprite buffer at the start of vertical blank
//                  (buffered_spriteram16_device::vblank_copy_rising)
//   FE4000 (r)     P1_P2     FE4000 (w, high byte) coin counters (ignored)
//   FE4002 (r)     SYSTEM    FE4002 (w, high byte) sound latch
//   FE4004 (r)     DSW
//   FE8000-FE8007 (w) scroll: BG x, BG y, FG x, FG y (scroll_w: data &= mem_mask; y is given to the tilemap as -data - 256)
//   FE800E (w)     ignored (watchdog or IRQ acknowledge)
//   FEC000-FECFFF  text video RAM (the 32 x 32 tilemap uses the first 1024 words)
//   FF0000-FF3FFF  BG video RAM (128 x 64 tiles of 32 x 32)      FF4000-FF7FFF  FG video RAM (the same)
//   FF8000-FF87FF  palette RAM (1024 words, xRGBRRRRGGGGBBBB_bit4)
//   FFC000-FFFFFF  16 KB work RAM
//
// Level 2 interrupt at the start of vertical blank, held until acknowledged (irq2_line_hold), autovectored.
// Every access completes with DTACK from here: block-RAM accesses after four clocks, ROM accesses when the cache has the word.
// Unmapped addresses read as 0 and swallow writes (MAME's defaults).  (Structure after the owner's silvmil-mister sm_main.sv.)
`default_nettype none

module sd_main (
    input  logic        clk,
    input  logic        reset,                        // the CPU (also held by the frozen-state bench)
    input  logic        cen_phi1, cen_phi2,           // the CPU clock as alternating enables

    // program ROM word read (through the cache): level request until ack
    output logic        rom_req,
    output logic [17:1] rom_addr,
    input  logic        rom_ack,                      // one cycle, rom_data valid
    input  logic [15:0] rom_data,

    // inputs, active low, in the board's bit order (SYSTEM's bit 10, the vertical blank, is put in here)
    input  logic [15:0] p1p2_in, sys_in, dsw_in,
    input  logic        vblank,                       // the raster is in vertical blank (MAME's screen_device::vblank())

    input  logic        vblank_irq,                   // pulse: the start of vertical blank (line 240)
    input  logic        vsnap,                        // 1: the picture shows the video RAMs and registers as they were at the start of
                                                      //    vertical blank (MAME); 0: as they are while each line is drawn

    // video: tile RAM read ports (registered, one clock after the address): four words of the RAM at a time
    input  logic [10:0] bg_addr, fg_addr,
    output logic [63:0] bg_data, fg_data,
    input  logic [7:0]  tx_addr,
    output logic [63:0] tx_data,
    // video: the sprite buffer, {w3[8:0], w2[8:0], w1[5:0], w0[11:0]} of an entry
    input  logic [9:0]  sp_addr,
    output logic [35:0] sp_data,
    // video: palette RAM read port (always live: the palette is looked up as the dots go out)
    input  logic [9:0]  pal_addr,
    output logic [15:0] pal_data,
    // video: the scroll as the tilemaps use it (x: tilemap x of screen x 0; y: tilemap y of screen line 0), snapshot or live
    output logic [11:0] bg_sx, fg_sx,
    output logic [10:0] bg_sy, fg_sy,

    // sound
    output logic [7:0]  snd_latch,
    output logic        snd_latch_wr,                 // one-cycle pulse

    // bus trace for the simulation
    output logic        trc_stb,
    output logic [23:1] trc_addr,
    output logic        trc_rw,
    output logic [15:0] trc_data,
    output logic [1:0]  trc_be,
    output logic        cpu_halted
);

    // ------------------------------------------------------------------ CPU
    logic [23:1] eab;
    logic [15:0] oEdb, iEdb;
    logic        eRWn, ASn, LDSn, UDSn, VMAn, E;
    logic        FC0, FC1, FC2, BGn, oRESETn, oHALTEDn;
    logic        DTACKn;

    wire iack = FC2 & FC1 & FC0 & ~ASn;

    // level 2 interrupt, held until acknowledged (MAME: irq2_line_hold)
    logic irq2;
    logic iack_d;
    always_ff @(posedge clk) begin
        iack_d <= iack;
        if (reset)                   irq2 <= 1'b0;
        else if (iack_d & ~iack)     irq2 <= 1'b0;
        else if (vblank_irq)         irq2 <= 1'b1;
    end

    logic pwr_d;
    always_ff @(posedge clk) pwr_d <= reset;

    fx68k u_cpu (
        .clk(clk), .HALTn(1'b1),
        .extReset(reset | pwr_d), .pwrUp(reset),
        .enPhi1(cen_phi1), .enPhi2(cen_phi2),
        .eRWn(eRWn), .ASn(ASn), .LDSn(LDSn), .UDSn(UDSn),
        .E(E), .VMAn(VMAn),
        .FC0(FC0), .FC1(FC1), .FC2(FC2),
        .BGn(BGn),
        .oRESETn(oRESETn), .oHALTEDn(oHALTEDn),
        .DTACKn(DTACKn), .VPAn(~iack),
        .BERRn(1'b1),
        .BRn(1'b1), .BGACKn(1'b1),
        .IPL0n(1'b1), .IPL1n(~irq2), .IPL2n(1'b1),      // level 2 = 010
        .iEdb(iEdb), .oEdb(oEdb),
        .eab(eab)
    );
    assign cpu_halted = ~oHALTEDn;

    // ------------------------------------------------------------------ decode
    wire [23:0] ba = {eab, 1'b0};
    wire sel_rom   = ba[23:18] == 6'h00;               // 000000-03FFFF
    wire sel_spr   = ba[23:13] == 11'h7F0;             // FE0000-FE1FFF
    wire sel_p12   = eab == 23'h7F2000;                // FE4000
    wire sel_sys   = eab == 23'h7F2001;                // FE4002
    wire sel_dsw   = eab == 23'h7F2002;                // FE4004
    wire sel_scr   = ba[23:3]  == 21'h1FD000;          // FE8000-FE8007
    wire sel_tx    = ba[23:12] == 12'hFEC;             // FEC000-FECFFF
    wire sel_bg    = ba[23:14] == 10'h3FC;             // FF0000-FF3FFF
    wire sel_fg    = ba[23:14] == 10'h3FD;             // FF4000-FF7FFF
    wire sel_pal   = ba[23:11] == 13'h1FF0;            // FF8000-FF87FF
    wire sel_ram   = ba[23:14] == 10'h3FF;             // FFC000-FFFFFF

    // ------------------------------------------------------------------ RAMs
    logic        we;                                   // one-cycle write strobe
    wire  [1:0]  be = {~UDSn, ~LDSn};

    logic [15:0] q_ram, q_bg, q_fg, q_tx, q_pal, q_spr;

    sd_ram16 #(.AW(13)) u_ram (
        .clka(clk), .addra(eab[13:1]), .da(oEdb), .wea(we && sel_ram ? be : 2'b00), .qa(q_ram),
        .clkb(clk), .addrb(13'd0), .qb());
    sd_ram16 #(.AW(10)) u_pal (
        .clka(clk), .addra(eab[10:1]), .da(oEdb), .wea(we && sel_pal ? be : 2'b00), .qa(q_pal),
        .clkb(clk), .addrb(pal_addr), .qb(pal_data));

    // The video RAMs are four words wide (entry = word address / 4, lane = word address % 4): their copies are swept four words a
    // clock.  The tile RAMs are copied into the renderer's copies (`*_d`) by a sweep of 2048 clocks (21 us): once at the start of
    // vertical blank when `vsnap` (MAME draws the whole frame at that moment, before the interrupt routine rewrites the RAMs), over and
    // over otherwise (the copy then trails the CPU's writes by at most 21 us).
    logic [10:0] cp_ra;
    logic [11:0] cp_i = 12'd0;
    logic        cp_run = 1'b0;
    logic        cp_we;
    logic [10:0] cp_wa;
    assign cp_ra = cp_i[10:0];
    always_ff @(posedge clk) begin
        cp_we <= cp_run;
        cp_wa <= cp_ra;
        if (vsnap ? vblank_irq : !cp_run) begin cp_i <= 12'd0; cp_run <= 1'b1; end
        else if (cp_run) begin
            cp_i <= cp_i + 12'd1;
            if (cp_i == 12'd2047) cp_run <= 1'b0;
        end
    end

    logic [63:0] c_bg, c_fg, c_tx, c_sp;
    sd_ram64 #(.AW(11)) u_bg (
        .clka(clk), .addra(eab[13:3]), .lane(eab[2:1]), .da(oEdb), .wea(we && sel_bg ? be : 2'b00), .qa(q_bg),
        .clkb(clk), .addrb(cp_ra), .qb(c_bg));
    sd_ram64 #(.AW(11)) u_fg (
        .clka(clk), .addra(eab[13:3]), .lane(eab[2:1]), .da(oEdb), .wea(we && sel_fg ? be : 2'b00), .qa(q_fg),
        .clkb(clk), .addrb(cp_ra), .qb(c_fg));
    sd_ram64 #(.AW(9)) u_tx (
        .clka(clk), .addra(eab[11:3]), .lane(eab[2:1]), .da(oEdb), .wea(we && sel_tx ? be : 2'b00), .qa(q_tx),
        .clkb(clk), .addrb(cp_ra[8:0]), .qb(c_tx));

    sd_sdp #(.AW(11), .DW(64)) u_bg_d (.clk(clk), .we(cp_we), .waddr(cp_wa), .wdata(c_bg), .raddr(bg_addr), .rdata(bg_data));
    sd_sdp #(.AW(11), .DW(64)) u_fg_d (.clk(clk), .we(cp_we), .waddr(cp_wa), .wdata(c_fg), .raddr(fg_addr), .rdata(fg_data));
    sd_sdp #(.AW(8),  .DW(64)) u_tx_d (.clk(clk), .we(cp_we && cp_wa[10:8] == 3'd0), .waddr(cp_wa[7:0]), .wdata(c_tx),
                                       .raddr(tx_addr), .rdata(tx_data));

    // Sprites: the CPU's RAM (an entry's four words side by side) is copied into one of two buffers by a sweep of 1024 clocks at
    // every start of vertical blank (the board's buffered sprite RAM).  MAME draws the frame at that moment from the buffer of the
    // vertical blank before, then copies: with `vsnap` the renderer reads the other buffer (the one copied a frame earlier), so its
    // picture is MAME's; without it, the one just copied (the board's: drawn after the copy).
    logic [10:0] sc_i = 11'd0;
    logic        sc_run = 1'b0, sc_we;
    logic  [9:0] sc_wa;
    logic        sp_bank = 1'b0;                       // the buffer the last copy went into
    always_ff @(posedge clk) begin
        sc_we <= sc_run;
        sc_wa <= sc_i[9:0];
        if (vblank_irq) begin sc_i <= 11'd0; sc_run <= 1'b1; sp_bank <= ~sp_bank; end
        else if (sc_run) begin
            sc_i <= sc_i + 11'd1;
            if (sc_i == 11'd1023) sc_run <= 1'b0;
        end
    end
    sd_ram64 #(.AW(10)) u_spr (
        .clka(clk), .addra(eab[12:3]), .lane(eab[2:1]), .da(oEdb), .wea(we && sel_spr ? be : 2'b00), .qa(q_spr),
        .clkb(clk), .addrb(sc_i[9:0]), .qb(c_sp));
    sd_sdp #(.AW(11), .DW(36)) u_sp_d (.clk(clk), .we(sc_we), .waddr({sp_bank, sc_wa}),
                                       .wdata({c_sp[56:48], c_sp[40:32], c_sp[21:16], c_sp[11:0]}),
                                       .raddr({vsnap ? ~sp_bank : sp_bank, sp_addr}), .rdata(sp_data));

    // ------------------------------------------------------------------ registers
    // The raw scroll registers (FE8000-FE8007 as last written) and the sound latch are plain latches: the machine's reset does not
    // clear them (MAME's tilemap scrolls keep their values over a reset and are 0 only until the first write), which also lets the
    // simulation hold the CPU in reset with a frozen state loaded.  `wv` marks a register that has been written: until then its
    // scroll is 0, as the MAME tilemap's (a written y register gives the tilemap -data - 256).
    logic [15:0] raw [4];
    logic  [3:0] wv;
    initial begin
        for (int i = 0; i < 4; i++) raw[i] = 16'd0;
        wv = 4'd0;
        snd_latch = 8'd0;
    end

    always_ff @(posedge clk) begin
        snd_latch_wr <= 1'b0;
        if (we && sel_scr) begin                                     // scroll_w: data &= mem_mask
            raw[eab[2:1]] <= oEdb & {{8{be[1]}}, {8{be[0]}}};
            wv[eab[2:1]]  <= 1'b1;
        end
        if (we && sel_sys && be[1]) begin snd_latch <= oEdb[15:8]; snd_latch_wr <= 1'b1; end      // the byte at FE4002
    end

    // the scroll values the tilemaps get: x = data (4096 wide), y = -data - 256 (2048 high)
    logic [11:0] bg_sx_l, fg_sx_l;
    logic [10:0] bg_sy_l, fg_sy_l;
    always_comb begin
        bg_sx_l = raw[0][11:0];
        bg_sy_l = wv[1] ? (11'd0 - raw[1][10:0] - 11'd256) : 11'd0;
        fg_sx_l = raw[2][11:0];
        fg_sy_l = wv[3] ? (11'd0 - raw[3][10:0] - 11'd256) : 11'd0;
    end

    // as the picture uses them: latched with the RAMs' snapshot at the start of vertical blank, or live
    logic [11:0] bg_sx_s, fg_sx_s;
    logic [10:0] bg_sy_s, fg_sy_s;
    always_ff @(posedge clk) if (vblank_irq) begin
        bg_sx_s <= bg_sx_l; bg_sy_s <= bg_sy_l; fg_sx_s <= fg_sx_l; fg_sy_s <= fg_sy_l;
    end
    assign bg_sx = vsnap ? bg_sx_s : bg_sx_l;
    assign bg_sy = vsnap ? bg_sy_s : bg_sy_l;
    assign fg_sx = vsnap ? fg_sx_s : fg_sx_l;
    assign fg_sy = vsnap ? fg_sy_s : fg_sy_l;

    // ------------------------------------------------------------------ bus cycle
    logic        rdy;                             // DTACK
    logic [2:0]  cnt;
    logic        wr_seen;
    assign DTACKn = ~rdy;

    // SYSTEM bit 10 is the screen's vertical blank, active low as MAME reads it (the port's value XOR its active-low default)
    wire [15:0] sys_v = {sys_in[15:11], ~vblank, sys_in[9:0]};

    logic [15:0] rd_mux;
    always_comb begin
        rd_mux = 16'h0000;
        if      (sel_ram)   rd_mux = q_ram;
        else if (sel_bg)    rd_mux = q_bg;
        else if (sel_fg)    rd_mux = q_fg;
        else if (sel_tx)    rd_mux = q_tx;
        else if (sel_pal)   rd_mux = q_pal;
        else if (sel_spr)   rd_mux = q_spr;
        else if (sel_p12)   rd_mux = p1p2_in;
        else if (sel_sys)   rd_mux = sys_v;
        else if (sel_dsw)   rd_mux = dsw_in;
    end

    assign rom_addr = eab[17:1];

    always_ff @(posedge clk) begin
        we         <= 1'b0;
        trc_stb    <= 1'b0;
        if (reset || ASn) begin
            rdy     <= 1'b0;
            cnt     <= 3'd0;
            wr_seen <= 1'b0;
            rom_req <= 1'b0;
        end else if (!iack && !rdy) begin
            if (!eRWn) begin
                // write: the data strobes (and the data) arrive a clock after AS
                if (!wr_seen) begin
                    if (be != 2'b00) begin
                        wr_seen <= 1'b1;
                        we      <= 1'b1;
                        trc_stb <= 1'b1; trc_addr <= eab; trc_rw <= 1'b0; trc_data <= oEdb; trc_be <= be;
                    end
                end else begin
                    rdy <= 1'b1;
                end
            end else if (sel_rom) begin
                // read from the ROM cache
                rom_req <= 1'b1;
                if (rom_ack) begin
                    iEdb    <= rom_data;
                    rom_req <= 1'b0;
                    rdy     <= 1'b1;
                    trc_stb <= 1'b1; trc_addr <= eab; trc_rw <= 1'b1; trc_data <= rom_data; trc_be <= be;
                end
            end else begin
                cnt <= cnt + 3'd1;
                if (cnt == 3'd3) begin
                    iEdb <= rd_mux;
                    rdy  <= 1'b1;
                    trc_stb <= 1'b1; trc_addr <= eab; trc_rw <= 1'b1; trc_data <= rd_mux; trc_be <= be;
                end
            end
        end
    end

    wire unused = ^{E, VMAn, BGn, oRESETn, c_sp[63:57], c_sp[47:41], c_sp[31:22], c_sp[15:12]};
endmodule
`default_nettype wire
