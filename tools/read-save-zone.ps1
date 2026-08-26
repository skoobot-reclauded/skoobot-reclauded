<#
    Print the zone a save's character is standing in, and nothing else.

        ZONE trollmire
        ZONE cults+town-kroshkkur

    For tools/sweep-classes.ps1, which needs to know whether a class began in a
    town before it spends a run's budget finding out (#134). Reading it from
    the save covers the DLC classes, whose descriptors ship in .teaac and
    cannot be read from disk -- which is how Writhing One got past the sweep's
    hardcoded list of town-start class names.

    One launch, load, read, quit. Inherits an outer lease through
    SKOOBOT_HARNESS_HOST when the sweep is holding one (#83).

    Exit codes:  0 printed a zone   1 could not load the save

    Run:
        powershell -ExecutionPolicy Bypass -File .\tools\read-save-zone.ps1 -SaveName sweep-cornac-berserker

    #134, #123.
#>
[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$SaveName)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'harness.ps1')

try {
    $g = Load-Save -Name $SaveName
    if (-not $g.Ready) { Write-Host "FAILED: could not load '$SaveName' ($($g.Reason))"; exit 1 }
    $r = Invoke-Bridge -TimeoutSec 30 -Lua 'return tostring(game.zone and game.zone.short_name or "?")'
    if ($r.Status -ne 'OK') { Write-Host "FAILED: bridge $($r.Status)"; exit 1 }
    Write-Host ("ZONE {0}" -f $r.Result.Trim())
}
finally { Stop-Game }
exit 0
