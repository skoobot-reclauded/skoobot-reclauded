<#
    Create a ToME character with no human input, and save it.

    This is the harness bootstrap: every behaviour test starts from a save, and
    this makes the first one. Race and class come from the Birther's own
    randomBirth(), so no descriptor knowledge is hardcoded here and nothing
    breaks when ToME adds a class. Only the name is forced, because the savefile
    directory is derived from it (mod/dialogs/Birther.lua:225) and the harness
    needs a predictable path.

    Run:  powershell -File .\tools\new-character.ps1 -Name harness
#>
param(
    [string]$Name = 'harness',
    [int]$BirthTimeoutSec = 900
)

. (Join-Path $PSScriptRoot 'harness.ps1')

function Step($label, $lua, $timeout = 30) {
    $r = Invoke-Bridge -Lua $lua -TimeoutSec $timeout
    Write-Host ('{0,-10} {1,-8} {2}' -f $label, $r.Status, $r.Result)
    if ($r.Tainted) { Write-Host '           TAINTED - human input during this step' }
    return $r
}

$g = Start-Game -TimeoutSec 60
if (-not $g.Ready) { Write-Host 'FAILED: no bridge at menu'; exit 1 }

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
if (-not $w.Matched) { Write-Host 'FAILED: tome-tier bridge never came up'; Stop-Game; exit 1 }
Write-Host "tome tier  OK       $($w.Line)"

$roll = @"
local d = game.dialogs and game.dialogs[1]
if not d or d.__CLASSNAME ~= "mod.dialogs.Birther" then return "not at birther: " .. bridge.dialogs() end
d:randomBirth()
d.c_name:setText("$Name")
return "rolled name=" .. d.c_name.text .. " play_hidden=" .. tostring(d.ui_by_ui[d.c_ok].hidden)
"@
$r = Step 'birther' $roll
if ($r.Status -ne 'OK') { Write-Host 'FAILED: could not roll a character'; Stop-Game; exit 1 }

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

$null = Step 'save' 'game:saveGame() return "save requested"' 120

# Saving is ASYNCHRONOUS -- background_saves defaults to true, so saveGame()
# returns immediately and a separate thread writes game.teag.tmp, then renames.
# Killing the process on the strength of that return leaves a zero-byte .tmp and
# no save at all. Wait for the real file.
$save = Join-Path $script:SaveRoot "$Name\game.teag"
$deadline = (Get-Date).AddSeconds(180)
while ((Get-Date) -lt $deadline) {
    if ((Test-Path $save) -and (Get-Item $save).Length -gt 0) { break }
    Start-Sleep -Seconds 3
}

$null = Step 'verify' 'return bridge.state()' 30
Stop-Game

if ((Test-Path $save) -and (Get-Item $save).Length -gt 0) {
    Write-Host "`n[new-character] PASS - $save ($((Get-Item $save).Length) bytes)"
    exit 0
}
Write-Host "`n[new-character] FAILED - no completed save at $save"
Get-ChildItem (Join-Path $script:SaveRoot $Name) -ErrorAction Ignore |
    Select-Object Name, Length | Format-Table -AutoSize
exit 1
