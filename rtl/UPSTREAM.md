# Files in this directory derived from other projects

The core's platform layer is a copy of the owner's Silver Millennium core (`silvmil-mister`, MAME's `f32/silvmil.cpp`: also a
68000 + Z80 + OKI M6295 board with a line renderer), taken on 2026-10-29.  What each file kept and what changed:

| File | Derived from | Licence | Changes for this core |
|---|---|---|---|
| `sdram_ctrl.sv` | the owner's `silvmil-mister/mister/rtl/sdram_ctrl.sv` (from `crospang-mister` / `ohmygod-mister` / `mcatadv-mister`, itself the Pocket Gaiapolis core's multi-port controller by plasticbugs, carried to MiSTer, with the Punch-Out!! core's `sdram16.sv` pin-level behaviour) | GPL-3.0-or-later (`../LICENSE`) | none: byte-identical |
| `sd_ram.sv` | `sm_ram.sv` (from `omg_ram.sv` / `mcatadv_ram.sv`: block RAMs written the way Quartus 17 infers M10K) | same | renamed; `sd_ram64` added (four 16-bit words side by side, from four `sd_ram16`: the video RAMs whose copies are swept four words a clock) |
| `sd_cache.sv` | `sm_cache.sv` (from `omg_cache.sv`) | same | renamed; the tag narrowed to the 256 KB program |
| `sd_fastload.sv` | `sm_fastload.sv` (the fast load of the owner's Monster Maulers / Violent Storm cores) | same | renamed; in `../SuperDuck.sv` it is the DDR3's only user (no frame buffer) |
| `sd_crtadj.sv` | `sm_crtadj.sv` (the Metro core's `metro_crtadj.sv`: glue for rmonic79's CRT Adjust, `../modules/crt_adjust`) | same | renamed; `VTOTAL` 262 |
| `sd_mem.sv` | `sm_mem.sv` (from `omg_mem.sv` / `mcatadv_mem.sv`: loader, burst arbiter) | same | this board's image layout and remaps (32 x 32 tiles: a row is 8 words; 16 x 16 sprites: 4 words), 8-word tile bursts, the character ROM in block RAM, the Z80 program's 32 KB, the OKI's 640 KB of samples; no configuration bytes |
| `sd_main.sv` | `sm_main.sv` | same | Super Duck's map: the 64-bit video RAMs and their copies, the double sprite buffer, the scroll registers (`-data - 256`), level 2 interrupt, SYSTEM's vertical blank bit |
| `sd_video.sv` | `sm_video.sv` (from `omg_video.sv`) | same | MAME's 384 x 262 raster in MAME's own line numbers (lines 16..239 visible), the driver's sync positions, 256-dot lines, the xRGBRRRRGGGGBBBB_bit4 palette |
| `sd_render.sv` | `sm_render.sv` (the structure: tile passes, sprite pass, line buffer) | same | rewritten for this board: 128 x 64 tilemaps of 32 x 32 tiles with the driver's tilemap_scan, the Tiger Road sprite list (1024 entries, a scanner running alongside the tile passes), the text layer from block RAM |
| `sd_core.sv` | `sm_core.sv` | same | wiring for the above; one OKI, no YM2151 |
| `pll.v`, `pll.qip`, `pll/` | the Metro core's PLL via `silvmil-mister` (reference 50 MHz: 96 MHz machine clock, 96 MHz shifted for the SDRAM chip) | same | none |
| `../sim/` | `silvmil-mister/mister/sim` (`sdram_model.sv` unchanged) | same | this board's image layout, state format and raster alignment |

Written for this core (not derived): `sd_sound.sv` (Z80, OKI with its bank register, the sound latch as the Z80's interrupt;
structure after `sm_sound.sv`), `sd_cen.sv` (the clock enables: everything divides 96 MHz exactly).  The 68000 core
(`../modules/cpu-fx68k`), the Z80 (`../modules/cpu-tv80`), the OKI (`../modules/jt6295`) and the CRT Adjust page
(`../modules/crt_adjust`) are vendored: `../modules/VENDOR.md`.
