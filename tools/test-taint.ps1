<#
    Prove the interference detector fires. The taint flag VOIDS a measurement,
    and its resize half was structurally dead for the project's whole life:
    $script:LastResolution entered every run unseeded, so the first resize a run
    saw could only establish a baseline and a single human resize never tainted
    anything (#221). Nothing exercised it, which is why nobody knew.

    Three properties, in order:
      1. the launch seeds the baseline -- LastResolution is the launch size
         after Start-Game, not $null;
      2. the engine re-asserting that same size does NOT taint -- the false
         positive the narrowing at Invoke-Bridge was written to stop (the
         launch emits [DO RESIZE] twice, so this is observed, not argued);
      3. ONE mid-run resize taints, and the line that did it is kept (#220).

    Run:
        powershell -ExecutionPolicy Bypass -File .\tools\test-taint.ps1

    Companion to test-occupancy.ps1, test-relaunch.ps1 and test-unfocused.ps1.
#>
[CmdletBinding()]
param([int]$SettleSec = 6)

. (Join-Path $PSScriptRoot 'harness.ps1')

Add-Type @'
using System;
using System.Runtime.InteropServices;
public class TaintWin {
    [DllImport("user32.dll")] public static extern bool MoveWindow(IntPtr h,int x,int y,int w,int t,bool r);
}
'@

$fail = 0
function Check([string]$what, [bool]$ok, [string]$got) {
    if ($ok) { Write-Host "  PASS  $what" }
    else { Write-Host "  FAIL  $what -- got: $got"; $script:fail++ }
}

$g = Start-Game -TimeoutSec 90
if (-not $g.Ready) { Write-Host '[test-taint] FAILED - bridge never came up'; Stop-Game; exit 1 }

try {
    Write-Host ''
    Write-Host '[1] the launch seeds the resize baseline'
    $seeded = $script:LastResolution
    Check 'LastResolution is set after Start-Game' ($null -ne $seeded) '<null>'
    if ($null -eq $seeded) { Write-Host '[test-taint] FAILED - nothing else can be checked'; exit 1 }
    Write-Host "        baseline = $seeded"

    Write-Host ''
    Write-Host '[2] the engine re-asserting its own size does not taint'
    # The launch emits [DO RESIZE] more than once at the configured size, so
    # the re-assert case has already happened by here: seeding must be silent.
    $r0 = Invoke-Bridge -Lua 'return 2+2' -TimeoutSec 20
    Check 'settle call is not tainted' (-not $r0.Tainted) "tainted=$($r0.Tainted)"
    Check 'nothing recorded from the launch' (@($script:HarnessInterference).Count -eq 0) `
          ("$(@($script:HarnessInterference) -join ' | ')")

    Write-Host ''
    Write-Host '[3] ONE mid-run resize taints, and the cause is kept'
    $proc = Get-Process t-engine -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $proc -or $proc.MainWindowHandle -eq 0) {
        Write-Host '  SKIP  no game window to resize'; $script:fail++
    } else {
        $w = if ($seeded -match '^(\d+)x') { [int]$Matches[1] + 224 } else { 1024 }
        Write-Host "        resizing once to ${w}x768"
        [void][TaintWin]::MoveWindow($proc.MainWindowHandle, 40, 40, $w, 768, $true)
        Start-Sleep -Seconds $SettleSec
        $r1 = Invoke-Bridge -Lua 'return 2+2' -TimeoutSec 20
        Check 'a single resize taints' ([bool]$r1.Tainted) "tainted=$($r1.Tainted)"
        Check 'the call names the cause' (@($r1.Interference).Count -gt 0) '<empty>'
        $kept = @($script:HarnessInterference | Where-Object { $_ -match 'DO RESIZE' })
        Check 'the run keeps the line' ($kept.Count -gt 0) "$(@($script:HarnessInterference) -join ' | ')"
        if ($kept.Count -gt 0) { Write-Host "        kept: $($kept[0])" }
        Check 'the baseline moved with it' ($script:LastResolution -ne $seeded) "$($script:LastResolution)"
    }
} finally {
    Stop-Game
}

Write-Host ''
if ($fail -gt 0) { Write-Host "[test-taint] FAILED - $fail check(s)"; exit 1 }
Write-Host '[test-taint] PASS - the baseline is seeded, a re-assert is silent, one resize taints and is recorded'
exit 0
