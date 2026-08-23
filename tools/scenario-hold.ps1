<#
    #15: "hold while impaired" -- a per-entry flag on a Combat placement that
    the rotation skips while the character is stunned, dazed, confused or
    frozen, so the big hit is not spent at half damage.

    Only a player who has set the DEBUFF_* stop to WARN or IGNORE ever sees
    it act: at STOP the bot hands back before the rotation runs. The
    scenario shows both halves, on the fixture (tools/new-character.ps1
    -Class Berserker):

      1. Combat = [Rockswallow (hold), Attack]. Rockswallow is learnt for the
         run as scenario-t010 does: nothing in its pre-use depends on
         equipment, so the availability filter lets it through, and in query
         mode no talent is actually used, so its target condition never
         matters. Attack is innate, so EFF_STUNNED's "3 random talents on
         cooldown" can never take it. Every probe drives ONE decision through
         query mode against one frozen adjacent hostile (no game.turn
         passes) and reads the message log and the rotation the bot built.
      2. Control, unafflicted: the bot would use Rockswallow -- the FIRST.
      3. EFF_STUNNED applied, DEBUFF_STUNNED at IGNORE: the bot would use
         Attack -- the SECOND -- with the held entry logged as held, and the
         rotation the bot built holds Attack alone.
     3b. Combat = [Rockswallow (hold)] alone, still stunned: the rotation is
         empty, and the stop must say WHY -- "every one is held while
         impaired (1)", not the old "none configured, or all on cooldown",
         which was untrue on both counts and left holding mentioned only on
         the debug channel (#75). The loadout hint is not offered: it belongs
         to a player who has configured nothing, not to one whose talents are
         merely held.
     3c. The same held rotation at EFF_STUNNED durations 5, 2 and 1, each
         applied fresh. At 5 and 2 the entry is still held; at 1 -- the last
         turn -- it is not, because waiting out an impairment that lapses
         anyway costs the rotation a turn and buys nothing (#68). The probe
         reports the engine's own dur, whether the stun is traceable to a
         live effect through __tmpvals, and the rotation, so the turn
         boundary is in the record rather than in someone's head.
      4. The same stun with DEBUFF_STUNNED at STOP: the bot hands back for
         the stun before the rotation runs -- the flag is a refinement of
         the stop, not a replacement.
      5. The stun removed (and the cooldowns it set cleared): Rockswallow
         again -- the FIRST.
      6. The talent screen: the Combat row shows ", held" and the pane the
         flag's prose; Space clears it and sets it again; Space on an
         Available row is refused; the row's action menu offers the toggle;
         "Also add to Recovery" gives Recovery its own table without the
         flag.

    The four SCOUTER_* conditions are IGNORE for the run and put back, as is
    DEBUFF_STUNNED; the spawn is removed; the save is never written.

    Exit codes:  0 pass   1 fail   2 tainted   3 inconclusive (no quiet spot,
    nothing to spawn, the talent could not be learnt, the stun resisted --
    setup, never product)

    Run:
        powershell -ExecutionPolicy Bypass -File .\tools\scenario-hold.ps1

    #15, #68, #75, #27.
#>
[CmdletBinding()]
param(
    [string]$SaveName = 'fixture-berserker',
    [string]$Held = 'T_ROCKSWALLOW',
    [string]$Plain = 'T_ATTACK'
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'harness.ps1')

Write-Host ''
Write-Host '[hold] hold a Combat entry while impaired (#15)'

function Inconclusive($why) {
    Write-Host "[hold] INCONCLUSIVE - $why"
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
    if (-not $g.Ready) { Write-Host "[hold] FAILED - could not load '$SaveName' ($($g.Reason))"; exit 1 }
    $null = Assert-Result ([pscustomobject]@{ Status = 'OK'; Result = $g.Addons; Tainted = $false }) 'the product is loaded' -Match 'skoobot_reclauded'

    $install = Probe @"
_G.ho = { spawned = nil, saved = nil }
local b = rawget(_G, "skoobot_reclauded")
if not b or not b.rules or not b.impaired or not b.rules.rotation then return "OLD no hold support in the runtime table" end
local HELD, PLAIN = "$Held", "$Plain"
local CONDS = { "SCOUTER_BIGENEMY", "SCOUTER_STRONGERENEMY", "SCOUTER_CROWDPOWER", "SCOUTER_ENEMYCOUNT", "DEBUFF_STUNNED" }

function ho.hostiles()
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
function ho.onChangeLevel()
  local p = game.player
  return game.level.map:checkEntity(p.x, p.y, engine.Map.TERRAIN, "change_level") ~= nil
end
function ho.freeAdjacent()
  local p = game.player
  for _, c in pairs(util.adjacentCoords(p.x, p.y)) do
    local x, y = c[1], c[2]
    if game.level.map:isBound(x, y) and not game.level.map:checkAllEntities(x, y, "block_move")
       and not game.level.map(x, y, engine.Map.ACTOR) then return x, y end
  end
  return nil
end
function ho.findQuiet()
  local p = game.player
  for i = 1, 80 do
    if ho.hostiles() == 0 and not ho.onChangeLevel() and ho.freeAdjacent() then return true end
    p:teleportRandom(p.x, p.y, 60, 10)
  end
  return ho.hostiles() == 0 and not ho.onChangeLevel() and ho.freeAdjacent() ~= nil
end
function ho.reset()
  while #game.dialogs > 0 do game:unregisterDialog(game.dialogs[#game.dialogs]) end
  if b.active then b.stop("test reset") end
  b.active = false; b.do_nothing = false; b.last_reason = nil
  b.activation = nil; b.loop = nil; b.prevloop = nil
  b.data(game.player).stopwarn = {}
  game.player.life = game.player.max_life
  -- EFF_STUNNED puts up to three talents on a 1-turn cooldown; no turn passes
  -- here, so clear them or the held talent would be skipped for the wrong reason.
  game.player.talents_cd[HELD] = nil
  game.player.talents_cd[PLAIN] = nil
end
function ho.setup()
  local p = game.player
  if not p:getTalentFromId(HELD) then return "SETUP no talent " .. HELD end
  if not p:knowTalent(HELD) then p:learnTalent(HELD, true, 1) end
  if not p:knowTalent(HELD) then return "SETUP could not learn " .. HELD end
  if not p:knowTalent(PLAIN) then return "SETUP " .. PLAIN .. " is not known" end
  local r = b.rules.get(p)
  for _, s in ipairs(b.rules.module.SECTIONS) do
    local list = r[s]
    for i = #list, 1, -1 do list[i] = nil end
  end
  b.rules.module.place(r, { tid = HELD, hold = true }, "Combat")
  b.rules.module.place(r, { tid = PLAIN }, "Combat")
  ho.saved = ho.saved or {}
  for _, code in ipairs(CONDS) do
    ho.saved[code] = ho.saved[code] or b.conditions.get(code).stoptype
    b.conditions.set(code, "IGNORE")
  end
  return ("OK combat=%s hold1=%s hold2=%s"):format(table.concat(b.rules.tids(p, "Combat"), ","),
    tostring(r.Combat[1].hold), tostring(r.Combat[2].hold))
end
function ho.spawn()
  local p = game.player
  local sx, sy = ho.freeAdjacent()
  if not sx then return "SETUP no free adjacent tile" end
  for _ = 1, 8 do
    local m = game.zone:makeEntity(game.level, "actor",
      { special = function(e) return not e.unique and (e.rank or 1) <= 2 end }, nil, true)
    if not m then return "SETUP no actor to spawn" end
    m.rank = 2
    m.energy.mod = 0
    m.energy.value = 0
    local before = ho.hostiles()
    game.zone:addEntity(game.level, m, "actor", sx, sy)
    if ho.hostiles() == before + 1 then ho.spawned = m return ("OK %s at %d,%d"):format(m.name, m.x, m.y) end
    game.level:removeEntity(m, true)
  end
  return "SETUP the spawned actor is not a visible hostile"
end
function ho.restore()
  local p = game.player
  if ho.spawned and ho.spawned.x and not ho.spawned.dead then game.level:removeEntity(ho.spawned, true) end
  ho.spawned = nil
  p:removeEffect(p.EFF_STUNNED, true, true)
  for code, st in pairs(ho.saved or {}) do b.conditions.set(code, st) end
  ho.saved = nil
  ho.reset()
  if p.x then p:playerFOV() end
  return "restored"
end
function ho.rotation()
  local out = {}
  for _, e in ipairs(b.rules.rotation()) do out[#out + 1] = type(e) == "string" and e or b.rules.module.key(e) end
  return table.concat(out, ",")
end
-- The message-log lines added since `before` (a line count), newest last,
-- colour codes stripped: only what THIS decision said, never an earlier one.
function ho.newLog(before)
  local ld = game.uiset and game.uiset.logdisplay
  if not ld or not ld.log then return "no logdisplay" end
  local n = math.min(#ld.log - before, 8)
  local out = {}
  for i = n, 1, -1 do out[#out + 1] = (tostring(ld.log[i].str):gsub("#[^#]*#", "")) end
  return table.concat(out, " | ")
end
-- One decision through query mode: the reason, the rotation the bot built,
-- whether it reads the character as impaired, and what it said.
function ho.query()
  local p = game.player
  ho.reset()
  if ho.hostiles() == 0 then return "SETUP no hostile in view" end
  b.state = 13   -- STATE_FIGHT
  local before = game.turn
  local ld = game.uiset and game.uiset.logdisplay
  local nlog = ld and ld.log and #ld.log or 0
  b.query()
  return ("QUERY dturn=%d impaired=%s rotation=%s reason=%s log=%s"):format(game.turn - before,
    tostring(b.impaired()), ho.rotation(), tostring(b.last_reason), ho.newLog(nlog))
end
-- #75: a rotation of ONE held entry, with the character impaired. The
-- rotation is then empty for the one reason the stop never used to name --
-- "none configured, or all on cooldown" was untrue on both counts. Puts the
-- two-entry rotation back before it returns, so the parts after this one
-- see what they expect.
function ho.heldOnly()
  local p = game.player
  ho.reset()
  if ho.hostiles() == 0 then return "SETUP no hostile in view" end
  local r = b.rules.get(p)
  for _, s in ipairs(b.rules.module.SECTIONS) do
    local list = r[s]
    for i = #list, 1, -1 do list[i] = nil end
  end
  b.rules.module.place(r, { tid = HELD, hold = true }, "Combat")
  b.state = 13   -- STATE_FIGHT
  local before = game.turn
  local ld = game.uiset and game.uiset.logdisplay
  local nlog = ld and ld.log and #ld.log or 0
  b.query()
  local out = ("HELDONLY dturn=%d impaired=%s rotation=[%s] reason=%s log=%s"):format(game.turn - before,
    tostring(b.impaired()), ho.rotation(), tostring(b.last_reason), ho.newLog(nlog))
  b.rules.module.place(r, { tid = PLAIN }, "Combat")
  ho.reset()
  return out
end
function ho.stun(on, dur)
  local p = game.player
  if on then p:setEffect(p.EFF_STUNNED, dur or 5, {}) else p:removeEffect(p.EFF_STUNNED, true, true) end
  ho.reset()
  return ("stunned=%s"):format(tostring(p:attr("stunned") ~= nil and p:attr("stunned") > 0))
end
-- #68: the same held rotation at several remaining durations, MEASURED
-- rather than assumed. Reports what the engine says the effect has left,
-- whether the addon reads it as lapsing, and which entry the rotation then
-- offers -- so the turn boundary is in the record and not in someone's head.
--
-- The effect is re-applied fresh for each duration, so nothing carries over;
-- no game turn passes, so `dur` is what setEffect was given.
function ho.durations()
  local p = game.player
  local out = {}
  for _, d in ipairs({ 5, 2, 1 }) do
    p:removeEffect(p.EFF_STUNNED, true, true)
    p:setEffect(p.EFF_STUNNED, d, {})
    ho.reset()
    local eff = p:hasEffect(p.EFF_STUNNED)
    -- what the addon can see about where the stun came from
    local claimed = "none"
    for _, params in pairs(p.tmp or {}) do
      if type(params) == "table" then
        for _, kv in ipairs(params.__tmpvals or {}) do
          if kv[1] == "stunned" then claimed = tostring(params.dur) end
        end
      end
    end
    out[#out + 1] = ("set=%d dur=%s attr=%s claimed=%s ending=%s rotation=[%s]"):format(
      d, tostring(eff and eff.dur), tostring(p:attr("stunned")), claimed,
      tostring(b.impairmentEnding()), ho.rotation())
  end
  p:removeEffect(p.EFF_STUNNED, true, true)
  ho.reset()
  return "DURATIONS " .. table.concat(out, " ;; ")
end
-- The "Holding ... while impaired" line is a decision detail and is emitted at
-- debug (#46); this run reads it from the log, so raise the channel for the
-- session. setLevel is session-only (the persisted LOG_LEVEL is untouched) and
-- the game is stopped at the end of the run.
ho.logLevelWas = b.log and b.log.getLevel and b.log.getLevel()
local lvl = b.log and b.log.setLevel and b.log.setLevel("debug")
return "installed level=" .. tostring(ho.logLevelWas) .. "->" .. tostring(lvl)
"@
    if ($install.Result -match '^OLD') { Inconclusive $install.Result }
    if (-not (Assert-Result $install 'helpers installed' -Match '^installed')) { Stop-Game; exit 1 }

    $setup = Probe 'return ho.setup()'
    Write-Host "  $($setup.Result)"
    if ($setup.Result -match '^SETUP') { Inconclusive $setup.Result }
    $null = Assert-Result $setup 'Combat is [held, plain] in that order, the first held and the second not' -Match "combat=$Held,$Plain hold1=true hold2=nil"

    $quiet = Probe 'return tostring(ho.findQuiet())' 120
    if ($quiet.Result -ne 'true') { Inconclusive 'no spot with nothing in sight and a free neighbour' }
    $spawn = Probe 'return ho.spawn()'
    Write-Host "  $($spawn.Result)"
    if ($spawn.Result -match '^SETUP') { Inconclusive $spawn.Result }

    # ----- 2: control -------------------------------------------------------
    Write-Host ''
    Write-Host '  --- 2. unafflicted: the FIRST entry'
    $ctrl = Probe 'return ho.query()'
    Write-Host "  $($ctrl.Result)"
    if ($ctrl.Result -match '^SETUP') { Inconclusive $ctrl.Result }
    $null = Assert-Result $ctrl 'query advances no game turn' -Match 'dturn=0 '
    $null = Assert-Result $ctrl 'the character is not impaired' -Match 'impaired=false'
    $null = Assert-Result $ctrl 'the rotation holds both entries' -Match "rotation=$Held,$Plain "
    $null = Assert-Result $ctrl 'the bot would use Rockswallow -- the first' -Match 'AI would use the talent Rockswallow'
    $null = Assert-Result $ctrl 'the bot does not stop' -Match 'reason=nil'

    # ----- 3: stunned, IGNORE ---------------------------------------------
    Write-Host ''
    Write-Host '  --- 3. stunned, DEBUFF_STUNNED at IGNORE: the SECOND entry'
    $st = Probe 'return ho.stun(true)'
    Write-Host "  $($st.Result)"
    if ($st.Result -notmatch 'stunned=true') { Inconclusive 'EFF_STUNNED did not apply (resisted/immune?)' }
    $s = Probe 'return ho.query()'
    Write-Host "  $($s.Result)"
    if ($s.Result -match '^SETUP') { Inconclusive $s.Result }
    $null = Assert-Result $s 'query advances no game turn' -Match 'dturn=0 '
    $null = Assert-Result $s 'the character reads as impaired' -Match 'impaired=true'
    $null = Assert-Result $s 'the rotation the bot built holds the plain entry alone' -Match "rotation=$Plain "
    $null = Assert-Result $s 'the bot would use Attack -- the second' -Match 'AI would use the talent Attack'
    $null = Assert-Result $s 'the bot does not stop (the stun is IGNORE)' -Match 'reason=nil'
    $log = Get-GameLogLines
    # The channel tags every level but info: "[SKOOBOT] [debug] [Combat] ..." (#46).
    $heldLines = @($log | Where-Object { $_ -match "\[SKOOBOT\] (\[debug\] )?\[Combat\] Holding tid:$Held while impaired" })
    Ok ($heldLines.Count -gt 0) 'the log says the held entry was held' "$($heldLines.Count) line(s)"

    # ----- 3b: the whole rotation held (#75) -------------------------------
    Write-Host ''
    Write-Host '  --- 3b. every Combat entry held: the stop says so'
    $ho = Probe 'return ho.heldOnly()'
    Write-Host "  $($ho.Result)"
    if ($ho.Result -match '^SETUP') { Inconclusive $ho.Result }
    $null = Assert-Result $ho 'query advances no game turn' -Match 'dturn=0 '
    $null = Assert-Result $ho 'the character reads as impaired' -Match 'impaired=true'
    $null = Assert-Result $ho 'the rotation the bot built is empty' -Match 'rotation=\[\] '
    $null = Assert-Result $ho 'the bot hands back' -Match 'reason=Cannot act: no Combat talent is ready'
    $null = Assert-Result $ho 'and says holding is why, not "none configured, or all on cooldown"' -Match 'every one is held while impaired \(1\)'
    Ok ($ho.Result -notmatch 'none configured, or all on cooldown') 'the old wording, which was untrue on both counts, is gone' $ho.Result
    # The loadout hint belongs to an EMPTY rotation, not a held one: pointing
    # a player with talents configured at the suggestion is noise (#18, #75).
    Ok ($ho.Result -notmatch 'suggest a loadout') 'the "configure something" hint is not offered to a player who has' $ho.Result

    # ----- 3c: the last turn of the stun (#68) -----------------------------
    Write-Host ''
    Write-Host '  --- 3c. an impairment about to lapse does not hold'
    $du = Probe 'return ho.durations()'
    Write-Host "  $($du.Result)"
    if ($du.Result -match '^SETUP') { Inconclusive $du.Result }
    foreach ($seg in ($du.Result -replace '^DURATIONS ', '') -split ' ;; ') { Note "duration: $seg" }
    $null = Assert-Result $du 'a stun with turns left still holds the entry' -Match ('set=5 [^;]*ending=false rotation=\[' + $Plain + '\]')
    $null = Assert-Result $du '...and at two turns as well' -Match ('set=2 [^;]*ending=false rotation=\[' + $Plain + '\]')
    $null = Assert-Result $du 'a stun on its last turn does NOT hold: the held entry is offered first' -Match ('set=1 [^;]*ending=true rotation=\[' + $Held + ',' + $Plain + '\]')
    # The addon learns the duration from __tmpvals, which is how it avoids
    # naming effect ids: if the engine stopped recording the link, `claimed`
    # would read "none", the impairment would be unaccounted for, and the
    # entry would keep holding -- the safe direction, but a silent loss of
    # the refinement. This is where that shows.
    Ok ($du.Result -notmatch 'claimed=none') 'the stun is traceable to a live effect through __tmpvals' $du.Result

    # ----- 4: stunned, STOP -----------------------------------------------
    Write-Host ''
    Write-Host '  --- 4. the same stun with DEBUFF_STUNNED at STOP: the stop comes first'
    $null = Probe 'skoobot_reclauded.conditions.set("DEBUFF_STUNNED", "STOP") return "set"'
    $stop = Probe 'return ho.query()'
    Write-Host "  $($stop.Result)"
    $null = Assert-Result $stop 'the bot hands back for the stun before the rotation runs' -Match 'reason=[^|]*stunned'
    $null = Assert-Result $stop 'no talent is named' -Match '^(?!.*AI would use the talent)'
    $null = Probe 'skoobot_reclauded.conditions.set("DEBUFF_STUNNED", "IGNORE") return "set"'

    # ----- 5: the stun gone -------------------------------------------------
    Write-Host ''
    Write-Host '  --- 5. the stun removed: the FIRST entry again'
    $off = Probe 'return ho.stun(false)'
    Write-Host "  $($off.Result)"
    $null = Assert-Result $off 'the stun is gone' -Match 'stunned=false'
    $back = Probe 'return ho.query()'
    Write-Host "  $($back.Result)"
    $null = Assert-Result $back 'the character is not impaired' -Match 'impaired=false'
    $null = Assert-Result $back 'the rotation holds both entries again' -Match "rotation=$Held,$Plain "
    $null = Assert-Result $back 'the bot would use Rockswallow -- the first' -Match 'AI would use the talent Rockswallow'

    # ----- 6: the talent screen ---------------------------------------------
    Write-Host ''
    Write-Host '  --- 6. the talent screen shows and toggles the flag'
    $screen = Probe @"
local ok, res = pcall(function()
  local p, b = game.player, skoobot_reclauded
  local rm = b.rules.module
  ho.reset()
  local r = b.rules.get(p)
  bridge.key("MENU_SKOOBOT_RECLAUDED")
  local m = game.dialogs[#game.dialogs]
  if not m or tostring(m.title) ~= "SkooBot: Reclauded" then return "ERR menu not on top" end
  m:use(m.list[1])
  local d = game.dialogs[#game.dialogs]
  if not d or not d.c_list then return "ERR talent screen not on top" end
  local function row(tid, section)
    for _, it in ipairs(d.c_list.list) do
      if it.entry and it.entry.tid == tid and it.section == section then return it end
    end
  end
  local function press(sym)
    local Key = require "engine.Key"
    local h = Key.current
    bridge.injecting = true
    local okk, err = pcall(h.receiveKey, h, Key[sym], false, false, false, false, nil, false, sym)
    bridge.injecting = false
    if not okk then error(err) end
  end
  local out = {}
  local held = assert(row("$Held", "Combat"), "no Combat row for the held talent")
  out[#out + 1] = ("shown=%s kind=[%s] prose=%s"):format(tostring(held.held), tostring(held.kind),
    tostring(tostring(held.desc):find("Holding while impaired", 1, true) ~= nil))
  d:selectItem(held)
  press("_SPACE")
  out[#out + 1] = ("cleared=%s kind=[%s]"):format(tostring(r.Combat[1].hold), tostring(row("$Held", "Combat").kind))
  press("_SPACE")
  out[#out + 1] = ("set=%s"):format(tostring(r.Combat[1].hold))
  -- Space on an Available row: refused, nothing changes
  d:selectItem(assert(row("$Plain", nil), "no Available row for the plain talent"))
  press("_SPACE")
  out[#out + 1] = ("avail_refused=%s plain_hold=%s"):format(tostring(d.c_desc.cur_item == d.status_key), tostring(r.Combat[2].hold))
  -- the action menu on the held Combat row offers the toggle
  d:use(row("$Held", "Combat"), "left")
  local menu = game.dialogs[#game.dialogs]
  local names, cancel = {}, nil
  for _, it in ipairs(menu and menu.list or {}) do
    names[#names + 1] = tostring(it.name)
    if tostring(it.name):find("Cancel", 1, true) then cancel = it end
  end
  if cancel then menu:use(cancel) end
  out[#out + 1] = "menu=" .. table.concat(names, "|")
  -- "Also add to Recovery": its own table, no flag
  d:place(r.Combat[1], "Recovery")
  out[#out + 1] = ("recovery_hold=%s own_table=%s combat_hold=%s"):format(tostring(r.Recovery[1] and r.Recovery[1].hold),
    tostring(r.Recovery[1] ~= r.Combat[1]), tostring(r.Combat[1].hold))
  while #game.dialogs > 0 do game:unregisterDialog(game.dialogs[#game.dialogs]) end
  return table.concat(out, " ")
end)
return ok and res or ("ERR " .. tostring(res))
"@
    Write-Host "  $($screen.Result)"
    $null = Assert-Result $screen 'the Combat row shows the flag in its Kind column and the pane carries the prose' -Match 'shown=true kind=\[[^\]]*, held\] prose=true'
    $null = Assert-Result $screen 'Space clears the flag and the row no longer says held' -Match 'cleared=nil kind=\[[^\]]*\]'
    $null = Assert-Result $screen 'Space sets it again' -Match 'set=true'
    $null = Assert-Result $screen 'Space on an Available row is refused and changes nothing' -Match 'avail_refused=true plain_hold=nil'
    $null = Assert-Result $screen 'the action menu offers the toggle on a Combat row' -Match 'Stop holding while impaired \(Space\)'
    $null = Assert-Result $screen '"Also add to Recovery" gives Recovery its own table without the flag' -Match 'recovery_hold=nil own_table=true combat_hold=true'
    if ($screen.Result -match 'cleared=nil kind=\[([^\]]*)\]') { Ok ($Matches[1] -notmatch 'held') 'after clearing, the Kind column no longer reads held' $Matches[1] }

    $null = Probe 'return ho.restore()'
}
finally {
    Stop-Game
}

Start-Sleep -Seconds 1
$errs = @((Get-Content $script:LogPath -Raw -ErrorAction Ignore) -split "`r?`n" | Where-Object { $_ -match 'Lua Error' })
Ok ($errs.Count -eq 0) 'no Lua Error in the run'
foreach ($e in ($errs | Select-Object -First 3)) { Write-Host "         $e" }

Write-Host ''
if ($script:HarnessTainted) { Write-Host '[hold] TAINTED - void, re-run.'; exit 2 }
if ($script:HarnessFailures.Count -gt 0) {
    Write-Host "[hold] FAILED - $($script:HarnessFailures.Count) check(s):"
    foreach ($f in $script:HarnessFailures) { Write-Host "                 $f" }
    exit 1
}
Write-Host '[hold] PASS - a held entry waits out the impairment and the rotation falls through'
exit 0
