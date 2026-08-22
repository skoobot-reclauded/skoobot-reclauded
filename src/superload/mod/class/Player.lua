-- SkooBot: Reclauded -- the act loop.
--
-- Copyright (C) 2018-2020 SkoobyDoo (SkooBot 0.0.12, superload/mod/class/Player.lua)
-- Copyright (C) 2026 SkoobyDoo
--
-- This program is free software: you can redistribute it and/or modify it
-- under the terms of the GNU General Public License as published by the Free
-- Software Foundation, either version 3 of the License, or (at your option)
-- any later version. See LICENSE.
--
-- spotHostiles follows ToME's own resting checks (Nicolas Casalini, GPL-3.0):
-- line of sight rather than telepathy, so that having telepathy does not
-- stop the bot resting.
--
-- ---------------------------------------------------------------------------
--
-- PORTED FROM SkooBot 0.0.12 (D-12). The decision logic is the original's,
-- deliberately unchanged, so that the port can be measured against the
-- original for parity before anything is fixed. Where a line of the original
-- was a known bug, it is reproduced faithfully and marked `-- v1:` with the
-- task that fixes it; do not "tidy" those in passing, fix them under their
-- task with a test.
--
-- What did change, and why:
--
-- * Nothing is added to mod.class.Player except the two wrapped methods at
--   the bottom (act, postUseTalent). The original added a dozen methods to
--   the class -- checkStop, tryStop, getStopConditionList, ... -- and the
--   original is still installed by real people. Two addons defining the same
--   method on the same class means the one loaded last silently wins, so
--   nothing here may carry a name the original uses. State lives in the
--   `skoobot_reclauded` runtime table, config on `player.skoobot_reclauded`.
--   This is also the T-021 direction: the superload surface is now three
--   methods across two classes, all of them wrappers.
-- * The original leaked four functions into _G (aiStop, checkForAdditionalAction,
--   getUnspentTotal, skoobot_act). They are locals here.
-- * Power scoring moved to data/power.lua, a pure module busted can test.
-- * SAI_passTurn is gone: its only call in the original sat after two branches
--   that both return, so it could never run.
-- * Everything the harness needs to observe the bot -- inspect(), actions,
--   last_reason -- is on the runtime table, as the walking skeleton had it.

local Astar = require "engine.Astar"

local _M = loadPrevious(...)

local power = dofile("/data-skoobot_reclauded/power.lua")

local STATE_REST    = 10
local STATE_EXPLORE = 11
local STATE_HUNT    = 12
local STATE_FIGHT   = 13

-- v1: thinkCount > 25 and turnCount > 1000, both invocation counts rather
-- than progress. T-027 replaces them with a progress invariant.
local THINK_LIMIT = 25
local TURN_LIMIT  = 1000

-- The runtime table. Transient: none of this is saved with the character.
local bot = {
    active       = false,
    state        = STATE_REST,   -- v1 tempvals.state, kept between activations
    do_nothing   = false,        -- v1 tempvals.do_nothing: query mode
    runonce      = false,        -- v1 tempvals.runonce
    actions      = 0,            -- not in v1: how many actions this activation took
    last_reason  = nil,          -- not in v1: why the bot last stopped
    activation   = nil,          -- v1 tempActivation: per-activation counters
    loop         = nil,          -- v1 tempLoop: per-iteration scratch
    prevloop     = nil,          -- v1 tempPrevLoop
    nearest_hostile_distance = nil,
    action_timer = false,        -- v1 player.skoobotactiontimer (see scheduleAction)
}
_G.skoobot_reclauded = bot

-- Forward declarations for the mutually recursive core.
local skoobot_act, checkForAdditionalAction, aiStop

local function cfg(key)
    local s = config.settings.tome.skoobot_reclauded
    return s and s[key]
end

local function log(msg)
    print("[SKOOBOT] " .. msg)
end

-- Strip ToME colour codes for the harness-facing reason string.
local function plain(s)
    return (tostring(s):gsub("#[^#]*#", ""))
end

--- Per-character configuration, persisted with the save.
--
-- v1 scattered this over four player fields (skoobotautotalents,
-- skoobotstopconditions, skoobotstopwarn, skoobotactiontimer). One table under
-- a name the original does not use keeps the two addons' saves apart.
local function data(p)
    p = p or game.player
    if not p.skoobot_reclauded then p.skoobot_reclauded = {} end
    local d = p.skoobot_reclauded
    if not d.autotalents then d.autotalents = {} end
    return d
end
bot.data = data

-------------------------------------------------------------------------------
-- Stop conditions (v1 getStopConditionList & co.)
-------------------------------------------------------------------------------

