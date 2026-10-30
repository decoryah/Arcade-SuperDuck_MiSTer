#!/usr/bin/env python3
"""The core's ROM image (the bytes the MRA delivers, rtl/sd_mem.sv's layout) and a check of the graphics path.

    supduck_image.py build <out.rom>     write the image
    supduck_image.py check               the loader's remap + the renderer's pixel pick (rtl/sd_mem.sv, rtl/sd_render.sv, written out
                                         below) against MAME's gfx decode of the driver's layouts, for every tile, sprite and character

Image layout (byte offsets):
  0x000000  68000 program (256 KB, each word low byte first)
  0x040000  FG tiles ("fgtiles", 512 KB)       0x0C0000  BG tiles ("bgtiles", 512 KB)       0x140000  sprites ("spritegen", 512 KB)
  0x1C0000  OKI samples: "oki" 128 KB, then "okibank" 512 KB
  0x260000  Z80 program (32 KB)                0x268000  characters ("chars", 32 KB)
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import supduck_rom

O_MAIN, O_FG, O_BG, O_SPR, O_OKI, O_OKIB, O_Z80, O_CHR = 0x000000, 0x040000, 0x0C0000, 0x140000, 0x1C0000, 0x1E0000, 0x260000, 0x268000
IMG_SIZE = 0x270000
SD_WORDS = 0x130000                    # image words stored in the SDRAM (everything before the Z80 program)


def build(regions=None):
    r = regions or supduck_rom.build()
    img = bytearray(IMG_SIZE)
    m = r['maincpu']
    img[O_MAIN:O_MAIN + 0x40000:2] = m[1::2]          # each word low byte first
    img[O_MAIN + 1:O_MAIN + 0x40000:2] = m[0::2]
    img[O_FG:O_FG + 0x80000] = r['fgtiles']
    img[O_BG:O_BG + 0x80000] = r['bgtiles']
    img[O_SPR:O_SPR + 0x80000] = r['spritegen']
    img[O_OKI:O_OKI + 0x20000] = r['oki'][:0x20000]
    img[O_OKIB:O_OKIB + 0x80000] = r['okibank']
    img[O_Z80:O_Z80 + 0x8000] = r['audiocpu'][:0x8000]
    img[O_CHR:O_CHR + 0x8000] = r['chars']
    return bytes(img)


# ---- rtl/sd_mem.sv's remap (word address of the image -> word address of the SDRAM)
SD_FG, SD_BG, SD_SPR, SD_PCM = 0x020000, 0x060000, 0x0A0000, 0x0E0000


def remap(wa):
    if SD_FG <= wa < SD_SPR:
        base = SD_FG if wa < SD_BG else SD_BG
        r = wa - base
        return base + (((r >> 7) & 0x3ff) << 8 | (r & 31) << 3 | ((r >> 5) & 3) << 1 | ((r >> 17) & 1))
    if SD_SPR <= wa < SD_PCM:
        r = wa - SD_SPR
        return SD_SPR + (((r >> 6) & 0xfff) << 6 | ((r >> 1) & 15) << 2 | ((r >> 5) & 1) << 1 | (r & 1))
    return wa


def sdram(img):
    """The SDRAM's words after the load: a list indexed by SDRAM word address."""
    mem = [0] * SD_WORDS
    for wa in range(SD_WORDS):
        mem[remap(wa)] = img[2 * wa] | img[2 * wa + 1] << 8
    return mem


# ---- rtl/sd_render.sv's pixel picks
def tile_pen(mem, base, code, x, y):
    """The pen of pixel (x, y) of tile `code` (32 x 32), no flips."""
    a = base + (code << 8 | y << 3)
    g, q = x >> 3, x & 7
    w0, w1 = mem[a + (g << 1)], mem[a + (g << 1 | 1)]
    b0 = (w0 >> 8) if q & 4 else (w0 & 0xff)
    b1 = (w1 >> 8) if q & 4 else (w1 & 0xff)
    qq = q & 3
    return (b1 >> (3 - qq) & 1) << 3 | (b1 >> (7 - qq) & 1) << 2 | (b0 >> (3 - qq) & 1) << 1 | (b0 >> (7 - qq) & 1)


