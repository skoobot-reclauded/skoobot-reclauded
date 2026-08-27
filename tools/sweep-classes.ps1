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

    WHAT THE ROTATION IS. The product's own loadout proposal -- what a player
    who accepted the talent screen's suggestion would be running -- via
    soak.ps1 -ProposedRules. That is the point: "classes that perform
    sub-optimally with the suggested build" is the question this exists for.

    It was NOT that for the first pass, and the results of that run should be
    read accordingly. Until #130 went looking, the rotation came from
    soak.ps1's sk.rules(), which walks p.talents and puts every activated
    talent into Combat -- a crude superset that a player would never have.
    The run's `rules_source` field records which was used.

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
    [switch]$NoRunLease,
    # Skip pointing the game's junctions at this checkout.
    [switch]$NoSetup,
    # #160: put every class in this zone before its run, whatever birth chose.
    # Cheating on purpose. It retires the two exclusions that were never about
    # the class -- town starts (#123) and island starts (#149) -- because both
    # are about where birth HAPPENS to put someone, which is exactly the
    # variable a controlled measurement should remove. '' restores the old
    # behaviour and the exclusions with it.
    [string]$StartZone = 'norgos-lair',
    # Record creature dossiers (#135). Off by default; see soak.ps1 -Dossier.
    [switch]$Dossier,
    # The player's stop-condition knobs for every run, passed to soak.ps1.
    #
    # The power conditions ship as STOP, and a STOP whose cause stays in view
    # stops on the spot at every restart -- by design, that is the product
    # handing the game to the player. For a MEASUREMENT run it means any class
    # that meets a boss above MAX_DIFF_POWER scores STUCK for a reason that has
    # nothing to do with the class, and the sweep passed nothing at all until
    # now (#123). fixture-berserker meeting Prox the Mighty is the case that
    # surfaced it.
    #
    # WARN rather than IGNORE by default: the run continues, and the flag is
    # still raised and recorded -- which is exactly what #135's corpus needs to
    # tell "died to a warned enemy" from "died with nothing raised". Pass
    # IGNORE for raw capability, or '' to measure the shipped defaults.
    #
    # LIFE_LOWLIFE is in the list for the same reason and it is the bigger one:
    # it ships as STOP, so any class that drops below the ratio with an enemy
    # in view stops there for good and scores STUCK. A six-minute soak on the
    # fixture ended exactly that way. A class that would have died should die
    # -- the death is a measurement and #135 records it, with the flags that
    # were raised -- whereas STUCK says only that the product handed over.
    # Expect more deaths in the table than the first sweeps showed, and expect
    # them to mean something.
    [string]$Conditions = 'SCOUTER_STRONGERENEMY=WARN,SCOUTER_BIGENEMY=WARN,SCOUTER_CROWDPOWER=WARN,SCOUTER_ENEMYCOUNT=WARN,LIFE_LOWLIFE=WARN'
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'harness.ps1')

$RepoRoot = Split-Path -Parent $PSScriptRoot
# Where a comparable run begins: the zone every class is placed in (#160), or
# Trollmire when placement is off and birth decides.
$expectedStart = $(if ($StartZone) { $StartZone } else { 'trollmire' })

# Classes known to begin in a town rather than on a dungeon floor, from their
# descriptors' starting_zone (data/birth/classes/{mage,celestial,
# chronomancer}.lua): town-angolwen, town-gates-of-morning, town-point-zero.
# Skipped by decision (#123) and unbirthable in any case.
#
# This list is a HINT, not the test. It cannot see the DLC classes -- their
# descriptors ship in .teaac and cannot be read -- and Writhing One duly slipped
# through it and spent a whole run walking into a shop in cults+town-kroshkkur
# (#134). The zone the character actually lands in is checked after birth
# below, which needs no list and covers whatever an addon adds.
$TOWN_STARTS = @('Archmage', 'Sun Paladin', 'Anorithil', 'Paradox Mage', 'Temporal Warden')

