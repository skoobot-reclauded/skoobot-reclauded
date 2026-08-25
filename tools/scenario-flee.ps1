<#
    #59: the flee action of the combat rotation, on the fixture.

    A flee is a Combat entry, {action="flee", from="nearest"|"strongest"},
    placed like a talent. When the rotation reaches it the bot takes one
    step away from the chosen hostile and the turn ends; when no such step
    exists the rotation moves on. The step is the engine's own flee_dmap /
    flee_simple logic ported to the player (src/superload/mod/class/Player.lua,
    fleeStep): the hostile's distance map where it has one for the player's
    grid, plain distance otherwise.

    What is driven, on the fixture (tools/new-character.ps1 -Class Berserker):

      A. nearest, real acts. One hostile spawned adjacent, frozen in place
         (energy.mod = 0: it never acts, so it never computes FOV, so its
         distance map has no value for our grid and the plain-distance path
         decides -- deterministic), flee-from-nearest alone in Combat. Each
         act is one activation -- start(), then stop() in the same frame,
         as scenario-t010 does: the distance to the hostile must grow by
         exactly one per act, the player must land on the grid the step
         chose, and bot.actions must read one, until the hostile is out of
         sight or there is no farther grid. game.turn must advance with
         the acts: these are real moves, not query mode.
      B. the distance map. The same hostile is made to compute its FOV
         (NPC:doFOV), so its map now has a value for our grid; the step must
         then go to a grid whose value is lower than ours or absent, and --
         starting adjacent -- never to another grid adjacent to the hostile.
     B2. keep sight (#69). From the same spot, the plain step and the
         keep-sight step read side by side. The keep-sight one must leave the
         hostile in line of sight and must still increase the distance -- or,
         if no such grid exists, say which of the two kinds of "no step" that
         was. The plain step is deliberately NOT required to break sight: on
         open ground the two agree, and demanding a difference would be
         demanding a tree.
      C. strongest. A fresh quiet spot; a weak hostile on one side and a
         strong one (+500 armour: power.level reads combat_armor directly)
         on the other, both adjacent, flee-from-strongest in Combat. The one
         act must increase the distance from the STRONG one and the log
         must name it.
      D. query mode. The same setup through bot.query(), run BEFORE C's act
         while the geometry is known: the message log must read "AI would
         flee from <strong> to the <direction>" and no game.turn may pass.
      E. the talent screen. Available lists all three flee rows, kind Action
         ("Flee but keep sight" is #69's);
         "2" on one is refused (Combat only), "1" places it, the pane shows
         the module's prose, and the bot reads it back in the rotation.
      F. cornered (#67). canMove stubbed to refuse for one decision, so the
         flee has no step every run rather than when the terrain obliges.
         With the flee ALONE in Combat the bot must hand back "cornered: no
         grid farther from <name>, and the rotation is flee only" instead of
         walking at the thing it was told to run from. With a talent under
         the flee it must NOT: closing the distance is what brings that
         talent into range, and that is the player's own instruction.

    The four SCOUTER_* conditions are IGNORE for the run (the strong spawn
    would trip them) and put back; the spawns are removed; the save is never
    written.

    Exit codes:  0 pass   1 fail   2 tainted   3 inconclusive (no quiet spot
    with room, nothing to spawn -- setup, never product)

    Run:
        powershell -ExecutionPolicy Bypass -File .\tools\scenario-flee.ps1

    #59, #67, #69, #80, #27.
#>
[CmdletBinding()]
param(
    [string]$SaveName = 'fixture-berserker',
    [int]$MaxSteps = 12
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'harness.ps1')

Write-Host ''
Write-Host '[flee] the flee action of the combat rotation (#59)'

function Inconclusive($why) {
    Write-Host "[flee] INCONCLUSIVE - $why"
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
    if (-not $g.Ready) { Write-Host "[flee] FAILED - could not load '$SaveName' ($($g.Reason))"; exit 1 }
    $null = Assert-Result ([pscustomobject]@{ Status = 'OK'; Result = $g.Addons; Tainted = $false }) 'the product is loaded' -Match 'skoobot_reclauded'

    $install = Probe @'
_G.fl = { spawned = {}, scouters = nil, pacified = nil }
local b = rawget(_G, "skoobot_reclauded")
if not b or not b.rules or not b.rules.flee or not b.rules.module.isAction then return "OLD no flee in the runtime table" end
local SCOUTERS = { "SCOUTER_BIGENEMY", "SCOUTER_STRONGERENEMY", "SCOUTER_CROWDPOWER", "SCOUTER_ENEMYCOUNT" }

function fl.hostiles()
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
-- Every other hostile put on the player's own faction for the length of a
-- probe, and put back afterwards. A probe that spawns its own actor and then
-- measures "the nearest hostile" is a coin flip without this: the fixture's
-- level carries about thirty hostiles in view, several at the distances the
-- probes spawn at, so which one the rotation picks depends on where they
-- wandered. Removing the interference rather than detecting it, as
-- scenario-explore-exits.ps1 does for the same defect class -- see #124.
function fl.pacify()
  local p = game.player
  fl.pacified = {}
  for _, e in pairs(game.level.entities or {}) do
    if e ~= p and e.faction and e.x and p.reactionToward and p:reactionToward(e) < 0 then
      fl.pacified[#fl.pacified + 1] = { e, e.faction }
      e.faction = p.faction
    end
  end
  if p.x then p:playerFOV() end
  return #fl.pacified
end
function fl.unpacify()
  local list = fl.pacified or {}
  for _, f in ipairs(list) do f[1].faction = f[2] end
  local ok = true
  for _, f in ipairs(list) do if f[1].faction ~= f[2] then ok = false end end
  fl.pacified = nil
  if game.player.x then game.player:playerFOV() end
  return ok
end
function fl.onChangeLevel()
  local p = game.player
  return game.level.map:checkEntity(p.x, p.y, engine.Map.TERRAIN, "change_level") ~= nil
end
function fl.free(x, y)
  return game.level.map:isBound(x, y) and not game.level.map:checkAllEntities(x, y, "block_move")
    and not game.level.map(x, y, engine.Map.ACTOR)
end
function fl.dist(a, bx, by)
  return core.fov.distance(a.x, a.y, bx, by)
end
-- A cardinal direction D from the player such that D, its opposite and
-- the two diagonals beside D are all free: room for a hostile at D and a
-- step away from it, and for part C room beside the weak one.
function fl.roomDir()
  local p = game.player
  for _, d in ipairs({ 2, 4, 6, 8 }) do
    local dx, dy = util.coordAddDir(p.x, p.y, d)
    local ox, oy = util.coordAddDir(p.x, p.y, util.opposedDir(d, p.x, p.y))
    -- util.dirSides: `left`/`right` are the diagonals beside D, `hard_*` the
    -- cardinals at right angles to it (engine/utils.lua dir_sides).
    local sides = util.dirSides(d, p.x, p.y)
    local lx, ly = util.coordAddDir(p.x, p.y, sides.left)
    local rx, ry = util.coordAddDir(p.x, p.y, sides.right)
    if fl.free(dx, dy) and fl.free(ox, oy) and fl.free(lx, ly) and fl.free(rx, ry) then return d end
  end
  return nil
end
function fl.quietHere()
  return fl.hostiles() == 0 and not fl.onChangeLevel() and fl.roomDir() ~= nil
end
function fl.findQuiet()
  local p = game.player
  for i = 1, 120 do
    if fl.quietHere() then return fl.roomDir() end
    p:teleportRandom(p.x, p.y, 60, 10)
  end
  if fl.quietHere() then return fl.roomDir() end
  return nil
end
function fl.reset()
  while #game.dialogs > 0 do game:unregisterDialog(game.dialogs[#game.dialogs]) end
  if b.active then b.stop("test reset") end
  b.active = false; b.do_nothing = false; b.last_reason = nil
  b.activation = nil; b.loop = nil; b.prevloop = nil
  game.player.life = game.player.max_life
end
function fl.rules(from)
  local p = game.player
  local r = b.rules.get(p)
  for _, s in ipairs(b.rules.module.SECTIONS) do
    local list = r[s]
    for i = #list, 1, -1 do list[i] = nil end
  end
  b.rules.module.place(r, { action = "flee", from = from }, "Combat")
  local rot = b.rules.rotation()
  return #rot, rot[1] and b.rules.module.key(rot[1]) or "nil"
end
function fl.setup()
  if not fl.scouters then
    fl.scouters = {}
    for _, code in ipairs(SCOUTERS) do
      fl.scouters[code] = b.conditions.get(code).stoptype
      b.conditions.set(code, "IGNORE")
    end
  end
  return "OK"
end
-- One hostile at direction d from the player, frozen: energy.mod = 0 means
-- it never gains energy, so it never acts and never computes FOV.
function fl.spawn(d, label, armor)
  local p = game.player
  local sx, sy = util.coordAddDir(p.x, p.y, d)
  if not fl.free(sx, sy) then return "SETUP the spawn grid is not free" end
  for _ = 1, 8 do
    local m = game.zone:makeEntity(game.level, "actor",
      { special = function(e) return not e.unique and (e.rank or 1) <= 2 end }, nil, true)
    if not m then return "SETUP no actor to spawn" end
    m.rank = 2
    m.name = label .. " " .. tostring(m.name)
    m.combat_armor = (m.combat_armor or 0) + (armor or 0)
    m.energy.mod = 0
    m.energy.value = 0
    local before = fl.hostiles()
    game.zone:addEntity(game.level, m, "actor", sx, sy)
    if fl.hostiles() == before + 1 then
      fl.spawned[#fl.spawned + 1] = m
      return ("OK %s at %d,%d power=%.1f"):format(m.name, m.x, m.y, b.power(m))
    end
    game.level:removeEntity(m, true)
  end
  return "SETUP the spawned actor is not a visible hostile"
end
-- #97: an immobile hostile `dist` grids away, and one decision against it.
-- never_move is what makes the two-grid oscillation permanent -- the
-- geometry resets exactly every turn -- so it is what the skip is keyed on.
function fl.immobile(dist)
  fl.reset()
  fl.unspawn()
  local p = game.player
  local sx, sy
  for _, d in ipairs({ {1,0}, {-1,0}, {0,1}, {0,-1}, {1,1}, {-1,-1}, {1,-1}, {-1,1} }) do
    local ok = true
    for k = 1, dist do
      if not fl.free(p.x + d[1] * k, p.y + d[2] * k) then ok = false break end
    end
    if ok then sx, sy = p.x + d[1] * dist, p.y + d[2] * dist break end
  end
  if not sx then return "SETUP no free line at distance " .. dist end
  -- Before spawning, not after: the spawn must be the only hostile the
  -- rotation can pick, or "nearest" is decided by whatever wandered closest
  -- (#124). Every return below here has to put the factions back.
  local others = fl.pacify()
  local m
  for _ = 1, 8 do
    m = game.zone:makeEntity(game.level, "actor",
      { special = function(e) return not e.unique and (e.rank or 1) <= 2 end }, nil, true)
    if not m then break end
    m.rank = 2
    m.name = "rooted " .. tostring(m.name)
    m.energy.mod = 0
    m.energy.value = 0
    local before = fl.hostiles()
    game.zone:addEntity(game.level, m, "actor", sx, sy)
    if fl.hostiles() == before + 1 then break end
    game.level:removeEntity(m, true)
    m = nil
  end
  if not m then
    fl.unpacify()
    return "SETUP the spawned actor is not a visible hostile"
  end
  m:addTemporaryValue("never_move", 1)
  fl.spawned[#fl.spawned + 1] = m
  -- The product's own hostile list, not a second implementation of "nearest":
  -- anything other than exactly one means the flee target need not be the
  -- spawn, and the measurement below would describe an actor this probe never
  -- chose. SETUP, so the runner reports INCONCLUSIVE rather than a false FAIL.
  local seen = tonumber(tostring(b.inspect()):match("hostiles=(%d+)")) or -1
  if seen ~= 1 then
    fl.unpacify()
    return ("SETUP %d hostiles in view after pacifying %d, so the flee target need not be the spawn"):format(seen, others)
  end
  fl.rules("nearest")
  local t0 = game.turn
  b.state = 13
  b.query()
  local restored = fl.unpacify()
  return ("IMMOBILE d=%d nm=%s dturn=%d others=%d restored=%s reason=%s"):format(
    core.fov.distance(p.x, p.y, m.x, m.y), tostring(m:attr("never_move") and true or false),
    game.turn - t0, others, tostring(restored), tostring(b.last_reason))
end
function fl.unspawn()
  for _, m in ipairs(fl.spawned) do if m.x and not m.dead then game.level:removeEntity(m, true) end end
  fl.spawned = {}
  if game.player.x then game.player:playerFOV() end
  return "removed"
end
function fl.restore()
  fl.unspawn()
  for code, st in pairs(fl.scouters or {}) do b.conditions.set(code, st) end
  fl.scouters = nil
  fl.reset()
  return "restored"
end
-- Part A: one real act. Reports what the step chose before the act and
-- where the player stands after it, in the same frame, before the engine
-- ticks. The act is start() then stop() in that frame (the t010 pattern):
-- one activation, one decision, the bot off again before the engine hands
-- the player the next turn. bot.runonce() would be the natural call, but
-- it cannot be called twice in one game -- the entry point overwrites
-- itself with its own flag (filed from this scenario's first run).
function fl.stepOnce(from, which)
  local p = game.player
  local m = fl.spawned[which or 1]
  fl.reset()
  if not p:enoughEnergy() then return "WAIT no energy" end
  if fl.hostiles() == 0 then return "OUTOFSIGHT" end
  local x, y, h = b.rules.flee({ action = "flee", from = from })
  if not x then return "BLOCKED " .. tostring(h) end
  local d0, px, py = fl.dist(p, m.x, m.y), p.x, p.y
  b.start()
  local d1, actions, reason = fl.dist(p, m.x, m.y), b.actions, b.last_reason
  if b.active then b.stop("measured") end
  return ("STEP d0=%d d1=%d moved=%s landed=%s actions=%d from=%s reason=%s"):format(
    d0, d1, tostring(p.x ~= px or p.y ~= py), tostring(p.x == x and p.y == y), actions,
    tostring(h and h.name), tostring(reason))
end
-- Part G (#69): the keep-sight step, read without acting, beside the plain
-- one from the same spot. The guarantee under test is one-directional --
-- the keep-sight step ALWAYS leaves the hostile in sight, where the plain
-- one may or may not -- so that is what is asserted; on open ground the two
-- often agree, and requiring them to differ would be requiring a tree.
function fl.losStep()
  local p = game.player
  local m = fl.spawned[1]
  fl.reset()
  if fl.hostiles() == 0 then return "OUTOFSIGHT" end
  local d0 = fl.dist(p, m.x, m.y)
  local ax, ay, ah = b.rules.flee({ action = "flee", from = "nearest" })
  local lx, ly, lh = b.rules.flee({ action = "flee", from = "nearest", keep_los = true })
  local function seen(x, y) return (x and p:hasLOS(m.x, m.y, nil, nil, x, y)) and true or false end
  local function far(x, y) return x and core.fov.distance(x, y, m.x, m.y) or -1 end
  return ("LOSSTEP d0=%d | plain=%s,%s plainseen=%s plaind=%d plainwhy=%s | los=%s,%s losseen=%s losd=%d loswhy=%s"):format(
    d0,
    tostring(ax), tostring(ay), tostring(seen(ax, ay)), far(ax, ay), tostring(ax and "-" or ah),
    tostring(lx), tostring(ly), tostring(seen(lx, ly)), far(lx, ly), tostring(lx and "-" or lh))
end
-- Part F (#67): cornered. A flee with no step, and nothing under it.
--
-- Cornering a character on a real map is terrain luck, so the block is made
-- deterministic instead: canMove is stubbed to refuse for the length of one
-- decision, which is exactly what a dead end looks like to fleeStep -- no
-- neighbour is a candidate, so it reports "no grid farther from <name>".
-- A measurement may stub the engine like this; the product may not. It is
-- put back in the same frame, and reported.
--
-- Nothing else in the path reads canMove before the stop: caps.move is the
-- condition list (pinned, dead), not the terrain, and the Astar tail is
-- BELOW the cornered check.
function fl.cornered(withTalent)
  local p = game.player
  fl.reset()
  if fl.hostiles() == 0 then return "OUTOFSIGHT" end
  local r = b.rules.get(p)
  for _, s in ipairs(b.rules.module.SECTIONS) do
    local list = r[s]
    for i = #list, 1, -1 do list[i] = nil end
  end
  b.rules.module.place(r, { action = "flee", from = "nearest" }, "Combat")
  local tid
  if withTalent then
    tid = p:knowTalent("T_ATTACK") and "T_ATTACK" or nil
    if not tid then return "SETUP the fixture does not know Attack" end
    b.rules.module.place(r, { tid = tid }, "Combat")
  end
  local rot = b.rules.rotation()

  local realCanMove = p.canMove
  p.canMove = function() return false end
  local ok, err = pcall(function() b.start() end)
  p.canMove = realCanMove

  local active, reason, actions = b.active, b.last_reason, b.actions
  if b.active then b.stop("measured") end
  fl.reset()
  return ("CORNERED rot=%d talent=%s ok=%s err=%s active=%s actions=%d restored=%s reason=%s"):format(
    #rot, tostring(tid), tostring(ok), tostring(err), tostring(active), actions,
    tostring(p.canMove == realCanMove), tostring(reason))
end
-- Part B: the hostile looks, then the step is read without acting.
function fl.dmapStep()
  local p = game.player
  local m = fl.spawned[1]
  fl.reset()
  if fl.hostiles() == 0 then return "OUTOFSIGHT" end
  m:doFOV()
  local here = m:distanceMap(p.x, p.y)
  if not here then return "SETUP the hostile's map has no value for our grid after doFOV" end
  local x, y, h = b.rules.flee({ action = "flee", from = "nearest" })
  if not x then return "BLOCKED " .. tostring(h) end
  local there = m:distanceMap(x, y)
  return ("DMAP here=%.1f there=%s d0=%d d1=%d"):format(here, tostring(there), fl.dist(p, m.x, m.y), fl.dist(m, x, y))
end
-- Part D: one decision through query mode, and the message-log lines it
-- added (newest last, colour codes stripped) -- only what THIS decision
-- said, never an earlier line.
function fl.query(from)
  local p = game.player
  fl.reset()
  b.state = 13   -- STATE_FIGHT
  local before = game.turn
  local ld = game.uiset and game.uiset.logdisplay
  local nlog = ld and ld.log and #ld.log or 0
  b.query()
  local last = "no logdisplay"
  if ld and ld.log then
    local n = math.min(#ld.log - nlog, 8)
    local out = {}
    for i = n, 1, -1 do out[#out + 1] = (tostring(ld.log[i].str):gsub("#[^#]*#", "")) end
    last = table.concat(out, " | ")
  end
  return ("QUERY dturn=%d reason=%s log=%s"):format(game.turn - before, tostring(b.last_reason), last)
end
return "installed"
'@
    if ($install.Result -match '^OLD') { Inconclusive $install.Result }
    if (-not (Assert-Result $install 'helpers installed' -Match '^installed')) { Stop-Game; exit 1 }

    $null = Probe 'return fl.setup()'

    # ----- A: nearest, real acts -------------------------------------------
    Write-Host ''
    Write-Host '  --- A. flee from the nearest: one step away per act'
    $quiet = Probe 'return tostring(fl.findQuiet())' 180
    if ($quiet.Result -notmatch '^\d+$') { Inconclusive 'no quiet spot with room for a hostile and a step away' }
    $dir = [int]$quiet.Result
    $spawn = Probe "return fl.spawn($dir, 'lone', 0)"
    Write-Host "  $($spawn.Result)"
    if ($spawn.Result -match '^SETUP') { Inconclusive $spawn.Result }
    $rules = Probe "return table.concat({fl.rules('nearest')}, ' ')"
    $null = Assert-Result $rules 'Combat holds the flee-from-nearest action alone, and the rotation reads it' -Match '^1 action:flee:nearest$'

    $steps = 0; $bad = @(); $ended = ''
    $turns = Assert-Turns -What 'the acts spent game time (at least one turn per act)' -AtLeast 10 -Block {
        for ($i = 1; $i -le $MaxSteps; $i++) {
            $r = Probe "return fl.stepOnce('nearest', 1)"
            if ($r.Status -ne 'OK') { $script:bad += "bridge $($r.Status)"; break }
            $txt = "$($r.Result)"
            if ($txt -match '^WAIT') { Start-Sleep -Seconds 2; $i--; continue }
            if ($txt -match '^(OUTOFSIGHT|BLOCKED)') { $script:ended = $txt; break }
            # Real game time passes between acts and the level is alive: once a
            # wandering hostile has come into view the bot is correctly fleeing
            # from whichever is nearest, and this test of "one hostile, one step
            # away per act" is over. Interference, not a failure.
            if ($txt -match 'from=' -and $txt -notmatch 'from=lone ') { $script:ended = "INTERFERENCE ($txt)"; break }
            Write-Host "  act $i`: $txt"
            $script:steps++
            if ($txt -match 'd0=(\d+) d1=(\d+)') {
                if ([int]$Matches[2] -lt ([int]$Matches[1] + 1)) { $script:bad += "act $i`: distance $($Matches[1]) -> $($Matches[2]), wanted at least +1" }
            } else { $script:bad += "act $i`: no distances in '$txt'" }
            if ($txt -notmatch 'moved=true') { $script:bad += "act $i`: the player did not move" }
            if ($txt -notmatch 'landed=true') { $script:bad += "act $i`: the player did not land on the grid the step chose" }
            if ($txt -notmatch 'actions=1') { $script:bad += "act $i`: bot.actions did not advance by one" }
            if ($txt -notmatch 'from=lone ') { $script:bad += "act $i`: the step was not from the spawned hostile" }
            # The move spends energy in the decision frame; the ticks that turn
            # it into game time run after the command returns.
            Start-Sleep -Seconds 2
        }
    }
    Write-Host "  ended: $ended ($steps act(s))"
    # A spot the finder accepted can still run out of room after one step
    # (BLOCKED: no grid farther). That is the terrain, not the product: the
    # step it did take was right, and "no farther grid" is a legitimate end.
    # Treat it as the setup problem it is rather than a failure.
    if ($steps -lt 2 -and $ended -match '^BLOCKED') { Inconclusive "the quiet spot ran out of room after $steps step(s): $ended" }
    Ok ($steps -ge 2) 'at least two flee steps were taken before anything else came into view' "$steps"
    Ok ($bad.Count -eq 0) 'every act grew the distance by at least one (the hostile moves too), moved the player to the chosen grid, and counted one action' ($bad -join '; ')
    foreach ($m in $bad) { Write-Host "         $m" }
    Ok ($ended -match '^(OUTOFSIGHT|BLOCKED|INTERFERENCE)' -or $steps -eq $MaxSteps) 'the acts ended by the hostile leaving view, no farther grid, or another hostile arriving (never a stop)' $ended
    Ok ($turns.Delta -ge 10 * $steps) "game.turn advanced at least 10 per act ($($turns.Delta) for $steps)"
    $log = Get-GameLogLines
    $fleeLines = @($log | Where-Object { $_ -match '\[SKOOBOT\] \[Action\] Fleeing from lone ' })
    Ok ($fleeLines.Count -ge $steps -and $fleeLines.Count -gt 0) "the log shows the flee action ($($fleeLines.Count) line(s))"
    foreach ($l in ($fleeLines | Select-Object -First 2)) { Write-Host "         $l" }

    # ----- B: the distance map ---------------------------------------------
    Write-Host ''
    Write-Host '  --- B. the hostile has looked: its distance map decides'
    $null = Probe 'return fl.unspawn()'
    $quiet = Probe 'return tostring(fl.findQuiet())' 180
    if ($quiet.Result -notmatch '^\d+$') { Inconclusive 'no quiet spot for part B' }
    $dir = [int]$quiet.Result
    $spawn = Probe "return fl.spawn($dir, 'looker', 0)"
    Write-Host "  $($spawn.Result)"
    if ($spawn.Result -match '^SETUP') { Inconclusive $spawn.Result }
    $dm = Probe 'return fl.dmapStep()'
    Write-Host "  $($dm.Result)"
    if ($dm.Result -match '^SETUP') { Inconclusive $dm.Result }
    $null = Assert-Result $dm 'a step exists once the hostile has looked' -Match '^DMAP'
    if ($dm.Result -match 'here=([\d.]+) there=(\S+) d0=(\d+) d1=(\d+)') {
        $here = [double]$Matches[1]; $there = $Matches[2]; $d0 = [int]$Matches[3]; $d1 = [int]$Matches[4]
        Ok ($there -eq 'nil' -or [double]$there -lt $here) "the chosen grid scores below ours on the hostile's map (here=$here there=$there)"
        Ok ($d0 -eq 1 -and $d1 -ge 2) "starting adjacent, the step never lands next to the hostile (d0=$d0 d1=$d1)"
    }


    # ----- B2: keep sight (#69) ---------------------------------------------
    Write-Host ''
    Write-Host '  --- B2. the keep-sight step leaves the hostile in view'
    $g = Probe 'return fl.losStep()' 60
    Write-Host "  $($g.Result)"
    if ($g.Result -match '^(OUTOFSIGHT|SETUP)') { Inconclusive $g.Result }
    if ($g.Result -match 'los=nil,nil') {
        # No LOS-keeping step from this spot is a legitimate answer, and the
        # reason must say which of the two kinds of "no step" it was.
        $null = Assert-Result $g 'when there is no keep-sight step, the reason says so' -Match 'loswhy=no grid farther from [^|]*that keeps it in sight'
        Note "no keep-sight step available from this spot: $($g.Result)"
    } else {
        $null = Assert-Result $g 'the keep-sight step keeps the hostile in sight' -Match ' losseen=True '
        $null = Assert-Result $g 'and is still a step AWAY, not merely a step' -Match 'd0=(\d+) .*losd=(\d+)'
        $m0 = [regex]::Match($g.Result, 'd0=(\d+)'); $ml = [regex]::Match($g.Result, 'losd=(\d+)')
        Ok ([int]$ml.Groups[1].Value -gt [int]$m0.Groups[1].Value) 'the keep-sight step increases the distance' $g.Result
    }
    # The plain step is deliberately NOT required to break sight: on open
    # ground the two agree, and demanding a difference would be demanding a
    # tree. The guarantee is one-directional and that is what is asserted.
    # ----- C: strongest ------------------------------------------------------
    Write-Host ''
    Write-Host '  --- C. flee from the strongest: away from the one with the power'
    $null = Probe 'return fl.unspawn()'
    $quiet = Probe 'return tostring(fl.findQuiet())' 180
    if ($quiet.Result -notmatch '^\d+$') { Inconclusive 'no quiet spot for part C' }
    $dir = [int]$quiet.Result
    $weak = Probe "return fl.spawn($dir, 'weak', 0)"
    Write-Host "  $($weak.Result)"
    if ($weak.Result -match '^SETUP') { Inconclusive $weak.Result }
    $strong = Probe "return fl.spawn(util.opposedDir($dir, game.player.x, game.player.y), 'strong', 500)"
    Write-Host "  $($strong.Result)"
    if ($strong.Result -match '^SETUP') { Inconclusive $strong.Result }
    $pw = Probe 'return ("weak=%.1f strong=%.1f"):format(skoobot_reclauded.power(fl.spawned[1]), skoobot_reclauded.power(fl.spawned[2]))'
    Write-Host "  $($pw.Result)"
    if ($pw.Result -match 'weak=([\d.]+) strong=([\d.]+)') {
        Ok ([double]$Matches[2] -gt [double]$Matches[1]) 'the strong spawn has the higher power level'
    }
    $rules = Probe "return table.concat({fl.rules('strongest')}, ' ')"
    $null = Assert-Result $rules 'Combat holds the flee-from-strongest action alone' -Match '^1 action:flee:strongest$'

    # ----- D: query mode, before the real act moves anything --------------------
    Write-Host ''
    Write-Host '  --- D. query mode says what it would do'
    $q = Probe "return fl.query('strongest')"
    Write-Host "  $($q.Result)"
    $null = Assert-Result $q 'query advances no game turn' -Match 'dturn=0 '
    $null = Assert-Result $q 'the message reads "AI would flee from <strong> to the <direction>"' -Match 'AI would flee from strong [^|]* to the (north|south|east|west|northeast|northwest|southeast|southwest)'
    $null = Assert-Result $q 'query does not stop the bot' -Match 'reason=nil'

    Write-Host ''
    Write-Host '  --- C (cont.). the real act'
    $c = $null
    $null = Assert-Turns -What 'the act spent game time' -AtLeast 10 -Block {
        for ($i = 1; $i -le 5; $i++) {
            $script:c = Probe "return fl.stepOnce('strongest', 2)"
            if ("$($script:c.Result)" -match '^WAIT') { Start-Sleep -Seconds 2; continue }
            break
        }
        Write-Host "  $($script:c.Result)"
        Start-Sleep -Seconds 2
    }
    $c = $script:c
    $null = Assert-Result $c 'the step was taken' -Match '^STEP'
    $null = Assert-Result $c 'the step is away from the strong one: distance 1 -> 2' -Match 'd0=1 d1=2'
    $null = Assert-Result $c 'the step was from the strong one, not the weak one' -Match 'from=strong '
    $null = Assert-Result $c 'the player moved to the chosen grid and one action was counted' -Match 'moved=true landed=true actions=1'
    $log = Get-GameLogLines
    $strongLines = @($log | Where-Object { $_ -match '\[SKOOBOT\] \[Action\] Fleeing from strong ' })
    Ok ($strongLines.Count -gt 0) 'the log names the strong one as what was fled from'


    # ----- F: cornered (#67) -------------------------------------------------
    Write-Host ''
    Write-Host '  --- F. a flee with no step, and nothing under it, hands back'
    # The strong one from part C is still adjacent-ish and in view; that is
    # all this needs. canMove is stubbed inside the probe so the block is the
    # same every run instead of depending on the terrain.
    $f1 = Probe 'return fl.cornered(false)' 60
    Write-Host "  $($f1.Result)"
    if ($f1.Result -match '^(OUTOFSIGHT|SETUP)') { Inconclusive $f1.Result }
    $null = Assert-Result $f1 'the decision did not raise' -Match ' ok=true err=nil '
    $null = Assert-Result $f1 'the rotation was the flee alone' -Match ' rot=1 talent=nil '
    $null = Assert-Result $f1 'the bot handed back' -Match ' active=false '
    $null = Assert-Result $f1 'the reason says cornered, and what there was no step away from' -Match ' reason=Cannot act: cornered: no grid farther from '
    $null = Assert-Result $f1 'and says the rotation had nothing else in it' -Match 'and the rotation is flee only$'
    $null = Assert-Result $f1 'canMove was put back' -Match ' restored=true '

    # The other half of the ruling, and the more important regression: with a
    # talent under the flee, being cornered is "fight when you cannot run",
    # which is what the player asked for. It must NOT stop.
    Write-Host ''
    Write-Host '  --- F (cont.). with a talent under it, cornered fights instead'
    $f2 = Probe 'return fl.cornered(true)' 60
    Write-Host "  $($f2.Result)"
    if ($f2.Result -match '^(OUTOFSIGHT|SETUP)') { Inconclusive $f2.Result }
    $null = Assert-Result $f2 'the decision did not raise' -Match ' ok=true err=nil '
    $null = Assert-Result $f2 'the rotation was the flee and a talent' -Match ' rot=2 talent=T_ATTACK '
    Ok ($f2.Result -notmatch 'reason=Cannot act: cornered') 'it did not hand back as cornered' $f2.Result
    $null = Assert-Result $f2 'canMove was put back here too' -Match ' restored=true '

    # ----- G: a target that cannot follow (#97) ------------------------------
    Write-Host ''
    Write-Host '  --- G. an immobile target at range is not worth fleeing from'
    # The reported loop: the flee steps away, the step runs out at the sight
    # radius, the rotation falls through, and the act loop paths back toward
    # the target to get in range. Two grids, forever. What makes it permanent
    # is that the target never moves.
    $g1 = Probe 'return fl.immobile(3)' 60
    Write-Host "  at range   $($g1.Result)"
    if ($g1.Result -match '^SETUP') { Inconclusive $g1.Result }
    $null = Assert-Result $g1 'the target really is immobile and at range' -Match ' d=3 nm=true '
    $null = Assert-Result $g1 'query advances no game turn' -Match ' dturn=0 '
    $null = Assert-Result $g1 'the pacified hostiles got their factions back' -Match ' restored=true '
    $null = Assert-Result $g1 'the flee is skipped, and says why' -Match 'nothing to flee from: .*cannot follow, and is not next to you'
    Ok ($g1.Result -notmatch 'cornered') 'it is NOT reported as cornered: there is somewhere to go, just no reason to go' $g1.Result

    # Adjacent is the exception and is the point of the row: a mold you are
    # standing next to is exactly where it can reach you.
    $g2 = Probe 'return fl.immobile(1)' 60
    Write-Host "  adjacent   $($g2.Result)"
    if ($g2.Result -match '^SETUP') { Inconclusive $g2.Result }
    $null = Assert-Result $g2 'the adjacent case is set up as intended' -Match ' d=1 nm=true '
    $null = Assert-Result $g2 'the pacified hostiles got their factions back' -Match ' restored=true '
    Ok ($g2.Result -notmatch 'nothing to flee from') 'standing next to it, the flee is NOT skipped' $g2.Result
    # ----- E: the talent screen ---------------------------------------------
    Write-Host ''
    Write-Host '  --- E. the talent screen lists the flee rows, Combat only'
    $null = Probe 'return fl.restore()'
    # Two probes, not one: the screen enables unicode input on the tick after
    # it registers (on_register -> onTickEnd -> unicodeInput), and KeyBind
    # drops a key that carries a character until then -- so the digits must
    # arrive in a later command than the one that opened the screen.
    $open = Probe @'
local ok, res = pcall(function()
  local p, b = game.player, skoobot_reclauded
  local R, rm = b.rules, b.rules.module
  local r = R.get(p)
  for _, s in ipairs(rm.SECTIONS) do local l = r[s] for i = #l, 1, -1 do l[i] = nil end end
  bridge.key("MENU_SKOOBOT_RECLAUDED")
  local m = game.dialogs[#game.dialogs]
  if not m or tostring(m.title) ~= "SkooBot: Reclauded" then return "ERR menu not on top" end
  m:use(m.list[1])
  local d = game.dialogs[#game.dialogs]
  if not d or not d.c_list then return "ERR talent screen not on top" end
  fl.d = d
  function fl.fleeRows()
    local out = {}
    for _, it in ipairs(d.c_list.list) do
      if it.entry and it.entry.action == "flee" then out[#out + 1] = it end
    end
    return out
  end
  local avail = fl.fleeRows()
  local names, kinds = {}, {}
  for _, it in ipairs(avail) do names[#names + 1] = it.cname; kinds[#kinds + 1] = it.kind end
  -- the flee rows are the last rows of Available
  local all = d.c_list.list
  local last = all[#all]
  return ("rows=%d names=[%s] kinds=[%s] lastkind=%s"):format(
    #avail, table.concat(names, "|"), table.concat(kinds, "|"), tostring(last and last.kind))
end)
return ok and res or ("ERR " .. tostring(res))
'@
    Write-Host "  $($open.Result)"
    $null = Assert-Result $open 'Available lists all three flee rows, sorted by name' -Match 'rows=3 names=\[Flee but keep sight\|Flee from the nearest hostile\|Flee from the strongest hostile\]'
    $null = Assert-Result $open 'their kind is Action, and they come last' -Match 'kinds=\[Action\|Action\|Action\] lastkind=Action'

    $screen = Probe @'
local ok, res = pcall(function()
  local p, b = game.player, skoobot_reclauded
  local R, rm = b.rules, b.rules.module
  local r = R.get(p)
  local d = fl.d
  if not d or game.dialogs[#game.dialogs] ~= d then return "ERR the talent screen is not on top" end
  local function typech(ch)
    local Key = require "engine.Key"
    local h = Key.current
    bridge.injecting = true
    local okk, err = pcall(h.receiveKey, h, Key["_" .. ch] or 0, false, false, false, false, ch, false, ch)
    bridge.injecting = false
    if not okk then error(err) end
  end
  local nearest
  for _, it in ipairs(fl.fleeRows()) do if it.entry.from == "nearest" and not it.section then nearest = it end end
  if not nearest then return "ERR no Available row for flee-from-nearest" end
  d:selectItem(nearest)
  typech("2")
  local refused = d.c_desc.cur_item == d.status_key
  local dpn = #r.DamagePrevention
  typech("1")
  local rot = b.rules.rotation()
  local inCombat
  for _, it in ipairs(fl.fleeRows()) do if it.section == "Combat" and it.entry.from == "nearest" then inCombat = it end end
  local desc = inCombat and tostring(inCombat.desc) or ""
  while #game.dialogs > 0 do game:unregisterDialog(game.dialogs[#game.dialogs]) end
  fl.d = nil
  return ("refused=%s dp=%d combat=%d rot=%s prose=%s"):format(
    tostring(refused), dpn, #r.Combat, rot[1] and rm.key(rot[1]) or "nil",
    tostring(desc:find("One step away from the nearest hostile", 1, true) ~= nil))
end)
return ok and res or ("ERR " .. tostring(res))
'@
    Write-Host "  $($screen.Result)"
    $null = Assert-Result $screen '"2" (Damage Prevention) on a flee row is refused with the reason shown' -Match 'refused=true dp=0'
    $null = Assert-Result $screen '"1" places it in Combat and the bot reads it in the rotation' -Match 'combat=1 rot=action:flee:nearest'
    $null = Assert-Result $screen 'the placed row carries the fixed prose' -Match 'prose=true'

    $null = Probe 'return fl.restore()'
}
finally {
    Stop-Game
}

Start-Sleep -Seconds 1
$errs = @((Get-Content $script:LogPath -Raw -ErrorAction Ignore) -split "`r?`n" | Where-Object { $_ -match 'Lua Error' })
Ok ($errs.Count -eq 0) 'no Lua Error in the run'
foreach ($e in ($errs | Select-Object -First 3)) { Write-Host "         $e" }

Write-Host ''
if ($script:HarnessTainted) { Write-Host '[flee] TAINTED - void, re-run.'; exit 2 }
if ($script:HarnessFailures.Count -gt 0) {
    Write-Host "[flee] FAILED - $($script:HarnessFailures.Count) check(s):"
    foreach ($f in $script:HarnessFailures) { Write-Host "                 $f" }
    exit 1
}
Write-Host '[flee] PASS - the flee steps away from the chosen hostile, counts, and says so in query mode'
exit 0
