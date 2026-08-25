<#
    T-010 regression (#5): a Combat talent the game refuses falls through to
    the next priority instead of stalling the rotation.

    The complaint (original #49, PROJECT-HISTORY ledger row 1): an Archer with
    Headshot first in the rotation got stuck and never reached lower
    priorities, because Headshot only fires at a marked target and v1's
    SAI_useTalent passed the target but never no_confirm (old #49). The fix
    in src/superload/mod/class/Player.lua ("FIXED (T-010)") passes
    no_confirm and a forced target, so such a talent refuses cleanly: its
    action returns nil, so useTalent returns false, SAI_useTalent marks it
    failed for this iteration (#76 -- it was a postUseTalent wrapper before),
    and filterFailedTalents drops it so the next priority is tried.

    This is the scenario #4 deferred "to a class with a suitable targeted
    talent and real (non-query) combat". Query mode cannot show it -- in query
    mode no talent is used, so nothing can be refused -- and the fixture is a
    Berserker (tools/new-character.ps1 -Class Berserker), a melee class with
    no marked-target talent of its own, so the conditional talent is learnt
    here explicitly and is known to be the only one.

    The conditional talent is Rockswallow (T_ROCKSWALLOW, wild-gift/earthen-
    vines 4, data/talents/gifts/earthen-vines.lua): requires_target, range
    20, and its action returns nil unless the target carries EFF_STONE_VINE.
    Nothing in its pre-use depends on equipment or class, so the bot's own
    availability filter (preUseTalent, canProject) lets it through and the
    refusal happens where T-010's did: inside useTalent, at the target. The
    plain attack after it is the innate Attack (T_ATTACK), which every actor
    knows and which cannot be refused against an adjacent hostile. Headshot
    itself is not used because its pre-use needs a launcher and ammunition
    (archerPreUse), which would make the availability filter, not the
    fallthrough, the thing under test.

    What is driven, on the fixture, in real combat:
      1. learn T_ROCKSWALLOW; confirm T_ATTACK is known;
      2. rules: Combat = [Rockswallow, Attack], every other section empty;
      3. the four SCOUTER_* conditions set to IGNORE for the run, so whatever
         the zone spawns reaches the FIGHT branch (put back afterwards);
      4. a quiet spot, one rank<=2 hostile spawned adjacent, playerFOV();
      5. skoobot_reclauded.start() -- one real activation: the first decision
         tries Rockswallow, is refused, and must try Attack in the same
         iteration; the bot is then stopped by the scenario so the fight does
         not continue on its own.

    Asserted: Rockswallow is in the iteration's talentfailed set; two
    SAI_useTalent calls were made; the player's energy was spent (an action
    happened); the bot did not stop with a CANNOT_ACT reason; the engine's
    own "[useTalent] TALENT FAILED: T_ROCKSWALLOW" and the bot's "[Action]
    Using Talent Attack" lines are in the log; and game.turn advanced by at
    least one turn (10 ticks) once the engine ran the action.

    The save is never written: the learnt talent and the rules live only in
    this process.

    Exit codes:  0 pass   1 fail   2 tainted   3 inconclusive (no quiet spot,
    nothing to spawn, the talent could not be learnt -- setup, never product)

    Run:
        powershell -ExecutionPolicy Bypass -File .\tools\scenario-t010-marked-target.ps1

    T-010 (#5), T-006 (#4), #27.
#>
[CmdletBinding()]
param(
    [string]$SaveName = 'fixture-berserker',
    [string]$Conditional = 'T_ROCKSWALLOW',
    [string]$Plain = 'T_ATTACK'
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'harness.ps1')

Write-Host ''
Write-Host '[t010] conditional talent falls through to the next priority (#5)'

function Inconclusive($why) {
    Write-Host "[t010] INCONCLUSIVE - $why"
    Stop-Game
    exit 3
}

try {
    $g = Load-Save -Name $SaveName
    if (-not $g.Ready) { Write-Host "[t010] FAILED - could not load '$SaveName' ($($g.Reason))"; exit 1 }
    $null = Assert-Result ([pscustomobject]@{ Status = 'OK'; Result = $g.Addons; Tainted = $false }) 'the product is loaded' -Match 'skoobot_reclauded'

    $install = Invoke-Bridge -Lua @"
_G.mt = {}
local b = rawget(_G, "skoobot_reclauded")
if not b then return "ERR no skoobot_reclauded runtime table" end
local COND, PLAIN = "$Conditional", "$Plain"
local SCOUTERS = { "SCOUTER_BIGENEMY", "SCOUTER_STRONGERENEMY", "SCOUTER_CROWDPOWER", "SCOUTER_ENEMYCOUNT" }

function mt.hostiles()
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
function mt.onChangeLevel()
  local p = game.player
  return game.level.map:checkEntity(p.x, p.y, engine.Map.TERRAIN, "change_level") ~= nil
end
function mt.reset()
  while #game.dialogs > 0 do game:unregisterDialog(game.dialogs[#game.dialogs]) end
  if b.active then b.stop("test reset") end
end
-- An adjacent grid the spawn can stand on AND be seen from: free to enter,
-- and not sight-blocking, because ToME has terrain that blocks sight without
-- blocking movement and an actor standing in it is not a visible hostile.
-- Returns nil when this spot has no such grid, which is a reason to move on
-- rather than to spawn and hope (#122).
function mt.spawnGrid()
  local p = game.player
  for _, c in pairs(util.adjacentCoords(p.x, p.y)) do
    local x, y = c[1], c[2]
    if game.level.map:isBound(x, y) and not game.level.map:checkAllEntities(x, y, "block_move")
       and not game.level.map(x, y, engine.Map.ACTOR) and not game.level.map:opaque(x, y) then
      return x, y
    end
  end
  return nil
end
-- Quiet: nothing in sight, not a level-change tile (the explore branch hands
-- back there before anything else), and somewhere beside us the probe's actor
-- can be both placed and seen.
function mt.quietHere()
  local x = mt.spawnGrid()
  return mt.hostiles() == 0 and not mt.onChangeLevel() and x ~= nil
end
function mt.findQuiet()
  local p = game.player
  for i = 1, 80 do
    if mt.quietHere() then return true end
    p:teleportRandom(p.x, p.y, 60, 10)
  end
  return mt.quietHere()
end

-- 1, 2, 3: the talents, the rules, the scouters.
function mt.setup()
  local p = game.player
  local t = p:getTalentFromId(COND)
  if not t then return "SETUP no talent " .. COND end
  if not p:knowTalent(COND) then p:learnTalent(COND, true, 1) end
  if not p:knowTalent(COND) then return "SETUP could not learn " .. COND end
  if not p:knowTalent(PLAIN) then return "SETUP " .. PLAIN .. " is not known" end
  local r = b.rules.get(p)
  for _, s in ipairs(b.rules.module.SECTIONS) do
    local list = r[s]
    for i = #list, 1, -1 do list[i] = nil end
  end
  b.rules.module.place(r, {tid = COND}, "Combat")
  b.rules.module.place(r, {tid = PLAIN}, "Combat")
  local tids = b.rules.tids(p, "Combat")
  _G.__mt_scouters = {}
  for _, code in ipairs(SCOUTERS) do
    _G.__mt_scouters[code] = b.conditions.get(code).stoptype
    b.conditions.set(code, "IGNORE")
  end
  return ("OK cond=%s (%s) plain=%s combat=%s"):format(COND, t.name, PLAIN, table.concat(tids, ","))
end

-- 4: one hostile next to us.
--
-- The draw is retried, because it is a draw: makeEntity's filter constrains
-- rank and uniqueness, not faction or visibility, so a single attempt can
-- hand back an actor the player does not react to as an enemy or cannot see,
-- and one attempt is what made this scenario flake between identical runs
-- (#122). Counted as a difference, not as a presence: a wanderer arriving
-- between findQuiet and here would otherwise be mistaken for the spawn.
function mt.spawn()
  local p = game.player
  local sx, sy = mt.spawnGrid()
  if not sx then mt.unspawn() return "SETUP no free adjacent tile the spawn could be seen on" end
  local tried = 0
  for _ = 1, 8 do
    local m = game.zone:makeEntity(game.level, "actor",
      { special = function(e) return not e.unique and (e.rank or 1) <= 2 end }, nil, true)
    if not m then break end
    tried = tried + 1
    local before = mt.hostiles()
    game.zone:addEntity(game.level, m, "actor", sx, sy)
    p:playerFOV()
    local n = mt.hostiles()
    if n == before + 1 then
      _G.__mt_spawned = m
      return ("OK spawned=%s rank=%s hostiles=%d draws=%d"):format(
        tostring(m.name), tostring(m.rank), n, tried)
    end
    game.level:removeEntity(m, true)
  end
  mt.unspawn()
  return ("SETUP no drawn actor was a visible hostile after %d draws"):format(tried)
end
function mt.unspawn()
  local m = _G.__mt_spawned
  if m and m.x and not m.dead then game.level:removeEntity(m, true) end
  _G.__mt_spawned = nil
  for code, stoptype in pairs(_G.__mt_scouters or {}) do b.conditions.set(code, stoptype) end
  _G.__mt_scouters = nil
  if game.player.x then game.player:playerFOV() end
  return "removed"
end

-- 5: one real activation, then stop. Everything read here is read in the
-- same frame as the decision, before the engine ticks.
function mt.drive()
  local p = game.player
  mt.reset()
  local m = _G.__mt_spawned
  local e0, t0, a0 = p.energy.value, game.turn, b.actions
  b.start()
  local failed = b.loop and b.loop.talentfailed and b.loop.talentfailed[COND] == true
  local out = ("active=%s reason=%s actions=%d refused=%s energy=%d->%d turn=%d target=%s alive=%s"):format(
    tostring(b.active), tostring(b.last_reason), b.actions - a0, tostring(failed),
    e0, p.energy.value, t0, tostring(m and m.name), tostring(m and not m.dead))
  if b.active then b.stop("measured") end
  return out
end
return "installed " .. COND .. " " .. PLAIN
"@ -TimeoutSec 30
    if (-not (Assert-Result $install 'helpers installed' -Match '^installed')) { Stop-Game; exit 1 }

    $setup = Invoke-Bridge -Lua 'return mt.setup()' -TimeoutSec 60
    Write-Host "  $($setup.Result)"
    if ($setup.Status -ne 'OK') { Write-Host "[t010] FAILED - setup: $($setup.Status)"; Stop-Game; exit 1 }
    if ($setup.Result -match '^SETUP') { Inconclusive $setup.Result }
    $null = Assert-Result $setup 'Combat rules are [conditional, plain] in that order' -Match "combat=$Conditional,$Plain"

    $quiet = Invoke-Bridge -Lua 'return tostring(mt.findQuiet())' -TimeoutSec 120
    if ($quiet.Result -ne 'True') { Inconclusive 'no spot with nothing in sight AND a visible free tile beside it' }

    $spawn = Invoke-Bridge -Lua 'return mt.spawn()' -TimeoutSec 60
    Write-Host "  $($spawn.Result)"
    if ($spawn.Status -ne 'OK') { Write-Host "[t010] FAILED - spawn: $($spawn.Status)"; Stop-Game; exit 1 }
    if ($spawn.Result -match '^SETUP') { Inconclusive $spawn.Result }

    Write-Host ''
    Write-Host '  --- one real activation with the conditional talent first'
    $drive = $null
    $turns = Assert-Turns -What 'the action was taken: game.turn advanced once the engine ran it' -AtLeast 10 -Block {
        $script:drive = Invoke-Bridge -Lua 'return mt.drive()' -TimeoutSec 60
        Write-Host "  $($script:drive.Result)"
        # The action spends energy in the decision frame; the ticks that turn
        # it into game time run after the command returns.
        Start-Sleep -Seconds 3
    }
    $drive = $script:drive
    if (-not (Assert-Result $drive 'the activation ran')) { Stop-Game; exit 1 }
    $null = Assert-Result $drive "$Conditional was refused and marked failed for the iteration" -Match 'refused=True'
    $null = Assert-Result $drive 'two talent uses were attempted in one iteration (the refusal fell through)' -Match 'actions=2'
    $null = Assert-Result $drive 'energy was spent: the second talent actually fired' -Match 'energy=(\d+)->(\d+)'
    if ($drive.Result -match 'energy=(\d+)->(\d+)') {
        $e0 = [int]$Matches[1]; $e1 = [int]$Matches[2]
        $null = Assert-Result ([pscustomobject]@{ Status = $(if ($e1 -lt $e0) { 'OK' } else { 'ERR' }); Result = "$e0 -> $e1"; Tainted = $false }) "energy after < energy before ($e0 -> $e1)"
    }
    $null = Assert-Result $drive 'the bot did not stop with a CANNOT_ACT reason' -Match '^(?!.*reason=Cannot act)'

    $log = Get-GameLogLines
    $refusedLine = @($log | Where-Object { $_ -match "TALENT FAILED:\s+$Conditional\b" })
    $firedLine   = @($log | Where-Object { $_ -match '\[SKOOBOT\] \[Action\] Using Talent Attack on target' })
    $condLine    = @($log | Where-Object { $_ -match '\[SKOOBOT\] \[Action\] Using Talent Rockswallow on target' })
    $null = Assert-Result ([pscustomobject]@{ Status = $(if ($condLine.Count -gt 0) { 'OK' } else { 'ERR' }); Result = "$($condLine.Count) line(s)"; Tainted = $false }) 'the log shows the bot trying the conditional talent first'
    $null = Assert-Result ([pscustomobject]@{ Status = $(if ($refusedLine.Count -gt 0) { 'OK' } else { 'ERR' }); Result = "$($refusedLine.Count) line(s)"; Tainted = $false }) "the engine logged the refusal ([useTalent] TALENT FAILED: $Conditional)"
    $null = Assert-Result ([pscustomobject]@{ Status = $(if ($firedLine.Count -gt 0) { 'OK' } else { 'ERR' }); Result = "$($firedLine.Count) line(s)"; Tainted = $false }) 'the log shows the bot firing Attack in the same iteration'
    foreach ($l in @($condLine + $refusedLine + $firedLine | Select-Object -First 4)) { Write-Host "         $l" }

    $null = Invoke-Bridge -Lua 'mt.reset() return mt.unspawn()' -TimeoutSec 30
}
finally {
    Stop-Game
}

Write-Host ''
if ($script:HarnessTainted) { Write-Host '[t010] TAINTED - void, re-run.'; exit 2 }
if ($script:HarnessFailures.Count -gt 0) {
    Write-Host "[t010] FAILED - $($script:HarnessFailures.Count) check(s):"
    foreach ($f in $script:HarnessFailures) { Write-Host "                 $f" }
    exit 1
}
Write-Host '[t010] PASS - the refused talent fell through to the next priority; the rotation did not stall'
exit 0