# Classes whose result says more about the BUILD than about the class, and so
# measures nothing until build automation (#88) exists.
#
# Owner, 2026-08-26, on Adventurer: "it's a naked class ... intended to spend
# category points to select from any tree in the game. its performance will be
# incredibly build related ... testing a dude punching forest trolls one by one
# and chugging infusion heals until it gets in a 1v2 that it can't outheal isn't
# very informative."
#
# Sweep 1 bears that out exactly: DIED to a forest troll at character level 3,
# having spent the run in melee with no talents worth the name.
#
# Skipped BY DEFAULT, not removed: -Only Adventurer still runs it, because the
# day there are builds tailored for the bot this is the most interesting class
# on the roster rather than the least.
$BUILD_DEPENDENT = @{
    'Adventurer' = 'build-dependent: no class talents of its own, and no build automation yet (#88)'
}

# Zones the bot cannot cross, so a class that starts in one cannot produce a
# comparable floor however well it plays.
#
# Owner, 2026-08-26: "demonologist and at least one other class spawn on an
# island with nontrivial navigation. I think they have to use some temporary
# teleport ability to island hop."
#
# Sweep 1 measured exactly that: Demonologist and Doombringer are the only two
# ashes-urhrok+searing-halls starters and both ended STUCK on floor 1 without
# ever leaving it -- one pacing an island edge for 130,393 turns with no stops
# (#145), the other handing back "no path to losgoroth" thirty-seven times
# (#146). Both are the same cause: what they could see, they could not walk to.
#
# Keyed on the ZONE rather than the class, as the town skip is, so a class
# added later that starts there is covered without being named.
$UNNAVIGABLE_ZONES = @{
    'ashes-urhrok+searing-halls' = 'island start: needs a traversal the bot does not have (#149)'
}

function Test-UnnavigableZone([string]$zone) {
    if (-not $zone) { return $null }
    foreach ($k in $UNNAVIGABLE_ZONES.Keys) { if ($zone -like "$k*") { return $UNNAVIGABLE_ZONES[$k] } }
    return $null
}

