# fusectl.ps1 - drive the Fuse emulator in the background, for tests.
#
# Fuse runs off-screen and never takes the keyboard focus: keys go to its
# window as messages (not as real key presses), and screens are captured
# with PrintWindow, which works for a window nobody can see. So tests can
# run while you use the PC.
#
#   . apps/zx-vvv/host/fusectl.ps1
#   Start-FuseHidden tape.tap; Send-FuseKey 0x31; Save-FuseScreen shot.png; Stop-Fuse

Add-Type -AssemblyName System.Drawing
Add-Type @"
using System; using System.Runtime.InteropServices; using System.Threading;
public class FuseCtl {
 [StructLayout(LayoutKind.Sequential)] public struct R { public int L,T,Ri,B; }
 [StructLayout(LayoutKind.Sequential)] public struct P { public int X,Y; }
 [StructLayout(LayoutKind.Sequential)] public struct WP { public int len, flags, show; public P min, max; public R normal; }
 [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out R r);
 [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint f);
 [DllImport("user32.dll")] public static extern bool SetWindowPlacement(IntPtr h, ref WP p);
 [DllImport("user32.dll")] public static extern bool GetWindowPlacement(IntPtr h, ref WP p);
 [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
 [DllImport("user32.dll")] public static extern uint MapVirtualKey(uint code, uint type);
 [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
 [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] public struct SI {
   public int cb; public string res, desk, title; public int x, y, xs, ys, xc, yc, fill, flags;
   public short show, res2; public IntPtr res3, hin, hout, herr; }
 [StructLayout(LayoutKind.Sequential)] public struct PI { public IntPtr hp, ht; public int pid, tid; }
 [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
 static extern bool CreateProcess(string app, string cmd, IntPtr pa, IntPtr ta, bool inherit, uint flags,
                                  IntPtr env, string dir, ref SI si, out PI pi);
 /* Starts a program with its window off-screen and not activated. */
 public static int StartHidden(string exe, string args) {
   SI si = new SI(); si.cb = Marshal.SizeOf(typeof(SI));
   si.flags = 0x1 | 0x4;                      /* STARTF_USESHOWWINDOW | STARTF_USEPOSITION */
   si.show = 4;                               /* SW_SHOWNOACTIVATE */
   si.x = -3000; si.y = -3000;
   PI pi;
   if (!CreateProcess(exe, "\"" + exe + "\" " + args, IntPtr.Zero, IntPtr.Zero, false, 0,
                      IntPtr.Zero, null, ref si, out pi))
     throw new Exception("CreateProcess failed: " + Marshal.GetLastWin32Error());
   return pi.pid; }
 public static void OffScreen(IntPtr h) {
   SetWindowPos(h, IntPtr.Zero, -3000, -3000, 0, 0, 0x0001 | 0x0004 | 0x0010); }  /* NOSIZE NOZORDER NOACTIVATE */
 public static void Key(IntPtr h, byte vk) {
   uint scan = MapVirtualKey(vk, 0);
   PostMessage(h, 0x100, (IntPtr)vk, (IntPtr)(1 | (scan << 16)));
   Thread.Sleep(150);
   PostMessage(h, 0x101, (IntPtr)vk, (IntPtr)unchecked((int)(1 | (scan << 16) | 0xC0000000)));
   Thread.Sleep(200); }
 /* A key with a modifier held: VK_SHIFT (0x10) is CAPS SHIFT, VK_CONTROL (0x11) SYMBOL SHIFT. */
 public static void Combo(IntPtr h, byte mod, byte vk) {
   uint ms = MapVirtualKey(mod, 0), scan = MapVirtualKey(vk, 0);
   PostMessage(h, 0x100, (IntPtr)mod, (IntPtr)(1 | (ms << 16)));
   Thread.Sleep(80);
   PostMessage(h, 0x100, (IntPtr)vk, (IntPtr)(1 | (scan << 16)));
   Thread.Sleep(150);
   PostMessage(h, 0x101, (IntPtr)vk, (IntPtr)unchecked((int)(1 | (scan << 16) | 0xC0000000)));
   Thread.Sleep(80);
   PostMessage(h, 0x101, (IntPtr)mod, (IntPtr)unchecked((int)(1 | (ms << 16) | 0xC0000000)));
   Thread.Sleep(200); } }
"@

function Start-FuseHidden($tap) {
    # A missing tape would make Fuse show an error box on the desktop.
    if (-not (Test-Path $tap)) { throw "no tape: $tap" }
    $id = [FuseCtl]::StartHidden("$env:LOCALAPPDATA\Programs\fuse\fuse.exe",
                                 "--machine 48 --no-loading-sound --tape `"$tap`"")
    $script:fuseProc = Get-Process -Id $id
    for ($i = 0; $i -lt 50; $i++) {
        Start-Sleep -Milliseconds 200
        $h = (Get-Process -Id $id).MainWindowHandle
        if ($h -ne [IntPtr]::Zero) { break }
    }
    $script:fuseWin = $h
    [FuseCtl]::OffScreen($h)                   # in case it ignored the start position
}

function Send-FuseKey($vk) { [FuseCtl]::Key($script:fuseWin, [byte]$vk) }
function Send-FuseCaps($vk) { [FuseCtl]::Combo($script:fuseWin, 0x10, [byte]$vk) }     # CAPS SHIFT + key
function Send-FuseSymbol($vk) { [FuseCtl]::Combo($script:fuseWin, 0x11, [byte]$vk) }   # SYMBOL SHIFT + key

# The Spectrum screen (with border), 640x480 at Fuse's 2x scale.
function Save-FuseScreen($path) {
    $h = $script:fuseWin; $r = New-Object FuseCtl+R
    for ($try = 0; $try -lt 5; $try++) {
        [FuseCtl]::GetWindowRect($h, [ref]$r) | Out-Null
        if (($r.Ri - $r.L) -ge 648 -and ($r.B - $r.T) -ge 530) { break }
        Start-Sleep -Milliseconds 300            # not drawn at full size yet
    }
    $b = New-Object System.Drawing.Bitmap ($r.Ri - $r.L), ($r.B - $r.T)
    $g = [System.Drawing.Graphics]::FromImage($b); $dc = $g.GetHdc()
    [FuseCtl]::PrintWindow($h, $dc, 2) | Out-Null; $g.ReleaseHdc($dc)
    $c = $b.Clone((New-Object System.Drawing.Rectangle 8, 50, 640, 480), $b.PixelFormat)
    $c.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
    $c.Dispose(); $g.Dispose(); $b.Dispose()     # GDI runs out on long runs otherwise
}

function Stop-Fuse { if ($script:fuseProc) { Stop-Process $script:fuseProc -ErrorAction SilentlyContinue } }

# ---- Waiting for the Spectrum instead of guessing how long it takes -------

$script:probe = Join-Path ([IO.Path]::GetTempPath()) "fuse-probe-$PID.png"
$script:zxscreen = Join-Path $PSScriptRoot '..\..\..\host\tools\zxscreen.py'

function Get-FuseHash {
    Save-FuseScreen $script:probe
    (Get-FileHash $script:probe -Algorithm MD5).Hash
}

# Wait until the screen stays the same for two looks in a row (a drawing
# has finished). Returns its hash.
function Wait-FuseStable($maxSec = 20) {
    $last = ''; $same = 0
    $end = (Get-Date).AddSeconds($maxSec)
    while ((Get-Date) -lt $end) {
        Start-Sleep -Milliseconds 400
        $h = Get-FuseHash
        if ($h -eq $last) { if (++$same -ge 2) { return $h } } else { $same = 0 }
        $last = $h
    }
    return $last
}

# Press a key and wait until the screen has changed and settled. A key
# the emulator missed (it can happen while it is busy) is sent again.
function Send-FuseKeyWait($vk, $maxSec = 15) {
    $before = Get-FuseHash
    for ($try = 0; $try -lt 3; $try++) {
        Send-FuseKey $vk
        $end = (Get-Date).AddSeconds($maxSec / 3)
        while ((Get-Date) -lt $end) {
            Start-Sleep -Milliseconds 300
            if ((Get-FuseHash) -ne $before) { Wait-FuseStable | Out-Null; return $true }
        }
    }
    return $false
}

# Wait until a page has loaded: row 23 no longer says "Loading" and the
# screen has settled.
function Wait-FusePage($maxSec = 90) {
    $end = (Get-Date).AddSeconds($maxSec)
    while ((Get-Date) -lt $end) {
        Start-Sleep -Milliseconds 700
        Save-FuseScreen $script:probe
        $status = (& python $script:zxscreen $script:probe | Select-Object -Index 23)
        if ($status -and $status -notmatch '^Loading') { Wait-FuseStable | Out-Null; return $true }
    }
    return $false
}
