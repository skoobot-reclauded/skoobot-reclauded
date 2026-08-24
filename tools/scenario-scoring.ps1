<#
    #11: the situation scored -- the four power knobs and the explore-damage
    ratio as the terms of one threat score, and the posture the fight
    branch follows, asserted against a live game on the fixture
    (tools/new-character.ps1 -Class Berserker).

    The numbers are measured, not assumed (the salvage-power pattern):
    hostiles are spawned at a chosen distance in a quiet spot, normal-rank
    with armour added where the probe needs them strong, and every knob a
    probe sets is computed from the measured figures. Every probe drives
    ONE decision through query mode, so no game.turn advances and nothing
    wanders in; skoobot_reclauded.score() reads the evaluation the bot made
    of the same situation.

      A. a crowd of weak mobs at range: no flag, score under 1, posture
         FIGHT -- the bot would close the distance;
      B. one boss (rank 4, x2) adjacent at 40% life, MAX_DIFF_POWER at its
         default and the other two knobs out of reach: STRONGERENEMY stops
         the bot, the reason carries v1's wording and the threat score, and
         the score's own posture is HANDBACK with the same reason;
      C. the same boss adjacent with the single-enemy conditions at IGNORE:
         posture FIGHT (a step away would give it a free hit), the bot
         would attack;
      D. the same boss three grids away at IGNORE: posture RETREAT, the bot
         would take a flee step away from it before anything else;
      E. three armoured normals two grids away over a zero crowd margin,
         CROWDPOWER at IGNORE: posture HOLD, the bot would wait for them to
         come into reach rather than walk into them;
      F. a 5% scratch while exploring at 50% life with nothing in view: the
         T-011 stop fires with the explore-damage term as the threat;
      G. a grid the player must consent to enter -- a clone of the terrain
         between the bot and a hostile, with door_player_check set -- is not
         a route: the bot goes round it or says there is no path, and never
         steps onto it (#64). A sealed vault door sets no block_move, so
         Astar treated it as passable and the bot walked into its own
         yes/no popup, over and over.

    The SCOUTER_* conditions are STOP and LIFE_LOWLIFE / LIFE_BIGLOSS are
    IGNORE for the probes unless a probe says otherwise; Combat is [Attack]
    alone; settings, conditions, life, the spawns are all put back; the
    save is never written.

    Exit codes:  0 pass   1 fail   2 tainted   3 inconclusive (no quiet
    spot with room, nothing to spawn, or the spawn is not a visible hostile
    -- setup, never product)

    Run:
        powershell -ExecutionPolicy Bypass -File .\tools\scenario-scoring.ps1

    #11, #62, #64, #81, #27.
#>
[CmdletBinding()]
param(
    [string]$SaveName = 'fixture-berserker',
    [string]$Plain = 'T_ATTACK'
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'harness.ps1')

Write-Host ''
Write-Host '[scoring] the situation scored: terms, flags, posture (#11)'

function Inconclusive($why) {
    Write-Host "[scoring] INCONCLUSIVE - $why"
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
# Lua's tostring of a number for a probe option line. Invariant culture so a
# comma-decimal locale cannot turn 0.4 into "0,4".
function N($x) { return ([double]$x).ToString('0.####', [Globalization.CultureInfo]::InvariantCulture) }

try {
    $g = Load-Save -Name $SaveName
    if (-not $g.Ready) { Write-Host "[scoring] FAILED - could not load '$SaveName' ($($g.Reason))"; exit 1 }
    $null = Assert-Result ([pscustomobject]@{ Status = 'OK'; Result = $g.Addons; Tainted = $false }) 'the product is loaded' -Match 'skoobot_reclauded'

    $install = Probe @"
_G.sc = { spawned = {}, saved = nil }
local b = rawget(_G, "skoobot_reclauded")
if not b or not b.score or not b.conditions or not b.rules then return "OLD no score() in the runtime table" end
local PLAIN = "$Plain"
local SETTINGS = { "MAX_INDIVIDUAL_POWER", "MAX_DIFF_POWER", "MAX_COMBINED_POWER", "MAX_ENEMY_COUNT",
  "NORMAL_POWER_RATIO", "ELITES_POWER_RATIO", "BOSS_POWER_RATIO", "LOWHEALTH_RATIO", "IGNORE_DAMAGE_HEALTH_RATIO" }
local CONDS = { SCOUTER_BIGENEMY = "STOP", SCOUTER_STRONGERENEMY = "STOP", SCOUTER_CROWDPOWER = "STOP",
  SCOUTER_ENEMYCOUNT = "STOP", LIFE_LOWLIFE = "IGNORE", LIFE_BIGLOSS = "IGNORE" }

function sc.hostiles()
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
function sc.onChangeLevel()
  local p = game.player
  return game.level.map:checkEntity(p.x, p.y, engine.Map.TERRAIN, "change_level") ~= nil
end
local function free(x, y)
  return game.level.map:isBound(x, y) and not game.level.map:checkAllEntities(x, y, "block_move")
    and not game.level.map(x, y, engine.Map.ACTOR)
end
local DIRS = { {1,0}, {-1,0}, {0,1}, {0,-1}, {1,1}, {-1,-1}, {1,-1}, {-1,1} }
-- A direction with 'dist' free grids in a straight line from the player,
-- and the grid on the opposite side free too (a flee step needs somewhere
-- to go). Returns dx, dy or nil.
function sc.line(dist)
  local p = game.player
  for _, d in ipairs(DIRS) do
    local ok = free(p.x - d[1], p.y - d[2])
    for k = 1, dist do
      if not free(p.x + d[1] * k, p.y + d[2] * k) then ok = false break end
    end
    if ok then return d[1], d[2] end
  end
  return nil
end
-- Free grids at exactly 'dist' in straight lines, up to n of them.
function sc.freeAt(dist, n)
  local p = game.player
  local out = {}
  for _, d in ipairs(DIRS) do
    local ok = true
    for k = 1, dist do
      if not free(p.x + d[1] * k, p.y + d[2] * k) then ok = false break end
    end
    if ok then out[#out + 1] = { p.x + d[1] * dist, p.y + d[2] * dist } end
    if #out >= n then break end
  end
  return out
end
function sc.quietHere()
  return sc.hostiles() == 0 and not sc.onChangeLevel() and sc.line(3) ~= nil and #sc.freeAt(2, 3) >= 3
end
function sc.findQuiet()
  local p = game.player
  for i = 1, 120 do
    if sc.quietHere() then return true end
    p:teleportRandom(p.x, p.y, 60, 10)
  end
  return sc.quietHere()
end
function sc.save()
  if sc.saved then return end
  local s = config.settings.tome.skoobot_reclauded
  sc.saved = { settings = {}, conds = {} }
  for _, k in ipairs(SETTINGS) do sc.saved.settings[k] = s[k] end
  for c in pairs(CONDS) do sc.saved.conds[c] = b.conditions.get(c).stoptype end
end
function sc.restore()
  if not sc.saved then return "nothing saved" end
  local s = config.settings.tome.skoobot_reclauded
  for k, v in pairs(sc.saved.settings) do s[k] = v end
  for c, v in pairs(sc.saved.conds) do b.conditions.set(c, v) end
  game.player.life = game.player.max_life
  b.data(game.player).stopwarn = {}
  return "restored"
end
function sc.setup()
  local p = game.player
  if not p:knowTalent(PLAIN) then return "SETUP " .. PLAIN .. " is not known" end
  local r = b.rules.get(p)
  for _, s in ipairs(b.rules.module.SECTIONS) do
    local list = r[s]
    for i = #list, 1, -1 do list[i] = nil end
  end
  b.rules.module.place(r, { tid = PLAIN }, "Combat")
  sc.save()
  return ("OK combat=%s"):format(table.concat(b.rules.tids(p, "Combat"), ","))
end
-- A clean, inactive activation in 'state' at full life with the saved
-- settings and the probe's condition policies (overridden by 'conds').
function sc.reset(state, conds)
  sc.save()
  local p = game.player
  local s = config.settings.tome.skoobot_reclauded
  for k, v in pairs(sc.saved.settings) do s[k] = v end
  for c, v in pairs(CONDS) do b.conditions.set(c, (conds and conds[c]) or v) end
  b.data(p).stopwarn = {}
  while #game.dialogs > 0 do game:unregisterDialog(game.dialogs[#game.dialogs]) end
  if b.active then b.stop("test reset") end
  p.life = p.max_life
  p.talents_cd[PLAIN] = nil
  b.active = false; b.do_nothing = false; b.state = state or 13; b.last_reason = nil
  b.activation = nil; b.loop = nil; b.prevloop = nil
end
-- Spawn a normal-rank hostile at (x, y) with 'armor' added and 'rank' set.
local function spawnAt(x, y, armor, rank)
  for _ = 1, 8 do
    local m = game.zone:makeEntity(game.level, "actor",
      { special = function(e) return not e.unique and (e.rank or 1) <= 2 end }, nil, true)
    if not m then return nil, "SETUP no actor to spawn" end
    m.rank = rank or 2
    m.combat_armor = (m.combat_armor or 0) + (armor or 0)
    m.energy.mod = 0
    m.energy.value = 0
    local before = sc.hostiles()
    game.zone:addEntity(game.level, m, "actor", x, y)
    if sc.hostiles() == before + 1 then sc.spawned[#sc.spawned + 1] = m return m end
    game.level:removeEntity(m, true)
  end
  return nil, "SETUP the spawned actor is not a visible hostile"
end
-- n hostiles at distance 'dist' in straight lines, armoured by 'armor'.
function sc.spawn(n, dist, armor, rank)
  local grids = sc.freeAt(dist, n)
  if #grids < n then return "SETUP only " .. #grids .. " free grids at distance " .. dist end
  for i = 1, n do
    local m, err = spawnAt(grids[i][1], grids[i][2], armor, rank)
    if not m then return err end
  end
  return ("OK %d at distance %d"):format(n, dist)
end
-- One hostile along the free line at 'dist', so that a step away exists.
function sc.spawnLine(dist, armor, rank)
  local p = game.player
  local dx, dy = sc.line(3)
  if not dx then return "SETUP no free line" end
  local m, err = spawnAt(p.x + dx * dist, p.y + dy * dist, armor, rank)
  if not m then return err end
  return ("OK %s at distance %d"):format(m.name, core.fov.distance(p.x, p.y, m.x, m.y))
end
function sc.unspawn()
  for _, m in ipairs(sc.spawned) do if m.x and not m.dead then game.level:removeEntity(m, true) end end
  sc.spawned = {}
  game.player:playerFOV()
  return "removed"
end
-- The measured figures: own power at full life, each spawn's weighted power.
function sc.numbers()
  local p = game.player
  p.life = p.max_life
  p:playerFOV()
  local v = b.score()
  local ws = {}
  for _, h in ipairs(sc.spawned) do ws[#ws + 1] = ("%.2f"):format(b.power(h)) end
  return ("own=%.4f max=%.4f sum=%.4f count=%d raw=%s"):format(v.figures.own, v.figures.max, v.figures.sum,
    v.figures.count, table.concat(ws, ","))
end
-- The message-log lines added since 'before', newest last, colour stripped.
local function newLog(before)
  local ld = game.uiset and game.uiset.logdisplay
  if not ld or not ld.log then return "no logdisplay" end
  local n = math.min(#ld.log - before, 8)
  local out = {}
  for i = n, 1, -1 do out[#out + 1] = (tostring(ld.log[i].str):gsub("#[^#]*#", "")) end
  return table.concat(out, " | ")
end
local function verdict()
  local v = b.score()
  local flags = {}
  for _, code in ipairs({ "SCOUTER_BIGENEMY", "SCOUTER_STRONGERENEMY", "SCOUTER_CROWDPOWER", "SCOUTER_ENEMYCOUNT" }) do
    if v.flags[code] then flags[#flags + 1] = code:gsub("SCOUTER_", "") end
  end
  return ("score=%.2f posture=%s flags=[%s] terms=[ind=%.2f str=%.2f crowd=%.2f count=%.2f] why=[%s]"):format(
    v.score, v.posture, table.concat(flags, ","), v.terms.individual, v.terms.stronger, v.terms.crowd,
    v.terms.count, table.concat(v.reasons, "; "))
end
-- One decision in query mode. o: settings to override, 'conds', 'life'
-- (a fraction), 'state' (11 EXPLORE, 13 FIGHT; default FIGHT).
function sc.probe(o)
  o = o or {}
  sc.reset(o.state, o.conds)
  local p = game.player
  local s = config.settings.tome.skoobot_reclauded
  for _, k in ipairs(SETTINGS) do if o[k] ~= nil then s[k] = o[k] end end
  if o.life then p.life = math.floor(p.max_life * o.life) end
  p:playerFOV()
  if sc.hostiles() ~= #sc.spawned then
    return "SETUP " .. sc.hostiles() .. " hostiles in view, expected " .. #sc.spawned
  end
  local before = game.turn
  local ld = game.uiset and game.uiset.logdisplay
  local nlog = ld and ld.log and #ld.log or 0
  local v = verdict()
  -- #79: what the bot compares with, asked of the addon rather than
  -- recomputed here. The heuristic itself depends on life (the survival
  -- score does) AND the life scaling is a curve since #79, so re-deriving
  -- it on this side would be two chances to drift.
  local mine = b.ownPower(p)
  b.query()
  return ("QUERY dturn=%d hostiles=%d life=%d/%d mine=%.1f %s reason=%s log=%s"):format(game.turn - before,
    sc.hostiles(), p.life, p.max_life, mine, v, tostring(b.last_reason), newLog(nlog))
end
-- #64: seal one grid and see the bot refuse to route through it.
--
-- A sealed vault door sets no block_move, so Astar treats it as passable
-- for the player: with a hostile past one, the FIGHT branch's path ran
-- straight into it, the yes/no popup opened, and a dialog is a hand-back.
-- The first long soak measured 65 of 66 stops in ten minutes as exactly
-- this loop.
--
-- Made deterministic here rather than waiting for a vault: the grid between
-- the player and a hostile two squares away gets a CLONE of its own terrain
-- with door_player_check set -- a clone, because the terrain entity is a
-- shared prototype and writing on it would seal every grid of that kind on
-- the level -- and the original is put back afterwards.
function sc.sealed()
  local p = game.player
  sc.reset(13)
  local dx, dy = sc.line(3)
  if not dx then return "SETUP no free line" end
  local bx, by = p.x + dx, p.y + dy               -- the grid to seal
  local m, err = spawnAt(p.x + dx * 2, p.y + dy * 2, 0, 2)
  if not m then return err or "SETUP no actor to spawn" end
  p:playerFOV()

  local Map = engine.Map
  local was = game.level.map(bx, by, Map.TERRAIN)
  if not was then return "SETUP no terrain to clone" end
  local seal = was:clone()
  seal.door_player_check = "TEST seal"
  game.level.map(bx, by, Map.TERRAIN, seal)
  game.level.map:updateMap(bx, by)

  local consentHere = b.needsConsent(bx, by)
  local consentAway = b.needsConsent(p.x - dx, p.y - dy)
  local ld = game.uiset and game.uiset.logdisplay
  local nlog = ld and ld.log and #ld.log or 0
  local turn0, x0, y0 = game.turn, p.x, p.y
  b.query()
  -- The direction of the sealed grid, so the check can say "not that way"
  -- without knowing the geometry it happened to get.
  local sealdir = game.level.map:compassDirection(dx, dy)
  local out = ("SEALED consent=%s consent_elsewhere=%s sealdir=%s dturn=%d moved=%s reason=%s log=%s"):format(
    tostring(consentHere), tostring(consentAway), tostring(sealdir), game.turn - turn0,
    tostring(p.x ~= x0 or p.y ~= y0), tostring(b.last_reason), newLog(nlog))

  game.level.map(bx, by, Map.TERRAIN, was)
  game.level.map:updateMap(bx, by)
  sc.unspawn()
  sc.reset(13)
  return out .. (" restored=%s"):format(tostring(game.level.map(bx, by, Map.TERRAIN) == was))
end
-- The T-011 situation: an EXPLORE decision that took a 5% loss this turn
-- at 'life' (a fraction), nothing in view.
function sc.scratch(life)
  sc.reset(11)
  local p = game.player
  p.life = math.floor(p.max_life * life)
  p:playerFOV()
  if sc.hostiles() ~= 0 then return "SETUP a hostile is in view" end
  local unspent = (p.unused_talents or 0) + (p.unused_generics or 0)
    + (p.unused_talents_types or 0) + (p.unused_stats or 0) + (p.unused_prodigies or 0)
  b.activation = { iterations = 0, last_turn = game.turn, stalled = 0, unspentTotal = unspent,
    start_level = game.level, start_x = -1, start_y = -1, left_start = true }
  b.loop = { life = p.life + math.floor(p.max_life * 0.05), thinkCount = 0, talentfailed = {} }
  b.prevloop = nil
  local before = game.turn
  b.query()
  return ("QUERY dturn=%d life=%d/%d reason=%s"):format(game.turn - before, p.life, p.max_life, tostring(b.last_reason))
end
return "installed"
"@
    if ($install.Result -match '^OLD') { Inconclusive $install.Result }
    if (-not (Assert-Result $install 'helpers installed' -Match '^installed')) { Stop-Game; exit 1 }

    $setup = Probe 'return sc.setup()'
    Write-Host "  $($setup.Result)"
    if ($setup.Result -match '^SETUP') { Inconclusive $setup.Result }
    $null = Assert-Result $setup 'Combat is [Attack] alone' -Match "combat=$Plain$"

    if ((Probe 'return tostring(sc.findQuiet())' 180).Result -ne 'true') { Inconclusive 'no quiet spot with a free line of three and three free grids at distance two' }

    $own0 = Probe 'return ("own=%.4f"):format(skoobot_reclauded.score().figures.own)'
    if ($own0.Result -notmatch 'own=([\d.]+)') { Inconclusive "could not read own power: $($own0.Result)" }
    $own = [double]$Matches[1]
    $armor = [math]::Max(500, [math]::Ceiling(3 * $own))
    Write-Host ("  own power at full life = {0:F2}; strong spawns get armour +{1}" -f $own, $armor)

    # ----- A: a crowd of weak mobs at range ----------------------------------------
    Write-Host ''
    Write-Host '  --- A. three unarmoured normals two grids away: under every limit, FIGHT'
    $sp = Probe 'return sc.spawn(3, 2, 0, 2)'
    Write-Host "  $($sp.Result)"
    if ($sp.Result -match '^SETUP') { Inconclusive $sp.Result }
    $n = Probe 'return sc.numbers()'
    Write-Host "  $($n.Result)"
    if ($n.Result -notmatch 'own=([\d.]+) max=([\d.]+) sum=([\d.]+) count=(\d+)') { Inconclusive "could not parse the figures: $($n.Result)" }
    $maxW = [double]$Matches[2]; $sumW = [double]$Matches[3]
    # "Weak" by construction: the knobs are set so each term is at most 0.5.
    $Mi = [math]::Max(200, 2 * $maxW + 1); $Md = [math]::Max(10, 2 * $maxW - $own + 1); $Mc = [math]::Max(500, 2 * $sumW - $own + 1)
    $a = Probe "return sc.probe({ MAX_INDIVIDUAL_POWER = $(N $Mi), MAX_DIFF_POWER = $(N $Md), MAX_COMBINED_POWER = $(N $Mc) })"
    Write-Host "  $($a.Result)"
    if ($a.Result -match '^SETUP') { Inconclusive $a.Result }
    $null = Assert-Result $a 'no flag is set' -Match 'flags=\[\] '
    $null = Assert-Result $a 'the posture is FIGHT' -Match 'posture=fight '
    $null = Assert-Result $a 'the reason names the count and the score' -Match 'why=\[3 in view, none over a limit -- threat \d\.\d\]'
    $null = Assert-Result $a 'the bot does not stop' -Match 'reason=nil'
    $null = Assert-Result $a 'with nothing in reach it would close the distance' -Match 'AI would move to the'
    # ...which is also the guard on #81's trap. The FIGHT branch's target
    # filter was `if filterFailedTalents(...)` -- a table, always true. The
    # obvious repair, testing the count on the TARGET list, makes a hostile
    # out of talent range not a target at all: targets empties, the "fight's
    # over" branch sends the bot to REST, it re-enters with the hostile
    # still in view, and it spins to THINK_LIMIT. Melee stops working, and
    # this line is what says so.
    $null = Assert-Result $a 'query advances no game turn' -Match 'dturn=0 '
    if ($a.Result -match 'score=([\d.]+) ') { Ok ([double]$Matches[1] -le 0.5 -and [double]$Matches[1] -gt 0) "the score is between 0 and 0.5 ($($Matches[1]))" }
    $null = Probe 'return sc.unspawn()'

    # ----- B: a boss adjacent at 40% life ----------------------------------------------
    Write-Host ''
    Write-Host '  --- B. one boss (rank 4, x2) adjacent at 40% life, MAX_DIFF_POWER at its default: STRONGERENEMY stops, naming the score'
    $sp = Probe "return sc.spawnLine(1, $armor, 4)"
    Write-Host "  $($sp.Result)"
    if ($sp.Result -match '^SETUP') { Inconclusive $sp.Result }
    $b = Probe 'return sc.probe({ MAX_INDIVIDUAL_POWER = 1000000, MAX_COMBINED_POWER = 1000000, life = 0.4 })'
    Write-Host "  $($b.Result)"
    if ($b.Result -match '^SETUP') { Inconclusive $b.Result }
    $null = Assert-Result $b 'the STRONGERENEMY flag is set and BIGENEMY (raised out of reach) is not' -Match 'flags=\[STRONGERENEMY\] '
    $null = Assert-Result $b "the score's own posture is HANDBACK" -Match 'posture=handback '
    $null = Assert-Result $b 'the bot stops with v1''s wording, the life-scaled own power, and the threat score' -Match 'reason=Stopped: an enemy''s power level, [\d.]+, is more than MAX_DIFF_POWER above yours \([\d.]+ at current life\) -- threat [\d.]+ log='
    $null = Assert-Result $b 'the score''s reason is the stop''s reason' -Match 'why=\[an enemy''s power level, [\d.]+, is more than MAX_DIFF_POWER above yours'
    if ($b.Result -match 'terms=\[ind=[\d.]+ str=([\d.]+) ' -and $b.Result -match '-- threat ([\d.]+)') {
        $str = [double]($b.Result -replace '.*terms=\[ind=[\d.]+ str=([\d.]+) .*', '$1'); $thr = [double]($b.Result -replace '.*-- threat ([\d.]+).*', '$1')
        Ok ([math]::Abs($str - $thr) -lt 0.06 -and $thr -gt 1) "the threat in the reason is the stronger term ($thr ~ $str), over 1"
    }
    if ($b.Result -match 'an enemy''s power level, ([\d.]+), is more than MAX_DIFF_POWER above yours \(([\d.]+) at current life\)') {
        $max = [double]$Matches[1]; $mine = [double]$Matches[2]
        $exp = [double]($b.Result -replace '.* mine=([\d.]+) .*', '$1')
        Ok ([math]::Abs($mine - $exp) -lt 0.51) "own power in the reason is the heuristic on the life curve at 40% life ($mine ~ $exp)"
        Ok ($max -gt 1.5 * $armor) "the boss figure carries the x2 rank weight ($max over $armor of armour alone)"
    }

    # ----- C: the same boss adjacent, accepted -----------------------------------------
    Write-Host ''
    Write-Host '  --- C. the same boss adjacent with BIGENEMY and STRONGERENEMY at IGNORE: FIGHT, a step away would give it a free hit'
    $c = Probe 'return sc.probe({ MAX_COMBINED_POWER = 1000000, life = 0.4, conds = { SCOUTER_BIGENEMY = "IGNORE", SCOUTER_STRONGERENEMY = "IGNORE" } })'
    Write-Host "  $($c.Result)"
    if ($c.Result -match '^SETUP') { Inconclusive $c.Result }
    $null = Assert-Result $c 'the flags are still set' -Match 'flags=\[BIGENEMY,STRONGERENEMY\] '
    $null = Assert-Result $c 'the posture is FIGHT, with the reason' -Match 'posture=fight .*why=\[[^\]]* is [\d.]+x your limit and adjacent: a step away would give it a free hit\]'
    $null = Assert-Result $c 'the bot does not stop' -Match 'reason=nil'
    $null = Assert-Result $c 'and would attack' -Match 'AI would use the talent Attack'
    $null = Probe 'return sc.unspawn()'

    # ----- D: the same boss three grids away, accepted ---------------------------------
    Write-Host ''
    Write-Host '  --- D. the boss three grids away at IGNORE: RETREAT, a flee step first'
    $sp = Probe "return sc.spawnLine(3, $armor, 4)"
    Write-Host "  $($sp.Result)"
    if ($sp.Result -match '^SETUP') { Inconclusive $sp.Result }
    $d = Probe 'return sc.probe({ MAX_COMBINED_POWER = 1000000, life = 0.4, conds = { SCOUTER_BIGENEMY = "IGNORE", SCOUTER_STRONGERENEMY = "IGNORE" } })'
    Write-Host "  $($d.Result)"
    if ($d.Result -match '^SETUP') { Inconclusive $d.Result }
    # The spawn is three STEPS along a free line, and sc.line offers diagonals
    # too, so three steps is distance 3 or 4 depending on which direction was
    # free. spawnLine reports the distance it actually got; assert against
    # that rather than against 3, which passes or fails on the geometry the
    # level happened to offer. (Seen failing on a diagonal, 2026-08-23.)
    $spawnDist = if ($sp.Result -match 'at distance (\d+)') { $Matches[1] } else { '3' }
    $null = Assert-Result $d 'the posture is RETREAT, with the distance in the reason' -Match ('posture=retreat .*why=\[[^\]]* is [\d.]+x your limit at distance ' + $spawnDist + ': step away first\]')
    $null = Assert-Result $d 'the bot does not stop' -Match 'reason=nil'
    $null = Assert-Result $d 'and would flee from it before anything else' -Match 'AI would flee from [^|]* to the (north|south|east|west|northeast|northwest|southeast|southwest)'
    $null = Assert-Result $d 'no talent and no approach' -Match '^(?!.*AI would (use|move))'
    $null = Probe 'return sc.unspawn()'

    # ----- E: a crowd over its limit at range, accepted ----------------------------------
    Write-Host ''
    Write-Host '  --- E. three armoured normals two grids away over a zero crowd margin, CROWDPOWER at IGNORE: HOLD, wait'
    $sp = Probe "return sc.spawn(3, 2, $armor, 2)"
    Write-Host "  $($sp.Result)"
    if ($sp.Result -match '^SETUP') { Inconclusive $sp.Result }
    $e = Probe 'return sc.probe({ MAX_COMBINED_POWER = 0, MAX_DIFF_POWER = 1000000, MAX_INDIVIDUAL_POWER = 1000000, conds = { SCOUTER_CROWDPOWER = "IGNORE" } })'
    Write-Host "  $($e.Result)"
    if ($e.Result -match '^SETUP') { Inconclusive $e.Result }
    $null = Assert-Result $e 'only the crowd flag is set' -Match 'flags=\[CROWDPOWER\] '
    $null = Assert-Result $e 'the posture is HOLD, with the crowd term in the reason' -Match 'posture=hold .*why=\[the crowd is [\d.]+x your combined limit: fight what comes into reach, do not walk into it\]'
    $null = Assert-Result $e 'the bot does not stop' -Match 'reason=nil'
    $null = Assert-Result $e 'with nothing in reach it would wait for them rather than walk into them' -Match 'AI would wait for [^|]* to come into reach'
    $null = Assert-Result $e 'no approach' -Match '^(?!.*AI would move)'
    # The same crowd with the flag NOT accepted stops, as before (#62), with the score appended.
    $e2 = Probe 'return sc.probe({ MAX_COMBINED_POWER = 0, MAX_DIFF_POWER = 1000000, MAX_INDIVIDUAL_POWER = 1000000 })'
    Write-Host "  $($e2.Result)"
    $null = Assert-Result $e2 'the same crowd at STOP stops the bot with v1''s wording and the threat score' -Match 'reason=Stopped: the combined enemy power level, [\d.]+, is more than MAX_COMBINED_POWER above yours \([\d.]+ at current life\) -- threat [\d.]+ log='
    $null = Assert-Result $e2 'and the posture says HANDBACK' -Match 'posture=handback '
    $null = Probe 'return sc.unspawn()'


    # ----- G: a sealed grid is not a route (#64) ------------------------------------------
    Write-Host ''
    Write-Host '  --- G. the bot does not path through a grid the player must consent to enter'
    $g = Probe 'return sc.sealed()' 90
    Write-Host "  $($g.Result)"
    if ($g.Result -match '^SETUP') { Inconclusive $g.Result }
    $null = Assert-Result $g 'the sealed grid needs consent, and an ordinary one does not' -Match '^SEALED consent=true consent_elsewhere=false '
    $null = Assert-Result $g 'query advances no game turn and moves nothing' -Match ' dturn=0 moved=false '
    # The point: the only straight route to the hostile is sealed, so the bot
    # must go round it or say there is no path -- never step onto it. Before
    # #64 the path ran through, the yes/no popup opened, and the bot handed
    # back on its own dialog; the first soak measured that as 65 of 66 stops
    # in ten minutes, the single largest source of hand-backs it produced.
    if ($g.Result -match ' sealdir=(\w+) ') {
        $dir = $Matches[1]
        Ok ($g.Result -notmatch "AI would move to the $dir\b") "it does not step into the sealed grid (would have been $dir)" $g.Result
    } else {
        Ok $false 'the probe reported which way the sealed grid was' $g.Result
    }
    $null = Assert-Result $g 'the terrain clone was put back' -Match ' restored=true$'
    # ----- F: explore damage as a term ----------------------------------------------------
    Write-Host ''
    Write-Host '  --- F. a 5% scratch while exploring at 50% life, nothing in view: the T-011 stop with the explore-damage term'
    $f = Probe 'return sc.scratch(0.5)'
    Write-Host "  $($f.Result)"
    if ($f.Result -match '^SETUP') { Inconclusive $f.Result }
    $null = Assert-Result $f 'the stop fires with the T-011 wording and the threat' -Match 'reason=Stopped: took damage while exploring, and life is below IGNORE_DAMAGE_HEALTH_RATIO -- threat [\d.]+$'
    if ($f.Result -match '-- threat ([\d.]+)') { Ok ([math]::Abs([double]$Matches[1] - 5) -lt 0.3) "the threat is (1 - 0.5) / (1 - 0.9) = 5 ($($Matches[1]))" }
    $f2 = Probe 'return sc.scratch(0.95)'
    Write-Host "  $($f2.Result)"
    $null = Assert-Result $f2 'the same scratch at 95% life is ignored (T-011)' -Match 'reason=nil'
}
finally {
    $null = Invoke-Bridge -Lua 'if sc then sc.unspawn(); sc.restore() end return "clean"' -TimeoutSec 15 -ErrorAction SilentlyContinue
    Stop-Game
}

Start-Sleep -Seconds 1
$errs = @((Get-Content $script:LogPath -Raw -ErrorAction Ignore) -split "`r?`n" | Where-Object { $_ -match 'Lua Error' })
Ok ($errs.Count -eq 0) 'no Lua Error in the run'
foreach ($e in ($errs | Select-Object -First 3)) { Write-Host "         $e" }

Write-Host ''
if ($script:HarnessTainted) { Write-Host '[scoring] TAINTED - void, re-run.'; exit 2 }
if ($script:HarnessFailures.Count -gt 0) {
    Write-Host "[scoring] FAILED - $($script:HarnessFailures.Count) check(s):"
    foreach ($f in $script:HarnessFailures) { Write-Host "                 $f" }
    exit 1
}
Write-Host '[scoring] PASS - the knobs parametrise one score, the flags mean what they did, and the posture is what the bot does'
exit 0
