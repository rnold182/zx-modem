# fusetest.ps1 - zx-vvv's golden-file test in the Fuse emulator.
#
# Builds a tape: the ZX MODEM menu, an info reply, zx-vvv (as app 1 of the
# canned app list) and one canned http reply per test page. Fuse loads the
# browser (its home page request gets the first page), then H loads each
# next page. For every page it checks:
#   - the text of every screen against <name>.zx.txt (or .expect.txt),
#   - every cell's colour and font against <name>.style.json,
#   - screen 1 with the first link focused (6) against <name>.sel.json,
#   - the L list against <name>.links.txt.
# Screens are read back by host/tools/zxscreen.py. golden.py and
# golden_style.py write the expected files.
#
#   powershell -File apps/zx-vvv/host/fusetest.ps1 [-Pages a.8tml,b.8tml] [-Dir folder]
# Needs Fuse in %LOCALAPPDATA%\Programs\fuse, Python with Pillow, a host
# build in build/ (vvv.bin, zxmenu.tap). Fuse runs off-screen and never takes
# the keyboard focus, so the PC stays usable while it runs.

param([string[]]$Pages, [string]$Dir)    # -Dir: pages (and goldens) from another folder

$ErrorActionPreference = 'Stop'
$Root = (Resolve-Path "$PSScriptRoot\..\..\..").Path
$Build = "$Root\build"
$TestDir = if ($Dir) { (Resolve-Path $Dir).Path } else { "$Root\apps\zx-vvv\testpages" }
$Shots = "$Build\fusetest"
$Py = "$Root\host\tools\zxscreen.py"
New-Item -ItemType Directory -Force $Shots | Out-Null
Get-ChildItem $Shots -Filter *.png | Remove-Item

if ($Pages.Count -eq 1 -and $Pages[0] -match ',') { $Pages = $Pages[0] -split ',' }
if (-not $Pages) {
    $Pages = Get-ChildItem $TestDir -File | Where-Object { $_.Name -match '\.(8tml|txt)$' -and $_.Name -notmatch '\.(zx|expect|links)\.txt$' } |
        ForEach-Object { $_.Name }
}

. "$PSScriptRoot/fusectl.ps1"          # Fuse off-screen, keys as window messages

function Golden($base) {
    if (Test-Path "$base.expect.txt") { return "$base.expect.txt" }
    return "$base.zx.txt"
}
function ScreenCount($golden) {
    $lines = @(Get-Content $golden)
    $n = $lines.Count
    while ($n -gt 0 -and $lines[$n - 1] -eq '') { $n-- }
    return [Math]::Max(1, [Math]::Ceiling($n / 22))
}
function Check($what) {
    & python $Py @what
    if ($LASTEXITCODE) { $script:failed++ }
    $script:checks++
}

# the tape
# zx-vvv asks for stylesheets after a page: the site's site.8ss once (all
# test pages are on one site), and the page's own style: sheet when it isn't
# the one it already has.
$replies = @('info:HomeNet', "overlay:$Build\vvv.bin")
$lastSheet = ''
for ($i = 0; $i -lt $Pages.Count; $i++) {
    $p = $Pages[$i]
    $replies += "page:$TestDir\$p@https://test.example/$p"
    if ($i -eq 0) {
        $replies += $(if (Test-Path "$TestDir\site.8ss") { "sheet:$TestDir\site.8ss" } else { 'nosheet' })
    }
    $sheet = ''
    $lines = @(Get-Content "$TestDir\$p")
    if ($lines.Count -gt 0 -and $lines[0].TrimEnd() -eq '---') {
        for ($k = 1; $k -lt $lines.Count -and $lines[$k].Trim() -ne '---'; $k++) {
            if ($lines[$k] -match '^\s*style\s*:\s*(.+?)\s*$') { $sheet = $Matches[1] }
        }
    }
    if ($sheet -and $sheet -ne $lastSheet) {
        $replies += $(if (Test-Path "$TestDir\$sheet") { "sheet:$TestDir\$sheet" } else { 'nosheet' })
        $lastSheet = $sheet
    }
}
& python "$Root\host\tools\fake_reply.py" "$Build\zxmenu.tap" "$Build\fusetest.tap" @replies
if ($LASTEXITCODE) { throw 'fake_reply failed' }

Get-Process fuse -ErrorAction SilentlyContinue | Stop-Process
Start-FuseHidden "$Build\fusetest.tap"
Start-Sleep -Seconds 20                 # LOAD "" and the menu
$script:failed = 0; $script:checks = 0
for ($i = 0; $i -lt $Pages.Count; $i++) {
    $p = $Pages[$i]
    $name = [IO.Path]::GetFileNameWithoutExtension($p)
    $base = "$TestDir\$name"
    # 1 starts zx-vvv (its home page request gets the first page); H the next
    Send-FuseKeyWait ($(if ($i -eq 0) { 0x31 } else { 0x48 })) | Out-Null
    if (-not (Wait-FusePage)) { Write-Output "${name}: the page never finished loading" }
    $golden = Golden $base
    $n = ScreenCount $golden
    $captures = @("$Shots\$name-1.png")
    Save-FuseScreen $captures[0]
    if (Test-Path "$base.sel.json") {           # 6: focus the first link
        Send-FuseKeyWait 0x36 | Out-Null
        Save-FuseScreen "$Shots\$name-sel.png"
        Check @('--compare-style', "$base.sel.json", "$Shots\$name-sel.png")
    }
    if ((Test-Path "$base.links.txt") -and (Get-Item "$base.links.txt").Length -gt 0) {
        Send-FuseKeyWait 0x4C | Out-Null      # L: the list of links
        Save-FuseScreen "$Shots\$name-links.png"
        Check @('--compare-links', "$base.links.txt", "$Shots\$name-links.png")
        Send-FuseKeyWait 0x4C | Out-Null      # and back
    }
    for ($k = 2; $k -le $n; $k++) {
        Send-FuseKeyWait 0x4E | Out-Null      # N
        $shot = "$Shots\$name-$k.png"
        Save-FuseScreen $shot
        $captures += $shot
    }
    Check (@('--compare', $golden) + $captures)
    if (Test-Path "$base.style.json") { Check (@('--compare-style', "$base.style.json") + $captures) }
}
Stop-Fuse
Write-Output "$($script:checks - $script:failed)/$($script:checks) checks pass ($($Pages.Count) pages)"
exit $script:failed
