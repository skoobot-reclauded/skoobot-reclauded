<#
    T-003 baseline: run the ORIGINAL SkooBot 0.0.12, unmodified, on ToME 1.7.6
    and record what works and what breaks.

    This is the empirical half of the port's remediation list (T-001 is the
    analytical half). It drives v1 through the devbridge exactly as a player
    would reach it -- keybinds, the SkooBot menu, the talent dialog, the
    options tab, the query and toggle actions -- and writes down every Lua
    error and every stop reason. Nothing here asserts that v1 is correct; it
    asserts that we measured it.

    v1 is loaded from a COPY, never from the research archive's reference
    clone: the game reads the addon directory and a junction into reference/
    would make the archive part of the game's load path. Stage one with

        git -C "<archive>/reference/skoobot-upstream" archive ad23dea init.lua hooks data overload superload | tar -x -C <dir>

    and pass <dir> as -V1Dir. The script refuses a path under reference/.

    While it runs, the product junction (tome-skoobot_reclauded) is removed so
    that v1 is the only bot in the game -- both superload Player:act(), and two
    bots answering one turn is not a baseline of anything. The junction is put
    back when the script ends, however it ends.

    The save it uses is separate (default 'baselinev1') because a save records
    its addon list and the engine drops anything unlisted (T-042); it is
    created on first run through tools/new-character.ps1 -RequiredAddons.

    Run:
        powershell -ExecutionPolicy Bypass -File .\tools\scenario-baseline-v1.ps1 -V1Dir <copy of v1>

    Exit codes:  0 measured   1 could not set up or run   2 tainted by human input

    T-003.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$V1Dir,
    [string]$SaveName = 'baselinev1',
    [int]$ActDeadlineSec = 150,
    [switch]$KeepJunctions
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'harness.ps1')

# v1's short_name, not the product's. Both guards in harness.ps1 read this.
$script:RequiredSaveAddons = @('skoobot', 'skoobot_devbridge')

$RepoRoot = Split-Path -Parent $PSScriptRoot
if ($env:TOME_DIR) { $GameDir = $env:TOME_DIR } else { $GameDir = 'C:\games\TalesMajEyal' }
$AddonsDir   = Join-Path $GameDir 'game\addons'
$V1Link      = Join-Path $AddonsDir 'tome-skoobot'
$ProductLink = Join-Path $AddonsDir 'tome-skoobot_reclauded'