def sprite_pen(mem, code, x, y):
    a = SD_SPR + (code << 6 | y << 2)
    h = x >> 3
    wa, wb = mem[a + (h << 1)], mem[a + (h << 1 | 1)]
    b = 7 - (x & 7)
    return (wa >> b & 1) << 3 | (wa >> (8 + b) & 1) << 2 | (wb >> b & 1) << 1 | (wb >> (8 + b) & 1)


def char_words(img):
    c = img[O_CHR:O_CHR + 0x8000]
    return [c[2 * i] | c[2 * i + 1] << 8 for i in range(0x4000)]


def char_pen(cw, code, x, y):
    w = cw[code << 3 | y]
    b = (w >> 8) if x & 4 else (w & 0xff)
    q = x & 3
    return (b >> (3 - q) & 1) << 1 | (b >> (7 - q) & 1)


# ---- MAME's gfx decode (emu/drawgfx.cpp: bit n of the region is bit 7 - n % 8 of byte n / 8; planeoffset[0] is the pen's top bit)
def step(start, inc, n):
    return [start + inc * i for i in range(n)]


def decode(region, planes, xs, ys, inc, code):
    out = []
    base = code * inc
    for yo in ys:
        row = []
        for xo in xs:
            pen = 0
            for po in planes:
                bit = base + po + yo + xo
                pen = pen << 1 | ((region[bit >> 3] >> (7 - (bit & 7))) & 1)
            row.append(pen)
        out.append(row)
    return out


def tile_layout(rlen):
    half = rlen * 8 // 2
    planes = [half + 4, half + 0, 4, 0]
    xs = step(0, 1, 4) + step(8, 1, 4) + step(4 * 2 * 2 * 32, 1, 4) + step(4 * 2 * 2 * 32 + 8, 1, 4) + \
         step(4 * 2 * 2 * 64, 1, 4) + step(4 * 2 * 2 * 64 + 8, 1, 4) + step(4 * 2 * 2 * 96, 1, 4) + step(4 * 2 * 2 * 96 + 8, 1, 4)
    ys = step(0, 4 * 2 * 2, 32)
    return planes, xs, ys, 256 * 8


SPR_LAYOUT = ([0, 8, 16, 24], step(0, 1, 8) + step(8 * 4 * 16, 1, 8), step(0, 8 * 4, 16), 16 * 16 * 4)
CHR_LAYOUT = ([4, 0], step(0, 1, 4) + step(8, 1, 4), step(0, 16, 8), 128)


def check():
    regions = supduck_rom.build()
    img = build(regions)
    mem = sdram(img)
    cw = char_words(img)
    bad = 0
    for name, base in (('fgtiles', SD_FG), ('bgtiles', SD_BG)):
        lay = tile_layout(len(regions[name]))
        n = 0
        for code in range(1024):
            ref = decode(regions[name], *lay, code)
            for y in range(32):
                for x in range(32):
                    if tile_pen(mem, base, code, x, y) != ref[y][x]:
                        n += 1
        print('%-9s 1024 tiles of 32 x 32: %d differing pixels' % (name, n))
        bad += n
    n = 0
    for code in range(4096):
        ref = decode(regions['spritegen'], *SPR_LAYOUT, code)
        for y in range(16):
            for x in range(16):
                if sprite_pen(mem, code, x, y) != ref[y][x]:
                    n += 1
    print('spritegen 4096 sprites of 16 x 16: %d differing pixels' % n)
    bad += n
    n = 0
    for code in range(2048):
        ref = decode(regions['chars'], *CHR_LAYOUT, code)
        for y in range(8):
            for x in range(8):
                if char_pen(cw, code, x, y) != ref[y][x]:
                    n += 1
    print('chars     2048 characters of 8 x 8: %d differing pixels' % n)
    bad += n
    return bad


def main(argv):
    if len(argv) == 3 and argv[1] == 'build':
        open(argv[2], 'wb').write(build())
        print('%s: %d bytes' % (argv[2], IMG_SIZE))
        return 0
    if len(argv) == 2 and argv[1] == 'check':
        return 1 if check() else 0
    print(__doc__)
    return 2


if __name__ == '__main__':
    sys.exit(main(sys.argv))
