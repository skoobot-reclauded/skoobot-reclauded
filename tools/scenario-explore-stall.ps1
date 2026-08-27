<#
    #164/#153: the engine and the bot disagree about what is in view, and the
    pair live-locks.

    #164's Shadowblade burned 21,368 game turns exploring past a black jelly
    that could never move or reach it: the engine aborted every run for a
    hostile, and the bot's own spotHostiles found nothing, so it explored
    again. Zero hand-backs, no damage, and #13's liveness invariant satisfied
    throughout -- only #145's IDLE detector ever noticed.

    THE MECHANISM, which this probe exists to pin rather than to assume.

    spotHostiles reports an actor only where `map.seens(x, y)` is set, and
    engine/Map.lua:649 sets it for a grid in FOV ONLY IF THE GRID IS LIT:

        function _M:apply(x, y, v)
            self.infovs[x + y * self.w] = true
            if self.lites[x + y * self.w] then
                self.seens[x + y * self.w] = v or 1

    Inside the character's own light radius, applyExtraLite (:663) sets it
    unconditionally. So a hostile four to eight grids away, in plain line of
    sight and well within sight range, is simply NOT in seens while it stands
    in the dark -- and the moment the character walks close enough to light it,
    it is.

    That would be harmless if the map were wiped each step. It is not.
    Map:cleanFOV (:460) returns early unless map.clean_fov is armed, and the
    only thing that arms it during play is Map:display() at :620 -- a DRAWN
    FRAME. No frame is drawn inside act()'s `while ... runStep() do end` loop,
    so seens accumulates across a whole run: everything lit from anywhere along
    the path stays marked. The engine's runCheck consults that union and aborts.
    runStopped then arms the flag and recomputes, so the bot's next decision
    reads a clean, current, DARK map and finds nothing to fight.

    Neither view is stale. The engine's is a superset, and the difference is
    made of grids that were lit earlier in the run and are dark now.

    runMoved's whole body is playerFOV(), so moving the character and calling
    playerFOV() without arming the flag IS what a run step does. The probe is
    the mechanism, not an imitation of it -- no frame starvation, no fast
    driving, no waiting for the wild.

    A  the search itself: find a grid where a CLEAN view is blind to the
       hostile but an ACCUMULATED one is not. Finding one at all is the proof;
       the assertions below say it was found and that it is the real thing.
    B  runStopped arms the flag, so the same exported spotHostiles returns the
       wide set before that call and the narrow one after -- and the
       disagreement is counted.
    C  repeated, the branch reports the level stalled, so the explore branch
       stops re-issuing a run the engine will abort identically.
    D  an abort both views agree about resets the count, so a hostile that
       merely moved can never reach the limit.

    NOT COVERED, deliberately: the end-to-end probe #164 asks for -- drive the
    bot and assert the explored fraction rises. That needs the character driven
    for real past a hostile in a geometry that has to survive its own AI, and
    it is a different scenario. A to D pin the mechanism, the detection and the
    decision, which is what #164 was blocked on.

    THE DARKNESS IS STAGED. Measured on this fixture: 50 of 80 candidate grids
    were in line of sight of a hostile and NOT ONE of them was dark, so this
    zone can never produce the failure. The probe therefore darkens the
    hostile's grid and puts the light back, the way scenario-explore-exits
    builds an exhausted level rather than exploring one to exhaustion.

    Everything moved or darkened is put back and every restoration is
    asserted. The stall counter is reset at the end: leaving it at the limit
    would leave the character unable to explore the level this borrowed.

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
-- bot's private copy. They are line-identical, so using ONE function on both
-- sides of the test leaves time as the only variable, which is the whole claim.
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

-- A hostile to disagree about. #164's never_move jelly is why the loop never
-- ENDS, not why it starts, so an immovable one is not needed to reproduce it.
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
say("sight", p.sight or 10)
say("lite", p.lite or 0)

local function targetSeen()
  for _, h in ipairs(p:spotHostiles(true)) do
    if h.actor == hostile then return true end
  end
  return false
end

-- Somewhere the character can be force-moved to and back without disturbing
-- anything. An occupied grid is excluded deliberately: a forced move onto
-- another actor overwrites it in the ACTOR layer, and stepping off again would
-- leave the grid empty -- the scenario would delete a monster and then restore
-- clean.
local function standable(x, y)
  return map:isBound(x, y)
     and not map:checkAllEntities(x, y, "block_move")
     and not map(x, y, map.ACTOR)
end

-- NEAR: beside the hostile, so it is inside the character's own light radius
-- and applyExtraLite marks its grid unconditionally.
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

