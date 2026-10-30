-- When the game writes each video area, in us after the start of vertical blank (the frame notifier = the level 2 interrupt), and
-- how many writes come after the picture's first line (line 16: 38 lines of 64 us after line 240) has begun.  Answers what the OSD's
-- Video RAM setting changes (docs/status.md): "At vblank" draws from a copy taken at line 240, "Live" from the RAMs as they are.
-- (After the owner's crospang-mister tools/lua/vwrites.lua.)  Presses coin 1 (frame 200) and start 1 (260), then in play jump every 50
-- frames, left / right and shot; logs the attract mode (frames 60-190) and the play (400-1100), prints the counts and exits.
--   mame supduck -video none -sound none -nothrottle -autoboot_script tools/lua/vwrites.lua
local mach = manager.machine
local sp   = mach.devices[":maincpu"].spaces["program"]
local K = {}
_G.VWK = K
local function t() local x = mach.time; return (type(x) == "number") and x or x:as_double() end
local function absframe() return math.floor(t() * 6000000 / (384 * 262) + 0.5) end
local f = absframe()
local vbl_t = 0
local PRESS = { {200, 205, 2, 0x4000}, {260, 265, 2, 0x0100} }               -- {from, to, port, bits pulled low}
for s = 400, 1100, 50 do PRESS[#PRESS + 1] = {s, s + 4, 0, 0x20} end          -- jump
for s = 420, 1100, 100 do PRESS[#PRESS + 1] = {s, s + 20, 0, 0x02} end        -- left
for s = 470, 1100, 100 do PRESS[#PRESS + 1] = {s, s + 20, 0, 0x01} end        -- right
for s = 430, 1100, 60 do PRESS[#PRESS + 1] = {s, s + 3, 0, 0x10} end          -- shot
local function held(port)
  local m = 0
  for _, p in ipairs(PRESS) do if p[3] == port and f >= p[1] and f <= p[2] then m = m | p[4] end end
  return m
end
K.rd = sp:install_read_tap(0xfe4000, 0xfe4005, "inputs", function(off, data, mask) return data & ~held(off & 6) end)
local function phase() if f >= 60 and f <= 190 then return "attract" elseif f >= 400 and f <= 1100 then return "play" end end
local stats = {}
for _, a in ipairs({ {"pal", 0xff8000, 0xff87ff}, {"text", 0xfec000, 0xfecfff}, {"bg", 0xff0000, 0xff3fff},
                     {"fg", 0xff4000, 0xff7fff}, {"spr", 0xfe0000, 0xfe1fff}, {"scroll", 0xfe8000, 0xfe8007} }) do
  K[a[1]] = sp:install_write_tap(a[2], a[3], a[1], function(off, data, mask)
    local ph = phase()
    if not ph then return end
    local us = (t() - vbl_t) * 1e6
    local key = ph .. " " .. a[1]
    local s = stats[key]
    if not s then s = { n = 0, min = 1e9, max = 0, frames = {}, nf = 0, over = 0 }; stats[key] = s end
    s.n = s.n + 1
    if us < s.min then s.min = us end
    if us > s.max then s.max = us end
    if us > 2432 then s.over = s.over + 1 end
    if not s.frames[f] then s.frames[f] = true; s.nf = s.nf + 1 end
  end)
end
K.n = emu.add_machine_frame_notifier(function()
  f = absframe()
  vbl_t = t()
  if f > 1100 then
    local keys = {}
    for k in pairs(stats) do keys[#keys + 1] = k end
    table.sort(keys)
    for _, k in ipairs(keys) do
      local s = stats[k]
      print(string.format("WRITES %-14s %7d writes in %4d frames, %6.0f .. %6.0f us after vblank, %d after line 16 began",
                          k, s.n, s.nf, s.min, s.max, s.over))
    end
    mach:exit()
  end
end)
