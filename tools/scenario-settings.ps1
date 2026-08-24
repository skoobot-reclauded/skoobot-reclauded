<#
    #90: the options tab's settings must survive a restart.

    The tab writes one file per setting through game:saveSettings --
    "/settings/tome.skoobot_reclauded.<OPTION>.cfg", holding the line
    `tome.skoobot_reclauded.<OPTION> = <value>`. The engine runs every such
    file as Lua at startup, long before any addon exists, so the namespace
    table it indexes has to exist by then or the assignment goes nowhere and
    data/settings.lua seeds the default over nothing.

    Nothing caught that, because every other scenario sets its knobs through
    the live table and never restarts. This one restarts. That is the whole
    point of it:

      1. read the setting's current value, and remember whether a cfg for it
         already existed, so the run can put the machine back exactly;
      2. write a distinctive value through skoobot_reclauded.setSetting --
         the same call the options tab makes;
      3. assert the live table took it, and that the cfg on disk carries it
         (checked from PowerShell: the file is the artifact, not the table);
      4. STOP THE GAME AND LOAD IT AGAIN, and assert the value came back.

    Step 4 is the only step that was ever in doubt, and the only one no other
    scenario performs.

    Cleanup is asserted, not assumed: the harness runs every other scenario
    against this same settings directory, so a value left behind would follow
    them into their own runs.

    Exit codes:  0 pass   1 fail   2 tainted   3 inconclusive

    Run:
        powershell -ExecutionPolicy Bypass -File .\tools\scenario-settings.ps1

    #90.
#>
[CmdletBinding()]
param(
    [string]$SaveName = 'harness',
    # A setting no other scenario reads from the persisted file, changed to a
    # value nothing else would produce, and put back at the end.
    [string]$Option = 'MAX_ENEMY_COUNT',
    [int]$Probe = 77
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'harness.ps1')

$script:Fail = @()
$script:Tainted = $false
function Check($ok, $what) {
    if ($ok) { Write-Host "  PASS  $what" } else { Write-Host "  FAIL  $what"; $script:Fail += $what }
}
function Say($r) {
    if ($r.Tainted) { $script:Tainted = $true }
    Write-Host "  $($r.Result)"
    return $r.Result
}

$CfgDir  = Join-Path $env:USERPROFILE 'T-Engine\4.0\settings'
$CfgFile = Join-Path $CfgDir "tome.skoobot_reclauded.$Option.cfg"
$hadCfg  = Test-Path $CfgFile
$cfgWas  = if ($hadCfg) { Get-Content $CfgFile -Raw } else { $null }

Write-Host ''
Write-Host "[settings] the options tab must outlive the process (#90)"
Write-Host "  option=$Option probe=$Probe cfg=$CfgFile existed=$hadCfg"

