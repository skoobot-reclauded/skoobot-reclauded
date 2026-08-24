<#
    #57 / #58: a stop is one notice, and a message names the key that is bound.

    #58: every stop used to reach the player as whatever string its call site
    chose -- eight spellings, two colours the game's own log uses for hits --
    so it scrolled past unnoticed. Now every stop goes through one call with a
    severity: a fixed "[SkooBot]" prefix and one colour per severity in the
    message log, the same text on the big-news banner, and (for STOPPED, when
    the STOP_POPUP setting is on) a popup whose checkbox turns itself off.
    skoobot_reclauded.last_reason keeps "<label>: <text>" for the harness.

    #57: the all-on-cooldown stop used to say "Shift+F7 by default" from a
    string literal. It now looks the menu binding up when the message is
    built, so a rebind shows.

    What this drives, through the bridge, on the harness character:
      1. keyFor() renders the default binding and an unknown action;
      2. a remap in KeyBind.binds_remap changes what keyFor() says;
      3. a STOPPED notice through the public API: reason, banner, log line,
         and no popup while the setting is off;
      4. the same with the setting on: the popup opens, ticking its box and
         closing turns the setting off;
      5. a HANDED_BACK notice never opens the popup, and banner=false mutes
         the banner;
      6. the real cooldown site, with a hostile spawned next to the character
         and no talents configured: the log line names the live menu key;
      7. the real pinned site: the log line ends with the restart key.

    Query mode throughout, so no game turn passes; everything spawned or
    applied is reverted, and the persisted STOP_POPUP value is put back.

    Exit codes:  0 pass   1 fail   2 tainted   3 inconclusive

    Run:
        powershell -ExecutionPolicy Bypass -File .\tools\scenario-stop-notices.ps1
#>
[CmdletBinding()]
param([string]$SaveName = 'harness')

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
    if ($r.Status -ne 'OK') { Write-Host "  bridge $($r.Status): $($r.Result)" }
    return $r
}

Write-Host ''
Write-Host '[stop-notices] one format for every stop; keys looked up live (#57, #58)'

