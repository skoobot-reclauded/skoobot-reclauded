<#
    T-015 regression: the character drowns while resting underwater.

    The emblematic v1 bug -- TheIronBird lost characters to it, and the guard
    that was meant to prevent it (`not game.player.undead == 1`) was dead code
    for eight years, as was mishander's replacement. The fix runs the bot to
    air whenever the game itself would drain its breath.

    The pure predicate (ToME's own suffocation rule) is unit-tested exhaustively
    in spec/air_spec.lua. This exercises the wiring in a live game: it turns the
    tile under the player into water it cannot breathe (a clone of the current
    floor with an air_level, so it works in any zone and restores cleanly), and
    asserts the bot decides to RUN TO AIR rather than rest into a drowning
    death. A control on the same spot without the water shows it rests normally.

    Driven through query mode: no game.turn passes, the terrain edit is
    reverted immediately, and nothing is left changed in the world.

    Exit codes:  0 pass   1 fail   2 tainted   3 inconclusive

    Run:
        powershell -ExecutionPolicy Bypass -File .\tools\scenario-t015-drowning.ps1

    T-015.
#>
[CmdletBinding()]
param([string]$SaveName = 'harness')

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'harness.ps1')

$script:Fail = @()
$script:Tainted = $false
function Check($ok, $what) {
    if ($ok) { Write-Host "  PASS  $what" } else { Write-Host "  FAIL  $what"; $script:Fail += $what }
}

Write-Host ''
Write-Host '[t015] drowns while resting underwater (TheIronBird)'

