<#
    #120 regression: an enemy standing in a grid the player cannot enter must
    not stop the walk toward it.

    A creature that walks through walls -- a golem in an arena pillar, in the
    report -- occupies a grid A* will not route into. The approach step pathed
    to the target's OWN grid, so calc returned nil and the bot handed back with
    "no path to <name>" while standing a few steps away with every neighbouring
    grid free.

    The target's own grid stays the first choice, because the last step into it
    is how a melee attack happens (#81); only when that fails does the walk aim
    at the closest free grid beside it.

    Built by putting a wall under a real hostile rather than by summoning one
    into a vault: the terrain is cloned, swapped and restored, so it works in
    any zone and leaves nothing changed.

    Exit codes:  0 pass   1 fail   2 tainted   3 inconclusive

    Run:
        powershell -ExecutionPolicy Bypass -File .\tools\scenario-enemy-in-wall.ps1

    #120.
#>
[CmdletBinding()]
param([string]$SaveName = 'harness')

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'harness.ps1')

$script:Fail = @()
function Check($ok, $what) {
    if ($ok) { Write-Host "  PASS  $what" } else { Write-Host "  FAIL  $what"; $script:Fail += $what }
}

Write-Host ''
Write-Host '[enemy-in-wall] a hostile in an unenterable grid must not stop the approach (#120)'

try {
    $g = Load-Save -Name $SaveName
    if (-not $g.Ready) { Write-Host "[enemy-in-wall] FAILED - could not load '$SaveName' ($($g.Reason))"; exit 1 }
    Check ($g.Addons -match 'skoobot_reclauded') 'the product is loaded'

    $out = Invoke-Bridge -Lua @'
local p = game.player
local bot = skoobot_reclauded
local map = game.level.map
local r = {}
local function say(k, v) r[#r+1] = k .. "=" .. tostring(v) end

-- Put a hostile a few grids away, with room around it.
local ax, ay
for radius = 3, 6 do
  for _, d in ipairs(util.adjacentDirs()) do
    local cx, cy = p.x, p.y
    for _ = 1, radius do cx, cy = util.coordAddDir(cx, cy, d) end
    if map:isBound(cx, cy) and p:canMove(cx, cy) then
      local free = 0
      for _, d2 in ipairs(util.adjacentDirs()) do
        local nx, ny = util.coordAddDir(cx, cy, d2)
        if map:isBound(nx, ny) and p:canMove(nx, ny) then free = free + 1 end
      end
      if free >= 5 then ax, ay = cx, cy break end
    end
  end
  if ax then break end
end
if not ax then say("setup", "no open grid found"); return table.concat(r, "  ||  ") end

local Actor = require "mod.class.NPC"
local foe = game.zone:makeEntity(game.level, "actor", { type = "vermin" }, nil, true)
if not foe then say("setup", "makeEntity returned nothing"); return table.concat(r, "  ||  ") end
game.zone:addEntity(game.level, foe, "actor", ax, ay)
foe.faction = "enemies"
foe.name = "wallbound test dummy"

-- Turn the grid UNDER it into a wall: a clone of the current terrain with
-- block_move set, so it restores cleanly whatever zone this is.
local old = map(ax, ay, map.TERRAIN)
local wall = old:cloneFull()
wall.block_move = true
wall.does_block_move = true
wall.name = (old.name or "floor") .. " (test pillar)"
map(ax, ay, map.TERRAIN, wall)
map:redisplay()

say("foe_at", ax .. "," .. ay)
say("dist", core.fov.distance(p.x, p.y, ax, ay))
say("grid_enterable", p:canMove(ax, ay))

-- The bot must have something in Combat, or it hands back for that instead and
-- the approach code never runs. T_ATTACK is the engine's basic attack and is
-- melee, so closing the distance is the only way to use it -- exactly the
-- decision under test.
local d = bot.data(p)
local savedRules = d.autotalents
d.autotalents = { Combat = { { tid = "T_ATTACK" } }, DamagePrevention = {}, Recovery = {}, Sustain = {} }
say("has_attack", p:knowTalent("T_ATTACK") and true or false)

-- Ask the bot what it would do. do_nothing, so no turn passes.
local ld = game.uiset and game.uiset.logdisplay
local nlog = ld and ld.log and #ld.log or 0
local before = game.turn
local ok, err = pcall(function() bot.query() end)
local newlines = {}
if ld and ld.log then
  local n = math.min(#ld.log - nlog, 8)
  for i = n, 1, -1 do newlines[#newlines + 1] = (tostring(ld.log[i].str):gsub("#[^#]*#", "")) end
end
say("query_ok", ok)
say("query_err", err)
say("turn_moved", game.turn ~= before)
say("reason", bot.last_reason)
say("log", table.concat(newlines, " / "))

-- Put the world back.
d.autotalents = savedRules
map(ax, ay, map.TERRAIN, old)
if foe and not foe.dead then game.level:removeEntity(foe, true) end
map:redisplay()
say("restored", map(ax, ay, map.TERRAIN) == old)
return table.concat(r, "  ||  ")
'@

    Write-Host "  raw: $($out.Result)"
    if ($out.Tainted) { Write-Host '[enemy-in-wall] TAINTED'; exit 2 }

    $kv = @{}
    foreach ($pair in ($out.Result -split '\s+\|\|\s+')) {
        $i = $pair.IndexOf('=')
        if ($i -gt 0) { $kv[$pair.Substring(0, $i)] = $pair.Substring($i + 1) }
    }

    if ($kv.ContainsKey('setup')) {
        Write-Host "[enemy-in-wall] INCONCLUSIVE - could not build the situation: $($kv['setup'])"
        exit 3
    }
    if ($kv['grid_enterable'] -ne 'False' -and $kv['grid_enterable'] -ne 'false') {
        Write-Host "[enemy-in-wall] INCONCLUSIVE - the grid under the hostile is still enterable, so nothing was tested."
        exit 3
    }

    if ($kv['has_attack'] -ne 'true') {
        Write-Host '[enemy-in-wall] INCONCLUSIVE - the character does not know T_ATTACK, so no melee rotation could be set.'
        exit 3
    }
    # PROVES THE PATH WAS TAKEN. Without a rotation the bot hands back for that
    # instead and never reaches the approach at all -- which is what the first
    # run of this scenario did, reporting a clean pass having tested nothing.
    if ($kv['reason'] -match 'no Combat talent is configured') {
        Write-Host '[enemy-in-wall] INCONCLUSIVE - the bot stopped on the rotation, not the approach; nothing was tested.'
        exit 3
    }

    Check $true 'the hostile stands in a grid the player cannot enter'
    Check ($kv['query_ok'] -eq 'true') 'the decision did not error'
    Check ($kv['restored'] -eq 'true') 'the terrain was put back'
    Check ($kv['reason'] -notmatch 'no path to') "the bot does not hand back with 'no path to' (reason: $($kv['reason']))"
    Check ($kv['log'] -match 'would move') "the bot decides to close the distance (log: $($kv['log']))"

    if ($script:Fail.Count -gt 0) { Write-Host "[enemy-in-wall] FAILED - $($script:Fail.Count) check(s)"; exit 1 }
    Write-Host '[enemy-in-wall] PASS'
    exit 0
} catch {
    Write-Host "[enemy-in-wall] ERROR $_"
    exit 3
} finally {
    Stop-Game | Out-Null
}
