<#
    #50: keybind collision detection -- advisory, never a rebind.

    Another addon, or the player's own remap, can put a second action on one
    of this addon's keys; the engine then fires whichever of the two it finds
    first and says nothing. The addon now checks its five actions against
    KeyBind.binds_def and binds_remap at ToME:runDone, announces each
    collision once per game session (one [SKOOBOT] line in the engine log,
    one line in the message log), and the menu shows "Keybinds: OK" or
    "Keybinds: N collision(s) (see log)" with the colliding names under it.

    What this drives, through the bridge, on the harness character:
      1. with the default binds, skoobot_reclauded.keybinds.collisions() is
         empty and the menu, opened through its own key, says "Keybinds: OK";
      2. a second action defined on Shift+F3 through the engine's own
         KeyBind:defineAction -- what another addon does -- is reported
         against the toggle, announced once (a second notice() adds nothing),
         and the menu says so with both names;
      3. a remap of the menu key onto bare F3 collides with the base game's
         party switch, and the count goes to two;
      4. with both reverted the report is empty again and nothing was rebound.
    The engine log is read after the game stops: the load-time summary line,
    exactly the collision lines the probes caused, and no Lua Error.

    No game.turn advances. Everything injected is removed; binds_remap is
    never saved, so the player's keybinds2.cfg is untouched.

    Exit codes:  0 pass   1 fail   2 tainted   3 inconclusive (a build that
    predates #50, or a profile whose own remap already collides)

    Run:
        powershell -ExecutionPolicy Bypass -File .\tools\scenario-keybinds.ps1
#>
[CmdletBinding()]
param([string]$SaveName = 'harness')

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'harness.ps1')

$RepoRoot = Split-Path -Parent $PSScriptRoot

$script:Fail = @()
$script:Tainted = $false
function Check($ok, $what) {
    if ($ok) { Write-Host "  PASS  $what" } else { Write-Host "  FAIL  $what"; $script:Fail += $what }
}
# A probe that errors or returns ERR makes the run inconclusive: the fixture
# could not be built, so nothing below it says anything about the product.
function Probe($label, $lua, $timeout = 60) {
    $r = Invoke-Bridge -Lua $lua -TimeoutSec $timeout
    if ($r.Tainted) { $script:Tainted = $true }
    $txt = "$($r.Result)"
    Write-Host ('  {0,-9} {1,-8} {2}' -f $label, $r.Status, $txt)
    if ($r.Status -ne 'OK' -or $txt -match '^ERR') {
        Write-Host "[keybinds] INCONCLUSIVE at '$label': $txt"
        Stop-Game
        exit 3
    }
    return $txt
}

Write-Host ''
Write-Host '[keybinds] keybind collision detection (#50)'

