<#
    Soak (#61): an unattended long run of the bot on the fixture, measured.

    The question this answers is not "does it pass" but "how far does it get,
    and what stops it": levels reached, turns taken, every stop reason with
    its count, every death with its killer, every Lua error the engine
    logged. That is the long-term replacement for the hand-played 1-to-15
    run the owner ruled out as a release gate (docs/release-0.1.md).

    The bot stops on purpose, often -- that is its design (docs/design-stop-
    conditions.md). A player restarts it; here a RESUME POLICY does, so the
    run keeps going and the stops are counted instead of ending the
    measurement at the first one. The policy is a measuring device and
    nothing else: it is NOT product behaviour, it never spends a point or
    writes a stat, and every action it takes is counted and reported so a
    number in the summary can be read for what it is.

      (a) a dialog is open   close it through its own EXIT bind (the level-up
                             dialog closes with nothing allocated; a popup
                             just closes). One with ACCEPT but no EXIT gets
                             ACCEPT ("accept-dialog"). A Chat has no binds
                             at all and cannot be escaped: its FIRST answer
                             is given through the dialog's own use(), the
                             method typing the answer's letter calls, and
                             the answer's text is reported ("answer-chat").
                             The death dialog is never touched: death ends
                             the run.
      (b) "standing on a     stairs DOWN, or into another non-wilderness
          level change"      zone: trigger the game's CHANGE_LEVEL bind once.
                             Stairs UP or into the wilderness: one real move
                             off the tile (the bot cannot run in the
                             wilderness, and up is not progress).
      (c) the same reason    REST through the game's bind, once; if it
          5 times in a row   recurs, one real move off the tile, once (the
          with no turn taken engine's auto-explore re-targets an ADJACENT
                             vault door forever; only distance breaks it);
                             if it still recurs with no turn taken, record
                             "STUCK <reason>" and end the run.
      (d) the player is dead record the killer (game.player.killedBy, which
                             onPartyDeath sets) and end.
      (e) anything else      skoobot_reclauded.start() again.
      (f) DESCEND WHEN       the hand-back is on stairs UP or the wilderness
          EXPLORED           exit, and either the level is explored or this is
                             the -DescendAfter'th such hand-back on this level
                             (the first long run spent 271 of 338 stops there:
                             once a level is explored the engine's auto-explore
                             targets an exit and keeps that target, so (b)'s
                             step-off restarted a bot that walked straight
                             back). If a DOWN staircase the player has SEEN is
                             reachable through tiles the player has seen, walk
                             to it -- the engine's own A* (engine.Astar, the
                             same call the bot's combat pathing makes), one
                             real move per poll, spending turns like a player,
                             handing back to the bot the moment a hostile is
                             in view -- and take it with CHANGE_LEVEL. Counted
                             as "descend"; every move is counted too. No seen
                             down staircase: fall through to (b).
                             -NoDescend turns the rung off.
                             The same trigger also fires on a LOOP the soak
                             cannot step out of: one hand-back reason recurring
                             -LoopAfter times on one level (the second
                             validation run spent all 12 minutes and 78 of 79
                             stops in #64's sealed-door loop, one tile from the
                             door, because (c)'s step-away moves one tile and
                             the bot's own pathing walks back). A walk started
                             that way hands back only for an ADJACENT hostile:
                             one merely in view, that the bot cannot reach, is
                             what the loop is made of.
      (g) NEXT ZONE          the level is the zone's last (game.zone.max_level)
                             and (f)'s trigger holds, or the hand-back is on
                             the wilderness exit of an explored level with no
                             seen down staircase: the engine's own transition,
                             game:changeLevel(1, zone) -- the call a step onto
                             a zone entrance on the world map makes
                             (Game.lua:2292) -- to the first zone of the list
                             below not yet visited, whose level_range minimum
                             is at most the character's level + 2. Counted as
                             "next-zone". The wilderness is never entered: the
                             bot cannot run there, by design. -Zones "a,b,c"
                             replaces the list.
    Either (f) or (g) may be refused by the engine for two turns after a kill
    (changeLevelCheck); a turn is then passed through the MOVE_STAY bind and
    counted as "wait".

    THE ZONE LIST is a measurement carriage, not product: it is the order a
    player of this level would usually take the early dungeons in, and it
    exists only so a run can keep measuring past the first zone. Ids and
    level ranges verified against data/zones/<id>/zone.lua in ToME 1.7.6
    (2026-08-23), and re-read from the installed module at start: an id with
    no zone.lua is dropped and reported. "kor-pul" is not a zone; the ruins
    are "ruins-kor-pul".

        trollmire            level_range 1-7    3 levels (alt layout: 3)
        ruins-kor-pul        level_range 1-7    3 levels
        norgos-lair          level_range 1-7    3 levels
        scintillating-caves  level_range 1-7    5 levels (alt layout: 3)
        rhaloren-camp        level_range 1-7    3 levels
        old-forest           level_range 7-16   4 levels
        daikara              level_range 7-16   4 levels
        maze                 level_range 7-16   4 levels (alt layout: 2)
        sandworm-lair        level_range 7-16   4 levels (no level connectivity:
                                                the tunnellers dig the way)

    By default the fixture's Combat, Sustain and Recovery rules are filled
    from what the character knows (-NoAutoRules to skip): every usable
    activated talent in id order, then the innate Attack, so a fresh fixture
    can fight at all. A player would do this from the talent screen; the
    rule set is crude and is part of what the run measures.

    The fixture is never overwritten. The game autosaves on every level
    change under game.save_name, so that is re-pointed at -ScratchSave
    ("soak-scratch") right after loading; the fixture directory is not
    touched and the scratch save is overwritten by the next run.

    Ends on -MaxMinutes, -MaxLevel, -MaxTurns (game.turn units: 10 per player
    turn), death, the Eidolon taking the character (#141 -- which is a death
    the engine intercepted, and does NOT set `dead`), STUCK, a crash, or a
    bridge that stops answering. Writes a
    JSON summary to -OutFile (default build/results/soak-<stamp>.json), a
    markdown twin beside it, and prints the markdown.

    Exit codes:  0 the run ended by its own limits   1 it ended otherwise
                 (death, stuck, crash, bridge lost, could not load)
    A death is not a failure of the run -- it is the headline measurement --
    but exit 1 makes it visible to whatever scheduled the soak.

    Run:
        powershell -ExecutionPolicy Bypass -File .\tools\soak.ps1
        powershell -ExecutionPolicy Bypass -File .\tools\soak.ps1 -MaxMinutes 6
        powershell -ExecutionPolicy Bypass -File .\tools\soak.ps1 -MaxMinutes 240 -MaxLevel 15
        powershell -ExecutionPolicy Bypass -File .\tools\soak.ps1 -Conditions "SCOUTER_STRONGERENEMY=WARN,SCOUTER_BIGENEMY=WARN"
        powershell -ExecutionPolicy Bypass -File .\tools\soak.ps1 -NoDescend -Zones "trollmire,ruins-kor-pul"

    The -Conditions form is for measuring past the product's own hand-back: the
    power-level conditions are STOP by default, and a STOP whose cause stays
    in view -- an enemy above MAX_DIFF_POWER -- stops every restart on the
    spot, by design, so a default run ends STUCK there. -Conditions sets the
    player's own WARN/STOP/IGNORE knobs for the run, through the product's
    conditions API, and the summary records what was set.

    #61, #27.
#>
[CmdletBinding()]
param(
    [string]$SaveName = 'fixture-berserker',
    [int]$MaxMinutes = 30,
    [int]$MaxLevel = 15,
    # game.turn units, 10 per player turn at normal speed; 0 = no limit.
    # Game turns to run for, counted from this run's first sample (#179).
    # game.turn advances 10 per player turn. 0 disables it and -MaxMinutes is
    # the only bound.
    #
    # Prefer this to -MaxMinutes whenever runs share a machine: a wall-clock
    # budget buys fewer game turns under contention -- measured here at 124
    # turns/sec against 7 busy cores versus 185 idle, a 33% loss -- so parallel
    # runs would look worse than serial ones for no reason but the scheduler.
    # A turn budget is the same measurement whatever else is running.
    [int]$MaxTurns = 0,
    [string]$OutFile,
    [int]$PollSec = 4,
    [switch]$NoAutoRules,
    # Fill the rotation from the PRODUCT's loadout proposal rather than from
    # every activated talent the character knows. What #123 wants, since it
    # asks how the SUGGESTED build performs.
    [switch]$ProposedRules,
    # Record creature dossiers at the moments that decide whether the power
    # formula was right (#135). OFF by default and installed only when asked:
    # not installed means no superload and no serialisation, so an ordinary run
    # pays nothing. Written beside the summary as <name>.dossier.json.
    [switch]$Dossier,
    # #138: on an ending that does not say WHY -- a timeout or a loop -- take
    # this many screenshots, injecting one harness action between them, before
    # the game is stopped.
    #
    # The first is taken before ANY input, or the evidence is of the harness
    # poking the game rather than of the state it got stuck in. The ones after
    # it show what happens when the harness tries to carry on, which is the
    # half a single frame cannot show.
    #
    # On by default, because the whole point is not having to have predicted
    # which run would need it. It costs nothing on a run that ends by its own
    # limits with something to show for it, and three PNGs when it does not.
    [int]$TimeoutActionCaptures = 3,
    # #86's stairs offer, for THIS CHARACTER only (never the account -- that
    # leak has been fixed once already).
    #
    # An unattended run must answer the offer, and the generic dialog closer
    # cannot: it presses EXIT first, and #86 deliberately made Escape on the
    # StairsDialog mean "not now". So the harness was declining its own descent
    # every time -- measured on Doomed in sweep 1, which spent 12,302 turns on
    # a fully explored trollmire:1 with a down staircase it had already found.
    #
    # 'always' answers it before it is ever asked. 'ask' leaves the product's
    # default in place and is what to use when the OFFER is what is being
    # measured rather than the depth.
    [ValidateSet('always', 'ask', 'never', 'leave')]
    [string]$TakeStairs = 'always',
    # #145: consecutive polls in which the clock moved and the character did
    # not. Demonologist burned a whole run at 130,393 game turns with ZERO
    # stops -- so every existing ending missed it, because they all key on a
    # stop reason repeating. Turns advancing while the character stands still
    # is the one signal that needs no stop to read.
    #
    # It is measured as DISTINCT POSITIONS over a window, not as a position
    # that never changes: the owner watched the Demonologist run back and forth
    # diagonally the whole time. A character pacing between two tiles is going
    # nowhere exactly as much as one standing on a single tile, and a
    # fixed-position test would have missed the run this exists for.
    #
    # 0 disables. Polls are a few seconds apart, so 15 is on the order of a
    # minute: long past anything a fight or a rest explains.
    # #158: spend stat and talent points automatically, so the sweep measures a
    # character that levelled up rather than one that never did. A band-aid for
    # the sweeps; the real feature is #88.
    # #160: put the character in this zone before the run starts, whatever
    # birth decided. Cheating, deliberately -- the harness is not bound to fair
    # play and the point is to exercise the logic on a comparable floor. Empty
    # leaves the character where birth put it.
    #
    # It retires two exclusions that were never about the class: town starts
    # (#123) and island starts (#149) are both about where birth HAPPENS to put
    # someone, which is exactly the variable a controlled measurement removes.
    [string]$StartZone = '',
    # #173 trials: which FLOOR of -StartZone to drop into. The interesting
    # creatures are rarely on floor 1 -- every Spellblaze Crystal death in the
    # corpus is on scintillating-caves 3 or 5 -- and walking down to them costs
    # most of a run's budget. Cheating, like -StartZone itself (#160).
    [int]$StartFloor = 1,
    # Level the character to this before starting, so a trial on a deep floor
    # is not just a level-1 character being deleted. XP only: the points are
    # then spent by the ordinary -NoAutoSpend path, so the build is the same
    # one a real run would have had.
    [int]$PreLevel = 0,
    [switch]$NoAutoSpend,
    # #161: polls to wait out a bindless progress dialog before calling it stuck.
    [int]$DialogWaitPolls = 12,
    [int]$IdleAfter = 15,
    # Distinct grids in that window that still count as going nowhere. 3 covers
    # standing still, pacing between two tiles, and a three-tile shuffle.
    [int]$IdleDistinct = 3,
    # The player's stop-condition policies for this run, "CODE=WARN|STOP|IGNORE,..."
    # (e.g. "SCOUTER_STRONGERENEMY=WARN,SCOUTER_BIGENEMY=WARN"), applied through
    # skoobot_reclauded.conditions.set and recorded in the summary.
    [string]$Conditions,
    [string]$ScratchSave = 'soak-scratch',
    # (c): how many identical stops with no turn taken before REST is tried.
    [int]$StuckAfter = 5,
    # (f): off. The up-stairs hand-back is then stepped off as before.
    [switch]$NoDescend,
    # (f): the number of hand-backs on stairs up / the wilderness exit, on one
    # level, after which the walk to a seen down staircase is tried even if
    # the level does not report itself explored.
    [int]$DescendAfter = 3,
    # (f): one hand-back reason recurring this many times on one level is a
    # loop the soak cannot step out of, and the walk is tried (again every
    # time the count reaches a multiple). 0 turns this trigger off.
    [int]$LoopAfter = 15,
    # (f): seconds between moves while walking; the ordinary poll is for the
    # bot's own turns, a move per poll needs no 4 s of thinking time.
    [int]$WalkPollSec = 1,
    # (f): a walk longer than this is abandoned (the map is 65x40 at most in
    # the zones listed; a path cannot honestly be longer).
    [int]$MaxWalkMoves = 400,
    # (g): "a,b,c" of zone ids, replacing the list at the top of this file.
    [string]$Zones,
    # How long to wait for another host to give the game up before starting
    # (#83). A soak wants the game for many minutes and used to hold NO lease
    # at all -- it attaches to a game some other, already-exited host
    # launched -- so any lane's scenario child could take the game out from
    # under a run in progress. It now holds one for the whole soak.
    [int]$LeaseWaitMin = 60,
    # Do not take a lease. For running under an outer host that holds one.
    [switch]$NoRunLease
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'harness.ps1')

# (g): the measurement carriage, in the order tried. Verified against ToME
# 1.7.6 data/zones/<id>/zone.lua (see the header); the ranges are re-read
# from the installed module at start and an id without a zone.lua is dropped.
# #162: a recommended progression, in order. next-zone takes the first entry it
# can use, so the ORDER here IS the route -- no travel code knows about it.
#
# From a community guide, with two of the owner's changes: Kor'Pul last, because
# its light-radius requirement is inventory work (#87) and the bot has none; and
# Trollmire just before it, because floor 4 is genuinely dangerous and the
# gentler zones are worth having first.
#
# Deep Bellow is Dwarf-only and is dropped below for anyone else.
$DefaultZones = @('norgos-lair', 'scintillating-caves', 'rhaloren-camp', 'heart-gloom',
                  'deep-bellow', 'trollmire', 'ruins-kor-pul',
                  'old-forest', 'daikara', 'maze', 'sandworm-lair')

# Zones only some races may enter. Left in the order and filtered per character,
# rather than omitted -- changeLevel would happily put a Cornac in the Deep
# Bellow and the run would be off-plan without saying so.
$ZONE_RACE = @{ 'deep-bellow' = 'Dwarf' }
$ZoneIds = @(if ($Zones) { $Zones -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ } } else { $DefaultZones })
foreach ($z in $ZoneIds) { if ($z -notmatch '^[a-z0-9+-]+$') { throw "[soak] -Zones: '$z' is not a zone id" } }

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
if (-not $OutFile) {
    if (-not (Test-Path $script:ResultsDir)) { New-Item -ItemType Directory -Path $script:ResultsDir -Force | Out-Null }
    $OutFile = Join-Path $script:ResultsDir "soak-$stamp.json"
}
$MdFile = [IO.Path]::ChangeExtension($OutFile, '.md')

Write-Host ''
Write-Host "[soak] save=$SaveName max=${MaxMinutes}m level>=$MaxLevel turns+=$MaxTurns poll=${PollSec}s out=$OutFile"
Write-Host "[soak] descend=$(if ($NoDescend) { 'off' } else { "after $DescendAfter or explored" }) zones=$($ZoneIds -join ',')"

# Hold the game for the whole soak (#83). A soak does not launch the game --
# it attaches through the bridge to one an earlier, already-exited host
# started -- so until now it held no lease and nothing stopped a scenario
# child from taking the game mid-run. Taking one here also makes the reverse
# true: a lane's library run waits for the soak instead of interleaving with
# it, which is the point of one lease per run rather than one per child.
#
# The junction check is the other half. A lease says whose the game is; it
# does not say which checkout the game would load. Asserting both means a
# soak's numbers are about the tree it was started from.
if (-not $NoRunLease) {
    $null = Wait-HarnessLease -TimeoutSec ($LeaseWaitMin * 60) -Label 'soak'
    Assert-JunctionsOwned -GameDir $script:GameDir
    Write-Host "[soak] holding the game lease for this run (host pid $PID)"
}

# #175: what is about to be measured, resolved from the junction. OUTSIDE the
# lease block: sweep-classes passes -NoRunLease because the sweep holds the
# lease itself, so a stamp taken in there is absent from every sweep -- the one
# place it is actually needed. It was, until this line moved: the first version
# was verified against a standalone soak and recorded `build: null` for all 29
# classes of sweep-15.
$script:BuildStamp = Get-BuildStamp -GameDir $script:GameDir
Write-Host "[soak] $(Format-BuildStamp $script:BuildStamp)"

# ---------------------------------------------------------------------------
# The record. Everything below is what the JSON summary is made of.
# ---------------------------------------------------------------------------
$started   = Get-Date
$endReason = $null
$stops     = @{}        # reason -> @{count; severity; first_turn; last_turn}
$resumes   = @{}        # action -> count
$resumeLog = New-Object System.Collections.Generic.List[object]
$zoneTrail = New-Object System.Collections.Generic.List[string]   # NOT $zones: that is the [string] -Zones parameter, and names are case-insensitive
$tainted   = $false
$polls     = 0
$bridgeMisses = 0
$first     = $null
$last      = $null
$peakLevel = 0      # NOT $maxLevel: PowerShell variables are case-insensitive, and that is the -MaxLevel parameter
$deaths    = 0
$killer    = $null
$stuckLabel = $null
$conditionsApplied = @()
# (f) and (g). The two rung counters are rows of the resume table even at
# zero, so a summary always says whether they fired.
$resumes['descend'] = 0
$resumes['next-zone'] = 0
$resumes['auto-spend'] = 0
$resumes['dialog-wait'] = 0
$descendWalks = 0; $descendMoves = 0; $descendAbandoned = 0; $waits = 0
$levelHandbacks = @{}     # "zone:level" -> hand-backs on stairs up / the wilderness exit
$levelLoops     = @{}     # "zone:level|reason" -> recurrences of one hand-back reason on one level
$descendRetryAt = @{}     # "zone:level" -> hand-back count at which (f) may be tried again after "no path"
$zoneList = @()           # [{id; min; max}] as verified against the installed module
$zoneTransitions = New-Object System.Collections.Generic.List[string]
$walk = $null             # the (f)/(g) state: @{action; phase; key; moves; waits; from}

function Count-Resume($action, $s, $reason) {
    if ($resumes.ContainsKey($action)) { $resumes[$action]++ } else { $resumes[$action] = 1 }
    $resumeLog.Add([pscustomobject]@{ turn = $s.turn; level = $s.level; zone = "$($s.zone):$($s.zlevel)"; action = $action; reason = $reason })
    Write-Host ('  resume   {0,-14} turn={1} L{2} {3}:{4}  {5}' -f $action, $s.turn, $s.level, $s.zone, $s.zlevel, $reason)
}

# Numbers vary per stop ("power level, 23.4, is above"); fold them so one
# reason is one row.
function Normalize-Reason([string]$r) {
    if (-not $r -or $r -eq 'nil') { return '(no reason)' }
    ($r -replace '\d+(\.\d+)?', '#').Trim()
}

# Parse "k=v|k=v|...|reason=<anything>" into an object.
function Parse-Status([string]$line) {
    $o = @{}
    if ($line -match '^(.*?)\|reason=(.*)$') { $head = $Matches[1]; $o.reason = $Matches[2] } else { $head = $line; $o.reason = '' }
    foreach ($kv in ($head -split '\|')) {
        if ($kv -match '^([a-z_]+)=(.*)$') { $o[$Matches[1]] = $Matches[2] }
    }
    foreach ($k in 'turn', 'level', 'zlevel', 'zmax', 'x', 'y', 'life', 'maxlife', 'pool', 'poolmax', 'ndialogs', 'downs') {
        if ($o.ContainsKey($k) -and $o[$k] -match '^-?\d+') { $o[$k] = [int]$Matches[0] } elseif ($o.ContainsKey($k)) { $o[$k] = -1 }
    }
    [pscustomobject]$o
}

function Bump-Count([hashtable]$t, [string]$k) {
    if ($t.ContainsKey($k)) { $t[$k]++ } else { $t[$k] = 1 }
    $t[$k]
}

$exit = 1
# Defined OUTSIDE the try below, though both its callers are inside it. The
# second call is in the `finally`, and `try` begins 663 lines before this
# function used to be declared -- so any failure in birth, placement or setup
# reached the finally with Get-Vision never defined and reported "The term
# 'Get-Vision' is not recognized", burying the real error under a missing
# function. A soak that fails early must still say why (#195).
<#
    #178: the character's own light radius and sight range.

    map.seens -- the only thing spotHostiles tests -- is set for a grid in
    field of view ONLY IF THE GRID IS LIT (engine/Map.lua:649), and
    unconditionally within the character's own light radius
    (applyExtraLite, :663). So `lite` decides how much of a run's
    accumulated field of view the bot can still see once runStopped wipes
    it, which is the whole of #153 and the live-lock in #164.

    The prediction this exists to test: a poor light radius should make a
    character MORE prone to the stall, because a larger one marks more
    grids unconditionally and leaves less for the accumulated view to add.
    Nothing recorded it before, so the corpus could not answer it.

    Read at both ends because equipment changes them -- a lantern picked up
    on floor one is exactly the interesting case, and a single reading at
    birth would attribute its whole run to the wrong number.
#>
function Get-Vision {
    $r = Invoke-Bridge -TimeoutSec 30 -Lua 'local p = game.player if not p then return "none" end return ("lite=%s sight=%s"):format(tostring(p.lite or 0), tostring(p.sight or 10))'
    if ($r.Status -ne 'OK') { return $null }
    if ("$($r.Result)" -match 'lite=([\d.]+) sight=([\d.]+)') {
        return [ordered]@{ lite = [double]$Matches[1]; sight = [double]$Matches[2] }
    }
    return $null
}

try {
    $g = Load-Save -Name $SaveName
    if (-not $g.Ready) { Write-Host "[soak] FAILED - could not load '$SaveName' ($($g.Reason))"; $endReason = 'LOAD_FAILED'; exit 1 }
    if ($g.Addons -notmatch 'skoobot_reclauded') { Write-Host "[soak] FAILED - the product is not loaded ($($g.Addons))"; $endReason = 'LOAD_FAILED'; exit 1 }

    $install = Invoke-Bridge -Lua @"
_G.sk = {}
local b = rawget(_G, "skoobot_reclauded")
if not b then return "ERR no skoobot_reclauded runtime table" end

-- Autosaves go to a scratch save, never back onto the fixture.
game.save_name = "$ScratchSave"

function sk.stairs()
  local p = game.player
  if not p.x or not game.level then return "none" end
  local e = game.level.map(p.x, p.y, engine.Map.TERRAIN)
  if not e or not e.change_level then return "none" end
  if e.change_zone then
    if tostring(e.change_zone):find("^wilderness") then return "wild" end
    return "zone"
  end
  local target = e.change_level_abs and e.change_level or (game.level.level + e.change_level)
  if target > game.level.level then return "down" end
  return "up"
end

-- One line of state. With step = "walk" or "walk-loop" a (f) walk step is
-- taken FIRST and its result reported as walk=, so a move costs one round
-- trip, not two.
function sk.status(step)
  local p = game.player
  if not p then return "turn=-1|level=-1|zone=none|zlevel=-1|zmax=-1|x=-1|y=-1|life=-1|maxlife=-1|pool=-1|poolmax=-1|active=false|dead=false|killer=|ndialogs=0|dialog=|stairs=none|downs=0|explored=false|walk=|reason=no player" end
  local walk = ""
  if step then walk = (tostring(sk.walkStep(step == "walk-loop")):gsub("|", "/")) end
  local d = game.dialogs and game.dialogs[#game.dialogs]
  local dtitle = d and sk.dialogName(d) or ""
  local killer = ""
  if p.dead and p.killedBy then killer = tostring(p.killedBy.name or "?") end
  -- #91: the POOL beside the raw pair. life/max_life is what the
  -- character sheet shows; the pool is what the game kills at and what
  -- every decision in this addon is made on, and for anything carrying
  -- die_at the two are different numbers. A soak log that recorded only
  -- the first could not explain a stop.
  local el = b.effectiveLife and b.effectiveLife(p) or { safe_pool = p.life, safe_max = p.max_life }
  return ("turn=%s|level=%s|zone=%s|zlevel=%s|zmax=%s|x=%s|y=%s|life=%d|maxlife=%d|pool=%d|poolmax=%d|active=%s|dead=%s|killer=%s|ndialogs=%d|dialog=%s|stairs=%s|downs=%d|explored=%s|walk=%s|reason=%s"):format(
    tostring(game.turn), tostring(p.level), tostring(game.zone and game.zone.short_name or "none"),
    tostring(game.level and game.level.level or -1), tostring(game.zone and game.zone.max_level or -1),
    tostring(p.x or -1), tostring(p.y or -1), math.floor(p.life or -1), math.floor(p.max_life or -1),
    math.floor(el.safe_pool or -1), math.floor(el.safe_max or -1),
    tostring(b.active), tostring(p.dead and true or false), killer:gsub("|", "/"),
    game.dialogs and #game.dialogs or 0, dtitle:gsub("|", "/"), sk.stairs(), #sk.downs(), tostring(sk.explored()),
    walk, tostring(b.last_reason))
end

-- (a) the top dialog, through its own EXIT bind. Never the death dialog.
-- The title alone can be empty (QuestPopup, Chat), so the class is always
-- named too.
function sk.dialogName(d)
  local t = tostring(d.title or "")
  if t == "" then t = "(untitled)" end
  return t .. "/" .. tostring(d.__CLASSNAME or "?")
end
local function press(d, virtual)
  bridge.injecting = true
  local ok, err = pcall(d.key.triggerVirtual, d.key, virtual)
  bridge.injecting = false
  if not ok then return "error " .. tostring(err) end
  return nil
end
-- EXIT first. A dialog with no EXIT -- a Chat, whose answers are picked with
-- ACCEPT and which cannot be escaped -- gets ACCEPT, i.e. its first answer,
-- which is reported as such. Anything with neither is reported with the
-- binds it does have, and ends the run.
function sk.closeDialog()
  local d = game.dialogs and game.dialogs[#game.dialogs]
  if not d then return "none" end
  local name = sk.dialogName(d)
  if d.__CLASSNAME == "mod.dialogs.DeathDialog" then return "death" end
  local v = d.key and d.key.virtuals
  if v and v.EXIT then
    return press(d, "EXIT") or ("closed " .. name)
  end
  if v and v.ACCEPT then
    return press(d, "ACCEPT") or ("accepted " .. name)
  end
  -- A Chat has no binds at all: an answer is picked by typing its letter,
  -- which calls self:use(self.list[n]) (engine/dialogs/Chat.lua:49). The
  -- first answer, through that same method, and its text is reported.
  if d.use and type(d.list) == "table" and d.list[1] and tostring(d.__CLASSNAME or ""):find("Chat") then
    local item = d.list[1]
    bridge.injecting = true
    local ok, err = pcall(d.use, d, item)
    bridge.injecting = false
    if not ok then return "error " .. tostring(err) end
    return "answered " .. name .. " -> " .. tostring(item.name)
  end
  local keys = {}
  for k in pairs(v or {}) do keys[#keys+1] = tostring(k) end
  table.sort(keys)
  return "noexit " .. name .. " binds=" .. table.concat(keys, ",")
end

-- (b) one real move off a stair tile, to a free adjacent non-stair tile.
-- Up to three real moves, each to a free non-stair tile, preferring one
-- with no vault door beside it and stopping as soon as none is. The
-- engine's auto-explore re-targets a vault door whenever the player is
-- next to it, diagonals included (PlayerExplore.lua:1861), so one step
-- that lands on the door's other neighbour changes nothing.
local function besideVaultDoor(x, y)
  for _, c in pairs(util.adjacentCoords(x, y)) do
    local t = game.level.map(c[1], c[2], engine.Map.TERRAIN)
    if t and (t.door_player_check or t.door_player_stop) then return true end
  end
  return false
end
function sk.stepOff()
  local p = game.player
  local moves = 0
  for step = 1, 3 do
    local best, bestBeside
    for _, c in pairs(util.adjacentCoords(p.x, p.y)) do
      local x, y = c[1], c[2]
      if game.level.map:isBound(x, y) and not game.level.map:checkAllEntities(x, y, "block_move")
         and not game.level.map(x, y, engine.Map.ACTOR)
         and not game.level.map:checkEntity(x, y, engine.Map.TERRAIN, "change_level") then
        local beside = besideVaultDoor(x, y)
        if not best or (bestBeside and not beside) then best, bestBeside = c, beside end
      end
    end
    if not best then break end
    if not p:move(best[1], best[2]) then break end
    moves = moves + 1
    if not besideVaultDoor(p.x, p.y) then break end
  end
  p:playerFOV()
  if moves == 0 then return "nowhere" end
  return "moved " .. moves .. (besideVaultDoor(p.x, p.y) and " (still beside a sealed door)" or "")
end

function sk.start()
  if b.active then return "already active" end
  b.start()
  return "started active=" .. tostring(b.active) .. " reason=" .. tostring(b.last_reason)
end

-- The rules a player would have set: what the character can fire, then the
-- innate Attack last; sustains kept up; inscriptions that need no target as
-- recovery and damage prevention.
-- The PRODUCT's own discovery, which is what a player who accepts the talent
-- screen's proposal would be running. sk.rules() below is a much cruder
-- superset -- every activated talent the character knows -- and measuring a
-- class against that answers a different question from "how does the
-- suggested build do" (#123, #130).
function sk.proposedRules()
  local p = game.player
  local r = b.rules.get(p)
  for _, s in ipairs(b.rules.module.SECTIONS) do
    local l = r[s] for i = #l, 1, -1 do l[i] = nil end
  end
  local prop = b.loadout.propose(p)
  if not prop then return "ERR discovery proposed nothing" end
  b.loadout.apply(prop, "replace", p)
  -- Attack is the floor: discovery may legitimately propose no attack at all
  -- for a character whose talents are all situational, and a rotation with
  -- nothing in it measures the empty-Combat dead end (#96) rather than the class.
  if #b.rules.tids(p, "Combat") == 0 then b.rules.module.place(r, {tid="T_ATTACK"}, "Combat") end
  return ("combat=%s sustain=%s recovery=%s"):format(
    table.concat(b.rules.tids(p, "Combat"), ","), table.concat(b.rules.tids(p, "Sustain"), ","),
    table.concat(b.rules.tids(p, "Recovery"), ","))
end

function sk.rules()
  local p = game.player
  local r = b.rules.get(p)
  for _, s in ipairs(b.rules.module.SECTIONS) do
    local l = r[s]
    for i = #l, 1, -1 do l[i] = nil end
  end
  local combat, sustain, recover = {}, {}, {}
  for tid, _ in pairs(p.talents) do
    local t = p:getTalentFromId(tid)
    if t and not t.no_npc_use and not t.no_dumb_use and tid ~= "T_ATTACK" and t.hide ~= "always" then
      if t.mode == "activated" then
        if t.is_inscription and not t.requires_target then recover[#recover+1] = tid
        else combat[#combat+1] = tid end
      elseif t.mode == "sustained" then sustain[#sustain+1] = tid end
    end
  end
  table.sort(combat) table.sort(sustain) table.sort(recover)
  for _, tid in ipairs(combat) do b.rules.module.place(r, {tid=tid}, "Combat") end
  b.rules.module.place(r, {tid="T_ATTACK"}, "Combat")
  for _, tid in ipairs(sustain) do b.rules.module.place(r, {tid=tid}, "Sustain") end
  for _, tid in ipairs(recover) do
    b.rules.module.place(r, {tid=tid}, "Recovery")
    b.rules.module.place(r, {tid=tid}, "DamagePrevention")
  end
  return ("combat=%s sustain=%s recovery=%s"):format(
    table.concat(b.rules.tids(p, "Combat"), ","), table.concat(b.rules.tids(p, "Sustain"), ","),
    table.concat(b.rules.tids(p, "Recovery"), ","))
end

-- (f) DESCEND WHEN EXPLORED.
-- A down staircase: change_level relative (or absolute with change_level_abs)
-- landing deeper than here, and not a zone exit (data/general/grids/basic.lua).
local function isDown(t)
  if not t or not t.change_level or t.change_zone then return false end
  local target = t.change_level_abs and t.change_level or (game.level.level + t.change_level)
  return target > game.level.level
end
-- What the player knows: a tile seen or remembered (stairs and doors are
-- always_remember, so a glimpse is enough). Never a vault door: the prompt
-- behind it is the product's own sealed-door loop (#64), not a route.
local function known(x, y)
  local map = game.level.map
  if not (map.remembers(x, y) or map.has_seens(x, y)) then return false end
  local t = map(x, y, engine.Map.TERRAIN)
  if t and (t.door_player_check or t.door_player_stop) then return false end
  return true
end
-- Every seen down staircase, nearest first as the crow flies.
function sk.downs()
  local p, out = game.player, {}
  if not p or not p.x or not game.level then return out end
  local map = game.level.map
  for x = 0, map.w - 1 do for y = 0, map.h - 1 do
    if (map.remembers(x, y) or map.has_seens(x, y)) and isDown(map(x, y, engine.Map.TERRAIN)) then
      out[#out+1] = { x = x, y = y, d = core.fov.distance(p.x, p.y, x, y) }
    end
  end end
  table.sort(out, function(u, v) return u.d < v.d end)
  return out
end
-- The engine's own A* (engine/Astar.lua), the call the bot's combat pathing
-- makes, restricted to tiles the player knows. Nearest reachable wins.
local Astar = require "engine.Astar"
function sk.pathDown()
  local p = game.player
  local downs = sk.downs()
  for _, c in ipairs(downs) do
    local path = Astar.new(game.level.map, p):calc(p.x, p.y, c.x, c.y, nil, nil, known)
    if path and #path > 0 then return path, c end
  end
  return nil, nil, #downs
end
-- Nothing left to explore, read from the engine's own auto-explore without
-- running it: it targets an exit only when no unseen tile, item or door is
-- reachable ("fully explored and we can go to the next level",
-- mod/class/interface/PlayerExplore.lua:2299), and running_prev keeps that
-- target until the level changes.
function sk.explored()
  local p = game.player
  local r = p and p.running_prev
  if r and r.explore == "exit" and r.levelstring == tostring(game.level) then return true end
  return false
end
-- One step of the walk. Hands back to the bot (by returning "hostile") the
-- moment anything hostile is in view; the walk never fights. Started on a
-- loop (see the header), only an ADJACENT hostile hands back: one in view
-- that the bot cannot reach is what the loop is made of.
function sk.walkStep(loop)
  local p = game.player
  if not p or not p.x or not game.level then return "noplayer" end
  local map = game.level.map
  if game.dialogs and game.dialogs[1] then return "dialog" end
  if b.active then return "active" end
  local hostiles = p:spotHostiles(true)
  if loop then
    local near = 0
    for _, h in ipairs(hostiles) do
      if core.fov.distance(p.x, p.y, h.x, h.y) <= 1 then near = near + 1 end
    end
    if near > 0 then return "hostile " .. near .. " adjacent (" .. #hostiles .. " in view)" end
  elseif #hostiles > 0 then
    return "hostile " .. #hostiles
  end
  if isDown(map(p.x, p.y, engine.Map.TERRAIN)) then return "arrived" end
  local path, target, n = sk.pathDown()
  if not path then
    if (n or 0) > 0 then return "nopath " .. n end
    return "nostairs"
  end
  local nx, ny = path[1].x, path[1].y
  local a = map(nx, ny, engine.Map.ACTOR)
  if a then
    -- An actor on the next grid used to abandon the walk outright, which cost
    -- two of Doomed's three descend walks in sweep 1 -- "blocked by shadow",
    -- twice, on a level it had already explored.
    --
    -- A non-hostile is not a wall: moving into one swaps places. A hostile is
    -- the BOT's business and not the walk's, so that one still hands back --
    -- and note the hostile check above only sees SPOTTED ones, which is why
    -- anything reaches here at all.
    if p:reactionToward(a) < 0 then
      return "blocked by hostile " .. tostring(a.name or "?")
    end
  end
  local ox, oy = p.x, p.y
  local ok, err = pcall(p.move, p, nx, ny)
  if not ok then return "error " .. tostring(err) end
  p:playerFOV()
  if p.x == ox and p.y == oy then
    local t = map(nx, ny, engine.Map.TERRAIN)
    if t and t.door_closed then return ("opened door %d,%d left=%d"):format(nx, ny, #path) end
    return ("nomove %d,%d"):format(nx, ny)
  end
  return ("moved %d,%d left=%d to=%d,%d"):format(p.x, p.y, #path - 1, target.x, target.y)
end
function sk.where()
  return tostring(game.zone and game.zone.short_name or "none") .. ":" .. tostring(game.level and game.level.level or -1)
end
-- The outcome of a change just asked for: "changed" when the zone or level
-- differs (an arrival dialog may be open on top: (a) handles it), "dialog"
-- when one is open and nothing changed yet -- the transmogrification chest
-- asking first; the change happens when (a) closes it -- and "refused"
-- otherwise, which is changeLevelCheck: two turns after a kill.
local function outcome(before, note)
  local after = sk.where()
  local d = game.dialogs and game.dialogs[1] and (" (" .. sk.dialogName(game.dialogs[#game.dialogs]) .. " open)") or ""
  if after ~= before then return "changed " .. after .. d end
  if d ~= "" then return "dialog " .. sk.dialogName(game.dialogs[#game.dialogs]) end
  return "refused at " .. after .. (note or "")
end
-- The game's own CHANGE_LEVEL bind, and what it did.
function sk.takeStairs()
  local before = sk.where()
  local r = bridge.key("CHANGE_LEVEL")
  return outcome(before, " (" .. tostring(r) .. ")")
end

-- (g) NEXT ZONE: the engine's own transition, the call a step onto a zone
-- entrance on the world map makes (mod/class/Game.lua:2292). With a zone
-- given the player lands on the new level's up staircase (old_lev is -1000
-- there, Game.lua:1079 and :1294), exactly as when walking in.
function sk.nextZone(id, floor)
  floor = tonumber(floor) or 1
  if game.zone and game.zone.short_name == id and floor <= 1 then return "already in " .. id end
  local before = sk.where()
  local ok, err = pcall(game.changeLevel, game, floor, id)
  if not ok then return "error " .. tostring(err) end
  return outcome(before)
end

--- Gain XP up to a character level. Points are left unspent on purpose: the
--- ordinary auto-spend path picks them up, so a pre-levelled trial character
--- has the build a real run would have given it. See #173.
function sk.preLevel(n)
  local p = game.player
  n = tonumber(n) or 0
  if not p or n <= 0 then return "skipped" end
  local guard = 0
  while p.level < n and guard < 60 do
    guard = guard + 1
    local need = p:getExpChart(p.level + 1)
    if not need then break end
    local delta = need - p.exp
    if delta <= 0 then delta = 1 end
    p:gainExp(delta + 1)
  end
  return ("level=%d stats=%s talents=%s generics=%s"):format(p.level,
    tostring(p.unused_stats), tostring(p.unused_talents), tostring(p.unused_generics))
end
-- The zone's level_range as the installed module declares it (some zones
-- declare two layouts; the widest range is taken), or "missing".
function sk.zoneInfo(id)
  local path = "/data/zones/" .. id .. "/zone.lua"
  if not fs.exists(path) then return "missing" end
  local f = fs.open(path, "r")
  if not f then return "unreadable" end
  local text = f:read(10485760) or ""
  f:close()
  local min, max
  for a, c in text:gmatch("level_range%s*=%s*{%s*(%d+)%s*,%s*(%d+)") do
    a, c = tonumber(a), tonumber(c)
    if not min or a < min then min = a end
    if not max or c > max then max = c end
  end
  if not min then return "norange" end
  return ("min=%d max=%d"):format(min, max)
end
function sk.visitedZones()
  local out = {}
  for k, v in pairs(game.visited_zones or {}) do if v then out[#out+1] = tostring(k) end end
  table.sort(out)
  return table.concat(out, ",")
end
-- #158, HARNESS ONLY. A band-aid build so a sweep measures a character that
-- spent its points rather than one that never did. This lives in the soak's
-- own helpers, which are never packaged -- tools/pack.ps1 packs src/ only --
-- and it must not become product behaviour by accident. The real feature is
-- #88.
--
-- The owner's heuristic: the shortest-cooldown investable talent in the
-- rotation that HAS a stat requirement identifies the primary stat.

--- Can a point still go into this stat? The game's own limits
--- (mod/class/Actor.lua:826, useBuildOrder), which must be honoured or the
--- points stick: a soft per-level cap, and a hard one.
function sk.statOpen(p, stat)
  local ok, raw = pcall(p.getStat, p, stat, nil, nil, true)
  if not ok or type(raw) ~= "number" then return false end
  if p:isStatMax(stat) then return false end
  if raw >= p.level * 1.4 + 20 then return false end
  if raw >= 60 + math.max(0, p.level - 50) then return false end
  return true
end

--- Talent ids in the rotation, or every activated talent if the rotation is
--- not readable. Defensive about shape: entries may be ids or rule tables.
function sk.rotationTids()
  local p, out, seen = game.player, {}, {}
  local function add(v)
    local tid = v
    if type(v) == "table" then tid = v.talent or v.id or v.tid end
    if type(tid) == "string" and p.talents and p.talents[tid] and not seen[tid] then
      seen[tid] = true ; out[#out+1] = tid
    end
  end
  local b = rawget(_G, "skoobot_reclauded")
  local ok, rot = pcall(function() return b and b.rules and b.rules.rotation and b.rules.rotation() end)
  if ok and type(rot) == "table" then for _, e in ipairs(rot) do add(e) end end
  if #out == 0 then
    for tid in pairs(p.talents or {}) do
      local t = p:getTalentFromId(tid)
      if t and t.mode == "activated" then add(tid) end
    end
  end
  return out
end

--- The stat the rotation leans on, by the owner's heuristic.
function sk.primaryStat()
  local p = game.player
  local best, bestcd, bestname
  for _, tid in ipairs(sk.rotationTids()) do
    local t = p:getTalentFromId(tid)
    local raw = t and p:getTalentLevelRaw(tid) or 0
    -- investable: known, and not already at its maximum rank
    if t and raw > 0 and raw < (t.points or 0) then
      local req = t.require
      if type(req) == "function" then
        local ok, r = pcall(req, p, t, raw + 1) ; req = ok and r or nil
      end
      local stat
      if type(req) == "table" and type(req.stat) == "table" then
        for s in pairs(req.stat) do stat = stat or s end
      end
      if stat then
        local cd = t.cooldown
        if type(cd) == "function" then local ok, v = pcall(cd, p, t) ; cd = ok and v or nil end
        cd = tonumber(cd) or 9999
        if not bestcd or cd < bestcd then best, bestcd, bestname = stat, cd, tostring(t.name) end
      end
    end
  end
  return best, bestcd, bestname
end

--- Spend everything unspent. Returns a one-line report.
function sk.autoSpend()
  local p = game.player
  if not p then return "no player" end
  local stat, cd, tname = sk.primaryStat()
  local out = {}

  -- Stats: the primary, then Constitution, then anywhere legal. The spill is
  -- not optional: the per-level cap stops a level-3 character putting a fourth
  -- point into one stat, and without somewhere else to go the points stick and
  -- the hand-back returns for ever.
  local order = { stat, "con", "str", "dex", "mag", "wil", "cun" }
  local spent = 0
  while (p.unused_stats or 0) > 0 do
    local did = false
    for _, s in ipairs(order) do
      if s and (p.unused_stats or 0) > 0 and sk.statOpen(p, s) then
        p:incStat(s, 1) ; p.unused_stats = p.unused_stats - 1
        spent = spent + 1 ; did = true ; break
      end
    end
    if not did then break end
  end
  out[#out+1] = ("stats primary=%s(%s cd=%s) spent=%d left=%d"):format(
    tostring(stat), tostring(tname), tostring(cd), spent, p.unused_stats or 0)

  -- Talents: only into ones that ALREADY have a point, which is the owner's
  -- rule and also the safe one -- learning something new changes the rotation
  -- under the run, and picking what to learn is #88's job.
  local tspent, gspent = 0, 0
  local function pass(budget, wantGeneric)
    local moved = true
    while moved and (p[budget] or 0) > 0 do
      moved = false
      for _, tid in ipairs(sk.rotationTids()) do
        local t = p:getTalentFromId(tid)
        local raw = t and p:getTalentLevelRaw(tid) or 0
        if t and raw >= 1 and raw < (t.points or 0) and p:canLearnTalent(t) then
          local tt = p:getTalentTypeFrom(t.type[1])
          local isGeneric = tt and tt.generic and true or false
          if isGeneric == wantGeneric then
            p:learnTalent(t.id, true)
            p[budget] = p[budget] - 1
            if wantGeneric then gspent = gspent + 1 else tspent = tspent + 1 end
            moved = true ; break
          end
        end
      end
    end
  end
  pass("unused_talents", false)
  pass("unused_generics", true)
  out[#out+1] = ("talents class=%d generic=%d left=%s/%s"):format(
    tspent, gspent, tostring(p.unused_talents or 0), tostring(p.unused_generics or 0))
  return table.concat(out, " | ")
end

-- #138: a screenshot WITHOUT the engine's "Screenshot taken!" popup.
-- game:saveScreenshot() opens one (engine/Game.lua:818), which would land on
-- top of the very state being captured and change what the next shot shows.
-- takeScreenshot() is the same call without it; dialogs ARE drawn, since the
-- suppression at :184 applies only to savefile shots -- and the dialog is
-- usually the thing worth seeing. Written to the module dir, the same write
-- path the dossiers use (#135); /skoobot-bridge/ is not writable.
-- #132: escort outcomes, per run, read from the QUEST.
--
-- NOT from registerEscorts: that writes a lifetime tally to the ACCOUNT
-- profile (mod/class/interface/PlayerStats.lua:60), so it cannot be attributed
-- to a run, and a measurement rig incrementing it would be writing to the
-- player's own profile -- the mistake the sweep already made once with
-- TAKE_STAIRS.
--
-- The game separates the case this exists for: escort-duty.lua:146 records
-- `killing_npc` on the quest, and it is the CHARACTER'S OWN NAME when the
-- bot's own effects did it. An escort killed by the bot and one killed by a
-- troll are otherwise indistinguishable.
--
-- Ids are "escort-duty-<zone>-<level>" (escort-duty.lua:54), so a run can
-- carry several and each says where it was granted.
function sk.escorts()
  local p = game.player
  if not p or not p.quests then return "none" end
  local out = {}
  for id, q in pairs(p.quests) do
    if tostring(id):find("^escort%-duty") then
      local st = tonumber(q.status)
      local status = (st == 100 and "DONE") or (st == 101 and "FAILED")
                  or (st == 1 and "COMPLETED") or (st == 0 and "PENDING")
                  or ("UNKNOWN:" .. tostring(q.status))
      local killer = tostring(q.killing_npc or "")
      out[#out+1] = table.concat({
        "id=" .. tostring(id),
        "kind=" .. tostring(q.kind_id or "?"),
        "status=" .. status,
        "granted_turn=" .. tostring(q.gained_turn or "?"),
        "killer=" .. killer,
        "selfkill=" .. tostring(killer ~= "" and killer == tostring(p.name)),
      }, ",")
    end
  end
  if #out == 0 then return "none" end
  return table.concat(out, " | ")
end

function sk.shot(name)
  local ok, s = pcall(game.takeScreenshot, game)
  if not ok then return "ERR takeScreenshot " .. tostring(s) end
  if not s then return "ERR no image" end
  if not fs.exists("/screenshots") then fs.mkdir("/screenshots") end
  local path = "/screenshots/" .. tostring(name) .. ".png"
  local f = fs.open(path, "w")
  if not f then return "ERR open " .. path end
  f:write(s)
  f:close()
  return "wrote " .. path
end

return "installed save_name=" .. tostring(game.save_name)
"@ -TimeoutSec 30
    if ($install.Status -ne 'OK' -or $install.Result -notmatch '^installed') {
        Write-Host "[soak] FAILED - helpers: $($install.Status) $($install.Result)"; $endReason = 'SETUP_FAILED'; exit 1
    }
    Write-Host "  $($install.Result)"

    if (-not $NoAutoRules) {
        $call  = $(if ($ProposedRules) { 'return sk.proposedRules()' } else { 'return sk.rules()' })
        $rules = Invoke-Bridge -Lua $call -TimeoutSec 30
        Write-Host "  rules    $($rules.Status) $($rules.Result)"
    }

    if ($Dossier) {
        $don = Invoke-Bridge -Lua 'return bridge.dossierOn()' -TimeoutSec 30
        Write-Host "  dossier  $($don.Status) $($don.Result)"
        if ($don.Status -ne 'OK') { Write-Host '[soak] WARNING: dossiers requested but the hook did not install' }
    }

    # The player's own stop-condition knobs, through the product's API. A
    # STOP condition whose cause stays in view -- an enemy above
    # MAX_DIFF_POWER, by default STOP -- stops every restart on the spot,
    # which is the product handing the game to the player as designed; a
    # run that wants to measure what happens past that point sets it to
    # WARN or IGNORE here, and the summary records that it did.
    if ($Conditions) {
        foreach ($pair in ($Conditions -split ',')) {
            if ($pair -match '^\s*([A-Z_]+)\s*=\s*(WARN|STOP|IGNORE)\s*$') {
                $code = $Matches[1]; $policy = $Matches[2]
                $cr = Invoke-Bridge -Lua "local c = skoobot_reclauded.conditions.get('$code') if not c then return 'ERR no condition $code' end skoobot_reclauded.conditions.set('$code', '$policy') return '$code=' .. skoobot_reclauded.conditions.get('$code').stoptype" -TimeoutSec 30
                Write-Host "  condition $($cr.Status) $($cr.Result)"
                if ($cr.Status -eq 'OK' -and $cr.Result -notmatch '^ERR') { $conditionsApplied += $cr.Result }
            } else {
                Write-Host "  condition IGNORED '$pair' (want CODE=WARN|STOP|IGNORE)"
            }
        }
    }

    # #86 / #123: the stairs answer, per character. Set through the product's
    # own writer so it lands where a player's choice would, and recorded so no
    # run is ambiguous about whether it was allowed to descend.
    $stairsApplied = 'leave'
    if ($TakeStairs -ne 'leave') {
        $vals = @{ ask = 0; always = 1; never = 2 }
        $sr = Invoke-Bridge -TimeoutSec 30 -Lua ("local ok = skoobot_reclauded.setCharSetting('TAKE_STAIRS', {0}) return tostring(ok) .. ' ' .. tostring(skoobot_reclauded.cfg and skoobot_reclauded.cfg('TAKE_STAIRS'))" -f $vals[$TakeStairs])
        Write-Host "  stairs   $($sr.Status) TAKE_STAIRS=$TakeStairs ($($sr.Result))"
        if ($sr.Status -eq 'OK' -and $sr.Result -notmatch '^false') { $stairsApplied = $TakeStairs }
        else { Write-Host '[soak] WARNING: TAKE_STAIRS was not applied; the run may decline its own descent' }
    }

    # #160: place the character, before anything reads the zone. Dialogs first
    # -- a town start leaves several, and changeLevel under an open dialog is
    # asking for trouble -- then the move, then whatever the arrival puts up.
    $placedIn = $null
    if ($StartZone) {
        $null = Invoke-Bridge -Lua 'local out = {} for i = 1, 8 do local r = sk.closeDialog() if r == "none" then break end out[#out+1] = r end return table.concat(out, "; ")' -TimeoutSec 30
        $tp = Invoke-Bridge -Lua "return sk.nextZone('$StartZone', $StartFloor)" -TimeoutSec 120
        $null = Invoke-Bridge -Lua 'local out = {} for i = 1, 8 do local r = sk.closeDialog() if r == "none" then break end out[#out+1] = r end return table.concat(out, "; ")' -TimeoutSec 30
        $where = (Invoke-Bridge -Lua 'return sk.where()' -TimeoutSec 30).Result
        Write-Host "  placed   $($tp.Status) -> $where ($($tp.Result))"
        if ($where -like "$StartZone*") { $placedIn = $where }
        else { Write-Host "[soak] WARNING: asked for $StartZone and landed in $where" }
    }

    if ($PreLevel -gt 0) {
        $pl = Invoke-Bridge -Lua "return sk.preLevel($PreLevel)" -TimeoutSec 120
        Write-Host "  prelevel $($pl.Status) $($pl.Result)"
    }

    $visionStart = Get-Vision
    if ($visionStart) { Write-Host "  vision   lite=$($visionStart.lite) sight=$($visionStart.sight)" }

    # #158: spend whatever birth left unspent, before the first decision.
    $buildApplied = $null
    if (-not $NoAutoSpend) {
        $as = Invoke-Bridge -Lua 'return sk.autoSpend()' -TimeoutSec 60
        Write-Host "  build    $($as.Status) $($as.Result)"
        if ($as.Status -eq 'OK') { $buildApplied = $as.Result }
    }

    # (g): the zone list, checked against the installed module. An id with no
    # zone.lua is dropped here and reported, not discovered at the transition.
    $myRace = (Invoke-Bridge -Lua 'local d = game.player.descriptor or {} return tostring(d.subrace or d.race or "?")' -TimeoutSec 30).Result
    foreach ($z in $ZoneIds) {
        if ($ZONE_RACE.ContainsKey($z) -and $myRace -notmatch $ZONE_RACE[$z]) {
            Write-Host "  zone     SKIPPED '$z' ($($ZONE_RACE[$z]) only; this is $myRace)"
            continue
        }
        $zi = Invoke-Bridge -Lua "return sk.zoneInfo('$z')" -TimeoutSec 30
        if ($zi.Status -eq 'OK' -and $zi.Result -match '^min=(\d+) max=(\d+)') {
            $zoneList += [pscustomobject]@{ id = $z; min = [int]$Matches[1]; max = [int]$Matches[2] }
        } else {
            Write-Host "  zone     DROPPED '$z' ($($zi.Status) $($zi.Result))"
        }
    }
    Write-Host "  zones    $(($zoneList | ForEach-Object { "$($_.id)($($_.min)-$($_.max))" }) -join ' ')"

    # Any dialog left from the load is closed the way (a) closes them.
    $null = Invoke-Bridge -Lua 'local out = {} for i = 1, 5 do local r = sk.closeDialog() if r == "none" then break end out[#out+1] = r end return table.concat(out, "; ")' -TimeoutSec 30

    $deadline = $started.AddMinutes($MaxMinutes)
    $lastReason = $null; $lastStopTurn = -1; $sameCount = 0; $stuckStage = 0
    $waitDialog = 0
    $idleWhere = New-Object System.Collections.Generic.List[string]
    $idleTurn = -1; $idleTurn0 = -1
    $s = $null

    # (f)/(g) helpers over the loop's state. A walk ends in one of three ways,
    # each counted: the stairs or the zone taken, the bot handed the situation
    # (a hostile, a blocked tile), or nothing to walk to.
    function Start-Bot($s, $reason) {
        $st = Invoke-Bridge -Lua 'return sk.start()' -TimeoutSec 30
        if ($st.Tainted) { $script:tainted = $true }
        Count-Resume 'restart' $s $reason
    }
    function Abandon-Walk($s, $why) {
        if ($walk.action -eq 'descend') { $script:descendAbandoned++ }
        Write-Host "  walk     abandoned $($walk.action) after $($walk.moves) move(s): $why"
        $script:walk = $null
    }

    $kick = Invoke-Bridge -Lua 'return sk.start()' -TimeoutSec 30
    Write-Host "  start    $($kick.Status) $($kick.Result)"
    if ($kick.Tainted) { $tainted = $true }

    while ($true) {
        # A walking poll is short: the move is the only thing that happens.
        $walking = ($walk -and $walk.phase -eq 'walking')
        Start-Sleep -Seconds $(if ($walking) { $WalkPollSec } else { $PollSec })
        if (-not (Test-GameAlive)) { $endReason = 'CRASHED'; break }
        $r = Invoke-Bridge -Lua $(if ($walking) { "return sk.status('$(if ($walk.loop) { 'walk-loop' } else { 'walk' })')" } else { 'return sk.status()' }) -TimeoutSec 30
        if ($r.Status -ne 'OK') {
            $bridgeMisses++
            Write-Host "  poll     $($r.Status) ($bridgeMisses in a row)"
            if ($r.Status -eq 'CRASHED') { $endReason = 'CRASHED'; break }
            if ($bridgeMisses -ge 5) { $endReason = 'BRIDGE_LOST'; break }
            continue
        }
        $bridgeMisses = 0
        $polls++
        if ($r.Tainted) { $tainted = $true }
        $s = Parse-Status $r.Result
        if (-not $first) { $first = $s }
        $last = $s
        if ($s.level -gt $peakLevel) { $peakLevel = $s.level }
        $zl = "$($s.zone):$($s.zlevel)"
        if ($zoneTrail.Count -eq 0 -or $zoneTrail[$zoneTrail.Count - 1] -ne $zl) { $zoneTrail.Add($zl) }
        $lifeText = if ($s.pool -ne $s.life -or $s.poolmax -ne $s.maxlife) { "$($s.life)/$($s.maxlife) pool $($s.pool)/$($s.poolmax)" } else { "$($s.life)/$($s.maxlife)" }
        Write-Host ('  poll     turn={0} L{1} {2} life={3} active={4} dialogs={5} {6}' -f $s.turn, $s.level, $zl, $lifeText, $s.active, $s.ndialogs, $(if ($s.active -eq 'true') { '' } elseif ($walking) { "walk=$($s.walk)" } else { "reason=$($s.reason)" }))

        # ----- ends -----
        # #141: the Eidolon does not kill the character, it takes them. die()
        # self-resurrects and moves them to `eidolon-plane`, so `dead` stays
        # false and the loop below never fires -- the run would poll out the
        # rest of its minutes in a zone that is not part of the game being
        # measured, then report MAX_MINUTES and zero deaths. Arrival IS the
        # death, and it is recorded as one; the distinct end reason keeps a
        # death the Eidolon intercepted tellable from one that ended the
        # character, which is a distinction #135's corpus wants.
        if ($s.zone -eq 'eidolon-plane') {
            $deaths++
            $killer = $s.killer
            if (-not $killer) {
                # Only knowable from before the move: nothing on the plane did
                # it. #174: ASK, do not grep. The old fallback matched the game
                # log for 'kill|slain|die' and the bridge echoes its own state
                # into that log -- a state string containing "killer=" matches
                # "kill", so every eidolon death recorded a [BRIDGE] line as
                # its killer and the field was useless.
                $ld = Invoke-Bridge -Lua 'return bridge.lastDeath()' -TimeoutSec 30
                if ($ld.Status -eq 'OK' -and "$($ld.Result)" -match 'killer=(.+)$') { $killer = $Matches[1] }
            }
            Write-Host "  eidolon  taken at turn=$($s.turn) L$($s.level)$(if ($killer) { " (killed by $killer)" })"
            $endReason = 'EIDOLON'; break
        }
        if ($s.dead -eq 'true') {
            $deaths++
            $killer = $s.killer
            if (-not $killer) {
                # #174, as above: ask the bridge, which recorded it in die().
                $ld = Invoke-Bridge -Lua 'return bridge.lastDeath()' -TimeoutSec 30
                if ($ld.Status -eq 'OK' -and "$($ld.Result)" -match 'killer=(.+)$') { $killer = $Matches[1] }
            }
            $endReason = 'DEATH'; break
        }
        # #145: going nowhere, measured without needing a stop to key on. Only
        # while the bot is ACTIVE and no stop has fired -- a bot that has handed
        # back is standing still because it was told to, and the stop-based
        # endings own that case.
        if ($IdleAfter -gt 0) {
            if ($s.active -eq 'true' -and [int]$s.turn -gt $idleTurn) {
                $null = $idleWhere.Add("$($s.x),$($s.y)")
                while ($idleWhere.Count -gt $IdleAfter) { $idleWhere.RemoveAt(0) }
                if ($idleWhere.Count -ge $IdleAfter) {
                    $distinct = @($idleWhere | Sort-Object -Unique)
                    if ($distinct.Count -le $IdleDistinct) {
                        $stuckLabel = "IDLE $($distinct.Count) grid(s) in $($idleWhere.Count) polls while the clock ran ($idleTurn0 -> $($s.turn)): $($distinct -join ' ')"
                        $endReason = 'IDLE'; break
                    }
                }
                if ($idleWhere.Count -eq 1) { $idleTurn0 = [int]$s.turn }
            } else {
                $idleWhere.Clear()
            }
            $idleTurn = [int]$s.turn
        }
        if ((Get-Date) -ge $deadline) { $endReason = 'MAX_MINUTES'; break }
        if ($MaxLevel -gt 0 -and $s.level -ge $MaxLevel) { $endReason = 'MAX_LEVEL'; break }
        # #179: a BUDGET, measured from this run's own first sample, not an
        # absolute game turn. Runs do not start at zero -- across sweep-16 the
        # start turn ranged 0 to 2000 -- and birth turn is a property of the
        # class, so an absolute limit hands each class a different budget and
        # biases the one comparison the sweep exists to make.
        if ($MaxTurns -gt 0 -and $first -and ($s.turn - $first.turn) -ge $MaxTurns) {
            $endReason = 'MAX_TURNS'; break
        }

        # ----- (a) a dialog: close it through its own key -----
        if ($s.ndialogs -gt 0) {
            $c = Invoke-Bridge -Lua 'return sk.closeDialog()' -TimeoutSec 30
            if ($c.Tainted) { $tainted = $true }
            if ($c.Result -eq 'death') { continue }   # the next poll sees dead=true
            if ($c.Result -match '^noexit') {
                # #161: a dialog with NO BINDS AT ALL is a progress dialog, not
                # a decision -- "Generating level" is the engine's own, it has
                # nothing to press because nothing is meant to press it, and it
                # closes itself when generation finishes. Sweep 6 lost three of
                # twenty runs to treating it as terminal, each on its first
                # floor after five to six thousand turns.
                #
                # Bounded, because a genuinely undismissable modal must still
                # end the run: that is what this check exists for.
                # No binds listed at all, or the engine's own progress dialog
                # by name. Both tests, because the binds list is the general
                # signal and the name is the one case we have actually seen.
                if ($c.Result -match 'binds=\s*$' -or $c.Result -match 'Generating') {
                    $waitDialog++
                    if ($waitDialog -le $DialogWaitPolls) {
                        Count-Resume 'dialog-wait' $s "$($c.Result) (progress dialog, $waitDialog/$DialogWaitPolls)"
                        Start-Sleep -Milliseconds 700
                        continue
                    }
                }
                Count-Resume 'dialog-stuck' $s $c.Result
                $stuckLabel = "STUCK dialog with neither EXIT nor ACCEPT: $($c.Result)"
                $endReason = 'STUCK'; break
            }
            $action = if ($c.Result -match '^accepted') { 'accept-dialog' } elseif ($c.Result -match '^answered') { 'answer-chat' } else { 'close-dialog' }
            Count-Resume $action $s "$($c.Result) (bot reason: $($s.reason))"
            continue
        }

        if ($s.active -eq 'true') { $walk = $null; continue }

        # ----- (f)/(g) in progress: a walk, or a change waiting to take -----
        # These polls are the rung's own turns, not the bot's stops: nothing
        # here is recorded in the histogram, and every move is counted.
        if ($walk) {
            $key = "$($s.zone):$($s.zlevel)"
            if ($key -ne $walk.key) {
                # The change took: the transmogrification chest finishes it
                # when (a) closes the dialog, so it can land a poll later.
                Count-Resume $walk.action $s "$($walk.key) -> $key after $($walk.moves) move(s) from $($walk.from) ($($walk.how))"
                if ($walk.action -eq 'next-zone') { $zoneTransitions.Add("$($walk.key) -> $key") }
                $walk = $null
                Start-Sleep -Seconds $PollSec
                Start-Bot $s "after $key"
                continue
            }
            if ($walk.phase -eq 'walking') {
                $w = "$($s.walk)"
                if ($w -match '^(moved|opened door)') {
                    $walk.moves++; $descendMoves++
                    if ($walk.moves -gt $MaxWalkMoves) { Abandon-Walk $s "longer than $MaxWalkMoves moves"; Start-Bot $s 'walk abandoned' }
                    continue
                }
                if ($w -eq 'arrived') {
                    $walk.phase = 'taking'
                    # fall through to the taking phase below, this poll
                } elseif ($w -match '^(hostile|blocked|active|dialog)') {
                    # The bot's situation, not the walk's. It is handed the
                    # game; the trigger re-fires at the next hand-back, since
                    # the level's hand-back count stands.
                    Abandon-Walk $s $w
                    if ($w -notmatch '^(active|dialog)') { Start-Bot $s "handed back during the walk: $w" }
                    continue
                } else {
                    # nopath / nostairs / nomove / error: nothing to walk to
                    # through what the player knows. The bot explores more;
                    # (f) is not tried on this level until -DescendAfter more
                    # hand-backs have accrued.
                    $descendRetryAt[$walk.key] = $(if ($levelHandbacks.ContainsKey($walk.key)) { $levelHandbacks[$walk.key] } else { 0 }) + $DescendAfter
                    Abandon-Walk $s $w
                    Start-Bot $s "walk found nothing: $w"
                    continue
                }
            }
            if ($walk.phase -eq 'taking') {
                if ($walk.action -eq 'descend' -and $s.stairs -ne 'down') {
                    # Pushed off the stairs (a swap, a knockback): walk back.
                    $walk.phase = 'walking'
                    continue
                }
                if ($walk.action -eq 'descend') {
                    $t = Invoke-Bridge -Lua 'return sk.takeStairs()' -TimeoutSec 120
                } else {
                    $t = Invoke-Bridge -Lua "return sk.nextZone('$($walk.target)')" -TimeoutSec 180
                }
                if ($t.Tainted) { $tainted = $true }
                $walk.how = "$($t.Result)"
                if ($t.Result -match '^changed') {
                    $now = ($t.Result -replace '^changed ', '') -replace ' \(.*$', ''   # "zone:level", without the note about an arrival dialog
                    Count-Resume $walk.action $s "$($walk.key) -> $now after $($walk.moves) move(s) from $($walk.from)"
                    if ($walk.action -eq 'next-zone') { $zoneTransitions.Add("$($walk.key) -> $now") }
                    $walk = $null
                    # Level generation takes a moment; let the next poll find the new level.
                    Start-Sleep -Seconds $PollSec
                    Start-Bot $s 'after the change'
                    continue
                }
                if ($t.Result -match '^dialog') { continue }   # (a) closes it; the change follows
                # Refused: changeLevelCheck's two turns after a kill. One turn
                # through the game's own MOVE_STAY bind, counted.
                $walk.waits++
                if ($walk.waits -gt 5 -or $t.Status -ne 'OK' -or $t.Result -match '^(error|already|noplayer)') {
                    Abandon-Walk $s "the engine kept refusing: $($t.Status) $($t.Result)"
                    Start-Bot $s 'change refused'
                    continue
                }
                $null = Invoke-Bridge -Lua 'return bridge.key("MOVE_STAY")' -TimeoutSec 30
                $waits++
                Count-Resume 'wait' $s "$($walk.action) refused: $($t.Result)"
                continue
            }
        }

        # ----- inactive: record the stop -----
        $reason = Normalize-Reason $s.reason
        $sev = if ($s.reason -match '^(Stopped|Handed back|Cannot act)') { $Matches[1] } else { '?' }
        if ($stops.ContainsKey($reason)) {
            $stops[$reason].count++; $stops[$reason].last_turn = $s.turn
        } else {
            $stops[$reason] = @{ count = 1; severity = $sev; first_turn = $s.turn; last_turn = $s.turn }
        }
        if ($reason -eq $lastReason -and $s.turn -eq $lastStopTurn) { $sameCount++ } else { $sameCount = 1; $stuckStage = 0 }
        $lastReason = $reason; $lastStopTurn = $s.turn

        # ----- (c) the same stop, no turn taken, again and again -----
        # Two rungs before giving up, each counted. REST first. Then one real
        # move off the tile: the engine's own auto-explore re-targets a vault
        # door whenever the player stands NEXT to it (PlayerExplore.lua:1861,
        # "if we are next to it, then we should try to open it"), so a bot
        # that handed back at the door prompt and was restarted on the same
        # tile walks into the same prompt forever, and only distance breaks
        # it -- the first validation run ended exactly there. Only if the
        # same reason recurs with no turn taken after both is it STUCK.
        if ($sameCount -ge $StuckAfter) {
            if ($stuckStage -eq 0) {
                $stuckStage = 1; $sameCount = 0
                $null = Invoke-Bridge -Lua 'return bridge.key("REST")' -TimeoutSec 30
                Count-Resume 'rest' $s "$reason ($StuckAfter in a row with no turn taken)"
                Start-Sleep -Seconds $PollSec
                $null = Invoke-Bridge -Lua 'return sk.start()' -TimeoutSec 30
                Count-Resume 'restart' $s $reason
                continue
            }
            if ($stuckStage -eq 1) {
                $stuckStage = 2; $sameCount = 0
                $so = Invoke-Bridge -Lua 'return sk.stepOff()' -TimeoutSec 30
                Count-Resume 'step-away' $s "$reason ($StuckAfter more with no turn taken; $($so.Result))"
                $null = Invoke-Bridge -Lua 'return sk.start()' -TimeoutSec 30
                Count-Resume 'restart' $s $reason
                continue
            }
            $stuckLabel = "STUCK $reason"
            $endReason = 'STUCK'; break
        }

        # ----- (f)/(g) on a loop: one reason, one level, -LoopAfter times -----
        # (c) only sees a loop that spends no turns. One that spends a few --
        # #64's sealed door: close, restart, the bot paths back through the
        # door, prompt -- never trips it, and (b)'s step-away is one tile the
        # bot undoes. The count is per level and per reason, so a genuinely
        # recurring measurement on a new level starts from zero.
        if ($LoopAfter -gt 0 -and $s.reason -notmatch 'standing on a level change') {
            $key = "$($s.zone):$($s.zlevel)"
            $loops = Bump-Count $levelLoops "$key|$reason"
            if ($loops -ge $LoopAfter -and ($loops % $LoopAfter) -eq 0) {
                $why = "loop: '$reason' x$loops on $key"
                if (-not $NoDescend -and $s.downs -gt 0) {
                    $walk = @{ action = 'descend'; phase = 'walking'; key = $key; moves = 0; waits = 0; from = "$($s.x),$($s.y)"; how = ''; target = $null; loop = $true }
                    $descendWalks++
                    Write-Host "  walk     descend from $key at $($s.x),$($s.y): $($s.downs) seen down staircase(s), $why"
                    continue
                }
                # #156: NOT only at the bottom of a zone. The trigger used to
                # require zlevel >= zmax, on the assumption that a run leaves a
                # zone when it has finished it -- but a run that is LOOPING has
                # finished with the zone whatever depth it is at, and Doomed
                # proved it: 26,000 turns on trollmire:1 of 3, fifteen
                # hand-backs saying the only way on is the world map, and
                # next-zone never once fired because 1 < 3.
                #
                # Descending is still preferred and still tried first. This is
                # the fallback for a loop with nowhere down to go, and it is
                # strictly better than the alternative it replaces, which was
                # to keep going until MAX_MINUTES.
                if ($zoneList.Count -gt 0) {
                    $visited = @(((Invoke-Bridge -Lua 'return sk.visitedZones()' -TimeoutSec 30).Result -split ',') | Where-Object { $_ })
                    $next = $zoneList | Where-Object { $_.id -ne $s.zone -and $_.id -notin $visited -and $_.min -le ($s.level + 2) } | Select-Object -First 1
                    if ($next) {
                        $walk = @{ action = 'next-zone'; phase = 'taking'; key = $key; moves = 0; waits = 0; from = "$($s.x),$($s.y)"; how = ''; target = $next.id; loop = $true }
                        Write-Host "  walk     next-zone from $key (last level, $why) -> $($next.id) (level_range $($next.min)-$($next.max), character L$($s.level))"
                        continue
                    }
                }
                # #140: "carrying on" with nowhere to go is how a run outlasts
                # its own usefulness. The same reason, on the same level,
                # LoopAfter times, with no staircase seen and no next zone, is
                # the definition of stuck -- so say so once and end on the
                # second, rather than spending the rest of MAX_MINUTES proving
                # it. One firing of grace, because a loop that resolves itself
                # does happen and ending on the first would lose those runs.
                $nowhere = Bump-Count $levelLoops "$key|$reason|nowhere"
                if ($nowhere -ge 2) {
                    $stuckLabel = "STUCK $reason (x$loops on $key, nothing to descend to)"
                    $endReason = 'STUCK'; break
                }
                Write-Host "  loop     $why; no seen down staircase$(if ($NoDescend) { ' (descend off)' }), one more cycle then stopping"
            }
        }

        # ----- (b) stairs, and (f)/(g) on stairs up or the wilderness exit -----
        # #159: "this level is explored" is a DEFINITIVE statement, not a
        # transient one -- the level is finished and the only exit is one the
        # bot will not take (#151, #152). Nothing about it changes by asking
        # again, so waiting for -LoopAfter to believe it is the harness
        # disbelieving the bot on principle. Act on it at once: descend if
        # there is a seen way down, otherwise change zone (#157 removed the
        # depth restriction that used to block that).
        # Also the zone-exit refusal (#151): "the only way on is the world map"
        # is as definitive as "explored", and Doomed stormed it fifteen times in
        # sweep 6 while the harness held the lever that answers it.
        if ($s.reason -match 'this level is explored|leads to the world map') {
            $key = "$($s.zone):$($s.zlevel)"
            if (-not $NoDescend -and $s.downs -gt 0) {
                $walk = @{ action = 'descend'; phase = 'walking'; key = $key; moves = 0; waits = 0
                           from = "$($s.x),$($s.y)"; how = ''; target = $null; loop = $false }
                $descendWalks++
                Write-Host "  walk     descend from ${key}: explored, $($s.downs) seen down staircase(s)"
                continue
            }
            if ($zoneList.Count -gt 0) {
                $visited = @(((Invoke-Bridge -Lua 'return sk.visitedZones()' -TimeoutSec 30).Result -split ',') | Where-Object { $_ })
                $next = $zoneList | Where-Object { $_.id -ne $s.zone -and $_.id -notin $visited -and $_.min -le ($s.level + 2) } | Select-Object -First 1
                if ($next) {
                    $walk = @{ action = 'next-zone'; phase = 'taking'; key = $key; moves = 0; waits = 0
                               from = "$($s.x),$($s.y)"; how = ''; target = $next.id; loop = $false }
                    Write-Host "  walk     next-zone from $key (explored) -> $($next.id)"
                    continue
                }
            }
        }

        # #158: the character levelled up and has points sitting unspent. Spend
        # them and carry on -- unspent points are a hand-back on nearly every
        # run, and behind it a character that never gets stronger.
        if (-not $NoAutoSpend -and $s.reason -match 'unspent points') {
            $as = Invoke-Bridge -Lua 'return sk.autoSpend()' -TimeoutSec 60
            Count-Resume 'auto-spend' $s $as.Result
            Start-Bot $s $reason
            continue
        }

        if ($s.reason -match 'standing on a level change') {
            if ($s.stairs -in @('down', 'zone')) {
                $cl = Invoke-Bridge -Lua 'return bridge.key("CHANGE_LEVEL")' -TimeoutSec 60
                Count-Resume "stairs-$($s.stairs)" $s "$($cl.Result)"
                # Level generation takes a moment; let the next poll find the new level.
                Start-Sleep -Seconds $PollSec
                Start-Bot $s $reason
                continue
            }

            # Up, or the wilderness exit. The Nth hand-back here on this level,
            # or a level with nothing left to explore, is the trigger for both
            # rungs; (f) has priority, because a deeper level of this zone is
            # the measurement the soak is after.
            $key = "$($s.zone):$($s.zlevel)"
            $n = Bump-Count $levelHandbacks $key
            $explored = ($s.explored -eq 'true')
            $ripe = $explored -or ($n -ge $DescendAfter)
            $retryAt = $(if ($descendRetryAt.ContainsKey($key)) { $descendRetryAt[$key] } else { 0 })
            if ($ripe -and -not $NoDescend -and $s.downs -gt 0 -and $n -ge $retryAt) {
                $walk = @{ action = 'descend'; phase = 'walking'; key = $key; moves = 0; waits = 0; from = "$($s.x),$($s.y)"; how = ''; target = $null }
                $descendWalks++
                Write-Host "  walk     descend from $key at $($s.x),$($s.y): $($s.downs) seen down staircase(s), hand-back $n$(if ($explored) { ', explored' })"
                continue
            }
            $lastLevel = ($s.zmax -gt 0 -and $s.zlevel -ge $s.zmax)
            if ($ripe -and $zoneList.Count -gt 0 -and ($lastLevel -or ($s.stairs -eq 'wild' -and $explored -and $s.downs -eq 0))) {
                $visited = @(((Invoke-Bridge -Lua 'return sk.visitedZones()' -TimeoutSec 30).Result -split ',') | Where-Object { $_ })
                $next = $zoneList | Where-Object { $_.id -ne $s.zone -and $_.id -notin $visited -and $_.min -le ($s.level + 2) } | Select-Object -First 1
                if ($next) {
                    $walk = @{ action = 'next-zone'; phase = 'taking'; key = $key; moves = 0; waits = 0; from = "$($s.x),$($s.y)"; how = ''; target = $next.id }
                    Write-Host "  walk     next-zone from $key ($(if ($lastLevel) { 'last level' } else { 'wilderness exit' }), $(if ($explored) { 'explored' } else { "hand-back $n" })) -> $($next.id) (level_range $($next.min)-$($next.max), character L$($s.level))"
                    continue
                }
                Write-Host "  walk     next-zone: nothing left in the list for L$($s.level) (visited: $($visited -join ','))"
            }

            $so = Invoke-Bridge -Lua 'return sk.stepOff()' -TimeoutSec 30
            Count-Resume "step-off-$($s.stairs)" $s "$($so.Result)"
            Start-Bot $s $reason
            continue
        }

        # ----- (e) anything else: start again -----
        $st = Invoke-Bridge -Lua 'return sk.start()' -TimeoutSec 30
        if ($st.Tainted) { $tainted = $true }
        Count-Resume 'restart' $s $reason
    }
    if ($endReason -in @('MAX_MINUTES', 'MAX_LEVEL', 'MAX_TURNS')) { $exit = 0 }
}
finally {
    # Everything in this block runs on the way to Stop-Game, and the script
    # sets ErrorActionPreference 'Stop' -- so any evidence-gathering statement
    # that errors ABORTS the finally, skips Stop-Game, and leaks the game on
    # top of whatever went wrong. Evidence is best-effort; the kill is not.
    # Downgrade to Continue for the cleanup path (#196).
    $ErrorActionPreference = 'Continue'

    # The engine's own complaints, from the whole run's log, before it goes.
    $luaErrors = @()
    try {
        $log = Get-GameLogLines
        for ($i = 0; $i -lt $log.Count; $i++) {
            if ($log[$i] -match 'Lua Error') {
                $ctx = @(); for ($j = $i; $j -lt [math]::Min($i + 4, $log.Count); $j++) { $ctx += $log[$j].Trim() }
                $luaErrors += ($ctx -join ' // ')
            }
        }
    } catch { }
    # #132: read the escort quests before the game goes away. Parsed here into
    # rows so the summary carries structure rather than a string the sweep would
    # have to re-parse.
    $escortRows = @()
    $esc = Invoke-Bridge -Lua 'return sk.escorts()' -TimeoutSec 30
    if ($esc.Status -eq 'OK' -and $esc.Result -and $esc.Result -ne 'none') {
        foreach ($part in ($esc.Result -split ' \| ')) {
            $h = @{}
            foreach ($kv in ($part -split ',')) {
                $eq = $kv.IndexOf('=')
                if ($eq -gt 0) { $h[$kv.Substring(0, $eq)] = $kv.Substring($eq + 1) }
            }
            $escortRows += [pscustomobject]@{
                id           = $h['id']
                kind         = $h['kind']
                status       = $h['status']
                granted_turn = $h['granted_turn']
                killer       = $h['killer']
                selfkill     = ($h['selfkill'] -eq 'true')
            }
        }
        $sk = @($escortRows | Where-Object { $_.selfkill }).Count
        Write-Host "  escorts  $($escortRows.Count): $((($escortRows | ForEach-Object { "$($_.kind)=$($_.status)" }) -join ', '))$(if ($sk -gt 0) { " -- $sk killed by this character" })"
    } else {
        Write-Host "  escorts  none"
    }

    # #138: BEFORE the bot is stopped and before Stop-Game, or the state that
    # needs explaining is already gone. MAX_MINUTES and STUCK are the two
    # endings that do not say why they happened; DEATH and EIDOLON name their
    # killer, and the limit endings are the run working.
    $captureFiles = @()
    if ($TimeoutActionCaptures -gt 0 -and $endReason -in @('MAX_MINUTES', 'STUCK', 'IDLE')) {
        $base  = [IO.Path]::GetFileNameWithoutExtension($OutFile)
        $outDirC = Split-Path -Parent $OutFile
        $notes = New-Object System.Collections.Generic.List[string]
        $notes.Add("ending: $endReason$(if ($stuckLabel) { " ($stuckLabel)" })")
        Write-Host "  capture  ${endReason}: $TimeoutActionCaptures shot(s), the first before any input"
        for ($i = 0; $i -lt $TimeoutActionCaptures; $i++) {
            $stC = Invoke-Bridge -Lua 'return sk.status()' -TimeoutSec 20
            $dlC = Invoke-Bridge -Lua 'return bridge.dialogs()' -TimeoutSec 20
            $shotName = "$base.timeout-$i"
            $shC = Invoke-Bridge -Lua "return sk.shot('$shotName')" -TimeoutSec 60
            $notes.Add('')
            $notes.Add("[$i] state   : $($stC.Result)")
            $notes.Add("[$i] dialogs : $($dlC.Result)")
            $notes.Add("[$i] shot    : $($shC.Result)")
            Write-Host "  capture  $i dialogs=$($dlC.Result)"
            $psrc = Join-Path $script:TomeHome (Join-Path 'tome\screenshots' "$shotName.png")
            if (Test-Path $psrc) {
                if ($outDirC -and -not (Test-Path $outDirC)) { New-Item -ItemType Directory -Force -Path $outDirC | Out-Null }
                Move-Item -Force $psrc (Join-Path $outDirC "$shotName.png")
                $captureFiles += "$shotName.png"
            } else {
                $notes.Add("[$i] WARNING : no file at $psrc")
            }
            # One action between shots, and none after the last: the sequence is
            # shot, act, shot -- so every frame after the first is the answer to
            # a named action rather than to an unknown amount of poking.
            if ($i -lt $TimeoutActionCaptures - 1) {
                $actC = Invoke-Bridge -Lua 'local r = sk.closeDialog() if r == "none" then sk.start() r = "restarted the bot" end return r' -TimeoutSec 30
                $notes.Add("[$i] action  : $($actC.Result)")
                Write-Host "  capture  action -> $($actC.Result)"
            }
        }
        ($notes -join "`n") | Set-Content -Path (Join-Path $outDirC "$base.timeout.txt") -Encoding utf8
        Write-Host "  capture  -> $($captureFiles.Count) png + $base.timeout.txt"
    }

    # A dead game cannot be screenshotted, so its log is the only evidence a
    # crash leaves -- and the engine truncates that log at the next launch, so
    # the next class in a sweep destroys it. The first CRASHED run this project
    # has seen (#185) survived only because it happened to be the last class of
    # a half; one place further up the roster and there would be nothing.
    if ($endReason -in @('CRASHED', 'BRIDGE_LOST')) {
        $baseC   = [IO.Path]::GetFileNameWithoutExtension($OutFile)
        $outDirX = Split-Path -Parent $OutFile
        if (Save-GameLog -Dest (Join-Path $outDirX "$baseC.crash-te4_log.txt")) {
            Write-Host "  capture  ${endReason}: game log kept at $baseC.crash-te4_log.txt"
        }
    }

    $null = Invoke-Bridge -Lua 'if skoobot_reclauded and skoobot_reclauded.active then skoobot_reclauded.stop("soak ended") end return "stopped"' -TimeoutSec 15 -ErrorAction SilentlyContinue

    # #135: drain BEFORE Stop-Game. The ledger lives in the game's memory, so
    # the only chance to write it is while the game is still alive -- the first
    # attempt at this sat next to the summary, after Stop-Game, and reported
    # "CRASHED game not running" on a run that had recorded perfectly well.
    # Written from inside the game because the result channel is the log and
    # these are megabytes.
    $dossierFile = $null
    if ($Dossier) {
        $dname = [IO.Path]::GetFileNameWithoutExtension($OutFile) + '.dossier.json'
        $dw = Invoke-Bridge -Lua "return bridge.dossierWrite('$dname')" -TimeoutSec 120
        Write-Host "  dossier  $($dw.Status) $($dw.Result)"
        # The game writes into its own write path (the module dir), not the
        # bridge dir -- see bridge.dossierWrite.
        $dsrc = Join-Path $script:TomeHome (Join-Path 'tome\dossiers' $dname)
        if (Test-Path $dsrc) {
            $ddst = Join-Path (Split-Path -Parent $OutFile) $dname
            $ddir = Split-Path -Parent $ddst
            if ($ddir -and -not (Test-Path $ddir)) { New-Item -ItemType Directory -Force -Path $ddir | Out-Null }
            Move-Item -Force $dsrc $ddst
            Write-Host "  dossier  -> $ddst"
            $dossierFile = $dname
        } else {
            Write-Host "  dossier  WARNING: no file at $dsrc"
        }
    }

    # #178: read BEFORE Stop-Game, for the reason recorded four lines above
    # about the dossier. This sat after Stop-Game on its first outing and
    # reported `end: null` on a MAX_MINUTES run that had ended with the game
    # perfectly alive -- so the field would have been null on EVERY run, and
    # the equipment change it exists to catch would never have been seen.
    #
    # Still nil where the bridge genuinely cannot answer -- a death, an eidolon
    # rescue, a crash -- and recorded as nil rather than backfilled from the
    # start reading, because "we do not know" and "it did not change" are
    # different and only one of them is true.
    $visionEnd = Get-Vision
    if ($visionEnd) { Write-Host "  vision   end lite=$($visionEnd.lite) sight=$($visionEnd.sight)" }

    Stop-Game

    $ended = Get-Date
    $wall = [math]::Round(($ended - $started).TotalSeconds)
    $stopRows = @($stops.Keys | ForEach-Object {
        [ordered]@{ reason = $_; count = $stops[$_].count; severity = $stops[$_].severity; first_turn = $stops[$_].first_turn; last_turn = $stops[$_].last_turn }
    } | Sort-Object { -$_.count }, { $_.reason })
    $resumeRows = @($resumes.Keys | Sort-Object | ForEach-Object { [ordered]@{ action = $_; count = $resumes[$_] } })
    $summary = [ordered]@{
        save         = $SaveName
        started      = $started.ToString('o')
        ended        = $ended.ToString('o')
        wall_seconds = $wall
        end_reason   = $endReason
        stuck        = $stuckLabel
        limits       = [ordered]@{ max_minutes = $MaxMinutes; max_level = $MaxLevel; max_turns = $MaxTurns }
        turns        = [ordered]@{ start = $(if ($first) { $first.turn } else { -1 }); end = $(if ($last) { $last.turn } else { -1 }); delta = $(if ($first -and $last) { $last.turn - $first.turn } else { 0 }) }
        level        = [ordered]@{ start = $(if ($first) { $first.level } else { -1 }); end = $(if ($last) { $last.level } else { -1 }); max = $peakLevel }
        zones        = @($zoneTrail)
        deaths       = $deaths
        killer       = $killer
        stops        = @($stopRows)
        stop_total   = ($stopRows | ForEach-Object { $_.count } | Measure-Object -Sum).Sum
        resumes      = [ordered]@{ total = ($resumeRows | ForEach-Object { $_.count } | Measure-Object -Sum).Sum; by_action = @($resumeRows); log = @($resumeLog | Select-Object -Last 200) }
        # (f)/(g): the two rungs' own counters, present even at zero.
        rungs        = [ordered]@{
            descend   = [ordered]@{ enabled = (-not $NoDescend); after = $DescendAfter; loop_after = $LoopAfter; taken = $resumes['descend']; walks = $descendWalks; moves = $descendMoves; abandoned = $descendAbandoned }
            next_zone = [ordered]@{ taken = $resumes['next-zone']; transitions = @($zoneTransitions); zones = @($zoneList | ForEach-Object { "$($_.id) ($($_.min)-$($_.max))" }) }
            waits     = $waits
        }
        lua_errors   = [ordered]@{ count = $luaErrors.Count; samples = @($luaErrors | Select-Object -First 10) }
        tainted      = $tainted
        polls        = $polls
        auto_rules   = (-not $NoAutoRules)
        rules_source = $(if ($NoAutoRules) { 'none' } elseif ($ProposedRules) { 'loadout-proposal' } else { 'every-known-talent' })
        dossier      = $dossierFile
        captures     = @($captureFiles)
        escorts      = [ordered]@{
            granted   = $escortRows.Count
            done      = @($escortRows | Where-Object { $_.status -eq 'DONE' }).Count
            failed    = @($escortRows | Where-Object { $_.status -eq 'FAILED' }).Count
            pending   = @($escortRows | Where-Object { $_.status -eq 'PENDING' }).Count
            selfkills = @($escortRows | Where-Object { $_.selfkill }).Count
            rows      = @($escortRows)
        }
        conditions   = @($conditionsApplied)
        take_stairs  = $stairsApplied
        placed_in    = $placedIn
        auto_spend   = $(if ($NoAutoSpend) { 'off' } else { 'on' })
        build_at_start = $buildApplied
        # #178: light radius and sight, at both ends. See Get-Vision above for
        # why this is the number #153's prediction turns on.
        vision       = [ordered]@{ start = $visionStart; end = $visionEnd }
        # #175: the CODE, as opposed to build_at_start, which is the character's
        # stats and talents. Resolved from the junction the game loads.
        build          = $script:BuildStamp
        scratch_save = $ScratchSave
    }
    $dir = Split-Path -Parent $OutFile
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    ($summary | ConvertTo-Json -Depth 6) | Set-Content -Path $OutFile -Encoding utf8

    $md = New-Object System.Collections.Generic.List[string]
    $md.Add("# Soak: $SaveName, $($started.ToString('yyyy-MM-dd HH:mm'))")
    $md.Add('')
    $md.Add('| measure | value |')
    $md.Add('|---|---|')
    $md.Add("| ended | $endReason$(if ($stuckLabel) { " ($stuckLabel)" }) |")
    $md.Add("| wall-clock | $wall s of $($MaxMinutes * 60) s |")
    $md.Add("| game.turn | $($summary.turns.start) -> $($summary.turns.end) (+$($summary.turns.delta), ~$([math]::Floor($summary.turns.delta / 10)) player turns) |")
    $md.Add("| level | $($summary.level.start) -> $($summary.level.end) (max $peakLevel, limit $MaxLevel) |")
    $md.Add("| zones | $($zoneTrail -join ' > ') |")
    $md.Add("| deaths | $deaths$(if ($killer) { " (killed by $killer)" }) |")
    if ($escortRows.Count -gt 0) {
        $sk2 = @($escortRows | Where-Object { $_.selfkill }).Count
        $md.Add("| escorts | $($escortRows.Count) granted, $(@($escortRows | Where-Object { $_.status -eq 'DONE' }).Count) done, $(@($escortRows | Where-Object { $_.status -eq 'FAILED' }).Count) failed$(if ($sk2 -gt 0) { ", **$sk2 killed by this character**" }) |")
    }
    if ($captureFiles.Count -gt 0) { $md.Add("| captures | $($captureFiles -join ', ') (+ $([IO.Path]::GetFileNameWithoutExtension($OutFile)).timeout.txt) |") }
    $md.Add("| stops | $($summary.stop_total) across $($stopRows.Count) reason(s) |")
    $md.Add("| resumes | $($summary.resumes.total) |")
    $md.Add("| descend | $($resumes['descend']) taken ($descendWalks walk(s), $descendMoves move(s), $descendAbandoned abandoned; $(if ($NoDescend) { 'off' } else { "after $DescendAfter hand-backs, explored, or a loop of $LoopAfter" })) |")
    $md.Add("| next-zone | $($resumes['next-zone']) taken$(if ($zoneTransitions.Count -gt 0) { ' (' + ($zoneTransitions -join '; ') + ')' }); list: $(($zoneList | ForEach-Object { $_.id }) -join ' > ') |")
    $md.Add("| waits | $waits (a change refused for two turns after a kill) |")
    $md.Add("| Lua errors | $($luaErrors.Count) |")
    $md.Add("| tainted | $tainted |")
    $md.Add("| conditions | $(if ($conditionsApplied.Count -gt 0) { $conditionsApplied -join ', ' } else { 'defaults' }) |")
    $md.Add("| take_stairs | $stairsApplied |")
    if ($placedIn) { $md.Add("| placed_in | $placedIn -- the character was PUT here, it did not walk (#160) |") }
    $md.Add("| polls | $polls every $PollSec s |")
    $md.Add('')
    $md.Add('| stop reason | count | severity | first turn | last turn |')
    $md.Add('|---|---:|---|---:|---:|')
    foreach ($row in $stopRows) { $md.Add("| $($row.reason) | $($row.count) | $($row.severity) | $($row.first_turn) | $($row.last_turn) |") }
    $md.Add('')
    $md.Add('| resume action | count |')
    $md.Add('|---|---:|')
    foreach ($row in $resumeRows) { $md.Add("| $($row.action) | $($row.count) |") }
    if ($luaErrors.Count -gt 0) {
        $md.Add('')
        $md.Add('Lua errors (first 10):')
        foreach ($e in ($luaErrors | Select-Object -First 10)) { $md.Add("- ``$e``") }
    }
    ($md -join "`n") | Set-Content -Path $MdFile -Encoding utf8

    Write-Host ''
    foreach ($l in $md) { Write-Host $l }
    Write-Host ''
    Write-Host "[soak] summary written to $OutFile (and $MdFile)"
    if ($exit -eq 0) { Write-Host "[soak] DONE - ended on $endReason" } else { Write-Host "[soak] ENDED - $endReason$(if ($stuckLabel) { " ($stuckLabel)" })" }
}
exit $exit
