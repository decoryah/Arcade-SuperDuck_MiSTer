# Status and measurements (2026-10-30)

Every number below is from MAME 0.289 and Verilator / Quartus runs on the owner's machine; the scripts are in `../tools/`
(`tools/paths.py` says where they look for MAME, the romset and the scratch folder `work/`), the benches in `../sim/`.

**On a real MiSTer** (the owner's, 2026-10-30, the first build of `supduck_20261030`): "Game runs well".  The released
`supduck_20261030.rbf` is that RTL without the OSD's SDRAM read capture item (the capture fixed at Normal, the setting tested;
`SuperDuck.sv`); it was not tested on the board again.

## The board (from MAME's `src/mame/capcom/supduck.cpp` and `tigeroad_spr.cpp`, kept in `../../ref/mame/`)

Comad, 1992, "roughly based off Bionic Commando, close to the Tiger Road / F1-Dream based Pushman / Bouncing Balls".  Every clock
from the 8 MHz crystal:

| | |
|---|---|
| 68000 | 8 MHz; level 2 interrupt at the start of vertical blank (hold line, autovectored) |
| Z80 | 2 MHz; INT = the sound latch's "data pending" (set by the 68000's write, cleared by the Z80's read) |
| OKI M6295 | 1 MHz, pin 7 high; 00000-1FFFF fixed samples, 20000-3FFFF one of four 128 KB banks (Z80 9000: data & 3) |
| screen | 6 MHz dots, 384 x 262, 256 x 224 visible (lines 16..239), 59.637 Hz; hsync dots 306..333, vsync lines 251..253 |
| palette | 1024 entries, xRGBRRRRGGGGBBBB_bit4 (5 bits a component, bits 14 / 13 / 12 the top bits) |

* 68000 map: ROM 000000-03FFFF; sprite RAM FE0000-FE1FFF (copied to a buffer at the start of vertical blank); FE4000 P1_P2 (w: coin
  counters, high byte), FE4002 SYSTEM (w: sound latch, high byte), FE4004 DSW; FE8000-FE8007 scroll (BG x, BG y, FG x, FG y; y is
  given to the tilemap as -data - 256); text RAM FEC000-FECFFF; BG RAM FF0000-FF3FFF; FG RAM FF4000-FF7FFF; palette FF8000-FF87FF;
  work RAM FFC000-FFFFFF.  SYSTEM bit 10 is the screen's vertical blank (active low as MAME reads it).
* Z80 map: ROM 0000-7FFF, RAM 8000-87FF, 9000 OKI bank (w), 9800 OKI, A000 sound latch (r).
* Layers, back to front: BG (128 x 64 tiles of 32 x 32, opaque, colours 256-511), FG (the same, pen 15 transparent, colours 0-255),
  sprites (1024 entries, 16 x 16, from the last entry to the first, pen 15 transparent, colours 512-767), text (32 x 32 of 8 x 8,
  2 bits, pen 3 transparent, colours 768-1023).  The 32 x 32 tilemaps use the driver's own scan: pages of 8 x 8 tiles, rows upside
  down (`row ^ 63`).

## ROM path

| check | result |
|---|---|
| `tools/supduck_rom.py check`: the regions built from ROM_START (ROM_LOAD16_BYTE, ROM_LOAD32_BYTE) vs MAME's loaded regions (`tools/lua/dump_regions.lua`) | 8 regions (maincpu, audiocpu, chars, fgtiles, bgtiles, spritegen, oki, okibank) byte-identical |
| `tools/supduck_image.py check`: the loader's remap + the renderer's pixel pick vs MAME's gfx decode of the driver's layouts | 1024 FG + 1024 BG tiles of 32 x 32, 4096 sprites of 16 x 16, 2048 characters of 8 x 8: every pixel identical |
| `tools/make_mra.py`: the image `tools/mra_build.py` builds from the `.mra` and the romset vs `supduck_image.py` | byte-identical; the MRA carries MiSTer's md5 (`mra_build.mister_md5`), eaf23b3e3ca6f83cf747b401f0a1c9dd |
| DIP switch default the script derives from the driver's `INPUT_PORTS` | FFBF (DIP-A BF, DIP-B FF), MAME's |

The MRA's DIP switches are MiSTer's bit ranges: one bit is `bits="n"`, a field `bits="first,last"` with every setting of the field in
value order (Coinage `0,2`: 8 settings; Lives `6,7`: 4).

## Reference renderer (`tools/supduck_ref.py`, MAME's `screen_update` + `tigeroad_spr` written out)

Pens decoded with MAME's own layouts, independent of the core's remap.  Against the pixels MAME drew from the same state:

