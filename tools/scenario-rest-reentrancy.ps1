<#
    #114 regression: beginning a rest must not crash when the engine stops the
    rest as it starts.

    ToME's restInit is not re-entrant. It sets self.resting, spends energy, and
    Player:useEnergy fires callbackOnActEnd; any callback that damages or
    debuffs the player reaches restStop, which nils self.resting before
    PlayerRest.lua:53 increments self.resting.cnt. A playtester hit it on
    0.1.0-g8627575 the first time the bot rested.

    The trigger is reproduced at the same seam the engine uses: useEnergy is
    wrapped for the duration of the run so that it calls restStop, which is
    exactly what a damaging callbackOnActEnd does. The bot is then driven
    through its own rest decision with bot.runonce().

    PROVES THE PATH WAS TAKEN. The wrapper sets a flag when it fires, and the
    scenario is INCONCLUSIVE (3) rather than passing if the bot never reached
    restInit -- otherwise a save where the bot chose to fight would report a
    clean pass having tested nothing.

    Exit codes:  0 pass   1 fail   2 tainted   3 inconclusive

    Run:
        powershell -ExecutionPolicy Bypass -File .\tools\scenario-rest-reentrancy.ps1

    #114.
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
Write-Host '[rest-reentrancy] restInit must not crash when the rest is stopped as it begins (#114)'

try {
    $g = Load-Save -Name $SaveName
    if (-not $g.Ready) { Write-Host "[rest-reentrancy] FAILED - could not load '$SaveName' ($($g.Reason))"; exit 1 }
    Check ($g.Addons -match 'skoobot_reclauded') 'the product is loaded'

    $out = Invoke-Bridge -Lua @'
local p = game.player
local bot = skoobot_reclauded
local r = {}
local function say(k, v) r[#r+1] = k .. "=" .. tostring(v) end

-- Make the character want to rest: no hostiles is the save's business, but
-- missing life is what puts the act loop in the rest branch.
local before_life = p.life
p.life = math.max(1, math.floor(p.max_life * 0.6))

-- Reproduce the engine's own trigger: restStop from inside useEnergy, which
-- is where Player:useEnergy fires callbackOnActEnd.
local reached = false
local old = p.useEnergy
p.useEnergy = function(self, ...)
  local ret = old(self, ...)
  if self.resting then reached = true; self:restStop("regression probe") end
  return ret
end

local ok, err = pcall(function() bot.runonce() end)

p.useEnergy = old
p.life = before_life
if p.resting then p:restStop("cleanup") end

say("reached_restinit", reached)
say("no_error", ok)
say("err", err)
say("resting_left", p.resting ~= nil)
say("last_reason", bot.last_reason)
return table.concat(r, "  ||  ")
'@

    Write-Host "  raw: $($out.Result)"
    if ($out.Tainted) { Write-Host '[rest-reentrancy] TAINTED'; exit 2 }

    $kv = @{}
    foreach ($pair in ($out.Result -split '\s+\|\|\s+')) {
        $i = $pair.IndexOf('=')
        if ($i -gt 0) { $kv[$pair.Substring(0, $i)] = $pair.Substring($i + 1) }
    }

    if ($kv['reached_restinit'] -ne 'true') {
        Write-Host '[rest-reentrancy] INCONCLUSIVE - the bot never reached restInit, so nothing was tested.'
        Write-Host "                  last_reason: $($kv['last_reason'])"
        exit 3
    }
    Check $true 'the bot reached restInit (the path under test ran)'
    Check ($kv['no_error'] -eq 'true') 'no error escaped the rest attempt'
    Check ($kv['resting_left'] -eq 'false') 'no half-initialised resting state was left behind'

    if ($script:Fail.Count -gt 0) {
        Write-Host "[rest-reentrancy] FAILED - $($script:Fail.Count) check(s)"
        exit 1
    }
    Write-Host '[rest-reentrancy] PASS'
    exit 0
} catch {
    Write-Host "[rest-reentrancy] ERROR $_"
    exit 3
} finally {
    Stop-Game | Out-Null
}