# --------------------------------------------------------------------------
# Junction helpers, same discipline as setup-dev.ps1: Directory::Delete on a
# junction removes the reparse point only; Remove-Item -Recurse can delete
# THROUGH it, which here would empty the staged copy or src/.
# --------------------------------------------------------------------------
function Get-JunctionTarget($path) {
    $item = Get-Item -LiteralPath $path -Force -ErrorAction Ignore
    if (-not $item) { return $null }
    if (-not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { return '<not-a-link>' }
    if ($item.Target) { return @($item.Target)[0] }
    return '<unknown>'
}
function Remove-Junction($path) { [System.IO.Directory]::Delete($path, $false) }

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

# --------------------------------------------------------------------------
# Setup
# --------------------------------------------------------------------------
Write-Host ''
Write-Host '[baseline-v1] SkooBot 0.0.12 on ToME 1.7.6 (T-003)'

$v1Full = [IO.Path]::GetFullPath($V1Dir)
if ($v1Full -match '[\\/]reference[\\/]') {
    Write-Host "[baseline-v1] FAILED - refusing to junction the research archive's reference clone ($v1Full). Stage a copy."
    exit 1
}
$v1Init = Join-Path $v1Full 'init.lua'
if (-not (Test-Path $v1Init)) { Write-Host "[baseline-v1] FAILED - no init.lua under $v1Full"; exit 1 }
$manifest = Get-Content $v1Init -Raw
if ($manifest -notmatch 'short_name\s*=\s*"skoobot"') {
    Write-Host "[baseline-v1] FAILED - $v1Init is not SkooBot (short_name is not 'skoobot')"; exit 1
}
$v1Version = if ($manifest -match 'addon_version\s*=\s*\{([^}]*)\}') { ($Matches[1] -replace '\s','') -replace ',','.' } else { '?' }
Write-Host "[baseline-v1] v1 addon_version $v1Version from $v1Full"

$productWas = Get-JunctionTarget $ProductLink
$v1Was      = Get-JunctionTarget $V1Link
$exit = 1
try {
    # Product out, v1 in.
    if ($productWas -eq '<not-a-link>') {
        Write-Host "[baseline-v1] FAILED - $ProductLink is a real directory, not a junction; refusing to touch it"; exit 1
    }
    if ($null -ne $productWas) { Remove-Junction $ProductLink; Write-Host "[baseline-v1] removed product junction (was -> $productWas)" }

    if ($v1Was -eq '<not-a-link>') {
        Write-Host "[baseline-v1] FAILED - $V1Link is a real directory, not a junction; refusing to replace it"; exit 1
    }
    if ($null -ne $v1Was) { Remove-Junction $V1Link }
    New-Item -ItemType Junction -Path $V1Link -Target $v1Full | Out-Null
    Write-Host "[baseline-v1] junction tome-skoobot -> $v1Full"

    # A save that records v1. Made once; the engine only attaches listed addons.
    if ($null -eq (Get-SaveAddons -Name $SaveName)) {
        Write-Host "[baseline-v1] no save '$SaveName'; creating one (this takes minutes)"
        & powershell -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'new-character.ps1') `
            -Name $SaveName -RequiredAddons skoobot,skoobot_devbridge
        if ($LASTEXITCODE -ne 0) { Write-Host "[baseline-v1] FAILED - could not create save '$SaveName'"; exit 1 }
    }

    $g = Load-Save -Name $SaveName
    if (-not $g.Ready) { Write-Host "[baseline-v1] FAILED - could not load '$SaveName' ($($g.Reason))"; exit 1 }
    Write-Host ''
    Write-Host 'Load'
    if ($g.AddonsIntact) { Finding 'OK' 'no required addon was dropped by the savefile' } else { Finding 'BROKEN' 'the engine dropped a required addon' }
    if ($g.Addons -match '(^|,)skoobot(,|$)') { Finding 'OK' "v1 is loaded (addons: $($g.Addons))" } else { Finding 'BROKEN' "v1 is NOT loaded (addons: $($g.Addons))"; exit 1 }

    # ----------------------------------------------------------------------
    # Helpers installed into the game for the rest of the run. loadstring
    # chunks run in _G, so a table assigned here persists between commands.
    # ----------------------------------------------------------------------
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
function bl.find(want)
  local p = game.player
  local n = bl.hostiles()
  for i = 1, 60 do
    if (want == 0 and n == 0) or (want > 0 and n > 0) then break end
    p:teleportRandom(p.x, p.y, 60, 10)
    n = bl.hostiles()
  end
  return n
end
function bl.status()
  local P = require "mod.class.Player"
  local st = P.skoobot and P.skoobot.tempvals and P.skoobot.tempvals.state
  local p = game.player
  return "turn=" .. tostring(game.turn) .. " active=" .. tostring(P.ai_active) .. " state=" .. tostring(st)
    .. " life=" .. tostring(math.floor(p.life)) .. "/" .. tostring(math.floor(p.max_life))
    .. " air=" .. tostring(p.air) .. " hostiles=" .. tostring(bl.hostiles())
    .. " resting=" .. tostring(p.resting ~= nil) .. " running=" .. tostring(p.running ~= nil)
    .. " dialogs=" .. tostring(#game.dialogs) .. " dlg=" .. bridge.dialogs()
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
    $null = Probe 'class' @'
local P = require "mod.class.Player"
local A = require "mod.class.Actor"
return "ai_active=" .. tostring(P.ai_active) .. " skoobot=" .. tostring(P.skoobot ~= nil)
  .. " start=" .. tostring(P.skoobot_start ~= nil) .. " query=" .. tostring(P.skoobot_query ~= nil)
  .. " runonce=" .. tostring(P.skoobot_runonce ~= nil) .. " checkStop=" .. tostring(P.checkStop ~= nil)
  .. " powerlevel=" .. tostring(A.evaluatePowerLevel ~= nil) .. " scores=" .. tostring(A.evaluatePowerScores ~= nil)
'@
    $kb = Probe 'keybinds' @'
local k = game.key
local out = {}
for _, a in ipairs({"TOGGLE_SKOOBOT","DISABLE_SKOOBOT","SKOOBOT_RUNONCE","ASK_SKOOBOT","SKOOBOT_MENU"}) do
  local keys = {}
  for ks, types in pairs(k.binds or {}) do if types[a] then keys[#keys+1] = ks end end
  out[#out+1] = a .. "=" .. tostring(k.virtuals and k.virtuals[a] ~= nil) .. ":" .. (#keys > 0 and table.concat(keys, "/") or "none")
end
return table.concat(out, " ")
'@
    if ($kb.Status -eq 'OK') {
        if ($kb.Result -match '=false|:none') { Finding 'BROKEN' "a keybind is unregistered or unbound: $($kb.Result)" } else { Finding 'OK' 'all five v1 actions have handlers and default keys' }
    }
    $null = Probe 'settings' @'
local s = config.settings.tome.SkooBot
if not s then return "ERR config.settings.tome.SkooBot is nil" end
local out = {}
for _, k in ipairs({"LOWHEALTH_RATIO","MAX_INDIVIDUAL_POWER","MAX_DIFF_POWER","MAX_COMBINED_POWER","MAX_ENEMY_COUNT","ACTION_DELAY"}) do
  out[#out+1] = k .. "=" .. tostring(s[k])
end
return table.concat(out, " ")
'@
    $sc = Probe 'stopconds' @'
local l = game.player:getStopConditionList()
local out = {}
for _, c in ipairs(l) do out[#out+1] = c.code .. ":" .. c.stoptype end
return #l .. " " .. table.concat(out, " ")
'@
    $pw = Probe 'powerlevel' @'
local ok, v = pcall(function() return game.player:evaluatePowerLevel() end)
if not ok then return "ERR " .. tostring(v) end
local ok2, s = pcall(function() return game.player:evaluatePowerScores() end)
if not ok2 then return "power=" .. tostring(v) .. " scores ERR " .. tostring(s) end
local keys = {}
for k, x in pairs(s) do keys[#keys+1] = k .. "=" .. (type(x) == "table" and "{..}" or string.format("%.1f", x)) end
table.sort(keys)
return "power=" .. string.format("%.1f", v) .. " " .. table.concat(keys, " ")
'@
    if ($pw.Status -eq 'OK' -and $pw.Result -match '^ERR') { Finding 'BROKEN' "evaluatePowerLevel: $($pw.Result)" }
    $tt = Probe 'tooltip' @'
local p = game.player
local ok, r = pcall(function() return p:tooltip(p.x, p.y, p) end)
if not ok then return "ERR " .. tostring(r) end
return "tooltip=" .. type(r) .. (type(r) == "table" and (" len=" .. tostring(#r)) or "")
'@
    if ($tt.Status -eq 'OK' -and $tt.Result -match '^ERR') { Finding 'BROKEN' "Actor:tooltip superload: $($tt.Result)" }

    # ----------------------------------------------------------------------
    # Options tab: the GameOptions:tabs / :generateList hooks.
    # ----------------------------------------------------------------------
    Write-Host ''
    Write-Host 'Options tab'
    $op = Probe 'options' @'
local GO = require "mod.dialogs.GameOptions"
local d = GO.new()
game:registerDialog(d)
local found
for i, t in ipairs(d.c_tabs.tabs) do if tostring(t.title):find("SkooBot") then found = t.kind end end
if not found then game:unregisterDialog(d) return "ERR no SkooBot tab among " .. #d.c_tabs.tabs .. " tabs" end
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
        elseif ($op.Result -match 'options=6') { Finding 'OK' 'the [SkooBot] options tab lists its six settings' }
        else { Finding 'CHANGED' "options tab present but not six entries: $($op.Result)" }
    }

    # ----------------------------------------------------------------------
    # The menu, the talent dialog, and the picker that overflows (T-014).
    # Driven through the real dialogs, by the same calls the keys make.
    # ----------------------------------------------------------------------
    Write-Host ''
    Write-Host 'Menu and talent dialog'
    $null = Probe 'menu-key' 'return bridge.key("SKOOBOT_MENU") .. " -> " .. bridge.dialogs()'
    $u2 = Probe 'menu-use' @'
local d = game.dialogs[#game.dialogs]
if not d or tostring(d.title) ~= "SkooBot Menu" then return "ERR top dialog is " .. bridge.dialogs() end
d:use(d.list[1])
local t = game.dialogs[#game.dialogs]
return "opened '" .. tostring(t and t.title) .. "' entries=" .. tostring(t and t.list and #t.list) .. " h=" .. tostring(t and t.h) .. " game.h=" .. tostring(game.h)
'@
    $u3 = Probe 'picker' @'
local t = game.dialogs[#game.dialogs]
if not t or not t.list then return "ERR no talent dialog: " .. bridge.dialogs() end
t:use(t.list[#t.list])
local p = game.dialogs[#game.dialogs]
if not p or not p.list then return "ERR picker did not open: " .. bridge.dialogs() end
return ("title='%s' items=%d h=%d game.h=%d overflow=%s"):format(tostring(p.title), #p.list, p.h, game.h, tostring(p.h > game.h))
'@
    if ($u3.Status -eq 'OK' -and $u3.Result -match 'overflow=true') { Finding 'DEFECT' "T-014 reproduced: $($u3.Result)" }
    elseif ($u3.Status -eq 'OK' -and $u3.Result -match 'overflow=false') { Finding 'INFO' "picker fits at this size: $($u3.Result)" }
    $u4 = Probe 'pick' @'
local p = game.dialogs[#game.dialogs]
local name = tostring(p.list[1].name)
p:use(p.list[1])
local u = game.dialogs[#game.dialogs]
return "picked '" .. name .. "' -> '" .. tostring(u and u.title) .. "'"
'@
    $u5 = Probe 'usetype' @'
local u = game.dialogs[#game.dialogs]
u:use(u.list[1])
local q = game.dialogs[#game.dialogs]
return "-> '" .. tostring(q and q.title) .. "' class=" .. tostring(q and q.__CLASSNAME)
'@
    $u6 = Probe 'priority' @'
local q = game.dialogs[#game.dialogs]
if not q or not q.okclick then return "ERR expected GetQuantity, got " .. bridge.dialogs() end
q:okclick()
local t = game.dialogs[#game.dialogs]
local cfg = game.player.skoobotautotalents or {}
local first = cfg[1] and (tostring(cfg[1].tid) .. "/" .. tostring(cfg[1].usetype) .. "/" .. tostring(cfg[1].priority)) or "none"
return "top='" .. tostring(t and t.title) .. "' configured=" .. #cfg .. " first=" .. first .. " entries=" .. tostring(t and t.list and #t.list)
'@
    if ($u6.Status -eq 'OK' -and $u6.Result -match 'configured=1 first=T_\w+/Combat/1') { Finding 'OK' 'the add-talent flow stores tid/usetype/priority' }
    elseif ($u6.Status -eq 'OK') { Finding 'CHANGED' "add-talent flow ended oddly: $($u6.Result)" }
    $null = Probe 'close' @'
while #game.dialogs > 0 do game:unregisterDialog(game.dialogs[#game.dialogs]) end
return "dialogs=" .. bridge.dialogs()
'@
    $null = Probe 'menu-key2' 'return bridge.key("SKOOBOT_MENU") .. " -> " .. bridge.dialogs()'
    $s2 = Probe 'stop-menu' @'
local d = game.dialogs[#game.dialogs]
if not d or tostring(d.title) ~= "SkooBot Menu" then return "ERR top dialog is " .. bridge.dialogs() end
d:use(d.list[2])
local p = game.dialogs[#game.dialogs]
if not p or not p.list then return "ERR condition picker did not open: " .. bridge.dialogs() end
local r = ("title='%s' items=%d h=%d game.h=%d overflow=%s"):format(tostring(p.title), #p.list, p.h, game.h, tostring(p.h > game.h))
p:use(p.list[1])
local q = game.dialogs[#game.dialogs]
q:use(q.list[3])
local c = game.player:getStopCondition("DEBUFF_STUNNED")
return r .. " ; DEBUFF_STUNNED -> " .. tostring(c and c.stoptype)
'@
    if ($s2.Status -eq 'OK' -and $s2.Result -match 'DEBUFF_STUNNED -> STOP') { Finding 'OK' 'stop-condition menu round trip changes the policy' }
    if ($s2.Status -eq 'OK' -and $s2.Result -match 'overflow=true') { Finding 'DEFECT' "condition picker overflows too: $($s2.Result)" }
    $null = Probe 'close2' @'
while #game.dialogs > 0 do game:unregisterDialog(game.dialogs[#game.dialogs]) end
game.player:setStopCondition("DEBUFF_STUNNED", "WARN")
return "dialogs=" .. bridge.dialogs()
'@

    # ----------------------------------------------------------------------
    # Acting. A quiet spot first: query, run-once, then a full toggle.
    # Progress is measured in game.turn; wall-clock is only a deadline.
    # ----------------------------------------------------------------------
    Write-Host ''
    Write-Host 'Acting (quiet)'
    $q = Probe 'quiet' 'return "hostiles=" .. tostring(bl.find(0)) .. " " .. bl.status()' 120
    if ($q.Status -ne 'OK' -or $q.Result -notmatch 'hostiles=0 ') {
        Finding 'INFO' 'could not find a quiet spot; acting results below are in company'
    }
    $null = Probe 'query' 'local r = bridge.key("ASK_SKOOBOT") return r .. " | " .. bl.lastlog(3)'
    $null = Probe 'runonce' 'local r = bridge.key("SKOOBOT_RUNONCE") return r .. " | " .. bl.status() .. " | " .. bl.lastlog(2)'
    Start-Sleep -Seconds 3
    $null = Probe 'after-once' 'return bl.status() .. " | " .. bl.lastlog(2)'

    function Watch($label, $deadlineSec) {
        $t0 = Invoke-Bridge -Lua 'return tostring(game.turn)' -TimeoutSec 30
        $before = if ($t0.Status -eq 'OK') { [int]($t0.Result -replace '[^\d\-].*$', '') } else { -1 }
        # A dialog on screen owns Key.current, so a virtual key fired at it is
        # swallowed and the bot never starts -- and v1 itself refuses to start
        # while any dialog is open. Clear the deck, then watch whether the KEY
        # path works; if it does not, start directly so the bot is still measured.
        $null = Probe "$label-clear" 'while #game.dialogs > 0 do game:unregisterDialog(game.dialogs[#game.dialogs]) end return "dialogs=" .. bridge.dialogs() .. " focus_is_map=" .. tostring(require("engine.Key").current == game.key)'
        $tg = Probe "$label-toggle" 'local r = bridge.key("TOGGLE_SKOOBOT") return r .. " | " .. bl.status()'
        if ($tg.Status -eq 'OK' -and $tg.Result -notmatch 'active=true') {
            Finding 'BROKEN' "${label}: TOGGLE_SKOOBOT via the keybind did not activate the bot: $($tg.Result)"
            $tg = Probe "$label-direct" 'require("mod.class.Player").skoobot_start() return bl.status()'
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
        $null = Probe "$label-off" 'local r = bridge.key("DISABLE_SKOOBOT") return r .. " | " .. bl.status()'
        $adv = $turn - $before
        Finding 'INFO' ("{0}: game.turn advanced {1} ({2} -> {3}); handed back={4}; last: {5}" -f $label, $adv, $before, $turn, (-not $active), $last)
        if ($adv -le 0) { Finding 'BROKEN' "${label}: the bot did not advance the game at all" }
        if ($active) { Finding 'CHANGED' "${label}: still active at the deadline (no stop within ${deadlineSec}s)" }
    }
    Watch 'quiet' $ActDeadlineSec

    # ----------------------------------------------------------------------
    # In company: configure every usable activated talent as Combat the way
    # the UI would, find something hostile, and let the fight logic run.
    # ----------------------------------------------------------------------
    Write-Host ''
    Write-Host 'Acting (hostile in view)'
    $null = Probe 'talents' @'
local p = game.player
p.skoobotautotalents = {}
local n = 0
for tid, _ in pairs(p.talents) do
  local t = p:getTalentFromId(tid)
  if t and t.mode == "activated" and not t.no_npc_use and not t.no_dumb_use and t.hide ~= "always" then
    n = n + 1
    p.skoobotautotalents[#p.skoobotautotalents+1] = {tid=tid, usetype="Combat", priority=n}
  end
end
return "combat talents configured: " .. #p.skoobotautotalents
'@
    $h = Probe 'company' 'return "hostiles=" .. tostring(bl.find(1)) .. " " .. bl.status()' 120
    if ($h.Status -eq 'OK' -and $h.Result -match 'hostiles=0 ') {
        Finding 'INFO' 'could not find a hostile within 60 teleports; fight path not measured'
    } else {
        Watch 'fight' $ActDeadlineSec
    }

    # ----------------------------------------------------------------------
    # T-014 with a character that actually has talents. A level-1 character
    # owns about six, which fit; the report was from someone with enough to
    # overflow. Learn a few dozen (transient: the game is not saved after this)
    # and measure the picker again.
    # ----------------------------------------------------------------------
    Write-Host ''
    Write-Host 'Picker with many talents (T-014)'
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
local d = require("mod.dialogs.BotTalentDialog").new(p)
game:registerDialog(d)
d:use(d.list[#d.list])
local pk = game.dialogs[#game.dialogs]
local r = ("learned=%d title='%s' items=%d h=%d game.h=%d overflow=%s"):format(learned, tostring(pk.title), #pk.list, pk.h, game.h, tostring(pk.h > game.h))
while #game.dialogs > 0 do game:unregisterDialog(game.dialogs[#game.dialogs]) end
return r
'@ 90
    if ($many.Status -eq 'OK' -and $many.Result -match 'overflow=true') { Finding 'DEFECT' "T-014 reproduced: $($many.Result)" }
    elseif ($many.Status -eq 'OK') { Finding 'INFO' "picker still fits: $($many.Result)" }

    $exit = 0
}
finally {
    Stop-Game
    # Put the world back the way it was, whatever happened above.
    if (-not $KeepJunctions) {
        if ($null -ne (Get-JunctionTarget $V1Link)) { Remove-Junction $V1Link; Write-Host '[baseline-v1] removed junction tome-skoobot' }
    } else {
        Write-Host '[baseline-v1] KEPT junction tome-skoobot (-KeepJunctions)'
    }
    if ($null -ne $productWas -and $productWas -ne '<not-a-link>' -and $null -eq (Get-JunctionTarget $ProductLink)) {
        New-Item -ItemType Junction -Path $ProductLink -Target $productWas | Out-Null
        Write-Host "[baseline-v1] restored product junction -> $productWas"
    }
}

# --------------------------------------------------------------------------
# What the engine said. The log is truncated on the next launch, so archive
# it and pull out every Lua error with enough context to read.
# --------------------------------------------------------------------------
Write-Host ''
Write-Host 'Engine log'
Start-Sleep -Seconds 2
$archive = Join-Path $RepoRoot 'build\logs'
if (-not (Test-Path $archive)) { New-Item -ItemType Directory -Path $archive -Force | Out-Null }
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$dest = Join-Path $archive "baseline-v1-$stamp.txt"
Copy-Item $script:LogPath $dest -ErrorAction Ignore
$lines = @((Get-Content $script:LogPath -Raw -ErrorAction Ignore) -split "`r?`n")

$bound = @($lines | Where-Object { $_ -match "^Binding addon`tSkooBot`t" })   # the tab after the name: "SkooBot Devbridge" also starts with it
if ($bound.Count -gt 0) { Finding 'OK' "engine bound v1: $($bound[0])" } else { Finding 'BROKEN' 'no "Binding addon SkooBot" line in the log' }

$errIdx = @(); for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match 'Lua Error') { $errIdx += $i } }
if ($errIdx.Count -eq 0) { Finding 'OK' 'no Lua Error anywhere in the run' }
foreach ($i in $errIdx) {
    $ctx = @()
    for ($j = $i; $j -lt [math]::Min($i + 6, $lines.Count); $j++) { $ctx += $lines[$j].Trim() }
    Finding 'ERROR' ($ctx -join ' // ')
}
$acts = @($lines | Where-Object { $_ -match '^\[Skoobot\] \[Action\]' })
$states = @($lines | Where-Object { $_ -match '^\[Skoobot\] \[State\]' })
Finding 'INFO' "$($acts.Count) action line(s), $($states.Count) state line(s) from v1 in the log"
foreach ($a in ($acts | Select-Object -First 5)) { Write-Host "         $a" }
$interfere = @($lines | Where-Object { $_ -match '\[BRIDGE\] INTERFERE (key|mouse)|\[DO RESIZE\]' })
if ($interfere.Count -gt 0) { $script:Tainted = $true }
Write-Host "  log archived to $dest"

Write-Host ''
Write-Host '[baseline-v1] summary'
$script:Findings | Group-Object Kind | ForEach-Object { Write-Host ('  {0,-7} {1}' -f $_.Name, $_.Count) }
if ($script:Tainted) {
    Write-Host ''
    Write-Host '[baseline-v1] TAINTED - a human touched the machine during this run. Void; re-run.'
    exit 2
}
exit $exit
