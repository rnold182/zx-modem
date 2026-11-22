# fusetest.ps1 - zx-vvv's golden-file test in the Fuse emulator.
#
# Builds a tape: the ZX MODEM menu, an info reply, zx-vvv (as app 1 of the
# canned app list) and one canned http reply per test page. Fuse loads the
# browser (its home page request gets the first page), then H loads each
# next page. Every screen of every page is captured, read back as text
# (host/tools/zxscreen.py) and compared with the page's golden file.
#
#   powershell -File apps/zx-vvv/host/fusetest.ps1 [page names...]
# Needs Fuse in %LOCALAPPDATA%\Programs\fuse, Python with Pillow, a host
# build in build/ (vvv.bin, zxmenu.tap). Don't touch the keyboard while it runs.

param([string[]]$Pages, [string]$Dir)

$ErrorActionPreference = 'Stop'
$Root = (Resolve-Path "$PSScriptRoot\..\..\..").Path
$Build = "$Root\build"
$TestDir = if ($Dir) { (Resolve-Path $Dir).Path } else { "$Root\apps\zx-vvv\testpages" }
$Shots = "$Build\fusetest"
New-Item -ItemType Directory -Force $Shots | Out-Null
Get-ChildItem $Shots -Filter *.png | Remove-Item

if (-not $Pages) {
    $Pages = Get-ChildItem $TestDir -File | Where-Object { $_.Name -match '\.(8tml|txt)$' -and $_.Name -notmatch '\.(zx|expect)\.txt$' } |
        ForEach-Object { $_.Name }
}

Add-Type -AssemblyName System.Drawing
Add-Type @"
using System; using System.Runtime.InteropServices; using System.Threading;
public class FuseKeys {
 [StructLayout(LayoutKind.Sequential)] public struct R { public int L,T,Ri,B; }
 [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out R r);
 [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint f);
 [DllImport("user32.dll")] static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
 public static void Tap(byte vk){ keybd_event(vk,0,0,UIntPtr.Zero); Thread.Sleep(150); keybd_event(vk,0,2,UIntPtr.Zero); Thread.Sleep(200); } }
"@

function Snap($path) {
    $h = (Get-Process -Id $script:fuse.Id).MainWindowHandle; $r = New-Object FuseKeys+R
    [FuseKeys]::GetWindowRect($h, [ref]$r) | Out-Null
    $b = New-Object System.Drawing.Bitmap ($r.Ri - $r.L), ($r.B - $r.T)
    $g = [System.Drawing.Graphics]::FromImage($b); $dc = $g.GetHdc()
    [FuseKeys]::PrintWindow($h, $dc, 2) | Out-Null; $g.ReleaseHdc($dc)
    $c = $b.Clone((New-Object System.Drawing.Rectangle 8, 50, 640, 480), $b.PixelFormat)
    try { $c.Save($path, [System.Drawing.Imaging.ImageFormat]::Png) }
    catch { throw "capture failed: window $($r.L),$($r.T)-$($r.Ri),$($r.B) handle $h -> $path : $_" }
}
function Key($vk) {
    (New-Object -ComObject WScript.Shell).AppActivate($script:fuse.Id) | Out-Null
    Start-Sleep -Milliseconds 300
    [FuseKeys]::Tap([byte]$vk)
}
function Golden($page) {
    $base = "$TestDir\" + [IO.Path]::GetFileNameWithoutExtension($page)
    if (Test-Path "$base.expect.txt") { return "$base.expect.txt" }
    return "$base.zx.txt"
}
function ScreenCount($golden) {
    $lines = @(Get-Content $golden)
    $n = $lines.Count
    while ($n -gt 0 -and $lines[$n - 1] -eq '') { $n-- }
    return [Math]::Max(1, [Math]::Ceiling($n / 22))
}

# the tape
$replies = @('info:HomeNet', "overlay:$Build\vvv.bin")
foreach ($p in $Pages) { $replies += "page:$TestDir\$p@https://test.example/$p" }
& python "$Root\host\tools\fake_reply.py" "$Build\zxmenu.tap" "$Build\fusetest.tap" @replies
if ($LASTEXITCODE) { throw 'fake_reply failed' }

Get-Process fuse -ErrorAction SilentlyContinue | Stop-Process
$script:fuse = Start-Process "$env:LOCALAPPDATA\Programs\fuse\fuse.exe" -PassThru `
    -ArgumentList "--machine 48 --no-loading-sound --tape `"$Build\fusetest.tap`""
Start-Sleep -Seconds 20                 # LOAD "" and the menu
Key 0x31                                # 1: zx-vvv, which loads the first page
Start-Sleep -Seconds 14

$failed = 0
for ($i = 0; $i -lt $Pages.Count; $i++) {
    $p = $Pages[$i]
    if ($i -gt 0) { Key 0x48; Start-Sleep -Seconds 9 }     # H: the next canned page
    $golden = Golden $p
    $n = ScreenCount $golden
    $captures = @()
    for ($k = 1; $k -le $n; $k++) {
        if ($k -gt 1) { Key 0x4E; Start-Sleep -Milliseconds 2500 }   # N
        $shot = "$Shots\$([IO.Path]::GetFileNameWithoutExtension($p))-$k.png"
        Snap $shot
        $captures += $shot
    }
    & python "$Root\host\tools\zxscreen.py" --compare $golden @captures
    if ($LASTEXITCODE) { $failed++ }
}
Stop-Process $script:fuse
Write-Output "$($Pages.Count - $failed)/$($Pages.Count) pages match"
exit $failed
