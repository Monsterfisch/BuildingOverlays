--[[
  Building Overlays

  Draws pictures on top of buildings, the way the game draws its own crenellations over the
  tower walkways: a picture that hides the empty walkway and goes away when troops step
  onto the building. Which pictures, for which building, entrance direction, occupancy and
  gate state, and where they sit is listed in overlay_list.lua; the PNGs live in overlays/.

  How it works
    * `renderGmOverlayBuilding` draws a building's extra sprites, then every path of it ends
      at the same instruction (`movzx eax, word [ebp + buildingType]`). A jump from there
      into this module's assembly runs once per building and frame, after the game's own
      overlays, so the pictures land over the units standing on the building.
    * The assembly walks a small table, one record per overlay, tests the building against
      it (type, anyone on it, entrance direction on screen, gate state) and calls the
      game's own picture routine (the one `renderGM` uses for its 16 bit pictures) with a
      picture packed in the game's TGX format. That routine does the clipping and the
      zoomed-out drawing, so the pictures behave like the game's own.
    * The PNGs are packed twice, in RGB565 and RGB555, and the right copy is picked from the
      game's pixel format on every draw.
    * Alt + arrow keys / PageUp / PageDown / End (the free Alt keys of WM_SYSKEYDOWN) line
      the pictures up in a running game.

  Every address is found by pattern scan or read out of the instruction that uses it, so the
  module runs on Stronghold Crusader.exe and Stronghold_Crusader_Extreme.exe alike.
]]

local png = require("png")
local list = require("overlay_list")

local MODULE_NAME = "building-overlays"
local MODULE_FOLDERS = { "ucp/modules/building-overlays/" }   -- UCP maps this to the active version

local DEFAULTS = {
  large_gatehouse = { enabled = true, swap_sides = false },
  calibration = { keys = true },
}

-- Building ids (BuildingType); overlay_list.lua may also use the plain number.
local BUILDINGS = {
  large_gatehouse = 45, small_gatehouse = 46,
  tower1 = 74, tower2 = 75, tower3 = 76, tower4 = 77, tower5 = 78,
  stone_keep = 41, stronghold = 42, keep_four = 43, keep_five = 44,
}

-- The tail every path of `renderGmOverlayBuilding` ends in, preceded by the `mov ecx, core
-- / call renderGM` that closes the last case. Unique in both executables.
local AOB_TAIL = "0F B7 85 ? ? ? ? 0F BF C0 8B 04 85 ? ? ? ? 33 C9 3B C1 89 4C 24 30 "
  .. "89 4C 24 34 89 44 24 24"
local TAIL_SIZE = 7                      -- the `movzx` the jump replaces
local TYPE_DISPLACEMENT_OPERAND = 3
local CORE_OPERAND = -9                  -- mov ecx, <texture render core>
local RENDER_GM_REL_OPERAND = -4         -- call renderGM
local RENDER_GM_BLIT_CALL = 0x53         -- inside renderGM: call <the TGX picture routine>

local AOB_PIXEL_FORMAT = "81 3D ? ? ? 00 65 05 00 00 75 40"
local PIXEL_FORMAT_OPERAND = 2
local AOB_MAP_ORIENTATION = "A1 ? ? ? ? 85 C0 53 55 56 57 8B E9 BF 08 00 00 00 74 22 "
  .. "83 F8 06 75 07 BF 18 3A 01 00 EB 16 83 F8 04 75 07 BF 28 74 02 00"
local MAP_ORIENTATION_OPERAND = 1

-- WM_SYSKEYDOWN dispatcher: the 7 byte `jmp [eax*4 + table]` at +36.
local AOB_SYS_KEY = "8B 74 24 64 8D 46 F3 3D D1 00 00 00 BD 01 00 00 00 89 2D ? ? ? ? "
  .. "0F 87 ? ? ? ? 0F B6 80 ? ? ? ? FF 24 85 ? ? ? ?"
local SYS_KEY_JUMP = 36
local SYS_KEY_JUMP_SIZE = 7
local VK = { prior = 0x21, next = 0x22, finish = 0x23, left = 0x25, up = 0x26, right = 0x27,
  down = 0x28 }

-- Building fields (the building struct is 0x32C bytes, same in both executables).
local B_SHOWN = 0x34                     -- displayOwnerFlag
local B_FRAMES = { 0x38, 0x3C, 0x40, 0x44 }   -- the game's own overlay frames; none = not built
local B_TYPE = 0xD2
local B_OCCUPIED = 0xB0                  -- 1 while troops stand on it (picks the tile art)
local B_VARIATION = 0x102                -- 0x50: entrance runs along x
local B_GATE_STATE = 0x2A2               -- 0 open, 1 closing, 2 closed, 3 opening
local VARIATION_X = 0x50

