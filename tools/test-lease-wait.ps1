<#
    Prove Wait-HarnessLease: a host that wants the game for minutes waits
    for the holder instead of being refused, and gives up when told to (#83).

    Needs no game. The holder is a bare PowerShell process that takes the
    lease and sleeps, which is all a lease knows about a host -- the lease is
    alive while its host process is, whether or not a t-engine ever ran. That
    keeps this a seconds-long check of the waiting logic, and leaves
    test-occupancy.ps1 to prove the parts that do need a real game.

    Three properties:
      1. with the lease held, Enter-HarnessLease refuses AT ONCE (unchanged);
      2. Wait-HarnessLease blocks instead, and takes the lease once the
         holder exits;
      3. Wait-HarnessLease gives up at its timeout rather than forever, and
         names the holder when it does.

    Run:
        powershell -ExecutionPolicy Bypass -File .\tools\test-lease-wait.ps1
#>
[CmdletBinding()]
param(
    [switch]$Hold,
    [int]$HoldSeconds = 6
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'harness-lease.ps1')

# --- the holder -------------------------------------------------------------
if ($Hold) {
    # Never inherit the caller's lease: that would make the holder US.
    $env:SKOOBOT_HARNESS_HOST = $null
    $null = Enter-HarnessLease
    Start-Sleep -Seconds $HoldSeconds
    exit 0
}

# --- the test ---------------------------------------------------------------
$fail = 0
function Check($ok, $what) {
    if ($ok) { Write-Host "  PASS  $what" } else { Write-Host "  FAIL  $what"; $script:fail++ }
}

$env:SKOOBOT_HARNESS_HOST = $null
if (Get-ForeignLease) {
    Write-Host "[test-lease-wait] the game is in use by $(Format-Lease (Get-ForeignLease)); run this when it is free"
    exit 2
}

function Start-Holder([int]$Seconds) {
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath, '-Hold', '-HoldSeconds', "$Seconds")
    $p = Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -PassThru -WindowStyle Hidden
    $null = $p.Handle
    # Wait for the lease to actually name it, not merely for the process to exist.
    $deadline = (Get-Date).AddSeconds(20)
    while ((Get-Date) -lt $deadline) {
        $l = Get-HarnessLease
        if ($l -and [int]$l.host -eq $p.Id) { return $p }
        Start-Sleep -Milliseconds 200
    }
    throw "[test-lease-wait] the holder never took the lease"
}

try {
    Write-Host ''
    Write-Host '[test-lease-wait] 1. a held lease is refused at once'
    $holder = Start-Holder -Seconds 60
    $env:SKOOBOT_HARNESS_HOST = $null
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $refused = $false
    try { $null = Enter-HarnessLease } catch { $refused = $_.Exception.Message -match 'IN USE' }
    $sw.Stop()
    Check $refused 'Enter-HarnessLease refuses while another live host holds it'
    Check ($sw.Elapsed.TotalSeconds -lt 2) "...and does not wait ($([math]::Round($sw.Elapsed.TotalSeconds, 1)) s)"

    Write-Host ''
    Write-Host '[test-lease-wait] 3. a waiter gives up at its timeout'
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $gaveUp = $false; $named = $false
    try { $null = Wait-HarnessLease -TimeoutSec 4 -MinWaitSec 1 -MaxWaitSec 2 -Label 'probe' }
    catch { $gaveUp = $true; $named = $_.Exception.Message -match "host pid $($holder.Id)" }
    $sw.Stop()
    Check $gaveUp 'Wait-HarnessLease throws once its timeout passes'
    Check ($sw.Elapsed.TotalSeconds -ge 3.5) "...after waiting, not at once ($([math]::Round($sw.Elapsed.TotalSeconds, 1)) s)"
    Check $named '...and the message names the holder'
    Stop-Process -Id $holder.Id -Force -ErrorAction Ignore
    Start-Sleep -Milliseconds 300

    Write-Host ''
    Write-Host '[test-lease-wait] 2. a waiter gets in when the holder exits'
    $holder = Start-Holder -Seconds $HoldSeconds
    $env:SKOOBOT_HARNESS_HOST = $null
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $lease = Wait-HarnessLease -TimeoutSec 60 -MinWaitSec 1 -MaxWaitSec 2 -Label 'probe'
    $sw.Stop()
    Check ($null -ne $lease -and [int]$lease.host -eq $PID) 'Wait-HarnessLease returns OUR lease'
    Check ($sw.Elapsed.TotalSeconds -ge 2) "...having waited for the holder ($([math]::Round($sw.Elapsed.TotalSeconds, 1)) s)"
    Check ($sw.Elapsed.TotalSeconds -lt ($HoldSeconds + 15)) '...and got in promptly once it went'
    Exit-HarnessLease
} finally {
    if ($holder) { Stop-Process -Id $holder.Id -Force -ErrorAction Ignore }
    Exit-HarnessLease
}

Write-Host ''
if ($fail -eq 0) { Write-Host '[test-lease-wait] PASS'; exit 0 }
Write-Host "[test-lease-wait] FAIL ($fail)"; exit 1
