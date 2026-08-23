<#
    Surface scenario: every way a player reaches SkooBot: Reclauded, driven
    through the real keybinds and dialogs, with every Lua error and stop
    reason written down.

    This is the twin of tools/scenario-baseline-v1.ps1, which runs the SAME
    probes against the original SkooBot 0.0.12. Run both and diff the
    findings: that is the parity check for the port (D-12), and afterwards
    the regression check for every fix layered on top of it.

    Measured in game.turn, never wall-clock. Exit codes:
        0 measured   1 could not set up or run   2 tainted by human input

    Run:
        powershell -ExecutionPolicy Bypass -File .\tools\scenario-surface.ps1

    T-003 (parity), T-071.
#>
[CmdletBinding()]
param(
    [string]$SaveName = 'harness',
    [int]$ActDeadlineSec = 150
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'harness.ps1')

$RepoRoot = Split-Path -Parent $PSScriptRoot

$script:Findings = @()
function Finding($kind, $what) {
    $script:Findings += [pscustomobject]@{ Kind = $kind; What = $what }
    Write-Host ('  {0,-6} {1}' -f $kind, $what)
}
function Probe($label, $lua, $timeout = 30) {
    $r = Invoke-Bridge -Lua $lua -TimeoutSec $timeout
    $txt = if ($null -ne $r.Result) { $r.Result } else { '' }
    Write-Host ('  {0,-12} {1,-8} {2}' -f $label, $r.Status, $txt)
    if ($r.Tainted) { $script:Tainted = $true; Write-Host '               TAINTED - human input during this step' }
    if ($r.Status -ne 'OK') { Finding 'BROKEN' "$label -> $($r.Status) $txt" }
    return $r
}

Write-Host ''
Write-Host '[surface] SkooBot: Reclauded on ToME 1.7.6'

