<#
    #46: the levelled debug channel, in the game.

    data/log.lua is pure and spec/log_spec.lua proves its gating, laziness
    and line shape without a game. What only a game can show is the wiring:
    that the persisted LOG_LEVEL seeds the channel, that the options-tab
    entry cycles it and writes the setting, that the bridge can switch it,
    that the bot's own lines land in the engine's print log at the level
    each was given, that a warning reaches the message log and a stop does
    not reach it twice, and that a disabled level costs no formatting in the
    real act loop.

    Lines are read from get_printlog() -- the loader's record of every
    print() call (game/loader/pre-init.lua) -- in the same frame as the
    decision that produced them, so nothing depends on tailing te4_log.txt
    mid-run. Decisions are driven through query mode on a quiet tile, which
    spends no energy and advances no game.turn, plus one runonce for a real
    "[Action]" line; the game is never saved, and the level is put back to
    the default before the game is stopped, through the same options entry,
    so the settings file is left as it was found.

    Exit codes:  0 pass   1 fail   2 tainted   3 inconclusive (no quiet spot
    -- a setup problem, never a product failure)

    Run:
        powershell -ExecutionPolicy Bypass -File .\tools\scenario-debug-channel.ps1

    #46, #27.
#>
[CmdletBinding()]
param(
    [string]$SaveName = 'harness'
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'harness.ps1')

Write-Host ''
Write-Host '[debug-channel] the levelled debug channel (#46)'

function Inconclusive($why) {
    Write-Host "[debug-channel] INCONCLUSIVE - $why"
    Stop-Game
    exit 3
}

