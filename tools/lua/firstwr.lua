-- The time (us after the start) of the first writes to each area and of the frame notifiers (docs/status.md: MAME's first vertical
-- blank comes a whole frame after the start).  Exits after six frames.
local mach = manager.machine
local sp = mach.devices[":maincpu"].spaces["program"]
local K = {}
_G.FWK = K
local function now() local t = mach.time; t = (type(t) == "number") and t or t:as_double(); return t * 1e6 end
local areas = { {"pal", 0xff8000, 0xff87ff}, {"text", 0xfec000, 0xfecfff}, {"bg", 0xff0000, 0xff3fff}, {"fg", 0xff4000, 0xff7fff},
                {"spr", 0xfe0000, 0xfe1fff}, {"scroll", 0xfe8000, 0xfe8007}, {"latch", 0xfe4002, 0xfe4003}, {"io0", 0xfe4000, 0xfe4001} }
for _, a in ipairs(areas) do
  local seen = 0
  K[a[1]] = sp:install_write_tap(a[2], a[3], a[1], function(off, data, mask)
    if seen < 3 then print(string.format("FIRST %s %.1f us %06x %04x", a[1], now(), off, data)); seen = seen + 1 end
  end)
end
local n = 0
K.n = emu.add_machine_frame_notifier(function()
  n = n + 1
  print(string.format("VBL %d %.1f us", n, now()))
  if n >= 6 then mach:exit() end
end)
