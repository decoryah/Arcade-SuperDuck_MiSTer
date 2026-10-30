#!/usr/bin/env python3
"""Writes the core's .mra from the ROM_START table (tools/supduck_rom.py), the image layout (tools/supduck_image.py) and the DSW
definitions of the driver's INPUT_PORTS (MAME's supduck.cpp: tools/paths.py MAME_SRC), and checks it: the image tools/mra_build.py
assembles from the .mra and the romset must be byte-identical to supduck_image.py's.  (After the owner's silvmil-mister make_mra.py.)

    make_mra.py [outdir]          default mra/

DIP switches: one <dip> per MAME PORT_DIPNAME, its bits as MiSTer's range "first,last" (one bit: "n"; MiSTer reads a list of bits as
a range, so "0,1,2" would be bits 0..1), its settings in the order of the field's value 0, 1, 2 ...
"""
import os
import re
import sys
import zlib

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import paths
import supduck_rom
import supduck_image as IMG

TITLE, YEAR, MAKER = 'Super Duck', 1992, 'Comad'

# What the buttons do (pressing each in MAME 0.289: tools/probe.py; the game's input routine at 0x403A, docs/status.md).  MAME's
# INPUT_PORTS give each player four buttons; the game reads only the first two (buttons 3 and 4 appear only in the service mode's
# input test), so only those are mapped.
#   button 1: a shot straight up from the duck -- the game acts on it only in some states (0x395E: FFC362 bit 6 or a player state bit)
#   button 2: the duck jumps to the next platform (the screen follows)
BUTTONS = ['Shot', 'Jump']


def crc_of(z, fname):
    return '%08x' % (zlib.crc32(supduck_rom.get_file(z, fname)) & 0xffffffff)


def rom_lines():
    z = supduck_rom.open_zip()
    reg = {r: entries for r, size, entries in supduck_rom.REGIONS}
    L = []

    def plain(fname, length, comment=None):
        if comment:
            L.append('        <!-- %s -->' % comment)
        L.append('        <part name="%s" crc="%s" offset="0x0" length="0x%x"/>' % (fname, crc_of(z, fname), length))

    # maincpu: ROM_LOAD16_BYTE, 5.u16n the even (high) bytes, 6.u16l the odd (low) ones; the image has each word low byte first
    (hi, _, _, n), (lo, _, _, _) = reg['maincpu']
    L.append('        <!-- maincpu: the 68000 program, each word low byte first -->')
    L.append('        <interleave output="16">')
    L.append('            <part name="%s" crc="%s" offset="0x0" length="0x%x" map="01"/>' % (lo, crc_of(z, lo), n))
    L.append('            <part name="%s" crc="%s" offset="0x0" length="0x%x" map="10"/>' % (hi, crc_of(z, hi), n))
    L.append('        </interleave>')
    first = True
    for fname, mode, off, n in reg['fgtiles']:
        plain(fname, n, 'fgtiles: the FG tile ROM (the core remaps it as it loads)' if first else None)
        first = False
    first = True
    for fname, mode, off, n in reg['bgtiles']:
        plain(fname, n, 'bgtiles: the BG tile ROM' if first else None)
        first = False
    # spritegen: ROM_LOAD32_BYTE, byte k of every four from the k-th file
    L.append('        <!-- spritegen: the sprite ROM, ROM_LOAD32_BYTE -->')
    L.append('        <interleave output="32">')
    for fname, mode, off, n in reg['spritegen']:
        m = ['0', '0', '0', '0']
        m[3 - off] = '1'
        L.append('            <part name="%s" crc="%s" offset="0x0" length="0x%x" map="%s"/>' % (fname, crc_of(z, fname), n, ''.join(m)))
    L.append('        </interleave>')
    plain(reg['oki'][0][0], reg['oki'][0][3], 'oki: the fixed samples, then okibank: the four banks')
    plain(reg['okibank'][0][0], reg['okibank'][0][3])
    plain(reg['audiocpu'][0][0], reg['audiocpu'][0][3], 'audiocpu: the Z80 program (32 KB)')
    plain(reg['chars'][0][0], reg['chars'][0][3], 'chars: the text layer\'s characters')
    return L


# ---- DIP switches from the driver's INPUT_PORTS
def def_str(s):
    s = s.strip()
    m = re.match(r'DEF_STR\s*\(\s*(\w+)\s*\)', s)
    if m:
        v = m.group(1)
        if re.match(r'^\d+C_\d+C$', v):
            return v.replace('_', '/')
        return v.replace('_', ' ')
    m = re.match(r'"(.*)"$', s)
    return m.group(1) if m else s


def parse_dips(dsw):
    dips = []                     # [mask, default, name, {value: label}]
    for line in dsw.splitlines():
        line = re.sub(r'/\*.*?\*/', '', line.split('//')[0]).strip()       # the driver's comments: // and /* */
        m = re.match(r'PORT_DIPNAME\(\s*(0x[0-9a-fA-F]+)\s*,\s*(0x[0-9a-fA-F]+)\s*,\s*(.*?)\s*\)\s*(PORT_DIPLOCATION\(\s*"(.*?)"\s*\))?$', line)
        if m:
            dips.append([int(m.group(1), 16), int(m.group(2), 16), def_str(m.group(3)), {}, m.group(5)])
            continue
        m = re.match(r'PORT_DIPSETTING\(\s*(0x[0-9a-fA-F]+)\s*,\s*(.*?)\s*\)$', line)
        if m:
            dips[-1][3][int(m.group(1), 16)] = def_str(m.group(2))
            continue
        m = re.match(r'PORT_SERVICE_DIPLOC\(\s*(0x[0-9a-fA-F]+)\s*,\s*IP_ACTIVE_LOW\s*,\s*"(.*?)"\s*\)', line)
        if m:
            mask = int(m.group(1), 16)
            dips.append([mask, mask, 'Service Mode', {mask: 'Off', 0: 'On'}, m.group(2)])
            continue
    return dips