------------------------------------------------------------------- A: the search
-- FAR must satisfy three things at once, and the earlier version of this probe
-- guessed at all three and got them wrong: within SIGHT of the hostile so
-- spotHostiles' calc_circle reaches its grid at all; in LINE OF SIGHT so the
-- walk is not blocked by terrain; and DARK, so a clean view does not mark it.
-- None of that is worth deriving -- it is cheaper and far more honest to try
-- candidates and keep the one that actually behaves that way.
-- Map:apply hands us the discriminator directly: `infovs` is set for every
-- grid in FOV whatever the light, `seens` only for the lit ones. So
-- "in line of sight but dark" is exactly infovs AND NOT seens, and there is no
-- need to move-and-hope. The first version of this probe sorted candidates
-- FURTHEST first on the theory that distant meant dark; 28 of 60 were blind
-- and none reproduced, because at the edge of sight they were blind from
-- terrain rather than darkness, and no amount of accumulating helps a walk
-- that is blocked.
local sight = p.sight or 10
local lite = p.lite or 0
local hi = hostile.x + hostile.y * map.w

-- STAGED: the hostile's grid is put into darkness, and put back at the end.
--
-- Measured on this fixture before staging was added: of 80 candidate grids, 50
-- were in line of sight of the hostile and NONE of them was dark. The zone is
-- lit wherever it can be seen, so the disagreement cannot arise on it at all
-- -- which is a fact about this save, not about the defect. Darkness is the
-- condition the mechanism needs, so the probe creates it rather than hunting
-- for a save that happens to have it, the way scenario-explore-exits builds
-- an exhausted level instead of exploring one to exhaustion.
--
-- Map:apply reads self.lites by raw index, so clearing that index is exactly
-- what makes the grid dark for the path under test. The C mirror
-- (_map:setLite) is deliberately left alone: the renderer is not part of this
-- and perturbing less is worth more than a tidy-looking screen.
local lit_before = map.lites[hi]
map.lites[hi] = nil
say("staged_dark", (map.lites[hi] == nil))
say("was_lit", (lit_before ~= nil))

-- STAGED: bot.active. noteRunStop is deliberately inert while a human plays --
-- the guard exists to stop the BOT re-issuing its own explore -- so the probe
-- has to say the bot is running or it would measure the disabled path and
-- report a green nothing. Put back at the end.
local active_before = bot.active
bot.active = true
say("staged_active", (bot.active == true))

