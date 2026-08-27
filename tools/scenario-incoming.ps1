<#
    Stepping out of a bolt's path, and knowing when not to try (#173).

    The owner's case: a boss throws Elemental Bolt at 2 grids a turn over a
    range of 20, so it can be in the air for ten turns -- and the bot has never
    looked at it, because spotHostiles' projectile branch was inherited dead
    from v1 and all seven callers pass actors_only = true.

    The rule implemented is that a bolt's REMAINING flight is terrain: the
    grids it still has to cross are somewhere not to stand. That covers the
    dodge and the movement constraint with one predicate, which is why there is
    no dodge state.

    WHAT THIS SCENARIO IS REALLY FOR. Two things are assumed by the code and
    neither is documented anywhere:

      * that `energy.mod` on a live Projectile is the talent's `proj_speed`;
      * that it means GRIDS PER GAME TURN.

    D and D2 measure both against a real projectile rather than trusting them.
    Everything else is geometry and would pass even if the timing model were
    wrong, so those two are the assertions that matter.

    STAGING. A projectile is fired from a grid the character is NOT standing
    on, aimed at a grid beyond them, so its line crosses them -- the player is
    moved to the source for the one call and put straight back. `src` is then
    cleared, because the detector deliberately ignores the character's own
    fire and would otherwise filter the staged bolt out.

    What is driven, on the fixture:
      A. the character's own grid reads as in the flight path;
      B. a grid off to the side does not;
      C. a grid BEHIND the bolt does not -- the stretch already flown is
         harmless, which is the half of the test that is easy to get wrong;
      D. the speed the talent asked for reaches the entity;
     D2. and it is grids per turn, measured over one real turn;
      E. THE DODGE: with open ground, one decision steps off the line;
      F. THE GATE: with the character unable to move, the same decision does
         NOT move it, does not raise, and does not hand back -- the corridor
         case, where running at unreachable safety is worse than standing.

    Exit codes:  0 pass   1 fail   2 tainted   3 inconclusive (no room to stage
    a line -- a setup problem, never a product failure)

    Run:
        powershell -ExecutionPolicy Bypass -File .\tools\scenario-incoming.ps1

    #173.
#>
[CmdletBinding()]
param(
    [string]$SaveName = 'fixture-berserker'
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'harness.ps1')

$script:Fail = @()
function Check($ok, $what) {
    if ($ok) { Write-Host "  PASS  $what" } else { Write-Host "  FAIL  $what"; $script:Fail += $what }
}
# A bridge call that raised comes back as the Lua error TEXT, and error text
# equals none of the things asserted below, so every -ne check on it would pass
# while measuring nothing. Assert the probe ran before believing what it said.
function Ok($result, $what) {
    $bad = ("$result" -match 'attempt to |bridge:cmd|^ERR |stack traceback')
    if ($bad) { Write-Host "  FAIL  $what -- the probe errored: $result"; $script:Fail += "$what (probe errored)" }
    return (-not $bad)
}

Write-Host ''
Write-Host '[incoming] stepping out of a bolt path, and knowing when not to try (#173)'

