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
-- PORTED FROM SkooBot 0.0.12 (D-12), decision logic unchanged, so the port can
-- be measured against the original for parity. Where a line of the original was
-- a known bug it is reproduced faithfully and marked `-- v1:` with the task
-- that fixes it: do not "tidy" those in passing -- fix them under their task,
-- with a test.
--
-- NOTHING may be added to mod.class.Player beyond the two one-line wrappers at
-- the bottom, and nothing here may carry a name the original uses: it is still
-- installed by real people, and two addons defining one method on one class
-- means the last loaded silently wins. State lives on the `skoobot_reclauded`
-- runtime table, config on `player.skoobot_reclauded`.

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
local conditions = dofile("/data-skoobot_reclauded/conditions.lua")
local score = dofile("/data-skoobot_reclauded/score.lua")
local cfgfmt = dofile("/data-skoobot_reclauded/cfg.lua")
local lifem = dofile("/data-skoobot_reclauded/life.lua")
local resources = dofile("/data-skoobot_reclauded/resources.lua")
local escortm = dofile("/data-skoobot_reclauded/escort.lua")

local STATE_REST    = 10
local STATE_EXPLORE = 11
local STATE_HUNT    = 12
local STATE_FIGHT   = 13
local STATE_SEEK    = 14
local STATE_ESCORT  = 15

