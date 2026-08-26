<#
    The class baseline sweep (#123): birth one character of every measurable
    class, run each for a bounded time, and report whether it cleared its
    first floor.

    A TRIAGE INSTRUMENT, NOT A GATE. The output is a table and, from it, one
    issue per class that cannot get through floor one. A 30-50% pass rate is
    the expected result and not a failure of the run; 100% would mean the
    bound was too loose to find anything.

    WHAT "CLEARED" MEANS HERE. The character reached a DEEPER FLOOR OF ITS
    STARTING ZONE. Reaching a different zone does not count: the two ways that
    happens are both the harness moving the character rather than the
    character earning it -- the soak's next-zone rung teleporting out of a
    finished zone, and a death with lives left being rescued to the Eidolon
    plane and dropped somewhere new.

    The bot does the clearing -- survive the floor and explore it to
    exhaustion -- and the harness presses '>'. That division is deliberate and
    is counted per class in `descents`, so a CLEARED never over-claims. Note
    the counter is the soak's `stairs-down` RESUME, not `rungs.descend`: the
    descend rung only fires when the harness had to walk to the stairs, and
    auto-explore usually walks there itself (#121), so reading descend alone
    reports zero injected descents on a run that was entirely injected.

    Scoring by FLOOR rather than by zone is the owner's call for a faster
    first pass (2026-08-25).

    -Minutes IS A CAP, NOT A TARGET. A class that clears floor one in thirty
    seconds keeps going until the budget is spent, so the trail routinely runs
    deeper than the question needs. Two consequences, and both are scoring
    rules rather than notes:

      * CLEARED OUTRANKS DIED. A class that clears floor one and dies on floor
        three has answered this sweep's question yes. The death is recorded
        beside it (`Deaths`, `DiedAfter`, `Killer`), never instead of it.
      * THE EIDOLON PLANE IS A DEATH, NOT A FLOOR. A death with lives left
        teleports there and the rescue RESETS player.dead (#61), so it can be
        the only evidence a death happened -- and counting it as a second
        floor would turn a death into a CLEARED. It is excluded from the trail
        for scoring and counted in `Eidolon`.

    The per-class soak records are kept beside the results, so a scoring rule
    that turns out to be wrong can be re-applied to a finished sweep without
    re-running any of it.

    WHAT IS MEASURED, AND WHAT IS NOT:
      * the roster comes from tools/unlock-classes.ps1 and is PER-RACE, since
        a class whose special_check rejects the race is absent from the tree
        rather than locked (Cornac 30, Dwarf 31 -- the extra is Stone Warden);
      * the five TOWN-START classes are skipped by decision (#123) and are in
        any case unbirthable by the harness today: Archmage reaches
        town-angolwen and stops on an untitled dialog with no EXIT bind;
      * the four Steamtech classes never appear in a Maj'Eyal roster at all --
        they are campaign-gated, and are their own sweep (owner, 2026-08-25).

    WHAT THE ROTATION ACTUALLY IS, which is not what this file claimed until
    #130 went looking. The rules come from tools/soak.ps1's own `sk.rules()`,
    which is NOT the loadout proposal: it walks p.talents and puts every
    activated talent into Combat, filtered only by no_npc_use / no_dumb_use /
    hide. So this measures A CRUDE SUPERSET of the suggested build, and a
    class that does badly here may be carrying talents the product would never
    have proposed.

    That matters for reading the results: "classes that perform sub-optimally
    with the suggested build" is the question this was built for, and it is
    NOT yet the question being answered. Pointing the sweep at
    bot.loadout.propose is the change that would make the claim true, and it
    is worth making before the numbers are used to judge classes.

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

        # The Eidolon plane is where a death with lives left puts you, and the
        # rescue RESETS player.dead -- so it is a death in the trail rather
        # than a floor, and it may be the only evidence of one (#61). Counting
        # it as a floor would turn a death into a CLEARED.
        $eidolon   = @($trail | Where-Object { $_ -like 'eidolon-plane*' }).Count
        $realTrail = @($trail | Where-Object { $_ -notlike 'eidolon-plane*' })
        $firstReal = $(if ($realTrail.Count -gt 0) { $realTrail[0] } else { '?' })
        $startZone = ($firstReal -split ':')[0]

        # A DEEPER FLOOR OF THE STARTING ZONE, and nothing else. Reaching a
        # different zone does not count, because the two ways that happens are
        # both the harness moving the character rather than the character
        # earning it: the soak's next-zone rung teleports out of a finished
        # zone, and a death with lives left is rescued to the Eidolon plane and
        # then dropped somewhere new. The first pass had both, and both read as
        # CLEARED: Doomed died on trollmire:1 and was scored a pass because the
        # rescue put it in ruins-kor-pul.
        $cleared = @($realTrail | Where-Object {
            $_ -ne $firstReal -and ($_ -split ':')[0] -eq $startZone
        }).Count -gt 0

        # Whether this run is comparable with the rest. A class that begins in
        # a DLC zone cleared *a* first floor, but not the same one, so its row
        # is reported and left out of the headline.
        $comparable = ($startZone -eq 'trollmire')

        # CLEARED outranks DIED, because the question this sweep answers is
        # "did this class get off its FIRST floor" and the run keeps going for
        # the whole budget afterwards. A class that clears floor one and then
        # dies on floor three has answered the question yes; the death is
        # recorded beside it rather than replacing it.
        $outcome = 'STUCK'
        if     ($s.lua_errors.count -gt 0)          { $outcome = 'ERROR' }
        elseif ($cleared)                           { $outcome = 'CLEARED' }
        elseif ($s.deaths -gt 0 -or $eidolon -gt 0) { $outcome = 'DIED' }

        # The TOP THREE stops, not one. A class does not report "out of mana";
        # it reports whatever the rotation did instead, and the shape of that
        # only shows up across several reasons (owner, 2026-08-25). The full
        # histogram stays in the .soak.json beside this.
        $top3 = @(@($s.stops) | Select-Object -First 3 | ForEach-Object { "$($_.reason) x$($_.count)" })
        $top  = ($top3 -join ' ; ')
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
            Eidolon  = $eidolon
            DiedAfter= ($cleared -and ($s.deaths -gt 0 -or $eidolon -gt 0))
            Killer   = $s.killer
            LuaErrors= $s.lua_errors.count
            # The stairs the HARNESS took, which is rungs.descend only when it
            # had to walk there first. Auto-explore usually walks there itself
            # (#121), and the soak then fires CHANGE_LEVEL as its 
            # resume -- so reading descend.taken alone reports 0 injected
            # descents on a run that was entirely injected.
            Descents = ((@($s.resumes.by_action) | Where-Object { $_.action -eq 'stairs-down' } | ForEach-Object { $_.count }) + 0)[0] + $s.rungs.descend.taken
            NextZone = $s.rungs.next_zone.taken
            StartZone= $startZone
            Comparable = $comparable
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
# The headline counts COMPARABLE runs only: a class that starts in a DLC zone
# cleared a first floor, but not the same one, so its row is printed and left
# out of the percentage rather than quietly averaged into it.
$judged  = @($results | Where-Object { $_.Outcome -in @('CLEARED','DIED','STUCK','ERROR') -and $_.Comparable })
$cleared = @($judged | Where-Object { $_.Outcome -eq 'CLEARED' }).Count
$ran     = $judged.Count
$offZone = @($results | Where-Object { $_.Outcome -in @('CLEARED','DIED','STUCK','ERROR') -and -not $_.Comparable })
$pct     = $(if ($ran -gt 0) { [math]::Round(100 * $cleared / $ran) } else { 0 })

$md = New-Object System.Collections.Generic.List[string]
$md.Add("# Class baseline sweep -- $Race, $Minutes min per class")
$md.Add('')
$md.Add("**$cleared of $ran cleared their first floor ($pct%).** Comparable runs only -- every class starting in Trollmire. The clearing is the bot's; the harness presses '>' and `Descents` says how often.")
if ($offZone.Count -gt 0) {
    $md.Add('')
    $md.Add("Reported but NOT in that percentage, because they do not start in Trollmire and so did not clear the same floor: " + (($offZone | ForEach-Object { "$($_.Class) ($($_.StartZone))" }) -join ', ') + '.')
}
$md.Add('')
$md.Add('| Class | Tree | Race | Outcome | Floors | Char lvl | Turns | Stops | Descents | Most common stops |')
$md.Add('|---|---|---|---|---|---|---|---|---|---|')
foreach ($r in ($results | Sort-Object @{e={$_.Outcome}}, @{e={$_.Class}})) {
    $md.Add("| $($r.Class) | $($r.Tree) | $($r.Race) | **$($r.Outcome)** | $($r.Trail) | $($r.CharLevel) | $($r.Turns) | $($r.Stops) | $($r.Descents) | $($r.TopStop) |")
}
$md.Add('')
$md.Add('`Descents` counts stairs the HARNESS took, so it says how much of a `CLEARED` was injected; the clearing itself is the bot''s. A `STUCK` row is not necessarily a class problem -- read the stop column first, because a known bug eating the whole budget (a sealed door, #64; a talent that opens a dialog every turn) looks exactly like a class that cannot cope.')
$md.Add('')
$md.Add('Skipped: town-start classes (#123) -- ' + ($TOWN_STARTS -join ', ') + '. Steamtech classes are campaign-gated and never appear in a Maj''Eyal roster.')

$mdPath = Join-Path $OutDir 'summary.md'
Set-Content -Path $mdPath -Value $md -Encoding utf8

Write-Host ''
foreach ($l in $md) { Write-Host $l }
Write-Host ''
Write-Host "[sweep] PASS - $cleared/$ran cleared ($pct%); table at $mdPath"
exit 0
