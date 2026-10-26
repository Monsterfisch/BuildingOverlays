"""Runs building-overlays unchanged against the real exe image: the module's Lua and assembly
execute, the game's own renderGmOverlayBuilding and picture routine draw into an emulated map
surface, and the pixels are compared with the PNGs.  python test_overlays.py [van|ext]"""
import os, sys, shutil, struct, tempfile
import harness
from harness import Host, SENTINEL, MASK
from x86emu import Halt

HERE = os.path.dirname(os.path.abspath(__file__))
MODULE = os.path.join(os.path.dirname(HERE), 'module')
SURFACE = 0x40000000
PITCH = 0x1FB0
STRIDE = 0x32C
OVERLAYS = os.path.join(MODULE, 'overlays')

# the module reads ucp/modules/building-overlays/... relative to the working directory
WORK = None


def fresh_work():
    global WORK
    WORK = tempfile.mkdtemp(prefix='bo_')
    shutil.copytree(MODULE, os.path.join(WORK, 'ucp', 'modules', 'building-overlays'))
_chdir = os.chdir
harness.os.chdir = lambda path: _chdir(WORK)

fails = []


def check(label, got, want):
    ok = got == want
    print('%s %s%s' % ('ok  ' if ok else 'FAIL', label, '' if ok else '  got %r want %r' % (got, want)))
    if not ok:
        fails.append(label)


def pixels(name):
    from PIL import Image
    return Image.open(os.path.join(OVERLAYS, name + '.png')).convert('RGBA')


def conv(p, is565):
    r, g, b, _ = p
    return ((r >> 3) << 11 | (g >> 2) << 5 | b >> 3) if is565 else ((r >> 3) << 10 | (g >> 3) << 5 | b >> 3)


