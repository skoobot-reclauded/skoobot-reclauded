<#
    #177: does a freshly birthed Adventurer really begin below LOWHEALTH_RATIO,
    or is the pool computed wrongly?

    The first class sweep found Adventurer taking **0 game turns**, stopping on
    `Low Health Ratio` at birth on every restart. The class has since been
    excluded from sweeps (owner's call, 2026-08-26: it is a naked class meant
    to spend category points, so its performance measures the build rather than
    the class) -- which is right for the sweep and means the instrument that
    found this will never look at it again.

    #177 names two candidate causes, and THEY WANT OPPOSITE FIXES:

      1. the character genuinely begins below the threshold -- a small life
         pool for its level, which is a threshold question for #101 and this
         closes as working-as-designed;
      2. the pool is computed wrongly at birth, so a healthy character reads as
         half-dead -- a data/life.lua defect that every low-pool character is
         quietly paying for, and Adventurer is merely where it is loudest.

    This is not a regression test and is deliberately NOT named scenario-*, so
    run-scenarios does not pick it up: it births characters, which is slow, and
    the question it answers is asked once.

    HOW IT TELLS THEM APART. Reading one class cannot. A pool that looks low
    might be correct for a naked class, and a threshold that looks wrong might
    be right. So it births TWO -- the class under suspicion and a control with
    an ordinary life pool -- and compares life.lua's answer against the raw
    engine fields for both:

      cause (1) looks like: both classes AGREE with their raw life/max_life,
                            and Adventurer's is simply lower
      cause (2) looks like: life.lua DISAGREES with the raw fields, on one
                            class or on both

    A disagreement on the control is the more interesting result of the two,
    because it would mean this was never about Adventurer.

    Exit codes:  0 ran and reported   1 failed   2 tainted   3 inconclusive

    Run:
        powershell -ExecutionPolicy Bypass -File .\tools\probe-life-at-birth.ps1
        powershell -ExecutionPolicy Bypass -File .\tools\probe-life-at-birth.ps1 -Class Summoner

    NOT YET RUN. Written while the harness was reserved for another work
    stream; nothing here has been executed. #177.
#>
[CmdletBinding()]
param(
    [string]$Class = 'Adventurer',
    [string]$Control = 'Berserker',
    [string]$Race = 'Cornac',
    [switch]$SkipBirth
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'harness.ps1')

$script:Fail = @()
function Check($ok, $what) {
    if ($ok) { Write-Host "  PASS  $what" } else { Write-Host "  FAIL  $what"; $script:Fail += $what }
}

# The read, as one bridge call. Everything it needs is already exposed:
# bot.effectiveLife is lifem.of, and the condition list carries the threshold,
# so this asks the product what it thinks rather than recomputing it here --
# a probe that reimplements the thing under test cannot disagree with it.
$LUA = @'
local p = game.player
local b = skoobot_reclauded
if not p then return "ERR no player" end
if not b or not b.effectiveLife then return "ERR this build has no bot.effectiveLife" end
local el = b.effectiveLife(p)
if type(el) ~= "table" then return "ERR effectiveLife returned " .. type(el) end

-- The threshold the stop actually fires on. bot.setting is the product's own
-- effective-value accessor (it is `cfg`, exposed), so this gets defaults and
-- per-character overrides exactly as the running bot would -- not the 0.5 the
-- issue quotes, which is only the default.
local ratio = "?"
if b.setting then local ok, v = pcall(b.setting, "LOWHEALTH_RATIO") if ok and v then ratio = tostring(v) end end

local raw = 0
if (p.max_life or 0) > (p.die_at or 0) then
  raw = ((p.life or 0) - (p.die_at or 0)) / ((p.max_life or 0) - (p.die_at or 0))
end

return ("OK class=%s level=%s life=%s max_life=%s die_at=%s pool=%s safe_fraction=%s raw_fraction=%.4f ratio=%s"):format(
  tostring(p.descriptor and p.descriptor.subclass or "?"), tostring(p.level),
  tostring(p.life), tostring(p.max_life), tostring(p.die_at),
  tostring(el.pool), tostring(el.safe_fraction), raw, ratio)
'@

function Read-Life([string]$saveName, [string]$label) {
    $g = Load-Save -Name $saveName
    if (-not $g.Ready) { Write-Host "[life-at-birth] could not load '$saveName' ($($g.Reason))"; return $null }
    $r = Invoke-Bridge -Lua $LUA -TimeoutSec 60
    Stop-Game | Out-Null
    if ($r.Tainted) { Write-Host '[life-at-birth] TAINTED'; exit 2 }
    Write-Host "  $label  $($r.Result)"
    if ("$($r.Result)" -notmatch '^OK ') { return $null }
    $kv = @{}
    foreach ($tok in ("$($r.Result)" -replace '^OK ', '') -split ' ') {
        $i = $tok.IndexOf('='); if ($i -gt 0) { $kv[$tok.Substring(0, $i)] = $tok.Substring($i + 1) }
    }
    return $kv
}

