<#
    SkooBot: Reclauded -- test harness.

    Drives a real ToME process from outside: launches it, sends Lua over the
    devbridge file channel, reads results back out of te4_log.txt, and reports
    human interference so a disrupted run is quarantined rather than believed.

    Dot-source it:   . .\tools\harness.ps1
#>

# Paths. Derived rather than hardcoded, so nothing here carries one machine's
# user name and the tools work for anyone who checks the repo out. Override the
# game location with TOME_DIR if it is installed elsewhere.
if ($env:TOME_DIR) { $script:GameDir = $env:TOME_DIR } else { $script:GameDir = 'C:\games\TalesMajEyal' }
$script:GameExe   = Join-Path $script:GameDir 't-engine.exe'
$script:LogPath   = Join-Path $script:GameDir 'te4_log.txt'

# T-Engine's home directory. bootstrap/boot.lua mounts it at / inside the game,
# so <home>\skoobot-bridge is /skoobot-bridge to the devbridge addons.
$script:TomeHome  = Join-Path $env:USERPROFILE 'T-Engine\4.0'
$script:BridgeDir = Join-Path $script:TomeHome 'skoobot-bridge'
$script:SaveRoot  = Join-Path $script:TomeHome 'tome\save'

$script:Seq       = 0
$script:GamePid   = $null
$script:LogOffset = 0
$script:LogBuf    = New-Object System.Collections.Generic.Queue[string]

function Reset-LogCursor {
    $script:LogOffset = 0
    $script:LogBuf.Clear()
}

# te4_log.txt is held open for writing by the game, so a plain Get-Content hits
# a sharing violation. Open it with FileShare.ReadWrite instead.
function Read-NewLogLines {
    if (-not (Test-Path $script:LogPath)) { return }
    $fs = [System.IO.File]::Open($script:LogPath, 'Open', 'Read', 'ReadWrite')
    try {
        if ($script:LogOffset -gt $fs.Length) { $script:LogOffset = 0 }  # truncated by a relaunch
        $fs.Seek($script:LogOffset, 'Begin') | Out-Null
        $sr = New-Object System.IO.StreamReader($fs)
        $text = $sr.ReadToEnd()
        $script:LogOffset = $fs.Position
    } finally { $fs.Dispose() }
    if ($text) {
        foreach ($l in ($text -split "`r?`n")) { if ($l -ne '') { $script:LogBuf.Enqueue($l) } }
    }
}

<#
    Consume buffered log lines until one matches, or the timeout expires.

    Lines are drained from a queue rather than re-read by byte offset: a naive
    offset scan advances past everything in the chunk it happened to read, so a
    response arriving in the same chunk as an earlier match is lost forever.
