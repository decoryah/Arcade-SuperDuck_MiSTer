// Clock enables from the 96 MHz machine clock.  The board takes every clock from its 8 MHz crystal (supduck.cpp: "All clock timing
// comes from crystal 1"):
//
//   68000       8 MHz     cen_phi1 / cen_phi2, alternating, one every 6 clocks (each phase at 8 MHz)
//   Z80         2 MHz     cen_z80, every 48 clocks
//   OKI M6295   1 MHz     cen_oki, every 96 clocks (pin 7 high: sample rate 1 MHz / 132)
//
// All three are exact divisions of 96 MHz.  The dot clock (6 MHz = 96 / 16) is generated in sd_video.
`default_nettype none
module sd_cen (
    input  logic clk,
    output logic cen_phi1, cen_phi2,
    output logic cen_z80,
    output logic cen_oki
);
    logic [2:0] d6 = 3'd0;
    logic       ph = 1'b0;
    logic [5:0] d48 = 6'd0;
    logic       z2 = 1'b0;
    always_ff @(posedge clk) begin
        cen_phi1 <= 1'b0;
        cen_phi2 <= 1'b0;
        cen_z80  <= 1'b0;
        cen_oki  <= 1'b0;
        d6 <= (d6 == 3'd5) ? 3'd0 : d6 + 3'd1;
        if (d6 == 3'd5) begin
            ph <= ~ph;
            if (ph) cen_phi2 <= 1'b1; else cen_phi1 <= 1'b1;
        end
        d48 <= (d48 == 6'd47) ? 6'd0 : d48 + 6'd1;
        if (d48 == 6'd47) begin
            cen_z80 <= 1'b1;
            z2      <= ~z2;
            cen_oki <= z2;
        end
    end
endmodule
`default_nettype wire
