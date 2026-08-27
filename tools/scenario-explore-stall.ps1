<#
    #164/#153: the engine and the bot disagree about what is in view, and the
    pair live-locks.

    #164's Shadowblade burned 21,368 game turns exploring past a black jelly
    that could never move or reach it: the engine aborted every run for a
    hostile, and the bot's own spotHostiles found nothing, so it explored
    again. Zero hand-backs, no damage, and #13's liveness invariant satisfied
    throughout -- only #145's IDLE detector ever noticed.

    #153 settled why from the source, and this measures it rather than
    trusting the reading. engine/Map.lua:460's cleanFOV() returns early unless
    map.clean_fov is armed, and the only thing that arms it during play is
    Map:display() at :620 -- a DRAWN FRAME. No frame is drawn inside act()'s
    `while ... runStep() do end` loop, so every runMoved() -> playerFOV() adds
    to seens without clearing it, and the engine's runCheck consults the union
    of everything seen along the run path. runStopped then arms the flag and
    recomputes, so the bot's later view is clean and current. Neither side is
    stale; the engine's is a superset.

    THE MECHANISM IS REPRODUCED DIRECTLY, not by running fast enough to starve
    the renderer. runMoved's whole body is `playerFOV()`, so moving the
    character and calling playerFOV() without arming the flag IS what a run
    step does -- the probe is the mechanism, not an imitation of it.

    A  accumulate: seen from a grid beside the hostile, then step away and
       recompute WITHOUT arming -> the hostile is still in seens, from a grid
       it cannot be seen from. That is what aborts the engine's run.
    B  runStopped arms the flag, so the same function returns the wide set
       before that call and the narrow one after -- and the disagreement is
       counted.
    C  at the limit the bot reports the level stalled, so the explore branch
       stops re-issuing a run the engine will abort identically.
    D  an abort both views agree about resets the count, so a hostile that
       merely moved can never reach the limit.

    NOT COVERED, deliberately: the end-to-end "explored fraction rises" probe
    #164 asks for. It needs the character driven for real past a hostile in a
    geometry that has to be built, and writing that blind -- against a harness
    that was leased elsewhere for the whole of this change -- is how a
    scenario ends up green and inert (#169 has two of those). It wants a
    session that can run it. A to D pin the mechanism, the detection and the
    decision, which is what #164 was blocked on.

    Everything moved or marked is put back, and the restoration is asserted.
    The stall counter is reset at the end: leaving it at the limit would leave
    the character unable to explore this level.

    Exit codes:  0 pass   1 fail   2 tainted   3 inconclusive

    Run:
        powershell -ExecutionPolicy Bypass -File .\tools\scenario-explore-stall.ps1

    #164, and it pins #153's finding.
#>
[CmdletBinding()]
param([string]$SaveName = 'harness')

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'harness.ps1')

$script:Fail = @()
function Check($ok, $what) {
    if ($ok) { Write-Host "  PASS  $what" } else { Write-Host "  FAIL  $what"; $script:Fail += $what }
}

Write-Host ''
Write-Host '[explore-stall] does the engine abort runs for a hostile the bot cannot see? (#164, #153)'

