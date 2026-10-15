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
strips.SLOT_SIZE, strips.ENTRY_SIZE, strips.ENTRIES_SIZE, strips.MAX_ENTRIES = 0x790, 60, 0x3C0, 16
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
mov ebp,[esi+12]
test ebp,ebp
je d_out
mov edi,[ecx+R_H]
mov ebx,[SX]
add ebx,[esi+8]
mov edx,[SY]
mov eax,[esi]
cmp dword [DRAW_KIND],2
je d_ready
cmp dword [PIXEL_FORMAT],0x565
je d_ready
mov eax,[esi+4]
d_ready:
cmp dword [LOG_OFF],0
jne d_blit
mov ecx,[FRAME]
cmp [LOG_FRAME],ecx
je d_same
mov [LOG_FRAME],ecx
mov dword [LOG_COUNT],0
d_same:
mov ecx,[LOG_COUNT]
cmp ecx,LOG_MAX
jae d_blit
inc dword [LOG_COUNT]
imul ecx,ecx,LOG_ENTRY
add ecx,LOG
mov [ecx],ebx
mov [ecx+4],edx
mov [ecx+8],ebp
mov [ecx+12],edi
mov [ecx+16],eax
mov esi,[DRAW_KIND]
mov [ecx+20],esi
mov esi,[DRAW_ALPHA]
mov [ecx+24],esi
mov esi,[DRAW_OWNER]
mov [ecx+28],esi
mov esi,[DRAW_SPRITE]
mov [ecx+32],esi
mov esi,[LOG_B]
mov [ecx+36],esi
d_blit:
call BLIT_ONE
d_out:
popad
ret
]]

-- One picture piece: ebx = x, edx = y, ebp = width, edi = height, eax = the picture, drawn the
-- way DRAW_KIND / DRAW_ALPHA / DRAW_OWNER / DRAW_SPRITE say; keeps every register.
strips.BLIT_ONE_SCRIPT = [[
pushad
cmp dword [DRAW_KIND],2
je b_indexed
mov ecx,[DRAW_ALPHA]
test ecx,ecx
je b_plain
push ecx
push eax
push edi
push ebp
push edx
push ebx
mov ecx,RENDER_CORE
mov eax,TGX_FADED
call eax
jmp b_out
b_plain:
push eax
push edi
push ebp
push edx
push ebx
mov ecx,RENDER_CORE
mov eax,BLIT
call eax
jmp b_out
b_indexed:
push dword [OWNER_GLOBAL]
push dword [SPRITE_GLOBAL]
mov ecx,[DRAW_OWNER]
mov [OWNER_GLOBAL],ecx
mov ecx,[DRAW_SPRITE]
mov [SPRITE_GLOBAL],ecx
mov ecx,[DRAW_ALPHA]
test ecx,ecx
je b_indexed_plain
push ecx
push eax
push edi
push ebp
push edx
push ebx
mov ecx,RENDER_CORE
mov eax,INDEXED_FADED
call eax
jmp b_indexed_done
b_indexed_plain:
push eax
push edi
push ebp
push edx
push ebx
mov ecx,RENDER_CORE
mov eax,INDEXED
call eax
b_indexed_done:
pop dword [SPRITE_GLOBAL]
pop dword [OWNER_GLOBAL]
b_out:
popad
ret
]]

