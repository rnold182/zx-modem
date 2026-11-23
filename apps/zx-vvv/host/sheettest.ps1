# sheettest.ps1 - zx-vvv's page stylesheets in the Fuse emulator.
#
# Two pages, each with its own sheet (testpages/sheets/):
# style: comes before another header key, and the second sheet's address
# sorts after the first's (both broke this once). Walk:
#   sheet1 (+ site.8ss missing, z1.8ss: red)  -> red background
#   H -> sheet2 (z2.8ss: green)               -> green, on the first visit
#   R -> sheet2 again: its sheet is known, no new request. (The next
#        replies are pages too: a sheet fetched again would get a page,
#        no background, black. Fuse loads so fast that R, still held, can
#        reload twice, hence more than one.)
#
#   powershell -File apps/zx-vvv/host/sheettest.ps1

$ErrorActionPreference = 'Stop'
$Root = (Resolve-Path "$PSScriptRoot\..\..\..").Path
$Build = "$Root\build"
$S = "$Root\apps\zx-vvv\testpages\sheets"
$Shot = "$Build\fusetest\sheet.png"
New-Item -ItemType Directory -Force "$Build\fusetest" | Out-Null
. "$PSScriptRoot/fusectl.ps1"

$replies = @('info:HomeNet', "overlay:$Build\vvv.bin",
    "page:$S\sheet1.8tml@https://test.example/z/one.8tml", 'nosheet',
    "sheet:$S\z1.8ss@https://test.example/z/z1.8ss",
    "page:$S\sheet2.8tml@https://test.example/z/two.8tml",
    "sheet:$S\z2.8ss@https://test.example/z/z2.8ss",
    "page:$S\sheet2.8tml@https://test.example/z/two.8tml",
    "page:$S\sheet2.8tml@https://test.example/z/two.8tml",
    "page:$S\sheet2.8tml@https://test.example/z/two.8tml")
& python "$Root\host\tools\fake_reply.py" "$Build\zxmenu.tap" "$Build\sheettest.tap" @replies
if ($LASTEXITCODE) { throw 'fake_reply failed' }

$script:bad = 0
# The paper colour of an empty content cell, and the status line.
function Look {
    Save-FuseScreen $Shot
    $py = "import sys; sys.path.insert(0, r'$Root\host\tools'); import zxscreen as z; " +
          "f = z.load_font(z.DEFAULT_ROM); px = z.load(r'$Shot'); " +
          "print(z.read_cell_full(px, 10, 30, f)[2]); " +
          "print(''.join(z.read_cell(px, 23, c, f) for c in range(32)).rstrip())"
    return @(& python -c $py)
}
function Expect($what, $paper, $status) {
    $l = Look
    if ([int]$l[0] -eq $paper -and $l[1] -match $status) { Write-Output "ok    $what  (paper $($l[0]) |$($l[1])|)" }
    else { Write-Output "FAIL  $what  (paper $($l[0]) |$($l[1])|, wanted $paper /$status/)"; $script:bad++ }
}

Get-Process fuse -ErrorAction SilentlyContinue | Stop-Process
Start-FuseHidden "$Build\sheettest.tap"
Start-Sleep -Seconds 20
Send-FuseKeyWait 0x31 | Out-Null; Wait-FusePage | Out-Null           # zx-vvv: sheet1
Expect 'page one in its sheet (red)' 2 '^test\.example/z/one'
Send-FuseKeyWait 0x48 | Out-Null; Wait-FusePage | Out-Null           # H: sheet2
Expect 'page two in its sheet at once (green)' 4 '^test\.example/z/two'
Send-FuseKeyWait 0x52 | Out-Null; Wait-FusePage | Out-Null           # R
Expect 'reload: sheet kept, not fetched again' 4 '^test\.example/z/two'
Stop-Fuse
Write-Output $(if ($script:bad) { "$script:bad step(s) failed" } else { 'all steps pass' })
exit $script:bad
