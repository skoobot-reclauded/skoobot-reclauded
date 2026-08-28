<#
    The half of the remote-sweep plumbing that lives ON a runner.

    Windows OpenSSH puts a session in **session 0**, which is isolated from
    every desktop, so anything that needs a window fails there -- ToME exits
    with "Error initializing SDL video: No displays available" and the harness
    reports the far less helpful "NO BRIDGE after 60s" over an empty log. That
    is not about who is logged on: session 0 can never own a desktop.

    So ssh does not run the sweep. It drops a command file and pokes a
    scheduled task registered with /it ("run only when the user is logged on"),
    which Windows starts in the interactive session. Hence the standing
    requirement that a runner **stays logged on at the console** -- logged off,
    there is no session to launch into. See #182.

    Install (once per runner, over ssh):
        powershell -ExecutionPolicy Bypass -File runner-agent.ps1 -Install
    The task then invokes this same file with -Run.
#>
[CmdletBinding()]
param(
    [switch]$Install,
    [switch]$Run,
    [string]$Base = "$env:USERPROFILE\skoobot-agent",
    [string]$TaskName = 'skoobot-agent'
)
$ErrorActionPreference = 'Stop'

$cmdFile  = Join-Path $Base 'cmd.ps1'
$logFile  = Join-Path $Base 'run.log'
$doneFile = Join-Path $Base 'run.done'

if ($Install) {
    if (-not (Test-Path $Base)) { $null = New-Item -ItemType Directory -Force -Path $Base }
    $self = Join-Path $Base 'runner-agent.ps1'
    if ($PSCommandPath -ne $self) { Copy-Item $PSCommandPath $self -Force }

    $tr = "powershell -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$self`" -Run"
    # /it is the whole point: it hands the task an interactive token. /st is in
    # the past on purpose -- the trigger never fires, the controller always
    # starts this by name with `schtasks /run`.
    # Do NOT redirect schtasks' stderr. Under ErrorActionPreference 'Stop' a
    # native exe's stderr comes back wrapped in ErrorRecords and throws even on
    # exit 0 -- and schtasks always warns here, because /st is deliberately in
    # the past. The task registers fine; the redirect is what fails. Check the
    # exit code instead (OPERATIONS.md 2.1.1).
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    & schtasks /create /tn $TaskName /f /sc once /st 00:00 /ru $env:USERNAME /it /tr $tr | Out-Null
    $code = $LASTEXITCODE
    $ErrorActionPreference = $prev
    if ($code -ne 0) {
        Write-Host "[agent] FAILED to register $TaskName (schtasks exit $code)"
        exit 1
    }
    Write-Host "[agent] $TaskName registered on $env:COMPUTERNAME, base $Base"
    Write-Host '[agent] PASS'
    exit 0
}

if ($Run) {
    # Errors here must not stop the wrapper: the point is to record what
    # happened and always write the marker, or the controller polls forever.
    $ErrorActionPreference = 'Continue'
    Remove-Item $doneFile -ErrorAction SilentlyContinue
    "[agent] session $((Get-Process -Id $PID).SessionId) on $env:COMPUTERNAME at $(Get-Date -Format 'HH:mm:ss')" |
        Out-File -FilePath $logFile -Encoding utf8
    if (-not (Test-Path $cmdFile)) {
        "[agent] no command file at $cmdFile" | Out-File -FilePath $logFile -Encoding utf8 -Append
        'exit=2' | Out-File -FilePath $doneFile -Encoding utf8
        exit 2
    }
    try {
        & powershell -ExecutionPolicy Bypass -File $cmdFile *>&1 |
            Out-File -FilePath $logFile -Encoding utf8 -Append
        $code = $LASTEXITCODE
    } catch {
        "[agent] EXCEPTION $_" | Out-File -FilePath $logFile -Encoding utf8 -Append
        $code = 99
    }
    "exit=$code" | Out-File -FilePath $doneFile -Encoding utf8
    exit 0
}

Write-Host 'usage: runner-agent.ps1 -Install   (once, over ssh)'
Write-Host '       runner-agent.ps1 -Run       (what the scheduled task calls)'
exit 2
