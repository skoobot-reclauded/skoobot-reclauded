<#
    #133: low life with something in view must try the player's Recovery
    talents before handing the game back.

    The stop is LIFE_LOWLIFE, a STOP evaluated at the TURN site -- before the
    state branch -- so the recovery the FIGHT branch would fire at a gentler
    threshold never got a chance. The bot handed back having spent none of its
    options, into a situation neither restarting nor resting could change. The
    first class sweep lost a whole four-minute run to it without the character
    taking one turn (#123).

    What is driven, on the fixture:
      A. a quiet spot, everything else pacified, one hostile adjacent;
      B. a healing infusion in Recovery and life dropped below the threshold:
         the bot USES the infusion and does NOT stop for low life;
      C. the same situation with Recovery empty: it DOES stop, with the
         low-life reason -- the mitigation must not swallow the stop when
         there is nothing to try;
      D. the attempt is bounded: past LOWLIFE_TRIES in one activation the stop
         is let through even with a recovery available, so a heal that cannot
         keep up reports rather than looping.

    Everything hostile except the spawn is put on the player's faction for the
    run and restored (#124's remedy), or the decision goes somewhere else.

    Exit codes:  0 pass  1 fail  2 tainted  3 inconclusive (no quiet spot, no
    healing infusion on the fixture -- setup, never product)

    Run:
        powershell -ExecutionPolicy Bypass -File .\tools\scenario-lowlife.ps1

    #133, #123.
#>
[CmdletBinding()]
param([string]$SaveName = 'fixture-berserker')

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'harness.ps1')

Write-Host ''
Write-Host '[lowlife] low life tries the recovery before handing back (#133)'

function Inconclusive($why) { Write-Host "[lowlife] INCONCLUSIVE - $why"; Stop-Game; exit 3 }
function Probe($lua, $timeout = 60) {
    $r = Invoke-Bridge -Lua $lua -TimeoutSec $timeout
    if ($r.Tainted) { $script:HarnessTainted = $true }
    if ($r.Status -ne 'OK') { Write-Host "  BRIDGE $($r.Status): $($r.Result)" }
    return $r
}
function Ok($cond, $what, $detail = '') {
    $null = Assert-Result ([pscustomobject]@{ Status = $(if ($cond) { 'OK' } else { 'ERR' }); Result = $detail; Tainted = $false }) $what
}

try {
    $g = Load-Save -Name $SaveName
    if (-not $g.Ready) { Write-Host "[lowlife] FAILED - could not load '$SaveName' ($($g.Reason))"; exit 1 }
    $null = Assert-Result ([pscustomobject]@{ Status = 'OK'; Result = $g.Addons; Tainted = $false }) 'the product is loaded' -Match 'skoobot_reclauded'

    $install = Probe @'
_G.ll = {}
local b = rawget(_G, "skoobot_reclauded")
if not b then return "ERR no runtime table" end
ll.b = b

function ll.pacify()
  local p = game.player
  ll.pacified = {}
  for _, e in pairs(game.level.entities or {}) do
    if e ~= p and e.faction and e.x and p.reactionToward and p:reactionToward(e) < 0 then
      ll.pacified[#ll.pacified+1] = { e, e.faction }
      e.faction = p.faction
    end
  end
  if p.x then p:playerFOV() end
  return #ll.pacified
end
function ll.unpacify()
  for _, f in ipairs(ll.pacified or {}) do f[1].faction = f[2] end
  ll.pacified = nil
  if game.player.x then game.player:playerFOV() end
  return "restored"
end
function ll.reset()
  while #game.dialogs > 0 do game:unregisterDialog(game.dialogs[#game.dialogs]) end
  if ll.b.active then ll.b.stop("test reset") end
  ll.b.active = false; ll.b.do_nothing = false; ll.b.last_reason = nil
  ll.b.activation = nil; ll.b.loop = nil; ll.b.prevloop = nil
  game.player.life = game.player.max_life
  return "reset"
end
-- A healing infusion the fixture already carries; Recovery is where the
-- loadout proposal puts them.
function ll.healer()
  local p = game.player
  for tid, _ in pairs(p.talents) do
    local t = p:getTalentFromId(tid)
    if t and t.is_inscription and tostring(tid):find("REGENERATION") then return tid end
  end
  for tid, _ in pairs(p.talents) do
    local t = p:getTalentFromId(tid)
    if t and t.is_inscription and not t.requires_target then return tid end
  end
  return nil
end
-- One hostile adjacent, so ctx.hostiles > 0.
function ll.spawn()
  local p = game.player
  local sx, sy
  for _, c in pairs(util.adjacentCoords(p.x, p.y)) do
    local x, y = c[1], c[2]
    if game.level.map:isBound(x, y) and not game.level.map:checkAllEntities(x, y, "block_move")
       and not game.level.map(x, y, engine.Map.ACTOR) and not game.level.map:opaque(x, y) then sx, sy = x, y break end
  end
  if not sx then return "SETUP no visible free tile beside the player" end
  for _ = 1, 8 do
    local m = game.zone:makeEntity(game.level, "actor",
      { special = function(e) return not e.unique and (e.rank or 1) <= 2 end }, nil, true)
    if not m then break end
    m.energy.mod = 0; m.energy.value = 0
    local before = tonumber(tostring(ll.b.inspect()):match("hostiles=(%d+)")) or 0
    game.zone:addEntity(game.level, m, "actor", sx, sy)
    if (tonumber(tostring(ll.b.inspect()):match("hostiles=(%d+)")) or 0) == before + 1 then
      ll.spawned = m
      return ("OK %s"):format(tostring(m.name))
    end
    game.level:removeEntity(m, true)
  end
  return "SETUP no drawn actor was a visible hostile"
end
function ll.unspawn()
  if ll.spawned and ll.spawned.x and not ll.spawned.dead then game.level:removeEntity(ll.spawned, true) end
  ll.spawned = nil
  if game.player.x then game.player:playerFOV() end
  return "removed"
end
-- Set Recovery to the healer (or empty it), drop life, drive one decision.
function ll.drive(withHealer, tries)
  ll.reset()
  local p = game.player
  local r = ll.b.rules.get(p)
  for _, s in ipairs(ll.b.rules.module.SECTIONS) do
    local l = r[s] for i = #l, 1, -1 do l[i] = nil end
  end
  ll.b.rules.module.place(r, {tid="T_ATTACK"}, "Combat")
  if withHealer then
    local h = ll.healer()
    if not h then return "SETUP no healing infusion on this fixture" end
    ll.b.rules.module.place(r, {tid=h}, "Recovery")
  end
  ll.b.conditions.set("LIFE_LOWLIFE", "STOP")
  -- Below the threshold: a quarter of the pool.
  p.life = math.floor(p.max_life * 0.25)
  ll.b.state = 13
  ll.b.start()
  -- Stage the counter past the bound if asked, then decide again.
  if tries and ll.b.activation then
    ll.b.activation.lowlife = tries
    ll.b.active = false; ll.b.last_reason = nil
    p.life = math.floor(p.max_life * 0.25)
    ll.b.start()
  end
  -- bot.actions is zeroed by start(), so it is read directly and NOT as a
  -- delta against the pre-start value, which comes out negative.
  local out = ("recovery=%s life=%s/%s actions=%d reason=%s"):format(
    tostring(withHealer), tostring(p.life), tostring(p.max_life),
    ll.b.actions, tostring(ll.b.last_reason))
  if ll.b.active then ll.b.stop("measured") end
  p.life = p.max_life
  return out
end
return "installed"
'@ 30
    if (-not (Assert-Result $install 'helpers installed' -Match '^installed')) { Stop-Game; exit 1 }

    Write-Host ''
    Write-Host '  --- A. a hostile in view, everything else pacified'
    $setup = Probe 'll.reset() local n = ll.pacify() local s = ll.spawn() return ("pacified=%d spawn=%s"):format(n, s)' 120
    Write-Host "  $($setup.Result)"
    if ($setup.Result -match 'SETUP') { Inconclusive $setup.Result }
    $null = Assert-Result $setup 'one hostile is in view' -Match 'spawn=OK'

    Write-Host ''
    Write-Host '  --- B. with a recovery available it heals instead of stopping'
    $heal = Probe 'return ll.drive(true)' 120
    Write-Host "  $($heal.Result)"
    if ($heal.Result -match '^SETUP') { Inconclusive $heal.Result }
    $null = Assert-Result $heal 'it did NOT hand back for low life' -Match '^(?!.*below).*$'
    $null = Assert-Result $heal 'an action was taken' -Match 'actions=[1-9]'

    Write-Host ''
    Write-Host '  --- C. with nothing to try, the stop still fires'
    $noheal = Probe 'return ll.drive(false)' 120
    Write-Host "  $($noheal.Result)"
    $null = Assert-Result $noheal 'it stops, naming the life pool' -Match 'below'
    $null = Assert-Result $noheal 'and it is the low-life stop' -Match 'life pool'

    Write-Host ''
    Write-Host '  --- D. the attempt is bounded, so a heal that cannot keep up reports'
    $bound = Probe 'return ll.drive(true, 99)' 120
    Write-Host "  $($bound.Result)"
    $null = Assert-Result $bound 'past the bound the stop is let through' -Match 'below'

    $clean = Probe 'll.unspawn() ll.unpacify() ll.reset() return "clean"'
    Write-Host "  cleanup    $($clean.Result)"
    $errs = @(Get-GameLogLines | Where-Object { $_ -match 'Lua Error' })
    Ok ($errs.Count -eq 0) 'no Lua Error in the run' ($errs -join ' | ')
}
finally { Stop-Game }

Write-Host ''
if ($script:HarnessTainted) { Write-Host '[lowlife] TAINTED - void, re-run.'; exit 2 }
if ($script:HarnessFailures.Count -gt 0) {
    Write-Host "[lowlife] FAILED - $($script:HarnessFailures.Count) check(s):"
    foreach ($f in $script:HarnessFailures) { Write-Host "                  $f" }
    exit 1
}
Write-Host '[lowlife] PASS - it heals when it can, stops when it cannot, and the attempt is bounded'
exit 0
