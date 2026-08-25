<#
    #121: what the engine's auto-explore does with the stairs.

    The comment behind #103 claimed exits are collected and never targeted, so
    a refusal could only mean "nothing reachable left". That was read from
    engine/interface/PlayerExplore.lua, which the game does not run -- the
    module's own copy is what mod.class.Player requires, and it targets exits
    explicitly, in a fixed precedence, after everything else is exhausted.

    This measures the behaviour rather than arguing about it, because two open
    issues rest on the answer: #86 ("head for the down stairs once a level is
    explored") may be most of the way done already, and #103's stop text names
    the stairs on the assumption the player has to walk there themselves.

    Rather than explore a real level to exhaustion, which takes hundreds of
    turns and would be slow and flaky, the exhausted state is BUILT: every
    grid marked seen, every object marked walked-over, every special tile
    marked ignored. That leaves exits as the only thing left to want, which is
    exactly the state the question is about. Everything is put back afterwards.

    A  the level is exhausted and the player is NOT on an exit
       -> auto-explore targets an EXIT and keeps running
    B  the same, with the player standing ON the down stairs
       -> it still has the OTHER exit to go to, so it keeps running
    C  the bot's own decision in state B
    D  the same again, with every other exit stripped of its change_level, so
       the only way out of a finished level is the grid underfoot
       -> auto-explore refuses, which is #103's real trigger

    D is the case the owner reported: the flood fill collects exits from the
    grids it walks INTO, never from the one the player already occupies, so the
    exit underfoot is not a target. With a second exit on the map (B) there is
    still somewhere to go; with none (D) there is nothing left at all.

    D also closes the gap #103's own closing comment named: its regression in
    scenario-stop-notices stubs autoExplore to return false, so the message is
    covered but the engine condition that produces it is not. This produces it.

    A and D are asserted. B and C are measured and printed: asserting a value
    nobody has observed yet would only pin today's guess.

    Exit codes:  0 pass   1 fail   2 tainted   3 inconclusive

    Run:
        powershell -ExecutionPolicy Bypass -File .\tools\scenario-explore-exits.ps1

    #121, and it informs #86 and #103.
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
Write-Host '[explore-exits] does auto-explore target the stairs by itself? (#121)'

