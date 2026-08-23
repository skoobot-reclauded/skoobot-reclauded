<#
    #13 (T-027): the liveness invariant -- no progress in STALL_LIMIT
    act-loop iterations is a livelock, whatever the cause, and a productive
    run trips nothing.

    Two halves, on the fixture (a Cornac Berserker on Trollmire 1):

    (a) The positive control. v1 froze when auto-explore was called while
        the character could not move (the pin / dominate / entangle freeze,
        T-012): the run stops without moving, the bot starts it again, and
        nothing ever spends energy. #7 fixed that at the root with a
        never_move guard on the explore branch, so to reach the spin this
        scenario BYPASSES the guard for the bot alone: the player's attr()
        is shadowed to answer nil for "never_move" when the caller is the
        addon's own Player superload, while the engine's move() -- the same
        method, called from mod/class/Actor.lua -- still sees the pin and
        refuses. That is the T-012 freeze with the fix removed, which is
        exactly the case salvage-yura9111.md says the invariant must catch
        and an invocation counter would have needed a hundred wasted turns
        to. A control run with the guard in place shows the bot handing
        back for "cannot move" first, so the spin is the bypass's doing.

        Asserted: one real activation stops with "no progress in 8
        iterations (state: SAI_STATE_EXPLORE)", in the same frame and with
        game.turn unchanged (the spin is nested act() calls, not turns);
        the trace channel shows exactly 8 driver iterations; the
        "[Liveness]" bug-report line is in the print log; the engine still
        saw the pin.

    (b) The healthy run. The bot is given the rules a player would set (the
        soak's), started on a quiet tile, and polled by game.turn; every
        legitimate hand-back (a dialog, a level change, unspent points, a
        stop condition) is noted and the bot restarted, as the soak does,
        until 1000+ game turns have passed or the deadline. Asserted: the
        invariant never fired; every hand-back carried a reason; the run
        advanced at least -TargetTurns. A run that ends short of the
        target without a trip -- the character died, or kept stopping for
        the same cause in view -- is INCONCLUSIVE, not a failure: it
        measured nothing about liveness.

    Query mode is not used for (a): the invariant lives in the per-turn
    driver, which a real activation reaches and a query does not. The game
    is never saved; the pin, the shadowed attr(), the rules and the log
    level are all undone before the game is stopped.

    Exit codes:  0 pass   1 fail   2 tainted   3 inconclusive (no quiet
    spot, the pin resisted, auto-explore had nothing to explore, or the
    healthy run was cut short -- setup, never product)

    Run:
        powershell -ExecutionPolicy Bypass -File .\tools\scenario-liveness.ps1

    #13 (T-027), #7 (T-012), #46, #27.
#>
[CmdletBinding()]
param(
    [string]$SaveName = 'fixture-berserker',
    # The product's STALL_LIMIT (src/superload/mod/class/Player.lua).
    [int]$StallLimit = 8,
    [int]$TargetTurns = 1000,
    [int]$DeadlineSec = 300,
    [int]$MaxRestarts = 40
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'harness.ps1')

Write-Host ''
Write-Host '[liveness] the progress invariant (#13)'

function Inconclusive($why) {
    Write-Host "[liveness] INCONCLUSIVE - $why"
    Stop-Game
    exit 3
}

try {
    $g = Load-Save -Name $SaveName
    if (-not $g.Ready) { Write-Host "[liveness] FAILED - could not load '$SaveName' ($($g.Reason))"; exit 1 }
    $null = Assert-Result ([pscustomobject]@{ Status = 'OK'; Result = $g.Addons; Tainted = $false }) 'the product is loaded' -Match 'skoobot_reclauded'

    $install = Invoke-Bridge -Lua @'
_G.lv = {}
local b = rawget(_G, "skoobot_reclauded")
if not b then return "ERR no skoobot_reclauded runtime table" end
if not b.log then return "OLD no skoobot_reclauded.log (#46)" end

function lv.hostiles()
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
function lv.onChangeLevel()
  local p = game.player
  return game.level.map:checkEntity(p.x, p.y, engine.Map.TERRAIN, "change_level") ~= nil
end
-- Quiet: nothing in sight, not a level-change tile, and nothing lying on
-- the tile -- auto-explore picks an item up before it moves, and a pinned
-- character CAN do that, which would be one real turn before the spin.
function lv.quietHere()
  local p = game.player
  return lv.hostiles() == 0 and not lv.onChangeLevel()
    and game.level.map:getObject(p.x, p.y, 1) == nil
end
function lv.findQuiet()
  local p = game.player
  for i = 1, 80 do
    if lv.quietHere() then return true end
    p:teleportRandom(p.x, p.y, 60, 10)
  end
  return lv.quietHere()
end
function lv.reset()
  while #game.dialogs > 0 do game:unregisterDialog(game.dialogs[#game.dialogs]) end
  if b.active then b.stop("test reset") end
  local p = game.player
  if p.resting then p:restStop() end
  if p.running then p:runStop() end
  b.state = 11   -- STATE_EXPLORE
  b.activation = nil; b.loop = nil; b.prevloop = nil
  b.last_reason = nil
end

-- The print log since a mark: the bot's lines, and how many were driver
-- iterations (trace) and liveness reports (info).
function lv.mark() return #get_printlog() end
function lv.since(mark)
  local log = get_printlog()
  local out = { all = 0, iterations = 0, liveness = 0, stop = nil }
  for i = mark + 1, #log do
    local s = tostring(log[i][1] or "")
    if s:find("^%[SKOOBOT%]") then
      out.all = out.all + 1
      if s:find("^%[SKOOBOT%] %[trace%] %[PlayerActions%] iteration ") then out.iterations = out.iterations + 1 end
      if s:find("^%[SKOOBOT%] %[Liveness%] no progress in ") then out.liveness = out.liveness + 1 end
      local stop = s:match("^%[SKOOBOT%] %[Stop%] (.*)$")
      if stop then out.stop = stop end
    end
  end
  return out
end

-- The pin, and the bypass. attr() is shadowed on the player instance: the
-- class method still answers everyone else, including the engine's own
-- move(), and is back the moment the shadow is removed.
function lv.pin()
  local p = game.player
  p:setEffect(p.EFF_PINNED, 50, {})
  return p:attr("never_move") and true or false
end
function lv.unpin()
  local p = game.player
  p:removeEffect(p.EFF_PINNED, true, true)
  return p:attr("never_move") and true or false
end
function lv.bypass(on)
  local p = game.player
  if not on then
    p.attr = nil
    return "off engine_sees_pin=" .. tostring(p:attr("never_move") and true or false)
  end
  local real = p.attr   -- the class method, through the metatable
  p.attr = function(self, prop, ...)
    if prop == "never_move" and select("#", ...) == 0 then
      local info = debug.getinfo(2, "S")
      if info and tostring(info.source):find("skoobot_reclauded", 1, true) then return nil end
    end
    return real(self, prop, ...)
  end
  return "on engine_sees_pin=" .. tostring(p:attr("never_move") and true or false)
end

-- (a) the control: pinned, guard in place, one query-mode decision.
function lv.control()
  lv.reset()
  game.player.life = game.player.max_life
  if not lv.pin() then return "SETUP the pin did not take (resisted/immune?)" end
  if lv.hostiles() ~= 0 then return "SETUP a hostile is in view" end
  if lv.onChangeLevel() then return "SETUP on a change-level tile" end
  local before = game.turn
  b.query()
  return ("REASON %s | dturn=%d"):format(tostring(b.last_reason), game.turn - before)
end

-- (a) the freeze: pinned, guard bypassed, one real activation. Everything
-- is read in the frame of the decision, before the engine ticks; the
-- activation either trips the invariant inside start() or is still active
-- when start() returns, and either way it is stopped here.
function lv.freeze()
  lv.reset()
  game.player.life = game.player.max_life
  if not game.player:attr("never_move") and not lv.pin() then return "SETUP the pin did not take" end
  if lv.hostiles() ~= 0 then return "SETUP a hostile is in view" end
  if lv.onChangeLevel() then return "SETUP on a change-level tile" end
  local level = b.log.getLevel()
  b.log.setLevel("trace")
  local by = lv.bypass(true)
  local m = lv.mark()
  local before = game.turn
  b.start()   -- resets b.actions to 0 for the activation
  local active = b.active
  local reason = b.last_reason
  local c = lv.since(m)
  if b.active then b.stop("measured") end
  lv.bypass(false)
  b.log.setLevel(level)
  if game.player.running then game.player:runStop() end
  return ("REASON %s | dturn=%d | active=%s | iterations=%d | liveness=%d | actions=%d | bypass=[%s] | stopline=[%s]"):format(
    tostring(reason), game.turn - before, tostring(active), c.iterations, c.liveness,
    b.actions, by, tostring(c.stop))
end

-- (b) the rules a player would have set (tools/soak.ps1's sk.rules): what
-- the character can fire, then the innate Attack last; sustains kept up;
-- inscriptions that need no target as recovery and damage prevention.
function lv.rules()
  local p = game.player
  local r = b.rules.get(p)
  for _, s in ipairs(b.rules.module.SECTIONS) do
    local l = r[s]
    for i = #l, 1, -1 do l[i] = nil end
  end
  local combat, sustain, recover = {}, {}, {}
  for tid, _ in pairs(p.talents) do
    local t = p:getTalentFromId(tid)
    if t and not t.no_npc_use and not t.no_dumb_use and tid ~= "T_ATTACK" and t.hide ~= "always" then
      if t.mode == "activated" then
        if t.is_inscription and not t.requires_target then recover[#recover+1] = tid
        else combat[#combat+1] = tid end
      elseif t.mode == "sustained" then sustain[#sustain+1] = tid end
    end
  end
  table.sort(combat) table.sort(sustain) table.sort(recover)
  for _, tid in ipairs(combat) do b.rules.module.place(r, {tid=tid}, "Combat") end
  b.rules.module.place(r, {tid="T_ATTACK"}, "Combat")
  for _, tid in ipairs(sustain) do b.rules.module.place(r, {tid=tid}, "Sustain") end
  for _, tid in ipairs(recover) do
    b.rules.module.place(r, {tid=tid}, "Recovery")
    b.rules.module.place(r, {tid=tid}, "DamagePrevention")
  end
  return ("combat=%d sustain=%d recovery=%d"):format(#b.rules.tids(p, "Combat"), #b.rules.tids(p, "Sustain"), #b.rules.tids(p, "Recovery"))
end
function lv.clearRules()
  local r = b.rules.get(game.player)
  for _, s in ipairs(b.rules.module.SECTIONS) do
    local l = r[s]
    for i = #l, 1, -1 do l[i] = nil end
  end
  return "cleared"
end

-- (b) one line per poll: the inspect() line plus what is on screen.
function lv.status()
  local p = game.player
  local d = game.dialogs and game.dialogs[#game.dialogs]
  local dname = "none"
  if d then dname = tostring(d.title or "") .. "/" .. tostring(d.__CLASSNAME or "?") end
  return b.inspect() .. " dead=" .. tostring(p.dead and true or false) .. " dialog=" .. dname:gsub("|", "/")
end
-- The top dialog, through its own EXIT bind, else ACCEPT. Never the death
-- dialog. Returns what was done.
function lv.closeDialog()
  local d = game.dialogs and game.dialogs[#game.dialogs]
  if not d then return "none" end
  if d.__CLASSNAME == "mod.dialogs.DeathDialog" then return "death" end
  local v = d.key and d.key.virtuals
  local function press(virtual)
    bridge.injecting = true
    local ok, err = pcall(d.key.triggerVirtual, d.key, virtual)
    bridge.injecting = false
    if not ok then return "error " .. tostring(err) end
    return virtual
  end
  if v and v.EXIT then return press("EXIT") end
  if v and v.ACCEPT then return press("ACCEPT") end
  if d.use and type(d.list) == "table" and d.list[1] and tostring(d.__CLASSNAME or ""):find("Chat") then
    bridge.injecting = true
    pcall(d.use, d, d.list[1])
    bridge.injecting = false
    return "answered"
  end
  game:unregisterDialog(d)
  return "unregistered"
end
-- One real move to a free adjacent non-stair tile, for a stop that recurs
-- on the spot.
function lv.stepOff()
  local p = game.player
  for _, c in pairs(util.adjacentCoords(p.x, p.y)) do
    local x, y = c[1], c[2]
    if game.level.map:isBound(x, y) and not game.level.map:checkAllEntities(x, y, "block_move")
       and not game.level.map(x, y, engine.Map.ACTOR)
       and not game.level.map:checkEntity(x, y, engine.Map.TERRAIN, "change_level") then
      if p:move(x, y) then p:playerFOV() return "moved" end
    end
  end
  return "nowhere"
end
function lv.start()
  if b.active then return "already active" end
  b.start()
  return "started active=" .. tostring(b.active) .. " reason=" .. tostring(b.last_reason)
end
return "installed"
'@ -TimeoutSec 30
    if ($install.Result -match '^OLD') { Inconclusive $install.Result }
    if (-not (Assert-Result $install 'helpers installed' -Match '^installed')) { Stop-Game; exit 1 }

    $quiet = Invoke-Bridge -Lua 'return tostring(lv.findQuiet())' -TimeoutSec 120
    if ($quiet.Result -ne 'True') { Inconclusive 'no spot with nothing in sight to start from' }

    # -----------------------------------------------------------------------
    # (a) the positive control
    # -----------------------------------------------------------------------
    Write-Host ''
    Write-Host '  --- (a) pinned, guard in place: the bot hands back (T-012, the control)'
    $ctrl = Invoke-Bridge -Lua 'return lv.control()' -TimeoutSec 60
    Write-Host "  $($ctrl.Result)"
    if ($ctrl.Result -match '^SETUP') { Inconclusive "control: $($ctrl.Result)" }
    $null = Assert-Result $ctrl 'with the never_move guard in place the bot hands back for "cannot move"' -Match 'REASON Stopped: cannot move'
    $null = Assert-Result $ctrl 'and the query advances no game turn' -Match 'dturn=0'

    Write-Host ''
    Write-Host "  --- (a) pinned, guard bypassed for the bot: the invariant trips in $StallLimit iterations"
    $freeze = $null
    $turns = Assert-Turns -What 'the spin spent no game time at all: game.turn is unchanged after the engine ran on' -AtMost 0 -Block {
        $script:freeze = Invoke-Bridge -Lua 'return lv.freeze()' -TimeoutSec 120
        Write-Host "  $($script:freeze.Result)"
        Start-Sleep -Seconds 2
    }
    $freeze = $script:freeze
    if ($freeze.Result -match '^SETUP') { Inconclusive "freeze: $($freeze.Result)" }
    if (-not (Assert-Result $freeze 'the activation ran')) { Stop-Game; exit 1 }
    if ($freeze.Result -match 'REASON Cannot act: auto-explore refused to start') { Inconclusive 'auto-explore had nothing to explore from here; the spin could not be built' }
    $null = Assert-Result $freeze 'the engine still saw the pin while the bot did not (the bypass is the bot''s alone)' -Match 'bypass=\[on engine_sees_pin=true\]'
    $null = Assert-Result $freeze "the bot stopped: no progress in $StallLimit iterations, with the AI state in the reason" -Match "REASON Stopped: no progress in $StallLimit iterations \(state: SAI_STATE_EXPLORE\)"
    $null = Assert-Result $freeze 'the trip happened inside the one activation, with no game turn spent' -Match '\| dturn=0 \| active=false \|'
    $null = Assert-Result $freeze "the driver ran exactly $StallLimit iterations before the trip (trace)" -Match "\| iterations=$StallLimit \|"
    $null = Assert-Result $freeze 'the [Liveness] bug-report line, with the inspect() state, is in the log at info' -Match '\| liveness=1 \|'
    $null = Assert-Result $freeze 'the stop line names the state and asks for a report' -Match 'stopline=\[Stopped: no progress in \d+ iterations \(state: SAI_STATE_EXPLORE\) -- please report this\]'
    $null = Assert-Result $freeze 'auto-explore was attempted on every iteration (an action each time, none of them progress)' -Match "\| actions=$StallLimit \|"

    $undo = Invoke-Bridge -Lua 'lv.reset() return "bypass=" .. lv.bypass(false) .. " pinned=" .. tostring(lv.unpin())' -TimeoutSec 30
    Write-Host "  $($undo.Result)"
    $null = Assert-Result $undo 'the pin and the bypass are undone' -Match 'bypass=off engine_sees_pin=false pinned=false'

    # -----------------------------------------------------------------------
    # (b) the healthy run
    # -----------------------------------------------------------------------
    Write-Host ''
    Write-Host "  --- (b) a healthy run: $TargetTurns+ game turns, restarted after each legitimate hand-back"
    $rules = Invoke-Bridge -Lua 'return lv.rules()' -TimeoutSec 30
    Write-Host "  rules: $($rules.Result)"
    $null = Assert-Result $rules 'the fixture has Combat rules for the run' -Match 'combat=[1-9]'
    # REST first, at 70% life: a short rest, then explore, then whatever the
    # level brings.
    $quiet2 = Invoke-Bridge -Lua 'lv.reset() skoobot_reclauded.state = 10 game.player.life = game.player.max_life * 0.7 return tostring(lv.findQuiet())' -TimeoutSec 120
    if ($quiet2.Result -ne 'True') { Inconclusive 'no quiet spot for the healthy run' }

    $t0 = Get-GameTurn
    if ($t0 -lt 0) { Inconclusive 'game.turn unreadable before the run' }
    $s = Invoke-Bridge -Lua 'return lv.start()' -TimeoutSec 60
    Write-Host "  $($s.Result)"

    $deadline = (Get-Date).AddSeconds($DeadlineSec)
    $turn = $t0; $restarts = 0; $tripped = $false; $noReason = 0; $died = $false
    $handbacks = @{}; $lastReason = ''; $sameNoProgress = 0; $lastTurnAtStop = $t0; $endedWhy = 'deadline'
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 3
        if (-not (Test-GameAlive)) { $endedWhy = 'game died'; break }
        $st = Invoke-Bridge -Lua 'return lv.status()' -TimeoutSec 30
        if ($st.Status -ne 'OK') { continue }
        if ($st.Tainted) { $script:HarnessTainted = $true }
        if ($st.Result -match 'turn=(\d+)') { $turn = [int]$Matches[1] }
        Write-Host "  poll  $($st.Result)"
        if ($st.Result -match 'dead=true') { $died = $true; $endedWhy = 'the character died'; break }
        if (($turn - $t0) -ge $TargetTurns -and $st.Result -match 'active=true') { $endedWhy = 'target reached'; break }
        if ($st.Result -match 'active=false') {
            $reason = if ($st.Result -match 'reason=(.*?) dead=') { $Matches[1] } else { 'nil' }
            if ($reason -match 'no progress in \d+ iterations') { $tripped = $true; $endedWhy = 'THE INVARIANT TRIPPED'; break }
            if ($reason -eq 'nil') { $noReason++ }
            if ($handbacks.ContainsKey($reason)) { $handbacks[$reason]++ } else { $handbacks[$reason] = 1 }
            if ($reason -eq $lastReason -and $turn -eq $lastTurnAtStop) { $sameNoProgress++ } else { $sameNoProgress = 0 }
            $lastReason = $reason; $lastTurnAtStop = $turn
            if (($turn - $t0) -ge $TargetTurns) { $endedWhy = 'target reached'; break }
            $restarts++
            if ($restarts -gt $MaxRestarts) { $endedWhy = "more than $MaxRestarts restarts"; break }
            if ($sameNoProgress -ge 3) {
                $step = Invoke-Bridge -Lua 'return lv.stepOff()' -TimeoutSec 30
                Write-Host "  resume  same stop three times with no turn taken -> step off: $($step.Result)"
                if ($sameNoProgress -ge 6) { $endedWhy = "stuck on '$reason'"; break }
            }
            if ($st.Result -match 'dialog=(?!none)') {
                $cd = Invoke-Bridge -Lua 'return lv.closeDialog()' -TimeoutSec 30
                Write-Host "  resume  dialog -> $($cd.Result)"
                if ($cd.Result -eq 'death') { $died = $true; $endedWhy = 'the character died'; break }
            }
            $r = Invoke-Bridge -Lua 'return lv.start()' -TimeoutSec 60
            Write-Host "  resume  restart $restarts after '$reason': $($r.Result)"
        }
    }
    $null = Invoke-Bridge -Lua 'if skoobot_reclauded.active then skoobot_reclauded.stop("measured") end return lv.status()' -TimeoutSec 30
    $adv = $turn - $t0
    Write-Host ''
    Write-Host "  run ended: $endedWhy; game.turn $t0 -> $turn (+$adv); restarts=$restarts"
    foreach ($k in ($handbacks.Keys | Sort-Object)) { Write-Host ("    {0,3} x {1}" -f $handbacks[$k], $k) }

    $null = Assert-Result ([pscustomobject]@{ Status = 'OK'; Result = "tripped=$tripped"; Tainted = $false }) "the invariant never fired across $adv game turns" -Match 'tripped=False'
    $null = Assert-Result ([pscustomobject]@{ Status = 'OK'; Result = "noreason=$noReason"; Tainted = $false }) 'every hand-back carried a reason' -Match 'noreason=0'
    $null = Invoke-Bridge -Lua 'return lv.clearRules()' -TimeoutSec 30
    if (-not $tripped -and $adv -lt $TargetTurns) {
        Inconclusive "the healthy run advanced only $adv of $TargetTurns game turns ($endedWhy); nothing about liveness was measured"
    }
    $null = Assert-Result ([pscustomobject]@{ Status = $(if ($adv -ge $TargetTurns) { 'OK' } else { 'ERR' }); Result = "advanced=$adv"; Tainted = $false }) "the run advanced at least $TargetTurns game turns without tripping ($adv)"
}
finally {
    Stop-Game
}

Write-Host ''
if ($script:HarnessTainted) { Write-Host '[liveness] TAINTED - void, re-run.'; exit 2 }
if ($script:HarnessFailures.Count -gt 0) {
    Write-Host "[liveness] FAILED - $($script:HarnessFailures.Count) check(s):"
    foreach ($f in $script:HarnessFailures) { Write-Host "                 $f" }
    exit 1
}
Write-Host "[liveness] PASS - the T-012 spin trips the invariant in $StallLimit iterations; a healthy run of $TargetTurns+ turns does not"
exit 0
