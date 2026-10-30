// The sound board (MAME supduck_state::sound_map): a Z80 (2 MHz), its program in block RAM (written by the loader), 2 KB of RAM, an
// OKI M6295 (jt6295, Jose Tejada; 1 MHz, pin 7 high: sample rate clock / 132) reading its samples from SDRAM, and the sound latch the
// 68000 writes, whose "data pending" is the Z80's INT (generic_latch_8: set by the 68000's write, cleared by the Z80's read).
//
//   0000-7FFF ROM    8000-87FF RAM    9000 (w) OKI bank    9800 OKI M6295 (r/w)    A000 (r) sound latch
//   (MAME's unmapped reads are 0; the interrupt acknowledge reads 0xFF: the bus floats high, RST 38h in IM 0 / IM 1)
//
// The OKI's 256 KB space (supduck_state::oki_map): 00000-1FFFF the fixed samples ("oki", 128 KB), 20000-3FFFF one of the four
// 128 KB banks of "okibank" (okibank_w: data & 3).  In the core's sample area (sd_mem.sv) the fixed samples are first and the banks
// follow them: byte = (a[17] ? bank + 1 : 0) * 0x20000 + a[16:0].
`default_nettype none
module sd_sound (
    input  logic        clk,
    input  logic        rst,
    input  logic        cen_z80,              // the Z80's clock
    input  logic        cen_oki,              // the OKI's clock

    input  logic [7:0]  latch,                // the 68000's sound latch
    input  logic        latch_wr,             // pulse: the 68000 wrote it

    // Z80 program load (from the loader)
    input  logic        zr_we,
    input  logic [14:0] zr_addr,
    input  logic [7:0]  zr_data,

    // OKI sample byte read: level request until ack (sd_mem.sv)
    output logic        pcm_req,
    output logic [19:0] pcm_addr,
    input  logic        pcm_ack,
    input  logic [7:0]  pcm_q,

    output logic signed [13:0] pcm,           // jt6295's sum of the voices
    output logic [15:0] dbg_pc,
    output logic        dbg_irq
);
    // ------------------------------------------------------------------ Z80
    logic        m1_n, mreq_n, iorq_n, rd_n, wr_n, rfsh_n;
    logic [15:0] A;
    logic [7:0]  cpu_di, cpu_do;
    logic        pending;

    tv80s_cen u_cpu (
        .reset_n(~rst), .clk(clk), .cen(cen_z80), .wait_n(1'b1),
        .int_n(~pending), .nmi_n(1'b1), .busrq_n(1'b1),
        .m1_n(m1_n), .mreq_n(mreq_n), .iorq_n(iorq_n), .rd_n(rd_n), .wr_n(wr_n),
        .rfsh_n(rfsh_n), .halt_n(), .busak_n(), .A(A), .di(cpu_di), .dout(cpu_do)
    );
    assign dbg_pc  = A;
    assign dbg_irq = pending;

    // ------------------------------------------------------------------ memories
    // the bus signals come from registers that change only on cen_z80 (every 48 machine clocks), so the block RAMs' registered reads
    // of the live address are valid long before the CPU samples them
    wire sel_rom   = !A[15];                                  // 0000-7FFF
    wire sel_ram   = A[15:11] == 5'b10000;                    // 8000-87FF
    wire sel_bank  = A == 16'h9000;
    wire sel_oki   = A == 16'h9800;
    wire sel_latch = A == 16'hA000;
    wire mem_cyc   = !mreq_n && rfsh_n;
    wire mem_wr    = mem_cyc && !wr_n;
    wire mem_rd    = mem_cyc && !rd_n;

    logic [7:0] rom_q, ram_q;
    sd_sdp #(.AW(15), .DW(8)) u_rom (.clk(clk), .we(zr_we), .waddr(zr_addr), .wdata(zr_data), .raddr(A[14:0]), .rdata(rom_q));
    sd_ram8 #(.AW(11)) u_ram (.clk(clk), .we(mem_wr && sel_ram), .addr(A[10:0]), .d(cpu_do), .q(ram_q));

    // ------------------------------------------------------------------ the latch's interrupt, the bank, the chip's writes
    logic mem_wr_d;
    always_ff @(posedge clk) mem_wr_d <= mem_wr;
    wire  wr_p = mem_wr && !mem_wr_d;                         // one pulse per memory write cycle

    logic       oki_wr;
    logic [7:0] wdat;
    logic [1:0] bank;
    always_ff @(posedge clk) begin
        oki_wr <= 1'b0;
        if (rst) begin
            pending <= 1'b0; bank <= 2'd0;
        end else begin
            if (latch_wr)                    pending <= 1'b1;
            else if (mem_rd && sel_latch)    pending <= 1'b0;
            if (wr_p && sel_bank) bank <= cpu_do[1:0];
            if (wr_p && sel_oki) begin wdat <= cpu_do; oki_wr <= 1'b1; end
        end
    end

    // OKI M6295
    logic [7:0]  oki_dout;
    logic [17:0] oki_a;
    logic [7:0]  oki_rd;
    logic        oki_ok;
    jt6295 #(.INTERPOL(0)) u_oki (
        .rst(rst), .clk(clk), .cen(cen_oki), .ss(1'b1),
        .wrn(~oki_wr), .din(wdat), .dout(oki_dout),
        .rom_addr(oki_a), .rom_data(oki_rd), .rom_ok(oki_ok),
        .sound(pcm), .sample()
    );
    // the chip's address in the sample area (fixed samples, then the banks)
    wire [2:0]  page   = oki_a[17] ? ({1'b0, bank} + 3'd1) : 3'd0;
    wire [19:0] oki_pa = {page, oki_a[16:0]};
    // the sample byte is read from the SDRAM whenever that address changes and held (as the owner's silvmil / ohmygod cores)
    logic [19:0] srv_a;
    logic        have;
    always_ff @(posedge clk) begin
        if (rst) begin
            have <= 1'b0; pcm_req <= 1'b0; oki_rd <= 8'h00; srv_a <= 20'd0;
        end else begin
            if (pcm_ack) begin
                oki_rd <= pcm_q; srv_a <= pcm_addr; have <= 1'b1; pcm_req <= 1'b0;
            end else if (!pcm_req && !(have && srv_a == oki_pa)) begin
                pcm_addr <= oki_pa; pcm_req <= 1'b1;
            end
        end
    end
    assign oki_ok = have && (srv_a == oki_pa);

    // ------------------------------------------------------------------ the CPU's data input
    always_comb begin
        cpu_di = 8'h00;
        if (!m1_n && !iorq_n)       cpu_di = 8'hFF;               // interrupt acknowledge: the bus floats high
        else if (!mreq_n) begin
            if (sel_rom)            cpu_di = rom_q;
            else if (sel_ram)       cpu_di = ram_q;
            else if (sel_oki)       cpu_di = oki_dout;
            else if (sel_latch)     cpu_di = latch;
        end
    end
endmodule
`default_nettype wire
