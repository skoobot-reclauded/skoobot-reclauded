<#
    #54: the first-run and new-character walk, as a player would take it.

    Two audiences: someone new to SkooBot: Reclauded (from the original, or
    from other addons) and someone setting a fresh character up. This drives
    every flow such a player meets, through the real keys and dialogs, on the
    deterministic fixture (a Cornac Berserker with nothing configured), and
    writes down exactly what they see -- every NOTE line is evidence for
    docs/first-run.md -- while asserting the parts #54 fixed:

      1. the manifest, as the engine loads it: what the Addons list shows
         (long_name, versions), and a description that is true of 0.1 and
         leads with the one thing a player must know (enable it BEFORE
         creating the character);
      2. what the player sees at load: the engine-log ready line, and whether
         anything reached the message log;
      3. the first toggle with nothing configured, to its first stop, and the
         deterministic dead-end ("no Combat talent is configured") with its hint
         naming the live menu key and the loadout suggestion;
      4. the menu by key: the choices, the keybind status (#50), and the help
         text under them naming how to start and every bound key;
      5. the talent screen from scratch: the sections, the Available list, the
         suggest row with its count, the proposal and the Merge / Replace /
         Cancel wording;
      6. the stop-conditions dialogs: the labels and the WARN / STOP / IGNORE
         choice;
      7. the settings screen (#95): every row and its description, the
         per-character / account marking each one carries, and the range a
         numerical row opens with -- down to what a player typing 50 into it
         ends up with (#74). Then 7b: the game's own options tab, which is
         now a single row saying where the settings went;
      8. the first real stop with a suggested loadout applied: the notice
         line, the banner and the popup text;
      9. COEXISTENCE with the original SkooBot, only when game/addons/
         tome-skoobot exists (a copy of the original junctioned in, never the
         research archive): a save listing both, both menus on their own
         keys, the collision report, shared state, and no Lua error. Skipped,
         and said so, otherwise.

    Nothing is written to the fixture: the save name is re-pointed at a
    scratch name right after loading (the game autosaves on a zone change),
    settings are changed in memory only, and no save is made.

    Exit codes:  0 pass   1 fail   2 tainted   3 inconclusive

    Run:
        powershell -ExecutionPolicy Bypass -File .\tools\scenario-first-run.ps1
        powershell -ExecutionPolicy Bypass -File .\tools\scenario-first-run.ps1 -SaveName firstrun-archer
        powershell -ExecutionPolicy Bypass -File .\tools\scenario-first-run.ps1 -SkipFirstStop
        powershell -ExecutionPolicy Bypass -File .\tools\scenario-first-run.ps1 -CoexistenceOnly   (tome-skoobot junctioned)

    #54.
#>
[CmdletBinding()]
param(
    [string]$SaveName = 'fixture-berserker',
    # The save with both addons listed, for the coexistence part. Created
    # here if absent (minutes) -- only when the original is junctioned.
    [string]$CoexistSaveName = 'coexist',
    [string]$ScratchSave = 'firstrun-scratch',
    [int]$FirstStopDeadlineSec = 150,
    [switch]$SkipFirstStop,
    [switch]$SkipCoexistence,
    # Only part 9: the original is junctioned and part A already ran.
    [switch]$CoexistenceOnly
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'harness.ps1')

$RepoRoot = Split-Path -Parent $PSScriptRoot
if ($env:TOME_DIR) { $GameDir = $env:TOME_DIR } else { $GameDir = 'C:\games\TalesMajEyal' }
$V1Link = Join-Path $GameDir 'game\addons\tome-skoobot'

$script:Fail = @()
$script:Tainted = $false
function Check($ok, $what) {
    if ($ok) { Write-Host "  PASS  $what" } else { Write-Host "  FAIL  $what"; $script:Fail += $what }
}
# Evidence, not a verdict: what the player sees, verbatim, for the audit.
function Note($what) { Write-Host "  NOTE  $what" }
# A probe that errors or returns ERR makes the run inconclusive: the flow
# could not be reached, so nothing below says anything about the product.
function Probe($label, $lua, $timeout = 60) {
    $r = Invoke-Bridge -Lua $lua -TimeoutSec $timeout
    if ($r.Tainted) { $script:Tainted = $true }
    $txt = "$($r.Result)"
    Write-Host ('  {0,-11} {1,-8} {2}' -f $label, $r.Status, $txt)
    if ($r.Status -ne 'OK' -or $txt -match '^ERR') {
        Write-Host "[first-run] INCONCLUSIVE at '$label': $txt"
        Stop-Game
        exit 3
    }
    return $txt
}
function Archive-Log($suffix) {
    Start-Sleep -Seconds 1
    $archive = Join-Path $RepoRoot 'build\logs'
    if (-not (Test-Path $archive)) { New-Item -ItemType Directory -Path $archive -Force | Out-Null }
    $dest = Join-Path $archive ("first-run-$suffix-{0}.txt" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    Copy-Item $script:LogPath $dest -ErrorAction Ignore
    Write-Host "  log archived to $dest"
    return @((Get-Content $script:LogPath -Raw -ErrorAction Ignore) -split "`r?`n")
}

Write-Host ''
Write-Host '[first-run] the first-run and new-character walk (#54)'

# ---------------------------------------------------------------------------
# The manifest, statically: what te4.org and the Workshop show. The in-game
# Addons list shows only the name and the versions (boot/mod/dialogs/
# Addons.lua), so the description is read here and from the loaded manifest
# below, never from a screen.
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '  --- manifest (src/init.lua)'
$init = Get-Content (Join-Path $RepoRoot 'src\init.lua') -Raw
$desc = if ($init -match '(?s)description\s*=\s*\[\[(.*?)\]\]') { $Matches[1] } else { '' }
Check ($desc.Length -gt 0) 'init.lua carries a description'
Check ($desc -notmatch '(?i)status:\s*early|not yet feature-complete') 'the description no longer calls the addon early or incomplete'
Check ($desc -match 'ENABLE THIS ADDON BEFORE CREATING THE CHARACTER') 'the description says to enable the addon before creating the character'
$firstPara = ($desc -split "`r?`n")[0]
Check ($firstPara -match '(?i)rests, explores and fights') 'the first paragraph says what the addon does'
Check ($desc -match 'Shift\+F7' -and $desc -match 'Shift\+F3') 'the description names the default menu and toggle keys'
Check ($desc -match '(?i)original SkooBot' -and $desc -match '(?i)will not touch it') 'it still says the original is separate and untouched'
Check ($desc -match '(?i)offline' -and $desc -match '(?i)no language model') 'it still says the addon runs offline with no language model'
Note ("description: {0} characters, {1} paragraphs" -f $desc.Length, (($desc -split "`r?`n`r?`n").Count))

# ===========================================================================
# Part A: the fixture, nothing configured.
# ===========================================================================
if ($CoexistenceOnly) { Note "part A skipped (-CoexistenceOnly)" }
else {
try {
    $g = Load-Save -Name $SaveName
    if (-not $g.Ready) { Write-Host "[first-run] FAILED - could not load '$SaveName' ($($g.Reason))"; exit 1 }
    Check ($g.Addons -match 'skoobot_reclauded') 'the product is loaded'

    $null = Probe 'helpers' @"
_G.fr = {}
game.save_name = "$ScratchSave"
local b = skoobot_reclauded
fr.b = b
function fr.plain(s)
  if type(s) == "table" and s.toString then s = s:toString() end
  -- One bridge result is one log line: a newline inside it (the game's own
  -- date line carries one) would cut everything after it off.
  return (tostring(s):gsub("#[^#]*#", ""):gsub("\r?\n", " / "))
end
function fr.hostiles()
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
function fr.onChangeLevel()
  local p = game.player
  return game.level.map:checkEntity(p.x, p.y, engine.Map.TERRAIN, "change_level") ~= nil
end
function fr.findQuiet()
  local p = game.player
  for i = 1, 80 do
    if fr.hostiles() == 0 and not fr.onChangeLevel() then return true end
    p:teleportRandom(p.x, p.y, 60, 10)
  end
  return fr.hostiles() == 0 and not fr.onChangeLevel()
end
function fr.findHostile()
  local p = game.player
  for i = 1, 60 do
    if fr.hostiles() > 0 then return true end
    p:teleportRandom(p.x, p.y, 60, 10)
  end
  return fr.hostiles() > 0
end
-- The last n message-log lines, colour codes stripped, newest last.
function fr.lastlog(n)
  local ld = game.uiset and game.uiset.logdisplay
  if not ld or not ld.getLines then return "" end
  local out = {}
  for _, l in ipairs(ld:getLines(n or 3)) do
    local s = l
    if type(l) == "table" then s = l.str or l.msg or l[1] or l end
    out[#out+1] = fr.plain(s)
  end
  return table.concat(out, " || ")
end
-- Every message-log line that mentions SkooBot, among the last n.
function fr.skoobotlog(n)
  local ld = game.uiset and game.uiset.logdisplay
  if not ld or not ld.getLines then return "" end
  local out = {}
  for _, l in ipairs(ld:getLines(n or 40)) do
    local s = l
    if type(l) == "table" then s = l.str or l.msg or l[1] or l end
    s = fr.plain(s)
    if s:lower():find("skoobot", 1, true) then out[#out+1] = s end
  end
  return #out .. ": " .. table.concat(out, " || ")
end
function fr.closeAll()
  while #game.dialogs > 0 do game:unregisterDialog(game.dialogs[#game.dialogs]) end
end
function fr.press(sym, shift)
  local Key = require "engine.Key"
  local h = Key.current
  bridge.injecting = true
  local ok, err = pcall(h.receiveKey, h, Key[sym], false, shift or false, false, false, nil, false, sym)
  bridge.injecting = false
  if not ok then error(err) end
end
function fr.reset()
  local p = game.player
  b.stop("reset")
  b.data(p).autotalents = {}
  p.life = p.max_life
  b.active = false; b.do_nothing = false; b.state = 11; b.last_reason = nil   -- 11 = STATE_EXPLORE
  b.activation = nil; b.loop = nil; b.prevloop = nil
  game.bignews.saySimple = nil
end
function fr.status()
  return b.inspect() .. " dlg=" .. bridge.dialogs()
end
-- The default key for one of our actions, as a player reads it, whatever
-- the profile has remapped.
function fr.defaultKey(t)
  local KeyBind = require "engine.KeyBind"
  local keys = dofile("/data-skoobot_reclauded/keys.lua")
  local def = KeyBind.binds_def[t]
  local ks = def and def.default and def.default[1]
  local function symname(sym)
    local code = tonumber(sym) or KeyBind[sym]
    if not code or not core.key.symName then return nil end
    return core.key.symName(code)
  end
  return ks and keys.describe(ks, symname) or "?"
end
return "installed save_name=" .. tostring(game.save_name)
"@

    # ----- 1. the manifest as loaded -------------------------------------
    Write-Host ''
    Write-Host '  --- 1. the manifest as the engine loaded it'
    $man = Probe 'manifest' @'
local a = game.__mod_info and game.__mod_info.addons and game.__mod_info.addons.skoobot_reclauded
if not a then return "ERR no skoobot_reclauded in game.__mod_info.addons" end
local d = tostring(a.description or "")
local first = d:match("^([^\n]*)") or ""
return ("long_name=[%s] addon_version=%s game_version=%s source=%s early=%s enable=%s toggle=%s menu=%s first=[%s]"):format(
  tostring(a.long_name), tostring(a.addon_version_txt), tostring(a.version_txt),
  a.teaa and "archive" or "directory",
  tostring(d:lower():find("status: early", 1, true) ~= nil or d:lower():find("not yet feature", 1, true) ~= nil),
  tostring(d:find("ENABLE THIS ADDON BEFORE CREATING THE CHARACTER", 1, true) ~= nil),
  fr.defaultKey("TOGGLE_SKOOBOT_RECLAUDED"), fr.defaultKey("MENU_SKOOBOT_RECLAUDED"), first)
'@
    Check ($man -match 'long_name=\[SkooBot: Reclauded\]') 'the Addons list names it "SkooBot: Reclauded"'
    Check ($man -match 'addon_version=0\.1\.0 game_version=1\.7\.6') 'with addon version 0.1.0 for game 1.7.6'
    Check ($man -match 'early=false enable=true') 'the loaded description is the corrected one'
    if ($man -match 'toggle=(\S+) menu=(\S+)') {
        $tk, $mk = $Matches[1], $Matches[2]
        Check (($desc -match [regex]::Escape($tk)) -and ($desc -match [regex]::Escape($mk))) "the description's keys are the keybind file's defaults ($tk, $mk)"
    }
    Note "Addons list row: $man"

    # ----- 2. what the player sees at load ---------------------------------
    Write-Host ''
    Write-Host '  --- 2. at load'
    $ld = Probe 'load-msgs' 'return "message-log lines mentioning SkooBot = " .. fr.skoobotlog(60) .. " | collisions=" .. #fr.b.keybinds.collisions()'
    Note "at load: $ld"
    Check ($ld -match 'collisions=0') 'no keybind collision on this profile (the status line would say so)'

    $st0 = Probe 'untouched' @'
local p = game.player
local rm = fr.b.rules.module
local n = rm.count(fr.b.rules.get(p))
local conds = {}
for _, c in ipairs(fr.b.conditions.list()) do conds[#conds+1] = c.label .. "=" .. c.stoptype end
return ("rules=%d class=%s level=%d zone=%s | conditions: %s"):format(n, tostring(p.descriptor and p.descriptor.subclass),
  p.level, tostring(game.zone and game.zone.short_name), table.concat(conds, ", "))
'@
    Check ($st0 -match '^rules=0 ') 'the fixture has no talent rules (a fresh character)'
    Note "fresh character: $st0"

    # ----- 3. the first toggle, nothing configured -------------------------
    Write-Host ''
    Write-Host '  --- 3. first toggle with nothing configured'
    $q = Probe 'quiet' 'fr.reset() return "quiet=" .. tostring(fr.findQuiet()) .. " hostiles=" .. fr.hostiles()' 120
    if ($q -notmatch 'quiet=true') { Write-Host "[first-run] INCONCLUSIVE - no quiet spot: $q"; Stop-Game; exit 3 }
    $t0 = Probe 'toggle' @'
fr.closeAll()
local before = game.turn
local r = bridge.key("TOGGLE_SKOOBOT_RECLAUDED")
return ("%s | turn0=%d | %s | log: %s"):format(r, before, fr.status(), fr.lastlog(2))
'@
    Note "first toggle: $t0"
    $deadline = (Get-Date).AddSeconds($FirstStopDeadlineSec)
    $first = ''
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 3
        if (-not (Test-GameAlive)) { break }
        $s = Invoke-Bridge -Lua 'return fr.status() .. " | log: " .. fr.lastlog(2)' -TimeoutSec 30
        if ($s.Status -ne 'OK') { continue }
        if ($s.Tainted) { $script:Tainted = $true }
        $first = $s.Result
        if ($s.Result -match 'active=false') { break }
    }
    Write-Host "  poll        $first"
    $null = Probe 'off' 'bridge.key("STOP_SKOOBOT_RECLAUDED") return fr.status()'
    if ($first -match 'active=false') {
        Check ($first -match 'reason=(Stopped|Handed back|Cannot act): ') 'the bot handed back with a labelled reason'
        Check ($first -match '\[SkooBot\] ') 'the reason reached the message log under the [SkooBot] prefix'
        Note "first stop, nothing configured: $first"

        # #96: the first toggle of a fresh installation is the one moment
        # this addon cannot do anything at all, and describing the way out is
        # not offering it -- the audit measured six keypresses from that
        # message to a working bot. Checked HERE, on the real toggle, rather
        # than in query mode: Ask answers a question, it does not open things.
        if ($first -match 'reason=Cannot act: no Combat talent is configured') {
            $offer = Probe 'setup-offer' @'
local b = fr.b
local dlg = game.dialogs[#game.dialogs]
if not dlg then return "NODIALOG" end
local title, body, buttons = tostring(dlg.title or "?"), "", {}
for _, ui in ipairs(dlg.uis or {}) do
  local u = ui.ui
  if u and u.text then
    local t = fr.plain(tostring(u.text))
    if u.fct then buttons[#buttons+1] = t else body = body .. " " .. t end
  end
end
local never = tostring(b.data(game.player).nosetupprompt)
fr.closeAll()
return ("dialog=[%s] buttons=[%s] never=%s body=[%s] left_open=%d"):format(
  title, table.concat(buttons, " | "), never, (body:gsub("%s+", " ")), #game.dialogs)
'@
            if ($offer -eq 'NODIALOG') {
                Check $false 'the dead end offers a way out, not only a message'
            } else {
                Check ($offer -match 'dialog=\[SkooBot: Reclauded\]') 'the dead end opens a dialog of its own'
                Check ($offer -match 'Set up talents') 'with a button straight to the talent screen'
                Check ($offer -match 'Not now') 'a way to dismiss it for this session'
                Check ($offer -match 'Never ask') 'and a way to never see it again on this character'
                Check ($offer -match 'nothing to fight with') 'the body says what is wrong in one sentence'
                # Escape and dismissal must not be the same as "never": a
                # dialog that turns itself off when dismissed does it by
                # accident.
                Check ($offer -match 'never=nil') 'merely seeing it does not set the never-ask flag'
                Check ($offer -match 'left_open=0') 'and it closes cleanly, leaving nothing over the map'
                Note "setup offer: $offer"
            }
        } else {
            Note "the offer is not measured this run: the first stop was not the dead end"
        }
    } else {
        Note "still running at ${FirstStopDeadlineSec}s with nothing configured (resting/exploring, nothing met): $first"
    }

    $dead = Probe 'dead-end' @'
local p, b = game.player, fr.b
fr.reset()
if not fr.findHostile() then return "SETUP no hostile within 60 teleports" end
local saved = {}
for _, c in ipairs(b.conditions.list()) do saved[c.code] = c.stoptype b.conditions.set(c.code, "IGNORE") end
b.active = false b.state = 13 b.last_reason = nil   -- 13 = STATE_FIGHT
b.activation = nil b.loop = nil b.prevloop = nil
local before = game.turn
local banner
game.bignews.saySimple = function(self, time, txt, ...) banner = txt:format(...) end
b.query()
game.bignews.saySimple = nil
for code, st in pairs(saved) do b.conditions.set(code, st) end
return ("reason=[%s] dturn=%d banner=[%s] log: %s"):format(tostring(b.last_reason), game.turn - before, fr.plain(banner), fr.lastlog(2))
'@ 120
    if ($dead -match '^SETUP') {
        Note "dead-end not reached: $dead"
    } else {
        Check ($dead -match 'reason=\[Cannot act: no Combat talent is configured\]') 'with a hostile in view and nothing configured the bot says exactly that, without offering cooldown as an alternative'
        Check ($dead -match 'set talent usage in the SkooBot: Reclauded menu, \S+, or let the bot suggest a loadout from the talent screen') 'the hint names the menu key and the loadout suggestion'
        Check ($dead -match 'dturn=0 ') 'query advances no game turn'
        Note "dead-end, verbatim: $dead"
    }

    # ----- 4. the menu ------------------------------------------------------
    Write-Host ''
    Write-Host '  --- 4. the menu, by key'
    $menu = Probe 'menu' @'
fr.closeAll()
local r = bridge.key("MENU_SKOOBOT_RECLAUDED")
local m = game.dialogs[#game.dialogs]
if not m or tostring(m.title) ~= "SkooBot: Reclauded" then return "ERR menu not on top after " .. r .. ": " .. bridge.dialogs() end
local rows = {}
for _, it in ipairs(m.list) do rows[#rows+1] = (fr.plain(it.name):gsub("^%s+", "")) end
local help = ""
for _, u in ipairs(m.uis or {}) do
  if u.ui and u.ui.text and u.ui ~= m.list then help = fr.plain(u.ui.text) end
end
local toggle, menukey = fr.b.keyFor("TOGGLE_SKOOBOT_RECLAUDED"), fr.b.keyFor("MENU_SKOOBOT_RECLAUDED")
fr.menu = m
return ("title=[%s] rows=[%s] w=%d h=%d game=%dx%d help_has_toggle=%s help_has_menu=%s help=[%s]"):format(
  tostring(m.title), table.concat(rows, " | "), m.w, m.h, game.w, game.h,
  tostring(help:find(toggle, 1, true) ~= nil), tostring(help:find(menukey, 1, true) ~= nil), help)
'@
    Check ($menu -match 'rows=\[a\) Talent rules -- which talents the bot may use \| b\) Stop conditions -- when it hands back \| c\) Settings -- thresholds, delay, popup, logging \| d\) Cancel \| Keybinds: OK\]') 'the menu lists its four choices and the keybind status (#95 added Settings)'
    Check ($menu -match 'help=\[How to start: ') 'the help text under the choices starts with how to start'
    Check ($menu -match 'help_has_toggle=true help_has_menu=true') 'the help text names the bound toggle and menu keys'
    Check ($menu -match 'Keys: ') 'the help text lists the keys'
    # #95: the thresholds are no longer under Escape > Options, so the help
    # must point at the Settings row instead. Pointing at the old place would
    # be worse than saying nothing.
    Check ($menu -match 'Escape > Key Bindings') 'the help text says where the keys are changed'
    Check ($menu -match 'thresholds and the rest are under Settings') 'and that the settings are on the menu''s own row'
    Check ($menu -notmatch 'Escape > Options') 'and does not send the player to the options tab any more'
    if ($menu -match 'w=(\d+) h=(\d+) game=(\d+)x(\d+)') { Check (([int]$Matches[1] -le [int]$Matches[3]) -and ([int]$Matches[2] -le [int]$Matches[4])) "the menu fits the screen ($($Matches[1])x$($Matches[2]) in $($Matches[3])x$($Matches[4]))" }
    Note "menu: $menu"

    # ----- 5. the talent screen from scratch -------------------------------
    Write-Host ''
    Write-Host '  --- 5. the talent screen from scratch'
    $ts = Probe 'screen' @'
local m = fr.menu
m:use(m.list[1])
local d = game.dialogs[#game.dialogs]
if not d or not d.c_list then return "ERR the talent screen did not open: " .. bridge.dialogs() end
fr.d = d
local headers, avail = {}, 0
for _, it in ipairs(d.c_list.list) do
  if it.nodes then headers[#headers+1] = fr.plain(it.name) .. "(" .. #it.nodes .. ")"
  elseif it.entry and not it.section then avail = avail + 1 end
end
local first = d.c_list.list[1]
return ("title=[%s] first=[%s] headers=[%s] available=%d h=%d game.h=%d"):format(tostring(d.title),
  fr.plain(first and first.cname or first and first.name), table.concat(headers, " | "), avail, d.h, game.h)
'@
    Check ($ts -match 'title=\[SkooBot: Reclauded - talent rules\]') 'choice a) opens the talent rules screen'
    Check ($ts -match 'first=\[\d+ unassigned -- suggest a loadout\?\]') 'the first row offers a suggested loadout with the unassigned count'
    Check ($ts -match 'headers=\[1\. Combat\(0\) \| 2\. Damage Prevention\(0\) \| 3\. Recovery\(0\) \| 4\. Sustain\(0\) \| Available\(\d+\)\]') 'the four sections are empty and Available follows'
    Note "talent screen: $ts"

    $prop = Probe 'proposal' @'
local d = fr.d
d:use(d.c_list.list[1], "left")
if not d.proposal then return "ERR the suggest row did not open a proposal" end
local P = d.proposal
fr.P = P
local headers = {}
for _, it in ipairs(d.c_list.list) do if it.nodes then headers[#headers+1] = fr.plain(it.name) .. "(" .. #it.nodes .. ")" end end
local rows = {}
for _, e in ipairs(P.entries) do rows[#rows+1] = e.section .. ":" .. tostring(e.tid) end
local first = d.c_list.list[1]
-- #85: the right-hand guide, which should now be about the PROPOSAL and
-- not the editing tutorial. Colour codes are stripped, so a code still
-- sitting in a row's label as literal text would show up here too.
local guide = fr.plain(d.c_tut and d.c_tut.text or ""):gsub("%s+", " ")
return ("entries=%d unassigned=%d skipped=%d choices=%d headers=[%s] first=[%s] intro=[%s] guide=[%s] rows=[%s]"):format(
  P.counts.entries, P.counts.unassigned, P.counts.skipped, P.counts.choices, table.concat(headers, " | "),
  fr.plain(first and first.name), fr.plain(d.c_desc and d.c_desc.cur_item == d.status_key and "(intro)" or "?"),
  guide, table.concat(rows, ","))
'@
    Check ($prop -match 'entries=[1-9]') 'the suggestion proposes at least one rule for a fresh character'
    # #85: the row is SHORT -- this column is half of half the dialog, and
    # a warning clipped to "PREVIEW -- nothing is written yet. App" at 1440p
    # is a warning nobody reads. The preview state is said in the guide
    # panel, checked below, which has the room for it.
    Check ($prop -match 'first=\[Apply or cancel\.\.\.  \(Enter\)\]') 'the proposal view leads with a short apply row'
    Check ($prop -match 'guide=\[.*PREVIEW -- nothing has been written yet') 'the guide panel says it is a preview, where there is room to read it'
    Check ($prop -match 'guide=\[.*\(new\) is a row Merge would add') 'and explains what the row marks mean'
    Check ($prop -notmatch 'guide=\[.*Drag from Available') 'the editing tutorial is not left standing in the proposal view'
    Note "proposal: $prop"

    $am = Probe 'apply-menu' @'
local d = fr.d
fr.press("_RETURN")
local m = game.dialogs[#game.dialogs]
if not m or m == d or not m.list then return "ERR no apply menu: " .. bridge.dialogs() end
local names = {}
for _, it in ipairs(m.list) do names[#names+1] = fr.plain(it.name) end
local cancel
for _, it in ipairs(m.list) do if fr.plain(it.name):find("Cancel", 1, true) then cancel = it end end
local title = tostring(m.title)
if cancel then m:use(cancel) end
local top = game.dialogs[#game.dialogs]
return ("title=[%s] names=[%s] back_on_screen=%s proposal_still=%s"):format(title, table.concat(names, " | "),
  tostring(top == d), tostring(d.proposal ~= nil))
'@
    # #85: Merge says what it would REMOVE as well as what it would add --
    # a suggestion that drops a talent used to look like one that changed
    # nothing.
    Check ($am -match 'title=\[Apply the suggested loadout\] names=\[a\) Merge: add \d+ new, remove \d+, keep every row you placed \| b\) Replace: clear the 0 current rows, write the \d+ suggested \| c\) Cancel: write nothing\]') 'Enter offers Merge, Replace and Cancel, each saying what it writes and what it takes away'
    Check ($am -match 'back_on_screen=true proposal_still=true') 'Cancel returns to the proposal, still unwritten'
    Note "apply menu: $am"

    $merge = Probe 'merge' @'
local d = fr.d
fr.press("_RETURN")
local m = game.dialogs[#game.dialogs]
if not m or m == d or not m.list then return "ERR no apply menu: " .. bridge.dialogs() end
m:use(m.list[1])   -- Merge
local rm = fr.b.rules.module
local r = fr.b.rules.get(game.player)
local per = {}
for _, s in ipairs(rm.SECTIONS) do per[#per+1] = s .. "=" .. #r[s] end
local said = d.c_desc and d.c_desc.cur_item == d.status_key
local first = d.c_list.list[1]
local out = ("proposal=%s count=%d per=[%s] first=[%s] said=%s"):format(tostring(d.proposal ~= nil), rm.count(r),
  table.concat(per, " "), fr.plain(first and first.cname or first and first.name), tostring(said))
fr.closeAll()
return out
'@
    Check ($merge -match 'proposal=false count=[1-9]') 'Merge writes the suggestion and returns to the rules view'
    Note "after Merge: $merge"

    # ----- 6. the stop conditions dialog -----------------------------------
    Write-Host ''
    Write-Host '  --- 6. the stop-conditions dialogs'
    $sc = Probe 'conditions' @'
fr.closeAll()
bridge.key("MENU_SKOOBOT_RECLAUDED")
local m = game.dialogs[#game.dialogs]
if not m or tostring(m.title) ~= "SkooBot: Reclauded" then return "ERR no menu: " .. bridge.dialogs() end
m:use(m.list[2])
local p = game.dialogs[#game.dialogs]
if not p or not p.list or p == m then return "ERR the condition picker did not open: " .. bridge.dialogs() end
local items = {}
for _, it in ipairs(p.list) do items[#items+1] = fr.plain(it.name) end
local t1 = tostring(p.title)
p:use(p.list[1])
local q = game.dialogs[#game.dialogs]
if not q or not q.list or q == p then return "ERR the policy picker did not open: " .. bridge.dialogs() end
local opts = {}
for _, it in ipairs(q.list) do opts[#opts+1] = fr.plain(it.name) end
local t2 = tostring(q.title)
q:use(q.list[2])   -- WARN, the default for the first entry
local c = fr.b.conditions.get("DEBUFF_STUNNED")
local out = ("picker=[%s] items=%d [%s] | policy=[%s] options=[%s] | after=%s top=%s"):format(t1, #items,
  table.concat(items, " | "), t2, table.concat(opts, " | "), tostring(c and c.stoptype), bridge.dialogs())
fr.closeAll()
return out
'@
    Check ($sc -match 'picker=\[Stop conditions: pick one to change\] items=15 ') 'choice b) lists the fifteen conditions'
    Check ($sc -match 'policy=\[Stunned -- what should the bot do\?\] options=\[a\) IGNORE -- never stop for this \| b\) WARN -- stop once, then carry on if restarted \| c\) STOP -- stop every time it applies\]') 'picking one names it and explains IGNORE, WARN and STOP'
    Check ($sc -match 'after=WARN top=none') 'the choice is applied and every dialog closes'
    Note "stop conditions: $sc"

    # ----- 7. the settings screen, and the pointer left behind (#95) --------
    #
    # This part used to audit the game's Options tab, which held eleven
    # numeric entries, a toggle and the log level. #95 moved all of it to a
    # screen of the addon's own, so the audit moves with it -- the questions
    # are the same ones, and they are the questions that matter about any
    # screen a player reads: does every row explain itself, does anything
    # shout, and does a description fit the pane it is drawn in.
    Write-Host ''
    Write-Host '  --- 7. the settings screen'
    $st = Probe 'settings-screen' @'
local SD = require "mod.dialogs.skoobot_reclauded.SettingsDialog"
local d = SD.new()
game:registerDialog(d)
local out, empty, shouting = {}, 0, 0
for _, it in ipairs(d.list or {}) do
  local title = fr.plain(it.name)
  local desc = tostring(it.desc or ""):gsub("%s+", " ")
  if desc == "" then empty = empty + 1 end
  if desc:find("%u%u%u%u%u%u") then shouting = shouting + 1 end
  out[#out+1] = title .. " :: " .. desc
end
local rows = #(d.list or {})
-- The description pane is a TextzoneList WITH a scrollbar, so a long
-- description scrolls rather than being silently cut (the trap the options
-- tab had). Prove the scrollbar is really there rather than assuming it.
local bar = d.c_desc and d.c_desc.scrollbar and true or false
game:unregisterDialog(d)
return ("rows=%d empty=%d shouting=%d scrollbar=%s ;; %s"):format(
  rows, empty, shouting, tostring(bar), table.concat(out, " ;; "))
'@
    Check ($st -match 'rows=14 ') 'the screen lists all twelve options and the two actions'
    Check ($st -match 'empty=0 ') 'every row explains itself'
    Check ($st -match 'shouting=0 ') 'no description shouts in capitals'
    Check ($st -match 'scrollbar=true') 'the description pane scrolls, so nothing is silently clipped'

    # The split is the point of the screen, so it must be legible ON the rows
    # rather than only in the help text.
    Check ($st -match 'Maximum Enemy Power: \d+\s+\(default\)') 'a threshold the character has not touched reads as the default'
    Check ($st -match 'Popup when the bot stops: (yes|no)\s+\(all characters\)') 'an account preference says it applies to every character'
    Check ($st -match 'Save this character.s thresholds as the default for future characters') 'the save-as-default action is offered, in the owner''s words'
    Check ($st -match 'Clear this character.s own thresholds') 'and the way back to the defaults'

    # The wording work from #54, #82 and #91 came with the descriptions and
    # must not have been dropped in the move.
    Check ($st -match 'Power level is the addon.s rough threat score') 'power level is still explained in one clause'
    Check ($st -match 'These five limits are also a scale') 'the threat scale is still explained once'
    Check ($st -match 'Low Health Ratio: [\d.]+.*:: A fraction of your life pool') 'the life ratios still say they are fractions of the life pool (#91)'
    Check ($st -notmatch 'Max enemy power level|Maximum Individual Enemy Power') 'the two titles that read backwards are still gone'
    foreach ($line in ($st -split ' ;; ' | Select-Object -Skip 1)) { Note "setting: $line" }

    # The options tab keeps ONE row, and its job is to say where to go. An
    # addon with no presence in Options is one a player concludes has no
    # settings, which is why the row exists at all.
    Write-Host ''
    Write-Host '  --- 7b. the options tab is a pointer'
    $op = Probe 'options' @'
local GO = require "mod.dialogs.GameOptions"
local d = GO.new()
game:registerDialog(d)
local found
for _, t in ipairs(d.c_tabs.tabs) do if tostring(t.title):find("Reclauded") then found = t.title end end
if not found then game:unregisterDialog(d) return "ERR no SkooBot: Reclauded tab" end
for _, t in ipairs(d.c_tabs.tabs) do if t.title == found then d:switchTo(t.kind) end end
local out = {}
for _, it in ipairs(d.list or {}) do
  local zone = it.zone and fr.plain(it.zone.text) or ""
  zone = zone:gsub("^SkooBot: Reclauded[%s/]*", ""):gsub("%s+", " ")
  out[#out+1] = fr.plain(it.name) .. " :: " .. zone
end
game:unregisterDialog(d)
return ("tab=[%s] entries=%d ;; %s"):format(found, #out, table.concat(out, " ;; "))
'@
    Check ($op -match 'tab=\[\[SkooBot: Reclauded\]\] entries=1 ') 'the tab is one row now, not thirteen'
    Check ($op -match 'Settings are in the SkooBot menu') 'and it says where the settings went'
    Check ($op -match 'belong to the character you are playing') 'it explains why they are not here'
    Note "options tab: $op"

    # #74's finding, re-asked of the new screen: the range a numerical row
    # opens with, and what a player typing "50" into it ends up with.
    # Reading the prompt is not enough -- the prompt was only ever cosmetic;
    # the bound is c_box.min / c_box.max, and the minimum is GetQuantity's
    # SIXTH argument, which is exactly the mistake that made every entry
    # 0..1000000 the first time.
    #
    # The engine clamps on ACCEPT, not while typing: __TEXTINPUT calls
    # updateText(nil, true) -- no_limits -- so the box holds 50 until Enter
    # calls updateText(0), which bounds it.
    $rg = Probe 'setting-ranges' @'
local SD = require "mod.dialogs.skoobot_reclauded.SettingsDialog"
local d = SD.new()
game:registerDialog(d)
local want = { "Low Health Ratio", "Ignore Damage Above Life Ratio",
               "Normal Enemy Power Ratio", "Maximum Enemy Power Above Yours", "Action Delay" }
local out = {}
for _, title in ipairs(want) do
  local item
  for _, it in ipairs(d.list or {}) do
    if not item and fr.plain(it.name):find(title, 1, true) then item = it end
  end
  if not item then
    out[#out+1] = title .. " MISSING"
  else
    d:use(item)
    local dlg = game.dialogs[#game.dialogs]
    local box = dlg and dlg.c_box
    if not box then
      out[#out+1] = title .. " NODIALOG"
    else
      local prompt = fr.plain(box.title or ""):gsub(":%s*$", "")
      -- Typing is not onTextInput here: the Numberbox holds its digits in
      -- `tmp` and updateText reads them. updateText(nil, true) is the
      -- no_limits form the engine uses WHILE typing; updateText(0) is what
      -- Enter calls, and is where the bound is applied.
      box.first = false
      box.tmp = { "5", "0" }
      box:updateText(nil, true)
      local typed = box.number
      box:updateText(0)
      out[#out+1] = ("%s min=%s max=%s prompt=[%s] typed=%s becomes=%s"):format(
        title, tostring(box.min), tostring(box.max), prompt, tostring(typed), tostring(box.number))
      game:unregisterDialog(dlg)
    end
  end
end
game:unregisterDialog(d)
return table.concat(out, " ;; ")
'@
    Check ($rg -notmatch 'MISSING|NODIALOG') 'every numerical row opens a quantity box'
    Check ($rg -match 'Low Health Ratio min=0 max=1 ') 'a life fraction is bounded 0 to 1, not 0 to a million'
    Check ($rg -match 'Low Health Ratio .*typed=50 becomes=1\b') 'and typing 50 into it lands on 1, not fifty times maximum life'
    Check ($rg -match 'Normal Enemy Power Ratio min=0 max=10 ') 'a rank ratio is bounded 0 to 10'
    Check ($rg -match 'Action Delay min=0 max=1000000 ') 'a setting with no range of its own keeps the default one'
    foreach ($line in ($rg -split ' ;; ')) { Note "range: $line" }
    # ----- 8. the first real stop ------------------------------------------
    Write-Host ''
    Write-Host '  --- 8. the first stop with the suggested loadout'
    if ($SkipFirstStop) {
        Note 'first stop skipped (-SkipFirstStop)'
    } else {
        $q2 = Probe 'quiet' @'
fr.closeAll()
local p, b = game.player, fr.b
b.stop("reset")
p.life = p.max_life
b.active = false; b.do_nothing = false; b.state = 11; b.last_reason = nil
b.activation = nil; b.loop = nil; b.prevloop = nil
local ok = fr.findQuiet()
fr.banner = nil
game.bignews.saySimple = function(self, time, txt, ...) fr.banner = txt:format(...) end
local s = config.settings.tome.skoobot_reclauded
fr.popupWas = s.STOP_POPUP
s.STOP_POPUP = true      -- in memory only; put back below
return "quiet=" .. tostring(ok) .. " hostiles=" .. fr.hostiles() .. " rules=" .. b.rules.module.count(b.rules.get(p))
'@ 120
        if ($q2 -notmatch 'quiet=true') { Write-Host "[first-run] INCONCLUSIVE - no quiet spot for the first stop: $q2"; Stop-Game; exit 3 }
        $t1 = Probe 'toggle' 'local before = game.turn local r = bridge.key("TOGGLE_SKOOBOT_RECLAUDED") return r .. " | turn0=" .. before .. " | " .. fr.status()'
        $deadline = (Get-Date).AddSeconds($FirstStopDeadlineSec)
        $stopped = ''
        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Seconds 3
            if (-not (Test-GameAlive)) { break }
            $s = Invoke-Bridge -Lua 'return fr.status()' -TimeoutSec 30
            if ($s.Status -ne 'OK') { continue }
            if ($s.Tainted) { $script:Tainted = $true }
            $stopped = $s.Result
            if ($s.Result -match 'active=false') { break }
        }
        Write-Host "  poll        $stopped"
        $fs = Probe 'first-stop' @'
local b = fr.b
local popup = "none"
local top = game.dialogs[#game.dialogs]
if top and tostring(top.title) == "SkooBot: Reclauded" and top.close then
  for _, u in ipairs(top.uis or {}) do if u.ui and u.ui.text and not u.ui.title then popup = fr.plain(u.ui.text) break end end
  top:close()
end
local wasActive = b.active
if b.active then b.stop("deadline", b.notice.HANDED_BACK, { banner = false }) end
game.bignews.saySimple = nil
config.settings.tome.skoobot_reclauded.STOP_POPUP = fr.popupWas
return ("active_at_deadline=%s reason=[%s] banner=[%s] popup=[%s] turn=%d actions=%s log: %s"):format(
  tostring(wasActive), tostring(b.last_reason), fr.plain(fr.banner), popup, game.turn, tostring(b.actions), fr.lastlog(3))
'@
        if ($fs -match 'active_at_deadline=false') {
            Check ($fs -match 'reason=\[(Stopped|Handed back|Cannot act): ') 'the first stop carries a labelled reason'
            Check ($fs -match 'banner=\[SkooBot (stopped|handed back|cannot act): ') 'the banner repeats it'
            Check ($fs -match '\[SkooBot\] (Stopped|Handed back|Cannot act): ') 'the message log carries it under the [SkooBot] prefix'
            if ($fs -match 'reason=\[Stopped: ') { Check ($fs -match 'popup=\[Stopped: ') 'a STOPPED notice opened the popup (setting on for this run)' }
        } else {
            Note "still running at ${FirstStopDeadlineSec}s (a long healthy session, not a hang)"
        }
        Note "first stop: $fs"
    }
}
finally {
    Stop-Game
}

Write-Host ''
Write-Host '  --- engine log (part A)'
$lines = Archive-Log 'fixture'
$ready = @($lines | Where-Object { $_ -match '^\[SKOOBOT\] ready; ' })
Check ($ready.Count -eq 1) 'one [SKOOBOT] ready line in the engine log'
foreach ($l in $ready) { Note "engine log: $l" }
$kbl = @($lines | Where-Object { $_ -match '^\[SKOOBOT\] \[Keybinds\] checked ' })
foreach ($l in $kbl) { Note "engine log: $l" }
$errs = @($lines | Where-Object { $_ -match 'Lua Error' })
Check ($errs.Count -eq 0) 'no Lua Error in the run'
foreach ($e in ($errs | Select-Object -First 5)) { Write-Host "         $e" }
}

# ===========================================================================
# Part B: coexistence with the original SkooBot, when it is installed.
# ===========================================================================
Write-Host ''
Write-Host '  --- 9. coexistence with the original SkooBot'
$v1 = Get-Item -LiteralPath $V1Link -Force -ErrorAction Ignore
if ($SkipCoexistence) {
    Note 'coexistence skipped (-SkipCoexistence)'
} elseif (-not $v1) {
    Note "coexistence skipped: the original is not installed (no $V1Link)"
} elseif (-not (Test-Path (Join-Path $V1Link 'init.lua'))) {
    Note "coexistence skipped: $V1Link has no init.lua"
} else {
    $v1Init = Get-Content (Join-Path $V1Link 'init.lua') -Raw
    if ($v1Init -notmatch 'short_name\s*=\s*"skoobot"') { Write-Host "[first-run] FAILED - $V1Link is not the original SkooBot"; exit 1 }
    $v1Version = if ($v1Init -match 'addon_version\s*=\s*\{([^}]*)\}') { ($Matches[1] -replace '\s','') -replace ',','.' } else { '?' }
    Note "original SkooBot $v1Version at $V1Link"

    # Both bots, and the bridge: the save has to list all three.
    $script:RequiredSaveAddons = @('skoobot', 'skoobot_reclauded', 'skoobot_devbridge')
    if ($null -eq (Get-SaveAddons -Name $CoexistSaveName)) {
        Write-Host "  no save '$CoexistSaveName'; creating one (this takes minutes)"
        & powershell -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'new-character.ps1') `
            -Name $CoexistSaveName -RequiredAddons skoobot,skoobot_reclauded,skoobot_devbridge
        if ($LASTEXITCODE -ne 0) { Write-Host "[first-run] FAILED - could not create save '$CoexistSaveName'"; exit 1 }
    }

    try {
        $g = Load-Save -Name $CoexistSaveName
        if (-not $g.Ready) { Write-Host "[first-run] FAILED - could not load '$CoexistSaveName' ($($g.Reason))"; exit 1 }
        Check ($g.AddonsIntact) 'no required addon dropped by the savefile rule'
        Check ($g.Addons -match '(^|,)skoobot(,|$)' -and $g.Addons -match 'skoobot_reclauded') "both addons are loaded ($($g.Addons))"

        $null = Probe 'helpers' @"
_G.fr = {}
game.save_name = "$ScratchSave"
function fr.plain(s)
  if type(s) == "table" and s.toString then s = s:toString() end
  -- One bridge result is one log line: a newline inside it (the game's own
  -- date line carries one) would cut everything after it off.
  return (tostring(s):gsub("#[^#]*#", ""):gsub("\r?\n", " / "))
end
function fr.lastlog(n)
  local ld = game.uiset and game.uiset.logdisplay
  if not ld or not ld.getLines then return "" end
  local out = {}
  for _, l in ipairs(ld:getLines(n or 3)) do
    local s = l
    if type(l) == "table" then s = l.str or l.msg or l[1] or l end
    out[#out+1] = fr.plain(s)
  end
  return table.concat(out, " || ")
end
function fr.closeAll()
  while #game.dialogs > 0 do game:unregisterDialog(game.dialogs[#game.dialogs]) end
end
return "installed"
"@
        $both = Probe 'surface' @'
local P = require "mod.class.Player"
local b = rawget(_G, "skoobot_reclauded")
local coll = b and b.keybinds and #b.keybinds.collisions() or -1
local out = {}
for _, c in ipairs(b and b.keybinds and b.keybinds.collisions() or {}) do out[#out+1] = c.text end
return ("v1: ai_active=%s skoobot_start=%s | ours: table=%s active=%s | collisions=%d [%s] | v1 fields on player: autotalents=%s stopconditions=%s | ours: %s"):format(
  tostring(P.ai_active), tostring(P.skoobot_start ~= nil), tostring(b ~= nil), tostring(b and b.active),
  coll, table.concat(out, " ; "),
  tostring(game.player.skoobotautotalents ~= nil), tostring(game.player.skoobotstopconditions ~= nil),
  tostring(game.player.skoobot_reclauded ~= nil))
'@
        Check ($both -match 'skoobot_start=true \| ours: table=true') 'both runtimes are present'
        Check ($both -match 'collisions=0 ') 'the two addons share no key (the collision check finds nothing)'
        Note "coexistence surface: $both"

        $m1 = Probe 'v1-menu' @'
fr.closeAll()
local r = bridge.key("SKOOBOT_MENU")
local d = game.dialogs[#game.dialogs]
local rows = {}
if d and d.list then for _, it in ipairs(d.list) do rows[#rows+1] = fr.plain(it.name) end end
local out = ("%s -> title=[%s] rows=[%s]"):format(r, tostring(d and d.title), table.concat(rows, " | "))
fr.closeAll()
return out
'@
        Check ($m1 -match 'title=\[SkooBot Menu\]') "the original's menu opens on the original's key"
        Note "v1 menu: $m1"
        $m2 = Probe 'our-menu' @'
fr.closeAll()
local r = bridge.key("MENU_SKOOBOT_RECLAUDED")
local d = game.dialogs[#game.dialogs]
local rows = {}
if d and d.list then for _, it in ipairs(d.list) do rows[#rows+1] = (fr.plain(it.name):gsub("^%s+", "")) end end
local out = ("%s -> title=[%s] rows=[%s]"):format(r, tostring(d and d.title), table.concat(rows, " | "))
fr.closeAll()
return out
'@
        Check ($m2 -match 'title=\[SkooBot: Reclauded\]') 'our menu opens on our key'
        Check ($m2 -match 'Keybinds: OK') 'our menu reports the keybinds OK beside the original'
        Note "our menu: $m2"

        $qq = Probe 'queries' @'
fr.closeAll()
local r1 = bridge.key("ASK_SKOOBOT")
local l1 = fr.lastlog(2)
local r2 = bridge.key("ASK_SKOOBOT_RECLAUDED")
local l2 = fr.lastlog(2)
local P = require "mod.class.Player"
local b = skoobot_reclauded
return ("v1 %s: %s || ours %s: %s | v1 active=%s ours active=%s"):format(r1, l1, r2, l2, tostring(P.ai_active), tostring(b.active))
'@
        Check ($qq -match 'v1 active=false ours active=false') 'a query on either leaves both inactive'
        Note "queries: $qq"

        $tt = Probe 'tooltip' @'
local p = game.player
local ok, r = pcall(function() return p:tooltip(p.x, p.y, p) end)
if not ok then return "ERR " .. tostring(r) end
local s = fr.plain(r)
local n = select(2, s:gsub("Power Level", ""))
return "power_level_lines=" .. n
'@
        Note "tooltip with both: $tt"
        $ss = Probe 'settings' @'
local a = config.settings.tome.SkooBot
local b = config.settings.tome.skoobot_reclauded
return ("v1 namespace=%s ours=%s | v1 LOWHEALTH=%s ours LOWHEALTH=%s"):format(tostring(a ~= nil), tostring(b ~= nil),
  tostring(a and a.LOWHEALTH_RATIO), tostring(b and b.LOWHEALTH_RATIO))
'@
        Check ($ss -match 'v1 namespace=true ours=true') 'each addon has its own settings namespace'
        Note "settings: $ss"
    }
    finally {
        Stop-Game
    }
    Write-Host ''
    Write-Host '  --- engine log (part B)'
    $lines = Archive-Log 'coexist'
    $bound = @($lines | Where-Object { $_ -match "^Binding addon`t(SkooBot|SkooBot: Reclauded)`t" })
    Check ($bound.Count -eq 2) "the engine bound both addons ($($bound.Count))"
    foreach ($l in $bound) { Note "engine log: $l" }
    $errs = @($lines | Where-Object { $_ -match 'Lua Error' })
    Check ($errs.Count -eq 0) 'no Lua Error with both addons loaded'
    foreach ($e in ($errs | Select-Object -First 5)) { Write-Host "         $e" }
}

Write-Host ''
if ($script:Tainted) { Write-Host '[first-run] TAINTED - void, re-run.'; exit 2 }
if ($script:Fail.Count -gt 0) {
    Write-Host "[first-run] FAILED - $($script:Fail.Count) check(s):"
    foreach ($f in $script:Fail) { Write-Host "                 $f" }
    exit 1
}
Write-Host '[first-run] PASS - the first-run flows read as they should, and what the player sees is recorded above'
exit 0
