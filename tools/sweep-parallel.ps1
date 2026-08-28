<#
    Run classes across several slots at once on one machine (#194).

    A work queue, not a fixed split: every slot takes the next class the moment
    it is free, so one slow class cannot hold up the rest. Any set of classes
    works -- a whole roster, a handful, or the same class many times to dig
    into one of them.

        # everything, 8 at a time
        .\tools\sweep-parallel.ps1 -Slots 8

        # a few classes
        .\tools\sweep-parallel.ps1 -Only 'Bulwark,Mindslayer,Doomed' -Slots 3

        # one class eight times, for a distribution rather than an anecdote
        .\tools\sweep-parallel.ps1 -Only 'Doomed' -Repeat 8 -Slots 8

    Each worker runs sweep-classes.ps1 for ONE class inside its slot, so a row
    produced here means exactly what a serial row means and merges with one.
    The merge at the end is sweep-classes -SummarizeOnly over the same class
    list.

    Two timeouts, because a series must not be hostage to one run:

    -BirthTimeoutSec  how long a birth may take (default 300; the serial
                      default of 900 was set before anyone watched a birth fail,
                      and Mindslayer spent every second of it -- #184).
    -ClassTimeoutSec  the emergency cap on a whole class. A run that loops
                      without advancing game time hits no other limit: soak's
                      MaxMinutes is measured against progress it never makes.
                      When it fires, that slot's game is killed by pid from its
                      own lease file, the class is recorded TIMEOUT, and the
                      queue carries on.

    Wave 1 is the only dispatch that is not naturally staggered, and eight
    simultaneous cold starts can cost a class (#197): -WaveStaggerSec spaces
    them, and a class that comes back UNBIRTHABLE is requeued once at the tail
    where it runs alone against warm caches.
#>
[CmdletBinding()]
param(
    # Classes by leaf name, comma-separated or an array. Default: the roster.
    [string[]]$Only,
    [int]$Slots = 8,
    # Run each requested class this many times. For deep-diving one class.
    [int]$Repeat = 1,
    [int]$Minutes = 4,
    [string]$Race = 'Cornac',
    [string]$Roster,
    [string]$OutDir,
    [switch]$Dossier,
    [string]$StartZone = 'norgos-lair',
    [string]$Conditions = 'SCOUTER_STRONGERENEMY=WARN,SCOUTER_BIGENEMY=WARN,SCOUTER_CROWDPOWER=WARN,SCOUTER_ENEMYCOUNT=WARN,LIFE_LOWLIFE=WARN',
    [int]$BirthTimeoutSec = 300,
    # 0 = derive from the other two, plus slack for launch and teardown.
    [int]$ClassTimeoutSec = 0,
    [string]$Root = 'C:\Users\localuser\slots',
    [string]$GameDir = 'C:\games\TalesMajEyal',
    [string]$SeedHome = "$env:USERPROFILE\T-Engine\4.0",
    [int]$PollSec = 5,
    # Seconds between the launches of wave 1 only. 0 disables the stagger.
    [int]$WaveStaggerSec = 8,
    # Apply the sweep's skip policy even though classes are named with -Only.
    # Auto-on for a full-roster run; pass it explicitly when a named list is
    # one machine's share of a roster split, so Adventurer still SKIPs (#194).
    [switch]$KeepSkips,
    [switch]$KeepSlots
)
$ErrorActionPreference = 'Continue'
$RepoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'harness.ps1')
. (Join-Path $PSScriptRoot 'slots.ps1')

function Say($m)  { Write-Host "[parallel] $m" }
function Fail($m) { Write-Host "[parallel] FAILED - $m"; exit 1 }

if (-not $OutDir) { $OutDir = Join-Path $RepoRoot 'build\results\sweep' }
if (-not $Roster) { $Roster = Join-Path $RepoRoot ("build\results\classes-{0}.txt" -f (Get-ResultSlug $Race)) }
if ($ClassTimeoutSec -le 0) { $ClassTimeoutSec = $BirthTimeoutSec + ($Minutes * 60) + 180 }

# ---- what are we running? -----------------------------------------------
if (-not (Test-Path $Roster)) {
    Fail "no roster at $Roster -- run tools\unlock-classes.ps1"
}
$rosterRows = @(Get-Content $Roster | Where-Object { $_ -and $_.Trim() } | ForEach-Object {
    $parts = $_.Trim() -split '/'
    [pscustomobject]@{ Tree = $parts[0]; Class = $parts[-1].Trim() }
})

# -File hands a comma-joined list over as ONE string, so split again whatever
# shape it arrives in (the trap tools/new-character.ps1 records).
$wanted = @()
if ($Only) { $wanted = @(($Only -join ',') -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }

if ($wanted.Count -gt 0) {
    $unknown = @($wanted | Where-Object { $n = $_; -not ($rosterRows | Where-Object { $_.Class -eq $n }) })
    if ($unknown.Count -gt 0) { Fail "not in the roster: $($unknown -join ', ')" }
    $classes = $wanted
} else {
    $classes = @($rosterRows | ForEach-Object { $_.Class })
}

# Repeat expands into separate queue items. Every rep of a class produces the
# SAME result filename, so writing them all to one directory would leave one
# survivor and silently call it the answer. Each rep gets its own directory.
$queue = @()
foreach ($r in 1..$Repeat) {
    foreach ($c in $classes) {
        $queue += [pscustomobject]@{ Class = $c; Rep = $r }
    }
}
$totalJobs = $queue.Count
if ($totalJobs -eq 0) { Fail 'nothing to run' }
if ($Slots -gt $totalJobs) { $Slots = $totalJobs }

Say "$totalJobs run(s) over $Slots slot(s): $($classes.Count) class(es)$(if ($Repeat -gt 1) { " x $Repeat" })"
Say "birth cap ${BirthTimeoutSec}s, class cap ${ClassTimeoutSec}s, $Minutes min per run"

if (-not (Test-Path $OutDir)) { $null = New-Item -ItemType Directory -Force -Path $OutDir }
$slotSet = New-SlotSet -Count $Slots -Root $Root -GameDir $GameDir -SeedHome $SeedHome

# One stamp for the whole batch: every worker loads the same checkout, so eight
# identical lines would say nothing that one does not (#186). Read from a
# SLOT's game dir, not the real install: slot addon junctions are pinned to
# this checkout, while the real install's may be repointed at any moment by a
# dev session -- stamping the install would name whatever THAT session was
# working on (#198).
$stamp = Get-BuildStamp -GameDir $slotSet[0].GameDir
Add-Content -Path (Join-Path $OutDir 'stamps.txt') -Value (Format-BuildStamp $stamp) -Encoding utf8
Say (Format-BuildStamp $stamp)

# ---- the queue ----------------------------------------------------------
# Plain arrays, rebuilt each pass. A List[object] here threw "Argument types
# do not match" out of $running.Remove() on every iteration, which spun the
# loop forever while printing nothing -- and the Select-String the caller
# piped through hid the exception completely, so it read as a hung watchdog
# rather than a crashing one. Rebuilding also removes the
# modify-while-enumerating hazard that made Remove() necessary.
$free    = @($slotSet)
$running = @()
$next    = 0
$done    = 0
$timedOut = @()
$started = Get-Date

function Start-ClassJob($item, $slot) {
    # A worker's own directory, cleared first. Anything left from the previous
    # class here would be copied up as though this run produced it -- #188.
    $workDir = Join-Path $slot.Slot 'out'
    if (Test-Path $workDir) { Remove-Item $workDir -Recurse -Force -ErrorAction SilentlyContinue }
    $null = New-Item -ItemType Directory -Force -Path $workDir

    $job = Start-Job -Name "slot$($slot.N)" -ArgumentList `
        $RepoRoot, $slot.GameDir, $slot.Home, $item.Class, $Minutes, $workDir, $Race, `
        $StartZone, $Conditions, $BirthTimeoutSec, [bool]$Dossier, $Roster, ($KeepSkips -or $wanted.Count -eq 0) -ScriptBlock {
        param($repo, $gd, $hm, $class, $mins, $work, $race, $zone, $cond, $birth, $dossier, $roster, $keepSkips)
        # First act: this process is the root of the worker tree. The
        # `& powershell` below, whatever IT runs, and any game they launch are
        # all descendants of it, and on Windows Stop-Job kills none of them --
        # so the watchdog needs a pid it can tree-kill (#196).
        Set-Content -Path (Join-Path $work 'worker.pid') -Value $PID -Encoding ascii
        $env:TOME_DIR  = $gd
        $env:TOME_HOME = $hm
        $a = @('-ExecutionPolicy', 'Bypass', '-File', "$repo\tools\sweep-classes.ps1",
               '-Only', $class, '-Minutes', $mins, '-OutDir', $work, '-Race', $race,
               '-Roster', $roster, '-StartZone', $zone, '-Conditions', $cond,
               '-BirthTimeoutSec', $birth, '-NoSetup', '-NoRunLease')
        if ($dossier) { $a += '-Dossier' }
        if ($keepSkips) { $a += '-KeepSkips' }
        & powershell @a 2>&1 | Out-File -FilePath (Join-Path $work 'job.log') -Encoding utf8
    }
    Say ("slot$($slot.N) <- $($item.Class)$(if ($Repeat -gt 1) { " #$($item.Rep)" })  ($done/$totalJobs done)")
    # Returned, not pushed onto a shared collection: the caller owns the list.
    return [pscustomobject]@{
        Job      = $job
        Slot     = $slot
        Item     = $item
        WorkDir  = $workDir
        Deadline = (Get-Date).AddSeconds($ClassTimeoutSec)
        Started  = Get-Date
    }
}

function Stop-WorkerTree($r) {
    # Stop-Job ends the job's own process and nothing else: on Windows a job
    # does not own the native processes it spawned, so the `& powershell`
    # running sweep-classes, whatever IT is running, and any game they launched
    # all survive it. A mid-birth new-character could then relaunch a game into
    # the slot we are about to hand to the next class -- the narrow window
    # #196 left open. taskkill /T walks the parent chain in one call: no
    # hand-rolled Win32_Process walk, and no ordering problem.
    $wp = Join-Path $r.WorkDir 'worker.pid'
    if (Test-Path $wp) {
        $wpid = 0
        try { $wpid = [int]((Get-Content $wp -Raw -ErrorAction Stop).Trim()) } catch { $wpid = 0 }
        if ($wpid -gt 0) {
            & taskkill.exe /T /F /PID $wpid 2>$null | Out-Null
            Say "slot$($r.Slot.N) -- worker tree $wpid killed"
        }
    }
    # A backstop, not the mechanism: this slot's own lease pid, so the other
    # slots keep running. The ledger reap that follows is the second.
    $gp = Get-SlotGamePid $r.Slot
    if ($gp) { Stop-Process -Id $gp -Force -ErrorAction SilentlyContinue }
}

function Add-Detail([string]$path, [string]$note) {
    # Append a parenthetical to a result row's Detail, leaving the rest of the
    # row alone. Idempotent, so a re-run cannot stack the same note twice.
    if (-not (Test-Path $path)) { return }
    $j = Get-Content $path -Raw | ConvertFrom-Json
    $d = "$($j.Detail)".Trim()
    if ($d -like "*$note*") { return }
    $j | Add-Member -NotePropertyName Detail -NotePropertyValue $(
        if ($d) { "$d ($note)" } else { $note }) -Force
    ($j | ConvertTo-Json -Depth 4) | Set-Content $path -Encoding utf8
}

function Complete-Run($r, [string]$forced) {
    $slug = Get-ResultSlug $r.Item.Class
    $secs = [int]((Get-Date) - $r.Started).TotalSeconds

    # A forced end kills the worker TREE first, so nothing the worker is still
    # doing can launch into the slot between here and the reap (#196).
    if ($forced) { Stop-WorkerTree $r }

    # Then the ledger reap, which every completion does -- the backstop for
    # whatever the tree kill could not reach and for any Stop-Game path that
    # failed. Invoke-SlotReap, never a second copy of the rule (#121).
    $null = Invoke-SlotReap $r.Slot

    # Reps of one class share a filename, so they need separate directories.
    # (Eaten once by a careless region edit: with $dest undefined every copy
    # below failed quietly and a CLEARED class merged as MISSING.)
    $dest = $(if ($Repeat -gt 1) { Join-Path $OutDir "rep$($r.Item.Rep)" } else { $OutDir })
    if (-not (Test-Path $dest)) { $null = New-Item -ItemType Directory -Force -Path $dest }
    $jlPath = Join-Path $r.WorkDir 'job.log'

    if ($forced) {
        # The killing is done (Stop-WorkerTree, above). Record the class,
        # because one that vanishes from the table is worse than one that
        # failed loudly (#187).
        Stop-Job $r.Job -ErrorAction SilentlyContinue
        $row = [pscustomobject]@{
            Class = $r.Item.Class; Race = $Race; Outcome = 'TIMEOUT'
            Detail = "$forced after ${secs}s"; StartZone = '?'; Comparable = $false
            Turns = 0; Stops = 0; Descents = 0; CharLevel = '-1->-1'
        }
        ($row | ConvertTo-Json -Depth 4) | Set-Content (Join-Path $dest "$slug.json") -Encoding utf8
        # The transcript is the only account of a run nobody watched (#183).
        $jl = Join-Path $r.WorkDir 'job.log'
        if (Test-Path $jl) { Copy-Item $jl (Join-Path $dest "$slug.timeout.log") -Force }
        $script:timedOut += $r.Item.Class
        Say "slot$($r.Slot.N) -- $($r.Item.Class) TIMEOUT after ${secs}s ($forced); slot recovered"
    } else {
        # Whether THIS run produced a row, read before the copy overwrites the
        # previous attempt's. A retry that produced nothing must not be allowed
        # to stamp attempt 1's row as its own.
        $ownRow = Test-Path (Join-Path $r.WorkDir "$slug.json")

        # Only this class's result files, plus the transcript under the class's
        # name. The transcript used to be kept for TIMEOUT only; wave-1 of the
        # first 8-slot run was then undiagnosable because each slot's next
        # class had already cleared the directory (#196). Evidence first.
        Get-ChildItem $r.WorkDir -File -Filter "$slug.*" -ErrorAction SilentlyContinue |
            ForEach-Object { Copy-Item $_.FullName (Join-Path $dest $_.Name) -Force }
        if (Test-Path $jlPath) { Copy-Item $jlPath (Join-Path $dest "$slug.job.log") -Force }
        $res = Join-Path $dest "$slug.json"
        $out = if (Test-Path $res) {
            try { (Get-Content $res -Raw | ConvertFrom-Json).Outcome } catch { 'unreadable' }
        } else { 'NO RESULT' }

        if ($r.Item.Retry -and $ownRow) {
            # A pass on retry is a pass that says so, the same rule the launch
            # retry already follows: a class that needs the retry every sweep
            # stays visible as birth-flaky instead of being laundered (#197).
            Add-Detail $res 'attempt 2'
        } elseif ($r.Item.Retry) {
            Say "slot$($r.Slot.N) -- $($r.Item.Class) attempt 2 produced no row; attempt 1's stands"
        } elseif ($out -eq 'UNBIRTHABLE') {
            # Cold-start contention is launch weather, not a finding: requeue
            # once at the tail, where it runs alone against warm caches, and
            # convert a missing row into wall time (#197). TIMEOUT and CRASHED
            # are findings and are never retried.
            $script:queue += [pscustomobject]@{ Class = $r.Item.Class; Rep = $r.Item.Rep; Retry = $true }
            $script:totalJobs = $script:queue.Count
            Say "slot$($r.Slot.N) -- $($r.Item.Class) UNBIRTHABLE; requeued once at the tail"
        }

        Say "slot$($r.Slot.N) -- $($r.Item.Class)$(if ($r.Item.Retry) { ' (attempt 2)' }) $out (${secs}s)"
    }

    Remove-Job $r.Job -Force -ErrorAction SilentlyContinue
    $script:free += $r.Slot
    $script:done++
}

while ($next -lt $totalJobs -or $running.Count -gt 0) {
    while ($next -lt $totalJobs -and $free.Count -gt 0) {
        # Wave 1 only. Eight simultaneous cold starts put all eight against the
        # same two 60s windows -- the launch banner and the menu bridge -- and
        # one of eight missed in sweep-18. Its natural 17s spread was not
        # enough, so the spacing has to be deliberate rather than incidental
        # (#197). Every later dispatch is staggered by class completion.
        if ($next -gt 0 -and $next -lt $Slots -and $WaveStaggerSec -gt 0) {
            Start-Sleep -Seconds $WaveStaggerSec
        }
        $slot = $free[0]
        $free = @($free | Select-Object -Skip 1)
        $running += (Start-ClassJob $queue[$next] $slot)
        $next++
    }
    Start-Sleep -Seconds $PollSec

    $still = @()
    foreach ($r in $running) {
        if ($r.Job.State -in @('Completed', 'Failed', 'Stopped')) {
            Complete-Run $r ''
        } elseif ((Get-Date) -gt $r.Deadline) {
            Complete-Run $r "over the ${ClassTimeoutSec}s class cap"
        } else {
            $still += $r
        }
    }
    $running = @($still)
}

$elapsed = ((Get-Date) - $started).TotalSeconds
Write-Host ''
Say ("$totalJobs run(s) in {0:N0}s ({1:N1} min) over $Slots slot(s)" -f $elapsed, ($elapsed / 60))
if ($timedOut.Count -gt 0) { Say "TIMED OUT: $($timedOut -join ', ')" }

# ---- what came out ------------------------------------------------------
if ($Repeat -gt 1) {
    # Reps are separate samples of the same class, not one table: averaging
    # them would hide the spread, which is the entire reason for running a
    # class more than once.
    Write-Host ''
    Write-Host ('  {0,-20} {1,-4} {2,-12} {3,9} {4,-9} {5}' -f 'class', 'rep', 'outcome', 'turns', 'level', 'floors')
    foreach ($rep in 1..$Repeat) {
        foreach ($c in $classes) {
            $f = Join-Path (Join-Path $OutDir "rep$rep") ("{0}.json" -f (Get-ResultSlug $c))
            if (-not (Test-Path $f)) { Write-Host ('  {0,-20} {1,-4} {2}' -f $c, $rep, 'NO RESULT'); continue }
            $j = Get-Content $f -Raw | ConvertFrom-Json
            Write-Host ('  {0,-20} {1,-4} {2,-12} {3,9} {4,-9} {5}' -f
                $c, $rep, $j.Outcome, $j.Turns, $j.CharLevel, $j.Trail)
        }
    }
    Write-Host ''
    Say "per-rep results under $OutDir
ep1..rep$Repeat -- each is one sample, summarise a rep with -SummarizeOnly -OutDir <rep dir>"
    exit 0
}

# ---- one table over the lot ---------------------------------------------
Say 'merging'
$m = @('-ExecutionPolicy', 'Bypass', '-File', (Join-Path $PSScriptRoot 'sweep-classes.ps1'),
       '-SummarizeOnly', '-OutDir', $OutDir, '-Race', $Race, '-Roster', $Roster,
       '-Minutes', $Minutes)
# Summarise exactly what was asked for. Without this a three-class run reports
# the other twenty-six as MISSING, which is true of the roster and a lie about
# the run (#187).
if ($wanted.Count -gt 0) { $m += @('-Only', ($classes -join ',')) }
& powershell @m 2>&1 | Select-Object -Last 40
exit 0
