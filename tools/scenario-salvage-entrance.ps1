<#
    #62, mishander's level-entrance take (salvage item 8): a bot toggled on
    the stairs the player arrived by explores instead of handing back with
    "standing on a level change".

    The character is put on a level-change tile of the current level (found
    by scanning the map for change_level terrain the character can stand on)
    and ONE decision is driven through query mode three times, with the
    activation's recorded start tile set by hand:

      start = here, never left      -> no "standing on a level change"
      start = elsewhere             -> "standing on a level change"
      start = here, but left since  -> "standing on a level change"
                                       (the exemption lapses: stairs walked
                                       back onto are stairs walked onto)

    and once more off the stairs as a control, so that the hand-back above
    is shown to be the tile's doing. Query mode runs a single skoobot_act
    with do_nothing set, so no game.turn advances and nothing wanders in;
    visible hostiles around the stairs are despawned first, because with a
    hostile in view the decision goes to FIGHT and never reaches the
    explore branch. The game is never saved.

    Exit codes:  0 pass   1 fail   2 tainted   3 inconclusive (no reachable
    level-change tile, or hostiles that cannot be cleared -- a setup problem,
    never a product failure)

    Run:
        powershell -ExecutionPolicy Bypass -File .\tools\scenario-salvage-entrance.ps1

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
    Write-Host "[salvage-entrance] INCONCLUSIVE - $why"
    Stop-Game
    exit 3
}
# The reason alone: a probe line ends with the message log's last lines,
# which still hold the previous probe's hand-back, so a "does not hand back"
# check must not look at the whole line.
function Reason($line) { if ($line -match '^REASON (.*?) \| dturn=') { return $Matches[1] } return $line }

Write-Host ''
Write-Host '[salvage-entrance] explore from the stairs the bot was toggled on (#62)'

