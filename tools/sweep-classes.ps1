<#
    The class baseline sweep (#123): birth one character of every measurable
    class, run each for a bounded time, and report whether it cleared its
    first floor.

    A TRIAGE INSTRUMENT, NOT A GATE. The output is a table and, from it, one
    issue per class that cannot get through floor one. A 30-50% pass rate is
    the expected result and not a failure of the run; 100% would mean the
    bound was too loose to find anything.

    WHAT "CLEARED" MEANS HERE. The character reached a second floor of its
    starting zone (or left the zone) while alive. The bot does the clearing --
    survive the floor and explore it to exhaustion -- and tools/soak.ps1's
    descend rung does the stair-taking once the level reports itself explored.
    That division is deliberate and is recorded per class as `descents`: we
    are measuring whether a class can survive and finish a floor, not whether
    it is willing to press '>'. Scoring by FLOOR rather than by zone is the
    owner's call for a faster first pass (2026-08-25).

    WHAT IS MEASURED, AND WHAT IS NOT:
      * the roster comes from tools/unlock-classes.ps1 and is PER-RACE, since
        a class whose special_check rejects the race is absent from the tree
        rather than locked (Cornac 30, Dwarf 31 -- the extra is Stone Warden);
      * the five TOWN-START classes are skipped by decision (#123) and are in
        any case unbirthable by the harness today: Archmage reaches
        town-angolwen and stops on an untitled dialog with no EXIT bind;
      * the four Steamtech classes never appear in a Maj'Eyal roster at all --
        they are campaign-gated, and are their own sweep (owner, 2026-08-25).

    The rules are auto-filled from the loadout proposal, which is the point:
    this measures THE SUGGESTED BUILD, which is what "classes that perform
    sub-optimally with the suggested build" is about.

    COST. The game is single-occupancy and this holds the lease from start to
    finish (#83), so it is serial and cannot interleave with scenario work.
    Budget roughly (birth ~90 s + -Minutes) per class. It is resumable: a
    class whose result file already exists is skipped unless -Force.

    Run:
        # the whole measurable set, four minutes each
        powershell -ExecutionPolicy Bypass -File .\tools\sweep-classes.ps1

        # a subset, quickly, to prove the rig
        powershell -ExecutionPolicy Bypass -File .\tools\sweep-classes.ps1 -Only Berserker,Summoner -Minutes 2

    Exit codes:  0 the sweep ran (whatever the classes did)   1 the sweep
    itself could not run   3 no roster

    #123. Depends on tools/unlock-classes.ps1 having been run once.
#>
[CmdletBinding()]
param(
    [string]$Race = 'Cornac',
    # Wall-clock minutes per class.
    [int]$Minutes = 4,
    # Only these classes (leaf names), comma-separated or an array.
    [string[]]$Only,
    # The roster file; defaults to the one unlock-classes.ps1 writes.
    [string]$Roster,
    [string]$OutDir,
    # Re-run classes that already have a result file.
    [switch]$Force,
    # Reuse fixture saves that already exist instead of re-birthing.
    [switch]$SkipBirth,
    [int]$BirthTimeoutSec = 900,
    [int]$LeaseWaitMin = 60,
    # Do not take a lease. For running under an outer host that holds one.
    [switch]$NoRunLease
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'harness.ps1')

$RepoRoot = Split-Path -Parent $PSScriptRoot

# The five that begin in a town rather than on a dungeon floor. Identified by
# their descriptors' starting_zone (data/birth/classes/{mage,celestial,
# chronomancer}.lua), not guessed: town-angolwen, town-gates-of-morning and
# town-point-zero. Skipped by decision (#123) and unbirthable in any case.
$TOWN_STARTS = @('Archmage', 'Sun Paladin', 'Anorithil', 'Paradox Mage', 'Temporal Warden')

# A class that refuses the standing race needs its own. Stone Warden's
# special_check rejects anything but a Dwarf (data/birth/classes/wilder.lua).
$RACE_EXCEPTIONS = @{ 'Stone Warden' = 'Dwarf' }

function Fail($why) { Write-Host "[sweep] FAILED - $why"; exit 1 }

function Slug([string]$s) { return (($s -replace '[^A-Za-z0-9]+', '-').Trim('-')).ToLower() }

if (-not $Roster) { $Roster = Join-Path $RepoRoot ("build\results\classes-{0}.txt" -f (Slug $Race)) }
if (-not $OutDir) { $OutDir = Join-Path $RepoRoot 'build\results\sweep' }
if (-not (Test-Path $OutDir)) { $null = New-Item -ItemType Directory -Force -Path $OutDir }

Write-Host ''
Write-Host "[sweep] class baseline sweep (#123): $Race, $Minutes min per class"

if (-not (Test-Path $Roster)) {
    Write-Host "[sweep] no roster at $Roster"
    Write-Host '        run: powershell -ExecutionPolicy Bypass -File .\tools\unlock-classes.ps1'
    exit 3
}

# The roster is "Tree/Class" per line; the sweep works in leaf names.
$rows = @(Get-Content $Roster | Where-Object { $_ -and $_.Trim() } | ForEach-Object {
    $parts = $_.Trim() -split '/'
    [pscustomobject]@{ Tree = $parts[0]; Class = $parts[-1] }
})
if ($rows.Count -eq 0) { Fail "the roster at $Roster is empty" }

# -Only may arrive as one comma-joined string: `powershell -File` hands every
# argument over as a plain string, so a [string[]] given "a,b" is ONE element
# with a comma in it. Same trap tools/new-character.ps1 records.
#
# NOT named $only: PowerShell variable names are case-INSENSITIVE, so `$only`
# and the `$Only` parameter are the same variable, and `$only = @()` silently
# empties the parameter before it is read. That is how the first run of this
# script birthed every class in the roster instead of the two asked for.
$wanted = @()
if ($Only) { $wanted = @($Only | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }

$plan = @()
foreach ($r in $rows) {
    $skip = $null
    if ($TOWN_STARTS -contains $r.Class) { $skip = "town start" }
    if ($wanted.Count -gt 0 -and $wanted -notcontains $r.Class) { continue }
    $plan += [pscustomobject]@{
        Tree  = $r.Tree
        Class = $r.Class
        Race  = $(if ($RACE_EXCEPTIONS.ContainsKey($r.Class)) { $RACE_EXCEPTIONS[$r.Class] } else { $Race })
        Skip  = $skip
    }
}
if ($wanted.Count -gt 0) {
    foreach ($n in $wanted) { if (-not ($plan | Where-Object { $_.Class -eq $n })) { Write-Host "[sweep] WARNING: '$n' is not in the roster" } }
}

$measurable = @($plan | Where-Object { -not $_.Skip })
$skipped    = @($plan | Where-Object { $_.Skip })
Write-Host ("        {0} to measure, {1} skipped, roster {2}" -f $measurable.Count, $skipped.Count, (Split-Path -Leaf $Roster))
if ($measurable.Count -eq 0) { Fail 'nothing to measure' }

# One lease for the whole sweep, as run-scenarios.ps1 does (#83). Children
# inherit it through SKOOBOT_HARNESS_HOST, which Enter-HarnessLease sets on
# this process -- so every birth and every soak finds the lease already theirs
# and none of them fights the sweep for the game.
if (-not $NoRunLease) {
    $null = Wait-HarnessLease -TimeoutSec ($LeaseWaitMin * 60) -Label 'sweep'
    Write-Host "[sweep] holding the game lease for this run (host pid $PID)"
}

$results = @()
$i = 0
try {
    foreach ($p in $plan) {
        $i++
        $slug = Slug $p.Class
        $save = "sweep-$(Slug $p.Race)-$slug"
        $json = Join-Path $OutDir "$slug.json"
        $tag  = "[{0}/{1}] {2}" -f $i, $plan.Count, $p.Class

        if ($p.Skip) {
            Write-Host "$tag  SKIPPED ($($p.Skip))"
            $results += [pscustomobject]@{ Class = $p.Class; Tree = $p.Tree; Race = $p.Race; Outcome = 'SKIPPED'; Detail = $p.Skip }
            continue
        }
        if ((Test-Path $json) -and -not $Force) {
            Write-Host "$tag  (already done; -Force to re-run)"
            $results += (Get-Content $json -Raw | ConvertFrom-Json)
            continue
        }

        # --- birth -------------------------------------------------------
        $saveDir = Join-Path $env:USERPROFILE ("T-Engine\4.0\tome\save\" + ($save -replace '-', '_'))
        $born = $SkipBirth -and (Test-Path (Join-Path $saveDir 'game.teag'))
        if (-not $born) {
            Write-Host "$tag  birthing as $($p.Race)..."
            $bargs = @('-ExecutionPolicy', 'Bypass', '-File', (Join-Path $PSScriptRoot 'new-character.ps1'),
                       '-Name', $save, '-Class', $p.Class, '-Race', $p.Race, '-BirthTimeoutSec', $BirthTimeoutSec)
            $bout = & powershell @bargs 2>&1
            $born = ($LASTEXITCODE -eq 0) -and (Test-Path (Join-Path $saveDir 'game.teag'))
            if (-not $born) {
                $why = ($bout | Select-String 'FAILED' | Select-Object -Last 1)
                Write-Host "$tag  UNBIRTHABLE - $why"
                $row = [pscustomobject]@{ Class = $p.Class; Tree = $p.Tree; Race = $p.Race; Outcome = 'UNBIRTHABLE'
                                          Detail = "$why"; Save = $save }
                ($row | ConvertTo-Json -Depth 4) | Set-Content $json -Encoding utf8
                $results += $row
                continue
            }
        }

        # --- run ---------------------------------------------------------
        Write-Host "$tag  running $Minutes min..."
        $soakOut = Join-Path $OutDir "$slug.soak.json"
        $sargs = @('-ExecutionPolicy', 'Bypass', '-File', (Join-Path $PSScriptRoot 'soak.ps1'),
                   '-SaveName', $save, '-MaxMinutes', $Minutes, '-MaxLevel', 50,
                   '-OutFile', $soakOut, '-NoRunLease')
        $null = & powershell @sargs 2>&1

        if (-not (Test-Path $soakOut)) {
            Write-Host "$tag  ERROR - the run wrote no result record"
            $row = [pscustomobject]@{ Class = $p.Class; Tree = $p.Tree; Race = $p.Race; Outcome = 'ERROR'
                                      Detail = 'no soak result record'; Save = $save }
            ($row | ConvertTo-Json -Depth 4) | Set-Content $json -Encoding utf8
            $results += $row
            continue
        }

        $s = Get-Content $soakOut -Raw | ConvertFrom-Json
        # The zone trail is "zone:level" per distinct step. A second entry that
        # is not the first IS the floor being cleared -- either a descent
        # within the zone or leaving it.
        $trail = @($s.zones)
        $first = $(if ($trail.Count -gt 0) { $trail[0] } else { '?' })
        $moved = @($trail | Where-Object { $_ -ne $first }).Count -gt 0

        $outcome = 'STUCK'
        if     ($s.lua_errors.count -gt 0) { $outcome = 'ERROR' }
        elseif ($s.deaths -gt 0)           { $outcome = 'DIED'  }
        elseif ($moved)                    { $outcome = 'CLEARED' }

        $top = $(if ($s.stops -and @($s.stops).Count -gt 0) { "$(@($s.stops)[0].reason) x$(@($s.stops)[0].count)" } else { '' })
        $row = [pscustomobject]@{
            Class    = $p.Class
            Tree     = $p.Tree
            Race     = $p.Race
            Outcome  = $outcome
            Save     = $save
            Trail    = ($trail -join ' > ')
            CharLevel= "$($s.level.start)->$($s.level.end)"
            Turns    = $s.turns.delta
            Deaths   = $s.deaths
            Killer   = $s.killer
            LuaErrors= $s.lua_errors.count
            Descents = $s.rungs.descend.taken
            Stops    = $s.stop_total
            TopStop  = $top
            EndReason= $s.end_reason
            Tainted  = $s.tainted
            Soak     = (Split-Path -Leaf $soakOut)
        }
        ($row | ConvertTo-Json -Depth 4) | Set-Content $json -Encoding utf8
        $results += $row
        Write-Host ("$tag  {0}  [{1}]  turns={2} stops={3}" -f $outcome, $row.Trail, $row.Turns, $row.Stops)
    }
}
finally {
    Stop-Game
}

# ---- the table the morning is read from ---------------------------------
$cleared = @($results | Where-Object { $_.Outcome -eq 'CLEARED' }).Count
$ran     = @($results | Where-Object { $_.Outcome -in @('CLEARED','DIED','STUCK','ERROR') }).Count
$pct     = $(if ($ran -gt 0) { [math]::Round(100 * $cleared / $ran) } else { 0 })

$md = New-Object System.Collections.Generic.List[string]
$md.Add("# Class baseline sweep -- $Race, $Minutes min per class")
$md.Add('')
$md.Add("**$cleared of $ran cleared their first floor ($pct%).** Stair-taking is the harness's descend rung once the level reports itself explored; the clearing is the bot's.")
$md.Add('')
$md.Add('| Class | Tree | Race | Outcome | Floors | Char lvl | Turns | Stops | Descents | Most common stop |')
$md.Add('|---|---|---|---|---|---|---|---|---|---|')
foreach ($r in ($results | Sort-Object @{e={$_.Outcome}}, @{e={$_.Class}})) {
    $md.Add("| $($r.Class) | $($r.Tree) | $($r.Race) | **$($r.Outcome)** | $($r.Trail) | $($r.CharLevel) | $($r.Turns) | $($r.Stops) | $($r.Descents) | $($r.TopStop) |")
}
$md.Add('')
$md.Add('`Descents` counts stairs taken by the harness''s descend rung, not by the bot: it is how much of a `CLEARED` was injected. A `STUCK` row is not necessarily a class problem -- read the stop column first, because a known bug (a sealed door, #64) eating the whole budget looks exactly like a class that cannot cope.')
$md.Add('')
$md.Add('Skipped: town-start classes (#123) -- ' + ($TOWN_STARTS -join ', ') + '. Steamtech classes are campaign-gated and never appear in a Maj''Eyal roster.')

$mdPath = Join-Path $OutDir 'summary.md'
Set-Content -Path $mdPath -Value $md -Encoding utf8

Write-Host ''
foreach ($l in $md) { Write-Host $l }
Write-Host ''
Write-Host "[sweep] PASS - $cleared/$ran cleared ($pct%); table at $mdPath"
exit 0
