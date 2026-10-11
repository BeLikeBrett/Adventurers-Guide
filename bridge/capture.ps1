# Captures the bottom-edge signal of the visible WoW client window and decodes the
# WoWAI pixel strip (see Codec.lua in the addon). Prints one JSON line per
# new message to stdout. Started by bridge.js; can also be run by hand.
#
#   capture.ps1 -TestImage strip.png    decode a PNG once and exit (used by tests)

param(
  [int]$Cell = 1,
  [int]$Cells = 512,
  [int]$MaxRows = 1,
  [int]$IntervalMs = 100,
  [string]$ProcessName = "WowB",
  [string]$Anchor = "bottom",
  [string]$TestImage = "",
  [string]$Screenshot = ""
)

$ErrorActionPreference = "Continue"
[Console]::OutputEncoding = [Text.Encoding]::UTF8
Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class CapWin {
  [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
  [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref POINT p);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X; public int Y; }
}
public class GuideStripFrame { public int id; public string text; }
public class GuideStripDecoder {
  public static GuideStripFrame Decode(System.Drawing.Bitmap bmp, int cells, int cell) {
    try {
      int[,] ramp=new int[3,16];
      for(int i=0;i<16;i++){var p=bmp.GetPixel(i*cell+cell/2,cell/2);ramp[0,i]=p.R;ramp[1,i]=p.G;ramp[2,i]=p.B;}
      int[,] map=new int[3,256];
      for(int c=0;c<3;c++){
        if(ramp[c,15]-ramp[c,0]<100)return null;
        for(int i=0;i<15;i++)if(ramp[c,i]>=ramp[c,i+1])return null;
        for(int v=0;v<256;v++){int best=0,distance=1000;for(int i=0;i<16;i++){int d=Math.Abs(v-ramp[c,i]);if(d<distance){best=i;distance=d;}}map[c,v]=best;}
      }
      var bytes=new System.Collections.Generic.List<byte>();int acc=0,bits=0,needed=6;
      for(int i=16;i<cells;i++){
        var p=bmp.GetPixel(i*cell+cell/2,cell/2);int v=map[0,p.R]*256+map[1,p.G]*16+map[2,p.B];acc=(acc<<12)|v;bits+=12;
        while(bits>=8){bits-=8;bytes.Add((byte)((acc>>bits)&255));acc&=(1<<bits)-1;
          if(bytes.Count==2&&(bytes[0]!=199||bytes[1]!=26))return null;
          if(bytes.Count==6){needed=8+bytes[4]*256+bytes[5];if(needed>728)return null;}
          if(bytes.Count>=needed)break;
        }
        if(needed>=8&&bytes.Count>=needed){
          int s1=0,s2=0;for(int k=2;k<needed-2;k++){s1=(s1+bytes[k])%255;s2=(s2+s1)%255;}
          if(bytes[needed-2]!=s1||bytes[needed-1]!=s2)return null;
          return new GuideStripFrame{id=bytes[2]*256+bytes[3],text=new System.Text.UTF8Encoding(false,true).GetString(bytes.GetRange(6,needed-8).ToArray())};
        }
      }
    }catch(ArgumentException){}
    return null;
  }
}
"@ -ReferencedAssemblies System.Drawing
[void][CapWin]::SetProcessDPIAware()

function Emit($obj) {
  [Console]::Out.WriteLine((ConvertTo-Json -Compress -InputObject $obj))
  [Console]::Out.Flush()
}

# Each channel is either fully on or off, so anything past mid-grey counts as on.
function CellValue($bmp, [int]$c, [int]$r) {
  $px = $bmp.GetPixel($c * $Cell + [int]($Cell / 2), $r * $Cell + [int]($Cell / 2))
  $v = 0
  if ($px.R -ge 128) { $v += 4 }
  if ($px.G -ge 128) { $v += 2 }
  if ($px.B -ge 128) { $v += 1 }
  return $v
}

function DecodeCompact($bmp) {
  return [GuideStripDecoder]::Decode($bmp, $Cells, $Cell)
}