Write-Host ''
Write-Host "[life-at-birth] is $Class really below the threshold at birth, or is the pool wrong? (#177)"

try {
    $saves = [ordered]@{}
    foreach ($c in @($Class, $Control)) {
        $sn = "probe-life-$($c.ToLower() -replace '[^a-z0-9]', '')"
        $saves[$c] = $sn
        if (-not $SkipBirth) {
            Write-Host ''
            Write-Host "  --- birthing $c as $Race into '$sn'"
            & powershell -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'new-character.ps1') `
                -Name $sn -Class $c -Race $Race | Select-Object -Last 3
            if ($LASTEXITCODE -ne 0) {
                Write-Host "[life-at-birth] INCONCLUSIVE - could not birth $c (exit $LASTEXITCODE)"
                exit 3
            }
        }
    }

    Write-Host ''
    Write-Host '  --- reading both'
    $a = Read-Life $saves[$Class]   "$Class".PadRight(14)
    $b = Read-Life $saves[$Control] "$Control".PadRight(14)
    if (-not $a -or -not $b) { Write-Host '[life-at-birth] INCONCLUSIVE - a read did not come back'; exit 3 }

    # AGREEMENT is the discriminator, not the absolute value. life.lua discounts
    # temporary sources and accounts for die_at (#91), so a small difference is
    # expected and correct; a large one on a character with no effects at birth
    # is the defect.
    $tol = 0.02
    $aGap = [math]::Abs([double]$a['safe_fraction'] - [double]$a['raw_fraction'])
    $bGap = [math]::Abs([double]$b['safe_fraction'] - [double]$b['raw_fraction'])
    # "?" when the accessor was not there. Kept as a distinct state rather than
    # defaulted to 0.5: a verdict computed against a guessed threshold is worse
    # than no verdict, and 0.5 is only the shipped default.
    $ratio = $null
    if ($a['ratio'] -match '^[\d.]+$') { $ratio = [double]$a['ratio'] }

    Write-Host ''
    Write-Host "  $Class safe_fraction=$($a['safe_fraction']) raw=$($a['raw_fraction']) gap=$([math]::Round($aGap,4))"
    Write-Host "  $Control safe_fraction=$($b['safe_fraction']) raw=$($b['raw_fraction']) gap=$([math]::Round($bGap,4))"
    Write-Host "  threshold LOWHEALTH_RATIO=$(if ($null -ne $ratio) { $ratio } else { 'UNREADABLE' })"
    Write-Host ''

    Check ($aGap -le $tol) "life.lua agrees with the raw pool for $Class (gap $([math]::Round($aGap,4)))"
    Check ($bGap -le $tol) "life.lua agrees with the raw pool for $Control (gap $([math]::Round($bGap,4)))"

    Write-Host ''
    if ($aGap -gt $tol -or $bGap -gt $tol) {
        Write-Host '[life-at-birth] VERDICT: cause (2). data/life.lua disagrees with the engine at birth.'
        Write-Host '                 This is a life.lua defect and is NOT confined to one class --'
        Write-Host '                 every low-pool character is paying for it. See #91 for the'
        Write-Host '                 arithmetic that was corrected once already.'
    } elseif ($null -eq $ratio) {
        Write-Host '[life-at-birth] INCONCLUSIVE on the threshold: life.lua agrees with the engine'
        Write-Host '                 for both classes, so it is not cause (2) -- but LOWHEALTH_RATIO'
        Write-Host '                 could not be read, so whether it is cause (1) is unanswered.'
        exit 3
    } elseif ([double]$a['safe_fraction'] -lt $ratio) {
        Write-Host "[life-at-birth] VERDICT: cause (1). $Class genuinely begins below LOWHEALTH_RATIO."
        Write-Host '                 The bot is right and the threshold is the question -- #101 owns'
        Write-Host '                 it, and #177 closes as working-as-designed.'
    } else {
        Write-Host "[life-at-birth] VERDICT: neither. $Class is above the threshold here, so the"
        Write-Host '                 0-turn run had another cause and #177 needs re-scoping rather'
        Write-Host '                 than answering.'
    }

    if ($script:Fail.Count -gt 0) { exit 1 }
    exit 0
} catch {
    Write-Host "[life-at-birth] ERROR $_"
    exit 3
} finally {
    Stop-Game | Out-Null
}
