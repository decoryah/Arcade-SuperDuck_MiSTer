// Block RAM building blocks (the owner's silvmil-mister sm_ram.sv, from omg_ram.sv, itself from mcatadv_ram.sv).
//
// Written the way Quartus 17 infers M10K reliably: a byte-wide array per lane with
// whole-element writes, registered reads, no read-during-write check.

// 16-bit word RAM, port A read/write (byte enables), port B read only, optionally
// on another clock (port B is the display side for the palette RAM).
module sd_ram16 #(
    parameter AW = 12
) (
    input  logic          clka,
    input  logic [AW-1:0] addra,
    input  logic [15:0]   da,
    input  logic [1:0]    wea,       // [1] high byte, [0] low byte
    output logic [15:0]   qa,
    input  logic          clkb,
    input  logic [AW-1:0] addrb,
    output logic [15:0]   qb
);
    (* ramstyle = "no_rw_check" *) logic [7:0] hi [0:(1<<AW)-1];
    (* ramstyle = "no_rw_check" *) logic [7:0] lo [0:(1<<AW)-1];

    always_ff @(posedge clka) begin
        if (wea[1]) hi[addra] <= da[15:8];
        qa[15:8] <= hi[addra];
    end
    always_ff @(posedge clka) begin
        if (wea[0]) lo[addra] <= da[7:0];
        qa[7:0] <= lo[addra];
    end
    always_ff @(posedge clkb) qb <= {hi[addrb], lo[addrb]};
endmodule

// Simple dual port, one clock: write port + read port (no byte enables).
module sd_sdp #(
    parameter AW = 12,
    parameter DW = 16
) (
    input  logic          clk,
    input  logic          we,
    input  logic [AW-1:0] waddr,
    input  logic [DW-1:0] wdata,
    input  logic [AW-1:0] raddr,
    output logic [DW-1:0] rdata
);
    (* ramstyle = "no_rw_check" *) logic [DW-1:0] mem [0:(1<<AW)-1];
    always_ff @(posedge clk) begin
        if (we) mem[waddr] <= wdata;
        rdata <= mem[raddr];
    end
endmodule

// Simple dual port with separate write and read clocks (line buffers: the renderer
// writes on the machine clock, the display reads on the video clock).
module sd_sdp2 #(
    parameter AW = 9,
    parameter DW = 16
) (
    input  logic          wclk,
    input  logic          we,
    input  logic [AW-1:0] waddr,
    input  logic [DW-1:0] wdata,
    input  logic          rclk,
    input  logic [AW-1:0] raddr,
    output logic [DW-1:0] rdata
);
    (* ramstyle = "no_rw_check" *) logic [DW-1:0] mem [0:(1<<AW)-1];
    always_ff @(posedge wclk) if (we) mem[waddr] <= wdata;
    always_ff @(posedge rclk) rdata <= mem[raddr];
endmodule

// Byte-wide RAM with an initial-content-free single port (Z80 RAM)
module sd_ram8 #(
    parameter AW = 13
) (
    input  logic          clk,
    input  logic          we,
    input  logic [AW-1:0] addr,
    input  logic [7:0]    d,
    output logic [7:0]    q
);
    (* ramstyle = "no_rw_check" *) logic [7:0] mem [0:(1<<AW)-1];
    always_ff @(posedge clk) begin
        if (we) mem[addr] <= d;
        q <= mem[addr];
    end
endmodule

// 64-bit wide word RAM: four 16-bit words side by side (a video RAM whose copy is swept four words a clock).  Port A is the CPU's:
// word `lane` of entry `addra`, with byte enables; port B reads a whole entry, optionally on another clock.
module sd_ram64 #(
    parameter AW = 11
) (
    input  logic          clka,
    input  logic [AW-1:0] addra,
    input  logic [1:0]    lane,
    input  logic [15:0]   da,
    input  logic [1:0]    wea,       // [1] high byte, [0] low byte
    output logic [15:0]   qa,
    input  logic          clkb,
    input  logic [AW-1:0] addrb,
    output logic [63:0]   qb
);
    logic [15:0] q [4];
    logic [1:0]  lane_q;
    always_ff @(posedge clka) lane_q <= lane;
    assign qa = q[lane_q];
    genvar i;
    generate
        for (i = 0; i < 4; i = i + 1) begin : g_lane
            sd_ram16 #(.AW(AW)) u (
                .clka(clka), .addra(addra), .da(da), .wea(lane == i ? wea : 2'b00), .qa(q[i]),
                .clkb(clkb), .addrb(addrb), .qb(qb[16 * i +: 16]));
        end
    endgenerate
endmodule