-- At the front corner (renderGmOverlayBuilding's tail): ecx = record, edi / esi where the game
-- draws the building, [SCRATCH+16] its index. Draws the strips that a piece covered last frame
-- but not this one (all of them for a picture that was not shown last frame) and notes the
-- picture for the pieces of the next frame, with the strips the pieces covered this frame.
-- Entry: { record, map x, map y, drawn by pieces this frame[3], covered by pieces the frame
-- before[3], frame its overhang was drawn, kind, alpha, owner colour, sprite, key }. The key
-- (KEY) finds last frame's entry: the record for this module's pictures, the call's info for the
-- game's, so an animation that moved on to its next picture still counts as the same one.
strips.REMEMBER_SCRIPT = [[
mov [KEY],ecx
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
mov [LOG_B],ebp
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
mov eax,[KEY]
m_find:
test ebx,ebx
je m_all
cmp [edx+56],eax
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
mov eax,[KEY]
mov [edx+56],eax
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
mov [LOG_B],esi
mov ecx,MARK_UNITS
test ecx,ecx
je t_marked
mov ecx,[FRAME]
cmp [MARKED+esi*4],ecx
je t_marked
mov [MARKED+esi*4],ecx
push ebx
mov [MARK_B],esi
mov ebx,esi
imul ebx,ebx,BUILDING_SIZE
add ebx,BUILDINGS
call MARK_UNITS
pop ebx
t_marked:
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
mov [KEY],ecx
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

-- "Is a mangonel or tower ballista standing on this tower?" (ebx = the building) -> eax 1 / 0.
-- Walks the footprint and every unit on each tile like UNITS_HERE.
strips.SIEGE_SCRIPT = [[
push esi
push edi
push ebp
push ecx
push edx
xor eax,eax
mov esi,[ebx+B_SIZE]
test esi,esi
jle g_out
mov [SIEGE_SCRATCH],esi
movsx ebp,word [ebx+B_X]
movsx edi,word [ebx+B_Y]
lea edi,[edi+edi*2]
lea edi,[edi*4+TRANSLATE]
g_row:
mov edx,[edi]
add edx,ebp
lea edx,[edx*2+UNIT_TILES]
mov ecx,esi
g_column:
movsx eax,word [edx]
mov dword [SIEGE_SCRATCH+4],64
g_chain:
test eax,eax
je g_next_tile
dec dword [SIEGE_SCRATCH+4]
je g_next_tile
imul eax,eax,UNIT_SIZE
cmp word [eax+UNIT_TYPE],MANGONEL
je g_found
cmp word [eax+UNIT_TYPE],TOWER_BALLISTA
je g_found
movsx eax,word [eax+UNIT_NEXT]
jmp g_chain
g_next_tile:
add edx,2
dec ecx
jne g_column
add edi,12
dec dword [SIEGE_SCRATCH]
jne g_row
xor eax,eax
jmp g_out
g_found:
mov eax,1
g_out:
pop edx
pop ecx
pop ebp
pop edi
pop esi
ret
]]

-- Units, arrows and the like behind overlays: the game queues what stands on a tile while it
-- draws that tile's row but draws it a few rows later (renderUnits, five row buckets), after the
-- pieces in front of it - and so after the overlay strips that go with those pieces. A unit on a
-- tower or gatehouse, or one walking behind it, comes out over its roof and crenellations.
-- Every strip drawn is written to a log (LOG, this frame), and QUEUE_SCRIPT notes for every
-- queued entry where the log stood at that moment. NOTE_SCRIPT, where renderUnits starts on an
-- entry, works out its rectangle and whether strips are to go over it: those logged after it was
-- queued, and for a unit standing on a building (MARK_SCRIPT, at the building's first piece) all
-- of that building's strips. If so it keeps a copy of the pixels there. REDRAW_SCRIPT, when the
-- entry is drawn, draws those strips again (clipped to its rows) and then puts back the old
-- pixels wherever the entry itself drew nothing - so the strips land on the unit only, the mask
-- being the unit's own pixels.
-- With "hide units under roofs" (HIDE_UNITS) a unit standing on a building whose roof was drawn
-- this frame or the last (ROOF_SHOWN) is not drawn at all - except one walking the passage.
strips.MARK_SCRIPT = [[
push esi
push edi
push ebp
push ecx
push edx
push eax
mov esi,[ebx+B_SIZE]
test esi,esi
jle k_out
mov [MARK_SCRATCH],esi
movsx ebp,word [ebx+B_X]
movsx edi,word [ebx+B_Y]
lea edi,[edi+edi*2]
lea edi,[edi*4+TRANSLATE]
k_row:
mov edx,[edi]
add edx,ebp
lea edx,[edx*2+UNIT_TILES]
mov ecx,esi
k_column:
movsx eax,word [edx]
mov dword [MARK_SCRATCH+4],64
k_chain:
test eax,eax
jle k_next_tile
dec dword [MARK_SCRATCH+4]
je k_next_tile
cmp eax,MAX_UNITS
jae k_next_tile
push edx
mov edx,[FRAME]
mov [UNIT_STAMP+eax*4],edx
mov edx,[MARK_B]
mov [UNIT_BUILDING+eax*4],edx
pop edx
imul eax,eax,UNIT_SIZE
movsx eax,word [eax+UNIT_NEXT]
jmp k_chain
k_next_tile:
add edx,2
dec ecx
jne k_column
add edi,12
dec dword [MARK_SCRATCH]
jne k_row
k_out:
pop eax
pop edx
pop ecx
pop ebp
pop edi
pop esi
ret
]]

-- In the game's queue (eax = the bucket 1..5, ecx = the render state): note where the log stands.
strips.QUEUE_SCRIPT = [[
push edx
push eax
lea edx,[eax-1]
cmp edx,4
ja q_done
mov eax,[ecx+BUCKET_COUNTS+edx*4]
cmp eax,BUCKET_ROOM
jae q_done
shl edx,9
add edx,eax
xor eax,eax
push ecx
mov ecx,[FRAME]
cmp [LOG_FRAME],ecx
pop ecx
jne q_store
mov eax,[LOG_COUNT]
q_store:
mov [QUEUED_AT+edx*4],eax
q_done:
pop eax
pop edx
add eax,-1
cmp eax,4
jmp QUEUE_RESUME
]]

-- COVER_DRAW 0: are there strips to go over [UX, UX2) x [UY, UY2)? (COVER_HIT) 1: draw them.
-- The strips of building N_B noted last frame, then the log from Q_FROM on (except N_B's).
strips.COVER_SCRIPT = [[
pushad
mov dword [COVER_HIT],0
mov esi,[N_B]
cmp esi,MAX_BUILDINGS
jae c_log
mov ebp,esi
imul ebp,ebp,SLOT_SIZE
add ebp,PENDING
mov edx,[FRAME]
dec edx
mov eax,edx
and eax,1
cmp [ebp+eax*4],edx
jne c_log
mov ebx,[VIEWPORT]
test ebx,ebx
je c_log
call CAMERA
mov edi,[ebp+8+eax*4]
imul eax,eax,ENTRIES_SIZE
lea edx,[ebp+0x10+eax]
c_entry:
test edi,edi
je c_log
mov ecx,[edx]
mov eax,[edx+4]
sub eax,[CAM]
mov [SX],eax
mov eax,[edx+8]
sub eax,[CAM+4]
mov [SY],eax
cmp eax,[UY2]
jge c_next_entry
add eax,[ecx+R_H]
cmp eax,[UY]
jle c_next_entry
mov eax,[edx+40]
mov [DRAW_KIND],eax
mov eax,[edx+44]
mov [DRAW_ALPHA],eax
mov eax,[edx+48]
mov [DRAW_OWNER],eax
mov eax,[edx+52]
mov [DRAW_SPRITE],eax
mov eax,[UX2]
dec eax
sub eax,[SX]
sub eax,[ecx+R_PHASE]
sar eax,4
inc eax
mov [ZJ_END],eax
mov eax,[UX]
sub eax,[SX]
sub eax,[ecx+R_PHASE]
sar eax,4
inc eax
test eax,eax
jge c_first
xor eax,eax
c_first:
mov ebx,eax
c_strip:
cmp ebx,[ZJ_END]
jg c_next_entry
cmp ebx,[ecx+R_STRIP_COUNT]
jae c_next_entry
mov dword [COVER_HIT],1
cmp dword [COVER_DRAW],0
je c_done
call DRAW_STRIP
inc ebx
jmp c_strip
c_next_entry:
add edx,ENTRY_SIZE
dec edi
jmp c_entry
c_log:
mov eax,[FRAME]
cmp [LOG_FRAME],eax
jne c_done
mov ecx,[Q_FROM]
c_log_next:
cmp ecx,[LOG_COUNT]
jae c_done
mov edx,ecx
imul edx,edx,LOG_ENTRY
add edx,LOG
mov eax,[edx+36]
cmp eax,[N_B]
je c_log_skip
mov eax,[edx]
cmp eax,[UX2]
jge c_log_skip
add eax,[edx+8]
cmp eax,[UX]
jle c_log_skip
mov eax,[edx+4]
cmp eax,[UY2]
jge c_log_skip
add eax,[edx+12]
cmp eax,[UY]
jle c_log_skip
mov dword [COVER_HIT],1
cmp dword [COVER_DRAW],0
je c_done
push ecx
mov eax,[edx+20]
mov [DRAW_KIND],eax
mov eax,[edx+24]
mov [DRAW_ALPHA],eax
mov eax,[edx+28]
mov [DRAW_OWNER],eax
mov eax,[edx+32]
mov [DRAW_SPRITE],eax
mov ebx,[edx]
mov ebp,[edx+8]
mov edi,[edx+12]
mov eax,[edx+16]
mov edx,[edx+4]
call BLIT_ONE
pop ecx
c_log_skip:
inc ecx
jmp c_log_next
c_done:
popad
mov eax,[COVER_HIT]
ret
]]

-- Where renderUnits starts on an entry (ebp = x, edi = y; [esp+0x18] = the unit, -1 / 0 = a
-- picture: set ecx / eax, frame esi; for a unit [esp+0x10] / [esp+0x14] = width / height;
-- [esp+0x28] = the render state, [esp+0x2C] = the entry's place in its bucket).
-- Zoomed out the blitter halves draw coordinates, so [DY0, DY1) stays in draw rows for the
-- game's clip while [RX0, RX1) x [RY0, RY1) is in surface pixels, inside the 4056 x 2076 surface.
strips.NOTE_SCRIPT = [[
pushad
mov dword [ACTIVE],0
mov dword [N_B],-1
mov eax,[esp+0x38]
cmp eax,0
jle n_picture
mov ecx,[esp+0x30]
mov edx,[esp+0x34]
cmp eax,MAX_UNITS
jae n_rect
mov esi,[FRAME]
cmp [UNIT_STAMP+eax*4],esi
jne n_rect
mov esi,[UNIT_BUILDING+eax*4]
mov [N_B],esi
mov edi,HIDE_UNITS
test edi,edi
je n_rect
cmp esi,MAX_BUILDINGS
jae n_rect
mov edi,[FRAME]
dec edi
cmp [ROOF_SHOWN+esi*4],edi
jl n_rect
imul edi,eax,UNIT_SIZE
cmp byte [edi+UNIT_PASSAGE],0
jne n_rect
popad
jmp UNIT_SKIP
n_picture:
mov ecx,[esp+0x18]
test eax,eax
jne n_set
mov ecx,[esp+0x1C]
n_set:
cmp ecx,GM_LIMIT
jae n_out
mov esi,[esp+4]
cmp esi,1
jl n_out
cmp esi,0x4000
jg n_out
mov eax,[FIRST_FRAMES+ecx*4]
lea eax,[eax+esi-1]
shl eax,4
movsx ecx,word [WIDTHS+eax]
movsx edx,word [WIDTHS+eax+2]
n_rect:
cmp ecx,0
jle n_out
cmp ecx,MAX_SIDE
jg n_out
cmp edx,0
jle n_out
cmp edx,MAX_SIDE
jg n_out
mov eax,[esp+8]
mov [UX],eax
add eax,ecx
mov [UX2],eax
mov eax,[esp]
mov [UY],eax
add eax,edx
mov [UY2],eax
mov dword [Q_FROM],0x7FFFFFFF
mov eax,[esp+0x48]
mov ecx,[eax+BUCKET]
dec ecx
cmp ecx,4
ja n_queued
mov eax,[esp+0x4C]
cmp eax,BUCKET_ROOM
jae n_queued
shl ecx,9
add ecx,eax
mov eax,[QUEUED_AT+ecx*4]
mov [Q_FROM],eax
n_queued:
call COVER
test eax,eax
je n_out
mov eax,[UY]
cmp eax,[CLIP_TOP]
jge n_top
mov eax,[CLIP_TOP]
n_top:
test eax,eax
jge n_top_ok
xor eax,eax
n_top_ok:
mov [DY0],eax
mov eax,[UY2]
cmp eax,[CLIP_BOTTOM]
jle n_bottom
mov eax,[CLIP_BOTTOM]
n_bottom:
mov [DY1],eax
cmp eax,[DY0]
jle n_out
xor ecx,ecx
cmp dword [ZOOMED_OUT],0
setne cl
mov eax,[DY0]
sar eax,cl
mov [RY0],eax
mov eax,[DY1]
add eax,ecx
sar eax,cl
cmp eax,SURFACE_H
jle n_rows
mov eax,SURFACE_H
n_rows:
mov [RY1],eax
cmp eax,[RY0]
jle n_out
mov eax,[UX]
sub eax,16
sar eax,cl
jge n_left
xor eax,eax
n_left:
mov [RX0],eax
mov eax,[UX2]
add eax,16
add eax,ecx
sar eax,cl
cmp eax,SURFACE_W
jle n_right
mov eax,SURFACE_W
n_right:
mov [RX1],eax
cmp eax,[RX0]
jle n_out
mov edi,SNAP
call KEEP
mov dword [ACTIVE],1
n_out:
popad
cmp dword [esp+0x18],-1
jne UNIT_PATH
jmp PICTURE_PATH
]]

-- Copies the screen's [RX0, RX1) x [RY0, RY1) to edi.
strips.KEEP_SCRIPT = [[
pushad
mov esi,[RY0]
imul esi,esi,PITCH
mov eax,[RX0]
lea esi,[esi+eax*2]
add esi,[SURFACE_PTR]
mov ebx,[RY1]
sub ebx,[RY0]
mov edx,[RX1]
sub edx,eax
k_row:
push esi
mov ecx,edx
k_pixel:
mov ax,[esi]
mov [edi],ax
add esi,2
add edi,2
dec ecx
jne k_pixel
pop esi
add esi,PITCH
dec ebx
jne k_row
popad
ret
]]

-- Where renderUnits is done with an entry.
strips.REDRAW_SCRIPT = [[
pushad
cmp dword [ACTIVE],0
je z_out
mov dword [ACTIVE],0
mov edi,AFTER
call KEEP
push dword [CLIP_TOP]
push dword [CLIP_BOTTOM]
mov eax,[DY0]
mov [CLIP_TOP],eax
mov eax,[DY1]
mov [CLIP_BOTTOM],eax
mov dword [LOG_OFF],1
mov dword [COVER_DRAW],1
call COVER
mov dword [COVER_DRAW],0
mov dword [LOG_OFF],0
pop dword [CLIP_BOTTOM]
pop dword [CLIP_TOP]
mov edi,[RY0]
imul edi,edi,PITCH
mov eax,[RX0]
lea edi,[edi+eax*2]
add edi,[SURFACE_PTR]
mov esi,SNAP
mov ebx,AFTER
mov ebp,[RY1]
sub ebp,[RY0]
mov edx,[RX1]
sub edx,eax
z_row:
push edi
mov ecx,edx
z_pixel:
mov ax,[ebx]
cmp ax,[esi]
jne z_unit
mov [edi],ax
z_unit:
add esi,2
add ebx,2
add edi,2
dec ecx
jne z_pixel
pop edi
add edi,PITCH
dec ebp
jne z_row
z_out:
popad
mov eax,[esp+0x2C]
add eax,1
jmp REDRAW_RESUME
]]

strips.LOG_MAX, strips.LOG_ENTRY = 16384, 40   -- the strips drawn in a frame
strips.MAX_SIDE, strips.PITCH = 256, 0x1FB0     -- largest unit picture handled; map surface row
strips.SURFACE_H = 2076                          -- map surface rows (the game creates it 4056 x 2076)
strips.MAX_UNITS = 10000

strips.ROOF_READ = [[
mov eax,[ebp+ROOF_FIELD]
push edx
movzx edx,word [ebp+TYPE_FIELD]
cmp edx,FIRST_TOWER
jb r_done
cmp edx,LAST_TOWER
ja r_done
mov [ROOF_TYPE],edx
mov edx,[CURRENT]
cmp edx,MAX_BUILDINGS
jae r_done
push ebx
push eax
lea ebx,[ebp+BUILDINGS]
call SIEGE_HERE
test eax,eax
pop eax
pop ebx
jne r_none
cmp word [ebp+ON_TOP_FIELD],0
jne r_cached
test eax,eax
je r_cached
mov [ROOF_CACHE+edx*4],eax
jmp r_done
r_cached:
cmp dword [ROOF_CACHE+edx*4],0
je r_default
mov eax,[ROOF_CACHE+edx*4]
jmp r_done
r_default:
mov edx,[ROOF_TYPE]
cmp dword [ROOF_DEFAULTS+edx*4],0
je r_done
mov eax,[ROOF_DEFAULTS+edx*4]
jmp r_done
r_none:
xor eax,eax
r_done:
pop edx
ret
]]

strips.VANILLA_THUNK = [[
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

strips.F1_ENTRY = [[
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

strips.F2_ENTRY = [[
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

strips.HOVER_SCRIPT = [[
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

strips.FRAME_START_SCRIPT = [[
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

return strips
