# navtest.ps1 - zx-vvv's links and history in the Fuse emulator.
#
# A scripted walk with canned modem replies, one per page request:
#   links.8tml, screen 3 -> focus a link (6), follow it (ENTER) -> blocks.8tml
#   -> B: back to links.8tml at screen 3 -> L, pick link 2 -> inline.8tml
#   -> B: back to links.8tml at screen 3 again -> R gets an error reply:
#   the page must stay exactly as it was.
# Each step is checked on the screen (title, status counter, focused link).
#
#   powershell -File apps/zx-vvv/host/navtest.ps1

$ErrorActionPreference = 'Stop'
$Root = (Resolve-Path "$PSScriptRoot\..\..\..").Path
$Build = "$Root\build"
$T = "$Root\apps\zx-vvv\testpages"
$Shot = "$Build\fusetest\nav.png"
New-Item -ItemType Directory -Force "$Build\fusetest" | Out-Null
. "$PSScriptRoot/fusectl.ps1"

$replies = @('info:HomeNet', "overlay:$Build\vvv.bin",
    "page:$T\links.8tml@https://test.example/site/links.8tml",
    "page:$T\blocks.8tml@https://test.example/site/part3a.8tml",
    "page:$T\links.8tml@https://test.example/site/links.8tml",
    "page:$T\inline.8tml@https://test.example/site/part1b.8tml",
    "page:$T\links.8tml@https://test.example/site/links.8tml",
    'httperr:3:Could not connect')
& python "$Root\host\tools\fake_reply.py" "$Build\zxmenu.tap" "$Build\navtest.tap" @replies
if ($LASTEXITCODE) { throw 'fake_reply failed' }

$script:bad = 0
function Screen { Save-FuseScreen $Shot; return @(& python "$Root\host\tools\zxscreen.py" $Shot) }
function Expect($what, $row, $pattern) {
    $line = (Screen)[$row]
    if ($line -match $pattern) { Write-Output "ok    $what  |$line|" }
    else { Write-Output "FAIL  $what  |$line|  (wanted /$pattern/)"; $script:bad++ }
}

Get-Process fuse -ErrorAction SilentlyContinue | Stop-Process
Start-FuseHidden "$Build\navtest.tap"
Start-Sleep -Seconds 20
Send-FuseKeyWait 0x31 | Out-Null; Wait-FusePage | Out-Null           # zx-vvv: links.8tml
Expect 'first page' 0 'Links everywh'
Send-FuseKeyWait 0x4E | Out-Null; Send-FuseKeyWait 0x4E | Out-Null    # N N: screen 3
Expect 'screen 3' 23 ' 3/\d+$'
Send-FuseKeyWait 0x36 | Out-Null                                      # 6: a link
Expect 'focused link shows its address' 23 '^part\d[abc]\.8tml|^\.\./up/'
Send-FuseKeyWait 0x0D | Out-Null; Wait-FusePage | Out-Null           # ENTER: follow
Expect 'followed' 0 'Blocks'
Send-FuseKeyWait 0x42 | Out-Null; Wait-FusePage | Out-Null           # B: back
Expect 'back' 0 'Links everywh'
Expect 'back at screen 3' 23 ' 3/\d+$'
Send-FuseKeyWait 0x4C | Out-Null                                      # L: the list
Expect 'link list' 0 '^ Links\s'
Expect 'list row 1' 2 '^  1 part1a\.8tml'
Send-FuseKeyWait 0x36 | Out-Null                                      # 6: link 2
Send-FuseKeyWait 0x0D | Out-Null; Wait-FusePage | Out-Null           # ENTER: follow
Expect 'followed from the list' 0 'Inline'
Send-FuseKeyWait 0x42 | Out-Null; Wait-FusePage | Out-Null           # B
Expect 'back again' 0 'Links everywh'
Expect 'still screen 3' 23 ' 3/\d+$'
$before = (Screen)[1..22] -join "`n"
Send-FuseKeyWait 0x52 | Out-Null; Wait-FusePage | Out-Null           # R: an error reply
Expect 'error shown' 23 '^Could not connect'
Expect 'page kept' 0 'Links everywh'
if (((Screen)[1..22] -join "`n") -eq $before) { Write-Output 'ok    page text unchanged after the error' }
else { Write-Output 'FAIL  page text changed after the error'; $script:bad++ }
Stop-Fuse
Write-Output $(if ($script:bad) { "$script:bad step(s) failed" } else { 'all steps pass' })
exit $script:bad