try {
    $g = Load-Save -Name $SaveName
    if (-not $g.Ready) { Write-Host "[explore-exits] FAILED - could not load '$SaveName' ($($g.Reason))"; exit 1 }
    Check ($g.Addons -match 'skoobot_reclauded') 'the product is loaded'

    $out = Invoke-Bridge -Lua @'
local p = game.player
local bot = skoobot_reclauded
local map = game.level.map
local r = {}
local function say(k, v) r[#r+1] = k .. "=" .. tostring(v) end

local startx, starty, startlevel = p.x, p.y, game.level

-- Every level-change grid on the map, split the way autoExplore's precedence
-- splits them: down first, then a zone change, then up.
local down, zone, up = {}, {}, {}
for x = 0, map.w - 1 do
  for y = 0, map.h - 1 do
    local t = map(x, y, map.TERRAIN)
    if t and t.change_level then
      if t.change_zone then zone[#zone+1] = {x, y}
      elseif t.change_level > 0 then down[#down+1] = {x, y}
      else up[#up+1] = {x, y} end
    end
  end
end
say("exits_down", #down)
say("exits_zone", #zone)
say("exits_up", #up)
if #down + #zone + #up == 0 then
  say("setup", "this level has no level-change grid at all")
  return table.concat(r, "  ||  ")
end

-- Build the exhausted state, remembering exactly what we touch.
local seen_added, obj_added, special_added = {}, {}, {}
for x = 0, map.w - 1 do
  for y = 0, map.h - 1 do
    local k = x + y * map.w
    if not map.has_seens[k] then
      map.has_seens[k] = true
      seen_added[#seen_added+1] = k
    end
    if map:getObject(x, y, 1) and not map.attrs(x, y, "obj_seen") then
      map.attrs(x, y, "obj_seen", true)
      obj_added[#obj_added+1] = {x, y}
    end
    local t = map(x, y, map.TERRAIN)
    if t and t.special and not map.attrs(x, y, "autoexplore_ignore") then
      map.attrs(x, y, "autoexplore_ignore", true)
      special_added[#special_added+1] = {x, y}
    end
  end
end
say("marked_seen", #seen_added)
say("marked_objects", #obj_added)
say("marked_special", #special_added)

local function restore()
  for _, k in ipairs(seen_added) do map.has_seens[k] = nil end
  for _, c in ipairs(obj_added) do map.attrs(c[1], c[2], "obj_seen", nil) end
  for _, c in ipairs(special_added) do map.attrs(c[1], c[2], "autoexplore_ignore", nil) end
  if game.level == startlevel and (p.x ~= startx or p.y ~= starty) then p:move(startx, starty, true) end
  p:runStop()
  map:redisplay()
end

-- PROBE A: exhausted, and the player is not standing on an exit. The harness
-- save begins on the level entrance, which IS one, so step off it first --
-- otherwise this measures "what does it do from an exit", which is probe B.
local isExit = {}
for _, list in ipairs({down, zone, up}) do
  for _, c in ipairs(list) do isExit[c[1] .. "," .. c[2]] = true end
end
if isExit[p.x .. "," .. p.y] then
  local moved = false
  for radius = 1, 8 do
    for _, d in ipairs(util.adjacentDirs()) do
      local cx, cy = p.x, p.y
      for _ = 1, radius do cx, cy = util.coordAddDir(cx, cy, d) end
      if map:isBound(cx, cy) and p:canMove(cx, cy) and not isExit[cx .. "," .. cy] then
        moved = pcall(function() p:move(cx, cy, true) end) and p.x == cx and p.y == cy
        break
      end
    end
    if moved then break end
  end
  if not moved then
    restore()
    say("setup", "could not step off the exit the character starts on")
    return table.concat(r, "  ||  ")
  end
end
say("a_started_on_exit", isExit[p.x .. "," .. p.y] and true or false)
say("a_from", p.x .. "," .. p.y)

-- Stepping anywhere can reveal grids, so re-mark before measuring.
local function markAllSeen()
  for x = 0, map.w - 1 do
    for y = 0, map.h - 1 do
      local k = x + y * map.w
      if not map.has_seens[k] then map.has_seens[k] = true; seen_added[#seen_added+1] = k end
    end
  end
end
markAllSeen()
local okA, retA = pcall(function() return p:autoExplore() end)
say("a_ok", okA)
say("a_returned", retA)
say("a_explore_type", p.running and p.running.explore)
if p.running and p.running.target then
  say("a_target", tostring(p.running.target.x) .. "," .. tostring(p.running.target.y))
end
p:runStop()

-- PROBE B: the same, standing ON a down staircase.
local target = down[1] or zone[1] or up[1]
local movedok = pcall(function() p:move(target[1], target[2], true) end)
say("b_moved", movedok and (p.x == target[1] and p.y == target[2]))
say("b_level_changed", game.level ~= startlevel)
if game.level ~= startlevel then
  say("setup", "stepping onto the exit changed the level; cannot measure or restore")
  return table.concat(r, "  ||  ")
end
markAllSeen()
say("b_on", p.x .. "," .. p.y)
local okB, retB = pcall(function() return p:autoExplore() end)
say("b_ok", okB)
say("b_returned", retB)
say("b_explore_type", p.running and p.running.explore)
if p.running and p.running.target then
  say("b_target", tostring(p.running.target.x) .. "," .. tostring(p.running.target.y))
end
p:runStop()

-- PROBE C: what the BOT says in state B -- the real text of #103's stop.
local d = bot.data(p)
local savedRules = d.autotalents
d.autotalents = { Combat = { { tid = "T_ATTACK" } }, DamagePrevention = {}, Recovery = {}, Sustain = {} }
local before = game.turn
local okC = pcall(function() bot.query() end)
d.autotalents = savedRules
say("c_ok", okC)
say("c_turn_moved", game.turn ~= before)
say("c_reason", bot.last_reason)

-- PROBE D: #103's actual trigger, built rather than waited for.
--
-- B returned true because this level has two exits and the player was standing
-- on only one of them. The flood fill collects exits from the grids it walks
-- INTO, never from the one the player already occupies, so the exit underfoot
-- is not a target -- with a second exit on the map there is still somewhere to
-- go. The owner's repro is the single-exit case: stand on the only way out of
-- a finished level and there is nothing left at all.
--
-- So: strip change_level from every OTHER exit, leaving exactly one, underfoot.
-- Cloned terrain, restored afterwards, as with any zone.
local stripped = {}
for _, list in ipairs({down, zone, up}) do
  for _, c in ipairs(list) do
    if not (c[1] == p.x and c[2] == p.y) then
      local old = map(c[1], c[2], map.TERRAIN)
      local flat = old:cloneFull()
      flat.change_level = nil
      flat.change_zone = nil
      map(c[1], c[2], map.TERRAIN, flat)
      stripped[#stripped+1] = { c[1], c[2], old }
    end
  end
end
say("d_stripped", #stripped)
map:redisplay()
markAllSeen()
local okD, retD = pcall(function() return p:autoExplore() end)
say("d_ok", okD)
say("d_returned", retD)
p:runStop()

-- A REAL decision, not bot.query(). Query mode returns from the explore branch
-- before autoExplore is ever consulted ("AI would begin exploring"), so a
-- query-based probe reports no stop at all -- which is what probes C and D's
-- own query measurement above shows, and is #103's still-open remainder.
-- A hostile in view sends the decision to FIGHT and the explore branch never
-- runs, so the probe would report on the wrong branch entirely.
local insp = bot.inspect()
say("d_hostiles_before", tonumber(tostring(insp):match("hostiles=(%d+)")) or 0)

-- Anything hostile in view sends the decision to FIGHT and the explore branch
-- never runs. Rather than abandon the probe, put every hostile on the player's
-- own faction for the length of it and put them back afterwards -- lighter than
-- removing and re-adding actors, and it leaves the level otherwise untouched.
local pacified = {}
for _, e in pairs(game.level.entities or {}) do
  if e ~= p and e.faction and e.x and p.reactionToward and p:reactionToward(e) < 0 then
    pacified[#pacified+1] = { e, e.faction }
    e.faction = p.faction
  end
end
say("d_pacified", #pacified)
local insp2 = bot.inspect()
say("d_hostiles", tonumber(tostring(insp2):match("hostiles=(%d+)")) or 0)
d.autotalents = { Combat = { { tid = "T_ATTACK" } }, DamagePrevention = {}, Recovery = {}, Sustain = {} }
-- Start in EXPLORE, as scenario-stop-notices does. From REST the first decision
-- rests instead and the explore branch is never reached, which is what the
-- first run of this probe measured: the bot simply stayed active.
local savedLife = p.life
p.life = p.max_life
bot.active = false; bot.do_nothing = false; bot.state = 11; bot.last_reason = nil
bot.activation = nil; bot.loop = nil; bot.prevloop = nil
local beforeD = game.turn
local okD2 = pcall(function() bot.start() end)
say("d_active_after", bot.active)
say("d_reason", bot.last_reason)
if bot.active then bot.stop("probe done") end
p.life = savedLife
d.autotalents = savedRules
say("d_query_ok", okD2)
say("d_dturn", game.turn - beforeD)

for _, f in ipairs(pacified) do f[1].faction = f[2] end
local backok = true
for _, f in ipairs(pacified) do if f[1].faction ~= f[2] then backok = false end end
say("d_factions_restored", backok)

for _, s in ipairs(stripped) do map(s[1], s[2], map.TERRAIN, s[3]) end
map:redisplay()
local putback = true
for _, s in ipairs(stripped) do
  if map(s[1], s[2], map.TERRAIN) ~= s[3] then putback = false end
end
say("d_terrain_restored", putback)

restore()
say("restored_pos", p.x == startx and p.y == starty)
say("restored_level", game.level == startlevel)
return table.concat(r, "  ||  ")
'@

    Write-Host "  raw: $($out.Result)"
    if ($out.Tainted) { Write-Host '[explore-exits] TAINTED'; exit 2 }

    $kv = @{}
    foreach ($pair in ($out.Result -split '\s+\|\|\s+')) {
        $i = $pair.IndexOf('=')
        if ($i -gt 0) { $kv[$pair.Substring(0, $i)] = $pair.Substring($i + 1) }
    }

    if ($kv.ContainsKey('setup')) {
        Write-Host "[explore-exits] INCONCLUSIVE - $($kv['setup'])"
        exit 3
    }
    # PROVES THE SITUATION WAS BUILT. Without this, a level that was already
    # fully explored and had no exits would sail through every check below
    # having tested nothing.
    if ([int]$kv['exits_down'] + [int]$kv['exits_zone'] + [int]$kv['exits_up'] -eq 0) {
        Write-Host '[explore-exits] INCONCLUSIVE - no level-change grid on this level.'
        exit 3
    }
    if ($kv['a_started_on_exit'] -eq 'true') {
        Write-Host '[explore-exits] INCONCLUSIVE - the character began standing on an exit, so probe A is not the case it means to test.'
        exit 3
    }

    Write-Host ''
    Write-Host "  measured  A: autoExplore returned $($kv['a_returned']), explore type '$($kv['a_explore_type'])', target $($kv['a_target'])"
    Write-Host "  measured  B: on the stairs, autoExplore returned $($kv['b_returned']), explore type '$($kv['b_explore_type'])'"
    Write-Host "  measured  C: the bot's reason there was: $($kv['c_reason'])"
    Write-Host ''

    Check ($kv['a_ok'] -eq 'true') 'auto-explore did not error on an exhausted level'
    # The claim #121 settled by reading, now pinned: with nothing else left,
    # the engine's own auto-explore heads for a level change on its own. If
    # this ever fails, #86 is back to needing its own routing.
    Check ($kv['a_returned'] -eq 'true') 'with the level exhausted, auto-explore still has somewhere to go'
    Check ($kv['a_explore_type'] -eq 'exit') "and what it is going to is an exit (was '$($kv['a_explore_type'])')"

    Check ($kv['b_ok'] -eq 'true') 'auto-explore did not error while standing on the stairs'
    Check ($kv['c_ok'] -eq 'true') 'the bot reached a decision there'
    Check ($kv['c_turn_moved'] -ne 'true') 'the query spent no game time'
    # Whatever B does, the bot must not call it an inability -- that is the
    # whole of #103, and it must hold in the state the refusal really happens
    # in rather than the one the old comment assumed.
    if ($kv['b_returned'] -eq 'false') {
        Check ($kv['c_reason'] -notmatch 'Cannot act') "the refusal reads as a hand-back, not a cannot-act (reason: $($kv['c_reason']))"
    }

    # PROBE D is #103's real trigger, and the gap its own closing comment named:
    # the regression in scenario-stop-notices stubs autoExplore to return false,
    # so the message is covered but the engine condition that produces it is not.
    # This produces it.
    if ([int]$kv['d_stripped'] -eq 0) {
        Write-Host '[explore-exits] INCONCLUSIVE - only one exit on this level, so probe D changed nothing and B already covered it.'
        exit 3
    }
    Write-Host "  measured  D: sole exit underfoot, autoExplore returned $($kv['d_returned'])"
    Write-Host "  measured  D: the bot's reason there was: $($kv['d_reason'])"
    Write-Host ''

    Check ($kv['d_ok'] -eq 'true') 'auto-explore did not error with one exit left, underfoot'
    Check ($kv['d_returned'] -eq 'false') 'standing on the ONLY exit of a finished level, auto-explore refuses'
    Check ($kv['d_query_ok'] -eq 'true') 'the bot reached a decision on that refusal'
    Check ($kv['d_reason'] -match 'explored') "it hands back saying the level is explored (reason: $($kv['d_reason']))"
    Check ($kv['d_reason'] -notmatch 'Cannot act') 'and does not claim an inability (#103)'
    Check ($kv['d_terrain_restored'] -eq 'true') 'the stripped exits were put back'
    Check ($kv['d_factions_restored'] -eq 'true') 'the pacified hostiles got their factions back'

    Check ($kv['restored_pos'] -eq 'true') 'the character was put back where it started'
    Check ($kv['restored_level'] -eq 'true') 'the level was not changed'

    if ($script:Fail.Count -gt 0) { Write-Host "[explore-exits] FAILED - $($script:Fail.Count) check(s)"; exit 1 }
    Write-Host '[explore-exits] PASS'
    exit 0
} catch {
    Write-Host "[explore-exits] ERROR $_"
    exit 3
} finally {
    Stop-Game | Out-Null
}
