<#
    #91: how much life there really is -- die_at, and how far each source of
    it can be trusted -- asserted against a live game on the fixture
    (tools/new-character.ps1 -Class Berserker).

    Before this, every life judgement was `life / max_life`, which is not
    how the game works: a character dies at `die_at`
    (engine/interface/ActorLife.lua:51) and the game's own life bar is drawn
    over `max_life - die_at` (mod/class/Player.lua:465). A Lich at die_at
    -500 read as 0% life with five hundred points still to spend.

    Each probe drives ONE decision through query mode (the T-01x pattern):
    the runtime table is put into a clean activation, a hostile is in view
    two grids away, b.query() runs a single skoobot_act with do_nothing set,
    and b.last_reason says what the bot would have done. No game.turn
    advances, so the effects applied for a probe do not tick. The four
    SCOUTER_* conditions are IGNORE for the run so the spawn cannot trip a
    power stop; LIFE_LOWLIFE is STOP, which is its default.

      0. The reading is the game's own arithmetic: with no die_at at all,
         the pool is life and the maximum is max_life, and the fraction is
         what it always was. Nothing changes for the ordinary character.
      1. PERMANENT (a cloak, an artifact, a Lich's passive -- a temporary
         value nothing records against an effect or a sustain): at life 10
         of 100 the bot stops, and at the same life with die_at -400 it does
         not. That is the bug, in one pair.
      2. TEMPORARY, with time on it: Heroism for ten turns at life below
         zero. Counted in full, and the two readings agree.
      3. TEMPORARY, about to lapse: the same effect with one turn left. NOT
         counted -- the bot hands back BEFORE the thing holding it up goes,
         and the reason names it. Heroism's own description is the reason
         this matters: "if your life is below 0 when this effect wears off
         it will be set to 1", and the next hit is not survivable.
      4. ADVERSE: die_at above zero, where death arrives EARLY. A character
         at 60 of 100 has ten points left, not sixty, and stops.
      5. Own power is scaled on the pool too, so the same character reads
         as stronger with a pool behind it than without one.

    The timed ADVERSE path (UNRAVEL, data/timed_effects/magical.lua:3740)
    and the two effects that keep their temporary-value id in a field of
    their own (FRENZY, ROGUE'S BREW) are held by spec/life_spec.lua over
    fakes: applying them here would need a Temporal Warden's summon and a
    Cunning tree this fixture has not got.

    Exit codes:  0 pass   1 fail   2 tainted   3 inconclusive (no quiet
    spot, nothing to spawn -- setup, never product)

    Run:
        powershell -ExecutionPolicy Bypass -File .\tools\scenario-life.ps1

    #91.
#>
[CmdletBinding()]
param(
    [string]$SaveName = 'fixture-berserker',
    [string]$Plain = 'T_ATTACK'
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'harness.ps1')

Write-Host ''
Write-Host '[life] the life pool the game kills at, and how far each part of it is trusted (#91)'

function Inconclusive($why) {
    Write-Host "[life] INCONCLUSIVE - $why"
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
# The pool is the game's own subtraction, and this checks the relation
# rather than a figure: the fixture's max_life is whatever the character
# rolled, and a literal here would be asserting the fixture, not the code.
function Check-Pool($text, $what) {
    if ($text -match 'life=(-?\d+)/(-?\d+) die_at=(-?\d+) pool=(-?\d+)/(-?\d+)') {
        $life = [int]$Matches[1]; $max = [int]$Matches[2]; $d = [int]$Matches[3]
        $pool = [int]$Matches[4]; $pmax = [int]$Matches[5]
        Ok (($pool -eq $life - $d) -and ($pmax -eq $max - $d)) "$what ($life - $d = $pool, $max - $d = $pmax)" $text
    } else { Ok $false $what $text }
}

try {
    $g = Load-Save -Name $SaveName
    if (-not $g.Ready) { Write-Host "[life] FAILED - could not load '$SaveName' ($($g.Reason))"; exit 1 }
    $null = Assert-Result ([pscustomobject]@{ Status = 'OK'; Result = $g.Addons; Tainted = $false }) 'the product is loaded' -Match 'skoobot_reclauded'

    $install = Probe @"
_G.lf = { spawned = nil, saved = nil, tmp = {} }
local b = rawget(_G, "skoobot_reclauded")
if not b or not b.effectiveLife then return "OLD no effectiveLife in the runtime table" end
local PLAIN = "$Plain"
local CONDS = { "SCOUTER_BIGENEMY", "SCOUTER_STRONGERENEMY", "SCOUTER_CROWDPOWER", "SCOUTER_ENEMYCOUNT",
  "LIFE_LOWLIFE", "LIFE_BIGLOSS", "DEBUFF_STUNNED", "DEBUFF_CONFUSED" }

function lf.hostiles()
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
local function free(x, y)
  return game.level.map:isBound(x, y) and not game.level.map:checkAllEntities(x, y, "block_move")
    and not game.level.map(x, y, engine.Map.ACTOR)
end
function lf.freeAt(dist)
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
function lf.onChangeLevel()
  local p = game.player
  return game.level.map:checkEntity(p.x, p.y, engine.Map.TERRAIN, "change_level") ~= nil
end
function lf.findQuiet()
  local p = game.player
  for _ = 1, 80 do
    if lf.hostiles() == 0 and not lf.onChangeLevel() and lf.freeAt(2) then return true end
    p:teleportRandom(p.x, p.y, 60, 10)
  end
  return lf.hostiles() == 0 and not lf.onChangeLevel() and lf.freeAt(2) ~= nil
end
function lf.spawn(dist)
  local p = game.player
  local sx, sy = lf.freeAt(dist)
  if not sx then return "SETUP no free grid at distance " .. dist end
  for _ = 1, 8 do
    local m = game.zone:makeEntity(game.level, "actor",
      { special = function(e) return not e.unique and (e.rank or 1) <= 2 end }, nil, true)
    if not m then return "SETUP no actor to spawn" end
    m.rank = 2
    m.energy.mod = 0
    m.energy.value = 0
    local before = lf.hostiles()
    game.zone:addEntity(game.level, m, "actor", sx, sy)
    if lf.hostiles() == before + 1 then
      lf.spawned = m
      return ("OK %s at %d,%d"):format(m.name, m.x, m.y)
    end
    game.level:removeEntity(m, true)
  end
  return "SETUP the spawned actor is not a visible hostile"
end
function lf.unspawn()
  if lf.spawned and lf.spawned.x and not lf.spawned.dead then game.level:removeEntity(lf.spawned, true) end
  lf.spawned = nil
  game.player:playerFOV()
  return "removed"
end

-- die_at added the way a worn item adds it: a temporary value nothing
-- records against an effect or a sustain, which is what "permanent" means
-- to data/life.lua.
function lf.addTmp(name, v)
  lf.tmp[#lf.tmp + 1] = { name, game.player:addTemporaryValue(name, v) }
end
function lf.clearTmp()
  local p = game.player
  for i = #lf.tmp, 1, -1 do p:removeTemporaryValue(lf.tmp[i][1], lf.tmp[i][2]) end
  lf.tmp = {}
end
function lf.heroism(dur)
  local p = game.player
  p:removeEffect(p.EFF_HEROISM, true, true)
  if dur then
    p:setEffect(p.EFF_HEROISM, dur, { die_at = 200 })
    local eff = p.tmp and p.tmp[p.EFF_HEROISM]
    if not eff then return "SETUP heroism did not apply" end
    eff.dur = dur                       -- setEffect may scale it; this probe wants exactly dur
  end
  return "ok"
end

-- LIFE stays clean between probes: the effect goes before the life does, so
-- the character is never left below its own die_at.
function lf.reset()
  local p = game.player
  while #game.dialogs > 0 do game:unregisterDialog(game.dialogs[#game.dialogs]) end
  if b.active then b.stop("test reset") end
  b.active = false; b.do_nothing = false; b.last_reason = nil
  b.activation = nil; b.loop = nil; b.prevloop = nil
  b.data(p).stopwarn = {}
  lf.heroism(nil)
  lf.clearTmp()
  p.life = p.max_life
  p.talents_cd[PLAIN] = nil
  return "reset"
end
function lf.setup()
  local p = game.player
  if not p:knowTalent(PLAIN) then return "SETUP " .. PLAIN .. " is not known" end
  local r = b.rules.get(p)
  for _, s in ipairs(b.rules.module.SECTIONS) do
    local list = r[s]
    for i = #list, 1, -1 do list[i] = nil end
  end
  b.rules.module.place(r, { tid = PLAIN }, "Combat")
  lf.saved = lf.saved or {}
  for _, code in ipairs(CONDS) do lf.saved[code] = lf.saved[code] or b.conditions.get(code).stoptype end
  for _, code in ipairs(CONDS) do b.conditions.set(code, "IGNORE") end
  b.conditions.set("LIFE_LOWLIFE", "STOP")
  return ("OK die_at=%s life=%d/%d"):format(tostring(p.die_at), p.life, p.max_life)
end
function lf.restore()
  local p = game.player
  lf.reset()
  lf.unspawn()
  for code, st in pairs(lf.saved or {}) do b.conditions.set(code, st) end
  lf.saved = nil
  if p.x then p:playerFOV() end
  return ("restored die_at=%s life=%d/%d"):format(tostring(p.die_at), p.life, p.max_life)
end

-- What data/life.lua reads, plus the game's own arithmetic beside it.
function lf.reading()
  local p = game.player
  local el = b.effectiveLife(p)
  local theirs = (p.max_life - p.die_at) > 0 and ((p.life - p.die_at) / (p.max_life - p.die_at)) or 0
  return ("life=%d/%d die_at=%d pool=%d/%d frac=%.3f safe=%.3f theirs=%.3f"
    .. " perm=%d sus=%d tmp=%d trusted=%s expiring=%d"):format(
    p.life, p.max_life, p.die_at, el.safe_pool, el.safe_max, el.fraction, el.safe_fraction, theirs,
    el.permanent, el.sustained, el.temporary, tostring(el.trusted), #el.expiring)
end

-- One decision in FIGHT, with the reading beside the reason.
function lf.query()
  local p = game.player
  local before = game.turn
  b.active = false; b.do_nothing = false; b.last_reason = nil
  b.activation = nil; b.loop = nil; b.prevloop = nil
  b.data(p).stopwarn = {}
  b.state = 13
  b.query()
  return ("dturn=%d hostiles=%d reason=[%s] | %s"):format(
    game.turn - before, lf.hostiles(), tostring(b.last_reason), lf.reading())
end
return "installed"
"@
    if ($install.Status -ne 'OK' -or $install.Result -notmatch 'installed') {
        Inconclusive "could not install the probe helpers: $($install.Result)"
    }

    if ((Probe 'return tostring(lf.findQuiet())').Result -ne 'true') { Inconclusive 'no quiet spot with room to spawn' }
    $setup = Probe 'return lf.setup()'
    if ($setup.Result -match '^SETUP') { Inconclusive $setup.Result }
    Write-Host "  setup: $($setup.Result)"
    $sp = Probe 'return lf.spawn(2)'
    if ($sp.Result -match '^SETUP') { Inconclusive $sp.Result }
    Write-Host "  spawn: $($sp.Result)"

    # ----- 0: the plain character ------------------------------------------
    Write-Host ''
    Write-Host '  --- 0. no die_at: the reading is what it always was'
    $r0 = Probe 'lf.reset() return lf.reading()'
    Write-Host "  $($r0.Result)"
    Ok ($r0.Result -match 'die_at=0 ') 'the fixture carries no die_at' $r0.Result
    Ok ($r0.Result -match 'frac=1\.000 safe=1\.000 theirs=1\.000') 'at full life every figure is 1' $r0.Result
    Ok ($r0.Result -match 'trusted=true expiring=0') 'nothing is discounted' $r0.Result

    # ----- 1: permanent ----------------------------------------------------
    Write-Host ''
    Write-Host '  --- 1. permanent die_at: the pool is real life, and the bot spends it'
    $q1 = Probe 'lf.reset() game.player.life = 10 return lf.query()'
    Write-Host "  bare      $($q1.Result)"
    Ok ($q1.Result -match 'dturn=0 ') 'query advances no game turn' $q1.Result
    Ok ($q1.Result -match 'hostiles=[1-9]') 'something hostile is in view, as LOWLIFE needs' $q1.Result
    Ok ($q1.Result -match 'of your life pool') 'at 10 of 100 with no die_at the bot stops for low life' $q1.Result

    $q2 = Probe 'lf.reset() lf.addTmp("die_at", -400) game.player.life = 10 return lf.query()'
    Write-Host "  die_at    $($q2.Result)"
    Check-Pool $q2.Result 'the pool is life - die_at over max_life - die_at'
    Ok ($q2.Result -match 'perm=-400 sus=0 tmp=0') 'an unrecorded temporary value is the permanent part' $q2.Result
    Ok ($q2.Result -notmatch 'of your life pool') 'the same life with four hundred points behind it does NOT stop' $q2.Result
    if ($q2.Result -match 'frac=([\d.]+) safe=[\d.]+ theirs=([\d.]+)') {
        Ok ([math]::Abs([double]$Matches[1] - [double]$Matches[2]) -lt 0.002) "the reading is the game's own arithmetic ($($Matches[1]) = $($Matches[2]))" $q2.Result
    } else { Ok $false "the reading is the game's own arithmetic" $q2.Result }

    # ----- 2: a timed source with time left --------------------------------
    Write-Host ''
    Write-Host '  --- 2. Heroism with ten turns left: counted in full'
    $q3 = Probe 'lf.reset() local s = lf.heroism(10) if s ~= "ok" then return s end game.player.life = -30 return lf.query()'
    Write-Host "  heroism   $($q3.Result)"
    if ($q3.Result -match '^SETUP') { Inconclusive $q3.Result }
    Ok ($q3.Result -match 'tmp=-200') 'the effect is attributed as a temporary source, at its own figure' $q3.Result
    Ok ($q3.Result -match 'perm=0 sus=0') 'and nothing of it leaks into the permanent part' $q3.Result
    Ok ($q3.Result -match 'trusted=true expiring=0') 'with ten turns left it is trusted' $q3.Result
    Ok ($q3.Result -notmatch 'of your life pool') 'at life -30 the bot does not stop: the pool is 170 of 300' $q3.Result

    # ----- 3: the same source about to lapse -------------------------------
    Write-Host ''
    Write-Host '  --- 3. Heroism with one turn left: NOT counted, and the reason says so'
    $q4 = Probe 'lf.reset() local s = lf.heroism(1) if s ~= "ok" then return s end game.player.life = -30 return lf.query()'
    Write-Host "  lapsing   $($q4.Result)"
    if ($q4.Result -match '^SETUP') { Inconclusive $q4.Result }
    Ok ($q4.Result -match 'trusted=false expiring=1') 'the lapsing source is discounted' $q4.Result
    Ok ($q4.Result -match 'safe=0\.000') 'the safe reading is empty, which at life -30 it is' $q4.Result
    Ok ($q4.Result -match 'of your life pool') 'the bot hands back BEFORE the effect goes' $q4.Result
    Ok ($q4.Result -match '0% of your life pool \(\d+% counting .*Heroism') 'the reason gives both figures and names what it did not count' $q4.Result

    # ----- 4: the adverse direction ----------------------------------------
    Write-Host ''
    Write-Host '  --- 4. die_at above zero: death arrives early'
    $q5 = Probe 'lf.reset() lf.addTmp("die_at", 50) game.player.life = 60 return lf.query()'
    Write-Host "  adverse   $($q5.Result)"
    Check-Pool $q5.Result 'the fifty points above zero come off the pool'
    Ok ($q5.Result -match 'perm=50 ') 'and count as part of the character, not as something to wait out' $q5.Result
    Ok ($q5.Result -match 'of your life pool') 'and the bot stops, where life/max_life would have called it 60%' $q5.Result

    # ----- 5: own power is scaled on the pool ------------------------------
    Write-Host ''
    Write-Host '  --- 5. own power follows the pool as well'
    $p1 = Probe 'lf.reset() game.player.life = 10 return ("own=%.2f"):format(skoobot_reclauded.ownPower(game.player))'
    $p2 = Probe 'lf.reset() lf.addTmp("die_at", -400) game.player.life = 10 return ("own=%.2f"):format(skoobot_reclauded.ownPower(game.player))'
    Write-Host "  bare $($p1.Result) | pooled $($p2.Result)"
    if ($p1.Result -match 'own=([\d.]+)' ) { $own1 = [double]$Matches[1] } else { $own1 = -1 }
    if ($p2.Result -match 'own=([\d.]+)' ) { $own2 = [double]$Matches[1] } else { $own2 = -1 }
    Ok ($own1 -ge 0 -and $own2 -gt $own1) "a character with a pool behind it counts for more ($own1 -> $own2)" "$($p1.Result) $($p2.Result)"
}
finally {
    $rest = Invoke-Bridge -Lua 'if lf then return lf.restore() end return "no helpers"' -TimeoutSec 30 -ErrorAction SilentlyContinue
    Write-Host ''
    Write-Host "  cleanup: $($rest.Result)"
    Stop-Game
}

Write-Host ''
if ($script:HarnessTainted) { Write-Host '[life] TAINTED - void, re-run.'; exit 2 }
if ($script:HarnessFailures.Count -gt 0) {
    Write-Host "[life] FAILED - $($script:HarnessFailures.Count) check(s):"
    foreach ($fail in $script:HarnessFailures) { Write-Host "              $fail" }
    exit 1
}
Write-Host '[life] PASS - the pool the game kills at is what the bot decides on, and a lapsing source is not counted'
exit 0
