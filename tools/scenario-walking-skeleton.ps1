<#
    T-071 scenario: the product loads, takes control, does something, and
    gives control back.

    Measured in game.turn, never wall-clock. A keystroke, a click or a
    resolution change costs frames, not turns, so a turn-counted assertion is
    immune to interference by construction -- which matters on a machine a
    person also uses. Wall-clock appears here only as a deadline for giving up.

    "Did something" is deliberately weak: this is a walking skeleton, and the
    bot stopping early for a good reason IS the designed behaviour, not a
    failure. What the scenario refuses to accept is a bot that loads and then
    does nothing at all, or one that runs forever.

    Run:
        powershell -ExecutionPolicy Bypass -File .\tools\scenario-walking-skeleton.ps1

    T-071.
#>
[CmdletBinding()]
param(
    [string]$SaveName = 'harness',
    [int]$MinTurns    = 10,
    [int]$DeadlineSec = 300
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'harness.ps1')

$script:Fail = @()
function Check($ok, $what) {
    if ($ok) { Write-Host "  PASS  $what" }
    else     { Write-Host "  FAIL  $what"; $script:Fail += $what }
}

function Get-Turn {
    $r = Invoke-Bridge -Lua 'return tostring(game.turn)' -TimeoutSec 30
    if ($r.Status -ne 'OK') { return $null }
    return [int]($r.Result -replace '[^\d\-].*$', '')
}

Write-Host ''
Write-Host '[scenario] walking skeleton (T-071)'

try {
    $g = Load-Save -Name $SaveName
    if (-not $g.Ready) {
        Write-Host "[scenario] FAILED - could not load a game ($($g.Reason))"
        exit 1
    }
    Check $g.AddonsIntact 'no required addon was dropped'
    Check ($g.Addons -match 'skoobot_reclauded') 'the product is loaded'

    # It has to have registered its keybind, or the toggle below proves nothing.
    #
    # KeyBind.binds is keyed by KEYSTRING, not by action type -- binds[ks][type]
    # = true (engine/KeyBind.lua:132-133) -- while the handlers live in
    # .virtuals[type]. Looking for the action in .binds finds nothing and says
    # "not bound" about a binding that works perfectly.
    $kb = Invoke-Bridge -Lua @'
local k = game.key
if not k then return "no key handler" end
local handler = k.virtuals and k.virtuals.TOGGLE_SKOOBOT_RECLAUDED
local keys = {}
for ks, types in pairs(k.binds or {}) do
  if types.TOGGLE_SKOOBOT_RECLAUDED then keys[#keys+1] = ks end
end
return "handler=" .. tostring(handler ~= nil)
    .. " keys=" .. (#keys > 0 and table.concat(keys, ",") or "none")
    .. " bot=" .. tostring(rawget(_G, "skoobot_reclauded") ~= nil)
'@ -TimeoutSec 30
    Write-Host "  info  $($kb.Result)"
    Check ($kb.Result -match 'bot=true') 'the addon installed its runtime'
    Check ($kb.Result -match 'handler=true') 'the toggle action has a handler'
    Check ($kb.Result -notmatch 'keys=none') 'the toggle action is bound to a key'

    $before = Get-Turn
    Check ($null -ne $before) "read game.turn before ($before)"

    # Through the keybind, not by calling start() directly: the binding is part
    # of what T-071 has to deliver, and a direct call would not test it.
    $t = Invoke-Bridge -Lua 'return bridge.key("TOGGLE_SKOOBOT_RECLAUDED")' -TimeoutSec 30
    Write-Host "  info  toggle: $($t.Result)"

    # Poll for turns, not for seconds. The deadline only stops a hung run.
    $deadline = (Get-Date).AddSeconds($DeadlineSec)
    $turn = $before
    $active = $true
    $tainted = $false
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 3
        if (-not (Test-GameAlive)) { break }
        $s = Invoke-Bridge -Lua @'
local b = rawget(_G, "skoobot_reclauded")
return "turn=" .. tostring(game.turn)
    .. " active=" .. tostring(b and b.active)
    .. " actions=" .. tostring(b and b.actions)
    .. " reason=" .. tostring(b and b.last_reason)
'@ -TimeoutSec 30
        if ($s.Status -ne 'OK') { continue }
        if ($s.Tainted) { $tainted = $true }
        Write-Host "  poll  $($s.Result)"
        if ($s.Result -match 'turn=(\d+)') { $turn = [int]$Matches[1] }
        if ($s.Result -match 'active=false') { $active = $false; break }
        if (($turn - $before) -ge $MinTurns -and $s.Result -match 'actions=([1-9])') {
            # It is working; let it finish on its own budget rather than here.
        }
    }

    $advanced = $turn - $before
    Write-Host ''
    Write-Host "  info  game.turn advanced by $advanced ($before -> $turn)"

    Check ($advanced -ge $MinTurns) "the bot advanced the game by at least $MinTurns turns"
    Check (-not $active) 'the bot handed control back rather than running forever'

    $final = Invoke-Bridge -Lua @'
local b = rawget(_G, "skoobot_reclauded")
if not b then return "no bot" end
return "actions=" .. tostring(b.actions) .. " reason=" .. tostring(b.last_reason)
'@ -TimeoutSec 30
    Write-Host "  info  final: $($final.Result)"
    Check ($final.Result -match 'actions=[1-9]') 'the bot took at least one action'
    Check ($final.Result -notmatch 'reason=nil') 'the bot recorded why it stopped'
    Check ($final.Result -notmatch 'internal error') 'the bot did not stop on an internal error'

    Stop-Game
    Start-Sleep -Seconds 2

    $lines = @((Get-Content $script:LogPath -Raw) -split "`r?`n")
    $acted = @($lines | Where-Object { $_ -match '^\[SKOOBOT\] (resting|exploring)' })
    Write-Host "  info  $($acted.Count) action line(s) in the engine log"
    foreach ($a in ($acted | Select-Object -First 6)) { Write-Host "        $a" }
    Check ($acted.Count -ge 1) 'the engine log records the actions it took'

    $errs = @($lines | Where-Object { $_ -match 'Lua Error' })
    Check ($errs.Count -eq 0) 'no Lua Error anywhere in the run'
    foreach ($e in ($errs | Select-Object -First 5)) { Write-Host "        $e" }

    if ($tainted) {
        Write-Host ''
        Write-Host '  TAINTED - a human touched the machine during this run.'
        Write-Host '            The result is void. Re-run it; do not record it.'
        exit 2
    }

} finally {
    Stop-Game
}

Write-Host ''
if ($script:Fail.Count -gt 0) {
    Write-Host "[scenario] FAILED - $($script:Fail.Count) check(s):"
    foreach ($f in $script:Fail) { Write-Host "                 $f" }
    exit 1
}
Write-Host '[scenario] PASS - loads, takes control, acts, hands back'
exit 0
