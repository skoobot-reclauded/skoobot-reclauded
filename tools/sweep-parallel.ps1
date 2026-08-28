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
# identical lines would say nothing that one does not (#186).
$stamp = Get-BuildStamp -GameDir $GameDir
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
        $StartZone, $Conditions, $BirthTimeoutSec, [bool]$Dossier, $Roster, ($wanted.Count -eq 0) -ScriptBlock {
        param($repo, $gd, $hm, $class, $mins, $work, $race, $zone, $cond, $birth, $dossier, $roster, $keepSkips)
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

function Complete-Run($r, [string]$forced) {
    $slug = Get-ResultSlug $r.Item.Class
    $secs = [int]((Get-Date) - $r.Started).TotalSeconds

    # Reap from the slot's launch LEDGER, which harness.ps1 appends at every
    # launch. The first version of this grepped job.log for "launched pid="
    # lines -- and was INERT, because sweep-classes captures its children's
    # output into variables, so those lines never reach the job transcript.
    # The happy-path test read "no REAPED lines" as no false positives when it
    # was actually blindness: a test that could not fail (#196). The line below
    # therefore always prints the ledger count -- 0 launches recorded would
    # mean the ledger itself is broken, and silence is how the last one hid.
    $ledger = Join-Path (Join-Path $r.Slot.Home 'T-Engine\4.0') 'skoobot-bridge\launched.log'
    $entries = @()
    if (Test-Path $ledger) { $entries = @(Get-Content $ledger -ErrorAction Ignore | Where-Object { $_.Trim() }) }
    $reaped = 0
    foreach ($e in $entries) {
        $parts = "$e" -split ','
        $lp = 0; try { $lp = [int]$parts[0] } catch { continue }
        $proc = Get-Process -Id $lp -ErrorAction Ignore
        if (-not $proc -or $proc.ProcessName -ne 't-engine') { continue }
        if ($parts.Count -ge 2) {
            # Identity, not just pid: a recycled pid belongs to someone else.
            try {
                $ls = [datetime]::Parse($parts[1], $null, [Globalization.DateTimeStyles]::RoundtripKind)
                if ([math]::Abs(($proc.StartTime - $ls).TotalSeconds) -gt 5) { continue }
            } catch { continue }
        }
        Stop-Process -Id $lp -Force -ErrorAction Ignore
        $reaped++
    }
    if (Test-Path $ledger) { Remove-Item $ledger -Force -ErrorAction Ignore }
    Say "slot$($r.Slot.N) -- ledger: $($entries.Count) launch(es), $reaped reaped$(if ($reaped -gt 0) { ' -- a Stop-Game path failed' })"

    # Reps of one class share a filename, so they need separate directories.
    # (Eaten once by a careless region edit: with $dest undefined every copy
    # below failed quietly and a CLEARED class merged as MISSING.)
    $dest = $(if ($Repeat -gt 1) { Join-Path $OutDir "rep$($r.Item.Rep)" } else { $OutDir })
    if (-not (Test-Path $dest)) { $null = New-Item -ItemType Directory -Force -Path $dest }
    $jlPath = Join-Path $r.WorkDir 'job.log'

    if ($forced) {
        # Kill this slot's game by the pid in its own lease file, so the other
        # slots keep running. Then record the class, because a class that
        # vanishes from the table is worse than one that failed loudly (#187).
        $gp = Get-SlotGamePid $r.Slot
        if ($gp) { Stop-Process -Id $gp -Force -ErrorAction SilentlyContinue }
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
        Say "slot$($r.Slot.N) -- $($r.Item.Class) $out (${secs}s)"
    }

    Remove-Job $r.Job -Force -ErrorAction SilentlyContinue
    $script:free += $r.Slot
    $script:done++
}

while ($next -lt $totalJobs -or $running.Count -gt 0) {
    while ($next -lt $totalJobs -and $free.Count -gt 0) {
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
