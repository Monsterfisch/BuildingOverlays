"""Runs building-overlays unchanged against the real exe image: the module's Lua and assembly
execute, the game's own renderGmOverlayBuilding and picture routine draw into an emulated map
surface, and the pixels are compared with the PNGs.  python test_overlays.py [van|ext]"""
import os, sys, shutil, struct, tempfile
import harness
from harness import Host, SENTINEL, MASK

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


class KeyHost(Host):
    def detour(self, fn, address, size):
        self.keyfn = fn
        super().detour(fn, address, size)


def suite(ext):
    print('=== %s' % ('Extreme' if ext else 'vanilla'))
    fresh_work()
    h = KeyHost(extreme=ext, config={}, foreign_patches=False, aic=False)
    for line in h.logs:
        print('  log', line)
    E = h.E
    tail = E.find('0F B7 85 ? ? ? ? 0F BF C0 8B 04 85 ? ? ? ? 33 C9 3B C1 89 4C 24 30 89 4C 24 34 89 44 24 24')[0]
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
        return b

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
    check('nothing while the game marks it occupied (+0xB0)', count(), 0)
    units = E.find('8B 44 24 04 69 C0 2C 03 00 00 53 55 03 C1 56 8B B0 0C 01 00 00 33 DB 85 F6 57 7E')[0]
    seen = []
    h.stub(units, result=1, ret_bytes=4, record=seen)
    put_building(1, 45)
    draw(1, bx, by)
    check('nothing while units stand on its tiles', count(), 0)
    check('units test gets the building state and index', (seen[0][0], seen[0][1][0]), (buildings - 0x14, 1))
    h.stub(units, result=0, ret_bytes=4)
    draw(1, bx, by)
    check('picture is back when the units leave', count() > 20000, True)
    del h.cpu.hooks[units]

    # the line-up tool: Alt + O switches it on, the picked overlay is shown whatever stands there
    def key(vk):
        regs = h.lua.table()
        regs[b'ESI'] = vk
        h.keyfn(regs)
    h.stub(units, result=1, ret_bytes=4)
    put_building(1, 45, variation=0x50)
    key(0x4F)
    draw(1, bx, by)
    first = count()
    check('tool on: picked overlay shown and framed with units on it', first > 27358, True)
    check('frame is magenta', pixel(bx + spot[0], by + spot[1]), 0xF81F)
    key(0x27); key(0x27); key(0x28)
    draw(1, bx, by)
    check('arrows move it', pixel(bx + spot[0] + 2, by + spot[1] + 1), 0xF81F)
    key(0x22)
    put_building(1, 45, variation=0x51)
    draw(1, bx, by)
    check('page down picks the other overlay', pixel(bx + spot[0], by + spot[1]), 0xF81F)
    key(0x23)
    saved = open(os.path.join(WORK, 'ucp', 'modules', 'building-overlays', 'calibration.lua')).read()
    check('Alt + End saves both overlays', saved.count('building = 45'), 2)
    check('the moved spot is saved', 'x = -105, y = -192' in saved, True)
    key(0x4F)
    draw(1, bx, by)
    check('tool off: units hide it again', count(), 0)
    del h.cpu.hooks[units]

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
    put_building(1, 45, shown=0)
    draw(1, bx, by)
    check('nothing for a building that is not shown', count(), 0)
    put_building(1, 45, frame=0)
    draw(1, bx, by)
    check('nothing for a building that is not built', count(), 0)
    put_building(1, 47)
    draw(1, bx, by)
    check('nothing for another building', count(), 0)


for which in (sys.argv[1:] or ['van', 'ext']):
    suite(which == 'ext')
print('FAILED: %s' % fails if fails else 'all green')
sys.exit(1 if fails else 0)
