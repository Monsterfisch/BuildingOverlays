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
  editor = { enabled = true, key = "letter_o" },
}

-- Alt + key that switches the line-up tool on and off; only keys that do nothing in the
-- game's WM_SYSKEYDOWN table (the same list resource-grid-overlay offers).
local VIRTUAL_KEY_CODES = {
  letter_a = 0x41, letter_b = 0x42, letter_f = 0x46, letter_g = 0x47, letter_i = 0x49,
  letter_j = 0x4A, letter_l = 0x4C, letter_m = 0x4D, letter_n = 0x4E, letter_o = 0x4F,
  letter_p = 0x50, letter_s = 0x53, letter_w = 0x57, letter_y = 0x59, letter_z = 0x5A,
  f1 = 0x70, f2 = 0x71, f3 = 0x72, f4 = 0x73, f5 = 0x74, f6 = 0x75, f7 = 0x76, f8 = 0x77,
  f9 = 0x78, insert = 0x2D, delete_key = 0x2E, home = 0x24,
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
local RECORD_SIZE = 0x30
local R_TYPE, R_UNITS, R_ENTRANCE, R_GATE, R_X, R_Y, R_W, R_H, R_DATA565, R_DATA555 =
  0, 4, 8, 0xC, 0x10, 0x14, 0x18, 0x1C, 0x20, 0x24
local R_OUT565, R_OUT555 = 0x28, 0x2C      -- the frame drawn round the picked overlay

-- The game's own "are there units on this building's tiles" test: thiscall on the buildings
-- state (building array - 0x14), one argument, `ret 4`.
local AOB_UNITS_ON_BUILDING = "8B 44 24 04 69 C0 2C 03 00 00 53 55 03 C1 56 8B B0 0C 01 00 00 "
  .. "33 DB 85 F6 57 7E"
local BUILDINGS_STATE_BEFORE_ARRAY = 0x14

-- The mouse state (`isMouseInsideBox` is called on it): +0x10 / +0x14 the mouse x / y on the
-- screen. Read from the menu item handler, the same pattern smarter-recruits uses.
local AOB_MOUSE = "8B 56 10 8B 46 4C 8B 4E 0C 52 8B 50 08 03 56 08 8B 40 04 03 46 04 51 52 50 "
  .. "B9 ? ? ? ? E8"
local MOUSE_OPERAND = 26
local MOUSE_X, MOUSE_Y = 0x10, 0x14
-- The one call of GetAsyncKeyState in the exe; the operand is its import slot.
local AOB_ASYNC_KEY = "6A 28 FF 15 ? ? ? ? 66 85 C0"
local ASYNC_KEY_OPERAND = 4
local ZOOMED_OUT = 0x54                  -- in the texture render core: 1 while zoomed out

-- The four arrow buttons next to the picked overlay: up and down on its right, left and
-- right under it. Sizes in pixels.
local ARROW_SIZE = 24
local ARROW_GAP = 8
local ARROW_NAMES = { "up", "down", "left", "right" }

local UNITS = { empty = 0, occupied = 1, any = 2 }
local ENTRANCES = { any = 0, left = 1, right = 2 }
-- A bit per gate state (0 open, 1 closing, 2 closed, 3 opening).
local GATES = { any = 0xF, open = 0x1, closing = 0x2, closed = 0x4, opening = 0x8 }

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
cmp dword [STATE+4],0
je normal
cmp ecx,[STATE+8]
je draw
normal:
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
cmp dword [STATE+4],0
je skip
cmp ecx,[STATE+8]
jne skip
cmp dword [PIXEL_FORMAT],0x565
mov eax,[ecx+R_OUT565]
je frame_ready
mov eax,[ecx+R_OUT555]
frame_ready:
call drawit
ARROW_CALLS
skip:
add ecx,RECORD_SIZE
dec edx
jne next
done:
popad
popfd
ORIGINAL
jmp RESUME
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

-- One arrow button, its own assembly (UCP gives FASM 64 KB for source, symbols and output).
-- In: eax / ebp its top left on the map surface, [SCRATCH+28] which arrow (0 up, 1 down,
-- 2 left, 3 right), ecx the picked overlay's record. Tests the mouse against it (halved when
-- zoomed out), moves the overlay while the left button is held on it (one step at once,
-- then after a pause one every few frames, faster after a while) and draws it.
local ARROW_SCRIPT = [[
push ebx
push ecx
push edx
mov [SCRATCH+20],eax
mov [SCRATCH+24],ebp
mov [SCRATCH+44],ecx
mov edx,ARROW_SIZE
cmp dword [ZOOMED_OUT],0
je full_size
sar eax,1
sar ebp,1
mov edx,ARROW_HALF
full_size:
xor ebx,ebx
mov ecx,[MOUSE_X]
sub ecx,eax
cmp ecx,edx
jae pointer_away
mov ecx,[MOUSE_Y]
sub ecx,ebp
cmp ecx,edx
jae pointer_away
mov ebx,1
pointer_away:
push 1
call dword [ASYNC_KEY]
test ah,0x80
jne button_down
mov dword [STATE+12],0
mov ecx,[SCRATCH+44]
mov eax,[ecx+R_X]
mov [STATE+16],eax
mov eax,[ecx+R_Y]
mov [STATE+20],eax
jmp pressed
button_down:
test ebx,ebx
je pressed
mov eax,[STATE+12]
inc dword [STATE+12]
test eax,eax
je one_step
cmp eax,18
jb pressed
cmp eax,90
jae fast
test al,3
jne pressed
jmp one_step
fast:
test al,1
jne pressed
mov dword [SCRATCH+48],3
jmp apply
one_step:
mov dword [SCRATCH+48],1
apply:
mov ecx,[SCRATCH+44]
mov eax,[SCRATCH+48]
mov edx,[SCRATCH+28]
test edx,edx
je go_up
cmp edx,1
je go_down
cmp edx,2
je go_left
add [ecx+R_X],eax
jmp pressed
go_up:
sub [ecx+R_Y],eax
jmp pressed
go_down:
add [ecx+R_Y],eax
jmp pressed
go_left:
sub [ecx+R_X],eax
pressed:
mov eax,[SCRATCH+28]
add eax,eax
add eax,ebx
shl eax,3
lea edx,[eax+ARROWS]
cmp dword [PIXEL_FORMAT],0x565
mov eax,[edx]
je arrow_ready
mov eax,[edx+4]
arrow_ready:
push eax
push ARROW_SIZE
push ARROW_SIZE
push dword [SCRATCH+24]
push dword [SCRATCH+20]
mov ecx,RENDER_CORE
mov eax,BLIT
call eax
pop edx
pop ecx
pop ebx
ret
]]