-- One record per overlay, read by the assembly.
local RECORD_SIZE = 0x28
local R_TYPE, R_UNITS, R_ENTRANCE, R_GATE, R_X, R_Y, R_W, R_H, R_DATA565, R_DATA555 =
  0, 4, 8, 0xC, 0x10, 0x14, 0x18, 0x1C, 0x20, 0x24

local UNITS = { empty = 0, occupied = 1, any = 2 }
local ENTRANCES = { any = 0, left = 1, right = 2 }
-- A bit per gate state (0 open, 1 closing, 2 closed, 3 opening).
local GATES = { any = 0xF, open = 0x1, closing = 0x2, closed = 0x4, opening = 0x8 }

local SCRIPT = [[
pushfd
pushad
lea ebx,[ebp+BUILDINGS]
cmp dword [ebx+BSHOWN],0
je done
mov eax,[ebx+FRAME0]
or eax,[ebx+FRAME1]
or eax,[ebx+FRAME2]
or eax,[ebx+FRAME3]
je done
movzx eax,word [ebx+BTYPE]
mov [SCRATCH],eax
xor eax,eax
cmp dword [ebx+OCCUPIED],0
setne al
mov [SCRATCH+4],eax
xor eax,eax
cmp word [ebx+VARIATION],VARIATION_X
sete al
mov ecx,[MAP_ORIENTATION]
cmp ecx,2
je flip
cmp ecx,6
jne keep
flip:
xor eax,1
keep:
mov [SCRATCH+8],eax
movzx eax,word [ebx+GATE_STATE]
and eax,3
mov [SCRATCH+12],eax
mov ecx,RECORDS
mov edx,RECORD_COUNT
next:
mov eax,[SCRATCH]
cmp eax,[ecx+R_TYPE]
jne skip
mov eax,[ecx+R_UNITS]
cmp eax,2
je units_ok
cmp eax,[SCRATCH+4]
jne skip
units_ok:
mov eax,[ecx+R_ENTRANCE]
test eax,eax
je entrance_ok
dec eax
cmp eax,[SCRATCH+8]
jne skip
entrance_ok:
mov eax,[ecx+R_GATE]
push ecx
mov ecx,[SCRATCH+12]
shr eax,cl
pop ecx
test al,1
je skip
push edx
push ecx
cmp dword [PIXEL_FORMAT],0x565
mov eax,[ecx+R_DATA565]
je have_data
mov eax,[ecx+R_DATA555]
have_data:
push eax
push dword [ecx+R_H]
push dword [ecx+R_W]
mov eax,esi
add eax,[ecx+R_Y]
push eax
mov eax,edi
add eax,[ecx+R_X]
push eax
mov ecx,RENDER_CORE
mov eax,BLIT
call eax
pop ecx
pop edx
skip:
add ecx,RECORD_SIZE
dec edx
jne next
done:
popad
popfd
ORIGINAL
jmp RESUME
]]

local function log(level, text)
  if _G.log ~= nil then
    _G.log(level, text)
  end
end

local function setting(config, group, name)
  local section = config[group]
  if type(section) == "table" and section[name] ~= nil then
    return section[name]
  end
  local defaults = DEFAULTS[group]
  if defaults ~= nil and defaults[name] ~= nil then
    return defaults[name]
  end
  return name == "enabled"
end

local function scan(pattern, purpose)
  local ok, address = pcall(core.AOBScan, pattern)
  if not ok or address == nil then
    error(MODULE_NAME .. ": could not find " .. purpose)
  end
  return address
end

local function readFile(name)
  for _, folder in ipairs(MODULE_FOLDERS) do
    local file = io.open(folder .. name, "rb")
    if file ~= nil then
      local data = file:read("a")
      file:close()
      return data
    end
  end
  return nil
end

---------------------------------------------------------------------------------------
-- Pictures
---------------------------------------------------------------------------------------

