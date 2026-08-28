<#
    Can the aim caution ever price an ally? (#148)

    aimPointFor counts an ally only when the talent's TARGET TYPE declares
    `friendlyfire` (src/superload/mod/class/Player.lua). If most area talents
    do not declare it, the ally term is structurally zero, the escortee is
    invisible to the caution, and no A/B on escort self-kills can measure the
    fix -- it would be measuring a branch that never runs.

    This reads the module's own talent table and tabulates it. Read-only: it
    learns nothing, spawns nothing and moves nothing, so it needs no teardown.

    Named probe-* so run-scenarios does not collect it (#177's precedent):
    this is a question asked once, not a regression guard.
#>
param(
    [string]$SaveName = 'fixture-berserker'
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\harness.ps1"

Write-Host ''
Write-Host '[friendlyfire] can the aim caution ever price an ally? (#148)'

try {
    $g = Load-Save -Name $SaveName
    if (-not $g.Ready) { Write-Host "[friendlyfire] FAILED - could not load '$SaveName' ($($g.Reason))"; exit 1 }

    $out = Invoke-Bridge -TimeoutSec 180 -Lua @'
local p = game.player
local r = {}
local function say(k, v) r[#r+1] = k .. "=" .. tostring(v) end

-- The same footprint test the wiring uses; anything else is not searched.
local function isArea(typ)
  return (typ.ball or typ.cone or typ.line or typ.widebeam or typ.triangle or typ.wall) and true or false
end

local area, ff, sf, ffnum, sfnum = 0, 0, 0, 0, 0
local names = {}
for tid, t in pairs(p.talents_def or {}) do
  if type(t) == "table" and t.mode == "activated" and type(tid) == "string" then
    local okt, tg = pcall(p.getTalentTarget, p, t)
    if okt and type(tg) == "table" and not tg.multiple then
      local okty, typ = pcall(function() return engine.Target:getType(tg) end)
      if okty and type(typ) == "table" and isArea(typ) then
        area = area + 1
        if typ.friendlyfire then
          ff = ff + 1
          if type(typ.friendlyfire) == "number" then ffnum = ffnum + 1 end
          if #names < 6 then names[#names+1] = tid end
        end
        if typ.selffire then
          sf = sf + 1
          if type(typ.selffire) == "number" then sfnum = sfnum + 1 end
        end
      end
    end
  end
end

say("area_talents", area)
say("with_friendlyfire", ff)
say("with_selffire", sf)
say("friendlyfire_numeric", ffnum)
say("selffire_numeric", sfnum)
say("sample", table.concat(names, ","))
return table.concat(r, "  ||  ")
'@

    if ($out.Status -ne 'OK') { Write-Host "[friendlyfire] FAILED - bridge $($out.Status): $($out.Result)"; exit 1 }
    Write-Host "  raw: $($out.Result)"

    $kv = @{}
    foreach ($pair in ($out.Result -split '\s*\|\|\s*')) {
        $i = $pair.IndexOf('='); if ($i -gt 0) { $kv[$pair.Substring(0, $i)] = $pair.Substring($i + 1) }
    }
    $area = [int]$kv['area_talents']; $ff = [int]$kv['with_friendlyfire']; $sf = [int]$kv['with_selffire']
    Write-Host ''
    Write-Host ("  area-shaped activated talents in this module : {0}" -f $area)
    Write-Host ("  ... declaring friendlyfire (ally priced)     : {0} ({1:P0})" -f $ff, $(if ($area) { $ff / $area } else { 0 }))
    Write-Host ("  ... declaring selffire (self priced)         : {0} ({1:P0})" -f $sf, $(if ($area) { $sf / $area } else { 0 }))
    Write-Host ("  numeric (percent) rather than boolean        : friendlyfire {0}, selffire {1}" -f $kv['friendlyfire_numeric'], $kv['selffire_numeric'])
    if ($kv['sample']) { Write-Host ("  sample of the priced ones                    : {0}" -f $kv['sample']) }
    Write-Host ''
    if ($ff -eq 0) {
        Write-Host '[friendlyfire] VERDICT: the ally term is structurally ZERO -- no area talent in'
        Write-Host '               this module declares friendlyfire, so the escortee can never be'
        Write-Host '               priced and an escort-kill A/B cannot measure the caution.'
    } else {
        Write-Host ("[friendlyfire] VERDICT: reachable -- {0} of {1} area talents price an ally, so the" -f $ff, $area)
        Write-Host '               caution can fire. Whether it fires for the classes doing the killing'
        Write-Host '               is the next question.'
    }
} finally {
    Stop-Game
}
