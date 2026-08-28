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
# harness.ps1 for Get-SaveDirName, which New-SlotSet uses to find the save
# directory: the save NAME uses hyphens, the DIRECTORY underscores truncated to
# 25 characters. Never a second copy of that rule -- one cost Cultist of
# Entropy eight sweeps of UNBIRTHABLE with a valid save on disk (#121).
. (Join-Path $PSScriptRoot 'harness.ps1')
. (Join-Path $PSScriptRoot 'slots.ps1')

function Say($m) { Write-Host "[parallel] $m" }

$slots = New-SlotSet -Count $Count -Root $Root -GameDir $GameDir -SeedHome $SeedHome -Save $Save

# ---- run them all at once -----------------------------------------------
# Each job sets TOME_DIR and TOME_HOME for its own process only. harness.ps1
# reads both, so the slot's game, saves, bridge channel and log are its own.
$started = Get-Date
# Job AND slot together: a wedged job has to be reaped through its own slot,
# and two parallel arrays would be one edit away from reaping the wrong one.
$runs = @()
foreach ($s in $slots) {
    $out = Join-Path $s.Slot 'soak.json'
    # A result left from a previous run is read as though this run produced it.
    # That is exactly #188 again, in the script written to fix the last one: the
    # first 4-slot run reported a baseline's 18,381 turns as a parallel result.
    Remove-Item $out -Force -ErrorAction SilentlyContinue
    $job = Start-Job -Name "slot$($s.N)" -ArgumentList $RepoRoot, $s.GameDir, $s.Home, $Save, $Minutes, $out, $StartZone, $Conditions -ScriptBlock {
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
    $runs += [pscustomobject]@{ Slot = $s; Job = $job }
}
$jobs = @($runs | ForEach-Object { $_.Job })
Say "$($jobs.Count) soak(s) launched at $($started.ToString('HH:mm:ss')); waiting"
$null = Wait-Job -Job $jobs -Timeout (($Minutes + 12) * 60)
$elapsed = ((Get-Date) - $started).TotalSeconds

# Wait-Job's timeout stops WAITING, not the job, so the table below used to be
# rendered while a wedged slot's soak and game were still running. Measured
# against a deliberately wedged slot: the Remove-Job -Force at the foot does
# take the chain down a few seconds later, so this is an ordering and
# reporting fix, not the outright leak #196 predicted. Stop first, reap
# through the same function the scheduler uses, and name the slot wedged.
$wedged = @()
foreach ($r in $runs) {
    if ($r.Job.State -eq 'Running') {
        Say "slot$($r.Slot.N) -- still running at the timeout; stopping it"
        Stop-Job $r.Job -ErrorAction SilentlyContinue
        $wedged += $r.Slot.N
    }
}
foreach ($r in $runs) { $null = Invoke-SlotReap $r.Slot }

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
        # A wedged slot said nothing at all before: "NO RESULT" reads as a run
        # that failed, when it is a run that never ended (#196).
        $what = if ($wedged -contains $s.N) { 'NO RESULT (wedged)' } else { 'NO RESULT' }
        Write-Host ('  {0,-7} {1} -- {2}' -f "slot$($s.N)", $what, $why)
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
