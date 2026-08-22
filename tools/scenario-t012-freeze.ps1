<#
    T-012 regression: the pin / dominate / sleep freeze (#46).

    Constructs the exact states users reported and asserts the bot hands
    control back instead of spinning or soft-locking:

      * PINNED (never_move) -- the freeze. v1 called auto-explore while unable
        to move, which can never make progress, and looped. The fix guards the
        explore branch with attr("never_move"), so the bot stops.
      * SLEEP (sleep attr) -- "when I get asleep". v1's ASLEEP stop had a
        precedence bug and never fired; the fix gates it on attr("sleep").

    This is a complaint turned into an executable test (the T-006 pattern),
    scoped to T-012. Progress is measured in game.turn; the deadline only
    catches a hang. A bot that DID spin would advance turns without ever
    handing back -- which is the failure this asserts against.

    Exit codes:  0 pass   1 fail   2 tainted   3 inconclusive (effect resisted
    or no quiet spot -- a setup problem, never a product failure)

    Run:
        powershell -ExecutionPolicy Bypass -File .\tools\scenario-t012-freeze.ps1

    T-012.
#>
[CmdletBinding()]
param(
    [string]$SaveName = 'harness',
    [int]$DeadlineSec = 90
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'harness.ps1')

$script:Fail = @()
$script:Tainted = $false
function Check($ok, $what) {
    if ($ok) { Write-Host "  PASS  $what" } else { Write-Host "  FAIL  $what"; $script:Fail += $what }
}

Write-Host ''
Write-Host '[t012] pin / sleep freeze (#46)'

try {
    $g = Load-Save -Name $SaveName
    if (-not $g.Ready) { Write-Host "[t012] FAILED - could not load '$SaveName' ($($g.Reason))"; exit 1 }
    Check ($g.Addons -match 'skoobot_reclauded') 'the product is loaded'

    $null = Invoke-Bridge -Lua @'
_G.bl = {}
function bl.hostiles()
  local p = game.player
  if not p or not p.x or not game.level or not game.level.map then return -1 end
  p:playerFOV()
  local n = 0
  core.fov.calc_circle(p.x, p.y, game.level.map.w, game.level.map.h, p.sight or 10,
    function(_, x, y) return game.level.map:opaque(x, y) end,
    function(_, x, y)
      local a = game.level.map(x, y, game.level.map.ACTOR)
      if a and p:reactionToward(a) < 0 and p:canSee(a) and game.level.map.seens(x, y) then n = n + 1 end
    end, nil)
  return n
end
function bl.onChangeLevel()
  local p = game.player
  return game.level.map:checkEntity(p.x, p.y, engine.Map.TERRAIN, "change_level") ~= nil
end
-- A spot with nothing in sight AND not a level-change tile: the explore branch
-- hands back on a change-level tile before it ever reaches the never_move
-- guard, so the freeze test has to start somewhere the guard is what fires.
function bl.findQuiet()
  local p = game.player
  for i = 1, 80 do
    if bl.hostiles() == 0 and not bl.onChangeLevel() then return true end
    p:teleportRandom(p.x, p.y, 60, 10)
  end
  return bl.hostiles() == 0 and not bl.onChangeLevel()
end
function bl.clearBot()
  local b = rawget(_G, "skoobot_reclauded")
  if b and b.active then b.stop("test reset") end
end
return "installed"
'@ -TimeoutSec 30

    $quiet = Invoke-Bridge -Lua 'return tostring(bl.findQuiet())' -TimeoutSec 120
    if ($quiet.Result -ne 'True') {
        Write-Host '[t012] INCONCLUSIVE - could not find a spot with nothing in sight to test from.'
        Stop-Game; exit 3
    }

    # -----------------------------------------------------------------------
    # Drive ONE decision through query mode and read why the bot would hand
    # back. Query runs a single skoobot_act with do_nothing set, so it spends
    # no player energy and advances no game.turn -- which means nothing wanders
    # into view mid-test (the flake that a toggle-and-poll approach hit: the
    # bot rested, monsters moved, and a hostile routed it into FIGHT before the
    # guard). The bot table is injected into a clean EXPLORE activation at full
    # life on an open tile, so the one decision reaches exactly the guarded path.
    # Returns "REASON <text>" or "SETUP <detail>".
    # -----------------------------------------------------------------------
    function Test-Handback($label, $applyLua, $attrCheck) {
        Write-Host ''
        Write-Host "  --- $label"
        $r = Invoke-Bridge -Lua @"
local p = game.player
skoobot_reclauded.stop("reset")
p:removeEffect(p.EFF_PINNED, true, true)
p:removeEffect(p.EFF_SLEEP, true, true)
p.life = p.max_life
$applyLua
p:playerFOV()
if bl.hostiles() ~= 0 then return "SETUP a hostile is in view: " .. bl.hostiles() end
if bl.onChangeLevel() then return "SETUP on a change-level tile" end
if not ($attrCheck) then return "SETUP effect not applied (resisted/immune?)" end
local b = skoobot_reclauded
b.active = false; b.state = 11; b.last_reason = nil    -- 11 = STATE_EXPLORE
b.activation = nil; b.loop = nil; b.prevloop = nil     -- query builds a fresh one
local before = game.turn
b.query()
return "REASON " .. tostring(b.last_reason) .. " | dturn=" .. tostring(game.turn - before)
"@ -TimeoutSec 30
        if ($r.Status -ne 'OK') { return "SETUP bridge $($r.Status)" }
        if ($r.Tainted) { $script:Tainted = $true }
        Write-Host "  $($r.Result)"
        return $r.Result
    }

    # A control first: with no effect, the bot does NOT hand back here -- it
    # would explore -- so a "cannot move"/"Asleep" reason below is caused by the
    # effect, not by the setup.
    $ctrl = Test-Handback 'control (no effect)' '' 'true'
    if ($ctrl -match '^SETUP') { Write-Host "[t012] INCONCLUSIVE (control: $ctrl)"; Stop-Game; exit 3 }
    Check ($ctrl -notmatch 'cannot move' -and $ctrl -notmatch 'Asleep') 'control: an unafflicted bot does not hand back for a freeze reason'
    Check ($ctrl -match 'dturn=0') 'query advances no game turn (nothing can wander in)'

    # PINNED -> the freeze. The bot must hand back BECAUSE it cannot move,
    # rather than calling auto-explore and spinning.
    $r1 = Test-Handback 'PINNED (the freeze)' 'p:setEffect(p.EFF_PINNED, 20, {})' 'p:attr("never_move")'
    if ($r1 -match '^SETUP') { Write-Host "[t012] INCONCLUSIVE (pinned: $r1)"; Stop-Game; exit 3 }
    Check ($r1 -match 'cannot move') 'PINNED: the bot hands back because it cannot move (was a spin in v1)'

    # SLEEP -> the ASLEEP stop, which never fired in v1.
    $r2 = Test-Handback 'SLEEP (never fired in v1)' 'p:setEffect(p.EFF_SLEEP, 20, {power=1})' 'p:attr("sleep")'
    if ($r2 -match '^SETUP') { Write-Host "[t012] INCONCLUSIVE (sleep: $r2)"; Stop-Game; exit 3 }
    Check ($r2 -match 'Asleep') 'SLEEP: the ASLEEP stop fires (it never did in v1)'
}
finally {
    Stop-Game
}

Write-Host ''
if ($script:Tainted) { Write-Host '[t012] TAINTED - void, re-run.'; exit 2 }
if ($script:Fail.Count -gt 0) {
    Write-Host "[t012] FAILED - $($script:Fail.Count) check(s):"
    foreach ($f in $script:Fail) { Write-Host "                 $f" }
    exit 1
}
Write-Host '[t012] PASS - pinned and asleep both hand control back'
exit 0
