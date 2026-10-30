// Raster, line buffer and palette lookup (the display side), all on the machine clock.
//
// MAME's screen (supduck.cpp): set_raw(6000000, 384, 0, 256, 262, 16, 240): dot clock 6 MHz (96 MHz / 16), 384 dots a line
// (15.625 kHz), 262 lines a frame (59.637 Hz), dots 0..255 of lines 16..239 visible.  The counters here are MAME's own: line 0 is
// MAME's vpos 0, so the picture is lines 16..239 and the vertical blank (and the board's interrupt) starts at line 240.  The driver's
// note "hsync is 306..333 (offset by 128), vsync is 251..253 (offset by 6)" gives the sync pulses in these coordinates: 28 dots,
// 50 after the picture and 50 before the next line's; 3 lines, 11 after the picture.
//
// A line is drawn (sd_render) while the one before it is shown, into the other half of the line buffer; the display reads the
// buffer, then the palette RAM (a 10-bit pen, MAME's numbers: 0..255 FG, 256..511 BG, 512..767 sprites, 768..1023 text), and
// registers the colour at the dot.  (Structure after the owner's silvmil-mister sm_video.sv.)
`default_nettype none
module sd_video (
    input  logic        clk,

    // raster out
    output logic        ce_pix,
    output logic        hblank, vblank, hsync, vsync,
    output logic [23:0] rgb,

    // raster events (one-cycle pulses)
    output logic        line_start,       // a line is to be drawn: line_no into half line_bank
    output logic  [7:0] line_no,          // MAME's vpos of the line (16..239)
    output logic        line_bank,
    output logic        vbl_pulse,        // vertical blanking starts (line 240)

    // renderer write port
    input  logic        lb_we,
    input  logic [8:0]  lb_addr,          // {bank, x[7:0]}
    input  logic [9:0]  lb_data,

    // palette RAM read port (registered)
    output logic [9:0]  pal_addr,
    input  logic [15:0] pal_data
);
    localparam H_ACT = 256, H_TOT = 384, V_FIRST = 16, V_LAST = 239, V_TOT = 262;
    localparam H_SYNC0 = 306, H_SYNC1 = 334;           // 28 dots
    localparam V_SYNC0 = 251, V_SYNC1 = 254;           // 3 lines

    // ------------------------------------------------------------ raster
    logic [3:0] ph = 4'd0;
    logic [8:0] hc = 9'd0, vc = 9'd0;                  // the dot / line being output
    always_ff @(posedge clk) begin
        ph <= ph + 4'd1;
        ce_pix <= (ph == 4'd15);
    end

    // the counters at the next dot
    wire        wrap = (hc == H_TOT - 1);
    wire [8:0]  hn = wrap ? 9'd0 : hc + 9'd1;
    wire [8:0]  vn = wrap ? ((vc == V_TOT - 1) ? 9'd0 : vc + 9'd1) : vc;
    wire [8:0]  ln = vn + 9'd1;                        // the line drawn while line vn is shown

    always_ff @(posedge clk) begin
        line_start <= 1'b0;
        vbl_pulse  <= 1'b0;
        if (ph == 4'd15) begin
            hc <= hn;
            vc <= vn;
            hblank <= (hn >= H_ACT);
            vblank <= (vn < V_FIRST) || (vn > V_LAST);
            hsync  <= (hn >= H_SYNC0) && (hn < H_SYNC1);
            vsync  <= (vn >= V_SYNC0) && (vn < V_SYNC1);
            if (wrap) begin
                line_bank  <= ln[0];
                line_start <= (ln >= V_FIRST) && (ln <= V_LAST);
                line_no    <= ln[7:0];
                vbl_pulse  <= (vn == V_LAST + 1);
            end
        end
    end

    // ------------------------------------------------------------ line buffer and palette
    // the dot after the next one is read two clocks ahead of the register: the line buffer's output is registered, so is
    // the palette RAM's (sd_main's port B), and the dot's colour is registered at the dot edge.
    wire        rd_bank = wrap ? ~vc[0] : vc[0];
    wire [8:0]  rd_addr = {rd_bank, hn[7:0]};
    logic [9:0] lb_q;
    sd_sdp #(.AW(9), .DW(10)) u_lb (.clk(clk), .we(lb_we), .waddr(lb_addr), .wdata(lb_data), .raddr(rd_addr), .rdata(lb_q));
    assign pal_addr = lb_q;

    // palette entry: MAME palette_device::xRGBRRRRGGGGBBBB_bit4: 5 bits a component, bits 14 / 13 / 12 the high bits of R / G / B
    wire [4:0] cr = {pal_data[14], pal_data[11:8]};
    wire [4:0] cg = {pal_data[13], pal_data[7:4]};
    wire [4:0] cb = {pal_data[12], pal_data[3:0]};
    always_ff @(posedge clk) if (ph == 4'd15) begin
        rgb <= {cr, cr[4:2], cg, cg[4:2], cb, cb[4:2]};
    end
endmodule
`default_nettype wire
