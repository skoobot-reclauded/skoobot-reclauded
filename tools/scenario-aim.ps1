<#
    #148: does the bot put an area talent where it catches most, rather than on
    whichever enemy it happened to pick?

    The owner's example is the one this builds: "instead of beaming the closest
    or strongest enemy, beam the guy at the end of the hall -- that way you beam
    all 9 enemies in it."

    THE GEOMETRY, and why it needs three actors rather than two. With two
    enemies in a ball's radius of each other, both candidates catch both, and
    the scenario would pass without the search doing anything. So:

        P . . . . A . . . B C

    one hostile NEAR (which is what getNearestHostile picks), and two clustered
    FAR, adjacent to each other and more than a radius away from the near one.
    A ball centred on A catches one. Centred on B it catches two. The pick is A;
    the right answer is B; and before #148 the bot never asked.

    THE TALENT IS SEARCHED FOR, not named. An id hardcoded here rots the moment
    ToME moves a file, and the first attempt at this scenario went looking for
    data/talents/spell/fire.lua, which does not exist. Instead every defined
    talent is asked what its target type resolves to, and the first genuine ball
    with a usable radius and range is force-learned. If the module has none the
    probe is INCONCLUSIVE, which is honest, rather than red.

    A  the situation is built: a ball talent, three hostiles, the geometry
    B  aimPointFor picks the FAR cluster, not the near pick
    C  a non-area talent is left alone -- nil, so the rotation fires as before

    NOT COVERED: a friendly in the blast being priced rather than ignored.
    data/aim.lua's arithmetic for it is unit-pinned, but the projection's
    counting of it is not tested here -- it needs an ally placed in the radius,
    and the escortee is the only ally a fixture reliably has. That wants
    scenario-escort's staging, not this one's.

    Everything staged is restored and the restoration is asserted: factions,
    spawned actors, the learned talent, and the character's position.

    Exit codes:  0 pass   1 fail   2 tainted   3 inconclusive

    Run:
        powershell -ExecutionPolicy Bypass -File .\tools\scenario-aim.ps1

    NOT YET RUN -- written while the harness was reserved for another work
    stream. #148.
#>
[CmdletBinding()]
param([string]$SaveName = 'fixture-berserker')

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'harness.ps1')

$script:Fail = @()
function Check($ok, $what) {
    if ($ok) { Write-Host "  PASS  $what" } else { Write-Host "  FAIL  $what"; $script:Fail += $what }
}

Write-Host ''
Write-Host '[aim] does an area talent go where it catches most? (#148)'

