<#
    T-019 regression: a stop-condition list saved before a condition existed
    crashes the bot on explore (owner playtest 2026-08-22).

    The stop-condition list is written to the character the first time it is
    asked for and saved with them. v1 never reconciled it afterwards, and never
    had to: every v1 release shipped the same twelve conditions. The port's
    first added condition (TERRAIN_GLOWING_CHEST, T-013) is looked up on every
    explore decision, so a character created on an earlier build threw

        Player.lua:193: attempt to index a nil value   (checkStop <- skoobot_act)

    the moment the bot was toggled on. The fix reconciles the saved list with
    this version's defaults on every read -- new conditions appear, retired
    ones go, labels refresh, the user's WARN/STOP/IGNORE choices survive -- and
    an unknown code fails closed (behaves as STOP) instead of returning nil.

    This installs exactly such a stale list (the twelve v1 codes, one of them
    customised, plus a code no version defines), then drives one EXPLORE
    decision through query mode -- the same skoobot_act line the crash came
    from, with no game.turn passing -- and asserts the decision completes and
    the list came out reconciled.

    Exit codes:  0 pass   1 fail   2 tainted   3 inconclusive

    Run:
        powershell -ExecutionPolicy Bypass -File .\tools\scenario-t019-stale-conditions.ps1

    T-019.
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
function Probe($lua, $timeout = 30) {
    $r = Invoke-Bridge -Lua $lua -TimeoutSec $timeout
    if ($r.Tainted) { $script:Tainted = $true }
    Write-Host "  $($r.Result)"
    return $r.Result
}

Write-Host ''
Write-Host '[t019] stale stop-condition list must not crash the bot'

try {
    $g = Load-Save -Name $SaveName
    if (-not $g.Ready) { Write-Host "[t019] FAILED - could not load '$SaveName' ($($g.Reason))"; exit 1 }
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
-- A list as a pre-T-013 build would have saved it: the twelve v1 codes, stale
-- labels, LIFE_LOWLIFE customised to IGNORE by the "user", plus one code no
-- version of this addon defines.
function bl.staleList()
  local d = skoobot_reclauded.data(game.player)
  local codes = {"DEBUFF_STUNNED","DEBUFF_CONFUSED","DEBUFF_DAZED","DEBUFF_FROZEN","DEBUFF_ASLEEP",
    "LIFE_BIGLOSS","LIFE_LOWLIFE","DIALOG_LORE","SCOUTER_ENEMYCOUNT","SCOUTER_BIGENEMY",
    "SCOUTER_STRONGERENEMY","SCOUTER_CROWDPOWER"}
  d.stopconditions = {}
  for i, c in ipairs(codes) do d.stopconditions[i] = {label="old " .. c, code=c, stoptype="WARN"} end
  d.stopconditions[7].stoptype = "IGNORE"
  d.stopconditions[#d.stopconditions + 1] = {label="gone", code="RETIRED_CONDITION", stoptype="STOP"}
  return "installed entries=" .. #d.stopconditions .. " chest=no lowlife=IGNORE retired=yes"
end
-- One EXPLORE decision in query mode, with the error caught rather than
-- reaching the engine's dialog; report what happened.
function bl.decideExplore()
  local p = game.player
  skoobot_reclauded.stop("reset")
  skoobot_reclauded.data(p).autotalents = {}
  p.life = p.max_life
  local b = skoobot_reclauded
  b.active = false; b.do_nothing = false; b.state = 11; b.last_reason = nil  -- 11 = STATE_EXPLORE
  b.activation = nil; b.loop = nil; b.prevloop = nil
  local before = game.turn
  local ok, err = pcall(b.query)
  if not ok then return "error=" .. tostring(err) .. " dturn=" .. tostring(game.turn - before) end
  return "ok reason=" .. tostring(b.last_reason) .. " dturn=" .. tostring(game.turn - before)
end
-- What the list looks like after the decision read it.
function bl.describeList()
  local list = skoobot_reclauded.conditions.list()
  local byCode = {}
  for _, v in ipairs(list) do byCode[v.code] = v end
  local chest = byCode.TERRAIN_GLOWING_CHEST
  local low = byCode.LIFE_LOWLIFE
  local stunned = byCode.DEBUFF_STUNNED
  return "entries=" .. #list
    .. " chest=" .. tostring(chest and chest.stoptype)
    .. " lowlife=" .. tostring(low and low.stoptype)
    .. " retired=" .. tostring(byCode.RETIRED_CONDITION ~= nil)
    .. " stunned_label=" .. tostring(stunned and stunned.label)
end
-- An unknown code must fail closed, and setting one must not throw.
function bl.unknownCode()
  local c = skoobot_reclauded.conditions
  local okGet, got = pcall(c.get, "NO_SUCH_CONDITION")
  local okSet = pcall(c.set, "NO_SUCH_CONDITION", "IGNORE")
  return "get_ok=" .. tostring(okGet) .. " stoptype=" .. tostring(okGet and type(got) == "table" and got.stoptype)
    .. " set_ok=" .. tostring(okSet) .. " entries=" .. #c.list()
end
return "installed"
'@ -TimeoutSec 30

    if ((Invoke-Bridge -Lua 'return tostring(bl.findQuiet())' -TimeoutSec 120).Result -ne 'True') {
        Write-Host '[t019] INCONCLUSIVE - no quiet, open spot to test from.'; Stop-Game; exit 3
    }

    Write-Host ''
    Write-Host '  --- a list saved by a build that predates TERRAIN_GLOWING_CHEST'
    $stale = Probe 'return bl.staleList()'
    Check ($stale -match 'entries=13 chest=no') 'stale list installed (12 v1 codes + 1 retired, no chest)'

    Write-Host ''
    Write-Host '  --- one explore decision: must complete, not throw'
    $decide = Probe 'return bl.decideExplore()'
    Check ($decide -match '^ok ') 'the explore decision completes (the crash was Player.lua:193 in checkStop)'
    Check ($decide -match 'dturn=0') 'query advanced no game turn (deterministic)'

    Write-Host ''
    Write-Host '  --- the list came out reconciled'
    $after = Probe 'return bl.describeList()'
    Check ($after -match 'entries=15 ')              'the list has exactly this version''s fifteen conditions'
    Check ($after -match 'chest=WARN')               'the added condition is present with its default'
    Check ($after -match 'lowlife=IGNORE')           'the user''s own setting survived'
    Check ($after -match 'retired=false')            'a retired code was dropped'
    Check ($after -match 'stunned_label=Stunned') 'labels were refreshed'

    Write-Host ''
    Write-Host '  --- an unknown code fails closed'
    $unknown = Probe 'return bl.unknownCode()'
    Check ($unknown -match 'get_ok=true stoptype=STOP') 'get() of an unknown code returns a STOP entry, never nil'
    Check ($unknown -match 'set_ok=true entries=15')  'set() of an unknown code neither throws nor adds'
}
finally {
    Stop-Game
}

Write-Host ''
if ($script:Tainted) { Write-Host '[t019] TAINTED - void, re-run.'; exit 2 }
if ($script:Fail.Count -gt 0) {
    Write-Host "[t019] FAILED - $($script:Fail.Count) check(s):"
    foreach ($f in $script:Fail) { Write-Host "                 $f" }
    exit 1
}
Write-Host '[t019] PASS - a stale saved list is reconciled, and the bot explores'
exit 0
