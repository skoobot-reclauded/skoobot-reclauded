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

<#
    Explain a bridge timeout instead of just reporting one.

    An addon that errors at load and a bridge that never came up produce the
    identical symptom: silence. The engine says which it was, loudly, in
    te4_log.txt -- and that file is opened in 'w' mode, so the next launch
    destroys the evidence. Print the lines that carry the answer and keep a
    copy of the whole log before it goes.

    build/logs/ is gitignored (build/ already is), so archiving is free.
#>
function Show-LoadDiagnostics {
    param([string[]]$Seen)

    $pattern = 'Lua Error|Removing addon|Checking addon|error opening|stack traceback|\*\*\*'

    # Whatever the caller already drained, plus anything still unread.
    $lines = @()
    if ($Seen) { $lines += $Seen }
    Read-NewLogLines
    while ($script:LogBuf.Count -gt 0) { $lines += $script:LogBuf.Dequeue() }

    $hits = @($lines | Where-Object { $_ -match $pattern })
    if ($hits.Count -gt 0) {
        Write-Host '[harness] --- engine lines that may explain it ---'
        foreach ($h in ($hits | Select-Object -Last 25)) { Write-Host "           $h" }
    } else {
        Write-Host '[harness] --- no addon-load or Lua-error lines in the log ---'
    }

    $archive = Join-Path (Split-Path -Parent $PSScriptRoot) 'build\logs'
    if (-not (Test-Path $archive)) { New-Item -ItemType Directory -Path $archive -Force | Out-Null }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $dest  = Join-Path $archive "te4_log-$stamp.txt"
    if (Test-Path $script:LogPath) {
        # The game still holds it open for writing; copy through a shared read.
        try {
            $fs = [System.IO.File]::Open($script:LogPath, 'Open', 'Read', 'ReadWrite')
            try {
                $out = [System.IO.File]::Create($dest)
                try { $fs.CopyTo($out) } finally { $out.Dispose() }
            } finally { $fs.Dispose() }
            Write-Host "[harness] full log archived to $dest"
        } catch {
            Write-Host "[harness] could not archive the log: $($_.Exception.Message)"
        }
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

<#
    Launch a game and wait until the bridge can actually execute a command.

    "ready" is not readiness. The hook emits it from Boot:run/ToME:run, which
    happens well before the display() pump starts turning: on a cold start
    here the pump stayed silent for roughly a hundred seconds after "ready"
    while the window came up, and every command fired into that gap timed out
    and was deleted unread. That looks exactly like a broken bridge and is
    not one -- five phantom failures in a row, which is the class of result
    this harness exists to prevent.

    So readiness is proved by a round trip, not by a log line. PumpTimeoutSec
    covers the wait for the first frame; it is generous on purpose, because
    the cost of being wrong is a fake failure.
#>
function Start-Game {
    param(
        [int]$TimeoutSec = 60,
        [int]$PumpTimeoutSec = 240
    )
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
    if (-not $r.Matched) {
        Write-Host "[harness] NO BRIDGE after ${TimeoutSec}s"
        Show-LoadDiagnostics -Seen $r.Seen
        return [pscustomobject]@{ Pid = $p.Id; Ready = $false; Hook = $false; PumpSec = $null }
    }
    Write-Host "[harness] hook ran: $($r.Line)"

    $t0 = Get-Date
    $probe = Invoke-Bridge -Lua 'return "pong"' -TimeoutSec $PumpTimeoutSec
    $elapsed = [math]::Round(((Get-Date) - $t0).TotalSeconds, 1)
    if ($probe.Status -eq 'OK') {
        Write-Host "[harness] pump live after ${elapsed}s"
        return [pscustomobject]@{ Pid = $p.Id; Ready = $true; Hook = $true; PumpSec = $elapsed }
    }

    Write-Host "[harness] BRIDGE HOOK RAN BUT PUMP NEVER TURNED (${elapsed}s, status=$($probe.Status))"
    Show-LoadDiagnostics
    [pscustomobject]@{ Pid = $p.Id; Ready = $false; Hook = $true; PumpSec = $elapsed }
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