# A zone id that is a town. ToME names them consistently -- town-angolwen,
# town-point-zero, cults+town-kroshkkur -- so the segment test covers the DLC
# ones without naming them.
function Test-TownZone([string]$zone) {
    if (-not $zone) { return $false }
    foreach ($seg in ($zone -split '\+')) { if ($seg -like 'town-*') { return $true } }
    return $false
}

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
    if (-not $StartZone -and $TOWN_STARTS -contains $r.Class) { $skip = "town start" }
    if ($BUILD_DEPENDENT.ContainsKey($r.Class)) { $skip = $BUILD_DEPENDENT[$r.Class] }
    if ($wanted.Count -gt 0 -and $wanted -notcontains $r.Class) { continue }
    # Asking for a class by name overrides a default skip: the skips are about
    # what a WHOLE-ROSTER sweep should spend its time on, not about what may be
    # run.
    if ($wanted -contains $r.Class) { $skip = $null }
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
# Point the game at THIS checkout before anything else. The harness refuses to
# load when the junctions point elsewhere -- correctly -- but it refuses at the
# first birth, minutes in, after the lease is taken and a class is already
# half-created. A sweep launched from a worktree, or after a scenario was run
# from one, hit that every time; the guard caught it, and the run was still lost.
#
# setup-dev is idempotent and cheap, so doing it here costs a second and removes
# the whole class of "measured the wrong build" and "failed eight minutes in".
if (-not $NoSetup) {
    $sd = & powershell -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'setup-dev.ps1') 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host ($sd | Out-String)
        Fail "setup-dev failed; the junctions do not point at $RepoRoot"
    }
    Write-Host "[sweep] junctions point at $RepoRoot"
}

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
        # Get-SaveDirName, not a second copy of the rule. This line had its own
        # and it was wrong: it never truncated, so a class whose save name is
        # over 25 characters was looked for in a directory the engine never
        # creates. Cultist of Entropy was reported UNBIRTHABLE in eight sweeps
        # with a valid save on disk the whole time, and fixing harness.ps1 alone
        # left this copy still wrong -- exactly what #121 records about a fact
        # kept in two places.
        $saveDir = Join-Path $script:SaveRoot (Get-SaveDirName -Name $save)
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

        # --- where did it land? ------------------------------------------
        # A town start cannot be compared with a dungeon floor and has nothing
        # to explore, so it is skipped here rather than after burning the
        # budget. Read from the save's own zone, so a class no list knows about
        # is still caught (#134).
        $zone = & powershell -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'read-save-zone.ps1') -SaveName $save 2>&1 |
                Select-String '^ZONE ' | ForEach-Object { ($_ -split ' ')[1] } | Select-Object -First 1
        $unnav = $(if ($StartZone) { $null } else { Test-UnnavigableZone $zone })
        if ((-not $StartZone) -and ((Test-TownZone $zone) -or $unnav)) {
            $why = $(if ($unnav) { "$unnav ($zone)" } else { "town start: $zone" })
            Write-Host "$tag  SKIPPED ($why)"
            $row = [pscustomobject]@{ Class = $p.Class; Tree = $p.Tree; Race = $p.Race; Outcome = 'SKIPPED'
                                      Detail = $why; Save = $save; StartZone = $zone; Comparable = $false }
            ($row | ConvertTo-Json -Depth 4) | Set-Content $json -Encoding utf8
            $results += $row
            continue
        }

        # --- run ---------------------------------------------------------
        Write-Host "$tag  running $Minutes min..."
        $soakOut = Join-Path $OutDir "$slug.soak.json"
        $sargs = @('-ExecutionPolicy', 'Bypass', '-File', (Join-Path $PSScriptRoot 'soak.ps1'),
                   '-SaveName', $save, '-MaxMinutes', $Minutes, '-MaxLevel', 50,
                   '-OutFile', $soakOut, '-NoRunLease', '-ProposedRules')
        if ($Dossier) { $sargs += '-Dossier' }
        if ($Conditions) { $sargs += @('-Conditions', $Conditions) }
        if ($StartZone) { $sargs += @('-StartZone', $StartZone) }
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
        # #162: keyed on where the run ACTUALLY started, not on a hardcoded
        # zone name. That hardcoding was right while birth chose the zone and
        # Trollmire was simply where most classes began; #160 made the start a
        # choice, and leaving it would have printed 0% comparable the moment the
        # choice was anything else.
        $comparable = ($startZone -eq $expectedStart)

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
        # #178: light radius, surfaced per class rather than left in the soak
        # JSON, because the prediction it tests is a PER-CLASS one -- starting
        # equipment differs by class, and a column nobody sees is a column
        # nobody correlates. "start->end" because a lantern found on floor one
        # is the interesting case.
        $lite = '?'
        if ($s.vision -and $s.vision.start) {
            $lite = "$($s.vision.start.lite)"
            if ($s.vision.end -and $s.vision.end.lite -ne $s.vision.start.lite) {
                $lite += "->$($s.vision.end.lite)"
            }
        }
        $row = [pscustomobject]@{
            Class    = $p.Class
            Tree     = $p.Tree
            Race     = $p.Race
            Lite     = $lite
            Outcome  = $outcome
            Save     = $save
            Trail    = ($trail -join ' > ')
            CharLevel= "$($s.level.start)->$($s.level.end)"
            Turns    = $s.turns.delta
            Deaths   = $s.deaths
            Eidolon  = $eidolon
            DiedAfter= ($cleared -and ($s.deaths -gt 0 -or $eidolon -gt 0))
            Killer   = $s.killer
            # #132: escorts per class. SelfKill is the number this exists for --
            # the escortee killed by this character's own effects, which is
            # otherwise indistinguishable from one killed by a troll.
            Escorts  = (($s.escorts.granted, 0) -ne $null)[0]
            EscDone  = (($s.escorts.done, 0) -ne $null)[0]
            EscFail  = (($s.escorts.failed, 0) -ne $null)[0]
            SelfKill = (($s.escorts.selfkills, 0) -ne $null)[0]
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
# #175: which code this measured. Resolved from the junction the game loads,
# not from this script's directory, and carrying the uncommitted count because
# a hash on its own lies whenever someone is mid-edit.
$sweepBuild = Get-BuildStamp -GameDir $script:GameDir
$md.Add("Measured on **``$($sweepBuild.short)``**$(if ($sweepBuild.dirty -gt 0) { " plus **$($sweepBuild.dirty) uncommitted file(s)**" }) in ``$(Split-Path -Leaf $sweepBuild.repo)`` -- $($sweepBuild.subject)")
$md.Add('')
$md.Add("**$cleared of $ran cleared their first floor ($pct%).** Comparable runs only -- every class starting in ``$expectedStart``. The clearing is the bot's; the harness presses '>' and `Descents` says how often.")
$md.Add('')
# What the numbers mean depends entirely on this, so it is never left implied.
if ($Conditions) {
    $md.Add("Stop conditions for every run: ``$Conditions``. The power conditions ship as STOP, which ends a run on the spot wherever a boss stays in view -- so a sweep left at the defaults measures where the product hands over, not what the class can do.")
} else {
    $md.Add('Stop conditions: **the shipped defaults**. The power conditions are STOP, so any class that met an enemy above MAX_DIFF_POWER stopped there and its outcome says nothing about the class.')
}
if ($offZone.Count -gt 0) {
    $md.Add('')
    $md.Add("Reported but NOT in that percentage, because they do not start in $expectedStart and so did not clear the same floor: " + (($offZone | ForEach-Object { "$($_.Class) ($($_.StartZone))" }) -join ', ') + '.')
}
$md.Add('')
$md.Add('| Class | Tree | Race | Outcome | Floors | Char lvl | Turns | Stops | Descents | Escorts | Most common stops |')
$md.Add('|---|---|---|---|---|---|---|---|---|---|---|')
foreach ($r in ($results | Sort-Object @{e={$_.Outcome}}, @{e={$_.Class}})) {
    $esc = if ($r.Escorts -gt 0) { "$($r.EscDone)/$($r.Escorts)$(if ($r.SelfKill -gt 0) { " **-$($r.SelfKill) self**" })" } else { '-' }
    $md.Add("| $($r.Class) | $($r.Tree) | $($r.Race) | **$($r.Outcome)** | $($r.Trail) | $($r.CharLevel) | $($r.Turns) | $($r.Stops) | $($r.Descents) | $esc | $($r.TopStop) |")
}
$md.Add('')
$md.Add('`Descents` counts stairs the HARNESS took, so it says how much of a `CLEARED` was injected; the clearing itself is the bot''s. A `STUCK` row is not necessarily a class problem -- read the stop column first, because a known bug eating the whole budget (a sealed door, #64; a talent that opens a dialog every turn) looks exactly like a class that cannot cope.')
$md.Add('')
if ($StartZone) { $md.Add("Every class was PLACED in ``$StartZone`` before its run (#160) -- it did not walk there. Town-start and island-start exclusions do not apply."); $md.Add('') }
$md.Add('Skipped: town-start classes (#123) -- ' + ($TOWN_STARTS -join ', ') + '. Steamtech classes are campaign-gated and never appear in a Maj''Eyal roster.')
$md.Add('')
$md.Add('')
$md.Add('Also skipped on arrival, because the bot cannot cross them: ' + (($UNNAVIGABLE_ZONES.Keys | Sort-Object) -join ', ') + ' (#149).')
$md.Add('Also skipped as build-dependent, which measures the build rather than the class until #88: ' + (($BUILD_DEPENDENT.Keys | Sort-Object) -join ', ') + '. Run one anyway with ``-Only <class>``.')

$mdPath = Join-Path $OutDir 'summary.md'
Set-Content -Path $mdPath -Value $md -Encoding utf8

Write-Host ''
foreach ($l in $md) { Write-Host $l }
Write-Host ''
Write-Host "[sweep] PASS - $cleared/$ran cleared ($pct%); table at $mdPath"
exit 0
