<#
    #14: the superload surface, in the game.

    spec/surface_spec.lua holds the source to its shape: one superload file,
    ONE one-line wrapper, nothing added to either class, the tooltip line
    bound as a hook. What only a running game can show is that the engine
    sees the same thing and the behaviour is unchanged through the new
    plumbing:

      1. the surface the engine loaded: mod.class.Player's act is this
         addon's wrapper (by its source file) and the ONLY function this
         addon put on either class; postUseTalent is NOT ours any more (#76)
         and still resolves through the class chain; Actor:tooltip is
         not this addon's; loadPrevious handed each superload the class it
         names (_NAME, api-surface Remediation 8); none of the six
         names the original leaked (reduce, recSum, aiStop, skoobot_act,
         checkForAdditionalAction, getUnspentTotal) is in _G;
      2. the tooltip: every creature's tooltip still carries one "Power
         Level: N" line, N the figure skoobot_reclauded.power() gives for it,
         now sitting after the stats block where the hook fires rather than
         at the very end -- checked on the player and on another actor of
         the level;
      3. the refusal without a wrapper (#76): useTalent reports a talent
         whose own action returned nil -- the case no hook can see, since
         Actor:postUseTalent fires only after `if not ret then return end` --
         as boolean FALSE, and a talent suspended awaiting its own targeting
         as NIL. That difference is the fact SAI_useTalent now reads in place
         of the wrapper, and why it tests `== false` and not falsiness. The
         bot ACTING on it is scenario-t010-marked-target's job;
      4. act: with the bot toggled on, the per-turn driver runs from
         Player:act -- its trace line is printed -- game.turn advances and
         actions are taken.

    Exit codes:  0 pass   1 fail   2 tainted   3 inconclusive (no quiet spot
    or no second actor to read -- setup, never a product failure)

    Run:
        powershell -ExecutionPolicy Bypass -File .\tools\scenario-hooks.ps1

    #14.
#>
[CmdletBinding()]
param(
    [string]$SaveName = 'fixture-berserker',
    # Game turns the toggled bot must advance (10 per player turn at normal
    # speed), and how long it gets, restarted after each legitimate stop.
    [int]$TargetTurns = 100,
    [int]$DeadlineSec = 120,
    [int]$MaxRestarts = 8
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'harness.ps1')

$RepoRoot = Split-Path -Parent $PSScriptRoot

Write-Host ''
Write-Host '[hooks] the superload surface (#14)'

function Inconclusive($why) {
    Write-Host "[hooks] INCONCLUSIVE - $why"
    Stop-Game
    exit 3
}

# ---------------------------------------------------------------------------
# The tree, before the game: what would be packed.
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '  --- the superload tree'
$files = @(Get-ChildItem (Join-Path $RepoRoot 'src\superload') -Recurse -File | ForEach-Object {
    $_.FullName.Substring((Join-Path $RepoRoot 'src\superload\').Length) -replace '\\', '/' })
$treeResult = [pscustomobject]@{ Status = 'OK'; Result = ($files -join ','); Tainted = $false }
$null = Assert-Result $treeResult 'src/superload holds exactly one file, mod/class/Player.lua' -Match '^mod/class/Player\.lua$'

try {
    $g = Load-Save -Name $SaveName
    if (-not $g.Ready) { Write-Host "[hooks] FAILED - could not load '$SaveName' ($($g.Reason))"; exit 1 }
    $null = Assert-Result ([pscustomobject]@{ Status = 'OK'; Result = $g.Addons; Tainted = $false }) 'the product is loaded' -Match 'skoobot_reclauded'

    $install = Invoke-Bridge -Lua @'
_G.hk = {}
local b = rawget(_G, "skoobot_reclauded")
if not b then return "ERR no skoobot_reclauded runtime table" end
if not b.tooltip then return "OLD no skoobot_reclauded.tooltip (#14)" end

hk.OURS = "/skoobot_reclauded/superload/mod/class/Player.lua"

function hk.source(f)
  if type(f) ~= "function" then return "none" end
  local info = debug.getinfo(f, "S")
  return info and tostring(info.source) or "?"
end
-- Every function on a class table that this addon's superload defined.
function hk.oursOn(C)
  local out = {}
  for k, v in pairs(C) do
    if type(v) == "function" and hk.source(v):find(hk.OURS, 1, true) then out[#out + 1] = tostring(k) end
  end
  table.sort(out)
  return table.concat(out, ",")
end

function hk.plain(s)
  if type(s) == "table" and s.toString then s = s:toString() end
  return (tostring(s):gsub("#[^#]*#", ""))
end
-- The Power Level lines of an actor's tooltip: how many, the first figure,
-- and whether the first sits after the stats block (after "M. save").
function hk.tooltip(a, seen_by)
  local ts = a:tooltip(a.x, a.y, seen_by)
  if not ts then return "none" end
  local s = hk.plain(ts)
  local n = select(2, s:gsub("Power Level: ", ""))
  local at, _, figure = s:find("Power Level: (%-?%d+)")
  local msave = s:find("M. save", 1, true)
  return ("lines=%d figure=%s expected=%s after_stats=%s"):format(n, tostring(figure),
    string.format("%d", b.power(a)), tostring(at ~= nil and msave ~= nil and at > msave))
end
-- Some other actor of the level, for the tooltip: the nearest to the
-- player, whatever its reaction. Its tooltip is computed directly, so it
-- need not be in view.
function hk.other()
  local p = game.player
  local best, bestd
  for _, e in pairs(game.level.entities) do
    if e ~= p and e.__is_actor and e.x and e.y and not e.dead then
      local d = core.fov.distance(p.x, p.y, e.x, e.y)
      if not best or d < bestd then best, bestd = e, d end
    end
  end
  return best
end

function hk.hostiles()
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
function hk.onChangeLevel()
  local p = game.player
  return game.level.map:checkEntity(p.x, p.y, engine.Map.TERRAIN, "change_level") ~= nil
end
function hk.quietHere()
  return hk.hostiles() == 0 and not hk.onChangeLevel()
end
function hk.findQuiet()
  local p = game.player
  for i = 1, 80 do
    if hk.quietHere() then return true end
    p:teleportRandom(p.x, p.y, 60, 10)
  end
  return hk.quietHere()
end
function hk.reset()
  while #game.dialogs > 0 do game:unregisterDialog(game.dialogs[#game.dialogs]) end
  if b.active then b.stop("test reset") end
  local p = game.player
  if p.resting then p:restStop() end
  if p.running then p:runStop() end
  b.state = 10   -- STATE_REST
  b.activation = nil; b.loop = nil; b.prevloop = nil
  b.last_reason = nil
end

-- The print log since a mark: the bot's lines, and how many were the
-- per-turn driver's iteration trace.
function hk.mark() return #get_printlog() end
function hk.since(mark)
  local log = get_printlog()
  local out = { all = 0, iterations = 0, actions = 0 }
  for i = mark + 1, #log do
    local s = tostring(log[i][1] or "")
    if s:find("^%[SKOOBOT%]") then
      out.all = out.all + 1
      if s:find("^%[SKOOBOT%] %[trace%] %[PlayerActions%] iteration ") then out.iterations = out.iterations + 1 end
      if s:find("^%[SKOOBOT%] %[Action%] ") then out.actions = out.actions + 1 end
    end
  end
  return out
end

-- The rules a player would have set (tools/scenario-liveness.ps1's
-- lv.rules): what the character can fire, the innate Attack last,
-- sustains kept up, targetless inscriptions as recovery and prevention.
function hk.rules()
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
-- The top dialog, through its own EXIT bind, else ACCEPT; never the death
-- dialog.
function hk.closeDialog()
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
  game:unregisterDialog(d)
  return "unregistered"
end
function hk.status()
  local d = game.dialogs and game.dialogs[#game.dialogs]
  return b.inspect() .. " dead=" .. tostring(game.player.dead and true or false)
    .. " dialog=" .. (d and (tostring(d.__CLASSNAME or "?")) or "none")
end
return "installed"
'@ -TimeoutSec 30
    if ($install.Result -match '^OLD') { Inconclusive $install.Result }
    if (-not (Assert-Result $install 'helpers installed' -Match '^installed')) { Stop-Game; exit 1 }

    # -----------------------------------------------------------------------
    # 1. the surface the engine loaded
    # -----------------------------------------------------------------------
    Write-Host ''
    Write-Host '  --- 1. the surface the engine loaded'
    $surface = Invoke-Bridge -Lua @'
local P = require "mod.class.Player"
local A = require "mod.class.Actor"
local leaked = {}
for _, name in ipairs{"reduce", "recSum", "aiStop", "skoobot_act", "checkForAdditionalAction", "getUnspentTotal"} do
  if rawget(_G, name) ~= nil then leaked[#leaked + 1] = name end
end
return ("player=%s actor=%s | act=%s postUseTalent_ours=%s postUseTalent_resolves=%s | ours_on_player=[%s] ours_on_actor=[%s] | actor_tooltip=%s player_tooltip=%s | leaked=[%s] runtime=%s"):format(
  tostring(P._NAME), tostring(A._NAME),
  tostring(hk.source(rawget(P, "act")):find(hk.OURS, 1, true) ~= nil),
  tostring(hk.source(rawget(P, "postUseTalent")):find(hk.OURS, 1, true) ~= nil),
  tostring(type(P.postUseTalent) == "function"),
  hk.oursOn(P), hk.oursOn(A),
  hk.source(rawget(A, "tooltip")), hk.source(rawget(P, "tooltip")),
  table.concat(leaked, ","), type(rawget(_G, "skoobot_reclauded")))
'@ -TimeoutSec 30
    Write-Host "  $($surface.Result)"
    $null = Assert-Result $surface "the engine's Player:act is this addon's wrapper" -Match '\| act=true '
    $null = Assert-Result $surface "Player:postUseTalent is NOT (the wrapper went with #76)" -Match ' postUseTalent_ours=false '
    $null = Assert-Result $surface 'and still resolves through the class chain, so nothing was broken taking it off' -Match ' postUseTalent_resolves=true \|'
    # act and runStopped, and nothing else. This is the RUNTIME half of the
    # superload-surface guard -- spec/surface_spec.lua is the source half, and
    # growing the list is a decision made in both places or in neither.
    # runStopped was added for #153: the engine's runCheck reads a seens map
    # that accumulates over a run, runStopped's own body is what cleans it, and
    # the disagreement that live-locks the bot (#164) only exists as the
    # difference between the same call either side of it. No hook exists --
    # the only triggerHook in mod/class/Player.lua is
    # Player:onEnterLevel:generateEscort -- so api-surface-1.7.6.md's rule
    # applies: keep the wrapper, say why, one delegating line. It is inert
    # unless bot.active.
    $null = Assert-Result $surface 'act and runStopped are the only functions this addon put on mod.class.Player' -Match 'ours_on_player=\[act,runStopped\]'
    $null = Assert-Result $surface 'and none on mod.class.Actor' -Match 'ours_on_actor=\[\]'
    $null = Assert-Result $surface "Actor:tooltip is not this addon's (the line is a hook)" -Match 'actor_tooltip=(?![^ ]*skoobot_reclauded)[^ ]+ '
    $null = Assert-Result $surface "nor is Player:tooltip" -Match 'player_tooltip=(?![^ ]*skoobot_reclauded)[^ ]+ '
    $null = Assert-Result $surface 'none of the six names the original leaked is in _G, and the runtime table is' -Match 'leaked=\[\] runtime=table$'

    # -----------------------------------------------------------------------
    # 2. the tooltip
    # -----------------------------------------------------------------------
    Write-Host ''
    Write-Host '  --- 2. the tooltip'
    $v1 = Invoke-Bridge -Lua 'return tostring(require("mod.class.Player").skoobot_start ~= nil)' -TimeoutSec 30
    $expectLines = if ($v1.Result -eq 'true') { 2 } else { 1 }
    if ($expectLines -eq 2) { Write-Host '  INFO  the original SkooBot is installed too: two Power Level lines are expected' }
    $tp = Invoke-Bridge -Lua 'local p = game.player return hk.tooltip(p, p)' -TimeoutSec 30
    Write-Host "  player: $($tp.Result)"
    $null = Assert-Result $tp "the player's tooltip carries the Power Level line ($expectLines)" -Match "^lines=$expectLines "
    $null = Assert-Result $tp 'with the figure skoobot_reclauded.power() gives' -Match 'figure=(-?\d+) expected=\1 '
    $null = Assert-Result $tp 'after the stats block, where the hook fires' -Match 'after_stats=true$'
    $to = Invoke-Bridge -Lua @'
local a = hk.other()
if not a then return "SETUP no other actor on the level" end
return ("[%s] %s"):format(tostring(a.name), hk.tooltip(a, nil))
'@ -TimeoutSec 30
    Write-Host "  other:  $($to.Result)"
    if ($to.Result -match '^SETUP') { Inconclusive $to.Result }
    $null = Assert-Result $to "another actor's tooltip carries it too ($expectLines)" -Match "\] lines=$expectLines "
    $null = Assert-Result $to 'with its own figure' -Match 'figure=(-?\d+) expected=\1 '

    # -----------------------------------------------------------------------
    # 3. the refusal, without a wrapper
    # -----------------------------------------------------------------------
    Write-Host ''
    Write-Host '  --- 3. useTalent tells a refusal from a pending talent, so no wrapper is needed'
    $quiet = Invoke-Bridge -Lua 'hk.reset() return tostring(hk.findQuiet())' -TimeoutSec 120
    if ($quiet.Result -ne 'True') { Inconclusive 'no spot with nothing in sight to decide from' }
    $put = Invoke-Bridge -Lua @'
local p = game.player
local T = require "engine.interface.ActorTalents"
hk.reset()
local t = p:getTalentFromId("T_ATTACK")

-- (a) THE case no hook can see: the talent's own action refuses, so
-- postUseTalent returns nil (mod/class/Actor.lua: `if not ret then return
-- end`) and useTalent returns FALSE at engine/interface/ActorTalents.lua:197.
-- This is the fact SAI_useTalent reads in place of the retired wrapper.
-- Reproduced by stubbing the action for exactly one call -- a measurement
-- may do that; the product may not -- and putting it straight back.
local def = T.talents_def[t.id]
local realAction = def.action
def.action = function() return nil end
local okR, refused = pcall(p.useTalent, p, t.id, nil, nil, true, nil, true, true)
def.action = realAction

-- (b) and the case that must NOT be read as a refusal: no forced target, so
-- the real Attack opens targeting and its coroutine SUSPENDS. useTalent
-- returns nil while it waits. A talent that may yet fire must not be marked
-- failed, which is exactly why SAI_useTalent tests `== false` rather than
-- falsiness (api-surface Remediation 3).
local dlg0 = #game.dialogs
local okP, pending = pcall(p.useTalent, p, t.id, nil, nil, true, nil, true, true)
local grew = #game.dialogs - dlg0
local targeting = game.target and game.target.target_type ~= nil

hk.reset()
return ("refused_ok=%s refused=%s(%s) | pending_ok=%s pending=%s(%s) dlg_grew=%d targeting=%s | action_restored=%s dialogs_after=%d"):format(
  tostring(okR), tostring(refused), type(refused),
  tostring(okP), tostring(pending), type(pending), grew, tostring(targeting),
  tostring(def.action == realAction), #game.dialogs)
'@ -TimeoutSec 60
    Write-Host "  $($put.Result)"
    $null = Assert-Result $put "a talent whose own action refuses does not raise" -Match '^refused_ok=true '
    $null = Assert-Result $put '...and is reported as boolean FALSE -- the case no hook can see' -Match ' refused=false\(boolean\) '
    $null = Assert-Result $put 'a talent left to open its own targeting does not raise either' -Match ' pending_ok=true '
    $null = Assert-Result $put '...and is reported as NIL, not false: it is suspended, not refused' -Match ' pending=nil\(nil\) '
    $null = Assert-Result $put 'the stubbed action was put back' -Match ' action_restored=true '
    $null = Assert-Result $put 'and the probe left no dialog behind' -Match ' dialogs_after=0$'
    # false and nil being genuinely different returns is the whole reason
    # SAI_useTalent tests `ret == false` and not `not ret`. If the engine
    # ever collapsed them, the bot would start marking pending talents as
    # failed, and this is the pair of checks that would catch it.
    #
    # What this does NOT show is the bot acting on the refusal: that a
    # refused talent is skipped and the next priority tried inside one
    # iteration is scenario-t010-marked-target, with a real marked-target
    # talent.

    # -----------------------------------------------------------------------
    # 4. act: the driver runs from Player:act
    # -----------------------------------------------------------------------
    Write-Host ''
    Write-Host "  --- 4. act: toggled on, the driver runs from Player:act and $TargetTurns+ game turns pass"
    $rules = Invoke-Bridge -Lua 'return hk.rules()' -TimeoutSec 30
    Write-Host "  rules: $($rules.Result)"
    $null = Assert-Result $rules 'the fixture has Combat rules for the run' -Match 'combat=[1-9]'
    $quiet2 = Invoke-Bridge -Lua 'hk.reset() return tostring(hk.findQuiet())' -TimeoutSec 120
    if ($quiet2.Result -ne 'True') { Inconclusive 'no quiet spot to start from' }

    $startTurn = Get-GameTurn
    $s = Invoke-Bridge -Lua @'
local b = skoobot_reclauded
hk.reset()
b.log.setLevel("trace")
hk.m0 = hk.mark()
b.start()
return "started active=" .. tostring(b.active) .. " reason=" .. tostring(b.last_reason)
'@ -TimeoutSec 60
    Write-Host "  $($s.Result)"
    $deadline = (Get-Date).AddSeconds($DeadlineSec)
    $restarts = 0
    $endedWhy = 'deadline'
    $last = ''
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 3
        $st = Invoke-Bridge -Lua 'return hk.status()' -TimeoutSec 30
        if ($st.Tainted) { $script:HarnessTainted = $true }
        $last = "$($st.Result)"
        if ($st.Status -ne 'OK') { $endedWhy = "status $($st.Status)"; break }
        $turn = -1
        if ($last -match 'turn=(\d+)') { $turn = [int]$Matches[1] }
        if ($last -match 'dead=true') { $endedWhy = 'dead'; break }
        if ($turn - $startTurn -ge $TargetTurns) { $endedWhy = 'target reached'; break }
        if ($last -match 'active=false') {
            if ($restarts -ge $MaxRestarts) { $endedWhy = 'restart budget'; break }
            $restarts++
            $r = Invoke-Bridge -Lua @'
local b = skoobot_reclauded
local closed = hk.closeDialog()
if closed == "death" then return "dead" end
if game.player.resting then game.player:restStop() end
if game.player.running then game.player:runStop() end
if not b.active then b.start() end
return ("restart closed=%s active=%s reason=%s"):format(closed, tostring(b.active), tostring(b.last_reason))
'@ -TimeoutSec 60
            Write-Host "  $($r.Result)"
            if ($r.Result -eq 'dead') { $endedWhy = 'dead'; break }
        }
    }
    Write-Host "  ended: $endedWhy after $restarts restart(s); $last"
    $end = Invoke-Bridge -Lua @'
local b = skoobot_reclauded
local c = hk.since(hk.m0 or 0)
if b.active then b.stop("measured") end
local p = game.player
if p.resting then p:restStop() end
if p.running then p:runStop() end
b.log.setLevel("info")
return ("turn=%d iterations=%d actions=%d actionlines=%d"):format(game.turn, c.iterations, b.actions, c.actions)
'@ -TimeoutSec 60
    Write-Host "  $($end.Result)"
    $endTurn = if ($end.Result -match '^turn=(\d+)') { [int]$Matches[1] } else { -1 }
    $advanced = $endTurn - $startTurn
    if ($endedWhy -eq 'dead') { Inconclusive "the fixture died during the run; nothing about the act wrapper was measured ($last)" }
    $adv = [pscustomobject]@{ Status = $end.Status; Result = "advanced=$advanced enough=$($advanced -ge $TargetTurns)"; Tainted = $end.Tainted }
    $null = Assert-Result $adv "game.turn advanced at least $TargetTurns under the toggle ($startTurn -> $endTurn)" -Match ' enough=True$'
    $null = Assert-Result $end 'the per-turn driver ran from Player:act (its iteration trace was printed)' -Match ' iterations=[1-9]\d* '
    $null = Assert-Result $end 'and the bot took actions' -Match ' actionlines=[1-9]\d*$'
}
finally {
    Stop-Game
}

Write-Host ''
Write-Host '  --- engine log'
$lines = Get-GameLogLines
$errs = @($lines | Where-Object { $_ -match 'Lua Error' })
$errResult = [pscustomobject]@{ Status = 'OK'; Result = "lua_errors=$($errs.Count)"; Tainted = $false }
$null = Assert-Result $errResult 'no Lua Error in the run' -Match '^lua_errors=0$'
foreach ($e in ($errs | Select-Object -First 5)) { Write-Host "         $e" }

Write-Host ''
if ($script:HarnessTainted) { Write-Host '[hooks] TAINTED - void, re-run.'; exit 2 }
if ($script:HarnessFailures.Count -gt 0) {
    Write-Host "[hooks] FAILED - $($script:HarnessFailures.Count) check(s):"
    foreach ($f in $script:HarnessFailures) { Write-Host "                 $f" }
    exit 1
}
Write-Host '[hooks] PASS - one superload file, two one-line wrappers, the tooltip line a hook, and the bot still rests, explores and fights through them'
exit 0
