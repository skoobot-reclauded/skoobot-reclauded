<#
    Run the scenario library, one scenario at a time, and record every run.

    Each tools/scenario-*.ps1 is run as its own `powershell -ExecutionPolicy
    Bypass -File` child. This runner never touches the game itself.

    The RUN holds the game lease, not each child (#83). Before that, twenty
    children took and freed twenty leases with a gap between every pair, and
    a host wanting the game for minutes -- a soak -- almost always landed
    inside one of the twenty rather than in a gap: on 2026-08-23 one was
    starved for over an hour by three lanes doing exactly this. Now the unit
    of contention is the run. Children inherit the lease through
    SKOOBOT_HARNESS_HOST and cannot be refused for IN USE. -NoRunLease
    restores the old per-child behaviour.

    Before each scenario, tools/setup-dev.ps1 is run from THIS checkout, so
    the junctions point at the tree being tested even when another worktree
    ran last. setup-dev refuses under another live host's lease, and a
    scenario refuses (IN USE / JUNCTIONS POINT AT ANOTHER CHECKOUT) when the
    game changed hands between the two; either is BUSY here, and the runner
    waits -- jittered, so two waiters cannot shadow each other -- and retries
    rather than recording a failure that is nobody's.

    Exit codes from a scenario, and what the runner does with them:

        0  PASS
        1  FAIL
        2  TAINTED       a human touched the machine mid-run: the result is
                         void, never recorded as a verdict. Re-run ONCE
                         (-RetryOnTaint is the default; -NoRetryOnTaint to
                         record it as TAINTED and move on). A second taint is
                         recorded as TAINTED.
        3  INCONCLUSIVE  the scenario could not build its situation. Not a
                         pass and not a product failure; listed as such.
        other / killed   CRASHED or TIMEOUT

    Every run appends one JSON line to build/results/<yyyy-MM-dd>.jsonl
    (Write-ScenarioResult in harness.ps1): scenario, status, exit, seconds,
    tainted, attempts, the scenario's own verdict line, and the tail of its
    output. build/ is gitignored. The runner prints a summary table and
    exits 1 if anything FAILED, CRASHED, TIMED OUT or stayed BUSY.

    Excluded by default, and said so in the output:
        scenario-baseline-v1        needs the ORIGINAL SkooBot 0.0.12 installed
                                    and its own save (tools/scenario-baseline-v1.ps1)
        scenario-walking-skeleton   superseded by the per-issue scenarios

    Run:
        powershell -ExecutionPolicy Bypass -File .\tools\run-scenarios.ps1
        powershell -ExecutionPolicy Bypass -File .\tools\run-scenarios.ps1 -Only t012-freeze,surface
        powershell -ExecutionPolicy Bypass -File .\tools\run-scenarios.ps1 -Skip talent-screen

    Names are taken with or without the `scenario-` prefix and `.ps1` suffix.
    `powershell -File` passes "a,b" as one string, so lists are split on
    commas here.

    #27 (T-044), #4 (T-006).
#>
[CmdletBinding()]
param(
    [string[]]$Only,
    [string[]]$Skip,
    [switch]$NoRetryOnTaint,
    # Do not run setup-dev.ps1 before each scenario (the junctions are known
    # to be right and nobody else is using the game).
    [switch]$NoSetupDev,
    # Longest a single scenario may run before it is killed and recorded as
    # TIMEOUT. The harness's own timeouts add up to several minutes on a bad
    # launch, so this is generous.
    [int]$TimeoutMin = 25,
    # When the game is another host's: how many times to retry a scenario,
    # and roughly how long to wait between tries. Jittered by +/-3 s so two
    # waiters cannot synchronise on the same gap (#83). With the run-level
    # lease below this is a safety net rather than the normal path: children
    # inherit the run's lease and cannot be refused for IN USE.
    [int]$BusyRetries = 400,
    [int]$BusyWaitSec = 8,
    # How long to wait for another host to give the game up before starting
    # at all. The run then holds ONE lease from here to the last scenario,
    # rather than one per child with a gap between every pair (#83, option 3).
    [int]$LeaseWaitMin = 60,
    # Do not take a run-level lease. For running the library UNDER an outer
    # host that already holds one, or deliberately interleaving with another
    # session at scenario granularity, as before #83.
    [switch]$NoRunLease,
    [string]$ResultsPath
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'harness.ps1')

$RepoRoot = Split-Path -Parent $PSScriptRoot
$ToolsDir = $PSScriptRoot

function Split-Names([string[]]$list) {
    if (-not $list) { return @() }
    @($list | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ } |
        ForEach-Object { ($_ -replace '^scenario-', '') -replace '\.ps1$', '' })
}

