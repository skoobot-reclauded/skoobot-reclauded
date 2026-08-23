<#
    Soak (#61): an unattended long run of the bot on the fixture, measured.

    The question this answers is not "does it pass" but "how far does it get,
    and what stops it": levels reached, turns taken, every stop reason with
    its count, every death with its killer, every Lua error the engine
    logged. That is the long-term replacement for the hand-played 1-to-15
    run the owner ruled out as a release gate (docs/release-0.1.md).

    The bot stops on purpose, often -- that is its design (docs/design-stop-
    conditions.md). A player restarts it; here a RESUME POLICY does, so the
    run keeps going and the stops are counted instead of ending the
    measurement at the first one. The policy is a measuring device and
    nothing else: it is NOT product behaviour, it never spends a point or
    writes a stat, and every action it takes is counted and reported so a
    number in the summary can be read for what it is.

      (a) a dialog is open   close it through its own EXIT bind (the level-up
                             dialog closes with nothing allocated; a popup
                             just closes). One with ACCEPT but no EXIT gets
                             ACCEPT ("accept-dialog"). A Chat has no binds
                             at all and cannot be escaped: its FIRST answer
                             is given through the dialog's own use(), the
                             method typing the answer's letter calls, and
                             the answer's text is reported ("answer-chat").
                             The death dialog is never touched: death ends
                             the run.
      (b) "standing on a     stairs DOWN, or into another non-wilderness
          level change"      zone: trigger the game's CHANGE_LEVEL bind once.
                             Stairs UP or into the wilderness: one real move
                             off the tile (the bot cannot run in the
                             wilderness, and up is not progress).
      (c) the same reason    REST through the game's bind, once; if it
          5 times in a row   recurs, one real move off the tile, once (the
          with no turn taken engine's auto-explore re-targets an ADJACENT
                             vault door forever; only distance breaks it);
                             if it still recurs with no turn taken, record
                             "STUCK <reason>" and end the run.
      (d) the player is dead record the killer (game.player.killedBy, which
                             onPartyDeath sets) and end.
      (e) anything else      skoobot_reclauded.start() again.

    By default the fixture's Combat, Sustain and Recovery rules are filled
    from what the character knows (-NoAutoRules to skip): every usable
    activated talent in id order, then the innate Attack, so a fresh fixture
    can fight at all. A player would do this from the talent screen; the
    rule set is crude and is part of what the run measures.

    The fixture is never overwritten. The game autosaves on every level
    change under game.save_name, so that is re-pointed at -ScratchSave
    ("soak-scratch") right after loading; the fixture directory is not
    touched and the scratch save is overwritten by the next run.

    Ends on -MaxMinutes, -MaxLevel, -MaxTurns (game.turn units: 10 per player
    turn), death, STUCK, a crash, or a bridge that stops answering. Writes a
    JSON summary to -OutFile (default build/results/soak-<stamp>.json), a
    markdown twin beside it, and prints the markdown.

    Exit codes:  0 the run ended by its own limits   1 it ended otherwise
                 (death, stuck, crash, bridge lost, could not load)
    A death is not a failure of the run -- it is the headline measurement --
    but exit 1 makes it visible to whatever scheduled the soak.

    Run:
        powershell -ExecutionPolicy Bypass -File .\tools\soak.ps1
        powershell -ExecutionPolicy Bypass -File .\tools\soak.ps1 -MaxMinutes 6
        powershell -ExecutionPolicy Bypass -File .\tools\soak.ps1 -MaxMinutes 240 -MaxLevel 15
        powershell -ExecutionPolicy Bypass -File .\tools\soak.ps1 -Conditions "SCOUTER_STRONGERENEMY=WARN,SCOUTER_BIGENEMY=WARN"

    The last form is for measuring past the product's own hand-back: the
    power-level conditions are STOP by default, and a STOP whose cause stays
    in view -- an enemy above MAX_DIFF_POWER -- stops every restart on the
    spot, by design, so a default run ends STUCK there. -Conditions sets the
    player's own WARN/STOP/IGNORE knobs for the run, through the product's
    conditions API, and the summary records what was set.

    #61, #27.
#>
[CmdletBinding()]
param(
    [string]$SaveName = 'fixture-berserker',
    [int]$MaxMinutes = 30,
    [int]$MaxLevel = 15,
    # game.turn units, 10 per player turn at normal speed; 0 = no limit.
    [int]$MaxTurns = 0,
    [string]$OutFile,
    [int]$PollSec = 4,
    [switch]$NoAutoRules,
    # The player's stop-condition policies for this run, "CODE=WARN|STOP|IGNORE,..."
    # (e.g. "SCOUTER_STRONGERENEMY=WARN,SCOUTER_BIGENEMY=WARN"), applied through
    # skoobot_reclauded.conditions.set and recorded in the summary.
    [string]$Conditions,
    [string]$ScratchSave = 'soak-scratch',
    # (c): how many identical stops with no turn taken before REST is tried.
    [int]$StuckAfter = 5
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'harness.ps1')

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
if (-not $OutFile) {
    if (-not (Test-Path $script:ResultsDir)) { New-Item -ItemType Directory -Path $script:ResultsDir -Force | Out-Null }
    $OutFile = Join-Path $script:ResultsDir "soak-$stamp.json"
}
$MdFile = [IO.Path]::ChangeExtension($OutFile, '.md')

Write-Host ''
Write-Host "[soak] save=$SaveName max=${MaxMinutes}m level>=$MaxLevel turns>=$MaxTurns poll=${PollSec}s out=$OutFile"

# ---------------------------------------------------------------------------
# The record. Everything below is what the JSON summary is made of.
# ---------------------------------------------------------------------------
$started   = Get-Date
$endReason = $null
$stops     = @{}        # reason -> @{count; severity; first_turn; last_turn}
$resumes   = @{}        # action -> count
$resumeLog = New-Object System.Collections.Generic.List[object]
$zones     = New-Object System.Collections.Generic.List[string]
$tainted   = $false
$polls     = 0
$bridgeMisses = 0
$first     = $null
$last      = $null
$peakLevel = 0      # NOT $maxLevel: PowerShell variables are case-insensitive, and that is the -MaxLevel parameter
$deaths    = 0
$killer    = $null
$stuckLabel = $null
$conditionsApplied = @()

function Count-Resume($action, $s, $reason) {
    if ($resumes.ContainsKey($action)) { $resumes[$action]++ } else { $resumes[$action] = 1 }
    $resumeLog.Add([pscustomobject]@{ turn = $s.turn; level = $s.level; zone = "$($s.zone):$($s.zlevel)"; action = $action; reason = $reason })
    Write-Host ('  resume   {0,-14} turn={1} L{2} {3}:{4}  {5}' -f $action, $s.turn, $s.level, $s.zone, $s.zlevel, $reason)
}

# Numbers vary per stop ("power level, 23.4, is above"); fold them so one
# reason is one row.
function Normalize-Reason([string]$r) {
    if (-not $r -or $r -eq 'nil') { return '(no reason)' }
    ($r -replace '\d+(\.\d+)?', '#').Trim()
}

# Parse "k=v|k=v|...|reason=<anything>" into an object.
function Parse-Status([string]$line) {
    $o = @{}
    if ($line -match '^(.*?)\|reason=(.*)$') { $head = $Matches[1]; $o.reason = $Matches[2] } else { $head = $line; $o.reason = '' }
    foreach ($kv in ($head -split '\|')) {
        if ($kv -match '^([a-z_]+)=(.*)$') { $o[$Matches[1]] = $Matches[2] }
    }
    foreach ($k in 'turn', 'level', 'zlevel', 'life', 'maxlife', 'ndialogs') {
        if ($o.ContainsKey($k) -and $o[$k] -match '^-?\d+') { $o[$k] = [int]$Matches[0] } elseif ($o.ContainsKey($k)) { $o[$k] = -1 }
    }
    [pscustomobject]$o
}

$exit = 1
try {
    $g = Load-Save -Name $SaveName
    if (-not $g.Ready) { Write-Host "[soak] FAILED - could not load '$SaveName' ($($g.Reason))"; $endReason = 'LOAD_FAILED'; exit 1 }
    if ($g.Addons -notmatch 'skoobot_reclauded') { Write-Host "[soak] FAILED - the product is not loaded ($($g.Addons))"; $endReason = 'LOAD_FAILED'; exit 1 }

    $install = Invoke-Bridge -Lua @"
_G.sk = {}
local b = rawget(_G, "skoobot_reclauded")
if not b then return "ERR no skoobot_reclauded runtime table" end

-- Autosaves go to a scratch save, never back onto the fixture.
game.save_name = "$ScratchSave"

function sk.stairs()
  local p = game.player
  if not p.x or not game.level then return "none" end
  local e = game.level.map(p.x, p.y, engine.Map.TERRAIN)
  if not e or not e.change_level then return "none" end
  if e.change_zone then
    if tostring(e.change_zone):find("^wilderness") then return "wild" end
    return "zone"
  end
  local target = e.change_level_abs and e.change_level or (game.level.level + e.change_level)
  if target > game.level.level then return "down" end
  return "up"
end

function sk.status()
  local p = game.player
  if not p then return "turn=-1|level=-1|zone=none|zlevel=-1|life=-1|maxlife=-1|active=false|dead=false|killer=|ndialogs=0|dialog=|stairs=none|reason=no player" end
  local d = game.dialogs and game.dialogs[#game.dialogs]
  local dtitle = d and sk.dialogName(d) or ""
  local killer = ""
  if p.dead and p.killedBy then killer = tostring(p.killedBy.name or "?") end
  return ("turn=%s|level=%s|zone=%s|zlevel=%s|life=%d|maxlife=%d|active=%s|dead=%s|killer=%s|ndialogs=%d|dialog=%s|stairs=%s|reason=%s"):format(
    tostring(game.turn), tostring(p.level), tostring(game.zone and game.zone.short_name or "none"),
    tostring(game.level and game.level.level or -1), math.floor(p.life or -1), math.floor(p.max_life or -1),
    tostring(b.active), tostring(p.dead and true or false), killer:gsub("|", "/"),
    game.dialogs and #game.dialogs or 0, dtitle:gsub("|", "/"), sk.stairs(), tostring(b.last_reason))
end

-- (a) the top dialog, through its own EXIT bind. Never the death dialog.
-- The title alone can be empty (QuestPopup, Chat), so the class is always
-- named too.
function sk.dialogName(d)
  local t = tostring(d.title or "")
  if t == "" then t = "(untitled)" end
  return t .. "/" .. tostring(d.__CLASSNAME or "?")
end
local function press(d, virtual)
  bridge.injecting = true
  local ok, err = pcall(d.key.triggerVirtual, d.key, virtual)
  bridge.injecting = false
  if not ok then return "error " .. tostring(err) end
  return nil
end
-- EXIT first. A dialog with no EXIT -- a Chat, whose answers are picked with
-- ACCEPT and which cannot be escaped -- gets ACCEPT, i.e. its first answer,
-- which is reported as such. Anything with neither is reported with the
-- binds it does have, and ends the run.
function sk.closeDialog()
  local d = game.dialogs and game.dialogs[#game.dialogs]
  if not d then return "none" end
  local name = sk.dialogName(d)
  if d.__CLASSNAME == "mod.dialogs.DeathDialog" then return "death" end
  local v = d.key and d.key.virtuals
  if v and v.EXIT then
    return press(d, "EXIT") or ("closed " .. name)
  end
  if v and v.ACCEPT then
    return press(d, "ACCEPT") or ("accepted " .. name)
  end
  -- A Chat has no binds at all: an answer is picked by typing its letter,
  -- which calls self:use(self.list[n]) (engine/dialogs/Chat.lua:49). The
  -- first answer, through that same method, and its text is reported.
  if d.use and type(d.list) == "table" and d.list[1] and tostring(d.__CLASSNAME or ""):find("Chat") then
    local item = d.list[1]
    bridge.injecting = true
    local ok, err = pcall(d.use, d, item)
    bridge.injecting = false
    if not ok then return "error " .. tostring(err) end
    return "answered " .. name .. " -> " .. tostring(item.name)
  end
  local keys = {}
  for k in pairs(v or {}) do keys[#keys+1] = tostring(k) end
  table.sort(keys)
  return "noexit " .. name .. " binds=" .. table.concat(keys, ",")
end

-- (b) one real move off a stair tile, to a free adjacent non-stair tile.
-- Up to three real moves, each to a free non-stair tile, preferring one
-- with no vault door beside it and stopping as soon as none is. The
-- engine's auto-explore re-targets a vault door whenever the player is
-- next to it, diagonals included (PlayerExplore.lua:1861), so one step
-- that lands on the door's other neighbour changes nothing.
local function besideVaultDoor(x, y)
  for _, c in pairs(util.adjacentCoords(x, y)) do
    local t = game.level.map(c[1], c[2], engine.Map.TERRAIN)
    if t and (t.door_player_check or t.door_player_stop) then return true end
  end
  return false
end
function sk.stepOff()
  local p = game.player
  local moves = 0
  for step = 1, 3 do
    local best, bestBeside
    for _, c in pairs(util.adjacentCoords(p.x, p.y)) do
      local x, y = c[1], c[2]
      if game.level.map:isBound(x, y) and not game.level.map:checkAllEntities(x, y, "block_move")
         and not game.level.map(x, y, engine.Map.ACTOR)
         and not game.level.map:checkEntity(x, y, engine.Map.TERRAIN, "change_level") then
        local beside = besideVaultDoor(x, y)
        if not best or (bestBeside and not beside) then best, bestBeside = c, beside end
      end
    end
    if not best then break end
    if not p:move(best[1], best[2]) then break end
    moves = moves + 1
    if not besideVaultDoor(p.x, p.y) then break end
  end
  p:playerFOV()
  if moves == 0 then return "nowhere" end
  return "moved " .. moves .. (besideVaultDoor(p.x, p.y) and " (still beside a sealed door)" or "")
end

function sk.start()
  if b.active then return "already active" end
  b.start()
  return "started active=" .. tostring(b.active) .. " reason=" .. tostring(b.last_reason)
end

-- The rules a player would have set: what the character can fire, then the
-- innate Attack last; sustains kept up; inscriptions that need no target as
-- recovery and damage prevention.
function sk.rules()
  local p = game.player
  local r = b.rules.get(p)
  for _, s in ipairs(b.rules.module.SECTIONS) do
    local l = r[s]
    for i = #l, 1, -1 do l[i] = nil end
  end
  local combat, sustain, recover = {}, {}, {}
  for tid, _ in pairs(p.talents) do
    local t = p:getTalentFromId(tid)
    if t and not t.no_npc_use and not t.no_dumb_use and tid ~= "T_ATTACK" and t.hide ~= "always" then
      if t.mode == "activated" then
        if t.is_inscription and not t.requires_target then recover[#recover+1] = tid
        else combat[#combat+1] = tid end
      elseif t.mode == "sustained" then sustain[#sustain+1] = tid end
    end
  end
  table.sort(combat) table.sort(sustain) table.sort(recover)
  for _, tid in ipairs(combat) do b.rules.module.place(r, {tid=tid}, "Combat") end
  b.rules.module.place(r, {tid="T_ATTACK"}, "Combat")
  for _, tid in ipairs(sustain) do b.rules.module.place(r, {tid=tid}, "Sustain") end
  for _, tid in ipairs(recover) do
    b.rules.module.place(r, {tid=tid}, "Recovery")
    b.rules.module.place(r, {tid=tid}, "DamagePrevention")
  end
  return ("combat=%s sustain=%s recovery=%s"):format(
    table.concat(b.rules.tids(p, "Combat"), ","), table.concat(b.rules.tids(p, "Sustain"), ","),
    table.concat(b.rules.tids(p, "Recovery"), ","))
end
return "installed save_name=" .. tostring(game.save_name)
"@ -TimeoutSec 30
    if ($install.Status -ne 'OK' -or $install.Result -notmatch '^installed') {
        Write-Host "[soak] FAILED - helpers: $($install.Status) $($install.Result)"; $endReason = 'SETUP_FAILED'; exit 1
    }
    Write-Host "  $($install.Result)"

    if (-not $NoAutoRules) {
        $rules = Invoke-Bridge -Lua 'return sk.rules()' -TimeoutSec 30
        Write-Host "  rules    $($rules.Status) $($rules.Result)"
    }

    # The player's own stop-condition knobs, through the product's API. A
    # STOP condition whose cause stays in view -- an enemy above
    # MAX_DIFF_POWER, by default STOP -- stops every restart on the spot,
    # which is the product handing the game to the player as designed; a
    # run that wants to measure what happens past that point sets it to
    # WARN or IGNORE here, and the summary records that it did.
    if ($Conditions) {
        foreach ($pair in ($Conditions -split ',')) {
            if ($pair -match '^\s*([A-Z_]+)\s*=\s*(WARN|STOP|IGNORE)\s*$') {
                $code = $Matches[1]; $policy = $Matches[2]
                $cr = Invoke-Bridge -Lua "local c = skoobot_reclauded.conditions.get('$code') if not c then return 'ERR no condition $code' end skoobot_reclauded.conditions.set('$code', '$policy') return '$code=' .. skoobot_reclauded.conditions.get('$code').stoptype" -TimeoutSec 30
                Write-Host "  condition $($cr.Status) $($cr.Result)"
                if ($cr.Status -eq 'OK' -and $cr.Result -notmatch '^ERR') { $conditionsApplied += $cr.Result }
            } else {
                Write-Host "  condition IGNORED '$pair' (want CODE=WARN|STOP|IGNORE)"
            }
        }
    }

    # Any dialog left from the load is closed the way (a) closes them.
    $null = Invoke-Bridge -Lua 'local out = {} for i = 1, 5 do local r = sk.closeDialog() if r == "none" then break end out[#out+1] = r end return table.concat(out, "; ")' -TimeoutSec 30

    $deadline = $started.AddMinutes($MaxMinutes)
    $lastReason = $null; $lastStopTurn = -1; $sameCount = 0; $stuckStage = 0
    $s = $null

    $kick = Invoke-Bridge -Lua 'return sk.start()' -TimeoutSec 30
    Write-Host "  start    $($kick.Status) $($kick.Result)"
    if ($kick.Tainted) { $tainted = $true }

    while ($true) {
        Start-Sleep -Seconds $PollSec
        if (-not (Test-GameAlive)) { $endReason = 'CRASHED'; break }
        $r = Invoke-Bridge -Lua 'return sk.status()' -TimeoutSec 30
        if ($r.Status -ne 'OK') {
            $bridgeMisses++
            Write-Host "  poll     $($r.Status) ($bridgeMisses in a row)"
            if ($r.Status -eq 'CRASHED') { $endReason = 'CRASHED'; break }
            if ($bridgeMisses -ge 5) { $endReason = 'BRIDGE_LOST'; break }
            continue
        }
        $bridgeMisses = 0
        $polls++
        if ($r.Tainted) { $tainted = $true }
        $s = Parse-Status $r.Result
        if (-not $first) { $first = $s }
        $last = $s
        if ($s.level -gt $peakLevel) { $peakLevel = $s.level }
        $zl = "$($s.zone):$($s.zlevel)"
        if ($zones.Count -eq 0 -or $zones[$zones.Count - 1] -ne $zl) { $zones.Add($zl) }
        Write-Host ('  poll     turn={0} L{1} {2} life={3}/{4} active={5} dialogs={6} {7}' -f $s.turn, $s.level, $zl, $s.life, $s.maxlife, $s.active, $s.ndialogs, $(if ($s.active -eq 'true') { '' } else { "reason=$($s.reason)" }))

        # ----- ends -----
        if ($s.dead -eq 'true') {
            $deaths++
            $killer = $s.killer
            if (-not $killer) {
                $tailLog = @(Get-GameLogLines | Select-Object -Last 30)
                $killer = (@($tailLog | Where-Object { $_ -match 'kill|slain|die' } | Select-Object -Last 1) -join '')
            }
            $endReason = 'DEATH'; break
        }
        if ((Get-Date) -ge $deadline) { $endReason = 'MAX_MINUTES'; break }
        if ($MaxLevel -gt 0 -and $s.level -ge $MaxLevel) { $endReason = 'MAX_LEVEL'; break }
        if ($MaxTurns -gt 0 -and $s.turn -ge $MaxTurns) { $endReason = 'MAX_TURNS'; break }

        # ----- (a) a dialog: close it through its own key -----
        if ($s.ndialogs -gt 0) {
            $c = Invoke-Bridge -Lua 'return sk.closeDialog()' -TimeoutSec 30
            if ($c.Tainted) { $tainted = $true }
            if ($c.Result -eq 'death') { continue }   # the next poll sees dead=true
            if ($c.Result -match '^noexit') {
                Count-Resume 'dialog-stuck' $s $c.Result
                $stuckLabel = "STUCK dialog with neither EXIT nor ACCEPT: $($c.Result)"
                $endReason = 'STUCK'; break
            }
            $action = if ($c.Result -match '^accepted') { 'accept-dialog' } elseif ($c.Result -match '^answered') { 'answer-chat' } else { 'close-dialog' }
            Count-Resume $action $s "$($c.Result) (bot reason: $($s.reason))"
            continue
        }

        if ($s.active -eq 'true') { continue }

        # ----- inactive: record the stop -----
        $reason = Normalize-Reason $s.reason
        $sev = if ($s.reason -match '^(Stopped|Handed back|Cannot act)') { $Matches[1] } else { '?' }
        if ($stops.ContainsKey($reason)) {
            $stops[$reason].count++; $stops[$reason].last_turn = $s.turn
        } else {
            $stops[$reason] = @{ count = 1; severity = $sev; first_turn = $s.turn; last_turn = $s.turn }
        }
        if ($reason -eq $lastReason -and $s.turn -eq $lastStopTurn) { $sameCount++ } else { $sameCount = 1; $stuckStage = 0 }
        $lastReason = $reason; $lastStopTurn = $s.turn

        # ----- (c) the same stop, no turn taken, again and again -----
        # Two rungs before giving up, each counted. REST first. Then one real
        # move off the tile: the engine's own auto-explore re-targets a vault
        # door whenever the player stands NEXT to it (PlayerExplore.lua:1861,
        # "if we are next to it, then we should try to open it"), so a bot
        # that handed back at the door prompt and was restarted on the same
        # tile walks into the same prompt forever, and only distance breaks
        # it -- the first validation run ended exactly there. Only if the
        # same reason recurs with no turn taken after both is it STUCK.
        if ($sameCount -ge $StuckAfter) {
            if ($stuckStage -eq 0) {
                $stuckStage = 1; $sameCount = 0
                $null = Invoke-Bridge -Lua 'return bridge.key("REST")' -TimeoutSec 30
                Count-Resume 'rest' $s "$reason ($StuckAfter in a row with no turn taken)"
                Start-Sleep -Seconds $PollSec
                $null = Invoke-Bridge -Lua 'return sk.start()' -TimeoutSec 30
                Count-Resume 'restart' $s $reason
                continue
            }
            if ($stuckStage -eq 1) {
                $stuckStage = 2; $sameCount = 0
                $so = Invoke-Bridge -Lua 'return sk.stepOff()' -TimeoutSec 30
                Count-Resume 'step-away' $s "$reason ($StuckAfter more with no turn taken; $($so.Result))"
                $null = Invoke-Bridge -Lua 'return sk.start()' -TimeoutSec 30
                Count-Resume 'restart' $s $reason
                continue
            }
            $stuckLabel = "STUCK $reason"
            $endReason = 'STUCK'; break
        }

        # ----- (b) stairs -----
        if ($s.reason -match 'standing on a level change') {
            if ($s.stairs -in @('down', 'zone')) {
                $cl = Invoke-Bridge -Lua 'return bridge.key("CHANGE_LEVEL")' -TimeoutSec 60
                Count-Resume "stairs-$($s.stairs)" $s "$($cl.Result)"
                # Level generation takes a moment; let the next poll find the new level.
                Start-Sleep -Seconds $PollSec
            } else {
                $so = Invoke-Bridge -Lua 'return sk.stepOff()' -TimeoutSec 30
                Count-Resume "step-off-$($s.stairs)" $s "$($so.Result)"
            }
            $null = Invoke-Bridge -Lua 'return sk.start()' -TimeoutSec 30
            Count-Resume 'restart' $s $reason
            continue
        }

        # ----- (e) anything else: start again -----
        $st = Invoke-Bridge -Lua 'return sk.start()' -TimeoutSec 30
        if ($st.Tainted) { $tainted = $true }
        Count-Resume 'restart' $s $reason
    }
    if ($endReason -in @('MAX_MINUTES', 'MAX_LEVEL', 'MAX_TURNS')) { $exit = 0 }
}
finally {
    # The engine's own complaints, from the whole run's log, before it goes.
    $luaErrors = @()
    try {
        $log = Get-GameLogLines
        for ($i = 0; $i -lt $log.Count; $i++) {
            if ($log[$i] -match 'Lua Error') {
                $ctx = @(); for ($j = $i; $j -lt [math]::Min($i + 4, $log.Count); $j++) { $ctx += $log[$j].Trim() }
                $luaErrors += ($ctx -join ' // ')
            }
        }
    } catch { }
    $null = Invoke-Bridge -Lua 'if skoobot_reclauded and skoobot_reclauded.active then skoobot_reclauded.stop("soak ended") end return "stopped"' -TimeoutSec 15 -ErrorAction SilentlyContinue
    Stop-Game

    $ended = Get-Date
    $wall = [math]::Round(($ended - $started).TotalSeconds)
    $stopRows = @($stops.Keys | ForEach-Object {
        [ordered]@{ reason = $_; count = $stops[$_].count; severity = $stops[$_].severity; first_turn = $stops[$_].first_turn; last_turn = $stops[$_].last_turn }
    } | Sort-Object { -$_.count }, { $_.reason })
    $resumeRows = @($resumes.Keys | Sort-Object | ForEach-Object { [ordered]@{ action = $_; count = $resumes[$_] } })
    $summary = [ordered]@{
        save         = $SaveName
        started      = $started.ToString('o')
        ended        = $ended.ToString('o')
        wall_seconds = $wall
        end_reason   = $endReason
        stuck        = $stuckLabel
        limits       = [ordered]@{ max_minutes = $MaxMinutes; max_level = $MaxLevel; max_turns = $MaxTurns }
        turns        = [ordered]@{ start = $(if ($first) { $first.turn } else { -1 }); end = $(if ($last) { $last.turn } else { -1 }); delta = $(if ($first -and $last) { $last.turn - $first.turn } else { 0 }) }
        level        = [ordered]@{ start = $(if ($first) { $first.level } else { -1 }); end = $(if ($last) { $last.level } else { -1 }); max = $peakLevel }
        zones        = @($zones)
        deaths       = $deaths
        killer       = $killer
        stops        = @($stopRows)
        stop_total   = ($stopRows | ForEach-Object { $_.count } | Measure-Object -Sum).Sum
        resumes      = [ordered]@{ total = ($resumeRows | ForEach-Object { $_.count } | Measure-Object -Sum).Sum; by_action = @($resumeRows); log = @($resumeLog | Select-Object -Last 200) }
        lua_errors   = [ordered]@{ count = $luaErrors.Count; samples = @($luaErrors | Select-Object -First 10) }
        tainted      = $tainted
        polls        = $polls
        auto_rules   = (-not $NoAutoRules)
        conditions   = @($conditionsApplied)
        scratch_save = $ScratchSave
    }
    $dir = Split-Path -Parent $OutFile
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    ($summary | ConvertTo-Json -Depth 6) | Set-Content -Path $OutFile -Encoding utf8

    $md = New-Object System.Collections.Generic.List[string]
    $md.Add("# Soak: $SaveName, $($started.ToString('yyyy-MM-dd HH:mm'))")
    $md.Add('')
    $md.Add('| measure | value |')
    $md.Add('|---|---|')
    $md.Add("| ended | $endReason$(if ($stuckLabel) { " ($stuckLabel)" }) |")
    $md.Add("| wall-clock | $wall s of $($MaxMinutes * 60) s |")
    $md.Add("| game.turn | $($summary.turns.start) -> $($summary.turns.end) (+$($summary.turns.delta), ~$([math]::Floor($summary.turns.delta / 10)) player turns) |")
    $md.Add("| level | $($summary.level.start) -> $($summary.level.end) (max $peakLevel, limit $MaxLevel) |")
    $md.Add("| zones | $($zones -join ' > ') |")
    $md.Add("| deaths | $deaths$(if ($killer) { " (killed by $killer)" }) |")
    $md.Add("| stops | $($summary.stop_total) across $($stopRows.Count) reason(s) |")
    $md.Add("| resumes | $($summary.resumes.total) |")
    $md.Add("| Lua errors | $($luaErrors.Count) |")
    $md.Add("| tainted | $tainted |")
    $md.Add("| conditions | $(if ($conditionsApplied.Count -gt 0) { $conditionsApplied -join ', ' } else { 'defaults' }) |")
    $md.Add("| polls | $polls every $PollSec s |")
    $md.Add('')
    $md.Add('| stop reason | count | severity | first turn | last turn |')
    $md.Add('|---|---:|---|---:|---:|')
    foreach ($row in $stopRows) { $md.Add("| $($row.reason) | $($row.count) | $($row.severity) | $($row.first_turn) | $($row.last_turn) |") }
    $md.Add('')
    $md.Add('| resume action | count |')
    $md.Add('|---|---:|')
    foreach ($row in $resumeRows) { $md.Add("| $($row.action) | $($row.count) |") }
    if ($luaErrors.Count -gt 0) {
        $md.Add('')
        $md.Add('Lua errors (first 10):')
        foreach ($e in ($luaErrors | Select-Object -First 10)) { $md.Add("- ``$e``") }
    }
    ($md -join "`n") | Set-Content -Path $MdFile -Encoding utf8

    Write-Host ''
    foreach ($l in $md) { Write-Host $l }
    Write-Host ''
    Write-Host "[soak] summary written to $OutFile (and $MdFile)"
    if ($exit -eq 0) { Write-Host "[soak] DONE - ended on $endReason" } else { Write-Host "[soak] ENDED - $endReason$(if ($stuckLabel) { " ($stuckLabel)" })" }
}
exit $exit
