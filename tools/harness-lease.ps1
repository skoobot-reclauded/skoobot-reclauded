<#
    Harness lease: one live host owns the game at a time.

    The game install is a single resource -- one t-engine process, one
    te4_log.txt, one bridge directory, three junctions that point at exactly
    one checkout -- and Stop-Game kills every t-engine it can see. Two
    sessions driving scenarios at once therefore void each other. On
    2026-08-22 both `tome-tier pump never turned` failures were status=CRASHED:
    the game process killed mid-load by the other session's Start-Game, and
    read as a launch flake (#60).

    The lease is a small JSON file in the bridge directory naming the host
    process that owns the game right now:

        { host, root, game, since }

        host    PID of the PowerShell process that called Start-Game
        root    the checkout whose harness.ps1 that process is running
        game    PID of the t-engine it launched, once known
        since   when the lease was taken, ISO 8601

    A lease is LIVE while its host process is alive and was started before
    the lease was written, so a reused PID cannot resurrect a dead lease. A
    dead host's lease is stale and is simply taken over: nothing has to clean
    up after a crashed run.

    The lease ends when the host EXITS, not when Stop-Game runs. That is
    deliberate: clean-build.ps1 restores the junctions after stopping the
    game, and that has to happen under the lease too. Since every harness run
    here is its own `powershell -File` process, "until the host exits" means
    "for the duration of the scenario", which is the right unit -- two
    sessions interleave at scenario granularity.

    A child process inherits its ancestor's lease through the environment
    (SKOOBOT_HARNESS_HOST), so clean-build.ps1 can run setup-dev.ps1 as a
    child without being refused by its own lease.

    Dot-sourced by harness.ps1 and setup-dev.ps1. Nothing here launches or
    kills anything; it only answers "whose is the game right now?".
#>

$script:LeasePath = Join-Path $env:USERPROFILE 'T-Engine\4.0\skoobot-bridge\harness.lock'
$script:LeaseRoot = Split-Path -Parent $PSScriptRoot

<#
    The lease on disk, or $null if there is none or it is unreadable. A
    garbled file is treated as absent rather than fatal: the worst outcome of
    that is the pre-lease behaviour, and a file nobody can parse is nobody's.
#>
function Get-HarnessLease {
    if (-not (Test-Path $script:LeasePath)) { return $null }
    try {
        $raw = Get-Content $script:LeasePath -Raw -ErrorAction Stop
        if (-not $raw -or -not $raw.Trim()) { return $null }
        $l = $raw | ConvertFrom-Json
        $null = [int]$l.host
        return $l
    } catch { return $null }
}

# Alive, and started before the lease was written.
function Test-LeaseLive($lease) {
    if ($null -eq $lease) { return $false }
    $p = Get-Process -Id ([int]$lease.host) -ErrorAction Ignore
    if (-not $p) { return $false }
    try {
        $since = [datetime]::Parse($lease.since, $null, [Globalization.DateTimeStyles]::RoundtripKind)
        if ($p.StartTime -gt $since.AddSeconds(1)) { return $false }   # the PID was reused
    } catch { }
    return $true
}

# Ours: this process, or an ancestor whose lease we inherited.
function Test-LeaseMine($lease) {
    if ($null -eq $lease) { return $false }
    $h = [int]$lease.host
    if ($h -eq $PID) { return $true }
    if ($env:SKOOBOT_HARNESS_HOST -and $h -eq [int]$env:SKOOBOT_HARNESS_HOST) { return $true }
    return $false
}

# The live lease held by some OTHER host, or $null.
function Get-ForeignLease {
    $l = Get-HarnessLease
    if ($null -eq $l) { return $null }
    if (Test-LeaseMine $l) { return $null }
    if (-not (Test-LeaseLive $l)) { return $null }
    return $l
}

function Format-Lease($lease) {
    "$($lease.root) (host pid $($lease.host), since $($lease.since))"
}

<#
    Take the lease, or throw if another live host holds it. Re-entrant for the
    holder and its children: call it again with -GamePid once the game is
    launched, and the holder stays whoever took the lease first.
#>
function Enter-HarnessLease {
    param([int]$GamePid = 0)
    $foreign = Get-ForeignLease
    if ($foreign) {
        throw "[harness] IN USE by $(Format-Lease $foreign) -- wait for it or work on something else; never kill t-engine by hand"
    }
    $l = Get-HarnessLease
    if ($l -and (Test-LeaseMine $l) -and (Test-LeaseLive $l)) {
        $owner = [int]$l.host; $since = $l.since
    } else {
        $owner = $PID; $since = (Get-Date).ToString('o')
    }
    $dir = Split-Path -Parent $script:LeasePath
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $game = $null
    if ($GamePid) { $game = $GamePid }
    $obj = [ordered]@{ host = $owner; root = $script:LeaseRoot; game = $game; since = $since }
    ($obj | ConvertTo-Json -Compress) | Set-Content -Path $script:LeasePath -Encoding utf8
    $env:SKOOBOT_HARNESS_HOST = "$owner"
    return $obj
}

<#
    Release explicitly. Not needed in the normal case -- a lease dies with its
    host -- but a long-lived interactive host that is done with the game can
    hand it back without exiting.
#>
function Exit-HarnessLease {
    $l = Get-HarnessLease
    if ($l -and (Test-LeaseMine $l)) { Remove-Item $script:LeasePath -Force -ErrorAction Ignore }
    if ($env:SKOOBOT_HARNESS_HOST -eq "$PID") { $env:SKOOBOT_HARNESS_HOST = $null }
}

# ---------------------------------------------------------------------------
# Which checkout would the game actually load?
#
# setup-dev.ps1 re-points the three junctions to whichever checkout runs it,
# which is how a worktree becomes the live one. Nothing used to check that
# the checkout LAUNCHING the game was the one the junctions pointed at, so a
# scenario could silently measure another checkout's src/ (#60).
# ---------------------------------------------------------------------------

function Get-LinkTarget($path) {
    $item = Get-Item -LiteralPath $path -Force -ErrorAction Ignore
    if (-not $item) { return $null }
    if (-not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { return '<not-a-link>' }
    if ($item.Target) { return @($item.Target)[0] }
    return '<unknown>'
}

<#
    Every development junction that EXISTS must point into this checkout.
    An absent one is not an error: that is clean-build's state for the
    product, and the state of a machine that has not run setup-dev yet.
    Throws, with the command that fixes it.
#>
function Assert-JunctionsOwned {
    param([Parameter(Mandatory)][string]$GameDir)
    $addons = Join-Path $GameDir 'game\addons'
    $expect = [ordered]@{
        'tome-skoobot_reclauded' = (Join-Path $script:LeaseRoot 'src')
        'tome-skoobot-devbridge' = (Join-Path $script:LeaseRoot 'tools\devbridge')
        'boot-skoobot-devbridge' = (Join-Path $script:LeaseRoot 'tools\devbridge-boot')
    }
    $wrong = @()
    foreach ($name in $expect.Keys) {
        $actual = Get-LinkTarget (Join-Path $addons $name)
        if ($null -eq $actual) { continue }
        if ($actual -eq '<not-a-link>') { $wrong += "$name is a real directory"; continue }
        if ($actual -eq '<unknown>')    { $wrong += "$name has an unreadable target"; continue }
        $a = [IO.Path]::GetFullPath($actual).TrimEnd('\')
        $e = [IO.Path]::GetFullPath($expect[$name]).TrimEnd('\')
        if ($a -ine $e) { $wrong += "$name -> $actual" }
    }
    if ($wrong.Count -eq 0) { return }
    $fix = Join-Path $script:LeaseRoot 'tools\setup-dev.ps1'
    throw ("[harness] JUNCTIONS POINT AT ANOTHER CHECKOUT: " + ($wrong -join '; ') +
           " -- this harness is $script:LeaseRoot. Fix: powershell -ExecutionPolicy Bypass -File `"$fix`"")
}
