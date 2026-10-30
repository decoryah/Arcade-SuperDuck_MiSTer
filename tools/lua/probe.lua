-- Presses inputs at the 68000's reads of the input ports, so any bit can be pressed (also the ones MAME's INPUT_PORTS leave unknown),
-- and dumps MAME's pictures.  (From the owner's silvmil-mister tools/lua/probe.lua.)
--
--   PRESS=<list>     comma-separated "from-to:port:mask": in machine frames from..to (inclusive) the port reads with these bits low
--                    (pressed; hex mask); port 0 = 0xFE4000 (P1_P2), 2 = 0xFE4002 (SYSTEM), 4 = 0xFE4004 (DSW: a switch on).
--                    E.g. "200-205:2:4000,260-265:2:0100" (coin 1, start 1)
--   DUMPFRAMES=<list> frames to dump: "f,f,..." and / or "a-b/s" ranges;  DUMPDIR=<dir> gets f<N>.rgb (256 x 224 x 3)
--   READLOG=1        DUMPDIR/reads.log: "frame port value" whenever the value the game reads of a port changes
local mach = manager.machine
local sp   = mach.devices[":maincpu"].spaces["program"]
local scr  = mach.screens[":screen"]
local KEEP = {}
_G.PROBEKEEP = KEEP

local function absframe()
  local t = mach.time
  t = (type(t) == "number") and t or t:as_double()
  return math.floor(t * 6000000 / (384 * 262) + 0.5)
end

local PRESS = {}
for item in string.gmatch(os.getenv("PRESS") or "", "[^,]+") do
  local a, b, port, mask = string.match(item, "^(%d+)%-(%d+):(%d):(%x+)$")
  assert(a, "bad PRESS item " .. item)
  PRESS[#PRESS + 1] = { tonumber(a), tonumber(b), tonumber(port), tonumber(mask, 16) }
end
local DIR = os.getenv("DUMPDIR") or "."
local FR, LAST = {}, 0
for item in string.gmatch(os.getenv("DUMPFRAMES") or "600", "[^,]+") do
  local a, b, s = string.match(item, "^(%d+)%-(%d+)/(%d+)$")
  if a then
    for n = tonumber(a), tonumber(b), tonumber(s) do FR[n] = true; if n > LAST then LAST = n end end
  else
    local n = tonumber(item); FR[n] = true; if n > LAST then LAST = n end
  end
end

local f = absframe()
local function held(port)
  local m = 0
  for _, p in ipairs(PRESS) do
    if p[3] == port and f >= p[1] and f <= p[2] then m = m | p[4] end
  end
  return m
end

local seen = { [0] = -1, [2] = -1, [4] = -1 }
local log
if os.getenv("READLOG") then log = assert(io.open(DIR .. "/reads.log", "w")) end
KEEP.tap = sp:install_read_tap(0xfe4000, 0xfe4005, "inputs", function(off, data, mask)
  local port = off & 6
  local v = data & ~held(port)
  if log and (v & 0xffff) ~= seen[port] then
    seen[port] = v & 0xffff
    log:write(string.format("%d %d %04x\n", f, port, v & 0xffff))
  end
  return v
end)

-- screen:pixels() is 32-bit ARGB, little-endian (bytes B, G, R, A); the notifier runs before the screen update, so the picture of
-- frame N is read in the next callback (as tools/lua/dump_state.lua does)
local function dump_pixels(path)
  local px = scr:pixels()
  local out = {}
  for i = 0, #px // 4 - 1 do
    local b, g, r = px:byte(i * 4 + 1, i * 4 + 3)
    out[i + 1] = string.char(r, g, b)
  end
  local o = assert(io.open(path, "wb"))
  o:write(table.concat(out))
  o:close()
end

local pending
KEEP.notif = emu.add_machine_frame_notifier(function()
  if pending then dump_pixels(pending); pending = nil end
  f = absframe()
  if FR[f] then pending = string.format("%s/f%05d.rgb", DIR, f) end
  if f >= LAST + 1 then
    if log then log:close() end
    mach:exit()
  end
end)
