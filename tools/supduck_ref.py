#!/usr/bin/env python3
"""Reference renderer: MAME's supduck_state::screen_update (src/mame/capcom/supduck.cpp) and tigeroad_spr_device::draw_sprites written
out, drawing a frozen MAME state (tools/lua/dump_state.lua) and comparing it with the pixels MAME drew from it.

    supduck_ref.py <state dir> [--png]      every f<N> in the folder; --png also writes f<N>.ref.png

The pens are decoded from the ROM regions with MAME's own layouts (tools/supduck_image.py decode()), independently of the core's
remap.  Prints the differing pixels of every frame and the total.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import supduck_rom
import supduck_image as IMG
import pngio

W, H, VTOP = 256, 224, 16                 # the visible area: dots 0..255 of lines 16..239


def words(path):
    return [int(x, 16) for x in open(path).read().split()]


def regs(path):
    t = open(path).read().split()
    return int(t[0]), [(-1 if v == '-1' else int(v, 16)) for v in t[1:5]]


class Gfx:
    def __init__(self):
        r = supduck_rom.build()
        self.r = r
        self.lay_t = IMG.tile_layout(0x80000)
        self.cache = {}

    def get(self, kind, code):
        k = (kind, code)
        if k not in self.cache:
            if kind == 'fg':
                self.cache[k] = IMG.decode(self.r['fgtiles'], *self.lay_t, code)
            elif kind == 'bg':
                self.cache[k] = IMG.decode(self.r['bgtiles'], *self.lay_t, code)
            elif kind == 'spr':
                self.cache[k] = IMG.decode(self.r['spritegen'], *IMG.SPR_LAYOUT, code)
            else:
                self.cache[k] = IMG.decode(self.r['chars'], *IMG.CHR_LAYOUT, code)
        return self.cache[k]


def pal5(v):
    return (v << 3) | (v >> 2)


def pal_rgb(p):
    # palette_device::xRGBRRRRGGGGBBBB_bit4
    r = ((p >> 8) & 0x0f) | ((p >> 10) & 0x10)
    g = ((p >> 4) & 0x0f) | ((p >> 9) & 0x10)
    b = (p & 0x0f) | ((p >> 8) & 0x10)
    return pal5(r), pal5(g), pal5(b)


def tilemap_scan(col, row):
    # supduck_state::tilemap_scan
    offset = ((col & ~7) // 8) * 64
    offset += ((row ^ 0x3f) & 7) * 8
    offset += col & 7
    offset &= 0x3ff
    offset += (((row ^ 0x3f) & ~7) // 8) * 0x400
    return offset


def render(gfx, pre):
    frame, R = regs(pre + '.regs')
    bg, fg, tx, spr, pal = (words(pre + s) for s in ('.bg', '.fg', '.tx', '.spr', '.pal1'))
    # scroll_w: x = data, y = -data - 256; a register never written leaves the tilemap's scroll at 0
    bsx = R[0] if R[0] >= 0 else 0
    bsy = (-R[1] - 256) if R[1] >= 0 else 0
    fsx = R[2] if R[2] >= 0 else 0
    fsy = (-R[3] - 256) if R[3] >= 0 else 0
    bmp = [[0] * W for _ in range(H)]                 # pen indexes; bitmap.fill(black_pen) then BG covers everything

    def layer(ram, kind, sx, sy, base, opaque):
        for yy in range(H):
            ty = (yy + VTOP + sy) & 2047
            for x in range(W):
                tx_ = (x + sx) & 4095
                d = ram[tilemap_scan(tx_ >> 5, ty >> 5)]
                code = (d & 0xff) | (0x100 if d & 0x4000 else 0) | (0x200 if d & 0x8000 else 0)
                color = (d & 0x0f00) >> 8
                px, py = tx_ & 31, ty & 31
                if d & 0x2000:
                    px = 31 - px
                if d & 0x1000:
                    py = 31 - py
                pen = gfx.get(kind, code)[py][px]
                if opaque or pen != 15:
                    bmp[yy][x] = base + color * 16 + pen

    layer(bg, 'bg', bsx, bsy, 256, True)
    layer(fg, 'fg', fsx, fsy, 0, False)

    # tigeroad_spr_device::draw_sprites(..., flip_screen false, rev_y true): from the last entry to the first
    def sext9(v):
        v &= 0x1ff
        return v - 0x200 if v & 0x100 else v
    for i in range(1023, -1, -1):
        code = spr[4 * i] % 4096
        attr = spr[4 * i + 1]
        sy = 240 - sext9(spr[4 * i + 2])
        sx = sext9(spr[4 * i + 3])
        fx, fy, color = attr & 2, attr & 1, (attr >> 2) & 0x0f
        g = gfx.get('spr', code)
        for r in range(16):
            yy = sy + r - VTOP
            if not 0 <= yy < H:
                continue
            srow = g[15 - r if fy else r]
            for c in range(16):
                x = sx + c
                if not 0 <= x < W:
                    continue
                pen = srow[15 - c if fx else c]
                if pen != 15:
                    bmp[yy][x] = 512 + color * 16 + pen

    # text: 32 x 32 of 8 x 8, scan rows, not scrolled; pen 3 transparent
    for yy in range(H):
        y = yy + VTOP
        for x in range(W):
            d = tx[(y >> 3) * 32 + (x >> 3)]
            attr = d >> 8
            code = (d & 0xff) + ((attr & 0xc0) << 2) + ((attr & 0x20) << 5)
            color = attr & 0x0f
            py = y & 7
            if attr & 0x10:
                py = 7 - py
            pen = gfx.get('chr', code)[py][x & 7]
            if pen != 3:
                bmp[yy][x] = 768 + color * 4 + pen

    out = bytearray(W * H * 3)
    lut = [pal_rgb(p) for p in pal]
    for yy in range(H):
        for x in range(W):
            j = (yy * W + x) * 3
            out[j:j + 3] = bytes(lut[bmp[yy][x]])
    return frame, bytes(out)


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 2
    d = argv[1]
    png = '--png' in argv
    gfx = Gfx()
    total, nf = 0, 0
    for name in sorted(os.listdir(d)):
        if not name.endswith('.regs'):
            continue
        pre = os.path.join(d, name[:-5])
        if not os.path.exists(pre + '.rgb'):
            continue
        frame, img = render(gfx, pre)
        ref = open(pre + '.rgb', 'rb').read()
        n = sum(1 for i in range(0, len(ref), 3) if ref[i:i + 3] != img[i:i + 3])
        total += n
        nf += 1
        print('f%05d: %d differing pixels' % (frame, n))
        if png:
            pngio.write(pre + '.ref.png', W, H, img)
    print('%d frames, %d differing pixels in all' % (nf, total))
    return 1 if total else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