try {
    $g = Load-Save -Name $SaveName
    if (-not $g.Ready) { Write-Host "[debug-channel] FAILED - could not load '$SaveName' ($($g.Reason))"; exit 1 }
    $null = Assert-Result ([pscustomobject]@{ Status = 'OK'; Result = $g.Addons; Tainted = $false }) 'the product is loaded' -Match 'skoobot_reclauded'

    $install = Invoke-Bridge -Lua @'
_G.dc = {}
local b = rawget(_G, "skoobot_reclauded")
if not b then return "ERR no skoobot_reclauded runtime table" end
if not b.log then return "OLD no skoobot_reclauded.log" end

function dc.hostiles()
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
function dc.onChangeLevel()
  local p = game.player
  return game.level.map:checkEntity(p.x, p.y, engine.Map.TERRAIN, "change_level") ~= nil
end
function dc.findQuiet()
  local p = game.player
  for i = 1, 80 do
    if dc.hostiles() == 0 and not dc.onChangeLevel() then return true end
    p:teleportRandom(p.x, p.y, 60, 10)
  end
  return dc.hostiles() == 0 and not dc.onChangeLevel()
end
function dc.reset()
  while #game.dialogs > 0 do game:unregisterDialog(game.dialogs[#game.dialogs]) end
  if b.active then b.stop("test reset") end
  b.state = 11   -- STATE_EXPLORE: the branch with the most to say
  b.activation = nil; b.loop = nil; b.prevloop = nil
  game.player.life = game.player.max_life
end

-- The bot's printed lines since a mark, by tag. The print log records one
-- entry per print() call; the channel prints one string per line.
function dc.mark() return #get_printlog() end
function dc.since(mark)
  local log = get_printlog()
  local out = { all = 0, info = 0, debug = 0, trace = 0, warn = 0, error = 0, lines = {} }
  for i = mark + 1, #log do
    local s = tostring(log[i][1] or "")
    if s:find("^%[SKOOBOT%]") then
      out.all = out.all + 1
      local tag = s:match("^%[SKOOBOT%] %[(%a+)%] ")
      if tag and out[tag] then out[tag] = out[tag] + 1 else out.info = out.info + 1 end
      out.lines[#out.lines + 1] = s
    end
  end
  return out
end
function dc.summary(c)
  return ("all=%d info=%d debug=%d trace=%d warn=%d error=%d"):format(c.all, c.info, c.debug, c.trace, c.warn, c.error)
end
function dc.has(c, pattern)
  for _, s in ipairs(c.lines) do if s:find(pattern) then return true end end
  return false
end

-- The last n message-log lines, colour codes stripped.
function dc.lastlog(n)
  local ld = game.uiset and game.uiset.logdisplay
  if not ld or not ld.getLines then return {} end
  local out = {}
  for _, l in ipairs(ld:getLines(n or 4)) do
    local s = l
    if type(l) == "table" then s = l.str or l.msg or l[1] or l end
    if type(s) == "table" and s.toString then s = s:toString() end
    out[#out + 1] = (tostring(s):gsub("#[^#]*#", ""))
  end
  return out
end
function dc.countlog(n, needle)
  local c = 0
  for _, s in ipairs(dc.lastlog(n)) do if s:find(needle, 1, true) then c = c + 1 end end
  return c
end

-- One query-mode decision at a level; returns the counts by tag and the
-- turn delta, which must be 0.
function dc.decide(level)
  dc.reset()
  local set = b.log.setLevel(level)
  if set ~= level then return "SETUP setLevel(" .. tostring(level) .. ") -> " .. tostring(set) end
  local m = dc.mark()
  local before = game.turn
  b.query()
  local c = dc.since(m)
  return ("level=%s dturn=%d %s state=%s survival=%s stop=%s"):format(
    b.log.getLevel(), game.turn - before, dc.summary(c),
    tostring(dc.has(c, "^%[SKOOBOT%] %[debug%] %[State%] ")),
    tostring(dc.has(c, "^%[SKOOBOT%] %[trace%] %[Survival%] Evaluating")),
    tostring(dc.has(c, "^%[SKOOBOT%] %[Stop%] ")))
end

-- The options-tab entry for the log level: its status text and its action.
function dc.optionEntry()
  local GO = require "mod.dialogs.GameOptions"
  local d = GO.new()
  game:registerDialog(d)
  local found
  for _, t in ipairs(d.c_tabs.tabs) do if tostring(t.title):find("Reclauded") then found = t.kind end end
  if not found then game:unregisterDialog(d) return nil, "no SkooBot: Reclauded tab" end
  local ok, err = pcall(function() d:switchTo(found) end)
  if not ok then game:unregisterDialog(d) return nil, "switchTo: " .. tostring(err) end
  local entry, last
  for _, it in ipairs(d.list or {}) do
    local s = it.name
    if type(s) == "table" and s.toString then s = s:toString() end
    s = tostring(s):gsub("#[^#]*#", "")
    last = s
    if s:find("Log level", 1, true) then entry = it end
  end
  if not entry then game:unregisterDialog(d) return nil, "no 'Log level' entry; last is " .. tostring(last) end
  return d, entry, last
end
function dc.option(cycles)
  local d, entry, last = dc.optionEntry()
  if not d then return "ERR " .. tostring(entry) end
  local out = { "last=" .. tostring(last):gsub("^%s+", ""), "start=" .. tostring(entry.status()) }
  for i = 1, (cycles or 0) do
    entry.fct(entry)
    out[#out + 1] = tostring(entry.status()) .. "/" .. tostring(config.settings.tome.skoobot_reclauded.LOG_LEVEL) .. "/" .. b.log.getLevel()
  end
  game:unregisterDialog(d)
  return table.concat(out, " ")
end
return "installed level=" .. b.log.getLevel() .. " setting=" .. tostring(config.settings.tome.skoobot_reclauded.LOG_LEVEL)
'@ -TimeoutSec 30
    if ($install.Result -match '^OLD') { Inconclusive $install.Result }
    if (-not (Assert-Result $install 'helpers installed' -Match '^installed')) { Stop-Game; exit 1 }
    Write-Host "  $($install.Result)"
    $null = Assert-Result $install 'the channel starts at info, from LOG_LEVEL = 3' -Match 'level=info setting=3$'

    $quiet = Invoke-Bridge -Lua 'return tostring(dc.findQuiet())' -TimeoutSec 120
    if ($quiet.Result -ne 'True') { Inconclusive 'no spot with nothing in sight to decide from' }

    Write-Host ''
    Write-Host '  --- switching from the bridge'
    $sw = Invoke-Bridge -Lua @'
local b = skoobot_reclauded
local out = {}
out[#out+1] = "debug=" .. tostring(b.log.setLevel("debug"))
out[#out+1] = "num=" .. tostring(b.log.setLevel(5))
local name, err = b.log.setLevel("loud")
out[#out+1] = "bad=" .. tostring(name) .. "/" .. tostring(err) .. "/" .. b.log.getLevel()
out[#out+1] = "off=" .. tostring(b.log.setLevel("off"))
out[#out+1] = "back=" .. tostring(b.log.setLevel("info"))
return table.concat(out, " ")
'@ -TimeoutSec 30
    Write-Host "  $($sw.Result)"
    $null = Assert-Result $sw 'setLevel takes a name and returns it' -Match 'debug=debug '
    $null = Assert-Result $sw 'setLevel takes a number and returns the name' -Match 'num=trace '
    $null = Assert-Result $sw 'setLevel refuses an unknown level with a message and leaves the level alone' -Match 'bad=nil/no such log level: loud/trace '
    $null = Assert-Result $sw 'off and back to info' -Match 'off=off back=info$'

    Write-Host ''
    Write-Host '  --- one query-mode decision at each level'
    foreach ($lvl in @('off', 'info', 'debug', 'trace')) {
        $r = Invoke-Bridge -Lua "return dc.decide('$lvl')" -TimeoutSec 60
        Write-Host "  $($r.Result)"
        if ($r.Result -match '^SETUP') { Inconclusive $r.Result }
        $null = Assert-Result $r "at $lvl the decision advances no game turn" -Match 'dturn=0 '
        switch ($lvl) {
            'off'   { $null = Assert-Result $r 'at off the bot prints nothing at all' -Match ' all=0 ' }
            'info'  { $null = Assert-Result $r 'at info there is no debug or trace line' -Match ' debug=0 trace=0 '
                      $null = Assert-Result $r 'at info the [State] line is not printed' -Match 'state=false' }
            'debug' { $null = Assert-Result $r 'at debug the [State] line is printed, tagged [debug]' -Match 'state=true'
                      $null = Assert-Result $r 'at debug there is no trace line' -Match ' trace=0 ' }
            'trace' { $null = Assert-Result $r 'at trace the per-iteration [Survival] chatter is printed, tagged [trace]' -Match 'survival=true'
                      $null = Assert-Result $r 'at trace the [State] line is still there' -Match 'state=true' }
        }
    }

    Write-Host ''
    Write-Host '  --- a real action at info: the line the other scenarios grep for'
    $once = Invoke-Bridge -Lua @'
local b = skoobot_reclauded
dc.reset()
b.log.setLevel("info")
b.state = 10   -- STATE_REST: rest or, with nothing to rest for, explore
local m = dc.mark()
b.runonce()
local c = dc.since(m)
local action = nil
for _, s in ipairs(c.lines) do if s:find("^%[SKOOBOT%] %[Action%] ") then action = s end end
if game.player.resting then game.player:restStop() end
if game.player.running then game.player:runStop() end
return ("action=[%s] %s"):format(tostring(action), dc.summary(c))
'@ -TimeoutSec 60
    Write-Host "  $($once.Result)"
    $null = Assert-Result $once 'runonce prints its [Action] line with the plain "[SKOOBOT] [Action]" prefix (no level tag at info)' -Match 'action=\[\[SKOOBOT\] \[Action\] Beginning to (rest|explore)\.\]'
    $null = Assert-Result $once 'and nothing below info' -Match ' debug=0 trace=0 '

    Write-Host ''
    Write-Host '  --- warnings reach the message log once; stops are not doubled'
    $warn = Invoke-Bridge -Lua @'
local b = skoobot_reclauded
dc.reset()
b.log.setLevel("warn")
local m = dc.mark()
b.log.warn("[Harness] probe %d of %s", 1, "warn")
b.log.info("[Harness] probe hidden at warn")
local c = dc.since(m)
local seen = dc.countlog(6, "[Harness] probe 1 of warn")
local hidden = dc.countlog(6, "probe hidden")
b.log.setLevel("error")
b.log.warn("[Harness] probe 2 silenced at error")
local c2 = dc.since(m)
local seen2 = dc.countlog(6, "probe 2 silenced")
b.log.setLevel("info")
-- a stop: one [Stop] line in the print log, exactly one message-log line
local m3 = dc.mark()
b.active = true
b.stop("harness stop probe")
local c3 = dc.since(m3)
local stoplog = dc.countlog(6, "harness stop probe")
return ("file=%d/%s chat=%d hidden=%d | silenced=%d/%d | stop=%s stopchat=%d stopline=%s"):format(
  c.all, dc.summary(c), seen, hidden, c2.all - c.all, seen2,
  tostring(dc.has(c3, "^%[SKOOBOT%] %[Stop%] Handed back: harness stop probe$")), stoplog,
  tostring(c3.lines[1]))
'@ -TimeoutSec 30
    Write-Host "  $($warn.Result)"
    $null = Assert-Result $warn 'at warn, one warn line is printed and the info line is not' -Match '^file=1/all=1 info=0 debug=0 trace=0 warn=1 error=0 '
    $null = Assert-Result $warn 'the warning reached the message log, once, as plain text' -Match ' chat=1 hidden=0 '
    $null = Assert-Result $warn 'at error, a warning goes nowhere' -Match '\| silenced=0/0 \|'
    $null = Assert-Result $warn 'a stop prints one [Stop] line at info, with no level tag' -Match ' stop=true '
    $null = Assert-Result $warn 'and the player sees the stop exactly once (the notice, not the channel)' -Match ' stopchat=1 '

    Write-Host ''
    Write-Host '  --- a disabled level does no work in the act loop'
    $lazy = Invoke-Bridge -Lua @'
local b = skoobot_reclauded
b.log.setLevel("info")
local called = 0
b.log.debug(function() called = called + 1 return "x" end)
b.log.trace(function() called = called + 1 return "x" end)
local before = called
b.log.setLevel("trace")
b.log.trace(function() called = called + 1 return "x" end)
b.log.setLevel("info")
return ("disabled_calls=%d enabled_calls=%d"):format(before, called - before)
'@ -TimeoutSec 30
    Write-Host "  $($lazy.Result)"
    $null = Assert-Result $lazy 'a message function is not called at a disabled level, and is at an enabled one' -Match '^disabled_calls=0 enabled_calls=1$'

    Write-Host ''
    Write-Host '  --- the options tab'
    # Six cycles from info: debug, trace, off, error, warn, info -- back where
    # it started, so the settings file ends as it began.
    $opt = Invoke-Bridge -Lua 'return dc.option(6)' -TimeoutSec 60
    Write-Host "  $($opt.Result)"
    $null = Assert-Result $opt 'the Log level entry is the last one on the tab' -Match '^last=\[Reclauded\] Log level '
    $null = Assert-Result $opt 'it shows the level by name, info to start' -Match ' start=info '
    $null = Assert-Result $opt 'each selection steps the name, the persisted number and the running channel together, and wraps' -Match ' debug/4/debug trace/5/trace off/0/off error/1/error warn/2/warn info/3/info$'
    $final = Invoke-Bridge -Lua 'return "level=" .. skoobot_reclauded.log.getLevel() .. " setting=" .. tostring(config.settings.tome.skoobot_reclauded.LOG_LEVEL)' -TimeoutSec 30
    $null = Assert-Result $final 'the level and the setting are back at the default' -Match '^level=info setting=3$'
}
finally {
    Stop-Game
}

Write-Host ''
if ($script:HarnessTainted) { Write-Host '[debug-channel] TAINTED - void, re-run.'; exit 2 }
if ($script:HarnessFailures.Count -gt 0) {
    Write-Host "[debug-channel] FAILED - $($script:HarnessFailures.Count) check(s):"
    foreach ($f in $script:HarnessFailures) { Write-Host "                 $f" }
    exit 1
}
Write-Host '[debug-channel] PASS - the channel is seeded from the setting, switched from the tab and the bridge, and gates what the bot prints'
exit 0