#>
function Wait-LogLine {
    param(
        [Parameter(Mandatory)][string]$Pattern,
        [int]$TimeoutSec = 30
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $seen = @()
    while ($true) {
        Read-NewLogLines
        while ($script:LogBuf.Count -gt 0) {
            $l = $script:LogBuf.Dequeue()
            $seen += $l
            if ($l -match $Pattern) {
                return [pscustomobject]@{ Matched = $true; Line = $l; Seen = $seen }
            }
        }
        if ((Get-Date) -ge $deadline) {
            return [pscustomobject]@{ Matched = $false; Line = $null; Seen = $seen }
        }
        Start-Sleep -Milliseconds 100
    }
}

function Stop-Game {
    Get-Process -Name 't-engine' -ErrorAction Ignore | ForEach-Object { Stop-Process -Id $_.Id -Force }
    $script:GamePid = $null
}

function Test-GameAlive {
    if (-not $script:GamePid) { return $false }
    [bool](Get-Process -Id $script:GamePid -ErrorAction Ignore)
}

function Start-Game {
    param([int]$TimeoutSec = 60)
    Stop-Game
    if (-not (Test-Path $script:BridgeDir)) { New-Item -ItemType Directory -Path $script:BridgeDir | Out-Null }
    Get-ChildItem $script:BridgeDir -Filter 'cmd-*' -ErrorAction Ignore | Remove-Item -Force
    Reset-LogCursor
    $script:Seq = 0
    $p = Start-Process -FilePath $script:GameExe `
                       -ArgumentList '--flush-stdout','--no-steam','--no-web' `
                       -WorkingDirectory $script:GameDir -PassThru
    $script:GamePid = $p.Id
    Write-Host "[harness] launched pid=$($p.Id)"
    $r = Wait-LogLine -Pattern '\[BRIDGE\] ready' -TimeoutSec $TimeoutSec
    if ($r.Matched) { Write-Host "[harness] bridge up: $($r.Line)" }
    else { Write-Host "[harness] NO BRIDGE after ${TimeoutSec}s" }
    [pscustomobject]@{ Pid = $p.Id; Ready = $r.Matched }
}
<#
    Send Lua to the game, and by default wait for its result.

    Status is OK | ERR | TIMEOUT | CRASHED | SENT. Tainted means a human touched
    the machine while the command was in flight; treat that result as void and
    re-run rather than recording a defect, because a keystroke or a resize
    produces failures that are not bugs in the bot.

    -NoWait fires and forgets. Some engine operations -- birth, world generation
    -- rebuild game state, and the frame executing the command can disappear
    before it ever reports. Waiting for a reply that will never arrive is not a
    diagnosis; poll for the resulting state instead. NoWait also skips cleanup so
    the file survives to be picked up; Start-Game clears the directory.
#>
function Invoke-Bridge {
    param(
        [Parameter(Mandatory)][string]$Lua,
        [int]$TimeoutSec = 30,
        [switch]$NoWait
    )
    if (-not (Test-GameAlive)) {
        return [pscustomobject]@{ Status = 'CRASHED'; Result = 'game not running'; Interference = @(); Tainted = $false }
    }

    $script:Seq++
    $name = 'cmd-{0:d4}.lua' -f $script:Seq
    $tmp  = Join-Path $script:BridgeDir ($name + '.tmp')
    $dst  = Join-Path $script:BridgeDir $name
    # Write then rename: the game must never see a half-written command file.
    # ASCII, not utf8 -- PowerShell 5.1 writes a BOM that loadstring chokes on.
    Set-Content -Path $tmp -Value $Lua -Encoding ascii
    Move-Item -Path $tmp -Destination $dst -Force

    if ($NoWait) {
        return [pscustomobject]@{ Status = 'SENT'; Result = $name; Interference = @(); Tainted = $false }
    }

    $r = Wait-LogLine -Pattern ('\[BRIDGE\] ' + [regex]::Escape($name) + ' (OK|ERR)') -TimeoutSec $TimeoutSec

    # The game cannot delete these itself (physfs write-path restriction), so
    # cleanup is ours. The bridge's sequence gate means a leftover file is
    # inert, not a replay hazard.
    Remove-Item $dst -Force -ErrorAction Ignore

    # Focus changes are logged but do NOT taint. Gaining or losing focus alters
    # no game state, and the launch itself emits one, so counting it would flag
    # every first command of every run. Keys, clicks and resizes do change things.
    $interference = @($r.Seen | Where-Object { $_ -match '\[BRIDGE\] INTERFERE (key|mouse)|\[DO RESIZE\]' })

    $status = 'TIMEOUT'; $result = $null
    if ($r.Matched) {
        if ($r.Line -match ([regex]::Escape($name) + ' (OK|ERR) ?(.*)$')) {
            $status = $Matches[1]; $result = $Matches[2]
        }
    } elseif (-not (Test-GameAlive)) { $status = 'CRASHED'; $result = 'process died' }

    [pscustomobject]@{
        Status       = $status
        Result       = $result
        Interference = $interference
        Tainted      = ($interference.Count -gt 0)
    }
}
