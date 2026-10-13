--[[
  Assembly for the overlay panel shown in the building panel (see init.lua). blit and
  drawButton are the ones smarter-recruits uses for its buttons.
]]

local templates = {}

-- blit(image, x, y), cdecl: copies a picture onto the screen through the game's pencil
-- (which clips it). image: +0 width, +4 height, +8 RGB565 pixels, +0xC RGB555 pixels,
-- +0x10 one alpha byte per pixel: 0 = see-through, 255 = opaque. Pixels in between are
-- mixed with the screen the way the game fades its sprites, with the game's own blend
-- tables (BLEND_TABLES, built by BUILD_BLEND the first time, as the game's sprite drawing
-- does): 33 levels of 0x200 bytes, level L scales a colour by L/32, entry 8 * channel value
-- at +0 blue, +2 green, +4 red, already in place. A pixel of level L (alpha / 8, rounded)
-- is table L of the picture's colour plus table 32 - L of the screen's.
-- SCRATCH +20: the level, +24: the picture's part, +44: green mask, +48: pixel format.
templates.blit = [[
push ebp
push ebx
push esi
push edi
cmp word [BLEND_READY],0
jne blend_ready
call BUILD_BLEND
blend_ready:
mov ecx,PENCIL
call SETUP_SURFACE
mov esi,[esp+0x14]
mov eax,[esp+0x18]
mov edx,[esp+0x1C]
mov ecx,[esi+4]
lea ecx,[edx+ecx-1]
mov ebx,[esi]
lea ebx,[eax+ebx-1]
push 0
push ecx
push ebx
push edx
push eax
mov ecx,PENCIL
call SETUP_PENCIL
test eax,eax
je finished
mov eax,[PENCIL+0x30]
mov edx,[PENCIL+0x38]
cmp eax,edx
jle x_sorted
xchg eax,edx
x_sorted:
mov [SCRATCH],eax
mov [SCRATCH+4],edx
mov eax,[PENCIL+0x34]
mov edx,[PENCIL+0x3C]
cmp eax,edx
jle y_sorted
xchg eax,edx
y_sorted:
mov [SCRATCH+8],eax
mov [SCRATCH+12],edx
mov ebp,[esi+8]
mov dword [SCRATCH+44],0x3F
mov dword [SCRATCH+48],0x565
cmp dword [PIXEL_FORMAT],0x565
je format_known
mov ebp,[esi+0xC]
mov dword [SCRATCH+44],0x1F
mov dword [SCRATCH+48],0x555
format_known:
mov ebx,[SCRATCH+8]
next_row:
cmp ebx,[SCRATCH+12]
jg finished
mov edi,ebx
imul edi,[PENCIL+8]
add edi,[PENCIL+4]
mov eax,ebx
sub eax,[esp+0x1C]
imul eax,[esi]
sub eax,[esp+0x18]
mov [SCRATCH+16],eax
mov ecx,[SCRATCH]
next_pixel:
cmp ecx,[SCRATCH+4]
jg row_done
mov eax,[SCRATCH+16]
add eax,ecx
mov edx,[esi+0x10]
movzx edx,byte [edx+eax]
test edx,edx
je skip_pixel
add edx,4
shr edx,3
test edx,edx
je skip_pixel
cmp edx,32
jae opaque
mov [SCRATCH+20],edx
movzx eax,word [ebp+eax*2]
push ebx
push esi
mov esi,edx
shl esi,9
add esi,BLEND_TABLES
call blend_lookup
mov [SCRATCH+24],eax
movzx eax,word [edi+ecx*2]
mov esi,32
sub esi,[SCRATCH+20]
shl esi,9
add esi,BLEND_TABLES
call blend_lookup
add eax,[SCRATCH+24]
mov [edi+ecx*2],ax
pop esi
pop ebx
jmp skip_pixel
opaque:
movzx edx,word [ebp+eax*2]
mov [edi+ecx*2],dx
skip_pixel:
inc ecx
jmp next_pixel
row_done:
inc ebx
jmp next_row
finished:
pop edi
pop esi
pop ebx
pop ebp
ret
blend_lookup:
mov ebx,eax
and ebx,0x1F
movzx edx,word [esi+ebx*8]
mov ebx,eax
shr ebx,5
and ebx,[SCRATCH+44]
or dx,word [esi+ebx*8+2]
mov ebx,eax
cmp dword [SCRATCH+48],0x565
je red_565
shr ebx,10
and ebx,0x1F
jmp red_known
red_565:
shr ebx,11
red_known:
or dx,word [esi+ebx*8+4]
movzx eax,dx
ret
]]

