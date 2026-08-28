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
# TOME_HOME names the PARENT the engine is given as --home; it appends
# T-Engine\4.0 itself. Set it, with TOME_DIR pointing at a slot game directory,
# to run several games at once on one machine -- each gets its own saves,
# bridge channel and te4_log.txt. The log is the reason a slot needs its own
# game directory at all: the engine writes it to the working directory, and
# bootstraps its engine code from there too, so the two cannot be separated
# (#189).
if ($env:TOME_HOME) { $script:TomeHome = Join-Path $env:TOME_HOME 'T-Engine\4.0' }
else { $script:TomeHome = Join-Path $env:USERPROFILE 'T-Engine\4.0' }
$script:BridgeDir = Join-Path $script:TomeHome 'skoobot-bridge'
$script:SaveRoot  = Join-Path $script:TomeHome 'tome\save'

# Whose is the game right now, and which checkout would it load? One live
# host owns the game at a time (harness-lease.ps1, #60). Two sessions used to
# kill each other's games through Stop-Game and read the result as a flake.
$script:RepoRoot  = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'harness-lease.ps1')

$script:Seq       = 0
$script:GamePid   = $null
$script:LogOffset = 0
$script:LastResolution = $null   # last "[DO RESIZE] Got: WxH" seen; a change taints (Invoke-Bridge)
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
    if (Save-GameLog -Dest (Join-Path $archive "te4_log-$stamp.txt")) {
        Write-Host "[harness] full log archived to $archive\te4_log-$stamp.txt"
    }
}