try {
    $g = Load-Save -Name $SaveName
    if (-not $g.Ready) { Write-Host "[aim] FAILED - could not load '$SaveName' ($($g.Reason))"; exit 1 }
    Check ($g.Addons -match 'skoobot_reclauded') 'the product is loaded'

    $out = Invoke-Bridge -TimeoutSec 180 -Lua @'
local p = game.player
local b = skoobot_reclauded
local map = game.level.map
local r = {}
local function say(k, v) r[#r+1] = k .. "=" .. tostring(v) end

if not b or not b.aimPointFor then
  say("setup", "this build predates bot.aimPointFor (#148)")
  return table.concat(r, "  ||  ")
end

local startx, starty, startlevel = p.x, p.y, game.level

-- Pacify, so nothing else is a foe and the counts mean what they say. The
-- factions are put back at the end and the restoration is asserted.
local pacified = {}
for _, e in pairs(game.level.entities or {}) do
  if e ~= p and e.faction and e.x and p.reactionToward and p:reactionToward(e) < 0 then
    pacified[#pacified+1] = { e, e.faction }
    e.faction = p.faction
  end
end
say("pacified", #pacified)

local function standable(x, y)
  return map:isBound(x, y)
     and not map:checkAllEntities(x, y, "block_move")
     and not map(x, y, map.ACTOR)
end

-- A genuine ball talent, found rather than named.
--
-- NOTHING IS LEARNED TO TEST IT. getTalentTarget does not require the talent to
-- be known, so every candidate is inspected without touching the character --
-- an earlier draft force-learned each one in turn to look at it, which fires
-- on_learn for hundreds of talents on a fixture and trusts on_unlearn to be its
-- exact inverse. Only the ONE that is chosen is learned.
--
-- Sorted, because pairs() over talents_def is unordered and a scenario that
-- picks a different talent on each run cannot be compared with itself.
local names = {}
for tid, t in pairs(p.talents_def or {}) do
  if type(t) == "table" and t.mode == "activated" and not t.no_npc_use and type(tid) == "string" then
    names[#names+1] = tid
  end
end
table.sort(names)

local learned, ballTid, radius, trange
for _, tid in ipairs(names) do
  if ballTid then break end
  local t = p.talents_def[tid]
  local okt, tg = pcall(p.getTalentTarget, p, t)
  if okt and type(tg) == "table" and not tg.multiple then
    local okty, typ = pcall(function() return engine.Target:getType(tg) end)
    if okty and type(typ) == "table" and (typ.ball or 0) >= 2 and (typ.range or 0) >= 6 then
      ballTid, radius, trange = tid, typ.ball, typ.range
    end
  end
end
if ballTid and not p:knowTalent(ballTid) then
  local okl = pcall(function() p:learnTalent(ballTid, true, 1) end)
  if okl then learned = true else ballTid = nil end
end
if not ballTid then
  for _, q in ipairs(pacified) do q[1].faction = q[2] end
  say("setup", "no activated ball talent with radius>=2 and range>=6 in this module")
  return table.concat(r, "  ||  ")
end
say("talent", ballTid)
say("radius", radius)
say("range", trange)

-- The geometry. NEAR at 4, the FAR pair at 8 and adjacent -- so the pair is
-- more than `radius` from NEAR and a ball on NEAR cannot reach them.
local spawned = {}
local function put(x, y, name)
  local m = game.zone:makeEntity(game.level, "actor",
    { special = function(e) return not e.unique and (e.rank or 1) <= 2 end }, nil, true)
  if not m then return nil end
  game.zone:addEntity(game.level, m, "actor", x, y)
  m.faction = "enemies"
  m.name = name
  m.energy = m.energy or {} ; m.energy.mod = 0 ; m.energy.value = 0
  spawned[#spawned+1] = m
  return m
end

-- Walk outward along a direction that has room for both spots.
local near, far1, far2
for _, d in ipairs(util.adjacentDirs()) do
  if near then break end
  local nx, ny = p.x, p.y
  local ok = true
  for step = 1, 9 do
    nx, ny = util.coordAddDir(nx, ny, d)
    if not standable(nx, ny) then ok = false break end
    if step == 4 then near = { x = nx, y = ny } end
    if step == 8 then far1 = { x = nx, y = ny } end
  end
  if not ok or not far1 then near, far1 = nil, nil
  else
    for _, d2 in ipairs(util.adjacentDirs()) do
      local ax, ay = util.coordAddDir(far1.x, far1.y, d2)
      if not far2 and standable(ax, ay)
         and core.fov.distance(near.x, near.y, ax, ay) > radius then
        far2 = { x = ax, y = ay }
      end
    end
    if not far2 then near, far1 = nil, nil end
  end
end
if not near or not far1 or not far2 then
  for _, q in ipairs(pacified) do q[1].faction = q[2] end
  say("setup", "no straight line with room for a near spot at 4 and a pair at 8")
  return table.concat(r, "  ||  ")
end
say("near_at", near.x .. "," .. near.y)
say("far_at", far1.x .. "," .. far1.y .. "/" .. far2.x .. "," .. far2.y)
say("near_to_far", core.fov.distance(near.x, near.y, far1.x, far1.y))

local mNear = put(near.x, near.y, "aim near dummy")
local mFar1 = put(far1.x, far1.y, "aim far dummy A")
local mFar2 = put(far2.x, far2.y, "aim far dummy B")
p:playerFOV()
if not (mNear and mFar1 and mFar2) then
  for _, m in ipairs(spawned) do game.level:removeEntity(m, true) end
  for _, q in ipairs(pacified) do q[1].faction = q[2] end
  say("setup", "could not draw three actors to place")
  return table.concat(r, "  ||  ")
end

-- The candidate list the rotation would hand over: what spotHostiles sees.
local seen = p:spotHostiles(true)
say("seen", #seen)

------------------------------------------------------------------ B: the choice
local okB, pick = pcall(b.aimPointFor, ballTid, seen)
say("b_ok", okB)
if okB and type(pick) == "table" then
  say("b_at", pick.x .. "," .. pick.y)
  say("b_foes", pick.foes)
  say("b_is_far", (pick.x == far1.x and pick.y == far1.y) or (pick.x == far2.x and pick.y == far2.y))
  say("b_is_near", pick.x == near.x and pick.y == near.y)
  say("b_has_actor", pick.actor ~= nil)
else
  say("b_at", "nil")
end

------------------------------------------------------- C: a non-area talent
local okC, plain = pcall(b.aimPointFor, "T_ATTACK", seen)
say("c_ok", okC)
say("c_nil", plain == nil)

------------------------------------------------------------------------ restore
for _, m in ipairs(spawned) do
  if m and not m.dead then game.level:removeEntity(m, true) end
end
if learned then pcall(function() p:unlearnTalent(ballTid) end) end
for _, q in ipairs(pacified) do q[1].faction = q[2] end
if p.x ~= startx or p.y ~= starty then p:move(startx, starty, true) end
p:playerFOV()
say("restored_pos", (p.x == startx and p.y == starty))
say("restored_level", (game.level == startlevel))
say("restored_talent", (not learned) or (not p:knowTalent(ballTid)))
say("restored_hostiles", #p:spotHostiles(true))

return table.concat(r, "  ||  ")
'@

    Write-Host "  raw: $($out.Result)"
    if ($out.Tainted) { Write-Host '[aim] TAINTED'; exit 2 }

    $kv = @{}
    foreach ($pair in ($out.Result -split '\s+\|\|\s+')) {
        $i = $pair.IndexOf('='); if ($i -gt 0) { $kv[$pair.Substring(0, $i)] = $pair.Substring($i + 1) }
    }
    if ($kv.ContainsKey('setup')) { Write-Host "[aim] INCONCLUSIVE - $($kv['setup'])"; exit 3 }

    Write-Host ''
    Write-Host "  measured  talent $($kv['talent']) radius $($kv['radius']) range $($kv['range'])"
    Write-Host "  measured  near $($kv['near_at']), far pair $($kv['far_at']), apart by $($kv['near_to_far'])"
    Write-Host "  measured  aim point $($kv['b_at']) catching $($kv['b_foes'])"
    Write-Host ''

    # PROVES THE SITUATION WAS BUILT -- without these the probe could pass
    # having scored one candidate against nothing.
    $null = Require-Staged -Tag 'aim' -Ok ([int]$kv['seen'] -ge 3) -Detail $out.Result `
        -What 'three hostiles are in view to choose between'
    $null = Require-Staged -Tag 'aim' -Ok ([int]$kv['near_to_far'] -gt [int]$kv['radius']) -Detail $out.Result `
        -What 'the far pair is further from the near one than the blast radius'

    # B. The issue's own example: the pick is the near one, the right answer is
    # the cluster, and the search is the only thing that can tell them apart.
    Check ($kv['b_ok'] -eq 'True') 'aimPointFor returned without raising'
    Check ($kv['b_at'] -ne 'nil') 'it found an aim point for a ball talent'
    Check ($kv['b_is_far'] -eq 'True') 'and it is the far cluster, not the nearest enemy'
    Check ($kv['b_is_near'] -ne 'True') 'the nearest enemy was NOT chosen'
    Check ([int]$kv['b_foes'] -ge 2) "the chosen grid catches both of the pair (caught $($kv['b_foes']))"
    # Option 1 aims at an ACTOR, never at bare coordinates: a talent that reads
    # its target refuses under force_target's __no_self.
    Check ($kv['b_has_actor'] -eq 'True') 'the candidate carries its actor, so the talent is aimed at an actor'

    # C. Everything that is not an area talent must take exactly the path it
    # took before -- that is what keeps the blast radius of this change small.
    Check ($kv['c_ok'] -eq 'True') 'a non-area talent does not raise'
    Check ($kv['c_nil'] -eq 'True') 'and returns nil, so the rotation fires at its own pick'

    Check ($kv['restored_pos'] -eq 'true') 'the character was put back'
    Check ($kv['restored_level'] -eq 'true') 'the level was not changed'
    Check ($kv['restored_talent'] -eq 'true') 'the borrowed talent was unlearned'
    Check ($kv['restored_hostiles'] -eq '0') 'the spawned actors were removed and the factions restored'

    if ($script:Fail.Count -gt 0) { Write-Host "[aim] FAILED - $($script:Fail.Count) check(s)"; exit 1 }
    Write-Host '[aim] PASS'
    exit 0
} catch {
    Write-Host "[aim] ERROR $_"
    exit 3
} finally {
    Stop-Game | Out-Null
}
