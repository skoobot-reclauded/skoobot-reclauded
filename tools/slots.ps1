<#
    Slots: several independent games on one machine (#189).

    Dot-source this. It defines New-SlotSet and nothing else runs.

    A slot is a game directory plus an engine home. Both are needed because
    te4_log.txt -- which the harness reads its results out of -- is written to
    the WORKING directory, and the engine bootstraps its engine code from there
    too, so the log cannot be moved on its own. Sharing one log is impossible
    anyway: the engine opens it 'w' and each launch truncates the last.

    A slot is nearly free. bootstrap/game/lib/lib64/locales are read-only data
    (871 MB) and become junctions; the ~71 MB of loose files at the top level
    become hard links. Only te4_log.txt is genuinely written there.

    Measured on an 8-vCPU guest, 8 slots ran at 767 turns/s against 90 solo,
    with CPU at 61% and disk active time at 93% -- so the ceiling is I/O from
    the engine's own logging, not cores.
#>

function New-SlotSet {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$Count,
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$GameDir,
        [Parameter(Mandatory)][string]$SeedHome,
        # Copy this save into every slot. Omit to leave the slots empty, which
        # is what a scheduler wants -- it births its own character per class.
        [string]$Save,
        [switch]$Quiet
    )

    $linkDirs = @('bootstrap', 'game', 'lib', 'lib64', 'locales')
    $slots = @()

    foreach ($n in 1..$Count) {
        $slot  = Join-Path $Root "slot$n"
        $sgame = Join-Path $slot 'game-dir'
        $shome = Join-Path $slot 'home'
        foreach ($d in @($slot, $sgame, $shome)) {
            if (-not (Test-Path $d)) { $null = New-Item -ItemType Directory -Force -Path $d }
        }
        foreach ($d in $linkDirs) {
            $src = Join-Path $GameDir $d
            if (-not (Test-Path $src)) { continue }
            $dst = Join-Path $sgame $d
            if (-not (Test-Path $dst)) { $null = New-Item -ItemType Junction -Path $dst -Target $src }
        }
        # Hard links, not copies: the same bytes on the same volume. Falls back
        # to copying if the volume refuses.
        foreach ($f in (Get-ChildItem $GameDir -File)) {
            $dst = Join-Path $sgame $f.Name
            if (Test-Path $dst) { continue }
            try { $null = New-Item -ItemType HardLink -Path $dst -Target $f.FullName -ErrorAction Stop }
            catch { Copy-Item $f.FullName $dst -Force }
        }

        # The engine appends T-Engine\4.0 to whatever --home it is given.
        $eng = Join-Path $shome 'T-Engine\4.0'
        if (-not (Test-Path $eng)) { $null = New-Item -ItemType Directory -Force -Path $eng }
        # 'boot' matters: without it the engine treats the home as a first run
        # and opens a welcome dialog at the main menu that nothing dismisses.
        foreach ($d in @('settings', 'profiles', 'boot')) {
            $src = Join-Path $SeedHome $d
            if ((Test-Path $src) -and -not (Test-Path (Join-Path $eng $d))) {
                Copy-Item $src (Join-Path $eng $d) -Recurse -Force
            }
        }

        if ($Save) {
            # Get-SaveDirName, never a second copy of the rule: the save NAME
            # uses hyphens, the DIRECTORY uses underscores truncated to 25
            # characters. A duplicate of that rule reported Cultist of Entropy
            # UNBIRTHABLE for eight sweeps with a valid save on disk (#121).
            $saveDir = Get-SaveDirName -Name $Save
            $saveSrc = Join-Path $SeedHome "tome\save\$saveDir"
            if (-not (Test-Path $saveSrc)) { throw "no save directory at $saveSrc (from save name '$Save')" }
            $saveDst = Join-Path $eng "tome\save\$saveDir"
            if (-not (Test-Path $saveDst)) {
                $null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $saveDst)
                Copy-Item $saveSrc $saveDst -Recurse -Force
            }
        }

        $slots += [pscustomobject]@{
            N       = $n
            Slot    = $slot
            GameDir = $sgame
            Home    = $shome
            # The harness records the live game's pid here. A watchdog needs it
            # to kill one slot's game without touching its siblings.
            Lease   = Join-Path $eng 'skoobot-bridge\harness.lock'
        }
    }

    if (-not $Quiet) {
        $used = (Get-ChildItem $Root -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
        Write-Host ("[slots] {0} slot(s) under {1}, {2:N0} MB of real bytes" -f $Count, $Root, ($used / 1MB))
    }
    return $slots
}

function Get-SlotGamePid {
    <#
        The pid of the game a slot is running, or 0. Read from the slot's own
        lease file, which harness.ps1 writes with the game pid in it -- so a
        watchdog kills exactly one slot's game and leaves the rest alone.
    #>
    param([Parameter(Mandatory)]$Slot)
    if (-not (Test-Path $Slot.Lease)) { return 0 }
    try {
        $l = Get-Content $Slot.Lease -Raw -ErrorAction Stop | ConvertFrom-Json
        if ($l.game) { return [int]$l.game }
    } catch { return 0 }
    return 0
}