local cands = {}
for x = 0, map.w - 1 do for y = 0, map.h - 1 do
  local d = core.fov.distance(hostile.x, hostile.y, x, y)
  if d > lite and d <= sight and standable(x, y) then cands[#cands+1] = {x = x, y = y, d = d} end
end end
table.sort(cands, function(a, b) return a.d < b.d end)   -- nearest dark grid first: likeliest to have LOS
say("candidates", #cands)

local far, tried, los, dark = nil, 0, 0, 0
for _, c in ipairs(cands) do
  if far or tried >= 80 then break end
  tried = tried + 1
  p:move(c.x, c.y, true)
  fovClean()
  local inLos = map.infovs[hi] and true or false
  local isLit = map.seens(hostile.x, hostile.y) and true or false
  if inLos then los = los + 1 end
  -- In line of sight, unlit, and nothing else in view either -- the last
  -- because noteRunStop's narrow read has to be zero for the disagreement to
  -- count.
  if inLos and not isLit and wide() == 0 then
    dark = dark + 1
    p:move(near.x, near.y, true) ; fovAccumulate()
    p:move(c.x, c.y, true)       ; fovAccumulate()
    if targetSeen() then far = c end
  end
end
say("a_tried", tried)
say("a_in_los", los)
say("a_los_and_dark", dark)
if not far then
  map.lites[hi] = lit_before ; bot.active = active_before
  p:move(startx, starty, true) ; fovClean()
  say("setup", "no grid found that is in line of sight of the hostile with nothing else in view"
      .. " (tried " .. tried .. ", " .. los .. " in line of sight, " .. dark
      .. " of those dark and otherwise empty); the hostile may be in a crowded or enclosed spot")
  return table.concat(r, "  ||  ")
end
say("far_at", far.x .. "," .. far.y)
say("far_distance", far.d)
-- Standing at FAR with the accumulated view: the hostile is reported.
say("a_wide", wide())
say("a_target_seen", targetSeen())
say("a_at_far", (p.x == far.x and p.y == far.y))

------------------------------------------------------- B: runStopped, and the count
local before = bot.levelState("explorestall").n or 0
say("b_count_before", before)
local b_ok, b_err = pcall(function() p:runStopped() end)
say("b_ok", b_ok)
if not b_ok then say("b_err", tostring(b_err)) end
say("b_narrow", wide())
say("b_target_seen", targetSeen())
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
map.lites[hi] = lit_before
bot.active = active_before
p:move(startx, starty, true)
fovClean()
bot.levelState("explorestall").n = 0
say("restored_lit", (map.lites[hi] == lit_before))
say("restored_active", (bot.active == active_before))
say("restored_pos", (p.x == startx and p.y == starty))
say("restored_level", (game.level == startlevel))
say("restored_stall", bot.exploreStalled())
say("restored_hostile_alive", (not hostile.dead) and true or false)

return table.concat(r, "  ||  ")
'@ 180

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
    Write-Host "  measured  $($kv['hostile']) at $($kv['hostile_at']); sight $($kv['sight']), light radius $($kv['lite'])"
    Write-Host "  measured  A: $($kv['a_tried']) grids tried, $($kv['a_in_los']) in line of sight, $($kv['a_los_and_dark']) of those dark"
    Write-Host "  measured  A: $($kv['far_at']) is $($kv['far_distance']) away and sees it only when accumulated"
    Write-Host "  measured  B: after runStopped the same call sees $($kv['b_narrow'])"
    Write-Host ''

    # PROVES THE SITUATION WAS BUILT. Without these the probe could pass having
    # stood in one place looking at nothing.
    Check ($kv['was_lit'] -eq 'true') 'the hostile stood on a lit grid, so darkening it is a real change'
    Check ($kv['staged_dark'] -eq 'true') 'and it was darkened for the probe'
    # Without this the probe would exercise the disabled path and report a
    # green nothing: noteRunStop is inert unless the bot is running.
    Check ($kv['staged_active'] -eq 'true') 'the bot was marked active, so the wrapper is not the inert path'
    Check ([int]$kv['a_tried'] -gt 0) 'candidate grids within sight of the hostile were tried'
    Check ($kv['a_at_far'] -eq 'true') 'the character is standing on the grid that was found'
    Check ([int]$kv['far_distance'] -le [int]$kv['sight']) 'and it is within sight range, so the FOV walk reaches the hostile'
    Check ([int]$kv['far_distance'] -gt [int]$kv['lite']) 'and beyond the light radius, which is why a clean view is blind to it'

    # A. The finding #153 read out of the source, now measured. Standing still,
    # the same function reports the hostile or not depending only on whether
    # the map was wiped since the character was last close enough to light it.
    Check ($kv['a_target_seen'] -eq 'true') 'seens ACCUMULATES: from a grid blind to it when clean, the hostile is in view'
    Check ([int]$kv['a_wide'] -gt 0) 'and spotHostiles reports it, which is what aborts the engine run'

    # B. runStopped arms clean_fov and recomputes, so the same call after it
    # returns the current-position set. The difference IS the disagreement.
    Check ($kv['b_ok'] -eq 'true') "runStopped did not raise ($($kv['b_err']))"
    Check ($kv['b_target_seen'] -eq 'false') 'after runStopped the hostile is gone from the same call'
    Check ($kv['b_narrow'] -eq '0') 'and nothing else is in view either: the map was cleaned'
    Check ([int]$kv['b_count_after'] -eq [int]$kv['b_count_before'] + 1) 'the disagreement was counted'
    Check ($kv['b_stalled'] -eq 'false') 'one disagreement is not a stall'

    # C. The decision #153's option 2 makes. Bounded in Lua, so a guard that
    # never fires fails here rather than hanging the run.
    Check ($kv['c_stalled'] -eq 'true') "repeated disagreement reports the level stalled (after $($kv['c_cycles']) cycles)"
    Check ([int]$kv['c_cycles'] -lt 20) 'and it got there without hitting the probe bound'

    # D. The guard that keeps a MOVING hostile from reaching the limit, which
    # is why the count is consecutive rather than total.
    Check ($kv['d_wide_before'] -eq '0') 'with a clean view there is nothing to disagree about'
    Check ($kv['d_count_after'] -eq '0') 'an abort both views agree about resets the count'
    Check ($kv['d_stalled'] -eq 'false') 'and the level is no longer stalled'

    Check ($kv['restored_lit'] -eq 'true') 'the light was put back on the hostile grid'
    Check ($kv['restored_active'] -eq 'true') 'and the bot was left as it was found'
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