try {
    $g = Load-Save -Name $SaveName
    if (-not $g.Ready) { Write-Host "[stop-notices] FAILED - could not load '$SaveName' ($($g.Reason))"; exit 1 }
    Check ($g.Addons -match 'skoobot_reclauded') 'the product is loaded'

    $install = Probe @'
_G.sn = {}
local KeyBind = require "engine.KeyBind"
local b = skoobot_reclauded
if not (b and b.notice and b.keyFor and b.setSetting) then return "OLD the loaded build predates #57/#58" end

function sn.lastlog(n)
  local ld = game.uiset and game.uiset.logdisplay
  if not ld or not ld.getLines then return "" end
  local out = {}
  for _, l in ipairs(ld:getLines(n or 4)) do
    local s = l
    if type(l) == "table" then s = l.str or l.msg or l[1] or l end
    if type(s) == "table" and s.toString then s = s:toString() end
    out[#out+1] = (tostring(s):gsub("#[^#]*#", ""))
  end
  return table.concat(out, " || ")
end

function sn.hostiles()
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
function sn.onChangeLevel()
  local p = game.player
  return game.level.map:checkEntity(p.x, p.y, engine.Map.TERRAIN, "change_level") ~= nil
end
function sn.findQuiet()
  local p = game.player
  for i = 1, 80 do
    if sn.hostiles() == 0 and not sn.onChangeLevel() then return true end
    p:teleportRandom(p.x, p.y, 60, 10)
  end
  return sn.hostiles() == 0 and not sn.onChangeLevel()
end

-- Put the bot in a known, inactive state with nothing configured.
function sn.reset()
  local p = game.player
  b.stop("reset")
  b.data(p).autotalents = {}
  p:removeEffect(p.EFF_PINNED, true, true)
  p.life = p.max_life
  b.active = false; b.do_nothing = false; b.state = 11; b.last_reason = nil   -- 11 = STATE_EXPLORE
  b.activation = nil; b.loop = nil; b.prevloop = nil
  game.bignews.saySimple = nil
end

-- Capture what the banner gets while fn runs (the method is shadowed on the
-- instance and removed again, so the class is untouched).
function sn.capture(fn)
  local banner
  game.bignews.saySimple = function(self, time, txt, ...) banner = txt:format(...) end
  local ok, err = pcall(fn)
  game.bignews.saySimple = nil
  if not ok then error(err) end
  return banner
end

-- A notice through the public API. Returns one line the scenario parses.
function sn.notify(severity, popup, opts)
  sn.reset()
  local s = config.settings.tome.skoobot_reclauded
  local before = s.STOP_POPUP
  s.STOP_POPUP = popup
  local ndialogs = #game.dialogs
  b.active = true
  local banner = sn.capture(function() b.stop("probe reason", severity, opts) end)
  local opened, after = "none", "n/a"
  if #game.dialogs > ndialogs then
    local top = game.dialogs[#game.dialogs]
    opened = tostring(top.title)
    top.suppress = true          -- as if the checkbox were ticked
    top:close()
    after = tostring(s.STOP_POPUP)
  end
  s.STOP_POPUP = before
  if after ~= "n/a" then b.setSetting("STOP_POPUP", before) end   -- put the persisted value back
  return "reason=" .. tostring(b.last_reason) .. " | banner=" .. tostring(banner)
      .. " | popup=" .. opened .. " | after=" .. after .. " | active=" .. tostring(b.active)
      .. " | log=" .. sn.lastlog(2)
end

-- The real all-on-cooldown site: a hostile next to us, nothing configured.
-- The power-level conditions are set to IGNORE for the probe (and put back)
-- so that whatever the zone spawns, the decision reaches the FIGHT branch.
local SCOUTERS = { "SCOUTER_BIGENEMY", "SCOUTER_STRONGERENEMY", "SCOUTER_CROWDPOWER", "SCOUTER_ENEMYCOUNT" }
function sn.cooldownSite()
  sn.reset()
  local p = game.player
  local m = game.zone:makeEntity(game.level, "actor",
    { special = function(e) return not e.unique and (e.rank or 1) <= 2 end }, nil, true)
  if not m then return "SETUP no actor to spawn" end
  _G.__sn_scouters = {}
  for _, code in ipairs(SCOUTERS) do
    _G.__sn_scouters[code] = b.conditions.get(code).stoptype
    b.conditions.set(code, "IGNORE")
  end
  local sx, sy
  for _, c in pairs(util.adjacentCoords(p.x, p.y)) do
    local x, y = c[1], c[2]
    if game.level.map:isBound(x, y) and not game.level.map:checkAllEntities(x, y, "block_move")
       and not game.level.map(x, y, engine.Map.ACTOR) then sx, sy = x, y break end
  end
  if not sx then return "SETUP no free adjacent tile" end
  game.zone:addEntity(game.level, m, "actor", sx, sy)
  _G.__sn_spawned = m
  p:playerFOV()
  if sn.hostiles() == 0 then sn.unspawn() return "SETUP the spawned actor is not a visible hostile" end
  local before = game.turn
  local banner = sn.capture(function() b.query() end)
  local out = "reason=" .. tostring(b.last_reason) .. " | banner=" .. tostring(banner)
      .. " | dturn=" .. tostring(game.turn - before) .. " | log=" .. sn.lastlog(2)
  sn.unspawn()
  return out
end
function sn.unspawn()
  local m = _G.__sn_spawned
  if m and m.x then game.level:removeEntity(m, true) end
  _G.__sn_spawned = nil
  for code, stoptype in pairs(_G.__sn_scouters or {}) do b.conditions.set(code, stoptype) end
  _G.__sn_scouters = nil
  game.player:playerFOV()
  return "removed"
end

-- The real pinned site (t012's), for the restart-key footer.
function sn.pinnedSite()
  sn.reset()
  local p = game.player
  p:setEffect(p.EFF_PINNED, 20, {})
  p:playerFOV()
  if not p:attr("never_move") then return "SETUP pin not applied (immune?)" end
  if sn.hostiles() ~= 0 then p:removeEffect(p.EFF_PINNED, true, true) return "SETUP a hostile is in view" end
  local before = game.turn
  local banner = sn.capture(function() b.query() end)
  p:removeEffect(p.EFF_PINNED, true, true)
  return "reason=" .. tostring(b.last_reason) .. " | banner=" .. tostring(banner)
      .. " | dturn=" .. tostring(game.turn - before) .. " | log=" .. sn.lastlog(2)
end

function sn.keys(remap)
  local before = KeyBind.binds_remap.MENU_SKOOBOT_RECLAUDED
  if remap == "set" then KeyBind.binds_remap.MENU_SKOOBOT_RECLAUDED = { "sym:_F9:true:false:false:false" } end
  if remap == "clear" then KeyBind.binds_remap.MENU_SKOOBOT_RECLAUDED = nil end
  return "menu=" .. b.keyFor("MENU_SKOOBOT_RECLAUDED") .. " | toggle=" .. b.keyFor("TOGGLE_SKOOBOT_RECLAUDED")
      .. " | none=" .. b.keyFor("NO_SUCH_ACTION_SKOOBOT") .. " | remapped=" .. tostring(before ~= nil)
end
return "installed"
'@
    if ($install.Result -match '^OLD') { Write-Host "[stop-notices] INCONCLUSIVE - $($install.Result)"; Stop-Game; exit 3 }
    Check ($install.Result -eq 'installed') 'probe helpers installed'

    if ((Probe 'return tostring(sn.findQuiet())' 120).Result -ne 'True') {
        Write-Host '[stop-notices] INCONCLUSIVE - no quiet spot to test from.'; Stop-Game; exit 3
    }

    # ----- 1, 2: keyFor ---------------------------------------------------
    Write-Host ''
    Write-Host '  --- keyFor: the bound key, rendered for a player'
    $k0 = Probe 'return sn.keys()'
    Write-Host "  $($k0.Result)"
    $menuKey = if ($k0.Result -match 'menu=([^|]+) \|') { $Matches[1].Trim() } else { '' }
    $toggleKey = if ($k0.Result -match 'toggle=([^|]+) \|') { $Matches[1].Trim() } else { '' }
    if ($k0.Result -match 'remapped=false') {
        Check ($menuKey -eq 'Shift+F7') 'default menu binding renders as Shift+F7 (the engine would say SF7)'
        Check ($toggleKey -eq 'Shift+F3') 'default toggle binding renders as Shift+F3'
    } else {
        Write-Host "  INFO  this profile remaps the menu key; accepting '$menuKey'"
        Check ($menuKey -ne '' -and $menuKey -ne 'unbound') 'a remapped menu binding renders'
    }
    Check ($k0.Result -match 'none=unbound') 'an action with no binding renders as "unbound"'

    $k1 = Probe 'return sn.keys("set")'
    Write-Host "  $($k1.Result)"
    Check ($k1.Result -match 'menu=Ctrl\+F9 \|') 'a remap to Ctrl+F9 is what the message now names'
    $k2 = if ($k0.Result -match 'remapped=false') { Probe 'return sn.keys("clear")' } else { Probe 'return sn.keys()' }
    Write-Host "  $($k2.Result)"
    Check ($k2.Result -match ('menu=' + [regex]::Escape($menuKey) + ' \|')) 'the remap is reverted'

    # ----- 3: STOPPED, popup off ----------------------------------------------
    Write-Host ''
    Write-Host '  --- a STOPPED notice with the popup off'
    $s3 = Probe 'return sn.notify(skoobot_reclauded.notice.STOPPED, false)'
    Write-Host "  $($s3.Result)"
    Check ($s3.Result -match 'reason=Stopped: probe reason \|') 'last_reason is "Stopped: <text>"'
    Check ($s3.Result -match 'banner=#LIGHT_RED#SkooBot stopped: probe reason \|') 'the banner got the coloured one-liner'
    Check ($s3.Result -match 'popup=none') 'no popup while STOP_POPUP is off'
    Check ($s3.Result -match 'active=false') 'the bot is stopped'
    Check ($s3.Result -match ('\[SkooBot\] Stopped: probe reason \(restart with ' + [regex]::Escape($toggleKey) + '\)')) 'the log line carries the prefix, the reason and the restart key'

    # ----- 4: STOPPED, popup on --------------------------------------------
    Write-Host ''
    Write-Host '  --- a STOPPED notice with the popup on: the popup opens, its checkbox turns it off'
    $s4 = Probe 'return sn.notify(skoobot_reclauded.notice.STOPPED, true)'
    Write-Host "  $($s4.Result)"
    Check ($s4.Result -match 'popup=SkooBot: Reclauded') 'the popup opened'
    Check ($s4.Result -match 'after=false') 'ticking the box and closing turned STOP_POPUP off'

    # ----- 5: HANDED_BACK, popup on; banner muted ---------------------------
    Write-Host ''
    Write-Host '  --- a HANDED_BACK notice: no popup even with the setting on; banner=false mutes the banner'
    $s5 = Probe 'return sn.notify(skoobot_reclauded.notice.HANDED_BACK, true)'
    Write-Host "  $($s5.Result)"
    Check ($s5.Result -match 'reason=Handed back: probe reason \|') 'last_reason is "Handed back: <text>"'
    Check ($s5.Result -match 'banner=#GOLD#SkooBot handed back: probe reason \|') 'gold banner for a hand-back'
    Check ($s5.Result -match 'popup=none') 'no popup for a hand-back'
    # The log window still holds the STOPPED probe's line above this one, so
    # the hint check is on the hand-back's own line: it is the newest, hence
    # last, and nothing may follow the reason on it.
    Check ($s5.Result -match '\[SkooBot\] Handed back: probe reason\s*$') 'the log line has the prefix and no restart hint'
    $s5b = Probe 'return sn.notify(skoobot_reclauded.notice.HANDED_BACK, false, { banner = false })'
    Write-Host "  $($s5b.Result)"
    Check ($s5b.Result -match 'banner=nil') 'banner=false (the player pressed stop) shows no banner'

    # ----- 6: the real dead-end site names the live menu key ----------------
    Write-Host ''
    Write-Host '  --- the real site: a hostile next to us and no talents configured'
    $s6 = Probe 'return sn.cooldownSite()' 60
    Write-Host "  $($s6.Result)"
    if ($s6.Result -match '^SETUP') {
        Write-Host "  INFO  inconclusive here ($($s6.Result)); the rendering is covered above"
    } else {
        Check ($s6.Result -match 'reason=Cannot act: no Combat talent is configured') 'the dead-end stop is a CANNOT_ACT notice, and names the case (#71)'
        # The key may be followed by more hint (#18 added a second clause), so
        # accept a comma or the closing bracket after it.
        Check ($s6.Result -match ('SkooBot: Reclauded menu, ' + [regex]::Escape($menuKey) + '[,)]')) 'the hint names the menu key that is bound (#57)'
        Check ($s6.Result -match 'banner=#ORANGE#SkooBot cannot act:') 'orange banner for cannot-act'
        Check ($s6.Result -match 'dturn=0') 'query advanced no game turn'
    }

    # ----- 7: the real pinned site ends with the restart key ----------------
    Write-Host ''
    Write-Host '  --- the real site: pinned, the footer names the restart key'
    $s7 = Probe 'return sn.pinnedSite()' 60
    Write-Host "  $($s7.Result)"
    if ($s7.Result -match '^SETUP') {
        Write-Host "  INFO  inconclusive here ($($s7.Result))"
    } else {
        Check ($s7.Result -match 'reason=Stopped: cannot move \(pinned, held, or overloaded\)') 'the pinned stop is a STOPPED notice (t012 still reads "cannot move")'
        Check ($s7.Result -match ('\(restart with ' + [regex]::Escape($toggleKey) + '\)')) 'the log line ends with the restart key'
        Check ($s7.Result -match 'dturn=0') 'query advanced no game turn'
    }
}
finally {
    $null = Invoke-Bridge -Lua 'if sn then sn.unspawn(); sn.reset() end return "clean"' -TimeoutSec 15 -ErrorAction SilentlyContinue
    Stop-Game
}

Write-Host ''
if ($script:Tainted) { Write-Host '[stop-notices] TAINTED - void, re-run.'; exit 2 }
if ($script:Fail.Count -gt 0) {
    Write-Host "[stop-notices] FAILED - $($script:Fail.Count) check(s):"
    foreach ($f in $script:Fail) { Write-Host "                 $f" }
    exit 1
}
Write-Host '[stop-notices] PASS - every stop is one notice, and messages name the bound key'
exit 0
