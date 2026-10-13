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
-- so no rotation has to be worked out. Strips no piece drew this frame (picture wider than the
-- building) are drawn at the front corner, as before.
-- PENDING, per building: stamp[2], count[2], then two sets (by frame parity) of up to 4 entries
-- { record, map x, map y, drawn strips bitmap[3] }.
strips.SLOT_SIZE, strips.ENTRY_SIZE, strips.ENTRIES_SIZE, strips.MAX_ENTRIES = 0xD0, 24, 0x60, 4
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

-- ecx = record, ebx = strip, picture's top left on screen in [SX] / [SY]; keeps every register
strips.DRAW_STRIP_SCRIPT = [[
pushad
mov esi,[ecx+R_STRIPS]
mov eax,ebx
shl eax,4
add esi,eax
cmp dword [esi+12],0
je d_out
cmp dword [PIXEL_FORMAT],0x565
mov eax,[esi]
je d_ready
mov eax,[esi+4]
d_ready:
push eax
push dword [ecx+R_H]
push dword [esi+12]
push dword [SY]
mov eax,[SX]
add eax,[esi+8]
push eax
mov ecx,RENDER_CORE
mov eax,BLIT
call eax
d_out:
popad
ret
]]

-- At the front corner (renderGmOverlayBuilding's tail): ecx = record, edi / esi where the game
-- draws the building, [SCRATCH+16] its index. Draws the strips the pieces did not draw this frame
-- (all of them for a picture that was not shown last frame) and notes the picture for the
-- pieces of the next frame.
strips.REMEMBER_SCRIPT = [[
pushad
mov eax,edi
add eax,[ecx+R_X]
mov [SX],eax
mov eax,esi
add eax,[ecx+R_Y]
mov [SY],eax
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
xor ebx,ebx
m_left:
cmp ebx,[ecx+R_STRIP_COUNT]
jae m_store
bt dword [edx+12],ebx
jc m_next
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
m_done:
popad
ret
]]

-- Right after the game drew a piece of a building (esi = the building, ebx = the view, the
-- piece's x in TILE_X): every picture noted for this building last frame gets the two strips
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


return strips
