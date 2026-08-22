<#
    SkooBot: Reclauded -- test harness.

    Drives a real ToME process from outside: launches it, sends Lua over the
    devbridge file channel, reads results back out of te4_log.txt, and reports
    human interference so a disrupted run is quarantined rather than believed.

    Dot-source it:   . .\tools\harness.ps1

    A script that dot-sources this one is run as

        powershell -ExecutionPolicy Bypass -File .\tools\<script>.ps1

    The flag is not optional: every execution-policy scope on this machine is
    Restricted, so a bare `powershell -File ...` fails with "running scripts is
    disabled on this system" before the script starts. Do not "fix" that by
    changing the machine policy.
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

<#
    Make the previous run's log unmatchable before launching the next one.

    te4_log.txt is truncated by the engine on startup, but not until it opens
    the file -- measured at ~5 ms AFTER Start-Process returns. Reset-LogCursor
    rewinds to offset 0, so a read landing inside that window sees the whole
    PREVIOUS run: its `[BRIDGE] ready`, and its `cmd-0001.lua OK`. Start-Game
    then reports a game that is ready and answering before the process has
    even opened its log.

    That is a false pass, and it fired on two of four launches spaced three
    seconds apart. Deleting the file first removes the possibility rather than
    detecting it afterwards -- the engine recreates it. If the delete fails
    (something still holds it open), fall back to parking the cursor at the
    current end of file: reads then return nothing until the engine truncates,
    at which point Read-NewLogLines' own truncation check rewinds to 0.
