<#
    #12: the condition list as data -- capability detection and the act
    loop's response to what a condition blocks, asserted against a live game
    on the fixture (tools/new-character.ps1 -Class Berserker).

    Every probe drives ONE decision through query mode (the T-01x pattern):
    the runtime table is put into a clean activation in the state under
    test, b.query() runs a single skoobot_act with do_nothing set, and
    b.last_reason and the message log say what the bot would have done. No
    game.turn advances, so nothing wanders in and the effects applied for a
    probe do not tick. Combat is [Attack] alone for the run; the four
    SCOUTER_* conditions are IGNORE so that the armoured spawn does not trip
    a power stop; the DEBUFF_* policies are set per probe and every one of
    them is put back; the spawn is removed; the save is never written.

      0. The list: fourteen policy entries -- v1's thirteen codes in v1's
         order plus TURNS_BLACKOUT (#77) after the debuffs -- in
         the saved list and the menu; the liveness entries (CANNOT_MOVE,
         ENCASED) are in the definition list and in neither.
     0b. BLACKOUT (#77), after the quiet spot is found so nothing is in view:
         the fourteenth entry, staged by writing the turn gap
         onto the activation -- query mode takes no turn, so the driver that
         computes the gap never runs. A gap of exactly one player turn is not
         a blackout; more than one hands back with "lost N turns while unable
         to act", singular at one, and the player is told in the message log.
      1. FIGHT, pinned, a hostile adjacent: the bot attacks rather than
         stopping -- "cannot move" does not mean "cannot fight".
      2. FIGHT, pinned, the hostile two grids away: no talent reaches and
         the bot cannot close, so it hands back saying exactly that,
         instead of attempting the step the engine would refuse.
      3. EXPLORE, pinned: hands back "cannot move (pinned, held, or
         overloaded)", as #7 had it and t012 still reads.
      4. Stunned twice over (the attribute at 2, as two sources leave it):
         DEBUFF_STUNNED at STOP fires and names the count. v1 tested `== 1`
         and read this character as unafflicted.
      5. Confused at 30% (the effect's default; the attribute is the
         percentage): DEBUFF_CONFUSED at STOP fires. v1's `== 1` fired only
         at exactly 1%.
      6. Dazed with DEBUFF_DAZED at IGNORE, in EXPLORE: the policy is
         ignored but the block is not -- dazed sets never_move -- so the
         bot hands back "cannot move (dazed)" rather than calling
         auto-explore and spinning.
      7. Asleep with DEBUFF_ASLEEP at IGNORE, in FIGHT: asleep blocks
         talents too, so the bot hands back "cannot act (asleep)".

    Exit codes:  0 pass   1 fail   2 tainted   3 inconclusive (no quiet
    spot, nothing to spawn, the pin resisted -- setup, never product)

    Run:
        powershell -ExecutionPolicy Bypass -File .\tools\scenario-conditions.ps1

    #12, #7, #77, #27.
#>
[CmdletBinding()]
param(
    [string]$SaveName = 'fixture-berserker',
    [string]$Plain = 'T_ATTACK'
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'harness.ps1')

Write-Host ''
Write-Host '[conditions] the condition list as data: capability detection and the blocked response (#12)'

function Inconclusive($why) {
    Write-Host "[conditions] INCONCLUSIVE - $why"
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
    if (-not $g.Ready) { Write-Host "[conditions] FAILED - could not load '$SaveName' ($($g.Reason))"; exit 1 }
    $null = Assert-Result ([pscustomobject]@{ Status = 'OK'; Result = $g.Addons; Tainted = $false }) 'the product is loaded' -Match 'skoobot_reclauded'

    $install = Probe @"
_G.cd = { spawned = nil, saved = nil, tmp = {} }
local b = rawget(_G, "skoobot_reclauded")
if not b or not b.conditions or not b.conditions.module or not b.conditions.capabilities then
  return "OLD no condition list in the runtime table"
end
local PLAIN = "$Plain"
local CONDS = { "SCOUTER_BIGENEMY", "SCOUTER_STRONGERENEMY", "SCOUTER_CROWDPOWER", "SCOUTER_ENEMYCOUNT",
  "DEBUFF_STUNNED", "DEBUFF_CONFUSED", "DEBUFF_DAZED", "DEBUFF_FROZEN", "DEBUFF_ASLEEP", "LIFE_LOWLIFE", "LIFE_BIGLOSS" }

function cd.hostiles()
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
function cd.onChangeLevel()
  local p = game.player
  return game.level.map:checkEntity(p.x, p.y, engine.Map.TERRAIN, "change_level") ~= nil
end
local function free(x, y)
  return game.level.map:isBound(x, y) and not game.level.map:checkAllEntities(x, y, "block_move")
    and not game.level.map(x, y, engine.Map.ACTOR)
end
-- A free grid at exactly `dist` from the player that the player can see,
-- with the grid between free too (dist 2 along a straight line), so that
-- a spawn there is in view and two steps away.
function cd.freeAt(dist)
  local p = game.player
  for _, d in ipairs({ {1,0}, {-1,0}, {0,1}, {0,-1}, {1,1}, {-1,-1}, {1,-1}, {-1,1} }) do
    local ok = true
    for k = 1, dist do
      if not free(p.x + d[1] * k, p.y + d[2] * k) then ok = false break end
    end
    if ok then return p.x + d[1] * dist, p.y + d[2] * dist end
  end
  return nil
end
function cd.findQuiet()
  local p = game.player
  for i = 1, 80 do
    if cd.hostiles() == 0 and not cd.onChangeLevel() and cd.freeAt(2) then return true end
    p:teleportRandom(p.x, p.y, 60, 10)
  end
  return cd.hostiles() == 0 and not cd.onChangeLevel() and cd.freeAt(2) ~= nil
end
function cd.clearTmp()
  local p = game.player
  for _, t in ipairs(cd.tmp) do p:removeTemporaryValue(t[1], t[2]) end
  cd.tmp = {}
end
function cd.addTmp(name, v)
  cd.tmp[#cd.tmp + 1] = { name, game.player:addTemporaryValue(name, v) }
end
function cd.reset()
  while #game.dialogs > 0 do game:unregisterDialog(game.dialogs[#game.dialogs]) end
  if b.active then b.stop("test reset") end
  b.active = false; b.do_nothing = false; b.last_reason = nil
  b.activation = nil; b.loop = nil; b.prevloop = nil
  b.data(game.player).stopwarn = {}
  game.player.life = game.player.max_life
  game.player.talents_cd[PLAIN] = nil
end
function cd.setup()
  local p = game.player
  if not p:knowTalent(PLAIN) then return "SETUP " .. PLAIN .. " is not known" end
  local r = b.rules.get(p)
  for _, s in ipairs(b.rules.module.SECTIONS) do
    local list = r[s]
    for i = #list, 1, -1 do list[i] = nil end
  end
  b.rules.module.place(r, { tid = PLAIN }, "Combat")
  cd.saved = cd.saved or {}
  for _, code in ipairs(CONDS) do
    cd.saved[code] = cd.saved[code] or b.conditions.get(code).stoptype
  end
  cd.policies({})
  return ("OK combat=%s"):format(table.concat(b.rules.tids(p, "Combat"), ","))
end
-- The SCOUTER_* and LIFE_* conditions at IGNORE for the run, the DEBUFF_*
-- ones as given (IGNORE when not).
function cd.policies(t)
  for _, code in ipairs(CONDS) do b.conditions.set(code, t[code] or "IGNORE") end
  return "set"
end
function cd.spawn(dist)
  local p = game.player
  local sx, sy = cd.freeAt(dist)
  if not sx then return "SETUP no free grid at distance " .. dist end
  for _ = 1, 8 do
    local m = game.zone:makeEntity(game.level, "actor",
      { special = function(e) return not e.unique and (e.rank or 1) <= 2 end }, nil, true)
    if not m then return "SETUP no actor to spawn" end
    m.rank = 2
    m.energy.mod = 0
    m.energy.value = 0
    local before = cd.hostiles()
    game.zone:addEntity(game.level, m, "actor", sx, sy)
    if cd.hostiles() == before + 1 then
      cd.spawned = m
      return ("OK %s at %d,%d dist=%d"):format(m.name, m.x, m.y, core.fov.distance(p.x, p.y, m.x, m.y))
    end
    game.level:removeEntity(m, true)
  end
  return "SETUP the spawned actor is not a visible hostile"
end
function cd.unspawn()
  if cd.spawned and cd.spawned.x and not cd.spawned.dead then game.level:removeEntity(cd.spawned, true) end
  cd.spawned = nil
  game.player:playerFOV()
  return "removed"
end
function cd.effects(off)
  local p = game.player
  for _, e in ipairs({ "EFF_PINNED", "EFF_STUNNED", "EFF_CONFUSED", "EFF_DAZED", "EFF_SLEEP" }) do
    if p[e] then p:removeEffect(p[e], true, true) end
  end
  cd.clearTmp()
  return "clear"
end
function cd.restore()
  cd.effects()
  cd.unspawn()
  for code, st in pairs(cd.saved or {}) do b.conditions.set(code, st) end
  cd.saved = nil
  cd.reset()
  if game.player.x then game.player:playerFOV() end
  return "restored"
end
-- The message-log lines added since `before`, newest last, colour stripped.
function cd.newLog(before)
  local ld = game.uiset and game.uiset.logdisplay
  if not ld or not ld.log then return "no logdisplay" end
  local n = math.min(#ld.log - before, 8)
  local out = {}
  for i = n, 1, -1 do out[#out + 1] = (tostring(ld.log[i].str):gsub("#[^#]*#", "")) end
  return table.concat(out, " | ")
end
local function capsText()
  local caps = b.conditions.capabilities()
  local m = b.conditions.module
  return ("move=%s act=%s target=%s"):format(
    caps.move and ("[" .. m.blockedText(caps.move) .. "]") or "no",
    caps.act and ("[" .. m.blockedText(caps.act) .. "]") or "no",
    caps.target and ("[" .. m.blockedText(caps.target) .. "]") or "no")
end
-- One decision through query mode in `state` (11 EXPLORE, 13 FIGHT).
function cd.query(state)
  local p = game.player
  cd.reset()
  b.state = state
  local before = game.turn
  local ld = game.uiset and game.uiset.logdisplay
  local nlog = ld and ld.log and #ld.log or 0
  b.query()
  return ("QUERY dturn=%d hostiles=%d %s stunned=%s confused=%s reason=%s log=%s"):format(game.turn - before,
    cd.hostiles(), capsText(), tostring(p:attr("stunned")), tostring(p:attr("confused")),
    tostring(b.last_reason), cd.newLog(nlog))
end
-- #77: a blackout, staged.
--
-- The gap cannot be produced in query mode: it is computed by the per-turn
-- driver, which runs only when the engine gives the player a turn, and query
-- mode deliberately takes none. So the activation is created by one query,
-- the gap written onto it, and a second query reads it. from_query is
-- cleared first because bot.query() drops an activation a previous query
-- left, which would take the gap with it.
--
-- What this does not cover is the driver's own subtraction, one line at the
-- point last_turn is refreshed. What it does cover is everything after it:
-- that conditionContext carries turnGap, that the fourteenth entry reads it,
-- and that the wording reaches the player.
function cd.blackout(gap)
  local p = game.player
  cd.reset()
  b.state = 13
  b.query()
  if not b.activation then return "SETUP no activation after a query" end
  local primed = tostring(b.last_reason)
  b.activation.from_query = nil
  b.activation.turn_gap = gap
  b.data(p).stopwarn = {}
  local before = game.turn
  local ld = game.uiset and game.uiset.logdisplay
  local nlog = ld and ld.log and #ld.log or 0
  b.query()
  -- Read the gap BACK off the activation. bot.query() drops one a previous
  -- query left (`from_query`), and a stop can clear one too, so the number
  -- the condition saw is not necessarily the number written above -- and a
  -- dropped activation reads as gap 0, which looks exactly like "no
  -- blackout" and is the one way this probe can lie. Reported so a failure
  -- says which it was. Hostiles too: the power conditions are STOP here and
  -- come before BLACKOUT in the list, so anything wandering in would answer
  -- with its own reason.
  local held = b.activation and b.activation.turn_gap
  return ("BLACKOUT gap=%d held=%s hostiles=%d primed=%s dturn=%d reason=%s log=%s"):format(
    gap, tostring(held), cd.hostiles(), primed, game.turn - before,
    tostring(b.last_reason), cd.newLog(nlog))
end
function cd.describe()
  local m = b.conditions.module
  local policy, live, codes = 0, {}, {}
  for _, def in ipairs(m.LIST) do
    if def.default then policy = policy + 1 else live[#live + 1] = def.code end
  end
  local saved = b.conditions.list()
  for _, v in ipairs(saved) do codes[#codes + 1] = v.code end
  local inSave = {}
  for _, v in ipairs(saved) do inSave[v.code] = true end
  local leak = {}
  for _, code in ipairs(live) do if inSave[code] then leak[#leak + 1] = code end end
  return ("policy=%d saved=%d liveness=[%s] leaked=[%s] first=%s last=%s"):format(policy, #saved,
    table.concat(live, ","), table.concat(leak, ","), codes[1], codes[#codes])
end
return "installed"
"@
    if ($install.Result -match '^OLD') { Inconclusive $install.Result }
    if (-not (Assert-Result $install 'helpers installed' -Match '^installed')) { Stop-Game; exit 1 }

    $setup = Probe 'return cd.setup()'
    Write-Host "  $($setup.Result)"
    if ($setup.Result -match '^SETUP') { Inconclusive $setup.Result }
    $null = Assert-Result $setup 'Combat is [Attack] alone' -Match "combat=$Plain$"

    # ----- 0: the list ----------------------------------------------------------
    Write-Host ''
    Write-Host '  --- 0. the list: fourteen policy entries, liveness entries outside the save'
    $d = Probe 'return cd.describe()'
    Write-Host "  $($d.Result)"
    $null = Assert-Result $d 'fourteen policy entries, and the saved list has exactly those' -Match 'policy=14 saved=14 '
    $null = Assert-Result $d 'CANNOT_MOVE and ENCASED are liveness entries of the list' -Match 'liveness=\[CANNOT_MOVE,ENCASED\]'
    $null = Assert-Result $d 'and neither reaches the saved list' -Match 'leaked=\[\]'
    $null = Assert-Result $d "v1's order: DEBUFF_STUNNED first, SCOUTER_CROWDPOWER last" -Match 'first=DEBUFF_STUNNED last=SCOUTER_CROWDPOWER'

    $quiet = Probe 'return tostring(cd.findQuiet())' 120
    if ($quiet.Result -ne 'true') { Inconclusive 'no spot with nothing in sight and two free grids in a line' }

    # ----- BLACKOUT (#77) ---------------------------------------------------
    Write-Host ''
    Write-Host '  --- 0b. BLACKOUT: the turns lost while unable to act'
    $b0 = Probe 'return cd.blackout(0)'
    Write-Host "  $($b0.Result)"
    if ($b0.Result -match '^SETUP') { Inconclusive $b0.Result }
    $null = Assert-Result $b0 'no gap, no stop' -Match ' dturn=0 reason=nil'
    $b1 = Probe 'return cd.blackout(10)'
    Write-Host "  $($b1.Result)"
    $null = Assert-Result $b1 'a gap of exactly one player turn is not a blackout' -Match ' dturn=0 reason=nil'
    # Singular BEFORE plural. Both hand back, and BLACKOUT is a WARN, so
    # running them in the other order made the second depend on the first's
    # acknowledgement being cleared -- which it is, by cd.reset, but that is
    # a dependency the assertions did not need to carry. (One flake in a full
    # library run, 2026-08-23; both cases pass alone.)
    $b3 = Probe 'return cd.blackout(11)'
    Write-Host "  $($b3.Result)"
    $null = Assert-Result $b3 'the gap reached the condition intact' -Match ' held=11 hostiles=0 '
    $null = Assert-Result $b3 'one turn is singular' -Match 'reason=Handed back: lost 1 turn while unable to act'
    $b2 = Probe 'return cd.blackout(35)'
    Write-Host "  $($b2.Result)"
    $null = Assert-Result $b2 'more than one turn hands back' -Match 'reason=Handed back: lost 3 turns while unable to act'
    $null = Assert-Result $b2 'and the player is told in the message log' -Match 'log=.*lost 3 turns while unable to act'
    $null = Assert-Result $b2 'reading it advances no game turn' -Match ' dturn=0 '


    # ----- 1: pinned, FIGHT, adjacent ------------------------------------------
    Write-Host ''
    Write-Host '  --- 1. FIGHT, pinned, a hostile adjacent: the bot attacks'
    $spawn = Probe 'return cd.spawn(1)'
    Write-Host "  $($spawn.Result)"
    if ($spawn.Result -match '^SETUP') { Inconclusive $spawn.Result }
    $ctrl = Probe 'cd.effects() return cd.query(13)'
    Write-Host "  $($ctrl.Result)"
    $null = Assert-Result $ctrl 'control: unafflicted, the bot would attack' -Match 'AI would use the talent Attack'
    $null = Assert-Result $ctrl 'control: nothing is blocked' -Match 'move=no act=no target=no'
    $null = Assert-Result $ctrl 'query advances no game turn' -Match 'dturn=0 '
    $pin = Probe 'local p = game.player cd.effects() p:setEffect(p.EFF_PINNED, 20, {}) return tostring(p:attr("never_move"))'
    if ($pin.Result -eq 'nil' -or $pin.Result -eq 'false') { Inconclusive 'EFF_PINNED did not apply (resisted/immune?)' }
    $q1 = Probe 'return cd.query(13)'
    Write-Host "  $($q1.Result)"
    $null = Assert-Result $q1 'pinned: move is blocked, and named by the generic words' -Match 'move=\[pinned, held, or overloaded\] act=no target=no'
    $null = Assert-Result $q1 'pinned: the bot would still attack the adjacent hostile' -Match 'AI would use the talent Attack'
    $null = Assert-Result $q1 'pinned: no stop -- cannot move is not cannot fight' -Match 'reason=nil'

    # ----- 2: pinned, FIGHT, two grids away --------------------------------------
    Write-Host ''
    Write-Host '  --- 2. FIGHT, pinned, the hostile two grids away: hands back, naming the block'
    $null = Probe 'return cd.unspawn()'
    $spawn2 = Probe 'return cd.spawn(2)'
    Write-Host "  $($spawn2.Result)"
    if ($spawn2.Result -match '^SETUP') { Inconclusive $spawn2.Result }
    $q2 = Probe 'return cd.query(13)'
    Write-Host "  $($q2.Result)"
    $null = Assert-Result $q2 'the bot hands back as CANNOT_ACT, naming the block and the target it cannot reach' -Match 'reason=Cannot act: cannot move \(pinned, held, or overloaded\), and no Combat talent reaches '
    $null = Assert-Result $q2 'no talent was named and no step was attempted' -Match '^(?!.*AI would (use|move))'
    $null = Assert-Result $q2 'query advances no game turn' -Match 'dturn=0 '

    # ----- 3: pinned, EXPLORE ----------------------------------------------------
    Write-Host ''
    Write-Host '  --- 3. EXPLORE, pinned: hands back as before'
    $null = Probe 'return cd.unspawn()'
    $q3 = Probe 'return cd.query(11)'
    Write-Host "  $($q3.Result)"
    $null = Assert-Result $q3 'nothing in view' -Match 'hostiles=0 '
    $null = Assert-Result $q3 'the explore branch hands back "cannot move (pinned, held, or overloaded)"' -Match 'reason=Stopped: cannot move \(pinned, held, or overloaded\)'

    # ----- 4: stunned x2 ------------------------------------------------------------
    Write-Host ''
    Write-Host '  --- 4. stunned twice over, DEBUFF_STUNNED at STOP: fires and names the count'
    $null = Probe 'cd.effects() return "clear"'
    $spawn4 = Probe 'return cd.spawn(1)'
    if ($spawn4.Result -match '^SETUP') { Inconclusive $spawn4.Result }
    $null = Probe 'cd.policies({ DEBUFF_STUNNED = "STOP" }) cd.addTmp("stunned", 1) cd.addTmp("stunned", 1) return "set"'
    $q4 = Probe 'return cd.query(13)'
    Write-Host "  $($q4.Result)"
    $null = Assert-Result $q4 'the attribute reads 2, as two sources leave it' -Match 'stunned=2 '
    $null = Assert-Result $q4 'DEBUFF_STUNNED fires (v1 tested == 1 and missed this)' -Match 'reason=Stopped: you are stunned \(x2\)'
    $null = Assert-Result $q4 'no talent is named' -Match '^(?!.*AI would use)'
    $c4 = Probe 'cd.clearTmp() return cd.query(13)'
    Write-Host "  $($c4.Result)"
    $null = Assert-Result $c4 'with the stun gone the same decision attacks' -Match 'stunned=nil .*AI would use the talent Attack'

    # ----- 5: confused 30% ----------------------------------------------------------
    Write-Host ''
    Write-Host '  --- 5. confused at 30%, DEBUFF_CONFUSED at STOP: fires'
    $conf = Probe 'local p = game.player cd.policies({ DEBUFF_CONFUSED = "STOP" }) p:setEffect(p.EFF_CONFUSED, 5, {power=30}) return tostring(p:attr("confused"))'
    Write-Host "  confused=$($conf.Result)"
    if ($conf.Result -eq 'nil') { Inconclusive 'EFF_CONFUSED did not apply (resisted/immune?)' }
    $q5 = Probe 'return cd.query(13)'
    Write-Host "  $($q5.Result)"
    $null = Assert-Result $q5 'the attribute is the percentage' -Match 'confused=30 '
    $null = Assert-Result $q5 'DEBUFF_CONFUSED fires with the chance in the reason (v1 fired only at exactly 1%)' -Match 'reason=Stopped: you are confused \(30% chance to act randomly\)'
    $null = Assert-Result $q5 'confusion blocks nothing: it is a model-validity stop, not a capability' -Match 'move=no act=no target=no'

    # ----- 6: dazed at IGNORE, EXPLORE ----------------------------------------------
    Write-Host ''
    Write-Host '  --- 6. dazed with DEBUFF_DAZED at IGNORE, EXPLORE: the block is consulted whatever the policy'
    $null = Probe 'cd.effects() cd.unspawn() return "clear"'
    $daze = Probe 'local p = game.player cd.policies({}) p:setEffect(p.EFF_DAZED, 5, {}) return ("dazed=%s never_move=%s"):format(tostring(p:attr("dazed")), tostring(p:attr("never_move")))'
    Write-Host "  $($daze.Result)"
    if ($daze.Result -notmatch 'dazed=\d') {
        Write-Host '  SKIP  EFF_DAZED did not apply (resisted/immune?); the dazed probe is skipped'
    } else {
        $q6 = Probe 'return cd.query(11)'
        Write-Host "  $($q6.Result)"
        $null = Assert-Result $q6 'dazed is named as the block, not the generic catch-all it also trips' -Match 'move=\[dazed\] '
        $null = Assert-Result $q6 'at IGNORE the policy stays silent but the explore branch still hands back for the block' -Match 'reason=Stopped: cannot move \(dazed\)'
    }

    # ----- 7: asleep at IGNORE, FIGHT -----------------------------------------------
    Write-Host ''
    Write-Host '  --- 7. asleep with DEBUFF_ASLEEP at IGNORE, FIGHT: cannot act'
    $null = Probe 'cd.effects() return "clear"'
    $spawn7 = Probe 'return cd.spawn(1)'
    if ($spawn7.Result -match '^SETUP') { Inconclusive $spawn7.Result }
    $sleep = Probe 'local p = game.player cd.policies({}) p:setEffect(p.EFF_SLEEP, 20, {power=1}) return tostring(p:attr("sleep"))'
    Write-Host "  sleep=$($sleep.Result)"
    if ($sleep.Result -eq 'nil') {
        Write-Host '  SKIP  EFF_SLEEP did not apply (resisted/immune?); the asleep probe is skipped'
    } else {
        $q7 = Probe 'return cd.query(13)'
        Write-Host "  $($q7.Result)"
        $null = Assert-Result $q7 'asleep blocks move and act' -Match 'move=\[asleep\] act=\[asleep\] target=no'
        $null = Assert-Result $q7 'the fight branch hands back "cannot act (asleep)" instead of walking the rotation' -Match 'reason=Cannot act: cannot act \(asleep\)'
        $null = Assert-Result $q7 'no talent is named' -Match '^(?!.*AI would use)'
    }

    $null = Probe 'return cd.restore()'
}
finally {
    Stop-Game
}

Start-Sleep -Seconds 1
$errs = @((Get-Content $script:LogPath -Raw -ErrorAction Ignore) -split "`r?`n" | Where-Object { $_ -match 'Lua Error' })
Ok ($errs.Count -eq 0) 'no Lua Error in the run'
foreach ($e in ($errs | Select-Object -First 3)) { Write-Host "         $e" }

Write-Host ''
if ($script:HarnessTainted) { Write-Host '[conditions] TAINTED - void, re-run.'; exit 2 }
if ($script:HarnessFailures.Count -gt 0) {
    Write-Host "[conditions] FAILED - $($script:HarnessFailures.Count) check(s):"
    foreach ($f in $script:HarnessFailures) { Write-Host "                 $f" }
    exit 1
}
Write-Host '[conditions] PASS - the list drives detection, and a blocked capability has a defined response in every state'
exit 0
