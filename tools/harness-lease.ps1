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
    Take the lease, waiting for another live host to finish instead of
    failing at once. Returns the lease; throws only if the wait runs out.

    Enter-HarnessLease refuses the moment somebody else holds it, which is
    right for a scenario -- one of twenty, each wanting the game for about
    fifteen seconds. It is wrong for a host that wants the game for minutes.
    On the night of 2026-08-23 a soak polling every 90 s was starved for over
    an hour by three lanes running the scenario library: a 90 s retry almost
    always lands INSIDE somebody's lease, and the gap between one library
    child and the next is a second or two wide, so the poll had to be lucky
    twice over. It got in on attempt 11, and only because the libraries ran
    out (#83).

    So: poll in seconds, not minutes, and jitter, so two waiters cannot
    synchronise on the same gap forever.

    This does NOT make the lease fair. A waiter can still lose a gap to a
    host that arrived later; it only makes a long-run host likely to win one
    rather than unlikely. The waiting list that would make "first come" true
    is option 2 on #83 and is deliberately not built -- the owner chose the
    cheap pair (jitter here, one lease per run in the callers).
#>
function Wait-HarnessLease {
    param(
        [int]$TimeoutSec = 1800,
        [int]$MinWaitSec = 5,
        [int]$MaxWaitSec = 10,
        [int]$GamePid = 0,
        [string]$Label = 'harness'
    )
    $deadline  = (Get-Date).AddSeconds($TimeoutSec)
    $announced = $false
    $lastSaid  = Get-Date
    $held      = 'another host'
    while ($true) {
        try {
            return Enter-HarnessLease -GamePid $GamePid
        } catch {
            # Only a foreign lease is worth waiting out; anything else (an
            # unwritable lease directory, say) is a real failure. Decide on
            # the message, not on a fresh Get-ForeignLease: the holder can
            # exit between the refusal and the question, and rethrowing
            # because the game just became free would be absurd.
            if ($_.Exception.Message -notmatch 'IN USE') { throw }
            $foreign = Get-ForeignLease
            if ($foreign) { $held = Format-Lease $foreign }
            if (-not $announced) {
                $budget = if ($TimeoutSec -ge 120) { "$([math]::Round($TimeoutSec / 60)) min" } else { "$TimeoutSec s" }
                Write-Host "[$Label] the game is held by $held; waiting up to $budget"
                $announced = $true; $lastSaid = Get-Date
            } elseif (((Get-Date) - $lastSaid).TotalSeconds -ge 60) {
                Write-Host "[$Label] still waiting for $held"
                $lastSaid = Get-Date
            }
            if ((Get-Date) -ge $deadline) {
                throw "[$Label] the game stayed in use for $TimeoutSec s -- last held by $held"
            }
            # -Maximum is exclusive for integers, so +1 to include MaxWaitSec.
            Start-Sleep -Seconds (Get-Random -Minimum $MinWaitSec -Maximum ($MaxWaitSec + 1))
        }
    }
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
# What will the game actually EXECUTE? (#175)
#
# Two things this deliberately does NOT do.
#
# It does not read the current directory. Pointing the junctions at another
# checkout is routine -- every scenario run does it, and #173's A/B did it on
# purpose to run main's product against a worktree's harness -- so the question
# is answered from the JUNCTION and nowhere else.
#
# And it does not report the whole repository's state. The game loads exactly
# three paths, and work elsewhere in the same checkout -- docs, other tools, a
# second session's edits -- changes neither what runs nor what a sweep measures.
# Reporting those as drift would flag every sweep as unattributable and teach
# everyone to ignore the flag.
#
# So the identity is the TREE of each loaded path (`git rev-parse HEAD:src`),
# which moves only when that path's content moves, plus the count of
# uncommitted files WITHIN those paths. The commit is carried too, for
# provenance, but it is the trees that say whether two runs executed the same
# code.
$script:LoadedPaths = @('src', 'tools/devbridge', 'tools/devbridge-boot')

function Get-BuildStamp {
    param([string]$GameDir)
    if (-not $GameDir) { $GameDir = $script:GameDir }
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'      # git writes progress to stderr
    try {
        $stamp = [ordered]@{
            repo = ''; commit = 'unknown'; short = 'unknown'
            trees = ''; dirty = -1; dirty_elsewhere = -1; subject = ''
        }
        $link = Get-LinkTarget (Join-Path (Join-Path $GameDir 'gameddons') 'tome-skoobot_reclauded')
        $repo = $null
        if ($link -and $link -notmatch '^<') {
            $repo = Split-Path -Parent ([IO.Path]::GetFullPath($link))   # <checkout>\src -> <checkout>
        }
        if (-not $repo) { $repo = $script:LeaseRoot }
        $stamp.repo = "$repo"
        if ($repo -and (Test-Path (Join-Path $repo '.git'))) {
            try {
                $h = (& git -C $repo rev-parse HEAD)
                if ($h) { $stamp.commit = "$h".Trim(); $stamp.short = $stamp.commit.Substring(0, 7) }
                $subj = (& git -C $repo log -1 --format=%s)
                if ($subj) { $stamp.subject = "$subj".Trim() }

                $ids = @()
                foreach ($p in $script:LoadedPaths) {
                    $t = (& git -C $repo rev-parse "HEAD:$p")
                    $ids += if ($t) { "$t".Trim().Substring(0, 8) } else { '????????' }
                }
                $stamp.trees = ($ids -join '/')

                $inLoaded = @(& git -C $repo status --porcelain -- $script:LoadedPaths)
                $stamp.dirty = @($inLoaded | Where-Object { "$_".Trim() }).Count
                $all = @(& git -C $repo status --porcelain)
                $allN = @($all | Where-Object { "$_".Trim() }).Count
                $stamp.dirty_elsewhere = $allN - $stamp.dirty
            } catch { }
        }
        return $stamp
    } finally { $ErrorActionPreference = $prev }
}

function Format-BuildStamp {
    param($Stamp)
    if (-not $Stamp) { return 'build=unknown' }
    $d = if ($Stamp.dirty -gt 0) { " +$($Stamp.dirty) UNCOMMITTED in loaded paths" }
         elseif ($Stamp.dirty -eq 0) { '' } else { ' (dirty unknown)' }
    $e = if ($Stamp.dirty_elsewhere -gt 0) { " ($($Stamp.dirty_elsewhere) elsewhere, not loaded)" } else { '' }
    return ("build={0} trees={1}{2}{3} [{4}] {5}" -f
        $Stamp.short, $Stamp.trees, $d, $e, (Split-Path -Leaf $Stamp.repo), $Stamp.subject)
}

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