def dsw_dips():
    src = open(paths.MAME_SRC, encoding='utf-8').read()
    blk = re.search(r'INPUT_PORTS_START\(\s*supduck\s*\)(.*?)INPUT_PORTS_END', src, re.S).group(1)
    return parse_dips(blk[blk.index('PORT_START("DSW")'):])


def dip_bits(bits):
    """A <dip>'s bits: one bit, or the range "first,last" (MiSTer's form; not a list of every bit)."""
    assert bits == list(range(bits[0], bits[-1] + 1)), bits  # a field is contiguous bits
    return str(bits[0]) if len(bits) == 1 else '%d,%d' % (bits[0], bits[-1])


def switches_lines():
    default = 0xFFFF
    lines = []
    for mask, dflt, name, settings, loc in dsw_dips():
        bits = [b for b in range(16) if mask >> b & 1]
        default = (default & ~mask) | dflt
        ids = []
        for v in range(1 << len(bits)):
            val = sum(((v >> i) & 1) << b for i, b in enumerate(bits))
            # MiSTer splits ids at commas
            ids.append(settings.get(val, 'Unknown (%d)' % v).replace(',', ' /'))
        if name == 'Unknown' and loc:
            name = '%s - Unknown' % loc
        lines.append('        <dip bits="%s" name="%s" ids="%s"/>' % (dip_bits(bits), name.replace('"', ''), ','.join(ids)))
    head = '    <switches default="%02X,%02X" base="16">' % (default & 0xFF, default >> 8)
    return [head] + lines + ['    </switches>'], default


def mra_text():
    sw, default = switches_lines()
    out = ['<misterromdescription>',
           '    <name>%s</name>' % TITLE,
           '    <setname>supduck</setname>',
           '    <mameversion>0289</mameversion>',
           '    <year>%d</year>' % YEAR,
           '    <manufacturer>%s</manufacturer>' % MAKER,
           '    <players>2</players>',
           '    <joystick>4</joystick>',                 # PORT_4WAY
           '    <rotation>horizontal</rotation>',
           '    <rbf>supduck</rbf>',
           '    <platform>Comad</platform>',
           '',
           '    <!--',
           '      Image for the Super Duck core (rtl/sd_mem.sv, tools/supduck_image.py):',
           '',
           '        0x000000  68000 program (256 KB, each word low byte first)',
           '        0x040000  FG tiles (512 KB)         0x0C0000  BG tiles (512 KB)         0x140000  sprites (512 KB)',
           '        0x1C0000  OKI M6295 samples: the fixed 128 KB, then the four 128 KB banks',
           '        0x260000  Z80 program (32 KB)       0x268000  characters (32 KB)',
           '',
           '      Made by tools/make_mra.py from MAME 0.289 (src/mame/capcom/supduck.cpp); parts are found by name and CRC.',
           '',
           '      DIP switches (ioctl index 254): byte 0 is DIP-A (bits 7:0 of MAME\'s DSW port), byte 1 is DIP-B (bits 15:8); a 1 is',
           '      "off".  MAME\'s default is %04X.' % default,
           '    -->']
    out += sw
    # address=: fast load -- a recent Main_MiSTer copies the assembled image into the DDR3 at that byte address and sends an empty
    # download instead of the bytes (rtl/sd_fastload.sv reads it back); an older one ignores the attribute
    out += ['', '    <rom index="0" zip="supduck.zip" md5="None" address="0x32000000">']
    out += rom_lines()
    # the core's joystick bits 4..7 (SuperDuck.sv): button 1, button 2, start, coin
    out += ['    </rom>', '',
            '    <buttons names="%s,Start,Coin" default="A,B,Start,Select"/>' % ','.join(BUTTONS),
            '</misterromdescription>', '']
    return '\n'.join(out), default


def main(argv):
    import mra_build
    outdir = argv[1] if len(argv) > 1 else os.path.join(paths.REPO, 'mra')
    os.makedirs(outdir, exist_ok=True)
    text, default = mra_text()
    path = os.path.join(outdir, TITLE + '.mra')
    open(path, 'w', encoding='utf-8', newline='\n').write(text)
    zipp = os.path.join(paths.ROMS, 'supduck.zip')
    # the md5 MiSTer computes: each part's data as read, in order (Main_MiSTer support/arcade/mra_loader.cpp) -- with interleaved
    # parts that is not the image's md5, and MiSTer does not send a ROM whose md5 does not match
    md5 = mra_build.mister_md5(path, zipp)
    text = text.replace('md5="None"', 'md5="%s"' % md5, 1)
    open(path, 'w', encoding='utf-8', newline='\n').write(text)
    img, md5_check = mra_build.build(path, zipp)
    ok = img == IMG.build() and md5_check == md5
    print('%s: %s, MiSTer md5 %s, DSW default %04X' % (os.path.relpath(path, outdir), 'image identical' if ok else 'IMAGE DIFFERS',
                                                       md5, default))
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main(sys.argv))