function Decode($bmp) {
  if($Cells -eq 512 -and $MaxRows -eq 1){return DecodeCompact $bmp}
  $acc = 0; $nbits = 0
  $bytes = New-Object System.Collections.Generic.List[int]
  $needed = 6
  $total = $Cells * $MaxRows
  for ($i = 0; $i -lt $total; $i++) {
    $c = $i % $Cells
    $r = [int][Math]::Floor($i / $Cells)
    $v = CellValue $bmp $c $r
    $acc = ($acc -shl 3) -bor $v
    $nbits += 3
    while ($nbits -ge 8) {
      $b = ($acc -shr ($nbits - 8)) -band 0xFF
      $bytes.Add($b)
      $nbits -= 8
      $acc = $acc -band ((1 -shl $nbits) - 1)
      if ($bytes.Count -eq 2) {
        if ($bytes[0] -ne 0xC7 -or $bytes[1] -ne 0x1A) { return $null }
      }
      if ($bytes.Count -eq 6) {
        $len = ($bytes[4] * 256) + $bytes[5]
        $needed = 8 + $len
        if ($needed -gt [int]($total * 3 / 8)) { return @{ error = "length" } }
      }
      if ($bytes.Count -ge $needed) { break }
    }
    if ($bytes.Count -ge $needed) { break }
  }
  if ($bytes.Count -lt $needed) { return @{ error = "truncated" } }
  $len = ($bytes[4] * 256) + $bytes[5]
  $s1 = 0; $s2 = 0
  for ($k = 2; $k -lt (6 + $len); $k++) {
    $s1 = ($s1 + $bytes[$k]) % 255
    $s2 = ($s2 + $s1) % 255
  }
  if ($bytes[6 + $len] -ne $s1 -or $bytes[7 + $len] -ne $s2) { return @{ error = "checksum" } }
  $payload = New-Object byte[] $len
  for ($k = 0; $k -lt $len; $k++) { $payload[$k] = [byte]$bytes[6 + $k] }
  return @{ id = (($bytes[2] * 256) + $bytes[3]); text = [Text.Encoding]::UTF8.GetString($payload) }
}

if ($TestImage -ne "") {
  $bmp = [System.Drawing.Bitmap]::FromFile($TestImage)
  $msg = Decode $bmp
  $bmp.Dispose()
  if ($msg) { Emit $msg } else { Emit @{ error = "no valid strip in image" } }
  exit 0
}

if ($Screenshot -ne "") {
  $game = Get-Process $ProcessName -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
  if (-not $game -or [CapWin]::IsIconic($game.MainWindowHandle)) { Emit @{error="Open a visible WoW window first"}; exit 1 }
  $point=New-Object CapWin+POINT; $area=New-Object CapWin+RECT
  [void][CapWin]::ClientToScreen($game.MainWindowHandle,[ref]$point)
  [void][CapWin]::GetClientRect($game.MainWindowHandle,[ref]$area)
  $image=New-Object System.Drawing.Bitmap $area.Right,$area.Bottom
  $graphics=[System.Drawing.Graphics]::FromImage($image)
  try { $graphics.CopyFromScreen($point.X,$point.Y,0,0,$image.Size);$image.Save($Screenshot,[System.Drawing.Imaging.ImageFormat]::Png) }
  finally { $graphics.Dispose();$image.Dispose() }
  Emit @{path=$Screenshot};exit 0
}

$lastId = -1
$lastWarn = [DateTime]::MinValue
$proc = $null
$w = $Cells * $Cell
$h = $MaxRows * $Cell
while ($true) {
  if (-not $proc -or $proc.HasExited) {
    $proc = Get-Process $ProcessName -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
    if (-not $proc) {
      Emit @{ info = "waiting for $ProcessName window" }
      Start-Sleep -Seconds 3
      continue
    }
    Emit @{ info = "attached to '$($proc.MainWindowTitle)' (pid $($proc.Id))" }
  }
  $hwnd = $proc.MainWindowHandle
  if ([CapWin]::IsIconic($hwnd)) { Start-Sleep -Milliseconds 1000; continue }
  $pt = New-Object CapWin+POINT
  [void][CapWin]::ClientToScreen($hwnd, [ref]$pt)
  $rect = New-Object CapWin+RECT
  if ($Anchor -eq "bottom" -and [CapWin]::GetClientRect($hwnd, [ref]$rect)) { $pt.Y += [Math]::Max(0, $rect.Bottom - $h) }
  $bmp = New-Object System.Drawing.Bitmap $w, $h
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $ok = $true
  try { $g.CopyFromScreen($pt.X, $pt.Y, 0, 0, $bmp.Size) } catch { $ok = $false }
  $g.Dispose()
  if ($ok) {
    $msg = Decode $bmp
    if ($msg -and $msg.error) {
      # Magic matched but the frame didn't validate: say so, at most every 5 s.
      if (([DateTime]::Now - $lastWarn).TotalSeconds -ge 5) {
        $lastWarn = [DateTime]::Now
        Emit @{ warn = "strip seen but rejected: $($msg.error)" }
      }
    } elseif ($msg) {
      $key = "$($msg.id):$($msg.text)"
      if ($key -ne $lastId) {
        $lastId = $key
        Emit $msg
      }
    }
  }
  $bmp.Dispose()
  Start-Sleep -Milliseconds $IntervalMs
}
