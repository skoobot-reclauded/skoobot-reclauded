<#
    Escort automation (#93): a live escort quest switches the bot out of
    exploring and into keeping up with, and guarding, the escortee.

    The design and the engine reading behind it are in docs/design-escort.md.
    The one fact that shapes every assertion here: the escortee walks ITSELF
    to the portal (mod/ai/escort.lua move_escort) and does not follow the
    player, so the bot's job is to keep up and to be near enough to fight what
    finds it -- not to lead it anywhere.

    The quest is granted for real, with the engine's own
    Player:grantQuest("escort-duty") -- the same call mod/class/Player.lua:174
    makes on entering a level that rolled one. So the escortee, the portal
    grid and the quest entry are the genuine articles, not fixtures.

    Every other hostile is put on the player's faction for the length of the
    run and restored afterwards, the way scenario-explore-exits.ps1 does: with
    anything hostile in view the decision goes to FIGHT and the escort branch
    is never reached, so the probe would measure the wrong branch (#124).

    What is driven, on the fixture:
      A. grant the quest; confirm the escortee carries escort_quest, a quest
         id and the escort_target the portal was placed at;
      B. WARN, the default: the first decision hands back naming the escortee,
         and says exploring is off;
      C. after that acknowledgement the state is SAI_STATE_ESCORT, not
         SAI_STATE_EXPLORE -- auto-explore is not called at all;
      D. escortee moved well outside the band: the bot closes, and the player
         ends the turn nearer to it than it started;
      E. escortee adjacent: the bot holds -- it waits, spends the turn, and
         does not walk;
      F. ESCORT_ACTIVE = IGNORE: the escort is ignored and the bot explores,
         which is what that policy promises;
      G. quest and actor removed: the bot goes back to exploring by itself.

    The save is never written: the quest, the actor and the rules live only in
    this process. The quest is removed again at the end.

    Exit codes:  0 pass   1 fail   2 tainted   3 inconclusive (no quiet spot,
    the quest could not be granted -- setup, never product)

    Run:
        powershell -ExecutionPolicy Bypass -File .\tools\scenario-escort.ps1

    #93.
#>
[CmdletBinding()]
param(
    [string]$SaveName = 'fixture-berserker'
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'harness.ps1')

Write-Host ''
Write-Host '[escort] an escort defers exploring, and the bot keeps up (#93)'

function Inconclusive($why) {
    Write-Host "[escort] INCONCLUSIVE - $why"
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
    if (-not $g.Ready) { Write-Host "[escort] FAILED - could not load '$SaveName' ($($g.Reason))"; exit 1 }
    $null = Assert-Result ([pscustomobject]@{ Status = 'OK'; Result = $g.Addons; Tainted = $false }) 'the product is loaded' -Match 'skoobot_reclauded'

    $install = Probe @'
_G.es = { pacified = nil, quest = nil, npc = nil }
local b = rawget(_G, "skoobot_reclauded")
if not b then return "ERR no skoobot_reclauded runtime table" end
if not b.conditions.module.find("ESCORT_ACTIVE") then return "ERR no ESCORT_ACTIVE entry" end
es.b = b

-- Everything hostile onto our own faction: a hostile in view sends the
-- decision to FIGHT and the escort branch never runs (#124's remedy).
function es.pacify()
  local p = game.player
  es.pacified = {}
  for _, e in pairs(game.level.entities or {}) do
    if e ~= p and e.faction and e.x and p.reactionToward and p:reactionToward(e) < 0 then
      es.pacified[#es.pacified + 1] = { e, e.faction }
      e.faction = p.faction
    end
  end
  if p.x then p:playerFOV() end
  return #es.pacified
end
function es.unpacify()
  local list = es.pacified or {}
  for _, f in ipairs(list) do f[1].faction = f[2] end
  local ok = true
  for _, f in ipairs(list) do if f[1].faction ~= f[2] then ok = false end end
  es.pacified = nil
  if game.player.x then game.player:playerFOV() end
  return ok
end
function es.hostiles()
  local n = tonumber(tostring(es.b.inspect()):match("hostiles=(%d+)"))
  return n or -1
end
function es.reset()
  while #game.dialogs > 0 do game:unregisterDialog(game.dialogs[#game.dialogs]) end
  if es.b.active then es.b.stop("test reset") end
  es.b.active = false; es.b.do_nothing = false; es.b.last_reason = nil
  es.b.activation = nil; es.b.loop = nil; es.b.prevloop = nil
  game.player.life = game.player.max_life
  return "reset"
end
-- The escortee, found the way the product finds it.
function es.findNpc()
  for _, e in pairs(game.level.entities or {}) do
    if e.escort_quest and e.x then return e end
  end
  return nil
end
-- The rules must not be empty or the FIGHT branch has nothing to do; the
-- escort branch never consults them, but a stray hostile would.
function es.rules()
  local p = game.player
  local r = es.b.rules.get(p)
  for _, s in ipairs(es.b.rules.module.SECTIONS) do
    local l = r[s] for i = #l, 1, -1 do l[i] = nil end
  end
  es.b.rules.module.place(r, { tid = "T_ATTACK" }, "Combat")
  return "ok"
end
return "installed"
'@ 30
    if (-not (Assert-Result $install 'helpers installed' -Match '^installed')) { Stop-Game; exit 1 }

    # ----- A: a real escort quest -------------------------------------------
    Write-Host ''
    Write-Host '  --- A. grant the quest; the escortee and its portal are the real ones'
    $grant = Probe @'
es.reset()
es.rules()
local p = game.player
-- The engine's own call (mod/class/Player.lua:174). on_grant places the
-- escortee beside us and the portal far away, and opens the start chat.
local ok, err = pcall(function() p:grantQuest("escort-duty") end)
if not ok then return "SETUP grantQuest raised: " .. tostring(err) end
local npc = es.findNpc()
if not npc then return "SETUP the quest granted no escortee" end
es.npc = npc
es.quest = npc.quest_id
local tx, ty = nil, nil
if type(npc.escort_target) == "table" then tx, ty = npc.escort_target.x, npc.escort_target.y end
-- The start chat is a dialog; close it so the dialog branch does not simply
-- swallow every later decision. The player would answer it -- that hand-back
-- is asserted in B and is the product's, not this scenario's, business.
local dialogs = #game.dialogs
while #game.dialogs > 0 do game:unregisterDialog(game.dialogs[#game.dialogs]) end
return ("OK name=%s quest=%s target=%s,%s reaction=%s dialogs=%d"):format(
  tostring(npc.name), tostring(npc.quest_id), tostring(tx), tostring(ty),
  tostring(p:reactionToward(npc)), dialogs)
'@ 120
    Write-Host "  $($grant.Result)"
    if ($grant.Result -match '^SETUP') { Inconclusive $grant.Result }
    $null = Assert-Result $grant 'the escortee carries a quest id' -Match ' quest=escort-duty-'
    $null = Assert-Result $grant 'the portal was placed and written onto the actor' -Match ' target=\d+,\d+ '
    $null = Assert-Result $grant 'the escortee is not a hostile' -Match ' reaction=\d+'
    $null = Assert-Result $grant 'granting the quest opened the start chat' -Match ' dialogs=[1-9]'

    $quiet = Probe 'return tostring(es.pacify()) .. " left=" .. tostring(es.hostiles())'
    Write-Host "  pacified   $($quiet.Result)"
    if ($quiet.Result -notmatch 'left=0') { Inconclusive "could not clear the view: $($quiet.Result)" }

    # ----- B: the WARN, once ------------------------------------------------
    Write-Host ''
    Write-Host '  --- B. WARN: the first decision says exploring is off, and names who'
    $warn = Probe @'
es.reset()
es.b.conditions.set("ESCORT_ACTIVE", "WARN")
es.b.state = 11
es.b.start()
local out = ("active=%s state=%s reason=%s"):format(
  tostring(es.b.active), es.b.inspect():match("state=(%S+)"), tostring(es.b.last_reason))
if es.b.active then es.b.stop("measured") end
return out
'@
    Write-Host "  $($warn.Result)"
    $null = Assert-Result $warn 'the bot handed back' -Match 'active=false'
    $null = Assert-Result $warn 'it says exploring is off until the escort ends' -Match 'exploring is off until the escort ends'
    $null = Assert-Result $warn 'and names the escortee' -Match 'escorting \S'

    # ----- C: the state, after the acknowledgement ---------------------------
    Write-Host ''
    Write-Host '  --- C. once acknowledged the state is ESCORT, and explore is never called'
    $state = Probe @'
es.reset()
es.b.state = 11
local before = game.player.running
es.b.start()
local out = ("state=%s running=%s reason=%s"):format(
  es.b.inspect():match("state=(%S+)"), tostring(game.player.running ~= nil), tostring(es.b.last_reason))
if es.b.active then es.b.stop("measured") end
return out .. " wasrunning=" .. tostring(before ~= nil)
'@
    Write-Host "  $($state.Result)"
    $null = Assert-Result $state 'the bot is in SAI_STATE_ESCORT' -Match 'state=SAI_STATE_ESCORT'
    $null = Assert-Result $state 'auto-explore was not started' -Match ' running=false'

    # ----- D: closing -------------------------------------------------------
    Write-Host ''
    Write-Host '  --- D. an escortee outside the band is closed on'
    $close = Probe @'
es.reset()
local p, npc = game.player, es.npc
-- Put it well outside FOLLOW_FAR, on a grid it can stand on.
local put = nil
for r = 6, 12 do
  for _, d in ipairs({ {1,0}, {-1,0}, {0,1}, {0,-1} }) do
    local x, y = p.x + d[1] * r, p.y + d[2] * r
    if game.level.map:isBound(x, y) and not game.level.map:checkAllEntities(x, y, "block_move")
       and not game.level.map(x, y, engine.Map.ACTOR) then put = { x, y } break end
  end
  if put then break end
end
if not put then return "SETUP nowhere to put the escortee out of the band" end
npc:move(put[1], put[2], true)
p:playerFOV()
local d0 = core.fov.distance(p.x, p.y, npc.x, npc.y)
local x0, y0 = p.x, p.y
es.b.state = 11
es.b.start()
local d1 = core.fov.distance(p.x, p.y, npc.x, npc.y)
local out = ("d0=%d d1=%d moved=%s state=%s reason=%s"):format(
  d0, d1, tostring(p.x ~= x0 or p.y ~= y0), es.b.inspect():match("state=(%S+)"), tostring(es.b.last_reason))
if es.b.active then es.b.stop("measured") end
return out
'@
    Write-Host "  $($close.Result)"
    if ($close.Result -match '^SETUP') { Inconclusive $close.Result }
    $null = Assert-Result $close 'the bot stayed in the escort state' -Match 'state=SAI_STATE_ESCORT'
    $null = Assert-Result $close 'the player moved' -Match ' moved=true'
    if ($close.Result -match 'd0=(\d+) d1=(\d+)') {
        Ok ([int]$Matches[2] -lt [int]$Matches[1]) "the step closed the gap (d $($Matches[1]) -> $($Matches[2]))" $close.Result
    } else {
        Ok $false 'the probe reported the distances' $close.Result
    }

    # ----- E: holding -------------------------------------------------------
    Write-Host ''
    Write-Host '  --- E. an escortee inside the band is waited for, not walked at'
    $hold = Probe @'
es.reset()
local p, npc = game.player, es.npc
local put = nil
for _, c in pairs(util.adjacentCoords(p.x, p.y)) do
  local x, y = c[1], c[2]
  if game.level.map:isBound(x, y) and not game.level.map:checkAllEntities(x, y, "block_move")
     and not game.level.map(x, y, engine.Map.ACTOR) then put = { x, y } break end
end
if not put then return "SETUP no free tile beside the player" end
npc:move(put[1], put[2], true)
p:playerFOV()
local x0, y0 = p.x, p.y
local e0 = p.energy.value
es.b.state = 11
-- bot.actions is zeroed by start(), so it is read after and NOT as a delta:
-- a delta against the pre-start value counts this activation's actions minus
-- the previous one's and comes out at zero for a correct single action.
-- The turn is not read either -- the engine ticks it after this frame, which
-- is why the energy is the in-frame evidence that something was spent.
es.b.start()
local out = ("moved=%s actions=%d energy=%d->%d state=%s reason=%s"):format(
  tostring(p.x ~= x0 or p.y ~= y0), es.b.actions, e0, p.energy.value,
  es.b.inspect():match("state=(%S+)"), tostring(es.b.last_reason))
if es.b.active then es.b.stop("measured") end
return out
'@
    Write-Host "  $($hold.Result)"
    if ($hold.Result -match '^SETUP') { Inconclusive $hold.Result }
    $null = Assert-Result $hold 'the player did not walk' -Match 'moved=false'
    $null = Assert-Result $hold 'but an action was counted, so #13 sees progress' -Match 'actions=[1-9]'
    if ($hold.Result -match 'energy=(\d+)->(\d+)') {
        Ok ([int]$Matches[2] -lt [int]$Matches[1]) "the wait actually spent the turn's energy ($($Matches[1]) -> $($Matches[2]))" $hold.Result
    } else {
        Ok $false 'the probe reported the energy' $hold.Result
    }
    $null = Assert-Result $hold 'and it is still the escort state' -Match 'state=SAI_STATE_ESCORT'

    # ----- F: IGNORE --------------------------------------------------------
    Write-Host ''
    Write-Host '  --- F. IGNORE means explore as if the escort were not happening'
    $ignore = Probe @'
es.reset()
es.b.conditions.set("ESCORT_ACTIVE", "IGNORE")
es.b.state = 11
es.b.start()
local out = ("state=%s running=%s reason=%s"):format(
  es.b.inspect():match("state=(%S+)"), tostring(game.player.running ~= nil), tostring(es.b.last_reason))
if es.b.active then es.b.stop("measured") end
es.b.conditions.set("ESCORT_ACTIVE", "WARN")
return out
'@
    Write-Host "  $($ignore.Result)"
    $null = Assert-Result $ignore 'the bot is not in the escort state' -Match '^(?!.*state=SAI_STATE_ESCORT)'

    # ----- G: the escort ends -----------------------------------------------
    Write-Host ''
    Write-Host '  --- G. with the escortee gone the bot goes back to exploring'
    $gone = Probe @'
es.reset()
local npc = es.npc
if npc and npc.x then game.level:removeEntity(npc, true) end
game.player:playerFOV()
es.b.state = 11
es.b.start()
local out = ("state=%s reason=%s"):format(
  es.b.inspect():match("state=(%S+)"), tostring(es.b.last_reason))
if es.b.active then es.b.stop("measured") end
return out
'@
    Write-Host "  $($gone.Result)"
    $null = Assert-Result $gone 'the escort state was left' -Match '^(?!.*state=SAI_STATE_ESCORT)'

    # ----- cleanup ----------------------------------------------------------
    $clean = Probe @'
local restored = es.unpacify()
-- Drop the quest so nothing about this run could reach a save.
if es.quest and game.player.quests then game.player.quests[es.quest] = nil end
es.reset()
return ("restored=%s quest=%s"):format(tostring(restored), tostring(game.player.quests and game.player.quests[es.quest]))
'@
    Write-Host "  cleanup    $($clean.Result)"
    $null = Assert-Result $clean 'the pacified hostiles got their factions back' -Match 'restored=true'

    $errs = @(Get-GameLogLines | Where-Object { $_ -match 'Lua Error' })
    Ok ($errs.Count -eq 0) 'no Lua Error in the run' ($errs -join ' | ')
}
finally {
    Stop-Game
}

Write-Host ''
if ($script:HarnessTainted) { Write-Host '[escort] TAINTED - void, re-run.'; exit 2 }
if ($script:HarnessFailures.Count -gt 0) {
    Write-Host "[escort] FAILED - $($script:HarnessFailures.Count) check(s):"
    foreach ($f in $script:HarnessFailures) { Write-Host "                  $f" }
    exit 1
}
Write-Host '[escort] PASS - the escort defers exploring, the bot keeps up and holds, and the policy is honoured'
exit 0
