# Vendored modules

Third-party HDL cores copied into the tree -- no submodules, so the build is self-contained and reproducible.
Each keeps its own LICENSE alongside.

| module | upstream | via | licence |
|---|---|---|---|
| cpu-fx68k (+ `../microrom.mem`, `../nanorom.mem`) | https://github.com/ijor/fx68k (Jorge Cwik) | copied unchanged from the owner's `silvmil-mister/mister/modules/cpu-fx68k` (the `crospang-mister` / `ohmygod-mister` / `metro-mister` / `mcatadv-mister` copy, the one that builds with Quartus 17 and runs in Verilator with `--no-assert-case -Wno-BLKANDNBLK`) on 2026-10-29 | GPL-3.0 |
| cpu-tv80 | https://github.com/hoglet67/tv80 (Guy Hutchison's TV80) | the five files the core needs (`tv80_alu.v`, `tv80_core.v`, `tv80_mcode.v`, `tv80_reg.v`, `tv80s_cen.v`: the clock-enable wrapper of plasticbugs/punchout), copied unchanged from the owner's `silvmil-mister/mister/modules/cpu-tv80` (the `crospang-mister` / `gaiapolis-mister` copy) on 2026-10-29 (`tv80s.v` is kept for reference, not built) | MIT |
| jt6295 (OKI M6295) | https://github.com/jotego/jt6295 (Jose Tejada) | the 8 files `hdl/jt6295*.v` (INTERPOL=0 needs no others), copied unchanged from `silvmil-mister/mister/modules/jt6295` (the `crospang-mister` / `ohmygod-mister` copy) on 2026-10-29 | GPL-3.0 |
| crt_adjust (CRT Adjust: H-Size, H-Position, V-Shift) | https://github.com/rmonic79/MiSTer-CRT-Adjust (Umberto Parisi, rmonic79) | `rtl/crt_adjust.sv` of the upstream at commit c682de9, copied unchanged from `silvmil-mister/mister/modules/crt_adjust` (the Metro core's copy) on 2026-10-29, which carries **two changes marked `METRO` in the file** (the sign extension of a negative H-Position in the content-shift mode, and the picture / vertical-blank gating with the vertical blank of the line being emitted); the glue is `../rtl/sd_crtadj.sv` | GPL-3.0-or-later |

The fx68k microcode ROM files are read with `$readmemb("microrom.mem")` / `"nanorom.mem"`, i.e. relative to the directory the simulator
or Quartus runs in: `sim/run.sh` copies them next to the binary, Quartus finds them in the project directory.

To update one: re-copy from upstream at the new commit and record it here.