-- Where the four arrows sit, as asm for the picked overlay (ecx): right of it, above and
-- below its middle, and under it, left and right of its middle. They stay put while the
-- button is held (else the overlay would slide out from under the mouse) and catch up with
-- the overlay when it is let go.
local function arrowCalls()
  local lines = {}
  local half = ARROW_SIZE + 2
  local function add(text)
    lines[#lines + 1] = text
  end
  for k = 0, 3 do
    add("mov eax,[STATE+16]")
    add("add eax,edi")
    add("mov ebp,[STATE+20]")
    add("add ebp,esi")
    if k < 2 then
      add("add eax,[ecx+R_W]")
      add("add eax," .. ARROW_GAP)
      add("push eax")
      add("mov eax,[ecx+R_H]")
      add("shr eax,1")
      add("add ebp,eax")
      add(k == 0 and ("sub ebp," .. half) or "add ebp,2")
      add("pop eax")
    else
      add("push ebp")
      add("mov ebp,[ecx+R_W]")
      add("shr ebp,1")
      add("add eax,ebp")
      add(k == 2 and ("sub eax," .. half) or "add eax,2")
      add("pop ebp")
      add("add ebp,[ecx+R_H]")
      add("add ebp," .. ARROW_GAP)
    end
    add("mov dword [SCRATCH+28]," .. k)
    add("call ARROW")
  end
  return table.concat(lines, "\n")
end

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

local function readFile(folder, name)
  local file = io.open(folder .. name, "rb")
  if file == nil then
    return nil
  end
  local data = file:read("a")
  file:close()
  return data
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

---A chevron arrow, ARROW_SIZE square, pointing the given way, as pixels for packTgx.
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
  local pixels = {}
  for y = 0, size - 1 do
    for x = 0, size - 1 do
      local d = math.min(distance(x + 0.5, y + 0.5, a, b), distance(x + 0.5, y + 0.5, b, c))
      pixels[y * size + x + 1] = d <= 1.7 and fill or d <= 2.7 and edge or { 0, 0, 0, 0 }
    end
  end
  return pixels
end

local function store(bytes)
  local address = core.allocate(#bytes, true)
  core.writeBytes(address, bytes)
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

---Spots saved by Alt + End: a list of overlay entries, used for x and y by name.
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
    name = entry.name, id = id, entrance = entry.entrance or "any",
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
  -- Last, so the hook never sees a half written record.
  core.writeInteger(state.block, #overlays)
end

---A plugin hands over a folder holding overlays.lua (the file Alt + End writes) and the PNGs
---it names. Called from the plugin's own enable, after this module's.
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
-- The line-up tool: Alt + <key> switches it on, then Alt + arrows move the picked overlay
---------------------------------------------------------------------------------------

local function formatEntry(overlay)
  return string.format(
    '  { name = "%s", building = %d, picture = "%s", entrance = "%s", units = "%s", '
    .. 'gate = "%s", x = %d, y = %d },', overlay.name, overlay.id, overlay.picture,
    overlay.entrance, overlay.units, overlay.gate, overlay.x, overlay.y)
end

local function writeCalibration()
  local lines = {
    "-- Written by Building Overlays (Alt + End). Copy it into a plugin as",
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

local function pick(index)
  state.selected = index
  core.writeInteger(state.block + 8, overlays[index].record)
  core.writeInteger(state.block + 16, core.readInteger(overlays[index].record + R_X))
  core.writeInteger(state.block + 20, core.readInteger(overlays[index].record + R_Y))
  log(INFO, string.format("%s: picked %s (%d of %d)", MODULE_NAME, overlays[index].name,
    index, #overlays))
end

local function installKeys(dispatch, toggleKey)
  core.detourCode(function(registers)
    local key = registers.ESI
    if #overlays == 0 then
      return registers
    end
    if key == toggleKey then
      local on = core.readInteger(state.block + 4) == 0
      core.writeInteger(state.block + 4, on and 1 or 0)
      if on then
        pick(state.selected)
      end
      log(INFO, MODULE_NAME .. ": line-up tool " .. (on and "on" or "off"))
      return registers
    end
    if core.readInteger(state.block + 4) == 0 then
      return registers
    end
    local dx, dy = 0, 0
    if key == VK.prior then
      pick((state.selected - 2) % #overlays + 1)
    elseif key == VK.next then
      pick(state.selected % #overlays + 1)
    elseif key == VK.finish then
      writeCalibration()
    elseif key == VK.left then dx = -1
    elseif key == VK.right then dx = 1
    elseif key == VK.up then dy = -1
    elseif key == VK.down then dy = 1
    end
    if dx ~= 0 or dy ~= 0 then
      local overlay = overlays[state.selected]
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
  local renderGm = tail + RENDER_GM_REL_OPERAND + 4 + core.readInteger(tail + RENDER_GM_REL_OPERAND)
  if (core.readByte(tail - 10) & 0xFF) ~= 0xB9 or (core.readByte(tail - 5) & 0xFF) ~= 0xE8
      or (core.readByte(renderGm + RENDER_GM_BLIT_CALL) & 0xFF) ~= 0xE8 then
    error(MODULE_NAME .. ": the game's overlay drawing is not the one this module knows")
  end
  local blit = renderGm + RENDER_GM_BLIT_CALL + 5
    + core.readInteger(renderGm + RENDER_GM_BLIT_CALL + 1)
  local buildings = (typeDisplacement - B_TYPE) & 0xFFFFFFFF

  state = {
    block = core.allocate(24, true),   -- +0 count, +4 tool on, +8 picked record, +12 frames held,
                                       -- +16 / +20 where the arrows sit (the picked spot)
    records = core.allocate(MAX_OVERLAYS * RECORD_SIZE, true),
    selected = 1,
    arrows = core.allocate(#ARROW_NAMES * 2 * 8, true),   -- per arrow and hover state: 565, 555
  }
  for index, name in ipairs(ARROW_NAMES) do
    for hovered = 0, 1 do
      local pixels = arrowPixels(name, hovered == 1)
      local entry = state.arrows + ((index - 1) * 2 + hovered) * 8
      core.writeInteger(entry, store(packTgx(ARROW_SIZE, ARROW_SIZE, pixels, true)))
      core.writeInteger(entry + 4, store(packTgx(ARROW_SIZE, ARROW_SIZE, pixels, false)))
    end
  end

  local original = {}
  for offset = 0, TAIL_SIZE - 1 do
    original[#original + 1] = string.format("0x%02X", core.readByte(tail + offset) & 0xFF)
  end
  local script = SCRIPT:gsub("%f[%w_]ORIGINAL%f[^%w_]", "db " .. table.concat(original, ","))
  script = script:gsub("%f[%w_]ARROW_CALLS%f[^%w_]", arrowCalls())
  local mouse = core.readInteger(scan(AOB_MOUSE, "the mouse state") + MOUSE_OPERAND)
  local asyncKey = core.readInteger(scan(AOB_ASYNC_KEY, "the key state call") + ASYNC_KEY_OPERAND)
  local values = {
    BUILDINGS = buildings, BSHOWN = B_SHOWN, STATE = state.block,
    FRAME0 = B_FRAMES[1], FRAME1 = B_FRAMES[2], FRAME2 = B_FRAMES[3], FRAME3 = B_FRAMES[4],
    BTYPE = B_TYPE, OCCUPIED = B_OCCUPIED, VARIATION = B_VARIATION, VARIATION_X = VARIATION_X,
    GATE_STATE = B_GATE_STATE, SCRATCH = core.allocate(64, true), MAP_ORIENTATION = orientation,
    PIXEL_FORMAT = pixelFormat, RECORDS = state.records, RECORD_SIZE = RECORD_SIZE,
    RENDER_CORE = renderCore, BLIT = blit, RESUME = tail + TAIL_SIZE,
    BUILDINGS_STATE = buildings - BUILDINGS_STATE_BEFORE_ARRAY, UNITS_ON_BUILDING = unitsOnBuilding,
    R_TYPE = R_TYPE, R_UNITS = R_UNITS, R_ENTRANCE = R_ENTRANCE, R_GATE = R_GATE, R_X = R_X,
    R_Y = R_Y, R_W = R_W, R_H = R_H, R_DATA565 = R_DATA565, R_DATA555 = R_DATA555,
    R_OUT565 = R_OUT565, R_OUT555 = R_OUT555, ARROWS = state.arrows,
    MOUSE_X = mouse + MOUSE_X, MOUSE_Y = mouse + MOUSE_Y, ASYNC_KEY = asyncKey,
    ZOOMED_OUT = renderCore + ZOOMED_OUT, ARROW_SIZE = ARROW_SIZE, ARROW_HALF = ARROW_SIZE // 2,
  }
  -- FASM gets a fixed 64 KB for source, symbols and output: only pass what a script uses.
  local function assemble(text)
    local used = {}
    for name, value in pairs(values) do
      if text:find("%f[%w_]" .. name .. "%f[^%w_]") then
        used[name] = value
      end
    end
    return core.allocateAssembly(text, used)
  end
  values.ARROW = assemble(ARROW_SCRIPT)
  local blob = assemble(script)

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
    local ok, dispatch = pcall(core.AOBScan, AOB_SYS_KEY)
    local keyName = setting(config, "editor", "key")
    local toggleKey = VIRTUAL_KEY_CODES[keyName]
    if toggleKey == nil then
      log(WARNING, string.format("%s: unknown key '%s', using Alt + O", MODULE_NAME, tostring(keyName)))
      toggleKey = VIRTUAL_KEY_CODES[DEFAULTS.editor.key]
    end
    if ok and dispatch ~= nil then
      installKeys(dispatch, toggleKey)
    else
      log(WARNING, MODULE_NAME .. ": could not find the Alt key handler; the line-up tool is off")
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