function Save-GameLog {
    <#
        Copy te4_log.txt somewhere it will survive. The engine opens that file
        in 'w' mode, so the NEXT launch truncates it -- in a sweep that means
        the following class destroys the only record of the one that failed.
        Callers that have just lost a run should take a copy immediately.
    #>
    param([Parameter(Mandatory)][string]$Dest)
    if (-not (Test-Path $script:LogPath)) { return $false }
    try {
        # A live game still holds it open for writing, so read it shared. A
        # dead one does not, and the same call works either way.
        $fs = [System.IO.File]::Open($script:LogPath, 'Open', 'Read', 'ReadWrite')
        try {
            $out = [System.IO.File]::Create($Dest)
            try { $fs.CopyTo($out) } finally { $out.Dispose() }
        } finally { $fs.Dispose() }
        return $true
    } catch {
        Write-Host "[harness] could not archive the log: $($_.Exception.Message)"
        return $false
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

<#
    The directory a save named $Name actually lives in. The engine derives it
    as `name:gsub("[^a-zA-Z0-9_-.]", "_"):lower()` (engine/Savefile.lua:46),
    and in a Lua set `_-.` is an empty range, so a hyphen and a dot become
    underscores too: `fixture-berserker` is loaded by that name and saved
    under `fixture_berserker`. Loading is unaffected -- Module:instanciate
    applies the same rule -- but anything that reads the directory must apply
    it as well, or a fixture with a hyphen in its name is reported as having
    no save at all (#27).
#>
function Get-ResultSlug {
    <#
        The file-name form of a class or race: lowercase, non-alphanumerics
        collapsed to a single hyphen. Result files, save names and anything
        that has to find them again all depend on agreeing about this, so it
        lives here rather than in each caller.
    #>
    param([Parameter(Mandatory)][string]$Name)
    return (($Name -replace '[^A-Za-z0-9]+', '-').Trim('-')).ToLower()
}

function Get-SaveDirName {
    param([Parameter(Mandatory)][string]$Name)
    # TRUNCATED TO 25 FIRST, because the engine does: mod/class/Game.lua:204
    #   name = name:removeColorCodes():gsub("#", " "):sub(1, 25)
    #   self.save_name = name
    # and the save directory follows save_name, not the name that was asked for.
    #
    # Without this a long name births perfectly, saves perfectly, and the
    # harness then looks for the file in a directory that never existed. It cost
    # Cultist of Entropy every sweep it has ever been in -- eight of them,
    # reported as UNBIRTHABLE with a valid game.teag sitting on disk the whole
    # time under sweep_cornac_cultist_of_e -- and Temporal Warden one.
    $short = if ($Name.Length -gt 25) { $Name.Substring(0, 25) } else { $Name }
    ([regex]::Replace($short, '[^a-zA-Z0-9_]', '_')).ToLowerInvariant()
}

function Get-SaveDescPath {
    param([Parameter(Mandatory)][string]$Name)
    Join-Path $script:SaveRoot "$(Get-SaveDirName -Name $Name)\desc.lua"
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

    Unless the game is someone else's. While another live host holds the
    lease this does nothing, because "every game process" would be THEIR run
    -- killing it produced two phantom CRASHED launches on 2026-08-22 (#60).
    With no live holder it still reaps everything, orphans included.
#>
function Wait-ProcessGone {
    <#
        Stop-Process -Force is ASYNCHRONOUS: it returns before the process has
        exited, so a caller that checks immediately sees the game still alive.
        The old kill-by-name teardown hid this behind a wait loop; splitting the
        intents (#217) left teardown without one, and test-occupancy's
        "reaps the orphan" check caught it in the first run.

        Waits on the NAMED pids, never on "no t-engine anywhere" -- in slot mode
        the siblings are supposed to still be running.
    #>
    param([int[]]$Ids, [int]$TimeoutSec = 30)
    if (-not $Ids -or $Ids.Count -eq 0) { return $true }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
        $alive = @($Ids | Where-Object { Get-Process -Id $_ -ErrorAction Ignore })
        if ($alive.Count -eq 0) { return $true }
        Start-Sleep -Milliseconds 25
    }
    Write-Host "[harness] WARNING: pid(s) $($Ids -join ',') still alive ${TimeoutSec}s after being killed"
    return $false
}

function Invoke-LedgerReap {
    <#
        Kill every game a home's launch ledger still accounts for, and clear
        the ledger. Reaps by IDENTITY -- pid AND launch time -- so a recycled
        pid belonging to someone else is never a match, and only t-engine is
        ever killed.

        The one killing mechanism for teardown, shared by the serial path here
        and by the slot scheduler's Invoke-SlotReap. A second hand-written copy
        is the two-places drift that cost Cultist of Entropy eight sweeps
        (#121, #217).
    #>
    [CmdletBinding()]
    param(
        [string]$BridgeDir,
        # Clear the ledger after reaping. Only a caller that ACCOUNTS for the
        # launches should: the scheduler at a class end, or Clear-Stage, which
        # owns the machine. A teardown must NOT -- every child process
        # (new-character, read-save-zone, soak) tears down inside one class, and
        # if each wiped the record the supervisor's count would read 0 and
        # #196's "the ledger itself is broken" alarm, and #203's wording built
        # on it, would both lose their evidence. Caught by a slot run reporting
        # `0 launch(es)` where it had always reported 3 (#217).
        [switch]$Clear
    )

    if (-not $BridgeDir) { $BridgeDir = $script:BridgeDir }
    $ledger = Join-Path $BridgeDir 'launched.log'
    $entries = @()
    if (Test-Path $ledger) {
        $entries = @(Get-Content $ledger -ErrorAction Ignore | Where-Object { $_.Trim() })
    }
    $reaped = 0
    $killed = @()
    foreach ($e in $entries) {
        $parts = "$e" -split ','
        $lp = 0; try { $lp = [int]$parts[0] } catch { continue }
        $proc = Get-Process -Id $lp -ErrorAction Ignore
        if (-not $proc -or $proc.ProcessName -ne 't-engine') { continue }
        if ($parts.Count -ge 2) {
            try {
                $ls = [datetime]::Parse($parts[1], $null, [Globalization.DateTimeStyles]::RoundtripKind)
                if ([math]::Abs(($proc.StartTime - $ls).TotalSeconds) -gt 5) { continue }
            } catch { continue }
        }
        Stop-Process -Id $lp -Force -ErrorAction Ignore
        $killed += $lp
        $reaped++
    }
    if ($Clear -and (Test-Path $ledger)) { Remove-Item $ledger -Force -ErrorAction Ignore }
    $null = Wait-ProcessGone -Ids $killed
    return [pscustomobject]@{ Launches = $entries.Count; Reaped = $reaped }
}

function Clear-Stage {
    <#
        Kill every t-engine on the machine, by name.

        This is the janitor #196 established the harness had relied on for its
        whole life: a game some failure path forgot to stop was cleaned up by
        the next launch, invisibly. It is correct for a caller that OWNS the
        machine -- which is Start-Game, before it launches, and nothing else by
        default.

        It is NOT correct as a teardown, and used to be: Stop-Game did this on
        every exit path, so a read-only summarize wiped an eight-slot sweep
        (#215). Stop-Game now stops what this host started; the dangerous verb
        lives here, where its callers can be counted.

        NOT SAFE beside slot sweeps. Slot leases live in each slot's own home
        and are invisible from here, so this cannot refuse on their behalf --
        #213's hazard-4 design is what would let it, and is not built. Until
        then the count below is the only warning: a non-zero one in a machine
        running slots means this has just killed somebody's work.
    #>
    [CmdletBinding()]
    param()
    # The stage is clear, so the record starts fresh too.
    $ledger = Join-Path $script:BridgeDir 'launched.log'
    if (Test-Path $ledger) { Remove-Item $ledger -Force -ErrorAction Ignore }
    $victims = @(Get-Process -Name 't-engine' -ErrorAction Ignore)
    if ($victims.Count -gt 0) {
        $victims | ForEach-Object { Stop-Process -Id $_.Id -Force -ErrorAction Ignore }
        Write-Host "[harness] cleared the stage: killed $($victims.Count) t-engine process(es) by name"
    }
    $script:GamePid = $null

    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt 30) {
        if (-not (Get-Process -Name 't-engine' -ErrorAction Ignore)) { return }
        Start-Sleep -Milliseconds 25
    }
    Write-Host '[harness] WARNING: a t-engine process is still alive 30s after being killed'
}

function Stop-Game {
    <#
        Stop what THIS host started: its own game by pid, plus anything its own
        home's launch ledger still accounts for. Never by name -- see
        Clear-Stage (#215, #217).
    #>
    $foreign = Get-ForeignLease
    if ($foreign) {
        Write-Host "[harness] not stopping the game: it belongs to $(Format-Lease $foreign)"
        $script:GamePid = $null
        return
    }
    $mine = @()
    if ($script:GamePid) {
        Stop-Process -Id $script:GamePid -Force -ErrorAction Ignore
        $mine += $script:GamePid
    }
    $script:GamePid = $null
    # The ledger catches what the pid alone cannot: a launch whose Stop-Game
    # never ran. In serial mode the lease guarantees one live host at a time,
    # so this home's entries are ours to reap.
    $null = Invoke-LedgerReap -BridgeDir $script:BridgeDir
    $null = Wait-ProcessGone -Ids $mine
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

    Two pre-flight refusals, both thrown rather than returned, because neither
    is a launch result: the game is another live host's (the lease), or the
    junctions would make it load a different checkout than this harness
    belongs to. Each message says what to do.
#>
function Start-Game {
    param(
        [int]$TimeoutSec = 60,
        [int]$PumpTimeoutSec = 240
    )
    $null = Enter-HarnessLease
    Assert-JunctionsOwned -GameDir $script:GameDir
    # The ONE janitor call site: this host is about to own the game, so a
    # leftover from someone's forgotten failure path is exactly what should go
    # (#196). Every other path wants Stop-Game, which stops only its own.
    # Each game seeds its own baseline from its launch resize; carrying the
    # previous game's size over would compare across processes (#221).
    $script:LastResolution = $null
    if ($env:TOME_HOME) { Stop-Game } else { Clear-Stage }
    if (-not (Test-Path $script:BridgeDir)) { New-Item -ItemType Directory -Path $script:BridgeDir | Out-Null }
    Get-ChildItem $script:BridgeDir -Filter 'cmd-*' -ErrorAction Ignore | Remove-Item -Force
    Clear-GameLog
    $script:Seq = 0
    $launchArgs = @('--flush-stdout', '--no-steam', '--no-web')
    if ($env:TOME_HOME) { $launchArgs += @('--home', $env:TOME_HOME) }
    $p = Start-Process -FilePath $script:GameExe `
                       -ArgumentList $launchArgs `
                       -WorkingDirectory $script:GameDir -PassThru
    $script:GamePid = $p.Id
    $null = Enter-HarnessLease -GamePid $p.Id
    Write-Host "[harness] launched pid=$($p.Id)"
    # #196: record every launch in a per-home ledger, so a supervisor can reap
    # orphans by identity (pid AND start time -- a recycled pid will not match).
    # The lease cannot serve this purpose: it records only the LATEST launch,
    # and the zone reader never even reached a finally -- the caller's
    # `Select-Object -First 1` pipeline killed it mid-flight.
    try {
        $lst = $(try { $p.StartTime.ToString('o') } catch { (Get-Date).ToString('o') })
        Add-Content -Path (Join-Path $script:BridgeDir 'launched.log') -Encoding ascii -Value "$($p.Id),$lst"
    } catch { }

    # Anchor to THIS process's output before believing anything in the log.
    # `[CPU] Detected N CPUs` is the engine's first line, so seeing it means we
    # are reading the new run. Belt and braces with Clear-GameLog: the old log
    # carried this banner too, so neither check alone is sufficient.
    $b = Wait-LogLine -Pattern '^\[CPU\] Detected' -TimeoutSec 60
    $null = Update-InterferenceScan -Seen $b.Seen -Setup
    if (-not $b.Matched) {
        Write-Host '[harness] the engine never printed its launch banner'
        Show-LoadDiagnostics -Seen $b.Seen
        return [pscustomobject]@{ Pid = $p.Id; Ready = $false; Hook = $false; PumpSec = $null }
    }

    $r = Wait-LogLine -Pattern '\[BRIDGE\] ready' -TimeoutSec $TimeoutSec
    $null = Update-InterferenceScan -Seen $r.Seen -Setup
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

    -Attempts retries the launch chain -- menu bridge, reboot, tome-tier
    bridge, tome-tier pump -- when it fails on infrastructure with the game
    still alive. The main menu's demo level has a long tail (design-harness.md
    section 4) that occasionally outlasts even the 240 s pump timeout, and a
    second launch is cheaper than a diagnosis every time. Every retry is
    printed and the result carries Attempt, so a pass on the second try is
    visible as one. A game that DIED is not retried: with the lease in place
    that is a real crash or a human, and hiding it would be the false-pass
    class this harness exists to prevent (#60).
#>
function Load-Save {
    param(
        [Parameter(Mandatory)][string]$Name,
        [int]$TimeoutSec = 300,
        [switch]$SkipAddonCheck,
        [int]$Attempts = 2
    )

    if (-not $SkipAddonCheck) {
        if (-not (Assert-SaveAddons -Name $Name)) {
            return [pscustomobject]@{ Ready = $false; Reason = 'save addon list'; Attempt = 0 }
        }
    }

    if ($Attempts -lt 1) { $Attempts = 1 }
    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        $r = Invoke-LoadAttempt -Name $Name -TimeoutSec $TimeoutSec
        $r | Add-Member -NotePropertyName Attempt -NotePropertyValue $attempt
        if ($r.Ready) {
            if ($attempt -gt 1) { Write-Host "[harness] loaded on attempt $attempt of $Attempts" }
            return $r
        }
        if (-not $r.Retryable -or $attempt -ge $Attempts) { return $r }
        Write-Host "[harness] launch attempt $attempt of $Attempts failed ($($r.Reason)); retrying"
    }
}

# One pass through the launch chain. Retryable means the failure was the
# infrastructure's and the game was still alive to prove it -- a process that
# died is reported, not relaunched.
function Invoke-LoadAttempt {
    param(
        [Parameter(Mandatory)][string]$Name,
        [int]$TimeoutSec = 300
    )

    $g = Start-Game
    if (-not $g.Ready) {
        return [pscustomobject]@{ Ready = $false; Reason = 'no bridge at menu'; Retryable = (Test-GameAlive) }
    }

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
    $null = Update-InterferenceScan -Seen $boot.Seen -Setup
    if (-not $boot.Matched) {
        Write-Host '[harness] module never rebooted'
        Show-LoadDiagnostics -Seen $boot.Seen
        $alive = Test-GameAlive
        Stop-Game
        return [pscustomobject]@{ Ready = $false; Reason = 'no reboot'; Retryable = $alive }
    }
    Clear-BridgeQueue

    $w = Wait-LogLine -Pattern '\[BRIDGE\] ready tier=tome' -TimeoutSec $TimeoutSec
    $null = Update-InterferenceScan -Seen $w.Seen -Setup
    if (-not $w.Matched) {
        Write-Host "[harness] tome-tier bridge never came up after ${TimeoutSec}s"
        Show-LoadDiagnostics -Seen $w.Seen
        $alive = Test-GameAlive
        Stop-Game
        return [pscustomobject]@{ Ready = $false; Reason = 'no tome tier'; Retryable = $alive }
    }

    # Same lesson as Start-Game: the hook line is not the pump.
    $probe = Invoke-Bridge -Lua 'return "pong"' -TimeoutSec 240
    if ($probe.Status -ne 'OK') {
        Write-Host "[harness] tome-tier pump never turned (status=$($probe.Status))"
        Show-LoadDiagnostics
        Stop-Game
        return [pscustomobject]@{ Ready = $false; Reason = 'no tome pump'; Retryable = ($probe.Status -ne 'CRASHED') }
    }

    $intact = Assert-NoAddonDropped -Seen $w.Seen
    $loaded = (Invoke-Bridge -Lua 'return bridge.addons()' -TimeoutSec 30).Result
    Write-Host "[harness] loaded addons: $loaded"

    <#
        #127: autosaves must never land on the fixture.

        The game autosaves on every level change, under game.save_name. So a
        scenario that drives the bot through one WRITES THE SAVE IT BORROWED,
        and the next scenario in the library run loads a fixture that has
        moved. That is #127's open question -- "why does a library run leave
        the level explored for a later scenario, when every scenario loads the
        save fresh and no scenario writes it" -- and the answer is that no
        scenario writes it *deliberately*: nothing here calls saveGame. The
        writes are the engine's own.

        Only soak.ps1 and scenario-first-run.ps1 ever defended against it, each
        with its own copy of this line. The other thirty-five did not.

        The evidence is on disk rather than inferred: save/fixture_berserker
        holds a zero-byte zone-trollmire.teaz.tmp stamped in the middle of a
        harness run, and completed zone-*.teaz files exist in other saves -- so
        the write is real, it is sometimes interrupted by Stop-Game killing the
        process mid-save, and when it is NOT interrupted the level state
        persists between processes.

        This is the likeliest common cause of the whole flaky-fixture family
        (#122, #124, #127, #176): four scenarios that build a situation and
        then measure, all failing on the state they happen to get.

        One place, because every scenario reaches the game through here.
    #>
    $scratch = 'scenario-scratch'
    $sn = Invoke-Bridge -TimeoutSec 30 -Lua "game.save_name = '$scratch' return tostring(game.save_name)"
    if ($sn.Status -ne 'OK' -or "$($sn.Result)" -ne $scratch) {
        # Loud, but not fatal: the scenario can still measure what it came for.
        # What is at risk is the FIXTURE, and therefore every run after this
        # one -- which is exactly the failure mode that is hard to trace back.
        Write-Host "[harness] WARNING: could not redirect autosaves off the fixture (got '$($sn.Result)')."
        Write-Host "[harness]          This run may write to save '$Name'; see #127."
    }

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

<#
    The ONE interference scan. Every window that reads the game log goes
    through this, so the resize baseline does not depend on which window
    happened to see the first resize (#221).

    Focus changes are logged but do NOT taint: they alter no game state and the
    launch emits one. Keys and clicks (the devbridge emits those only for
    non-injected input) always taint. A resize taints only when it CHANGES the
    size from the last seen -- the engine re-asserts its own configured size at
    launch and at every module reboot, and a whole run was once flagged by that.

    -Setup marks the launch and load windows: they seed the baseline and are
    recorded, but do not void a measurement that has not begun. Returns the
    lines that taint -- always empty under -Setup.
#>
function Update-InterferenceScan {
    param([string[]]$Seen, [switch]$Setup)

    $found = @($Seen | Where-Object { $_ -match '\[BRIDGE\] INTERFERE (key|mouse)' })
    foreach ($line in $Seen) {
        if ($line -match '\[DO RESIZE\] Got: (\d+)x(\d+)') {
            $size = "$($Matches[1])x$($Matches[2])"
            if ($null -ne $script:LastResolution -and $size -ne $script:LastResolution) {
                $found += $line
            }
            $script:LastResolution = $size
        }
    }

    if ($found.Count -eq 0) { return @() }
    # Recorded, never discarded: a voided measurement that cannot say what
    # voided it is not attributable (#220).
    if ($Setup) {
        $script:HarnessInterference += @($found | ForEach-Object { "setup: $_" })
        foreach ($f in $found) { Write-Host "[harness] interference during setup -- $f" }
        return @()
    }
    $script:HarnessInterference += $found
    return $found
}

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

    $interference = Update-InterferenceScan -Seen $r.Seen

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

# ---------------------------------------------------------------------------
# Assertions and result records (#27).
#
# Scenarios used to carry their own Check() and their own tally. These are
# the shared versions: each prints one PASS/FAIL line, remembers a failure
# in $script:HarnessFailures and a taint in $script:HarnessTainted, and
# returns a boolean so a scenario can still branch on it. Nothing above this
# line changed; every scenario dot-sources this file and keeps working.
# ---------------------------------------------------------------------------

$script:HarnessFailures = @()
$script:HarnessTainted  = $false
$script:HarnessInterference = @()
$script:ResultsDir      = Join-Path $script:RepoRoot 'build\results'

<#
    Every line of the game's log right now, through a shared read. The game
    holds the file open for writing, so a plain Get-Content fails. This does
    not move the harness's own read cursor: it is for asserting on what the
    engine and the bot printed, not for waiting on it.
#>
function Get-GameLogLines {
    if (-not (Test-Path $script:LogPath)) { return @() }
    $fs = [System.IO.File]::Open($script:LogPath, 'Open', 'Read', 'ReadWrite')
    try {
        $sr = New-Object System.IO.StreamReader($fs)
        $text = $sr.ReadToEnd()
    } finally { $fs.Dispose() }
    if (-not $text) { return @() }
    @($text -split "`r?`n" | Where-Object { $_ -ne '' })
}

<#
    A bridge result is good when the command ran (Status OK), nobody touched
    the machine while it did (not Tainted), and -- if -Match is given -- its
    Result matches. A taint is remembered separately from a failure because
    it voids the run rather than failing it: the scenario exits 2, and the
    runner re-runs it once.
#>
function Assert-Result {
    param(
        [Parameter(Mandatory)]$Result,
        [Parameter(Mandatory)][string]$What,
        [string]$Match
    )
    if ($Result.Tainted) {
        $script:HarnessTainted = $true
        foreach ($i in @($Result.Interference)) { Write-Host "  TAINT $What -- $i" }
    }
    $ok = ($Result.Status -eq 'OK')
    $why = ''
    if (-not $ok) {
        $why = "status=$($Result.Status)"
    } elseif ($Match -and -not ("$($Result.Result)" -match $Match)) {
        $ok = $false
        $why = "result did not match '$Match': $($Result.Result)"
    }
    if ($ok) { Write-Host "  PASS  $What" }
    else {
        Write-Host "  FAIL  $What ($why)"
        $script:HarnessFailures += "$What ($why)"
    }
    return $ok
}

<#
    A PRECONDITION, not a claim about the product.

    Most scenarios build the situation they test -- spawn an actor at a
    distance, walk the character into a door, darken a grid -- and then assert
    what the bot does about it. When the BUILDING fails, the assertions after
    it are meaningless: they measure a character that never met the thing.
    Reported as FAIL, that reads as a product defect and sends whoever is on
    the suite hunting one.

    Four scenarios have done exactly that (#122, #124, #127, #176), two of them
    in a single run on 2026-08-27, and the cost is worse than the wasted hunt:
    a red suite nobody trusts is not a gate. Anything that fails HERE exits 3,
    INCONCLUSIVE -- so a red suite always means the product.

    Use it for the situation being built. Never for what the bot then does
    about it: an INCONCLUSIVE that should have been a FAIL is a defect the
    suite will never report again.
#>
function Require-Staged {
    param(
        [Parameter(Mandatory)][string]$Tag,
        [Parameter(Mandatory)][string]$What,
        [Parameter(Mandatory)]$Ok,
        [string]$Detail
    )
    if ($Ok) { Write-Host "  STAGED $What"; return $true }
    Write-Host "  SETUP  $What -- NOT BUILT"
    if ($Detail) { Write-Host "         $Detail" }
    Write-Host "[$Tag] INCONCLUSIVE - the situation under test was not built: $What"
    Stop-Game | Out-Null
    exit 3
}

# game.turn as an integer, or -1 if the game did not answer.
function Get-GameTurn {
    $r = Invoke-Bridge -Lua 'return tostring(game.turn)' -TimeoutSec 30
    if ($r.Status -ne 'OK' -or "$($r.Result)" -notmatch '^\s*(-?\d+)') { return -1 }
    if ($r.Tainted) { $script:HarnessTainted = $true }
    return [int]$Matches[1]
}

<#
    Run a block and assert on how far game.turn moved across it. Progress is
    measured in turns, never wall-clock (docs/design-harness.md section 3):
    a click or a resize costs frames, not turns, so a turn-counted assertion
    is immune to interference by construction. game.turn counts engine
    ticks: 1000 energy to act, 100 per tick (mod/class/Game.lua:80,
    engine/GameEnergyBased.lua), so it advances by 10 per game turn at
    normal speed. -AtLeast 10 is "at least one turn"; -AtMost 0 is "no game
    time passed" (a query-mode decision).

    Returns {Before, After, Delta, Ok}; the block's own output is not
    captured, so it can print and Check as it likes.
#>
function Assert-Turns {
    param(
        [Parameter(Mandatory)][scriptblock]$Block,
        [Parameter(Mandatory)][string]$What,
        [int]$AtLeast = -1,
        [int]$AtMost = -1
    )
    $before = Get-GameTurn
    & $Block | Out-Null
    $after = Get-GameTurn
    $delta = $after - $before
    $ok = ($before -ge 0 -and $after -ge 0)
    $why = ''
    if (-not $ok) { $why = 'game.turn unreadable' }
    elseif ($AtLeast -ge 0 -and $delta -lt $AtLeast) { $ok = $false; $why = "advanced $delta, wanted at least $AtLeast" }
    elseif ($AtMost -ge 0 -and $delta -gt $AtMost)   { $ok = $false; $why = "advanced $delta, wanted at most $AtMost" }
    if ($ok) { Write-Host "  PASS  $What (game.turn $before -> $after, +$delta)" }
    else {
        Write-Host "  FAIL  $What ($why; game.turn $before -> $after)"
        $script:HarnessFailures += "$What ($why)"
    }
    [pscustomobject]@{ Before = $before; After = $after; Delta = $delta; Ok = $ok }
}

<#
    Append one JSON line for a scenario run to build/results/<yyyy-MM-dd>.jsonl.

    One line per run, never rewritten, so a day's file is the day's history:
    a re-run after a taint is a second line with attempts=2, not an edit of
    the first. build/ is gitignored, so nothing here reaches the repository;
    the file is what run-scenarios.ps1 summarises and what a person reads
    the morning after an unattended run.

    Fields: scenario, status (PASS | FAIL | TAINTED | INCONCLUSIVE | CRASHED |
    TIMEOUT | BUSY), exit, seconds, tainted, attempts, summary (the
    scenario's own verdict line), lines (the tail of its output), when.
#>
function Write-ScenarioResult {
    param(
        [Parameter(Mandatory)][string]$Scenario,
        [Parameter(Mandatory)][string]$Status,
        [int]$ExitCode = -1,
        [double]$Seconds = 0,
        [bool]$Tainted = $false,
        [int]$Attempts = 1,
        [string]$Summary = '',
        [string[]]$Lines = @(),
        [string]$Path
    )
    if (-not $Path) {
        if (-not (Test-Path $script:ResultsDir)) { New-Item -ItemType Directory -Path $script:ResultsDir -Force | Out-Null }
        $Path = Join-Path $script:ResultsDir ((Get-Date -Format 'yyyy-MM-dd') + '.jsonl')
    }
    $rec = [ordered]@{
        scenario = $Scenario
        status   = $Status
        exit     = $ExitCode
        seconds  = [math]::Round($Seconds, 1)
        tainted  = $Tainted
        attempts = $Attempts
        summary  = $Summary
        lines    = @($Lines)
        when     = (Get-Date).ToString('o')
    }
    # -Compress keeps it to one line; -Depth 3 is enough for a flat record
    # with one string array. ASCII-safe UTF-8 without a BOM, appended, so
    # the file is a valid JSON-lines stream from the first byte.
    $json = ($rec | ConvertTo-Json -Compress -Depth 3)
    [System.IO.File]::AppendAllText($Path, $json + "`n", (New-Object System.Text.UTF8Encoding($false)))
    return $Path
}
