--[[
  Building Overlays

  Draws pictures on top of buildings, the way the game draws its own crenellations over the
  tower walkways: a picture that hides the empty walkway and goes away when troops step
  onto the building. Which pictures, for which building, entrance direction, occupancy and
  gate state, and where they sit is listed in overlay_list.lua; the PNGs live in overlays/.
  Plugins add their own through registerOverlaySource.

  How it works
    * `renderGmOverlayBuilding` draws a building's extra sprites, then every path of it ends
      at the same instruction (`movzx eax, word [ebp + buildingType]`). A jump from there
      into this module's assembly runs once per building and frame, after the game's own
      overlays, so the pictures land over the units standing on the building.
    * The assembly walks a small table, one record per overlay, tests the building against
      it (type, anyone on its tiles, entrance direction on screen, gate state) and calls the
      game's own picture routine (the one `renderGM` uses for its 16 bit pictures) with a
      picture packed in the game's TGX format. That routine does the clipping and the
      zoomed-out drawing, so the pictures behave like the game's own.
    * The PNGs are packed twice, in RGB565 and RGB555, and the right copy is picked from the
      game's pixel format on every draw.
    * The line-up tool lives in the building panel: two shared items of the panel's item
      table (the ones smarter-buildings wraps as well; whoever comes second calls the first)
      draw a list of the selected building's overlays with arrow buttons and take the clicks
      on them. Clicks are handed to lua, which moves the picked overlay and saves.

  Every address is found by pattern scan or read out of the instruction that uses it, so the
  module runs on Stronghold Crusader.exe and Stronghold_Crusader_Extreme.exe alike.
]]

local png = require("png")
local list = require("overlay_list")
local panel = require("panel")

local MODULE_NAME = "building-overlays"
local MODULE_FOLDERS = { "ucp/modules/building-overlays/" }   -- UCP maps this to the active version

local DEFAULTS = {
  large_gatehouse = { enabled = true, swap_sides = false },
  editor = { enabled = true },
}

-- Overlays a plugin may add on top of the ones in overlay_list.lua.
local MAX_OVERLAYS = 64

-- Building ids (BuildingType); overlay_list.lua may also use the plain number.
local BUILDINGS = {
  large_gatehouse = 45, small_gatehouse = 46,
  tower1 = 74, tower2 = 75, tower3 = 76, tower4 = 77, tower5 = 78,
  stone_keep = 41, stronghold = 42, keep_four = 43, keep_five = 44,
}

-- The tail every path of `renderGmOverlayBuilding` ends in, preceded by the `mov ecx, core
-- / call renderGM` that closes the last case. Unique in both executables. +0x46 compares the
-- building with the selected one: `cmp edx, [selectedBuilding]`.
local AOB_TAIL = "0F B7 85 ? ? ? ? 0F BF C0 8B 04 85 ? ? ? ? 33 C9 3B C1 89 4C 24 30 "
  .. "89 4C 24 34 89 44 24 24"
local TAIL_SIZE = 7                      -- the `movzx` the jump replaces
local TYPE_DISPLACEMENT_OPERAND = 3
local CORE_OPERAND = -9                  -- mov ecx, <texture render core>
local RENDER_GM_REL_OPERAND = -4         -- call renderGM
local RENDER_GM_BLIT_CALL = 0x53         -- inside renderGM: call <the TGX picture routine>
local TAIL_SELECTED = { 0x46, { 0x3B, 0x15 } }

local AOB_PIXEL_FORMAT = "81 3D ? ? ? 00 65 05 00 00 75 40"
local PIXEL_FORMAT_OPERAND = 2
local AOB_MAP_ORIENTATION = "A1 ? ? ? ? 85 C0 53 55 56 57 8B E9 BF 08 00 00 00 74 22 "
  .. "83 F8 06 75 07 BF 18 3A 01 00 EB 16 83 F8 04 75 07 BF 28 74 02 00"
local MAP_ORIENTATION_OPERAND = 1

-- Building fields (the building struct is 0x32C bytes, same in both executables).
local BUILDING_SIZE = 0x32C
local B_SHOWN = 0x34                     -- displayOwnerFlag
local B_FRAMES = { 0x38, 0x3C, 0x40, 0x44 }   -- the game's own overlay frames; none = not built
local B_TYPE = 0xD2
local B_OCCUPIED = 0xB0                  -- 1 while troops stand on a tower (picks the tile art)
local B_VARIATION = 0x102                -- 0x50: entrance runs along x
local B_GATE_STATE = 0x2A2               -- 0 open, 1 closing, 2 closed, 3 opening
local VARIATION_X = 0x50

-- One record per overlay, read by the assembly.
local RECORD_SIZE = 0x34
local R_TYPE, R_UNITS, R_ENTRANCE, R_GATE, R_X, R_Y, R_W, R_H, R_DATA565, R_DATA555 =
  0, 4, 8, 0xC, 0x10, 0x14, 0x18, 0x1C, 0x20, 0x24
