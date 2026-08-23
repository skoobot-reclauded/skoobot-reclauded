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
-- * A stop is one call, stop(severity, text), and data/notice.lua decides how
--   it looks (#58); a message that names a key looks the binding up (#57).
--   v1's aiStop(msg) took a pre-coloured string from each of its ~25 sites.
-- * What the bot writes about itself goes through data/log.lua (#46): five
--   levels, off below info by default, one "[SKOOBOT]" channel into
--   te4_log.txt and warnings into the message log. v1's print() on every
--   thought is the trace level now.

local Astar = require "engine.Astar"
local KeyBind = require "engine.KeyBind"

local _M = loadPrevious(...)

local power = dofile("/data-skoobot_reclauded/power.lua")
local air = dofile("/data-skoobot_reclauded/air.lua")
local rules = dofile("/data-skoobot_reclauded/rules.lua")
local loadout = dofile("/data-skoobot_reclauded/loadout.lua")
local notice = dofile("/data-skoobot_reclauded/notice.lua")
local keys = dofile("/data-skoobot_reclauded/keys.lua")
local logm = dofile("/data-skoobot_reclauded/log.lua")

local STATE_REST    = 10
local STATE_EXPLORE = 11
local STATE_HUNT    = 12
local STATE_FIGHT   = 13

-- FIXED (#13, T-027). v1 stopped after turnCount > 1000 player acts: an
-- invocation count, not a measure of progress, so a productive run of a
-- thousand turns tripped the same wire as a spin ("did it get stuck?"), and
-- a spin inside one act was invisible to it until a thousand wasted
-- iterations had passed. yura9111's PR to the original counted auto-explore
-- calls the same way (salvage-yura9111.md). Both are gone.
--
-- The liveness invariant in their place (design-stop-conditions.md 1.3):
-- an act-loop iteration that did not advance game.turn consumed no game
-- time and so did nothing, whatever the code believes it did. STALL_LIMIT
-- consecutive no-ops is a livelock whatever the cause -- the pinned
-- auto-explore v1 froze on, encumbrance, a talent the game refuses every
-- time, and the next one nobody has imagined -- and the bot stops with the
-- AI state in the reason so that every trip is a bug report. There is no
-- ceiling on a run that is advancing: a productive long run trips nothing.
--
-- Why 8. One no-op iteration is legitimate: auto-explore refuses to start
-- because something just came into view, and the next iteration fights.
-- Nothing legitimate needs more than two, and every no-op costs a full
-- decision on a frame the player is waiting for, so the limit is small;
-- eight leaves room for a sequence nobody has thought of while still
-- firing inside a single keypress. The counter lives on the activation, so
-- a restart by the player starts it clean.
local STALL_LIMIT = 8

-- THINK_LIMIT stays, as the inner guard. It counts skoobot_act() re-entries
-- within one iteration -- the REST-to-EXPLORE hop when there is nothing to
-- rest for, HUNT-to-EXPLORE, FIGHT-to-REST, checkForAdditionalAction after
-- a free action -- which all happen at one game.turn and so are invisible
-- to the progress invariant until the iteration ends. A productive chain
-- is two or three deep; 25 without settling is real spinning inside one
-- decision, and it is caught before it can overflow the stack.
local THINK_LIMIT = 25

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
local skoobot_act, checkForAdditionalAction, stop

local function cfg(key)
    local s = config.settings.tome.skoobot_reclauded
    return s and s[key]
end

-- The channel (#46). The file sink is print, which the engine writes to
-- te4_log.txt; the user sink is the message log, for warn and error only,
-- in the stop notices' style so the player sees one voice. `game` is looked
-- up at call time: this chunk runs while the module is still loading and
-- `game` is false. The level starts from the persisted setting (LOG_LEVEL,
-- seeded by data/settings.lua before any class loads) and is switched for
-- the session by the options tab or, from the bridge,
-- skoobot_reclauded.log.setLevel("debug").
local chan = logm.new{
    sink = print,
    user = function(levelName, text)
        if not game or not game.log then return end
        local colour = levelName == "error" and "#LIGHT_RED#" or "#ORANGE#"
        -- As an argument, never as the format string (game.log formats).
        game.log("%s", colour .. "#{bold}#" .. notice.PREFIX .. "#{normal}# " .. text)
    end,
    level = cfg("LOG_LEVEL"),
}
bot.log = chan

-- v1's one-string log(msg), at debug. The FIGHT branch still speaks it;
-- everything else passes a format and arguments to the channel so that a
-- disabled level costs no concatenation.
local function log(msg)
    chan.debug("%s", msg)
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

    {label="Terrain: Glowing Chest",    code="TERRAIN_GLOWING_CHEST",  stoptype="WARN"},

    {label="Power Level: ENEMYCOUNT",   code="SCOUTER_ENEMYCOUNT",    stoptype="STOP"},
    {label="Power Level: BIGENEMY",     code="SCOUTER_BIGENEMY",      stoptype="STOP"},
    {label="Power Level: STRONGERENEMY",code="SCOUTER_STRONGERENEMY", stoptype="STOP"},
    {label="Power Level: CROWDPOWER",   code="SCOUTER_CROWDPOWER",    stoptype="STOP"},
}

local STOPTYPES = { WARN = true, STOP = true, IGNORE = true }

-- True when a saved list is exactly this version's conditions, in order.
local function stopListIsCurrent(list)
    if #list ~= #DEFAULT_CONDITIONS then return false end
    for i, c in ipairs(DEFAULT_CONDITIONS) do
        local v = list[i]
        if type(v) ~= "table" or v.code ~= c.code or v.label ~= c.label then return false end
    end
    return true
end

-- FIXED (T-019). v1 wrote the list to the save once and never looked at it
-- again, so a character never gained a condition added later and never lost
-- one removed -- and every lookup of a code the save lacked returned nil to a
-- caller that indexed it. v1 got away with that by never adding a condition;
-- the port's first one, TERRAIN_GLOWING_CHEST (T-013), is consulted on every
-- explore decision and took down every character created before it. The
-- saved list is now reconciled with DEFAULT_CONDITIONS whenever it differs:
-- same codes in the same order with fresh labels, keeping the user's
-- WARN/STOP/IGNORE choice wherever the code survives. Rebuilt in place, so
-- anything already holding the table sees the result. What the defaults
-- SHOULD be is T-026's question; this only keeps a save in step with them.
local function getStopConditionList(p)
    local d = data(p)
    local list = d.stopconditions
    if type(list) ~= "table" then
        list = {}
        d.stopconditions = list
    end
    if not stopListIsCurrent(list) then
        local chosen = {}
        for _, v in ipairs(list) do
            if type(v) == "table" and v.code and STOPTYPES[v.stoptype] then
                chosen[v.code] = v.stoptype
            end
        end
        for i = #list, 1, -1 do list[i] = nil end
        for i, c in ipairs(DEFAULT_CONDITIONS) do
            list[i] = {label=c.label, code=c.code, stoptype=chosen[c.code] or c.stoptype}
        end
        chan.info("[StopConditions] Reconciled the saved stop-condition list with this version's %d conditions",
            #list)
    end
    return list
end

-- FIXED (T-019). v1 returned nil for an unknown code and every caller indexed
-- it. After reconciliation an unknown code can only be a programming error (a
-- lookup with no DEFAULT_CONDITIONS entry), so it fails closed: the bot treats
-- it as STOP, and the log names the code so the entry gets added.
local function getStopCondition(p, code)
    for index, v in ipairs(getStopConditionList(p)) do
        if v.code == code then return v, index end
    end
    chan.error("[StopConditions] Unknown stop condition %s; treating it as STOP", tostring(code))
    return {label=tostring(code), code=code, stoptype="STOP"}, nil
end

local function setStopCondition(p, code, stoptype)
    local v, index = getStopCondition(p, code)
    if not index then return false end
    getStopConditionList(p)[index] = {label=v.label, code=code, stoptype=stoptype}
    return true
end

bot.conditions = {
    list = function() return getStopConditionList(game.player) end,
    get  = function(code) return getStopCondition(game.player, code) end,
    set  = function(code, stoptype) return setStopCondition(game.player, code, stoptype) end,
}

-------------------------------------------------------------------------------
-- Telling the player (#57, #58)
-------------------------------------------------------------------------------

--- The key bound to one of this addon's actions right now, as the player
--- reads it -- "Shift+F7" -- or "unbound". Looked up when the message is
--- built, never copied from the default, so a rebind shows (#57). "Bound" is
--- what the engine itself binds: the player's remap if there is one, else the
--- keybind file's default (KeyBind:getBindTable, engine/KeyBind.lua:114).
--- data/keys.lua does the rendering; the engine's own formatter is the
--- fallback for mouse and gesture bindings.
function bot.keyFor(virtual)
    local def = KeyBind.binds_def[virtual]
    local ks = def and KeyBind:getBindTable(def)[1]
    if not ks then return "unbound" end
    local function symname(sym)
        local code = tonumber(sym) or KeyBind[sym]
        if not code or not core.key.symName then return nil end
        return core.key.symName(code)
    end
    return keys.describe(ks, symname)
        or (game.key and game.key:formatKeyString(ks))
        or "unbound"
end

--- Set one of this addon's settings and persist it, the way the options tab
--- does. Shared by the tab and by the stop popup's checkbox (#58).
function bot.setSetting(option, value)
    local s = config.settings.tome.skoobot_reclauded
    s[option] = value
    game:saveSettings("tome.skoobot_reclauded." .. option,
        ("tome.skoobot_reclauded.%s = %s\n"):format(option, tostring(value)))
end

bot.notice = notice
local StopDialog   -- required on first use; the overload mounts the dialog tree

--- Stop the bot and tell the player why (#58). `severity` is notice.STOPPED
--- (the player must look), notice.HANDED_BACK (finished, or yielded on
--- purpose) or notice.CANNOT_ACT (could not act); `text` is plain prose with
--- no colour codes. One line in the message log with a fixed prefix and one
--- colour per severity, the same text on the big-news banner, and -- for
--- STOPPED, while the STOP_POPUP setting is on -- a popup the player must
--- close. `last_reason` gets "<label>: <text>", which the harness reads.
---
--- opts.hint    what to do next, shown after the reason; a STOPPED notice
---              defaults to naming the restart key
--- opts.banner  false to skip the banner (the player's own key press)
--- opts.popup   false to skip the popup whatever the setting says
function stop(severity, text, opts)
    opts = opts or {}
    bot.active = false
    bot.state = STATE_REST
    bot.activation = nil
    bot.loop = nil
    bot.prevloop = nil

    local hint = opts.hint
    if hint == nil and severity == notice.STOPPED then
        hint = "restart with " .. bot.keyFor("TOGGLE_SKOOBOT_RECLAUDED")
    end
    local n = notice.compose(severity, text, hint)
    bot.last_reason = n.reason
    -- Info, on purpose: the channel's user sink sees warn and above, and the
    -- player is told of a stop once, by the notice below (#58).
    chan.info("[Stop] %s", n.reason)

    -- As an argument, never as the format string: game.log formats what it is
    -- given (string.tformat), and the text may carry a '%'.
    game.log("%s", n.line)
    if opts.banner ~= false and game.bignews then
        game.bignews:saySimple(90, "%s", n.banner)
    end
    if n.severity == notice.STOPPED and opts.popup ~= false and cfg("STOP_POPUP") then
        StopDialog = StopDialog or require("mod.dialogs.skoobot_reclauded.StopDialog")
        game:registerDialog(StopDialog.new(n.popup, function(suppress)
            if suppress then bot.setSetting("STOP_POPUP", false) end
        end))
    end
end

-- Tries to stop the bot, returning true. A condition set to IGNORE is
-- disregarded and returns false.
--
-- v1 named its parameter `stoptype` and then shadowed it with the policy, so
-- the diagnostic printed "Ignoring stop condition: IGNORE" instead of the
-- condition's name. The parameter is `code` here and the message names it.
local function tryStop(p, code, text, severity, opts)
    local stoptype = getStopCondition(p, code).stoptype
    if stoptype == "IGNORE" then
        chan.debug("[StopConditions] Ignoring stop condition: %s", tostring(code))
        return false
    end
    stop(severity or notice.STOPPED, text, opts)
    return true
end

-- Check `condition` to see whether the bot should stop. A WARN condition
-- stops once, is then remembered as acknowledged, and re-arms when it clears.
local function checkStop(p, stopcategory, condition, text, severity, opts)
    local stoptype = getStopCondition(p, stopcategory).stoptype
    local d = data(p)

    if stoptype == "WARN" then
        if condition then
            if not d.stopwarn then d.stopwarn = {} end
            if d.stopwarn[stopcategory] == true then return false end
            d.stopwarn[stopcategory] = true
            return tryStop(p, stopcategory, text, severity, opts)
        else
            if d.stopwarn then d.stopwarn[stopcategory] = nil end
            return false
        end
    end

    if condition then return tryStop(p, stopcategory, text, severity, opts) end
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
    local p = game.player
    return {
        -- #13: the liveness counters. iterations is how many times the
        -- per-turn driver has run this activation; last_turn is game.turn
        -- at the last one; stalled is how many in a row found it unchanged.
        iterations = 0, last_turn = game.turn, stalled = 0,
        unspentTotal = getUnspentTotal(),
        -- #62 (salvage-mishander.md item 8): the tile this activation began
        -- on, so the explore branch can tell the stairs the player toggled the
        -- bot on from stairs the bot walked onto. The level is recorded too,
        -- since the same coordinates on another level are another tile.
        -- left_start is set by loopInit once the player has been anywhere
        -- else, and from then on the start tile is just another tile.
        start_level = game.level, start_x = p.x, start_y = p.y, left_start = false,
    }
end

--- Is the player still on the tile this activation began on, never having
--- left it? (#62, item 8.) False once left_start is set: stairs walked back
--- onto are stairs walked onto, and a fully explored dead-end level brings
--- auto-explore back to the stairs it came down by.
local function onActivationStartTile()
    local act, p = bot.activation, game.player
    return act ~= nil and not act.left_start and act.start_level == game.level
        and act.start_x == p.x and act.start_y == p.y
end

local function loopInit()
    local loop = {}
    loop.thinkCount = 0
    loop.talentfailed = {}

    -- #62 (item 8): this runs once per real turn, at the position the turn
    -- starts from, so it sees every tile the player has stood on.
    local act = bot.activation
    if act and not act.left_start
       and (act.start_level ~= game.level or act.start_x ~= game.player.x or act.start_y ~= game.player.y) then
        act.left_start = true
    end

    chan.trace("[Survival] Evaluating life change...")
    loop.delta = game.player.life - (bot.prevloop and bot.prevloop.life or game.player.life)
    loop.life = game.player.life
    if math.abs(loop.delta) > 0 then
        chan.debug("[Survival] Delta detected! = %s", loop.delta)
    end
    if (loop.delta < 0) and (math.abs(loop.delta) / game.player.max_life >= cfg("LOWHEALTH_RATIO") / 2) then
        -- v1: a stop here returns nil from the initialiser, leaving the loop
        -- table nil; the caller checks for that.
        if tryStop(game.player, "LIFE_BIGLOSS", "lost more than "
            .. math.floor(100 * cfg("LOWHEALTH_RATIO") / 2)
            .. "% of max life in one turn (half of LOWHEALTH_RATIO)") then return end
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
    chan.info("[Action] Using Talent %s on target %s", name, target and target.name or "")
    bot.actions = bot.actions + 1
    -- FIXED (T-010). The 5th arg is force_target and the 7th is no_confirm.
    -- v1 passed the target but never no_confirm, so a talent that wanted a
    -- confirmation or interactive targeting opened a prompt with no human to
    -- answer it -- the rotation stalled instead of falling through to the next
    -- priority (old #49, every marked-target class). With no_confirm and a
    -- forced target, such a talent instead refuses cleanly (returns false),
    -- postUseTalent marks it failed, and filterFailedTalents drops it so the
    -- next priority is tried. T-001 remediation 3; the scored rotation is T-020.
    return game.player:useTalent(tid, who, force_level, ignore_cd, target, false, true)
end

local function SAI_movePlayer(x, y)
    local dir = game.level.map:compassDirection(x - game.player.x, y - game.player.y)
    if bot.do_nothing then
        game.log("[SkooBot] AI would move to the " .. dir)
        return
    end
    chan.info("[Action] Moving to the %s", tostring(dir))
    bot.actions = bot.actions + 1
    return game.player:move(x, y)
end

local function SAI_beginExplore()
    if bot.do_nothing then
        game.log("[SkooBot] AI would begin exploring.")
        return
    end
    chan.info("[Action] Beginning to explore.")
    bot.actions = bot.actions + 1
    if game.player:autoExplore() then
        return game.player:act()
    else
        return stop(notice.CANNOT_ACT, "auto-explore refused to start")
    end
end

local function SAI_beginRest()
    if bot.do_nothing then
        game.log("[SkooBot] AI would begin resting.")
        return false
    end
    chan.info("[Action] Beginning to rest.")
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
        -- #62 (salvage item 2): each enemy's power is weighted by its rank
        -- band before the max and the sum, so a pack of commons no longer
        -- reads as a threat and a single boss reads as more of one. The
        -- bands and the default weights are mishander's; power.rankWeight
        -- says which rank is which.
        local weights = {
            normal = cfg("NORMAL_POWER_RATIO"),
            elite  = cfg("ELITES_POWER_RATIO"),
            boss   = cfg("BOSS_POWER_RATIO"),
        }
        for _, a in ipairs(seen) do
            local pw = power.level(a.actor, game.player.global_speed) * power.rankWeight(a.actor, weights)
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

--- The breathing capabilities air.lua needs, read off an actor.
local function breathCaps(self)
    return {
        no_breath    = self:attr("no_breath"),
        invulnerable = self:attr("invulnerable"),
        can_breath   = self.can_breath,
    }
end

--- Would this actor suffocate standing on (x, y)? ToME's own rule, via air.lua.
local function suffocatingAt(self, x, y)
    local map = game.level.map
    local air_level     = map:checkEntity(x, y, map.TERRAIN, "air_level")
    local air_condition = map:checkEntity(x, y, map.TERRAIN, "air_condition")
    return air.suffocates(breathCaps(self), air_level, air_condition)
end
bot.suffocating = function() local p = game.player return suffocatingAt(p, p.x, p.y) end

--- Is an unopened glowing chest in view? (T-013.)
--
-- v1 walked straight past them; the user asked the bot to STOP for one, so the
-- player can decide whether to open it -- glowing chests can be guarded. A
-- glowing chest is a terrain grid (data/general/events/glowing-chest.lua) with
-- `special = true`, a name containing "chest", and `chest_opened` set once
-- opened, so detection is exact and needs no name-string heuristics beyond
-- that. This only STOPS; walking the bot TO the chest is a scored objective
-- for T-020, deliberately not done here (salvage-mishander.md item 9).
local function glowingChestInView(self)
    if not self.x then return false end
    local map = game.level.map
    local found = false
    core.fov.calc_circle(self.x, self.y, map.w, map.h, self.sight or 10,
        function(_, x, y) return map:opaque(x, y) end,
        function(_, x, y)
            if found or not map.seens(x, y) then return end
            local terrain = map(x, y, map.TERRAIN)
            if terrain and terrain.special and not terrain.chest_opened
               and terrain.name and tostring(terrain.name):lower():find("chest", 1, true) then
                found = true
            end
        end, nil)
    return found
end

--- A path to the nearest tile the actor can breathe on AND actually reach.
--
-- v1 looked for `not air_level or air_level > 0` and did no reachability check,
-- so it could pick a pocket of air inside a wall and then fail to path there
-- (T-001 / salvage #6). This uses the same breathable test as the suffocation
-- trigger, and `canMove` so a coral wall that merely has air is never chosen.
local function getPathToAir(self)
    if not self.x then return nil end
    local map = game.level.map
    local caps = breathCaps(self)
    local best, best_dist

    core.fov.calc_circle(self.x, self.y, map.w, map.h, self.sight or 10,
        function(_, x, y) return map:opaque(x, y) end,
        function(_, x, y)
            local air_level     = map:checkEntity(x, y, map.TERRAIN, "air_level")
            local air_condition = map:checkEntity(x, y, map.TERRAIN, "air_condition")
            if air.breathable(caps, air_level, air_condition) and self:canMove(x, y, false) then
                local dist = math.abs(x - self.x) + math.abs(y - self.y)
                if not best_dist or dist < best_dist then
                    best_dist, best = dist, {x = x, y = y}
                end
            end
        end, nil)

    if best then
        return Astar.new(map, self):calc(self.x, self.y, best.x, best.y)
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

--- The name an item rule is keyed on: the form ToME's own inventory hotkeys
--- store (engine/interface/PlayerHotkeys.lua), which survives the item's
--- talent slot changing and is the same whichever inventory holds it.
local function itemName(o)
    return o:getName{no_add_name=true, force_id=true, no_count=true}
end

--- The live object-use talent for an item name, or nil while the item is not
--- wielded -- a charm in the bag has no talent at all (ActorObjectUse).
local function liveObjectTid(p, name)
    local d = p.object_talent_data
    if not d then return nil end
    for tid, entry in pairs(d) do
        if type(tid) == "string" and type(entry) == "table" and entry.obj and p:knowTalent(tid)
           and itemName(entry.obj) == name then
            return tid
        end
    end
    return nil
end

local function carried(p, name)
    for _, inven in pairs(p.inven or {}) do
        for _, o in ipairs(inven) do
            if o.getName and itemName(o) == name then return true end
        end
    end
    return false
end

--- The rules in the current shape, pruned of talents the character no longer
--- has. FIXED (#56): v1 kept a flat {tid, usetype, priority} list and sorted
--- it on every read, unstably. The saved table is now four ordered sections,
--- migrated IN PLACE on first read (data/rules.lua), so the dialog, the act
--- loop and a scenario holding the table all see one shape. A v1 rule on an
--- activatable item carried the item's talent slot, which changes with every
--- swap (#55); it is re-keyed on the item's name here, the way ToME keys its
--- own item hotkeys. Item rules are never pruned: the item can come back, and
--- a rule whose item is away is simply skipped.
local function getRules(p)
    local d = data(p)
    local r, report = rules.normalize(d.autotalents)
    d.autotalents = r
    if report.migrated > 0 or report.dropped > 0 then
        chan.info("[Rules] Migrated the saved talent rules: %d placed, %d dropped",
            report.migrated, report.dropped)
    end
    for _, section in ipairs(rules.SECTIONS) do
        for _, e in ipairs(r[section]) do
            if e.tid and not e.object then
                local t = p:getTalentFromId(e.tid)
                if t and t.is_object_use then
                    local o = t.getObject and t.getObject(p, t)
                    if o then
                        chan.info("[Rules] Re-keyed an item rule from %s to the item %s", e.tid, itemName(o))
                        e.object = itemName(o)
                        e.tid = nil
                    end
                end
            end
        end
    end
    local removed = rules.prune(r, function(e)
        -- An item rule waits for its item; a built-in action (#59) has no
        -- talent to lose.
        if e.object or rules.isAction(e) then return true end
        return p:knowTalent(e.tid) and true or false
    end)
    for _, e in ipairs(removed) do
        chan.warn("[Rules] Dropped the rule for a talent the character no longer has: %s", tostring(e.tid))
    end
    return r
end

--- The threat score of an actor, as the stop conditions see it (the player
--- by default). For the harness and for bug reports.
function bot.power(actor)
    return power.level(actor or game.player, game.player.global_speed)
end

--- What a rule is worth to the act loop right now: a talent rule is its tid;
--- an item rule is the live talent of the wielded item, or nothing.
local function resolveRule(p, e)
    local tid = e.tid or (e.object and liveObjectTid(p, e.object))
    if tid and p:knowTalent(tid) then return tid end
    return nil
end

--- The talent ids of one section, in order -- the order IS the priority.
local function getAutoTalents(section)
    local p = game.player
    return rules.tids(getRules(p), section, function(e) return resolveRule(p, e) end)
end

--- Is the character impaired in a way a held Combat entry waits out (#15)?
--- Stunned, dazed, confused or frozen, read as the capability counters they
--- are (attr), never `== 1`: a doubly stunned character is impaired too.
--- The same four conditions the DEBUFF_* stops watch; this is what a
--- player who set those to WARN or IGNORE gets instead of a stop. "One
--- turn of stun left" (design-stop-conditions.md 2.3) is not read: any
--- impairment holds, which is the simple form and errs toward holding.
local function impaired(p)
    return (p:attr("stunned") or p:attr("dazed") or p:attr("confused") or p:attr("frozen")) and true or false
end
bot.impaired = function(p) return impaired(p or game.player) end

--- The Combat rotation as the act loop walks it (#59): a talent id for a
--- talent or a live item, the entry itself for a built-in action, in the
--- player's order. A Combat entry with hold = true is left out while the
--- character is impaired (#15) -- skipped like a talent on cooldown, so the
--- rotation falls through to the next entry.
local function getCombatRotation()
    local p = game.player
    local held = impaired(p)
    local out = {}
    for _, e in ipairs(getRules(p).Combat) do
        if e.hold and held then
            log("[Combat] Holding " .. tostring(rules.key(e)) .. " while impaired")
        elseif rules.isAction(e) then
            out[#out + 1] = e
        else
            local tid = resolveRule(p, e)
            if tid then out[#out + 1] = tid end
        end
    end
    return out
end

local function getPreventionTalents() return getAutoTalents("DamagePrevention") end
local function getRecoveryTalents()   return getAutoTalents("Recovery") end
local function getSustainTalents()    return getAutoTalents("Sustain") end

--- What the talent screen needs, so that it holds no rule logic of its own.
local function entryFor(p, t)
    if t.is_object_use then
        local o = t.getObject and t.getObject(p, t)
        if not o then return nil end
        return {object=itemName(o)}
    end
    return {tid=t.id}
end

local function ruleKind(p, e)
    if rules.isAction(e) then return "action" end
    if e.object then return "object" end
    local t = e.tid and p:getTalentFromId(e.tid)
    if t and t.is_object_use then return "object" end
    return (t and t.mode == "sustained") and "sustained" or "activated"
end

--- A talent's description and display name, or a fallback. The game's own
--- screens call these unguarded; here one odd talent -- an inscription learnt
--- without its inscription data, which a test fixture can do -- must not take
--- the whole screen down with it.
local function safeDescription(p, t)
    local ok, desc = pcall(p.getTalentFullDescription, p, t)
    if ok and desc then return desc end
    return "No description is available for this talent."
end

local function safeName(p, t)
    local ok, name = pcall(p.getTalentDisplayName, p, t)
    if ok and name then return tostring(name) end
    return tostring(t.name or t.id)
end

local function describeRule(p, e)
    local d = { entry = e, key = rules.key(e), kind = ruleKind(p, e) }
    if d.kind == "action" then
        -- A built-in action (#59): always live, fixed prose, no talent.
        local a = rules.describeAction(e)
        d.live = true
        d.name = a.name
        d.tree = "Built-in action"
        d.desc = a.desc
    elseif e.object then
        d.tid = liveObjectTid(p, e.object)
        d.t = d.tid and p:getTalentFromId(d.tid) or nil
        d.live = d.t ~= nil
        d.carried = carried(p, e.object)
        if d.t then
            d.name = safeName(p, d.t)
            local o = d.t.getObject and d.t.getObject(p, d.t)
            d.tree = o and (tostring(o.type or "item") .. (o.subtype and ("/" .. tostring(o.subtype)) or "")) or "item"
            d.desc = safeDescription(p, d.t)
        else
            d.name = e.object
            d.tree = "item"
            if d.carried then
                d.desc = "Not active: the item has to be worn for the bot to use it. The rule keeps its place."
            else
                d.desc = "Not carried. The rule keeps its place and applies again when the item is back."
            end
        end
    else
        local t = e.tid and p:getTalentFromId(e.tid)
        d.t = t
        d.tid = e.tid
        d.live = t ~= nil and p:knowTalent(e.tid) ~= nil
        d.name = t and safeName(p, t) or tostring(e.tid)
        local tt = t and t.type and p:getTalentTypeFrom(t.type[1])
        d.tree = (tt and tt.name) or (t and t.type and t.type[1]) or "?"
        d.desc = t and safeDescription(p, t) or "Unknown talent."
    end
    return d
end

bot.rules = {
    module   = rules,
    itemName = itemName,
    get      = function(p) return getRules(p or game.player) end,
    tids     = function(p, section)
        p = p or game.player
        return rules.tids(getRules(p), section, function(e) return resolveRule(p, e) end)
    end,
    entryFor = function(p, t) return entryFor(p or game.player, t) end,
    kind     = function(p, e) return ruleKind(p or game.player, e) end,
    describe = function(p, e) return describeRule(p or game.player, e) end,
    resolve  = function(p, e) return resolveRule(p or game.player, e) end,
}

-------------------------------------------------------------------------------
-- Loadout discovery (#18)
-------------------------------------------------------------------------------

--- What data/loadout.lua needs to know about one talent: the plain fields
--- of its definition, with the two function-form fields the engine resolves
--- against the actor -- cooldown and requires_target -- resolved here, behind
--- pcall, because a definition can error without a target and one odd talent
--- must not take the proposal down. `tactical` is passed as it is, function
--- or table: the module calls a function form itself with this actor and no
--- target. Object-use talents (the worn item's "Activate" slot) are left to
--- the talent screen's item rules, which key on the item's name (#55).
local function loadoutTalent(p, tid, t)
    local ok, cd = pcall(p.getTalentCooldown, p, t)
    if not ok or type(cd) ~= "number" then cd = nil end
    local okr, rt = pcall(p.getTalentRequiresTarget, p, t)
    if not okr then rt = t.requires_target and true or false end
    return {
        tid = tid,
        name = safeName(p, t),
        level = p:getTalentLevelRaw(tid) or 0,
        active = p:isTalentActive(tid) and true or false,
        t = {
            mode = t.mode, tactical = t.tactical,
            no_npc_use = t.no_npc_use, no_dumb_use = t.no_dumb_use,
            sustain_slots = t.sustain_slots, hide = t.hide,
            on_pre_use = t.on_pre_use,
            cooldown = cd, requires_target = rt and true or false,
        },
    }
end

local function proposeLoadout(p)
    local list = {}
    for tid, _ in pairs(p.talents) do
        local t = p:getTalentFromId(tid)
        if t and not t.is_object_use and p:knowTalent(tid) then
            list[#list + 1] = loadoutTalent(p, tid, t)
        end
    end
    table.sort(list, function(a, b) return a.tid < b.tid end)
    local proposal = loadout.discover(list, { self = p })
    chan.info("[Loadout] Proposed %d entries, %d unassigned, %d skipped, %d choices",
        proposal.counts.entries, proposal.counts.unassigned, proposal.counts.skipped, proposal.counts.choices)
    return proposal
end

--- Discovery never writes on its own: propose() returns a proposal and
--- apply() writes one through data/rules.lua, in "merge" (the default: hand
--- rows untouched, its own rows refreshed) or "replace" (everything cleared
--- first -- the talent screen confirms before calling with it). The bot's
--- own rows carry suggested = true; a hand edit in the talent screen clears
--- the mark, so a re-run never touches a row the player moved.
bot.loadout = {
    module   = loadout,
    propose  = function(p) return proposeLoadout(p or game.player) end,
    apply    = function(proposal, mode, p)
        p = p or game.player
        local report = loadout.apply(proposal, getRules(p), rules, mode)
        chan.info("[Loadout] Applied (%s): %d added, %d removed, %d kept",
            report.mode, report.added, report.removed, report.kept)
        return report
    end,
    unplaced = function(proposal, p)
        p = p or game.player
        return loadout.unplaced(proposal, getRules(p), rules)
    end,
}

-------------------------------------------------------------------------------
-- The flee action (#59)
-------------------------------------------------------------------------------

--- The hostile a flee entry runs from: the nearest, or for from="strongest"
--- the highest bot.power -- the figure the stop conditions compare and the
--- Ctrl-hover tooltip shows, so the choice is explainable -- with the nearer
--- one on a tie. `hostiles` is spotHostiles' list (actors only).
local function fleeTarget(entry, hostiles)
    local p = game.player
    local best, bestPower, bestDist
    for _, h in ipairs(hostiles) do
        if h.actor then
            local dist = core.fov.distance(p.x, p.y, h.x, h.y)
            local pw = entry.from == "strongest" and bot.power(h.actor) or 0
            if not best or pw > bestPower or (pw == bestPower and dist < bestDist) then
                best, bestPower, bestDist = h, pw, dist
            end
        end
    end
    return best
end

--- The grid one flee step would take, or nil and the reason in words.
---
--- Ported from the engine's own flee AIs (engine/ai/simple.lua, flee_dmap
--- with flee_simple as its fallback; Nicolas Casalini, GPL-3.0). Every ToME
--- actor keeps a distance map (engine/interface/ActorFOV.lua): at each grid
--- it has seen, `game.turn + radius - distance` as of the last time it saw
--- it -- so the value is HIGHER where the hostile looked more recently and
--- from closer, and nil where it never looked. Among the eight neighbours the
--- player can move to, the one with the lowest value wins -- nil lowest of
--- all, so a grid out of the hostile's view beats one merely farther away --
--- and only a grid scoring below where the player stands counts as a step
--- away at all. When the hostile's map has no value for the player's own
--- grid (it has not looked yet -- a fresh spawn, or a hostile that has not
--- acted since arriving), plain distance decides instead: the neighbour
--- farthest from it, and only one farther than here. Ties either way go to
--- the farther grid, then to the first in the engine's direction order.
--- A character who cannot move (never_move: pinned, held, overloaded) has no
--- step; attempting the impossible is the liveness bug T-012 fixed.
local function fleeStep(entry, hostiles)
    local p = game.player
    if not p.x then return nil, nil, "no position" end
    if p:attr("never_move") then return nil, nil, "cannot move" end
    local h = fleeTarget(entry, hostiles)
    if not h then return nil, nil, "no hostile in view" end
    local a = h.actor
    local here = a.distanceMap and a:distanceMap(p.x, p.y) or nil
    local hereDist = core.fov.distance(p.x, p.y, a.x, a.y)
    local bx, by, bmap, bdist
    for _, dir in ipairs(util.adjacentDirs()) do
        local sx, sy = util.coordAddDir(p.x, p.y, dir)
        if p:canMove(sx, sy) then
            local dist = core.fov.distance(sx, sy, a.x, a.y)
            local cmap, better
            if here then
                cmap = a:distanceMap(sx, sy)
                better = cmap == nil or cmap < here
            else
                better = dist > hereDist
            end
            if better then
                local wins
                if not bx then
                    wins = true
                elseif here and (cmap == nil) ~= (bmap == nil) then
                    wins = cmap == nil
                elseif here and cmap ~= nil and cmap ~= bmap then
                    wins = cmap < bmap
                else
                    wins = dist > bdist
                end
                if wins then bx, by, bmap, bdist = sx, sy, cmap, dist end
            end
        end
    end
    if not bx then return nil, nil, "no grid farther from " .. tostring(h.name) end
    return bx, by, h
end

--- One step away from a hostile (#59): the flee action of the Combat
--- rotation. In query mode it says what it would do; otherwise it takes the
--- step through the player's own move(), which spends the turn. A flee that
--- has no step reports "not available" and returns false so the rotation
--- moves on -- like a talent on cooldown -- and it never stops the bot by
--- itself. Each attempt counts toward bot.actions like every other action,
--- so a circle around a pillar is counted by the same guards as anything
--- else. A step the engine then refuses (move() returned false: the grid
--- changed under us) is marked failed for this iteration like a refused
--- talent, so it is not retried until the next turn.
local function SAI_flee(entry, hostiles)
    local x, y, h = fleeStep(entry, hostiles)
    if not x then
        log("[Combat] [Flee] Not available (" .. tostring(h) .. "): " .. tostring(rules.key(entry)))
        return false
    end
    local dir = game.level.map:compassDirection(x - game.player.x, y - game.player.y)
    if bot.do_nothing then
        game.log("[SkooBot] AI would flee from " .. tostring(h.name) .. " to the " .. tostring(dir))
        return true
    end
    log("[Action] Fleeing from " .. tostring(h.name) .. " to the " .. tostring(dir))
    bot.actions = bot.actions + 1
    local moved = game.player:move(x, y)
    if not moved then
        log("[Combat] [Flee] The step was refused; not retrying this turn")
        bot.loop.talentfailed[rules.key(entry)] = true
        return false
    end
    return true
end

bot.rules.flee = function(entry, p)
    p = p or game.player
    return fleeStep(entry, spotHostiles(p, true))
end
bot.rules.rotation = function() return getCombatRotation() end

-- TODO (v1): exclude enemies in LOS but not LOE -- cannot Rush over pits, and
-- someone standing in front of the target blocks a non-piercing attack.
--
-- `talentsToUse` is a rotation list: talent ids, and (#59) built-in action
-- entries, which have no talent to check and are passed over here -- whether
-- a flee has a step is the rotation's question, not a target's.
local function getAvailableTalents(target, talentsToUse)
    local avail = {}
    local tx, ty
    if target ~= nil then
        tx = target.x
        ty = target.y
    end
    local theseTalents = talentsToUse or getTalents()
    for _, tid in ipairs(theseTalents) do
        local t = type(tid) == "string" and game.player:getTalentFromId(tid) or nil
        if not t then
            chan.trace("[AvailableTalentFilter] Passing over a non-talent entry: %s", tostring(rules.key(tid) or tid))
        else
            -- For dumb AI assume we need range and LOS; no special check for bolts.
            local total_range = (game.player:getTalentRange(t) or 0) + (game.player:getTalentRadius(t) or 0)
            local tg = {type=util.getval(t.direct_hit, game.player, t) and "hit" or "bolt", range=total_range}
            if t.mode == "activated" and not t.no_npc_use and not t.no_dumb_use and
               not game.player:isTalentCoolingDown(t) and game.player:preUseTalent(t, true, true) and
               (target ~= nil and not game.player:getTalentRequiresTarget(t) or game.player:canProject(tg, tx, ty))
               then
                avail[#avail + 1] = tid
                chan.trace("[AvailableTalentFilter] %s can use %s %s", game.player.name, t.name, tid)
            elseif t.mode == "sustained" and not t.no_npc_use and not t.no_dumb_use and
               not game.player:isTalentCoolingDown(t) and
               not game.player:isTalentActive(t.id) and
               game.player:preUseTalent(t, true, true)
               then
                avail[#avail + 1] = tid
            else
                chan.trace("[AvailableTalentFilter] Excluding talent: %s, cannot be used on %s",
                    tid, target ~= nil and target.name or "nil")
            end
        end
    end
    return avail
end

--- Drop what cannot be tried this iteration: a talent on cooldown or one
--- that already failed, and (#59) a built-in action whose step was refused.
local function filterFailedTalents(t)
    local out = {}
    for _, v in ipairs(t) do
        if type(v) == "table" then
            if bot.loop.talentfailed[rules.key(v)] == nil then out[#out + 1] = v end
        elseif not game.player:isTalentCoolingDown(game.player:getTalentFromId(v))
               and bot.loop.talentfailed[v] == nil then
            out[#out + 1] = v
        end
    end
    return out
end

-- Returns true if anything was sustained.
local function activateSustained()
    local talents = filterFailedTalents(getSustainTalents())
    for _, tid in pairs(talents) do
        local t = game.player:getTalentFromId(tid)
        chan.debug("[Sustain] Attempting to sustain: %s", tid)
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

--- The player's own power level as the stop conditions compare it (#62,
--- salvage-mishander.md item 3): the heuristic's figure scaled by the
--- fraction of life left, so a character at half life reads as half as
--- strong. Linear, as mishander wrote it, and probably not right: a
--- character at 51% life is worse off than half-strength because it has
--- fewer turns of margin. The curve is #11's to choose, with the score it
--- feeds; this only makes the comparison look at life at all. The figure
--- v1 compared -- and the tooltip still shows -- ignored life entirely.
local function ownPowerLevel(p)
    local fraction = (p.max_life and p.max_life > 0) and (p.life / p.max_life) or 1
    return power.level(p, p.global_speed) * fraction
end

local function checkPowerLevel()
    local p = game.player
    local myPowerLevel = ownPowerLevel(p)
    local mine = ("%.1f"):format(myPowerLevel)
    if checkStop(p, "SCOUTER_BIGENEMY",
        bot.loop.maxVisibleEnemyPower > cfg("MAX_INDIVIDUAL_POWER"),
        "an enemy's power level, " .. bot.loop.maxVisibleEnemyPower .. ", is above MAX_INDIVIDUAL_POWER") then
        return true
    end
    if checkStop(p, "SCOUTER_STRONGERENEMY",
        bot.loop.maxVisibleEnemyPower > myPowerLevel + cfg("MAX_DIFF_POWER"),
        "an enemy's power level, " .. bot.loop.maxVisibleEnemyPower
            .. ", is more than MAX_DIFF_POWER above yours (" .. mine .. " at current life)") then
        return true
    end
    -- #62 (salvage-mishander.md item 4): the crowd threshold is relative to
    -- the character, not a constant. v1 compared the sum with
    -- MAX_COMBINED_POWER alone, so the same crowd stopped a level-30 and a
    -- level-3 character alike; now the sum has to exceed the character's
    -- own (life-scaled) power by that much. The default stays 500, so the
    -- setting's meaning changed under it: it is the margin above yours.
    if checkStop(p, "SCOUTER_CROWDPOWER",
        bot.loop.sumVisibleEnemyPower > myPowerLevel + cfg("MAX_COMBINED_POWER"),
        "the combined enemy power level, " .. bot.loop.sumVisibleEnemyPower
            .. ", is more than MAX_COMBINED_POWER above yours (" .. mine .. " at current life)") then
        return true
    end
    if checkStop(p, "SCOUTER_ENEMYCOUNT",
        bot.loop.enemyCount > cfg("MAX_ENEMY_COUNT"),
        bot.loop.enemyCount .. " enemies in sight, above MAX_ENEMY_COUNT") then
        return true
    end
    return false
end

local function checkForDebuffs()
    local p = game.player
    -- v1: these test `== 1`, but the effect attributes are additive counters,
    -- not flags -- confused is even a 0-50 percentage (T-001). So a doubly
    -- stunned or 30%-confused character reads as unafflicted. Kept as v1's `== 1`
    -- for parity; the correct capability detection lands with the WARN/STOP/
    -- IGNORE reconciliation in T-026, where the model-validity reasoning for
    -- each (design-stop-conditions.md 2) decides its default.
    if checkStop(p, "DEBUFF_CONFUSED", p.confused == 1, "you are confused") then return true end
    if checkStop(p, "DEBUFF_DAZED",    p.dazed == 1,    "you are dazed")    then return true end
    if checkStop(p, "DEBUFF_STUNNED",  p.stunned == 1,  "you are stunned")  then return true end
    if checkStop(p, "DEBUFF_FROZEN",   p.frozen == 1,   "you are frozen")   then return true end
    -- FIXED (T-012). v1 wrote `p.sleep == 1 and not p.lucid_dreamer == 1`, which
    -- parses as `... and (not p.lucid_dreamer) == 1` -- a boolean compared with a
    -- number, always false, so a sleeping bot never handed back ("when I get
    -- asleep", #46). The capability form is the correct gate: sleep is a counter
    -- and the Solipsist's lucid_dreamer sustain stacks 5-25+, never 1 (T-001), so
    -- `~= 1` would have been wrong too. A Solipsist benefits from sleep and sets
    -- this condition to IGNORE.
    if checkStop(p, "DEBUFF_ASLEEP", p:attr("sleep") and not p:attr("lucid_dreamer"),
        "you are asleep") then return true end
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
            if tryStop(game.player, "DIALOG_LORE", "a dialog is open: " .. top.title, notice.HANDED_BACK) then
                chan.debug("[Dialog] stopped for the dialog: %s", tostring(top.title))
                return
            else
                chan.info("[Dialog] closing an ignored lore dialog: %s", tostring(top.title))
                top.key.virtuals.EXIT()
            end
        else
            return stop(notice.HANDED_BACK, "a dialog is open: " .. top.title)
        end
    end

    local hostiles = spotHostiles(game.player, true)
    if #hostiles > 0 then
        if checkStop(game.player, "LIFE_LOWLIFE",
            game.player.life < game.player.max_life * cfg("LOWHEALTH_RATIO"),
            "life is below LOWHEALTH_RATIO") then return end
        bot.state = STATE_FIGHT
    end

    if checkPowerLevel() then return end
    if checkForDebuffs() then return end

    if bot.activation.unspentTotal ~= getUnspentTotal() then
        return stop(notice.HANDED_BACK, "you have unspent points to allocate")
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
        return stop(notice.CANNOT_ACT, "could not settle on an action after " .. THINK_LIMIT .. " tries")
    end

    if activateSustained() then return end

    chan.debug("[State] %s", aiStateString())

    if bot.state == STATE_REST then
        local p = game.player
        -- FIXED (T-015). This block never ran in v1: the guard read
        -- `not game.player.undead == 1`, which Lua parses as
        -- `(not undead) == 1` -- a boolean compared with a number, always
        -- false -- so a character rested underwater and drowned (TheIronBird,
        -- eight years). mishander's `not can_breath` replacement was dead too
        -- (can_breath is always a table). The trigger is now ToME's own
        -- suffocation rule (data/air.lua), so run to air whenever the game
        -- itself would be draining our breath -- water, void, whatever a
        -- future version adds -- rather than resting into a drowning death.
        if suffocatingAt(p, p.x, p.y) then
            local path = getPathToAir(p)
            local moved
            if path and path[1] then moved = SAI_movePlayer(path[1].x, path[1].y) end
            if not moved and bot.active then
                return stop(notice.STOPPED, "suffocating, and no reachable air")
            end
            checkForAdditionalAction()
            return
        end
        -- Below half breath and not actively suffocating (surfaced, air still
        -- recovering): hand back rather than rest. Measured as a fraction of
        -- max_air, since it is 200 for a Yeek, not the flat 50 v1 assumed.
        if p.max_air and p.max_air > 0 and (p.air / p.max_air) < 0.5 then
            return stop(notice.STOPPED, "below half breath")
        end
        return SAI_beginRest()

    elseif bot.state == STATE_EXPLORE then
        if bot.loop.delta < 0 then
            if #hostiles > 0 then
                bot.state = STATE_FIGHT
                return skoobot_act(true)
            elseif (game.player.life / game.player.max_life) <= cfg("IGNORE_DAMAGE_HEALTH_RATIO") then
                -- FIXED (T-011). v1 stopped on ANY damage while exploring, so a
                -- single poison tick halted the bot (lukesilveira). Hand back
                -- only once life has actually fallen to the threshold; above it
                -- a scratch is not worth a stop. mishander reached the same fix
                -- from play (salvage item 1). Under T-020 this becomes a score
                -- input rather than a standalone flag.
                stop(notice.STOPPED, "took damage while exploring, and life is below IGNORE_DAMAGE_HEALTH_RATIO")
            end
        end
        -- Breath below three-quarters: switch to REST, which now runs to air
        -- if we are actually suffocating (T-015). Ratio, not v1's flat 75.
        if game.player.max_air and game.player.max_air > 0
           and (game.player.air / game.player.max_air) < 0.75 then
            bot.state = STATE_REST
            return skoobot_act(true)
        end
        -- FIXED (T-013). Hand back when a glowing chest is in view so the player
        -- can decide whether to open it (they can be guarded). WARN by default:
        -- it stops once and re-arms when the chest leaves view, so a player who
        -- re-toggles past it has chosen to skip it. A Solipsist-style player who
        -- never wants to be bothered sets this to IGNORE.
        if checkStop(game.player, "TERRAIN_GLOWING_CHEST", glowingChestInView(game.player),
            "a glowing chest is nearby -- open it yourself, they can be guarded", notice.HANDED_BACK) then
            return
        end
        -- #62 (salvage-mishander.md item 8). v1 handed back on ANY level-change
        -- tile, including the stairs the player had just arrived by -- so a
        -- player who toggles the bot on arrival got "level change found" and
        -- nothing else, and mishander, who wanted to bind auto-explore to the
        -- bot entirely, hit it every level. Their fix was a turn counter; this
        -- is the state it stood in for: the tile the activation started on is
        -- exempt until the player has left it. Auto-explore itself stops on
        -- stairs, so the bot still reaches them and hands back there as before
        -- -- a level change is only ever the player's decision.
        local onLevelChange = game.level.map:checkEntity(game.player.x, game.player.y,
            engine.Map.TERRAIN, "change_level")
        if onLevelChange and not onActivationStartTile() then
            stop(notice.HANDED_BACK, "standing on a level change")
        elseif game.player:attr("never_move") then
            -- FIXED (T-012). v1 called auto-explore while unable to move, which
            -- cannot make progress and spun -- the pin / dominate / entangle
            -- freeze users reported (#46). "Can I move at all?" is one predicate
            -- over every never_move source (16+ effects plus encumbrance), the
            -- same attr the engine's own move() gates on, so it stays correct as
            -- ToME adds effects -- unlike mishander's fork, which tested only
            -- EFF_PINNED. The general liveness backstop is T-027; the framework
            -- that folds this into the condition list is T-026.
            stop(notice.STOPPED, "cannot move (pinned, held, or overloaded)")
        else
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

        local combatTalents = filterFailedTalents(getCombatRotation())

        if #combatTalents > 0 then
            local picks = {getLowestHealthEnemy(targets), getNearestHostile()}
            local talents

            if (bot.loop.delta < 0)
               and (math.abs(bot.loop.delta) / game.player.max_life >= cfg("LOWHEALTH_RATIO") / 4) then
                talents = filterFailedTalents(getPreventionTalents())
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

            -- The rotation, in the player's order. A talent is tried on the
            -- picks -- the lowest-life enemy, then the nearest -- and the first
            -- usable one fires, as v1 did. A flee (#59) is tried on the field,
            -- not on a pick, so it splits the list into tiers: every talent
            -- above it is tried on both picks first, then the flee, then the
            -- talents below it. Placed first it fires whenever anything is in
            -- view; placed last it is the "nothing else to do" move.
            local tier = {}
            local function fireTier()
                if #tier == 0 then return false end
                for _, enemy in pairs(picks) do
                    log("[Combat] Target selected: " .. enemy.name)
                    talents = filterFailedTalents(getAvailableTalents(enemy, tier))
                    local tid = talents[1]
                    if tid ~= nil then
                        log("[Combat] Using talent: " .. tid .. " on target " .. enemy.name)
                        game.player:setTarget(enemy.actor)
                        SAI_useTalent(tid, nil, nil, nil, enemy.actor)
                        return true
                    end
                end
                tier = {}
                return false
            end
            for _, item in ipairs(combatTalents) do
                if type(item) == "table" then
                    if fireTier() then checkForAdditionalAction() return end
                    if SAI_flee(item, hostiles) then checkForAdditionalAction() return end
                else
                    tier[#tier + 1] = item
                end
            end
            if fireTier() then checkForAdditionalAction() return end

            -- no legal target: get closer
            local a = Astar.new(game.level.map, game.player)
            local path = a:calc(game.player.x, game.player.y, targets[1].x, targets[1].y)
            log("[Combat] [Movement] Pathing towards " .. targets[1].name)
            getDirNum(game.player, targets[1])  -- v1 computed this and never used it

            if not path then
                return stop(notice.CANNOT_ACT, "no path to " .. targets[1].name)
            else
                local moved = SAI_movePlayer(path[1].x, path[1].y)
                if not moved and not bot.do_nothing then
                    return stop(notice.CANNOT_ACT, "could not move towards " .. targets[1].name)
                end
                checkForAdditionalAction()
                return
            end
        else
            -- everything is on cooldown
            log("[Combat] All Combat talents on cooldown. Waiting.")
            -- #57: the menu key is looked up, not quoted from the default.
            -- #18: this is the moment a new character hits the blank list, so
            -- the hint names the way out of it.
            return stop(notice.CANNOT_ACT, "no Combat talent is ready -- none configured, or all on cooldown",
                { hint = "set talent usage in the SkooBot: Reclauded menu, " .. bot.keyFor("MENU_SKOOBOT_RECLAUDED")
                    .. ", or let the bot suggest a loadout from the talent screen" })
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
        return stop(notice.HANDED_BACK, "disabled by the player", { banner = false })
    end
    if game.zone.wilderness then
        return stop(notice.CANNOT_ACT, "cannot be used in the wilderness")
    end
    bot.active = true
    bot.actions = 0
    bot.last_reason = nil
    skoobot_act()
end

--- Stop from outside the loop: the stop key (hooks/load.lua) and the harness.
--- `severity` defaults to HANDED_BACK; `opts` as for stop().
function bot.stop(text, severity, opts)
    if bot.active then
        stop(severity or notice.HANDED_BACK, text or "disabled", opts)
    end
end

function bot.query()
    if bot.active == true then
        return game.log("Cannot query while SkooBot: Reclauded is active!")
    end
    if game.zone.wilderness then
        return stop(notice.CANNOT_ACT, "cannot be used in the wilderness")
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
        return stop(notice.CANNOT_ACT, "cannot be used in the wilderness")
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
    local act = bot.activation
    return ("turn=%s hostiles=%d life=%s/%s air=%s resting=%s running=%s wilderness=%s "
        .. "active=%s state=%s actions=%d iterations=%s stalled=%s reason=%s"):format(
        tostring(game.turn), hostiles, tostring(p.life), tostring(p.max_life), tostring(p.air),
        tostring(p.resting ~= nil), tostring(p.running ~= nil),
        tostring(game.zone and game.zone.wilderness or false),
        tostring(bot.active), aiStateString(), bot.actions,
        tostring(act and act.iterations), tostring(act and act.stalled), tostring(bot.last_reason))
end

-------------------------------------------------------------------------------
-- Per-turn driver (v1 playerActions / scheduleAction / act)
-------------------------------------------------------------------------------

local function playerActions()
    chan.trace("[PlayerActions] playerActions() game paused = %s", tostring(game.paused))
    if (not game.player.running) and (not game.player.resting) and bot.active then
        if not game.player:enoughEnergy() then
            -- Ordinary: the nested act() a run or rest starts from lands
            -- here once the step has spent the energy. v1 tagged it a
            -- bugfix warning; it is control flow.
            chan.debug("[PlayerActions] act called with insufficient energy; waiting for the next turn")
            return
        end
        if game.zone.wilderness then
            stop(notice.CANNOT_ACT, "cannot be used in the wilderness")
            return
        end
        -- #13: the liveness invariant, checked BEFORE the decision so a spin
        -- is cut at its STALL_LIMITth iteration rather than after it. The
        -- first iteration of an activation creates the counters inside
        -- skoobot_act(); from the second on, an unchanged game.turn means
        -- the previous iteration spent no game time.
        local act = bot.activation
        if act then
            act.iterations = act.iterations + 1
            if game.turn == act.last_turn then
                act.stalled = act.stalled + 1
            else
                act.stalled = 0
                act.last_turn = game.turn
            end
            chan.trace("[PlayerActions] iteration %d at game turn %d, stalled %d",
                act.iterations, game.turn, act.stalled)
            if act.stalled >= STALL_LIMIT then
                -- The bug report: the full state line, at info so it is in
                -- te4_log.txt by default; the notice carries the state.
                chan.info("[Liveness] no progress in %d iterations: %s", act.stalled, bot.inspect())
                return stop(notice.STOPPED, ("no progress in %d iterations (state: %s) -- please report this"):format(
                    act.stalled, aiStateString()))
            end
        end
        skoobot_act()
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
            chan.debug("[PlayerActions] act called with insufficient energy; waiting for the next turn")
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
