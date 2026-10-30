#!/usr/bin/env python3
"""Frozen-state check of the RTL: every captured MAME state is loaded into the RAMs of the bench (sim/run.sh +state=, both CPUs held in
reset) and the RTL's picture is compared with the pixels MAME drew from the same state.  (After the owner's silvmil-mister tools.)

    corpus_rtl.py <state dir> [--limit N] [--step K]   (the bench must be built: run sim/run.sh once;
                                                       SUPDUCK_BDIR picks its build directory, default $HOME/build_supduck)

Image: work/supduck.rom (built here with tools/supduck_image.py if missing).  Pictures: work/rtl_corpus/<state dir name>/.
"""
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import paths
import supduck_image
import cmp_frame


def wsl_path(p):
    p = os.path.abspath(p)
    return '/mnt/' + p[0].lower() + p[2:].replace('\\', '/')


def main(argv):
    args = [a for a in argv[1:] if not a.startswith('--')]
    if len(args) < 1:
        print(__doc__)
        return 2
    sdir = args[0]
    limit = int(argv[argv.index('--limit') + 1]) if '--limit' in argv else 0
    step = int(argv[argv.index('--step') + 1]) if '--step' in argv else 1
    rom = os.path.join(paths.WORK, 'supduck.rom')
    if not os.path.exists(rom):
        open(rom, 'wb').write(supduck_image.build())
    states = sorted(f[:-5] for f in os.listdir(sdir) if f.endswith('.regs'))[::step]
    if limit:
        states = states[:limit]
    out = os.path.join(paths.WORK, 'rtl_corpus', os.path.basename(os.path.normpath(sdir)))
    os.makedirs(out, exist_ok=True)
    # one WSL call runs the bench for every state (the first picture after the release of the reset is the state's: <out>.ppm),
    # $SUPDUCK_JOBS (default 7) at a time
    bdir = os.environ.get('SUPDUCK_BDIR', '$HOME/build_supduck')
    lines = []
    for st in states:
        p = os.path.join(out, st + '.ppm')
        if os.path.exists(p):
            os.remove(p)                      # no stale picture may pass for this run's
        lines.append('nice -n 10 ./obj/Vtb_top %s 0 %s +state=%s > /dev/null 2>&1' % (
            wsl_path(rom), wsl_path(os.path.join(out, st)), wsl_path(os.path.join(sdir, st))))
    jobs = os.path.join(out, 'jobs.txt')
    open(jobs, 'w', newline='\n').write('\n'.join(lines) + '\n')
    script = os.path.join(out, 'run.sh')
    open(script, 'w', newline='\n').write('\n'.join([
        'export PATH="$HOME/tools/oss-cad-suite/bin:$PATH"', 'cd "%s"' % bdir,
        'xargs -P %d -d "\\n" -I CMD bash -c CMD < "%s"' % (int(os.environ.get('SUPDUCK_JOBS', '7')), wsl_path(jobs))]) + '\n')
    r = subprocess.run(['wsl.exe', '--', 'bash', wsl_path(script)])
    if r.returncode:
        print('bench failed (%d)' % r.returncode)
        return 1
    total = bad = 0
    for st in states:
        ppm = os.path.join(out, st + '.ppm')
        if not os.path.exists(ppm):
            print('%s: no picture (the bench did not write it)' % st)
            total += 1
            bad += 1
            continue
        n = cmp_frame.compare(ppm, os.path.join(sdir, st), os.path.join(out, st + '.diff.png'))
        total += 1
        bad += 1 if n else 0
    print('%d of %d states pixel-identical' % (total - bad, total))
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
