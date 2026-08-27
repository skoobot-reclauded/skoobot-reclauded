<#
    Heading for a level change that was not refused (#165).

    Doomed spent the last 2,000 turns of sweep 9 walking between the world-map
    exit it is not allowed to take and a level it had already explored. Explore
    targets exits (#121), so refusing one (#151) and stepping off it puts that
    same exit straight back at the top of explore's list, and the pair cycles
    until the clock runs out. It was the only run of 29 to reach `explored=true`
    and it never left norgos-lair:1.

    The fix remembers a refused level change per level and, while any is
    remembered, heads for the nearest one that is not.

    WHY IT TERMINATES, which is the part worth testing rather than asserting:
    the refused set only ever grows, so once every known exit has been turned
    down `seekProgressExit` returns false and explore hands back exactly as it
    did before. Assertion E drives that to exhaustion instead of trusting it.

    STAGING. The fixture starts standing on a level change, so one exit already
    exists. A second is staged by cloning a nearby grid and giving it
    `change_level`, because the search has to have somewhere else to go for C
    and D to mean anything. Both the clone and the level's seen-state are
    restored afterwards.

    What is driven, on the fixture:
      A. with nothing refused, seekProgressExit() declines -- an ordinary run
         is untouched by this code path;
      B. progressExit() finds a level change at all;
      C. THE FIX: after the grid underfoot is refused, progressExit() stops
         returning it and names the other one;
      D. seekProgressExit() takes a real step, and it is towards that other
         exit -- the distance to it falls;
      E. once every known exit is refused it declines again, so the search
         cannot become the new loop.

    Exit codes:  0 pass   1 fail   2 tainted   3 inconclusive (fewer than two
    level changes could be staged -- a setup problem, never a product failure)

    Run:
        powershell -ExecutionPolicy Bypass -File .\tools\scenario-exit.ps1

    #165, and #156 shares the refused-exit memory.
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

Write-Host ''
Write-Host '[exit] heading for a level change that was not refused (#165)'

try {
    $g = Load-Save -Name $SaveName
    if (-not $g.Ready) { Write-Host "[exit] FAILED - could not load '$SaveName' ($($g.Reason))"; exit 1 }
    Check ($g.Addons -match 'skoobot_reclauded') 'the product is loaded'

    $setup = Invoke-Bridge -TimeoutSec 60 -Lua @'
_G.ex = {}

function ex.seeAll()
  local map = game.level.map
  for x = 0, map.w - 1 do for y = 0, map.h - 1 do
    map.has_seens(x, y, true) ; map.remembers(x, y, true)
  end end
  return "seen"
end

--- Every seen level change on the level, as "x,y" strings.
function ex.exits()
  local map, out = game.level.map, {}
  for x = 0, map.w - 1 do for y = 0, map.h - 1 do
    if map.has_seens(x, y) and map:checkEntity(x, y, engine.Map.TERRAIN, "change_level") then
      out[#out+1] = ("%d,%d"):format(x, y)
    end
  end end
  return out
end

--- Stage a second level change, far enough away that a step towards it is
--- measurable. Restored by ex.restore.
function ex.stage()
  local p, map = game.player, game.level.map
  local best, bd
  for x = 1, map.w - 2 do for y = 1, map.h - 2 do
    local t = map(x, y, engine.Map.TERRAIN)
    if t and not t.change_level and not t.does_block_move and p:canMove(x, y) then
      local d = core.fov.distance(p.x, p.y, x, y)
      if d >= 5 and (not bd or d > bd) then best, bd = { x = x, y = y, old = t }, d end
    end
  end end
  if not best then return "SETUP no free grid to stage a second exit" end
  local c = best.old:clone()
  c.name = "staged stairs (test)"
  c.change_level = 1
  map(best.x, best.y, engine.Map.TERRAIN, c) ; map:updateMap(best.x, best.y)
  map.has_seens(best.x, best.y, true) ; map.remembers(best.x, best.y, true)
  _G.__ex = best
  p:playerFOV()
  return ("staged=%d,%d dist=%d player=%d,%d"):format(best.x, best.y, bd, p.x, p.y)
end

function ex.restore()
  local b, map = _G.__ex, game.level.map
  if not b then return "nothing staged" end
  map(b.x, b.y, engine.Map.TERRAIN, b.old) ; map:updateMap(b.x, b.y)
  _G.__ex = nil
  return "restored"
end

function ex.progress()
  local x, y = skoobot_reclauded.progressExit()
  if not x then return "none" end
  return ("%d,%d"):format(x, y)
end

function ex.refusedCount()
  local n = 0
  for _ in pairs(skoobot_reclauded.levelState("refusedexit")) do n = n + 1 end
  return n
end

--- Refuse every level change we know about, by standing the player on each in
--- turn. Drives assertion E to exhaustion rather than assuming it.
function ex.refuseAll()
  local p = game.player
  local ox, oy = p.x, p.y
  for _, g in ipairs(ex.exits()) do
    local x, y = g:match("^(%d+),(%d+)$")
    p.x, p.y = tonumber(x), tonumber(y)
    skoobot_reclauded.markRefusedExit()
  end
  p.x, p.y = ox, oy
  return ("refused=%d"):format(ex.refusedCount())
end

return "installed"
'@
    if ($setup.Status -ne 'OK' -or $setup.Result -ne 'installed') {
        Write-Host "[exit] FAILED - helpers: $($setup.Status) $($setup.Result)"; exit 2
    }

    $null  = Invoke-Bridge -TimeoutSec 60 -Lua 'return ex.seeAll()'
    $stage = Invoke-Bridge -TimeoutSec 60 -Lua 'return ex.stage()'
    Write-Host "  stage    $($stage.Result)"
    if ($stage.Result -match '^SETUP') {
        Write-Host '[exit] INCONCLUSIVE - could not stage a second level change'; exit 3
    }

    $exits = (Invoke-Bridge -TimeoutSec 60 -Lua 'return table.concat(ex.exits(), " ")').Result
    Write-Host "  exits    $exits"
    if (($exits -split ' ').Count -lt 2) {
        Write-Host '[exit] INCONCLUSIVE - fewer than two level changes on this level'; exit 3
    }

    # ---- A: nothing refused, so the path is inert ---------------------------
    $a = (Invoke-Bridge -TimeoutSec 60 -Lua 'return tostring(skoobot_reclauded.seekProgressExit())').Result
    Check ($a -eq 'false') 'A: with nothing refused, the search declines and explore is untouched'

    # ---- B: it can find an exit --------------------------------------------
    $b = (Invoke-Bridge -TimeoutSec 60 -Lua 'return ex.progress()').Result
    Write-Host "  nearest  $b"
    Check ($b -ne 'none') 'B: a level change is found'

    # ---- C: refusing the one underfoot takes it out of the answer ----------
    $here = (Invoke-Bridge -TimeoutSec 60 -Lua @'
local p = game.player
skoobot_reclauded.markRefusedExit()
return ("%d,%d|%s|%d"):format(p.x, p.y, ex.progress(), ex.refusedCount())
'@).Result
    $parts = $here -split '\|'
    Write-Host "  refused  at $($parts[0]); nearest now $($parts[1]); count $($parts[2])"
    Check ($parts[2] -eq '1')            'C: the refusal is remembered'
    Check ($parts[1] -ne $parts[0])      'C: the refused grid is no longer the answer'
    Check ($parts[1] -ne 'none')         'C: another level change is named instead'

    # ---- D: it takes a real step, towards that exit -------------------------
    $d = (Invoke-Bridge -TimeoutSec 120 -Lua @'
local p = game.player
local tx, ty = skoobot_reclauded.progressExit()
if not tx then return "no target" end
local before = core.fov.distance(p.x, p.y, tx, ty)
local x0, y0 = p.x, p.y
local took = skoobot_reclauded.seekProgressExit()
local after = core.fov.distance(p.x, p.y, tx, ty)
return ("took=%s moved=%s before=%d after=%d"):format(
  tostring(took), tostring(p.x ~= x0 or p.y ~= y0), before, after)
'@).Result
    Write-Host "  step     $d"
    Check ($d -match 'took=true')  'D: the search takes a step'
    Check ($d -match 'moved=true') 'D: the character actually moved'
    if ($d -match 'before=(\d+) after=(\d+)') {
        Check ([int]$Matches[2] -lt [int]$Matches[1]) 'D: the step was towards the unrefused exit'
    } else {
        Check $false 'D: distances were reported'
    }

    # ---- E: refusing everything ends the search rather than looping ---------
    $e1 = (Invoke-Bridge -TimeoutSec 60 -Lua 'return ex.refuseAll()').Result
    $e2 = (Invoke-Bridge -TimeoutSec 60 -Lua 'return tostring(skoobot_reclauded.seekProgressExit())').Result
    $e3 = (Invoke-Bridge -TimeoutSec 60 -Lua 'return ex.progress()').Result
    Write-Host "  exhaust  $e1; seek=$e2; nearest=$e3"
    Check ($e3 -eq 'none')  'E: with every exit refused, none is offered'
    Check ($e2 -eq 'false') 'E: the search declines, so it cannot become the new loop'

    $null = Invoke-Bridge -TimeoutSec 60 -Lua 'return ex.restore()'
    Stop-Game
}
catch {
    Write-Host "[exit] TAINTED - $($_.Exception.Message)"
    try { Stop-Game } catch { }
    exit 2
}

Write-Host ''
if ($script:Fail.Count -gt 0) {
    Write-Host "[exit] FAILED - $($script:Fail.Count):"
    $script:Fail | ForEach-Object { Write-Host "    - $_" }
    exit 1
}
Write-Host '[exit] PASS'
exit 0
