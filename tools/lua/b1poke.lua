-- Button 1 (Shot) check for docs/status.md: coin and start as tools/capture.py --play does, then from frame 880 holds FFC362 bit 6
-- set (the condition under which the game acts on button 1, 68000 0x395E), presses button 1 (B1=1) at frames 900, 960, 1020 and
-- dumps the pictures 890..1060 (every 5th) to DUMPDIR as f<N>.rgb (256 x 224 x 3).  Run it with B1=0 and B1=1 and compare.
local mach = manager.machine
local sp = mach.devices[":maincpu"].spaces["program"]
local scr = mach.screens[":screen"]
local K = {}
_G.B1K = K
local function absframe() local t = mach.time; t = (type(t) == "number") and t or t:as_double(); return math.floor(t * 6000000 / (384 * 262) + 0.5) end
local f = absframe()
local B1 = os.getenv("B1") == "1"
local DIR = os.getenv("DUMPDIR")
K.tap = sp:install_read_tap(0xfe4000, 0xfe4005, "in", function(off, data, mask)
  local v = data
  if (off & 6) == 2 and f >= 200 and f <= 205 then v = v & ~0x4000 end
  if (off & 6) == 2 and f >= 260 and f <= 265 then v = v & ~0x0100 end
  if (off & 6) == 0 and B1 and ((f >= 900 and f <= 903) or (f >= 960 and f <= 963) or (f >= 1020 and f <= 1023)) then v = v & ~0x0010 end
  return v
end)
local pending
K.n = emu.add_machine_frame_notifier(function()
  if pending then
    local px = scr:pixels(); local out = {}
    for i = 0, #px // 4 - 1 do local b, g, r = px:byte(i * 4 + 1, i * 4 + 3); out[i + 1] = string.char(r, g, b) end
    local o = io.open(pending, "wb"); o:write(table.concat(out)); o:close(); pending = nil
  end
  f = absframe()
  if f >= 880 then sp:write_u8(0xffc362, sp:read_u8(0xffc362) | 0x40) end
  if f >= 890 and f <= 1060 and f % 5 == 0 then pending = string.format("%s/f%05d.rgb", DIR, f) end
  if f > 1061 then mach:exit() end
end)
