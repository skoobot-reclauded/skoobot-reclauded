<#
    T-016 regression: talent-config option labels accumulate a key-char prefix.

    Adding a talent and reopening the "select use type" picker showed labels
    growing "a) a) a) Combat", tracking the number of rules configured. The
    cause was PickOneDialog:generateList writing the key-char prefix back into
    each option's `name`; a SHARED option table (TalentDialog's USE_TYPES
    constant, reused for every rule) therefore accumulated the prefix on each
    open. The fix builds a fresh display list and never mutates the caller's.

    This tests the mechanism directly: construct PickOneDialog twice over one
    shared option list and assert the source list is never mutated, while the
    displayed labels carry the prefix exactly once both times. No full UI drive
    and no game.turn -- deterministic.

    Exit codes:  0 pass   1 fail   2 tainted   3 inconclusive

    Run:
        powershell -ExecutionPolicy Bypass -File .\tools\scenario-t016-label-accumulation.ps1

    T-016.
#>
[CmdletBinding()]
param([string]$SaveName = 'harness')

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'harness.ps1')

$script:Fail = @()
$script:Tainted = $false
function Check($ok, $what) {
    if ($ok) { Write-Host "  PASS  $what" } else { Write-Host "  FAIL  $what"; $script:Fail += $what }
}

Write-Host ''
Write-Host '[t016] talent-config label accumulation'

try {
    $g = Load-Save -Name $SaveName
    if (-not $g.Ready) { Write-Host "[t016] FAILED - could not load '$SaveName' ($($g.Reason))"; exit 1 }
    Check ($g.Addons -match 'skoobot_reclauded') 'the product is loaded'

    # Construct the picker twice over ONE shared option list and report both the
    # source names (must never change) and the displayed names (prefixed once).
    $r = Invoke-Bridge -Lua @'
local ok, res = pcall(function()
  local POD = require "mod.dialogs.skoobot_reclauded.PickOneDialog"
  local shared = { {name="Combat", value="Combat"}, {name="Sustain", value="Sustain"} }
  local d1 = POD.new("t016", shared, function() end)
  local src1  = shared[1].name .. "|" .. shared[2].name
  local disp1 = d1.list[1].name .. "|" .. d1.list[2].name
  local d2 = POD.new("t016", shared, function() end)
  local src2  = shared[1].name .. "|" .. shared[2].name
  local disp2 = d2.list[1].name .. "|" .. d2.list[2].name
  -- neither dialog was registered, so nothing to clean up
  return "src1=[" .. src1 .. "] src2=[" .. src2 .. "] disp1=[" .. disp1 .. "] disp2=[" .. disp2 .. "]"
end)
return ok and res or ("ERR " .. tostring(res))
'@ -TimeoutSec 30
    if ($r.Tainted) { $script:Tainted = $true }
    Write-Host "  $($r.Result)"
    if ($r.Status -ne 'OK' -or $r.Result -match '^ERR') {
        Write-Host "[t016] INCONCLUSIVE - could not construct the dialog: $($r.Result)"; Stop-Game; exit 3
    }

    # The source list must be untouched after BOTH constructions -- this is the
    # bug: a shared list gaining "a) a) ..." on the second open.
    Check ($r.Result -match 'src1=\[Combat\|Sustain\]') 'the shared option list is not mutated by the first open'
    Check ($r.Result -match 'src2=\[Combat\|Sustain\]') 'the shared option list is STILL not mutated by the second open (no accumulation)'
    # The prefix still renders, exactly once, both times.
    Check ($r.Result -match 'disp1=\[a\) Combat\|b\) Sustain\]') 'the displayed labels carry the key-char prefix once (first open)'
    Check ($r.Result -match 'disp2=\[a\) Combat\|b\) Sustain\]') 'the displayed labels are identical on the second open (not a) a) Combat)'
}
finally {
    Stop-Game
}

Write-Host ''
if ($script:Tainted) { Write-Host '[t016] TAINTED - void, re-run.'; exit 2 }
if ($script:Fail.Count -gt 0) {
    Write-Host "[t016] FAILED - $($script:Fail.Count) check(s):"
    foreach ($f in $script:Fail) { Write-Host "                 $f" }
    exit 1
}
Write-Host '[t016] PASS - the picker no longer mutates its option list'
exit 0
