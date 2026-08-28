<#
    Read a finished class sweep and say what went wrong (#61, #123).

    A sweep leaves 30 soak summaries, up to 90 screenshots and a table of
    outcomes. The table answers "which classes cleared their floor"; it does
    not answer "which runs failed for reasons that are OUR fault", and that is
    the question that turns a sweep into fixes.

    This separates the two. A class that meets Prox and dies is the product
    working; a class that spends four minutes handing back the same stop is a
    defect, and they look identical in the outcome column.

    WHAT COUNTS AS A SUSPECT, and why each one:

      no-progress    the run advanced almost no game turns. Whatever it was
                     doing, it was not playing -- this is the shape every loop
                     found on 2026-08-25 had.
      repeated-stop  one stop reason many times in one run. A stop is the bot
                     handing over; the same one over and over is a loop the
                     harness kept restarting into.
      no-turn-stop   a stop whose first and last turn are equal but which
                     fired repeatedly: the run burned restarts without the
                     game clock moving at all.
      lua-error      an engine error raised during the run. Never expected.
      unbirthable    the class could not be created, which is a harness or
                     roster defect rather than a measurement.
      error-outcome  the sweep scored ERROR.

    Everything it reports is a POINTER, not a verdict. The screenshots and the
    dossiers are the evidence; this says which run to look at.

    Run:
        powershell -ExecutionPolicy Bypass -File .\tools\analyze-sweep.ps1
        powershell -ExecutionPolicy Bypass -File .\tools\analyze-sweep.ps1 -Dir build\results\sweep-pre-20260825
#>
[CmdletBinding()]
param(
    [string]$Dir,
    # A run that advanced fewer than this many game turns did not play.
    # 10 game turns is one player turn; a four-minute run that is working
    # manages thousands.
    [int]$NoProgressTurns = 600,
    # One reason this many times in a single run is a loop, not a decision.
    [int]$RepeatedStop = 5,
    [string]$OutFile
)

$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $PSScriptRoot
if (-not $Dir)     { $Dir = Join-Path $RepoRoot 'build\results\sweep' }
if (-not $OutFile) { $OutFile = Join-Path $Dir 'ANALYSIS.md' }
if (-not (Test-Path $Dir)) { Write-Host "[analyze] no directory at $Dir"; exit 1 }

# The per-class rows are the small files; the .soak.json twins are the runs.
$rows = @()
# A dossier is not a class result. `*.soak.dossier.json` does not match
# `*.soak.json`, so every one of them used to be parsed as a row -- 58 files
# read where 29 exist, and one unparseable dossier killed the whole run (#172).
# The sections that want dossiers open them by name.
foreach ($f in (Get-ChildItem (Join-Path $Dir '*.json') |
                Where-Object { $_.Name -notlike '*.soak.json' -and $_.Name -notlike '*.dossier.json' })) {
    $j = Get-Content $f.FullName -Raw | ConvertFrom-Json
    $soakPath = Join-Path $Dir ($f.BaseName + '.soak.json')
    $soak = if (Test-Path $soakPath) { Get-Content $soakPath -Raw | ConvertFrom-Json } else { $null }
    $rows += [pscustomobject]@{ File = $f.BaseName; Row = $j; Soak = $soak }
}
if ($rows.Count -eq 0) { Write-Host "[analyze] no result files in $Dir"; exit 1 }

$md = New-Object System.Collections.Generic.List[string]
function Say($s) { $md.Add($s); Write-Host $s }

Say "# Sweep analysis -- $Dir"
Say ''
Say "$($rows.Count) class result(s)."
Say ''

# ---------------------------------------------------------------- outcomes --
Say '## Outcomes'
Say ''
Say '| Outcome | Classes |'
Say '|---|---|'
foreach ($g in ($rows | Group-Object { $_.Row.Outcome } | Sort-Object Count -Descending)) {
    Say "| **$($g.Name)** | $($g.Count) -- $((($g.Group | ForEach-Object { $_.Row.Class }) -join ', ')) |"
}
Say ''

# ----------------------------------------------------------- comparability --
# #219: every co-location fix of the last two days stopped at summary.md, so
# ANALYSIS carried none of the facts that say whether these rows can be read
# together. A table that cannot be compared is worse than one that says so.
$notComparable = @($rows | Where-Object { $_.Row.PSObject.Properties['Comparable'] -and -not $_.Row.Comparable })
$condShort  = @($rows | Where-Object { "$($_.Row.ConditionsMissing)" })
$warned     = @($rows | Where-Object { $_.Soak -and @($_.Soak.warnings | Where-Object { $_ }).Count -gt 0 })
$protos     = @($rows | Where-Object { "$($_.Row.Proto)" } | ForEach-Object { "$($_.Row.Proto)" } | Select-Object -Unique)

if ($notComparable.Count -gt 0 -or $condShort.Count -gt 0 -or $warned.Count -gt 0 -or $protos.Count -ne 1) {
    Say '## Comparability'
    Say ''
    if ($protos.Count -gt 1) {
        Say "- **These rows were not all measured by the same protocol** (``proto``: $($protos -join ', ')). Each row is true of its own run; the set is not one measurement (#214, #219)."
        foreach ($pr in $protos) {
            Say "    - ``$pr`` -- $((@($rows | Where-Object { "$($_.Row.Proto)" -eq $pr }) | ForEach-Object { $_.Row.Class }) -join ', ')"
        }
    } elseif ($protos.Count -eq 1) {
        Say "- Protocol: ``$($protos[0])`` for every row."
    } else {
        Say '- **No ``proto`` on any row**, so it cannot be checked that these runs share a protocol (#214). Rows written before that field existed.'
    }
    if ($condShort.Count -gt 0) {
        Say "- **$($condShort.Count) run(s) applied fewer stop conditions than requested** and are not comparable with the rest (#206): $((($condShort | ForEach-Object { "$($_.Row.Class) (missing $($_.Row.ConditionsMissing))" }) -join ', '))."
    }
    if ($warned.Count -gt 0) {
        Say "- **$($warned.Count) run(s) raised a warning** (#205): $((($warned | ForEach-Object { "$($_.Row.Class)" }) -join ', ')). Read ``<class>.soak.md`` before trusting those rows."
        foreach ($w in $warned) {
            foreach ($msg in @($w.Soak.warnings | Where-Object { $_ })) { Say "    - $($w.Row.Class): $msg" }
        }
    }
    if ($notComparable.Count -gt 0) {
        Say "- Outside the headline percentage (``Comparable = false``): $((($notComparable | ForEach-Object { $_.Row.Class }) -join ', '))."
    }
    Say ''
}

# ------------------------------------------------------------------ endings --
$withSoak = @($rows | Where-Object { $_.Soak })
if ($withSoak.Count -gt 0) {
    Say '## How the runs ended'
    Say ''
    Say '| end_reason | Runs |'
    Say '|---|---|'
    foreach ($g in ($withSoak | Group-Object { $_.Soak.end_reason } | Sort-Object Count -Descending)) {
        Say "| $($g.Name) | $($g.Count) |"
    }
    Say ''
}

# ------------------------------------------------------------ stop leaderboard
$stopTally = @{}
foreach ($r in $withSoak) {
    foreach ($s in @($r.Soak.stops)) {
        if (-not $s.reason) { continue }
        if (-not $stopTally.ContainsKey($s.reason)) {
            $stopTally[$s.reason] = [pscustomobject]@{ Reason = $s.reason; Total = 0; Runs = 0; Worst = 0; WorstClass = '' }
        }
        $e = $stopTally[$s.reason]
        $e.Total += $s.count
        $e.Runs  += 1
        if ($s.count -gt $e.Worst) { $e.Worst = $s.count; $e.WorstClass = $r.Row.Class }
    }
}
if ($stopTally.Count -gt 0) {
    Say '## Stops across every run'
    Say ''
    Say 'Sorted by total. `Worst` is the most times one run hit it -- a high worst on a low run count is a loop in one class, not a common condition.'
    Say ''
    Say '| Total | Runs | Worst (class) | Reason |'
    Say '|---|---|---|---|'
    foreach ($e in ($stopTally.Values | Sort-Object Total -Descending | Select-Object -First 25)) {
        Say "| $($e.Total) | $($e.Runs) | $($e.Worst) ($($e.WorstClass)) | ``$($e.Reason)`` |"
    }
    Say ''
}

# ------------------------------------------------------------------ suspects --
$suspects = @()
foreach ($r in $rows) {
    $c = $r.Row.Class
    if ($r.Row.Outcome -eq 'UNBIRTHABLE') {
        $suspects += [pscustomobject]@{ Class = $c; Kind = 'unbirthable'; Detail = "$($r.Row.Detail)" }
    }
    if ($r.Row.Outcome -eq 'ERROR') {
        $suspects += [pscustomobject]@{ Class = $c; Kind = 'error-outcome'; Detail = "lua_errors=$($r.Row.LuaErrors)" }
    }
    if (-not $r.Soak) { continue }
    $delta = 0; if ($r.Soak.turns -and $null -ne $r.Soak.turns.delta) { $delta = [int]$r.Soak.turns.delta }
    if ($delta -lt $NoProgressTurns) {
        $suspects += [pscustomobject]@{ Class = $c; Kind = 'no-progress'; Detail = "$delta game turns, ended $($r.Soak.end_reason)" }
    }
    foreach ($s in @($r.Soak.stops)) {
        if ($s.count -ge $RepeatedStop) {
            $kind = if ($s.first_turn -eq $s.last_turn) { 'no-turn-stop' } else { 'repeated-stop' }
            $suspects += [pscustomobject]@{ Class = $c; Kind = $kind
                Detail = "x$($s.count) at turn $($s.first_turn)$(if ($s.first_turn -ne $s.last_turn) { "-$($s.last_turn)" }): $($s.reason)" }
        }
    }
    # #202 / #209: progression the HARNESS injected. Skirmisher's DIED row left
    # norgos-lair from floor ONE this way and nothing in ANALYSIS could see it
    # -- the trail read like a class that ranged widely. The source floor is the
    # payload: ":1" means the level was explored and no way down was ever seen.
    # Deeper floors are the designed bottom-of-zone hand-off, so they stay quiet.
    if ([int]("0" + "$($r.Row.NextZone)") -gt 0) {
        $from = "$($r.Row.NextZoneFrom)"
        $designed = $from -and ($from -match ':(\d+)$') -and [int]$Matches[1] -ge 2
        if (-not $designed) {
            $suspects += [pscustomobject]@{ Class = $c; Kind = 'injected-exit'
                Detail = "left its zone on the harness's initiative x$($r.Row.NextZone)$(if ($from) { ", first from $from" }) -- not its own progress" }
        }
    }
    if ("$($r.Row.DescendExhausted)") {
        $suspects += [pscustomobject]@{ Class = $c; Kind = 'descend-exhausted'
            Detail = "gave up descending on $($r.Row.DescendExhausted) -- saw a staircase it could not use (#209)" }
    }
    if ($r.Soak.lua_errors -and [int]$r.Soak.lua_errors.count -gt 0) {
        $suspects += [pscustomobject]@{ Class = $c; Kind = 'lua-error'
            Detail = "$($r.Soak.lua_errors.count): $(@($r.Soak.lua_errors.samples) | Select-Object -First 1)" }
    }
}

Say '## Suspects'
Say ''
if ($suspects.Count -eq 0) {
    Say 'None. Every run either played or failed for a reason the product intends.'
} else {
    Say "$($suspects.Count) finding(s). These are pointers to runs worth opening, not verdicts."
    Say ''
    Say '| Class | Kind | Detail |'
    Say '|---|---|---|'
    foreach ($s in ($suspects | Sort-Object Kind, Class)) {
        Say "| $($s.Class) | **$($s.Kind)** | $($s.Detail) |"
    }
}
Say ''

# ----------------------------------------------------------------- escorts ---
# #132 built the instrument and closed without anything reading it. An escortee
# that dies is the clearest thing the sweep measures about protecting someone,
# and the killers say which way it failed: beaten, or never looked at all
# (#143's third lead). See #168.
$escGranted = 0; $escDone = 0; $escFailed = 0; $escSelf = 0
$byKind  = @{}
$killers = @{}
foreach ($r in $withSoak) {
    $e = $r.Soak.escorts
    if (-not $e) { continue }
    $escGranted += [int]$e.granted; $escDone += [int]$e.done
    $escFailed  += [int]$e.failed;  $escSelf += [int]$e.selfkills
    foreach ($row in @($e.rows)) {
        $k = "$($row.kind)"
        if (-not $byKind.ContainsKey($k)) { $byKind[$k] = @{ n = 0; done = 0 } }
        $byKind[$k].n++
        if ($row.status -eq 'DONE') { $byKind[$k].done++ }
        if ($row.status -eq 'FAILED') {
            # The field is `killer`. The quest's own name for it is
            # `killing_npc`, which sk.escorts does not write -- reading that one
            # returns null on every row and reads exactly like an instrument
            # that is not recording.
            $who = if ("$($row.killer)" -ne '') { "$($row.killer)" } else { '(unrecorded)' }
            if ("$($row.selfkill)" -eq 'True' -or "$($row.selfkill)" -eq 'true') { $who = "$who -- self-inflicted" }
            if (-not $killers.ContainsKey($who)) { $killers[$who] = 0 }
            $killers[$who]++
        }
    }
}
if ($escGranted -gt 0) {
    Say '## Escorts'
    Say ''
    $rate = [math]::Round(100.0 * $escDone / $escGranted)
    $selfShare = if ($escFailed -gt 0) { [math]::Round(100.0 * $escSelf / $escFailed) } else { 0 }
    Say "**$escDone of $escGranted survived ($rate%).** $escFailed failed, $escSelf of those self-inflicted ($selfShare%)."
    Say ''
    if ($byKind.Count -gt 0) {
        Say '| Escortee kind | Survived |'
        Say '|---|---|'
        foreach ($k in ($byKind.Keys | Sort-Object { $byKind[$_].n } -Descending)) {
            Say "| $k | $($byKind[$k].done)/$($byKind[$k].n) |"
        }
        Say ''
    }
    if ($killers.Count -gt 0) {
        Say 'What killed the ones that died -- small trash here means the guard never saw it, not that it lost the fight:'
        Say ''
        Say '| Killer | Escorts |'
        Say '|---|---|'
        foreach ($k in ($killers.Keys | Sort-Object { $killers[$_] } -Descending)) {
            Say "| $k | $($killers[$k]) |"
        }
        Say ''
    }
}

# ------------------------------------------------------------------ deaths ---
# #135's payoff: a death with a warning raised is the product judging the fight
# and losing it; a death with nothing raised is the scoring failing to see it
# coming. They read identically in the outcome column and they are opposite
# problems -- the first wants better tactics, the second wants better numbers.
$deathRows = @()
foreach ($r in $rows) {
    $dp = Join-Path $Dir ($r.File + '.soak.dossier.json')
    if (-not (Test-Path $dp)) { $dp = Join-Path $Dir ($r.File + '.dossier.json') }
    if (-not (Test-Path $dp)) { continue }
    try { $d = Get-Content $dp -Raw | ConvertFrom-Json } catch {
        $deathRows += [pscustomobject]@{ Class = $r.Row.Class; Moment = 'UNREADABLE'; Killer = "$($_.Exception.Message)"; Warned = ''; Terms = '' }
        continue
    }
    foreach ($rec in @($d.records)) {
        if ($rec.moment -ne 'death' -and $rec.moment -ne 'predicted_lethal') { continue }
        $flags = @()
        if ($rec.score -and $rec.score.flags) {
            foreach ($n in $rec.score.flags.PSObject.Properties) { if ($n.Value) { $flags += $n.Name } }
        }
        # source may be a same-ref to the player, or a form reference
        $killer = '?'
        $src = $rec.source
        if ($src -and $src.same -eq 'player') { $killer = '(self)' }
        elseif ($src -and $src.form -and $d.creatures.($src.form)) { $killer = $d.creatures.($src.form).name }
        $deathRows += [pscustomobject]@{
            Class  = $r.Row.Class
            Moment = $rec.moment
            Killer = $killer
            Warned = $(if ($flags.Count) { ($flags -join ' ') } else { 'NOTHING RAISED' })
            Terms  = $(if ($rec.score -and $rec.score.terms) { "stronger=$([math]::Round(($rec.score.terms.stronger, 0 -ne $null)[0],2))" } else { '' })
        }
    }
}
if ($deathRows.Count -gt 0) {
    Say '## Deaths, and whether anything was raised first'
    Say ''
    Say 'A death with a flag raised is the product judging the fight and losing it. A death with **NOTHING RAISED** is the scoring not seeing it coming -- the opposite problem, and the one the thresholds are for.'
    Say ''
    Say '| Class | Moment | Killer | Flags at the time | |'
    Say '|---|---|---|---|---|'
    foreach ($x in ($deathRows | Sort-Object Class, Moment)) {
        Say "| $($x.Class) | $($x.Moment) | $($x.Killer) | $($x.Warned) | $($x.Terms) |"
    }
    Say ''
    $unwarned = @($deathRows | Where-Object { $_.Moment -eq 'death' -and $_.Warned -eq 'NOTHING RAISED' })
    Say "**$($unwarned.Count) of $(@($deathRows | Where-Object { $_.Moment -eq 'death' }).Count) confirmed deaths had nothing raised.**"
    Say ''
}

# ------------------------------------------------------- run-stop disagreement
# #153/#164. The engine aborts a run for a hostile; the bot then picks a branch
# from its own view. Every run-abort where the engine could see something and
# the bot stayed in EXPLORE is one turn of the live-lock that cost Shadowblade
# a whole run -- 21,368 turns against a jelly that could never reach it.
$rsRows = @()
foreach ($r in $rows) {
    $dp = Join-Path $Dir ($r.File + '.soak.dossier.json')
    if (-not (Test-Path $dp)) { $dp = Join-Path $Dir ($r.File + '.dossier.json') }
    if (-not (Test-Path $dp)) { continue }
    try { $d = Get-Content $dp -Raw | ConvertFrom-Json } catch { continue }
    $tot = 0; $dis = 0; $who = @{}
    foreach ($rec in @($d.records)) {
        if ($rec.moment -ne 'run_stop') { continue }
        $tot++
        if ([int]$rec.engine_saw -gt 0 -and "$($rec.bot_state)" -eq 'SAI_STATE_EXPLORE') {
            $dis++
            foreach ($n in @($rec.names)) {
                if (-not $who.ContainsKey("$n")) { $who["$n"] = 0 }
                $who["$n"]++
            }
        }
    }
    if ($tot -gt 0) {
        $top = ($who.Keys | Sort-Object { $who[$_] } -Descending | Select-Object -First 3 |
                ForEach-Object { "$_ x$($who[$_])" }) -join ', '
        $rsRows += [pscustomobject]@{ Class = $r.Row.Class; Aborts = $tot; Disagreed = $dis; Blamed = $top }
    }
}
if ($rsRows.Count -gt 0) {
    Say '## Run-aborts where the bot did not act on what the engine saw'
    Say ''
    Say 'The engine refuses to keep running while `spotHostiles` returns anything, using a `seens` map that ACCUMULATES over the run path; the bot then reads a clean one and sees less. Neither view is stale -- the engine''s is a superset. `docs/design-explore-stall.md` has the mechanism.'
    Say ''
    Say '| Class | Run-aborts for a hostile | Bot stayed in EXPLORE | Most often |'
    Say '|---|---|---|---|'
    foreach ($x in ($rsRows | Sort-Object Disagreed -Descending)) {
        Say "| $($x.Class) | $($x.Aborts) | $($x.Disagreed) | $($x.Blamed) |"
    }
    Say ''
    $totDis = ($rsRows | Measure-Object Disagreed -Sum).Sum
    $totAll = ($rsRows | Measure-Object Aborts -Sum).Sum
    $pct = if ($totAll -gt 0) { [math]::Round(100 * $totDis / $totAll) } else { 0 }
    Say "**$totDis of $totAll run-aborts left the bot exploring ($pct%).**"
    Say ''
    # The line this replaces read: "Anything above a handful on one class is
    # #164's live-lock; a flat zero says the two views agree." Sweep 16
    # measured 2100 of 2105 -- every class hundreds of times -- with 29 of 29
    # classes CLEARED and not one IDLE ending. So a high number is NOT the
    # live-lock, and a reader following the old line would have concluded 29 of
    # them. The disagreement is the normal state of affairs; the live-lock is a
    # rare shape it can take. Corrected against the measurement (#153, #164).
    Say 'A high count is **normal and not by itself a fault**: sweep 16 measured 2100 of 2105 with 29 of 29 classes clearing their floor and no IDLE ending at all. The bot explores past it, at a cost of about two turns each time.'
    Say ''
    Say 'What marks the live-lock (#164) is not the count but the **shape**: a run with a large turn total, a near-zero stop count, and no progress -- 21,368 turns over two grids with zero hand-backs. Read this table beside `end_reason` and `Stops`, never on its own.'
    Say ''
}

# ------------------------------------------------------------------ evidence --
$shots = @(Get-ChildItem (Join-Path $Dir '*.timeout-*.png') -ErrorAction SilentlyContinue)
$doss  = @(Get-ChildItem (Join-Path $Dir '*.dossier.json') -ErrorAction SilentlyContinue)
Say '## Evidence on disk'
Say ''
Say "- screenshots: $($shots.Count)$(if ($shots.Count) { " (" + ((@($shots | ForEach-Object { ($_.BaseName -split '\.')[0] } | Sort-Object -Unique)) -join ', ') + ")" })"
Say "- dossiers: $($doss.Count)$(if ($doss.Count) { ', ' + ('{0:N1} MB total' -f (($doss | Measure-Object Length -Sum).Sum / 1MB)) })"
Say ''

($md -join "`n") | Set-Content -Path $OutFile -Encoding utf8
Write-Host ''
Write-Host "[analyze] written to $OutFile"
exit 0