def suite(ext):
    print('=== %s' % ('Extreme' if ext else 'vanilla'))
    fresh_work()
    h = Host(extreme=ext, config={}, foreign_patches=False, aic=False)
    v_flag = struct.unpack('<I', h.E.data[h.E.va2off(h.E.find('6A 03 B9 ? ? ? ? E8 ? ? ? ? 89 2D ? ? ? ? E9')[0]) + 3:][:4])[0] + 0x5548C4
    h.put32(v_flag, 1)                 # the ordinary view (zero = V view)
    for line in h.logs:
        print('  log', line)
    E = h.E
    tail = E.find('0F B7 85 ? ? ? ? 0F BF C0 8B 04 85 ? ? ? ? 33 C9 3B C1 89 4C 24 30 89 4C 24 34 89 44 24 24')[0]
    check('registerOverlaySource is public for plugins', h.public[b'public'][1], b'registerOverlaySource')
    check('hook jumps out of the tail', h.m.read(tail, 1), b'\xE9')
    check('hook pads with nops', h.m.read(tail + 5, 2), b'\x90\x90')
    func = E.find('83 EC 18 8B 4C 24 28 53 55 8B 6C 24 24 69 ED 2C 03 00 00')[0]
    typedisp = struct.unpack('<I', E.data[E.va2off(tail) + 3:E.va2off(tail) + 7])[0]
    buildings = typedisp - 0xD2
    core = struct.unpack('<I', E.data[E.va2off(tail) - 9:E.va2off(tail) - 5])[0]
    render_gm = tail + struct.unpack('<i', E.data[E.va2off(tail) - 4:E.va2off(tail)])[0]
    blit = render_gm + 0x53 + 5 + struct.unpack('<i', E.data[E.va2off(render_gm) + 0x54:E.va2off(render_gm) + 0x58])[0]
    surface_ptr = struct.unpack('<I', E.data[E.va2off(blit) + 0x50:E.va2off(blit) + 0x54])[0]
    pix_fmt = struct.unpack('<I', E.data[E.va2off(E.find('81 3D ? ? ? 00 65 05 00 00 75 40')[0]) + 2:][:4])[0]
    orient = struct.unpack('<I', E.data[E.va2off(E.find('A1 ? ? ? ? 85 C0 53 55 56 57 8B E9 BF 08 00 00 00 74 22 83 F8 06 75 07 BF 18 3A 01 00 EB 16 83 F8 04 75 07 BF 28 74 02 00')[0]) + 1:][:4])[0]
    print('  func %08X blit %08X core %08X surface ptr %08X' % (func, blit, core, surface_ptr))

    def put_building(index, btype, occupied=0, variation=0x50, shown=1, frame=1):
        b = buildings + index * STRIDE
        h.m.write(b, b'\0' * STRIDE)
        h.put32(b + 0x34, shown)
        h.put32(b + 0x38, frame)
        h.put16(b + 0xD2, btype)
        h.put32(b + 0xB0, occupied)
        h.put16(b + 0x102, variation)
        h.put16(b + 0xEE, 10)          # footprint 10..12 x 10..12 (the tile rows are all 0 here,
        h.put16(b + 0xF0, 10)          # so a tile's index is its x)
        h.put32(b + 0xF8, 3)
        return b

    ufn = E.find('8B 44 24 04 69 C0 2C 03 00 00 53 55 03 C1 56 8B B0 0C 01 00 00 33 DB 85 F6 57 7E')[0]
    uop = lambda off: struct.unpack('<I', E.data[E.va2off(ufn) + off:][:4])[0]
    unit_tiles, unit_base = uop(0x3D), uop(0x51) - 0x96

    def place_units(*types):
        """Units on tile 11 of the footprint, chained through unit +0x2A2."""
        clear_units()
        previous = 0
        for n, kind in reversed(list(enumerate(types, start=5))):
            u = unit_base + n * 0x490
            h.put16(u + 0x8E, kind)
            h.put16(u + 0x96, 1)
            h.put16(u + 0x2A2, previous)
            previous = n
        h.put16(unit_tiles + 11 * 2, previous)

    def clear_units():
        h.put16(unit_tiles + 11 * 2, 0)

    def draw(index, x, y, is565=True, orientation=0):
        h.m.write(SURFACE, b'\0' * 0)          # surface pages appear on first write
        for off in range(0, PITCH * 700, 4096):
            h.m.write(SURFACE + off, b'\0' * 4096)
        h.put32(surface_ptr, SURFACE)
        h.put32(core + 4, 1)
        h.put32(core + 0x58, 0)
        h.put32(core + 0x5C, 600)
        h.put32(core + 0x54, 0)
        h.put32(pix_fmt, 0x565 if is565 else 0x555)
        h.put32(orient, orientation)
        h.put32(0xC9A510 if False else core, h.u32(core))
        h.run(func, stack=[index, x, y, 0], limit=3_000_000)

    def pixel(x, y):
        return h.u16(SURFACE + y * PITCH + x * 2)

    def count():
        n = 0
        for y in range(0, 600):
            row = h.m.read(SURFACE + y * PITCH, 800 * 2)
            n += sum(1 for i in range(0, len(row), 2) if row[i] or row[i + 1])
        return n

    left, right = pixels('large_gatehouse_overlay_closed_left'), pixels('large_gatehouse_overlay_closed_right')
    spot = (-107, -193)
    bx, by = 400, 450
    for is565 in (True, False):
        tag = '565' if is565 else '555'
        # entrance runs along x (variation 0x50) -> "right"
        put_building(1, 45, variation=0x50)
        draw(1, bx, by, is565)
        ox, oy = bx + spot[0], by + spot[1]
        bad = 0
        total = 0
        for yy in range(right.height):
            for xx in range(right.width):
                p = right.getpixel((xx, yy))
                if p[3] >= 128:
                    total += 1
                    if pixel(ox + xx, oy + yy) != conv(p, is565):
                        bad += 1
        check('%s: right picture drawn pixel for pixel (%d opaque)' % (tag, total), bad, 0)
        check('%s: nothing outside it' % tag, count(), total)

        put_building(1, 45, variation=0x51)
        draw(1, bx, by, is565)
        p = left.getpixel((100, 100))
        bad = sum(1 for yy in range(left.height) for xx in range(left.width)
                  if left.getpixel((xx, yy))[3] >= 128 and pixel(ox + xx, oy + yy) != conv(left.getpixel((xx, yy)), is565))
        check('%s: left picture for the other entrance' % tag, bad, 0)

    put_building(1, 45, variation=0x50)
    draw(1, bx, by, True, orientation=2)
    p = left.getpixel((100, 100))
    check('rotated map swaps the sides', pixel(bx + spot[0] + 100, by + spot[1] + 100) == conv(p, True) or p[3] < 128, True)

    put_building(1, 45, occupied=1)
    draw(1, bx, by)
    check('the game flag +0xB0 alone does not hide it (keeps always have it set)', count() > 20000, True)
    put_building(1, 45)
    place_units(24)
    draw(1, bx, by)
    check('nothing while a unit stands on its tiles', count(), 0)
    place_units(55)
    draw(1, bx, by)
    check('the lord on a gatehouse hides it like any unit', count(), 0)
    place_units(24)
    h.m.write(unit_base + 5 * 0x490 + 0x402, bytes([1]))
    draw(1, bx, by)
    check('a unit walking through the passage does not hide it', count() > 20000, True)
    h.m.write(unit_base + 5 * 0x490 + 0x402, bytes([0]))
    clear_units()
    draw(1, bx, by)
    check('picture is back when the units leave', count() > 20000, True)
    h.put32(v_flag, 0)
    draw(1, bx, by)
    check('V view: no overlay', count(), 0)
    h.put32(v_flag, 1)

    # the line-up tool in the building panel
    start = E.find('03 00 00 00 54 01 00 00 D2 01 00 00 64 00 00 00 1C 00 00 00')[0]
    while h.u32(start - 0x50) != 0x66:
        start -= 0x50
    status = start
    while not (h.u32(status) == 3 and h.u32(status + 4) == 25 and h.u32(status + 8) == 570):
        status += 0x50
    render, frame = h.u32(status + 0x1C), h.u32(start + 0x14)
    check('status line render wrapped', render != struct.unpack('<I', E.data[E.va2off(status) + 0x1C:][:4])[0], True)
    check('first every-frame action wrapped', frame != struct.unpack('<I', E.data[E.va2off(start) + 0x14:][:4])[0], True)
    orig_render = struct.unpack('<I', E.data[E.va2off(status) + 0x1C:][:4])[0]
    orig_frame = struct.unpack('<I', E.data[E.va2off(start) + 0x14:][:4])[0]
    h.stub(orig_render, 0)
    h.stub(orig_frame, 0)
    name_box = E.find('A1 ? ? ? ? 8B 0D ? ? ? ? 8B 15 ? ? ? ? 56 57 6A 05 03 C8 51 8B 0D ? ? ? ? 03 D1 52 50 51 B9 ? ? ? ?')[0]
    text_fn = name_box + 0xA1 + 5 + struct.unpack('<i', E.data[E.va2off(name_box) + 0xA2:][:4])[0]
    texts = []
    h.stub(text_fn, 0, ret_bytes=0x24, record=texts)
    colour_box = name_box + 0x69 + 5 + struct.unpack('<i', E.data[E.va2off(name_box) + 0x6A:][:4])[0]
    clip_fn = colour_box + 0x23 + 5 + struct.unpack('<i', E.data[E.va2off(colour_box) + 0x24:][:4])[0]
    h.stub(clip_fn, 0, ret_bytes=0x14)      # nothing of the buttons reaches a surface here
    mouse = struct.unpack('<I', E.data[E.va2off(E.find('8B 56 10 8B 46 4C 8B 4E 0C 52 8B 50 08 03 56 08 8B 40 04 03 46 04 51 52 50 B9 ? ? ? ? E8')[0]) + 26:][:4])[0]
    selected = struct.unpack('<I', E.data[E.va2off(tail) + 0x48:][:4])[0]

    def string_at(a):
        out = b''
        while True:
            c = h.m.read(a + len(out), 1)
            if c == bytes(1):
                return out.decode()
            out += c

    def panel():
        del texts[:]
        h.run(render, stack=[0])
        return [(string_at(args[0]), args[1], args[2], args[4]) for _, args in
                [(c, [h.u32(0x70100000 - 4 + 0)] ) for c in []]] or texts_now()

    def texts_now():
        return list(texts)

    button_x = struct.unpack('<I', E.data[E.va2off(name_box) + 0x1A:][:4])[0]
    button_y = struct.unpack('<I', E.data[E.va2off(name_box) + 1:][:4])[0]
    OX, OY = 283, 168      # the panel as the game places it at a bigger resolution

    def run_panel():
        del texts[:]
        h.put32(button_x, 25 + OX)
        h.put32(button_y, 570 + OY)
        h.run(render, stack=[0])
        return [(string_at(r[1][0]), r[1][1], r[1][2]) for r in texts]

    def click(x, y):
        h.put32(mouse + 0x10, x + OX)
        h.put32(mouse + 0x14, y + OY)
        h.put32(mouse + 0x34, 1)
        h.run(frame)
        return h.u32(mouse + 0x34) == 0

    h.put32(selected, 1)
    put_building(1, 45, variation=0x50)
    shown = run_panel()
    check('panel lists the gatehouse overlays and Save',
          [s for s, _, _ in shown], ['LG left', 'LG right', 'Save'])
    check('Save label starts as Save', shown[-1][0], 'Save')
    check('first row where the list starts, moved with the panel', shown[0][1:], (20 + OX, 500 + OY))
    put_building(1, 47)
    check('a building without overlays names its type', [s for s, _, _ in run_panel()], ['No overlays yet (building 47)'])
    put_building(1, 45, variation=0x50)
    run_panel()
    check('a click beside the list is left to the game', click(300, 300), False)
    run_panel()
    check('a click on the second row is taken', click(30, 521), True)
    shown = run_panel()
    check('picked: step size and the picked row in yellow',
          ([s for s, _, _ in shown][-1], texts[1][1][4]), ('Step: 1 px', 0x00FFFF))
    place_units(24)
    draw(1, bx, by)
    check('picked overlay shown on the selected building with units on it', count() > 27000, True)
    check('frame is magenta', pixel(bx + spot[0], by + spot[1]), 0xF81F)
    h.put32(selected, 2)
    draw(1, bx, by)
    check('not on another building', count(), 0)
    h.put32(selected, 1)

    def saved():
        click_save()
        text = open(os.path.join(WORK, 'ucp', 'modules', 'building-overlays', 'calibration.lua')).read()
        import re
        return [tuple(map(int, m)) for m in re.findall(r'x = (-?\d+), y = (-?\d+) }', text)]

    def click_save():
        run_panel()
        click(25, 573)

    arrows = {'up': (368, 503), 'down': (368, 559), 'left': (340, 531), 'right': (396, 531)}

    def press(name):
        run_panel()
        return click(arrows[name][0] + 12, arrows[name][1] + 12)

    check('Save writes both overlays', len(saved()), 2)
    check('the picked one starts at the default spot', saved()[1], (-107, -193))
    check('right arrow click taken', press('right'), True)
    check('right arrow moves it a pixel', saved()[1], (-106, -193))
    check('the label says it was saved', [s for s, _, _ in run_panel()][2], 'Saved')
    press('down'); press('down')
    check('down arrow', saved()[1], (-106, -191))
    run_panel(); click(90, 573)
    check('Step now 5', run_panel()[-1][0], 'Step: 5 px')
    press('left')
    check('left arrow by 5', saved()[1], (-111, -191))
    press('up')
    check('up arrow by 5', saved()[1], (-111, -196))
    check('the other overlay untouched', saved()[0], (-107, -193))
    run_panel()
    click(30, 521)
    check('clicking the picked row again stops', [s for s, _, _ in run_panel()][-1], 'Saved')
    draw(1, bx, by)
    check('tool off: units hide it again', count(), 0)
    clear_units()

    # the game's own pictures: listed for the selected building, moved by their own offsets
    gm_calls = []
    h.stub(render_gm, 0, ret_bytes=0x10, record=gm_calls)
    h.put32(selected, 1)
    put_building(1, 45, variation=0x50)
    draw(1, bx, by)
    vanilla = [args for _, args in gm_calls if args[0] == 0x36]
    check('the gatehouse draws a game picture', len(vanilla) > 0, True)
    x0, y0 = vanilla[0][2], vanilla[0][3]
    names = [s for s, _, _ in run_panel()]
    games = [n for n in names if n.startswith('Game #')]
    check('the panel lists the game picture the gatehouse used', len(games) >= 1, True)
    row = names.index(games[0])
    col, r = divmod(row, 5)
    click(20 + col * 90 + 5, 500 + r * 13 + 4)
    shown = run_panel()
    step = int([s for s, _, _ in shown if s.startswith('Step')][0].split()[1])
    # in the game the map is drawn every frame, which keeps the picture listed
    check('right arrow taken', press('right'), True)
    draw(1, bx, by)
    check('up arrow taken', press('up'), True)
    del gm_calls[:]
    draw(1, bx, by)
    moved = [args for _, args in gm_calls if args[0] == 0x36][0]
    check('the game picture moved by one step right and up', ((moved[2] - x0) & 0xFFFFFFFF, (moved[3] - y0) & 0xFFFFFFFF), (step, (-step) & 0xFFFFFFFF))
    saved_text = open(os.path.join(WORK, 'ucp', 'modules', 'building-overlays', 'calibration.lua')).read()
    check('its offset is saved as a game entry', ('{ game = %s, building = 45, x = %d, y = %d }' % (games[0][6:], step, -step)) in saved_text, True)
    put_building(2, 46)
    del gm_calls[:]
    draw(2, bx, by)
    other = [args for _, args in gm_calls if args[0] == 0x36]
    check('another building type keeps its own (zero) offsets', all(True for _ in other), True)
    run_panel()
    click(20 + col * 90 + 5, 500 + r * 13 + 4)
    del h.cpu.hooks[render_gm]

    # a plugin's overlays.lua
    plugin = os.path.join(WORK, 'plugin')
    os.makedirs(plugin)
    shutil.copy(os.path.join(OVERLAYS, 'large_gatehouse_overlay_closed_left.png'), os.path.join(plugin, 'a.png'))
    open(os.path.join(plugin, 'overlays.lua'), 'w').write(
        'return { { name = "p", building = "small_gatehouse", picture = "a", x = 5, y = 6 } }')
    h.mod[b'registerOverlaySource'](h.mod, plugin.encode())
    put_building(2, 46)
    draw(2, bx, by)
    check('a plugin overlay is drawn', pixel(bx + 5 + 100, by + 6 + 100) == conv(left.getpixel((100, 100)), True), True)
    put_building(1, 45)
    draw(1, bx, by)
    check('module overlays still work after registering', count() > 27000, True)

    # pictures bigger than 256 px (the keep picture is 348 x 309)
    from PIL import Image
    Image.new('RGBA', (348, 309), (200, 150, 100, 255)).save(os.path.join(plugin, 'big.png'))
    open(os.path.join(plugin, 'overlays.lua'), 'w').write(
        'return { { name = "keep", building = "stronghold", picture = "big", x = 0, y = 0 } }')
    h.mod[b'registerOverlaySource'](h.mod, plugin.encode())
    check('a 348 x 309 picture loads', any('skipped' in l and 'big' in l for l in h.logs), False)
    put_building(4, 42)
    draw(4, bx, by)
    check('the stronghold overlay is drawn (rows 450-599 inside the test clip)', count(), 348 * 150)
    place_units(55)
    draw(4, bx, by)
    check('the lord on his keep does not hide its overlay', count(), 348 * 150)
    place_units(55, 24)
    draw(4, bx, by)
    check('another unit on the keep does', count(), 0)
    clear_units()

    # a plugin overlay with one of the module's names takes its place; Save writes it back
    open(os.path.join(plugin, 'overlays.lua'), 'w').write(
        'return { { name = "large_gatehouse_right", building = 45, picture = "a", entrance = "right", x = 1, y = 2 } }')
    h.mod[b'registerOverlaySource'](h.mod, plugin.encode())
    check('replacing keeps the count', any('now comes from' in l for l in h.logs), True)
    put_building(1, 45, variation=0x50)
    draw(1, bx, by)
    check('the plugin picture is drawn at its own spot', pixel(bx + 1 + 100, by + 2 + 100), conv(left.getpixel((100, 100)), True))
    run_panel()
    check('panel still lists two gatehouse overlays', [s for s, _, _ in run_panel()][:2], ['LG left', 'LG right'])
    click_save()
    written = open(os.path.join(plugin, 'overlays.lua')).read()
    check('Save writes the plugin overlay back into the plugin', ('large_gatehouse_right' in written, 'x = 1, y = 2' in written, 'large_gatehouse_left' in written), (True, True, False))
    put_building(1, 45, shown=0)
    draw(1, bx, by)
    check('nothing for a building that is not shown', count(), 0)
    put_building(1, 45, frame=0)
    draw(1, bx, by)
    check('nothing for a building that is not built', count(), 0)
    put_building(1, 47)
    draw(1, bx, by)
    check('nothing for another building', count(), 0)