$DefaultExcluded = [ordered]@{
    'baseline-v1'      = 'needs the original SkooBot 0.0.12 installed, and its own save'
    'walking-skeleton' = 'superseded by the per-issue scenarios'
}

$only = Split-Names $Only
$skip = Split-Names $Skip

$all = @(Get-ChildItem (Join-Path $ToolsDir 'scenario-*.ps1') | Sort-Object Name |
    ForEach-Object { ($_.BaseName -replace '^scenario-', '') })

$selected = @()
$excluded = @()
foreach ($name in $all) {
    if ($only.Count -gt 0) {
        if ($only -contains $name) { $selected += $name } else { $excluded += [pscustomobject]@{ Name = $name; Why = 'not in -Only' } }
        continue
    }
    if ($skip -contains $name) { $excluded += [pscustomobject]@{ Name = $name; Why = '-Skip' }; continue }
    if ($DefaultExcluded.Contains($name)) { $excluded += [pscustomobject]@{ Name = $name; Why = $DefaultExcluded[$name] }; continue }
    $selected += $name
}
foreach ($n in $only) { if ($all -notcontains $n) { Write-Host "[run-scenarios] WARNING: no scenario named '$n' (tools/scenario-$n.ps1)" } }

Write-Host ''
Write-Host "[run-scenarios] checkout $RepoRoot"
Write-Host "[run-scenarios] $($selected.Count) scenario(s): $($selected -join ', ')"
foreach ($e in $excluded) { Write-Host "[run-scenarios] excluded $($e.Name): $($e.Why)" }
if ($selected.Count -eq 0) { Write-Host '[run-scenarios] nothing to run'; exit 1 }

# One lease for the whole run (#83, option 3). Before this, each scenario
# child took and freed its own, so a library run was twenty leases with a
# gap between every pair -- and a long-run host trying to get in almost
# always landed inside one of the twenty rather than in a gap. Holding it
# here makes the unit of contention the RUN: fewer gaps, and the ones there
# are come at the end.
#
# Children inherit it through SKOOBOT_HARNESS_HOST, which Enter-HarnessLease
# sets on this process and Start-Process passes down, so their own
# Enter-HarnessLease calls find the lease already theirs and leave the owner
# alone -- the same path clean-build.ps1 has always used for setup-dev.
if (-not $NoRunLease) {
    $null = Wait-HarnessLease -TimeoutSec ($LeaseWaitMin * 60) -Label 'run-scenarios'
    Write-Host "[run-scenarios] holding the game lease for this run (host pid $PID)"
}

$StatusFor = @{ 0 = 'PASS'; 1 = 'FAIL'; 2 = 'TAINTED'; 3 = 'INCONCLUSIVE' }
$BusyPattern = 'IN USE by|JUNCTIONS POINT AT ANOTHER CHECKOUT|in use by'
# The per-scenario wait, jittered by +/-3 s. Two hosts polling on the same
# fixed interval can shadow each other indefinitely -- both wake, both find
# the other's lease, both sleep the same amount, forever. Jitter is what
# breaks that, and it costs one line (#83, option 1).
function Get-BusyWait { [math]::Max(1, $BusyWaitSec + (Get-Random -Minimum -3 -Maximum 4)) }


<#
    Run one child powershell, streaming its output as it arrives and keeping
    every line. Returns {ExitCode, Lines, Seconds, TimedOut}. Output goes
    through a file rather than a pipe so the child can be killed on a
    timeout without losing what it printed before.
