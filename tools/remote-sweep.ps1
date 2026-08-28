<#
    Run a sweep, or a share of one, on another machine and bring the results
    home.

    The point is LATENCY, not throughput: two machines each taking half the
    roster halve the wait for a build's numbers. Whole sweeps per machine would
    double the work done per day and leave the wait exactly as long.

    Pairs with tools/runner-agent.ps1, which must be installed on the runner
    first -- read its header for why ssh cannot start the game itself (#182).

        # once per runner
        .\tools\remote-sweep.ps1 -Runner 192.168.50.88 -InstallAgent

        # this machine takes one half, the runner the other
        .\tools\remote-sweep.ps1 -Runner 192.168.50.88 -Only 'Rogue,Shadowblade' -Minutes 4

    Results land in -OutDir (default build\results\sweep) alongside anything
    this machine produced, so `sweep-classes.ps1 -SummarizeOnly` then writes one
    table over both halves.

    The runner is synced with `git reset --hard` to a pushed commit rather than
    by copying the working tree: what a sweep measured has to be nameable, and
    a pile of rsync'd edits is not. Uncommitted work is therefore NOT tested
    remotely -- commit and push it first.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Runner,
    [string]$User = 'localuser',
    [string]$Key  = "$env:USERPROFILE\.ssh\skoobot_runner",
    [string]$RemoteRepo = 'C:\Users\localuser\Documents\skoobot-reclauded',
    [string]$RemoteBase = 'C:\Users\localuser\skoobot-agent',
    # The commit the runner is put on. Defaults to this checkout's HEAD, which
    # must already be pushed.
    [string]$Ref,
    [string[]]$Only,
    [int]$Minutes = 4,
    [switch]$Dossier,
    [string]$OutDir,
    # Install the session-1 agent and stop.
    [switch]$InstallAgent,
    [int]$PollSec = 20,
    [int]$TimeoutMin = 240
)
$ErrorActionPreference = 'Continue'
$RepoRoot = Split-Path -Parent $PSScriptRoot
if (-not $OutDir) { $OutDir = Join-Path $RepoRoot 'build\results\sweep' }

function Fail($m) { Write-Host "[remote] FAILED - $m"; exit 1 }
function Say($m)  { Write-Host "[remote] $m" }

$sshArgs = @('-i', $Key, '-o', 'StrictHostKeyChecking=accept-new', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=15')
$target  = "$User@$Runner"

# Quoting a PowerShell command through ssh -> cmd.exe -> powershell mangles
# anything containing quotes or $. -EncodedCommand takes UTF-16LE base64 and
# sidesteps the whole layer cake.
function Invoke-Runner([string]$ps) {
    $b64 = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($ps))
    $out = & ssh @sshArgs $target "powershell -NoProfile -EncodedCommand $b64" 2>&1
    return ($out | Where-Object { $_ -notmatch 'post-quantum|store now, decrypt later|openssh\.com/pq|^\*\*' })
}
function Copy-ToRunner([string]$local, [string]$remote) {
    $null = & scp @sshArgs $local "${target}:$remote" 2>&1
    return ($LASTEXITCODE -eq 0)
}
function Copy-FromRunner([string]$remote, [string]$local) {
    $null = & scp @sshArgs "${target}:$remote" $local 2>&1
    return ($LASTEXITCODE -eq 0)
}

# --- reachable? ----------------------------------------------------------
$who = Invoke-Runner 'Write-Output $env:COMPUTERNAME'
if (-not $who) { Fail "no ssh answer from $target (key $Key)" }
Say "runner is $($who -join '') at $Runner"

if ($InstallAgent) {
    $agent = Join-Path $PSScriptRoot 'runner-agent.ps1'
    if (-not (Copy-ToRunner $agent 'C:/Users/localuser/runner-agent.ps1')) { Fail 'could not copy runner-agent.ps1' }
    $r = Invoke-Runner 'powershell -ExecutionPolicy Bypass -File C:\Users\localuser\runner-agent.ps1 -Install'
    $r | ForEach-Object { Write-Host "  $_" }
    if (-not ($r -match 'PASS')) { Fail 'agent install did not report PASS' }
    Say 'PASS - agent installed'
    exit 0
}

# --- what are we asking it to run? --------------------------------------
if (-not $Ref) { $Ref = (& git -C $RepoRoot rev-parse HEAD).Trim() }
$short = (& git -C $RepoRoot rev-parse --short $Ref).Trim()
# A ref the runner cannot fetch fails minutes later inside the agent, where the
# error is a line in a log nobody is watching. Ask now.
$onRemote = (& git -C $RepoRoot branch -r --contains $Ref 2>&1) -join ' '
if (-not $onRemote.Trim()) {
    Fail "$short is not on any remote branch -- push it first, or the runner cannot check it out"
}