#>
function Clear-GameLog {
    if (-not (Test-Path $script:LogPath)) { Reset-LogCursor; return }
    try {
        Remove-Item $script:LogPath -Force -ErrorAction Stop
        Reset-LogCursor
    } catch {
        $script:LogOffset = (Get-Item $script:LogPath).Length
        $script:LogBuf.Clear()
        Write-Host "[harness] could not delete the log; parked cursor at $($script:LogOffset) bytes"
    }
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

# ---------------------------------------------------------------------------
# Savefile addon list.
#
# The engine loads only the addons a savefile records: anything else is
# dropped with one line -- "Removing addon <name>: not allowed by savefile"
# (engine/Module.lua:565-569) -- and no other symptom. A behaviour run started
# from a save that predates the product will therefore "verify" a game that
# never loaded it, and nothing in the output will say so.
#
# Two independent checks, because each catches what the other misses: read the
# descriptor before launching, and watch the log after. T-042.
# ---------------------------------------------------------------------------

# What a harness save must list to be worth measuring anything from.
$script:RequiredSaveAddons = @('skoobot_reclauded', 'skoobot_devbridge')

function Get-SaveDescPath {
    param([Parameter(Mandatory)][string]$Name)
    Join-Path $script:SaveRoot "$Name\desc.lua"
}

<#
    The addon short_names a savefile records, or $null if there is no save.
#>
function Get-SaveAddons {
    param([Parameter(Mandatory)][string]$Name)
    $desc = Get-SaveDescPath -Name $Name
    if (-not (Test-Path $desc)) { return $null }
    $text = Get-Content $desc -Raw
    if ($text -notmatch '(?s)addons\s*=\s*\{(.*?)\}') { return @() }
    $inner = $Matches[1]
    @([regex]::Matches($inner, "['""]([^'""]+)['""]") | ForEach-Object { $_.Groups[1].Value })
}

<#
    Fail loudly, before launching, if a save cannot exercise the product.
#>
function Assert-SaveAddons {
    param(
        [Parameter(Mandatory)][string]$Name,
        [string[]]$Required = $script:RequiredSaveAddons
    )
    $have = Get-SaveAddons -Name $Name
    if ($null -eq $have) {
        Write-Host "[harness] NO SAVE at $(Get-SaveDescPath -Name $Name)"
        return $false
    }
    $missing = @($Required | Where-Object { $have -notcontains $_ })
    if ($missing.Count -eq 0) {
        Write-Host "[harness] save '$Name' lists: $($have -join ', ')"
        return $true
    }
    Write-Host "[harness] SAVE '$Name' DOES NOT LIST: $($missing -join ', ')"
    Write-Host "           it lists: $($have -join ', ')"
    Write-Host '           The engine drops unlisted addons silently. Any behaviour'
    Write-Host '           measured from this save is measuring a game without them.'
    Write-Host "           Regenerate it:  powershell -ExecutionPolicy Bypass -File .\tools\new-character.ps1 -Name $Name"
    return $false
}

<#
    Did the engine drop any addon we needed? Reads whatever log lines the
    caller already drained, plus anything still unread.
#>
function Assert-NoAddonDropped {
    param(
        [string[]]$Seen,
        [string[]]$Required = $script:RequiredSaveAddons
    )
    $lines = @()
    if ($Seen) { $lines += $Seen }
    Read-NewLogLines
    while ($script:LogBuf.Count -gt 0) { $lines += $script:LogBuf.Dequeue() }

    $dropped = @()
    foreach ($l in $lines) {
        if ($l -match 'Removing addon ([\w\-]+):') {
            if ($Required -contains $Matches[1]) { $dropped += $l }
        }
    }
    if ($dropped.Count -eq 0) { return $true }
    Write-Host '[harness] ENGINE DROPPED A REQUIRED ADDON:'
    foreach ($d in $dropped) { Write-Host "           $d" }
    return $false
}

function Clear-BridgeQueue {
    Get-ChildItem $script:BridgeDir -Filter 'cmd-*' -ErrorAction Ignore | Remove-Item -Force
    $script:Seq = 0
}

<#
    Kill every game process, and WAIT until they are actually gone.

    Stop-Process -Force returns as soon as the kill is requested, not when the
    process has exited: measured here at 6 ms to return with the process still
    alive, and 77 ms until it really went away. Start-Game calls this and then
    launches immediately, so without the wait a second engine can start while
    the first still holds the GL context, the audio device and te4_log.txt --
    two instances at once, which is the one thing this harness must never do
    (docs/design-harness.md; the bridge directory is shared).
#>
function Stop-Game {
    Get-Process -Name 't-engine' -ErrorAction Ignore | ForEach-Object { Stop-Process -Id $_.Id -Force }
    $script:GamePid = $null

    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt 30) {
        if (-not (Get-Process -Name 't-engine' -ErrorAction Ignore)) { return }
        Start-Sleep -Milliseconds 25
    }
    Write-Host '[harness] WARNING: a t-engine process is still alive 30s after being killed'
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
    Clear-GameLog
    $script:Seq = 0
    $p = Start-Process -FilePath $script:GameExe `
                       -ArgumentList '--flush-stdout','--no-steam','--no-web' `
                       -WorkingDirectory $script:GameDir -PassThru
    $script:GamePid = $p.Id
    Write-Host "[harness] launched pid=$($p.Id)"

    # Anchor to THIS process's output before believing anything in the log.
    # `[CPU] Detected N CPUs` is the engine's first line, so seeing it means we
    # are reading the new run. Belt and braces with Clear-GameLog: the old log
    # carried this banner too, so neither check alone is sufficient.
    $b = Wait-LogLine -Pattern '^\[CPU\] Detected' -TimeoutSec 60
    if (-not $b.Matched) {
        Write-Host '[harness] the engine never printed its launch banner'
        Show-LoadDiagnostics -Seen $b.Seen
        return [pscustomobject]@{ Pid = $p.Id; Ready = $false; Hook = $false; PumpSec = $null }
    }

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
    Load a named savefile and hand back a live tome-tier bridge.

    Minimal on purpose. T-044 owns the regression-suite save loader --
    fixtures, result records, taint handling. This is only what T-042 needs to
    prove an addon set, and what a single T-071 scenario needs to start from a
    character instead of spending fifteen minutes making one.

    -SkipAddonCheck runs it anyway against a save known to be missing the
    product, which is how the detector itself gets tested.
#>
function Load-Save {
    param(
        [Parameter(Mandatory)][string]$Name,
        [int]$TimeoutSec = 300,
        [switch]$SkipAddonCheck
    )

    if (-not $SkipAddonCheck) {
        if (-not (Assert-SaveAddons -Name $Name)) {
            return [pscustomobject]@{ Ready = $false; Reason = 'save addon list' }
        }
    }

    $g = Start-Game
    if (-not $g.Ready) { return [pscustomobject]@{ Ready = $false; Reason = 'no bridge at menu' } }

    # instanciate() reboots the Lua state into the module, so this command
    # never returns -- fire and forget, then watch the log.
    $lua = @"
local Module = require "engine.Module"
local mod
for i, entry in ipairs(Module:listModules(true)) do
  for j, m in ipairs(entry.versions) do
    if m.short_name == "tome" and not m.is_boot and not mod then mod = m end
  end
end
if not mod then return "tome module not found" end
Module:instanciate(mod, "$Name", false, false)
return "loading"
"@
    $null = Invoke-Bridge -NoWait -Lua $lua
    Write-Host "[harness] loading save '$Name'"

    # The reboot resets the bridge's sequence gate to zero, so the command
    # file that triggered it would be claimed a second time by the new tier
    # and reboot again, forever. Clear the queue the moment the reboot starts.
    $boot = Wait-LogLine -Pattern '\[MODULE\] booting module version\s+tome' -TimeoutSec 60
    if (-not $boot.Matched) {
        Write-Host '[harness] module never rebooted'
        Show-LoadDiagnostics -Seen $boot.Seen
        Stop-Game
        return [pscustomobject]@{ Ready = $false; Reason = 'no reboot' }
    }
    Clear-BridgeQueue

    $w = Wait-LogLine -Pattern '\[BRIDGE\] ready tier=tome' -TimeoutSec $TimeoutSec
    if (-not $w.Matched) {
        Write-Host "[harness] tome-tier bridge never came up after ${TimeoutSec}s"
        Show-LoadDiagnostics -Seen $w.Seen
        Stop-Game
        return [pscustomobject]@{ Ready = $false; Reason = 'no tome tier' }
    }

    # Same lesson as Start-Game: the hook line is not the pump.
    $probe = Invoke-Bridge -Lua 'return "pong"' -TimeoutSec 240
    if ($probe.Status -ne 'OK') {
        Write-Host "[harness] tome-tier pump never turned (status=$($probe.Status))"
        Show-LoadDiagnostics
        Stop-Game
        return [pscustomobject]@{ Ready = $false; Reason = 'no tome pump' }
    }

    $intact = Assert-NoAddonDropped -Seen $w.Seen
    $loaded = (Invoke-Bridge -Lua 'return bridge.addons()' -TimeoutSec 30).Result
    Write-Host "[harness] loaded addons: $loaded"

    [pscustomobject]@{
        Ready       = $true
        AddonsIntact = $intact
        Addons      = $loaded
        Reason      = $null
    }
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
