<#
    Devbridge smoke test. Proves the loop end to end: launch a real game, run
    commands through the bridge, read results back, shut down.

    Run:  powershell -File .\tools\smoke-test.ps1
#>

. (Join-Path $PSScriptRoot 'harness.ps1')

$commands = @(
    'return 2+2'
    'return bridge.dialogs()'
    'return "tier=" .. bridge.tier .. " polls=" .. bridge.polls'
    'return "class=" .. tostring(game.__CLASSNAME)'
    'bridge.say("driven from outside") return "said"'
    'return "keyhandler=" .. tostring(require("engine.Key").current ~= nil)'
    'return bridge.key("EXIT")'
)

$g = Start-Game -TimeoutSec 60
if (-not $g.Ready) { Write-Host '[smoke] FAILED: bridge never came up'; Stop-Game; exit 1 }

$fail = 0
foreach ($c in $commands) {
    $r = Invoke-Bridge -Lua $c -TimeoutSec 20
    $flag = ''
    if ($r.Tainted) { $flag = '  <-- TAINTED (human input during run)' }
    '{0,-8} {1,-58} => {2}{3}' -f $r.Status, $c, $r.Result, $flag
    if ($r.Status -ne 'OK') { $fail++ }
}

Write-Host ''
if ($fail -eq 0) { Write-Host '[smoke] PASS - all commands returned OK' }
else { Write-Host "[smoke] $fail command(s) did not return OK" }

Stop-Game
exit $fail
