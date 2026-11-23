# fuzztest.ps1 - zx-vvv's robustness tests (M6): its real Z80 code, run in
# an emulated 48K by zxfuzz (apps/zx-vvv/host/fuzz/), no Fuse needed.
#
#   1. Every test page (hostile ones too) with 10 scripted sessions each:
#      keys, page loads, errors, broken replies; no crash, hang or stray write.
#   2. Fuzzing: mutated and generated pages and stylesheets, on all cores.
#   3. The layout of generated valid pages against the reference tool.
#
#   powershell -File apps/zx-vvv/host/fuzztest.ps1 [-Runs 20000] [-Diff 300] [-Seed 1]
# Build first (cmake --build build). Failing inputs land in build/fuzz-out.

param([int]$Runs = 20000, [int]$Diff = 300, [int]$Seed = 1)
$ErrorActionPreference = 'Stop'
$Root = (Resolve-Path "$PSScriptRoot\..\..\..").Path
$Build = "$Root\build"
$Exe = "$Build\host\zxfuzz.exe"
$Fuzz = "$PSScriptRoot\fuzz"
$Out = "$Build\fuzz-out"
$Corpus = "$Build\fuzz-corpus"
$bad = 0

& python "$Fuzz\mkmap.py" "$Build\zx.map" "$Build\menu.lst" "$Build\vvv.lst" | Out-Null
if ($LASTEXITCODE) { throw 'mkmap failed' }
New-Item -ItemType Directory -Force $Out | Out-Null

# 1. The test pages
$pages = Get-ChildItem "$Root\apps\zx-vvv\testpages" -Recurse -Filter *.8tml
$pages += Get-ChildItem "$Root\apps\zx-vvv\spec\spec\examples" -Filter *.8tml -ErrorAction SilentlyContinue
$site = "$Root\apps\zx-vvv\testpages\styled\site.8ss"
$sheet = "$Root\apps\zx-vvv\testpages\styled\page.8ss"
$n = 0
foreach ($p in $pages) {
    foreach ($s in 1..10) {
        $r = & $Exe --build $Build run $p.FullName --seed $s --site $site --sheet $sheet
        $n++
        if ($r -notmatch '^ok') { Write-Output "FAIL  $($p.Name) seed $s : $r"; $bad++ }
    }
}
Write-Output "test pages: $n sessions, $bad failed"

# 1b. Sessions the fuzzer once broke (testpages/hostile/regress.txt)
$H = "$Root\apps\zx-vvv\testpages\hostile"
foreach ($line in Get-Content "$H\regress.txt") {
    if ($line -match '^\s*(#|$)') { continue }
    $f = -split $line
    $a = @('--build', $Build, 'run', "$H\$($f[0])")
    if ($f.Count -gt 1) { $a += '--seed', $f[1] }
    if ($f.Count -gt 2 -and $f[2] -ne '-') { $a += '--site', "$H\$($f[2])" }
    if ($f.Count -gt 3 -and $f[3] -ne '-') { $a += '--sheet', "$H\$($f[3])" }
    $r = & $Exe @a
    if ($r -match '^ok') { Write-Output "ok    regress $($f[0]) $($f[1])" }
    else { Write-Output "FAIL  regress $($f[0]) $($f[1]) : $r"; $bad++ }
}

# 2. Fuzzing, one process per core
Remove-Item "$Corpus" -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $Corpus | Out-Null
Copy-Item "$Root\apps\zx-vvv\testpages\*" $Corpus -Recurse
Copy-Item "$Root\apps\zx-vvv\spec\spec\examples\*" $Corpus -ErrorAction SilentlyContinue
$workers = [Math]::Max(1, [Environment]::ProcessorCount - 2)
$each = [Math]::Ceiling($Runs / $workers)
$procs = foreach ($w in 1..$workers) {
    Start-Process -FilePath $Exe -NoNewWindow -PassThru -RedirectStandardOutput "$Out\w$w.log" `
        -ArgumentList '--build', $Build, 'fuzz', $Corpus, $each, ($Seed * 100 + $w), $Out
}
$procs | Wait-Process
$fails = Select-String -Path "$Out\w*.log" -Pattern '^FAIL'
$fails | ForEach-Object { Write-Output $_.Line }
Write-Output "fuzzing: $($workers * $each) runs, $(@($fails).Count) failed"
$bad += @($fails).Count

# 3. Layout against the reference
& python "$Fuzz\difftest.py" $Diff $Seed "$Build\diff-out"
if ($LASTEXITCODE) { $bad++ }

Write-Output $(if ($bad) { "$bad problem(s); inputs in $Out and $Build\diff-out" } else { 'all pass' })
exit $bad