local DEFAULT_CONDITIONS = {
    {label="Debuff: STUNNED",           code="DEBUFF_STUNNED",        stoptype="WARN"},
    {label="Debuff: CONFUSED",          code="DEBUFF_CONFUSED",       stoptype="WARN"},
    {label="Debuff: DAZED",             code="DEBUFF_DAZED",          stoptype="WARN"},
    {label="Debuff: FROZEN",            code="DEBUFF_FROZEN",         stoptype="WARN"},
    {label="Debuff: ASLEEP",            code="DEBUFF_ASLEEP",         stoptype="WARN"},

    {label="Life: BIGLOSS",             code="LIFE_BIGLOSS",          stoptype="WARN"},
    {label="Life: LOWLIFE",             code="LIFE_LOWLIFE",          stoptype="STOP"},

    {label="Dialog: LORE",              code="DIALOG_LORE",           stoptype="IGNORE"},

    {label="Power Level: ENEMYCOUNT",   code="SCOUTER_ENEMYCOUNT",    stoptype="STOP"},
    {label="Power Level: BIGENEMY",     code="SCOUTER_BIGENEMY",      stoptype="STOP"},
    {label="Power Level: STRONGERENEMY",code="SCOUTER_STRONGERENEMY", stoptype="STOP"},
    {label="Power Level: CROWDPOWER",   code="SCOUTER_CROWDPOWER",    stoptype="STOP"},
}

-- v1: written to the save once and never reconciled, so a character never
-- gains a condition added later and never loses one removed. T-026.
local function getStopConditionList(p)
    local d = data(p)
    if not d.stopconditions then
        d.stopconditions = {}
        for i, c in ipairs(DEFAULT_CONDITIONS) do
            d.stopconditions[i] = {label=c.label, code=c.code, stoptype=c.stoptype}
        end
    end
    return d.stopconditions
end

-- v1: returns nil for an unknown code, and the callers index the result.
-- T-026 makes this fail closed.
local function getStopCondition(p, code)
    for index, v in ipairs(getStopConditionList(p)) do
        if v.code == code then return v, index end
    end
    log("[StopConditions] [ERROR] Attempt to fetch nonexistent stop condition: " .. tostring(code))
end

local function setStopCondition(p, code, stoptype)
    local v, index = getStopCondition(p, code)
    getStopConditionList(p)[index] = {label=v.label, code=code, stoptype=stoptype}
end

bot.conditions = {
    list = function() return getStopConditionList(game.player) end,
    get  = function(code) return getStopCondition(game.player, code) end,
    set  = function(code, stoptype) return setStopCondition(game.player, code, stoptype) end,
}

function aiStop(msg)
    bot.active = false
    bot.state = STATE_REST
    bot.activation = nil
    bot.loop = nil
    bot.prevloop = nil
    bot.last_reason = plain(msg or "AI Stopping!")
    game.log((msg ~= nil and msg) or "#LIGHT_RED#AI Stopping!")
end

-- Tries to stop the bot, returning true. A condition set to IGNORE is
-- disregarded and returns false.
--
-- v1 named its parameter `stoptype` and then shadowed it with the policy, so
-- the diagnostic printed "Ignoring stop condition: IGNORE" instead of the
-- condition's name. The parameter is `code` here and the message names it.
local function tryStop(p, code, msg)
    local stoptype = getStopCondition(p, code).stoptype
    if stoptype == "IGNORE" then
        log("[StopConditions] [HIGHLIGHT] Ignoring stop condition: " .. tostring(code))
        return false
    end
    aiStop(msg)
    return true
end

-- Check `condition` to see whether the bot should stop. A WARN condition
-- stops once, is then remembered as acknowledged, and re-arms when it clears.
local function checkStop(p, stopcategory, condition, msg)
    local stoptype = getStopCondition(p, stopcategory).stoptype
    local d = data(p)

    if stoptype == "WARN" then
        if condition then
            if not d.stopwarn then d.stopwarn = {} end
            if d.stopwarn[stopcategory] == true then return false end
            d.stopwarn[stopcategory] = true
            return tryStop(p, stopcategory, msg)
        else
            if d.stopwarn then d.stopwarn[stopcategory] = nil end
            return false
        end
    end

    if condition then return tryStop(p, stopcategory, msg) end
    return false
end

-------------------------------------------------------------------------------
-- Per-activation and per-iteration scratch (v1 tempActivationInit / tempLoopInit)
-------------------------------------------------------------------------------

local function getUnspentTotal()
    local p = game.player
    return p.unused_talents + p.unused_generics + p.unused_talents_types + p.unused_stats + p.unused_prodigies