try {
    $g = Load-Save -Name $SaveName
    if (-not $g.Ready) { Write-Host "[explore-stall] FAILED - could not load '$SaveName' ($($g.Reason))"; exit 1 }
    Check ($g.Addons -match 'skoobot_reclauded') 'the product is loaded'

    $out = Invoke-Bridge -Lua @'
local p = game.player
local bot = skoobot_reclauded
local map = game.level.map
local r = {}
local function say(k, v) r[#r+1] = k .. "=" .. tostring(v) end

local startx, starty, startlevel = p.x, p.y, game.level

-- The engine's own exported spotHostiles (mod/class/Player.lua:956), not the
-- bot's private copy. They are line-identical, and using the engine's makes
-- the ONLY variable between the two reads the thing under test: time.
if not p.spotHostiles then
  say("setup", "this build has no Player:spotHostiles to compare against")
  return table.concat(r, "  ||  ")
end
if not bot.exploreStalled or not bot.levelState then
  say("setup", "this build predates bot.exploreStalled (#153)")
  return table.concat(r, "  ||  ")
end

local function wide() return #p:spotHostiles(true) end
local function fovClean() map.clean_fov = true ; p:playerFOV() end
local function fovAccumulate() p:playerFOV() end          -- exactly runMoved's body

-- A hostile to disagree about. Any will do: #164's never_move jelly is why the
-- loop never ENDS, not why it starts, so the probe does not need an immovable
-- one to reproduce the disagreement.
local hostile
for _, e in pairs(game.level.entities or {}) do
  if e ~= p and e.faction and e.x and not e.dead
     and p.reactionToward and p:reactionToward(e) < 0 then hostile = e ; break end
end
if not hostile then
  say("setup", "no hostile on this level to disagree about")
  return table.concat(r, "  ||  ")
end
say("hostile", hostile.name)
say("hostile_at", hostile.x .. "," .. hostile.y)

-- Somewhere the character can be force-moved to and back without disturbing
-- anything. An occupied grid is excluded deliberately: a forced move onto
-- another actor overwrites it in the ACTOR layer, and stepping off again would
-- leave the grid empty -- the scenario would delete a monster and restore
-- clean.
local function standable(x, y)
  return map:isBound(x, y)
     and not map:checkAllEntities(x, y, "block_move")
     and not map(x, y, map.ACTOR)
end

-- NEAR: a walkable grid beside the hostile, so it is certainly in view there.
local near
for dx = -1, 1 do for dy = -1, 1 do
  if not near and not (dx == 0 and dy == 0) and standable(hostile.x + dx, hostile.y + dy) then
    near = {x = hostile.x + dx, y = hostile.y + dy}
  end
end end
if not near then
  say("setup", "nothing standable beside the hostile")
  return table.concat(r, "  ||  ")
end

-- FAR: the standable grid furthest from the hostile, which is the likeliest to
-- have no line of sight to it. Proven below rather than assumed.
local far, fard
for x = 0, map.w - 1 do for y = 0, map.h - 1 do
  if standable(x, y) then
    local d = core.fov.distance(hostile.x, hostile.y, x, y)
    if not fard or d > fard then far, fard = {x = x, y = y}, d end
  end
end end
if not far then
  say("setup", "no standable grid to stand away from the hostile")
  return table.concat(r, "  ||  ")
end
-- The character's own grid holds an actor -- itself -- so standable() rejects
-- it, and a level with exactly one free grid would give near == far and prove
-- nothing.
if near.x == far.x and near.y == far.y then
  say("setup", "the only standable grid is beside the hostile")
  return table.concat(r, "  ||  ")
end
say("far_at", far.x .. "," .. far.y)
say("far_distance", fard)

-- FAR must be blind to the hostile with a CLEAN view, or there is no
-- disagreement to produce and every assertion below would be vacuous.
p:move(far.x, far.y, true)
fovClean()
local far_clean = wide()
say("far_clean_sees", far_clean)
if far_clean > 0 then
  p:move(startx, starty, true) ; fovClean()
  say("setup", "the furthest walkable grid still sees a hostile; this level is too open")
  return table.concat(r, "  ||  ")
end

------------------------------------------------------------------ A: accumulate
-- Beside the hostile, accumulating rather than cleaning -- what runMoved does.
-- The move is verified: one that silently did not happen would leave every
-- assertion below measuring the same grid twice and passing on nothing.
p:move(near.x, near.y, true)
say("a_near_landed", (p.x == near.x and p.y == near.y))
fovAccumulate()
say("a_near_sees", wide())

-- Back to FAR, still accumulating. seens now holds FOV(far) + FOV(near), which
-- is the set the engine's runCheck consults mid-run.
p:move(far.x, far.y, true)
fovAccumulate()
local a_wide = wide()
say("a_wide", a_wide)
say("a_at_far", (p.x == far.x and p.y == far.y))

------------------------------------------------------- B: runStopped, and the count
local before = bot.levelState("explorestall").n or 0
say("b_count_before", before)
local b_ok, b_err = pcall(function() p:runStopped() end)
say("b_ok", b_ok)
if not b_ok then say("b_err", tostring(b_err)) end
local b_narrow = wide()
say("b_narrow", b_narrow)
say("b_count_after", bot.levelState("explorestall").n or 0)
say("b_stalled", bot.exploreStalled())

--------------------------------------------------------------- C: reach the limit
-- Repeat the accumulate-then-stop cycle until the branch reports the level
-- stalled, bounded so a guard that never fires fails the probe instead of
-- hanging it.
local cycles = 0
while not bot.exploreStalled() and cycles < 20 do
  p:move(near.x, near.y, true) ; fovAccumulate()
  p:move(far.x, far.y, true)   ; fovAccumulate()
  p:runStopped()
  cycles = cycles + 1
end
say("c_cycles", cycles)
say("c_stalled", bot.exploreStalled())

---------------------------------------------------- D: agreement resets the count
-- A run that ends with both views agreeing -- here, nothing in view at all --
-- must clear the run. This is what stops a hostile that merely MOVED out of
-- view from ever reaching the limit.
fovClean()
say("d_wide_before", wide())
p:runStopped()
say("d_count_after", bot.levelState("explorestall").n or 0)
say("d_stalled", bot.exploreStalled())

------------------------------------------------------------------------ restore
p:move(startx, starty, true)
fovClean()
bot.levelState("explorestall").n = 0
say("restored_pos", (p.x == startx and p.y == starty))
say("restored_level", (game.level == startlevel))
say("restored_stall", bot.exploreStalled())
say("restored_hostile_alive", (not hostile.dead) and true or false)

return table.concat(r, "  ||  ")
'@

    Write-Host "  raw: $($out.Result)"
    if ($out.Tainted) { Write-Host '[explore-stall] TAINTED'; exit 2 }

    $kv = @{}
    foreach ($pair in ($out.Result -split '\s+\|\|\s+')) {
        $i = $pair.IndexOf('=')
        if ($i -gt 0) { $kv[$pair.Substring(0, $i)] = $pair.Substring($i + 1) }
    }

    if ($kv.ContainsKey('setup')) {
        Write-Host "[explore-stall] INCONCLUSIVE - $($kv['setup'])"
        exit 3
    }

    Write-Host ''
    Write-Host "  measured  the hostile is $($kv['hostile']) at $($kv['hostile_at'])"
    Write-Host "  measured  standing $($kv['far_distance']) away at $($kv['far_at']), a clean view sees $($kv['far_clean_sees']) hostile(s)"
    Write-Host "  measured  A: beside it a clean-free view sees $($kv['a_near_sees']); back at range it still sees $($kv['a_wide'])"
    Write-Host "  measured  B: after runStopped the same call sees $($kv['b_narrow'])"
    Write-Host ''

    # PROVES THE SITUATION WAS BUILT. Without this the probe could pass having
    # stood in one place looking at nothing.
    Check ($kv['far_clean_sees'] -eq '0') 'with a clean view, the far grid sees no hostile'
    Check ($kv['a_near_landed'] -eq 'true') 'the character actually reached the grid beside the hostile'
    Check ([int]$kv['a_near_sees'] -gt 0) 'beside the hostile, it is in view'
    Check ($kv['a_at_far'] -eq 'true') 'the character is back at the far grid'

    # A. The finding #153 read out of the source, now measured: the hostile is
    # still "seen" from a grid it cannot be seen from, because nothing wiped
    # the map between the two positions. This is what the engine's runCheck
    # consults, and it is why it aborts runs the bot cannot explain.
    Check ([int]$kv['a_wide'] -gt 0) 'seens ACCUMULATES: at range, a hostile only visible from elsewhere is still in view'

    # B. runStopped arms clean_fov and recomputes, so the same function called
    # after it returns the current-position set. The difference between the two
    # reads IS the disagreement -- there is nothing else to attribute it to.
    Check ($kv['b_ok'] -eq 'true') "runStopped did not raise ($($kv['b_err']))"
    Check ($kv['b_narrow'] -eq '0') 'and after runStopped the same call sees nothing: the view was cleaned'
    Check ([int]$kv['b_count_after'] -eq [int]$kv['b_count_before'] + 1) 'the disagreement was counted'
    Check ($kv['b_stalled'] -eq 'false') 'one disagreement is not a stall'

    # C. The decision #153 option 2 makes. Bounded in Lua, so a guard that
    # never fires fails here rather than hanging the run.
    Check ($kv['c_stalled'] -eq 'true') "repeated disagreement reports the level stalled (after $($kv['c_cycles']) cycles)"
    Check ([int]$kv['c_cycles'] -lt 20) 'and it got there without hitting the probe bound'

    # D. The guard that keeps a MOVING hostile from ever reaching the limit,
    # which is the whole reason the count is consecutive rather than total.
    Check ($kv['d_wide_before'] -eq '0') 'with a clean view there is nothing to disagree about'
    Check ($kv['d_count_after'] -eq '0') 'an abort both views agree about resets the count'
    Check ($kv['d_stalled'] -eq 'false') 'and the level is no longer stalled'

    Check ($kv['restored_pos'] -eq 'true') 'the character was put back where it started'
    Check ($kv['restored_level'] -eq 'true') 'the level was not changed'
    Check ($kv['restored_stall'] -eq 'false') 'the stall counter was cleared, so the level can still be explored'
    Check ($kv['restored_hostile_alive'] -eq 'true') 'the hostile was left alone'

    if ($script:Fail.Count -gt 0) { Write-Host "[explore-stall] FAILED - $($script:Fail.Count) check(s)"; exit 1 }
    Write-Host '[explore-stall] PASS'
    exit 0
} catch {
    Write-Host "[explore-stall] ERROR $_"
    exit 3
} finally {
    Stop-Game | Out-Null
}
