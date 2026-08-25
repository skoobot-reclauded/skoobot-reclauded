<#
    Unlock every locked CLASS at birth, and list what a character can be
    created as (#123).

    The class baseline sweep needs to birth one character of every class, and
    most subclasses are locked behind `profile.mod.allow_build` until the
    account has earned them. This does that once, and then reports the roster
    the sweep will iterate.

    WHERE THE KEYS COME FROM. Not from a list written here: from the game's own
    `Game.unlocks_list` (mod/class/Game.lua:2985), filtered to the entries
    whose display name begins with "Class:" -- which is exactly how ToME's own
    countBirthUnlocks categorises them. That matters because the keys are not
    derivable from the class names (`mage` unlocks *Archmage*; `corrupter_reaver`,
    `wilder_stone_warden`, `divine_sun_paladin`), and because an addon or a DLC
    that adds a class adds its key to the same table -- so this picks those up
    instead of quietly omitting them.

    Deliberately NOT filtered out: "Class tree: Poisons" and "Class feature:
    Alchemist's Drolem" both begin with "Class" but not with "Class:", so the
    anchored match leaves them alone.

    THIS WRITES THE ACCOUNT PROFILE, on purpose. `Game:setAllowedBuild` calls
    `profile:saveModuleProfile`, so the unlocks persist for this ToME profile
    and every later sweep is free. The owner approved that on #123
    (2026-08-25); it is why this is its own script and not a flag on
    tools/new-character.ps1, whose ordinary path must still FAIL on a locked
    class so a fixture cannot silently birth something else.

    Races are left alone. The sweep standardises on one race with a small
    exception table, and the one exception known to need it -- Stone Warden,
    which refuses anything but a Dwarf -- needs a race that is not locked.

    THE ROSTER IS PER-RACE, which is why -Race exists. A class whose
    `special_check` rejects the selected race is not "locked": it is absent
    from the tree entirely, because isDescriptorAllowed returns nil for it.
    Measured: Cornac reports 30 birthable, Dwarf reports 31 -- the extra being
    Stone Warden. So a sweep cannot enumerate once and call it the roster.

    WHAT STAYS LOCKED, AND WHY IT IS NOT A FAILURE. The four Tinker classes
    (Annihilator, Gunslinger, Psyshot, Sawbutcher) remain locked in the
    Maj'Eyal campaign even with their allow_build keys set -- verified:
    `tinker_psyshot` reads true while Tinker/Psyshot still reads locked. They
    belong to Embers of Rage, a different campaign, and are birthable there
    rather than here. So this script exits 0 when every KEY took, and reports
    what is still locked as information; a key that would not take is the
    only failure.

    Two launches, on purpose: the first unlocks, the second reads the roster
    back from a fresh process. That is what proves the write persisted rather
    than only having happened in memory.

    A ROSTER ENTRY IS NOT YET A FIXTURE. This reports what the Birther will
    let you pick; whether tools/new-character.ps1 can carry it all the way to
    a save is a separate question, and for at least one class the answer is
    no. Archmage births into town-angolwen and then stops on an untitled
    dialog with no EXIT bind -- its `starting_intro` -- which the birth loop
    cannot close, so no save is written. The sweep's measurable set is
    therefore the roster MINUS the five town-start classes (#123's decision to
    skip them), and that is a decision the sweep makes, not this script.

    Run:
        powershell -ExecutionPolicy Bypass -File .\tools\unlock-classes.ps1
        powershell -ExecutionPolicy Bypass -File .\tools\unlock-classes.ps1 -VerifyOnly

    Exit codes:  0 ok   1 failed   3 inconclusive (never reached the Birther)

    #123.
#>
[CmdletBinding()]
param(
    # Report the roster without unlocking anything.
    [switch]$VerifyOnly,
    # The race the roster is read under. A subrace ("Cornac", "Dwarf") by
    # display name or descriptor id; the roster differs between them.
    [string]$Race = 'Cornac',
    # Where to write the roster for the sweep to read. Defaults to a
    # per-race file, since the roster is per-race.
    [string]$OutFile,
    [int]$LaunchTimeoutSec = 180
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'harness.ps1')

if (-not $OutFile) {
    $safe = ($Race -replace '[^A-Za-z0-9]', '').ToLower()
    $OutFile = Join-Path (Split-Path -Parent $PSScriptRoot) "build\results\classes-$safe.txt"
}

Write-Host ''
Write-Host '[unlock] unlock every locked class, and list the birth roster (#123)'

function Fail($why)         { Write-Host "[unlock] FAILED - $why"; Stop-Game; exit 1 }
function Inconclusive($why) { Write-Host "[unlock] INCONCLUSIVE - $why"; Stop-Game; exit 3 }

# Get to a fresh tome game's Birther. Module:instanciate reboots the Lua state
# into the module -- the engine's own path, the same call the New Game menu
# makes (tools/new-character.ps1 does this too).
function Enter-Birther($label) {
    $g = Start-Game -TimeoutSec 60
    if (-not $g.Ready) { Fail "$label`: no bridge at the menu" }

    $lua = @'
local Module = require "engine.Module"
local mod
for i, entry in ipairs(Module:listModules(true)) do
  for j, m in ipairs(entry.versions) do
    if m.short_name == "tome" and not m.is_boot and not mod then mod = m end
  end
end
if not mod then return "ERR tome module not found" end
Module:instanciate(mod, "unlock-scratch", true, false)
return "starting"
'@
    $r = Invoke-Bridge -Lua $lua -TimeoutSec 25
    if ($r.Result -match '^ERR') { Fail "$label`: $($r.Result)" }

    $w = Wait-LogLine -Pattern '\[BRIDGE\] ready tier=tome' -TimeoutSec $LaunchTimeoutSec
    if (-not $w.Matched) { Show-LoadDiagnostics -Seen $w.Seen; Fail "$label`: the tome-tier bridge never came up" }
    Clear-BridgeQueue
    $probe = Invoke-Bridge -Lua 'return "pong"' -TimeoutSec 240
    if ($probe.Status -ne 'OK') { Fail "$label`: the tome-tier pump never turned ($($probe.Status))" }
    return $true
}

# The roster: every unlocked leaf of the Birther's own class tree, which is
# what a click sees -- read AFTER selecting the race, because raceUse()
# rebuilds the class tree and a class whose special_check rejects the race is
# not in it at all. Expandable here-string, as tools/new-character.ps1 uses
# for the same job; the Lua below carries no '$'.
$ROSTER_LUA = @"
local d = game.dialogs and game.dialogs[1]
if not d or d.__CLASSNAME ~= "mod.dialogs.Birther" then return "ERR not at the birther: " .. tostring(bridge.dialogs()) end
local function plain(s)
  if type(s) == "table" and s.toString then s = s:toString() end
  return (tostring(s):gsub("#[^#]*#", ""))
end
local function pick(tree, want)
  want = want:lower()
  for _, top in ipairs(tree) do
    if not top.locked and (plain(top.id):lower() == want or plain(top.name):lower() == want) then
      for _, n in ipairs(top.nodes or {}) do if not n.locked then return n end end
    end
    for _, n in ipairs(top.nodes or {}) do
      if not n.locked and (plain(n.id):lower() == want or plain(n.basename or n.name):lower() == want) then return n end
    end
  end
  return nil
end
local race = pick(d.all_races, "$Race")
if not race then return "ERR no unlocked race matches '$Race'" end
d:raceUse(race)
local open, shut = {}, {}
for _, top in ipairs(d.all_classes) do
  for _, n in ipairs(top.nodes or {}) do
    local row = plain(top.id) .. "/" .. plain(n.id)
    if n.locked then shut[#shut+1] = row else open[#open+1] = row end
  end
end
table.sort(open) table.sort(shut)
return ("RACE %s OPEN %d %s || SHUT %d %s"):format(tostring(race.id), #open, table.concat(open, ","), #shut, table.concat(shut, ","))
"@

try {
    if (-not $VerifyOnly) {
        $null = Enter-Birther 'unlock'
        $unlock = Invoke-Bridge -TimeoutSec 120 -Lua @'
-- The game's own table, filtered the way the game's own countBirthUnlocks
-- filters it. "Class tree:" and "Class feature:" do not match "^Class:".
local list = game.unlocks_list or rawget(_G, "unlocks_list")
if type(list) ~= "table" then return "ERR no unlocks_list on this game" end
local keys = {}
for key, label in pairs(list) do
  if type(label) == "string" and label:find("^Class:") then keys[#keys+1] = key end
end
table.sort(keys)
if #keys == 0 then return "ERR unlocks_list carries no Class: entries" end
local already, done = {}, {}
for _, key in ipairs(keys) do
  if profile.mod.allow_build[key] then already[#already+1] = key
  else
    -- setAllowedBuild(what, notify) -- notify opens an UnlockDialog per key,
    -- which is 20 dialogs nobody is here to close. Silent.
    game:setAllowedBuild(key)
    if profile.mod.allow_build[key] then done[#done+1] = key else done[#done+1] = "FAILED:" .. key end
  end
end
return ("KEYS %d ALREADY %d NEW %d %s"):format(#keys, #already, #done, table.concat(done, ","))
'@
        Write-Host "  $($unlock.Result)"
        if ($unlock.Status -ne 'OK') { Fail "the unlock did not run ($($unlock.Status))" }
        if ($unlock.Result -match '^ERR')      { Inconclusive $unlock.Result }
        if ($unlock.Result -match 'FAILED:')   { Fail "a key would not take: $($unlock.Result)" }
        if ($unlock.Tainted) { Write-Host '  TAINTED - human input during the unlock' }
        Stop-Game
    }

    # A fresh process. If the roster is complete here, the write persisted --
    # which is the only thing that makes a second sweep free.
    $null = Enter-Birther 'verify'
    $roster = Invoke-Bridge -Lua $ROSTER_LUA -TimeoutSec 60
    if ($roster.Status -ne 'OK') { Fail "could not read the roster ($($roster.Status))" }
    if ($roster.Result -match '^ERR') { Inconclusive $roster.Result }

    if ($roster.Result -notmatch '^RACE (\S+) OPEN (\d+) ([^|]*)\|\| SHUT (\d+) (.*)$') {
        Fail "the roster did not parse: $($roster.Result)"
    }
    $raceId    = $Matches[1]
    $openCount = [int]$Matches[2]
    $open      = @($Matches[3].Trim() -split ',' | Where-Object { $_ })
    $shutCount = [int]$Matches[4]
    $shut      = @($Matches[5].Trim() -split ',' | Where-Object { $_ })

    Write-Host ''
    Write-Host ("  birthable as {0}: {1}" -f $raceId, $openCount)
    foreach ($c in $open) { Write-Host "    $c" }
    if ($shutCount -gt 0) {
        Write-Host ''
        Write-Host ("  still locked, and not a failure: {0}" -f $shutCount)
        Write-Host '  (a class gated by CAMPAIGN rather than by allow_build -- the Tinker'
        Write-Host "   classes belong to Embers of Rage, not to Maj'Eyal)"
        foreach ($c in $shut) { Write-Host "    $c" }
    }

    $dir = Split-Path -Parent $OutFile
    if (-not (Test-Path $dir)) { $null = New-Item -ItemType Directory -Force -Path $dir }
    Set-Content -Path $OutFile -Value $open -Encoding utf8
    Write-Host ''
    Write-Host "  roster written to $OutFile"
}
finally {
    Stop-Game
}

Write-Host ''
Write-Host ("[unlock] PASS - {0} classes birthable as {1}{2}" -f $openCount, $raceId,
    $(if ($shutCount -gt 0) { ", $shutCount campaign-gated (see above)" } else { '' }))
exit 0
