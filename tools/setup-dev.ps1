<#
    Set up (or tear down) the development loop against a real ToME install.

    The engine loads an addon from an unpacked directory when it sits in
    game/addons/ named <module>-<something> and contains an init.lua
    (engine/Module.lua:409-414). Junctioning the repo's trees in means edits
    are live on the next launch, with no copying and no packing.

    Three junctions, not two. The devbridge pair is what the harness talks
    through; tome-skoobot_reclauded is the product itself, and without it the
    game has never loaded the thing under test -- every run before this script
    existed exercised the bridge only.

    Idempotent. Re-running it is the supported way to check the state: a
    junction already pointing at the right place is left alone, one pointing
    somewhere else is re-pointed, and a REAL directory in the way is reported
    as an error rather than deleted.

    Run:
        powershell -ExecutionPolicy Bypass -File .\tools\setup-dev.ps1
        powershell -ExecutionPolicy Bypass -File .\tools\setup-dev.ps1 -Remove

    -Remove is also the inverse the clean-build gate needs (T-035): it strips
    every junction this script creates, so the gate can prove the packed
    artifact loads on its own rather than quietly loading the working tree.

    Override the game location with the TOME_DIR environment variable.

    T-041.
#>
[CmdletBinding()]
param(
    [switch]$Remove
)

$ErrorActionPreference = 'Stop'

# --------------------------------------------------------------------------
# Paths. Derived, never hardcoded to one machine's user name.
# --------------------------------------------------------------------------
$RepoRoot = Split-Path -Parent $PSScriptRoot
if ($env:TOME_DIR) { $GameDir = $env:TOME_DIR } else { $GameDir = 'C:\games\TalesMajEyal' }
$AddonsDir = Join-Path $GameDir 'game\addons'
$TomeHome  = Join-Path $env:USERPROFILE 'T-Engine\4.0'
$SettingsDir = Join-Path $TomeHome 'settings'

# name in game/addons  ->  directory in this repo
$Junctions = [ordered]@{
    'tome-skoobot_reclauded' = (Join-Path $RepoRoot 'src')
    'tome-skoobot-devbridge' = (Join-Path $RepoRoot 'tools\devbridge')
    'boot-skoobot-devbridge' = (Join-Path $RepoRoot 'tools\devbridge-boot')
}

$script:Failed = 0
function Fail($msg) { Write-Host "  ERROR   $msg"; $script:Failed++ }
function Note($msg) { Write-Host "  $msg" }

