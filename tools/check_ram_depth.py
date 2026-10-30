#!/usr/bin/env python3
"""Check the RAMs Quartus actually built against the depths the RTL declares (from the owner's ohmygod-mister/mister/tools/check_ram_depth.py).

    check_ram_depth.py <SuperDuck.fit.rpt> [--list]

A simulator evaluates an array exactly as declared; Quartus 17 does not always (a two-dimensional unpacked array was once built half as deep,
invisible in every bench and broken on the board).  Run this on every fit report; it exits 1 if a listed memory is shallower than its
minimum, or is missing.
"""
import re
import sys

# (instance name fragment, minimum words, minimum width)
EXPECT = [
    # the line buffer: {bank, x[7:0]} = 512 words of 10 bits
    ("sd_video:u_video|sd_sdp:u_lb|altsyncram", 512, 10),
    # the 68000 board's RAMs (sd_ram16: two byte-wide halves each; sd_ram64: four sd_ram16 side by side) and the renderer's copies
    ("sd_main:u_main|sd_ram16:u_ram|altsyncram", 8192, 8),
    ("sd_main:u_main|sd_ram16:u_pal|altsyncram", 1024, 8),
    ("sd_main:u_main|sd_ram64:u_bg|sd_ram16:g_lane[0].u|altsyncram", 2048, 8),
    ("sd_main:u_main|sd_ram64:u_bg|sd_ram16:g_lane[3].u|altsyncram", 2048, 8),
    ("sd_main:u_main|sd_ram64:u_fg|sd_ram16:g_lane[0].u|altsyncram", 2048, 8),
    ("sd_main:u_main|sd_ram64:u_fg|sd_ram16:g_lane[3].u|altsyncram", 2048, 8),
    ("sd_main:u_main|sd_ram64:u_tx|sd_ram16:g_lane[0].u|altsyncram", 512, 8),
    ("sd_main:u_main|sd_ram64:u_spr|sd_ram16:g_lane[0].u|altsyncram", 1024, 8),
    ("sd_main:u_main|sd_ram64:u_spr|sd_ram16:g_lane[3].u|altsyncram", 1024, 8),
    ("sd_main:u_main|sd_sdp:u_bg_d|altsyncram", 2048, 64),
    ("sd_main:u_main|sd_sdp:u_fg_d|altsyncram", 2048, 64),
    ("sd_main:u_main|sd_sdp:u_tx_d|altsyncram", 256, 64),
    ("sd_main:u_main|sd_sdp:u_sp_d|altsyncram", 2048, 36),
    # the renderer's sprite list
    ("sd_render:u_render|sd_sdp:u_list|altsyncram", 1024, 30),
    # the program cache
    ("sd_cache:u_cache|sd_sdp:u_dat|altsyncram", 8192, 16),
    ("sd_cache:u_cache|sd_sdp:u_tag|altsyncram", 1024, 5),
    # the sound board: the Z80 program (32 KB) and RAM (2 KB)
    ("sd_sound:u_sound|sd_sdp:u_rom|altsyncram", 32768, 8),
    ("sd_sound:u_sound|sd_ram8:u_ram|altsyncram", 2048, 8),
    # the character ROM (32 KB)
    ("sd_mem:u_mem|sd_sdp:u_chars|altsyncram", 16384, 16),
]


def main():
    path = sys.argv[1]
    ram = []
    for line in open(path, errors="replace"):
        if "|ALTSYNCRAM" not in line or not line.startswith(";"):
            continue
        f = [c.strip() for c in line.split(";")]
        # ; name ; type ; mode ; clocks ; words ; width ; words ; width ; ...
        try:
            ram.append((f[1], int(f[5]), int(f[6])))
        except (IndexError, ValueError):
            continue
    if "--list" in sys.argv:
        for n, w, b in ram:
            print("%6d x %-3d %s" % (w, b, n))
    bad = 0
    for frag, wmin, bmin in EXPECT:
        hits = [(n, w, b) for n, w, b in ram if frag in n]
        if not hits:
            print("MISSING  %-52s (expected >= %d x %d)" % (frag, wmin, bmin))
            bad += 1
            continue
        for n, w, b in hits:
            # a wide RAM may be split into several blocks side by side; only depth matters here
            ok = w >= wmin
            if not ok:
                bad += 1
            print("%s  %-52s %6d x %-3d (>= %d)" % ("ok     " if ok else "TOO SHALLOW", frag, w, b, wmin))
    print("%d problem(s)" % bad)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
