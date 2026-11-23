# edittest.ps1 - zx-vvv's address field (G) in the Fuse emulator.
#
# Loads a page, presses G and checks the field: it starts with the page's
# address, CAPS+5 moves the cursor left, CAPS+0 deletes the character
# before it, a key inserts at the cursor, CAPS+3 clears, and ENTER loads
# what was typed (a bare host gets http:// and /index.8tml).
#
#   powershell -File apps/zx-vvv/host/edittest.ps1

$ErrorActionPreference = 'Stop'
$Root = (Resolve-Path "$PSScriptRoot\..\..\..").Path
$Build = "$Root\build"
$T = "$Root\apps\zx-vvv\testpages"
$Shot = "$Build\fusetest\edit.png"
New-Item -ItemType Directory -Force "$Build\fusetest" | Out-Null
. "$PSScriptRoot/fusectl.ps1"

$replies = @('info:HomeNet', "overlay:$Build\vvv.bin",
    "page:$T\links.8tml@https://test.example/site/links.8tml", 'nosheet',   # + site.8ss
    "page:$T\blocks.8tml@http://ab/index.8tml", 'nosheet')                  # (a new site)
& python "$Root\host\tools\fake_reply.py" "$Build\zxmenu.tap" "$Build\edittest.tap" @replies
if ($LASTEXITCODE) { throw 'fake_reply failed' }

$script:bad = 0
function Screen { Save-FuseScreen $Shot; return @(& python "$Root\host\tools\zxscreen.py" $Shot) }
function Field { $s = Screen; return ($s[20] + '|' + $s[21]) }
function Expect($what, $text, $pattern) {
    if ($text -match $pattern) { Write-Output "ok    $what  |$text|" }
    else { Write-Output "FAIL  $what  |$text|  (wanted /$pattern/)"; $script:bad++ }
}

Get-Process fuse -ErrorAction SilentlyContinue | Stop-Process
Start-FuseHidden "$Build\edittest.tap"
Start-Sleep -Seconds 20
Send-FuseKeyWait 0x31 | Out-Null; Wait-FusePage | Out-Null           # zx-vvv: the first page
Send-FuseKeyWait 0x47 | Out-Null                                      # G
Expect 'starts with the page address' (Field) '^https://test\.example/site/links\.\|?8tml'
Expect 'keys shown' ((Screen)[22]) 'ENTER go'
for ($i = 0; $i -lt 4; $i++) { Send-FuseCaps 0x35; Wait-FuseStable | Out-Null }   # CAPS+5 x4: before "8tml"
Send-FuseCaps 0x30; Wait-FuseStable | Out-Null                                     # CAPS+0: the '.' goes
Send-FuseKey 0x5A; Wait-FuseStable | Out-Null                      # z, inserted
Expect 'edited in the middle' (Field) 'linksz\|?8tml'          # (| = the field's row break)
Send-FuseCaps 0x33; Wait-FuseStable | Out-Null                     # CAPS+3: clear
Expect 'cleared' (Field) '^\s*\|\s*$'
# Long key runs go in batches of 10, letting the emulator catch up: a
# modifier pressed while it is busy can come through without its key.
for ($i = 0; $i -lt 70; $i++) {                                       # 70 digits: the field scrolls
    Send-FuseKey (0x30 + $i % 10)
    if ($i % 10 -eq 9) { Wait-FuseStable | Out-Null }
}
Wait-FuseStable | Out-Null
Expect 'scrolled to the cursor' (Field) '^7890123456'                 # chars 7-69, then the cursor
for ($i = 0; $i -lt 70; $i++) {                                       # back to the start
    Send-FuseCaps 0x35
    if ($i % 10 -eq 9) { Wait-FuseStable | Out-Null }
}
Wait-FuseStable | Out-Null
Expect 'scrolled back' (Field) '^0123456789'
Send-FuseCaps 0x33; Wait-FuseStable | Out-Null                     # clear again
Send-FuseKey 0x41; Send-FuseKey 0x42; Wait-FuseStable | Out-Null   # a b
Expect 'typed' (Field) '^ab'
Send-FuseKey 0x0D; Wait-FusePage | Out-Null                           # ENTER
Expect 'loaded what was typed' ((Screen)[0]) 'BLOCKS'
Expect 'its address' ((Screen)[23]) '^ab/index\.8tml'
Stop-Fuse
Write-Output $(if ($script:bad) { "$script:bad step(s) failed" } else { 'all steps pass' })
exit $script:bad
