import pefile, capstone, re, struct
G = r"H:\steam\steamapps\common\Stronghold Crusader Extreme UCP3 new"
class Exe:
    def __init__(self, path):
        pe = pefile.PE(path, fast_load=True); self.data = open(path,'rb').read()
        b = pe.OPTIONAL_HEADER.ImageBase
        self.secs = [(s.VirtualAddress+b, s.Misc_VirtualSize, s.PointerToRawData,
                      s.SizeOfRawData, s.Name.decode().strip('\x00')) for s in pe.sections]
        self.md = capstone.Cs(capstone.CS_ARCH_X86, capstone.CS_MODE_32); self.md.skipdata = True
    def va2off(self, va):
        for vs,vsz,po,rsz,_ in self.secs:
            if vs <= va < vs+max(vsz,rsz) and va-vs < rsz: return po+(va-vs)
    def off2va(self, o):
        for vs,vsz,po,rsz,_ in self.secs:
            if po <= o < po+rsz: return vs+(o-po)
    def dis(self, va, n=40):
        o = self.va2off(va)
        return "\n".join("%08X  %-22s %s %s" % (i.address, i.bytes.hex(' '), i.mnemonic, i.op_str)
                         for i in list(self.md.disasm(self.data[o:o+n*8], va))[:n])
    def ins(self, va, n=40):
        o = self.va2off(va); return list(self.md.disasm(self.data[o:o+n*8], va))[:n]
    def find(self, pat):
        rx = b''.join(b'.' if t=='?' else re.escape(bytes([int(t,16)])) for t in pat.split())
        return [self.off2va(m.start()) for m in re.finditer(rx, self.data, re.S)]
    def u32(self, va): return struct.unpack('<I', self.data[self.va2off(va):self.va2off(va)+4])[0]
    def i32(self, va): return struct.unpack('<i', self.data[self.va2off(va):self.va2off(va)+4])[0]
    def bytes_(self, va, n): o=self.va2off(va); return self.data[o:o+n]
    def callers(self, target):
        out = []
        for vs,vsz,po,rsz,n in self.secs:
            if n != '.text': continue
            d=self.data
            for m in re.finditer(b'\xE8', d[po:po+rsz]):
                i=po+m.start()
                rel = int.from_bytes(d[i+1:i+5],'little',signed=True)
                va = self.off2va(i)
                if va and va+5+rel == target: out.append(va)
        return out
    def refs(self, value):
        pat = struct.pack('<I', value)
        return [self.off2va(m.start()) for m in re.finditer(re.escape(pat), self.data)]
VAN = Exe(G + r"\Stronghold Crusader.exe")
EXT = Exe(G + r"\Stronghold_Crusader_Extreme.exe")
