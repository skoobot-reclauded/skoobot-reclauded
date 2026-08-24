<#
    #72: the addon introduces itself once, to a player who has nothing set up.

    Before this it printed its keys to te4_log.txt and nothing else -- the
    message log got a line only when a keybind collision was found (#50), and
    docs/first-run.md section 2 measured the result: message-log lines
    mentioning SkooBot, zero. Someone who installed this from the Workshop
    list, where the description is behind a click, had no way to learn it was
    there short of pressing a key they did not know about.

    Three properties, and the second and third are the ones that make it a
    greeting rather than nagging:

      1. a character with NO talent rules is greeted on load, in the message
         log, with both keys as that player actually has them bound (#57);
      2. the same character, loaded again, is NOT greeted -- the flag lives
         with the character, so it is saved with them;
      3. a character that already has rules is never greeted at all, and is
         marked as greeted so that clearing every rule later does not make
         the addon treat them as new.

    The flag lives on the character (skoobot_reclauded.data), the same store
    the auto-talent scratch and the WARN acknowledgements use, so the engine
    saves it with them. This scenario does NOT restart the game to prove that
    -- the persistence is the engine's and is exercised by #52's reconcile
    already. What it proves is the logic on top: that the flag is set, that a
    second call is silent, and that a configured character is marked without
    being greeted.

    Exit codes:  0 pass   1 fail   2 tainted   3 inconclusive

    Run:
        powershell -ExecutionPolicy Bypass -File .\tools\scenario-greeting.ps1

    #72.
#>
[CmdletBinding()]
param(
    [string]$SaveName = 'fixture-berserker'
)

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
    if ($r.Status -ne 'OK') { Write-Host "  BRIDGE $($r.Status): $($r.Result)" }
    Write-Host "  $($r.Result)"
    return $r.Result
}

# The greeting is raised from ToME:runDone, which has already fired by the
# time the bridge can be asked anything -- so it cannot be triggered on
# demand. What CAN be done is read the message log it wrote to, and re-run
# the same function with the flag cleared, which is what the addon does on a
# character it has never met.
$Helpers = @'
_G.gr = {}
function gr.log(n)
  local ld = game.uiset and game.uiset.logdisplay
  if not ld or not ld.getLines then return "" end
  local out = {}
  for _, l in ipairs(ld:getLines(n or 40)) do
    local s = l
    if type(s) == "table" then s = s.str or s.msg or s[1] or s end
    s = (tostring(s):gsub("#[^#]*#", ""))
    if s:find("SkooBot", 1, true) then out[#out+1] = s end
  end
  return table.concat(out, " || ")
end
function gr.state()
  local p, b = game.player, skoobot_reclauded
  return ("rules=%d greeted=%s"):format(
    b.rules.module.count(b.rules.get(p)), tostring(b.data(p).greeted))
end
return "installed"
'@

Write-Host ''
Write-Host '[greeting] the addon says how to start, once (#72)'

try {
    $g = Load-Save -Name $SaveName
    if (-not $g.Ready) { Write-Host "[greeting] FAILED - could not load '$SaveName' ($($g.Reason))"; exit 1 }
    Check ($g.Addons -match 'skoobot_reclauded') 'the product is loaded'
    $null = Invoke-Bridge -Lua $Helpers -TimeoutSec 30

    # ----- 1: a fresh character is greeted ----------------------------------
    Write-Host ''
    Write-Host '  --- 1. no rules: the greeting is in the message log'
    # The fixture may carry rules from an earlier scenario's save; clear them
    # and the flag, then run the greeting as a fresh load would.
    $state = Probe @'
local p, b = game.player, skoobot_reclauded
local r = b.rules.get(p)
for _, s in ipairs(b.rules.module.SECTIONS) do
  local l = r[s]
  for i = #l, 1, -1 do l[i] = nil end
end
b.data(p).greeted = nil
return gr.state()
'@
    Check ($state -match 'rules=0 greeted=nil') 'the character has no rules and has not been greeted'

    $first = Probe 'skoobot_reclauded.greet() return gr.log(6)'
    Check ($first -match 'Ready\.') 'the greeting is written to the message log'
    Check ($first -match 'opens the menu') 'it says what the menu key does'
    Check ($first -match 'starts it') 'and what the toggle key does'
    Check ($first -match '\[SkooBot\]') 'it carries the addon prefix, like every other line'
    # #57: the keys are looked up, never quoted from the defaults.
    Check ($first -notmatch 'Shift\+F7 opens the menu.*Shift\+F7 starts') 'the two keys are different keys'

    Write-Host ''
    Write-Host '  --- 2. the same character again: silence'
    $flag = Probe 'return gr.state()'
    Check ($flag -match 'greeted=true') 'the character is marked as greeted'
    $second = Probe 'skoobot_reclauded.greet() return gr.log(3)'
    Check ($second -notmatch 'Ready\.') 'a second load says nothing'

    # ----- 3: a configured character is never greeted -----------------------
    Write-Host ''
    Write-Host '  --- 3. a character that has rules is not greeted at all'
    $conf = Probe @'
local p, b = game.player, skoobot_reclauded
b.data(p).greeted = nil
local r = b.rules.get(p)
b.rules.module.place(r, { tid = "T_ATTACK" }, "Combat")
local said = b.greet()
return ("said=%s %s"):format(tostring(said), gr.state())
'@
    Check ($conf -match 'said=false') 'a configured character is not greeted'
    Check ($conf -match 'greeted=true') '...and is marked, so clearing every rule later does not greet them'
}
finally {
    $null = Invoke-Bridge -Lua @'
local p, b = game.player, skoobot_reclauded
local r = b.rules.get(p)
for _, s in ipairs(b.rules.module.SECTIONS) do
  local l = r[s]
  for i = #l, 1, -1 do l[i] = nil end
end
return "cleared"
'@ -TimeoutSec 15 -ErrorAction SilentlyContinue
    Stop-Game
}

Write-Host ''
if ($script:Tainted) { Write-Host '[greeting] TAINTED - void, re-run.'; exit 2 }
if ($script:Fail.Count -gt 0) {
    Write-Host "[greeting] FAILED - $($script:Fail.Count) check(s):"
    foreach ($f in $script:Fail) { Write-Host "                 $f" }
    exit 1
}
Write-Host '[greeting] PASS - a fresh character is told how to start, once'
exit 0