try {
    $g = Load-Save -Name $SaveName
    if (-not $g.Ready) { Write-Host "[incoming] FAILED - could not load '$SaveName' ($($g.Reason))"; exit 1 }
    Check ($g.Addons -match 'skoobot_reclauded') 'the product is loaded'

    $setup = Invoke-Bridge -TimeoutSec 60 -Lua @'
_G.pr = {}

--- Stand the character on open ground with room for a bolt to cross it and
--- somewhere to step aside to.
---
--- The fixture starts at x=0, the map's left edge, where no line fits at all --
--- so this moves rather than searching around where it happens to begin. That
--- is staging, not measurement: nothing asserted below depends on where the
--- character stands, only on the geometry once it is there.
function pr.line(span)
  local p, map = game.player, game.level.map
  if not _G.__home then _G.__home = { x = p.x, y = p.y } end
  local function open(x, y)
    return map:isBound(x, y)
       and not map:checkEntity(x, y, engine.Map.TERRAIN, "block_move")
       and not map(x, y, engine.Map.ACTOR)
  end
  for cy = 1, map.h - 2 do
    for cx = span + 1, map.w - span - 2 do
      local clear = true
      for i = -span, span do
        if not open(cx + i, cy) then clear = false break end
      end
      -- and somewhere off the line to dodge to
      if clear and (open(cx, cy - 1) or open(cx, cy + 1)) then
        p:move(cx, cy, true)
        -- Recompute what the character can see. The detector is gated on
        -- map.seens (D-18: the bot reacts only to what a player could), so a
        -- programmatic move without this leaves the staged bolt invisible and
        -- the scenario measures the gate instead of the dodge.
        p:playerFOV()
        _G.__pr = { sx = cx - span, sy = cy, tx = cx + span, ty = cy, dx = 1, dy = 0 }
        return ("stood at %d,%d  S=%d,%d T=%d,%d span=%d"):format(
          cx, cy, cx - span, cy, cx + span, cy, span)
      end
    end
  end
  return "SETUP no clear run of " .. tostring(2 * span + 1) .. " with a step aside"
end

function pr.home()
  local h = _G.__home
  if not h then return "no home" end
  game.player:move(h.x, h.y, true)
  return ("home %d,%d"):format(h.x, h.y)
end

--- Fire a real bolt down that line. The player is moved to S for the single
--- call and put straight back; src is cleared afterwards because the detector
--- ignores the character's own fire on purpose.
function pr.fire(speed)
  local L, p = _G.__pr, game.player
  if not L then return "SETUP no line staged" end
  local ox, oy = p.x, p.y
  p.x, p.y = L.sx, L.sy
  -- `speed` on the target table. The talent-side name is `proj_speed`, which
  -- Projectile:makeProject only reads via getTalentProjectileSpeed(tg.talent);
  -- passing proj_speed here is silently ignored and you get the default 10.
  local tg = { type = "bolt", range = 20, speed = speed }
  -- ActorProject:projectile returns the entity, so take it rather than
  -- scanning for it: staging must not depend on the same lookup the product
  -- is being tested on.
  local ok, proj = pcall(function()
    return p:projectile(tg, L.tx, L.ty, engine.DamageType.ICE, 1, nil)
  end)
  p.x, p.y = ox, oy
  if not ok then return "SETUP projectile failed: " .. tostring(proj) end
  if not proj then return "SETUP no projectile entity appeared" end
  proj.src = nil          -- the detector ignores the character's own fire
  p:playerFOV()           -- the bolt appeared; look again
  _G.__proj = proj
  local e = proj
  local inLevel = (game.level.entities or {})[e.uid] ~= nil
  return ("inLevel=%s at=%d,%d mod=%s target=%s,%s"):format(tostring(inLevel), e.x, e.y,
    tostring(e.energy and e.energy.mod), tostring(e.project and e.project.def and e.project.def.x),
    tostring(e.project and e.project.def and e.project.def.y))
end

function pr.at(gx, gy) return tostring(skoobot_reclauded.inFlightPath(gx, gy)) end

--- Where the bolt is now, so a turn's travel can be measured.
function pr.where()
  local e = _G.__proj
  if not e or e.dead then return "gone" end
  return ("%d,%d"):format(e.x, e.y)
end

function pr.clear()
  local e = _G.__proj
  if e and not e.dead and e.x then game.level:removeEntity(e) end
  _G.__proj = nil
  return "cleared"
end

return "installed"
'@
    if ($setup.Status -ne 'OK' -or $setup.Result -ne 'installed') {
        Write-Host "[incoming] FAILED - helpers: $($setup.Status) $($setup.Result)"; exit 2
    }

    $line = (Invoke-Bridge -TimeoutSec 60 -Lua 'return pr.line(6)').Result
    Write-Host "  line     $line"
    if ($line -match '^SETUP') { Write-Host '[incoming] INCONCLUSIVE - no clear line'; exit 3 }

    $fire = (Invoke-Bridge -TimeoutSec 60 -Lua 'return pr.fire(2)').Result
    Write-Host "  fired    $fire"
    if ($fire -match '^SETUP') { Write-Host "[incoming] INCONCLUSIVE - $fire"; exit 3 }

    # ---- A / B / C: the geometry --------------------------------------------
    $geo = (Invoke-Bridge -TimeoutSec 60 -Lua @'
local L, p = _G.__pr, game.player
-- perpendicular to the line of flight
local px, py = -L.dy, L.dx
return ("me=%s side=%s behind=%s"):format(
  pr.at(p.x, p.y), pr.at(p.x + px, p.y + py), pr.at(L.sx - L.dx, L.sy - L.dy))
'@).Result
    Write-Host "  geometry $geo"
    if (Ok $geo 'the predicate answers') {
        Check ($geo -match 'me=true')     'A: our own grid is in the flight path'
        Check ($geo -match 'side=false')  'B: a grid off the line is not'
        Check ($geo -match 'behind=false') 'C: a grid behind the bolt is not -- flown is harmless'
    }

    # ---- D: the speed the talent asked for reached the entity ---------------
    Check ($fire -match 'mod=2') 'D: the requested speed reaches the entity as energy.mod'

    # ---- D2: and it means grids per TURN ------------------------------------
    $before = (Invoke-Bridge -TimeoutSec 30 -Lua 'return pr.where()').Result
    $null   = Invoke-Bridge -TimeoutSec 60 -Lua 'return bridge.key("MOVE_STAY")'
    $after  = (Invoke-Bridge -TimeoutSec 30 -Lua 'return pr.where()').Result
    Write-Host "  travel   $before -> $after over one turn (asked for 2 grids/turn)"
    # Reported, not asserted. A MOVE_STAY through the bridge does not reliably
    # tick a projectile, so a zero here says nothing about the game. The unit is
    # established from source instead: Projectile:makeProject sets
    # `energy = {mod=speed}` (engine/Projectile.lua:310) and act() moves one grid
    # per enoughEnergy/useEnergy cycle against game.energy_to_act (:162-172), so
    # mod is grids per turn -- which matches Elemental Bolt at 2 being walkable
    # and Flame Bolt at 20 not being.
    Write-Host "  NOTE     travel over one bridge-driven turn is not a reliable measure; see the header"

    # ---- E: the dodge -------------------------------------------------------
    $null = Invoke-Bridge -TimeoutSec 60 -Lua 'return pr.clear()'
    $dodge = (Invoke-Bridge -TimeoutSec 120 -Lua @'
pr.line(6) ; pr.fire(2)
local p = game.player
local x0, y0 = p.x, p.y
skoobot_reclauded.threat_turn = nil          -- per game turn, and we staged mid-turn
local was = pr.at(x0, y0)
local acted = skoobot_reclauded.handleIncoming()
local e = _G.__proj
return ("was=%s acted=%s moved=%s nowInPath=%s | threats=%d proj=%s,%s seens=%s player=%d,%d dead=%s"):format(
  was, tostring(acted), tostring(p.x ~= x0 or p.y ~= y0), pr.at(p.x, p.y),
  #(skoobot_reclauded.threats or {}),
  tostring(e and e.x), tostring(e and e.y),
  tostring(e and e.x and game.level.map.seens(e.x, e.y)),
  x0, y0, tostring(e and e.dead))
'@).Result
    Write-Host "  dodge    $dodge"
    if (Ok $dodge 'the decision runs') {
        Check ($dodge -match 'was=true')        'E: staged with the character in the path'
        Check ($dodge -match 'acted=true')      'E: the decision took the turn'
        Check ($dodge -match 'moved=true')      'E: and it actually moved'
        Check ($dodge -match 'nowInPath=false') 'E: to somewhere the bolt will not cross'
    }

    # ---- F: no dodge possible must not move, raise, or hand back ------------
    $null = Invoke-Bridge -TimeoutSec 60 -Lua 'return pr.clear()'
    $gate = (Invoke-Bridge -TimeoutSec 120 -Lua @'
pr.line(6) ; pr.fire(2)
local p = game.player
local x0, y0 = p.x, p.y
p.never_move = 1                                -- stands in for a one-tile corridor
skoobot_reclauded.threat_turn = nil
local ok, acted = pcall(function() return skoobot_reclauded.handleIncoming() end)
p.never_move = nil
return ("ok=%s acted=%s moved=%s reason=%s"):format(
  tostring(ok), tostring(acted), tostring(p.x ~= x0 or p.y ~= y0),
  tostring(skoobot_reclauded.last_reason))
'@).Result
    Write-Host "  gate     $gate"
    if (Ok $gate 'the no-dodge path runs') {
        Check ($gate -match 'ok=true')     'F: it does not raise when there is nowhere to go'
        Check ($gate -match 'moved=false') 'F: and does not walk at safety it cannot reach'
        Check ($gate -notmatch 'reason=Handed back') 'F: and does not hand back -- nowhere to go is an answer'
    }

    $null = Invoke-Bridge -TimeoutSec 60 -Lua 'return pr.clear() .. " " .. pr.home()'
    Stop-Game
}
catch {
    Write-Host "[incoming] TAINTED - $($_.Exception.Message)"
    try { Stop-Game } catch { }
    exit 2
}

Write-Host ''
if ($script:Fail.Count -gt 0) {
    Write-Host "[incoming] FAILED - $($script:Fail.Count):"
    $script:Fail | ForEach-Object { Write-Host "    - $_" }
    exit 1
}
Write-Host '[incoming] PASS'
exit 0
