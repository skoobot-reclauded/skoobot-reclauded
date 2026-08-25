<#
    Taking the stairs (#86): the three TAKE_STAIRS settings, on a real
    staircase.

    #121 measured that the engine's own auto-explore already walks the
    character to the down stairs once a level is finished, and prefers them.
    So this issue was never a routing feature -- it is a dialog, a setting and
    a branch in a hand-back that was already firing there. This drives that
    branch.

    HOW THE DECISION IS STAGED, and why it is not staged the obvious way. The
    branch is exempt on the tile the activation started on (#62), so a probe
    has to make its decision from an activation that began somewhere else.
    `start()` cannot do it: it always builds a fresh activation at the tile the
    player is on. Leaving the bot running does not work either -- an explore run
    puts up the engine's "Running..." dialog, and the next decision hands back
    on that rather than on the stairs. `query()` is the one entry point that
    honours an existing unmarked activation (#65), so the activation is built
    beside the stairs, the bot is stopped, the character stands on them, and
    the question is asked.

    That covers WHICH branch is taken and what it says. Query mode deliberately
    does not open the offer (#96's rule: Ask answers a question, it does not
    open things) and does not descend, so the dialog and the descent are driven
    directly afterwards. What is therefore NOT covered here is the descent
    happening from inside a live act loop; see the issue.

    Everything hostile is put on the player's faction for the run and restored
    afterwards, or the decision goes to FIGHT and the explore branch is never
    reached (#124's remedy for the same problem).

    What is driven, on the fixture:
      A. a real level change on the level, and a free grid beside it;
      B. never: the old behaviour exactly -- "standing on a level change";
      C. ask: the same hand-back, and query mode still opens nothing;
     C2. the offer dialog itself: four buttons, and Escape is "not now";
      D. the offer's "never" button writes the setting, so it self-silences;
      E. always: query mode says it would take them, naming what;
     E2. and the descent -- the game's own CHANGE_LEVEL -- really changes level.

    The setting is put back at the end. The save is never written.

    Exit codes:  0 pass   1 fail   2 tainted   3 inconclusive (no level change
    on this level, no free grid beside it -- setup, never product)

    Run:
        powershell -ExecutionPolicy Bypass -File .\tools\scenario-stairs.ps1

    #86, #121, #103, #62, #65.
#>
[CmdletBinding()]
param(
    [string]$SaveName = 'fixture-berserker'
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'harness.ps1')

Write-Host ''
Write-Host '[stairs] the bot offers to take the stairs, and takes them when told to (#86)'

function Inconclusive($why) {
    Write-Host "[stairs] INCONCLUSIVE - $why"
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
    if (-not $g.Ready) { Write-Host "[stairs] FAILED - could not load '$SaveName' ($($g.Reason))"; exit 1 }
    $null = Assert-Result ([pscustomobject]@{ Status = 'OK'; Result = $g.Addons; Tainted = $false }) 'the product is loaded' -Match 'skoobot_reclauded'

    $install = Probe @'
_G.st = {}
local b = rawget(_G, "skoobot_reclauded")
if not b then return "ERR no skoobot_reclauded runtime table" end
st.b = b
st.saved = select(2, b.settingSource("TAKE_STAIRS"))
if st.saved == nil then return "ERR TAKE_STAIRS is not a setting" end

function st.findStairs()
  local map = game.level.map
  for x = 0, map.w - 1 do
    for y = 0, map.h - 1 do
      local grid = map(x, y, engine.Map.TERRAIN)
      if grid and grid.change_level then return x, y, tostring(grid.name), grid.change_zone and true or false end
    end
  end
  return nil
end
function st.pacify()
  local p = game.player
  st.pacified = {}
  for _, e in pairs(game.level.entities or {}) do
    if e ~= p and e.faction and e.x and p.reactionToward and p:reactionToward(e) < 0 then
      st.pacified[#st.pacified + 1] = { e, e.faction }
      e.faction = p.faction
    end
  end
  if p.x then p:playerFOV() end
  return #st.pacified
end
function st.unpacify()
  for _, f in ipairs(st.pacified or {}) do f[1].faction = f[2] end
  local ok = true
  for _, f in ipairs(st.pacified or {}) do if f[1].faction ~= f[2] then ok = false end end
  st.pacified = nil
  if game.player.x then game.player:playerFOV() end
  return ok
end
function st.reset()
  while #game.dialogs > 0 do game:unregisterDialog(game.dialogs[#game.dialogs]) end
  if st.b.active then st.b.stop("test reset") end
  st.b.active = false; st.b.do_nothing = false; st.b.last_reason = nil
  st.b.activation = nil; st.b.loop = nil; st.b.prevloop = nil
  game.player.life = game.player.max_life
  return "reset"
end
function st.setting()
  return tostring(select(2, st.b.settingSource("TAKE_STAIRS")))
end
-- One decision on the stairs, from an activation that began beside them.
function st.decide(mode)
  st.reset()
  st.b.setSetting("TAKE_STAIRS", mode)
  local p = game.player
  p:move(st.offx, st.offy, true)
  st.b.state = 11
  st.b.start()
  -- Put `active` down by hand rather than calling stop(): stop clears the
  -- activation, and the activation -- with its start tile beside the stairs --
  -- is the whole point of this staging.
  st.b.active = false; st.b.last_reason = nil
  local act = st.b.activation
  if not act then return "SETUP the staging start left no activation" end
  act.left_start = true          -- we have stood somewhere else, and we have
  while #game.dialogs > 0 do game:unregisterDialog(game.dialogs[#game.dialogs]) end
  p:move(st.sx, st.sy, true)
  local dialogs0 = #game.dialogs
  local lev0 = tostring(game.level and game.level.level)
  st.b.query()
  return ("start=%d,%d on=%d,%d dialogs=%d->%d level=%s->%s setting=%s reason=%s"):format(
    act.start_x, act.start_y, p.x, p.y, dialogs0, #game.dialogs,
    lev0, tostring(game.level and game.level.level), st.setting(), tostring(st.b.last_reason))
end
return "installed"
'@ 30
    if (-not (Assert-Result $install 'helpers installed' -Match '^installed')) { Stop-Game; exit 1 }

    # ----- A: a real staircase ----------------------------------------------
    Write-Host ''
    Write-Host '  --- A. a real level change on this level, and a grid beside it'
    $find = Probe @'
local x, y, name, zoneExit = st.findStairs()
if not x then return "SETUP no change_level grid on this level" end
st.sx, st.sy = x, y
for _, c in pairs(util.adjacentCoords(x, y)) do
  local ax, ay = c[1], c[2]
  if game.level.map:isBound(ax, ay) and not game.level.map:checkAllEntities(ax, ay, "block_move")
     and not game.level.map(ax, ay, engine.Map.ACTOR) then st.offx, st.offy = ax, ay break end
end
if not st.offx then return "SETUP no free grid beside the level change" end
local n = st.pacify()
return ("OK stairs=%d,%d name=%s zoneexit=%s off=%d,%d pacified=%d"):format(
  x, y, name, tostring(zoneExit), st.offx, st.offy, n)
'@ 120
    Write-Host "  $($find.Result)"
    if ($find.Result -match '^SETUP') { Inconclusive $find.Result }
    $null = Assert-Result $find 'a level change was found and a grid beside it' -Match ' stairs=\d+,\d+ '

    # ----- B: never ---------------------------------------------------------
    Write-Host ''
    Write-Host '  --- B. never: exactly the old behaviour'
    $never = Probe 'return st.decide(2)' 120
    Write-Host "  $($never.Result)"
    if ($never.Result -match '^SETUP') { Inconclusive $never.Result }
    $null = Assert-Result $never 'the decision was made on the stairs, from an activation started elsewhere' -Match 'start=(\d+),(\d+) on=(?!\1,\2)'
    $null = Assert-Result $never 'it hands back with the message it has always used' -Match 'standing on a level change'
    $null = Assert-Result $never 'and does not mention asking' -Match '^(?!.*asked whether)'
    $null = Assert-Result $never 'no offer was opened' -Match 'dialogs=0->0'

    # ----- C: ask -----------------------------------------------------------
    Write-Host ''
    Write-Host '  --- C. ask: the branch is reached, and query mode still opens nothing'
    $ask = Probe 'return st.decide(0)' 120
    Write-Host "  $($ask.Result)"
    $null = Assert-Result $ask 'it hands back' -Match 'standing on a level change'
    $null = Assert-Result $ask 'Ask answers a question, it does not open things' -Match 'dialogs=0->0'

    # ----- C2: the offer itself ---------------------------------------------
    Write-Host ''
    Write-Host '  --- C2. the offer dialog, driven directly'
    $open = Probe @'
local D = require("mod.dialogs.skoobot_reclauded.StairsDialog")
st.picked = nil
game:registerDialog(D.new("test body", function(c) st.picked = c end))
st.d = game.dialogs[#game.dialogs]
local n = 0
for _, u in ipairs(st.d.uis or {}) do if u.ui then n = n + 1 end end
return ("title=%s uis=%d open=%d"):format(tostring(st.d.title), n, #game.dialogs)
'@
    Write-Host "  $($open.Result)"
    $null = Assert-Result $open 'it is the product dialog' -Match 'title=SkooBot: Reclauded'
    $null = Assert-Result $open 'with a body and four buttons' -Match 'uis=5'
    $esc = Probe 'st.d.key.virtuals.EXIT() return ("left=%d picked=%s setting=%s"):format(#game.dialogs, tostring(st.picked), st.setting())'
    Write-Host "  $($esc.Result)"
    $null = Assert-Result $esc 'Escape closes it' -Match 'left=0'
    $null = Assert-Result $esc 'Escape is "not now", never "never"' -Match 'picked=later'
    $null = Assert-Result $esc 'so the setting is untouched' -Match 'setting=0'

    # ----- D: the never button ----------------------------------------------
    Write-Host ''
    Write-Host '  --- D. the offer silences itself when told to'
    $silence = Probe @'
local D = require("mod.dialogs.skoobot_reclauded.StairsDialog")
game:registerDialog(D.new("test body", function(c)
  if c == "never" then st.b.setSetting("TAKE_STAIRS", 2) end
end))
local d = game.dialogs[#game.dialogs]
d:pick("never")
return ("left=%d setting=%s"):format(#game.dialogs, st.setting())
'@
    Write-Host "  $($silence.Result)"
    $null = Assert-Result $silence 'the dialog closed' -Match 'left=0'
    $null = Assert-Result $silence 'and "never" wrote the setting' -Match 'setting=2'

    # ----- E: always --------------------------------------------------------
    Write-Host ''
    Write-Host '  --- E. always: the branch says it would take them, naming what'
    $always = Probe 'return st.decide(1)' 120
    Write-Host "  $($always.Result)"
    $log = @(Get-GameLogLines | Where-Object { $_ -match 'would take' })
    Ok ($log.Count -gt 0) 'query mode says it would take them' ($log -join ' | ')
    if ($log.Count -gt 0) { Write-Host "         $($log[-1])" }

    Write-Host '  --- E2. and the descent itself really works'
    $descend = Probe @'
st.reset()
local p = game.player
p:move(st.sx, st.sy, true)
-- The engine's handler refuses without a turn's worth of energy, and the
-- forced moves above have spent it.
p.energy.value = 1000
local lev0 = tostring(game.level and game.level.level)
local zone0 = tostring(game.zone and game.zone.short_name)
-- The same call takeLevelChange makes: the game's own handler, with every
-- guard it applies, rather than a re-implementation of them.
game.key:triggerVirtual("CHANGE_LEVEL")
return ("zone=%s->%s level=%s->%s"):format(zone0, tostring(game.zone and game.zone.short_name),
  lev0, tostring(game.level and game.level.level))
'@ 180
    Write-Host "  $($descend.Result)"
    if ($descend.Result -match 'zone=(\S+)->(\S+) level=(\S+)->(\S+)') {
        Ok (($Matches[1] -ne $Matches[2]) -or ($Matches[3] -ne $Matches[4])) `
           "the level or the zone really changed ($($Matches[1]):$($Matches[3]) -> $($Matches[2]):$($Matches[4]))" $descend.Result
    } else {
        Ok $false 'the probe reported the zone and level' $descend.Result
    }

    $errs = @(Get-GameLogLines | Where-Object { $_ -match 'Lua Error' })
    Ok ($errs.Count -eq 0) 'no Lua Error in the run' ($errs -join ' | ')
}
finally {
    # In the finally, not the body: TAKE_STAIRS is an ACCOUNT setting and is
    # written to disk, so a run that fails half way would otherwise leave the
    # machine's default wherever the last probe put it -- which is exactly what
    # happened while this scenario was being written.
    $clean = Invoke-Bridge -TimeoutSec 30 -Lua @'
if not _G.st or not st.b then return "nothing to restore" end
st.b.setSetting("TAKE_STAIRS", st.saved or 0)
local restored = st.unpacify()
st.reset()
return ("setting=%s restored=%s"):format(st.setting(), tostring(restored))
'@
    Write-Host "  cleanup    $($clean.Result)"
    Stop-Game
}

Write-Host ''
if ($script:HarnessTainted) { Write-Host '[stairs] TAINTED - void, re-run.'; exit 2 }
if ($script:HarnessFailures.Count -gt 0) {
    Write-Host "[stairs] FAILED - $($script:HarnessFailures.Count) check(s):"
    foreach ($f in $script:HarnessFailures) { Write-Host "                 $f" }
    exit 1
}
Write-Host '[stairs] PASS - never hands back, ask offers, the offer self-silences, and the descent works'
exit 0
