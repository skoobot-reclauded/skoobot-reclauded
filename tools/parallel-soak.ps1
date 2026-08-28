<#
    Run N soaks at once on one machine, to find out whether concurrency buys
    throughput here (#189).

    Each slot gets its own game directory and its own engine home, because the
    engine writes te4_log.txt to the WORKING directory and bootstraps its
    engine code from there too -- one knob, so the log cannot be moved on its
    own. Sharing the log is impossible regardless: the engine opens it 'w', so
    a second launch would truncate the first one's.

    A slot game directory costs almost nothing. bootstrap/game/lib/lib64/
    locales are read-only data (871 MB) and become junctions; the ~71 MB of
    loose files at the top level become hard links. Only te4_log.txt is really
    written there.

        .\tools\parallel-soak.ps1 -Count 4 -Save sweep-cornac-berserker -Minutes 4

    Compare the per-slot turn rate against a solo run of the same class. If
    four slots each manage close to a solo run's turns, concurrency is worth
    having; if they each manage a quarter, it is not.
#>
[CmdletBinding()]
param(
    [int]$Count = 4,
    [Parameter(Mandatory)][string]$Save,
    [int]$Minutes = 4,
    [string]$Root = 'C:\Users\localuser\slots',
    [string]$GameDir = 'C:\games\TalesMajEyal',
    [string]$SeedHome = "$env:USERPROFILE\T-Engine\4.0",
    [string]$StartZone = 'norgos-lair',
    [switch]$KeepSlots
)
$ErrorActionPreference = 'Continue'
$RepoRoot = Split-Path -Parent $PSScriptRoot

function Say($m) { Write-Host "[parallel] $m" }

# ---- build the slots ----------------------------------------------------
$LINK_DIRS = @('bootstrap', 'game', 'lib', 'lib64', 'locales')

function New-Slot([int]$n) {
    $slot = Join-Path $Root "slot$n"
    $sgame = Join-Path $slot 'game-dir'
    $shome = Join-Path $slot 'home'
    foreach ($d in @($slot, $sgame, $shome)) {
        if (-not (Test-Path $d)) { $null = New-Item -ItemType Directory -Force -Path $d }
    }
    foreach ($d in $LINK_DIRS) {
        $src = Join-Path $GameDir $d
        if (-not (Test-Path $src)) { continue }
        $dst = Join-Path $sgame $d
        if (-not (Test-Path $dst)) { $null = New-Item -ItemType Junction -Path $dst -Target $src }
    }
    # Hard links, not copies: the same bytes on the same volume, and a slot
    # then costs nothing. Falls back to copying if the volume refuses.
    foreach ($f in (Get-ChildItem $GameDir -File)) {
        $dst = Join-Path $sgame $f.Name
        if (Test-Path $dst) { continue }
        try { $null = New-Item -ItemType HardLink -Path $dst -Target $f.FullName -ErrorAction Stop }
        catch { Copy-Item $f.FullName $dst -Force }
    }
    # The engine appends T-Engine\4.0 to whatever --home is given.
    $eng = Join-Path $shome 'T-Engine\4.0'
    if (-not (Test-Path $eng)) { $null = New-Item -ItemType Directory -Force -Path $eng }
    foreach ($d in @('settings', 'profiles')) {
        $src = Join-Path $SeedHome $d
        if ((Test-Path $src) -and -not (Test-Path (Join-Path $eng $d))) {
            Copy-Item $src (Join-Path $eng $d) -Recurse -Force
        }
    }
    $saveSrc = Join-Path $SeedHome "tome\save\$Save"
    if (-not (Test-Path $saveSrc)) { throw "no save at $saveSrc" }
    $saveDst = Join-Path $eng "tome\save\$Save"
    if (-not (Test-Path $saveDst)) {
        $null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $saveDst)
        Copy-Item $saveSrc $saveDst -Recurse -Force
    }
    return [pscustomobject]@{ N = $n; Slot = $slot; GameDir = $sgame; Home = $shome }
}

Say "building $Count slot(s) under $Root"
$slots = @()
foreach ($n in 1..$Count) { $slots += (New-Slot $n) }
$used = (Get-ChildItem $Root -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
Say ("slots ready, {0:N0} MB of real bytes on disk" -f ($used / 1MB))

# ---- run them all at once -----------------------------------------------
# Each job sets TOME_DIR and TOME_HOME for its own process only. harness.ps1
# reads both, so the slot's game, saves, bridge channel and log are its own.
$started = Get-Date
$jobs = @()
foreach ($s in $slots) {
    $out = Join-Path $s.Slot 'soak.json'
    $jobs += Start-Job -Name "slot$($s.N)" -ArgumentList $RepoRoot, $s.GameDir, $s.Home, $Save, $Minutes, $out, $StartZone -ScriptBlock {
        param($repo, $gd, $hm, $save, $mins, $out, $zone)
        $env:TOME_DIR  = $gd
        $env:TOME_HOME = $hm
        & powershell -ExecutionPolicy Bypass -File "$repo\tools\soak.ps1" `
            -SaveName $save -MaxMinutes $mins -OutFile $out -StartZone $zone -NoRunLease 2>&1
    }
}
Say "$($jobs.Count) soak(s) launched at $($started.ToString('HH:mm:ss')); waiting"
$null = Wait-Job -Job $jobs -Timeout (($Minutes + 12) * 60)
$elapsed = ((Get-Date) - $started).TotalSeconds

# ---- what happened ------------------------------------------------------
Write-Host ''
Say ("all slots done in {0:N0}s wall" -f $elapsed)
Write-Host ''
Write-Host ('  {0,-7} {1,-10} {2,10} {3,10} {4}' -f 'slot', 'ended', 'turns', 'turns/s', 'floors')
$total = 0
foreach ($s in $slots) {
    $out = Join-Path $s.Slot 'soak.json'
    if (-not (Test-Path $out)) { Write-Host ('  {0,-7} {1}' -f "slot$($s.N)", 'NO RESULT'); continue }
    $j = Get-Content $out -Raw | ConvertFrom-Json
    $t = 0
    if ($j.turns -and $j.turns.delta) { $t = [int]$j.turns.delta }
    $total += $t
    Write-Host ('  {0,-7} {1,-10} {2,10:N0} {3,10:N1} {4}' -f
        "slot$($s.N)", $j.ended, $t, $(if ($elapsed -gt 0) { $t / $elapsed } else { 0 }), ($j.zones -join ' > '))
}
Write-Host ''
Say ("total {0:N0} game turns across {1} slot(s) in {2:N0}s -- {3:N1} turns/s aggregate" -f
    $total, $Count, $elapsed, $(if ($elapsed -gt 0) { $total / $elapsed } else { 0 }))

foreach ($j in $jobs) { Remove-Job $j -Force -ErrorAction SilentlyContinue }
if (-not $KeepSlots) { Say "slots left in place at $Root (-KeepSlots is the default behaviour; delete by hand if wanted)" }
exit 0