try {
    $g = Load-Save -Name $SaveName
    if (-not $g.Ready) { Write-Host "[t015] FAILED - could not load '$SaveName' ($($g.Reason))"; exit 1 }
    Check ($g.Addons -match 'skoobot_reclauded') 'the product is loaded'

    $null = Invoke-Bridge -Lua @'
_G.bl = {}
function bl.hostiles()
  local p = game.player
  if not p or not p.x or not game.level or not game.level.map then return -1 end
  p:playerFOV()
  local n = 0
  core.fov.calc_circle(p.x, p.y, game.level.map.w, game.level.map.h, p.sight or 10,
    function(_, x, y) return game.level.map:opaque(x, y) end,
    function(_, x, y)
      local a = game.level.map(x, y, game.level.map.ACTOR)
      if a and p:reactionToward(a) < 0 and p:canSee(a) and game.level.map.seens(x, y) then n = n + 1 end
    end, nil)
  return n
end
function bl.onChangeLevel()
  local p = game.player
  return game.level.map:checkEntity(p.x, p.y, engine.Map.TERRAIN, "change_level") ~= nil
end
function bl.findQuiet()
  local p = game.player
  for i = 1, 80 do
    if bl.hostiles() == 0 and not bl.onChangeLevel() then return true end
    p:teleportRandom(p.x, p.y, 60, 10)
  end
  return bl.hostiles() == 0 and not bl.onChangeLevel()
end
function bl.lastlog(n)
  local ld = game.uiset and game.uiset.logdisplay
  if not ld or not ld.getLines then return "no logdisplay" end
  local out = {}
  for _, l in ipairs(ld:getLines(n or 4)) do
    local s = l
    if type(l) == "table" then s = l.str or l.msg or l[1] or l end
    if type(s) == "table" and s.toString then s = s:toString() end
    out[#out+1] = (tostring(s):gsub("#[^#]*#", ""))
  end
  return table.concat(out, " || ")
end
-- Run one REST decision in query mode and report what the bot decided, by the
-- action it logged. Clears autotalents so no sustain fires first.
function bl.decideRest()
  local p = game.player
  skoobot_reclauded.stop("reset")
  skoobot_reclauded.data(p).autotalents = {}
  p.life = p.max_life
  local b = skoobot_reclauded
  b.active = false; b.do_nothing = false; b.state = 10; b.last_reason = nil  -- 10 = STATE_REST
  local unspent = (p.unused_talents or 0) + (p.unused_generics or 0)
    + (p.unused_talents_types or 0) + (p.unused_stats or 0) + (p.unused_prodigies or 0)
  b.activation = { turnCount = 0, unspentTotal = unspent }
  b.loop = { life = p.max_life, thinkCount = 0, talentfailed = {} }
  b.prevloop = nil
  local before = game.turn
  b.query()
  -- The action THIS decision took is the last "[SkooBot] AI would <verb>" in
  -- the log; earlier lines belong to earlier decisions (the control run leaves
  -- a "would begin resting" that must not be mistaken for this one's choice).
  local action = "none"
  for verb in bl.lastlog(6):gmatch("%[SkooBot%] AI would ([%a]+)") do action = verb end
  return "suffocating=" .. tostring(skoobot_reclauded.suffocating())
    .. " action=" .. action
    .. " reason=" .. tostring(b.last_reason)
    .. " dturn=" .. tostring(game.turn - before)
end
-- Turn the tile under the player into water it cannot breathe (a clone of the
-- current floor plus an air_level), returning a token to restore it.
function bl.floodHere()
  local p, map = game.player, game.level.map
  local old = map(p.x, p.y, engine.Map.TERRAIN)
  local w = old:clone()
  w.air_level = -5
  w.air_condition = "water"
  w.name = (old.name or "floor") .. " (flooded, test)"
  map(p.x, p.y, engine.Map.TERRAIN, w)
  map:updateMap(p.x, p.y)
  _G.__t015_old = old
  return "flooded air_level=" .. tostring(map:checkEntity(p.x, p.y, engine.Map.TERRAIN, "air_level"))
end
function bl.unflood()
  local p, map = game.player, game.level.map
  if _G.__t015_old then map(p.x, p.y, engine.Map.TERRAIN, _G.__t015_old); map:updateMap(p.x, p.y); _G.__t015_old = nil end
  return "restored air_level=" .. tostring(map:checkEntity(p.x, p.y, engine.Map.TERRAIN, "air_level"))
end
return "installed"
'@ -TimeoutSec 30

    if ((Invoke-Bridge -Lua 'return tostring(bl.findQuiet())' -TimeoutSec 120).Result -ne 'True') {
        Write-Host '[t015] INCONCLUSIVE - no quiet, open spot to test from.'; Stop-Game; exit 3
    }

    # Control: dry land -> the bot rests.
    Write-Host ''
    Write-Host '  --- control: on dry land the bot rests'
    $ctrl = Invoke-Bridge -Lua 'return bl.decideRest()' -TimeoutSec 30
    if ($ctrl.Tainted) { $script:Tainted = $true }
    Write-Host "  $($ctrl.Result)"
    Check ($ctrl.Result -match 'suffocating=false') 'control: dry land does not suffocate'
    Check ($ctrl.Result -match 'action=begin') 'control: the bot chooses to rest on dry land'

    # Flood the tile, then decide again: the bot must run to air, not rest.
    Write-Host ''
    Write-Host '  --- underwater: the bot runs to air instead of drowning'
    $flood = Invoke-Bridge -Lua 'return bl.floodHere()' -TimeoutSec 30
    Write-Host "  $($flood.Result)"
    $wet = Invoke-Bridge -Lua 'return bl.decideRest()' -TimeoutSec 30
    if ($wet.Tainted) { $script:Tainted = $true }
    Write-Host "  $($wet.Result)"
    $restore = Invoke-Bridge -Lua 'return bl.unflood()' -TimeoutSec 30
    Write-Host "  $($restore.Result)"

    Check ($flood.Result -match 'air_level=-5') 'the tile is now underwater'
    Check ($wet.Result -match 'suffocating=true') 'the bot sees it is suffocating (ToME''s own rule)'
    # This decision's action must be a move (run to air) -- or, if boxed in, a
    # suffocating handback -- never a rest, which is the drowning death v1
    # walked into. `action` is this decision's own last action, not the control's.
    Check ($wet.Result -notmatch 'action=begin') 'underwater: the bot does NOT rest (v1 drowned here)'
    Check ($wet.Result -match 'action=move' -or $wet.Result -match 'no reachable air') 'underwater: it runs to air (or hands back suffocating)'
    Check ($restore.Result -notmatch 'air_level=-5') 'the terrain was restored after the test'
}
finally {
    $null = Invoke-Bridge -Lua 'return bl.unflood()' -TimeoutSec 15 -ErrorAction SilentlyContinue
    Stop-Game
}

Write-Host ''
if ($script:Tainted) { Write-Host '[t015] TAINTED - void, re-run.'; exit 2 }
if ($script:Fail.Count -gt 0) {
    Write-Host "[t015] FAILED - $($script:Fail.Count) check(s):"
    foreach ($f in $script:Fail) { Write-Host "                 $f" }
    exit 1
}
Write-Host '[t015] PASS - the bot runs to air instead of drowning'
exit 0
