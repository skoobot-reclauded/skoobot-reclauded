<#
    Cleansing a blocking effect (#92), and the recovery pick that #133 got
    wrong.

    The owner watched a character sit frozen on death's door with a wild
    infusion in Recovery that would have broken the ice, while the bot fired a
    regeneration infusion instead -- because tryLowLifeRecovery took
    talents[1], the first row, whatever it was. Then it handed back on
    "cannot act (frozen)" and the harness restarted it into the same state.

    This stages that exact moment. Both infusions are granted, REGENERATION
    FIRST so the first row is the wrong answer, and FROZEN is applied:

      * FROZEN is `type = "physical"`, `status = "detrimental"`, and sets
        `encased_in_ice` and `never_move` (data/timed_effects/physical.lua:733).
      * a wild infusion's CURE counts detrimental effects matching its
        configured `what` (data/talents/misc/inscriptions.lua:143), and the
        racial wild infusion is `what = {physical=true}` -- so it reports the
        freeze.
      * a regeneration infusion's CURE only ever counts cut/poison/disease
        (:93), so it reports zero while frozen. The contrast is the test.

    What is driven, on the fixture:
      A. the setup really took: both infusions known, FROZEN applied, and the
         product's own capability layer sees the character as blocked;
      B. cureValue tells the two apart -- wild > 0, regeneration == 0;
      C. bestRecovery picks the WILD infusion even though regeneration is
         first in the list. This is the #133 bug, directly;
      D. with only regeneration on offer, bestRecovery still returns something
         but values it at zero, so the cleanse declines rather than burning an
         infusion that cannot help;
      E. with nothing on offer at all, it declines without erroring.

    NOT covered here: the talent actually firing and the ice really breaking.
    That needs a live act loop and is the soak's job -- this scenario is about
    the choice, which is where the bug was.

    Exit codes:  0 pass   1 fail   2 tainted   3 inconclusive (setup problem,
    never a product failure)

    Run:
        powershell -ExecutionPolicy Bypass -File .\tools\scenario-cleanse.ps1

    #92, #133.
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
Write-Host '[cleanse] a blocking effect the character can clear (#92, #133)'

try {
    $g = Load-Save -Name $SaveName
    if (-not $g.Ready) { Write-Host "[cleanse] FAILED - could not load '$SaveName' ($($g.Reason))"; exit 1 }
    Check ($g.Addons -match 'skoobot_reclauded') 'the product is loaded'

    # -----------------------------------------------------------------------
    # A. Stage it. Regeneration in slot 1, wild in slot 2 -- the wrong answer
    #    first, which is the ordering the loadout proposal happened to produce
    #    and the reason talents[1] was wrong.
    # -----------------------------------------------------------------------
    $setup = Invoke-Bridge -TimeoutSec 60 -Lua @'
local p = game.player
p:removeEffect(p.EFF_FROZEN, true, true)
p:setInscription(1, "INFUSION:_REGENERATION", {cooldown=10, dur=5, heal=100}, true)
p:setInscription(2, "INFUSION:_WILD", {cooldown=14, what={physical=true}, dur=4, power=14}, true)
_G.ct = {}
for tid in pairs(p.talents or {}) do
  local t = p:getTalentFromId(tid)
  local n = t and tostring(t.name) or ""
  if n:find("Regeneration") then ct.regen = tid end
  if n:find("Wild") then ct.wild = tid end
end
if not ct.regen or not ct.wild then
  return "SETUP missing regen=" .. tostring(ct.regen) .. " wild=" .. tostring(ct.wild)
end
p:setEffect(p.EFF_FROZEN, 10, { hp = 100 })
return ("ok regen=%s wild=%s encased=%s never_move=%s"):format(
  tostring(ct.regen), tostring(ct.wild),
  tostring(p:attr("encased_in_ice")), tostring(p:attr("never_move")))
'@
    Write-Host "  setup: $($setup.Result)"
    if ($setup.Status -ne 'OK' -or $setup.Result -match '^SETUP') {
        Write-Host '[cleanse] INCONCLUSIVE - could not grant both infusions.'
        Stop-Game; exit 3
    }
    Check ($setup.Result -match 'encased=1') 'FROZEN applied: encased_in_ice set'
    Check ($setup.Result -match 'never_move=1') 'FROZEN applied: never_move set'

    $caps = Invoke-Bridge -TimeoutSec 30 -Lua @'
local conds = skoobot_reclauded.conditions
local ok, caps = pcall(conds.capabilities, game.player, {})
if not ok then return "ERR " .. tostring(caps) end
return "move=" .. tostring(caps.move ~= nil) .. " target=" .. tostring(caps.target ~= nil)
'@
    Write-Host "  caps:  $($caps.Result)"
    Check ($caps.Result -match 'move=True|move=true') 'the capability layer sees the character as blocked'

    # -----------------------------------------------------------------------
    # B/C. The choice. bestRecovery is reached through `bot` because
    #      skoobot_act sits one under LuaJIT's 60-upvalue limit.
    # -----------------------------------------------------------------------
    $pick = Invoke-Bridge -TimeoutSec 60 -Lua @'
local p, b = game.player, skoobot_reclauded
-- regen FIRST: the first row is the wrong answer, which is the whole point
local list = { ct.regen, ct.wild }
local tid, value = b.bestRecovery(p, list)
local name = tid and tostring(p:getTalentFromId(tid).name) or "nil"
return ("picked=%s value=%s isWild=%s"):format(name, tostring(value), tostring(tid == ct.wild))
'@
    Write-Host "  pick:  $($pick.Result)"
    Check ($pick.Result -match 'isWild=true') 'bestRecovery picks the wild infusion over the first row'
    Check ($pick.Result -notmatch 'value=0\b') 'and values it above zero'

    # -----------------------------------------------------------------------
    # D. Only the regeneration on offer: it must NOT be treated as a cure.
    # -----------------------------------------------------------------------
    $only = Invoke-Bridge -TimeoutSec 60 -Lua @'
local p, b = game.player, skoobot_reclauded
local tid, value = b.bestRecovery(p, { ct.regen })
return ("picked=%s value=%s"):format(
  tid and tostring(p:getTalentFromId(tid).name) or "nil", tostring(value))
'@
    Write-Host "  regen-only: $($only.Result)"
    Check ($only.Result -match 'value=0\b') 'a pure regeneration is valued at zero while frozen'

    # -----------------------------------------------------------------------
    # E. Nothing on offer: decline, do not error.
    # -----------------------------------------------------------------------
    $none = Invoke-Bridge -TimeoutSec 30 -Lua @'
local ok, tid, value = pcall(skoobot_reclauded.bestRecovery, game.player, {})
return ("ok=%s tid=%s value=%s"):format(tostring(ok), tostring(tid), tostring(value))
'@
    Write-Host "  empty: $($none.Result)"
    Check ($none.Result -match 'ok=true') 'an empty recovery list does not error'

    $null = Invoke-Bridge -TimeoutSec 30 -Lua 'game.player:removeEffect(game.player.EFF_FROZEN, true, true) return "cleared"'
}
finally {
    Stop-Game
}

Write-Host ''
if ($script:Fail.Count -gt 0) {
    Write-Host "[cleanse] FAILED - $($script:Fail.Count) check(s):"
    $script:Fail | ForEach-Object { Write-Host "    - $_" }
    exit 1
}
Write-Host '[cleanse] PASS'
exit 0