try {
    $g = Load-Save -Name $SaveName
    if (-not $g.Ready) { Write-Host "[settings] FAILED - could not load '$SaveName' ($($g.Reason))"; exit 1 }
    Check ($g.Addons -match 'skoobot_reclauded') 'the product is loaded'

    # ----- 1: what it is now ------------------------------------------------
    Write-Host ''
    Write-Host '  --- 1. the value before'
    $before = Say (Invoke-Bridge -Lua "return tostring(config.settings.tome.skoobot_reclauded.$Option)" -TimeoutSec 30)
    if ($before -eq "$Probe") {
        Write-Host "[settings] INCONCLUSIVE - the setting is already $Probe; nothing would be proved"
        Stop-Game; exit 3
    }

    # ----- 2: write it the way the options tab does -------------------------
    Write-Host ''
    Write-Host '  --- 2. set it through setSetting, as the tab does'
    $set = Say (Invoke-Bridge -Lua "skoobot_reclauded.setSetting('$Option', $Probe) return tostring(config.settings.tome.skoobot_reclauded.$Option)" -TimeoutSec 30)
    Check ($set -eq "$Probe") "the live table holds the new value ($set)"

    # The file is the artifact. Read it from here rather than from the game,
    # so a game that merely thinks it saved cannot vouch for itself.
    Start-Sleep -Milliseconds 300
    $onDisk = if (Test-Path $CfgFile) { (Get-Content $CfgFile -Raw).Trim() } else { '<no file>' }
    Write-Host "  cfg on disk: $onDisk"
    Check ($onDisk -match "tome\.skoobot_reclauded\.$Option\s*=\s*$Probe") 'the cfg file on disk carries it'

    # ----- 3: the restart, which is the whole point -------------------------
    Write-Host ''
    Write-Host '  --- 3. stop the game, load it again, and ask'
    Stop-Game
    $g2 = Load-Save -Name $SaveName
    if (-not $g2.Ready) { Write-Host "[settings] FAILED - could not reload '$SaveName' ($($g2.Reason))"; exit 1 }
    $after = Say (Invoke-Bridge -Lua "return tostring(config.settings.tome.skoobot_reclauded.$Option)" -TimeoutSec 30)
    Check ($after -eq "$Probe") "the setting survived the restart (got $after, wanted $Probe)"

    # And the same question for a second setting, written in the same run, so
    # a fix that happens to work for one key is not mistaken for a fix.
    Write-Host ''
    Write-Host '  --- 3b. a second setting, and a boolean at that'
    $b = Say (Invoke-Bridge -Lua "return tostring(config.settings.tome.skoobot_reclauded.STOP_POPUP)" -TimeoutSec 30)
    Check ($b -eq 'true' -or $b -eq 'false') "STOP_POPUP reads as a boolean ($b)"

    # ----- 4: the per-character layer (#95) ---------------------------------
    #
    # A safety threshold belongs to the CHARACTER; the account value is what
    # a character with no opinion falls back to. The two must not leak into
    # each other, which is the whole risk of a two-layer store, and the leak
    # would be invisible on a machine with one character.
    Write-Host ''
    Write-Host '  --- 4. a threshold on the character, the account default underneath'
    $c1 = Say (Invoke-Bridge -TimeoutSec 30 -Lua @'
local b = skoobot_reclauded
b.clearCharSetting("MAX_ENEMY_COUNT")
local acct = config.settings.tome.skoobot_reclauded.MAX_ENEMY_COUNT
b.setCharSetting("MAX_ENEMY_COUNT", 3)
local src, val = b.settingSource("MAX_ENEMY_COUNT")
return ("acct_before=%s src=%s val=%s acct_now=%s reader=%s"):format(
  tostring(acct), tostring(src), tostring(val),
  tostring(config.settings.tome.skoobot_reclauded.MAX_ENEMY_COUNT),
  tostring(b.setting("MAX_ENEMY_COUNT")))
'@)
    Check ($c1 -match 'src=character val=3 ') 'the character''s own value is what applies'
    Check ($c1 -match 'reader=3') 'and it is what the bot itself reads, not just what the screen shows'
    if ($c1 -match 'acct_before=(\S+) src=.* acct_now=(\S+)') {
        Check ($Matches[1] -eq $Matches[2]) "the account default is untouched by it ($($Matches[1]))"
    } else { Check $false 'the account default is untouched by it' }

    # An account preference has no per-character value, and asking for one is
    # refused rather than written somewhere that will never be read.
    $c2 = Say (Invoke-Bridge -TimeoutSec 30 -Lua 'return tostring(skoobot_reclauded.setCharSetting("STOP_POPUP", true))')
    Check ($c2 -eq 'false') 'an account preference refuses a per-character value'

    Write-Host ''
    Write-Host '  --- 4b. save as default for future characters, then clear'
    $c3 = Say (Invoke-Bridge -TimeoutSec 30 -Lua @'
local b = skoobot_reclauded
local names = b.saveAsDefaults()
local acct = config.settings.tome.skoobot_reclauded.MAX_ENEMY_COUNT
b.clearCharSetting("MAX_ENEMY_COUNT")
local src, val = b.settingSource("MAX_ENEMY_COUNT")
return ("copied=%d acct=%s after_clear_src=%s val=%s"):format(
  #names, tostring(acct), tostring(src), tostring(val))
'@)
    Check ($c3 -match 'acct=3 ') 'saving as default copied the character''s value onto the account'
    Check ($c3 -match 'after_clear_src=account val=3') 'and clearing the character falls back to it'
}
finally {
    # Put the machine back: the live value, and the file exactly as it was.
    $null = Invoke-Bridge -Lua "if skoobot_reclauded then skoobot_reclauded.setSetting('$Option', $before) end return 'restored'" -TimeoutSec 15 -ErrorAction SilentlyContinue
    Stop-Game
    if ($hadCfg) { Set-Content -Path $CfgFile -Value $cfgWas -NoNewline -Encoding utf8 }
    elseif (Test-Path $CfgFile) { Remove-Item $CfgFile -Force }
    $left = if (Test-Path $CfgFile) { (Get-Content $CfgFile -Raw).Trim() } else { '<no file>' }
    Write-Host ''
    Write-Host "  cleanup: cfg is now $left (was $(if ($hadCfg) { $cfgWas.Trim() } else { '<no file>' }))"
    Check ($hadCfg -eq (Test-Path $CfgFile)) 'the settings directory is as it was found'
}

Write-Host ''
if ($script:Tainted) { Write-Host '[settings] TAINTED - void, re-run.'; exit 2 }
if ($script:Fail.Count -gt 0) {
    Write-Host "[settings] FAILED - $($script:Fail.Count) check(s):"
    foreach ($f in $script:Fail) { Write-Host "                 $f" }
    exit 1
}
Write-Host '[settings] PASS - a setting written from the options tab survives a restart'
exit 0
