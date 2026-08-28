<#
    Create a ToME character with no human input, and save it.

    This is the harness bootstrap: every behaviour test starts from a save, and
    this makes the first one. By default race and class come from the
    Birther's own randomBirth(), so no descriptor knowledge is hardcoded here
    and nothing breaks when ToME adds a class. Only the name is forced, because
    the savefile directory is derived from it (mod/dialogs/Birther.lua:225) and
    the harness needs a predictable path.

    -Class and -Race make a FIXTURE instead (#27): a deterministic character
    that every scenario can reason about. Either takes a display name or a
    descriptor id -- "Berserker", "Cornac", "Warrior", "Human" -- and is
    resolved against the Birther's own race and class trees, then selected
    through the same raceUse()/classUse() a click goes through, so a locked or
    disallowed choice fails here instead of silently producing a different
    character. A top-level name (a race or a class) picks its first unlocked
    subrace or subclass. With -Class and no -Race the race is the Birther's
    own default, Human / Cornac (Birther:makeDefault, mod/dialogs/Birther.lua:398).

    The standing fixture is

        powershell -ExecutionPolicy Bypass -File .\tools\new-character.ps1 -Name fixture-berserker -Class Berserker

    a melee class with no ranged or marked-target talents, so a scenario that
    needs such a talent learns it explicitly and knows it is the only one.

    Run:  powershell -ExecutionPolicy Bypass -File .\tools\new-character.ps1 -Name harness

    The -ExecutionPolicy flag is not optional: every scope on this machine is
    Restricted, so a bare `powershell -File ...` fails before the script runs.

    Regenerate the save whenever the addon set changes. A save records the
    addons it was made with and the engine silently drops any it does not
    list, so a stale save quietly measures a game without the product (T-042).
#>
param(
    [string]$Name = 'harness',
    # A subclass ("Berserker") or class ("Warrior"), by display name or
    # descriptor id. Omitted: randomBirth(), as before.
    [string]$Class,
    # A subrace ("Cornac") or race ("Human"). Omitted with -Class: Human / Cornac.
    [string]$Race,
    [int]$BirthTimeoutSec = 900,
    # The addon short_names the save must record. Defaults to the product and
    # the devbridge (harness.ps1). The T-003 baseline runs the ORIGINAL SkooBot
    # instead of the product, and needs a save that records that.
    [string[]]$RequiredAddons
)

. (Join-Path $PSScriptRoot 'harness.ps1')
if ($RequiredAddons) {
    # `powershell -File` hands every argument over as a plain string, so a
    # [string[]] parameter given "a,b" arrives as ONE element containing a
    # comma. Split it here, or Assert-SaveAddons looks for an addon literally
    # named "skoobot,skoobot_devbridge" and fails a correct save.
    $script:RequiredSaveAddons = @($RequiredAddons | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Step($label, $lua, $timeout = 30) {
    $r = Invoke-Bridge -Lua $lua -TimeoutSec $timeout
    Write-Host ('{0,-10} {1,-8} {2}' -f $label, $r.Status, $r.Result)
    if ($r.Tainted) { Write-Host '           TAINTED - human input during this step' }
    return $r
}

$g = Start-Game -TimeoutSec 60
# Stop-Game, or the not-ready game outlives the report of its failure: five of
# slot8's leaked games in the first 8-slot run came through this exact exit,
# proven by their pids in the kept birth transcripts (#196).
if (-not $g.Ready) { Write-Host 'FAILED: no bridge at menu'; Stop-Game; exit 1 }

# Straight into a new tome game. Module:instanciate reboots the Lua state into
# the module -- the engine's own path, the same call the New Game menu makes.
$lua = @"
local Module = require "engine.Module"
local mod
for i, entry in ipairs(Module:listModules(true)) do
  for j, m in ipairs(entry.versions) do
    if m.short_name == "tome" and not m.is_boot and not mod then mod = m end
  end
end
if not mod then return "tome module not found" end
Module:instanciate(mod, "$Name", true, false)
return "starting"
"@
$null = Step 'newgame' $lua 25

$w = Wait-LogLine -Pattern '\[BRIDGE\] ready tier=tome' -TimeoutSec 180
if (-not $w.Matched) {
    Write-Host 'FAILED: tome-tier bridge never came up'
    Show-LoadDiagnostics -Seen $w.Seen
    Stop-Game; exit 1
}
Write-Host "tome tier  OK       $($w.Line)"

# The reboot reset the bridge's sequence gate; drop anything left over so the
# new tier cannot re-claim a command meant for the old one.
Clear-BridgeQueue
$probe = Invoke-Bridge -Lua 'return "pong"' -TimeoutSec 240
if ($probe.Status -ne 'OK') {
    Write-Host "FAILED: tome-tier pump never turned (status=$($probe.Status))"
    Show-LoadDiagnostics
    Stop-Game; exit 1
}

# The reason this script exists at all now: a save records the addons that
# were loaded when it was made, and the engine silently drops any addon a save
# does not list. If the product is not loaded here, the save written below
# would bake in its absence and every later behaviour run would measure a game
# without it -- passing, and meaning nothing (T-042).
$loaded = (Invoke-Bridge -Lua 'return bridge.addons()' -TimeoutSec 30).Result
Write-Host "addons     $loaded"
foreach ($need in $script:RequiredSaveAddons) {
    if ($loaded -notmatch [regex]::Escape($need)) {
        Write-Host "FAILED: '$need' is not loaded in this new game, so the save would"
        Write-Host '        record its absence. Run tools/setup-dev.ps1, and check the'
        Write-Host '        addon is not disabled in the game Addons menu.'
        Stop-Game; exit 1
    }
}
if (-not (Assert-NoAddonDropped -Seen $w.Seen)) { Stop-Game; exit 1 }

if ($Class) {
    # A fixture. The Birther's trees are what the mouse sees: all_races and
    # all_classes are lists of {id, name, nodes = { {id, pid, basename,
    # locked}, ... }} built by generateRaces/generateClasses, a leaf's id
    # being the descriptor name and its basename the display name. Selection
    # goes through raceUse()/classUse() -- what a click calls -- which set the
    # descriptors and regenerate what depends on them. Race first: raceUse()
    # rebuilds the class tree, which would drop a class chosen before it.
    $wantRace = if ($Race) { $Race } else { 'Cornac' }
    $roll = @"
local d = game.dialogs and game.dialogs[1]
if not d or d.__CLASSNAME ~= "mod.dialogs.Birther" then return "not at birther: " .. bridge.dialogs() end
local function plain(s)
  if type(s) == "table" and s.toString then s = s:toString() end
  return (tostring(s):gsub("#[^#]*#", "")):lower()
end
-- A leaf matching `want` by id or display name; or, for a top-level match,
-- its first unlocked leaf. Locked entries never match.
local function pick(tree, want)
  want = want:lower()
  for _, top in ipairs(tree) do
    if not top.locked and (plain(top.id) == want or plain(top.name) == want) then
      for _, n in ipairs(top.nodes or {}) do if not n.locked then return n end end
    end
    for _, n in ipairs(top.nodes or {}) do
      if not n.locked and (plain(n.id) == want or plain(n.basename or n.name) == want) then return n end
    end
  end
  return nil
end
local function names(tree)
  local out = {}
  for _, top in ipairs(tree) do
    for _, n in ipairs(top.nodes or {}) do if not n.locked then out[#out+1] = tostring(n.id) end end
  end
  return table.concat(out, ",")
end
local race = pick(d.all_races, "$wantRace")
if not race then return "ERR no unlocked race matches '$wantRace'; have: " .. names(d.all_races) end
d:raceUse(race)
local class = pick(d.all_classes, "$Class")
if not class then return "ERR no unlocked class matches '$Class' for " .. tostring(race.id) .. "; have: " .. names(d.all_classes) end
d:classUse(class)
d.c_name:setText("$Name")
local t = d.descriptors_by_type
return ("picked race=%s/%s class=%s/%s sex=%s name=%s play_hidden=%s"):format(
  tostring(t.race), tostring(t.subrace), tostring(t.class), tostring(t.subclass), tostring(t.sex),
  d.c_name.text, tostring(d.ui_by_ui[d.c_ok].hidden))
"@
} else {
    $roll = @"
local d = game.dialogs and game.dialogs[1]
if not d or d.__CLASSNAME ~= "mod.dialogs.Birther" then return "not at birther: " .. bridge.dialogs() end
d:randomBirth()
d.c_name:setText("$Name")
return "rolled name=" .. d.c_name.text .. " play_hidden=" .. tostring(d.ui_by_ui[d.c_ok].hidden)
"@
}
$r = Step 'birther' $roll
if ($r.Status -ne 'OK') { Write-Host 'FAILED: could not roll a character'; Stop-Game; exit 1 }
if ($r.Result -match '^ERR ') { Write-Host "FAILED: $($r.Result)"; Stop-Game; exit 1 }
# The Play button is the Birther's own gate: hidden until every descriptor
# in its order is set and the name is long enough (Birther:setDescriptor),
# and atEnd("created") refuses while it is hidden. Checking it here costs
# nothing; not checking it would spend the whole birth timeout finding out.
if ($r.Result -notmatch 'play_hidden=false') {
    Write-Host "FAILED: the Birther's Play button is still hidden -- a choice did not take ($($r.Result))"
    Stop-Game; exit 1
}

# Fire and forget. atEnd() runs birth, world generation and a save/load cycle;
# the frame that invoked it does not survive to report. Poll for the world
# instead of waiting for a reply.
$null = Invoke-Bridge -NoWait -Lua @'
local d = game.dialogs and game.dialogs[1]
if d then d:atEnd("created") end
return "accepted"
'@
Write-Host 'confirm    SENT     birth + worldgen; polling for the world'

$deadline = (Get-Date).AddSeconds($BirthTimeoutSec)
$inWorld = $false
while ((Get-Date) -lt $deadline -and -not $inWorld) {
    Start-Sleep -Seconds 10
    if (-not (Test-GameAlive)) { Write-Host 'FAILED: game process died during birth'; exit 1 }
    $r = Invoke-Bridge -Lua 'return bridge.state()' -TimeoutSec 15
    if ($r.Status -eq 'OK') {
        Write-Host ('  poll     {0}' -f $r.Result)
        if ($r.Result -match 'zone=\S' -and $r.Result -notmatch 'zone=nil') { $inWorld = $true }
    }
}
if (-not $inWorld) { Write-Host "FAILED: no world after ${BirthTimeoutSec}s"; Stop-Game; exit 1 }

# The world exists, but birth has not finished. The engine is now showing the
# birth level-up dialog, and closing it runs the rest: the welcome text, then
# onBirth(), the starting quest and creating_player = false
# (mod/class/Game.lua:322-377). Saving under those dialogs used to work only
# because creating_player is not a saved field -- the quest and the intro were
# simply never granted. Each dialog is closed through its own EXIT bind, the
# key path the engine itself takes for a quick birth (Game.lua:341), never by
# unregistering it, so every on_finish callback runs. Nothing is allocated:
# the level-up dialog closes with no change to accept.
$settled = $false
$quiet = 0
for ($i = 0; $i -lt 16 -and -not $settled; $i++) {
    $r = Invoke-Bridge -Lua @'
local d = game.dialogs and game.dialogs[#game.dialogs]
if not d then return "none" end
-- #147: NAME it. `d.title or d.__CLASSNAME` looks right and is not: an empty
-- string is truthy in Lua, so an untitled dialog reported as "stuck " with
-- nothing after it -- the same defect #142 fixed in the product, and the reason
-- three classes failed to birth with no evidence of what stopped them.
local t = d.title
local title = (type(t) == "string" and t ~= "") and t or tostring(d.__CLASSNAME or "?")
local v = d.key and d.key.virtuals
if v and v.EXIT then
  d.key:triggerVirtual("EXIT")
  return "closed " .. title .. " -> " .. bridge.dialogs()
end
-- Then ACCEPT, the ladder sk.closeDialog has always used: a dialog that cannot
-- be escaped can usually be answered, and birth dialogs for Archmage, Paradox
-- Mage and Temporal Warden are of that kind.
if v and v.ACCEPT then
  d.key:triggerVirtual("ACCEPT")
  return "accepted " .. title .. " -> " .. bridge.dialogs()
end
-- A Chat has NO binds at all -- an answer is picked by typing its letter,
-- which calls self:use(self.list[n]) (engine/dialogs/Chat.lua:49). The town
-- starts open one as their intro, which is why Archmage, Paradox Mage and
-- Temporal Warden could never be birthed: `stuck mod.dialogs.Chat
-- binds=SCREENSHOT`. sk.closeDialog has had this rung since it was written.
if d.use and type(d.list) == "table" and d.list[1]
   and tostring(d.__CLASSNAME or ""):find("Chat") then
  local item = d.list[1]
  bridge.injecting = true
  local ok, err = pcall(d.use, d, item)
  bridge.injecting = false
  if not ok then return "stuck " .. title .. " chat error " .. tostring(err) end
  return "answered " .. title .. " -> " .. tostring(item.name) .. " -> " .. bridge.dialogs()
end
local keys = {}
for k in pairs(v or {}) do keys[#keys+1] = tostring(k) end
table.sort(keys)
return "stuck " .. title .. " binds=" .. table.concat(keys, ",")
'@ -TimeoutSec 30
    Write-Host ('  dialog   {0,-8} {1}' -f $r.Status, $r.Result)
    if ($r.Status -ne 'OK') { break }
    # A callback can register the next dialog on a later tick, so "none"
    # has to hold twice in a row before birth counts as finished.
    if ($r.Result -eq 'none') { $quiet++; if ($quiet -ge 2) { $settled = $true; break } }
    else { $quiet = 0 }
    if ($r.Result -match '^stuck') { Write-Host "FAILED: a birth dialog has no EXIT bind: $($r.Result)"; Stop-Game; exit 1 }
    Start-Sleep -Seconds 2
}
if (-not $settled) { Write-Host 'FAILED: the birth dialogs did not settle'; Stop-Game; exit 1 }
# #147: poll for the world AGAIN, after the dialogs. The first poll happens
# before them, which is right for every class whose level exists by the time
# birth confirms -- and wrong for one whose level is generated by CLOSING a
# birth dialog.
#
# Owner, on watching a Cultist of Entropy rolled: "prior to spawning into a
# level you're faced with the point allocation screen to spend attributes and
# skill points. the background is a black void and upon closing the dialogue you
# then generate a level and spawn in."
#
# So for that class the order is confirm -> dialog -> WORLD, and the driver
# assumed confirm -> world -> dialog. It then called saveGame() on a game that
# had not finished becoming one, which is exactly the shape of the only
# symptom it has ever produced: no error, no stuck dialog, and no save file.
$settledWorld = $false
$wdeadline = (Get-Date).AddSeconds([Math]::Min(120, $BirthTimeoutSec))
while (-not $settledWorld -and (Get-Date) -lt $wdeadline) {
    $r = Invoke-Bridge -Lua 'return bridge.state() .. " creating=" .. tostring(game.creating_player)' -TimeoutSec 20
    if ($r.Status -eq 'OK' -and $r.Result -match 'zone=\S' -and $r.Result -notmatch 'zone=nil' -and $r.Result -notmatch 'creating=true') {
        $settledWorld = $true
    } else {
        # A level generating puts up a bindless dialog; that is progress, not a
        # stall, so it is waited on rather than pressed (#161).
        Start-Sleep -Milliseconds 700
    }
}
Write-Host ("  world    {0}" -f $(if ($settledWorld) { 'ready' } else { 'NOT ready after the dialogs; saving anyway' }))

$null = Step 'born' 'local n = 0 for _ in pairs(game.player.quests or {}) do n = n + 1 end return bridge.state() .. " quests=" .. n .. " creating=" .. tostring(game.creating_player)' 30

$null = Step 'save' 'game:saveGame() return "save requested"' 120

# Saving is ASYNCHRONOUS -- background_saves defaults to true, so saveGame()
# returns immediately and a separate thread writes game.teag.tmp, then renames.
# Killing the process on the strength of that return leaves a zero-byte .tmp and
# no save at all. Wait for the real file.
# The directory is the engine's sanitised form of the name (Get-SaveDirName):
# a hyphen in the name is an underscore on disk.
$save = Join-Path $script:SaveRoot "$(Get-SaveDirName -Name $Name)\game.teag"
$deadline = (Get-Date).AddSeconds(180)
while ((Get-Date) -lt $deadline) {
    if ((Test-Path $save) -and (Get-Item $save).Length -gt 0) { break }
    Start-Sleep -Seconds 3
}

$null = Step 'verify' 'return bridge.state()' 30
Stop-Game

if ((Test-Path $save) -and (Get-Item $save).Length -gt 0) {
    # Check the descriptor that was actually written, not the game we think we
    # ran. This is the artifact every later run depends on.
    if (-not (Assert-SaveAddons -Name $Name)) {
        Write-Host "`n[new-character] FAILED - save written but its addon list is wrong"
        exit 1
    }
    Write-Host "`n[new-character] PASS - $save ($((Get-Item $save).Length) bytes)"
    exit 0
}
# #163: leave evidence. A birth that fails writes nothing but one line, which
# is how Cultist of Entropy has failed seven times across seven sweeps without
# anyone being able to say what it was doing. This is #138's argument -- a
# failure that leaves no picture cannot be diagnosed -- applied to the one place
# it was never applied.
#
# Best effort throughout: the game may be gone, and a diagnostic that throws on
# the way out of a failure is worse than none.
$diagDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'build\results'

if (-not (Test-Path $diagDir)) { $null = New-Item -ItemType Directory -Force -Path $diagDir }
$stem = "birth-failed-$Name"
try {
    $st = (Invoke-Bridge -Lua 'return bridge.state()' -TimeoutSec 20).Result
    $dl = (Invoke-Bridge -Lua 'return bridge.dialogs()' -TimeoutSec 20).Result
    $ch = (Invoke-Bridge -TimeoutSec 20 -Lua @'
local d = game.dialogs and game.dialogs[#game.dialogs]
if not d then return "no dialog" end
local out = { "class=" .. tostring(d.__CLASSNAME), "title=" .. tostring(d.title) }
if type(d.list) == "table" then
  for i, it in ipairs(d.list) do out[#out+1] = ("answer%d=%s"):format(i, tostring(it.name or it.text or "?")) end
end
local v = d.key and d.key.virtuals
local ks = {}
for k in pairs(v or {}) do ks[#ks+1] = tostring(k) end
table.sort(ks)
out[#out+1] = "binds=" .. table.concat(ks, ",")
return table.concat(out, " | ")
'@).Result
    # Self-contained: sk.* are the SOAK's helpers and this script never installs
    # them, so calling sk.shot here would have quietly produced text and no
    # picture. takeScreenshot, not saveScreenshot -- the latter opens a
    # "Screenshot taken!" popup on top of the state being captured (#138).
    $shot = (Invoke-Bridge -TimeoutSec 40 -Lua @"
local ok, img = pcall(game.takeScreenshot, game)
if not ok then return "ERR " .. tostring(img) end
if not img then return "ERR no image" end
if not fs.exists("/screenshots") then fs.mkdir("/screenshots") end
local path = "/screenshots/$stem.png"
local f = fs.open(path, "w")
if not f then return "ERR open " .. path end
f:write(img) f:close()
return "wrote " .. path
"@).Result
    $notes = @("birth failed for $Name ($Class / $Race)", "", "state   : $st", "dialogs : $dl", "top     : $ch", "shot    : $shot")
    ($notes -join "`n") | Set-Content -Path (Join-Path $diagDir "$stem.txt") -Encoding utf8
    Write-Host "  diag     state   : $st"
    Write-Host "  diag     dialogs : $dl"
    Write-Host "  diag     top     : $ch"
    $src = Join-Path $env:USERPROFILE "T-Engine\4.0\tome\screenshots\$stem.png"
    if (Test-Path $src) { Move-Item -Force $src (Join-Path $diagDir "$stem.png"); Write-Host "  diag     -> $stem.png + $stem.txt" }
    else { Write-Host "  diag     -> $stem.txt (no screenshot: $shot)" }
} catch { Write-Host "  diag     could not collect: $($_.Exception.Message)" }

Write-Host "`n[new-character] FAILED - no completed save at $save"
Get-ChildItem (Join-Path $script:SaveRoot (Get-SaveDirName -Name $Name)) -ErrorAction Ignore |
    Select-Object Name, Length | Format-Table -AutoSize
exit 1
