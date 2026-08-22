<#
    Release gate: prove the PACKED ARTIFACT loads and runs, not the repo.

    The check this replaces was "delete the two devbridge junctions and see
    that the addon still loads", which had nothing to gate: no packer existed,
    and once the product junction did exist the engine would happily load the
    working tree instead. A mis-packed archive with no root init.lua is skipped
    at engine/Module.lua:416 with NO error at all, so the gate would have gone
    green on src/ while shipping something that mounts nothing.

    So:
      1. pack a fresh artifact from src/;
      2. remove every junction this project creates -- crucially including
         tome-skoobot_reclauded, the one that could make this pass on the
         working tree;
      3. put the devbridge back, and ONLY the devbridge, because the engine has
         no command-line path into a module and something has to drive the menu
         (docs/design-harness.md section 4.3);
      4. install the .teaa into the game's addons directory;
      5. load the harness save and read the engine's own log.

    The oracle is `Binding addon` (Module.lua:490), whose third field is
    add.teaa -- the archive path when the addon came from an archive, and nil
    when it came from an unpacked directory. That field answers the actual
    question directly instead of inferring it from what is absent. Tab
    separated, like every print() with multiple arguments; matching it with
    spaces silently never fires.

    Run:
        powershell -ExecutionPolicy Bypass -File .\tools\clean-build.ps1

    Restores the development junctions on the way out, including on failure.

    T-035.
#>
[CmdletBinding()]
param(
    [string]$SaveName = 'harness',
    [switch]$SkipPack
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'harness.ps1')

$RepoRoot  = Split-Path -Parent $PSScriptRoot
$AddonsDir = Join-Path $script:GameDir 'game\addons'
$SHORT     = 'skoobot_reclauded'

$script:Fail = @()
function Check($ok, $what) {
    if ($ok) { Write-Host "  PASS  $what" }
    else     { Write-Host "  FAIL  $what"; $script:Fail += $what }
}

function Restore-DevLoop {
    Write-Host ''
    Write-Host '[clean-build] restoring the development junctions'
    & powershell -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'setup-dev.ps1') |
        Where-Object { $_ -match 'created|repoint|ok |ERROR' } | ForEach-Object { Write-Host "  $_" }
}

Write-Host ''
Write-Host '[clean-build] ============================================'

# --- 1. pack -------------------------------------------------------------
if (-not $SkipPack) {
    Write-Host '[clean-build] packing'
    & powershell -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'pack.ps1') |
        Select-Object -Last 3 | ForEach-Object { Write-Host "  $_" }
    if ($LASTEXITCODE -ne 0) { Write-Host '[clean-build] FAILED - pack.ps1 failed'; exit 1 }
}

$artifact = Get-ChildItem (Join-Path $RepoRoot 'dist') -Filter "tome-$SHORT-*.teaa" -ErrorAction Ignore |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $artifact) { Write-Host '[clean-build] FAILED - no artifact in dist/'; exit 1 }
Write-Host "[clean-build] artifact: $($artifact.Name)"

$installed = Join-Path $AddonsDir $artifact.Name