---Packs a picture in the game's TGX layout: per row runs of see-through pixels (0x20 + n-1),
---runs of pixels (n-1, then n 16 bit colours) and a row end (0x80). Alpha below 128 is
---see-through, the rest is opaque.
local function packTgx(width, height, pixels, is565)
  local out = {}
  for y = 0, height - 1 do
    local row = y * width
    local x = 0
    while x < width do
      local solid = pixels[row + x + 1][4] >= 128
      local n = 1
      while x + n < width and n < 32 and (pixels[row + x + n + 1][4] >= 128) == solid do
        n = n + 1
      end
      if solid then
        out[#out + 1] = n - 1
        for k = 0, n - 1 do
          local p = pixels[row + x + k + 1]
          local value
          if is565 then
            value = ((p[1] >> 3) << 11) | ((p[2] >> 2) << 5) | (p[3] >> 3)
          else
            value = ((p[1] >> 3) << 10) | ((p[2] >> 3) << 5) | (p[3] >> 3)
          end
          out[#out + 1] = value & 0xFF
          out[#out + 1] = value >> 8
        end
      else
        out[#out + 1] = 0x20 | (n - 1)
      end
      x = x + n
    end
    out[#out + 1] = 0x80
  end
  return out
end

local function store(bytes)
  local address = core.allocate(#bytes, true)
  core.writeBytes(address, bytes)
  return address
end

local function loadPicture(name)
  local data = readFile("overlays/" .. name .. ".png")
  if data == nil then
    return nil, "not found"
  end
  local ok, width, height, pixels = pcall(png.decode, data)
  if not ok then
    return nil, (tostring(width):gsub("^.-:%d+: ", ""))
  end
  return { width = width, height = height, pixels = pixels }
end

---Spots saved by Alt + End: { [overlay name] = { x, y } }.
local function loadCalibration()
  local text = readFile("calibration.lua")
  if text == nil then
    return {}
  end
  local chunk = load(text, "calibration", "t", {})
  if chunk == nil then
    return {}
  end
  local ok, result = pcall(chunk)
  return ok and type(result) == "table" and result or {}
end

---------------------------------------------------------------------------------------
-- Alt keys to line the pictures up
---------------------------------------------------------------------------------------

local function writeCalibration(overlays)
  local lines = { "return {" }
  for _, overlay in ipairs(overlays) do
    local x = core.readInteger(overlay.record + R_X)
    local y = core.readInteger(overlay.record + R_Y)
    lines[#lines + 1] = string.format("  %s = { %d, %d },", overlay.name, x, y)
    log(INFO, string.format("%s: %s x = %d, y = %d", MODULE_NAME, overlay.name, x, y))
  end
  lines[#lines + 1] = "}"
  for _, folder in ipairs(MODULE_FOLDERS) do
    local ok, file = pcall(io.open, folder .. "calibration.lua", "wb")
    if ok and file ~= nil then
      file:write(table.concat(lines, "\n"), "\n")
      file:close()
      log(INFO, MODULE_NAME .. ": saved calibration.lua")
      return
    end
  end
  log(WARNING, MODULE_NAME .. ": could not write calibration.lua; copy the numbers above "
    .. "into overlay_list.lua")
end

local function installKeys(overlays, dispatch)
  local selected = 1
  core.detourCode(function(registers)
    local key = registers.ESI
    local dx, dy = 0, 0
    if key == VK.prior or key == VK.next then
      selected = (selected - 1 + (key == VK.next and 1 or -1)) % #overlays + 1
      log(INFO, string.format("%s: picked %s", MODULE_NAME, overlays[selected].name))
    elseif key == VK.finish then
      writeCalibration(overlays)
    elseif key == VK.left then dx = -1
    elseif key == VK.right then dx = 1
    elseif key == VK.up then dy = -1
    elseif key == VK.down then dy = 1
    end
    if dx ~= 0 or dy ~= 0 then
      local overlay = overlays[selected]
      local x = core.readInteger(overlay.record + R_X) + dx
      local y = core.readInteger(overlay.record + R_Y) + dy
      core.writeInteger(overlay.record + R_X, x)
      core.writeInteger(overlay.record + R_Y, y)
      log(INFO, string.format("%s: %s x = %d, y = %d", MODULE_NAME, overlay.name, x, y))
    end
    return registers
  end, dispatch + SYS_KEY_JUMP, SYS_KEY_JUMP_SIZE)
end

---------------------------------------------------------------------------------------
-- Enable
---------------------------------------------------------------------------------------

local function collectOverlays(config)
  local swap = setting(config, "large_gatehouse", "swap_sides")
  local calibrated = loadCalibration()
  local overlays = {}
  for _, entry in ipairs(list) do
    if setting(config, entry.group, "enabled") then
      local id = type(entry.building) == "number" and entry.building or BUILDINGS[entry.building]
      local picture, problem = loadPicture(entry.picture)
      if id == nil then
        log(WARNING, string.format("%s: %s: unknown building %s; skipped", MODULE_NAME,
          entry.name, tostring(entry.building)))
      elseif picture == nil then
        log(WARNING, string.format("%s: overlays/%s.png: %s; %s skipped", MODULE_NAME,
          entry.picture, problem, entry.name))
      else
        local entrance = ENTRANCES[entry.entrance or "any"] or 0
        if swap and entry.group == "large_gatehouse" and entrance ~= 0 then
          entrance = 3 - entrance
        end
        local spot = calibrated[entry.name]
        overlays[#overlays + 1] = {
          name = entry.name, id = id, picture = picture, entrance = entrance,
          units = UNITS[entry.units or "empty"] or 0, gate = GATES[entry.gate or "any"] or 0xF,
          x = spot and spot[1] or entry.x or 0, y = spot and spot[2] or entry.y or 0,
        }
      end
    end
  end
  return overlays
end

local function writeRecords(overlays)
  local records = core.allocate(#overlays * RECORD_SIZE, true)
  for index, overlay in ipairs(overlays) do
    local record = records + (index - 1) * RECORD_SIZE
    local picture = overlay.picture
    overlay.record = record
    core.writeInteger(record + R_TYPE, overlay.id)
    core.writeInteger(record + R_UNITS, overlay.units)
    core.writeInteger(record + R_ENTRANCE, overlay.entrance)
    core.writeInteger(record + R_GATE, overlay.gate)
    core.writeInteger(record + R_X, overlay.x)
    core.writeInteger(record + R_Y, overlay.y)
    core.writeInteger(record + R_W, picture.width)
    core.writeInteger(record + R_H, picture.height)
    core.writeInteger(record + R_DATA565,
      store(packTgx(picture.width, picture.height, picture.pixels, true)))
    core.writeInteger(record + R_DATA555,
      store(packTgx(picture.width, picture.height, picture.pixels, false)))
  end
  return records
end

local function enable(self, config)
  config = config or {}
  local overlays = collectOverlays(config)
  if #overlays == 0 then
    return
  end

  local tail = scan(AOB_TAIL, "the end of the building overlay drawing")
  local pixelFormat = core.readInteger(scan(AOB_PIXEL_FORMAT, "the pixel format")
    + PIXEL_FORMAT_OPERAND)
  local orientation = core.readInteger(scan(AOB_MAP_ORIENTATION, "the map orientation")
    + MAP_ORIENTATION_OPERAND)
  local typeDisplacement = core.readInteger(tail + TYPE_DISPLACEMENT_OPERAND)
  local renderCore = core.readInteger(tail + CORE_OPERAND)
  local renderGm = tail + RENDER_GM_REL_OPERAND + 4 + core.readInteger(tail + RENDER_GM_REL_OPERAND)
  if (core.readByte(tail - 10) & 0xFF) ~= 0xB9 or (core.readByte(tail - 5) & 0xFF) ~= 0xE8
      or (core.readByte(renderGm + RENDER_GM_BLIT_CALL) & 0xFF) ~= 0xE8 then
    error(MODULE_NAME .. ": the game's overlay drawing is not the one this module knows")
  end
  local blit = renderGm + RENDER_GM_BLIT_CALL + 5
    + core.readInteger(renderGm + RENDER_GM_BLIT_CALL + 1)

  local records = writeRecords(overlays)

  local original = {}
  for offset = 0, TAIL_SIZE - 1 do
    original[#original + 1] = string.format("0x%02X", core.readByte(tail + offset) & 0xFF)
  end
  local script = SCRIPT:gsub("%f[%w_]ORIGINAL%f[^%w_]", "db " .. table.concat(original, ","))
  local values = {
    BUILDINGS = (typeDisplacement - B_TYPE) & 0xFFFFFFFF, BSHOWN = B_SHOWN,
    FRAME0 = B_FRAMES[1], FRAME1 = B_FRAMES[2], FRAME2 = B_FRAMES[3], FRAME3 = B_FRAMES[4],
    BTYPE = B_TYPE, OCCUPIED = B_OCCUPIED, VARIATION = B_VARIATION, VARIATION_X = VARIATION_X,
    GATE_STATE = B_GATE_STATE, SCRATCH = core.allocate(16, true), MAP_ORIENTATION = orientation,
    PIXEL_FORMAT = pixelFormat, RECORDS = records, RECORD_COUNT = #overlays,
    RECORD_SIZE = RECORD_SIZE, RENDER_CORE = renderCore, BLIT = blit, RESUME = tail + TAIL_SIZE,
    R_TYPE = R_TYPE, R_UNITS = R_UNITS, R_ENTRANCE = R_ENTRANCE, R_GATE = R_GATE, R_X = R_X,
    R_Y = R_Y, R_W = R_W, R_H = R_H, R_DATA565 = R_DATA565, R_DATA555 = R_DATA555,
  }
  local used = {}
  for name, value in pairs(values) do
    if script:find("%f[%w_]" .. name .. "%f[^%w_]") then
      used[name] = value
    end
  end
  local blob = core.allocateAssembly(script, used)
  core.writeCode(tail, { 0xE9, core.itob(core.getRelativeAddress(tail, blob, -5)), 0x90, 0x90 })

  if setting(config, "calibration", "keys") then
    local ok, dispatch = pcall(core.AOBScan, AOB_SYS_KEY)
    if ok and dispatch ~= nil then
      installKeys(overlays, dispatch)
    else
      log(WARNING, MODULE_NAME .. ": could not find the Alt key handler; the line-up keys are off")
    end
  end
  log(INFO, string.format("%s: %d overlay(s) active", MODULE_NAME, #overlays))
end

return {
  enable = enable,
  disable = function(self, config) end,
}
