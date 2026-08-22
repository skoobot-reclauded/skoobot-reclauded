<#
    T-011 regression: stop conditions fire too eagerly on trivial damage.

    lukesilveira: "took damage while exploring" halts the bot on a single
    poison tick. The fix ignores damage while life stays above
    IGNORE_DAMAGE_HEALTH_RATIO, and only hands back once life has actually
    fallen to it.

    Verified by an A/B on the SAME state, changing only the threshold: a
    small loss (10% of max) at 90% life must NOT stop the bot with the default
    0.75 ratio, and MUST stop it once the ratio is raised above the current
    life. Same damage, opposite outcome, so the threshold is provably what
    gates the stop.

    The decision is driven through query mode, which advances no game.turn, so
    the state is exactly what the test sets -- no rest cycle, no wandering
    monster, no flake. The bot table is injected with a fresh EXPLORE
    activation whose previous-life is full, so this iteration's delta is the
    10% loss and nothing else.

    Exit codes:  0 pass   1 fail   2 tainted   3 inconclusive

    Run:
        powershell -ExecutionPolicy Bypass -File .\tools\scenario-t011-trivial-damage.ps1

    T-011.
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
Write-Host '[t011] trivial-damage stop (lukesilveira)'

try {
    $g = Load-Save -Name $SaveName
    if (-not $g.Ready) { Write-Host "[t011] FAILED - could not load '$SaveName' ($($g.Reason))"; exit 1 }
    Check ($g.Addons -match 'skoobot_reclauded') 'the product is loaded'

    $set = Invoke-Bridge -Lua @'
local s = config.settings.tome.skoobot_reclauded
return "IGNORE_DAMAGE_HEALTH_RATIO=" .. tostring(s and s.IGNORE_DAMAGE_HEALTH_RATIO)
'@ -TimeoutSec 30
    Write-Host "  setting $($set.Result)"
    Check ($set.Result -match 'IGNORE_DAMAGE_HEALTH_RATIO=0\.75') 'the new setting exists with its default'

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
return "installed"
'@ -TimeoutSec 30

    if ((Invoke-Bridge -Lua 'return tostring(bl.findQuiet())' -TimeoutSec 120).Result -ne 'True') {
        Write-Host '[t011] INCONCLUSIVE - no quiet, open spot to test from.'; Stop-Game; exit 3
    }

    # Inject an EXPLORE decision that took a 10% loss this iteration (previous
    # life full), at 90% life, on an open tile, and run one query. Returns the
    # reason the bot would hand back, or nothing.
    function Decide-AtRatio($ratio) {
        $r = Invoke-Bridge -Lua @"
local p = game.player
skoobot_reclauded.stop("reset")
p:removeEffect(p.EFF_PINNED, true, true); p:removeEffect(p.EFF_SLEEP, true, true)
config.settings.tome.skoobot_reclauded.IGNORE_DAMAGE_HEALTH_RATIO = $ratio
skoobot_reclauded.data(p).autotalents = {}   -- so activateSustained is a no-op
p.life = p.max_life * 0.90
p:playerFOV()
if bl.hostiles() ~= 0 then return "SETUP a hostile is in view" end
if bl.onChangeLevel() then return "SETUP on a change-level tile" end
local unspent = (p.unused_talents or 0) + (p.unused_generics or 0)
    + (p.unused_talents_types or 0) + (p.unused_stats or 0) + (p.unused_prodigies or 0)
local b = skoobot_reclauded
b.active = false; b.do_nothing = false; b.state = 11; b.last_reason = nil
b.activation = { turnCount = 0, unspentTotal = unspent }
b.loop = { life = p.max_life, thinkCount = 0, talentfailed = {} }  -- prev life full -> delta = -10%
b.prevloop = nil
local before = game.turn
b.query()
return "REASON " .. tostring(b.last_reason) .. " | dturn=" .. tostring(game.turn - before)
"@ -TimeoutSec 30
        if ($r.Status -ne 'OK') { return "SETUP bridge $($r.Status)" }
        if ($r.Tainted) { $script:Tainted = $true }
        Write-Host "  ratio=$ratio -> $($r.Result)"
        return $r.Result
    }

    Write-Host ''
    Write-Host '  --- default 0.75: a 10% scratch at 90% life is ignored'
    $a = Decide-AtRatio '0.75'
    if ($a -match '^SETUP') { Write-Host "[t011] INCONCLUSIVE ($a)"; Stop-Game; exit 3 }
    Check ($a -notmatch 'took damage') 'default ratio: the bot does NOT hand back for a trivial scratch'
    Check ($a -match 'dturn=0') 'query advanced no game turn (deterministic state)'

    Write-Host ''
    Write-Host '  --- 0.95: the same scratch now falls below the threshold and stops'
    $b = Decide-AtRatio '0.95'
    if ($b -match '^SETUP') { Write-Host "[t011] INCONCLUSIVE ($b)"; Stop-Game; exit 3 }
    Check ($b -match 'took damage') 'raised ratio: the same damage now hands back -- the threshold is what gates it'

    # Restore the default so a later run on this save is not surprised.
    $null = Invoke-Bridge -Lua 'config.settings.tome.skoobot_reclauded.IGNORE_DAMAGE_HEALTH_RATIO = 0.75 return "restored"' -TimeoutSec 30
}
finally {
    Stop-Game
}

Write-Host ''
if ($script:Tainted) { Write-Host '[t011] TAINTED - void, re-run.'; exit 2 }
if ($script:Fail.Count -gt 0) {
    Write-Host "[t011] FAILED - $($script:Fail.Count) check(s):"
    foreach ($f in $script:Fail) { Write-Host "                 $f" }
    exit 1
}
Write-Host '[t011] PASS - a scratch is ignored; real damage still hands back'
exit 0
