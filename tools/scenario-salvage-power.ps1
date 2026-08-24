<#
    #62, mishander's power-level takes: rank-weighted enemy power (salvage
    item 2), life-scaled own power (item 3) and the relative crowd threshold
    (item 4), asserted against a live game.

    The numbers are measured, not assumed. Three normal-rank hostiles are
    spawned next to the character in a quiet spot, each given enough armour
    that its power level dwarfs the character's (power.level reads
    combat_armor directly, so this is deterministic), and every threshold
    below is computed from the measured figures so that the SAME crowd
    trips the v1 comparison and passes the new one:

      crowd     MAX_COMBINED_POWER set between the weighted and the
                unweighted sum (minus own power): with NORMAL_POWER_RATIO
                0.4 the bot does not stop; with the ratio at 1 (v1's
                arithmetic) it does; and at a zero margin, so the stop
                fires and reports the weighted sum the bot actually used
                and the life-scaled own power it compared with
      strongest MAX_DIFF_POWER set the same way around the strongest one
      boss      MAX_INDIVIDUAL_POWER set at 1.2x the strongest one's raw
                power: at rank 2 (x0.4) no stop, at rank 3.5 (unique, x1)
                no stop, at rank 4 (boss, x2) stop
      life      MAX_DIFF_POWER set so that the strongest one is under the
                character's margin at full life and over it at 40% life

    Every probe drives ONE decision through query mode (the T-01x pattern):
    the runtime table is put into a clean EXPLORE activation, b.query() runs
    a single skoobot_act with do_nothing set, and b.last_reason says why it
    would hand back. No game.turn advances, so nothing wanders in. The four
    SCOUTER_* conditions are STOP and LIFE_LOWLIFE / LIFE_BIGLOSS are IGNORE
    for the probes (so the 40%-life probe reaches the power check), and all
    of it -- settings, conditions, rank, life, the spawned actors -- is put
    back afterwards. The game is never saved.

    Exit codes:  0 pass   1 fail   2 tainted   3 inconclusive (no quiet spot,
    nothing to spawn, or the spawn is not a visible hostile -- a setup
    problem, never a product failure)

    Run:
        powershell -ExecutionPolicy Bypass -File .\tools\scenario-salvage-power.ps1

    #62.
#>
[CmdletBinding()]
param(
    [string]$SaveName = 'harness'
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'harness.ps1')

$script:Fail = @()
$script:Tainted = $false
function Check($ok, $what) {
    if ($ok) { Write-Host "  PASS  $what" } else { Write-Host "  FAIL  $what"; $script:Fail += $what }
}
function Probe($lua, $timeout = 30) {
    $r = Invoke-Bridge -Lua $lua -TimeoutSec $timeout
    if ($r.Tainted) { $script:Tainted = $true }
    if ($r.Status -ne 'OK') { Write-Host "  BRIDGE $($r.Status): $($r.Result)" }
    return $r
}
function Inconclusive($why) {
    Write-Host "[salvage-power] INCONCLUSIVE - $why"
    Stop-Game
    exit 3
}
# Lua's tostring of a number for a probe option line. Invariant culture so a
# comma-decimal locale cannot turn 0.4 into "0,4".
function N($x) { return ([double]$x).ToString('0.####', [Globalization.CultureInfo]::InvariantCulture) }

Write-Host ''
Write-Host '[salvage-power] rank weights, life-scaled own power, relative crowd threshold (#62)'