try {
    $g = Load-Save -Name $SaveName
    if (-not $g.Ready) { Write-Host "[keybinds] FAILED - could not load '$SaveName' ($($g.Reason))"; exit 1 }
    Check ($g.Addons -match 'skoobot_reclauded') 'the product is loaded'

    $install = Probe 'install' @'
_G.kb = {}
local KeyBind = require "engine.KeyBind"
local b = skoobot_reclauded
if not (b and b.keybinds and b.keybinds.collisions and b.keybinds.notice) then return "OLD the loaded build predates #50" end
kb.COLLIDER = "SKOOBOT_HARNESS_COLLIDER"
kb.SF3 = "sym:_F3:false:true:false:false"
kb.F3  = "sym:_F3:false:false:false:false"

-- "n=<count> | <type>@<key>:<others>[,...] ; ..." -- one token per collision.
function kb.list()
  local out = {}
  for _, c in ipairs(b.keybinds.collisions()) do
    out[#out+1] = c.type .. "@" .. tostring(c.key) .. ":" .. table.concat(c.others, ",")
  end
  return "n=" .. #out .. " | " .. table.concat(out, " ; ")
end

-- Is any of the actions involved in the current collisions remapped by the
-- player? (Then a non-empty default report is the profile's, not a defect.)
function kb.remapped()
  for _, c in ipairs(b.keybinds.collisions()) do
    if KeyBind.binds_remap[c.type] then return true end
    for _, o in ipairs(c.others) do if KeyBind.binds_remap[o] then return true end end
  end
  return false
end

function kb.lastlog(n)
  local ld = game.uiset and game.uiset.logdisplay
  if not ld or not ld.getLines then return "" end
  local out = {}
  for _, l in ipairs(ld:getLines(n or 2)) do
    local s = l
    if type(l) == "table" then s = l.str or l.msg or l[1] or l end
    if type(s) == "table" and s.toString then s = s:toString() end
    out[#out+1] = (tostring(s):gsub("#[^#]*#", ""))
  end
  return table.concat(out, " || ")
end

-- Open the menu through its own key and read it: the status row, the rows
-- under it, and the lettered choices. Selecting the status row must leave
-- the menu open. Closed again before returning.
function kb.menu()
  while #game.dialogs > 0 do game:unregisterDialog(game.dialogs[#game.dialogs]) end
  local r = bridge.key("MENU_SKOOBOT_RECLAUDED")
  local m = game.dialogs[#game.dialogs]
  if not m or tostring(m.title) ~= "SkooBot: Reclauded" then return "ERR menu not on top after " .. r .. ": " .. bridge.dialogs() end
  local status, details, choices, statusrow = nil, {}, {}, nil
  for _, it in ipairs(m.list) do
    local name = tostring(it.name):gsub("^%s+", "")
    if it.info then
      if status then details[#details+1] = name else status, statusrow = name, it end
    else
      choices[#choices+1] = name
    end
  end
  local stays = "n/a"
  if statusrow then
    m:use(statusrow)
    stays = tostring(game.dialogs[#game.dialogs] == m)
  end
  local w, gw = m.w, game.w
  while #game.dialogs > 0 do game:unregisterDialog(game.dialogs[#game.dialogs]) end
  return ("status=[%s] details=[%s] choices=[%s] stays=%s w=%d game.w=%d"):format(
    tostring(status), table.concat(details, " | "), table.concat(choices, " | "), stays, w, gw)
end

-- What another addon does: define an action on the engine, on Shift+F3.
function kb.inject()
  KeyBind:defineAction{ default = { kb.SF3 }, type = kb.COLLIDER, group = "actions", name = "Harness collider" }
  game.key:bindKeys()
  return "defined " .. kb.COLLIDER .. " bound=" .. tostring(game.key.binds[kb.SF3] and game.key.binds[kb.SF3][kb.COLLIDER])
end
function kb.uninject()
  KeyBind.binds_def[kb.COLLIDER] = nil
  game.key:bindKeys()
  return "removed bound=" .. tostring(game.key.binds[kb.SF3] and game.key.binds[kb.SF3][kb.COLLIDER])
end

-- What the player does: remap the menu key onto bare F3, the party switch.
-- binds_remap is in memory only; nothing calls saveRemap.
function kb.remap(on)
  if on then KeyBind.binds_remap.MENU_SKOOBOT_RECLAUDED = { kb.F3 } else KeyBind.binds_remap.MENU_SKOOBOT_RECLAUDED = nil end
  game.key:bindKeys()
  return "menu=" .. b.keyFor("MENU_SKOOBOT_RECLAUDED")
end

-- Proof that nothing was rebound: our five actions' effective keys.
function kb.effective()
  local out = {}
  for _, t in ipairs({"TOGGLE_SKOOBOT_RECLAUDED","STOP_SKOOBOT_RECLAUDED","RUNONCE_SKOOBOT_RECLAUDED","ASK_SKOOBOT_RECLAUDED","MENU_SKOOBOT_RECLAUDED"}) do
    local def = KeyBind.binds_def[t]
    local ks = def and KeyBind:getBindTable(def) or {}
    out[#out+1] = t:gsub("_SKOOBOT_RECLAUDED", "") .. "=" .. table.concat(ks, "/")
  end
  return table.concat(out, " ")
end
return "installed"
'@
    if ($install -match '^OLD') { Write-Host "[keybinds] INCONCLUSIVE - $install"; Stop-Game; exit 3 }
    Check ($install -eq 'installed') 'probe helpers installed'

    # ----- 1: the defaults ----------------------------------------------------
    Write-Host ''
    Write-Host '  --- default binds'
    $before = Probe 'effective' 'return kb.effective()'
    $l0 = Probe 'list' 'return kb.list()'
    if ($l0 -notmatch '^n=0 ') {
        $rm = Probe 'remapped' 'return tostring(kb.remapped())'
        if ($rm -eq 'true') {
            Write-Host "[keybinds] INCONCLUSIVE - this profile's own remap already collides: $l0"
            Stop-Game; exit 3
        }
    }
    Check ($l0 -match '^n=0 ') 'the default binds collide with nothing'
    $m0 = Probe 'menu' 'return kb.menu()'
    Check ($m0 -match 'status=\[Keybinds: OK\]') 'the menu says "Keybinds: OK"'
    Check ($m0 -match 'details=\[\]') 'no collision rows under it'
    Check ($m0 -match 'choices=\[a\) Set Skill Usage \| b\) Activate/Deactivate Bot Stop Conditions \| c\) Cancel\]') 'the three choices keep their letters'
    Check ($m0 -match 'stays=true') 'selecting the status row leaves the menu open'

    # ----- 2: another addon on Shift+F3 ---------------------------------------
    Write-Host ''
    Write-Host '  --- a second action defined on Shift+F3 (what another addon does)'
    $inj = Probe 'inject' 'return kb.inject()'
    Check ($inj -match 'bound=true') 'the engine bound the collider to Shift+F3'
    $l1 = Probe 'list' 'return kb.list()'
    Check ($l1 -match '^n=1 \| TOGGLE_SKOOBOT_RECLAUDED@Shift\+F3:SKOOBOT_HARNESS_COLLIDER$') 'reported against the toggle, on Shift+F3, naming the collider'
    $n1 = Probe 'notice' 'return "fresh=" .. tostring(skoobot_reclauded.keybinds.notice()) .. " | log=" .. kb.lastlog(1)'
    Check ($n1 -match '^fresh=1 ') 'notice() announced the new collision'
    Check ($n1 -match '\[SkooBot\] Shift\+F3: "Toggle SkooBot: Reclauded" and "Harness collider" -- only one of them will answer that key\. Change either under Escape > Key Bindings\.') 'the message-log line names the key and both actions and says what to do'
    $n2 = Probe 'again' 'return "fresh=" .. tostring(skoobot_reclauded.keybinds.notice())'
    Check ($n2 -eq 'fresh=0') 'a second notice() announces nothing (once per session)'
    $m1 = Probe 'menu' 'return kb.menu()'
    Check ($m1 -match 'status=\[Keybinds: 1 collision \(see log\)\]') 'the menu says "Keybinds: 1 collision (see log)"'
    Check ($m1 -match 'details=\[Shift\+F3: "Toggle SkooBot: Reclauded" and "Harness collider"\]') 'the row under it names the key and both actions'
    Check ($m1 -match 'choices=\[a\) Set Skill Usage \| b\) Activate/Deactivate Bot Stop Conditions \| c\) Cancel\]') 'the choices are unchanged'
    if ($m1 -match 'w=(\d+) game\.w=(\d+)') { Check ([int]$Matches[1] -le [int]$Matches[2]) "the widened menu fits the screen ($($Matches[1]) <= $($Matches[2]))" }

    # ----- 3: the player remaps onto the base game ---------------------------
    Write-Host ''
    Write-Host '  --- the menu key remapped onto bare F3 (the party switch)'
    $rm1 = Probe 'remap' 'return kb.remap(true)'
    Check ($rm1 -eq 'menu=F3') 'the remap took (keyFor says F3)'
    $l2 = Probe 'list' 'return kb.list()'
    Check ($l2 -match '^n=2 \| TOGGLE_SKOOBOT_RECLAUDED@Shift\+F3:SKOOBOT_HARNESS_COLLIDER ; MENU_SKOOBOT_RECLAUDED@F3:SWITCH_PARTY_3$') 'both collisions reported, in action order, the second against the base game'
    $n3 = Probe 'notice' 'return "fresh=" .. tostring(skoobot_reclauded.keybinds.notice()) .. " | log=" .. kb.lastlog(1)'
    Check ($n3 -match '^fresh=1 ') 'only the new collision is announced'
    Check ($n3 -match '\[SkooBot\] F3: "Open the SkooBot: Reclauded menu" and "Switch control to character 3"') 'the line names the base-game action'
    $m2 = Probe 'menu' 'return kb.menu()'
    Check ($m2 -match 'status=\[Keybinds: 2 collisions \(see log\)\]') 'the menu says "Keybinds: 2 collisions (see log)"'
    Check ($m2 -match 'details=\[Shift\+F3: [^\]|]+ \| F3: "Open the SkooBot: Reclauded menu" and "Switch control to character 3"\]') 'both rows are listed'

    # ----- 4: reverted --------------------------------------------------------
    Write-Host ''
    Write-Host '  --- reverted'
    $null = Probe 'unremap' 'return kb.remap(false)'
    $un = Probe 'uninject' 'return kb.uninject()'
    Check ($un -match 'bound=nil') 'the collider is gone from the engine'
    $l3 = Probe 'list' 'return kb.list()'
    Check ($l3 -match '^n=0 ') 'no collisions once both are reverted'
    $m3 = Probe 'menu' 'return kb.menu()'
    Check ($m3 -match 'status=\[Keybinds: OK\]') 'the menu is back to "Keybinds: OK"'
    $after = Probe 'effective' 'return kb.effective()'
    Check ($after -eq $before) 'nothing was rebound: the five actions have the keys they started with'
}
finally {
    Stop-Game
}

# ----- the engine log ---------------------------------------------------------
Write-Host ''
Write-Host '  --- engine log'
Start-Sleep -Seconds 1
$archive = Join-Path $RepoRoot 'build\logs'
if (-not (Test-Path $archive)) { New-Item -ItemType Directory -Path $archive -Force | Out-Null }
$dest = Join-Path $archive ("keybinds-{0}.txt" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
Copy-Item $script:LogPath $dest -ErrorAction Ignore
$lines = @((Get-Content $script:LogPath -Raw -ErrorAction Ignore) -split "`r?`n")

$summary = @($lines | Where-Object { $_ -match '^\[SKOOBOT\] \[Keybinds\] checked 5 actions: no collisions$' })
Check ($summary.Count -eq 1) 'one load-time summary line: "checked 5 actions: no collisions"'
$coll = @($lines | Where-Object { $_ -match '^\[SKOOBOT\] \[Keybinds\] collision: ' })
Check ($coll.Count -eq 2) "exactly the two collision lines the probes caused ($($coll.Count))"
Check (($coll -join "`n") -match 'collision: Shift\+F3: "Toggle SkooBot: Reclauded" and "Harness collider" \(TOGGLE_SKOOBOT_RECLAUDED and SKOOBOT_HARNESS_COLLIDER\)') 'the engine-log line carries the action types too'
$errs = @($lines | Where-Object { $_ -match 'Lua Error' })
Check ($errs.Count -eq 0) 'no Lua Error in the run'
foreach ($e in ($errs | Select-Object -First 3)) { Write-Host "         $e" }
Write-Host "  log archived to $dest"

Write-Host ''
if ($script:Tainted) { Write-Host '[keybinds] TAINTED - void, re-run.'; exit 2 }
if ($script:Fail.Count -gt 0) {
    Write-Host "[keybinds] FAILED - $($script:Fail.Count) check(s):"
    foreach ($f in $script:Fail) { Write-Host "                 $f" }
    exit 1
}
Write-Host '[keybinds] PASS - collisions are detected, announced once, shown in the menu, and nothing is rebound'
exit 0
