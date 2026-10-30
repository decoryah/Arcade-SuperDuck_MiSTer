#!/usr/bin/env python3
"""Builds the ROM regions of Super Duck from the MAME zip, exactly as ROM_START( supduck ) in src/mame/capcom/supduck.cpp (MAME 0.289)
loads them, and checks them against MAME's own regions (tools/lua/dump_regions.lua).

    supduck_rom.py check                compare with work/regions/supduck/<region>.bin
    supduck_rom.py build <dir>          write <region>.bin

Load modes: 'n' = ROM_LOAD (plain), 'b' = ROM_LOAD16_BYTE (every second byte), 'q' = ROM_LOAD32_BYTE (every fourth byte).
"""
import os
import sys
import zipfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import paths

SET = 'supduck'
# (region, size, [(file, mode, offset, length)])
REGIONS = [
    ('maincpu', 0x40000, [('5.u16n', 'b', 0x00000, 0x20000), ('6.u16l', 'b', 0x00001, 0x20000)]),
    ('audiocpu', 0x10000, [('4.su6', 'n', 0x00000, 0x8000)]),
    ('chars', 0x08000, [('3.cu15', 'n', 0x00000, 0x8000)]),
    ('fgtiles', 0x80000, [('7.uu29', 'n', 0x00000, 0x20000), ('8.uu30', 'n', 0x20000, 0x20000),
                          ('9.uu31', 'n', 0x40000, 0x20000), ('10.uu32', 'n', 0x60000, 0x20000)]),
    ('bgtiles', 0x80000, [('11.ul29', 'n', 0x00000, 0x20000), ('12.ul30', 'n', 0x20000, 0x20000),
                          ('13.ul31', 'n', 0x40000, 0x20000), ('14.ul32', 'n', 0x60000, 0x20000)]),
    ('spritegen', 0x80000, [('15.u1d', 'q', 0x00000, 0x20000), ('16.u2d', 'q', 0x00001, 0x20000),
                            ('17.u1c', 'q', 0x00002, 0x20000), ('18.u2c', 'q', 0x00003, 0x20000)]),
    ('oki', 0x80000, [('2.su12', 'n', 0x00000, 0x20000)]),
    ('okibank', 0x80000, [('1.su13', 'n', 0x00000, 0x80000)]),
]


def open_zip():
    return zipfile.ZipFile(os.path.join(paths.ROMS, SET + '.zip'))


def get_file(z, name):
    return z.read(name)


def build():
    z = open_zip()
    out = {}
    for rname, size, entries in REGIONS:
        reg = bytearray(size)
        for fname, mode, offset, n in entries:
            data = get_file(z, fname)
            if len(data) != n:
                raise ValueError('%s: file is %d bytes, ROM_START wants %d' % (fname, len(data), n))
            step = {'n': 1, 'b': 2, 'q': 4}[mode]
            if step == 1:
                reg[offset:offset + n] = data
            else:
                reg[offset:offset + step * n:step] = data
        out[rname] = bytes(reg)
    return out


def check():
    bad = 0
    for rname, img in sorted(build().items()):
        p = os.path.join(paths.WORK, 'regions', SET, rname + '.bin')
        if not os.path.exists(p):
            print('%-10s no MAME dump (%s)' % (rname, p))
            bad += 1
            continue
        ref = open(p, 'rb').read()
        if ref == img:
            print('%-10s identical (%d bytes)' % (rname, len(img)))
        else:
            first = next((i for i in range(min(len(ref), len(img))) if ref[i] != img[i]), None)
            print('%-10s DIFFERENT: size %d vs MAME %d, first difference at %s' % (rname, len(img), len(ref), first))
            bad += 1
    return bad


def main(argv):
    if len(argv) >= 2 and argv[1] == 'check':
        return 1 if check() else 0
    if len(argv) == 3 and argv[1] == 'build':
        os.makedirs(argv[2], exist_ok=True)
        for rname, img in build().items():
            open(os.path.join(argv[2], rname + '.bin'), 'wb').write(img)
        return 0
    print(__doc__)
    return 2


if __name__ == '__main__':
    sys.exit(main(sys.argv))
