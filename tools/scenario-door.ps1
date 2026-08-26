<#
    Not being walked into a sealed door (#136).

    The loop the owner watched, and the one that cost the class sweep whole
    runs: explore targets a vault door, the character walks into it, its check
    dialog opens, the bot hands back because a dialog is open, the harness
    closes it and restarts, and explore targets the same door again. In one
    five-minute soak this happened ten times at a single game turn -- turn
    25388 throughout, no turn taken.

    WHY IT REPEATS, which is not what it looks like. ToME already has the
    guard: explore marks a vault door `autoexplore_ignore` when it stops there
    (PlayerExplore.lua:2454) and the flood-fill scan then leaves it out of the
    target list (:2013) -- "we only run to a vault or locked door once". But
    :1866 puts an ignored door BACK at cost 1, top priority, whenever the
    character is standing next to it, so that a player who walks up to a vault
    can still open it. The bot never walks away, so the engine's own guard
    never gets the chance to work.

    So the fix is not to suppress exploring. It is to ask explore where to go
    only from somewhere it can answer -- break the adjacency first.

    STAGING. Doors come after `unseen` in the engine's target chain, so a door
    is only ever chosen once ordinary tiles are exhausted; on a half-explored
    level the bot walks past it and nothing reproduces. The level is therefore
    marked fully seen before the door is placed, which is the state a real run
    reaches on its way to the stairs.

    The door is a clone of an adjacent grid carrying `door_player_check`, the
    same field DOOR_VAULT uses (data/general/grids/basic.lua:269), so it is the
    real terrain predicate rather than a name match. It is restored afterwards.

    What is driven, on the fixture:
      A. the staged door is a consent grid, and starts UNMARKED as a real one
         does -- the engine marks only doors EXPLORE stopped at, never one the
         character was walked into;
      B. the bug is real: with the bot left to itself the check dialog opens;
      C. THE FIX: with the dialog closed, one decision steps AWAY -- distance
         to the door goes above 1 -- instead of walking back in;
      D. #137 first pass: once the step-off allowance is spent the bot heads
         for a known way off the level instead of handing back, so the door
         dialog never comes back and the character does not end up beside it
         again. NOT asserted here: the no-way-off fallback, which needs a level
         with no seen level change and cannot be staged on this fixture -- the
         fixture starts standing on one.

    Exit codes:  0 pass   1 fail   2 tainted   3 inconclusive (no free grid
    beside the player -- a setup problem, never a product failure)

    Run:
        powershell -ExecutionPolicy Bypass -File .\tools\scenario-door.ps1

    #136, and #134 by the same predicate.
#>
[CmdletBinding()]
param(
    [string]$SaveName = 'fixture-berserker'
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'harness.ps1')

$script:Fail = @()
function Check($ok, $what) {
    if ($ok) { Write-Host "  PASS  $what" } else { Write-Host "  FAIL  $what"; $script:Fail += $what }
}

Write-Host ''
Write-Host '[door] not being walked into a sealed door (#136)'

try {
    $g = Load-Save -Name $SaveName
    if (-not $g.Ready) { Write-Host "[door] FAILED - could not load '$SaveName' ($($g.Reason))"; exit 1 }
    Check ($g.Addons -match 'skoobot_reclauded') 'the product is loaded'

    $null = Invoke-Bridge -TimeoutSec 60 -Lua @'
_G.dr = {}
function dr.seeAll()
  local map = game.level.map
  for x = 0, map.w - 1 do for y = 0, map.h - 1 do
    map.has_seens(x, y, true) ; map.remembers(x, y, true)
  end end
  return "seen"
end
function dr.place()
  local p, map = game.player, game.level.map
  for _, dir in ipairs(util.adjacentDirs()) do
    local x, y = util.coordAddDir(p.x, p.y, dir)
    if x > 0 and y > 0 and x < map.w - 1 and y < map.h - 1 then
      local old = map(x, y, engine.Map.TERRAIN)
      if old and not old.change_level and not old.door_player_check then
        local d = old:clone()
        d.name = "sealed door (test)" ; d.is_door = true ; d.notice = true
        d.door_player_check = "This door seems to have been sealed off."
        d.door_opened = "DOOR_OPEN"
        map(x, y, engine.Map.TERRAIN, d) ; map:updateMap(x, y)
        -- NOT set here. The engine only marks a door it stopped EXPLORING at,
        -- never one the character was walked into, so pre-setting it staged a
        -- condition a real run never reaches and hid that both fixes were
        -- inert. The bot must set it itself. See #136.
        map.attrs(x, y, "autoexplore_ignore", nil)
        _G.__dr = { x = x, y = y, old = old }
        p:playerFOV()
        return ("door=%d,%d player=%d,%d consent=%s ignore=%s"):format(
          x, y, p.x, p.y, tostring(skoobot_reclauded.needsConsent(x, y)),
          tostring(map.attrs(x, y, "autoexplore_ignore")))
      end
    end
  end
  return "SETUP no free grid beside the player"
end
function dr.restore()
  if _G.__dr then
    game.level.map(_G.__dr.x, _G.__dr.y, engine.Map.TERRAIN, _G.__dr.old)
    game.level.map:updateMap(_G.__dr.x, _G.__dr.y) ; _G.__dr = nil
  end
  return "restored"
end
function dr.dialogs()
  local d = {}
  for _, dlg in ipairs(game.dialogs or {}) do d[#d+1] = tostring(dlg.title or "?") end
  return (#d > 0) and table.concat(d, ",") or "none"
end
function dr.dist()
  if not _G.__dr then return -1 end
  return core.fov.distance(game.player.x, game.player.y, _G.__dr.x, _G.__dr.y)
end
-- One decision from a clean activation, reporting where it went.
function dr.decide()
  local b = skoobot_reclauded
  b.active = false ; b.state = 11 ; b.last_reason = nil
  b.activation = nil ; b.loop = nil ; b.prevloop = nil
  local fx, fy = game.player.x, game.player.y
  b.start()
  return ("from=%d,%d to=%d,%d dist=%s reason=%s dialogs=%s"):format(
    fx, fy, game.player.x, game.player.y, tostring(dr.dist()),
    tostring(b.last_reason), dr.dialogs())
end
return "installed"
'@

    $null = Invoke-Bridge -TimeoutSec 120 -Lua 'return dr.seeAll()'
    $place = Invoke-Bridge -TimeoutSec 30 -Lua 'return dr.place()'
    Write-Host "  setup: $($place.Result)"
    if ($place.Result -match '^SETUP') {
        Write-Host '[door] INCONCLUSIVE - no free grid beside the player to stage a door on.'
        Stop-Game; exit 3
    }
    Check ($place.Result -match 'consent=true') 'the staged door is a consent grid'
    Check ($place.Result -match 'ignore=nil')   'and starts UNMARKED, as a real vault door does'

    # -----------------------------------------------------------------------
    # B. The bug is real: left to itself, the bot ends up at the door's dialog.
    # -----------------------------------------------------------------------
    $null = Invoke-Bridge -TimeoutSec 30 -Lua 'skoobot_reclauded.stop("reset") skoobot_reclauded.start() return "go"'
    $sawDialog = $false
    for ($i = 1; $i -le 6; $i++) {
        $d = (Invoke-Bridge -TimeoutSec 30 -Lua 'return dr.dialogs()').Result
        if ($d -match 'sealed door') { $sawDialog = $true; break }
        $null = Invoke-Bridge -TimeoutSec 30 -Lua 'if not skoobot_reclauded.active then skoobot_reclauded.start() end return "kick"'
    }
    Check $sawDialog 'the door check dialog does open (the loop this fixes is real)'
    $flag = (Invoke-Bridge -TimeoutSec 30 -Lua 'return tostring(game.level.map.attrs(_G.__dr.x, _G.__dr.y, "autoexplore_ignore"))').Result
    Check ($flag -eq 'true') 'and the bot marks it itself, since the engine does not'

    # -----------------------------------------------------------------------
    # C. The fix. Close the dialog, then take ONE decision: it must step away.
    # -----------------------------------------------------------------------
    $null = Invoke-Bridge -TimeoutSec 30 -Lua 'if #game.dialogs > 0 then bridge.key("EXIT") end return "closed"'
    Check ((Invoke-Bridge -TimeoutSec 30 -Lua 'return dr.dialogs()').Result -eq 'none') 'the dialog closes'
    Check ([int](Invoke-Bridge -TimeoutSec 30 -Lua 'return tostring(dr.dist())').Result -le 1) 'and the character is still beside the door'

    $one = Invoke-Bridge -TimeoutSec 60 -Lua 'return dr.decide()'
    Write-Host "  decision: $($one.Result)"
    $moved = $one.Result -match 'dist=(\d+)'
    $dist  = if ($moved) { [int]$Matches[1] } else { -1 }
    Check ($dist -gt 1) 'one decision breaks adjacency with the door'
    Check ($one.Result -match 'dialogs=none') 'and does not reopen its dialog'

    # -----------------------------------------------------------------------
    # D. Bounded: repeated decisions must not oscillate forever. Put the
    #    character back beside the door and keep deciding on ONE activation.
    # -----------------------------------------------------------------------
    $bounded = Invoke-Bridge -TimeoutSec 120 -Lua @'
local b = skoobot_reclauded
b.active = false ; b.state = 11 ; b.activation = nil ; b.loop = nil ; b.prevloop = nil
local d = _G.__dr
-- #140: reset the activation on every iteration, which is exactly what the
-- harness does after a hand-back. The bound used to live on the activation,
-- so this cleared it every time and the oscillation was unbounded in the one
-- configuration it mattered in. It must still bound.
--
-- #137 first pass: once the bound is used up the bot should head for the way
-- off the level rather than hand back, so the later iterations are expected to
-- report no stop at all.
-- No teleporting between iterations: a forced move grants no energy, so the
-- next real step is refused and the run reads as a product failure when it is
-- the probe's. Let the bot decide for itself and watch where it ends up.
local out = {}
for i = 1, 10 do
  b.active = false ; b.state = 11
  b.activation = nil ; b.loop = nil ; b.prevloop = nil
  b.start()
  out[#out+1] = ("%d:%s@%d,%d"):format(i, tostring(b.last_reason), game.player.x, game.player.y)
  if #game.dialogs > 0 then bridge.key("EXIT") end
end
out[#out+1] = ("final dist to door=%s"):format(tostring(dr.dist()))
return table.concat(out, " | ")
'@
    Write-Host "  bounded: $($bounded.Result)"
    $dialogRepeats = ([regex]::Matches($bounded.Result, 'a dialog is open: sealed door')).Count
    Check ($dialogRepeats -le 1) 'the door dialog does not come back'
    $finalDist = if ($bounded.Result -match 'final dist to door=(-?\d+)') { [int]$Matches[1] } else { -1 }
    Check ($finalDist -gt 1) 'and the character does not end up beside the door again'
    Check ($bounded.Result -notmatch 'keeps drawing exploring back') 'the pre-#137 give-up message is not reached when a way off exists'

    $null = Invoke-Bridge -TimeoutSec 30 -Lua 'skoobot_reclauded.stop("done") return dr.restore()'
}
finally {
    Stop-Game
}

Write-Host ''
if ($script:Fail.Count -gt 0) {
    Write-Host "[door] FAILED - $($script:Fail.Count) check(s):"
    $script:Fail | ForEach-Object { Write-Host "    - $_" }
    exit 1
}
Write-Host '[door] PASS'
exit 0