try {
    $g = Load-Save -Name $SaveName
    if (-not $g.Ready) { Write-Host "[salvage-power] FAILED - could not load '$SaveName' ($($g.Reason))"; exit 1 }
    Check ($g.Addons -match 'skoobot_reclauded') 'the product is loaded'

    $install = Probe @'
local b = rawget(_G, "skoobot_reclauded")
if not b or not b.power or not b.conditions then return "OLD no runtime table with power() and conditions" end
_G.sp = { spawned = {}, saved = nil }
local SETTINGS = { "MAX_INDIVIDUAL_POWER", "MAX_DIFF_POWER", "MAX_COMBINED_POWER", "MAX_ENEMY_COUNT",
  "NORMAL_POWER_RATIO", "ELITES_POWER_RATIO", "BOSS_POWER_RATIO", "LOWHEALTH_RATIO" }
local CONDS = { SCOUTER_BIGENEMY = "STOP", SCOUTER_STRONGERENEMY = "STOP", SCOUTER_CROWDPOWER = "STOP",
  SCOUTER_ENEMYCOUNT = "STOP", LIFE_LOWLIFE = "IGNORE", LIFE_BIGLOSS = "IGNORE" }
function sp.hostiles()
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
function sp.onChangeLevel()
  local p = game.player
  return game.level.map:checkEntity(p.x, p.y, engine.Map.TERRAIN, "change_level") ~= nil
end
-- Free tiles next to the character: the spawns below need three of them, so
-- the quiet spot must have them or the run is inconclusive on its own setup.
function sp.freeAdjacent()
  local p = game.player
  local n = 0
  for _, c in pairs(util.adjacentCoords(p.x, p.y)) do
    local x, y = c[1], c[2]
    if game.level.map:isBound(x, y) and not game.level.map:checkAllEntities(x, y, "block_move")
       and not game.level.map(x, y, engine.Map.ACTOR) then n = n + 1 end
  end
  return n
end
function sp.quietHere()
  return sp.hostiles() == 0 and not sp.onChangeLevel() and sp.freeAdjacent() >= 3
end
function sp.findQuiet()
  local p = game.player
  for i = 1, 80 do
    if sp.quietHere() then return true end
    p:teleportRandom(p.x, p.y, 60, 10)
  end
  return sp.quietHere()
end
-- Remember what the probes change, once.
function sp.save()
  if sp.saved then return end
  local s = config.settings.tome.skoobot_reclauded
  sp.saved = { settings = {}, conds = {} }
  for _, k in ipairs(SETTINGS) do sp.saved.settings[k] = s[k] end
  for c in pairs(CONDS) do sp.saved.conds[c] = b.conditions.get(c).stoptype end
end
function sp.restore()
  if not sp.saved then return "nothing saved" end
  local s = config.settings.tome.skoobot_reclauded
  for k, v in pairs(sp.saved.settings) do s[k] = v end
  for c, v in pairs(sp.saved.conds) do b.conditions.set(c, v) end
  game.player.life = game.player.max_life
  b.data(game.player).stopwarn = {}
  return "restored"
end
-- A clean, inactive EXPLORE activation at full life with the baseline
-- settings and the probe's condition policies.
function sp.reset()
  sp.save()
  local p = game.player
  local s = config.settings.tome.skoobot_reclauded
  for k, v in pairs(sp.saved.settings) do s[k] = v end
  for c, v in pairs(CONDS) do b.conditions.set(c, v) end
  b.data(p).stopwarn = {}
  for _, m in ipairs(sp.spawned) do m.rank = 2 end
  p.life = p.max_life
  b.active = false; b.do_nothing = false; b.state = 11; b.last_reason = nil   -- 11 = STATE_EXPLORE
  b.activation = nil; b.loop = nil; b.prevloop = nil
end
-- Spawn n normal-rank hostiles on free tiles next to the character, each with
-- `armor` added so its power level is large and known. Returns the count of
-- visible hostiles, or a SETUP line.
function sp.spawn(n, armor)
  local p = game.player
  local free = {}
  for _, c in pairs(util.adjacentCoords(p.x, p.y)) do
    local x, y = c[1], c[2]
    if game.level.map:isBound(x, y) and not game.level.map:checkAllEntities(x, y, "block_move")
       and not game.level.map(x, y, engine.Map.ACTOR) then free[#free + 1] = { x, y } end
  end
  if #free < n then return "SETUP only " .. #free .. " free adjacent tiles" end
  for i = 1, n do
    local placed = false
    for _ = 1, 6 do
      local m = game.zone:makeEntity(game.level, "actor",
        { special = function(e) return not e.unique and (e.rank or 1) <= 2 end }, nil, true)
      if not m then return "SETUP no actor to spawn" end
      m.rank = 2
      m.combat_armor = (m.combat_armor or 0) + armor
      local before = sp.hostiles()
      game.zone:addEntity(game.level, m, "actor", free[i][1], free[i][2])
      if sp.hostiles() == before + 1 then sp.spawned[#sp.spawned + 1] = m; placed = true; break end
      game.level:removeEntity(m, true)
    end
    if not placed then return "SETUP the spawned actor is not a visible hostile" end
  end
  return sp.hostiles()
end
function sp.unspawn()
  for _, m in ipairs(sp.spawned) do if m.x then game.level:removeEntity(m, true) end end
  sp.spawned = {}
  game.player:playerFOV()
  return "removed"
end
-- The measured figures the thresholds are computed from. At full life, the
-- state every probe starts from: the heuristic's survival score is
-- quadratic in life, so a character loaded at 100/104 scores less than the
-- probes will see.
function sp.numbers()
  sp.reset()
  local p = game.player
  local s = config.settings.tome.skoobot_reclauded
  local own = b.power(p)
  local sumR, maxR, raw = 0, 0, {}
  for _, m in ipairs(sp.spawned) do
    local r = b.power(m)
    raw[#raw + 1] = string.format("%.2f", r)
    sumR = sumR + r
    if r > maxR then maxR = r end
  end
  return ("own=%.4f sumR=%.4f maxR=%.4f r1=%.4f normal=%s elites=%s boss=%s raw=%s"):format(
    own, sumR, maxR, sp.spawned[1] and b.power(sp.spawned[1]) or 0,
    tostring(s.NORMAL_POWER_RATIO), tostring(s.ELITES_POWER_RATIO), tostring(s.BOSS_POWER_RATIO),
    table.concat(raw, ","))
end
-- One decision. o: settings to override for this probe, `ranks` (a list,
-- per spawned actor) and `life` (a fraction of max_life).
function sp.probe(o)
  sp.reset()
  local p = game.player
  local s = config.settings.tome.skoobot_reclauded
  for _, k in ipairs(SETTINGS) do if o[k] ~= nil then s[k] = o[k] end end
  for i, m in ipairs(sp.spawned) do if o.ranks and o.ranks[i] then m.rank = o.ranks[i] end end
  if o.life then p.life = math.floor(p.max_life * o.life) end
  p:playerFOV()
  if sp.hostiles() ~= #sp.spawned then
    return "SETUP " .. sp.hostiles() .. " hostiles in view, expected " .. #sp.spawned
  end
  -- What item 3 says the bot should compare with: the heuristic at the life
  -- the probe set, scaled by that life. Computed here, at probe time, so a
  -- heuristic that itself depends on life (the survival score does) is
  -- accounted for and the check below is exact.
  -- #79: asked of the addon rather than recomputed here. The shape of the
  -- life scaling is data/score.lua's business -- a curve since #79 -- and a
  -- probe that re-derived it would go stale the next time it moves.
  local mine = b.ownPower(p)
  local before = game.turn
  b.query()
  return ("REASON %s | dturn=%d | mine_expected=%.1f | life=%d/%d"):format(tostring(b.last_reason),
    game.turn - before, mine, p.life, p.max_life)
end
return "installed"
'@
    if ($install.Result -match '^OLD') { Inconclusive $install.Result }
    Check ($install.Result -eq 'installed') 'probe helpers installed'

    if ((Probe 'return tostring(sp.findQuiet())' 120).Result -ne 'True') { Inconclusive 'no quiet spot to test from' }

    # ----- defaults: mishander's numbers as shipped ---------------------------
    Write-Host ''
    Write-Host '  --- defaults'
    $d = Probe 'local s = config.settings.tome.skoobot_reclauded return ("normal=%s elites=%s boss=%s combined=%s diff=%s"):format(tostring(s.NORMAL_POWER_RATIO), tostring(s.ELITES_POWER_RATIO), tostring(s.BOSS_POWER_RATIO), tostring(s.MAX_COMBINED_POWER), tostring(s.MAX_DIFF_POWER))'
    Write-Host "  $($d.Result)"
    Check ($d.Result -match 'normal=0\.4 elites=1 boss=2 ') 'NORMAL 0.4 / ELITES 1 / BOSS 2 -- mishander''s ratios, as shipped'
    Check ($d.Result -match 'combined=500 ') 'MAX_COMBINED_POWER default is still 500 (its meaning changed: a margin above yours)'

    # ----- spawn: three normals, armoured past the character ------------------
    # Armour scales with the character so the thresholds below are positive
    # whoever the harness character is: each spawn's power is at least ~3x own.
    $own0 = Probe 'return ("own=%.4f"):format(skoobot_reclauded.power(game.player))'
    if ($own0.Result -notmatch 'own=([\d.]+)') { Inconclusive "could not read own power: $($own0.Result)" }
    $own = [double]$Matches[1]
    $armor = [math]::Max(500, [math]::Ceiling(3 * $own))
    $sp = Probe "return tostring(sp.spawn(3, $armor))" 60
    if ($sp.Result -match '^SETUP') { Inconclusive $sp.Result }
    Check ($sp.Result -eq '3') "three normal-rank hostiles spawned next to the character (armour +$armor each)"
    if ($sp.Result -ne '3') { Inconclusive "spawned count: $($sp.Result)" }

    $n = Probe 'return sp.numbers()'
    Write-Host "  $($n.Result)"
    if ($n.Result -notmatch 'own=([\d.]+) sumR=([\d.]+) maxR=([\d.]+) r1=([\d.]+) normal=([\d.]+) elites=([\d.]+) boss=([\d.]+)') {
        Inconclusive "could not parse the measured figures: $($n.Result)"
    }
    $own = [double]$Matches[1]; $sumR = [double]$Matches[2]; $maxR = [double]$Matches[3]; $r1 = [double]$Matches[4]
    $normal = [double]$Matches[5]; $elites = [double]$Matches[6]; $boss = [double]$Matches[7]
    $sumW = $normal * $sumR; $maxW = $normal * $maxR
    Check ($normal -lt 1 -and $maxW -gt 0.7 * $own) 'the figures make every threshold below positive and discriminating'

    # ----- item 2 + 4: crowd -- weighted, relative sum vs v1's ----------------
    Write-Host ''
    Write-Host '  --- crowd: three commons whose unweighted sum trips the check and whose weighted sum does not'
    $Mc = ($sumW + $sumR) / 2 - $own
    Write-Host ("  sum unweighted={0:F1} weighted={1:F1} own={2:F1} -> MAX_COMBINED_POWER={3:F1} (own+margin={4:F1})" -f $sumR, $sumW, $own, $Mc, ($own + $Mc))
    $c1 = Probe "return sp.probe({ MAX_COMBINED_POWER = $(N $Mc), MAX_DIFF_POWER = 1000000, MAX_INDIVIDUAL_POWER = 1000000 })" 60
    Write-Host "  weighted   $($c1.Result)"
    if ($c1.Result -match '^SETUP') { Inconclusive "crowd weighted: $($c1.Result)" }
    Check ($c1.Result -notmatch 'MAX_COMBINED_POWER') 'with the rank weights, the bot does NOT stop for the crowd'
    Check ($c1.Result -match 'dturn=0') 'query advances no game turn'
    $c2 = Probe "return sp.probe({ MAX_COMBINED_POWER = $(N $Mc), MAX_DIFF_POWER = 1000000, MAX_INDIVIDUAL_POWER = 1000000, NORMAL_POWER_RATIO = 1 })" 60
    Write-Host "  unweighted $($c2.Result)"
    if ($c2.Result -match '^SETUP') { Inconclusive "crowd unweighted: $($c2.Result)" }
    Check ($c2.Result -match 'MAX_COMBINED_POWER above yours') 'with NORMAL_POWER_RATIO at 1 (v1''s arithmetic) the same crowd stops the bot -- so the weight is what lets it through'
    Check ($c2.Result -match 'at current life') 'the crowd reason names the life-scaled own power it was compared with'
    if ($c2.Result -match 'the combined enemy power level, ([\d.]+), is more than') { Check ([math]::Abs([double]$Matches[1] - $sumR) -lt 1) "the reason carries the unweighted sum ($($Matches[1]) ~ $([math]::Round($sumR, 1)))" }
    # A stop clears the loop scratch, so the weighted sum is observed by
    # forcing the crowd stop with a zero margin and reading the bot's figure.
    $c3 = Probe "return sp.probe({ MAX_COMBINED_POWER = 0, MAX_DIFF_POWER = 1000000, MAX_INDIVIDUAL_POWER = 1000000 })" 60
    Write-Host "  zero-margin $($c3.Result)"
    if ($c3.Result -match '^SETUP') { Inconclusive "crowd zero margin: $($c3.Result)" }
    if ($c3.Result -match 'the combined enemy power level, ([\d.]+), is more than') { Check ([math]::Abs([double]$Matches[1] - $sumW) -lt 1) "the bot's own crowd figure is the weighted sum ($($Matches[1]) ~ $([math]::Round($sumW, 1)) = 0.4 x $([math]::Round($sumR, 1)))" }
    else { Check $false 'with a zero margin the crowd stop fires and reports the weighted sum' }
    if ($c3.Result -match 'yours \(([\d.]+) at current life\)' -and $c3.Result -match 'mine_expected=([\d.]+)') {
        $got = [double]($c3.Result -replace '.*yours \(([\d.]+) at current life\).*', '$1'); $exp = [double]($c3.Result -replace '.*mine_expected=([\d.]+).*', '$1')
        # 0.51, not 0.15: the reason prints power levels WHOLE since #84, so
        # the figure read back can be up to half a point from the exact one.
        # The comparison the bot made is still on the exact value -- only the
        # rendering rounds -- which is why this compares within a rounding
        # rather than demanding the decimal back.
        Check ([math]::Abs($got - $exp) -lt 0.51) "the own power the bot compared with is power x life/max_life at full life ($got ~ $exp)"
    }

    # ----- item 2: strongest -- weighted max vs v1's --------------------------
    Write-Host ''
    Write-Host '  --- strongest: one common whose raw power is over the margin and whose weighted power is not'
    $Md = ($maxW + $maxR) / 2 - $own
    Write-Host ("  max unweighted={0:F1} weighted={1:F1} own={2:F1} -> MAX_DIFF_POWER={3:F1}" -f $maxR, $maxW, $own, $Md)
    $s1 = Probe "return sp.probe({ MAX_DIFF_POWER = $(N $Md), MAX_COMBINED_POWER = 1000000, MAX_INDIVIDUAL_POWER = 1000000 })" 60
    Write-Host "  weighted   $($s1.Result)"
    if ($s1.Result -match '^SETUP') { Inconclusive "strongest weighted: $($s1.Result)" }
    Check ($s1.Result -notmatch 'MAX_DIFF_POWER') 'with the rank weights, the bot does NOT stop for the strongest common'
    $s2 = Probe "return sp.probe({ MAX_DIFF_POWER = $(N $Md), MAX_COMBINED_POWER = 1000000, MAX_INDIVIDUAL_POWER = 1000000, NORMAL_POWER_RATIO = 1 })" 60
    Write-Host "  unweighted $($s2.Result)"
    if ($s2.Result -match '^SETUP') { Inconclusive "strongest unweighted: $($s2.Result)" }
    Check ($s2.Result -match 'MAX_DIFF_POWER above yours') 'with NORMAL_POWER_RATIO at 1 the same common stops the bot'

    # ----- item 2: boss -- the rank band decides the weight -------------------
    Write-Host ''
    Write-Host '  --- boss: the same actor at rank 2, 3.5 and 4 against MAX_INDIVIDUAL_POWER = 1.2x its raw power'
    $Mi = 1.2 * $r1
    Write-Host ("  r1={0:F1} -> x{1}={2:F1}  x{3}={4:F1}  x{5}={6:F1}  threshold={7:F1}" -f $r1, $normal, ($normal * $r1), $elites, ($elites * $r1), $boss, ($boss * $r1), $Mi)
    $b2 = Probe "return sp.probe({ MAX_INDIVIDUAL_POWER = $(N $Mi), MAX_DIFF_POWER = 1000000, MAX_COMBINED_POWER = 1000000, ranks = { 2, 2, 2 } })" 60
    Write-Host "  rank 2     $($b2.Result)"
    if ($b2.Result -match '^SETUP') { Inconclusive "boss control: $($b2.Result)" }
    Check ($b2.Result -notmatch 'MAX_INDIVIDUAL_POWER') 'rank 2 (normal, x0.4): no stop'
    $b3 = Probe "return sp.probe({ MAX_INDIVIDUAL_POWER = $(N $Mi), MAX_DIFF_POWER = 1000000, MAX_COMBINED_POWER = 1000000, ranks = { 3.5, 2, 2 } })" 60
    Write-Host "  rank 3.5   $($b3.Result)"
    if ($b3.Result -match '^SETUP') { Inconclusive "unique: $($b3.Result)" }
    Check ($b3.Result -notmatch 'MAX_INDIVIDUAL_POWER') 'rank 3.5 (unique, x1): no stop -- face value is under 1.2x'
    $b4 = Probe "return sp.probe({ MAX_INDIVIDUAL_POWER = $(N $Mi), MAX_DIFF_POWER = 1000000, MAX_COMBINED_POWER = 1000000, ranks = { 4, 2, 2 } })" 60
    Write-Host "  rank 4     $($b4.Result)"
    if ($b4.Result -match '^SETUP') { Inconclusive "boss: $($b4.Result)" }
    Check ($b4.Result -match 'above MAX_INDIVIDUAL_POWER') 'rank 4 (boss, x2): the bot stops'
    # The stop clears the loop scratch, so the figure is read from the reason.
    if ($b4.Result -match "an enemy's power level, ([\d.]+), is above") { Check ([math]::Abs([double]$Matches[1] - $boss * $r1) -lt 1) "the reason carries the boss-weighted figure ($($Matches[1]) ~ $([math]::Round($boss * $r1, 1)))" }

    # ----- item 3: own power scaled by life -----------------------------------
    Write-Host ''
    Write-Host '  --- life: the same common is under the margin at full life and over it at 40% life'
    $Ml = $maxW - 0.7 * $own
    # 0.28, not 0.40: since #79 the life scaling is a curve, and f(0.4) is
    # 0.4 * (1 - 0.5 * 0.6) = 0.28. Both checks below hold either way -- the
    # curve only ever makes the hurt character read weaker -- but the figure
    # printed beside them should be the one the bot actually used.
    Write-Host ("  maxW={0:F1} own={1:F1} -> MAX_DIFF_POWER={2:F1}: full life compares with {3:F1}, 40% with {4:F1}" -f $maxW, $own, $Ml, ($own + $Ml), (0.28 * $own + $Ml))
    $l1 = Probe "return sp.probe({ MAX_DIFF_POWER = $(N $Ml), MAX_COMBINED_POWER = 1000000, MAX_INDIVIDUAL_POWER = 1000000 })" 60
    Write-Host "  full life  $($l1.Result)"
    if ($l1.Result -match '^SETUP') { Inconclusive "life full: $($l1.Result)" }
    Check ($l1.Result -notmatch 'MAX_DIFF_POWER') 'at full life the bot does NOT stop'
    $l2 = Probe "return sp.probe({ MAX_DIFF_POWER = $(N $Ml), MAX_COMBINED_POWER = 1000000, MAX_INDIVIDUAL_POWER = 1000000, life = 0.4 })" 60
    Write-Host "  40% life   $($l2.Result)"
    if ($l2.Result -match '^SETUP') { Inconclusive "life 40%: $($l2.Result)" }
    Check ($l2.Result -match 'MAX_DIFF_POWER above yours') 'at 40% life the same enemy stops the bot -- own power is scaled by life'
    Check ($l2.Result -match 'at current life') 'the reason says the figure is at current life'
    if ($l2.Result -match 'yours \(([\d.]+) at current life\)' -and $l2.Result -match 'mine_expected=([\d.]+)') {
        $got = [double]($l2.Result -replace '.*yours \(([\d.]+) at current life\).*', '$1'); $exp = [double]($l2.Result -replace '.*mine_expected=([\d.]+).*', '$1')
        Check ([math]::Abs($got - $exp) -lt 0.51) "the own power the bot compared with is power x life/max_life at 40% life ($got ~ $exp)"
    } else { Check $false 'the 40%-life reason carries the own-power figure' }
    Check ($l2.Result -match 'dturn=0') 'query advances no game turn'
}
finally {
    $null = Invoke-Bridge -Lua 'if sp then sp.unspawn(); sp.restore() end return "clean"' -TimeoutSec 15 -ErrorAction SilentlyContinue
    Stop-Game
}

Write-Host ''
if ($script:Tainted) { Write-Host '[salvage-power] TAINTED - void, re-run.'; exit 2 }
if ($script:Fail.Count -gt 0) {
    Write-Host "[salvage-power] FAILED - $($script:Fail.Count) check(s):"
    foreach ($f in $script:Fail) { Write-Host "                 $f" }
    exit 1
}
Write-Host '[salvage-power] PASS - rank weights, life-scaled own power and the relative crowd threshold all hold in-game'
exit 0
