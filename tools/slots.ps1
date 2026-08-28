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

    $linkDirs = @('bootstrap', 'lib', 'lib64', 'locales')
    # The slot's OWN addon junctions, pinned to the checkout these tools live
    # in. Junctioning game\ wholesale resolved through the REAL install's
    # addon junctions -- so a dev thread repointing them mid-sweep would
    # silently switch what every slot measures, and Assert-JunctionsOwned
    # would start refusing launches minutes into a run. Slots must not share
    # the standard pipeline's moving parts (#198).
    $repo = Split-Path -Parent $PSScriptRoot
    $pins = @{
        'tome-skoobot_reclauded' = Join-Path $repo 'src'
        'tome-skoobot-devbridge' = Join-Path $repo 'tools\devbridge'
        'boot-skoobot-devbridge' = Join-Path $repo 'tools\devbridge-boot'
    }
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
        # game\ is mirrored one level down so addons\ can be the slot's own.
        $gsrc = Join-Path $GameDir 'game'
        $gdst = Join-Path $sgame 'game'
        if (-not (Test-Path $gdst)) { $null = New-Item -ItemType Directory -Force -Path $gdst }
        foreach ($child in (Get-ChildItem $gsrc)) {
            if ($child.Name -eq 'addons') { continue }
            $dst = Join-Path $gdst $child.Name
            if (Test-Path $dst) { continue }
            if ($child.PSIsContainer) { $null = New-Item -ItemType Junction -Path $dst -Target $child.FullName }
            else {
                try { $null = New-Item -ItemType HardLink -Path $dst -Target $child.FullName -ErrorAction Stop }
                catch { Copy-Item $child.FullName $dst -Force }
            }
        }
        $adst = Join-Path $gdst 'addons'
        if (-not (Test-Path $adst)) { $null = New-Item -ItemType Directory -Force -Path $adst }
        foreach ($child in (Get-ChildItem (Join-Path $gsrc 'addons') -Force)) {
            $dst = Join-Path $adst $child.Name
            if (Test-Path $dst) { continue }
            if ($pins.ContainsKey($child.Name)) {
                # Ours, pinned -- NOT resolved through the real install's
                # junction, which another session may repoint at any time.
                $null = New-Item -ItemType Junction -Path $dst -Target $pins[$child.Name]
            } elseif ($child.PSIsContainer) {
                $null = New-Item -ItemType Junction -Path $dst -Target $child.FullName
            } else {
                try { $null = New-Item -ItemType HardLink -Path $dst -Target $child.FullName -ErrorAction Stop }
                catch { Copy-Item $child.FullName $dst -Force }
            }
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

        # The one popup a fresh home always shows is the FirstRun dialog
        # ("Welcome to Tales of Maj'Eyal" -- boot mod/class/Game.lua:596), and
        # its ONLY suppressor is profiles/online/generic/firstrun.profile with
        # a truthy `firstrun` (engine/PlayerProfile.lua:427). The online dir,
        # even for offline play. Seeding `profiles` covers it when SeedHome has
        # the file; TestVM08's real home never did -- nobody ever dismissed the
        # dialog on that machine -- so every slot there opened on the popup and
        # the owner watched them sit on it (#196). Write it unconditionally.
        $fr = Join-Path $eng 'profiles\online\generic\firstrun.profile'
        if (-not (Test-Path $fr)) {
            $null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $fr)
            Set-Content -Path $fr -Value 'firstrun = 1' -Encoding ascii
        }
        # And keep a fresh home deterministically offline: without these two,
        # engine/init.lua:99 forces connectivity ON, and the main menu spends
        # its time fetching news and a te4.org WebView (engine/init.lua:99-110).
        $cfgDir = Join-Path $eng 'settings'
        if (-not (Test-Path $cfgDir)) { $null = New-Item -ItemType Directory -Force -Path $cfgDir }
        foreach ($cfg in @(@('disable_all_connectivity.cfg', 'disable_all_connectivity = true'),
                           @('firstrun_gdpr.cfg', 'firstrun_gdpr = true'))) {
            $cp = Join-Path $cfgDir $cfg[0]
            if (-not (Test-Path $cp)) { Set-Content -Path $cp -Value $cfg[1] -Encoding ascii }
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

function Invoke-SlotReap {
    <#
        Kill every game the slot's launch ledger still accounts for, and clear
        the ledger. One home for the rule, because the scheduler and
        parallel-soak both need it and a second hand-written copy is exactly
        the two-places drift that cost Cultist of Entropy eight sweeps (#121).

        Reaps by IDENTITY -- pid AND launch time -- so a recycled pid belonging
        to somebody else is not a match, and only t-engine is ever killed. Pids
        come from the slot's own home, so a sibling slot's game can never be in
        range.

        Always prints the ledger count, even when it is zero: 0 launches
        recorded means the ledger itself is broken, and silence is how the
        previous, inert reaper hid (#196).

        -Outcome is the run's own result, when the caller knows it, and only
        changes the WORDING -- never whether the line is printed.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Slot,
        # A skipped class launches nothing, so its zero is legitimate. Every
        # full-roster sweep skips Adventurer, so the alarm value fired once per
        # clean run -- and a signal that cries wolf every time teaches the
        # reader, and any script watching the transcript, to filter it out,
        # which restores exactly the blindness #196 removed (#203).
        [string]$Outcome = ''
    )

    $ledger = Join-Path (Join-Path $Slot.Home 'T-Engine\4.0') 'skoobot-bridge\launched.log'
    $entries = @()
    if (Test-Path $ledger) {
        $entries = @(Get-Content $ledger -ErrorAction Ignore | Where-Object { $_.Trim() })
    }
    $reaped = 0
    foreach ($e in $entries) {
        $parts = "$e" -split ','
        $lp = 0; try { $lp = [int]$parts[0] } catch { continue }
        $proc = Get-Process -Id $lp -ErrorAction Ignore
        if (-not $proc -or $proc.ProcessName -ne 't-engine') { continue }
        if ($parts.Count -ge 2) {
            # Identity, not just pid: a recycled pid belongs to someone else.
            try {
                $ls = [datetime]::Parse($parts[1], $null, [Globalization.DateTimeStyles]::RoundtripKind)
                if ([math]::Abs(($proc.StartTime - $ls).TotalSeconds) -gt 5) { continue }
            } catch { continue }
        }
        Stop-Process -Id $lp -Force -ErrorAction Ignore
        $reaped++
    }
    if (Test-Path $ledger) { Remove-Item $ledger -Force -ErrorAction Ignore }
    # A skip with a NON-zero count keeps the alarm form: a class that skipped
    # and still launched something is a real anomaly.
    $note = if ($entries.Count -eq 0 -and $Outcome -eq 'SKIPPED') {
        'skipped, no launch'
    } else {
        "$($entries.Count) launch(es), $reaped reaped" + $(if ($reaped -gt 0) { ' -- a Stop-Game path failed' })
    }
    Write-Host "[slots] slot$($Slot.N) -- ledger: $note"
    return [pscustomobject]@{ Launches = $entries.Count; Reaped = $reaped }
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
