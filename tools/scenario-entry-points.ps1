<#
    #70 / #65: the entry points. RUNONCE twice in one game, and a fresh
    activation for every start(), whatever query() or runonce() left behind.

    What is driven, on the fixture (tools/new-character.ps1 -Class Berserker),
    from a quiet tile each time (nothing in view, off the stairs, full life,
    the bot in EXPLORE so the one decision is "begin exploring"):

      A. RUNONCE twice (#70). Two presses of the real key, through the
         bridge's key injection, each its own command with a real act
         between: each press must run its handler without a Lua error,
         leave bot.runonce a function, count one action, and spend game
         time (game.turn advances by a turn or more once the engine ticks).
         Before the fix the first press replaced the function with the flag
         it set, and the second failed with "attempt to call field
         'runonce' (a boolean value)" -- which is why every other scenario
         presses it at most once, and scenario-flee drives its acts through
         start()/stop() instead.
      B. query() then start() (#65). A query on one tile; then, on another
         tile, a real start() -- the activation it runs on is read in the
         same frame, before stop(): its start tile must be the tile the
         bot was toggled on, not the one the query stood on, and its #13
         counters must be at their first iteration. The activation the
         query left is aged by hand first (iterations 70, stalled 3), so a
         start() that reused it is caught by the counters as well as by
         the tile.
      C. runonce() then start(). The same, after a RUNONCE press: the
         press leaves no activation behind, and the start() is fresh.
      D. query() costs nothing: no game.turn passes, no action is counted,
         and the bot is inactive with do_nothing down afterwards.

    Nothing is hand-cleared from the runtime table between the parts -- the
    product's own bookkeeping is what is under test. The game is never
    saved; the run is ended and the bot stopped after every act.

    Exit codes:  0 pass   1 fail   2 tainted   3 inconclusive (no quiet
    spot, or auto-explore would not start from any -- setup, never product)

    Run:
        powershell -ExecutionPolicy Bypass -File .\tools\scenario-entry-points.ps1

    #70, #65.
#>
[CmdletBinding()]
param(
    [string]$SaveName = 'fixture-berserker',
    # Quiet spots to try before a part is called inconclusive.
    [int]$SpotTries = 3
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'harness.ps1')

Write-Host ''
Write-Host '[entry-points] runonce twice, and a fresh activation for every start (#70, #65)'

function Inconclusive($why) {
    Write-Host "[entry-points] INCONCLUSIVE - $why"
    Stop-Game
    exit 3
}
function Probe($lua, $timeout = 60) {
    $r = Invoke-Bridge -Lua $lua -TimeoutSec $timeout
    if ($r.Tainted) { $script:HarnessTainted = $true }
    if ($r.Status -ne 'OK') { Write-Host "  BRIDGE $($r.Status): $($r.Result)" }
    return $r
}
function Ok($cond, $what, $detail = '') {
    $null = Assert-Result ([pscustomobject]@{ Status = $(if ($cond) { 'OK' } else { 'ERR' }); Result = $detail; Tainted = $false }) $what
}

try {
    $g = Load-Save -Name $SaveName
    if (-not $g.Ready) { Write-Host "[entry-points] FAILED - could not load '$SaveName' ($($g.Reason))"; exit 1 }
    $null = Assert-Result ([pscustomobject]@{ Status = 'OK'; Result = $g.Addons; Tainted = $false }) 'the product is loaded' -Match 'skoobot_reclauded'

    $install = Probe @'
_G.ep = {}
local b = rawget(_G, "skoobot_reclauded")
if not b or type(b.runonce) ~= "function" or type(b.query) ~= "function" then return "OLD no runtime table with runonce()/query()" end

function ep.hostiles()
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
function ep.onChangeLevel()
  local p = game.player
  return game.level.map:checkEntity(p.x, p.y, engine.Map.TERRAIN, "change_level") ~= nil
end
function ep.quietHere()
  return ep.hostiles() == 0 and not ep.onChangeLevel()
end
-- End whatever the last act started, and put the bot in the state every
-- part starts from. The activation is NOT touched: what the entry points
-- do with it is the point.
function ep.settle()
  local p = game.player
  if p.running then p:runStop() end
  if p.resting then p:restStop() end
  while #game.dialogs > 0 do game:unregisterDialog(game.dialogs[#game.dialogs]) end
  if b.active then b.stop("test reset") end
  b.state = 11   -- STATE_EXPLORE
  b.last_reason = nil
  p.life = p.max_life
  return "settled"
end
-- A quiet tile at least ten grids from here: the start tile of the next
-- part must differ from the last one.
function ep.findQuiet()
  local p = game.player
  ep.settle()
  for i = 1, 120 do
    p:teleportRandom(p.x, p.y, 60, 10)
    if ep.quietHere() then return ("%d,%d"):format(p.x, p.y) end
  end
  return "none"
end
function ep.ready()
  local p = game.player
  if #game.dialogs > 0 then return "WAIT a dialog is up" end
  if not p:enoughEnergy() then return "WAIT no energy" end
  if not ep.quietHere() then return "SETUP not quiet any more" end
  return "READY"
end
-- One RUNONCE press, as the player makes it: the bound command through the
-- focused key handler. bridge.key() pcalls the handler and returns
-- "error <msg>" when it raised, so a broken entry point is a readable
-- result, not a dead bridge.
function ep.press()
  local p = game.player
  ep.settle()
  local r = ep.ready()
  if r ~= "READY" then return r end
  local actions, before = b.actions, game.turn
  local key = bridge.key("RUNONCE_SKOOBOT_RECLAUDED")
  return ("PRESS key=[%s] fn=%s active=%s single_run=%s activation=%s actions=+%d running=%s dturn=%d reason=%s"):format(
    tostring(key), type(b.runonce), tostring(b.active), tostring(b.single_run), tostring(b.activation ~= nil),
    b.actions - actions, tostring(p.running ~= nil), game.turn - before, tostring(b.last_reason))
end
-- One query. Whatever it leaves on the table is remembered, so that the
-- start() after it can be checked against it.
function ep.query()
  local p = game.player
  ep.settle()
  local r = ep.ready()
  if r ~= "READY" then return r end
  local actions, before = b.actions, game.turn
  b.query()
  ep.qact = b.activation
  ep.qx, ep.qy = p.x, p.y
  return ("QUERY dturn=%d active=%s do_nothing=%s actions=+%d activation=%s tile=%d,%d running=%s reason=%s"):format(
    game.turn - before, tostring(b.active), tostring(b.do_nothing), b.actions - actions,
    tostring(b.activation ~= nil), p.x, p.y, tostring(p.running ~= nil), tostring(b.last_reason))
end
-- Age whatever activation is on the table, as a run would have: a start()
-- that reuses it then shows these in its counters. stalled stays under
-- STALL_LIMIT, so a reuse is reported by the counters, not by a stop.
function ep.age()
  local act = b.activation
  if not act then return "none" end
  act.iterations = 70
  act.stalled = 3
  return ("aged iterations=%s stalled=%s start=%s,%s"):format(
    tostring(act.iterations), tostring(act.stalled), tostring(act.start_x), tostring(act.start_y))
end
-- One real start(), read in its own frame: the activation the run is on,
-- against the tile and turn the toggle happened at, then stop(). No
-- settle() first beyond what ready() needs: the table is as the previous
-- entry point left it.
function ep.start()
  local p = game.player
  while #game.dialogs > 0 do game:unregisterDialog(game.dialogs[#game.dialogs]) end
  if b.active then return "SETUP the bot is already active" end
  local r = ep.ready()
  if r ~= "READY" then return r end
  b.state = 11
  p.life = p.max_life
  local found = b.activation
  local sx, sy, turn = p.x, p.y, game.turn
  b.start()
  local act = b.activation
  local active, reason, actions = b.active, b.last_reason, b.actions
  if b.active then b.stop("measured") end
  if not act then return ("STOPPED reason=%s found=%s"):format(tostring(reason), tostring(found ~= nil)) end
  return ("START found=%s same=%s start=%d,%d here=%d,%d qtile=%s,%s level=%s iterations=%s stalled=%s last_turn=%s turn=%d left=%s from_query=%s active=%s actions=%d reason=%s"):format(
    tostring(found ~= nil), tostring(found ~= nil and act == found),
    act.start_x, act.start_y, sx, sy, tostring(ep.qx), tostring(ep.qy),
    tostring(act.start_level == game.level), tostring(act.iterations), tostring(act.stalled),
    tostring(act.last_turn), turn, tostring(act.left_start), tostring(act.from_query),
    tostring(active), actions, tostring(reason))
end
return "installed"
'@
    if ($install.Result -match '^OLD') { Inconclusive $install.Result }
    if (-not (Assert-Result $install 'helpers installed' -Match '^installed')) { Stop-Game; exit 1 }

    # A quiet tile, or inconclusive. Returns the "x,y" it landed on.
    function Find-Quiet($label) {
        $q = Probe 'return ep.findQuiet()' 180
        if ($q.Status -ne 'OK' -or $q.Result -notmatch '^\d+,\d+$') { Inconclusive "no quiet tile for $label" }
        return $q.Result
    }
    # Run an entry-point probe until the player is ready to act: a WAIT is
    # the engine still handing the energy back after the last act; a SETUP
    # needs a new tile. Returns the probe result, or $null after $SpotTries
    # tiles.
    function Until-Ready($label, $lua) {
        for ($spot = 1; $spot -le $SpotTries; $spot++) {
            for ($i = 1; $i -le 15; $i++) {
                $r = Probe $lua
                if ($r.Status -ne 'OK') { return $r }
                if ("$($r.Result)" -match '^WAIT') { Start-Sleep -Seconds 2; continue }
                break
            }
            if ("$($r.Result)" -notmatch '^(SETUP|STOPPED|WAIT)') { return $r }
            Write-Host "  $label`: $($r.Result) -- trying another tile"
            $null = Find-Quiet $label
        }
        return $null
    }
    # One RUNONCE press inside a turn count: the press itself, then the
    # ticks that turn the act into game time. The player is made ready
    # BEFORE the count starts: the engine's refill ticks after the last act
    # are up to a full turn of game.turn on their own, and must not pass
    # for this press's act. With energy in hand the game is paused until
    # the press, so nothing moves between the two commands.
    #
    # A tile the engine's auto-explore has no destination from -- a closed
    # pocket a teleport landed in -- makes the bot hand back "auto-explore
    # refused to start": the press ran, but there is no act to measure, so
    # the next tile is tried. Returns the press result, or $null when no
    # tile gave an act.
    function Press-Once($label) {
        for ($spot = 1; $spot -le $SpotTries; $spot++) {
            $ready = Until-Ready $label 'ep.settle() return ep.ready()'
            if (-not $ready -or "$($ready.Result)" -ne 'READY') { return $null }
            $before = Get-GameTurn
            $r = Probe 'return ep.press()'
            Write-Host "  $($r.Result)"
            if ("$($r.Result)" -match 'reason=Cannot act: auto-explore refused to start') {
                Write-Host "  $label`: nowhere to explore from this tile -- trying another"
                $null = Find-Quiet $label
                continue
            }
            Start-Sleep -Seconds 3
            $after = Get-GameTurn
            Ok ($before -ge 0 -and $after -ge 0 -and ($after - $before) -ge 10) "$label spent game time (a real act, at least one turn; game.turn $before -> $after)"
            return $r
        }
        return $null
    }
    function Check-Press($r, $label) {
        if (-not $r) { Inconclusive "$label`: no tile where the press could be made" }
        $null = Assert-Result $r "$label`: the key handler ran without a Lua error" -Match 'key=\[key RUNONCE_SKOOBOT_RECLAUDED\]'
        $null = Assert-Result $r "$label`: bot.runonce is still a function afterwards (#70)" -Match ' fn=function '
        $null = Assert-Result $r "$label`: one action was counted and the bot is inactive with single_run down" -Match ' active=false single_run=false .* actions=\+1 '
        $null = Assert-Result $r "$label`: the press left no activation behind (#65)" -Match ' activation=false '
    }

    # ----- A: RUNONCE twice ---------------------------------------------------
    Write-Host ''
    Write-Host '  --- A. the RUNONCE key, pressed twice in one game (#70)'
    $null = Find-Quiet 'press 1'
    $p1 = Press-Once 'press 1'
    Check-Press $p1 'press 1'

    # Real game time passed and the run may have ended on anything; a fresh
    # tile for the second press, found with the run stopped.
    $null = Find-Quiet 'press 2'
    $p2 = Press-Once 'press 2'
    Check-Press $p2 'press 2'

    # ----- B: query() then start() -------------------------------------------
    Write-Host ''
    Write-Host '  --- B. a query on one tile, a start on another: the start is fresh (#65)'
    $null = Find-Quiet 'query'
    $q = Until-Ready 'query' 'return ep.query()'
    if (-not $q) { Inconclusive 'no tile for the query' }
    Write-Host "  $($q.Result)"
    # ----- D, read off the same query ---------------------------------------
    $null = Assert-Result $q 'D: query advances no game turn and counts no action' -Match '^QUERY dturn=0 .* actions=\+0 '
    $null = Assert-Result $q 'D: query leaves the bot inactive, do_nothing down, and the player standing' -Match ' active=false do_nothing=false .* running=false '
    $aged = Probe 'return ep.age()'
    Write-Host "  query left: $($aged.Result)"

    $null = Find-Quiet 'start after query'
    $s = Until-Ready 'start after query' 'return ep.start()'
    if (-not $s) { Inconclusive 'auto-explore would not start from any tile after the query' }
    Write-Host "  $($s.Result)"
    # The counters are read in the frame of the decision: 0 and 0, or 1 and
    # at most 1 when a character with energy to spare ends the run at once
    # and the driver gets one iteration in. An aged activation reads 70/3.
    $null = Assert-Result $s 'B: the start ran and is active on its own activation' -Match '^START .* active=true actions=[12] reason=nil$'
    $null = Assert-Result $s 'B: the activation is not the one the query built' -Match ' (found=false|same=false) '
    $null = Assert-Result $s 'B: its start tile is the tile the bot was toggled on' -Match ' start=(\d+,\d+) here=\1 '
    if ($s.Result -match ' here=(\d+,\d+) qtile=(\d+,\d+) ') {
        Ok ($Matches[1] -ne $Matches[2]) "B: ... which is not the tile the query stood on ($($Matches[2]))"
    }
    $null = Assert-Result $s 'B: its liveness counters are at their first iteration, on the current turn, on this level' -Match ' level=true iterations=[01] stalled=[01] last_turn=(\d+) turn=\1 '

    # ----- C: runonce() then start() -----------------------------------------
    Write-Host ''
    Write-Host '  --- C. a RUNONCE press on one tile, a start on another: the start is fresh (#65)'
    $null = Find-Quiet 'press 3'
    $p3 = Press-Once 'press 3'
    Check-Press $p3 'press 3'
    $aged = Probe 'return ep.age()'
    Write-Host "  runonce left: $($aged.Result)"

    $null = Find-Quiet 'start after runonce'
    $s2 = Until-Ready 'start after runonce' 'return ep.start()'
    if (-not $s2) { Inconclusive 'auto-explore would not start from any tile after the runonce' }
    Write-Host "  $($s2.Result)"
    $null = Assert-Result $s2 'C: the start ran and is active on its own activation' -Match '^START .* active=true actions=[12] reason=nil$'
    $null = Assert-Result $s2 'C: the activation is not one the runonce left' -Match ' (found=false|same=false) '
    $null = Assert-Result $s2 'C: its start tile is the tile the bot was toggled on' -Match ' start=(\d+,\d+) here=\1 '
    $null = Assert-Result $s2 'C: its liveness counters are at their first iteration, on the current turn, on this level' -Match ' level=true iterations=[01] stalled=[01] last_turn=(\d+) turn=\1 '

    $null = Probe 'return ep.settle()'
}
finally {
    Stop-Game
}

Start-Sleep -Seconds 1
$errs = @((Get-Content $script:LogPath -Raw -ErrorAction Ignore) -split "`r?`n" | Where-Object { $_ -match 'Lua Error' })
Ok ($errs.Count -eq 0) 'no Lua Error in the run'
foreach ($e in ($errs | Select-Object -First 3)) { Write-Host "         $e" }

Write-Host ''
if ($script:HarnessTainted) { Write-Host '[entry-points] TAINTED - void, re-run.'; exit 2 }
if ($script:HarnessFailures.Count -gt 0) {
    Write-Host "[entry-points] FAILED - $($script:HarnessFailures.Count) check(s):"
    foreach ($f in $script:HarnessFailures) { Write-Host "                 $f" }
    exit 1
}
Write-Host '[entry-points] PASS - runonce works every press, and every start begins from where it was toggled'
exit 0