| states (`tools/capture.py`) | frames | differing pixels |
|---|---|---|
| no input: 100, 300, 600 (title, attract) | 3 | 0 |
| scripted play (coin 200, start 260, random joystick and buttons from 330), every 75th frame 150-4500 | 59 | 0 |
| the same play (seed 777), every 100th frame 400-3000, with `--fliptest` | 27 | 0 |

`--fliptest` (`tools/lua/dump_state.lua` FLIPTEST=1) sets the flip bits the game itself never uses at random in MAME's RAMs before a
dumped frame: tile flip X / Y on BG and FG, text flip Y, sprite flip X / Y (in the 27 states: 268 sprites on screen flipped in Y,
274 in X).  In the plain play states the game uses sprite flip X only.  Other features in the corpus: 37 different scroll states,
sprites clipped at the left, right and top edges, up to 24 sprites on screen.

## RTL, frozen states (`tools/corpus_rtl.py`)

The RTL's picture of each MAME state (tile, text, sprite and palette RAMs, the sprite buffer and the scroll registers loaded, both
CPUs held in reset) against MAME's pixels, through the real loader layout and SDRAM controller and a behavioural SDRAM chip:

| states | pixel-identical |
|---|---|
| title / attract (3) | 3 |
| scripted play (59) | 59 |
| flip test (27) | 27 |

**89 of 89 states pixel-identical.**  The longest line took 1,649 of the 6,144 clocks a line has (96 MHz / 6 MHz x 384).

## Whole machine from reset (`sim/run.sh ... +inputs=`, `tools/sys_match.py`)

The core from reset with MAME's input log (`tools/capture.py 2-700/1 --play --log`: coin at frame 200, start at 261, random joystick
and buttons from 330), every picture against MAME's picture of the same frame (`work/states/all`, every frame 2..700):

* **465 of 465 pictures identical to MAME's picture of the same frame** (frames 2..466: the boot, the attract mode, the coin, the
  start, and 136 frames of play with the random joystick and both buttons).  The run stopped at frame 466: the shell that ran the bench
  was stopped from outside (a second run to frame 480, for the sound, finished normally); no picture before that differed.
* MAME's screen starts at the beginning of vertical blank: its first vertical blank (its frame 1) comes 16.768 ms after the reset,
  a whole frame, not at line 240 of a raster starting at line 0 (`tools/lua/firstwr.lua`: the times of the game's first writes and
  of the frame notifiers).  The bench starts the core's raster at line 240 with the release of the reset; with the raster started
  at line 0 the core ran a frame ahead of MAME's game logic (every 8-frame animation step one frame off, 118 of 130 pictures
  identical).  The game's first writes then come within 50 us of MAME's (palette 11,359 / 11,353 us, text 13,701 / 13,663 us,
  scroll 18,645 / 18,600 us after the reset: the program cache's first line fills).
* 0 lines over their budget; the longest line took 1,662 of 6,144 clocks.

## Video RAM: At vblank / Live (`tools/lua/vwrites.lua`)

When the game writes each video area in MAME, in us after the start of vertical blank (line 240); the picture's first line (16)
begins 38 lines = 2,432 us after it.  The attract mode (frames 60-190) and play (400-1100: coin, start, then jump, left / right and
shot pressed by the script):

| area | attract | play | writes after line 16 began (play) |
|---|---|---|---|
| scroll | every frame, 34-60 us | every frame (701), 34-61 us | 0 |
| text | 4 frames, 235-586 us | 89 frames, 241-10,508 us | 2,050 of 10,506 |
| BG | -- | 2 frames (a scene change), 496-8,909 us | 450 of 1,088 |
| FG | -- | 2 frames, 3,637-9,107 us | 320 of 320 |
| palette | -- | 1 frame, 6,404-13,837 us | 1,664 of 1,664 |
| sprite RAM | -- | 695 frames, 0-16,768 us (the whole frame) | -- (drawn from the buffer copied at vertical blank) |

* **At vblank (MAME)**, the default: the copy at line 240 is taken before the interrupt routine writes the scroll, so the picture
  after a vertical blank shows the scroll written after the one before, and the sprite buffer copied then: MAME's picture (the
  465 frames above).
* **Live (less lag)**: the scroll written 34-61 us into vertical blank is in place long before line 16, and the renderer reads the
  sprite buffer copied at this vertical blank: scroll and sprites a frame earlier, together.  The text and tilemap writes that run
  into the picture (a score change, the two frames of a scene change) can show half old, half new for one frame.  The palette is
  read live in both settings.

## Sound (`sim/run.sh ... +inputs= +wav`, `tools/cmp_audio.py`)

