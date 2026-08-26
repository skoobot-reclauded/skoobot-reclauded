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
foreach ($f in (Get-ChildItem (Join-Path $Dir '*.json') | Where-Object { $_.Name -notlike '*.soak.json' })) {
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
