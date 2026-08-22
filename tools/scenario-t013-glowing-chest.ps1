<#
    T-013 regression: the bot does not stop for glowing chests (luluch).

    A glowing chest can be guarded, so the user asked the bot to hand back when
    one is in view and let them decide whether to open it. v1 walked straight
    past. The fix adds a WARN stop condition (TERRAIN_GLOWING_CHEST) that fires
    while an unopened glowing chest is visible.

    A glowing chest is a terrain grid with `special = true`, a name containing
    "chest", and `chest_opened` once opened. This clones the tile under the
    player into one (without the real chest's block_move popup, so nothing is
    triggered) and asserts the bot's explore decision hands back for it. A
    control with no chest explores normally. Driven through query mode, so no
    game.turn passes and the terrain edit is reverted immediately.

    This verifies the STOP only. Walking the bot TO a chest is a scored
    objective for T-020, deliberately out of scope (salvage-mishander item 9).

    Exit codes:  0 pass   1 fail   2 tainted   3 inconclusive

    Run:
        powershell -ExecutionPolicy Bypass -File .\tools\scenario-t013-glowing-chest.ps1

    T-013.
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
Write-Host '[t013] stop for glowing chests (luluch)'

try {
    $g = Load-Save -Name $SaveName
    if (-not $g.Ready) { Write-Host "[t013] FAILED - could not load '$SaveName' ($($g.Reason))"; exit 1 }
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
-- One EXPLORE decision in query mode; report why it would hand back, if at all.
function bl.decideExplore()
  local p = game.player
  skoobot_reclauded.stop("reset")
  skoobot_reclauded.data(p).autotalents = {}
  p.life = p.max_life
  local b = skoobot_reclauded
  b.active = false; b.do_nothing = false; b.state = 11; b.last_reason = nil  -- 11 = STATE_EXPLORE
  b.activation = nil; b.loop = nil; b.prevloop = nil
  local before = game.turn
  b.query()
  local action = "none"
  for verb in bl.lastlog(6):gmatch("%[SkooBot%] AI would ([%a]+)") do action = verb end
  return "action=" .. action .. " reason=" .. tostring(b.last_reason) .. " dturn=" .. tostring(game.turn - before)
end
function bl.lastlog(n)
  local ld = game.uiset and game.uiset.logdisplay
  if not ld or not ld.getLines then return "" end
  local out = {}
  for _, l in ipairs(ld:getLines(n or 4)) do
    local s = l
    if type(l) == "table" then s = l.str or l.msg or l[1] or l end
    if type(s) == "table" and s.toString then s = s:toString() end
    out[#out+1] = (tostring(s):gsub("#[^#]*#", ""))
  end
  return table.concat(out, " || ")
end
-- Turn the tile under the player into a glowing chest for detection: a clone
-- of the current terrain flagged special with a chest name. No block_move, so
-- nothing pops. Returns a token; bl.unchest restores.
function bl.chestHere()
  local p, map = game.player, game.level.map
  local old = map(p.x, p.y, engine.Map.TERRAIN)
  local g = old:clone()
  g.special = true
  g.chest_opened = nil
  g.name = "glowing chest (test)"
  map(p.x, p.y, engine.Map.TERRAIN, g)
  map:updateMap(p.x, p.y)
  _G.__t013_old = old
  p:playerFOV()
  return "placed special=" .. tostring(map:checkEntity(p.x, p.y, engine.Map.TERRAIN, "special"))
end
function bl.unchest()
  local p, map = game.player, game.level.map
  if _G.__t013_old then map(p.x, p.y, engine.Map.TERRAIN, _G.__t013_old); map:updateMap(p.x, p.y); _G.__t013_old = nil end
  return "restored"
end
return "installed"
'@ -TimeoutSec 30

    if ((Invoke-Bridge -Lua 'return tostring(bl.findQuiet())' -TimeoutSec 120).Result -ne 'True') {
        Write-Host '[t013] INCONCLUSIVE - no quiet, open spot to test from.'; Stop-Game; exit 3
    }

    # Control: no chest -> the bot explores. This also clears the WARN
    # acknowledgement so the chest case below actually fires.
    Write-Host ''
    Write-Host '  --- control: no chest, the bot explores'
    $ctrl = Invoke-Bridge -Lua 'return bl.decideExplore()' -TimeoutSec 30
    if ($ctrl.Tainted) { $script:Tainted = $true }
    Write-Host "  $($ctrl.Result)"
    Check ($ctrl.Result -notmatch 'glowing chest') 'control: the bot does not stop when there is no chest'

    # Place a glowing chest in view -> the bot hands back.
    Write-Host ''
    Write-Host '  --- glowing chest in view: the bot hands back'
    $place = Invoke-Bridge -Lua 'return bl.chestHere()' -TimeoutSec 30
    Write-Host "  $($place.Result)"
    $chest = Invoke-Bridge -Lua 'return bl.decideExplore()' -TimeoutSec 30
    if ($chest.Tainted) { $script:Tainted = $true }
    Write-Host "  $($chest.Result)"
    $restore = Invoke-Bridge -Lua 'return bl.unchest()' -TimeoutSec 30
    Write-Host "  $($restore.Result)"

    Check ($place.Result -match 'special=true') 'a glowing chest is now in view'
    Check ($chest.Result -match 'glowing chest') 'the bot hands back for the glowing chest (v1 walked past)'
    Check ($chest.Result -match 'dturn=0') 'query advanced no game turn (deterministic)'
}
finally {
    $null = Invoke-Bridge -Lua 'return bl.unchest()' -TimeoutSec 15 -ErrorAction SilentlyContinue
    Stop-Game
}

Write-Host ''
if ($script:Tainted) { Write-Host '[t013] TAINTED - void, re-run.'; exit 2 }
if ($script:Fail.Count -gt 0) {
    Write-Host "[t013] FAILED - $($script:Fail.Count) check(s):"
    foreach ($f in $script:Fail) { Write-Host "                 $f" }
    exit 1
}
Write-Host '[t013] PASS - the bot stops for a glowing chest'
exit 0