try {
    # --- 2. strip every junction ----------------------------------------
    Write-Host ''
    Write-Host '[clean-build] removing development junctions'
    & powershell -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'setup-dev.ps1') -Remove |
        Where-Object { $_ -match 'removed|absent|ERROR' } | ForEach-Object { Write-Host "  $_" }

    $productLink = Join-Path $AddonsDir "tome-$SHORT"
    Check (-not (Test-Path $productLink)) "product junction is gone (nothing can load from src/)"

    # --- 3. devbridge back, product NOT ---------------------------------
    # The engine has no CLI way into a module; something must drive the menu.
    New-Item -ItemType Junction -Path (Join-Path $AddonsDir 'tome-skoobot-devbridge') `
             -Target (Join-Path $RepoRoot 'tools\devbridge') | Out-Null
    New-Item -ItemType Junction -Path (Join-Path $AddonsDir 'boot-skoobot-devbridge') `
             -Target (Join-Path $RepoRoot 'tools\devbridge-boot') | Out-Null
    Write-Host '  devbridge junctions restored (driver only)'

    # --- 4. install the artifact ----------------------------------------
    Copy-Item $artifact.FullName $installed -Force
    Write-Host "  installed $($artifact.Name) into game/addons"

    # A directory and an archive of the same addon at once is a duplicate the
    # engine reports at :703-709; assert we are not in that state.
    Check (-not (Test-Path $productLink)) 'no duplicate: archive installed, junction absent'

    # --- 5. run ----------------------------------------------------------
    Write-Host ''
    Write-Host '[clean-build] loading the game from the artifact'
    $r = Load-Save -Name $SaveName
    if (-not $r.Ready) {
        Write-Host "[clean-build] FAILED - could not reach a game ($($r.Reason))"
        $script:Fail += 'game did not load'
    } else {
        Check $r.AddonsIntact 'no required addon dropped by the savefile rule'
        Check ($r.Addons -match [regex]::Escape($SHORT)) "bridge.addons() reports $SHORT loaded"
    }
    Stop-Game
    Start-Sleep -Seconds 2

    # --- 6. read the engine's own log ------------------------------------
    Write-Host ''
    Write-Host '[clean-build] engine log oracle'
    $log = Get-Content $script:LogPath -Raw -ErrorAction Ignore
    $lines = @($log -split "`r?`n")

    $binding = @($lines | Where-Object { $_ -match "^Binding addon\t.*\t.*$SHORT" })
    Check ($binding.Count -ge 1) 'engine bound the addon at all'

    if ($binding.Count -ge 1) {
        Write-Host "        $($binding[0])"
        # Fields: Binding addon <TAB> long_name <TAB> add.teaa <TAB> version_name
        $fields = $binding[0] -split "`t"
        $teaaField = if ($fields.Count -ge 3) { $fields[2] } else { '' }
        Check ($teaaField -match '\.teaa$') `
              "loaded FROM THE ARCHIVE (add.teaa = '$teaaField', not nil)"

        # The ' * with X' lines belong to the Binding addon line above them.
        $start = [array]::IndexOf($lines, $binding[0])
        $mounts = @()
        for ($i = $start + 1; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match '^Binding addon\t') { break }
            if ($lines[$i] -match '^ \* with (\w+)') { $mounts += $Matches[1] }
        }
        Write-Host "        mounts: $(if ($mounts) { $mounts -join ', ' } else { '(none)' })"

        # Manifest-driven, so this stays correct as src/ gains content.
        $initText = Get-Content (Join-Path $RepoRoot 'src\init.lua') -Raw
        foreach ($flag in 'hooks', 'superload', 'overload', 'data') {
            $declared = $initText -match "(?m)^\s*$flag\s*=\s*true\s*$"
            $mounted  = $mounts -contains $flag
            if ($declared) {
                Check $mounted "init.lua declares $flag and the engine mounted it"
            } elseif ($mounted) {
                Check $false "engine mounted $flag but init.lua does not declare it"
            }
        }
    }

    Check (-not ($lines | Where-Object { $_ -match "Removing addon $SHORT" })) `
          "no 'Removing addon $SHORT' line"

    # Only Lua errors after our addon was bound are ours to answer for.
    $bindIdx = if ($binding.Count -ge 1) { [array]::IndexOf($lines, $binding[0]) } else { 0 }
    $luaErrors = @($lines[$bindIdx..($lines.Count - 1)] | Where-Object { $_ -match 'Lua Error' })
    Check ($luaErrors.Count -eq 0) 'no Lua Error after the addon was bound'
    foreach ($e in ($luaErrors | Select-Object -First 5)) { Write-Host "        $e" }

    # A network-configuration report used to live here, back when the dev loop
    # disabled connectivity and this gate had to warn that its results were
    # therefore measured in a configuration no player uses. The dev loop no
    # longer disables it (setup-dev.ps1 records the measurements), so there is
    # one configuration, this gate measures the one players get, and the
    # warning has nothing left to warn about.

    # The artifact must not carry the bridge, whatever else is true.
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($artifact.FullName)
    try {
        $bad = @($zip.Entries | Where-Object { $_.FullName -match 'devbridge|^tools/|^spec/' })
        Check ($bad.Count -eq 0) 'artifact contains no development tooling'
    } finally { $zip.Dispose() }

} finally {
    Stop-Game
    if (Test-Path $installed) {
        Remove-Item $installed -Force -ErrorAction Ignore
        Write-Host ''
        Write-Host "[clean-build] uninstalled $($artifact.Name) from game/addons"
    }
    Restore-DevLoop
}

Write-Host ''
if ($script:Fail.Count -gt 0) {
    Write-Host "[clean-build] FAILED - $($script:Fail.Count) check(s):"
    foreach ($f in $script:Fail) { Write-Host "                $f" }
    exit 1
}
Write-Host '[clean-build] PASS - the packed artifact loads and runs standalone'
exit 0