-- drawButton(rect, image, hoverImage), cdecl: draws the hover picture while the mouse is
-- over the rect (x, y, w, h), the normal one otherwise.
templates.drawButton = [[
push esi
mov esi,[esp+8]
push dword [esi+12]
push dword [esi+8]
push dword [esi+4]
push dword [esi]
mov ecx,MOUSE
call IS_INSIDE
mov ecx,[esp+0xC]
test eax,eax
je chosen
mov ecx,[esp+0x10]
chosen:
push dword [esi+4]
push dword [esi]
push ecx
call BLIT
add esp,12
pop esi
ret
]]

-- The building panel's work status line (a shared item, drawn for every building before the
-- panel's own items), cdecl, one parameter. Draws the line, then - for a selected building
-- without overlays a line naming its building type (to put in an overlays.lua), for one
-- with overlays - the list of its overlays (the picked one in yellow), "Save" and, once
-- an overlay is picked, the step size and the four arrow buttons. Remembers what it drew
-- for the click handler (ROWS, ROW_COUNT, SHOWN, PICKED_SHOWN).
templates.render = [[
mov eax,[BUTTON_X]
sub eax,STATUS_X
mov [ORIGIN],eax
mov eax,[BUTTON_Y]
sub eax,STATUS_Y
mov [ORIGIN+4],eax
push dword [esp+4]
call dword [ORIGINAL_RENDER]
add esp,4
push ebx
push esi
push edi
push ebp
inc dword [PANEL_FRAME]
mov dword [ROW_COUNT],0
mov byte [PICKED_SHOWN],0
mov eax,[SELECTED]
test eax,eax
jle r_done
imul eax,eax,BUILDING_SIZE
movzx ebp,word [eax+BUILDINGS+BTYPE]
mov esi,RECORDS
mov edi,[STATE]
xor ebx,ebx
r_next:
test edi,edi
je r_sites
cmp ebp,[esi+R_TYPE]
jne r_skip
call r_row
r_skip:
add esi,RECORD_SIZE
dec edi
jmp r_next
r_sites:
cmp ebp,TYPE_COUNT
jae r_list_done
mov esi,ebp
imul esi,esi,RECORD_SIZE
add esi,SITES
mov edi,SITE_COUNT
r_site:
test edi,edi
je r_list_done
mov eax,[esi+R_SEEN]
add eax,3
cmp eax,[PANEL_FRAME]
jb r_site_skip
call r_row
r_site_skip:
add esi,SITE_STRIDE
dec edi
jmp r_site
r_list_done:
mov [ROW_COUNT],ebx
test ebx,ebx
jne r_listed
cmp ebp,TYPE_COUNT
jae r_done
mov ecx,[ORIGIN+4]
add ecx,LIST_Y
mov edx,[ORIGIN]
add edx,LIST_X
push 0
push 0
push FONT
push 0
push COLOUR
push 0
push ecx
push edx
push dword [NO_OVERLAY_TEXTS+ebp*4]
mov ecx,TEXT_MANAGER
call SHADOWED_TEXT
jmp r_done
r_listed:
mov byte [SHOWN],1
mov ecx,[ORIGIN+4]
add ecx,SAVE_Y
mov edx,[ORIGIN]
add edx,SAVE_X
push 0
push 0
push FONT
push 0
push COLOUR
push 0
push ecx
push edx
push dword [SAVE_LABEL]
mov ecx,TEXT_MANAGER
call SHADOWED_TEXT
cmp byte [PICKED_SHOWN],0
je r_done
mov eax,[STEP_INDEX]
mov ecx,[ORIGIN+4]
add ecx,STEP_Y
mov edx,[ORIGIN]
add edx,STEP_X
push 0
push 0
push FONT
push 0
push COLOUR
push 0
push ecx
push edx
push dword [STEP_TEXTS+eax*4]
mov ecx,TEXT_MANAGER
call SHADOWED_TEXT
xor ebx,ebx
r_place:
mov eax,ebx
shl eax,4
mov ecx,[ARROW_BASE+eax]
add ecx,[ORIGIN]
mov [ARROW_RECTS+eax],ecx
mov ecx,[ARROW_BASE+eax+4]
add ecx,[ORIGIN+4]
mov [ARROW_RECTS+eax+4],ecx
inc ebx
cmp ebx,4
jb r_place
xor ebx,ebx
r_arrow:
mov eax,ebx
shl eax,3
push dword [ARROW_PICTURES+eax+4]
push dword [ARROW_PICTURES+eax]
mov eax,ebx
shl eax,4
add eax,ARROW_RECTS
push eax
call DRAW_BUTTON
add esp,12
inc ebx
cmp ebx,4
jb r_arrow
r_done:
mov eax,[SELECTED]
cmp eax,[DIAG]
jne r_report
mov eax,[ROW_COUNT]
cmp eax,[DIAG+4]
je r_quiet
r_report:
mov eax,[SELECTED]
mov [DIAG],eax
mov eax,[ROW_COUNT]
mov [DIAG+4],eax
call LUA_DIAG
r_quiet:
pop ebp
pop edi
pop esi
pop ebx
ret
r_row:
cmp ebx,MAX_ROWS
jae r_row_full
mov [ROWS+ebx*4],esi
mov eax,COLOUR
cmp dword [STATE+4],0
je r_row_colour
cmp esi,[STATE+8]
jne r_row_colour
mov eax,PICKED_COLOUR
mov byte [PICKED_SHOWN],1
r_row_colour:
mov ecx,[ROW_PLACES+ebx*8+4]
add ecx,[ORIGIN+4]
mov edx,[ROW_PLACES+ebx*8]
add edx,[ORIGIN]
push 0
push 0
push FONT
push 0
push eax
push 0
push ecx
push edx
push dword [esi+R_NAME]
mov ecx,TEXT_MANAGER
call SHADOWED_TEXT
inc ebx
r_row_full:
ret
]]

