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
local strips = require("strips")

local MODULE_NAME = "building-overlays"
local MODULE_FOLDERS = { "ucp/modules/building-overlays/" }   -- UCP maps this to the active version

local DEFAULTS = {
  large_gatehouse = { enabled = true, swap_sides = false },
  editor = { enabled = true },
  drawing = { tile_by_tile = true },
  mouse = { hover_only = false },
}

-- Overlays a plugin may add on top of the ones in overlay_list.lua.
local MAX_OVERLAYS = 64

-- Building ids (BuildingType); overlay_list.lua may also use the plain number.
local BUILDINGS = {
  large_gatehouse = 45, small_gatehouse = 46,
  tower1 = 74, tower2 = 75, tower3 = 76, tower4 = 77, tower5 = 78,
  manor_house = 40, stone_keep = 41, stronghold = 42, keep_four = 43, keep_five = 44,
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
-- The V view (the editor's and game's "lower the buildings" key): the flag renderMap reads,
-- command object +0x5548C4 - zero while the V view is on. Object from the key handler.
local AOB_V_VIEW = "6A 03 B9 ? ? ? ? E8 ? ? ? ? 89 2D ? ? ? ? E9"
local V_VIEW_OBJECT, V_VIEW_FIELD = 3, 0x5548C4
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
local RECORD_SIZE = 0x40
local R_TYPE, R_UNITS, R_ENTRANCE, R_GATE, R_X, R_Y, R_W, R_H, R_DATA565, R_DATA555 =
  0, 4, 8, 0xC, 0x10, 0x14, 0x18, 0x1C, 0x20, 0x24
local R_OUT565, R_OUT555 = 0x28, 0x2C      -- the frame drawn round the picked overlay
local R_NAME = 0x30                        -- its name, for the panel list
-- The picture cut into strips one tile column wide (strips.lua): a table of
-- { data565, data555, x, width } per strip, their number, and where the cuts fall.

-- The game's own "are there units on this building's tiles" test: thiscall on the buildings
-- state (building array - 0x14), one argument, `ret 4`.
local AOB_UNITS_ON_BUILDING = "8B 44 24 04 69 C0 2C 03 00 00 53 55 03 C1 56 8B B0 0C 01 00 00 "
  .. "33 DB 85 F6 57 7E"
-- Its operands are what this module's own test reads: it walks the same footprint, but walks
-- every unit on a tile (unit +0x2A2 is the next one on the same tile) and leaves out the lord on
-- a keep (he always stands on it), and units walking through a gatehouse's passage.
local UNITS_TRANSLATE = { 0x2D, { 0x8D, 0x3C, 0xBD } }   -- lea edi, [edi*4 + tile rows]
local UNITS_TILES = { 0x3A, { 0x8D, 0x14, 0x55 } }       -- lea edx, [edx*2 + unit per tile]
local UNITS_OWNER = { 0x4E, { 0x0F, 0xBF, 0x80 } }       -- movsx eax, word [eax + unit owner]
local UNITS_PLAYERS = { 0x55, { 0x83, 0x3C, 0x85 } }     -- cmp [eax*4 + player ids], -1
local UNIT_SIZE, U_OWNER, U_TYPE, U_NEXT, LORD = 0x490, 0x96, 0x8E, 0x2A2, 55
-- Non-zero while a unit on a gatehouse is drawn walking through the passage rather than on the
-- roof (see smarter-gatehouses): those are hidden by the gatehouse anyway.
local U_PASSAGE = 0x402
local KEEP_FIRST, KEEP_LAST = 40, 44     -- manor house .. the largest keep: the lord lives there
local B_X, B_Y, B_SIZE, B_UID = 0xEE, 0xF0, 0xF8, 0xD8


-- The game's own tower and keep overlays: `cmp dword [reg + building +0xB0], edx / 0` before
-- each, in renderGmOverlayBuilding and renderGmOverlayBuilding2 (the 0x3000 bytes before the
-- tail): "troops on it" skips the crenellations and the roof together. In "only while the
-- mouse is on it" mode each becomes a call that, for a tower, notes the game's answer (GATED)
-- and lets the drawing go on; the picture hook (installSites) then skips the crenellations as
-- the game would and leaves the roof to the mouse. Every other building gets the game's answer.
local VANILLA_SEARCH = 0x3000
local REGISTERS = { [0] = "eax", "ecx", "edx", "ebx", nil, "ebp", "esi", "edi" }
local VANILLA_THUNK = [[
push eax
movzx eax,word [REG+TYPE_FIELD]
cmp eax,FIRST_TOWER
jb v_game
cmp eax,LAST_TOWER
ja v_game
pop eax
ORIGINAL
je v_open
mov dword [GATED],1
v_open:
cmp esp,esp
ret
v_game:
pop eax
ORIGINAL
ret
]]

-- Which building is under the mouse. renderMap writes a marker pixel under the mouse before it
-- draws each building and stores the building in the view's +0x1C when the marker got painted
-- over; it clears +0x1C when it starts a frame. The hook at that clear keeps the last frame's
-- answer (LAST_HOVER) and the view (VIEWPORT). The pixel under the mouse is (view +0x80 + mouse
-- x, view +0x84 + mouse y) on the map surface, which the operands below give.
local AOB_FRAME_START = "8B 0D ? ? ? ? 8B 93 80 00 00 00 89 4B 74 03 15 ? ? ? ? 8B 8B 84 00 00 00 "
  .. "03 D2 01 53 74 03 0D ? ? ? ? 8B 43 74 69 C9 B0 1F 00 00 03 C8 BA 01 00 00 00 89 4B 74 89 73 1C "
  .. "89 73 28"
local FRAME_START_MOUSE_X, FRAME_START_MOUSE_Y = 17, 34
local FRAME_START_HOOK, FRAME_START_SIZE = 57, 6
local VP_HOVER, VP_MOUSE_X, VP_MOUSE_Y = 0x1C, 0x80, 0x84
local FRAME_START_SCRIPT = [[
inc dword [FRAME]
push eax
mov eax,[ebx+VP_HOVER]
mov [LAST_HOVER],eax
mov [VIEWPORT],ebx
pop eax
mov [ebx+0x1C],esi
mov [ebx+0x28],esi
jmp FRAME_RESUME
]]

-- "Is the mouse on this building or on this overlay?" (ebx building, ecx record, edi / esi where
-- the building is drawn, [SCRATCH+16] its index) -> eax 1 / 0. The overlay's own rectangle
-- counts too, or a hidden overlay would show again as soon as the mouse is only over the part
-- of the picture that sticks out of the building, and flicker.
local HOVER_SCRIPT = [[
push edx
mov edx,[SCRATCH+16]
cmp edx,[LAST_HOVER]
je h_yes
mov edx,[VIEWPORT]
test edx,edx
je h_no
push ebp
mov ebp,[SCRATCH+16]
cmp ebp,[edx+VP_HOVER]
pop ebp
je h_yes
push ebx
push ebp
mov ebx,[edx+VP_MOUSE_X]
add ebx,[MOUSE_X]
mov ebp,[edx+VP_MOUSE_Y]
add ebp,[MOUSE_Y]
mov eax,edi
add eax,[ecx+R_X]
mov edx,esi
add edx,[ecx+R_Y]
cmp dword [ZOOMED_OUT],0
je h_full
sar eax,1
sar edx,1
sub ebx,eax
sub ebp,edx
mov eax,[ecx+R_W]
shr eax,1
cmp ebx,eax
jae h_out
mov eax,[ecx+R_H]
shr eax,1
cmp ebp,eax
jae h_out
jmp h_in
h_full:
sub ebx,eax
sub ebp,edx
cmp ebx,[ecx+R_W]
jae h_out
cmp ebp,[ecx+R_H]
jae h_out
h_in:
pop ebp
pop ebx
pop edx
mov eax,1
ret
h_out:
pop ebp
pop ebx
h_no:
pop edx
xor eax,eax
ret
h_yes:
pop edx
mov eax,1
ret
]]

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
local LIST_X, LIST_Y, LIST_W, LINE = 20, 500, 170, 16
-- The list: two columns of five short rows.
local MAX_ROWS, ROWS_PER_COLUMN, COLUMN_W, ROW_H = 10, 5, 88, 13
local SAVE_X, SAVE_Y, SAVE_W = 20, 570, 50
local STEP_X, STEP_Y, STEP_W = 80, 570, 100
local ARROW_SIZE = 24
local ARROW_PLACES = { { 368, 503 }, { 368, 559 }, { 340, 531 }, { 396, 531 } }   -- up down left right
local ARROW_NAMES = { "up", "down", "left", "right" }
local STEPS = { 1, 5, 20 }
local TYPE_COUNT = 128                   -- building types the "no overlays" line can name
local COLOUR = 0xB8EEFB                  -- the panel's own beige (BGR)
local PICKED_COLOUR = 0x00FFFF           -- yellow
local FONT = 0x12

local SCRIPT = [[
pushfd
pushad
cmp dword [STATE],0
je done
cmp dword [V_VIEW],0
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
mov eax,HOVER_ONLY
test eax,eax
jne by_mouse
cmp dword [SCRATCH+4],-1
jne occupancy_known
call UNITS_HERE
mov [SCRATCH+4],eax
occupancy_known:
mov eax,[SCRATCH+4]
jmp occupancy_test
by_mouse:
call HOVERED
occupancy_test:
cmp eax,[ecx+R_UNITS]
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
mov eax,TILE_STRIPS
test eax,eax
je whole_picture
call REMEMBER
jmp picture_done
whole_picture:
cmp dword [PIXEL_FORMAT],0x565
mov eax,[ecx+R_DATA565]
je picture_ready
mov eax,[ecx+R_DATA555]
picture_ready:
call drawit
picture_done:
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

-- "Is anyone but the lord on this building?" (ebx = the building), its own assembly: UCP gives
-- FASM 64 KB for source, symbols and output, and the main script is close to that already.
local UNITS_SCRIPT = [[
push esi
push edi
push ebp
push ecx
push edx
xor eax,eax
mov esi,[ebx+B_SIZE]
test esi,esi
jle u_out
mov [SCRATCH+20],esi
movsx ebp,word [ebx+B_X]
movsx edi,word [ebx+B_Y]
lea edi,[edi+edi*2]
lea edi,[edi*4+TRANSLATE]
u_row:
mov edx,[edi]
add edx,ebp
lea edx,[edx*2+UNIT_TILES]
mov ecx,esi
u_column:
movsx eax,word [edx]
mov dword [SCRATCH+28],64
u_chain:
test eax,eax
je u_next_tile
dec dword [SCRATCH+28]
je u_next_tile
imul eax,eax,UNIT_SIZE
cmp word [eax+UNIT_TYPE],LORD
jne not_lord
cmp dword [SCRATCH],KEEP_FIRST
jb not_lord
cmp dword [SCRATCH],KEEP_LAST
jbe u_next_unit
not_lord:
cmp byte [eax+UNIT_PASSAGE],0
jne u_next_unit
mov [SCRATCH+24],eax
movsx eax,word [eax+UNIT_OWNER]
cmp dword [eax*4+PLAYER_IDS],-1
jne u_found
mov eax,[SCRATCH+24]
u_next_unit:
movsx eax,word [eax+UNIT_NEXT]
jmp u_chain
u_next_tile:
add edx,2
dec ecx
jne u_column
add edi,12
dec dword [SCRATCH+20]
jne u_row
xor eax,eax
jmp u_out
u_found:
mov eax,1
u_out:
pop edx
pop ecx
pop ebp
pop edi
pop esi
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

---What the panel list shows for an overlay (12 characters fit): "large_gatehouse_left" -> "LG left".
local function shortLabel(name)
  local words = {}
  for word in tostring(name):gmatch("[^_%s]+") do
    words[#words + 1] = word
  end
  local label = table.concat(words, " ")
  if #label > 12 and #words > 1 then
    local initials = {}
    for index = 1, #words - 1 do
      initials[#initials + 1] = words[index]:sub(1, 1):upper()
    end
    label = table.concat(initials) .. " " .. words[#words]
  end
  return label:sub(1, 12)
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
  local spots, games = {}, {}
  if ok and type(result) == "table" then
    for _, entry in ipairs(result) do
      if type(entry) == "table" and entry.game ~= nil then
        games[#games + 1] = entry
      elseif type(entry) == "table" and entry.name ~= nil then
        spots[entry.name] = entry
      end
    end
  end
  return spots, games
end

---------------------------------------------------------------------------------------
-- The game's own overlay pictures
---------------------------------------------------------------------------------------

-- Every picture renderGmOverlayBuilding (and its second half for some towers) draws goes
-- through a `call` to one of four picture routines. Each of those calls gets a thunk of its own
-- that adds that picture's offset (a pseudo record: R_X / R_Y, its name, R_SEEN) to the x / y
-- it passes, and stamps the record when it draws for the selected building, so the panel can
-- list the pictures a building really uses. When and whether a picture is drawn stays the
-- game's own business. The calls are numbered in code order ("Game #n"); that number is what
-- the saved files use, and it is the same in both executables.
local F1_AOB = "83 EC 18 8B 4C 24 28 53 55 8B 6C 24 24 69 ED 2C 03 00 00"   -- renderGmOverlayBuilding
local F2_AOB = "51 8B 4C 24 08 53 55 56 8B F1 69 F6 2C 03 00 00 0F BF 86"   -- its second half
local F1_ENTRY = [[
push eax
mov eax,[esp+12]
mov [ANCHOR_X],eax
mov eax,[esp+8]
mov [CURRENT],eax
mov dword [GATED],0
pop eax
sub esp,0x18
mov ecx,[esp+0x28]
jmp RESUME
]]
local F2_ENTRY = [[
push eax
mov eax,[esp+12]
mov [ANCHOR_X],eax
mov eax,[esp+8]
mov [CURRENT],eax
mov dword [GATED],0
pop eax
push ecx
mov ecx,[esp+8]
jmp RESUME
]]
local R_SEEN = R_TYPE                    -- a pseudo record has no type: the frame it was drawn in
local RENDER_GM_BLEND, RENDER_GM_ALPHA, RENDER_GM_ANIMATION_CALL = 0x90, 0x4B0, 0x7F
local RENDER_GM_FIRST_FRAMES, RENDER_GM_WIDTHS = 0x0C, 0x43   -- operands inside renderGM
local RENDER_GM_OFFSETS = 0x24          -- mov edx, [eax*4 + image offsets]
local FIRST_TOWER, LAST_TOWER = 74, 78   -- lookout tower .. round tower
-- Keeps (41..44) and gate buildings (45..49) and the towers lose their game overlay pictures in
-- the V view, where the game lowers the buildings.
local CASTLE_FIRST, CASTLE_LAST = 41, 49
-- The game's own pictures drawn tile by tile: keeps from the manor house on, gate buildings and
-- towers. Their cuts (strips per picture and phase) are made the first time they are drawn.
local STRIP_FIRST, MAX_IMAGES = 40, 32768
local B_ROOF = 0x60                      -- a tower's roof picture
local STUB_SIZE, INFO_SIZE = 10, 0x20    -- push info / jmp COMMON; info per call
local I_TARGET, I_XO, I_YO, I_RECORDS, I_PLAIN = 0, 4, 8, 0xC, 0x10

-- Every hooked call: `push info / jmp COMMON`. COMMON finds the record for this call and the
-- building's type (each building type has its own offsets), stamps it when the selected
-- building is drawn, adds the offset to x / y, and in "only while the mouse is on it" mode
-- decides a tower's roof (hidden only under the mouse) and crenellations (hidden when the
-- game's troop check said so, GATED). A roof hidden under the mouse still flips the game's
-- marker pixel when the mouse is inside it, so the game keeps seeing the tower under the
-- mouse and the roof does not flicker. Then it jumps to the real picture routine.
local SITE_COMMON = [[
push eax
push edx
push ecx
mov ecx,[esp+12]
mov eax,[CURRENT]
imul eax,eax,BUILDING_SIZE
add eax,BUILDINGS
movzx edx,word [eax+BTYPE]
cmp edx,TYPE_COUNT
jae s_go
push eax
imul edx,edx,RECORD_SIZE
add edx,[ecx+I_RECORDS]
mov eax,[CURRENT]
cmp eax,[SELECTED]
jne s_unseen
mov eax,[PANEL_FRAME]
mov [edx+R_SEEN],eax
s_unseen:
push ebx
mov ebx,[edx+R_X]
mov eax,[ecx+I_XO]
add [esp+eax],ebx
mov ebx,[edx+R_Y]
mov eax,[ecx+I_YO]
add [esp+eax],ebx
pop ebx
cmp dword [V_VIEW],0
jne s_normal_view
cmp dword [ecx+I_PLAIN],0
je s_normal_view
mov eax,[esp]
movzx eax,word [eax+BTYPE]
cmp eax,CASTLE_FIRST
jb s_normal_view
cmp eax,CASTLE_LAST
jbe s_skip
cmp eax,FIRST_TOWER
jb s_normal_view
cmp eax,LAST_TOWER
jbe s_skip
s_normal_view:
mov eax,HOVER_ONLY
test eax,eax
je s_draw
cmp dword [ecx+I_PLAIN],0
je s_draw
mov eax,[esp]
movzx edx,word [eax+BTYPE]
cmp edx,FIRST_TOWER
jb s_draw
cmp edx,LAST_TOWER
ja s_draw
mov eax,[CURRENT]
cmp eax,MAX_BUILDINGS
jae s_wall
mov eax,[ROOF_CACHE+eax*4]
test eax,eax
je s_wall
cmp eax,[esp+0x1C]
jne s_wall
mov eax,[CURRENT]
cmp eax,[LAST_HOVER]
je s_roof_hidden
mov edx,[VIEWPORT]
test edx,edx
je s_draw
cmp eax,[edx+VP_HOVER]
je s_roof_hidden
jmp s_draw
s_wall:
cmp dword [GATED],0
jne s_skip
s_draw:
mov eax,TILE_STRIPS
test eax,eax
je s_whole
cmp dword [ecx+I_PLAIN],0
je s_whole
mov eax,[esp]
movzx eax,word [eax+BTYPE]
cmp eax,STRIP_FIRST
jb s_whole
cmp eax,CASTLE_LAST
jbe s_strip
cmp eax,FIRST_TOWER
jb s_whole
cmp eax,LAST_TOWER
ja s_whole
s_strip:
mov eax,[esp+0x18]
mov eax,[FIRST_FRAMES+eax*4]
add eax,[esp+0x1C]
dec eax
cmp eax,MAX_IMAGES
jae s_whole
mov [CUT_IMAGE],eax
mov edx,[ANCHOR_X]
sub edx,[esp+0x20]
and edx,15
mov [CUT_PHASE],edx
shl eax,4
add eax,edx
mov edx,[CUTS+eax*4]
test edx,edx
jne s_have_cut
push eax
call LUA_CUT
pop eax
mov edx,[CUTS+eax*4]
s_have_cut:
cmp edx,-1
je s_whole
test edx,edx
je s_whole
mov eax,[esp+0x20]
mov [SX],eax
mov eax,[esp+0x24]
mov [SY],eax
mov eax,[CURRENT]
mov [SCRATCH+16],eax
mov ecx,edx
call REMEMBER_AT
jmp s_skip
s_whole:
add esp,4
s_go:
mov eax,[ecx+I_TARGET]
mov [esp+12],eax
pop ecx
pop edx
pop eax
ret
s_roof_hidden:
mov eax,[VIEWPORT]
test eax,eax
je s_skip
push ebx
push esi
push edi
mov esi,[esp+0x24]
mov esi,[FIRST_FRAMES+esi*4]
add esi,[esp+0x28]
dec esi
shl esi,4
movsx ebx,word [WIDTHS+esi]
movsx esi,word [WIDTHS+esi+2]
mov edi,[eax+VP_MOUSE_X]
add edi,[MOUSE_X]
mov edx,[eax+VP_MOUSE_Y]
add edx,[MOUSE_Y]
mov eax,[esp+0x2C]
mov ecx,[esp+0x30]
cmp dword [ZOOMED_OUT],0
je s_full
sar eax,1
sar ecx,1
shr ebx,1
shr esi,1
s_full:
sub edi,eax
sub edx,ecx
cmp edi,ebx
jae s_outside
cmp edx,esi
jae s_outside
mov eax,[VIEWPORT]
mov eax,[eax+0x74]
xor word [eax],0x5A5A
s_outside:
pop edi
pop esi
pop ebx
s_skip:
add esp,4
pop ecx
pop edx
pop eax
add esp,4
ret 0x10
]]

-- A tower's roof picture number: while troops are on the tower (hasUnitsOntop, +0x2F8) the game
-- sets it to 0, or for the lookout tower to an open top, which is how the roof goes away. So in
-- "only while the mouse is on it" mode the reads of it in the overlay drawing go through
-- ROOF_READ, which remembers the roof of the empty tower per building and hands that back while
-- troops are up there. COMMON then hides it only under the mouse.
local B_ON_TOP = 0x2F8
local MAX_BUILDINGS = 10000
local ROOF_READ = [[
mov eax,[ebp+ROOF_FIELD]
push edx
movzx edx,word [ebp+TYPE_FIELD]
cmp edx,FIRST_TOWER
jb r_done
cmp edx,LAST_TOWER
ja r_done
mov edx,[CURRENT]
cmp edx,MAX_BUILDINGS
jae r_done
cmp word [ebp+ON_TOP_FIELD],0
jne r_cached
test eax,eax
je r_cached
mov [ROOF_CACHE+edx*4],eax
jmp r_done
r_cached:
cmp dword [ROOF_CACHE+edx*4],0
je r_done
mov eax,[ROOF_CACHE+edx*4]
r_done:
pop edx
ret
]]

local sites = {}                         -- { records (type 0), number }

local function bytesOf(value)
  value = value & 0xFFFFFFFF
  return value & 0xFF, (value >> 8) & 0xFF, (value >> 16) & 0xFF, (value >> 24) & 0xFF
end

---A cdecl function with no arguments that runs `callback` in lua (UCP's own detour trick).
local function luaFunction(purpose, callback)
  local pad = core.allocateCode({ 0x90, 0x90, 0x90, 0x90, 0x90, 0xC3 })
  core.detourCode(function(registers)
    local ok, message = pcall(callback)
    if not ok then
      log(WARNING, string.format("%s: %s failed: %s", MODULE_NAME, purpose, tostring(message)))
    end
    return registers
  end, pad, 5)
  return pad
end

---The game's code section (from the PE header in memory).
local function textSection()
  local base = 0x400000
  local nt = base + core.readInteger(base + 0x3C)
  local sections = core.readSmallInteger(nt + 6) & 0xFFFF
  local first = nt + 0x18 + (core.readSmallInteger(nt + 0x14) & 0xFFFF)
  for index = 0, sections - 1 do
    local header = first + index * 0x28
    local name = ""
    for k = 0, 7 do
      local c = core.readByte(header + k) & 0xFF
      if c == 0 then break end
      name = name .. string.char(c)
    end
    if name == ".text" then
      local start = base + core.readInteger(header + 0x0C)
      return start, start + core.readInteger(header + 0x08)
    end
  end
  return 0x401000, 0x5A0000
end

local function installSites(tail, renderGm, values)
  local f1 = scan(F1_AOB, "the building overlay drawing")
  local f2 = scan(F2_AOB, "the building overlay drawing (towers)")
  local f2End = f2
  while f2End < f1 do
    local a, b = core.readByte(f2End) & 0xFF, core.readByte(f2End + 1) & 0xFF
    if (a == 0x90 and b == 0x90) or (a == 0xCC and b == 0xCC) then
      break
    end
    f2End = f2End + 1
  end
  -- target -> offsets of x and y on COMMON's stack while it adjusts them (five dwords pushed
  -- above the return address), and whether a skipped call has to clean 0x10 bytes (renderGM)
  local targets = {
    [renderGm] = { 0x24, 0x28, 1 },
    [renderGm + RENDER_GM_BLEND] = { 0x24, 0x28, 0 },
    [renderGm + RENDER_GM_ALPHA] = { 0x24, 0x28, 0 },
    [readCallTarget(renderGm, RENDER_GM_ANIMATION_CALL, "the animation drawing")] = { 0x1C, 0x20, 0 },
  }
  -- Another module may already have redirected some of these calls (interface-visual-fixes
  -- does five): a call that lands outside the game's code, right after `mov ecx, <texture
  -- core>`, is such a picture call. It is hooked as well (on top of the other module's code),
  -- so the numbering is the same whatever else is installed.
  local textStart, textEnd = textSection()
  local found = {}
  for _, range in ipairs({ { f2, f2End }, { f1, tail } }) do
    local address = range[1]
    while address <= range[2] - 5 do
      if (core.readByte(address) & 0xFF) == 0xE8 then
        local target = (address + 5 + core.readInteger(address + 1)) & 0xFFFFFFFF
        local kind = targets[target]
        if kind == nil and (target < textStart or target >= textEnd)
            and (core.readByte(address - 5) & 0xFF) == 0xB9
            and (core.readInteger(address - 4) & 0xFFFFFFFF) == values.RENDER_CORE then
          kind = { 0x24, 0x28, 0 }
        end
        if kind ~= nil then
          found[#found + 1] = { address = address, target = target, kind = kind }
          address = address + 4
        end
      end
      address = address + 1
    end
  end
  values.CURRENT = core.allocate(4, true)
  values.PANEL_FRAME = core.allocate(4, true)
  core.writeInteger(values.PANEL_FRAME, 100)       -- so the zero stamps all count as old
  values.SITE_STRIDE = TYPE_COUNT * RECORD_SIZE
  values.SITES = core.allocate(math.max(#found, 1) * values.SITE_STRIDE, true)
  values.SITE_COUNT = #found
  values.FIRST_FRAMES = core.readInteger(renderGm + RENDER_GM_FIRST_FRAMES)
  values.WIDTHS = core.readInteger(renderGm + RENDER_GM_WIDTHS)
  values.FIRST_TOWER, values.LAST_TOWER, values.B_ROOF = FIRST_TOWER, LAST_TOWER, B_ROOF
  values.CASTLE_FIRST, values.CASTLE_LAST = CASTLE_FIRST, CASTLE_LAST
  values.STRIP_FIRST, values.MAX_IMAGES = STRIP_FIRST, MAX_IMAGES
  values.ANCHOR_X = core.allocate(4, true)
  values.CUT_IMAGE, values.CUT_PHASE = core.allocate(4, true), core.allocate(4, true)
  values.GM_OFFSETS = core.readInteger(renderGm + RENDER_GM_OFFSETS)
  if values.TILE_STRIPS == 1 then
    values.CUTS = core.allocate(MAX_IMAGES * 16 * 4, true)
    values.LUA_CUT = luaFunction("cutting a game picture", function()
      local image, phase = core.readInteger(values.CUT_IMAGE), core.readInteger(values.CUT_PHASE)
      local cut = strips.cutGame(values, image, phase, store)
      if cut == 0 then
        cut = -1     -- not cuttable: drawn whole from now on (the asm tests for 0 only)
      end
      core.writeInteger(values.CUTS + (image * 16 + phase) * 4, cut)
    end)
  else
    values.CUTS, values.LUA_CUT, values.SX, values.SY, values.REMEMBER_AT = 0, 0, 0, 0, 0
  end
  values.I_TARGET, values.I_XO, values.I_YO, values.I_RECORDS, values.I_PLAIN =
    I_TARGET, I_XO, I_YO, I_RECORDS, I_PLAIN
  values.TYPE_COUNT, values.R_SEEN = TYPE_COUNT, R_SEEN
  values.MAX_BUILDINGS = MAX_BUILDINGS
  values.ROOF_CACHE = core.allocate(MAX_BUILDINGS * 4, true)
  local common = assemble(SITE_COMMON, values)
  local infos = core.allocate(math.max(#found, 1) * INFO_SIZE, true)
  local filler = {}
  for index = 1, math.max(#found, 1) * STUB_SIZE do
    filler[index] = 0xCC
  end
  local stubs = core.allocateCode(filler)
  for number, call in ipairs(found) do
    local records = values.SITES + (number - 1) * values.SITE_STRIDE
    local info = infos + (number - 1) * INFO_SIZE
    local stub = stubs + (number - 1) * STUB_SIZE
    local name = storeString(string.format("Game #%d", number))
    for kind = 0, TYPE_COUNT - 1 do
      core.writeInteger(records + kind * RECORD_SIZE + R_NAME, name)
    end
    core.writeInteger(info + I_TARGET, call.target)
    core.writeInteger(info + I_XO, call.kind[1])
    core.writeInteger(info + I_YO, call.kind[2])
    core.writeInteger(info + I_RECORDS, records)
    core.writeInteger(info + I_PLAIN, call.kind[3])
    local code = { 0x68 }
    for _, byte in ipairs({ bytesOf(info) }) do code[#code + 1] = byte end
    code[#code + 1] = 0xE9
    for _, byte in ipairs({ bytesOf(common - (stub + STUB_SIZE)) }) do code[#code + 1] = byte end
    core.writeCode(stub, code)
    core.writeCode(call.address + 1, { bytesOf(stub - (call.address + 5)) })
    sites[number] = { records = records, number = number }
  end
  for _, entry in ipairs({ { f1, F1_ENTRY, 7 }, { f2, F2_ENTRY, 5 } }) do
    local hook = core.allocateAssembly(entry[2], { CURRENT = values.CURRENT, GATED = values.GATED,
      ANCHOR_X = values.ANCHOR_X,
      RESUME = entry[1] + entry[3] })
    local code = { 0xE9, bytesOf(hook - (entry[1] + 5)) }
    for _ = 6, entry[3] do
      code[#code + 1] = 0x90
    end
    core.writeCode(entry[1], code)
  end
  log(INFO, string.format("%s: %d of the game's own overlay pictures can be moved", MODULE_NAME, #found))
  if values.HOVER_ONLY == 1 then
    local roofField = (values.BUILDINGS + B_ROOF) & 0xFFFFFFFF
    local reader = assemble(ROOF_READ, {
      ROOF_FIELD = roofField, TYPE_FIELD = (values.BUILDINGS + B_TYPE) & 0xFFFFFFFF,
      ON_TOP_FIELD = (values.BUILDINGS + B_ON_TOP) & 0xFFFFFFFF,
      FIRST_TOWER = FIRST_TOWER, LAST_TOWER = LAST_TOWER, CURRENT = values.CURRENT,
      MAX_BUILDINGS = MAX_BUILDINGS, ROOF_CACHE = values.ROOF_CACHE,
    })
    local reads = 0
    for address = f1, tail - 6 do
      if (core.readByte(address) & 0xFF) == 0x8B and (core.readByte(address + 1) & 0xFF) == 0x85
          and (core.readInteger(address + 2) & 0xFFFFFFFF) == roofField then
        local code = { 0xE8, bytesOf(reader - (address + 5)) }
        code[#code + 1] = 0x90
        core.writeCode(address, code)
        reads = reads + 1
      end
    end
    log(INFO, string.format("%s: tower roofs stay while troops are on them (%d reads)", MODULE_NAME, reads))
  end
end

---A saved offset for one of the game's own pictures: { game = n, building = type, x, y }.
local function applyGameEntry(entry)
  local site = sites[tonumber(entry.game) or 0]
  local kind = tonumber(entry.building)
  if site == nil or kind == nil or kind < 0 or kind >= TYPE_COUNT then
    log(WARNING, string.format("%s: no game overlay #%s for building %s", MODULE_NAME,
      tostring(entry.game), tostring(entry.building)))
    return
  end
  local record = site.records + kind * RECORD_SIZE
  core.writeInteger(record + R_X, tonumber(entry.x) or 0)
  core.writeInteger(record + R_Y, tonumber(entry.y) or 0)
end

---------------------------------------------------------------------------------------
-- The overlay table
---------------------------------------------------------------------------------------

local state            -- everything the running hook uses; nil until enable has hooked
local overlays = {}    -- every overlay in the table, in record order
local pending = {}     -- plugin folders registered before enable finished
local firstSource      -- the first plugin folder: the game pictures' offsets are saved there

---Adds one overlay (an entry of overlay_list.lua or of a plugin's overlays.lua) to the table
---the hook walks. `folder` is where its picture lives.
local function addOverlay(entry, folder, swap, source)
  local existing
  for _, overlay in ipairs(overlays) do
    if overlay.name == tostring(entry.name) then
      existing = overlay
    end
  end
  if existing == nil and #overlays >= MAX_OVERLAYS then
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
    x = entry.x or 0, y = entry.y or 0, source = source,
  }
  local record
  if existing ~= nil then
    -- An overlay of the same name (a plugin's version of one of ours) takes over its record.
    for index, other in ipairs(overlays) do
      if other == existing then
        overlays[index] = overlay
      end
    end
    record = existing.record
    log(INFO, string.format("%s: %s now comes from %s", MODULE_NAME, overlay.name, folder))
  else
    overlays[#overlays + 1] = overlay
    record = state.records + (#overlays - 1) * RECORD_SIZE
  end
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
  core.writeInteger(record + R_NAME, storeString(entry.label or shortLabel(overlay.name)))
  overlay.picture_ = picture
  strips.cut(record, picture, overlay.x, packTgx, store)
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
  -- Spots saved while the plugin folder could not be written win over the plugin's own file.
  local spare = "ucp/building-overlays-" .. (folder:match("plugins/([^/]+)/") or "module") .. ".lua"
  local text = readFile("", spare)
  if text ~= nil then
    log(INFO, MODULE_NAME .. ": using the spots saved in " .. spare)
  else
    text = readFile(folder, "overlays.lua")
  end
  local chunk = text and load(text, "overlays", "t", {})
  local ok, entries = pcall(chunk or function() end)
  if not ok or type(entries) ~= "table" then
    log(WARNING, MODULE_NAME .. ": no readable overlays.lua in " .. folder)
    return
  end
  firstSource = firstSource or folder
  for _, entry in ipairs(entries) do
    if type(entry) == "table" and entry.game ~= nil then
      applyGameEntry(entry)
    else
      addOverlay(entry, folder, false, folder)
    end
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

local function writeEntries(path, header, entries)
  local lines = { header, "return {" }
  for _, overlay in ipairs(entries) do
    if overlay.game ~= nil then
      lines[#lines + 1] = string.format("  { game = %d, building = %d, x = %d, y = %d },",
        overlay.game, overlay.building, overlay.x, overlay.y)
    else
      lines[#lines + 1] = formatEntry(overlay)
    end
  end
  lines[#lines + 1] = "}"
  local ok, file = pcall(io.open, path, "wb")
  if ok and file ~= nil then
    file:write(table.concat(lines, "\n"), "\n")
    file:close()
    log(INFO, MODULE_NAME .. ": saved " .. path)
    return true
  end
  -- UCP refuses to write inside extension folders: write next to the ucp folder instead, then
  -- try to move the file into place. If that fails too the copy in ucp/ is kept (and read back
  -- by registerOverlaySource), and the log says where it is.
  local spare = "ucp/building-overlays-" .. (path:match("plugins/([^/]+)/") or "module") .. ".lua"
  local opened, handle = pcall(io.open, spare, "wb")
  if not opened or handle == nil then
    log(WARNING, MODULE_NAME .. ": could not write " .. path .. " nor " .. spare
      .. "; the entries are above")
    return false
  end
  handle:write(table.concat(lines, "\n"), "\n")
  handle:close()
  pcall(os.remove, path)
  local moved = select(2, pcall(os.rename, spare, path))
  if moved then
    log(INFO, MODULE_NAME .. ": saved " .. path)
  else
    log(WARNING, MODULE_NAME .. ": UCP does not allow writing " .. path .. "; saved to " .. spare
      .. " instead - copy it over the plugin's overlays.lua")
  end
  return true
end

---The Save button: a plugin's overlays go back into that plugin's own overlays.lua, the module's
---own ones into calibration.lua in the module folder (which wins over overlay_list.lua).
local function writeCalibration()
  local bySource, sources, own = {}, {}, {}
  for _, overlay in ipairs(overlays) do
    overlay.x = core.readInteger(overlay.record + R_X)
    overlay.y = core.readInteger(overlay.record + R_Y)
    log(INFO, formatEntry(overlay))
    if overlay.source ~= nil then
      if bySource[overlay.source] == nil then
        bySource[overlay.source] = {}
        sources[#sources + 1] = overlay.source
      end
      table.insert(bySource[overlay.source], overlay)
    else
      own[#own + 1] = overlay
    end
  end
  -- The game's own pictures that were moved go with the first plugin's overlays (or the module's).
  local games = {}
  for _, site in ipairs(sites) do
    for kind = 0, TYPE_COUNT - 1 do
      local record = site.records + kind * RECORD_SIZE
      local x, y = core.readInteger(record + R_X), core.readInteger(record + R_Y)
      if x ~= 0 or y ~= 0 then
        games[#games + 1] = { game = site.number, building = kind, x = x, y = y }
      end
    end
  end
  if #games > 0 then
    local target = firstSource
    if target ~= nil and bySource[target] == nil then
      bySource[target] = {}
      sources[#sources + 1] = target
    end
    for _, game in ipairs(games) do
      table.insert(target and bySource[target] or own, game)
    end
  end
  local saved = true
  for _, source in ipairs(sources) do
    saved = writeEntries(source .. "overlays.lua", "-- Building Overlays: written by the Save button.",
      bySource[source]) and saved
  end
  if #own > 0 then
    saved = writeEntries(MODULE_FOLDERS[1] .. "calibration.lua",
      "-- Written by Building Overlays (the Save button). A plugin uses the same format as its\n"
      .. "-- resources/modsupport/building-overlays/overlays.lua, next to the PNGs it names.", own) and saved
  end
  return saved
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
    for _, overlay in ipairs(overlays) do
      if overlay.record == record and dx ~= 0 then
        strips.cut(record, overlay.picture_, core.readInteger(record + R_X), packTgx, store)
      end
    end
    core.writeInteger(record + R_Y, core.readInteger(record + R_Y) + dy)
  elseif kind == 3 then
    core.writeInteger(ui.STEP_INDEX, (core.readInteger(ui.STEP_INDEX) + 1) % #STEPS)
  end
  -- Every move is saved at once (and Save saves again), so nothing is lost on quitting; the
  -- label says whether the last write worked.
  if kind == 2 or kind == 4 then
    local ok, saved = pcall(writeCalibration)
    if not ok then
      log(WARNING, MODULE_NAME .. ": saving failed: " .. tostring(saved))
    end
    core.writeInteger(ui.SAVE_LABEL, (ok and saved) and ui.SAVED_TEXT or ui.FAILED_TEXT)
  end
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
    ROW_PLACES = core.allocate(MAX_ROWS * 8, true),
    ARROW_RECTS = core.allocate(4 * 16, true),
    ARROW_BASE = core.allocate(4 * 16, true),
    ORIGIN = core.allocate(8, true),
    ARROW_PICTURES = core.allocate(4 * 8, true),
    STEP_TEXTS = core.allocate(#STEPS * 4, true),
    SAVE_LABEL = core.allocate(4, true),
    SAVED_TEXT = storeString("Saved"),
    FAILED_TEXT = storeString("Save failed - see ucp3.log"),
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
  core.writeInteger(ui.SAVE_LABEL, storeString("Save"))
  ui.NO_OVERLAY_TEXTS = core.allocate(TYPE_COUNT * 4, true)
  for kind = 0, TYPE_COUNT - 1 do
    core.writeInteger(ui.NO_OVERLAY_TEXTS + kind * 4,
      storeString(string.format("No overlays yet (building %d)", kind)))
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
  w.BUILDING_SIZE, w.MAX_ROWS, w.TYPE_COUNT = BUILDING_SIZE, MAX_ROWS, TYPE_COUNT
  w.COLUMN_W, w.ROW_H, w.R_SEEN = COLUMN_W, ROW_H, R_SEEN
  for row = 0, MAX_ROWS - 1 do
    core.writeInteger(ui.ROW_PLACES + row * 8, LIST_X + (row // ROWS_PER_COLUMN) * (COLUMN_W + 2))
    core.writeInteger(ui.ROW_PLACES + row * 8 + 4, LIST_Y + (row % ROWS_PER_COLUMN) * ROW_H)
  end
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
-- The game's own tower and keep overlays, in "only while the mouse is on it" mode
---------------------------------------------------------------------------------------

---Every `cmp dword [reg + building +0xB0], edx` (39 /r, 6 bytes) or `cmp dword [reg + that], 0`
---(83 /7 ib, 7 bytes) in the two overlay functions becomes a call that sets the flags as
---"empty" unless the mouse is on that building. Returns how many were changed.
local function patchVanillaOverlays(tail, values)
  local field = (values.BUILDINGS + B_OCCUPIED) & 0xFFFFFFFF
  local count = 0
  local address = tail - VANILLA_SEARCH
  while address < tail do
    local opcode = core.readByte(address) & 0xFF
    local modrm = core.readByte(address + 1) & 0xFF
    local size
    if opcode == 0x39 and (modrm & 0xC0) == 0x80 then
      size = 6
    elseif opcode == 0x83 and (modrm & 0xF8) == 0xB8 and (core.readByte(address + 6) & 0xFF) == 0 then
      size = 7
    end
    local register = size and REGISTERS[modrm & 7]
    if register ~= nil and (core.readInteger(address + 2) & 0xFFFFFFFF) == field then
      local bytes = {}
      for offset = 0, size - 1 do
        bytes[#bytes + 1] = string.format("0x%02X", core.readByte(address + offset) & 0xFF)
      end
      local script = VANILLA_THUNK:gsub("REG", register)
      script = script:gsub("ORIGINAL", "db " .. table.concat(bytes, ","))
      local thunk = core.allocateAssembly(script, {
        TYPE_FIELD = (values.BUILDINGS + B_TYPE) & 0xFFFFFFFF, GATED = values.GATED,
        FIRST_TOWER = FIRST_TOWER, LAST_TOWER = LAST_TOWER,
      })
      local code = { 0xE8, core.itob(core.getRelativeAddress(address, thunk, -5)) }
      for _ = 6, size do
        code[#code + 1] = 0x90
      end
      core.writeCode(address, code)
      count = count + 1
      address = address + size
    else
      address = address + 1
    end
  end
  return count
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
  local unitsTest = scan(AOB_UNITS_ON_BUILDING, "the units-on-building test")
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
    HOVER_ONLY = setting(config, "mouse", "hover_only") and 1 or 0,
    LAST_HOVER = core.allocate(4, true), VIEWPORT = core.allocate(4, true),
    GATED = core.allocate(4, true), MOUSE_X = 0, MOUSE_Y = 0,
    V_VIEW = core.readInteger(scan(AOB_V_VIEW, "the V view flag") + V_VIEW_OBJECT) + V_VIEW_FIELD,
    VP_HOVER = VP_HOVER, VP_MOUSE_X = VP_MOUSE_X, VP_MOUSE_Y = VP_MOUSE_Y,
    ZOOMED_OUT = renderCore + 0x54,
    TRANSLATE = readOperand(unitsTest, UNITS_TRANSLATE, "the tile rows"),
    UNIT_TILES = readOperand(unitsTest, UNITS_TILES, "the units on the tiles"),
    UNIT_OWNER = readOperand(unitsTest, UNITS_OWNER, "the unit owner"),
    PLAYER_IDS = readOperand(unitsTest, UNITS_PLAYERS, "the players"),
    UNIT_SIZE = UNIT_SIZE, LORD = LORD, KEEP_FIRST = KEEP_FIRST, KEEP_LAST = KEEP_LAST, B_X = B_X, B_Y = B_Y, B_SIZE = B_SIZE, B_UID = B_UID,
    BUILDING_SIZE = BUILDING_SIZE,
    R_TYPE = R_TYPE, R_UNITS = R_UNITS, R_ENTRANCE = R_ENTRANCE, R_GATE = R_GATE, R_X = R_X,
    R_Y = R_Y, R_W = R_W, R_H = R_H, R_DATA565 = R_DATA565, R_DATA555 = R_DATA555,
    R_OUT565 = R_OUT565, R_OUT555 = R_OUT555, R_NAME = R_NAME,
  }
  local unitBase = values.UNIT_OWNER - U_OWNER
  values.UNIT_TYPE, values.UNIT_NEXT = unitBase + U_TYPE, unitBase + U_NEXT
  values.UNIT_PASSAGE = unitBase + U_PASSAGE
  local script = SCRIPT:gsub("%f[%w_]ORIGINAL%f[^%w_]", "db " .. table.concat(original, ","))
  values.UNITS_HERE = assemble(UNITS_SCRIPT, values)
  values.FRAME = core.allocate(4, true)
  local start = scan(AOB_FRAME_START, "the start of the map drawing")
  values.MOUSE_X = core.readInteger(start + FRAME_START_MOUSE_X)
  values.MOUSE_Y = core.readInteger(start + FRAME_START_MOUSE_Y)
  values.FRAME_RESUME = start + FRAME_START_HOOK + FRAME_START_SIZE
  local frameHook = assemble(FRAME_START_SCRIPT, values)
  core.writeCode(start + FRAME_START_HOOK,
    { 0xE9, core.itob(core.getRelativeAddress(start + FRAME_START_HOOK, frameHook, -5)), 0x90 })
  if values.HOVER_ONLY == 1 then
    values.HOVERED = assemble(HOVER_SCRIPT, values)
  else
    values.HOVERED = 0
  end
  values.TILE_STRIPS = 0
  values.REMEMBER = 0
  if setting(config, "drawing", "tile_by_tile") then
    local ok, problem = pcall(function()
      local piece = scan(strips.AOB_TILE_PIECE, "where the map draws a building piece")
      values.TILE_X = core.readInteger(piece + strips.TILE_X_OPERAND)
      values.TILE_RESUME = piece + strips.TILE_HOOK + strips.TILE_HOOK_SIZE
      values.CAM = core.allocate(8, true)
      values.SX, values.SY = core.allocate(4, true), core.allocate(4, true)
      values.OLD = core.allocate(4, true)
      values.PENDING = core.allocate(MAX_BUILDINGS * strips.SLOT_SIZE, true)
      values.MAX_BUILDINGS, values.SLOT_SIZE, values.ENTRY_SIZE = MAX_BUILDINGS, strips.SLOT_SIZE, strips.ENTRY_SIZE
      values.ENTRIES_SIZE, values.MAX_ENTRIES = strips.ENTRIES_SIZE, strips.MAX_ENTRIES
      values.R_STRIPS, values.R_STRIP_COUNT, values.R_PHASE = strips.R_STRIPS, strips.R_STRIP_COUNT, strips.R_PHASE
      values.CAMERA = assemble(strips.CAMERA_SCRIPT, values)
      values.DRAW_STRIP = assemble(strips.DRAW_STRIP_SCRIPT, values)
      values.REMEMBER_AT = assemble(strips.REMEMBER_AT_SCRIPT, values)
      values.REMEMBER = assemble(strips.REMEMBER_SCRIPT, values)
      local tileHook = assemble(strips.TILE_SCRIPT, values)
      core.writeCode(piece + strips.TILE_HOOK,
        { 0xE9, core.itob(core.getRelativeAddress(piece + strips.TILE_HOOK, tileHook, -5)) })
      values.TILE_STRIPS = 1
    end)
    if not ok then
      log(WARNING, MODULE_NAME .. ": overlays are drawn in one piece: " .. tostring(problem))
    end
  end
  local blob = assemble(script, values)

  -- The module's own list first; the count stays 0 until the first record is complete.
  local swap = setting(config, "large_gatehouse", "swap_sides")
  local calibrated, calibratedGames = loadCalibration()
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
  local sitesOk, sitesProblem = pcall(installSites, tail, renderGm, values)
  if not sitesOk then
    log(WARNING, MODULE_NAME .. ": the game's own overlays cannot be moved: " .. tostring(sitesProblem))
    values.SITES, values.SITE_COUNT = state.records, 0
    values.PANEL_FRAME = values.PANEL_FRAME or core.allocate(4, true)
  end
  for _, entry in ipairs(calibratedGames) do
    applyGameEntry(entry)
  end

  if values.HOVER_ONLY == 1 then
    log(INFO, string.format("%s: tower roofs hide only under the mouse, crenellations as the game says "
      .. "(%d checks changed)", MODULE_NAME, patchVanillaOverlays(tail, values)))
  end

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

-- Plugins only see what is listed as public.
return {
  enable = enable,
  disable = function(self, config) end,
  registerOverlaySource = registerOverlaySource,
}, {
  public = { "registerOverlaySource" },
}
