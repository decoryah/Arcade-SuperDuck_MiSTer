// Line renderer: MAME's supduck_state::screen_update for one line (the one after the line being shown).
//
//   1. BG tilemap: 128 x 64 tiles of 32 x 32 (4096 x 2048), opaque.  Tilemap x = screen x + scroll x, tilemap y = line + scroll y (the
//      registers' values as sd_main gives them).  Per tile: the word from the BG video RAM at the driver's tilemap_scan
//      ({row'[5:3], col[6:3], row'[2:0], col[2:0]}, row' = row ^ 63), code = {w[15], w[14], w[7:0]}, colour w[11:8], flip X w[13],
//      flip Y w[12]; the tile row's 8 words from the tile ROM in SDRAM; 32 pen writes.  Pen = 256 + colour * 16 + pixel.
//   2. FG tilemap, the same, pen 15 transparent.  Pen = colour * 16 + pixel.
//   3. sprites (tigeroad_spr_device::draw_sprites, rev_y, flip screen off): 1024 entries of 4 words, drawn from the last entry to the
//      first (entry 0 on top), 16 x 16, pen 15 transparent.  y = 240 - sext9(w2), x = sext9(w3), tile w0 (modulo the ROM's 4096),
//      colour w1[5:2], flip X w1[1], flip Y w1[0].  Pen = 512 + colour * 16 + pixel.  A scanner looks at one entry a clock from the
//      start of the line (in parallel with the tile passes) and lists the ones on the line in drawing order; this pass draws the list.
//   4. text tilemap: 32 x 32 tiles of 8 x 8, not scrolled, 2 bits a pixel, pen 3 transparent.  code = {w[13], w[15:14], w[7:0]},
//      colour w[11:8], flip Y w[12].  Pen = 768 + colour * 4 + pixel.
//
// The ROM layouts (the loader's remap, sd_mem.sv / tools/supduck_image.py):
//   tiles: a 32-pixel row of a tile is 8 words at {tile, row, column group g, half h}: word = the gfx layout's two bytes of the row in
//          column group g (8 pixels) of region half h, first byte in the low half.  Pixel q of the group: byte q[2], bit 7 - q[1:0] is
//          the half's plane +0, bit 3 - q[1:0] its plane +4.  pen = {h1 bit 3-q, h1 bit 7-q, h0 bit 3-q, h0 bit 7-q}.
//   sprites: a 16-pixel row is 4 words at {tile, row, column half, word}: words 0 / 1 are bytes 0..3 of pixels 0..7, words 2 / 3 of
//          pixels 8..15; pixel x of a byte is bit 7 - x; pen = {byte 0, byte 1, byte 2, byte 3}.
//   chars (block RAM): word {char, row} = the row's two bytes, first in the low half; as the tiles' half 0.
//
// Line buffer entries are palette indexes.  (Structure after the owner's silvmil-mister sm_render.sv.)
`default_nettype none
module sd_render #(
    parameter [24:1] FG_BASE  = 24'h020000,       // SDRAM word addresses of the (remapped) FG tile ROM (1024 tiles: 512 KB),
    parameter [24:1] BG_BASE  = 24'h060000,       // the BG tile ROM (the same)
    parameter [24:1] SPR_BASE = 24'h0A0000        // and the sprite ROM (4096 tiles: 512 KB)
) (
    input  logic        clk,
    input  logic        rst,

    input  logic        start,                    // draw `line` into half `bank` of the line buffer
    input  logic [7:0]  line,
    input  logic        bank,
    output logic        busy,
    output logic        overrun,                  // pulse: a line started while the last one was still being drawn

    input  logic [11:0] bg_sx, fg_sx,
    input  logic [10:0] bg_sy, fg_sy,

    // video RAM copies (registered, one clock after the address): four words at a time
    output logic [10:0] bg_addr, fg_addr,
    input  logic [63:0] bg_data, fg_data,
    output logic [7:0]  tx_addr,
    input  logic [63:0] tx_data,
    // the sprite buffer: {w3[8:0], w2[8:0], w1[5:0], w0[11:0]} of the entry, one clock after the address
    output logic [9:0]  sp_addr,
    input  logic [35:0] sp_data,
    // character ROM (block RAM): one row of a character, one clock after the address
    output logic [13:0] cr_addr,
    input  logic [15:0] cr_data,

    // SDRAM burst clients (level request, a word per wr with its index, a pulse at the end): tile rows 8 words, sprite rows 4
    output logic        t_req,
    output logic [24:1] t_addr,
    input  logic        t_wr,
    input  logic [2:0]  t_idx,
    input  logic [15:0] t_data,
    input  logic        t_done,
    output logic        s_req,
    output logic [24:1] s_addr,
    input  logic        s_wr,
    input  logic [1:0]  s_idx,
    input  logic [15:0] s_data,
    input  logic        s_done,

    // line buffer write port
    output logic        lb_we,
    output logic [8:0]  lb_addr,                  // {bank, x[7:0]}
    output logic [9:0]  lb_data
);
    // ================================================================== the sprite scanner
    // From the start of the line: entries 1023 down to 0, one a clock (address -> buffer -> registered entry -> hit test), the ones on
    // the line written to the list in that order.  An entry: {code[11:0], pixel row[3:0] (flip Y applied), colour[3:0], flip X, x[8:0]}.
    logic [7:0]  sc_y;
    logic [9:0]  sc_i;
    logic        sc_run, sc_v1, sc_v2, sc_v3;
    logic [35:0] sc_e;
    logic [10:0] n_hits;                          // entries in the list
    logic        sl_we;
    logic [9:0]  sl_wa;
    logic [29:0] sl_wd;
    wire         scan_done = !sc_run && !sc_v1 && !sc_v2 && !sc_v3;

    wire  [8:0]  e_x    = sc_e[35:27];
    wire  [8:0]  e_y    = sc_e[26:18];
    wire  [5:0]  e_attr = sc_e[17:12];
    wire  [11:0] e_code = sc_e[11:0];
    // the sprite's top line is 240 - sext9(w2): the line's row in it d = line - 240 + sext9(w2)
    wire  [10:0] e_d    = {3'b000, sc_y} - 11'd240 + {{2{e_y[8]}}, e_y};
    wire         e_hity = (e_d[10:4] == 7'd0);                         // 0 <= d < 16
    wire         e_hitx = !e_x[8] || (e_x >= 9'h1F1);                  // x > -16: some of its 16 dots are at x >= 0
    wire  [3:0]  e_row  = e_attr[0] ? ~e_d[3:0] : e_d[3:0];

    always_ff @(posedge clk) begin
        sl_we <= 1'b0;
        if (rst) begin
            sc_run <= 1'b0; sc_v1 <= 1'b0; sc_v2 <= 1'b0; sc_v3 <= 1'b0; n_hits <= 11'd0;
        end else if (start) begin
            sc_y <= line; sc_i <= 10'd1023; sc_run <= 1'b1; sc_v1 <= 1'b0; sc_v2 <= 1'b0; sc_v3 <= 1'b0; n_hits <= 11'd0;
        end else begin
            if (sc_run) begin
                sp_addr <= sc_i;
                sc_i    <= sc_i - 10'd1;
                if (sc_i == 10'd0) sc_run <= 1'b0;
            end
            sc_v1 <= sc_run;
            sc_v2 <= sc_v1;
            sc_v3 <= sc_v2;
            if (sc_v2) sc_e <= sp_data;
            if (sc_v3 && e_hity && e_hitx) begin
                sl_we  <= 1'b1;
                sl_wa  <= n_hits[9:0];
                sl_wd  <= {e_code, e_row, e_attr[5:2], e_attr[1], e_x};
                n_hits <= n_hits + 11'd1;
            end
        end
    end

    logic [9:0]  sl_ra;
    logic [29:0] sl_q;
    sd_sdp #(.AW(10), .DW(30)) u_list (.clk(clk), .we(sl_we), .waddr(sl_wa), .wdata(sl_wd), .raddr(sl_ra), .rdata(sl_q));

    // ================================================================== the passes
    typedef enum logic [4:0] {
        S_IDLE, T_ADDR, T_WAIT, T_CAP, T_FETCH, T_PIX,
        P_LIST, P_LWAIT, P_LCAP, P_FETCH, P_DRAW,
        X_ADDR, X_WAIT, X_CAP, X_RWAIT, X_PIX
    } st_t;
    st_t st = S_IDLE;

    // latched at the start of the line
    logic [7:0]  y;
    logic        bk;

    // ---- tile passes
    logic        layer;                           // 0 BG, 1 FG
    logic [11:0] sx;                              // the layer's scroll
    logic [10:0] ty;                              // tilemap y of the line
    logic [3:0]  ti;                              // tile 0..8 of the line
    logic [4:0]  pp;                              // pixel 0..31
    logic [3:0]  t_col;
    logic        t_fx;
    logic [15:0] tw [8];
    wire  [6:0]  tcol  = sx[11:5] + {3'd0, ti};
    wire  [5:0]  trow  = ty[10:5] ^ 6'h3F;
    wire  [12:0] t_off = {trow[5:3], tcol[6:3], trow[2:0], tcol[2:0]};             // the driver's tilemap_scan
    wire  [10:0] t_x0  = {2'b00, ti, 5'd0} - {6'd0, sx[4:0]};                      // screen x of the tile's pixel 0 (signed 11 bit)
    wire  [10:0] tl_x  = t_x0 + {6'd0, pp};
    wire  [4:0]  t_sx  = t_fx ? ~pp : pp;                                          // the tile's column
    wire  [15:0] tw0   = tw[{t_sx[4:3], 1'b0}], tw1 = tw[{t_sx[4:3], 1'b1}];
    wire  [7:0]  tb0   = t_sx[2] ? tw0[15:8] : tw0[7:0];
    wire  [7:0]  tb1   = t_sx[2] ? tw1[15:8] : tw1[7:0];
    wire  [2:0]  tq_lo = 3'd7 - {1'b0, t_sx[1:0]};                                // the bit of the half's plane +0 in the byte
    wire  [2:0]  tq_hi = 3'd3 - {1'b0, t_sx[1:0]};                                // ... and of its plane +4
    wire  [3:0]  t_pen = {tb1[tq_hi], tb1[tq_lo], tb0[tq_hi], tb0[tq_lo]};
    logic [1:0]  t_lane;

    // ---- sprite pass
    logic [10:0] pk;                              // the next list entry
    logic [3:0]  p_col;
    logic        p_fx;
    logic [9:0]  p_x;                             // signed
    logic [15:0] sw [4];
    logic [3:0]  sp;                              // pixel 0..15
    wire  [3:0]  s_sx  = p_fx ? ~sp : sp;
    wire  [15:0] swa   = sw[{s_sx[3], 1'b0}], swb = sw[{s_sx[3], 1'b1}];
    wire  [2:0]  sb    = 3'd7 - s_sx[2:0];
    wire  [3:0]  s_pen = {swa[{1'b0, sb}], swa[{1'b1, sb}], swb[{1'b0, sb}], swb[{1'b1, sb}]};
    wire  [9:0]  sp_x  = p_x + {6'd0, sp};

    // ---- text pass
    logic [4:0]  xc;                              // column 0..31
    logic [2:0]  xq;                              // pixel 0..7
    logic [3:0]  x_col;
    logic [15:0] xw;
    wire  [9:0]  x_idx = {y[7:3], xc};
    wire  [2:0]  xq_lo = 3'd7 - {1'b0, xq[1:0]};
    wire  [2:0]  xq_hi = 3'd3 - {1'b0, xq[1:0]};

    assign busy = (st != S_IDLE);

    // the last row fetched of each kind, kept for the next tile / sprite of the same row (the ROMs do not change while the machine runs;
    // rst invalidates them, and a ROM load holds the machine in reset)
    logic        tc_valid, sc_valid;
    logic [15:0] tc_key;                          // {layer, tile[9:0], row[4:0]}
    logic [15:0] sc_key;                          // {tile[11:0], row[3:0]}
    wire  t_clear = &{tw[0], tw[1], tw[2], tw[3], tw[4], tw[5], tw[6], tw[7]};      // a row of pen 15 only
    wire  s_clear = &{sw[0], sw[1], sw[2], sw[3]};

    always_ff @(posedge clk) begin
        lb_we   <= 1'b0;
        overrun <= 1'b0;
        if (t_wr) tw[t_idx] <= t_data;
        if (s_wr) sw[s_idx] <= s_data;

        if (rst) begin
            st <= S_IDLE; t_req <= 1'b0; s_req <= 1'b0; tc_valid <= 1'b0; sc_valid <= 1'b0;
        end else begin
            if (start && st != S_IDLE) overrun <= 1'b1;
            case (st)
                S_IDLE: if (start) begin
                    y     <= line;
                    bk    <= bank;
                    layer <= 1'b0;
                    sx    <= bg_sx;
                    ty    <= {3'd0, line} + bg_sy;
                    ti    <= 4'd0;
                    st    <= T_ADDR;
                end

                // ---------------------------------------------------- tiles
                T_ADDR: begin
                    if (t_x0[10] == 1'b0 && t_x0 >= 11'd256) begin        // the rest of the row is right of the picture
                        if (!layer) begin
                            layer <= 1'b1;
                            sx    <= fg_sx;
                            ty    <= {3'd0, y} + fg_sy;
                            ti    <= 4'd0;
                        end else begin
                            pk <= 11'd0;
                            st <= P_LIST;
                        end
                    end else begin
                        if (layer) fg_addr <= t_off[12:2];
                        else       bg_addr <= t_off[12:2];
                        t_lane <= t_off[1:0];
                        st     <= T_WAIT;
                    end
                end
                T_WAIT: st <= T_CAP;                                      // the RAM samples the address
                T_CAP: begin                                              // its word is valid now
                    logic [15:0] v;
                    logic [15:0] key;
                    logic [4:0]  ry;
                    v   = (layer ? fg_data : bg_data) >> {t_lane, 4'd0};
                    ry  = v[12] ? ~ty[4:0] : ty[4:0];
                    key = {layer, v[15], v[14], v[7:0], ry};
                    t_col <= v[11:8];
                    t_fx  <= v[13];
                    pp    <= 5'd0;
                    if (tc_valid && tc_key == key) st <= T_PIX;           // the same row as the last fetch: its words are still in tw
                    else begin
                        t_addr   <= (layer ? FG_BASE : BG_BASE) + {6'd0, v[15], v[14], v[7:0], ry, 3'b000};
                        t_req    <= 1'b1;
                        tc_key   <= key;
                        tc_valid <= 1'b0;
                        st       <= T_FETCH;
                    end
                end
                T_FETCH: if (t_done) begin
                    t_req    <= 1'b0;
                    tc_valid <= 1'b1;
                    st       <= T_PIX;
                end
                T_PIX: begin
                    if (tl_x[10:8] == 3'b000 && (!layer || t_pen != 4'hF)) begin
                        lb_we   <= 1'b1;
                        lb_addr <= {bk, tl_x[7:0]};
                        lb_data <= {1'b0, ~layer, t_col, t_pen};
                    end
                    pp <= pp + 5'd1;
                    if (pp == 5'd31 || (layer && t_clear)) begin          // an FG row of pen 15 only draws nothing
                        ti <= ti + 4'd1;
                        st <= T_ADDR;
                    end
                end

                // ---------------------------------------------------- sprites (the scanner's list, in order)
                P_LIST: begin
                    if (pk < n_hits) begin
                        sl_ra <= pk[9:0];
                        pk    <= pk + 11'd1;
                        st    <= P_LWAIT;
                    end else if (scan_done) begin
                        xc <= 5'd0;
                        st <= X_ADDR;
                    end
                end
                P_LWAIT: st <= P_LCAP;
                P_LCAP: begin
                    p_col  <= sl_q[13:10];
                    p_fx   <= sl_q[9];
                    p_x    <= {sl_q[8], sl_q[8:0]};
                    sp     <= 4'd0;
                    if (sc_valid && sc_key == {sl_q[29:18], sl_q[17:14]}) st <= P_DRAW;   // still in sw
                    else begin
                        s_addr   <= SPR_BASE + {6'd0, sl_q[29:18], sl_q[17:14], 2'b00};
                        s_req    <= 1'b1;
                        sc_key   <= {sl_q[29:18], sl_q[17:14]};
                        sc_valid <= 1'b0;
                        st       <= P_FETCH;
                    end
                end
                P_FETCH: if (s_done) begin
                    s_req    <= 1'b0;
                    sc_valid <= 1'b1;
                    st       <= P_DRAW;
                end
                P_DRAW: begin
                    if (s_pen != 4'hF && sp_x[9:8] == 2'b00) begin
                        lb_we   <= 1'b1;
                        lb_addr <= {bk, sp_x[7:0]};
                        lb_data <= {2'b10, p_col, s_pen};
                    end
                    sp <= sp + 4'd1;
                    if (sp == 4'd15 || s_clear) st <= P_LIST;             // a row of pen 15 only draws nothing
                end

                // ---------------------------------------------------- text
                X_ADDR: begin
                    tx_addr <= x_idx[9:2];
                    t_lane  <= x_idx[1:0];
                    st      <= X_WAIT;
                end
                X_WAIT: st <= X_CAP;
                X_CAP: begin
                    logic [15:0] v;
                    v = tx_data >> {t_lane, 4'd0};
                    x_col   <= v[11:8];
                    cr_addr <= {v[13], v[15:14], v[7:0], v[12] ? ~y[2:0] : y[2:0]};
                    xq      <= 3'd0;
                    st      <= X_RWAIT;
                end
                X_RWAIT: st <= X_PIX;                                     // the ROM samples the address; its word next clock
                X_PIX: begin
                    if (xq == 3'd0) xw <= cr_data;
                    begin
                        logic [15:0] w;
                        logic [7:0]  b;
                        logic [1:0]  pen;
                        w   = (xq == 3'd0) ? cr_data : xw;
                        b   = xq[2] ? w[15:8] : w[7:0];
                        pen = {b[xq_hi], b[xq_lo]};
                        if (pen != 2'd3) begin
                            lb_we   <= 1'b1;
                            lb_addr <= {bk, xc, xq};
                            lb_data <= {4'b1100, x_col, pen};
                        end
                    end
                    xq <= xq + 3'd1;
                    if (xq == 3'd7) begin
                        xc <= xc + 5'd1;
                        st <= (xc == 5'd31) ? S_IDLE : X_ADDR;
                    end
                end
                default: st <= S_IDLE;
            endcase
        end
    end

endmodule
`default_nettype wire
