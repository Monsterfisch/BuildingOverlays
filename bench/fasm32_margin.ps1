param([string]$dir)
$sig = @"
using System;
using System.Runtime.InteropServices;
public static class Fasm {
  [DllImport(@"H:\steam\steamapps\common\Stronghold Crusader Extreme UCP3 new\ucp\code\vendor\fasm\fasm.dll", CallingConvention=CallingConvention.StdCall, CharSet=CharSet.Ansi)]
  public static extern int fasm_Assemble(string source, IntPtr memory, int size, short passes, IntPtr displayPipe);
}
"@
Add-Type -TypeDefinition $sig
$size = 57600
$mem = [Runtime.InteropServices.Marshal]::AllocHGlobal($size)
foreach ($f in Get-ChildItem $dir -Filter *.asm) {
  $src = [IO.File]::ReadAllText($f.FullName)
  $r = [Fasm]::fasm_Assemble($src, $mem, $size, 100, [IntPtr]::Zero)
  $cond = [Runtime.InteropServices.Marshal]::ReadInt32($mem, 0)
  $base = [IO.Path]::ChangeExtension($f.FullName, $null)
  if ($cond -eq 0) {
    $len = [Runtime.InteropServices.Marshal]::ReadInt32($mem, 4)
    $ptr = [Runtime.InteropServices.Marshal]::ReadIntPtr($mem, 8)
    $bytes = New-Object byte[] $len
    [Runtime.InteropServices.Marshal]::Copy($ptr, $bytes, 0, $len)
    [IO.File]::WriteAllBytes($base + "bin", $bytes)
  } else {
    $code = [Runtime.InteropServices.Marshal]::ReadInt32($mem, 4)
    $line = [Runtime.InteropServices.Marshal]::ReadIntPtr($mem, 8)
    $lineNumber = -1
    if ($line -ne [IntPtr]::Zero) { $lineNumber = [Runtime.InteropServices.Marshal]::ReadInt32($line, 4) }
    [IO.File]::WriteAllText($base + "err", "condition=$cond error=$code line=$lineNumber")
  }
}
