<#
    Prove the bridge survives losing the window.

    The development machine is also a machine a person uses: they will click into
    other windows, and may minimise the game. If the pump is coupled to
    rendering, all of that silently stops the harness and every test after it
    "fails" for no reason. This test makes that failure mode visible.
#>
. (Join-Path $PSScriptRoot 'harness.ps1')

Add-Type @'
using System;
using System.Runtime.InteropServices;
public class Win {
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
}
'@

$g = Start-Game -TimeoutSec 60
if (-not $g.Ready) { Write-Host 'FAILED: no bridge'; Stop-Game; exit 1 }  # #196: same leak shape as new-character had

$r = Invoke-Bridge -Lua 'return "focused polls=" .. bridge.polls' -TimeoutSec 20
"baseline    $($r.Status)  $($r.Result)"

$h = (Get-Process -Id $g.Pid).MainWindowHandle
$null = [Win]::ShowWindow($h, 6)   # SW_MINIMIZE
Start-Sleep -Seconds 3
Write-Host 'window minimised'

$fail = 0
foreach ($i in 1..3) {
    $r = Invoke-Bridge -Lua "return `"minimised probe $i polls=`" .. bridge.polls" -TimeoutSec 25
    "min probe $i  $($r.Status)  $($r.Result)"
    if ($r.Status -ne 'OK') { $fail++ }
}

$null = [Win]::ShowWindow($h, 9)   # SW_RESTORE
Start-Sleep -Seconds 2
$r = Invoke-Bridge -Lua 'return "restored polls=" .. bridge.polls' -TimeoutSec 20
"restored    $($r.Status)  $($r.Result)"
if ($r.Status -ne 'OK') { $fail++ }

Stop-Game
if ($fail -eq 0) { Write-Host "`n[unfocused] PASS - bridge survives a minimised window" }
else { Write-Host "`n[unfocused] FAIL - $fail probe(s) did not respond" }
exit $fail
