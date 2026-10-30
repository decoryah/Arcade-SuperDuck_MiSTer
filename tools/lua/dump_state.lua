-- Freezes frames of Super Duck and writes everything the reference renderer needs, together with the exact pixels MAME drew for that
-- frame (screen:pixels(): the visible 256 x 224).  (After the owner's silvmil-mister tools/lua/dump_state.lua.)
--
--   DUMPFRAMES=<f,f,f...>  machine frames to capture (the vertical blank that ends frame f; also a range a-b/step as "a-b/s")
--   DUMPDIR=<dir>          output directory
--   SCHEDULE=play|none     scripted inputs: play = coin / start / random joystick and buttons (default none)
--   SEED=<n>               seed of the random play
--   COIN_FRAME=<n>, START_FRAME=<n>, PLAY_FRAME=<n>   (defaults 200, 260, 330)
--   BUTTONS=<n>            how many of the four buttons the random play presses (default 4)
--   INPUTLOG=<file>        the port values of the scripted play, as "frame p1p2 system" lines when they change
--   WRLOG=<file>           log of the 68000's writes to FE4000-FE800F: frame addr data mask
--   FLIPTEST=1             set the flip bits of tiles, text and sprites at random before each dumped frame (below)
--
-- For every captured frame <N>:
--   f<N>.regs     frame, then the four scroll registers FE8000..FE8006 (raw, as last written; -1 never written)
--   f<N>.bg       FF0000-FF3FFF, one 16-bit word per line (hex; 8192 words)
--   f<N>.fg       FF4000-FF7FFF
--   f<N>.tx       FEC000-FECFFF (2048 words)
--   f<N>.spr      the sprite buffer the frame is drawn from: FE0000-FE1FFF as it was at the vertical blank before (4096 words;
--                 buffered_spriteram16_device copies the RAM after the frame is drawn)
--   f<N>.pal1     FF8000-FF87FF one callback later (MAME converts pen indexes to RGB when the pixels are read)
--   f<N>.rgb      256 x 224 x 3 bytes, the frame MAME drew from exactly this state (taken one callback later)
local mach = manager.machine
local sp   = mach.devices[":maincpu"].spaces["program"]
local scr  = mach.screens[":screen"]
local KEEP = {}
_G.DUMPKEEP = KEEP

local DIR = os.getenv("DUMPDIR") or "."

local function absframe()
  local t = mach.time
  t = (type(t) == "number") and t or t:as_double()
  return math.floor(t * 6000000 / (384 * 262) + 0.5)
end
local f = absframe()

-- scroll registers FE8000..FE8007 as last written (scroll_w: data &= mem_mask)
local R = { -1, -1, -1, -1 }
local wrlog
if os.getenv("WRLOG") then wrlog = assert(io.open(os.getenv("WRLOG"), "w")) end
KEEP.t1 = sp:install_write_tap(0xfe8000, 0xfe8007, "scroll", function(off, data, mask)
  local i = ((off & 6) >> 1) + 1
  R[i] = data & mask & 0xffff
  if wrlog then wrlog:write(string.format("%d %06x %04x %04x\n", f, off, data & 0xffff, mask & 0xffff)) end
end)
if wrlog then
  KEEP.t2 = sp:install_write_tap(0xfe4000, 0xfe4005, "io", function(off, data, mask)
    wrlog:write(string.format("%d %06x %04x %04x\n", f, off, data & 0xffff, mask & 0xffff))
  end)
end

-- frame list
local FRAMES = {}
local LAST = 0
for item in string.gmatch(os.getenv("DUMPFRAMES") or "300", "[^,]+") do
  local a, b, s = string.match(item, "^(%d+)%-(%d+)/(%d+)$")
  if a then
    for n = tonumber(a), tonumber(b), tonumber(s) do FRAMES[n] = true; if n > LAST then LAST = n end end
  else
    local n = tonumber(item); FRAMES[n] = true; if n > LAST then LAST = n end
  end
end

local function read_words(base, count)
  local t = {}
  for i = 0, count - 1 do t[i + 1] = sp:read_u16(base + i * 2) end
  return t
end
local function write_words(t, path)
  local o = assert(io.open(path, "w"))
  local s = {}
  for i = 1, #t do s[i] = string.format("%04x", t[i]) end
  o:write(table.concat(s, "\n"), "\n")
  o:close()
end

-- screen:pixels() is 32-bit ARGB, little-endian (bytes B, G, R, A)
local function dump_pixels(path)
  local px, pw, ph = scr:pixels()
  if not _G.SIZE_SHOWN then print(string.format("PIXELS %dx%d", pw or -1, ph or -1)); _G.SIZE_SHOWN = true end
  local out = {}
  local n = #px // 4
  for i = 0, n - 1 do
    local b, g, r = px:byte(i * 4 + 1, i * 4 + 3)
    out[i + 1] = string.char(r, g, b)
  end
  local o = assert(io.open(path, "wb"))
  o:write(table.concat(out))
  o:close()
end

local prev_spr                                    -- the sprite RAM at the last notifier: the buffer this frame is drawn from
local pending
local function dump()
  local pre = string.format("%s/f%05d", DIR, f)
  local o = assert(io.open(pre .. ".regs", "w"))
  local function h(v) return v < 0 and "-1" or string.format("%04x", v) end
  o:write(string.format("%d %s %s %s %s\n", f, h(R[1]), h(R[2]), h(R[3]), h(R[4])))
  o:close()
  write_words(read_words(0xff0000, 0x2000), pre .. ".bg")
  write_words(read_words(0xff4000, 0x2000), pre .. ".fg")
  write_words(read_words(0xfec000, 0x800), pre .. ".tx")
  write_words(prev_spr or read_words(0xfe0000, 0x1000), pre .. ".spr")
  -- the frame notifier runs before the screen is updated, so screen:pixels() still holds the PREVIOUS frame here
  pending = pre
  print("DUMPED frame " .. tostring(f))
  io.stdout:flush()
end

-- scripted inputs
local function find_field(pname, fname)
  local p = mach.ioport.ports[pname]
  if not p then return nil end
  for name, fld in pairs(p.fields) do
    if name == fname then return fld end
  end
  return nil
end
local coin, start = find_field(":SYSTEM", "Coin 1"), find_field(":SYSTEM", "1 Player Start")
local up, dn, lf, rt = find_field(":P1_P2", "P1 Up"), find_field(":P1_P2", "P1 Down"), find_field(":P1_P2", "P1 Left"), find_field(":P1_P2", "P1 Right")
local btn = { find_field(":P1_P2", "P1 Button 1"), find_field(":P1_P2", "P1 Button 2"),
              find_field(":P1_P2", "P1 Button 3"), find_field(":P1_P2", "P1 Button 4") }
local NBTN = tonumber(os.getenv("BUTTONS") or "4")
local SCHED       = os.getenv("SCHEDULE") or "none"
local COIN_FRAME  = tonumber(os.getenv("COIN_FRAME") or "200")
local START_FRAME = tonumber(os.getenv("START_FRAME") or "260")
local PLAY_FRAME  = tonumber(os.getenv("PLAY_FRAME") or "330")
local rng = tonumber(os.getenv("SEED") or "12345")
local function rnd(n) rng = (rng * 1103515245 + 12345) & 0x7fffffff; return (rng >> 8) % n end
local dir = 0
local function setv(fld, on) if fld then fld:set_value(on and 1 or 0) end end
local PERIOD = { 23, 37, 29, 41 }
local FLIPTEST = os.getenv("FLIPTEST") == "1"

local inlog
if os.getenv("INPUTLOG") then inlog = assert(io.open(os.getenv("INPUTLOG"), "w")) end
local last1, last2 = -1, -1

KEEP.notif = emu.add_machine_frame_notifier(function()
  f = absframe()
  if pending then
    dump_pixels(pending .. ".rgb")
    write_words(read_words(0xff8000, 0x400), pending .. ".pal1")
    pending = nil
  end
  local cn, st, du, dd, dl, dr = false, false, false, false, false, false
  local bt = { false, false, false, false }
  if SCHED == "play" then
    cn = (f >= COIN_FRAME) and ((f - COIN_FRAME) % 1800 < 6)
    st = (f >= START_FRAME) and ((f - START_FRAME) % 1800 < 6)
    if f >= PLAY_FRAME then
      if f % 10 == 0 then dir = rnd(5) end
      du = (dir == 1); dd = (dir == 2); dl = (dir == 3); dr = (dir == 4)
      for i = 1, NBTN do bt[i] = (f % PERIOD[i] < 5) end
    end
    setv(coin, cn); setv(start, st)
    setv(up, du); setv(dn, dd); setv(lf, dl); setv(rt, dr)
    for i = 1, 4 do setv(btn[i], bt[i]) end
  end
  if inlog then
    -- the port values (active low); SYSTEM's bit 10 (the vertical blank) is left high here: the bench puts in its own
    local v1, v2 = 0xffff, 0xffff
    if dr then v1 = v1 & ~0x0001 end
    if dl then v1 = v1 & ~0x0002 end
    if dd then v1 = v1 & ~0x0004 end
    if du then v1 = v1 & ~0x0008 end
    for i = 1, 4 do if bt[i] then v1 = v1 & ~(0x0008 << i) end end
    if st then v2 = v2 & ~0x0100 end
    if cn then v2 = v2 & ~0x4000 end
    if v1 ~= last1 or v2 ~= last2 then inlog:write(string.format("%d %04x %04x\n", f + 1, v1, v2)); last1, last2 = v1, v2 end
  end
  -- FLIPTEST=1: flip bits the game itself leaves alone, set at random in MAME's RAMs for a dumped frame: tile flip X / Y (BG, FG),
  -- text flip Y, sprite flip X / Y.  The frame notifier runs after MAME has drawn the frame, so they are set in the notifier before
  -- (the sprites then also reach the buffer the frame is drawn from); what the game writes over them in between is in the dump.
  if FLIPTEST and FRAMES[f + 1] then
    for i = 0, 0x3ff do
      local a = 0xfe0000 + i * 8 + 2
      sp:write_u16(a, (sp:read_u16(a) & ~3) | rnd(4))
    end
    for _, base in ipairs({ 0xff0000, 0xff4000 }) do
      for i = 0, 0x1fff do
        local a = base + i * 2
        sp:write_u16(a, (sp:read_u16(a) & ~0x3000) | (rnd(4) << 12))
      end
    end
    for i = 0, 0x3ff do
      local a = 0xfec000 + i * 2
      sp:write_u16(a, (sp:read_u16(a) & ~0x1000) | (rnd(2) << 12))
    end
  end
  if FRAMES[f] then dump() end
  prev_spr = read_words(0xfe0000, 0x1000)
  if f >= LAST + 1 then
    if wrlog then wrlog:close() end
    if inlog then inlog:close() end
    mach:exit()
  end
end)
