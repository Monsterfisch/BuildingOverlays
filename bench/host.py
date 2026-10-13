"""Run a resource-grid-overlay build inside lupa with core mocked onto an emulated 32 bit
address space, so its assembly and the game's own drawing code really execute."""
import re, struct, hashlib, sys
import lupa, keystone
sys.path.insert(0, r'C:\Users\MONSTE~1\AppData\Local\Temp\shcw')
sys.path.insert(0, r'C:\Users\MONSTE~1\AppData\Local\Temp\shcw\perf')
from shc import Exe, G
from x86emu import Memory, CPU, MASK

VAN_PATH = G + r"\Stronghold Crusader.exe"
EXT_PATH = G + r"\Stronghold_Crusader_Extreme.exe"
_EXES = {}


def exe(path):
    if path not in _EXES:
        _EXES[path] = Exe(path)
    return _EXES[path]


P = {
    'gm': "83 3D ? ? ? ? 01 75 0D 6A 04 B9 ? ? ? ? E8 ? ? ? ? C3",
    'key': "8B 74 24 64 8D 46 F3 3D D1 00 00 00 BD 01 00 00 00 89 2D ? ? ? ? 0F 87 ? ? ? ? 0F B6 80 ? ? ? ? FF 24 85 ? ? ? ?",
    'rnd': "89 2D ? ? ? ? E8 ? ? ? ? E8 ? ? ? ? A1 ? ? ? ? 8B 0D ? ? ? ? 50 51 B9 ? ? ? ? E8 ? ? ? ?",
    'sc': "83 FD 17 56 8B F1 75 05 BD 29 00 00 00 8B 44 24 10 53 57 89 6E 18",
    'vkey': "6A 03 B9 ? ? ? ? E8 ? ? ? ? 89 2D ? ? ? ? E9",
    'flat': "39 3D ? ? ? ? 74 10 39 3D ? ? ? ? 74 08 C7 44 24 24 01 00 00 00",
    'orient': "A1 ? ? ? ? 85 C0 53 55 56 57 8B E9 BF 08 00 00 00 74 22 83 F8 06 75 07 BF 18 3A 01 00 EB 16 83 F8 04 75 07 BF 28 74 02 00",
    'surf': "8B 41 0C 85 C0 8B 15 ? ? ? ? 75 06 8B 15 ? ? ? ? 85 C0 89 51 04 74 08 C7 41 08 B0 1F 00 00",
    'clip': "A1 ? ? ? ? 2B 05 ? ? ? ? 03 05 ? ? ? ? 3B 05 ? ? ? ? 89 45 FC 0F 8D ? ? ? ? 3B 05 ? ? ? ?",
}

SURFACE = 0x40000000
SURFACE_BYTES = 4056 * 2 * 4056
HEAP = 0x60000000
STACK_TOP = 0x70100000
SENTINEL = 0x7FFFFFF0

KS = keystone.Ks(keystone.KS_ARCH_X86, keystone.KS_MODE_32)


def fasm_to_keystone(script, values):
    """What core.assemble feeds FASM, turned into something keystone reads the same way."""
    lines = []
    for line in script.split('\n'):
        line = line.split(';', 1)[0].rstrip()
        if line.strip():
            lines.append(line)
    text = '\n'.join(lines)
    # constants: longest names first so a prefix never eats a longer name
    for name in sorted(values, key=len, reverse=True):
        text = re.sub(r'\b%s\b' % re.escape(name), '0x%X' % (values[name] & MASK), text)
    text = re.sub(r'\b(dword|word|byte) \[', r'\1 ptr [', text)
    return text


USE_FASM = True
FASM_SCRIPT = 'fasm32_margin.ps1'   # UCP's real buffer is 64000 bytes; the bench
                                    # gives a script 57600, so anything that passes
                                    # here has a tenth of the buffer to spare in the
                                    # game. A script that outgrows it fails inside
                                    # enable(), and the game never starts.
PERF_DIR = r'C:\Users\MONSTE~1\AppData\Local\Temp\shcw\perf'
FASM_CACHE = PERF_DIR + r'\fasm_cache'
POWERSHELL32 = r'C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe'


def ucp_source(script, values, origin):
    """The exact text core.assemble hands FASM."""
    for k, v in values.items():
        script = k + " = " + "0x%X" % v + "\n" + script
    script = "org " + "0x%X" % origin + "\n" + script
    return "use32" + "\n" + script