#>
function Invoke-Child {
    param([string]$File, [string[]]$Arguments = @(), [int]$TimeoutSec, [string]$Prefix = '    | ')
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
    $tmpDir = Join-Path $RepoRoot 'build\results\tmp'
    if (-not (Test-Path $tmpDir)) { New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null }
    $outFile = Join-Path $tmpDir "child-$stamp.out"
    $errFile = Join-Path $tmpDir "child-$stamp.err"
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $File) + $Arguments
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $p = Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -WorkingDirectory $RepoRoot `
                       -RedirectStandardOutput $outFile -RedirectStandardError $errFile -PassThru -NoNewWindow
    # Without -Wait, ExitCode is null after the child exits unless the
    # process handle was cached while it was alive. Touch it now.
    $null = $p.Handle
    $lines = New-Object System.Collections.Generic.List[string]
    $offset = 0
    $script:__off = 0
    $timedOut = $false
    $drain = {
        if (-not (Test-Path $outFile)) { return }
        $fs = [System.IO.File]::Open($outFile, 'Open', 'Read', 'ReadWrite')
        try {
            $fs.Seek($offset, 'Begin') | Out-Null
            $sr = New-Object System.IO.StreamReader($fs)
            $text = $sr.ReadToEnd()
            $script:__off = $fs.Position
        } finally { $fs.Dispose() }
        if ($text) {
            foreach ($l in ($text -split "`r?`n")) {
                if ($l -eq '') { continue }
                $lines.Add($l)
                Write-Host ($Prefix + $l)
            }
        }
    }
    while (-not $p.HasExited) {
        & $drain; $offset = $script:__off
        if ($sw.Elapsed.TotalSeconds -gt $TimeoutSec) {
            $timedOut = $true
            Write-Host "$Prefix[run-scenarios] TIMEOUT after $TimeoutSec s; stopping the child (its game is reaped by the next launch)"
            Stop-Process -Id $p.Id -Force -ErrorAction Ignore
            break
        }
        Start-Sleep -Milliseconds 500
    }
    $p.WaitForExit()
    Start-Sleep -Milliseconds 200
    & $drain; $offset = $script:__off
    $err = @()
    if (Test-Path $errFile) { $err = @((Get-Content $errFile -ErrorAction Ignore) | Where-Object { $_ -ne '' }) }
    foreach ($l in $err) { $lines.Add($l); Write-Host ($Prefix + 'stderr: ' + $l) }
    Remove-Item $outFile, $errFile -Force -ErrorAction Ignore
    $code = $p.ExitCode
    if ($null -eq $code) { $code = -2; Write-Host "$Prefix[run-scenarios] the child's exit code could not be read" }
    [pscustomobject]@{
        ExitCode = $(if ($timedOut) { -1 } else { [int]$code })
        Lines    = @($lines)
        Seconds  = $sw.Elapsed.TotalSeconds
        TimedOut = $timedOut
    }
}

# setup-dev from this checkout; $true when the junctions are ours, $false
# when another live host holds the game, throws on any other failure.
function Invoke-SetupDev {
    $r = Invoke-Child -File (Join-Path $ToolsDir 'setup-dev.ps1') -TimeoutSec 120 -Prefix '    setup | '
    if ($r.ExitCode -eq 0) { return $true }
    if (($r.Lines -join "`n") -match $BusyPattern) { return $false }
    throw "[run-scenarios] setup-dev.ps1 failed (exit $($r.ExitCode)); see above"
}

