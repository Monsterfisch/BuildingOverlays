"""Run smarter-walls unchanged under Lua 5.4 with core mocked onto an emulated 32-bit
address space holding the real exe image; assembly through UCP's fasm.dll."""
import os, sys, struct
import lupa.lua54 as lupa
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, r'C:\Users\MONSTE~1\AppData\Local\Temp\shcw\autosave\py')
sys.path.insert(0, r'C:\Users\MONSTE~1\AppData\Local\Temp\shcw\perf')
sys.path.insert(0, HERE)
from shc import Exe, G
from x86emu_t import Memory, CPU, MASK
from host import fasm, ucp_source

import glob as _glob
MODULE = os.environ.get('SW_MODULE', os.path.join(os.path.dirname(HERE), 'module'))
VAN_PATH = G + r'\Stronghold Crusader.exe'
EXT_PATH = G + r'\Stronghold_Crusader_Extreme.exe'
HEAP = 0x60000000
STACK_TOP = 0x70100000
SENTINEL = 0x7FFFFFF0
_EXES = {}


def exe(p):
    if p not in _EXES:
        _EXES[p] = Exe(p)
    return _EXES[p]


class Host:
    def __init__(self, extreme=False, config=None, foreign_patches=True, aic=True, pre=None):
        self.E = exe(EXT_PATH if extreme else VAN_PATH)
        self.m = Memory(self.image)
        self.cpu = CPU(self.m)
        self.cpu.hooks = {}
        self.heap = HEAP
        self.logs = []
        self.patched = []
        self.after_init = []
        self.scripts = []
        lua = self.lua = lupa.LuaRuntime(unpack_returned_tuples=True, encoding=None)
        g = lua.globals()
        g[b'VERBOSE'], g[b'INFO'], g[b'WARNING'], g[b'ERROR'] = b'VERBOSE', b'INFO', b'WARNING', b'ERROR'
        g[b'log'] = lambda level, message: self.logs.append(
            '%s: %s' % (level.decode(), message.decode('latin-1')))
        c = lua.table()
        c[b'AOBScan'] = self.scan
        c[b'scanForAOB'] = self.scan
        c[b'readInteger'] = lambda a: self.m.s32(int(a))
        c[b'readByte'] = lambda a: struct.unpack('<b', self.m.read(int(a), 1))[0]
        c[b'readSmallInteger'] = lambda a: struct.unpack('<h', self.m.read(int(a), 2))[0]
        c[b'allocateCode'] = self.allocate_code
        c[b'detourCode'] = self.detour
        self.exposed = {}
        self.calls = []
        c[b'exposeCode'] = lambda a, n, cc: (lambda *args: self.call_exposed(int(a), [int(x) for x in args]))

        code = [(vs, vs + max(vsz, rsz)) for vs, vsz, po, rsz, n in self.E.secs if n == '.text']

        def data_only(name, write):
            def guarded(a, v=None):
                if int(a) < 0x400000 or any(lo <= int(a) < hi for lo, hi in code):
                    raise AssertionError('%s wrote to the game image at %08X' % (name, int(a)))
                return write(a, v)
            return guarded
        c[b'writeInteger'] = data_only('writeInteger', lambda a, v: self.m.put32(int(a), int(v)))
        c[b'writeByte'] = data_only('writeByte', lambda a, v: self.m.write(int(a), bytes([int(v) & 0xFF])))
        c[b'writeBytes'] = data_only('writeBytes', self.write_bytes)
        c[b'writeSmallInteger'] = data_only('writeSmallInteger', lambda a, v: self.m.write(int(a), struct.pack('<H', int(v) & 0xFFFF)))
        c[b'writeString'] = data_only('writeString', lambda a, v: self.m.write(int(a), bytes(v)))
        c[b'writeCode'] = self.write_bytes
        c[b'writeCodeInteger'] = lambda a, v: (
            self.patched.append((int(a), struct.pack('<I', int(v) & MASK))),
            self.m.put32(int(a), int(v) & MASK))
        c[b'allocate'] = self.allocate
        c[b'allocateAssembly'] = self.allocate_assembly
        c[b'itob'] = lambda v: lua.table_from(list(struct.pack('<I', int(v) & MASK)))
        c[b'getRelativeAddress'] = lambda f, t, o=0: (int(t) - int(f) + int(o)) & MASK
        g[b'core'] = c
        self.aic = {}
        if aic:
            loader = lua.table()
            loader[b'setAdditionalAICValue'] = lambda self_, name, handler, reset: self.aic.__setitem__(name.decode(), (handler, reset))
            mods = lua.table(); mods[b'aicloader'] = loader
            g[b'modules'] = mods
        hk = lua.table()
        hk[b'registerHookCallback'] = lambda name, fn: self.after_init.append(fn)
        g[b'hooks'] = hk
        lua.execute(('package.path = [[%s\\?.lua;]] .. package.path' % MODULE).encode('mbcs'))
        if foreign_patches:
            # what improved-tunnelers, ui and ucp2-legacy do to the game before this module loads
            E = self.E
            tb = E.find('A1 ? ? ? ? 8B C8 69 C9 F4 39 00 00 39 99 ? ? ? ? 74 18 39 1D ?')[0] - 0x1B
            self.m.write(tb, b'\xE9\x00\x00\x00\x70\x90\x90\x90\x90')
            mi = E.find('8B 56 10 8B 46 4C 8B 4E 0C 52 8B 50 08 03 56 08 8B 40 04 03 46 04 51 52 50 B9')[0] - 0xA0
            self.m.write(mi + 6, b'\xE9\x00\x00\x00\x71\x90\x90\x90\x90')
            sd = E.find('83 EC 08 8B 44 24 0C 8B D0 69 D2 90 04 00 00')[0]
            self.ladder = sd + 9
            self.m.write(sd + 9, b'\xE9\x00\x00\x00\x72\x90')
            self.m.write(sd, bytes([0xE9,0,0,0,0x73,0x90,0x90]))   # smarter-buildings
        os.chdir(G)   # io.open('ucp/modules/...') relative to the game folder
        if pre is not None:
            pre(self)
        self.mod = lua.eval(b'dofile')((MODULE + r'\init.lua').encode('mbcs'))
        if isinstance(self.mod, tuple):     # init.lua may return (module, { public = ... })
            self.mod, self.public = self.mod[0], self.mod[1]
        self.mod[b'enable'](self.mod, self.to_lua(config or {}))

    def to_lua(self, value):
        if isinstance(value, dict):
            t = self.lua.table()
            for k, v in value.items():
                t[k.encode()] = self.to_lua(v)
            return t
        if isinstance(value, str):
            return value.encode()
        return value

    def image(self, base):
        E = self.E
        if base == 0x400000:
            return bytes(E.data[:4096])
        for vs, vsz, po, rsz, _ in E.secs:
            if vs <= base < vs + max(vsz, rsz):
                page = bytearray(4096)
                for i in range(4096):
                    va = base + i
                    if vs <= va < vs + rsz:
                        page[i] = E.data[po + va - vs]
                return bytes(page)
        return None

    def scan(self, pattern, *rest):
        """Scans the emulated memory (so earlier patches count), within the exe image."""
        pattern = pattern.decode('latin-1') if isinstance(pattern, bytes) else pattern
        hits = [h for h in self.E.find(pattern) if h is not None]
        if rest and rest[0] is not None:
            lo = int(rest[0]); hi = int(rest[1]) if len(rest) > 1 and rest[1] is not None else 0x7FFFFFFF
            hits = [h for h in hits if lo <= h <= hi]
        toks = pattern.split()
        good = []
        for h in hits:
            data = self.m.read(h, len(toks))
            if all(t == '?' or int(t, 16) == data[i] for i, t in enumerate(toks)):
                good.append(h)
        if not good:
            raise lupa.LuaError('AOBScan: no match ' + pattern)
        return good[0]

    def flatten(self, table):
        out = []

        def walk(t):
            for i in range(1, len(t) + 1):
                v = t[i]
                if lupa.lua_type(v) == 'table':
                    walk(v)
                else:
                    out.append(int(v) & 0xFF)
        walk(table)
        return bytes(out)

    def write_bytes(self, address, values, *rest):
        data = self.flatten(values)
        self.patched.append((int(address), data))
        self.m.write(int(address), data)

    def allocate(self, size, zero=None):
        a = self.heap
        self.heap = (self.heap + int(size) + 0x1F) & ~0xF
        self.m.write(a, b'\0' * int(size))
        return a

    def allocate_code(self, data):
        values = self.flatten(data)
        a = self.allocate(len(values))
        self.m.write(a, values)
        return a

    def detour(self, fn, address, size):
        address = int(address)

        def hook(cpu):
            regs = self.lua.table()
            fn(regs)
            cpu.eip = cpu.pop()
        self.cpu.hooks[address] = hook

    def allocate_assembly(self, script, values):
        script = script.decode('latin-1')
        values = {k.decode('latin-1'): int(v) & MASK for k, v in values.items()}
        size = len(fasm(ucp_source(script, values, 0)))
        a = self.allocate(size)
        code = fasm(ucp_source(script, values, a))
        assert len(code) == size
        self.m.write(a, code)
        self.scripts.append((a, script.strip().splitlines()[0]))
        return a

    def run(self, start, until=SENTINEL, regs=None, stack=(), limit=2_000_000):
        cpu = self.cpu
        cpu.r['esp'] = STACK_TOP
        for v in reversed(stack):
            cpu.push(int(v) & MASK)
        cpu.push(SENTINEL)
        for k, v in (regs or {}).items():
            cpu.r[k] = int(v) & MASK
        cpu.count = 0
        cpu.eip = start
        cpu.run(until, limit)
        return cpu

    def call_exposed(self, address, args):
        self.calls.append((address, args))
        fn = self.exposed.get(address)
        return fn(*args) if fn else 0

    def stub(self, address, result=0, ret_bytes=0, record=None):
        def hook(cpu):
            if record is not None:
                record.append((cpu.r['ecx'], [cpu.m.u32(cpu.r['esp'] + 4 + 4 * i) for i in range(5)]))
            cpu.r['eax'] = result & MASK
            cpu.eip = cpu.pop()
            cpu.r['esp'] = (cpu.r['esp'] + ret_bytes) & MASK
        self.cpu.hooks[address] = hook

    def u32(self, a):
        return self.m.u32(a)

    def u16(self, a):
        return struct.unpack('<H', self.m.read(a, 2))[0]

    def put32(self, a, v):
        self.m.put32(a, v & MASK)

    def put16(self, a, v):
        self.m.write(a, struct.pack('<H', v & 0xFFFF))

    def put8(self, a, v):
        self.m.write(a, bytes([v & 0xFF]))
