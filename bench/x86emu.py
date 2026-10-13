"""A small 32 bit x86 interpreter, enough to run the game's line drawer and the module's
own assembly side by side and compare what they leave in memory."""
import struct
import capstone
from capstone import x86_const as X

MASK = 0xFFFFFFFF
PAGE = 12
PAGE_SIZE = 1 << PAGE


class Memory:
    def __init__(self, image=None):
        self.pages = {}
        self.image = image          # callable(page_base) -> bytes|None, for the exe
        self.write_log = None       # set to a list of (address, size) to trace writes

    def page(self, number):
        p = self.pages.get(number)
        if p is None:
            data = self.image(number << PAGE) if self.image else None
            p = bytearray(data) if data is not None else bytearray(PAGE_SIZE)
            self.pages[number] = p
        return p

    def read(self, address, size):
        address &= MASK
        out = bytearray()
        while size:
            number, offset = address >> PAGE, address & (PAGE_SIZE - 1)
            take = min(size, PAGE_SIZE - offset)
            out += self.page(number)[offset:offset + take]
            address, size = address + take, size - take
        return bytes(out)

    def write(self, address, data):
        address &= MASK
        if self.write_log is not None:
            self.write_log.append((address, len(data)))
        view = memoryview(bytes(data))
        while view:
            number, offset = address >> PAGE, address & (PAGE_SIZE - 1)
            take = min(len(view), PAGE_SIZE - offset)
            self.page(number)[offset:offset + take] = view[:take]
            address, view = address + take, view[take:]

    def u32(self, a):
        return struct.unpack('<I', self.read(a, 4))[0]

    def s32(self, a):
        return struct.unpack('<i', self.read(a, 4))[0]

    def put32(self, a, v):
        self.write(a, struct.pack('<I', v & MASK))


REG32 = ['eax', 'ecx', 'edx', 'ebx', 'esp', 'ebp', 'esi', 'edi']
SUB = {}
for i, r in enumerate(REG32):
    SUB[r] = (r, 0, 32)
for r16, r32 in zip(['ax', 'cx', 'dx', 'bx', 'sp', 'bp', 'si', 'di'], REG32):
    SUB[r16] = (r32, 0, 16)
for r8, r32 in zip(['al', 'cl', 'dl', 'bl'], REG32[:4]):
    SUB[r8] = (r32, 0, 8)
for r8, r32 in zip(['ah', 'ch', 'dh', 'bh'], REG32[:4]):
    SUB[r8] = (r32, 8, 8)


class Halt(Exception):
    pass