$results = @()
$anyBad = $false
foreach ($name in $selected) {
    $file = Join-Path $ToolsDir "scenario-$name.ps1"
    Write-Host ''
    Write-Host "[run-scenarios] === $name ==="
    $attempts = 0
    $busyTries = 0
    $tainted = $false
    $final = $null
    while ($true) {
        if (-not $NoSetupDev) {
            if (-not (Invoke-SetupDev)) {
                $busyTries++
                if ($busyTries -gt $BusyRetries) { $final = [pscustomobject]@{ Status = 'BUSY'; Exit = -1; Seconds = 0; Lines = @('the game stayed in use by another host'); Summary = 'BUSY: lease held throughout' }; break }
                $wait = Get-BusyWait
                Write-Host "[run-scenarios] game in use (try $busyTries/$BusyRetries); waiting $wait s"
                Start-Sleep -Seconds $wait
                continue
            }
        }
        $attempts++
        $r = Invoke-Child -File $file -TimeoutSec ($TimeoutMin * 60)
        $text = $r.Lines -join "`n"
        if ($r.ExitCode -ne 0 -and -not $r.TimedOut -and $text -match $BusyPattern) {
            $attempts--
            $busyTries++
            if ($busyTries -gt $BusyRetries) { $final = [pscustomobject]@{ Status = 'BUSY'; Exit = $r.ExitCode; Seconds = $r.Seconds; Lines = $r.Lines; Summary = 'BUSY: lease held throughout' }; break }
            $wait = Get-BusyWait
            Write-Host "[run-scenarios] game in use (try $busyTries/$BusyRetries); waiting $wait s"
            Start-Sleep -Seconds $wait
            continue
        }
        $status = if ($r.TimedOut) { 'TIMEOUT' } elseif ($StatusFor.ContainsKey($r.ExitCode)) { $StatusFor[$r.ExitCode] } else { 'CRASHED' }
        # The scenario's own verdict line: "[name] PASS - ...", "[t012] FAILED - ...".
        $verdict = @($r.Lines | Where-Object { $_ -match '^\[[\w\-]+\] (PASS|FAIL|FAILED|TAINTED|INCONCLUSIVE|summary)\b' } | Select-Object -Last 1)
        $summary = if ($verdict.Count -gt 0) { $verdict[0] } elseif ($r.Lines.Count -gt 0) { $r.Lines[-1] } else { '' }
        $tainted = ($status -eq 'TAINTED')
        $null = Write-ScenarioResult -Scenario $name -Status $status -ExitCode $r.ExitCode -Seconds $r.Seconds `
                    -Tainted $tainted -Attempts $attempts -Summary $summary -Lines @($r.Lines | Select-Object -Last 15) -Path $ResultsPath
        Write-Host "[run-scenarios] $name -> $status (exit $($r.ExitCode), $([math]::Round($r.Seconds)) s, attempt $attempts)"
        if ($status -eq 'TAINTED' -and -not $NoRetryOnTaint -and $attempts -lt 2) {
            Write-Host '[run-scenarios] tainted: the result is void; re-running once'
            continue
        }
        $final = [pscustomobject]@{ Status = $status; Exit = $r.ExitCode; Seconds = $r.Seconds; Lines = $r.Lines; Summary = $summary }
        break
    }
    if ($final.Status -eq 'BUSY') {
        $null = Write-ScenarioResult -Scenario $name -Status 'BUSY' -ExitCode $final.Exit -Seconds $final.Seconds `
                    -Tainted $false -Attempts $attempts -Summary $final.Summary -Lines @($final.Lines | Select-Object -Last 15) -Path $ResultsPath
    }
    if ($final.Status -in @('FAIL', 'CRASHED', 'TIMEOUT', 'BUSY')) { $anyBad = $true }
    $results += [pscustomobject]@{
        Scenario = $name
        Status   = $final.Status
        Exit     = $final.Exit
        Seconds  = [math]::Round($final.Seconds)
        Attempts = $attempts
        Summary  = $final.Summary
    }
}

Write-Host ''
Write-Host '[run-scenarios] summary'
$results | Format-Table -AutoSize -Property Scenario, Status, Exit, Seconds, Attempts, Summary | Out-String -Width 200 | Write-Host
$where = if ($ResultsPath) { $ResultsPath } else { Join-Path $script:ResultsDir ((Get-Date -Format 'yyyy-MM-dd') + '.jsonl') }
Write-Host "[run-scenarios] results appended to $where"
$counts = $results | Group-Object Status | ForEach-Object { "$($_.Name)=$($_.Count)" }
Write-Host "[run-scenarios] $($counts -join ' ')"
if ($anyBad) { Write-Host '[run-scenarios] FAILED - at least one scenario did not pass'; exit 1 }
Write-Host '[run-scenarios] PASS - no scenario failed (INCONCLUSIVE and TAINTED, if any, are listed above)'
exit 0