local R_OUT565, R_OUT555 = 0x28, 0x2C      -- the frame drawn round the picked overlay
local R_NAME = 0x30                        -- its name, for the panel list

-- The game's own "are there units on this building's tiles" test: thiscall on the buildings
-- state (building array - 0x14), one argument, `ret 4`.
local AOB_UNITS_ON_BUILDING = "8B 44 24 04 69 C0 2C 03 00 00 53 55 03 C1 56 8B B0 0C 01 00 00 "
  .. "33 DB 85 F6 57 7E"
local BUILDINGS_STATE_BEFORE_ARRAY = 0x14

local UNITS = { empty = 0, occupied = 1, any = 2 }
local ENTRANCES = { any = 0, left = 1, right = 2 }
-- A bit per gate state (0 open, 1 closing, 2 closed, 3 opening).
local GATES = { any = 0xF, open = 0x1, closing = 0x2, closed = 0x4, opening = 0x8 }

---------------------------------------------------------------------------------------
-- The building panel
---------------------------------------------------------------------------------------

-- MenuItem layout (0x50 bytes) and the panel's item table: found through the tower Repair
-- button (type 3 at 340, 466, 100 x 28), walking back to the end marker of the table before.
local ITEM_SIZE = 0x50
local ITEM_TYPE, ITEM_X, ITEM_Y, ITEM_ACTION, ITEM_RENDER = 0x00, 0x04, 0x08, 0x14, 0x1C
local TYPE_EVERY_FRAME, TYPE_BLOCK, TYPE_LAST = 0x00, 0x64, 0x66
local AOB_REPAIR_ITEM = "03 00 00 00 54 01 00 00 D2 01 00 00 64 00 00 00 1C 00 00 00"
local STATUS_LINE = { 25, 570 }          -- the shared work status line every building shows

-- handleMenuElementsCallbacks: the mouse and its "is the mouse in this box" test.
local AOB_MENU_ITEM = "8B 56 10 8B 46 4C 8B 4E 0C 52 8B 50 08 03 56 08 8B 40 04 03 46 04 51 52 50 "
  .. "B9 ? ? ? ? E8"
local MENU_ITEM_MOUSE = { 0x19, { 0xB9 } }
local MENU_ITEM_IS_INSIDE = 0x1E
local MOUSE_LEFT_CLICK = 0x34            -- set for the frame in which the left button went down

-- The Save dialog's file name box renderer: the pencil and the text drawing.
local AOB_NAME_BOX = "A1 ? ? ? ? 8B 0D ? ? ? ? 8B 15 ? ? ? ? 56 57 6A 05 03 C8 51 8B 0D ? ? ? ? 03 "
  .. "D1 52 50 51 B9 ? ? ? ?"
local NAME_BOX_PENCIL = { 0x23, { 0xB9 } }
local NAME_BOX_ITEM_X = { 0x18, { 0x8B, 0x0D } }   -- ButtonX: where the item being drawn sits
local NAME_BOX_ITEM_Y = { 0x00, { 0xA1 } }
local NAME_BOX_DRAW_COLOUR_BOX = 0x69
local NAME_BOX_TEXT_MANAGER = { 0x9C, { 0xB9 } }
local NAME_BOX_SHADOWED_TEXT = 0xA1      -- call renderInGameTextWithShadow
local DRAW_COLOUR_BOX_SURFACE = 0x03     -- call setupPencilSurface
local DRAW_COLOUR_BOX_CLIP = 0x23        -- call setupPencil

-- The game's sprite fading tables, which the button blit mixes soft edges with.
local AOB_BLEND = "66 83 3D ? ? ? ? 00 75 05 E8 ? ? ? ? 8B C3 C1 E0 09 BA ? ? ? ? 2B D0 83 3D ? ? ? ? 00 8D 88"
local BLEND_READY_OPERAND = 3
local BLEND_BUILD_CALL = 0x0A
local BLEND_TABLES_OPERAND = 0x24
local BLEND_TOP_OPERAND = 0x15
local BLEND_LEVEL_SIZE = 0x200

-- Where the tool sits in the panel (800 x 600 layout, the game shifts it with the panel). The
-- list runs down the left under the building's name, clear of the gate buttons (200, 535);
-- the arrows sit between the gate buttons and the help button, under the Repair button
-- (340, 466) and left of the health display.
local LIST_X, LIST_Y, LIST_W, LINE, MAX_ROWS = 20, 500, 170, 16, 4
local SAVE_X, SAVE_Y, SAVE_W = 20, 570, 50
local STEP_X, STEP_Y, STEP_W = 80, 570, 100
local ARROW_SIZE = 24
local ARROW_PLACES = { { 368, 503 }, { 368, 559 }, { 340, 531 }, { 396, 531 } }   -- up down left right
local ARROW_NAMES = { "up", "down", "left", "right" }
local STEPS = { 1, 5, 20 }
local COLOUR = 0xB8EEFB                  -- the panel's own beige (BGR)
local PICKED_COLOUR = 0x00FFFF           -- yellow
local FONT = 0x12