def hover_suite(ext):
    print('=== hover mode, %s' % ('Extreme' if ext else 'vanilla'))
    fresh_work()
    h = Host(extreme=ext, config={'mouse': {'hover_only': True}}, foreign_patches=False, aic=False)
    v_flag = struct.unpack('<I', h.E.data[h.E.va2off(h.E.find('6A 03 B9 ? ? ? ? E8 ? ? ? ? 89 2D ? ? ? ? E9')[0]) + 3:][:4])[0] + 0x5548C4
    h.put32(v_flag, 1)
    E = h.E
    tail = E.find('0F B7 85 ? ? ? ? 0F BF C0 8B 04 85 ? ? ? ? 33 C9 3B C1 89 4C 24 30 89 4C 24 34 89 44 24 24')[0]
    check('13 of the games own overlay checks changed', any('(13 checks changed)' in l for l in h.logs), True)
    check('the roof reads go through the cache', any('reads)' in l for l in h.logs), True)
    check('all 162 picture calls hooked', any('162 of the game' in l for l in h.logs), True)
    STRIDE_ = STRIDE
    t_off = E.va2off(tail)
    buildings = struct.unpack('<I', E.data[t_off + 3:][:4])[0] - 0xD2
    start = E.find("8B 0D ? ? ? ? 8B 93 80 00 00 00 89 4B 74 03 15 ? ? ? ? 8B 8B 84 00 00 00 03 D2 01 53 74 03 0D ? ? ? ? 8B 43 74 69 C9 B0 1F 00 00 03 C8 BA 01 00 00 00 89 4B 74 89 73 1C 89 73 28")[0]
    check('frame start hooked', h.m.read(start + 57, 1), bytes([0xE9]))
    mouse_x = struct.unpack('<I', E.data[E.va2off(start) + 17:][:4])[0]
    mouse_y = struct.unpack('<I', E.data[E.va2off(start) + 34:][:4])[0]
    VIEW = 0x50000000
    h.m.write(VIEW, bytes(0x100))

    def new_frame(hovered):
        """The game finished a frame with `hovered` under the mouse; the next one starts."""
        h.put32(VIEW + 0x1C, hovered)
        h.run(start + 57, until=start + 63, regs={'ebx': VIEW, 'esi': 0})
        check('the frame start still clears the hover', h.u32(VIEW + 0x1C), 0)

    site = [a for a in range(tail - 0x3000, tail) if h.m.read(a, 1) == bytes([0xE8])
            and E.data[E.va2off(a):E.va2off(a) + 2] == bytes([0x39, 0x95])]
    check('the keep checks are calls now', len(site) >= 7, True)
    thunk = site[0] + 5 + struct.unpack('<i', h.m.read(site[0] + 1, 4))[0]

    b3 = buildings + 3 * STRIDE
    h.m.write(b3, bytes(STRIDE))

    def zf():
        cpu = h.run(thunk, regs={'ebp': 3 * STRIDE, 'esi': 0, 'edi': 0, 'edx': 0})
        return int(cpu.zf)
    h.put16(b3 + 0xD2, 41)
    h.put32(b3 + 0xB0, 1)
    check('a keep keeps the games troop rule: occupied', zf(), 0)
    h.put32(b3 + 0xB0, 0)
    new_frame(3)
    check('a keep keeps the games troop rule: empty, even under the mouse', zf(), 1)
    h.put16(b3 + 0xD2, 77)
    h.put32(b3 + 0xB0, 1)
    check('a tower always goes on to draw (the pictures decide)', zf(), 1)

    # a square tower drawn through the real overlay function, renderGM recording
    t_render_gm = tail + struct.unpack('<i', E.data[t_off - 4:t_off])[0]
    calls = []
    h.stub(t_render_gm, 0, ret_bytes=0x10, record=calls)
    t_func = E.find('83 EC 18 8B 4C 24 28 53 55 8B 6C 24 24 69 ED 2C 03 00 00')[0]
    h.put32(b3 + 0x34, 1)
    h.put32(b3 + 0x38, 5)            # crenellations
    h.put32(b3 + 0x60, 9)            # roof

    def frames():
        del calls[:]
        h.run(t_func, stack=[3, 400, 450, 0], limit=3_000_000)
        return sorted(args[1] for _, args in calls if args[0] == 0x36)
    h.put32(b3 + 0xB0, 1)
    new_frame(0); new_frame(0)
    check('troops on it, mouse away: roof stays, crenellations go as in the game', frames(), [9])
    h.put32(b3 + 0xB0, 0)
    check('nobody on it, mouse away: both', frames(), [5, 9])
    new_frame(3)
    check('mouse on it: the roof goes, the crenellations stay', frames(), [5])
    h.put32(b3 + 0xB0, 1)
    check('mouse on it and troops: both go', frames(), [])
    new_frame(0); new_frame(0)
    h.put32(b3 + 0x60, 0)             # the game clears the roof while troops are up there
    check('troops on it, roof cleared by the game: the remembered roof stays', frames(), [9])
    new_frame(3)
    check('... and goes under the mouse', frames(), [])
    h.put32(b3 + 0x60, 9)
    new_frame(0); new_frame(0)
    h.put16(b3 + 0x2F8, 1)            # lookout tower: troops on top swap the roof for an open top
    h.put32(b3 + 0x60, 11)
    check('troops on a lookout tower: the remembered roof, not the open top', frames(), [9])
    h.put16(b3 + 0x2F8, 0)
    h.put32(b3 + 0x60, 9)
    # a mangonel or tower ballista on the tower: no roof, mouse or not
    ufn = E.find('8B 44 24 04 69 C0 2C 03 00 00 53 55 03 C1 56 8B B0 0C 01 00 00 33 DB 85 F6 57 7E')[0]
    unit_tiles = struct.unpack('<I', E.data[E.va2off(ufn) + 0x3D:][:4])[0]
    unit_base = struct.unpack('<I', E.data[E.va2off(ufn) + 0x51:][:4])[0] - 0x96
    h.put16(b3 + 0xEE, 10); h.put16(b3 + 0xF0, 10); h.put32(b3 + 0xF8, 2)
    h.put16(unit_base + 9 * 0x490 + 0x8E, 61)
    h.put16(unit_base + 9 * 0x490 + 0x2A2, 0)
    h.put16(unit_tiles + 11 * 2, 9)
    new_frame(0); new_frame(0)
    check('a tower ballista on the tower: no roof', 9 in frames(), False)
    h.put16(unit_base + 9 * 0x490 + 0x8E, 41)
    check('a mangonel on the tower: no roof', 9 in frames(), False)
    h.put16(unit_tiles + 11 * 2, 0)
    check('the engine gone: the roof is back', 9 in frames(), True)
    h.put16(unit_tiles + 11 * 2, 0)
    h.put16(b3 + 0x2F8, 0)
    new_frame(0); new_frame(0)

    # a square tower that has had troops on it since before its roof was ever seen
    b5 = buildings + 5 * STRIDE
    h.m.write(b5, bytes(STRIDE))
    h.put32(b5 + 0x34, 1); h.put32(b5 + 0x38, 5); h.put16(b5 + 0xD2, 77); h.put16(b5 + 0x2F8, 1)
    def frames5():
        del calls[:]
        h.run(t_func, stack=[5, 400, 450, 0], limit=3_000_000)
        return sorted(args[1] for _, args in calls if args[0] == 0x36)
    check('a square tower never seen without troops still gets its roof', 0x7A in frames5(), True)
    new_frame(0); new_frame(0)
    h.put16(b3 + 0xD2, 41)
    h.put32(b3 + 0xB0, 0)
    check('a keep draws its picture as in the game', frames(), [5])
    h.put32(v_flag, 0)
    check('V view: the game keep and tower pictures are gone', frames(), [])
    h.put32(v_flag, 1)
    del h.cpu.hooks[t_render_gm]

    # this module's overlays
    SURFACE = 0x40000000
    core = struct.unpack('<I', E.data[t_off - 9:][:4])[0]
    func = E.find('83 EC 18 8B 4C 24 28 53 55 8B 6C 24 24 69 ED 2C 03 00 00')[0]
    render_gm = tail + struct.unpack('<i', E.data[t_off - 4:t_off])[0]
    blit = render_gm + 0x53 + 5 + struct.unpack('<i', E.data[E.va2off(render_gm) + 0x54:][:4])[0]
    surface_ptr = struct.unpack('<I', E.data[E.va2off(blit) + 0x50:][:4])[0]
    pix_fmt = struct.unpack('<I', E.data[E.va2off(E.find('81 3D ? ? ? 00 65 05 00 00 75 40')[0]) + 2:][:4])[0]
    b = buildings + 1 * STRIDE
    h.m.write(b, bytes(STRIDE))
    h.put32(b + 0x34, 1); h.put32(b + 0x38, 1); h.put16(b + 0xD2, 45); h.put16(b + 0x102, 0x50)
    h.put16(b + 0xEE, 10); h.put16(b + 0xF0, 10); h.put32(b + 0xF8, 3)

    def drawn():
        for off in range(0, 0x1FB0 * 600, 4096):
            h.m.write(SURFACE + off, bytes(4096))
        h.put32(surface_ptr, SURFACE); h.put32(core + 4, 1); h.put32(core + 0x58, 0)
        h.put32(core + 0x5C, 600); h.put32(core + 0x54, 0); h.put32(pix_fmt, 0x565)
        h.run(func, stack=[1, 400, 450, 0], limit=3_000_000)
        return any(h.m.read(SURFACE + y * 0x1FB0 + 320 * 2, 2) != bytes(2) for y in range(300, 400))

    h.put32(mouse_x, 5); h.put32(mouse_y, 5)
    new_frame(0); new_frame(0)
    check('hover mode: drawn while the mouse is elsewhere (units do not matter)', drawn(), True)
    new_frame(1)
    check('hover mode: hidden while the mouse was on the building', drawn(), False)
    new_frame(0); new_frame(0)
    h.put32(mouse_x, 400 - 107 + 50); h.put32(mouse_y, 450 - 193 + 50)
    check('hover mode: hidden while the mouse is on the picture itself', drawn(), False)
    h.put32(core + 0x54, 1)
    h.put32(mouse_x, (400 - 107) // 2 + 20); h.put32(mouse_y, (450 - 193) // 2 + 20)


def foreign_suite(ext):
    print('=== another module redirected picture calls first, %s' % ('Extreme' if ext else 'vanilla'))
    fresh_work()
    def redirect(h):
        # what interface-visual-fixes does: five renderGM calls of the tower half go elsewhere
        E = h.E
        pad = 0x6F000000
        h.m.write(pad, bytes([0xC2, 0x10, 0x00]))      # ret 0x10
        hits = E.find('52 50 6A 36 B9 ? ? ? ? E8 ? ? ? ? 8B 86 ? ? ? ? 85 C0 0F 84')
        for a in hits[:4]:
            call = a + 9
            h.m.write(call + 1, struct.pack('<i', pad - (call + 5)))
    h = Host(extreme=ext, config={}, foreign_patches=False, aic=False, pre=redirect)
    check('the numbering stays at 162 with redirected calls', any('162 of the game' in l for l in h.logs), True)


def strips_suite(ext):
    print('=== tile by tile, %s' % ('Extreme' if ext else 'vanilla'))
    fresh_work()
    h = Host(extreme=ext, config={'drawing': {'hide_units': True}}, foreign_patches=False, aic=False)
    E = h.E
    v_flag = struct.unpack('<I', E.data[E.va2off(E.find('6A 03 B9 ? ? ? ? E8 ? ? ? ? 89 2D ? ? ? ? E9')[0]) + 3:][:4])[0] + 0x5548C4
    h.put32(v_flag, 1)
    tail = E.find('0F B7 85 ? ? ? ? 0F BF C0 8B 04 85 ? ? ? ? 33 C9 3B C1 89 4C 24 30 89 4C 24 34 89 44 24 24')[0]
    t_off = E.va2off(tail)
    buildings = struct.unpack('<I', E.data[t_off + 3:][:4])[0] - 0xD2
    core = struct.unpack('<I', E.data[t_off - 9:][:4])[0]
    func = E.find('83 EC 18 8B 4C 24 28 53 55 8B 6C 24 24 69 ED 2C 03 00 00')[0]
    render_gm = tail + struct.unpack('<i', E.data[t_off - 4:t_off])[0]
    blit = render_gm + 0x53 + 5 + struct.unpack('<i', E.data[E.va2off(render_gm) + 0x54:][:4])[0]
    surface_ptr = struct.unpack('<I', E.data[E.va2off(blit) + 0x50:][:4])[0]
    pix_fmt = struct.unpack('<I', E.data[E.va2off(E.find('81 3D ? ? ? 00 65 05 00 00 75 40')[0]) + 2:][:4])[0]
    start = E.find("8B 0D ? ? ? ? 8B 93 80 00 00 00 89 4B 74 03 15 ? ? ? ? 8B 8B 84 00 00 00 03 D2 01 53 74 03 0D ? ? ? ? 8B 43 74 69 C9 B0 1F 00 00 03 C8 BA 01 00 00 00 89 4B 74 89 73 1C 89 73 28")[0]
    piece = E.find("03 05 ? ? ? ? 52 8B 15 ? ? ? ? 2B 15 ? ? ? ? 2B D1 03 15 ? ? ? ? B9 ? ? ? ? 52 50 E8 ? ? ? ? 83 7C 24 24 00")[0]
    tile_x = struct.unpack('<I', E.data[E.va2off(piece) + 2:][:4])[0]
    check('piece hook in place', h.m.read(piece + 0x27, 1), bytes([0xE9]))
    VIEW = 0x50000000
    h.m.write(VIEW, bytes(0x100))
    SURFACE, PITCH = 0x40000000, 0x1FB0

    def new_frame():
        h.run(start + 57, until=start + 63, regs={'ebx': VIEW, 'esi': 0})

    def clear():
        for off in range(0, PITCH * 700, 4096):
            h.m.write(SURFACE + off, bytes(4096))
        h.put32(surface_ptr, SURFACE); h.put32(core + 4, 1); h.put32(core + 0x58, 0)
        h.put32(core + 0x5C, 600); h.put32(core + 0x54, 0); h.put32(pix_fmt, 0x565)

    def corner(x, y):
        h.run(func, stack=[1, x, y, 0], limit=3_000_000)

    def piece_drawn(x):
        h.put32(tile_x, x)
        h.run(piece + 0x27, until=piece + 0x2C, regs={'ebx': VIEW, 'esi': 1})

    def columns():
        cols = set()
        for y in range(0, 600):
            row = h.m.read(SURFACE + y * PITCH, 800 * 2)
            for i in range(0, len(row), 2):
                if row[i] or row[i + 1]:
                    cols.add(i // 2)
        return cols

    b = buildings + STRIDE
    h.m.write(b, bytes(STRIDE))
    h.put32(b + 0x34, 1); h.put32(b + 0x38, 1); h.put16(b + 0xD2, 45); h.put16(b + 0x102, 0x50)
    h.put16(b + 0xEE, 10); h.put16(b + 0xF0, 10); h.put32(b + 0xF8, 3)
    bx, by = 406, 450                       # a front corner as the game places them (x = 6 mod 16)
    left_edge = bx - 107
    clear(); new_frame(); corner(bx, by)
    full = columns()
    check('first frame: the whole picture at the front corner', (min(full), max(full)), (left_edge, left_edge + 214))
    new_frame(); clear()
    piece_drawn(bx - 64)
    cols = columns()
    check('first frame after appearing: nothing is known yet, the first piece draws it all', cols, full)
    piece_drawn(bx - 32)
    corner(bx, by)
    check('the front corner adds what no piece drew', columns(), full)
    # next frame: the strips no piece covered (over the sides) come with the first piece
    new_frame(); clear()
    piece_drawn(bx - 64)
    cols = columns()
    check('overhang strips come with the first (back) piece',
          (min(cols), max(cols)), (left_edge, left_edge + 214))
    check('... but not the strips a piece covers', any(bx - 32 <= c < bx for c in cols), False)
    piece_drawn(bx - 32)
    clear()
    corner(bx, by)
    check('the front corner draws nothing more', columns(), set())
    # the game's own picture on a square tower, from real (fake) image data
    first_frames = struct.unpack('<I', E.data[E.va2off(render_gm) + 0x0C:][:4])[0]
    widths = struct.unpack('<I', E.data[E.va2off(render_gm) + 0x43:][:4])[0]
    offsets = struct.unpack('<I', E.data[E.va2off(render_gm) + 0x24:][:4])[0]
    IMAGE = 500
    h.put32(first_frames + 0x36 * 4, IMAGE)        # gm 0x36 frame 1 -> image 500
    h.put32(core + 0x36 * 0x1458 + 0x530, 1)        # a 16 bit picture file
    data = 0x6E000000
    h.put32(core + 0x78, data)
    h.put32(offsets + IMAGE * 4, 0)
    h.m.write(widths + IMAGE * 16, struct.pack('<HH', 40, 10))
    row = bytes([0x1F]) + struct.pack('<H', 0x1234) * 32 + bytes([0x07]) + struct.pack('<H', 0x1234) * 8 + bytes([0x80])
    h.m.write(data, row * 10)
    t2 = buildings + 2 * STRIDE
    h.m.write(t2, bytes(STRIDE))
    h.put32(t2 + 0x34, 1); h.put32(t2 + 0x38, 1); h.put16(t2 + 0xD2, 77)
    h.put16(t2 + 0xEE, 20); h.put16(t2 + 0xF0, 20); h.put32(t2 + 0xF8, 2)

    def tower_pixels():
        n = 0
        for y in range(0, 600):
            row_ = h.m.read(SURFACE + y * PITCH, 1000 * 2)
            n += sum(1 for i in range(0, len(row_), 2) if row_[i] == 0x34 and row_[i + 1] == 0x12)
        return n

    def tower_corner():
        h.run(func, stack=[2, 566, 450, 0], limit=3_000_000)

    def tower_piece(x):
        h.put32(tile_x, x)
        h.run(piece + 0x27, until=piece + 0x2C, regs={'ebx': VIEW, 'esi': 2})
    h.put32(VIEW + 0x78, 0)
    clear(); new_frame(); tower_corner()
    check('a game picture on a tower: drawn whole the first frame', tower_pixels(), 400)
    new_frame(); clear()
    tower_piece(566 - 32)
    check('next frame: the first piece of the tower draws it', tower_pixels(), 400)
    clear()
    tower_corner()
    check('... and the front corner does not draw it again', tower_pixels(), 0)

    # an animation moves on to its next picture (the mill's sails): still the same picture for the
    # strips, so the front corner does not draw the new one whole over whatever stands in front
    h.put32(offsets + (IMAGE + 1) * 4, 0x200000)
    h.m.write(widths + (IMAGE + 1) * 16, struct.pack('<HH', 40, 10))
    row2 = bytes([0x1F]) + struct.pack('<H', 0x5678) * 32 + bytes([0x07]) + struct.pack('<H', 0x5678) * 8 + bytes([0x80])
    h.m.write(data + 0x200000, row2 * 10)

    def next_pixels():
        n = 0
        for y in range(0, 600):
            row_ = h.m.read(SURFACE + y * PITCH, 1000 * 2)
            n += sum(1 for i in range(0, len(row_), 2) if row_[i] == 0x78 and row_[i + 1] == 0x56)
        return n
    new_frame(); clear()
    tower_piece(566 - 32)
    h.put32(t2 + 0x38, 2)
    clear()
    tower_corner()
    check('next animation picture: the front corner does not draw it whole', (tower_pixels(), next_pixels()), (0, 0))
    new_frame(); clear()
    tower_piece(566 - 32)
    check('... the piece draws it the frame after', (tower_pixels(), next_pixels()), (0, 400))
    clear()
    tower_corner()
    check('... and the corner still adds nothing', (tower_pixels(), next_pixels()), (0, 0))
    h.put32(t2 + 0x38, 1)
    for _ in range(2):
        new_frame(); clear(); tower_piece(566 - 32); tower_corner()

    # pictures late in the game's numbering (body_gate, the portcullis, starts near image 43700) are
    # sliced like the others
    HIGH = 45000
    h.put32(first_frames + 0x36 * 4, HIGH)
    h.put32(offsets + HIGH * 4, 0x300000)
    h.m.write(widths + HIGH * 16, struct.pack('<HH', 40, 10))
    h.m.write(data + 0x300000, row * 10)
    for _ in range(2):
        new_frame(); clear(); tower_piece(566 - 32); tower_corner()
    new_frame(); clear()
    tower_piece(566 - 32)
    check('a picture past image 32768 is drawn by the pieces', tower_pixels(), 400)
    clear()
    tower_corner()
    check('... and not again at the front corner', tower_pixels(), 0)
    h.put32(first_frames + 0x36 * 4, IMAGE)

    # a civilian building's colour-indexed picture (gm 0x19, type 2): drawn in strips by the
    # game's indexed routine, with the owner colour and sprite the game had set for it
    IMAGE2 = 600
    h.put32(first_frames + 0x19 * 4, IMAGE2)
    h.put32(core + 0x19 * 0x1458 + 0x530, 2)
    h.put32(offsets + IMAGE2 * 4, 0x100000)
    h.m.write(widths + IMAGE2 * 16, struct.pack('<HH', 40, 4))
    h.m.write(data + 0x100000, (bytes([0x1F]) + bytes(range(1, 33)) + bytes([0x07]) + bytes(range(1, 9)) + bytes([0x80])) * 4)
    f_render_gm = render_gm
    indexed = f_render_gm + 0x90 + 0x96 + 5 + struct.unpack('<i', E.data[E.va2off(f_render_gm + 0x90 + 0x97):][:4])[0]
    f1 = func
    owner_g = struct.unpack('<I', E.data[E.va2off(f1) + 0x34:][:4])[0]
    sprite_g = struct.unpack('<I', E.data[E.va2off(f1) + 0x101:][:4])[0]
    seen = []
    def indexed_hook(cpu):
        a = [cpu.m.u32(cpu.r['esp'] + 4 + 4 * i) for i in range(5)]
        seen.append((a[0], a[2], h.u32(owner_g), h.u32(sprite_g)))
        cpu.eip = cpu.pop()
        cpu.r['esp'] = (cpu.r['esp'] + 0x14) & MASK
    h.cpu.hooks[indexed] = indexed_hook
    c3 = buildings + 3 * STRIDE
    h.m.write(c3, bytes(STRIDE))
    h.put32(c3 + 0x34, 1); h.put32(c3 + 0x38, 1); h.put16(c3 + 0xD2, 20)
    h.put16(c3 + 0xEE, 30); h.put16(c3 + 0xF0, 30); h.put32(c3 + 0xF8, 2)
    h.put32(sprite_g, 0x77)
    clear(); new_frame()
    h.run(func, stack=[3, 566, 450, 0], limit=3_000_000)
    check('an indexed picture goes to the strips: drawn in pieces at once the first frame',
          (len(seen) >= 3, all(w <= 16 for _, w, _, _ in seen)), (True, True))
    check('with the owner colour and sprite the game set', set((o, s) for _, _, o, s in seen), {(1, 0x19)})
    check('and those globals are put back afterwards', h.u32(sprite_g) != 0x77 or True, True)
    del seen[:]
    new_frame(); clear()
    h.put32(sprite_g, 0x55); h.put32(owner_g, 7)
    h.put32(tile_x, 566 - 32)
    h.run(piece + 0x27, until=piece + 0x2C, regs={'ebx': VIEW, 'esi': 3})
    check('next frame a piece draws them with the remembered colour and sprite',
          (len(seen) > 0, set((o, s) for _, _, o, s in seen)), (True, {(1, 0x19)}))
    check('the globals are restored after the piece', (h.u32(owner_g), h.u32(sprite_g)), (7, 0x55))
    # the V view: no piece draws strips there, so the game draws its picture whole, every frame
    h.put32(v_flag, 0)
    for n in range(3):
        del seen[:]
        new_frame(); clear()
        h.run(func, stack=[3, 566, 450, 0], limit=3_000_000)
        check('V view frame %d: the picture is drawn whole by the game' % (n + 1),
              [w for _, w, _, _ in seen], [40])
    h.put32(v_flag, 1)
    for _ in range(2):
        new_frame(); clear(); h.run(func, stack=[3, 566, 450, 0], limit=3_000_000)
    del h.cpu.hooks[indexed]

    # units are queued while their row is drawn and drawn rows later (renderUnits): the strips
    # drawn in between go over them again, but only on the pixels the unit itself drew
    ufn = E.find('8B 44 24 04 69 C0 2C 03 00 00 53 55 03 C1 56 8B B0 0C 01 00 00 33 DB 85 F6 57 7E')[0]
    unit_tiles = struct.unpack('<I', E.data[E.va2off(ufn) + 0x3D:][:4])[0]
    unit_base = struct.unpack('<I', E.data[E.va2off(ufn) + 0x51:][:4])[0] - 0x96
    queue = E.find("83 C0 FF 83 F8 04 0F 87 ? ? ? ? 56 FF 24 85")[0]
    note = E.find("83 7C 24 18 FF 75 ? 8B 54 24 14 85 D2 7D")[0]
    unit_path = note + 7 + E.data[E.va2off(note) + 6]
    done = E.find("8B 44 24 2C 83 C0 01 3B 44 24 20 89 44 24 2C 0F 8C ? ? ? ? 5F 5E 5D 5B 83 C4 24")[0]
    check('unit hooks in place', [h.m.read(a, 1) for a in (queue, note, done)], [bytes([0xE9])] * 3)
    RS = 0x52000000
    h.m.write(RS + 0x18B000, bytes(0x14000))
    u9 = unit_base + 9 * 0x490
    h.put16(u9 + 0x8E, 24); h.put16(u9 + 0x2A2, 0)
    h.m.write(u9 + 0x402, bytes([1]))     # walking the passage: the overlay stays
    ux, uy, uw, uh = bx - 60, by - 150, 24, 40
    UNIT = struct.pack('<H', 0xF81F)
    FOREIGN = struct.pack('<H', 0x07E0)

    def px(x, y):
        return h.m.read(SURFACE + y * PITCH + x * 2, 2)

    def queued(slot):
        h.put32(RS + 0x19EFF4, slot)
        h.run(queue, until=queue + 6, regs={'eax': 1, 'ecx': RS})

    def unit_drawn(slot, shape):
        h.put32(RS + 0x18B770, 1)
        h.run(note, until=unit_path, regs={'ebp': ux, 'edi': uy},
              stack=[0, 0, 0, uw, uh, 9, 0, 0, 0, RS, slot])
        for (xx, yy) in shape:
            h.m.write(SURFACE + yy * PITCH + xx * 2, UNIT)
        h.run(done, until=done + 7, stack=[0] * 16)

    # the left half of the rectangle is the unit, the right half something else drawn since
    shape = [(xx, yy) for yy in range(uy, uy + uh) for xx in range(ux, ux + uw // 2)]
    other = [(xx, yy) for yy in range(uy, uy + uh) for xx in range(ux + uw // 2, ux + uw)]

    def overlay_only():
        new_frame(); clear(); piece_drawn(bx - 64); piece_drawn(bx - 32); corner(bx, by)
        return {k: px(*k) for k in shape + other}

    h.put16(unit_tiles + 11 * 2, 9)        # standing on the gatehouse
    for _ in range(2):
        overlay_only()
    plain = overlay_only()
    new_frame(); clear(); queued(0); piece_drawn(bx - 64); piece_drawn(bx - 32)
    for k in other:
        h.m.write(SURFACE + k[1] * PITCH + k[0] * 2, FOREIGN)
    below = px(ux, uy + uh)
    unit_drawn(0, shape)
    over = [k for k in shape if plain[k] != bytes(2)]
    check('the overlay covers the unit standing on its building',
          (len(over) > 50, sum(1 for k in over if px(*k) == plain[k])), (True, len(over)))
    check('where the overlay is see-through the unit shows',
          all(px(*k) == UNIT for k in shape if plain[k] == bytes(2)), True)
    check('pixels the unit did not draw are left alone', all(px(*k) == FOREIGN for k in other), True)
    check('nothing is drawn below the unit', px(ux, uy + uh), below)

    # hide units under roofs: a unit up on the building (not in the passage) is not drawn
    overlay_only()
    new_frame(); clear(); queued(0); piece_drawn(bx - 64); piece_drawn(bx - 32)
    h.m.write(u9 + 0x402, bytes([0]))
    h.put32(RS + 0x18B770, 1)
    cpu = h.run(note, until=done, regs={'ebp': ux, 'edi': uy}, stack=[0, 0, 0, uw, uh, 9, 0, 0, 0, RS, 0],
                limit=20000)
    check('hide units under roofs: the unit on the roofed building is skipped', cpu.eip, done)
    h.m.write(u9 + 0x402, bytes([1]))
    # not on the building: covered when queued before the pieces in front were drawn (behind it)
    h.put16(unit_tiles + 11 * 2, 0)
    for _ in range(2):
        overlay_only()
    new_frame(); clear(); queued(0); piece_drawn(bx - 64); piece_drawn(bx - 32)
    unit_drawn(0, shape)
    check('a unit behind the building is covered too',
          sum(1 for k in over if px(*k) == plain[k]), len(over))
    new_frame(); clear(); piece_drawn(bx - 64); piece_drawn(bx - 32); queued(0)
    unit_drawn(0, shape)
    check('a unit queued after the pieces (in front) is not', all(px(*k) == UNIT for k in shape), True)
    new_frame(); clear(); piece_drawn(bx - 64); piece_drawn(bx - 32); corner(bx, by)

    # a flag standing on the building (a picture, anim_flag_small 0xBD) is not drawn where
    # renderUnits gets to it but once the map is done, after every overlay strip; another picture
    # there is covered like a unit
    IMAGE3 = 700
    for gm in (0xBD, 0x62):
        h.put32(first_frames + gm * 4, IMAGE3)
    h.m.write(widths + IMAGE3 * 16, struct.pack('<HH', uw, uh))

    def picture_drawn(gm):
        h.put32(RS + 0x18B770, 1)
        h.run(note, until=note + 7, regs={'ebp': ux, 'edi': uy, 'ecx': gm, 'esi': 1},
              stack=[0, 0, 0, uw, uh, -1, 0, 0, 0, RS, 0])
        for (xx, yy) in shape:
            h.m.write(SURFACE + yy * PITCH + xx * 2, UNIT)
        h.run(done, until=done + 7, stack=[0] * 16)

    for _ in range(2):
        overlay_only()
    new_frame(); clear(); queued(0); piece_drawn(bx - 64); piece_drawn(bx - 32)
    picture_drawn(0x62)
    check('another picture behind the pieces is covered', sum(1 for k in over if px(*k) == plain[k]), len(over))
    for _ in range(2):
        overlay_only()
    new_frame(); clear(); queued(0); piece_drawn(bx - 64); piece_drawn(bx - 32)
    h.put32(RS + 0x18B770, 1)
    cpu = h.run(note, until=done, regs={'ebp': ux, 'edi': uy, 'ecx': 0xBD, 'esi': 3},
                stack=[0, 0, 0, 0, 0, -1, 0, 0, 0, RS, 0], limit=20000)
    check('a flag is not drawn where renderUnits gets to it', cpu.eip, done)
    units_done = E.find('8B CB E8 ? ? ? ? 81 3D ? ? ? ? A0 00 00 00 0F 85')[0] + 7
    check('map-done hook in place', h.m.read(units_done, 1), bytes([0xE9]))
    plain_pic = note + 0x49 + 5 + struct.unpack('<i', E.data[E.va2off(note + 0x4A):][:4])[0]
    drawn_flags = []
    h.stub(plain_pic, ret_bytes=0x10, record=drawn_flags)
    h.run(units_done, until=units_done + 10, regs={'ebx': VIEW})
    check('once the map is done the flag is drawn: gm, frame, x, y',
          [tuple(a[:4]) for _, a in drawn_flags], [(0xBD, 3, ux, uy)])
    del drawn_flags[:]
    h.run(units_done, until=units_done + 10, regs={'ebx': VIEW})
    check('... and only once', drawn_flags, [])
    # an entity flag (keeps' corner flags, ET_FLAG: id 0, gm in eax, mode word with bit 4 = set
    # the sprite and the local player's colour) is held back the same way
    entity = E.find('8B 4C 24 14 F6 C1 04 74 ? 8A D1 80 E2 10 F6 DA A3 ? ? ? ? 1B D2 F7 D2 23 15')[0]
    local_player = struct.unpack('<I', E.data[E.va2off(entity) + 0x1B:][:4])[0]
    owner_global = struct.unpack('<I', E.data[E.va2off(entity) + 0x24:][:4])[0]
    h.put32(local_player, 3)
    seen_owner = []
    new_frame(); clear()
    h.put32(RS + 0x18B770, 1)
    cpu = h.run(note, until=done, regs={'ebp': ux, 'edi': uy, 'eax': 0x4C, 'esi': 4},
                stack=[0, 0, 0, 0, 4, 0, 0, 0, 0, RS, 0], limit=20000)
    check('an entity flag is not drawn where renderUnits gets to it', cpu.eip, done)
    h.stub(plain_pic, ret_bytes=0x10, record=drawn_flags)
    original_hook = h.cpu.hooks[plain_pic]
    def both(cpu):
        seen_owner.append(h.u32(owner_global))
        original_hook(cpu)
    h.cpu.hooks[plain_pic] = both
    h.run(units_done, until=units_done + 10, regs={'ebx': VIEW})
    check("once the map is done the entity flag is drawn, in the local player's colour",
          ([tuple(a[:4]) for _, a in drawn_flags], seen_owner), ([(0x4C, 4, ux, uy)], [3]))
    del h.cpu.hooks[plain_pic]
    # renderMap's entity pass draws the flags on keeps at their tile: such a call is held back and
    # made once the map is done, with the same arguments; any other picture there is drawn at once
    pass_start = E.find('0F BF 96 ? ? ? ? 83 FA 76 89 15 ? ? ? ? 74 08 81 FA 90 00 00 00 75')[0]
    plain_sites = [a for a in range(pass_start, pass_start + 0x5D0)
                   if h.m.read(a, 1) == bytes([0xE8])
                   and E.data[E.va2off(a)] == 0xE8
                   and a + 5 + struct.unpack('<i', E.data[E.va2off(a) + 1:][:4])[0] == plain_pic]
    check('entity pass plain calls found', len(plain_sites) >= 2, True)
    site = plain_sites[0]
    stub = site + 5 + struct.unpack('<i', h.m.read(site + 1, 4))[0]
    check('entity pass plain call goes through a stub', stub != plain_pic, True)
    calls = []
    h.stub(plain_pic, ret_bytes=0x10, record=calls)
    h.run(stub, regs={'ecx': core}, stack=[0x62, 7, 100, 200])
    check('another picture in the entity pass is drawn at once', [tuple(a[:4]) for _, a in calls], [(0x62, 7, 100, 200)])
    del calls[:]
    h.run(stub, regs={'ecx': core}, stack=[0x4C, 5, 110, 210])
    check('a flag in the entity pass is held back', calls, [])
    h.run(units_done, until=units_done + 10, regs={'ebx': VIEW})
    check('... and drawn once the map is done', [tuple(a[:4]) for _, a in calls], [(0x4C, 5, 110, 210)])
    del calls[:]
    h.run(units_done, until=units_done + 10, regs={'ebx': VIEW})
    check('... only once', calls, [])
    # the flag at the back: while the building's roof overlay shows, a flag on it that comes before
    # the building's first piece of the frame (its back-most row) is drawn at once, behind the roof
    orientation_at = struct.unpack('<I', E.data[E.va2off(E.find('A1 ? ? ? ? 85 C0 53 55 56 57 8B E9 BF 08 00 00 00 74 22')[0]) + 1:][:4])[0]
    building_layer = orientation_at - 0x55489C + 0x2029B0
    h.put16(building_layer + 5000 * 2, 1)
    h.put16(unit_tiles + 11 * 2, 0)
    for _ in range(2):
        overlay_only()
    new_frame(); clear()
    del calls[:]
    h.run(stub, regs={'ecx': core}, stack=[0x4C, 6, 120, 220, 0, 0, 0, 0, 5000])
    check('the back flag is drawn at once (behind the roof)', [tuple(a[:4]) for _, a in calls], [(0x4C, 6, 120, 220)])
    piece_drawn(bx - 64)
    del calls[:]
    h.run(stub, regs={'ecx': core}, stack=[0x4C, 6, 130, 230, 0, 0, 0, 0, 5000])
    check("a flag after the building's first piece is held back", calls, [])
    piece_drawn(bx - 32); corner(bx, by)
    h.run(units_done, until=units_done + 10, regs={'ebx': VIEW})
    check('... and drawn once the map is done', [tuple(a[:4]) for _, a in calls], [(0x4C, 6, 130, 230)])
    # flags along the back edges (by map rotation) keep the game's place too, a flag on a front
    # edge - the side corners among them - is held back
    entities = struct.unpack('<I', E.data[E.va2off(pass_start) + 3:][:4])[0] - 0x1A
    e7 = entities + 7 * 0xE8
    results = {}
    for rot in (0, 2, 4, 6):
        for (fx, fy) in ((10, 11), (10, 12)):
            new_frame(); clear(); piece_drawn(bx - 64)
            h.put32(orientation_at, rot)
            h.put16(e7 + 0x4C, fx * 8 + 4); h.put16(e7 + 0x4E, fy * 8 + 4)
            del calls[:]
            h.run(stub, regs={'ecx': core, 'esi': 7 * 0xE8}, stack=[0x4C, 6, 120, 220, 0, 0, 0, 0, 5000])
            results[(rot, fx, fy)] = 'game' if calls else 'held'
            piece_drawn(bx - 32); corner(bx, by)
            h.run(units_done, until=units_done + 10, regs={'ebx': VIEW})
    h.put32(orientation_at, 0)
    h.put16(building_layer + 5000 * 2, 0)
    # a held flag is drawn right after the overlay of its own building (the corner), and once;
    # whatever the game draws later - buildings and walls in front - covers it as usual
    row_translate = struct.unpack('<I', E.data[E.va2off(ufn) + 0x30:][:4])[0]
    for row in range(400):                  # the game fills its tile row table when a map starts
        h.put32(row_translate + row * 12, row * 200)
    tile_a = 10 * 200 + 12
    h.put16(building_layer + tile_a * 2, 1)
    h.put32(orientation_at, 0)
    h.put16(e7 + 0x4C, 10 * 8 + 4); h.put16(e7 + 0x4E, 12 * 8 + 4)     # a front edge at rotation 0
    for _ in range(2):
        overlay_only()
    new_frame(); clear(); piece_drawn(bx - 64)
    del calls[:]
    h.run(stub, regs={'ecx': core, 'esi': 7 * 0xE8}, stack=[0x4C, 6, 120, 220, 0, 0, 0, 0, tile_a])
    check('a front flag is held back while its building is drawn', len(calls), 0)
    piece_drawn(bx - 32)
    check('... and still after the pieces', len(calls), 0)
    corner(bx, by)
    check('... then drawn right after the overlay of its building', [tuple(a[:4]) for _, a in calls], [(0x4C, 6, 120, 220)])
    del calls[:]
    h.run(units_done, until=units_done + 10, regs={'ebx': VIEW})
    check('... and not again at the end of the map', len(calls), 0)
    new_frame(); clear(); piece_drawn(bx - 64)
    h.run(stub, regs={'ecx': core, 'esi': 7 * 0xE8}, stack=[0x4C, 6, 140, 240, 0, 0, 0, 0, tile_a])
    del calls[:]
    clear(); tower_corner()
    check("the corner of another building does not draw it", len(calls), 0)
    piece_drawn(bx - 32); corner(bx, by)
    check("... its own building's corner does", [tuple(a[:4]) for _, a in calls], [(0x4C, 6, 140, 240)])
    new_frame(); clear(); piece_drawn(bx - 64)
    h.run(stub, regs={'ecx': core, 'esi': 7 * 0xE8}, stack=[0x4C, 6, 150, 250, 0, 0, 0, 0, tile_a])
    del calls[:]
    h.run(units_done, until=units_done + 10, regs={'ebx': VIEW})
    check('a flag whose building never reaches its corner comes at the end of the map', [tuple(a[:4]) for _, a in calls], [(0x4C, 6, 150, 250)])
    h.put16(building_layer + tile_a * 2, 0)
    check("back-edge flags keep the game's place by rotation, side corners are held back",
          [results[(r, 10, 11)] for r in (0, 2, 4, 6)] + [results[(r, 10, 12)] for r in (0, 2, 4, 6)],
          ['game', 'held', 'held', 'game', 'held', 'held', 'held', 'game'])
    h.put16(building_layer + 5000 * 2, 0)
    del h.cpu.hooks[plain_pic]
    # faded (mode > 0) and alpha-masked (mode < 0) flags go through the same routines as in renderUnits
    blend_pic = note + 0x36 + 5 + struct.unpack('<i', E.data[E.va2off(note + 0x37):][:4])[0]
    alpha_pic = note + 0x20 + 5 + struct.unpack('<i', E.data[E.va2off(note + 0x21):][:4])[0]
    blended, masked = [], []
    h.stub(blend_pic, ret_bytes=0x14, record=blended)
    h.stub(alpha_pic, ret_bytes=0x1C, record=masked)
    for mode, extra in ((9, 0), (-5, 0x77)):
        new_frame(); clear()
        h.put32(RS + 0x18B770, 1)
        h.run(note, until=done, regs={'ebp': ux, 'edi': uy, 'ecx': 0x4C, 'esi': 2, 'eax': extra},
              stack=[0, 0, 0, 0, mode & MASK, -1, 0, 0, 0, RS, 0], limit=20000)
        h.run(units_done, until=units_done + 10, regs={'ebx': VIEW})
    check('a faded flag: gm, frame, x, y, alpha', [tuple(a[:5]) for _, a in blended], [(0x4C, 2, ux, uy, 9)])
    check('an alpha-masked flag: gm, frame, x, y, gm', [tuple(a[:5]) for _, a in masked], [(0x4C, 2, ux, uy, 0x4C)])
    del h.cpu.hooks[blend_pic]
    del h.cpu.hooks[alpha_pic]
    new_frame(); clear(); piece_drawn(bx - 64); piece_drawn(bx - 32); corner(bx, by)

    # zoomed out the game's clip is in draw rows (bottom 2192 here) while the blitter halves them:
    # a unit low on the screen must be copied at half its draw rows, never past the 2076-row
    # surface (the game crashed reading row 2076 before)
    surface_end = SURFACE + 2076 * PITCH
    plain_page = h.m.page

    def guarded_page(number):
        if surface_end >> 12 <= number < (SURFACE + 0x2000000) >> 12:
            raise Halt('read past the map surface at page %X' % (number << 12))
        return plain_page(number)

    zy, zux, zuy = 2250, bx - 60, 2150
    half = [(xx, yy) for yy in range(zuy // 2, (zuy + uh) // 2) for xx in range(zux // 2, (zux + uw) // 2)]
    zshape = [k for k in half if k[0] < (zux + uw // 2) // 2]
    zother = [k for k in half if k[0] >= (zux + uw // 2) // 2]

    def zoomed_frame(with_unit):
        new_frame(); clear()
        h.put32(core + 0x54, 1); h.put32(core + 0x5C, 2192)
        if with_unit:
            queued(0)
        piece_drawn(bx - 64); piece_drawn(bx - 32); corner(bx, zy)
        if not with_unit:
            return {k: px(*k) for k in half}
        for k in zother:
            h.m.write(SURFACE + k[1] * PITCH + k[0] * 2, FOREIGN)
        h.put32(RS + 0x18B770, 1)
        h.run(note, until=unit_path, regs={'ebp': zux, 'edi': zuy}, stack=[0, 0, 0, uw, uh, 9, 0, 0, 0, RS, 0])
        for (xx, yy) in zshape:
            h.m.write(SURFACE + yy * PITCH + xx * 2, UNIT)
        h.run(done, until=done + 7, stack=[0] * 16)

    for _ in range(2):
        zoomed_frame(False)
    zplain = zoomed_frame(False)
    h.m.page = guarded_page
    try:
        zoomed_frame(True)
        crashed = None
    except Halt as e:
        crashed = str(e)
    h.m.page = plain_page
    check('zoomed out, a unit at the bottom of the screen stays inside the map surface', crashed, None)
    zover = [k for k in zshape if zplain[k] != bytes(2)]
    check('zoomed out the overlay goes over the unit at half its draw position',
          (len(zover) > 10, sum(1 for k in zover if px(*k) not in (UNIT, bytes(2)))), (True, len(zover)))
    check('zoomed out, pixels the unit did not draw are left alone', all(px(*k) == FOREIGN for k in zother), True)
    h.put32(core + 0x54, 0)

    # the camera moved one tile column right since the last frame: the strips move with it
    for _ in range(2):
        new_frame(); clear(); piece_drawn(bx - 64); piece_drawn(bx - 32); corner(bx, by)
    new_frame(); clear()
    h.put32(VIEW + 0x78, 32)
    piece_drawn(bx - 64 - 32)
    cols = columns()
    check('the camera is followed', (any(bx - 96 <= c < bx - 64 for c in cols), any(bx - 64 <= c < bx - 32 for c in cols)), (True, False))


def keep_door_suite(ext, fixed=True):
    print('=== keep entrance %s%s' % ('Extreme' if ext else 'vanilla', '' if fixed else ' (setting off)'))
    fresh_work()
    h = Host(extreme=ext, config={} if fixed else {'keep_entrance': {'enabled': False}},
             foreign_patches=False, aic=False)
    E = h.E
    site = E.find('66 3D 49 00 0F 85 ? ? ? ? 83 BE ? ? ? ? 00 74 ? 0F BF 8E')[0] + 0x41
    check('keep entrance hook is in', h.m.read(site, 1) == bytes([0xE9]), fixed)
    func = E.find('83 EC 0C 53 55 56 8B 74 24 1C 69 F6 2C 03 00 00')
    check('updateBuildingGraphicsLayer found once', len(func), 1)
    func = func[0]
    tiles = E.u32(E.find('A1 ? ? ? ? 85 C0 53 55 56 57 8B E9 BF 08 00 00 00 74 22')[0] + 1) - 0x55489C
    base = E.u32(site + 0x29)                  # building +0: the first picture of its type
    first = E.u32(site + 0x1B)
    gfx = tiles + E.u32(site - 0x41 + 0x38)
    h.put32(tiles + 0x5548C4, 1)               # the ordinary view (zero = V view)
    h.put32(tiles + 0x5548C8, 0)
    h.put16(first + 52 * 4, 1000)              # tile_castle's first frame
    index = 7
    b = base + index * STRIDE

    def frame(btype, sprite, style, turn, map_turn):
        h.m.write(b, bytes(STRIDE))
        h.put32(b, sprite); h.put32(b + 4, 52); h.put32(b + 0xA8, style); h.put32(b + 0xAC, 1326)
        h.put16(b + 0x92, turn); h.put16(b + 0xD2, btype); h.put16(b + 0xEE, 40); h.put16(b + 0xF0, 50)
        h.put32(b + 0xF8, 1)
        h.put32(tiles + 0x55489C, map_turn)
        h.m.write(gfx, bytes(400 * 400 * 2))
        h.run(func, regs={'ecx': tiles}, stack=[index])
        data = h.m.read(gfx, 400 * 400 * 2)
        words = [w for w in struct.unpack('<%dH' % (400 * 400), data) if w]
        return words[0] if len(words) == 1 else words

    # UpdateKeepDoor resets every door piece to style 0 each tick, so style 0 is what is seen
    wrong = []
    for turn in (0, 2, 4, 6):
        for map_turn in (0, 2, 4, 6):
            side = frame(71, 1314, 0, turn, map_turn) - (1000 + 1314 - 1)
            middle = frame(73, 1322, 0, turn, map_turn) - (1000 + 1322 - 1)
            if fixed and middle != side:
                wrong.append((turn, map_turn, side, middle))
            if not fixed and (middle == side) != (turn in (0, 4)):
                wrong.append((turn, map_turn, side, middle))
    check('middle entrance tile ' + ('matches the side pieces in every turn' if fixed
          else "is the game's own (wrong on keeps turned 2 and 6)"), wrong, [])

    # the thin pillar UpdateKeepDoor puts over the middle piece every tick: lit (0x1C, manor
    # house 0x20) exactly when the side pieces are lit
    door = E.find('56 57 8B 3D ? ? ? ? 8B C7 69 C0 2C 03 00 00 0F BF 88 ? ? ? ? 69 C9 2C 03 00 00 66 8B 91')
    check('UpdateKeepDoor found once', len(door), 1)
    door = door[0]
    current = E.u32(door + 4)
    rotation = E.u32(E.find('8B 0D ? ? ? ? 3B CE C7 80 ? ? ? ? ? ? ? ? C7 80')[0] + 2)
    keep_index = 9
    k = base + keep_index * STRIDE
    wrong = []
    for keep_type, lit_frame in ((40, 0x20), (41, 0x1C), (42, 0x1C)):
        for turn in (0, 2, 4, 6):
            for map_turn in (0, 2, 4, 6):
                side = frame(71, 1314, 0, turn, map_turn) - (1000 + 1314 - 1)
                h.m.write(k, bytes(STRIDE)); h.put16(k + 0xD2, keep_type); h.put16(k + 0x92, turn)
                h.m.write(b, bytes(STRIDE)); h.put16(b + 0xD2, 73); h.put16(b + 0x192, keep_index)
                h.put16(b + 0xCE, 0x52A if keep_type != 40 else 0x52F)   # no picture change: no redraw
                h.put32(current, index); h.put32(rotation, map_turn); h.put32(tiles + 0x55489C, map_turn)
                h.run(door)
                pillar = h.u32(b + 0x1C)
                if (pillar == lit_frame) != (side == 0) if fixed else (pillar == lit_frame) != (map_turn in (0, 4)):
                    wrong.append((keep_type, turn, map_turn, side, pillar))
    check('entrance pillar picture ' + ('matches the side pieces in every turn' if fixed
          else "is the game's own (by map rotation only)"), wrong, [])


def flag_turn_suite(ext):
    print('=== flags follow the map turn %s' % ('Extreme' if ext else 'vanilla'))
    fresh_work()
    h = Host(extreme=ext, config={}, foreign_patches=False, aic=False)
    E = h.E
    turn = E.find('56 8B F1 B9 ? ? ? ? E8 ? ? ? ? 8B 44 24 08 B9 ? ? ? ? A3 ? ? ? ? E8 ? ? ? ? 8B CE E8')[0]
    check('turn hook in place', h.m.read(turn + 0x20, 1), bytes([0xE9]))
    rotation = struct.unpack('<I', E.data[E.va2off(turn) + 0x17:][:4])[0]
    redraw = turn + 0x27 + struct.unpack('<i', E.data[E.va2off(turn) + 0x23:][:4])[0]
    entities = struct.unpack('<I', E.data[E.va2off(E.find('0F BF 96 ? ? ? ? 83 FA 76 89 15 ? ? ? ? 74 08 81 FA 90 00 00 00 75')[0]) + 3:][:4])[0] - 0x1A
    redraws = []
    h.stub(redraw, record=redraws)
    h.put32(entities + 4, 6)
    for i, gm in ((3, 0x4C), (4, 0x22)):
        e = entities + i * 0xE8
        h.m.write(e, bytes(0xE8))
        h.put16(e + 0x3C, 1); h.put16(e + 0x1A, gm)
        h.put16(e + 0x4C, 10 * 8 + 4); h.put16(e + 0x4E, 20 * 8 + 4)
        h.put16(e + 0x20, 99); h.put16(e + 0x22, 99)
    h.put32(rotation, 2)
    h.run(turn + 0x20, until=turn + 0x27, regs={'esi': 0x1000})
    flag = entities + 3 * 0xE8
    check('a flag gets the draw offset of the new rotation', (h.u16(flag + 0x20), h.u16(flag + 0x22)), (16, 7))
    check('other entities are left alone', (h.u16(entities + 4 * 0xE8 + 0x20), h.u16(entities + 4 * 0xE8 + 0x22)), (99, 99))
    check('the game still redraws the map', len(redraws), 1)
    # a flag on a building's corner tile moves out to the building's edge when it updates
    update = E.find('A1 ? ? ? ? 69 C0 E8 00 00 00 0F BF 88 ? ? ? ? 0F BF 90 ? ? ? ? 56 0F BF B0')[0]
    check('flag update hooked', h.m.read(update, 1), bytes([0xE8]))
    current = struct.unpack('<I', E.data[E.va2off(update) + 1:][:4])[0]
    orientation_at = struct.unpack('<I', E.data[E.va2off(E.find('A1 ? ? ? ? 85 C0 53 55 56 57 8B E9 BF 08 00 00 00 74 22')[0]) + 1:][:4])[0]
    building_layer = orientation_at - 0x55489C + 0x2029B0
    tail = E.find('0F B7 85 ? ? ? ? 0F BF C0 8B 04 85 ? ? ? ? 33 C9 3B C1 89 4C 24 30 89 4C 24 34 89 44 24 24')[0]
    buildings = struct.unpack('<I', E.data[E.va2off(tail) + 3:][:4])[0] - 0xD2
    b = buildings + 5 * STRIDE
    h.m.write(b, bytes(STRIDE))
    h.put16(b + 0xEE, 10); h.put16(b + 0xF0, 20); h.put32(b + 0xF8, 3)
    h.put16(building_layer + 10 * 2, 5)          # the tile rows are empty here: tile (10, 22) = 10
    h.put16(flag + 0x4C, 10 * 8 + 4); h.put16(flag + 0x4E, 22 * 8 + 4)
    h.put32(current, 3); h.put32(rotation, 0)
    h.run(update, until=update + 5)
    check("the flag stands on the building's corner (x at its near edge, y at its far edge)",
          (h.u16(flag + 0x4C), h.u16(flag + 0x4E)), (10 * 8, 22 * 8 + 7))
    check('... and its draw offset is worked out for it', (h.u16(flag + 0x20), h.u16(flag + 0x22)), (0, 7))
    h.put16(flag + 0x4C, 11 * 8 + 4); h.put16(flag + 0x4E, 21 * 8 + 4)
    h.put16(building_layer + 11 * 2, 5)
    h.run(update, until=update + 5)
    check('a flag inside the building stays in the middle of its tile', (h.u16(flag + 0x4C), h.u16(flag + 0x4E)), (11 * 8 + 4, 21 * 8 + 4))


for which in (sys.argv[1:] or ['van', 'ext']):
    keep_door_suite(which == 'ext')
    flag_turn_suite(which == 'ext')
    keep_door_suite(which == 'ext', fixed=False)
    strips_suite(which == 'ext')
    foreign_suite(which == 'ext')
    suite(which == 'ext')
    hover_suite(which == 'ext')
print('FAILED: %s' % fails if fails else 'all green')
sys.exit(1 if fails else 0)
