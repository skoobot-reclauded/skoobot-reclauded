<#
    Prove that every name the harness calls on the addon's runtime table
    actually exists on it (#216).

    The defect this exists for: `soak.ps1` called
    `skoobot_reclauded.cfg('TAKE_STAIRS')` to confirm a setting it had just
    written. `cfg` is not exported -- `src/data/cfg.lua` is a module and
    `ctx.cfg` is a field the act loop builds, but nothing puts a `cfg` function
    on the runtime table -- so `cfg and cfg(...)` short-circuited to nil, the
    line recorded `nil`, and the guard below it reported OK anyway. 145 runs
    across five sweeps said `(true nil)` and nobody could see it, because until
    #205 the soak transcript went to $null.

    A STATIC check cannot find these. `cfg` occurs as a name in `src/` -- in
    `settings.lua` and `cfg.lua` -- it is simply never exported, which no grep
    can distinguish from a real field. The question is only answerable by
    asking the table itself, at runtime, which is what this does.

    The list below is what a mechanical extraction over the Lua embedded in
    tools/*.ps1 finds, MINUS two prefixes that are not this table at all:

      config.settings.tome.skoobot_reclauded.X   the ACCOUNT SETTINGS table
      mod.dialogs.skoobot_reclauded.X            a module PATH in a require()

    Both look identical to a naive `skoobot_reclauded\.\w+` sweep, and both
    would be reported as phantoms by one. Regenerate with:

        python - <<'EOF'
        import io, re, glob
        pat = re.compile(r'((?:config\.settings\.tome\.|mod\.dialogs\.)?)'
                         r'skoobot_reclauded\.([A-Za-z_][A-Za-z0-9_]*)')
        out = set()
        for f in glob.glob('tools/*.ps1'):
            for line in io.open(f, encoding='utf-8', errors='replace'):
                for m in pat.finditer(line):
                    if not m.group(1): out.add(m.group(2))
        print('\n'.join(sorted(out)))
        EOF

    The extraction OVER-collects and the list is curated from it, not pasted:
    it cannot tell code from prose, so a name mentioned in a comment or inside
    a Lua string arrives looking like a call site. `log` was caught that way --
    "skoobot_reclauded.log (#46)" inside an error message read as a call, and
    the probe duly reported a phantom for a table that was there all along.
    `cfg` now appears only in two comments, which is why it is absent below.

    A stale list fails LOUD -- as a missing name -- which is the right
    direction: it asks to be looked at rather than going quiet.

    Run:
        powershell -ExecutionPolicy Bypass -File .\tools\scenario-bridge-surface.ps1
#>
[CmdletBinding()]
param(
    # The runtime table is built when the MODULE loads, so this needs a
    # character in play -- at the boot tier it does not exist yet and the probe
    # reports "no runtime table" for every name at once.
    [string]$SaveName = 'harness'
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'harness.ps1')

# Names the harness CALLS. These must be functions: a nil one is a phantom,
# and `x and x(...)` on it short-circuits to nil while the caller reports OK.
$CALLED = @(
    'data', 'greet', 'handleIncoming', 'inFlightPath', 'inspect', 'levelState',
    'markRefusedExit', 'nearestChest', 'needsConsent', 'ownPower', 'power', 'progressExit',
    'score', 'seekProgressExit', 'setCharSetting', 'setSetting', 'settingSource', 'start',
    'stop', 'suffocating', 'tooltip'
)

# Names reached as `X.member(...)`. The member call would error on a nil X, so
# these must exist -- but they are tables, not functions, and asserting
# "function" on them is how a check like this cries wolf. `log` earned its way
# into this list by being caught as a false positive first.
$TABLES = @('conditions', 'keybinds', 'loadout', 'log', 'notice', 'rules')

# Names read as plain fields. Reported, never failed: the addon assigns several
# only once the bot has run (`bot.last_reason` at Player.lua:340, `bot.threats`
# and `bot.threat_turn` at :2501-2502), and `last_reason` is declared `= nil` in
# the table's own initialiser. A nil here cannot be told from "not set yet", so
# failing on it would fire on every clean run.
$FIELDS = @(
    'actions', 'active', 'bestRecovery', 'last_reason', 'state', 'threat_turn',
    'threats'
)

$g = Load-Save -Name $SaveName
if (-not $g.Ready) { Write-Host "[surface] FAILED - could not load '$SaveName' ($($g.Reason))"; Stop-Game; exit 1 }
if ($g.Addons -notmatch 'skoobot_reclauded') { Write-Host "[surface] FAILED - the product is not loaded ($($g.Addons))"; Stop-Game; exit 1 }

try {
    $lua = @"
local b = rawget(_G, "skoobot_reclauded")
if not b then return "ERR no runtime table" end
local called = { "$($CALLED -join '", "')" }
local tables = { "$($TABLES -join '", "')" }
local fields = { "$($FIELDS -join '", "')" }
local bad, absent = {}, {}
for _, n in ipairs(called) do
  if type(b[n]) ~= "function" then bad[#bad+1] = n .. " is " .. type(b[n]) .. ", wanted function" end
end
for _, n in ipairs(tables) do
  if b[n] == nil then bad[#bad+1] = n .. " is nil, wanted a table" end
end
for _, n in ipairs(fields) do if b[n] == nil then absent[#absent+1] = n end end
local note = (#absent > 0) and ("; unset fields (expected before a run): " .. table.concat(absent, ",")) or ""
if #bad == 0 then return "OK " .. (#called + #tables) .. " names present" .. note end
return "PHANTOM " .. table.concat(bad, "; ") .. note
"@
    $r = Invoke-Bridge -Lua $lua -TimeoutSec 30
    Write-Host "[surface] $($r.Status) $($r.Result)"

    if ($r.Status -ne 'OK' -or "$($r.Result)" -notmatch '^OK ') {
        Write-Host '[surface] FAILED - a name the harness CALLS is not a function on the'
        Write-Host '          runtime table. Either the export was renamed or removed, or the'
        Write-Host '          caller is a phantom: a line that has always returned nil while'
        Write-Host '          reporting success (#216).'
        Stop-Game
        exit 1
    }
    Write-Host '[surface] PASS'
} finally {
    Stop-Game
}
exit 0