# --------------------------------------------------------------------------
# Junction helpers.
#
# Removal goes through Directory::Delete rather than Remove-Item. A junction
# is a directory to most of the API surface, and Remove-Item -Recurse on one
# can delete through it -- which here would mean deleting the contents of
# src/ or tools/ out of the working tree. Directory::Delete($p, $false)
# removes the reparse point only; verified against a canary file in the
# target before this script was written.
# --------------------------------------------------------------------------
function Get-JunctionTarget($path) {
    $item = Get-Item -LiteralPath $path -Force -ErrorAction Ignore
    if (-not $item) { return $null }
    if (-not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { return '<not-a-link>' }
    if ($item.Target) { return @($item.Target)[0] }
    return '<unknown>'
}

function Remove-Junction($path) {
    [System.IO.Directory]::Delete($path, $false)
}

function Compare-Path($a, $b) {
    if (-not $a -or -not $b) { return $false }
    return ([IO.Path]::GetFullPath($a).TrimEnd('\')) -ieq ([IO.Path]::GetFullPath($b).TrimEnd('\'))
}

# --------------------------------------------------------------------------
Write-Host ''
if ($Remove) { Write-Host "[setup-dev] REMOVE  repo=$RepoRoot" }
else         { Write-Host "[setup-dev] SETUP   repo=$RepoRoot" }
Write-Host "[setup-dev] game=$GameDir"
Write-Host ''

if (-not (Test-Path $AddonsDir)) {
    Write-Host "[setup-dev] FAILED - no addons directory at $AddonsDir"
    Write-Host "            Set TOME_DIR to the ToME install root."
    exit 1
}

# --------------------------------------------------------------------------
# Junctions
# --------------------------------------------------------------------------
Write-Host 'Junctions'
foreach ($name in $Junctions.Keys) {
    $link   = Join-Path $AddonsDir $name
    $target = $Junctions[$name]
    $actual = Get-JunctionTarget $link

    if ($Remove) {
        if ($null -eq $actual) {
            Note "absent  $name"
        } elseif ($actual -eq '<not-a-link>') {
            Fail "$name is a real directory, not a junction -- refusing to delete it"
        } else {
            Remove-Junction $link
            Note "removed $name"
        }
        continue
    }

    if (-not (Test-Path $target)) {
        Fail "$name -> $target does not exist in this repo"
        continue
    }

    if ($null -eq $actual) {
        New-Item -ItemType Junction -Path $link -Target $target | Out-Null
        Note "created $name -> $target"
    } elseif ($actual -eq '<not-a-link>') {
        Fail "$name is a real directory, not a junction -- refusing to replace it"
    } elseif (Compare-Path $actual $target) {
        Note "ok      $name -> $target"
    } else {
        Remove-Junction $link
        New-Item -ItemType Junction -Path $link -Target $target | Out-Null
        Note "repoint $name -> $target (was $actual)"
    }
}

# Anything else called skoobot in there is not ours and would still be loaded
# by the engine, so say so rather than leaving it to be discovered by a
# confusing duplicate-addon error at the main menu (Module.lua:703-709).
$strays = Get-ChildItem $AddonsDir -Force -ErrorAction Ignore |
          Where-Object { $_.Name -match 'skoobot' -and -not $Junctions.Contains($_.Name) }
foreach ($s in $strays) { Note "STRAY   $($s.Name) -- not created by this script" }

# --------------------------------------------------------------------------
# resolution.cfg
#
# Not reverted by -Remove. The pre-harness value is not recorded anywhere, so
# putting back a guess would be worse than leaving it; and it cannot affect
# whether an addon loads, which is all the clean-build gate measures. The
# harness addresses menus by dialog class and bound-command name, never by
# pixel position, so the size is a convenience rather than a dependency.
# --------------------------------------------------------------------------
Write-Host ''
Write-Host 'Settings'
if (-not (Test-Path $SettingsDir)) { New-Item -ItemType Directory -Path $SettingsDir -Force | Out-Null }

function Set-Cfg($file, $want) {
    $path = Join-Path $SettingsDir $file
    $current = $null
    if (Test-Path $path) { $current = (Get-Content $path -Raw -ErrorAction Ignore) }
    if ($current -and $current.Trim() -eq $want) { Note "ok      $file = $want"; return }
    Set-Content -Path $path -Value $want -Encoding ascii
    Note "wrote   $file = $want"
}

# resolution.cfg is NOT reverted by -Remove: the pre-harness value is recorded
# nowhere, so restoring a guess is worse than leaving it, and it cannot affect
# whether an addon loads.
if ($Remove) {
    Note "kept    resolution.cfg (no recorded pre-harness value to restore)"
} else {
    Set-Cfg 'resolution.cfg' "window.size = '800x600 Windowed'"
}

# Connectivity IS reverted, because unlike the resolution we know what it was.
#
# The engine connects to profiles.te4.org at startup, reconnects to channels,
# fetches news and measures latency. Turning that off removes a background
# thread and tightens the normal launch from 5-10s to 5-7s. (--no-web does not
# cover it: that is the embedded browser, not the profile thread.)
#
# Modest, and honestly less than first claimed. This was originally believed to
# be the cause of the intermittent 90-166s launches, because the gaps in a
# sampled slow launch all ended on `Server latency` lines. They did -- but that
# thread emits periodically, so its lines land at the boundary of any long gap.
# With connectivity fully disabled a 166s stall still happened, with no
# `Server latency` lines in the log at all. The tail is the boot menu building
# its demo level (see design-harness.md section 4) and this does not fix it.
#
# So the dev loop turns it off, and -Remove turns it back on.
#
# ---------------------------------------------------------------------------
# RELEASE TESTING MUST RUN WITH CONNECTIVITY ENABLED.
# ---------------------------------------------------------------------------
# Everything measured with it off is measured in a configuration no player
# uses. The online profile touches addon hash validation, achievements and
# character upload, and an addon that misbehaves only when those are live
# would pass every gate here. Before calling a build releasable, run
# `-Remove` (or set disable_all_connectivity = false by hand) and repeat the
# behaviour runs. Recorded against T-051 (#32), which owns the release gates.
if ($Remove) {
    Set-Cfg 'disable_all_connectivity.cfg' 'disable_all_connectivity = false'
    Note "        ^ connectivity restored -- this is the configuration to do release testing in"
} else {
    Set-Cfg 'disable_all_connectivity.cfg' 'disable_all_connectivity = true'
    Note "        ^ offline for speed; RELEASE testing must be re-run with this false (T-051)"
}

# --------------------------------------------------------------------------
Write-Host ''
if ($script:Failed -gt 0) {
    Write-Host "[setup-dev] FAILED - $($script:Failed) problem(s) above"
    exit 1
}
if ($Remove) {
    Write-Host '[setup-dev] PASS - development junctions removed'
} else {
    Write-Host '[setup-dev] PASS - development loop ready'
    Write-Host ''
    Write-Host '            The engine only attaches addons a savefile lists. A save made'
    Write-Host '            before skoobot_reclauded existed will silently drop it -- see'
    Write-Host '            tools/new-character.ps1 and docs/design-harness.md (T-042).'
}
exit 0
