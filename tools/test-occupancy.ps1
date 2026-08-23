<#
    Prove the harness lease: one live host owns the game, and nobody else's
    Start-Game or Stop-Game can take it away from them.

    The failure this guards against: Stop-Game kills every t-engine it can
    see, and Start-Game calls it first, so two sessions running scenarios at
    once void each other. On 2026-08-22 both `tome-tier pump never turned`
    failures were status=CRASHED -- the game killed mid-load by the other
    session's launch -- and were read as a launch flake (#60).

    Three properties, in order:
      1. while another live host holds the lease, Start-Game refuses;
      2. ...and Stop-Game leaves that host's game running;
      3. once the holder is dead its lease is stale: the next host reaps the
         orphaned t-engine and takes the game over, with nobody cleaning up.

    The holder is a second PowerShell process running this same script with
    -Hold: it launches a game through the same harness.ps1 and sleeps. It is
    killed at the end, which is what produces the orphan for property 3.

    Run:
        powershell -ExecutionPolicy Bypass -File .\tools\test-occupancy.ps1

    Companion to test-relaunch.ps1 and test-unfocused.ps1.
#>
[CmdletBinding()]
param(
    [switch]$Hold,
    [int]$HoldSeconds = 600,
    [int]$HolderTimeoutSec = 300
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'harness.ps1')

# --- the holder -------------------------------------------------------------
if ($Hold) {
    $g = Start-Game
    if (-not $g.Ready) { exit 1 }
    Start-Sleep -Seconds $HoldSeconds
    Stop-Game
    exit 0
}

# --- the test ---------------------------------------------------------------
$fail = 0
function Check($ok, $what) {
    if ($ok) { Write-Host "  PASS  $what" } else { Write-Host "  FAIL  $what"; $script:fail++ }
}
function Test-Pid($id) { [bool](Get-Process -Id $id -ErrorAction Ignore) }

# The holder must not inherit a lease from us, or it would count as us.
$env:SKOOBOT_HARNESS_HOST = $null
if (Get-ForeignLease) {
    Write-Host "[test-occupancy] the game is in use by $(Format-Lease (Get-ForeignLease)); run this when it is free"
    exit 2
}
Stop-Game   # start from nothing

$logDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'build\logs'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$holderLog = Join-Path $logDir 'occupancy-holder.txt'

$holder = Start-Process powershell -PassThru -NoNewWindow -RedirectStandardOutput $holderLog `
    -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"", '-Hold', '-HoldSeconds', "$HoldSeconds")
Write-Host "[test-occupancy] holder pid=$($holder.Id) is launching a game"

try {
    # Wait until the holder's lease names a live game AND its pump has
    # turned, so the properties below are tested against a fully-up run, the
    # way a real mid-scenario collision would be. The holder's own output says
    # when that is.
    $deadline = (Get-Date).AddSeconds($HolderTimeoutSec)
    $lease = $null
    while ((Get-Date) -lt $deadline) {
        $l = Get-HarnessLease
        $up = (Test-Path $holderLog) -and ((Get-Content $holderLog -Raw -ErrorAction Ignore) -match 'pump live')
        if ($up -and $l -and [int]$l.host -eq $holder.Id -and $l.game -and (Test-Pid ([int]$l.game))) { $lease = $l; break }
        if ($holder.HasExited) { break }
        Start-Sleep -Milliseconds 250
    }
    if (-not $lease) {
        Write-Host '[test-occupancy] FAILED - the holder never got a game up'
        if (Test-Path $holderLog) { Get-Content $holderLog | ForEach-Object { Write-Host "        $_" } }
        exit 1
    }
    # Not $gamePid: variable names are case-insensitive and the dot-sourced
    # harness owns $script:GamePid in this very scope -- Stop-Game nulls it.
    $heldGame = [int]$lease.game
    Write-Host "[test-occupancy] holder owns game pid=$heldGame"
    Check ($null -ne (Get-ForeignLease)) "the holder's lease reads as foreign and live from here"

    # 1. Start-Game refuses.
    $refused = $false
    try { $null = Start-Game } catch {
        $refused = ($_.Exception.Message -match 'IN USE')
        Write-Host "        refused: $($_.Exception.Message)"
    }
    Check $refused 'Start-Game refuses while another live host holds the game'
    Check (Test-Pid $heldGame) "the holder's game survived the refused Start-Game"

    # 2. Stop-Game leaves it alone.
    Stop-Game
    Check (Test-Pid $heldGame) "Stop-Game leaves another host's game running"

    # 3. A dead holder's lease is stale. Kill the holder; its game is orphaned.
    Stop-Process -Id $holder.Id -Force
    $null = $holder.WaitForExit(10000)
    Check (Test-Pid $heldGame) 'the orphaned game is still running after the holder died'
    Check ($null -eq (Get-ForeignLease)) "a dead host's lease is stale, not foreign"
    Stop-Game
    Check (-not (Test-Pid $heldGame)) 'Stop-Game reaps the orphan once no live host owns it'

    $taken = $false
    try { $g = Start-Game; $taken = [bool]$g.Ready } catch { Write-Host "        $($_.Exception.Message)" }
    Check $taken 'Start-Game takes the game over after the holder died'
    $mine = Get-HarnessLease
    Check ($mine -and [int]$mine.host -eq $PID) 'the lease now names this host'
    Stop-Game
} finally {
    if (-not $holder.HasExited) { Stop-Process -Id $holder.Id -Force -ErrorAction Ignore }
    Stop-Game
    Exit-HarnessLease
}

Write-Host ''
if ($fail -gt 0) {
    Write-Host "[test-occupancy] FAILED - $fail check(s)"
    exit 1
}
Write-Host '[test-occupancy] PASS - one live host owns the game; a dead one is taken over'
exit 0