$exit = 1
try {
    $g = Load-Save -Name $SaveName
    if (-not $g.Ready) { Write-Host "[surface] FAILED - could not load '$SaveName' ($($g.Reason))"; exit 1 }
    Write-Host ''
    Write-Host 'Load'
    if ($g.AddonsIntact) { Finding 'OK' 'no required addon was dropped by the savefile' } else { Finding 'BROKEN' 'the engine dropped a required addon' }
    if ($g.Addons -match 'skoobot_reclauded') { Finding 'OK' "the product is loaded (addons: $($g.Addons))" } else { Finding 'BROKEN' "the product is NOT loaded (addons: $($g.Addons))"; exit 1 }

    $null = Probe 'helpers' @'
_G.bl = {}
function bl.hostiles()
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
function bl.onChangeLevel()
  local p = game.player
  return game.level.map:checkEntity(p.x, p.y, engine.Map.TERRAIN, "change_level") ~= nil
end
function bl.find(want)
  local p = game.player
  local n = bl.hostiles()
  for i = 1, 60 do
    -- For the quiet case, also avoid level-change tiles: the bot correctly
    -- hands back on one the instant it is toggled ("level change found"),
    -- which would make the toggle look like it never activated.
    local ok = (want == 0 and n == 0 and not bl.onChangeLevel()) or (want > 0 and n > 0)
    if ok then break end
    p:teleportRandom(p.x, p.y, 60, 10)
    n = bl.hostiles()
  end
  return n
end
function bl.status()
  local b = rawget(_G, "skoobot_reclauded")
  if not b then return "no runtime table" end
  return b.inspect() .. " dlg=" .. bridge.dialogs()
end
function bl.lastlog(n)
  local ld = game.uiset and game.uiset.logdisplay
  if not ld or not ld.getLines then return "no logdisplay" end
  local out = {}
  for _, l in ipairs(ld:getLines(n or 4)) do
    local s = l
    if type(l) == "table" then s = l.str or l.msg or l[1] or l end
    if type(s) == "table" and s.toString then s = s:toString() end
    out[#out+1] = (tostring(s):gsub("#[^#]*#", ""))
  end
  return table.concat(out, " | ")
end
return "installed"
'@

    Write-Host ''
    Write-Host 'Surface'
    $null = Probe 'runtime' @'
local b = rawget(_G, "skoobot_reclauded")
if not b then return "ERR no skoobot_reclauded runtime table" end
local names = {}
for _, k in ipairs({"start","stop","query","runonce","inspect","power","data","conditions","talents"}) do
  names[#names+1] = k .. "=" .. type(b[k])
end
return table.concat(names, " ")
'@
    $kb = Probe 'keybinds' @'
local k = game.key
local out = {}
for _, a in ipairs({"TOGGLE_SKOOBOT_RECLAUDED","STOP_SKOOBOT_RECLAUDED","RUNONCE_SKOOBOT_RECLAUDED","ASK_SKOOBOT_RECLAUDED","MENU_SKOOBOT_RECLAUDED"}) do
  local keys = {}
  for ks, types in pairs(k.binds or {}) do if types[a] then keys[#keys+1] = ks end end
  out[#out+1] = a .. "=" .. tostring(k.virtuals and k.virtuals[a] ~= nil) .. ":" .. (#keys > 0 and table.concat(keys, "/") or "none")
end
return table.concat(out, " ")
'@
    if ($kb.Status -eq 'OK') {
        if ($kb.Result -match '=false|:none') { Finding 'BROKEN' "a keybind is unregistered or unbound: $($kb.Result)" } else { Finding 'OK' 'all five actions have handlers and default keys' }
    }
    $null = Probe 'settings' @'
local s = config.settings.tome.skoobot_reclauded
if not s then return "ERR config.settings.tome.skoobot_reclauded is nil" end
local out = {}
for _, k in ipairs({"LOWHEALTH_RATIO","MAX_INDIVIDUAL_POWER","MAX_DIFF_POWER","MAX_COMBINED_POWER","MAX_ENEMY_COUNT","ACTION_DELAY"}) do
  out[#out+1] = k .. "=" .. tostring(s[k])
end
return table.concat(out, " ")
'@
    $null = Probe 'stopconds' @'
local l = skoobot_reclauded.conditions.list()
local out = {}
for _, c in ipairs(l) do out[#out+1] = c.code .. ":" .. c.stoptype end
return #l .. " " .. table.concat(out, " ")
'@
    $pw = Probe 'powerlevel' @'
local ok, v = pcall(function() return skoobot_reclauded.power() end)
if not ok then return "ERR " .. tostring(v) end
return "power=" .. string.format("%.1f", v)
'@
    if ($pw.Status -eq 'OK' -and $pw.Result -match '^ERR') { Finding 'BROKEN' "power: $($pw.Result)" }
    $tt = Probe 'tooltip' @'
local p = game.player
local ok, r = pcall(function() return p:tooltip(p.x, p.y, p) end)
if not ok then return "ERR " .. tostring(r) end
return "tooltip=" .. type(r) .. (type(r) == "table" and (" len=" .. tostring(#r)) or "")
'@
    if ($tt.Status -eq 'OK' -and $tt.Result -match '^ERR') { Finding 'BROKEN' "Actor:tooltip superload: $($tt.Result)" }
    $null = Probe 'inspect' 'return skoobot_reclauded.inspect()'

    Write-Host ''
    Write-Host 'Options tab'
    $op = Probe 'options' @'
local GO = require "mod.dialogs.GameOptions"
local d = GO.new()
game:registerDialog(d)
local found
for i, t in ipairs(d.c_tabs.tabs) do if tostring(t.title):find("Reclauded") then found = t.kind end end
if not found then game:unregisterDialog(d) return "ERR no SkooBot: Reclauded tab among " .. #d.c_tabs.tabs .. " tabs" end
local ok, err = pcall(function() d:switchTo(found) end)
if not ok then game:unregisterDialog(d) return "ERR switchTo: " .. tostring(err) end
local names = {}
for _, it in ipairs(d.list or {}) do
  local s = it.name
  if type(s) == "table" and s.toString then s = s:toString() end
  names[#names+1] = (tostring(s):gsub("#[^#]*#", ""))
end
game:unregisterDialog(d)
return "tab=" .. found .. " options=" .. #names .. ": " .. table.concat(names, "; ")
'@
    if ($op.Status -eq 'OK') {
        if ($op.Result -match '^ERR') { Finding 'BROKEN' "options tab: $($op.Result)" }
        elseif ($op.Result -match 'options=7') { Finding 'OK' 'the [SkooBot: Reclauded] options tab lists its seven settings' }
        else { Finding 'CHANGED' "options tab present but not seven entries: $($op.Result)" }
    }

    Write-Host ''
    Write-Host 'Menu and talent dialog'
    $null = Probe 'menu-key' 'return bridge.key("MENU_SKOOBOT_RECLAUDED") .. " -> " .. bridge.dialogs()'
    $null = Probe 'menu-use' @'
local d = game.dialogs[#game.dialogs]
if not d or tostring(d.title) ~= "SkooBot: Reclauded" then return "ERR top dialog is " .. bridge.dialogs() end
d:use(d.list[1])
local t = game.dialogs[#game.dialogs]
local rows = t and t.c_list and t.c_list.list and #t.c_list.list
return "opened '" .. tostring(t and t.title) .. "' rows=" .. tostring(rows) .. " h=" .. tostring(t and t.h) .. " game.h=" .. tostring(game.h)
'@
    # #56: the talent screen is a sectioned list; the add chain (picker, use
    # type, priority prompt) no longer exists. tools/scenario-talent-screen.ps1
    # is the full regression; this only checks the shape and one move.
    $u3 = Probe 'screen' @'
local t = game.dialogs[#game.dialogs]
if not t or not t.c_list then return "ERR no talent screen: " .. bridge.dialogs() end
local headers, rows = 0, 0
for _, it in ipairs(t.c_list.list) do if it.nodes then headers = headers + 1 else rows = rows + 1 end end
return ("title='%s' headers=%d rows=%d h=%d game.h=%d overflow=%s"):format(tostring(t.title), headers, rows, t.h, game.h, tostring(t.h > game.h))
'@
    if ($u3.Status -eq 'OK' -and $u3.Result -match 'headers=5 rows=[1-9]') { Finding 'OK' 'the talent screen lists four sections plus Unassigned' }
    elseif ($u3.Status -eq 'OK') { Finding 'CHANGED' "talent screen shape: $($u3.Result)" }
    $u6 = Probe 'assign' @'
local t = game.dialogs[#game.dialogs]
local row
for _, it in ipairs(t.c_list.list) do if it.entry and not it.section and it.ekind == "activated" then row = it break end end
if not row then return "ERR no unassigned activated talent" end
t:selectItem(row)
t:moveSelected("Combat")
local r = skoobot_reclauded.rules.get(game.player)
local last = r.Combat[#r.Combat]
return ("moved=%s combat=%d last=%s top=%s"):format(tostring(row.entry.tid), #r.Combat, tostring(last and last.tid), tostring(game.dialogs[#game.dialogs] == t))
'@
    if ($u6.Status -eq 'OK' -and $u6.Result -match 'moved=(T_\w+) combat=\d+ last=\1 top=true') { Finding 'OK' 'moving an unassigned talent to Combat appends it there' }
    elseif ($u6.Status -eq 'OK') { Finding 'CHANGED' "talent move ended oddly: $($u6.Result)" }
    $null = Probe 'close' @'
while #game.dialogs > 0 do game:unregisterDialog(game.dialogs[#game.dialogs]) end
return "dialogs=" .. bridge.dialogs()
'@
    $null = Probe 'menu-key2' 'return bridge.key("MENU_SKOOBOT_RECLAUDED") .. " -> " .. bridge.dialogs()'
    $s2 = Probe 'stop-menu' @'
local d = game.dialogs[#game.dialogs]
if not d or tostring(d.title) ~= "SkooBot: Reclauded" then return "ERR top dialog is " .. bridge.dialogs() end
d:use(d.list[2])
local p = game.dialogs[#game.dialogs]
if not p or not p.list then return "ERR condition picker did not open: " .. bridge.dialogs() end
local r = ("title='%s' items=%d h=%d game.h=%d overflow=%s"):format(tostring(p.title), #p.list, p.h, game.h, tostring(p.h > game.h))
p:use(p.list[1])
local q = game.dialogs[#game.dialogs]
q:use(q.list[3])
local c = skoobot_reclauded.conditions.get("DEBUFF_STUNNED")
return r .. " ; DEBUFF_STUNNED -> " .. tostring(c and c.stoptype)
'@
    if ($s2.Status -eq 'OK' -and $s2.Result -match 'DEBUFF_STUNNED -> STOP') { Finding 'OK' 'stop-condition menu round trip changes the policy' }
    $null = Probe 'close2' @'
while #game.dialogs > 0 do game:unregisterDialog(game.dialogs[#game.dialogs]) end
skoobot_reclauded.conditions.set("DEBUFF_STUNNED", "WARN")
return "dialogs=" .. bridge.dialogs()
'@

    Write-Host ''
    Write-Host 'Acting (quiet)'
    $q = Probe 'quiet' 'return "hostiles=" .. tostring(bl.find(0)) .. " " .. bl.status()' 120
    if ($q.Status -ne 'OK' -or $q.Result -notmatch 'hostiles=0 ') {
        Finding 'INFO' 'could not find a quiet spot; acting results below are in company'
    }
    $null = Probe 'query' 'local r = bridge.key("ASK_SKOOBOT_RECLAUDED") return r .. " | " .. bl.lastlog(3)'
    $null = Probe 'runonce' 'local r = bridge.key("RUNONCE_SKOOBOT_RECLAUDED") return r .. " | " .. bl.status() .. " | " .. bl.lastlog(2)'
    Start-Sleep -Seconds 3
    $null = Probe 'after-once' 'return bl.status() .. " | " .. bl.lastlog(2)'

    function Watch($label, $deadlineSec) {
        $t0 = Invoke-Bridge -Lua 'return tostring(game.turn)' -TimeoutSec 30
        $before = if ($t0.Status -eq 'OK') { [int]($t0.Result -replace '[^\d\-].*$', '') } else { -1 }
        # A dialog on screen owns Key.current and swallows a virtual key, and the
        # bot refuses to start under one anyway. Clear the deck, then test the KEY
        # path; if it fails, start directly so the bot is still measured.
        $null = Probe "$label-clear" 'while #game.dialogs > 0 do game:unregisterDialog(game.dialogs[#game.dialogs]) end return "dialogs=" .. bridge.dialogs() .. " focus_is_map=" .. tostring(require("engine.Key").current == game.key)'
        $tg = Probe "$label-toggle" 'local r = bridge.key("TOGGLE_SKOOBOT_RECLAUDED") return r .. " | " .. bl.status()'
        # "active=false" right after the toggle is only a failure if the bot did
        # NOTHING. It legitimately activates and hands back in the same decision
        # -- on a level-change tile, or facing enemies too strong to fight -- and
        # that shows as active=false with a stop reason. Only a bare active=false
        # with no reason means the key was swallowed; then start directly.
        if ($tg.Status -eq 'OK' -and $tg.Result -notmatch 'active=true' -and $tg.Result -match 'reason=nil') {
            Finding 'BROKEN' "${label}: the toggle keybind did not activate the bot: $($tg.Result)"
            $tg = Probe "$label-direct" 'skoobot_reclauded.start() return bl.status()'
        } elseif ($tg.Result -notmatch 'active=true') {
            Finding 'INFO' "${label}: activated and handed back at once ($($tg.Result -replace '.*reason=', 'reason='))"
        }
        $deadline = (Get-Date).AddSeconds($deadlineSec)
        $turn = $before; $active = $true; $last = ''
        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Seconds 3
            if (-not (Test-GameAlive)) { Finding 'BROKEN' "${label}: the game process died"; break }
            $s = Invoke-Bridge -Lua 'return bl.status() .. " | " .. bl.lastlog(2)' -TimeoutSec 30
            if ($s.Status -ne 'OK') { continue }
            if ($s.Tainted) { $script:Tainted = $true }
            $last = $s.Result
            Write-Host "  poll         $($s.Result)"
            if ($s.Result -match 'turn=(\d+)') { $turn = [int]$Matches[1] }
            if ($s.Result -match 'active=false') { $active = $false; break }
        }
        $null = Probe "$label-off" 'local r = bridge.key("STOP_SKOOBOT_RECLAUDED") return r .. " | " .. bl.status()'
        $adv = $turn - $before
        Finding 'INFO' ("{0}: game.turn advanced {1} ({2} -> {3}); handed back={4}; last: {5}" -f $label, $adv, $before, $turn, (-not $active), $last)
        # What counts as healthy is progress, not whether it happened to be
        # active at the (arbitrary) deadline. A bot that hands back at once for
        # a legitimate reason -- too-strong enemies, a level-change tile --
        # advances no turns and that is the designed "stop early" behaviour. A
        # bot still active at the deadline having advanced thousands of turns is
        # a long, healthy session. A hang is being active while NOT advancing.
        if ($active) {
            if ($adv -gt 0) { Finding 'INFO' "${label}: still playing at the ${deadlineSec}s deadline (advanced $adv turns) -- a long session, not a hang" }
            else { Finding 'BROKEN' "${label}: active but advanced 0 turns -- a hang" }
        } elseif ($adv -le 0 -and $last -match 'reason=nil') {
            Finding 'BROKEN' "${label}: did not advance and gave no reason"
        }
        if ($last -match 'internal error') { Finding 'BROKEN' "${label}: stopped on an internal error" }
    }
    Watch 'quiet' $ActDeadlineSec

    Write-Host ''
    Write-Host 'Acting (hostile in view)'
    $null = Probe 'talents' @'
local p = game.player
local auto = skoobot_reclauded.data(p).autotalents
while #auto > 0 do table.remove(auto) end
local n = 0
for tid, _ in pairs(p.talents) do
  local t = p:getTalentFromId(tid)
  if t and t.mode == "activated" and not t.no_npc_use and not t.no_dumb_use and t.hide ~= "always" then
    n = n + 1
    auto[#auto+1] = {tid=tid, usetype="Combat", priority=n}
  end
end
return "combat talents configured: " .. #auto
'@
    $h = Probe 'company' 'return "hostiles=" .. tostring(bl.find(1)) .. " " .. bl.status()' 120
    if ($h.Status -eq 'OK' -and $h.Result -match 'hostiles=0 ') {
        Finding 'INFO' 'could not find a hostile within 60 teleports; fight path not measured'
    } else {
        Watch 'fight' $ActDeadlineSec
    }

    Write-Host ''
    Write-Host 'Talent screen with many talents (T-014)'
    $many = Probe 'picker-many' @'
local p = game.player
local learned = 0
for tid, t in pairs(p.talents_def) do
  if learned >= 40 then break end
  if t.mode == "activated" and not t.hide and not p:knowTalent(tid) then
    local ok = pcall(function() p:learnTalent(tid, true, 1) end)
    if ok and p:knowTalent(tid) then learned = learned + 1 end
  end
end
local d = require("mod.dialogs.skoobot_reclauded.TalentDialog").new(p)
game:registerDialog(d)
local rows = 0
for _, it in ipairs(d.c_list.list) do if it.entry and not it.section then rows = rows + 1 end end
local r = ("learned=%d title='%s' unassigned=%d h=%d game.h=%d overflow=%s"):format(learned, tostring(d.title), rows, d.h, game.h, tostring(d.h > game.h))
while #game.dialogs > 0 do game:unregisterDialog(game.dialogs[#game.dialogs]) end
return r
'@ 90
    if ($many.Status -eq 'OK') {
        # T-014 is fixed if the screen fits AND still lists every talent: since
        # #56 the Unassigned section scrolls rather than truncates. Overflow
        # here is a regression.
        if ($many.Result -match 'overflow=false') { Finding 'OK' "T-014 fixed: the talent screen fits the screen ($($many.Result))" }
        else { Finding 'BROKEN' "T-014 regressed: the talent screen overflows ($($many.Result))" }
        if ($many.Result -match 'unassigned=(\d+)' -and [int]$Matches[1] -ge 40) { Finding 'OK' 'the screen still lists every talent (scrolled, not truncated)' }
        else { Finding 'BROKEN' "the screen dropped talents: $($many.Result)" }
    }

    $exit = 0
}
finally {
    Stop-Game
}

Write-Host ''
Write-Host 'Engine log'
Start-Sleep -Seconds 2
$archive = Join-Path $RepoRoot 'build\logs'
if (-not (Test-Path $archive)) { New-Item -ItemType Directory -Path $archive -Force | Out-Null }
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$dest = Join-Path $archive "surface-$stamp.txt"
Copy-Item $script:LogPath $dest -ErrorAction Ignore
$lines = @((Get-Content $script:LogPath -Raw -ErrorAction Ignore) -split "`r?`n")

$bound = @($lines | Where-Object { $_ -match "^Binding addon`tSkooBot: Reclauded`t" })
if ($bound.Count -gt 0) { Finding 'OK' "engine bound the product: $($bound[0])" } else { Finding 'BROKEN' 'no "Binding addon SkooBot: Reclauded" line in the log' }

$errIdx = @(); for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match 'Lua Error') { $errIdx += $i } }
if ($errIdx.Count -eq 0) { Finding 'OK' 'no Lua Error anywhere in the run' }
foreach ($i in $errIdx) {
    $ctx = @()
    for ($j = $i; $j -lt [math]::Min($i + 6, $lines.Count); $j++) { $ctx += $lines[$j].Trim() }
    Finding 'ERROR' ($ctx -join ' // ')
}
$acts = @($lines | Where-Object { $_ -match '^\[SKOOBOT\] \[Action\]' })
$states = @($lines | Where-Object { $_ -match '^\[SKOOBOT\] \[State\]' })
Finding 'INFO' "$($acts.Count) action line(s), $($states.Count) state line(s) from the bot in the log"
foreach ($a in ($acts | Select-Object -First 5)) { Write-Host "         $a" }
# Keys and clicks only: the engine logs [DO RESIZE] itself at every launch.
$interfere = @($lines | Where-Object { $_ -match '\[BRIDGE\] INTERFERE (key|mouse)' })
if ($interfere.Count -gt 0) { $script:Tainted = $true }
Write-Host "  log archived to $dest"

Write-Host ''
Write-Host '[surface] summary'
$script:Findings | Group-Object Kind | ForEach-Object { Write-Host ('  {0,-7} {1}' -f $_.Name, $_.Count) }
if ($script:Tainted) {
    Write-Host ''
    Write-Host '[surface] TAINTED - a human touched the machine during this run. Void; re-run.'
    exit 2
}
exit $exit
