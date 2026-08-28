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
    # Match sweep-classes, or the runs are not comparable with a sweep: shipped
    # defaults are STOP, so a class stops dead wherever a boss stays in view.
    [string]$Conditions = 'SCOUTER_STRONGERENEMY=WARN,SCOUTER_BIGENEMY=WARN,SCOUTER_CROWDPOWER=WARN,SCOUTER_ENEMYCOUNT=WARN,LIFE_LOWLIFE=WARN',
    [switch]$KeepSlots
)
$ErrorActionPreference = 'Continue'
$RepoRoot = Split-Path -Parent $PSScriptRoot
# For Get-SaveDirName. The save NAME uses hyphens; the save DIRECTORY uses
# underscores and is truncated to 25 characters, so a second copy of that rule
# looks for a directory the engine never creates. That mistake reported Cultist
# of Entropy UNBIRTHABLE for eight sweeps with a valid save on disk (#121).
. (Join-Path $PSScriptRoot 'harness.ps1')

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
    # 'boot' as well: without it the engine treats the home as a first run and
    # opens a welcome dialog at the main menu, which nothing dismisses.
    foreach ($d in @('settings', 'profiles', 'boot')) {
        $src = Join-Path $SeedHome $d
        if ((Test-Path $src) -and -not (Test-Path (Join-Path $eng $d))) {
            Copy-Item $src (Join-Path $eng $d) -Recurse -Force
        }
    }
    $saveDir = Get-SaveDirName -Name $Save
    $saveSrc = Join-Path $SeedHome "tome\save\$saveDir"
    if (-not (Test-Path $saveSrc)) { throw "no save directory at $saveSrc (from save name '$Save')" }
    $saveDst = Join-Path $eng "tome\save\$saveDir"
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
    # A result left from a previous run is read as though this run produced it.
    # That is exactly #188 again, in the script written to fix the last one: the
    # first 4-slot run reported a baseline's 18,381 turns as a parallel result.
    Remove-Item $out -Force -ErrorAction SilentlyContinue
    $jobs += Start-Job -Name "slot$($s.N)" -ArgumentList $RepoRoot, $s.GameDir, $s.Home, $Save, $Minutes, $out, $StartZone, $Conditions -ScriptBlock {
        param($repo, $gd, $hm, $save, $mins, $out, $zone, $cond)
        $env:TOME_DIR  = $gd
        $env:TOME_HOME = $hm
        # Output kept, not discarded: a slot that dies before writing a result
        # has nothing else to explain itself, and two of four did exactly that.
        & powershell -ExecutionPolicy Bypass -File "$repo\tools\soak.ps1" `
            -SaveName $save -MaxMinutes $mins -OutFile $out -StartZone $zone `
            -Conditions $cond -NoRunLease 2>&1 |
            Out-File -FilePath (Join-Path (Split-Path -Parent $out) 'job.log') -Encoding utf8
    }
}
Say "$($jobs.Count) soak(s) launched at $($started.ToString('HH:mm:ss')); waiting"
$null = Wait-Job -Job $jobs -Timeout (($Minutes + 12) * 60)
$elapsed = ((Get-Date) - $started).TotalSeconds

# ---- what happened ------------------------------------------------------
Write-Host ''
Say ("all slots done in {0:N0}s wall" -f $elapsed)
Write-Host ''
Write-Host ('  {0,-7} {1,-9} {2,9} {3,8} {4,8} {5}' -f 'slot', 'ended', 'turns', 'ran', 'turns/s', 'floors')
$total = 0
$rates = @()
foreach ($s in $slots) {
    $out = Join-Path $s.Slot 'soak.json'
    if (-not (Test-Path $out)) {
        $jl = Join-Path $s.Slot 'job.log'
        $why = if (Test-Path $jl) { (Get-Content $jl | Where-Object { $_ -match 'IN USE|FAILED|Exception|error' } | Select-Object -Last 1) } else { 'no job.log' }
        Write-Host ('  {0,-7} {1} -- {2}' -f "slot$($s.N)", 'NO RESULT', $why)
        continue
    }
    $j = Get-Content $out -Raw | ConvertFrom-Json
    $t = 0
    if ($j.turns -and $j.turns.delta) { $t = [int]$j.turns.delta }
    $total += $t
    # Against the slot's OWN duration, not the batch wall clock. Dividing by
    # the latter credits a slot that died at 60s with the whole window and
    # makes contention look like an improvement. All slots start together, so
    # ended-minus-started is the run.
    $dur = 0
    try { $dur = ([datetime]$j.ended - $started).TotalSeconds } catch { $dur = $elapsed }
    if ($dur -le 0) { $dur = $elapsed }
    $rates += $(if ($dur -gt 0) { $t / $dur } else { 0 })
    Write-Host ('  {0,-7} {1,-9} {2,9:N0} {3,7:N0}s {4,8:N1} {5}' -f
        "slot$($s.N)", $j.ended.Substring(11,8), $t, $dur, $(if ($dur -gt 0) { $t / $dur } else { 0 }), ($j.zones -join ' > '))
}
Write-Host ''
Say ("total {0:N0} game turns across {1} slot(s) in {2:N0}s -- {3:N1} turns/s aggregate" -f
    $total, $Count, $elapsed, $(if ($elapsed -gt 0) { $total / $elapsed } else { 0 }))
if ($rates.Count -gt 0) {
    $mean = ($rates | Measure-Object -Average).Average
    $min  = ($rates | Measure-Object -Minimum).Minimum
    Say ("per-slot turns/s: mean {0:N1}, slowest {1:N1}, across {2} slot(s) that reported" -f $mean, $min, $rates.Count)
}

foreach ($j in $jobs) { Remove-Job $j -Force -ErrorAction SilentlyContinue }
if (-not $KeepSlots) { Say "slots left in place at $Root (-KeepSlots is the default behaviour; delete by hand if wanted)" }
exit 0
