<#
    Prove that a relaunch cannot be satisfied by the previous run's log.

    The bug this guards against reported a launch as ready and answering in
    0.0 seconds, because te4_log.txt still held the previous run's
    `[BRIDGE] ready` and `cmd-0001.lua OK` when the cursor rewound to offset 0.
    The engine truncates the file ~5 ms after Start-Process returns, so a poll
    landing in that window matched the wrong run entirely. It fired on two of
    four launches spaced three seconds apart -- a false PASS, which is the one
    result this harness must never produce.

    Back-to-back launches are the case that broke, so that is what this runs.
    A launch cannot physically complete in under a second on this machine; the
    floor below is deliberately generous and still an order of magnitude above
    what the bug produced.

    Run:
        powershell -ExecutionPolicy Bypass -File .\tools\test-relaunch.ps1

    Companion to test-unfocused.ps1. T-043.
#>
[CmdletBinding()]
param(
    [int]$Rounds  = 4,
    [double]$FloorSec = 1.0
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'harness.ps1')

$fail = 0
$results = @()

for ($i = 1; $i -le $Rounds; $i++) {
    $t0 = Get-Date
    $g  = Start-Game
    $secs = [math]::Round(((Get-Date) - $t0).TotalSeconds, 1)

    # The launch must have really happened: a live process, a bridge that
    # answers, and a log belonging to THIS run rather than the last one.
    $alive = Test-GameAlive
    $echo  = Invoke-Bridge -Lua ("return `"relaunch-$i`"") -TimeoutSec 60
    $fresh = ($echo.Status -eq 'OK' -and $echo.Result -match "relaunch-$i")

    Stop-Game

    $ok = $g.Ready -and $alive -and $fresh -and $secs -ge $FloorSec
    $results += [pscustomobject]@{ Round = $i; Sec = $secs; Ready = $g.Ready; Fresh = $fresh; Ok = $ok }
    if (-not $ok) { $fail++ }

    '{0}  round {1}: {2,5:N1}s  ready={3}  fresh-echo={4}' -f `
        $(if ($ok) { 'PASS' } else { 'FAIL' }), $i, $secs, $g.Ready, $fresh

    if ($secs -lt $FloorSec) {
        Write-Host "      a launch cannot complete in ${secs}s -- the log from the"
        Write-Host '      previous run is being matched again (see Clear-GameLog)'
    }

    # No pause between rounds: the tighter the gap, the better the test.
}

Write-Host ''
if ($fail -gt 0) {
    Write-Host "[test-relaunch] FAILED - $fail of $Rounds round(s)"
    exit 1
}
Write-Host "[test-relaunch] PASS - $Rounds back-to-back launches, each genuinely its own"
exit 0