try {
    $g = Load-Save -Name $SaveName
    if (-not $g.Ready) { Write-Host "[salvage-entrance] FAILED - could not load '$SaveName' ($($g.Reason))"; exit 1 }
    Check ($g.Addons -match 'skoobot_reclauded') 'the product is loaded'

    $install = Probe @'
local b = rawget(_G, "skoobot_reclauded")
if not b or not b.query then return "OLD no runtime table with query()" end
_G.se = { removed = {} }
function se.hostiles()
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
function se.onChangeLevel()
  local p = game.player
  return game.level.map:checkEntity(p.x, p.y, engine.Map.TERRAIN, "change_level") ~= nil
end
-- Every level-change tile on this level the character could stand on.
function se.exits()
  local p, map = game.player, game.level.map
  local out = {}
  for x = 0, map.w - 1 do
    for y = 0, map.h - 1 do
      if map:checkEntity(x, y, engine.Map.TERRAIN, "change_level") and p:canMove(x, y) then
        out[#out + 1] = { x = x, y = y }
      end
    end
  end
  return out
end
-- Despawn the hostiles in view; they are not put back (the game is never
-- saved). Returns how many went.
function se.clearHostiles()
  local p, map = game.player, game.level.map
  local gone = 0
  p:playerFOV()
  local victims = {}
  core.fov.calc_circle(p.x, p.y, map.w, map.h, p.sight or 10,
    function(_, x, y) return map:opaque(x, y) end,
    function(_, x, y)
      local a = map(x, y, map.ACTOR)
      if a and a ~= p and p:reactionToward(a) < 0 then victims[#victims + 1] = a end
    end, nil)
  for _, a in ipairs(victims) do
    game.level:removeEntity(a, true)
    se.removed[#se.removed + 1] = a
    gone = gone + 1
  end
  p:playerFOV()
  return gone
end
-- Stand on a level-change tile with nothing hostile in view. Tries every
-- exit as found, then clears the hostiles around the first one.
function se.standOnExit()
  local p = game.player
  local exits = se.exits()
  if #exits == 0 then return "SETUP no level-change tile the character can stand on" end
  for _, e in ipairs(exits) do
    p:move(e.x, e.y, true)
    p:playerFOV()
    if se.onChangeLevel() and se.hostiles() == 0 then return ("OK %d,%d of %d exits"):format(e.x, e.y, #exits) end
  end
  local e = exits[1]
  p:move(e.x, e.y, true)
  local gone = se.clearHostiles()
  if se.onChangeLevel() and se.hostiles() == 0 then return ("OK %d,%d of %d exits, %d hostiles despawned"):format(e.x, e.y, #exits, gone) end
  return "SETUP could not clear the hostiles around the exit at " .. e.x .. "," .. e.y
end
-- A tile next to the character that is not a level change.
function se.stepOff()
  local p, map = game.player, game.level.map
  for _, c in pairs(util.adjacentCoords(p.x, p.y)) do
    local x, y = c[1], c[2]
    if map:isBound(x, y) and p:canMove(x, y) and not map:checkEntity(x, y, engine.Map.TERRAIN, "change_level") then
      p:move(x, y, true)
      p:playerFOV()
      return ("OK %d,%d"):format(x, y)
    end
  end
  return "SETUP no adjacent tile off the stairs"
end
function se.reset()
  local p = game.player
  p:removeEffect(p.EFF_PINNED, true, true)
  p.life = p.max_life
  b.active = false; b.do_nothing = false; b.state = 11; b.last_reason = nil   -- 11 = STATE_EXPLORE
  b.activation = nil; b.loop = nil; b.prevloop = nil
end
-- One decision. start: nil to let the activation record where we stand,
-- or { dx = , dy = , left = } for a start tile offset from here and
-- whether the player has "left" it since.
function se.probe(start)
  se.reset()
  local p = game.player
  p:playerFOV()
  if se.hostiles() ~= 0 then return "SETUP a hostile is in view: " .. se.hostiles() end
  if start then
    -- Exactly what activationInit records, with the start tile moved. The
    -- loop scratch goes with it: skoobot_act's fresh-run path always creates
    -- both, and an activation without its scratch is not a state the bot
    -- reaches on its own (checkPowerLevel indexes it unconditionally).
    b.activation = {
      turnCount = 0,
      unspentTotal = p.unused_talents + p.unused_generics + p.unused_talents_types + p.unused_stats + p.unused_prodigies,
      start_level = game.level, start_x = p.x + start.dx, start_y = p.y + start.dy, left_start = start.left or false,
    }
    b.loop = { thinkCount = 0, talentfailed = {}, delta = 0, life = p.life }
  end
  local before = game.turn
  b.query()
  local act = b.activation
  return ("REASON %s | dturn=%d | onexit=%s | start=%s left=%s | log=%s"):format(tostring(b.last_reason),
    game.turn - before, tostring(se.onChangeLevel()),
    act and (tostring(act.start_x) .. "," .. tostring(act.start_y)) or "n/a",
    act and tostring(act.left_start) or "n/a",
    se.lastlog(2))
end
function se.lastlog(n)
  local ld = game.uiset and game.uiset.logdisplay
  if not ld or not ld.getLines then return "no logdisplay" end
  local out = {}
  for _, l in ipairs(ld:getLines(n or 2)) do
    local s = l
    if type(l) == "table" then s = l.str or l.msg or l[1] or l end
    if type(s) == "table" and s.toString then s = s:toString() end
    out[#out + 1] = (tostring(s):gsub("#[^#]*#", ""))
  end
  return table.concat(out, " / ")
end
return "installed"
'@
    if ($install.Result -match '^OLD') { Inconclusive $install.Result }
    Check ($install.Result -eq 'installed') 'probe helpers installed'

    $st = Probe 'return se.standOnExit()' 120
    Write-Host "  $($st.Result)"
    if ($st.Result -match '^SETUP') { Inconclusive $st.Result }
    Check ($st.Result -match '^OK') 'standing on a level-change tile with nothing hostile in view'

    # ----- 1: the activation starts here -> explore --------------------------
    Write-Host ''
    Write-Host '  --- toggled on the stairs: the activation starts here'
    $r1 = Probe 'return se.probe(nil)' 60
    Write-Host "  $($r1.Result)"
    if ($r1.Result -match '^SETUP') { Inconclusive "start here: $($r1.Result)" }
    Check ($r1.Result -match 'onexit=true') 'the character is on the level-change tile'
    Check ((Reason $r1.Result) -notmatch 'standing on a level change') 'the bot does NOT hand back for the level change it started on'
    Check ($r1.Result -match 'would begin exploring' -or $r1.Result -match 'REASON nil') 'it goes on to explore (query says it would begin exploring)'
    Check ($r1.Result -match 'left=false') 'the activation records that the start tile has not been left'
    Check ($r1.Result -match 'dturn=0') 'query advances no game turn'

    # ----- 2: the activation started elsewhere -> hand back ------------------
    Write-Host ''
    Write-Host '  --- walked onto the stairs: the activation started two tiles away'
    $r2 = Probe 'return se.probe({ dx = 2, dy = 0 })' 60
    Write-Host "  $($r2.Result)"
    if ($r2.Result -match '^SETUP') { Inconclusive "start elsewhere: $($r2.Result)" }
    Check ($r2.Result -match 'Handed back: standing on a level change') 'the bot hands back on a level change it walked onto (as before)'
    Check ($r2.Result -match 'dturn=0') 'query advances no game turn'

    # ----- 3: started here but left since -> hand back -----------------------
    Write-Host ''
    Write-Host '  --- back on the stairs it started on: the exemption has lapsed'
    $r3 = Probe 'return se.probe({ dx = 0, dy = 0, left = true })' 60
    Write-Host "  $($r3.Result)"
    if ($r3.Result -match '^SETUP') { Inconclusive "start here, left: $($r3.Result)" }
    Check ($r3.Result -match 'Handed back: standing on a level change') 'once the player has left the start tile, coming back to it hands back'

    # ----- 4: control, off the stairs -> no level-change hand-back -----------
    Write-Host ''
    Write-Host '  --- control: one tile off the stairs, activation started elsewhere'
    $off = Probe 'return se.stepOff()'
    Write-Host "  $($off.Result)"
    if ($off.Result -match '^SETUP') { Inconclusive "step off: $($off.Result)" }
    $r4 = Probe 'return se.probe({ dx = 2, dy = 0 })' 60
    Write-Host "  $($r4.Result)"
    if ($r4.Result -match '^SETUP') { Inconclusive "control: $($r4.Result)" }
    Check ($r4.Result -match 'onexit=false') 'the character is off the level-change tile'
    Check ((Reason $r4.Result) -notmatch 'standing on a level change') 'off the stairs there is no level-change hand-back -- so the hand-backs above were the tile''s doing'
    Check ($r4.Result -match 'left=true') 'loopInit marked the start tile as left once the character stood elsewhere'
}
finally {
    $null = Invoke-Bridge -Lua 'if se then se.reset() end return "clean"' -TimeoutSec 15 -ErrorAction SilentlyContinue
    Stop-Game
}

Write-Host ''
if ($script:Tainted) { Write-Host '[salvage-entrance] TAINTED - void, re-run.'; exit 2 }
if ($script:Fail.Count -gt 0) {
    Write-Host "[salvage-entrance] FAILED - $($script:Fail.Count) check(s):"
    foreach ($f in $script:Fail) { Write-Host "                 $f" }
    exit 1
}
Write-Host '[salvage-entrance] PASS - the start tile is exempt until left; every other level change hands back'
exit 0