class CPU:
    def __init__(self, memory):
        self.m = memory
        self.r = {k: 0 for k in REG32}
        self.eip = 0
        self.cf = self.zf = self.sf = self.of = False
        self.cs = capstone.Cs(capstone.CS_ARCH_X86, capstone.CS_MODE_32)
        self.cs.detail = True
        self.cache = {}
        self.regnames = {}
        self.hooks = {}          # address -> fn(cpu), run before the instruction there
        self.count = 0

    # ---- operands
    def reg_get(self, name):
        base, shift, bits = SUB[name]
        return (self.r[base] >> shift) & ((1 << bits) - 1)

    def reg_set(self, name, value):
        base, shift, bits = SUB[name]
        mask = ((1 << bits) - 1) << shift
        self.r[base] = (self.r[base] & ~mask & MASK) | ((value << shift) & mask)

    def rn(self, insn, reg):
        name = self.regnames.get(reg)
        if name is None:
            name = self.regnames[reg] = insn.reg_name(reg)
        return name

    def ea(self, insn, op):
        mem = op.mem
        address = mem.disp
        if mem.base:
            address += self.r[SUB[self.rn(insn, mem.base)][0]]
        if mem.index:
            address += self.r[SUB[self.rn(insn, mem.index)][0]] * mem.scale
        return address & MASK

    def get(self, insn, op, size=None):
        size = size or op.size
        if op.type == X.X86_OP_REG:
            return self.reg_get(self.rn(insn, op.reg))
        if op.type == X.X86_OP_IMM:
            return op.imm & ((1 << (size * 8)) - 1)
        return int.from_bytes(self.m.read(self.ea(insn, op), size), 'little')

    def set(self, insn, op, value, size=None):
        size = size or op.size
        value &= (1 << (size * 8)) - 1
        if op.type == X.X86_OP_REG:
            self.reg_set(self.rn(insn, op.reg), value)
        else:
            self.m.write(self.ea(insn, op), value.to_bytes(size, 'little'))

    def push(self, value):
        self.r['esp'] = (self.r['esp'] - 4) & MASK
        self.m.put32(self.r['esp'], value)

    def pop(self):
        value = self.m.u32(self.r['esp'])
        self.r['esp'] = (self.r['esp'] + 4) & MASK
        return value

    # ---- flags
    def logic_flags(self, result, bits):
        result &= (1 << bits) - 1
        self.zf = result == 0
        self.sf = bool(result >> (bits - 1))
        self.cf = self.of = False

    def add_flags(self, a, b, bits):
        mask = (1 << bits) - 1
        full = a + b
        result = full & mask
        sign = 1 << (bits - 1)
        self.cf = full > mask
        self.of = ((a ^ result) & (b ^ result) & sign) != 0
        self.zf = result == 0
        self.sf = bool(result & sign)
        return result

    def sub_flags(self, a, b, bits):
        mask = (1 << bits) - 1
        result = (a - b) & mask
        sign = 1 << (bits - 1)
        self.cf = a < b
        self.of = ((a ^ b) & (a ^ result) & sign) != 0
        self.zf = result == 0
        self.sf = bool(result & sign)
        return result

    def cond(self, cc):
        return {
            'e': self.zf, 'z': self.zf, 'ne': not self.zf, 'nz': not self.zf,
            'l': self.sf != self.of, 'ge': self.sf == self.of,
            'le': self.zf or self.sf != self.of, 'g': not self.zf and self.sf == self.of,
            'b': self.cf, 'ae': not self.cf, 'be': self.cf or self.zf,
            'a': not self.cf and not self.zf, 's': self.sf, 'ns': not self.sf,
        }[cc]

    # ---- execution
    def decode(self, address):
        entry = self.cache.get(address)
        if entry is None:
            code = self.m.read(address, 16)
            insn = next(self.cs.disasm(code, address, 1))
            entry = (insn, insn.mnemonic, list(insn.operands), insn.size)
            self.cache[address] = entry
        return entry

    def run(self, until, limit=200_000_000):
        while self.eip != until:
            hook = self.hooks.get(self.eip)
            if hook:
                hook(self)
            self.step()
            if self.count > limit:
                raise Halt('instruction limit')

    def step(self):
        insn, mn, ops, size_ = self.decode(self.eip)
        self.count += 1
        nxt = (self.eip + size_) & MASK
        self.eip = nxt

        if mn == 'mov':
            self.set(insn, ops[0], self.get(insn, ops[1], ops[0].size))
        elif mn == 'movzx':
            self.set(insn, ops[0], self.get(insn, ops[1]))
        elif mn == 'movsx':
            bits = ops[1].size * 8
            v = self.get(insn, ops[1])
            if v >> (bits - 1):
                v -= 1 << bits
            self.set(insn, ops[0], v)
        elif mn == 'lea':
            self.set(insn, ops[0], self.ea(insn, ops[1]))
        elif mn == 'push':
            self.push(self.get(insn, ops[0], 4) if ops[0].type != X.X86_OP_IMM
                      else ops[0].imm & MASK)
        elif mn == 'pop':
            self.set(insn, ops[0], self.pop(), 4)
        elif mn == 'pushal':
            esp = self.r['esp']
            for name in REG32:
                self.push(esp if name == 'esp' else self.r[name])
        elif mn == 'popal':
            for name in reversed(REG32):
                v = self.pop()
                if name != 'esp':
                    self.r[name] = v
        elif mn == 'pushfd':
            self.push(int(self.cf) | int(self.zf) << 6 | int(self.sf) << 7 | int(self.of) << 11)
        elif mn == 'popfd':
            v = self.pop()
            self.cf, self.zf, self.sf, self.of = bool(v & 1), bool(v >> 6 & 1), bool(v >> 7 & 1), bool(v >> 11 & 1)
        elif mn in ('add', 'sub', 'cmp', 'and', 'or', 'xor', 'test'):
            size = ops[0].size
            bits = size * 8
            a = self.get(insn, ops[0])
            b = self.get(insn, ops[1], size)
            if ops[1].type == X.X86_OP_IMM:
                b = ops[1].imm & ((1 << bits) - 1)
            if mn == 'add':
                self.set(insn, ops[0], self.add_flags(a, b, bits))
            elif mn == 'sub':
                self.set(insn, ops[0], self.sub_flags(a, b, bits))
            elif mn == 'cmp':
                self.sub_flags(a, b, bits)
            else:
                v = a & b if mn in ('and', 'test') else (a | b if mn == 'or' else a ^ b)
                self.logic_flags(v, bits)
                if mn != 'test':
                    self.set(insn, ops[0], v)
        elif mn == 'neg':
            bits = ops[0].size * 8
            a = self.get(insn, ops[0])
            self.set(insn, ops[0], self.sub_flags(0, a, bits))
            self.cf = a != 0
        elif mn == 'not':
            self.set(insn, ops[0], ~self.get(insn, ops[0]))
        elif mn in ('inc', 'dec'):
            bits = ops[0].size * 8
            cf = self.cf
            a = self.get(insn, ops[0])
            r = self.add_flags(a, 1, bits) if mn == 'inc' else self.sub_flags(a, 1, bits)
            self.cf = cf
            self.set(insn, ops[0], r)
        elif mn in ('shl', 'shr', 'sar'):
            bits = ops[0].size * 8
            a = self.get(insn, ops[0])
            n = (self.get(insn, ops[1], 1) if len(ops) > 1 else 1) & 31
            if n:
                if mn == 'shl':
                    r = (a << n) & ((1 << bits) - 1)
                    self.cf = bool((a >> (bits - n)) & 1)
                elif mn == 'shr':
                    r = a >> n
                    self.cf = bool((a >> (n - 1)) & 1)
                else:
                    sa = a - (1 << bits) if a >> (bits - 1) else a
                    r = (sa >> n) & ((1 << bits) - 1)
                    self.cf = bool((sa >> (n - 1)) & 1)
                self.logic_flags(r, bits)
                self.set(insn, ops[0], r)
        elif mn == 'imul':
            bits = ops[0].size * 8
            def signed(v):
                return v - (1 << bits) if v >> (bits - 1) else v
            if len(ops) == 3:
                a, b = signed(self.get(insn, ops[1])), ops[2].imm
            elif len(ops) == 2:
                a, b = signed(self.get(insn, ops[0])), signed(self.get(insn, ops[1]))
            else:
                raise Halt('one operand imul unsupported')
            full = a * b
            r = full & ((1 << bits) - 1)
            self.cf = self.of = signed(r) != full
            self.set(insn, ops[0], r)
        elif mn == 'mul':
            v = self.get(insn, ops[0]) * self.r['eax']
            self.r['eax'], self.r['edx'] = v & MASK, (v >> 32) & MASK
            self.cf = self.of = self.r['edx'] != 0
        elif mn == 'cdq':
            self.r['edx'] = MASK if self.r['eax'] >> 31 else 0
        elif mn == 'idiv':
            d = self.get(insn, ops[0])
            d = d - (1 << 32) if d >> 31 else d
            n = (self.r['edx'] << 32) | self.r['eax']
            n = n - (1 << 64) if n >> 63 else n
            q = abs(n) // abs(d) * (1 if (n < 0) == (d < 0) else -1)
            self.r['eax'], self.r['edx'] = q & MASK, (n - q * d) & MASK
        elif mn == 'xchg':
            a, b = self.get(insn, ops[0]), self.get(insn, ops[1])
            self.set(insn, ops[0], b)
            self.set(insn, ops[1], a)
        elif mn.startswith('set'):
            self.set(insn, ops[0], int(self.cond(mn[3:])))
        elif mn == 'jmp':
            self.eip = self.get(insn, ops[0], 4) if ops[0].type != X.X86_OP_IMM else ops[0].imm & MASK
        elif mn.startswith('j'):
            if self.cond(mn[1:]):
                self.eip = ops[0].imm & MASK
        elif mn == 'call':
            target = ops[0].imm & MASK if ops[0].type == X.X86_OP_IMM else self.get(insn, ops[0], 4)
            self.push(nxt)
            self.eip = target
        elif mn == 'ret':
            self.eip = self.pop()
            if ops:
                self.r['esp'] = (self.r['esp'] + ops[0].imm) & MASK
        elif mn == 'nop':
            pass
        else:
            raise Halt('unsupported %s %s at %08X' % (mn, insn.op_str, insn.address))
