#!/usr/bin/env python3
"""Runs MAME 0.289 headless on supduck and dumps frame states + MAME's pixels (tools/lua/dump_state.lua).

    capture.py <frames> [outdir] [--play] [--seed N] [--log] [--buttons N]

  <frames>   machine frames to capture, e.g. 300  or  150,300,600  or  150-3600/150 (first-last/step)
  outdir     default work/states/supduck
  --play     scripted inputs (coin at 200, start at 260, random joystick / buttons from 330); default: no inputs
  --log      also write wr.log (the 68000's writes to FE4000-FE800F) and inputs.log (replay of the port values)
  --fliptest set the flip bits of tiles, text and sprites at random in MAME's RAMs before each dumped frame (features the game leaves
             unused)

Then: supduck_ref.py <outdir>   compares the reference renderer with the pixels MAME drew.
(After the owner's silvmil-mister tools/capture.py.)
"""
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import paths


def main(argv):
    opts = {}
    args = []
    i = 1
    while i < len(argv):
        a = argv[i]
        if a in ('--seed', '--buttons'):
            opts[a] = argv[i + 1]
            i += 2
            continue
        if a.startswith('--'):
            opts[a] = True
        else:
            args.append(a)
        i += 1
    if not args:
        print(__doc__)
        return 2
    frames = args[0]
    out = os.path.abspath(args[1]) if len(args) > 1 else os.path.join(paths.WORK, 'states', 'supduck')
    os.makedirs(out, exist_ok=True)
    for sub in ('cfg', 'nvram'):
        os.makedirs(os.path.join(paths.WORK, sub), exist_ok=True)
    env = dict(os.environ, DUMPDIR=out, DUMPFRAMES=frames, SCHEDULE='play' if '--play' in opts else 'none')
    if '--seed' in opts:
        env['SEED'] = opts['--seed']
    if '--fliptest' in opts:
        env['FLIPTEST'] = '1'
    if '--buttons' in opts:
        env['BUTTONS'] = opts['--buttons']
    if '--log' in opts:
        env['WRLOG'] = os.path.join(out, 'wr.log')
        env['INPUTLOG'] = os.path.join(out, 'inputs.log')
    last = max(int(x) for part in frames.split(',') for x in
               ((part.split('-')[1].split('/')[0],) if '-' in part else (part,)))
    cmd = [paths.MAME, 'supduck', '-rompath', paths.ROMS, '-cfg_directory', os.path.join(paths.WORK, 'cfg'),
           '-nvram_directory', os.path.join(paths.WORK, 'nvram'), '-video', 'none', '-sound', 'none', '-nothrottle',
           '-skip_gameinfo', '-autoboot_script', os.path.join(paths.LUA, 'dump_state.lua'),
           '-seconds_to_run', str(last // 59 + 30)]
    r = subprocess.run(cmd, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, universal_newlines=True)
    for line in r.stdout.splitlines():
        if line.startswith('PIXELS') or 'rror' in line:
            print(line)
    n = sum(1 for f in os.listdir(out) if f.endswith('.regs'))
    print('supduck: %d states in %s (MAME exit %d)' % (n, out, r.returncode))
    return 0 if n else 1


if __name__ == '__main__':
    sys.exit(main(sys.argv))