-- The building panel's first every-frame item (shared, runs before every other item), cdecl.
-- A left click on something the render above drew in the last frame is used up and handed to
-- lua (CLICK_KIND 1 a list row, CLICK_ARG its record; 2 an arrow, CLICK_ARG 0 up, 1 down,
-- 2 left, 3 right; 3 the step size; 4 Save). The game's own action always runs afterwards.
templates.click = [[
cmp byte [SHOWN],0
je c_pass
mov byte [SHOWN],0
cmp dword [MOUSE+LEFT_CLICK],0
je c_pass
push ebx
xor ebx,ebx
c_row:
cmp ebx,[ROW_COUNT]
jae c_save
mov eax,[ROW_PLACES+ebx*8+4]
add eax,[ORIGIN+4]
mov edx,[ROW_PLACES+ebx*8]
add edx,[ORIGIN]
push ROW_H
push COLUMN_W
push eax
push edx
mov ecx,MOUSE
call IS_INSIDE
test eax,eax
je c_row_next
mov dword [CLICK_KIND],1
mov eax,[ROWS+ebx*4]
mov [CLICK_ARG],eax
jmp c_hit
c_row_next:
inc ebx
jmp c_row
c_save:
mov eax,[ORIGIN+4]
add eax,SAVE_Y
mov edx,[ORIGIN]
add edx,SAVE_X
push LINE
push SAVE_W
push eax
push edx
mov ecx,MOUSE
call IS_INSIDE
test eax,eax
je c_step
mov dword [CLICK_KIND],4
jmp c_hit
c_step:
cmp byte [PICKED_SHOWN],0
je c_none
mov eax,[ORIGIN+4]
add eax,STEP_Y
mov edx,[ORIGIN]
add edx,STEP_X
push LINE
push STEP_W
push eax
push edx
mov ecx,MOUSE
call IS_INSIDE
test eax,eax
je c_arrows
mov dword [CLICK_KIND],3
jmp c_hit
c_arrows:
xor ebx,ebx
c_arrow:
mov eax,ebx
shl eax,4
push dword [ARROW_RECTS+eax+12]
push dword [ARROW_RECTS+eax+8]
push dword [ARROW_RECTS+eax+4]
push dword [ARROW_RECTS+eax]
mov ecx,MOUSE
call IS_INSIDE
test eax,eax
je c_arrow_next
mov dword [CLICK_KIND],2
mov [CLICK_ARG],ebx
jmp c_hit
c_arrow_next:
inc ebx
cmp ebx,4
jb c_arrow
c_none:
pop ebx
jmp c_pass
c_hit:
mov dword [MOUSE+LEFT_CLICK],0
call LUA_CLICK
pop ebx
c_pass:
jmp dword [ORIGINAL_FRAME]
]]

return templates