The core from reset to frame 480 with the same input log, its mix (`SuperDuck.sv`, Volume Normal: the OKI's sum x 16, clipped)
against MAME's own recording of the same play (`-wavwrite -samplerate 48000`): the coin sound at 3.37 s (the Z80's one command
`82 22`: phrase 2, channel 2, attenuation step 2, logged in MAME with `tools/lua/okilog.lua`) and the game's music and effects from 6.5 s.

| | |
|---|---|
| lag | MAME 0.02 to 0.10 ms from the core (the sounds start on the same sample within 5 samples of 48 kHz) |
| envelope correlation (10 ms RMS) | 0.988 |
| level, in play (6.9-8.0 s) | MAME = 0.977 x core (-0.2 dB), residual 2.8 % of the energy (0.3 % in the best quarter second) |
| level, the coin sound (3.35-3.6 s) | peaks 12,816 (core) / 12,796 (MAME), mean 1,440 / 1,441: the same; a least-squares fit says 0.6 |

The fit is low where the sound is high-pitched because the core gives the OKI's output as the chip does, a staircase at its sample
rate (1 MHz / 132 = 7.6 kHz; jt6295 without interpolation, as in the owner's other cores), and MAME's recording is resampled to
48 kHz: the staircase's images above 3.8 kHz are energy MAME's has not got.  The peaks and the mean show the level is MAME's.

## The loader (`sim/run.sh <image> 0 <out> +load=fast | +load=rtl`)

The image pushed through `rtl/sd_mem.sv` (the RTL remap), then every SDRAM word, Z80 ROM byte and character word read back:

| run | SDRAM words differing | Z80 ROM bytes differing | character words differing |
|---|---|---|---|
| fast load (`rtl/sd_fastload.sv` from the bench's DDR3 model: busy at random, beats late and with gaps; image at 0x32000000) | 0 of 1,245,184 | 0 of 32,768 | 0 of 16,384 |
| the ordinary byte download | 0 of 1,245,184 | 0 of 32,768 | 0 of 16,384 |

The fast load takes 8.9 M clocks (0.093 s) from the end of the empty download to the last word in the SDRAM.

## The scandoubler (`sim/sd/sweep.sh`)

This core's raster (`rtl/sd_video.sv`) through CRT Adjust into the framework's `arcade_video`, 3 frames each: CRT Adjust On without
the gate and forced_scandoubler: **STALLED** (no VGA_VS: why the gate exists); with the core's gate (CRT Adjust off while the
scandoubler is in use): 448 lines, each source line twice, in order; HQ2x and CRT 25 %: 448 lines in order; 15 kHz with and without
CRT Adjust: 224 lines in order, 6,144 clocks a line.  The same results as the owner's Silver Millennium and Cross Pang cores.

## Buttons (`tools/probe.py`, the game's code)

MAME 0.289 gives each player four buttons.  The game's input routine in play (68000 0x403A) tests the joystick bits and bits 4 and 5
(buttons 1 and 2) only; bits 6 and 7 appear only in the service mode's input test (0x0EC2, every bit of the port shown).

| button | the game's code | in MAME |
|---|---|---|
| 1 | a press sets a flag (with auto-repeat every 16 frames while held); 0x395E acts on it only while `FFC362` bit 6 or bit 6 of the player's state byte is set (what sets them in play was not traced) | no effect in the scripted play (pressed at 600, 700-760, 900-1260); with `FFC362` bit 6 forced on (`tools/lua/b1poke.lua`): a shot flies straight up from the duck at every press |
| 2 | a press makes the duck jump (0x3996); ignored while `FFC362` bit 6 is set | the duck jumps to the next platform and the screen follows (differing pixels from the next frame on) |
| 3, 4 | not read | no effect |

So the MRA names two buttons, **Shot** and **Jump**; buttons 3 and 4 are not mapped.  The joysticks are 4-way as in MAME
(`PORT_4WAY`), filtered in `SuperDuck.sv` as MAME's `digital_joystick` does.

## Build (Quartus Prime Lite 17.0.2, `quartus_sh --flow compile SuperDuck`, about 25 min)

| | |
|---|---|
| ALMs | 13,149 / 41,910 (31 %) |
| block memory | 275 / 553 RAM blocks (50 %), 2.11 Mbit |
| DSP | 34 / 112 |
| PLLs | 3 / 6 |
| setup slack, machine clock (96 MHz) | +1.664 ns; the tightest setup anywhere +0.584 ns (the framework's HDMI clock); no negative slack; hold >= 0.250 ns |
| `tools/check_ram_depth.py` | 0 problems (every RAM the RTL declares, at its depth) |
| `SuperDuck.sdc` | read (`Reading SDC File: 'SuperDuck.sdc'` in the timing report) |

`releases/supduck_20261030.rbf` with its fitter, timing and RAM-depth reports; `tools/package.py` writes
`dist/SuperDuck_MiSTer_20261030.zip`.