end

local function activationInit()
    return { turnCount = 0, unspentTotal = getUnspentTotal() }
end

local function loopInit()
    local loop = {}
    loop.thinkCount = 0
    loop.talentfailed = {}

    log("[Survival] Evaluating life change...")
    loop.delta = game.player.life - (bot.prevloop and bot.prevloop.life or game.player.life)
    loop.life = game.player.life
    if math.abs(loop.delta) > 0 then
        log("[Survival] Delta detected! = " .. loop.delta)
    end
    if (loop.delta < 0) and (math.abs(loop.delta) / game.player.max_life >= cfg("LOWHEALTH_RATIO") / 2) then
        -- v1: a stop here returns nil from the initialiser, leaving the loop
        -- table nil; the caller checks for that.
        if tryStop(game.player, "LIFE_BIGLOSS", "#RED#AI Stopped: Lost more than "
            .. math.floor(100 * cfg("LOWHEALTH_RATIO") / 2) .. "%% life in one turn!") then return end
    end
    return loop
end

local function initLoopTempVars()
    bot.prevloop = bot.loop or loopInit()
    bot.loop = loopInit()
end

local function aiStateString()
    if bot.state == STATE_REST then return "SAI_STATE_REST"
    elseif bot.state == STATE_EXPLORE then return "SAI_STATE_EXPLORE"
    elseif bot.state == STATE_HUNT then return "SAI_STATE_HUNT"
    elseif bot.state == STATE_FIGHT then return "SAI_STATE_FIGHT"
    end
    return "Unknown State"
end

-------------------------------------------------------------------------------
-- Actions (v1 SAI_*). In query mode they say what they would do instead.
-------------------------------------------------------------------------------

local function validateRest(turns)
    if turns and turns ~= 0 then
        game.log("#GOLD#AI Turns Rested: " .. tostring(turns))
    end
    bot.state = STATE_EXPLORE
end

local function SAI_useTalent(tid, who, force_level, ignore_cd, target)
    local name = game.player:getTalentFromId(tid).name
    if bot.do_nothing then
        game.log("[SkooBot] AI would use the talent " .. name .. " on target " .. (target and target.name or ""))
        return
    end
    log("[Action] Using Talent " .. name .. " on target " .. (target and target.name or ""))
    bot.actions = bot.actions + 1
    return game.player:useTalent(tid, who, force_level, ignore_cd, target)
end

local function SAI_movePlayer(x, y)
    local dir = game.level.map:compassDirection(x - game.player.x, y - game.player.y)
    if bot.do_nothing then
        game.log("[SkooBot] AI would move to the " .. dir)
        return
    end
    log("[Action] Moving to the " .. dir)
    bot.actions = bot.actions + 1
    return game.player:move(x, y)
end

local function SAI_beginExplore()
    if bot.do_nothing then
        game.log("[SkooBot] AI would begin exploring.")
        return
    end
    log("[Action] Beginning to explore.")
    bot.actions = bot.actions + 1
    if game.player:autoExplore() then
        return game.player:act()
    else
        return aiStop("#RED#AI Stopped: autoExplore returned false.")
    end
end

local function SAI_beginRest()
    if bot.do_nothing then
        game.log("[SkooBot] AI would begin resting.")
        return false
    end
    log("[Action] Beginning to rest.")
    bot.actions = bot.actions + 1
    game.player:restInit(nil, nil, nil, validateRest)
    return checkForAdditionalAction()
end

-------------------------------------------------------------------------------
-- Perception
-------------------------------------------------------------------------------

