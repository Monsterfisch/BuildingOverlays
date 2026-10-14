--[[
  Building Overlays: drawing this module's pictures tile by tile (used by init.lua).
]]

local strips = {}

strips.R_STRIPS, strips.R_STRIP_COUNT, strips.R_PHASE = 0x34, 0x38, 0x3C

-- The game draws a building one piece per footprint tile, back to front, so whatever stands in
-- front of a tile covers it. Its overlays are drawn in one go at the building's front corner -
-- the last of its tiles - so they lie over neighbours that were drawn before that corner but
-- stand in front of the building (an overlay "showing through" the tower next to it).
-- Here this module's pictures are cut into strips one tile column (16 px) wide and every strip
-- is drawn right after each piece of the building that covers its column, the game's own order:
-- the last of those pieces is the front one, so the strip ends up over the building and under
-- anything in front of it. Positions come from the building's front corner in the frame before,
-- kept in camera-free map units (screen + 32 * view column, screen + 16 * view row - row bias),
-- so no rotation has to be worked out. Strips no piece covers (the picture hangs over the sides
-- of the footprint) are drawn with the building's back-most piece, the first one drawn, so
-- neighbours drawn after it cover them too.
-- PENDING, per building: stamp[2], count[2], then two sets (by frame parity) of up to 16 entries
-- (see REMEMBER_SCRIPT).
-- A picture is drawn the way the game would have drawn it (DRAW_KIND / DRAW_ALPHA, and for the
-- game's colour-indexed pictures the owner colour and sprite the game had set): kind 0 a 16 bit
-- TGX picture (faded with DRAW_ALPHA 1..31), kind 2 a colour-indexed one.
strips.SLOT_SIZE, strips.ENTRY_SIZE, strips.ENTRIES_SIZE, strips.MAX_ENTRIES = 0x710, 56, 0x380, 16
strips.AOB_TILE_PIECE = "03 05 ? ? ? ? 52 8B 15 ? ? ? ? 2B 15 ? ? ? ? 2B D1 03 15 ? ? ? ? B9 ? ? ? ? "
  .. "52 50 E8 ? ? ? ? 83 7C 24 24 00"
strips.TILE_X_OPERAND, strips.TILE_HOOK, strips.TILE_HOOK_SIZE = 2, 0x27, 5

-- ebx = the view -> [CAM] = 32 * view column, [CAM+4] = 16 * view row - row bias
strips.CAMERA_SCRIPT = [[
push eax
push edx
xor edx,edx
cmp dword [ebx+0x94],0
je c_bias
mov edx,0x40
cmp dword [ebx+0x90],0
je c_bias
mov edx,0x80
c_bias:
mov eax,[ebx+0x78]
sar eax,5
shl eax,5
mov [CAM],eax
mov eax,[ebx+0x7C]
add eax,edx
sar eax,4
shl eax,4
sub eax,edx
mov [CAM+4],eax
pop edx
pop eax
ret
]]

-- ecx = record, ebx = strip, picture's top left on screen in [SX] / [SY], how to draw it in
-- DRAW_KIND / DRAW_ALPHA / DRAW_OWNER / DRAW_SPRITE; keeps every register
strips.DRAW_STRIP_SCRIPT = [[
pushad
mov esi,[ecx+R_STRIPS]
mov eax,ebx
shl eax,4
add esi,eax
cmp dword [esi+12],0
je d_out
mov edi,[ecx+R_H]
mov ebx,[SX]
add ebx,[esi+8]
cmp dword [DRAW_KIND],2
je d_indexed
cmp dword [PIXEL_FORMAT],0x565
mov eax,[esi]
je d_ready
mov eax,[esi+4]
d_ready:
mov edx,[DRAW_ALPHA]
test edx,edx
je d_plain
push edx
push eax
push edi
push dword [esi+12]
push dword [SY]
push ebx
mov ecx,RENDER_CORE
mov eax,TGX_FADED
call eax
jmp d_out
d_plain:
push eax
push edi
push dword [esi+12]
push dword [SY]
push ebx
mov ecx,RENDER_CORE
mov eax,BLIT
call eax
jmp d_out
d_indexed:
push dword [OWNER_GLOBAL]
push dword [SPRITE_GLOBAL]
mov eax,[DRAW_OWNER]
mov [OWNER_GLOBAL],eax
mov eax,[DRAW_SPRITE]
mov [SPRITE_GLOBAL],eax
mov eax,[esi]
mov edx,[DRAW_ALPHA]
test edx,edx
je d_indexed_plain
push edx
push eax
push edi
push dword [esi+12]
push dword [SY]
push ebx
mov ecx,RENDER_CORE
mov eax,INDEXED_FADED
call eax
jmp d_indexed_done
d_indexed_plain:
push eax
push edi
push dword [esi+12]
push dword [SY]
push ebx
mov ecx,RENDER_CORE
mov eax,INDEXED
call eax
d_indexed_done:
pop dword [SPRITE_GLOBAL]
pop dword [OWNER_GLOBAL]
d_out:
popad
ret
]]

-- At the front corner (renderGmOverlayBuilding's tail): ecx = record, edi / esi where the game
-- draws the building, [SCRATCH+16] its index. Draws the strips that a piece covered last frame
-- but not this one (all of them for a picture that was not shown last frame) and notes the
-- picture for the pieces of the next frame, with the strips the pieces covered this frame.
-- Entry: { record, map x, map y, drawn by pieces this frame[3], covered by pieces the frame
-- before[3], frame its overhang was drawn, kind, alpha, owner colour, sprite }.
strips.REMEMBER_SCRIPT = [[
mov dword [DRAW_KIND],0
mov dword [DRAW_ALPHA],0
push eax
mov eax,edi
add eax,[ecx+R_X]
mov [SX],eax
mov eax,esi
add eax,[ecx+R_Y]
mov [SY],eax
pop eax
jmp REMEMBER_AT
]]

-- The same with the picture's place on screen already in [SX] / [SY] and the way to draw it in
-- DRAW_* (the game's own pictures, ecx = their cut, which is laid out like a record: R_H,
-- R_STRIPS, R_STRIP_COUNT, R_PHASE).
strips.REMEMBER_AT_SCRIPT = [[
pushad
mov dword [OLD],0
mov ebp,[SCRATCH+16]
cmp ebp,MAX_BUILDINGS
jae m_all
mov ebx,[VIEWPORT]
test ebx,ebx
je m_all
call CAMERA
imul ebp,ebp,SLOT_SIZE
add ebp,PENDING
mov edx,[FRAME]
dec edx
mov eax,edx
and eax,1
cmp [ebp+eax*4],edx
jne m_all
mov ebx,[ebp+8+eax*4]
imul eax,eax,ENTRIES_SIZE
lea edx,[ebp+0x10+eax]
m_find:
test ebx,ebx
je m_all
cmp [edx],ecx
je m_found
add edx,ENTRY_SIZE
dec ebx
jmp m_find
m_found:
mov [OLD],edx
xor ebx,ebx
m_left:
cmp ebx,[ecx+R_STRIP_COUNT]
jae m_store
bt dword [edx+12],ebx
jc m_next
bt dword [edx+24],ebx
jnc m_next
call DRAW_STRIP
m_next:
inc ebx
jmp m_left
m_all:
xor ebx,ebx
m_all_next:
cmp ebx,[ecx+R_STRIP_COUNT]
jae m_store
call DRAW_STRIP
inc ebx
jmp m_all_next
m_store:
mov ebp,[SCRATCH+16]
cmp ebp,MAX_BUILDINGS
jae m_done
cmp dword [VIEWPORT],0
je m_done
imul ebp,ebp,SLOT_SIZE
add ebp,PENDING
mov eax,[FRAME]
mov edx,eax
and edx,1
cmp [ebp+edx*4],eax
je m_append
mov [ebp+edx*4],eax
mov dword [ebp+8+edx*4],0
m_append:
mov ebx,[ebp+8+edx*4]
cmp ebx,MAX_ENTRIES
jae m_done
inc dword [ebp+8+edx*4]
imul edx,edx,ENTRIES_SIZE
lea edx,[ebp+0x10+edx]
imul ebx,ebx,ENTRY_SIZE
add edx,ebx
mov [edx],ecx
mov eax,[SX]
add eax,[CAM]
mov [edx+4],eax
mov eax,[SY]
add eax,[CAM+4]
mov [edx+8],eax
mov dword [edx+12],0
mov dword [edx+16],0
mov dword [edx+20],0
mov dword [edx+24],0
mov dword [edx+28],0
mov dword [edx+32],0
mov dword [edx+36],0
mov eax,[DRAW_KIND]
mov [edx+40],eax
mov eax,[DRAW_ALPHA]
mov [edx+44],eax
mov eax,[DRAW_OWNER]
mov [edx+48],eax
mov eax,[DRAW_SPRITE]
mov [edx+52],eax
mov eax,[OLD]
test eax,eax
je m_done
mov ebx,[eax+12]
mov [edx+24],ebx
mov ebx,[eax+16]
mov [edx+28],ebx
mov ebx,[eax+20]
mov [edx+32],ebx
m_done:
popad
ret
]]

-- Right after the game drew a piece of a building (esi = the building, ebx = the view, the
-- piece's x in TILE_X). At its first (back-most) piece of the frame a picture gets the strips no
-- piece covered last frame - the parts hanging over the footprint's sides - so nothing beside
-- the building that is drawn later is painted over. Then every picture noted for this building
-- last frame gets the two strips
-- that lie over this piece's 32 px.
strips.TILE_SCRIPT = [[
pushad
cmp dword [STATE],0
je t_out
cmp dword [V_VIEW],0
je t_out
cmp esi,MAX_BUILDINGS
jae t_out
mov ebp,esi
imul ebp,ebp,SLOT_SIZE
add ebp,PENDING
mov edx,[FRAME]
dec edx
mov eax,edx
and eax,1
cmp [ebp+eax*4],edx
jne t_out
call CAMERA
mov edi,[ebp+8+eax*4]
imul eax,eax,ENTRIES_SIZE
lea edx,[ebp+0x10+eax]
t_entry:
test edi,edi
je t_out
mov ecx,[edx]
mov eax,[edx+4]
sub eax,[CAM]
mov [SX],eax
mov eax,[edx+8]
sub eax,[CAM+4]
mov [SY],eax
mov eax,[edx+40]
mov [DRAW_KIND],eax
mov eax,[edx+44]
mov [DRAW_ALPHA],eax
mov eax,[edx+48]
mov [DRAW_OWNER],eax
mov eax,[edx+52]
mov [DRAW_SPRITE],eax
mov eax,[FRAME]
cmp [edx+36],eax
je t_pieces
mov [edx+36],eax
xor ebx,ebx
t_overhang:
cmp ebx,[ecx+R_STRIP_COUNT]
jae t_pieces
bt dword [edx+24],ebx
jc t_overhang_next
call DRAW_STRIP
t_overhang_next:
inc ebx
jmp t_overhang
t_pieces:
mov eax,[TILE_X]
sub eax,[SX]
sub eax,[ecx+R_PHASE]
sar eax,4
inc eax
mov ebx,eax
call t_one
inc ebx
call t_one
add edx,ENTRY_SIZE
dec edi
jmp t_entry
t_one:
cmp ebx,0
jl t_skip
cmp ebx,[ecx+R_STRIP_COUNT]
jae t_skip
bts dword [edx+12],ebx
call DRAW_STRIP
t_skip:
ret
t_out:
popad
cmp dword [esp+0x24],0
jmp TILE_RESUME
]]

---Cuts a picture into strips one tile column wide, where the tile columns fall for an overlay
---at x (see "Tile by tile"): strip j covers columns [phase + 16 (j - 1), phase + 16 j).
---Decodes one of the game's TGX pictures from memory into words (nil = see-through), w x h.
---size 2: 16 bit pixels, size 1: colour indices.
local function decodeGame(data, w, h, size)
  local read = size == 2 and function(a) return core.readSmallInteger(a) & 0xFFFF end
    or function(a) return core.readByte(a) & 0xFF end
  local words, row, column, at = {}, 0, 0, data
  local limit = w * h * 3 + h * 4 + 64
  while row < h and limit > 0 do
    limit = limit - 1
    local token = core.readByte(at) & 0xFF
    at = at + 1
    local n, kind = (token & 0x1F) + 1, token & 0xE0
    if kind == 0x00 then
      for _ = 1, n do
        if column < w then words[row * w + column + 1] = read(at) end
        at = at + size
        column = column + 1
      end
    elseif kind == 0x20 then
      column = column + n
    elseif kind == 0x40 then
      local word = read(at)
      at = at + size
      for _ = 1, n do
        if column < w then words[row * w + column + 1] = word end
        column = column + 1
      end
    else
      row = row + 1
      column = 0
    end
  end
  return words
end

---TGX for raw words (already in the screen's pixel format), as packTgx does for pixels.
local function packWords(w, h, words, from, width, size)
  local out = {}
  for y = 0, h - 1 do
    local x = 0
    while x < width do
      local solid = words[y * w + from + x + 1] ~= nil
      local n = 1
      while x + n < width and n < 32 and (words[y * w + from + x + n + 1] ~= nil) == solid do
        n = n + 1
      end
      if solid then
        out[#out + 1] = n - 1
        for k = 0, n - 1 do
          local word = words[y * w + from + x + k + 1]
          out[#out + 1] = word & 0xFF
          if size == 2 then
            out[#out + 1] = word >> 8
          end
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

---Cuts one of the game's pictures (image number `image`) into strips for the given phase and
---returns its cut, laid out like a record. v: GM_OFFSETS, RENDER_CORE, WIDTHS, RECORD_SIZE.
function strips.cutGame(v, image, phase, store, size)
  local data = (core.readInteger(v.GM_OFFSETS + image * 4) + core.readInteger(v.RENDER_CORE + 0x78))
    & 0xFFFFFFFF
  local w = core.readSmallInteger(v.WIDTHS + image * 16) & 0xFFFF
  local h = core.readSmallInteger(v.WIDTHS + image * 16 + 2) & 0xFFFF
  if data == 0 or w == 0 or h == 0 or w > 2048 or h > 2048 then
    return 0
  end
  local words = decodeGame(data, w, h, size)
  local count = (w - phase + 15) // 16 + 1
  local table_ = core.allocate(count * 16, true)
  for j = 0, count - 1 do
    local from = math.max(0, phase + 16 * (j - 1))
    local to = math.min(w, phase + 16 * j)
    if to > from then
      local strip = store(packWords(w, h, words, from, to - from, size))
      core.writeInteger(table_ + j * 16, strip)
      core.writeInteger(table_ + j * 16 + 4, strip)
      core.writeInteger(table_ + j * 16 + 8, from)
      core.writeInteger(table_ + j * 16 + 12, to - from)
    end
  end
  local cut = core.allocate(v.RECORD_SIZE, true)
  core.writeInteger(cut + v.R_H, h)
  core.writeInteger(cut + strips.R_STRIPS, table_)
  core.writeInteger(cut + strips.R_STRIP_COUNT, count)
  core.writeInteger(cut + strips.R_PHASE, phase)
  return cut
end

function strips.cut(record, picture, x, packTgx, store)
  local width, height, pixels = picture.width, picture.height, picture.pixels
  local phase = (-x) % 16
  local count = (width - phase + 15) // 16 + 1
  local table_ = core.allocate(count * 16, true)
  for j = 0, count - 1 do
    local from = math.max(0, phase + 16 * (j - 1))
    local to = math.min(width, phase + 16 * j)
    local entry = table_ + j * 16
    if to > from then
      local strip, w = {}, to - from
      for row = 0, height - 1 do
        for column = 0, w - 1 do
          strip[row * w + column + 1] = pixels[row * width + from + column + 1]
        end
      end
      core.writeInteger(entry, store(packTgx(w, height, strip, true)))
      core.writeInteger(entry + 4, store(packTgx(w, height, strip, false)))
      core.writeInteger(entry + 8, from)
      core.writeInteger(entry + 12, w)
    end
  end
  core.writeInteger(record + strips.R_STRIPS, table_)
  core.writeInteger(record + strips.R_PHASE, phase)
  core.writeInteger(record + strips.R_STRIP_COUNT, count)
end


-- The tile by tile path for one of the game's pictures (called from SITE_COMMON with the
-- building pushed: [esp+4]; ecx = the call's info, kept). Returns eax 0 = draw it the game's way,
-- 1 / 2 = it was handed to the strips (renderGM / its faded variant: the call is to be skipped).
strips.STRIP_GAME_SCRIPT = [[
mov eax,[ecx+I_PLAIN]
test eax,eax
je g_none
mov [CUT_CALL],eax
mov dword [DRAW_ALPHA],0
cmp eax,2
jne g_alpha_known
mov eax,[esp+0x2C]
cmp eax,0x20
jae g_none
mov [DRAW_ALPHA],eax
g_alpha_known:
mov eax,[esp+0x1C]
imul eax,eax,0x1458
mov eax,[eax+GM_TYPES]
cmp eax,2
je g_indexed
cmp eax,1
je g_true_colour
cmp eax,6
jne g_none
g_true_colour:
mov dword [DRAW_KIND],0
jmp g_strip
g_indexed:
mov dword [DRAW_KIND],2
mov eax,[OWNER_GLOBAL]
mov [DRAW_OWNER],eax
mov eax,[SPRITE_GLOBAL]
mov [DRAW_SPRITE],eax
g_strip:
mov eax,[esp+0x1C]
mov eax,[FIRST_FRAMES+eax*4]
add eax,[esp+0x20]
dec eax
cmp eax,MAX_IMAGES
jae g_none
mov [CUT_IMAGE],eax
mov edx,[ANCHOR_X]
sub edx,[esp+0x24]
and edx,15
mov [CUT_PHASE],edx
shl eax,4
add eax,edx
mov edx,[CUTS+eax*4]
test edx,edx
jne g_have_cut
push eax
call LUA_CUT
pop eax
mov edx,[CUTS+eax*4]
g_have_cut:
cmp edx,-1
je g_none
test edx,edx
je g_none
mov eax,[esp+0x24]
mov [SX],eax
mov eax,[esp+0x28]
mov [SY],eax
mov eax,[CURRENT]
mov [SCRATCH+16],eax
push ecx
mov ecx,edx
call REMEMBER_AT
pop ecx
mov eax,[CUT_CALL]
ret
g_none:
xor eax,eax
ret
]]

return strips
