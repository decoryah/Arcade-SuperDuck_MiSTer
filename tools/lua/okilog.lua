-- The Z80's writes to the OKI (9800) and its bank (9000) with their time (docs/status.md, Sound), with a coin at frame 200 as
-- tools/capture.py --play presses it.  Exits after frame 260.
local mach = manager.machine
local zs = mach.devices[":audiocpu"].spaces["program"]
local sp = mach.devices[":maincpu"].spaces["program"]
local K = {}
_G.OKK = K
local function now() local t = mach.time; t = (type(t) == "number") and t or t:as_double(); return t end
local function absframe() return math.floor(now() * 6000000 / (384 * 262) + 0.5) end
K.w = zs:install_write_tap(0x9000, 0x9800, "oki", function(off, data, mask)
  if off == 0x9800 or off == 0x9000 then print(string.format("OKI %.6f %04x %02x", now(), off, data & 0xff)) end
end)
K.r = sp:install_read_tap(0xfe4002, 0xfe4003, "coin", function(off, data, mask)
  local f = absframe()
  if f >= 200 and f <= 205 then return data & ~0x4000 end
  return data
end)
K.n = emu.add_machine_frame_notifier(function() if absframe() > 260 then mach:exit() end end)