-- The liveness invariant (#13, design-stop-conditions.md 1.3): an act-loop
-- iteration that did not advance game.turn consumed no game time and so did
-- nothing, whatever the code believes it did. STALL_LIMIT consecutive no-ops
-- is a livelock whatever the cause, and the stop carries the AI state so that
-- every trip is a bug report. There is no ceiling on a run that is advancing --
-- v1's turnCount > 1000 was an invocation count, which tripped on productive
-- runs and missed spins inside one act.
--
-- Why 8: one no-op is legitimate (auto-explore refuses because something came
-- into view, and the next iteration fights), nothing legitimate needs more than
-- two, and every no-op costs a decision on a frame the player is waiting for.
local STALL_LIMIT = 8

-- The inner guard: skoobot_act() re-entries WITHIN one iteration, which all
-- happen at one game.turn and so are invisible to the invariant above until
-- the iteration ends. A productive chain is two or three deep.
local THINK_LIMIT = 25

-- The runtime table. Transient: none of this is saved with the character.
local bot = {
    active       = false,
    state        = STATE_REST,   -- v1 tempvals.state, kept between activations
    do_nothing   = false,        -- v1 tempvals.do_nothing: query mode
    -- v1 tempvals.runonce: a runonce() is in progress. Not `runonce`: that
    -- key is the entry point itself (#70), and the port once put both on it.
    single_run   = false,
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
-- #96: raised from the dead-end site, defined with the notices below.
local offerSetup

--- One setting, as it applies RIGHT NOW (#95): the character's own value, then
--- the account default. Reads `p.skoobot_reclauded` directly rather than
--- through data(), which creates the table as a side effect -- this runs on
--- every decision and must not write anything.
local function cfg(key)
    if cfgfmt.PER_CHARACTER[key] then
        local p = game.player
        local d = p and p.skoobot_reclauded
        local own = d and d.settings and d.settings[key]
        if own ~= nil then return own end
    end
    local s = config.settings.tome.skoobot_reclauded
    return s and s[key]
end

--- The rank-band weights as set (#62), in power.rankWeight's shape.
--- The value one setting resolves to right now, for a probe: the reader
--- the bot itself uses, not a parallel one (#95).
bot.setting = cfg

local function rankWeights()
    return {
        normal = cfg("NORMAL_POWER_RATIO"),
        elite  = cfg("ELITES_POWER_RATIO"),
        boss   = cfg("BOSS_POWER_RATIO"),
    }
end

--- The knobs the score is parametrised by (#11), as set.
local function scoreKnobs()
    return {
        MAX_INDIVIDUAL_POWER       = cfg("MAX_INDIVIDUAL_POWER"),
        MAX_DIFF_POWER             = cfg("MAX_DIFF_POWER"),
        MAX_COMBINED_POWER         = cfg("MAX_COMBINED_POWER"),
        MAX_ENEMY_COUNT            = cfg("MAX_ENEMY_COUNT"),
        IGNORE_DAMAGE_HEALTH_RATIO = cfg("IGNORE_DAMAGE_HEALTH_RATIO"),
        -- #71: what the player calls each of these on the options tab, so a
        -- stop reason can name the knob rather than the setting key. From
        -- data/cfg.lua, the table the tab titles itself from.
        titles                     = cfgfmt.TITLE,
    }
end

-- The channel (#46). The file sink is print, which the engine writes to
-- te4_log.txt; the user sink is the message log, warn and error only. `game` is
-- looked up at CALL time: this chunk runs while the module is still loading and
-- `game` is false. The level starts from the persisted setting, seeded by
-- data/settings.lua before any class loads.
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

--- Per-character configuration, persisted with the save. One table under a
--- name the original does not use, where v1 scattered it over four player
--- fields, so the two addons' saves cannot read each other's.
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
--
-- The list itself is data/conditions.lua (#12); this only keeps the save in
-- step with it and reads the player's choice back.
-------------------------------------------------------------------------------

-- FIXED (T-019). v1 wrote the list to the save once and never looked again, so
-- a character never gained a condition added later, and every lookup of a code
-- the save lacked returned nil to a caller that indexed it. Reconciled with
-- conditions.LIST whenever it differs, keeping the player's choice wherever
-- the code survives, and rebuilt IN PLACE so anything holding the table sees
-- the result.
local function getStopConditionList(p)
    local d = data(p)
    local list = d.stopconditions
    if type(list) ~= "table" then
        list = {}
        d.stopconditions = list
    end
    if conditions.reconcile(list) then
        chan.info("[StopConditions] Reconciled the saved stop-condition list with this version's %d conditions",
            #list)
    end
    return list
end

-- FIXED (T-019). v1 returned nil for an unknown code and every caller indexed
-- it. After reconciliation an unknown code can only be a programming error, so
-- it fails closed: treated as STOP, with the code in the log so the entry gets
-- added.
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

local conditionContext   -- defined with the checks below
local liveEscortee       -- the escortee actor or nil (#93), same reason

bot.conditions = {
    module = conditions,
    list = function() return getStopConditionList(game.player) end,
    get  = function(code) return getStopCondition(game.player, code) end,
    set  = function(code, stoptype) return setStopCondition(game.player, code, stoptype) end,
    --- What the character cannot do right now (move / act / target), for
    --- the harness: conditions.capabilities over the live player.
    capabilities = function(p)
        p = p or game.player
        return conditionContext(p, {}).caps
    end,
}

-------------------------------------------------------------------------------
-- Telling the player (#57, #58)
-------------------------------------------------------------------------------

--- The key bound to one of this addon's actions right now, as the player reads
--- it, or "unbound". Looked up when the message is built, never copied from
--- the default, so a rebind shows (#57). data/keys.lua does the rendering.
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

--- Set one of this addon's settings and persist it. The one writer, shared by
--- the options tab, the stop popup's checkbox and the log-level entry, so the
--- file format cannot drift between them (#90). A value the format cannot hold
--- is not written to disk rather than written in a form that will not load --
--- the live table still takes it, so only the persistence is refused.
function bot.setSetting(option, value)
    local s = config.settings.tome.skoobot_reclauded
    s[option] = value
    local text, why = cfgfmt.line(option, value)
    if not text then
        chan.warn("[Settings] %s not saved: %s", tostring(option), tostring(why))
        return
    end
    game:saveSettings(cfgfmt.file(option), text)
end

--- #95: the same three operations for a CHARACTER's own value.
---
--- Kept in the character's own table, so the engine saves it with them and
--- nothing account-wide changes. Setting one is how a player says "this
--- character is different"; clearing it is how they take it back.
function bot.setCharSetting(option, value)
    if not cfgfmt.PER_CHARACTER[option] then
        chan.warn("[Settings] %s is an account setting and has no per-character value",
            tostring(option))
        return false
    end
    local d = data()
    d.settings = d.settings or {}
    d.settings[option] = value
    return true
end

function bot.clearCharSetting(option)
    local d = data()
    if d.settings then d.settings[option] = nil end
    return true
end

--- Is this character using its own value, and what is the account's?
function bot.settingSource(option)
    local d = game.player and game.player.skoobot_reclauded
    local own = cfgfmt.PER_CHARACTER[option] and d and d.settings and d.settings[option]
    local s = config.settings.tome.skoobot_reclauded
    local acct = s and s[option]
    if own ~= nil then return "character", own, acct end
    return "account", acct, acct
end

--- "Save as default for future characters" (#95). Only values the character
--- actually SET are copied; one it never overrode is already the account's.
function bot.saveAsDefaults()
    local d = game.player and game.player.skoobot_reclauded
    local own = d and d.settings
    local names = {}
    for _, name in ipairs(cfgfmt.ORDER) do
        if own and own[name] ~= nil then
            bot.setSetting(name, own[name])
            names[#names + 1] = cfgfmt.title(name)
        end
    end
    return names
end

bot.notice = notice
local StopDialog   -- required on first use; the overload mounts the dialog tree
local SetupDialog  -- #96, the same
local StairsDialog -- #86, the same

--- Stop the bot and tell the player why (#58). `severity` is notice.STOPPED,
--- HANDED_BACK or CANNOT_ACT; `text` is plain prose with no colour codes.
--- `last_reason` gets "<label>: <text>", which the harness reads.
--- opts.hint    what to do next; a STOPPED notice defaults to the restart key
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

--- #96: the dead end a fresh installation hits, offered as a choice. NOT gated
--- on STOP_POPUP, deliberately: that is about noise during play, and this is
--- the one moment a new installation cannot start at all. Silent when a dialog
--- is already up.
function offerSetup()
    local p = game.player
    if not p then return end
    -- Ask (query mode) answers a question; it does not open things. The
    -- player pressed "what would you do", not "do it".
    if bot.do_nothing then return end
    if bot.setup_prompted then return end          -- this session
    if data(p).nosetupprompt then return end       -- this character, for good
    -- Never stack. The offer is itself a dialog, so a bot toggled again while
    -- it is up would hand back with "a dialog is open: SkooBot: Reclauded",
    -- blocked by its own helpfulness -- which is what the first-run scenario
    -- reported when this check was only about other people's dialogs.
    if game.dialogs and #game.dialogs > 0 then return end

    SetupDialog = SetupDialog or require("mod.dialogs.skoobot_reclauded.SetupDialog")
    game:registerDialog(SetupDialog.new(
        "#GOLD#SkooBot has nothing to fight with.#WHITE#\n\n"
        .. "Its Combat list is empty, so it stopped at the first enemy it saw.\n\n"
        .. "The talent screen can suggest a set from what this character knows. "
        .. "Nothing is saved until you accept it, and you can change any of it.\n\n"
        .. "Menu: " .. bot.keyFor("MENU_SKOOBOT_RECLAUDED"),
        function(choice)
            if choice == "setup" then
                game:registerDialog(require("mod.dialogs.skoobot_reclauded.TalentDialog").new(game.player))
            elseif choice == "never" then
                data(game.player).nosetupprompt = true
                game.log("#GOLD#[SkooBot] It will not offer again for this character. "
                    .. "%s opens the menu whenever you want it.", bot.keyFor("MENU_SKOOBOT_RECLAUDED"))
            else
                bot.setup_prompted = true
            end
        end))
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
local function checkStop(p, stopcategory, condition, text, severity, opts, ctx)
    local stoptype = getStopCondition(p, stopcategory).stoptype
    local d = data(p)

    if stoptype == "WARN" then
        if condition then
            if not d.stopwarn then d.stopwarn = {} end
            local now = conditions.warnKey(stopcategory,
                ctx and ctx.score and ctx.score.figures)
            if conditions.warnCovers(d.stopwarn[stopcategory], now) then return false end
            d.stopwarn[stopcategory] = now
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
        -- #77: the last game.turn the ENGINE gave the player a turn, and the
        -- whole turns it never got. Separate from last_turn above, which counts
        -- DECISIONS: during a rest or a run the bot makes none, so a blackout
        -- read off that clock reported the whole rest as time lost.
        last_act_turn = game.turn, turns_lost = 0,
        -- #78: steps spent walking to a glowing chest, so a chest across
        -- the level is not chased for ever. Reset whenever the walk ends.
        seeks = 0,
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

--- Drop the activation and its loop scratch, so the next skoobot_act() builds
--- a fresh one from where the player stands now (#65). Every entry point begins
--- this way: the counters, the start tile and the unspent-points baseline
--- belong to ONE activation.
local function clearActivation()
    bot.activation = nil
    bot.loop = nil
    bot.prevloop = nil
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
    -- LIFE_BIGLOSS is the one condition read here, at the loop site, because
    -- the delta is computed here (#12). tryStop, not checkStop, as v1 had it:
    -- a WARN fires on every big-loss turn rather than once.
    local big = conditions.find("LIFE_BIGLOSS")
    local ctx = { delta = loop.delta, cfg = cfg }
    if big.detect(game.player, ctx) then
        -- v1: a stop here returns nil from the initialiser, leaving the loop
        -- table nil; the caller checks for that.
        if tryStop(game.player, big.code, conditions.message(big, game.player, ctx)) then return end
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
    elseif bot.state == STATE_SEEK then return "SAI_STATE_SEEK"
    elseif bot.state == STATE_ESCORT then return "SAI_STATE_ESCORT"
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

--- Talents this character has seen raise a Lua error, and will not use again
--- (#130). Kept on the character, so it survives a save and a talent that is
--- broken for this build is not rediscovered every session.
local function retiredTalents(p)
    local d = data(p or game.player)
    d.talent_errors = d.talent_errors or {}
    return d.talent_errors
end

--- Retire one, and say so once. The player is told because a talent silently
--- vanishing from the rotation is the kind of thing that reads as the bot
--- ignoring their configuration.
local function retireTalent(tid, name, why)
    local out = retiredTalents(game.player)
    if out[tid] then return end
    out[tid] = true
    why = why or "raised an engine error"
    chan.warn("[Talent] %s %s and will not be used again on this character", tostring(name), why)
    game.log("#YELLOW#[SkooBot] %s %s, and has been dropped from the rotation for this character.",
        tostring(name), why)
end

bot.retiredTalents = function(p) return retiredTalents(p) end

--- Retire every talent that has raised since we last looked (#130).
---
--- NOT checked after useTalent returns, which is where this began and why it
--- did not work: a talent that opens a dialog SUSPENDS ITS COROUTINE
--- (Command Staff calls talentDialog), so useTalent returns with the talent
--- still in flight and `talent_error` still nil. The error arrives later, when
--- the chat is answered and the coroutine resumes. So the check has to be a
--- sweep of the engine's own global log at the top of a decision, not a test
--- beside the call.
---
--- The log entry's shape is {[talent_id] = talent_def, Actor = ..., ...}
--- (engine/interface/ActorTalents.lua:424), so the id is a KEY, not a field.
local ActorTalents = require "engine.interface.ActorTalents"
local function harvestTalentErrors()
    local log = ActorTalents._talent_errors
    if type(log) ~= "table" then return end
    local seen = bot.talent_errors_seen or 0
    if #log <= seen then return end
    for i = seen + 1, #log do
        local e = log[i]
        if type(e) == "table" and e.Actor == game.player then
            for k, v in pairs(e) do
                if type(k) == "string" and k:find("^T_") then
                    retireTalent(k, type(v) == "table" and v.name or k)
                end
            end
        end
    end
    bot.talent_errors_seen = #log
end

local function SAI_useTalent(tid, who, force_level, ignore_cd, target)
    local name = game.player:getTalentFromId(tid).name
    if bot.do_nothing then
        game.log("[SkooBot] AI would use the talent " .. name .. " on target " .. (target and target.name or ""))
        return
    end
    chan.info("[Action] Using Talent %s on target %s", name, target and target.name or "")
    bot.actions = bot.actions + 1
    -- FIXED (T-010). The 5th arg is force_target, the 7th no_confirm. v1
    -- passed the target but never no_confirm, so a talent wanting a
    -- confirmation opened a prompt with no human to answer it and the rotation
    -- stalled instead of falling through. With both, such a talent refuses
    -- cleanly and the refusal is read here (#76).
    --
    -- FALSE is the refusal, and `== false` is the test, not falsiness: NIL is
    -- a talent still suspended in its coroutine, which may yet fire and must
    -- not be recorded as failed (docs/api-surface-1.7.6.md).
    --
    -- The mark lands before the caller's checkForAdditionalAction(), which is
    -- what lets Attack follow a refused Rockswallow inside one iteration
    -- (scenario-t010-marked-target).
    -- #131: a talent that ASKS THE PLAYER SOMETHING cannot be driven by the
    -- bot, and it does not raise, so #130's error sweep never sees it. Arcane
    -- Combat opened its spell picker on all 25 restarts of a four-minute run;
    -- the character took 20 game turns in total.
    --
    -- talentDialog pushes onto the engine's own list and THEN yields
    -- (engine/interface/ActorTalents.lua:1261-1278), removing the entry only
    -- once the coroutine resumes -- so when useTalent returns the entry is
    -- still there, and the list growing across the call is an exact marker.
    -- A bare "#game.dialogs grew" test would instead retire a good attack
    -- talent the first time one of its kills opened the level-up dialog.
    local dlist = game.player.talentDialogData and select(1, game.player:talentDialogData())
    local dbefore = (type(dlist) == "table") and #dlist or 0

    local ret = game.player:useTalent(tid, who, force_level, ignore_cd, target, false, true)
    if ret == false and bot.loop then bot.loop.talentfailed[tid] = true end

    if type(dlist) == "table" and #dlist > dbefore then
        retireTalent(tid, name, "asks a question the bot cannot answer")
        if bot.loop then bot.loop.talentfailed[tid] = true end
    end
    return ret
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

--- #103: how many level changes the player has actually seen.
---
--- Walked once, at the moment the level turns out to be finished, not per turn
--- -- the map is a few thousand grids. `has_seens` is the engine's own memory
--- of what the character has looked at, the same test autoExplore uses to
--- decide a tile is worth walking to, so this counts only stairs the PLAYER
--- knows about.
local function knownLevelChanges()
    local map = game.level and game.level.map
    if not map then return 0 end
    local n = 0
    for x = 0, map.w - 1 do
        for y = 0, map.h - 1 do
            if map.has_seens(x, y)
               and map:checkEntity(x, y, engine.Map.TERRAIN, "change_level") then
                n = n + 1
            end
        end
    end
    return n
end

-- Bounded, so a door beside the only route to the exit cannot become an
-- oscillation: step off, get drawn back, step off again. After this many the
-- run says so and hands over.
local STEPOFF_TRIES = 3
-- #165: a backstop on stepping towards a level change, per level.
local SEEKEXIT_STEPS = 400
-- #156: attempts at one level change before it counts as refused.
local STAIRS_TRIES = 3

--- Counters that survive the bot being restarted (#140).
---
--- Every bound written before this lived on `bot.activation`, which is rebuilt
--- on every start -- and the harness restarts after every hand-back, so a
--- bound of three was quietly handed unlimited attempts and bounded nothing.
--- The level is the right scope: the situation belongs to it, and arriving
--- somewhere new is a real fresh start.
local levelBounds = {}

local function levelBump(name)
    local k = tostring(game.zone and game.zone.short_name) .. ":"
        .. tostring(game.level and game.level.level)
    local t = levelBounds[k]
    if not t then t = {} ; levelBounds[k] = t end
    t[name] = (t[name] or 0) + 1
    return t[name]
end
--- A table that persists for this level, for state a counter cannot hold.
local function levelState(name)
    local k = tostring(game.zone and game.zone.short_name) .. ":"
        .. tostring(game.level and game.level.level)
    local t = levelBounds[k]
    if not t then t = {} ; levelBounds[k] = t end
    if type(t[name]) ~= "table" then t[name] = {} end
    return t[name]
end

-- Reached through `bot` from inside skoobot_act, which is at LuaJIT's
-- 60-upvalue limit; a new file local referenced there is a parse error.
bot.levelBump  = levelBump
bot.levelState = levelState

--- The nearest level change the PLAYER has seen, cached for the level.
---
--- The scan is the whole map, which knownLevelChanges() only ever does once
--- because it is expensive; this runs on every decision while walking to the
--- exit, so the answer is remembered instead. A level change does not move.
--- `has_seens` is the engine's own memory, so this only ever names stairs the
--- character actually found. See #137.
local function vaultExit()
    local st = levelState("vaultexit")
    if st.done then return st.x, st.y end
    st.done = true
    local map, p = game.level and game.level.map, game.player
    if not map then return nil end
    local bd
    for x = 0, map.w - 1 do
        for y = 0, map.h - 1 do
            if map.has_seens(x, y)
               and map:checkEntity(x, y, engine.Map.TERRAIN, "change_level") then
                local d = core.fov.distance(p.x, p.y, x, y)
                if not bd or d < bd then st.x, st.y, bd = x, y, d end
            end
        end
    end
    return st.x, st.y
end

--- A door the engine has already refused to explore past, right next to us.
---
--- ToME marks a vault or locked door `autoexplore_ignore` when explore stops at
--- it and then leaves it out of the target list -- "we only run to a vault or
--- locked door once". But while the character stands NEXT to it, the flag is
--- what puts it straight back in at cost 1, so explore targets it, stops on it
--- and refuses again. Standing still is what makes the engine's own guard
--- self-defeating. See #136.
local function adjacentRefusedDoor()
    local p, map = game.player, game.level and game.level.map
    if not map then return nil end
    for _, dir in ipairs(util.adjacentDirs()) do
        local x, y = util.coordAddDir(p.x, p.y, dir)
        if x >= 0 and y >= 0 and x < map.w and y < map.h
           and map.attrs(x, y, "autoexplore_ignore") and bot.needsConsent(x, y) then
            return x, y
        end
    end
    return nil
end

--- One step that breaks adjacency with (gx, gy). Exits are chosen after doors
--- in the same target chain, so once the door is out of the list explore walks
--- to the stairs on its own and no route has to be built here.
local function stepOffDoor(gx, gy)
    local p = game.player
    local bx, by, bd
    for _, dir in ipairs(util.adjacentDirs()) do
        local sx, sy = util.coordAddDir(p.x, p.y, dir)
        if p:canMove(sx, sy) and not bot.needsConsent(sx, sy) then
            local d = core.fov.distance(sx, sy, gx, gy)
            if d > 1 and (not bd or d > bd) then bx, by, bd = sx, sy, d end
        end
    end
    if not bx then return false end
    return p:move(bx, by) and true or false
end

local function SAI_beginExplore()
    if bot.do_nothing then
        game.log("[SkooBot] AI would begin exploring.")
        return
    end
    chan.info("[Action] Beginning to explore.")
    bot.actions = bot.actions + 1

    -- #136: ask explore where to go only from somewhere it can answer. While
    -- the character stands NEXT to a door the engine has already refused,
    -- explore puts that door back at top priority and walks into it, so the
    -- adjacency has to be broken BEFORE the question is asked, not after the
    -- answer disappoints.
    local dx, dy = adjacentRefusedDoor()
    if dx then
        local t = game.level.map(dx, dy, engine.Map.TERRAIN)
        local what = t and t.name or "a door"
        -- Per DOOR and per level, not per activation: a restart must not hand
        -- this another three tries, and a second vault deserves its own (#140).
        local tries = levelBump(("stepoff:%d,%d"):format(dx, dy))
        if tries > STEPOFF_TRIES then
            -- #137, first pass: a vault the bot cannot get past is not a
            -- reason to end the run. Walk to a way off the level instead and
            -- let #86's offer decide whether to take it -- so this ignores the
            -- vault without deciding to skip its contents, which is the part
            -- that is still the player's.
            --
            -- Deliberately unconditional for now. Asking, and remembering the
            -- answer as categorically / this one / never, is what #137 stays
            -- open for.
            local lx, ly = vaultExit()
            if not lx then
                return stop(notice.HANDED_BACK,
                    ("%s blocks the way on, and no way off this level has been found"):format(
                        tostring(what)))
            end
            -- Already standing on it. The explore branch checks for that
            -- before ever calling here, so reaching this means the #62
            -- exemption is holding it back -- the activation started on this
            -- tile. Say where the way out is rather than pathing to where we
            -- already are, which returns an empty path and reads as failure.
            if lx == game.player.x and ly == game.player.y then
                return stop(notice.HANDED_BACK,
                    ("%s blocks the way on; you are standing on the way out"):format(
                        tostring(what)))
            end
            local path = Astar.new(game.level.map, game.player):calc(
                game.player.x, game.player.y, lx, ly,
                nil, nil, function(x, y) return not bot.needsConsent(x, y) end)
            if not path or #path == 0 then
                return stop(notice.HANDED_BACK,
                    ("%s blocks the way on, and the way out at %d,%d cannot be reached"):format(
                        tostring(what), lx, ly))
            end
            if SAI_movePlayer(path[1].x, path[1].y) then
                chan.info("[Action] Ignoring %s; heading for the way off this level.",
                          tostring(what))
                return
            end
            return stop(notice.CANNOT_ACT,
                ("could not step towards the way off this level, past %s"):format(
                    tostring(what)))
        end
        if stepOffDoor(dx, dy) then
            chan.info("[Action] Stepping away from %s so exploring can move on.",
                      tostring(what))
            return
        end
        return stop(notice.HANDED_BACK,
            ("%s is the only way on, and there is no step away from it"):format(
                tostring(what)))
    end

    if game.player:autoExplore() then
        return game.player:act()
    else
        -- #103: a refusal is not an inability. autoExplore returns false only
        -- when it can reach nothing worth going to, so the level is finished
        -- and this is a hand-back. The stairs are named when the player has
        -- found any -- but see #121 before building on that.
        local exits = knownLevelChanges()
        local reason = "this level is explored -- nothing reachable left to see"
        if exits > 0 then
            reason = reason .. ("; %d level change%s you have found %s the way on"):format(
                exits, exits == 1 and "" or "s", exits == 1 and "is" or "are")
        end
        return stop(notice.HANDED_BACK, reason)
    end
end

--- Spend the turn in place (#11, the hold posture): the engine's own wait,
--- which also reloads a ranged weapon. A real action -- game.turn advances
--- -- so the progress invariant (#13) reads it as one.
local function SAI_wait(towards)
    local who = tostring(towards and towards.name or "them")
    if bot.do_nothing then
        game.log("[SkooBot] AI would wait for " .. who .. " to come into reach")
        return
    end
    chan.info("[Action] Waiting for %s to come into reach", who)
    bot.actions = bot.actions + 1
    game.player:waitTurn()
end

local function SAI_beginRest()
    if bot.do_nothing then
        game.log("[SkooBot] AI would begin resting.")
        return false
    end

    chan.info("[Action] Beginning to rest.")
    bot.actions = bot.actions + 1
    -- restInit is not re-entrant: it sets self.resting, then useEnergy fires
    -- callbackOnActEnd (mod/class/Player.lua:433), and a callback that damages
    -- or debuffs reaches restStop (:786, :810), which nils self.resting before
    -- PlayerRest.lua:53 indexes it. Nothing to do with being inside act() --
    -- measured from the bridge, outside a turn, with the same result. The
    -- engine still drives the rest; this stops its bug reaching the player.
    -- See #114.
    -- #153: a rest that achieves nothing still counts as an action, so #13's
    -- liveness invariant is satisfied and nothing reports it. Doomed spent
    -- 21,000 game turns on this, logged verbatim:
    --
    --   Ran for 2 turns (stop reason: hostile spotted ... (poison ivy))
    --   Resting starts...
    --   Rested for 0 turns (stop reason: all resources and life at maximum)
    --
    -- MEASURED, not predicted. Which pools a rest actually restores is the
    -- engine's judgement -- Doomed sat at 26/100 Hate while the engine called
    -- everything full -- so asking whether resting WOULD help means modelling
    -- something this addon does not know. Asking whether the last one DID is
    -- a fact.
    local t0 = game.turn
    local ok, err = pcall(game.player.restInit, game.player, nil, nil, nil, validateRest)
    local st = bot.levelState("rest")
    if game.turn == t0 then st.noop = (st.noop or 0) + 1 else st.noop = 0 end
    if not ok then
        chan.warn("[Action] The engine stopped the rest as it began: %s", tostring(err))
        -- restStop already ran validateRest and cleared the state; clear it
        -- here only if the failure came from somewhere that did not.
        if game.player.resting then game.player:restStop() end
    end
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

    -- #62 (salvage item 2): each enemy's power is weighted by its rank band,
    -- so a pack of commons no longer reads as a threat and a single boss reads
    -- as more of one -- power.rankWeight says which rank is which -- and
    -- recorded on its entry with its distance, for the score (#11).
    for _, a in ipairs(seen) do
        a.power = score.enemyPower(power.level(a.actor, game.player.global_speed),
            power.rankWeight(a.actor, rankWeights()))
        a.rank = a.actor.rank
        a.distance = core.fov.distance(self.x, self.y, a.x, a.y)
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

--- The nearest unopened glowing chest in view, or nil (T-013, #78). A terrain
--- grid with `special`, a name containing "chest", and `chest_opened` once
--- opened. Returns the grid, not a boolean, because #78 walks to it.
local function nearestGlowingChest(self)
    if not self.x then return nil end
    local map = game.level.map
    local bx, by, bd
    core.fov.calc_circle(self.x, self.y, map.w, map.h, self.sight or 10,
        function(_, x, y) return map:opaque(x, y) end,
        function(_, x, y)
            if not map.seens(x, y) then return end
            local terrain = map(x, y, map.TERRAIN)
            if terrain and terrain.special and not terrain.chest_opened
               and terrain.name and tostring(terrain.name):lower():find("chest", 1, true) then
                local d = core.fov.distance(self.x, self.y, x, y)
                if not bd or d < bd then bx, by, bd = x, y, d end
            end
        end, nil)
    if not bx then return nil end
    return { x = bx, y = by, distance = bd }
end

local function glowingChestInView(self)
    return nearestGlowingChest(self) ~= nil
end
bot.nearestChest = function(p) return nearestGlowingChest(p or game.player) end

--- A path to the nearest tile the actor can breathe on AND actually reach.
--
-- v1 looked for `not air_level or air_level > 0` and did no reachability check,
-- so it could pick a pocket of air inside a wall and then fail to path there
-- (T-001 / salvage #6). This uses the same breathable test as the suffocation
-- trigger, and `canMove`, so a coral wall that merely has air is never chosen.
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


--- A grid the player must CONSENT to enter (#64): a vault door, a locked door,
--- a loose rock, a shop entrance. None sets `block_move`, so Astar routes
--- straight through and the bot walks into a popup -- see
--- docs/api-surface-1.7.6.md.
---
--- The bot never PLANS a route through one. Not a matter of remembering a
--- refusal: a grid the player must be asked about is not a grid the bot may
--- decide to enter, asked or not. If a vault door is the only way to a hostile,
--- "no path to <name>" is the honest answer. Opening one deliberately is
--- unaffected -- the player walks in themselves.
---
--- The shop (#134) is on the TRAP layer rather than TERRAIN, which is the one
--- wrinkle: a store is an entity carrying `is_store` and stepping on it opens
--- the shop (mod/class/Player.lua:315). ToME's own auto-explore refuses them
--- too, returning "store entrance spotted" rather than entering (:1265, :1272),
--- so this is the bot catching up with the game rather than a new policy.
local function needsConsent(x, y)
    if not game.level or not game.level.map then return false end
    local map = game.level.map
    local t = map(x, y, engine.Map.TERRAIN)
    if t and (t.door_player_check or t.door_player_stop) then return true end
    if map:checkEntity(x, y, engine.Map.TRAP, "is_store") then return true end
    return false
end
bot.needsConsent = function(x, y) return needsConsent(x, y) end

--- Mark an adjacent consent grid the way the ENGINE marks one it stopped at.
---
--- ToME sets `autoexplore_ignore` on a vault or locked door only when EXPLORE
--- stops at it (PlayerExplore.lua:2454, :2505, :2590). Being walked INTO one
--- and getting its check dialog does not set it -- measured: staged a sealed
--- door, let the bot reach its dialog, and the attribute was nil throughout.
---
--- That mattered because #136's step-off and #137's walk-to-the-exit both
--- keyed on the flag, so in a real run neither ever engaged; they passed their
--- scenario only because the scenario set the flag itself.
---
--- Setting it here is not a new policy. It is the engine's own "we only run to
--- a vault or locked door once" applied at the one moment the bot knows it was
--- walked into one, and it also stops the flood-fill scan re-targeting the
--- door from across the level (:2013).
local function markWalkedInto()
    local p, map = game.player, game.level and game.level.map
    if not map then return 0 end
    local n = 0
    for _, dir in ipairs(util.adjacentDirs()) do
        local x, y = util.coordAddDir(p.x, p.y, dir)
        if x >= 0 and y >= 0 and x < map.w and y < map.h
           and needsConsent(x, y) and not map.attrs(x, y, "autoexplore_ignore") then
            map.attrs(x, y, "autoexplore_ignore", true)
            n = n + 1
        end
    end
    return n
end
-- Through `bot`, because skoobot_act is at LuaJIT's 60-upvalue limit.
bot.markWalkedInto = markWalkedInto

--- Remember a level change this character refused, per level. Explore targets
--- exits (#121), so without this the bot is walked back to the one it just
--- turned down for ever -- see #165.
local function markRefusedExit()
    local p = game.player
    if not p or not p.x then return end
    levelState("refusedexit")[("%d,%d"):format(p.x, p.y)] = true
end
bot.markRefusedExit = markRefusedExit

--- The nearest seen level change that has NOT been refused, or nil when every
--- one this character has found is refused. See #165.
local function progressExit()
    local map, p = game.level and game.level.map, game.player
    if not map or not p or not p.x then return nil end
    local refused = levelState("refusedexit")
    local bx, by, bd
    for x = 0, map.w - 1 do
        for y = 0, map.h - 1 do
            if map.has_seens(x, y)
               and not refused[("%d,%d"):format(x, y)]
               and map:checkEntity(x, y, engine.Map.TERRAIN, "change_level") then
                local d = core.fov.distance(p.x, p.y, x, y)
                if not bd or d < bd then bx, by, bd = x, y, d end
            end
        end
    end
    return bx, by
end

--- Step towards a level change that has not been refused; true when a step was
--- taken, so the explore branch knows not to explore. See #165.
---
--- It terminates without needing a counter: the refused set only grows, so once
--- every known exit is in it this returns false and explore hands back as it
--- did before. SEEKEXIT_STEPS is the backstop for a path that never arrives.
local function seekProgressExit()
    if not next(levelState("refusedexit")) then return false end
    local p = game.player
    local x, y = progressExit()
    if not x or (x == p.x and y == p.y) then return false end
    if levelBump("seekexit") > SEEKEXIT_STEPS then return false end
    local path = Astar.new(game.level.map, p):calc(p.x, p.y, x, y, nil, nil,
        function(ax, ay) return not needsConsent(ax, ay) end)
    if not path or #path == 0 then return false end
    chan.info("[Action] This level is explored and the way out was refused; heading for the level change at %d,%d.",
              x, y)
    return SAI_movePlayer(path[1].x, path[1].y) and true or false
end
bot.seekProgressExit = seekProgressExit

--- A name for a dialog that is worth reading in a stop reason.
---
--- Not every dialog has a title -- QuestPopup and Chat do not -- and the
--- hand-back was built from `title` alone, so the stop that most needs to name
--- its cause said "a dialog is open: " and stopped there. Worse, every untitled
--- dialog collapsed into that one string, so the sweep's stop table aggregated
--- several different causes into a single row and read as one recurring
--- problem. See #142.
---
--- The class name is the fallback, trimmed of its package: `QuestPopup` rather
--- than `mod.dialogs.QuestPopup`. Not beautiful, and it is the difference
--- between a diagnosable stop and a blank one.
---
--- It also stops a nil title reaching string.match, which raises rather than
--- returning nil -- a crash waiting for the first dialog that has no title
--- field at all rather than an empty one.
local function dialogLabel(d)
    local t = d and d.title
    if type(t) == "string" and t ~= "" then return t end
    local c = tostring((d and d.__CLASSNAME) or "?")
    return c:match("([^.]+)$") or c
end
bot.dialogLabel = dialogLabel
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
--- has. Migrated IN PLACE on first read (#56, data/rules.lua). A v1 rule on an
--- activatable item carried the item's talent slot, which changes with every
--- swap, so it is re-keyed on the item's NAME (#55). Item rules are never
--- pruned: the item can come back, and a rule whose item is away is skipped.
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

--- The situation as the score sees it right now (#11): terms, flags,
--- figures, posture and reasons, over what the player can see. For the
--- harness and for bug reports.
function bot.score(p)
    p = p or game.player
    return conditionContext(p, spotHostiles(p, true)).score
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

--- The capability counters a held Combat entry waits out (#15). Named as
--- attributes rather than effect ids on purpose: data/conditions.lua detects
--- by capability, never by effect name, because a dozen effects set `stunned`
--- and only the attr is common to them.
local IMPAIRMENTS = { "stunned", "dazed", "confused", "frozen" }

--- Is the character impaired in a way a held Combat entry waits out (#15)?
--- Read as the counters they are (attr), never `== 1`: a doubly stunned
--- character is impaired too. This is what a player who set those stops to
--- WARN or IGNORE gets instead of a stop.
local function impaired(p)
    for _, a in ipairs(IMPAIRMENTS) do
        if p:attr(a) then return true end
    end
    return false
end
bot.impaired = function(p) return impaired(p or game.player) end

--- The effect SUBTYPES that carry the four impairments (#68). ToME's own
--- grouping: EFF_STUNNED, EFF_DAZED and EFF_FROZEN are all `stun`,
--- EFF_CONFUSED is `confusion`, and the engine reasons about stun immunity
--- and the like through exactly these keys. Two keys for four attrs, and no
--- effect id named, so a new stunning effect is covered the day it ships.
local IMPAIRING_SUBTYPES = { stun = true, confusion = true }

--- #68: does every impairment on the character run out this turn? Waiting out
--- one that lapses anyway costs the rotation a turn and buys nothing, so a
--- held entry is released on the last turn.
---
--- Durations are per EFFECT, and `__tmpvals` looks like the link and is NOT:
--- EFF_STUNNED and its kind call addTemporaryValue directly, which records
--- nothing there, so a scan of it silently never fires
--- (docs/api-surface-1.7.6.md). The SUBTYPE is the link that exists. Measured,
--- not assumed -- scenario-hold part 3c is the guard.
---
--- It ERRS TOWARD HOLDING: an unexplained impairment is treated as lasting,
--- and the longest candidate wins without being attributed to an attr, so a
--- long confusion holds a lapsing stun. Coarse, in the safe direction.
local function impairmentEnding(p)
    local any = false
    for _, a in ipairs(IMPAIRMENTS) do
        if p:attr(a) then any = true break end
    end
    if not any then return false end
    local longest = nil
    for id, params in pairs(p.tmp or {}) do
        local def = p.tempeffect_def and p.tempeffect_def[id]
        local sub = def and def.subtype
        if type(sub) == "table" then
            for key in pairs(sub) do
                if IMPAIRING_SUBTYPES[key] then
                    local d = tonumber(type(params) == "table" and params.dur) or 0
                    if not longest or d > longest then longest = d end
                    break
                end
            end
        end
    end
    if not longest then return false end   -- nothing explains it: keep holding
    return longest <= 1
end
bot.impairmentEnding = function(p) return impairmentEnding(p or game.player) end

--- The life pool as data/life.lua reads it (#91), for a scenario that needs
--- to know what the bot decided on. Exposed rather than recomputed on the
--- far side: which parts of die_at are trusted is this module's business.
bot.effectiveLife = function(p) return lifem.of(p or game.player) end

--- The Combat rotation as the act loop walks it (#59): a talent id, or the
--- entry itself for a built-in action, in the player's order. A Combat entry
--- with hold = true is skipped while the character is impaired (#15), like a
--- talent on cooldown. Also returns how many were held, because an empty
--- rotation has three causes and the stop has to name the right one (#75).
local function getCombatRotation()
    local p = game.player
    -- #68: an impairment that lapses this turn is not worth waiting out.
    local held = impaired(p) and not impairmentEnding(p)
    local out, heldCount = {}, 0
    for _, e in ipairs(getRules(p).Combat) do
        if e.hold and held then
            heldCount = heldCount + 1
            chan.debug("[Combat] Holding %s while impaired", tostring(rules.key(e)))
        elseif rules.isAction(e) then
            out[#out + 1] = e
        else
            local tid = resolveRule(p, e)
            if tid then out[#out + 1] = tid end
        end
    end
    return out, heldCount
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

--- "Here is how to start", once per character (#72). One line, only to
--- somebody who has nothing configured. The flag lives on the character so the
--- engine saves it, and a character that already HAS rules is marked greeted
--- WITHOUT being greeted -- otherwise clearing every rule later would make the
--- addon treat them as new and start explaining itself again.
---
--- Called from ToME:runDone, the first moment the message log is live
--- (docs/api-surface-1.7.6.md).
--- @return true when it said something
function bot.greet()
    local p = game.player
    if not p then return false end
    local d = data(p)
    if d.greeted then return false end
    d.greeted = true
    if rules.count(getRules(p)) > 0 then return false end
    game.log("%s", "#GOLD##{bold}#" .. notice.PREFIX .. "#{normal}# Ready. "
        .. bot.keyFor("MENU_SKOOBOT_RECLAUDED") .. " opens the menu: set the talents it may use "
        .. "(or let it suggest a loadout), then " .. bot.keyFor("TOGGLE_SKOOBOT_RECLAUDED")
        .. " starts it.")
    return true
end

-------------------------------------------------------------------------------
-- Loadout discovery (#18)
-------------------------------------------------------------------------------

--- What data/loadout.lua needs about one talent: the plain fields of its
--- definition, with cooldown and requires_target resolved here behind pcall,
--- because a definition can error without a target and one odd talent must not
--- take the proposal down. `tactical` is passed as it is, function or table.
--- Object-use talents are left to the talent screen's item rules (#55).
local function loadoutTalent(p, tid, t)
    local ok, cd = pcall(p.getTalentCooldown, p, t)
    if not ok or type(cd) ~= "number" then cd = nil end
    local okg, rng = pcall(p.getTalentRange, p, t)
    if not okg or type(rng) ~= "number" then rng = nil end
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
            -- #98: the reach, so the proposal can tell a melee attack from
            -- a ranged one without knowing any talent by name. nil when the
            -- game will not say, and data/loadout.lua treats nil as "not
            -- known to be melee" rather than guessing.
            range = rng,
        },
    }
end

--- #98: what the main hand is, for the proposal. A bow or a sling cannot
--- make a melee attack, so *Attack* is not a recommendation for the
--- character holding one. Read here rather than in data/loadout.lua because
--- that module is pure and this is the engine's inventory.
local function mainhandFacts(p)
    local okv, inv = pcall(p.getInven, p, p.INVEN_MAINHAND)
    local o = okv and inv and inv[1] or nil
    if not o then return nil end
    return {
        name    = tostring(o.name or "your weapon"),
        subtype = tostring(o.subtype or ""),
        archery = (o.archery or (o.combat and o.combat.archery)) and true or false,
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
    -- #85: the talents this character has declined, so the proposal marks
    -- them and never writes them. Kept with the character (data/rules), so
    -- a re-run does not re-recommend what the player already said no to.
    local proposal = loadout.discover(list, { self = p, mainhand = mainhandFacts(p),
        declined = data(p).declined, rm = rules })
    chan.info("[Loadout] Proposed %d entries, %d unassigned, %d skipped, %d choices",
        proposal.counts.entries, proposal.counts.unassigned, proposal.counts.skipped, proposal.counts.choices)
    return proposal
end

--- Discovery never writes on its own: propose() returns a proposal, apply()
--- writes one. The bot's own rows carry suggested = true, and a hand edit in
--- the talent screen clears the mark, so a re-run never touches a moved row.
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
--- the highest COUNTED power, nearer one on a tie.
---
--- #80: ranked by the COUNTED, rank-weighted figure that spotHostiles records
--- as `.power`, read exactly as score.lua reads it -- `or 0` and the tie rule
--- included -- so the two cannot pick different enemies.
local function fleeTarget(entry, hostiles)
    local p = game.player
    local best, bestPower, bestDist
    for _, h in ipairs(hostiles) do
        if h.actor then
            local dist = core.fov.distance(p.x, p.y, h.x, h.y)
            local pw = entry.from == "strongest" and (h.power or 0) or 0
            if not best or pw > bestPower or (pw == bestPower and dist < bestDist) then
                best, bestPower, bestDist = h, pw, dist
            end
        end
    end
    return best
end

--- The grid one flee step would take, or nil and the reason in words.
---
--- The rule is the engine's own -- least seen, then farthest, over the
--- hostile's distance map, with `keep_los` (#69) as a filter on the candidates
--- rather than a different preference. All of it, including the one place this
--- deliberately differs from the engine, is in docs/api-surface-1.7.6.md,
--- "Fleeing: the engine's own least seen, then farthest rule". Ported from
--- engine/ai/simple.lua (Nicolas Casalini, GPL-3.0); #59.
local function fleeStep(entry, hostiles)
    local p = game.player
    if not p.x then return nil, nil, "no position" end
    if p:attr("never_move") then return nil, nil, "cannot move" end
    local h = fleeTarget(entry, hostiles)
    if not h then return nil, nil, "no hostile in view" end
    local a = h.actor
    local keepLos = entry.keep_los and true or false
    local here = a.distanceMap and a:distanceMap(p.x, p.y) or nil
    local hereDist = core.fov.distance(p.x, p.y, a.x, a.y)
    local bx, by, bmap, bdist
    for _, dir in ipairs(util.adjacentDirs()) do
        local sx, sy = util.coordAddDir(p.x, p.y, dir)
        -- #64: a grid the player must consent to enter is not a step the
        -- bot may take either -- fleeing into a sealed door opens its popup
        -- just as surely as pathing into one.
        if p:canMove(sx, sy) and not needsConsent(sx, sy)
           and (not keepLos or p:hasLOS(a.x, a.y, nil, nil, sx, sy)) then
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
    if not bx then
        return nil, nil, "no grid farther from " .. tostring(h.name)
            .. (keepLos and " that keeps it in sight" or "")
    end
    return bx, by, h
end

--- #97: is retreating from this target pointless?
---
--- A target that cannot move and is not already adjacent cannot become
--- adjacent, so stepping away buys nothing. Adjacent is the deliberate
--- exception: backing off a mold you are standing next to is what the row is
--- for. Without this, a ranged character oscillated between fleeing and closing
--- for ever against an immobile enemy just out of talent range.
---
--- Keyed on "cannot move", NOT on "can anything in the rotation reach it":
--- that rule has the same oscillation one grid outside a talent's range
--- whenever that talent is on cooldown. Knowingly an approximation; the
--- principled question is #99.
local function pointlessFlee(p, target)
    local a = target and target.actor
    if not a or not a.x then return nil end
    if not a:attr("never_move") then return nil end
    if core.fov.distance(p.x, p.y, a.x, a.y) <= 1 then return nil end
    return ("%s cannot follow, and is not next to you"):format(tostring(a.name))
end

local function SAI_flee(entry, hostiles)
    local pointless = pointlessFlee(game.player, fleeTarget(entry, hostiles))
    if pointless then
        chan.debug("[Combat] [Flee] Pointless (%s): %s", pointless, tostring(rules.key(entry)))
        return false, pointless, true
    end
    local x, y, h = fleeStep(entry, hostiles)
    if not x then
        chan.debug("[Combat] [Flee] Not available (%s): %s", tostring(h), tostring(rules.key(entry)))
        -- #67 wants the reason, to say what cornered the character.
        return false, tostring(h)
    end
    local dir = game.level.map:compassDirection(x - game.player.x, y - game.player.y)
    if bot.do_nothing then
        game.log("[SkooBot] AI would flee from " .. tostring(h.name) .. " to the " .. tostring(dir))
        return true
    end
    chan.info("[Action] Fleeing from %s to the %s", tostring(h.name), tostring(dir))
    bot.actions = bot.actions + 1
    local moved = game.player:move(x, y)
    if not moved then
        chan.debug("[Combat] [Flee] The step was refused; not retrying this turn")
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

--- The player's own power level as the score compares it (#62): the heuristic
--- scaled by the life left, on score.lifeFactor's curve (#79). Over the life
--- POOL, not life/max_life (#91).
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
    -- #130: a retired talent is dropped here as well as at use, so it never
    -- reaches the rotation again -- including on a later activation, which is
    -- what talentfailed alone does not cover.
    local retired = retiredTalents(game.player)
    for _, v in ipairs(t) do
        if type(v) == "table" then
            if bot.loop.talentfailed[rules.key(v)] == nil and not retired[rules.key(v)] then out[#out + 1] = v end
        elseif not game.player:isTalentCoolingDown(game.player:getTalentFromId(v))
               and bot.loop.talentfailed[v] == nil and not retired[v] then
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

-- TODO (v1): exclude enemies in LOS but not LOE -- cannot Rush over pits, and
-- someone standing in front of the target blocks a non-piercing attack.
--
-- Built-in action entries (#59) have no talent to check and are passed over:
-- whether a flee has a step is the rotation's question, not a target's.
local function ownPowerLevel(p)
    local el = lifem.of(p)
    return score.ownPower(power.level(p, p.global_speed), el.safe_pool, el.safe_max)
end
--- The same figure, for a scenario that needs to know what the bot compared
--- with. Exposed rather than recomputed on the far side: the shape of the
--- scaling is this module's business, and a probe that re-derived it would
--- go stale the next time the curve moves (#79).
bot.ownPower = function(p) return ownPowerLevel(p or game.player) end

--- Which of the score's flags the player has told the bot to live with
--- (#11): a power condition set to IGNORE, or a WARN that has fired and
--- been restarted past. The score's posture is for these; a flag that is
--- not accepted stops the bot at the turn site before any posture is read.
local function acceptedFlags(p)
    local d = data(p)
    local out = {}
    for _, code in ipairs(score.FLAGS) do
        local def = conditions.find(code)
        if def and def.default then
            local stoptype = getStopCondition(p, code).stoptype
            if stoptype == "IGNORE" or (stoptype == "WARN" and d.stopwarn and d.stopwarn[code] ~= nil) then
                out[code] = true
            end
        end
    end
    return out
end

--- The situation scored (#11): data/score.lua over the player's own
--- power, the hostiles spotHostiles weighted, what the condition list says
--- the player cannot do, life, air, and whether damage arrived this turn.
local function evaluateSituation(p, hostiles, caps, damaged)
    local blocks = {}
    for _, what in ipairs({ "move", "act", "target" }) do
        if caps[what] then blocks[what] = conditions.blockedText(caps[what]) end
    end
    return score.evaluate({
        own      = ownPowerLevel(p),
        -- #91: the discounted life POOL fraction, not life/max_life.
        life     = lifem.of(p).safe_fraction,
        air      = (p.max_air and p.max_air > 0) and (p.air / p.max_air) or nil,
        hostiles = hostiles,
        blocks   = blocks,
        damaged  = damaged and true or false,
        accepted = acceptedFlags(p),
        retreats = bot.activation and bot.activation.retreats or 0,
    }, scoreKnobs())
end

--- What the condition detectors are given besides the player (#12): the
--- hostile count, what the detected conditions block (#12), the situation
--- scored (#11), the settings, and the chest scan for the explore site.
--- Built once per decision; `hostiles` is spotHostiles' list.
function conditionContext(p, hostiles)
    local ctx = {
        hostiles    = #hostiles,
        cfg         = cfg,
        -- #71: the option titles, so a message can name the knob the way
        -- the options tab does rather than by its key.
        title       = cfgfmt.title,
        -- #91: life as data/life.lua decomposes it -- the pool the game kills
        -- at, and how much of it the bot may trust.
        life        = lifem.of(p),
        describeLife = lifem.describe,
        chestInView = glowingChestInView,
        -- #93: the escortee, or nil. A function rather than a value because
        -- most turns never ask, and it walks the level's entity list.
        escortee    = function() return liveEscortee() end,
        -- #77: whole turns the character never got, counted by the act wrapper
        -- against the ENGINE's clock and not the bot's decision clock -- a rest
        -- is not a blackout. nil outside an activation, 0 on its first turn.
        turnsLost   = (bot.activation and bot.activation.turns_lost) or 0,
    }
    ctx.caps = conditions.capabilities(p, ctx)
    ctx.score = evaluateSituation(p, hostiles, ctx.caps, false)
    return ctx
end

-- #78: how many steps a chest is worth walking. The map is 65x40 at most in
-- the early zones, so a longer path is not a chest across the room -- it is
-- one the other side of the level, and the bot was not toggled on to go
-- sightseeing.
local SEEK_LIMIT = 40

--- Should the bot walk to a chest rather than stop for it (#78)? No when the
--- policy is IGNORE, when anything hostile is in view or the score is not
--- simply "fight", when the character cannot move, or when there is no chest
--- or it is already adjacent.
local function seekChest(ctx, hostiles)
    if #hostiles > 0 or ctx.caps.move then return false end
    if ctx.score and ctx.score.posture ~= score.FIGHT then return false end
    local pol = getStopCondition(game.player, "TERRAIN_GLOWING_CHEST")
    if not pol or pol.stoptype == "IGNORE" then return false end
    local chest = nearestGlowingChest(game.player)
    if not chest or chest.distance <= 1 then return false end
    return true
end

--- The escortee on this level, or nil (#93).
function liveEscortee()
    local level = game.level
    if not level or not level.entities then return nil end
    return escortm.escortee(level.entities, function(qid)
        if not qid then return true end
        local q = game.player.hasQuest and game.player:hasQuest(qid)
        if not q or not q.isStatus then return true end
        return not (q:isStatus(engine.Quest.DONE) or q:isStatus(engine.Quest.FAILED))
    end)
end

--- Is something hostile on the escortee (#93)?
---
--- Scanned from the ESCORTEE's grid rather than the player's -- that is the
--- case a player-centric scan misses -- but `game.level.map.seens` inside
--- spotHostiles is still the PLAYER's memory, so this never reports a room the
--- character has not looked into. Deliberate; docs/design-escort.md.
local function escortThreatened(npc)
    if not npc or not npc.x then return false end
    return #spotHostiles(npc, true) > 0
end

--- Should the bot be escorting rather than exploring (#93)? The policy is the
--- player's: IGNORE here means "explore as if the escort were not happening".
local function shouldEscort(ctx, hostiles)
    if #hostiles > 0 or ctx.caps.move then return false end
    if ctx.score and ctx.score.posture ~= score.FIGHT then return false end
    local pol = getStopCondition(game.player, "ESCORT_ACTIVE")
    if not pol or pol.stoptype == "IGNORE" then return false end
    local npc = liveEscortee()
    if not npc then return false end
    -- Already given up on this one here (#139): the player has been told, and
    -- re-entering the branch only tells them again, every decision, for ever.
    if bot.levelState("escortgaveup")[tostring(npc.uid)] then return false end
    return true
end

--- Take the level change underfoot (#86).
---
--- The game's own CHANGE_LEVEL handler (mod/class/Game.lua), so every guard it
--- applies -- never_move, the detrimental-effects refusal on a wilderness
--- exit, the grid's own change_level_check -- applies here too instead of
--- being re-implemented and left to rot.
---
--- The bot always stops afterwards, even at "always". A level change
--- regenerates the level under a running act loop whose scratch still
--- describes the old one, and #114 is what calling a re-entrant engine routine
--- from inside act() costs. Resuming on the new level is the player's toggle
--- for now; see #86 before changing that.
--- Which level we are on, for telling a change that happened from one that
--- did not. See #156.
local function levelKey()
    return tostring(game.zone and game.zone.short_name)
        .. ":" .. tostring(game.level and game.level.level)
end

local function takeLevelChange(what)
    if bot.do_nothing then
        game.log("[SkooBot] AI would take " .. what)
        return
    end
    chan.info("[Action] Taking %s", what)
    bot.actions = bot.actions + 1
    local before = levelKey()
    game.key:triggerVirtual("CHANGE_LEVEL")
    -- #156: Game.lua's CHANGE_LEVEL has five paths that do nothing but write to
    -- the log -- no energy, no change_level on the grid, never_move, a
    -- detrimental effect barring the world map, and a change_level_check that
    -- says no. The bot reported "took the stairs" down all of them, fifteen
    -- times in one run. changeLevel is synchronous, so the level itself says.
    if levelKey() == before then
        local p = game.player
        local tries = levelBump(("stairs:%d,%d"):format(p.x, p.y))
        if tries > STAIRS_TRIES then
            markRefusedExit()
            return stop(notice.HANDED_BACK,
                ("%s did not take, %d times -- looking for another way on"):format(what, tries))
        end
        return stop(notice.HANDED_BACK, what .. " did not take")
    end
    return stop(notice.HANDED_BACK, "took " .. what)
end

--- Standing on a level change, on an explored level (#86).
---
--- The engine's own auto-explore already walks the character here and prefers
--- the down stairs (#121 measured it), so the only thing that was missing is
--- the asking. TAKE_STAIRS says which of the three this is.
--- Note the argument is the GRID, fetched by the caller. `map:checkEntity`
--- returns the value of the attribute it was asked about, not the entity
--- carrying it, so the existing `onLevelChange` is a number and indexing it
--- raises.
local function atLevelChange(grid)
    local zoneExit = (grid and grid.change_zone) and true or false
    local what = zoneExit and "the way out of this zone" or "the stairs"
    local mode = tonumber(cfg("TAKE_STAIRS")) or cfgfmt.STAIRS_ASK

    -- #151: whatever TAKE_STAIRS says, not into the world map. bot.start()
    -- refuses to run in the wilderness, so taking that exit walks into a place
    -- the bot immediately hands back from -- and it is standing on the exit, so
    -- it hands back from there for ever. Eleven classes did that in sweep 2, up
    -- to eighteen times each, once TAKE_STAIRS=always let them through.
    --
    -- "Always take the stairs" is about descending a dungeon. Leaving the zone
    -- for the overworld is a different decision and stays the player's until
    -- the bot can actually cross it (#126).
    -- #152: ALWAYS means DOWN. Doomed took the stairs fifteen times in one run
    -- and never left trollmire:1 -- it descended, explored, found the way back
    -- up, took that too, and bounced. "Always take the stairs" is a statement
    -- about making progress, and up is not progress; the harness has drawn the
    -- same distinction from the start (soak.ps1's isDown).
    --
    -- Same arithmetic as the harness: change_level is a DELTA unless
    -- change_level_abs says it is a level number.
    if mode == cfgfmt.STAIRS_ALWAYS and not zoneExit and grid.change_level then
        local target = grid.change_level_abs and grid.change_level
            or ((game.level and game.level.level or 0) + grid.change_level)
        if target <= (game.level and game.level.level or 0) then
            markRefusedExit()
            return stop(notice.HANDED_BACK,
                "standing on the way back up; taking it is not progress")
        end
    end

    if zoneExit and tostring(grid.change_zone):find("^wilderness") then
        markRefusedExit()
        return stop(notice.HANDED_BACK,
            "standing on the way out of this zone, which leads to the world map -- "
            .. "the bot does not travel it")
    end

    if mode == cfgfmt.STAIRS_NEVER then
        return stop(notice.HANDED_BACK, "standing on a level change")
    end
    if mode == cfgfmt.STAIRS_ALWAYS then
        return takeLevelChange(what)
    end

    -- Ask. Query mode answers a question, it does not open things, and an
    -- offer that stacks on another dialog blocks itself -- both #96's rules.
    if bot.do_nothing or (game.dialogs and #game.dialogs > 0) then
        return stop(notice.HANDED_BACK, "standing on a level change")
    end
    StairsDialog = StairsDialog or require("mod.dialogs.skoobot_reclauded.StairsDialog")
    game:registerDialog(StairsDialog.new(
        ("#GOLD#This level is explored.#WHITE#\n\nYou are standing on %s. Shall I take %s?\n\n")
            :format(zoneExit and "the way out of this zone" or "a staircase", zoneExit and "it" or "them")
        .. "\"Always\" and \"Never ask\" set the "
        .. cfgfmt.title("TAKE_STAIRS") .. " option for this character, which you can change "
        .. "back on the settings screen.",
        function(choice)
            -- Per-character, not account-wide: how willing this character is
            -- to be walked down the stairs is a play-style choice, and a
            -- button on a mid-run prompt should not rewrite the default every
            -- future character starts with.
            if choice == "always" then bot.setCharSetting("TAKE_STAIRS", cfgfmt.STAIRS_ALWAYS) end
            if choice == "never" then
                bot.setCharSetting("TAKE_STAIRS", cfgfmt.STAIRS_NEVER)
                game.log("#GOLD#[SkooBot] It will not offer again for this character. The %s option turns it back on.",
                    cfgfmt.title("TAKE_STAIRS"))
            end
            if choice == "take" or choice == "always" then takeLevelChange(what) end
        end))
    return stop(notice.HANDED_BACK, "standing on a level change -- asked whether to take it")
end

--- Recovery attempts allowed per activation before the low-life stop is let
--- through anyway (#133). Three, because a recovery that has not raised the
--- pool in three turns is not going to, and the player should be told rather
--- than watched over indefinitely.
--- What a talent would clear RIGHT NOW, as the game itself counts it.
---
--- tactical.CURE is either a plain number or a function of the actor's current
--- effects returning how many detrimental ones it would remove
--- (data/talents/misc/inscriptions.lua:93, :143). The function form is the one
--- worth asking, because it answers zero when the thing it cures is not
--- present -- which is exactly "would this help me right now". Asking the
--- game's own tactical beats any list of effect names kept here, for the same
--- reason conditions.lua detects by capability and never by effect id.
local function cureValue(p, tid)
    local t = p.getTalentFromId and p:getTalentFromId(tid)
    local tac = t and t.tactical
    -- `tactical` is sometimes a function returning the table, as
    -- loadout.lua's resolveTactical already allows for.
    if type(tac) == "function" then
        local ok, res = pcall(tac, p, t, nil)
        tac = (ok and type(res) == "table") and res or nil
    end
    -- Lower case at RUNTIME: aiLowerTacticals rewrites the keys as the talent
    -- loads, so a live `tactical.CURE` is nil however the data file spells it
    -- (docs/api-surface-1.7.6.md, "t.tactical keys are LOWERCASED on load").
    -- Both accepted, as loadout.lua does.
    local c = type(tac) == "table" and (tac.cure or tac.CURE) or nil
    if type(c) == "function" then
        local ok, v = pcall(c, p, t, p)
        return (ok and type(v) == "number") and v or 0
    end
    return type(c) == "number" and c or 0
end

--- The recovery that addresses the situation, rather than the first row.
---
--- #133 fired talents[1] unconditionally. With a regeneration infusion ahead
--- of a wild infusion in Recovery that heals into an ice block it could have
--- broken instead -- every time, decided by whatever order the loadout
--- proposal happened to produce. A cure that is also a heal must not be passed
--- over for a pure heal.
local function bestRecovery(p, talents)
    local best, bestv = talents[1], 0
    for _, tid in ipairs(talents) do
        local v = cureValue(p, tid)
        if v > bestv then best, bestv = tid, v end
    end
    return best, bestv
end

local CLEANSE_TRIES = 3

--- Turns to wait out a block nothing can cure before handing it back (#150).
--- Sleep, daze and an ice block are all measured in a handful of turns; ten is
--- past all of them and far short of a run.
---
--- On `bot` rather than a file local because skoobot_act reads it and that
--- function is at LuaJIT's 60-upvalue limit -- a new local there is a parse
--- error, not a lint one.
bot.BLOCK_WAIT_TRIES = 10

--- #92: clear a blocking effect before handing the turn back.
---
--- Watched twice on 2026-08-25: the bot stopped on `cannot act (frozen)` while
--- carrying a wild infusion that would have broken the ice block, was
--- restarted, and stopped again. Nothing it did ended the effect -- the effect
--- expired. Same shape as #133, one trigger along.
---
--- Placed before the LIVENESS checks and not merely before the policy ones.
--- ENCASED carries no `default`, so conditions.policy() never lists it and no
--- stoptype a player or the harness can set applies to it; a run with
--- DEBUFF_FROZEN=IGNORE locked up in an ice block regardless. A cleanse placed
--- before the policy conditions alone would not have prevented it.
---
--- Fires only while something is actually blocked, so an infusion is not spent
--- on a cosmetic debuff, and is bounded for the reason #133's is: a cure that
--- has not freed the character in three turns is not going to, and the player
--- should be told rather than watched over indefinitely.
local function tryCleanse(ctx)
    local p = game.player
    if not ctx or not ctx.caps then return false end

    -- #140: held on the level, because the harness rebuilds the activation
    -- after every hand-back and a bound kept there bounds nothing.
    local st = levelState("cleanse")
    if not (ctx.caps.move or ctx.caps.act or ctx.caps.target or impaired(p)) then
        -- Free again: whatever ended it, the next block starts from zero. So
        -- being blocked twice on one level is not rationed, while a cure that
        -- does not work still stops after three. #150's wait budget rides
        -- along, for the same reason and on the same event.
        st.tries = 0
        levelState("blockwait").tries = 0
        return false
    end

    st.tries = (st.tries or 0) + 1
    if st.tries > CLEANSE_TRIES then return false end

    local talents = getRecoveryTalents()
    if bot.loop then talents = filterFailedTalents(talents) end
    if #talents == 0 then return false end
    local tid, value = bestRecovery(p, talents)
    if not tid or value <= 0 then return false end

    local t = p:getTalentFromId(tid)
    chan.info("[Survival] blocked, and %s would clear it: using it before handing back",
              tostring(t and t.name or tid))
    SAI_useTalent(tid)
    checkForAdditionalAction()
    return true
end

-- Reached through `bot` at the call sites inside skoobot_act. That function
-- sits one under LuaJIT's 60-upvalue limit, so two new file locals push it
-- over -- a parse error, not a lint one. `bot` is already an upvalue there.
bot.tryCleanse   = function(ctx) return tryCleanse(ctx) end
bot.bestRecovery = function(p, talents) return bestRecovery(p, talents) end

local LOWLIFE_TRIES = 3

--- #133: try to fix low life before handing it back.
---
--- LIFE_LOWLIFE is a STOP evaluated at the TURN site, before the state
--- branch -- so the Recovery talents the player configured, which the FIGHT
--- branch fires at a gentler threshold, never get a chance. The bot handed
--- the game back having spent none of its options, into a situation neither
--- restarting nor resting could change: a class lost a whole four-minute run
--- to it without taking a single turn (#123, #133).
---
--- Returns true when it acted, in which case the caller must not go on to
--- evaluate the stop this turn.
local function tryLowLifeRecovery(ctx)
    local def = conditions.find("LIFE_LOWLIFE")
    if not def or not def.detect then return false end
    -- Nothing in view ends the episode as surely as recovering does: the
    -- condition needs a hostile, so the count has to reset here too or a quiet
    -- moment banks the failures for the next fight.
    if not ctx or (ctx.hostiles or 0) == 0 then
        local q = levelState("lowlife")
        q.tries, q.life = 0, nil
        return false
    end
    -- #140: consecutive FAILURES, held on the level so a restart cannot clear
    -- them. Per activation this bounded nothing under the harness. Counting
    -- failures rather than attempts is the other half: the point was never
    -- "heal at most three times on a level", it was "a heal that has not
    -- raised the pool is not going to", so a heal that works resets it.
    local st = levelState("lowlife")
    if not def.detect(game.player, ctx) then
        -- Out of it. The allowance covers ONE continuous stretch at low life,
        -- not the whole level: the first version reset only while the
        -- condition was still firing, so a character that recovered fully
        -- never reset at all and gave up instantly on its next bad moment.
        st.tries, st.life = 0, nil
        return false
    end

    -- IGNORE is the player saying they do not want to be stopped for this, so
    -- there is nothing here to save them from and the ordinary rotation --
    -- which fires recovery on its own terms -- should be left to it.
    local pol = getStopCondition(game.player, "LIFE_LOWLIFE")
    if not pol or pol.stoptype == "IGNORE" then return false end

    local pool = game.player.life
    if st.life and pool and pool > st.life then st.tries = 0 end
    st.life = pool
    st.tries = (st.tries or 0) + 1
    if st.tries > LOWLIFE_TRIES then return false end

    -- bot.loop is built AFTER this point on the first pass of an activation,
    -- so the failed-talent filter is applied only when there is one to apply.
    local talents = getRecoveryTalents()
    if bot.loop then talents = filterFailedTalents(talents) end
    if #talents == 0 then return false end

    chan.info("[Survival] low life with %d in view: recovery before handing back", ctx.hostiles)
    -- No forced target, matching the FIGHT branch's own recovery call. Aiming
    -- these at the player is right and is #118's, which ships the placement
    -- guard with it; doing it here would be half of that change without the
    -- half that stops a mis-placed damage talent finishing the character off.
    SAI_useTalent((bestRecovery(game.player, talents)))
    checkForAdditionalAction()
    return true
end

--- One loop over the condition list for a site (#12), replacing v1's
--- checkForDebuffs / checkPowerLevel if-chains: every policy entry with a
--- detector is evaluated in the list's order, and the first that fires under
--- its WARN/STOP/IGNORE policy stops the bot. checkStop sees the ones that did
--- not fire too, so a WARN re-arms when its condition clears.
local function checkConditions(site, ctx)
    local p = game.player
    for _, def in ipairs(conditions.LIST) do
        if def.site == site and def.default and def.detect then
            local hit = def.detect(p, ctx) and true or false
            if checkStop(p, def.code, hit, hit and conditions.message(def, p, ctx) or nil,
                         def.severity, nil, ctx) then
                return true
            end
        end
    end
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
        -- #142: named, never raw `title`. Untitled dialogs are common and a
        -- nil one would raise here rather than simply not matching.
        local label = bot.dialogLabel(top)
        if string.match(label, "Lore found:") and top.key.virtuals.EXIT then
            -- a lore dialog: the player may have configured it to be ignored
            if tryStop(game.player, "DIALOG_LORE", "a dialog is open: " .. label, notice.HANDED_BACK) then
                chan.debug("[Dialog] stopped for the dialog: %s", label)
                return
            else
                chan.info("[Dialog] closing an ignored lore dialog: %s", label)
                top.key.virtuals.EXIT()
            end
        else
            -- #136: a dialog with a consent grid beside us is how being walked
            -- into a vault door looks from here, and it is the only moment the
            -- bot can be sure of it. Mark it, or explore targets it again the
            -- instant the dialog is closed and nothing downstream can tell.
            bot.markWalkedInto()
            return stop(notice.HANDED_BACK, "a dialog is open: " .. label)
        end
    end

    local hostiles = spotHostiles(game.player, true)
    -- #12: the turn-site conditions -- the debuffs, LIFE_LOWLIFE (only with
    -- something in view) and the four power checks -- in the list's order. The
    -- power checks read the situation score (#11), built here with the rest of
    -- the context; its verdict goes to the log at debug so a bug report can say
    -- what the bot thought of the room.
    local ctx = conditionContext(game.player, hostiles)
    if #hostiles > 0 then
        chan.debug("[Score] threat %s, posture %s: %s", ctx.score.suffix:sub(12), ctx.score.posture,
            table.concat(ctx.score.reasons, "; "))
    end
    if bot.tryCleanse(ctx) then return end
    if tryLowLifeRecovery(ctx) then return end
    if checkConditions(conditions.SITE_TURN, ctx) then return end
    if #hostiles > 0 then
        bot.state = STATE_FIGHT
    end

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

    -- #130: before choosing anything, retire whatever raised since the last
    -- decision. A talent that opens a dialog raises after its coroutine
    -- resumes, so this is the first point at which the error is visible.
    harvestTalentErrors()

    if activateSustained() then return end

    chan.debug("[State] %s", aiStateString())

    if bot.state == STATE_REST then
        local p = game.player
        -- FIXED (T-015). Never ran in v1: `not game.player.undead == 1` parses
        -- as `(not undead) == 1`, always false, so a character rested
        -- underwater and drowned for eight years. The trigger is ToME's own
        -- suffocation rule now (data/air.lua).
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
        -- #154: a rest that moved no turns, twice, at full life, is not going
        -- to move one now. Explore instead -- returning without acting spends
        -- no turn either, which is the same idle with an extra step, and is
        -- exactly what the first version of this did: a two-minute soak
        -- advanced ZERO game turns.
        local rst = bot.levelState("rest")
        if (rst.noop or 0) >= 2 and (p.life or 0) >= (p.max_life or 0) then
            chan.debug("[Rest] %d rests moved no turns and life is full; exploring instead", rst.noop)
            bot.state = STATE_EXPLORE
            return skoobot_act(true)
        end
        return SAI_beginRest()

    elseif bot.state == STATE_EXPLORE then
        if bot.loop.delta < 0 then
            if #hostiles > 0 then
                bot.state = STATE_FIGHT
                return skoobot_act(true)
            end
            -- FIXED (T-011). v1 stopped on ANY damage while exploring, so a
            -- single poison tick halted the bot. Hand back only once life has
            -- fallen to the threshold, which since #11 is a term of the score
            -- -- scored again here because the delta is known only after the
            -- loop scratch was rebuilt. The `return` was missing until #11.
            local unseen = evaluateSituation(game.player, hostiles, ctx.caps, true)
            if unseen.flags.EXPLORE_DAMAGE then
                return stop(notice.STOPPED, unseen.reasons[1])
            end
        end
        -- Breath below three-quarters: switch to REST, which now runs to air
        -- if we are actually suffocating (T-015). Ratio, not v1's flat 75.
        if game.player.max_air and game.player.max_air > 0
           and (game.player.air / game.player.max_air) < 0.75 then
            bot.state = STATE_REST
            return skoobot_act(true)
        end
        -- T-013 and #78: hand back for a glowing chest -- they can be guarded,
        -- so the player decides -- but walk to it first, since the decision is
        -- easier to act on standing next to it. WARN re-arms when the chest
        -- leaves view. The policy is READ, not fired: firing it here would
        -- consume the WARN and the hand-back at the chest would never come.
        if seekChest(ctx, hostiles) then
            bot.state = STATE_SEEK
            return skoobot_act(true)
        end
        -- #93: an escort defers exploring entirely -- the escortee walks itself
        -- to its portal and wandering after unseen tiles abandons it.
        if shouldEscort(ctx, hostiles) then
            bot.state = STATE_ESCORT
            return skoobot_act(true)
        end
        if checkConditions(conditions.SITE_EXPLORE, ctx) then return end
        -- #62: exempt the tile the activation started on until the player has
        -- left it, or toggling the bot on the stairs you arrived by hands back
        -- at once with "level change found" and nothing else.
        local onLevelChange = game.level.map:checkEntity(game.player.x, game.player.y,
            engine.Map.TERRAIN, "change_level")
        if onLevelChange and not onActivationStartTile() then
            return atLevelChange(game.level.map(game.player.x, game.player.y, engine.Map.TERRAIN))
        end
        -- FIXED (T-012). v1 called auto-explore while unable to move, which
        -- cannot progress and spun -- the pin / dominate / entangle freeze
        -- users reported. Ask "can I move at all?" over every never_move
        -- source, never a named effect, so it stays correct as ToME adds them;
        -- mishander's fork tested only EFF_PINNED. Since #12 it is the
        -- CANNOT_MOVE entry. Exploring means moving, so a move block hands back
        -- whatever the policies say (liveness, design 1.1).
        local caps = ctx.caps
        if caps.move then
            stop(notice.STOPPED, "cannot move (" .. conditions.blockedText(caps.move) .. ")")
        elseif not bot.seekProgressExit() then
            SAI_beginExplore()
        end
        return

    elseif bot.state == STATE_HUNT then
        -- TODO (v1): hook takeHit() to get here, then work out whether the
        -- damage source can be targeted or we have to randomwalk/flee.
        bot.state = STATE_EXPLORE
        return skoobot_act(true)

    elseif bot.state == STATE_SEEK then
        -- #78: walking to a glowing chest -- a SECOND kind of objective, and
        -- the reason the scorer did not simply grow one: data/score.lua
        -- evaluates THREAT, and a chest is an opportunity. So the score is
        -- never asked to rank chests, only whether walking is still all right;
        -- anything but "fight" ends the walk, which keeps threat strictly
        -- ahead of opportunity.
        local act = bot.activation
        local chest = nearestGlowingChest(game.player)
        -- Gone, opened by something else, or out of sight: nothing to do.
        if not chest then
            if act then act.seeks = 0 end
            bot.state = STATE_EXPLORE
            return skoobot_act(true)
        end
        -- Arrived. The hand-back is the ordinary condition check, so the
        -- reason, the severity and the WARN/STOP/IGNORE policy are #8's and
        -- not a second copy of them.
        if chest.distance <= 1 then
            if act then act.seeks = 0 end
            bot.state = STATE_EXPLORE
            if checkConditions(conditions.SITE_EXPLORE, ctx) then return end
            -- IGNORE, or a WARN already acknowledged: carry on exploring.
            return skoobot_act(true)
        end
        -- The score's veto, re-read here rather than trusted from the step
        -- that started the walk.
        if ctx.caps.move or (ctx.score and ctx.score.posture ~= score.FIGHT) then
            if act then act.seeks = 0 end
            bot.state = STATE_EXPLORE
            return skoobot_act(true)
        end
        if act then
            act.seeks = (act.seeks or 0) + 1
            if act.seeks > SEEK_LIMIT then
                chan.debug("[Seek] gave up after %d steps", act.seeks)
                act.seeks = 0
                bot.state = STATE_EXPLORE
                return skoobot_act(true)
            end
        end
        local sa = Astar.new(game.level.map, game.player)
        -- #64's exclusion applies here too: a chest behind a vault door is
        -- not a reason to walk into the vault door.
        local spath = sa:calc(game.player.x, game.player.y, chest.x, chest.y,
            nil, nil, function(x, y) return not needsConsent(x, y) end)
        if not spath or #spath == 0 then
            chan.debug("[Seek] no path to the chest at %d,%d", chest.x, chest.y)
            if act then act.seeks = 0 end
            bot.state = STATE_EXPLORE
            -- No path is the old behaviour's situation exactly: in view,
            -- unreachable. Hand back where the bot stands, as #8 did.
            if checkConditions(conditions.SITE_EXPLORE, ctx) then return end
            return skoobot_act(true)
        end
        chan.info("[Seek] Walking to a glowing chest, %d away", chest.distance)
        if not SAI_movePlayer(spath[1].x, spath[1].y) and not bot.do_nothing then
            if act then act.seeks = 0 end
            bot.state = STATE_EXPLORE
            return stop(notice.CANNOT_ACT, "could not walk to the glowing chest")
        end
        checkForAdditionalAction()
        return

    elseif bot.state == STATE_ESCORT then
        -- #93. Built on STATE_SEEK's shape: a walking objective that threat
        -- always outranks, with the score re-read every step rather than
        -- trusted from the step that started the walk. The difference is that
        -- the target moves, so it is recomputed each step and arrival is a band.
        local act = bot.activation
        local npc = liveEscortee()
        local pol = getStopCondition(game.player, "ESCORT_ACTIVE")
        if not npc or not pol or pol.stoptype == "IGNORE" then
            if act then act.escorts = 0 end
            bot.state = STATE_EXPLORE
            return skoobot_act(true)
        end
        -- Told once per escort that exploring is off, and STOP hands back at
        -- every turn of one. The entry's own wording and severity, not a
        -- second copy of them.
        local edef = conditions.find("ESCORT_ACTIVE")
        if edef and checkStop(game.player, edef.code, true,
                              conditions.message(edef, game.player, ctx), edef.severity) then
            return
        end
        if ctx.caps.move or (ctx.score and ctx.score.posture ~= score.FIGHT) then
            if act then act.escorts = 0 end
            bot.state = STATE_EXPLORE
            return skoobot_act(true)
        end
        local plan, why = escortm.plan(game.player, npc,
            { dist = core.fov.distance, threatened = escortThreatened(npc) })
        if plan == escortm.DONE then
            if act then act.escorts = 0 end
            bot.state = STATE_EXPLORE
            return skoobot_act(true)
        end
        if plan == escortm.HOLD then
            -- The escortee walks itself (mod/ai/escort.lua move_escort), and it
            -- idles 35% of turns to let the player keep up, so standing still
            -- IS the move -- for a while. #129: this reset the counter on every
            -- hold, so only CLOSING was ever bounded and a hold could repeat for
            -- the whole run. Waiting is a real action, so #13 saw progress and
            -- nothing reported it.
            --
            -- Bounded on holds where the escortee did not move either: if
            -- neither of us is going anywhere, waiting cannot help.
            -- #139: anchored, not compared with last turn. An escortee
            -- shuffling between two tiles moves every turn and gets nowhere,
            -- which the previous-position test read as movement and reset the
            -- counter on, every turn.
            -- #140: the anchor is held on the LEVEL, not the activation. On the
            -- activation a restart cleared it, so the count never reached the
            -- limit however long the escortee shuffled. Deliberately NOT reset
            -- when the limit is hit either: the only thing that should start
            -- escorting again is the escortee actually getting somewhere, which
            -- holdCount already resets on.
            if act then
                act.escorts = 0
                local anchor = bot.levelState("escortanchor")
                local holds = escortm.holdCount(anchor, npc, core.fov.distance)
                if holds > escortm.HOLD_LIMIT then
                    -- Told once, then dropped for this level. #140 made the
                    -- anchor survive the hand-back so a restart could not clear
                    -- it, which turned a silent forever-wait into a LOUD one:
                    -- eighteen hand-backs in eleven game turns, measured in
                    -- sweep 1. The bound means "this escort is not going
                    -- anywhere", so the answer is to stop escorting and get on
                    -- with the level, not to keep announcing it. A player who
                    -- restarts after the notice has already decided to carry on.
                    bot.levelState("escortgaveup")[tostring(npc.uid)] = true
                    return stop(notice.HANDED_BACK,
                        ("%s has not got anywhere in %d turns; leaving them to it"):format(
                            escortm.name(npc), escortm.HOLD_LIMIT))
                end
            end
            chan.debug("[Escort] holding: %s", tostring(why))
            SAI_wait(npc)
            checkForAdditionalAction()
            return
        end
        if act then
            act.escorts = (act.escorts or 0) + 1
            if act.escorts > escortm.STEP_LIMIT then
                chan.debug("[Escort] gave up closing after %d steps", act.escorts)
                act.escorts = 0
                return stop(notice.HANDED_BACK, "could not keep up with " .. escortm.name(npc))
            end
        end
        local ea = Astar.new(game.level.map, game.player)
        -- #64's exclusion again: the escortee walks through a door the bot
        -- will not open without consent, and following it into one is the
        -- sealed-door loop.
        local epath = ea:calc(game.player.x, game.player.y, npc.x, npc.y,
            nil, nil, function(x, y) return not needsConsent(x, y) end)
        if not epath or #epath == 0 then
            if act then act.escorts = 0 end
            return stop(notice.HANDED_BACK, "no way through to " .. escortm.name(npc))
        end
        chan.info("[Escort] Closing on %s: %s", escortm.name(npc), tostring(why))
        if not SAI_movePlayer(epath[1].x, epath[1].y) and not bot.do_nothing then
            if act then act.escorts = 0 end
            return stop(notice.CANNOT_ACT, "could not move toward " .. escortm.name(npc))
        end
        checkForAdditionalAction()
        return

    elseif bot.state == STATE_FIGHT then
        -- #12 (design 1.1): a move block changes nothing until the rotation
        -- finds no talent that reaches -- a pinned character still attacks what
        -- is next to it -- and then the hand-back says why instead of trying a
        -- step the engine would refuse. An act or target block hands back here
        -- rather than walking the rotation for nothing.
        --
        -- #11: the score's posture says the rest.
        local caps = ctx.caps
        local verdict = ctx.score
        if verdict.posture == score.HANDBACK then
            -- #150: an act or target block cannot clear while the bot hands
            -- back. stop() spends no game time, so the effect never ticks down
            -- and the harness restarts into the identical state -- Bulwark did
            -- that 37 times at a single game turn, encased in ice, and
            -- Solipsist 15 times asleep. Waiting is the only thing that ends
            -- one, and it is what a player would do.
            --
            -- After tryCleanse, never instead of it: if something in Recovery
            -- clears the effect that has already been tried and this is the
            -- case where nothing can.
            if (caps.act or caps.target) and not bot.do_nothing then
                local bw = bot.levelState("blockwait")
                bw.tries = (bw.tries or 0) + 1
                if bw.tries <= bot.BLOCK_WAIT_TRIES then
                    chan.info("[Survival] %s; nothing clears it, waiting (%d/%d)",
                        table.concat(verdict.reasons, "; "), bw.tries, bot.BLOCK_WAIT_TRIES)
                    bot.actions = bot.actions + 1
                    game.player:waitTurn()
                    return
                end
            end
            local severity = (caps.act or caps.target) and notice.CANNOT_ACT or notice.STOPPED
            return stop(severity, table.concat(verdict.reasons, "; "))
        end
        -- The retreat steps in a row are counted on the activation, so the
        -- score can call the chase off (score.RETREAT_LIMIT); any other
        -- posture, or a step that could not be taken, starts the count over.
        local act = bot.activation
        if verdict.posture == score.RETREAT
           and SAI_flee({ action = "flee", from = "strongest" }, hostiles) then
            if act then act.retreats = (act.retreats or 0) + 1 end
            checkForAdditionalAction()
            return
        end
        if act then act.retreats = 0 end

        -- #81: v1's `if filterFailedTalents(getAvailableTalents(enemy))` tests
        -- a TABLE for truth, so this filter has never once filtered.
        --
        -- Do NOT repair it as `#... > 0`. getAvailableTalents requires
        -- canProject at the enemy's grid, so RANGE is part of the test: a melee
        -- character five squares off has nothing available, `targets` comes out
        -- empty, and the branch below sends the bot to REST -- which re-enters
        -- with the orc still in view and spins to THINK_LIMIT. Melee would stop
        -- working. scenario-scoring probe A guards it.
        --
        -- The filter decides only the PICK: approach needs every hostile, since
        -- closing the distance is HOW a melee talent comes into range.
        local targets, usable = {}, {}
        -- #146: an enemy already found unreachable FROM THIS GRID is not a
        -- target. Doombringer lost a whole run to one -- thirty-seven identical
        -- hand-backs in 110 game turns -- because a hostile in view keeps the
        -- bot in FIGHT and an unreachable one gives FIGHT nothing to do.
        local cannotReach, unreachable = bot.levelState("unreachable"), 0
        local herePos = ("%d,%d"):format(game.player.x, game.player.y)
        for _, enemy in pairs(hostiles) do
            local a = enemy.actor
            local uid = a and rawget(a, "uid")
            if uid and cannotReach[tostring(uid)] == herePos then
                unreachable = unreachable + 1
            else
                -- attacking is a talent, so it does not need adding as a choice
                targets[#targets + 1] = enemy
                if #filterFailedTalents(getAvailableTalents(enemy)) > 0 then
                    usable[#usable + 1] = enemy
                end
            end
        end

        if #targets == 0 and unreachable > 0 then
            -- Everything in view is behind something. EXPLORE, not REST: the
            -- comment below records that REST re-enters with the enemy still in
            -- view and spins to THINK_LIMIT, and exploring both avoids that and
            -- is the thing that can change the answer -- move, and reachability
            -- is a different question.
            chan.debug("[Combat] %d hostile(s) in view, none reachable from here; exploring", unreachable)
            bot.state = STATE_EXPLORE
            return skoobot_act(true)
        end

        if #targets == 0 then
            -- nothing left in sight: fight's over
            -- TODO (v1): or we are blind. Resolves itself once HUNT works.
            bot.state = STATE_REST
            return skoobot_act(true)
        end
        -- #67 needs the rotation as the PLAYER wrote it, not the filtered
        -- view: whether closing the distance could ever serve a talent is a
        -- question about the configuration, not about what is on cooldown.
        local rotation, heldCount = getCombatRotation()
        local combatTalents = filterFailedTalents(rotation)

        if #combatTalents > 0 then
            -- #81: the lowest-life enemy something can be used on, falling back
            -- to the lowest-life enemy at all when nothing can -- the pre-#81
            -- behaviour, kept so that making this filter live changes exactly
            -- one thing: the first pick is not wasted. getNearestHostile stays
            -- as the second pick; it re-reads the field itself.
            local picks = { getLowestHealthEnemy(#usable > 0 and usable or targets), getNearestHostile() }
            local talents

            -- #91: a quarter of the POOL, not of max_life. A character whose
            -- die_at doubles its pool loses a smaller share of it to the same
            -- hit and should not burn a Damage Prevention talent on a scratch;
            -- one with an adverse die_at loses a larger share and should.
            local el = lifem.of(game.player)
            if (bot.loop.delta < 0)
               and (el.safe_max > 0)
               and (math.abs(bot.loop.delta) / el.safe_max >= cfg("LOWHEALTH_RATIO") / 4) then
                talents = filterFailedTalents(getPreventionTalents())
                if #talents > 0 then
                    chan.debug("[Survival] [Sustain] using sustain, lost more than %d%% life in one turn!",
                        math.floor(100 * cfg("LOWHEALTH_RATIO") / 4))
                    SAI_useTalent(talents[1])
                    checkForAdditionalAction()
                    return
                else
                    chan.debug("[Survival] [Sustain] Lost more than %d%% life, but no sustain off cooldown!",
                        math.floor(100 * cfg("LOWHEALTH_RATIO") / 4))
                end
            end

            if (el.safe_fraction <= 1 - cfg("LOWHEALTH_RATIO") / 4) then
                talents = filterFailedTalents(getRecoveryTalents())
                if #talents > 0 then
                    chan.debug("[Survival] [Recovery] using recovery, missing more than %d%% life...",
                        math.floor(100 * cfg("LOWHEALTH_RATIO") / 4))
                    SAI_useTalent((bot.bestRecovery(game.player, talents)))
                    checkForAdditionalAction()
                    return
                else
                    chan.debug("[Survival] [Recovery] Missing more than %d%% life, but no recovery off cooldown!",
                        math.floor(100 * cfg("LOWHEALTH_RATIO") / 4))
                end
            end

            -- The rotation, in the player's order: a talent is tried on the
            -- picks -- lowest-life enemy, then nearest -- and the first usable
            -- one fires, as v1 did. A flee (#59) is tried on the FIELD, not on
            -- a pick, so it splits the list into tiers: everything above it is
            -- tried on both picks first, then the flee, then what is below.
            local tier = {}
            local function fireTier()
                if #tier == 0 then return false end
                for _, enemy in pairs(picks) do
                    chan.debug("[Combat] Target selected: %s", tostring(enemy.name))
                    talents = filterFailedTalents(getAvailableTalents(enemy, tier))
                    local tid = talents[1]
                    if tid ~= nil then
                        chan.debug("[Combat] Using talent: %s on target %s", tid, tostring(enemy.name))
                        game.player:setTarget(enemy.actor)
                        SAI_useTalent(tid, nil, nil, nil, enemy.actor)
                        return true
                    end
                end
                tier = {}
                return false
            end
            -- #67: what cornered the character, if a flee was tried and had
            -- nowhere to go. Kept for the fallthrough below.
            local blockedFlee, uselessFlee = nil, nil
            for _, item in ipairs(combatTalents) do
                if type(item) == "table" then
                    if fireTier() then checkForAdditionalAction() return end
                    local fled, why, pointless = SAI_flee(item, hostiles)
                    if fled then checkForAdditionalAction() return end
                    -- #97: a flee skipped as pointless is not a flee with
                    -- nowhere to go, and must not be reported as cornered.
                    if pointless then uselessFlee = why or uselessFlee
                    else blockedFlee = why or blockedFlee end
                else
                    tier[#tier + 1] = item
                end
            end
            if fireTier() then checkForAdditionalAction() return end

            -- no legal target: get closer -- unless the character cannot move
            -- (#12), or a flee was the whole rotation and had nowhere to go
            -- (#67), or the posture is to hold (#11) and a turn is spent
            -- waiting for them to come.
            if caps.move then
                -- #163: the same storm #150 fixed, at the OTHER site. This
                -- check returns before the posture is ever consulted, so #150's
                -- wait -- which lives in the HANDBACK branch -- never sees it.
                -- Paradox Mage handed back fifteen times at a single game turn,
                -- pinned, on the first run that class has ever had.
                --
                -- Shares #150's budget deliberately: it is the same condition
                -- and the same reasoning, and two separate allowances would let
                -- one fight spend both.
                local bw = bot.levelState("blockwait")
                bw.tries = (bw.tries or 0) + 1
                if bw.tries <= bot.BLOCK_WAIT_TRIES and not bot.do_nothing then
                    chan.info("[Survival] pinned and nothing reaches %s; waiting (%d/%d)",
                        tostring(targets[1].name), bw.tries, bot.BLOCK_WAIT_TRIES)
                    bot.actions = bot.actions + 1
                    game.player:waitTurn()
                    return
                end
                return stop(notice.CANNOT_ACT, "cannot move (" .. conditions.blockedText(caps.move)
                    .. "), and no Combat talent reaches " .. targets[1].name)
            end

            -- #67: CORNERED. The tail below is v1's -- walk at targets[1] --
            -- which for a rotation of flees alone is a bump attack, the exact
            -- opposite of the row the player placed. Asked of `rotation`, the
            -- player's own list, not `combatTalents`: a talent that merely
            -- failed this iteration still says they want to fight when
            -- cornered.
            if blockedFlee then
                local hasTalent = false
                for _, item in ipairs(rotation) do
                    if type(item) ~= "table" then hasTalent = true break end
                end
                if not hasTalent then
                    return stop(notice.CANNOT_ACT, "cornered: " .. blockedFlee
                        .. ", and the rotation is flee only")
                end
            end
            -- #97: the same shape for a flee that was skipped rather than
            -- blocked. "Cornered" would be untrue -- there is somewhere to
            -- go, there is just no reason to go there.
            if uselessFlee then
                local hasTalent = false
                for _, item in ipairs(rotation) do
                    if type(item) ~= "table" then hasTalent = true break end
                end
                if not hasTalent then
                    return stop(notice.CANNOT_ACT, "nothing to flee from: " .. uselessFlee
                        .. ", and the rotation is flee only")
                end
            end

            if verdict.posture == score.HOLD then
                SAI_wait(targets[1])
                checkForAdditionalAction()
                return
            end
            local a = Astar.new(game.level.map, game.player)
            -- #64: never route through a grid the player must consent to
            -- enter. Astar's add_check (engine/Astar.lua:113, :134, :156) takes
            -- each candidate grid; a sealed door sets no block_move, so without
            -- this the path runs through it and the bot walks into a popup it
            -- can only hand back on.
            local function pathTo(tx, ty)
                return a:calc(game.player.x, game.player.y, tx, ty,
                    nil, nil, function(x, y) return not needsConsent(x, y) end)
            end
            local path = pathTo(targets[1].x, targets[1].y)
            -- #120: a creature that walks through walls stands in a grid A*
            -- will not enter, so the walk fails with every neighbouring grid
            -- free -- a golem inside an arena pillar with eight open sides.
            -- Only ON that failure aim beside it instead: the target's OWN
            -- grid has to stay the first choice, because the last step into it
            -- is how a melee attack happens (#81).
            -- Standing beside it already is the one case the fallback must not
            -- run: every remaining neighbour is one step away, so it would pick
            -- one, step across, and shuffle around the pillar for ever.
            local beside = core.fov.distance(game.player.x, game.player.y, targets[1].x, targets[1].y) <= 1
            if not path and not beside then
                local best
                for _, dir in ipairs(util.adjacentDirs()) do
                    local sx, sy = util.coordAddDir(targets[1].x, targets[1].y, dir)
                    if game.player:canMove(sx, sy) and not needsConsent(sx, sy) then
                        local p2 = pathTo(sx, sy)
                        if p2 and #p2 > 0 and (not best or #p2 < #best) then best = p2 end
                    end
                end
                if best then
                    chan.debug("[Combat] [Movement] %s is in an unreachable grid; closing on a neighbour instead",
                        tostring(targets[1].name))
                    path = best
                end
            end
            chan.debug("[Combat] [Movement] Pathing towards %s", tostring(targets[1].name))
            getDirNum(game.player, targets[1])  -- v1 computed this and never used it

            if not path or #path == 0 then
                if beside then
                    return stop(notice.CANNOT_ACT, "standing next to " .. targets[1].name
                        .. ", which is in a grid you cannot enter, and nothing in the rotation reaches it")
                end
                -- #146: remember it, so the next decision is not this one again.
                -- Keyed to the grid we learned it from, because reachability is
                -- a fact about where we are standing: step anywhere else and the
                -- question is open again.
                local a1 = targets[1].actor
                if a1 and rawget(a1, "uid") then
                    bot.levelState("unreachable")[tostring(a1.uid)] =
                        ("%d,%d"):format(game.player.x, game.player.y)
                end
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
            chan.debug("[Combat] Nothing in the Combat rotation is usable.")
            -- #75, #71, #18: an empty rotation has three causes and the
            -- message says which. Asked of ROWS, not #rotation -- a row naming
            -- a talent this character does not have resolves to nothing, and
            -- that is not "nothing configured". Only the no-rows case gets the
            -- loadout hint.
            local rows = #getRules(game.player).Combat
            local configured = #rotation + heldCount
            local text, extra, nothingConfigured
            if rows == 0 then
                text = "no Combat talent is configured"
                extra = { hint = "set talent usage in the SkooBot: Reclauded menu, "
                    .. bot.keyFor("MENU_SKOOBOT_RECLAUDED")
                    .. ", or let the bot suggest a loadout from the talent screen" }
                nothingConfigured = true
            elseif heldCount == 0 then
                text = "no Combat talent is ready -- every one is on cooldown or unusable"
            elseif heldCount == configured then
                text = ("no Combat talent is ready -- every one is held while impaired (%d)")
                    :format(heldCount)
            else
                text = ("no Combat talent is ready -- %d held while impaired, "
                    .. "the rest on cooldown or unusable"):format(heldCount)
            end
            stop(notice.CANNOT_ACT, text, extra)
            -- #96: offer the way out rather than describing it. After the
            -- stop, so the message log and the banner read the same as they
            -- would without it and nothing depends on the dialog existing.
            if nothingConfigured then offerSetup() end
            return
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
    -- #65: a real run begins from a fresh activation, whatever a query left
    -- behind. Reusing one meant a query on the stairs followed by a toggle
    -- elsewhere ran on the query's start tile, with its unspentTotal and its
    -- #13 liveness counters.
    clearActivation()
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

--- Say what the bot would do here, acting on nothing: no energy is spent and
--- no game.turn passes. The activation stays on the table for inspection but
--- is marked as a query's, and the next entry point discards it (#65), so a
--- verdict is always for the tile the player stands on now. An UNMARKED one is
--- honoured, so a test can ask about another tile.
function bot.query()
    if bot.active == true then
        return game.log("Cannot query while SkooBot: Reclauded is active!")
    end
    if game.zone.wilderness then
        return stop(notice.CANNOT_ACT, "cannot be used in the wilderness")
    end
    if bot.activation and bot.activation.from_query then clearActivation() end
    bot.do_nothing = true
    skoobot_act()
    bot.do_nothing = false
    if bot.activation then bot.activation.from_query = true end
end

--- One decision, acted on, as the first decision of a toggle would be: a fresh
--- activation from this tile (#65).
---
--- The flag is `single_run`, not `runonce` (#70): putting both the function
--- and its flag on one key replaced the function with a boolean on the first
--- call, and the second press failed.
function bot.runonce()
    if bot.active == true then
        return game.log("Cannot runonce while SkooBot: Reclauded is active!")
    end
    if game.zone.wilderness then
        return stop(notice.CANNOT_ACT, "cannot be used in the wilderness")
    end
    clearActivation()
    bot.single_run = true
    skoobot_act()
    bot.single_run = false
    clearActivation()
end

--- One line for the harness and for bug reports.
--- The class pools this character runs on, worst first (#128). Read through
--- the engine's own registry rather than a list of names, so an addon that
--- adds a resource is covered.
function bot.resources(p)
    p = p or game.player
    local ActorResource = require "engine.interface.ActorResource"
    return resources.of(p, ActorResource.resources_def or {},
        function(tid) return p:knowTalent(tid) end)
end

function bot.inspect()
    local p = game and game.player
    if not p then return "no player" end
    local hostiles = #spotHostiles(p, true)
    local act = bot.activation
    -- #128: the pools go on the status line so every soak and every sweep run
    -- becomes evidence about starvation, which is the thing the bot cannot
    -- currently see and the player reports as "it just melees".
    local res = resources.describe(bot.resources(p))
    return ("turn=%s hostiles=%d life=%s/%s air=%s resting=%s running=%s wilderness=%s "
        .. "res=[%s] active=%s state=%s actions=%d iterations=%s stalled=%s reason=%s"):format(
        tostring(game.turn), hostiles, tostring(p.life), tostring(p.max_life), tostring(p.air),
        tostring(p.resting ~= nil), tostring(p.running ~= nil),
        tostring(game.zone and game.zone.wilderness or false), res,
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
            -- Ordinary control flow, not a bug: the nested act() a run or
            -- rest starts from lands here once the step has spent the energy.
            chan.debug("[PlayerActions] act called with insufficient energy; waiting for the next turn")
            return
        end
        if game.zone.wilderness then
            stop(notice.CANNOT_ACT, "cannot be used in the wilderness")
            return
        end
        -- #13: the liveness invariant, checked BEFORE the decision so a spin
        -- is cut at its STALL_LIMITth iteration rather than after it. From the
        -- second iteration on, an unchanged game.turn means the previous one
        -- spent no game time.
        local act = bot.activation
        if act then
            act.iterations = act.iterations + 1
            if game.turn == act.last_turn then
                act.stalled = act.stalled + 1
            else
                act.last_turn = game.turn
            end
            chan.trace("[PlayerActions] iteration %d at game turn %d, stalled %d",
                act.iterations, game.turn, act.stalled)
            if act.stalled >= STALL_LIMIT then
                -- The bug report: the full state line, at info so it is in
                -- te4_log.txt by default.
                chan.info("[Liveness] no progress in %d iterations: %s", act.stalled, bot.inspect())
                return stop(notice.STOPPED, ("no progress in %d iterations (state: %s) -- please report this"):format(
                    act.stalled, aiStateString()))
            end
        end
        skoobot_act()
    end
    if not bot.active and not bot.single_run then
        clearActivation()
    end
    if game.player:enoughEnergy() and bot.active and bot.state == STATE_EXPLORE then
        skoobot_act(true)
    end
end

-- v1 kept the "timer registered" flag on the player, where it was saved with
-- the character and never cleared, so ACTION_DELAY only ever worked once per
-- character. The flag is transient here.
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

-------------------------------------------------------------------------------
-- The engine seam (#14)
--
-- The whole of what this addon does to the game's classes: two methods of
-- mod.class.Player, each wrapped by a one-line superload, so a changed
-- signature in a future ToME is one line to re-read. Why neither can be a
-- hook: docs/api-surface-1.7.6.md.
-------------------------------------------------------------------------------

--- After the engine's Player:act (#14): the per-turn driver. Irreducible --
--- Player:act fires no hook and the engine's per-turn callbacks run too early
--- (docs/api-surface-1.7.6.md). The original's return passes through untouched.

--- How long one of this character's turns is, in game.turn units: ten ticks at
--- speed 1, proportionally sooner or later as global_speed moves. Without it a
--- slowed character reads as blacked out on every single turn (#77).
local function turnLength(p)
    local s = tonumber(p.global_speed) or 1
    if s <= 0 then s = 1 end
    return 10 / s
end

local function afterAct(self, ...)
    if game.player == self then
        -- #77: this runs BEFORE the rest/run gate below, because Player:act
        -- fires on every turn the engine hands the player, rests and explore
        -- runs included -- on which the bot decides nothing, so a blackout read
        -- off the decision clock reported every rest as time lost. A blackout
        -- is the opposite case: no turn is given, act() does not fire, and the
        -- gap is visible here when it resumes.
        local act = bot.activation
        if act then
            local gap = game.turn - (act.last_act_turn or game.turn)
            act.last_act_turn = game.turn
            -- floor, not round: one turn's worth of gap is the turn just
            -- taken, and anything short of a whole extra turn is jitter --
            -- energy does not divide exactly and speed can change mid-gap.
            act.turns_lost = math.max(0, math.floor(gap / turnLength(self)) - 1)
        end
    end
    if game.player == self and (not self.running) and (not self.resting) and bot.active then
        if not self:enoughEnergy() then
            chan.debug("[PlayerActions] act called with insufficient energy; waiting for the next turn")
            return ...
        end
        if cfg("ACTION_DELAY") == 0 then
            playerActions()
        else
            scheduleAction()
        end
    end
    return ...
end

--- What the bot COUNTS an actor for, and why, in words (#11). Both figures
--- come from data/score.lua's two helpers, the same ones spotHostiles and
--- ownPowerLevel call, so the tooltip and the stop reasons cannot drift.
--- The multiplier is spelled out because since #79 the scaling is a curve, so
--- "at 50% life" no longer means "half".
local function countedPower(actor, raw)
    if actor == game.player then
        local el = lifem.of(actor)
        local f = score.lifeFactor(el.safe_pool, el.safe_max)
        return score.ownPower(raw, el.safe_pool, el.safe_max),
            ("at %s, x%.2f"):format(lifem.describe(el), f)
    end
    local w = power.rankWeight(actor, rankWeights())
    return score.enemyPower(raw, w), ("x%s %s"):format(tostring(w), power.rankBand(actor.rank))
end

--- The Power Level line of a creature's tooltip (#14), added by the
--- "Actor:tooltip" hook to the tstring the engine is building. Two figures
--- since #11: the raw heuristic -- what the Maximum Enemy Power option is
--- written against -- and what the bot COUNTS this actor for.
function bot.tooltip(actor, ts)
    local scores = power.scores(actor, game.player and game.player.global_speed or 1)
    local raw = power.sum(scores)
    local counts, why = countedPower(actor, raw)
    ts:add("#FFD700#Power Level#FFFFFF#: " .. string.format("%d", raw)
        .. " -- counts as " .. string.format("%d", counts) .. " to SkooBot (" .. why .. ")", true)
    if core.key.modState("ctrl") then
        for k, v in pairs(scores) do
            if type(v) ~= "table" then
                ts:add(" #FFD700#" .. k .. "#FFFFFF#: " .. string.format("%1.2f", v), true)
            else
                for k2, v2 in pairs(v) do
                    ts:add(" #FFD700#Weapon " .. k2 .. "#FFFFFF#: " .. string.format("%1.2f", v2), true)
                end
            end
        end
    end
end

-- The superload surface. `loadPrevious(...)` is the loader's chain: each
-- addon's superload of a class gets the previous one's table, so this wraps
-- whatever the original SkooBot wrapped when both are installed, either order.
--
-- ONE wrapper (#76). `postUseTalent` was the second, and only to see a talent
-- that REFUSED -- which is exactly the case its hook does not fire for. But
-- useTalent returns false for it, so SAI_useTalent reads that instead. `act`
-- stays because it has no hook equivalent (docs/api-surface-1.7.6.md).
local old_act = _M.act
function _M:act(...) return afterAct(self, old_act(self, ...)) end

return _M