$onlyArg = ''
if ($Only) { $onlyArg = " -Only '" + ($Only -join ',') + "'" }
$dossierArg = ''
if ($Dossier) { $dossierArg = ' -Dossier' }

$cmd = @"
`$ErrorActionPreference = 'Continue'
`$repo = '$RemoteRepo'
& git -C `$repo fetch --quiet origin 2>&1 | Out-Null
& git -C `$repo reset --hard --quiet $Ref 2>&1 | Out-Null
`$at = (& git -C `$repo rev-parse --short HEAD).Trim()
if (`$at -ne '$short') { Write-Output "[cmd] SYNC FAILED - wanted $short, on `$at"; exit 4 }
. "`$repo\tools\harness-lease.ps1"
Write-Output ("[stamp] " + (Format-BuildStamp (Get-BuildStamp -GameDir 'C:\games\TalesMajEyal')))
& powershell -ExecutionPolicy Bypass -File "`$repo\tools\sweep-classes.ps1" -Minutes $Minutes$onlyArg$dossierArg
exit `$LASTEXITCODE
"@

$tmp = Join-Path $env:TEMP 'skoobot-remote-cmd.ps1'
Set-Content -Path $tmp -Value $cmd -Encoding utf8
if (-not (Copy-ToRunner $tmp "$RemoteBase/cmd.ps1")) { Fail 'could not copy the command file' }
# Count what the far side will parse, not the array as passed: -File hands a
# comma-joined list over as ONE string, so $Only.Count reports 1 for any
# number of classes and the line claims a sweep far smaller than it dispatched.
$onlyCount = 0
if ($Only) { $onlyCount = @(($Only -join ',') -split ',' | Where-Object { $_.Trim() }).Count }
Say "sync to $short, $Minutes min/class$(if ($Only) { ", $onlyCount class(es)" } else { ', full roster' })"

# --- go ------------------------------------------------------------------
$null = Invoke-Runner "Remove-Item '$RemoteBase\run.done' -ErrorAction SilentlyContinue; schtasks /run /tn skoobot-agent | Out-Null"
Say 'started; streaming the runner log'

$seen = 0
$deadline = (Get-Date).AddMinutes($TimeoutMin)
$done = $false
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds $PollSec
    $lines = @(Invoke-Runner "if (Test-Path '$RemoteBase\run.log') { Get-Content '$RemoteBase\run.log' }")
    if ($lines.Count -gt $seen) {
        $lines | Select-Object -Skip $seen | ForEach-Object { Write-Host "  | $_" }
        $seen = $lines.Count
    }
    $m = Invoke-Runner "if (Test-Path '$RemoteBase\run.done') { Get-Content '$RemoteBase\run.done' }"
    if ($m) { $done = $true; Say "runner finished ($($m -join ''))"; break }
}
if (-not $done) { Fail "runner did not finish within $TimeoutMin min" }

# --- bring the results home ---------------------------------------------
# Zipped, not scp'd per file: the server side is cmd.exe, which does not expand
# a glob in a remote path, so `scp host:dir/*.json` quietly copies nothing.
$zip = "$RemoteBase\results.zip"
$pack = @"
`$src = '$RemoteRepo\build\results\sweep'
if (-not (Test-Path `$src)) { Write-Output 'NO RESULTS'; exit 1 }
Remove-Item '$zip' -ErrorAction SilentlyContinue
Compress-Archive -Path (Join-Path `$src '*') -DestinationPath '$zip' -Force
Write-Output ("packed " + (Get-ChildItem `$src -File).Count + " file(s)")
"@
$p = Invoke-Runner $pack
if ($p -match 'NO RESULTS') { Fail 'the runner produced no results directory' }
Say ($p -join ' ')

if (-not (Test-Path $OutDir)) { $null = New-Item -ItemType Directory -Force -Path $OutDir }
$localZip = Join-Path $env:TEMP 'skoobot-remote-results.zip'
Remove-Item $localZip -ErrorAction SilentlyContinue
if (-not (Copy-FromRunner $zip $localZip)) { Fail 'could not fetch results.zip' }
Expand-Archive -Path $localZip -DestinationPath $OutDir -Force
Say "results expanded into $OutDir"

# The runner's stamp, kept so the merged table can name which machine ran what
# instead of reporting this machine's junctions for both halves (#175, #182).
$stampLine = Invoke-Runner "Get-Content '$RemoteBase\run.log' | Select-String '^\[stamp\] ' | Select-Object -First 1 | ForEach-Object { `$_.Line }"
if ($stampLine) {
    $clean = ($stampLine -join '') -replace '^\[stamp\] ', ''
    Add-Content -Path (Join-Path $OutDir 'stamps.txt') -Value $clean -Encoding utf8
    Say "recorded: $clean"
}

Write-Host ''
Say 'PASS - merge with: powershell -ExecutionPolicy Bypass -File .\tools\sweep-classes.ps1 -SummarizeOnly'
exit 0