local SCRIPT = [[
pushfd
pushad
cmp dword [STATE],0
je done
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
mov dword [SCRATCH+4],-1
mov eax,[esp+0x50]
mov [SCRATCH+16],eax
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
mov edx,[STATE]
next:
mov eax,[SCRATCH]
cmp eax,[ecx+R_TYPE]
jne skip
call picked_here
je draw
mov eax,[ecx+R_UNITS]
cmp eax,2
je units_ok
cmp dword [SCRATCH+4],-1
jne occupancy_known
push ecx
push edx
push dword [SCRATCH+16]
mov ecx,BUILDINGS_STATE
mov eax,UNITS_ON_BUILDING
call eax
pop edx
pop ecx
test eax,eax
setne al
movzx eax,al
cmp dword [ebx+OCCUPIED],0
je occupancy_set
mov eax,1
occupancy_set:
mov [SCRATCH+4],eax
occupancy_known:
mov eax,[ecx+R_UNITS]
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
draw:
cmp dword [PIXEL_FORMAT],0x565
mov eax,[ecx+R_DATA565]
je picture_ready
mov eax,[ecx+R_DATA555]
picture_ready:
call drawit
call picked_here
jne skip
cmp dword [PIXEL_FORMAT],0x565
mov eax,[ecx+R_OUT565]
je frame_ready
mov eax,[ecx+R_OUT555]
frame_ready:
call drawit
skip:
add ecx,RECORD_SIZE
dec edx
jne next
done:
popad
popfd
ORIGINAL
jmp RESUME
picked_here:
cmp dword [STATE+4],0
je not_picked
cmp ecx,[STATE+8]
jne not_picked
mov eax,[SCRATCH+16]
cmp eax,[SELECTED]
ret
not_picked:
or eax,1
ret
drawit:
push edx
push ecx
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
ret
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

local function expectBytes(address, bytes, purpose)
  for index, byte in ipairs(bytes) do
    if (core.readByte(address + index - 1) & 0xFF) ~= byte then
      error(string.format("%s: %s is not the code this module knows", MODULE_NAME, purpose))
    end
  end
end

local function readOperand(base, site, purpose)
  expectBytes(base + site[1], site[2], purpose)
  return core.readInteger(base + site[1] + #site[2])
end

local function readCallTarget(base, offset, purpose)
  expectBytes(base + offset, { 0xE8 }, purpose)
  return base + offset + 5 + core.readInteger(base + offset + 1)
end

local function readFile(folder, name)
  local file = io.open(folder .. name, "rb")
  if file == nil then
    return nil
  end
  local data = file:read("a")
  file:close()
  return data
end

---FASM gets a fixed 64 KB for source, symbols and output: only pass what a script uses.
local function assemble(script, values)
  local used = {}
  for name, value in pairs(values) do
    if script:find("%f[%w_]" .. name .. "%f[^%w_]") then
      used[name] = value
    end
  end
  return core.allocateAssembly(script, used)
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

---A two pixel wide bright frame the size of a picture, as pixels for packTgx.
local function framePixels(width, height)
  local pixels = {}
  for y = 0, height - 1 do
    for x = 0, width - 1 do
      local edge = x < 2 or y < 2 or x >= width - 2 or y >= height - 2
      pixels[y * width + x + 1] = edge and { 255, 0, 255, 255 } or { 0, 0, 0, 0 }
    end
  end
  return pixels
end

---A chevron arrow button, ARROW_SIZE square, pointing the given way.
local function arrowPixels(direction, hovered)
  local size = ARROW_SIZE
  local a, b, c               -- the two strokes: a to b and b to c
  if direction == "left" then
    a, b, c = { 16, 4 }, { 8, 12 }, { 16, 20 }
  elseif direction == "right" then
    a, b, c = { 8, 4 }, { 16, 12 }, { 8, 20 }
  elseif direction == "up" then
    a, b, c = { 4, 16 }, { 12, 8 }, { 20, 16 }
  else
    a, b, c = { 4, 8 }, { 12, 16 }, { 20, 8 }
  end
  local function distance(px, py, p, q)
    local dx, dy = q[1] - p[1], q[2] - p[2]
    local t = ((px - p[1]) * dx + (py - p[2]) * dy) / (dx * dx + dy * dy)
    t = math.max(0, math.min(1, t))
    local nx, ny = p[1] + t * dx - px, p[2] + t * dy - py
    return math.sqrt(nx * nx + ny * ny)
  end
  local fill = hovered and { 255, 220, 0, 255 } or { 40, 90, 255, 255 }
  local edge = { 10, 10, 50, 255 }
  local back = { 60, 50, 40, 160 }
  local pixels = {}
  for y = 0, size - 1 do
    for x = 0, size - 1 do
      local d = math.min(distance(x + 0.5, y + 0.5, a, b), distance(x + 0.5, y + 0.5, b, c))
      pixels[y * size + x + 1] = d <= 1.7 and fill or d <= 2.7 and edge or back
    end
  end
  return pixels
end

local function store(bytes)
  local address = core.allocate(#bytes, true)
  core.writeBytes(address, bytes)
  return address
end

---A picture in the layout the panel's blit reads: +0 width, +4 height, +8 RGB565, +0xC RGB555,
---+0x10 one alpha byte per pixel.
local function storeBlitPicture(width, height, pixels)
  local count = width * height
  local base = core.allocate(0x14 + count * 5, true)
  local rgb565, rgb555, mask = {}, {}, {}
  for index = 1, count do
    local p = pixels[index]
    local r, g, b = p[1], p[2], p[3]
    local value565 = ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3)
    local value555 = ((r >> 3) << 10) | ((g >> 3) << 5) | (b >> 3)
    rgb565[index * 2 - 1], rgb565[index * 2] = value565 & 0xFF, value565 >> 8
    rgb555[index * 2 - 1], rgb555[index * 2] = value555 & 0xFF, value555 >> 8
    mask[index] = p[4]
  end
  core.writeInteger(base, width)
  core.writeInteger(base + 4, height)
  core.writeInteger(base + 8, base + 0x14)
  core.writeInteger(base + 0xC, base + 0x14 + count * 2)
  core.writeInteger(base + 0x10, base + 0x14 + count * 4)
  core.writeBytes(base + 0x14, rgb565)
  core.writeBytes(base + 0x14 + count * 2, rgb555)
  core.writeBytes(base + 0x14 + count * 4, mask)
  return base
end

local function storeString(text)
  local address = core.allocate(#text + 1, true)
  core.writeString(address, text)
  return address
end

local function loadPicture(folder, name)
  local data = readFile(folder, name .. ".png")
  if data == nil then
    return nil, "not found"
  end
  local ok, width, height, pixels = pcall(png.decode, data)
  if not ok then
    return nil, (tostring(width):gsub("^.-:%d+: ", ""))
  end
  return { width = width, height = height, pixels = pixels }
end

---Spots saved with the Save button: a list of overlay entries, used for x and y by name.
local function loadCalibration()
  local text = readFile(MODULE_FOLDERS[1], "calibration.lua")
  local chunk = text and load(text, "calibration", "t", {})
  local ok, result = pcall(chunk or function() end)
  local spots = {}
  if ok and type(result) == "table" then
    for _, entry in ipairs(result) do
      if type(entry) == "table" and entry.name ~= nil then
        spots[entry.name] = entry
      end
    end
  end
  return spots
end

---------------------------------------------------------------------------------------
-- The overlay table
---------------------------------------------------------------------------------------

local state            -- everything the running hook uses; nil until enable has hooked
local overlays = {}    -- every overlay in the table, in record order
local pending = {}     -- plugin folders registered before enable finished

---Adds one overlay (an entry of overlay_list.lua or of a plugin's overlays.lua) to the table
---the hook walks. `folder` is where its picture lives.
local function addOverlay(entry, folder, swap)
  if #overlays >= MAX_OVERLAYS then
    log(WARNING, MODULE_NAME .. ": too many overlays; " .. tostring(entry.name) .. " skipped")
    return
  end
  local id = type(entry.building) == "number" and entry.building or BUILDINGS[entry.building]
  local picture, problem = loadPicture(folder, entry.picture or "")
  if id == nil then
    log(WARNING, string.format("%s: %s: unknown building %s; skipped", MODULE_NAME,
      tostring(entry.name), tostring(entry.building)))
    return
  elseif picture == nil then
    log(WARNING, string.format("%s: %s%s.png: %s; %s skipped", MODULE_NAME, folder,
      tostring(entry.picture), problem, tostring(entry.name)))
    return
  end
  local entrance = ENTRANCES[entry.entrance or "any"] or 0
  if swap and entrance ~= 0 then
    entrance = 3 - entrance
  end
  local overlay = {
    name = tostring(entry.name), id = id, entrance = entry.entrance or "any",
    units = entry.units or "empty", gate = entry.gate or "any", picture = entry.picture,
    x = entry.x or 0, y = entry.y or 0,
  }
  overlays[#overlays + 1] = overlay
  local record = state.records + (#overlays - 1) * RECORD_SIZE
  overlay.record = record
  core.writeInteger(record + R_TYPE, id)
  core.writeInteger(record + R_UNITS, UNITS[overlay.units] or 0)
  core.writeInteger(record + R_ENTRANCE, entrance)
  core.writeInteger(record + R_GATE, GATES[overlay.gate] or 0xF)
  core.writeInteger(record + R_X, overlay.x)
  core.writeInteger(record + R_Y, overlay.y)
  core.writeInteger(record + R_W, picture.width)
  core.writeInteger(record + R_H, picture.height)
  local frame = framePixels(picture.width, picture.height)
  core.writeInteger(record + R_DATA565,
    store(packTgx(picture.width, picture.height, picture.pixels, true)))
  core.writeInteger(record + R_DATA555,
    store(packTgx(picture.width, picture.height, picture.pixels, false)))
  core.writeInteger(record + R_OUT565, store(packTgx(picture.width, picture.height, frame, true)))
  core.writeInteger(record + R_OUT555, store(packTgx(picture.width, picture.height, frame, false)))
  core.writeInteger(record + R_NAME, storeString(overlay.name))
  -- Last, so the hook never sees a half written record.
  core.writeInteger(state.block, #overlays)
end

---A plugin hands over a folder holding overlays.lua (the file the Save button writes) and the
---PNGs it names. Called from the plugin's own enable, after this module's.
---e.g. modules["building-overlays"]:registerOverlaySource(
---  "ucp/plugins/MyPlugin-*/resources/modsupport/building-overlays/")
local function registerOverlaySource(self, path)
  if state == nil then
    pending[#pending + 1] = path
    return
  end
  local folder = path
  if io.resolveAliasedPath ~= nil then
    local ok, resolved = pcall(io.resolveAliasedPath, path)
    if ok and type(resolved) == "string" and resolved ~= "" then
      folder = resolved
    end
  end
  folder = folder:gsub("\\", "/")
  if folder:sub(-1) ~= "/" then
    folder = folder .. "/"
  end
  local text = readFile(folder, "overlays.lua")
  local chunk = text and load(text, "overlays", "t", {})
  local ok, entries = pcall(chunk or function() end)
  if not ok or type(entries) ~= "table" then
    log(WARNING, MODULE_NAME .. ": no readable overlays.lua in " .. folder)
    return
  end
  for _, entry in ipairs(entries) do
    addOverlay(entry, folder, false)
  end
  log(INFO, string.format("%s: %d overlay(s) in total after %s", MODULE_NAME, #overlays, folder))
end

---------------------------------------------------------------------------------------
-- The line-up tool in the building panel
---------------------------------------------------------------------------------------

local function formatEntry(overlay)
  return string.format(
    '  { name = "%s", building = %d, picture = "%s", entrance = "%s", units = "%s", '
    .. 'gate = "%s", x = %d, y = %d },', overlay.name, overlay.id, overlay.picture,
    overlay.entrance, overlay.units, overlay.gate, overlay.x, overlay.y)
end

local function writeCalibration()
  local lines = {
    "-- Written by Building Overlays (the Save button). Copy it into a plugin as",
    "-- resources/modsupport/building-overlays/overlays.lua, next to the PNGs it names.",
    "return {",
  }
  for _, overlay in ipairs(overlays) do
    overlay.x = core.readInteger(overlay.record + R_X)
    overlay.y = core.readInteger(overlay.record + R_Y)
    lines[#lines + 1] = formatEntry(overlay)
    log(INFO, formatEntry(overlay))
  end
  lines[#lines + 1] = "}"
  local ok, file = pcall(io.open, MODULE_FOLDERS[1] .. "calibration.lua", "wb")
  if ok and file ~= nil then
    file:write(table.concat(lines, "\n"), "\n")
    file:close()
    log(INFO, MODULE_NAME .. ": saved " .. MODULE_FOLDERS[1] .. "calibration.lua")
  else
    log(WARNING, MODULE_NAME .. ": could not write calibration.lua; copy the lines above")
  end
end

---What a click on the panel tool does (the assembly has already taken the click away).
local function onClick(ui)
  local kind = core.readInteger(ui.CLICK_KIND)
  local arg = core.readInteger(ui.CLICK_ARG)
  if kind == 1 then
    local on = not (core.readInteger(state.block + 4) ~= 0
      and core.readInteger(state.block + 8) == arg)
    core.writeInteger(state.block + 8, arg)
    core.writeInteger(state.block + 4, on and 1 or 0)
  elseif kind == 2 then
    local record = core.readInteger(state.block + 8)
    local step = STEPS[core.readInteger(ui.STEP_INDEX) + 1]
    local dx, dy = 0, 0
    if arg == 0 then dy = -step elseif arg == 1 then dy = step
    elseif arg == 2 then dx = -step else dx = step end
    core.writeInteger(record + R_X, core.readInteger(record + R_X) + dx)
    core.writeInteger(record + R_Y, core.readInteger(record + R_Y) + dy)
  elseif kind == 3 then
    core.writeInteger(ui.STEP_INDEX, (core.readInteger(ui.STEP_INDEX) + 1) % #STEPS)
  elseif kind == 4 then
    writeCalibration()
  end
end

---A cdecl function with no arguments that runs `callback` in lua (UCP's own detour trick).
local function luaFunction(purpose, callback)
  local pad = core.allocateCode({ 0x90, 0x90, 0x90, 0x90, 0x90, 0xC3 })
  local reported = false
  core.detourCode(function(registers)
    local ok, message = pcall(callback)
    if not ok and not reported then
      reported = true
      log(WARNING, string.format("%s: %s failed: %s", MODULE_NAME, purpose, tostring(message)))
    end
    return registers
  end, pad, 5)
  return pad
end

-- writeCodeInteger: the static item table lies in the exe image.
local function setField(item, offset, value)
  if core.readInteger(item + offset) ~= value then
    core.writeCodeInteger(item + offset, value)
  end
end

---The building panel's item table, its first every-frame item and its work status line.
local function findBuildingMenu()
  local repairItem = scan(AOB_REPAIR_ITEM, "the building panel's Repair button")
  local start, limit = repairItem, 400
  while core.readInteger(start - ITEM_SIZE + ITEM_TYPE) ~= TYPE_LAST and limit > 0 do
    start = start - ITEM_SIZE
    limit = limit - 1
  end
  if limit == 0 or core.readInteger(start + ITEM_TYPE) ~= TYPE_EVERY_FRAME then
    error(MODULE_NAME .. ": the building panel is not the one this module knows")
  end
  local item = start
  while core.readInteger(item + ITEM_TYPE) ~= TYPE_BLOCK do
    if core.readInteger(item + ITEM_TYPE) == 3 and core.readInteger(item + ITEM_X) == STATUS_LINE[1]
        and core.readInteger(item + ITEM_Y) == STATUS_LINE[2] then
      return start, item
    end
    item = item + ITEM_SIZE
  end
  error(MODULE_NAME .. ": the building panel's status line is not where this module expects it")
end

---Wraps the first every-frame item (clicks) and the work status line (drawing) in an item list.
local function wrapItems(items, originals, wrappers)
  local item, limit, frameDone, renders = items, 4000, false, 0
  while core.readInteger(item + ITEM_TYPE) ~= TYPE_LAST and limit > 0 do
    local kind = core.readInteger(item + ITEM_TYPE)
    if not frameDone and kind == TYPE_EVERY_FRAME
        and core.readInteger(item + ITEM_ACTION) == originals.frame then
      setField(item, ITEM_ACTION, wrappers.frame)
      frameDone = true
    elseif kind ~= TYPE_BLOCK and core.readInteger(item + ITEM_RENDER) == originals.render then
      setField(item, ITEM_RENDER, wrappers.render)
      renders = renders + 1
    end
    item = item + ITEM_SIZE
    limit = limit - 1
  end
  log(INFO, string.format("%s: panel items at %08X: click item %s, %d status line(s) wrapped",
    MODULE_NAME, items, frameDone and "wrapped" or "not found", renders))
end

local function installPanel(v)
  local start, status = findBuildingMenu()
  local nameBox = scan(AOB_NAME_BOX, "the game's text drawing")
  local menuItem = scan(AOB_MENU_ITEM, "the menu item handler")
  local drawColourBox = readCallTarget(nameBox, NAME_BOX_DRAW_COLOUR_BOX, "the box drawing")
  local blend = scan(AOB_BLEND, "the game's sprite fading")

  local data = core.allocate(64, true)
  local ui = {
    SHOWN = data, PICKED_SHOWN = data + 1, ROW_COUNT = data + 4, CLICK_KIND = data + 8,
    CLICK_ARG = data + 12, STEP_INDEX = data + 16, ORIGINAL_RENDER = data + 20,
    ORIGINAL_FRAME = data + 24,
    ROWS = core.allocate(MAX_ROWS * 4, true),
    ARROW_RECTS = core.allocate(4 * 16, true),
    ARROW_BASE = core.allocate(4 * 16, true),
    ORIGIN = core.allocate(8, true),
    ARROW_PICTURES = core.allocate(4 * 8, true),
    STEP_TEXTS = core.allocate(#STEPS * 4, true),
    SAVE_TEXT = storeString("Save"),
  }
  for index, name in ipairs(ARROW_NAMES) do
    local rect = ui.ARROW_BASE + (index - 1) * 16
    core.writeInteger(ui.ARROW_RECTS + (index - 1) * 16 + 8, ARROW_SIZE)
    core.writeInteger(ui.ARROW_RECTS + (index - 1) * 16 + 12, ARROW_SIZE)
    core.writeInteger(rect, ARROW_PLACES[index][1])
    core.writeInteger(rect + 4, ARROW_PLACES[index][2])
    core.writeInteger(rect + 8, ARROW_SIZE)
    core.writeInteger(rect + 12, ARROW_SIZE)
    for hovered = 0, 1 do
      core.writeInteger(ui.ARROW_PICTURES + (index - 1) * 8 + hovered * 4,
        storeBlitPicture(ARROW_SIZE, ARROW_SIZE, arrowPixels(name, hovered == 1)))
    end
  end
  for index, step in ipairs(STEPS) do
    core.writeInteger(ui.STEP_TEXTS + (index - 1) * 4, storeString(string.format("Step: %d px", step)))
  end

  local w = {}
  for key, value in pairs(v) do w[key] = value end
  for key, value in pairs(ui) do w[key] = value end
  w.SCRATCH = core.allocate(64, true)
  w.PENCIL = readOperand(nameBox, NAME_BOX_PENCIL, "the pencil")
  w.BUTTON_X = readOperand(nameBox, NAME_BOX_ITEM_X, "the item position")
  w.BUTTON_Y = readOperand(nameBox, NAME_BOX_ITEM_Y, "the item position")
  w.STATUS_X, w.STATUS_Y = STATUS_LINE[1], STATUS_LINE[2]
  w.TEXT_MANAGER = readOperand(nameBox, NAME_BOX_TEXT_MANAGER, "the text drawing")
  w.SHADOWED_TEXT = readCallTarget(nameBox, NAME_BOX_SHADOWED_TEXT, "the text drawing")
  w.SETUP_SURFACE = readCallTarget(drawColourBox, DRAW_COLOUR_BOX_SURFACE, "the drawing surface")
  w.SETUP_PENCIL = readCallTarget(drawColourBox, DRAW_COLOUR_BOX_CLIP, "the clipping")
  w.MOUSE = readOperand(menuItem, MENU_ITEM_MOUSE, "the mouse")
  w.IS_INSIDE = readCallTarget(menuItem, MENU_ITEM_IS_INSIDE, "the mouse test")
  w.LEFT_CLICK = MOUSE_LEFT_CLICK
  w.BLEND_READY = core.readInteger(blend + BLEND_READY_OPERAND)
  w.BUILD_BLEND = readCallTarget(blend, BLEND_BUILD_CALL, "the blend tables")
  w.BLEND_TABLES = core.readInteger(blend + BLEND_TABLES_OPERAND)
  if core.readInteger(blend + BLEND_TOP_OPERAND) ~= w.BLEND_TABLES + 32 * BLEND_LEVEL_SIZE then
    error(MODULE_NAME .. ": the game's blend tables are not the ones this module knows")
  end
  w.BUILDING_SIZE, w.MAX_ROWS = BUILDING_SIZE, MAX_ROWS
  w.LIST_X, w.LIST_Y, w.LIST_W, w.LINE = LIST_X, LIST_Y, LIST_W, LINE
  w.SAVE_X, w.SAVE_Y, w.SAVE_W = SAVE_X, SAVE_Y, SAVE_W
  w.STEP_X, w.STEP_Y, w.STEP_W = STEP_X, STEP_Y, STEP_W
  w.COLOUR, w.PICKED_COLOUR, w.FONT = COLOUR, PICKED_COLOUR, FONT
  w.LUA_CLICK = luaFunction("the overlay panel", function() onClick(ui) end)
  -- Logged whenever the panel's selected building or the number of listed overlays changes.
  w.DIAG = core.allocate(8, true)
  core.writeInteger(w.DIAG, -2)
  w.LUA_DIAG = luaFunction("the panel report", function()
    local building = core.readInteger(w.DIAG)
    local kind = -1
    if building > 0 then
      kind = core.readSmallInteger(v.BUILDINGS + building * BUILDING_SIZE + B_TYPE)
    end
    log(INFO, string.format("%s: panel drawn, selected building %d (type %d), %d overlay(s) listed",
      MODULE_NAME, building, kind, core.readInteger(w.DIAG + 4)))
  end)

  local originals = {
    render = core.readInteger(status + ITEM_RENDER),
    frame = core.readInteger(start + ITEM_ACTION),
  }
  core.writeInteger(ui.ORIGINAL_RENDER, originals.render)
  core.writeInteger(ui.ORIGINAL_FRAME, originals.frame)
  w.BLIT = assemble(panel.blit, w)
  w.DRAW_BUTTON = assemble(panel.drawButton, w)
  local wrappers = {
    render = assemble(panel.render, w),
    frame = assemble(panel.click, w),
  }

  wrapItems(start, originals, wrappers)
  local startBytes = {}
  for _, byte in ipairs(core.itob(start)) do
    startBytes[#startBytes + 1] = string.format("%02X", byte & 0xFF)
  end
  local found, constructorSite = pcall(core.AOBScan, "68 " .. table.concat(startBytes, " ") .. " B9")
  if found and constructorSite ~= nil then
    local menu = core.readInteger(constructorSite + 6)
    local function wrapLive()
      local items = core.readInteger(menu)
      log(INFO, string.format("%s: building panel uses items at %08X (static %08X)", MODULE_NAME,
        items, start))
      if items ~= 0 and items ~= start then
        wrapItems(items, originals, wrappers)
      end
    end
    wrapLive()
    hooks.registerHookCallback("afterInit", wrapLive)
  else
    log(WARNING, MODULE_NAME .. ": could not find the building panel itself; the overlay tool "
      .. "relies on its item table")
  end
end

---------------------------------------------------------------------------------------
-- Enable
---------------------------------------------------------------------------------------

local function enable(self, config)
  config = config or {}
  overlays = {}

  local tail = scan(AOB_TAIL, "the end of the building overlay drawing")
  local pixelFormat = core.readInteger(scan(AOB_PIXEL_FORMAT, "the pixel format")
    + PIXEL_FORMAT_OPERAND)
  local orientation = core.readInteger(scan(AOB_MAP_ORIENTATION, "the map orientation")
    + MAP_ORIENTATION_OPERAND)
  local unitsOnBuilding = scan(AOB_UNITS_ON_BUILDING, "the units-on-building test")
  local typeDisplacement = core.readInteger(tail + TYPE_DISPLACEMENT_OPERAND)
  local renderCore = core.readInteger(tail + CORE_OPERAND)
  local selected = readOperand(tail, TAIL_SELECTED, "the selected building")
  local renderGm = tail + RENDER_GM_REL_OPERAND + 4 + core.readInteger(tail + RENDER_GM_REL_OPERAND)
  if (core.readByte(tail - 10) & 0xFF) ~= 0xB9 or (core.readByte(tail - 5) & 0xFF) ~= 0xE8
      or (core.readByte(renderGm + RENDER_GM_BLIT_CALL) & 0xFF) ~= 0xE8 then
    error(MODULE_NAME .. ": the game's overlay drawing is not the one this module knows")
  end
  local blit = renderGm + RENDER_GM_BLIT_CALL + 5
    + core.readInteger(renderGm + RENDER_GM_BLIT_CALL + 1)
  local buildings = (typeDisplacement - B_TYPE) & 0xFFFFFFFF

  state = {
    block = core.allocate(16, true),           -- +0 overlay count, +4 tool on, +8 picked record
    records = core.allocate(MAX_OVERLAYS * RECORD_SIZE, true),
  }

  local original = {}
  for offset = 0, TAIL_SIZE - 1 do
    original[#original + 1] = string.format("0x%02X", core.readByte(tail + offset) & 0xFF)
  end
  local values = {
    BUILDINGS = buildings, BSHOWN = B_SHOWN, STATE = state.block, SELECTED = selected,
    FRAME0 = B_FRAMES[1], FRAME1 = B_FRAMES[2], FRAME2 = B_FRAMES[3], FRAME3 = B_FRAMES[4],
    BTYPE = B_TYPE, OCCUPIED = B_OCCUPIED, VARIATION = B_VARIATION, VARIATION_X = VARIATION_X,
    GATE_STATE = B_GATE_STATE, SCRATCH = core.allocate(32, true), MAP_ORIENTATION = orientation,
    PIXEL_FORMAT = pixelFormat, RECORDS = state.records, RECORD_SIZE = RECORD_SIZE,
    RENDER_CORE = renderCore, BLIT = blit, RESUME = tail + TAIL_SIZE,
    BUILDINGS_STATE = buildings - BUILDINGS_STATE_BEFORE_ARRAY, UNITS_ON_BUILDING = unitsOnBuilding,
    R_TYPE = R_TYPE, R_UNITS = R_UNITS, R_ENTRANCE = R_ENTRANCE, R_GATE = R_GATE, R_X = R_X,
    R_Y = R_Y, R_W = R_W, R_H = R_H, R_DATA565 = R_DATA565, R_DATA555 = R_DATA555,
    R_OUT565 = R_OUT565, R_OUT555 = R_OUT555, R_NAME = R_NAME,
  }
  local script = SCRIPT:gsub("%f[%w_]ORIGINAL%f[^%w_]", "db " .. table.concat(original, ","))
  local blob = assemble(script, values)

  -- The module's own list first; the count stays 0 until the first record is complete.
  local swap = setting(config, "large_gatehouse", "swap_sides")
  local calibrated = loadCalibration()
  for _, entry in ipairs(list) do
    if setting(config, entry.group, "enabled") then
      local copy = {}
      for key, value in pairs(entry) do
        copy[key] = value
      end
      local spot = calibrated[entry.name]
      if spot ~= nil then
        copy.x, copy.y = spot.x, spot.y
      end
      addOverlay(copy, MODULE_FOLDERS[1] .. "overlays/", swap and entry.group == "large_gatehouse")
    end
  end

  core.writeCode(tail, { 0xE9, core.itob(core.getRelativeAddress(tail, blob, -5)), 0x90, 0x90 })

  if setting(config, "editor", "enabled") then
    local ok, message = pcall(installPanel, values)
    if not ok then
      log(WARNING, MODULE_NAME .. ": the overlay tool in the building panel is off: "
        .. tostring(message))
    end
  end

  for _, path in ipairs(pending) do
    registerOverlaySource(self, path)
  end
  pending = {}
  log(INFO, string.format("%s: %d overlay(s) active", MODULE_NAME, #overlays))
end

return {
  enable = enable,
  disable = function(self, config) end,
  registerOverlaySource = registerOverlaySource,
}