--- Hostile actors (and, unless actors_only, threatening projectiles) the
--- player can actually see. LOS only, on purpose.
local function spotHostiles(self, actors_only)
    local seen = {}
    if not self.x then return seen end

    core.fov.calc_circle(self.x, self.y, game.level.map.w, game.level.map.h, self.sight or 10,
        function(_, x, y) return game.level.map:opaque(x, y) end,
        function(_, x, y)
            local actor = game.level.map(x, y, game.level.map.ACTOR)
            if actor and self:reactionToward(actor) < 0 and self:canSee(actor) and game.level.map.seens(x, y) then
                seen[#seen + 1] = {x=x, y=y, actor=actor, entity=actor, name=actor.name}
            end
        end, nil)

    -- v1 wrote these into the loop scratch unconditionally; the guard only
    -- lets inspect() call this outside an activation.
    if bot.loop then
        bot.loop.sumVisibleEnemyPower = 0
        bot.loop.maxVisibleEnemyPower = 0
        bot.loop.enemyCount = #seen
        for _, a in ipairs(seen) do
            local pw = power.level(a.actor, game.player.global_speed)
            bot.loop.sumVisibleEnemyPower = bot.loop.sumVisibleEnemyPower + pw
            if bot.loop.maxVisibleEnemyPower < pw then
                bot.loop.maxVisibleEnemyPower = pw
            end
        end
    end

    if not actors_only then
        -- Projectiles in line of sight that are headed our way.
        core.fov.calc_circle(self.x, self.y, game.level.map.w, game.level.map.h, self.sight or 10,
            function(_, x, y) return game.level.map:opaque(x, y) end,
            function(_, x, y)
                local proj = game.level.map(x, y, game.level.map.PROJECTILE)
                if not proj or not game.level.map.seens(x, y) then return end

                -- trust ourselves but not our friends
                if proj.src and self == proj.src then return end
                local sx, sy = proj.start_x, proj.start_y
                local tx, ty

                -- Bresenham is too coarse; check if we are anywhere near the
                -- mathematical line of flight.
                if type(proj.project) == "table" then
                    tx, ty = proj.project.def.x, proj.project.def.y
                elseif proj.homing then
                    tx, ty = proj.homing.target.x, proj.homing.target.y
                end
                if tx and ty then
                    local dist_to_line = math.abs((self.x - sx) * (ty - sy) - (self.y - sy) * (tx - sx))
                        / core.fov.distance(sx, sy, tx, ty)
                    local our_way = ((self.x - x) * (tx - x) + (self.y - y) * (ty - y)) > 0
                    if our_way and dist_to_line < 1.0 then
                        seen[#seen + 1] = {x=x, y=y, projectile=proj, entity=proj,
                            name=(proj.getName and proj:getName()) or proj.name}
                    end
                end
            end, nil)
    end
    return seen
end

local function getPathToAir(self)
    local seen = {}
    if not self.x then return nil end

    core.fov.calc_circle(self.x, self.y, game.level.map.w, game.level.map.h, self.sight or 10,
        function(_, x, y) return game.level.map:opaque(x, y) end,
        function(_, x, y)
            local terrain = game.level.map(x, y, game.level.map.TERRAIN)
            -- v1: no reachability check; a tile of air behind a wall is chosen
            -- and the path fails. T-015.
            if not terrain.air_level or terrain.air_level > 0 then
                seen[#seen + 1] = {x=x, y=y, terrain=terrain}
            end
        end, nil)

    local min_dist = math.huge
    local close_coord = nil
    for _, coord in pairs(seen) do
        local dist = math.abs(coord.x - self.x) + math.abs(coord.y - self.y)
        if dist < min_dist then
            min_dist = dist
            close_coord = coord
        end
    end

    if close_coord ~= nil then
        local a = Astar.new(game.level.map, self)
        return a:calc(self.x, self.y, close_coord.x, close_coord.y)
    end
    return nil
end

local function getNearestHostile()
    local seen = spotHostiles(game.player, true)
    local target = nil
    local targetdist = nil
    for _, enemy in pairs(seen) do
        local nextdist = core.fov.distance(game.player.x, game.player.y, enemy.x, enemy.y)
        if target == nil or nextdist < targetdist then
            targetdist = nextdist
            target = enemy
        end
    end
    bot.nearest_hostile_distance = targetdist
    return target
end

local function getLowestHealthEnemy(enemySet)
    local low_mark = math.huge
    local target = nil
    for _, enemy in pairs(enemySet) do
        if enemy.actor.life < low_mark then
            low_mark = enemy.actor.life
            target = enemy
        end
    end
    return target
end

local function getDirNum(src, dst)
    local dx = dst.x - src.x
    if dx ~= 0 then dx = dx / dx end
    local dy = dst.y - src.y
    if dy ~= 0 then dy = dy / dy end
    return util.coordToDir(dx, dy)
end

-------------------------------------------------------------------------------
-- Talents
-------------------------------------------------------------------------------

local function getTalents()
    local talents = {}
    for k, _ in pairs(game.player.talents) do
        talents[#talents + 1] = k
    end
    return talents
end

--- Drop configured talents the character no longer has.
local function pruneAutoTalents(p)
    local auto = data(p).autotalents
    local badindexes = {}
    for index, info in ipairs(auto) do
        if not p.talents[info.tid] then
            log("[TalentList] [WARN] Attempt to fetch missing talent: " .. tostring(info.tid))
            badindexes[#badindexes + 1] = index
        end
    end
    for i = #badindexes, 1, -1 do
        table.remove(auto, badindexes[i])
    end
end
bot.talents = { prune = function() return pruneAutoTalents(game.player) end }

--- The threat score of an actor, as the stop conditions see it (the player
--- by default). For the harness and for bug reports.
function bot.power(actor)
    return power.level(actor or game.player, game.player.global_speed)
end

--- Configured talent ids of one use type, highest priority first.
local function getAutoTalents(usetype)
    local talents = {}
    pruneAutoTalents(game.player)
    local tbl = {}
    for _, v in pairs(data(game.player).autotalents) do
        table.insert(tbl, v)
    end
    table.sort(tbl, function(a, b) return a.priority > b.priority end)
    for _, entry in ipairs(tbl) do
        if entry.usetype == usetype then
            talents[#talents + 1] = entry.tid
        end
    end
    return talents
end

local function getCombatTalents()      return getAutoTalents("Combat") end
local function getSustainableTalents() return getAutoTalents("Sustain") end
local function getSustainTalents()     return getAutoTalents("DamagePrevention") end
local function getRecoveryTalents()    return getAutoTalents("Recovery") end

-- TODO (v1): exclude enemies in LOS but not LOE -- cannot Rush over pits, and
-- someone standing in front of the target blocks a non-piercing attack.
local function getAvailableTalents(target, talentsToUse)
    local avail = {}
    local tx, ty
    if target ~= nil then
        tx = target.x
        ty = target.y
    end
    local theseTalents = talentsToUse or getTalents()
    for _, tid in pairs(theseTalents) do
        local t = game.player:getTalentFromId(tid)
        -- For dumb AI assume we need range and LOS; no special check for bolts.
        local total_range = (game.player:getTalentRange(t) or 0) + (game.player:getTalentRadius(t) or 0)
        local tg = {type=util.getval(t.direct_hit, game.player, t) and "hit" or "bolt", range=total_range}
        if t.mode == "activated" and not t.no_npc_use and not t.no_dumb_use and
           not game.player:isTalentCoolingDown(t) and game.player:preUseTalent(t, true, true) and
           (target ~= nil and not game.player:getTalentRequiresTarget(t) or game.player:canProject(tg, tx, ty))
           then
            avail[#avail + 1] = tid
            log("[AvailableTalentFilter] " .. game.player.name .. " can use " .. t.name .. " " .. tid)
        elseif t.mode == "sustained" and not t.no_npc_use and not t.no_dumb_use and
           not game.player:isTalentCoolingDown(t) and
           not game.player:isTalentActive(t.id) and
           game.player:preUseTalent(t, true, true)
           then
            avail[#avail + 1] = tid
        else
            log("[AvailableTalentFilter] Excluding talent: " .. tid .. ", cannot be used on "
                .. (target ~= nil and target.name or "nil"))
        end
    end
    return avail
end

local function filterFailedTalents(t)
    local out = {}
    for _, v in pairs(t) do
        if not game.player:isTalentCoolingDown(game.player:getTalentFromId(v)) and bot.loop.talentfailed[v] == nil then
            out[#out + 1] = v
        end
    end
    return out
end

-- Returns true if anything was sustained.
local function activateSustained()
    local talents = filterFailedTalents(getSustainableTalents())
    for _, tid in pairs(talents) do
        local t = game.player:getTalentFromId(tid)
        log("[Sustain] Attempting to sustain: " .. tid)
        if t.mode == "sustained" and game.player.sustain_talents[tid] == nil then
            if SAI_useTalent(tid) then
                checkForAdditionalAction()
                return true
            end
        end
    end
    return false
end

-------------------------------------------------------------------------------
-- Checks
-------------------------------------------------------------------------------

local function checkPowerLevel()
    local myPowerLevel = power.level(game.player, game.player.global_speed)
    local p = game.player
    if checkStop(p, "SCOUTER_BIGENEMY",
        bot.loop.maxVisibleEnemyPower > cfg("MAX_INDIVIDUAL_POWER"),
        "Max enemy power level too high: " .. bot.loop.maxVisibleEnemyPower) then
        return true
    end
    if checkStop(p, "SCOUTER_STRONGERENEMY",
        bot.loop.maxVisibleEnemyPower > myPowerLevel + cfg("MAX_DIFF_POWER"),
        "Max enemy power level too much stronger than player: "
            .. bot.loop.maxVisibleEnemyPower .. " > " .. myPowerLevel) then
        return true
    end
    if checkStop(p, "SCOUTER_CROWDPOWER",
        bot.loop.sumVisibleEnemyPower > cfg("MAX_COMBINED_POWER"),
        "Combined enemy power level too high: " .. bot.loop.sumVisibleEnemyPower) then
        return true
    end
    if checkStop(p, "SCOUTER_ENEMYCOUNT",
        bot.loop.enemyCount > cfg("MAX_ENEMY_COUNT"),
        "Too many enemies in sight: " .. bot.loop.enemyCount) then
        return true
    end
    return false
end

local function checkForDebuffs()
    local p = game.player
    if checkStop(p, "DEBUFF_CONFUSED", p.confused == 1, "#RED#AI Stopped: Player is Confused!") then return true end
    if checkStop(p, "DEBUFF_DAZED",    p.dazed == 1,    "#RED#AI Stopped: Player is Dazed!")    then return true end
    if checkStop(p, "DEBUFF_STUNNED",  p.stunned == 1,  "#RED#AI Stopped: Player is Stunned!")  then return true end
    if checkStop(p, "DEBUFF_FROZEN",   p.frozen == 1,   "#RED#AI Stopped: Player is Frozen!")   then return true end
    -- v1: `not p.lucid_dreamer == 1` parses as `(not p.lucid_dreamer) == 1`,
    -- a boolean compared with a number, so this condition has never fired.
    -- Reproduced literally; T-012 replaces it with the sleep capability check.
    if checkStop(p, "DEBUFF_ASLEEP", p.sleep == 1 and ((not p.lucid_dreamer) == 1),
        "#RED#AI Stopped: Player is Asleep!") then return true end
    return false
end

-------------------------------------------------------------------------------
-- The decision (v1 skoobot_act)
-------------------------------------------------------------------------------

-- Makes a single decision and acts on it; calls itself to proceed to the next.
function skoobot_act(noAction)
    if bot.activation == nil then
        -- a fresh run
        bot.activation = activationInit()
        initLoopTempVars()
    end

    if #game.dialogs > 0 then
        local top = game.dialogs[#game.dialogs]
        if string.match(top.title, "Lore found:") and top.key.virtuals.EXIT then
            -- a lore dialog: the player may have configured it to be ignored
            if tryStop(game.player, "DIALOG_LORE", "#RED# Ai Stopped: Dialog shown on screen: " .. top.title) then
                log("[HIGHLIGHT] tried to stop bot due to presence of dialog: " .. top.title)
                return
            else
                log("[HIGHLIGHT] unregistering dialog: " .. top.title)
                top.key.virtuals.EXIT()
            end
        else
            return aiStop("#RED# Ai Stopped: Dialog shown on screen: " .. top.title)
        end
    end

    local hostiles = spotHostiles(game.player, true)
    if #hostiles > 0 then
        if checkStop(game.player, "LIFE_LOWLIFE",
            game.player.life < game.player.max_life * cfg("LOWHEALTH_RATIO"),
            "#RED#AI cancelled for low health") then return end
        bot.state = STATE_FIGHT
    end

    if checkPowerLevel() then return end
    if checkForDebuffs() then return end

    if bot.activation.unspentTotal ~= getUnspentTotal() then
        return aiStop("#RED#AI Stopped: Unspent points changed!")
    end

    if bot.loop == nil or (not noAction) then
        initLoopTempVars()
        if bot.activation == nil then
            -- a delta-health alert stopped the ai
            return
        end
    end

    bot.loop.thinkCount = bot.loop.thinkCount + 1
    if bot.loop.thinkCount > THINK_LIMIT then
        return aiStop("#LIGHT_RED#AI Stopped: Number of attempts to calculate action exceeded maximum!")
    end

    if activateSustained() then return end

    log("[State] " .. aiStateString())

    if bot.state == STATE_REST then
        if game.player.air < 50 then
            return aiStop("#RED#AI stopped: Attempting to rest while under half breath!")
        end
        local terrain = game.level.map(game.player.x, game.player.y, game.level.map.TERRAIN)
        -- v1: `not game.player.undead == 1` parses as `(not undead) == 1`, a
        -- boolean compared with a number, so the whole run-to-air block has
        -- never executed. Reproduced literally; T-015 makes it real.
        if terrain.air_level and terrain.air_level < 0 and ((not game.player.undead) == 1) then
            local moved
            local path = getPathToAir(game.player)
            if path ~= nil then
                moved = SAI_movePlayer(path[1].x, path[1].y)
            end
            if not moved and bot.active then
                return aiStop("#RED#AI stopped: Suffocating, no air in sight!")
            else
                checkForAdditionalAction()
                return
            end
        end
        return SAI_beginRest()

    elseif bot.state == STATE_EXPLORE then
        if bot.loop.delta < 0 then
            if #hostiles > 0 then
                bot.state = STATE_FIGHT
                return skoobot_act(true)
            else
                -- v1: any damage at all, a single poison tick included. T-011.
                aiStop("#RED#AI stopped: took damage while exploring!")
            end
        end
        if game.player.air < 75 then
            bot.state = STATE_REST
            return skoobot_act(true)
        end
        if game.level.map:checkEntity(game.player.x, game.player.y, engine.Map.TERRAIN, "change_level") then
            aiStop("#GOLD#AI stopping: level change found")
        else
            -- v1: explores while unable to move, and spins. T-012.
            SAI_beginExplore()
        end
        return

    elseif bot.state == STATE_HUNT then
        -- TODO (v1): hook takeHit() to get here, then work out whether the
        -- damage source can be targeted or we have to randomwalk/flee.
        bot.state = STATE_EXPLORE
        return skoobot_act(true)

    elseif bot.state == STATE_FIGHT then
        local targets = {}
        for _, enemy in pairs(hostiles) do
            -- attacking is a talent, so it does not need adding as a choice
            if filterFailedTalents(getAvailableTalents(enemy)) then
                table.insert(targets, enemy)
            end
        end

        if #targets == 0 then
            -- nothing left in sight: fight's over
            -- TODO (v1): or we are blind. Resolves itself once HUNT works.
            bot.state = STATE_REST
            return skoobot_act(true)
        end

        local combatTalents = filterFailedTalents(getCombatTalents())

        if #combatTalents > 0 then
            local picks = {getLowestHealthEnemy(targets), getNearestHostile()}
            local talents

            if (bot.loop.delta < 0)
               and (math.abs(bot.loop.delta) / game.player.max_life >= cfg("LOWHEALTH_RATIO") / 4) then
                talents = filterFailedTalents(getSustainTalents())
                if #talents > 0 then
                    log("[Survival] [Sustain] using sustain, lost more than "
                        .. math.floor(100 * cfg("LOWHEALTH_RATIO") / 4) .. "% life in one turn!")
                    SAI_useTalent(talents[1])
                    checkForAdditionalAction()
                    return
                else
                    log("[Survival] [Sustain] Lost more than "
                        .. math.floor(100 * cfg("LOWHEALTH_RATIO") / 4) .. "% life, but no sustain off cooldown!")
                end
            end

            if (game.player.life / game.player.max_life <= 1 - cfg("LOWHEALTH_RATIO") / 4) then
                talents = filterFailedTalents(getRecoveryTalents())
                if #talents > 0 then
                    log("[Survival] [Recovery] using recovery, missing more than "
                        .. math.floor(100 * cfg("LOWHEALTH_RATIO") / 4) .. "% life...")
                    SAI_useTalent(talents[1])
                    checkForAdditionalAction()
                    return
                else
                    log("[Survival] [Recovery] Missing more than "
                        .. math.floor(100 * cfg("LOWHEALTH_RATIO") / 4) .. "% life, but no recovery off cooldown!")
                end
            end

            for _, enemy in pairs(picks) do
                log("[Combat] Target selected: " .. enemy.name)
                talents = filterFailedTalents(getAvailableTalents(enemy, combatTalents))
                local tid = talents[1]
                if tid ~= nil then
                    log("[Combat] Using talent: " .. tid .. " on target " .. enemy.name)
                    game.player:setTarget(enemy.actor)
                    SAI_useTalent(tid, nil, nil, nil, enemy.actor)
                    checkForAdditionalAction()
                    return
                end
            end

            -- no legal target: get closer
            local a = Astar.new(game.level.map, game.player)
            local path = a:calc(game.player.x, game.player.y, targets[1].x, targets[1].y)
            log("[Combat] [Movement] Pathing towards " .. targets[1].name)
            getDirNum(game.player, targets[1])  -- v1 computed this and never used it

            if not path then
                return aiStop("#RED#[SkooBot] [Combat] [Movement] "
                    .. "AI stopped: Unable to calculate path to nearest enemy!")
            else
                local moved = SAI_movePlayer(path[1].x, path[1].y)
                if not moved and not bot.do_nothing then
                    return aiStop("#RED#[SkooBot] [Combat] [Movement] "
                        .. "AI stopped: Movement along path to nearest enemy failed!")
                end
                checkForAdditionalAction()
                return
            end
        else
            -- everything is on cooldown
            log("[Combat] All Combat talents on cooldown. Waiting.")
            return aiStop("#RED#[SkooBot] [Combat] [Movement] All Combat talents on cooldown!\n"
                .. "Have you configured talent usage? (the SkooBot: Reclauded menu, Shift+F7 by default)")
        end
    end
end

function checkForAdditionalAction()
    if game.player:enoughEnergy() and bot.active then
        return skoobot_act(true)
    end
end

-------------------------------------------------------------------------------
-- Entry points (v1 skoobot_start / skoobot_query / skoobot_runonce)
-------------------------------------------------------------------------------

function bot.start()
    if bot.active == true then
        return aiStop("#GOLD#Disabling SkooBot: Reclauded!")
    end
    if game.zone.wilderness then
        return aiStop("#RED#SkooBot: Reclauded cannot be used in the wilderness!")
    end
    bot.active = true
    bot.actions = 0
    bot.last_reason = nil
    skoobot_act()
end

function bot.stop(reason)
    if bot.active then
        aiStop(reason or "#GOLD#SkooBot: Reclauded disabled!")
    end
end

function bot.query()
    if bot.active == true then
        return game.log("Cannot query while SkooBot: Reclauded is active!")
    end
    if game.zone.wilderness then
        return aiStop("#RED#SkooBot: Reclauded cannot be used in the wilderness!")
    end
    bot.do_nothing = true
    skoobot_act()
    bot.do_nothing = false
end

function bot.runonce()
    if bot.active == true then
        return game.log("Cannot runonce while SkooBot: Reclauded is active!")
    end
    if game.zone.wilderness then
        return aiStop("#RED#SkooBot: Reclauded cannot be used in the wilderness!")
    end
    bot.runonce = true
    skoobot_act()
    bot.runonce = false
end

--- One line for the harness and for bug reports.
function bot.inspect()
    local p = game and game.player
    if not p then return "no player" end
    local hostiles = #spotHostiles(p, true)
    return ("turn=%s hostiles=%d life=%s/%s air=%s resting=%s running=%s wilderness=%s "
        .. "active=%s state=%s actions=%d reason=%s"):format(
        tostring(game.turn), hostiles, tostring(p.life), tostring(p.max_life), tostring(p.air),
        tostring(p.resting ~= nil), tostring(p.running ~= nil),
        tostring(game.zone and game.zone.wilderness or false),
        tostring(bot.active), aiStateString(), bot.actions, tostring(bot.last_reason))
end

-------------------------------------------------------------------------------
-- Per-turn driver (v1 playerActions / scheduleAction / act)
-------------------------------------------------------------------------------

local function playerActions()
    log("[PlayerActions] playerActions() game paused = " .. tostring(game.paused))
    if (not game.player.running) and (not game.player.resting) and bot.active then
        if not game.player:enoughEnergy() then
            log("[WARN] [Bugfix] Player act called with insufficient energy for action.")
            return
        end
        if game.zone.wilderness then
            aiStop("#RED#Player AI cancelled by wilderness zone!")
            return
        end
        skoobot_act()
        if bot.activation then
            bot.activation.turnCount = bot.activation.turnCount + 1
            log("That was player Act Number " .. bot.activation.turnCount)
            if bot.activation.turnCount > TURN_LIMIT then
                aiStop("#LIGHT_RED#AI Disabled. AI acted for " .. TURN_LIMIT .. " turns. Did it get stuck?")
            end
        end
    end
    if not bot.active and not bot.runonce then
        bot.activation = nil
        bot.loop = nil
        bot.prevloop = nil
    end
    if game.player:enoughEnergy() and bot.active and bot.state == STATE_EXPLORE then
        skoobot_act(true)
    end
end

-- v1 kept the "timer registered" flag on the player, where it was saved with
-- the character and never cleared, so ACTION_DELAY only ever worked once per
-- character. The flag is transient here. The feature is still as rough as
-- v1's description said it was.
local function scheduleAction()
    game.paused = true
    if not bot.action_timer then
        bot.action_timer = true
        game:registerTimer(cfg("ACTION_DELAY"), function()
            playerActions()
            game.paused = false
        end)
    end
end

local old_act = _M.act
function _M:act()
    local ret = old_act(self)
    if game.player == self and (not self.running) and (not self.resting) and bot.active then
        if not self:enoughEnergy() then
            log("[WARN] [Bugfix] Player act called with insufficient energy for action.")
            return ret
        end
        if cfg("ACTION_DELAY") == 0 then
            playerActions()
        else
            scheduleAction()
        end
    end
    return ret
end

-- A talent that failed to fire is not retried in the same iteration.
local old_postUseTalent = _M.postUseTalent
function _M:postUseTalent(talent, ret, silent)
    local result = old_postUseTalent(self, talent, ret, silent)
    if not result and game.player == self and bot.loop then bot.loop.talentfailed[talent.id] = true end
    return result
end

return _M