def fasm(source):
    import os, subprocess, tempfile
    os.makedirs(FASM_CACHE, exist_ok=True)
    digest = hashlib.sha1((FASM_SCRIPT + source).encode('ascii')).hexdigest()
    binary = os.path.join(FASM_CACHE, digest + '.bin')
    if not os.path.exists(binary):
        work = tempfile.mkdtemp(dir=FASM_CACHE)
        with open(os.path.join(work, digest + '.asm'), 'w', newline='\n') as f:
            f.write(source)
        subprocess.run([POWERSHELL32, '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
                        PERF_DIR + '\\' + FASM_SCRIPT, '-dir', work],
                       check=True, capture_output=True)
        produced = os.path.join(work, digest + '.bin')
        if not os.path.exists(produced):
            error = open(os.path.join(work, digest + '.err')).read()
            line = int(error.rsplit('=', 1)[1])
            text = source.split('\n')
            raise AssertionError('FASM: %s: %r' % (
                error, text[line - 1] if 0 < line <= len(text) else '?'))
        os.replace(produced, binary)
    return open(binary, 'rb').read()


class Host:
    def __init__(self, module_dir, exe_path, runtime=None, overlay=None, tune=None):
        self.E = E = exe(exe_path)
        self.m = Memory(self.image)
        self.cpu = CPU(self.m)
        self.heap = HEAP
        self.logs = []
        self.detours = {}
        self.exposed_calls = 0
        self.lua_calls = 0
        self.assembled = []

        rd = lambda va: struct.unpack('<I', E.data[E.va2off(va):E.va2off(va) + 4])[0]
        self.renderSite = E.find(P['rnd'])[0]
        self.keySite = E.find(P['key'])[0] + 36
        self.screenSite = E.find(P['sc'])[0]
        self.viewport = rd(self.renderSite + 30)
        self.gameMode = rd(E.find(P['gm'])[0] + 2)
        self.orientation = rd(E.find(P['orient'])[0] + 1)
        flat = E.find(P['flat'])[0]
        self.flattenA, self.flattenB = rd(flat + 2), rd(flat + 10)
        self.viewFlag = rd(E.find(P['vkey'])[0] + 3) + 0x5548C4
        self.surfacePointer = rd(E.find(P['surf'])[0] + 7)
        self.windowStruct = self.surfacePointer - 0xD8
        clip = E.find(P['clip'])[0]
        self.clipTop, self.clipBottom = rd(clip + 34), rd(clip + 19)

        defaults = {
            'view+78': 3200, 'view+7c': 800, 'view+88': 37, 'view+8c': 84,
            'view+90': 0, 'view+94': 0, 'win+54': 0x555, 'orient': 0,
            'flatA': 1, 'flatB': 1, 'vflag': 1, 'gm': 1,
        }
        defaults.update(runtime or {})
        for key, value in defaults.items():
            self.put(key, value)
        self.m.put32(self.surfacePointer, SURFACE)
        self.m.put32(self.clipTop, 8)
        self.m.put32(self.clipBottom, 1200)

        lua = self.lua = lupa.LuaRuntime(unpack_returned_tuples=True)
        g = lua.globals()
        g.INFO, g.WARNING, g.ERROR = 'INFO', 'WARNING', 'ERROR'
        g.log = lambda level, message: self.logs.append('%s: %s' % (level, message))
        c = lua.table()
        c.AOBScan = self.scan
        c.readInteger = lambda a: self.m.s32(int(a))
        c.writeInteger = lambda a, v: self.m.put32(int(a), int(v))
        c.readByte = lambda a: self.m.read(int(a), 1)[0]
        c.readBytes = lambda a, n: lua.table_from(list(self.m.read(int(a), int(n))))
        c.writeBytes = lambda a, t: self.m.write(int(a), bytes(int(t[i + 1]) & 0xFF for i in range(len(t))))
        c.writeCodeBytes = c.writeBytes
        c.allocate = self.allocate
        c.allocateCode = self.allocate_code
        c.allocateAssembly = self.allocate_assembly
        c.exposeCode = self.expose
        c.detourCode = self.detour
        g.core = c
        self.core = c
        self.mod = lua.eval('dofile')(module_dir + r'\init.lua')
        self.mod.enable(self.mod, lua.table_from({
            'overlay': lua.table_from(overlay or {}),
            'tune': lua.table_from(tune or {})}))

    # ---- runtime values
    def address_of(self, key):
        named = {'orient': self.orientation, 'flatA': self.flattenA, 'flatB': self.flattenB,
                 'vflag': self.viewFlag, 'gm': self.gameMode}
        if key in named:
            return named[key]
        base, off = key.split('+')
        return (self.viewport if base == 'view' else self.windowStruct) + int(off, 16)

    def put(self, key, value):
        self.m.put32(self.address_of(key), value)

    def image(self, base):
        E = self.E
        for vs, vsz, po, rsz, _ in E.secs:
            if vs <= base < vs + max(vsz, rsz):
                page = bytearray(4096)
                for i in range(4096):
                    va = base + i
                    if vs <= va < vs + rsz:
                        page[i] = E.data[po + va - vs]
                return bytes(page)
        return None

    # ---- core mocks
    def scan(self, pattern):
        hits = self.E.find(pattern)
        if len(hits) != 1:
            raise lupa.LuaError('AOBScan: %d matches' % len(hits))
        return hits[0]

    def allocate(self, size, zero=None):
        address = self.heap
        self.heap = (self.heap + int(size) + 0x1F) & ~0xF
        return address

    def allocate_code(self, data):
        if isinstance(data, (int, float)):
            return self.allocate(int(data))
        values = [int(data[i + 1]) & 0xFF for i in range(len(data))]
        address = self.allocate(len(values))
        self.m.write(address, bytes(values))
        return address

    def allocate_assembly(self, script, values):
        """core.allocateAssembly, assembled by UCP's own fasm.dll: once at origin 0 for the
        size, then again at the address it lands on."""
        values = {k: int(v) for k, v in values.items()}
        if USE_FASM:
            size = len(fasm(ucp_source(script, values, 0)))
            address = self.allocate(size)
            code = fasm(ucp_source(script, values, address))
            if len(code) != size:
                raise AssertionError('fasm size differs between passes')
        else:
            address = self.allocate(0x4000)
            code, _ = KS.asm(fasm_to_keystone(script, values), address)
            code = bytes(code)
            self.heap = address + len(code) + 0x20
        self.m.write(address, code)
        self.assembled.append((address, code))
        return address

    def expose(self, address, count, convention):
        address, count = int(address), int(count)

        def call(*args):
            self.exposed_calls += 1
            cpu = self.cpu
            cpu.r['esp'] = STACK_TOP
            for value in reversed(args[:count]):
                cpu.push(int(value) & MASK)
            cpu.push(SENTINEL)
            cpu.eip = address
            cpu.run(SENTINEL)
            eax = cpu.r['eax']
            return eax - (1 << 32) if eax >> 31 else eax
        return call

    def detour(self, fn, address, size):
        address = int(address)
        self.detours[address] = fn
        if address >= HEAP:
            def hook(cpu):
                self.lua_calls += 1
                regs = self.lua.table_from({k.upper(): v for k, v in cpu.r.items()})
                out = fn(regs)
                for k in cpu.r:
                    cpu.r[k] = int(out[k.upper()]) & MASK
            self.cpu.hooks[address] = hook

    # ---- driving
    def regs(self, esi=0x47, ecx=0, ebp=0x0C):
        return self.lua.table_from({'ESI': esi, 'ECX': ecx, 'EBP': ebp, 'EAX': 0, 'EBX': 0,
                                    'EDX': 0, 'EDI': 0, 'ESP': STACK_TOP})

    def press(self, esi=0x47, ecx=0):
        self.detours[self.keySite](self.regs(esi, ecx))

    def screen(self, ebp):
        self.detours[self.screenSite](self.regs(ebp=ebp))

    def frame(self):
        """One pass through the render call site. Returns executed instruction count."""
        site = self.renderSite + 16
        before = self.cpu.count
        if site in self.detours:                        # 1.0.0: a lua detour
            self.lua_calls += 1
            self.detours[site](self.regs())
        else:                                           # 1.1.0: jumps into assembly
            cpu = self.cpu
            regs = {'eax': 0x11111111, 'ecx': 0x22222222, 'edx': 0x33333333,
                    'ebx': 0x44444444, 'esp': STACK_TOP, 'ebp': 0x55555555,
                    'esi': 0x66666666, 'edi': 0x77777777}
            cpu.r.update(regs)
            cpu.eip = site
            cpu.run(site + 5)
            expected = dict(regs)
            original_operand = struct.unpack('<I', self.E.data[self.E.va2off(site + 1):self.E.va2off(site + 1) + 4])[0]
            expected['eax'] = self.m.u32(original_operand)
            if cpu.r != expected:
                raise AssertionError('registers not preserved: %r vs %r' % (cpu.r, expected))
        return self.cpu.count - before

    def surface_digest(self):
        h = hashlib.sha1()
        first, last = SURFACE >> 12, (SURFACE + SURFACE_BYTES) >> 12
        painted = 0
        for number in sorted(self.m.pages):
            if first <= number <= last:
                page = self.m.pages[number]
                if any(page):
                    h.update(struct.pack('<I', number))
                    h.update(page)
                    painted += sum(1 for i in range(0, 4096, 2) if page[i] or page[i + 1])
        return h.hexdigest(), painted

    def clear_surface(self):
        first, last = SURFACE >> 12, (SURFACE + SURFACE_BYTES) >> 12
        for number in [n for n in self.m.pages if first <= n <= last]:
            del self.m.pages[number]
