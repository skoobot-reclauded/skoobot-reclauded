-- SkooBot: Reclauded -- keybinds, settings and the options tab.
--
-- Copyright (C) 2018-2020 SkoobyDoo (SkooBot 0.0.12, hooks/load.lua)
-- Copyright (C) 2026 SkoobyDoo
--
-- This program is free software: you can redistribute it and/or modify it
-- under the terms of the GNU General Public License as published by the Free
-- Software Foundation, either version 3 of the License, or (at your option)
-- any later version. See LICENSE.
--
-- ---------------------------------------------------------------------------
--
-- PORTED FROM SkooBot 0.0.12 (D-12). The bot itself lives in the Player
-- superload and exposes the `skoobot_reclauded` runtime table; this file only
-- wires keys and options to it. Every name here is distinct from the
-- original's so the two addons can be enabled together: action types,
-- the keybind file, the settings namespace and the options tab.

local class = require "engine.class"
local Textzone = require "engine.ui.Textzone"
local KeyBind = require "engine.KeyBind"
local GetQuantity = require "engine.dialogs.GetQuantity"

-- ---------------------------------------------------------------------------
-- Keybind collisions (#50)
--
-- Another addon, or the player's own remap, can put a second action on one of
-- this addon's keys. The engine then fires whichever of the two pairs()
-- yields first (engine/KeyBind.lua:228-233) and says nothing. This detects
-- that state and tells the player; it never rebinds anything.
--
-- Where the check can run is decided by three engine facts, found in the
-- 1.7.6 source rather than assumed:
--   * every addon's defineAction lands in the one class-level table,
--     KeyBind.binds_def, and every remap in KeyBind.binds_remap -- so the
--     check reads those two, never game.key.binds, which is built once in
--     Game:init/loaded and is stale until UserChat's bindKeys() after run();
--   * ToME:run hooks fire in addon weight order, so an addon that loads its
--     keybinds in its own ToME:run hook -- the original SkooBot does, at the
--     same weight as this one -- may not have done so when ours runs. All
--     of them have by ToME:runDone;
--   * game.log is a no-op (engine/Game.lua:56) until uiset:activate() inside
--     runReal, so a message-log line from ToME:run is silently dropped.
-- Hence the notice is raised from ToME:runDone, and the menu's status line
-- recomputes on every open, so a rebind made mid-game shows at once.
-- ---------------------------------------------------------------------------

local keys = dofile("/data-skoobot_reclauded/keys.lua")
local cfgfmt = dofile("/data-skoobot_reclauded/cfg.lua")

-- This addon's actions, in the keybind file's order: the order collisions
-- are reported in.
local ACTIONS = {
    "TOGGLE_SKOOBOT_RECLAUDED", "STOP_SKOOBOT_RECLAUDED", "RUNONCE_SKOOBOT_RECLAUDED",
    "ASK_SKOOBOT_RECLAUDED", "MENU_SKOOBOT_RECLAUDED",
}

-- A key string as the player reads it, rendered the way keyFor() does (#57).
local function describeKey(ks)
    local function symname(sym)
        local code = tonumber(sym) or KeyBind[sym]
        if not code or not core.key.symName then return nil end
        return core.key.symName(code)
    end
    return keys.describe(ks, symname)
        or (game.key and game.key:formatKeyString(ks))
        or tostring(ks)
end

local function actionName(t)
    local def = KeyBind.binds_def[t]
    return def and def.name or t
end

--- Every collision between one of this addon's actions and another bound
--- action, as of now. Each entry is keys.collisions()'s {type, keystring,
--- others} plus `key` (rendered) and `text` (the one-line wording).
local function keyCollisions()
    local list = keys.collisions(KeyBind.binds_def, KeyBind.binds_remap, ACTIONS)
    for _, c in ipairs(list) do
        c.key = describeKey(c.keystring)
        c.text = keys.collisionText(c, c.key, actionName)
    end
    return list
end

--- Announce each collision once per game session: one [SKOOBOT] line in the
--- engine log and one line in the message log. Returns how many were new.
local announced = {}
local function keyCollisionNotice()
    local fresh = 0
    for _, c in ipairs(keyCollisions()) do
        local sig = c.type .. "|" .. c.keystring .. "|" .. table.concat(c.others, ",")
        if not announced[sig] then
            announced[sig] = true
            fresh = fresh + 1
            print("[SKOOBOT] [Keybinds] collision: " .. c.text
                .. " (" .. c.type .. " and " .. table.concat(c.others, ", ") .. ")")
            -- As an argument, never as the format string: an action name may
            -- carry a '%'.
            game.log("%s", "#ORANGE##{bold}#" .. skoobot_reclauded.notice.PREFIX .. "#{normal}# " .. c.text
                .. " -- only one of them will answer that key. Change either under Escape > Key Bindings.")
        end
    end
    return fresh
end

class:bindHook("ToME:run", function()
    KeyBind:load("skoobot-reclauded")
    game.key:addBinds {
        TOGGLE_SKOOBOT_RECLAUDED = function()
            game.log("#GOLD#SkooBot: Reclauded toggle requested!")
            skoobot_reclauded.start()
        end,
        STOP_SKOOBOT_RECLAUDED = function()
            if skoobot_reclauded.active then
                game.log("#GOLD#SkooBot: Reclauded stop requested!")
                -- The player pressed the key: no banner for what they just did (#58).
                skoobot_reclauded.stop("stopped by the player", skoobot_reclauded.notice.HANDED_BACK,
                    { banner = false })
            end
        end,
        RUNONCE_SKOOBOT_RECLAUDED = function()
            game.log("#GOLD#SkooBot: Reclauded single run requested!")
            skoobot_reclauded.runonce()
        end,
        ASK_SKOOBOT_RECLAUDED = function()
            game.log("#GOLD#SkooBot: Reclauded query requested!")
            skoobot_reclauded.query()
        end,
        MENU_SKOOBOT_RECLAUDED = function()
            local d = require("mod.dialogs.skoobot_reclauded.Menu").new()
            game.log("#GOLD#SkooBot: Reclauded menu requested!")
            game:registerDialog(d)
        end,
    }
    -- #57: name the keys that are bound, not the defaults.
    local bot = skoobot_reclauded
    print("[SKOOBOT] ready; " .. bot.keyFor("TOGGLE_SKOOBOT_RECLAUDED") .. " toggles, "
        .. bot.keyFor("MENU_SKOOBOT_RECLAUDED") .. " opens the menu")

    -- #50: the menu and the harness read collisions through the runtime
    -- table. rawset, because .luacheckrc declares `skoobot_reclauded`
    -- read-only so its name can never be rebound; the table itself has no
    -- metatable, so this is an ordinary field write.
    rawset(bot, "keybinds", { collisions = keyCollisions, notice = keyCollisionNotice })
end)

-- After every addon's ToME:run hook and after uiset:activate(): the bind
-- tables are complete and the message log is live (see the note above).

class:bindHook("ToME:runDone", function()
    local list = keyCollisions()
    print(("[SKOOBOT] [Keybinds] checked %d actions: %s"):format(#ACTIONS,
        #list == 0 and "no collisions" or (#list .. " collision(s)")))
    keyCollisionNotice()
    -- #72. After the collision notice: a collision is a problem and goes
    -- first; this is an introduction and can follow it.
    skoobot_reclauded.greet()
end)

-- ---------------------------------------------------------------------------
-- The power level in every creature's tooltip (#14)
--
-- 0.1 superloaded mod.class.Actor for this one line. It never needed to: the
-- engine fires "Actor:tooltip" from inside Actor:tooltip with the very
-- tstring it is about to return (mod/class/Actor.lua:2133) -- after the
-- stats block, before the weapons and the effects -- for every actor,
-- the player included (Player:tooltip reaches Actor.tooltip by explicit
-- class reference, mod/class/Player.lua:442), and not at all for an actor
-- the viewer cannot see, which is exactly when the wrapper returned nil.
-- The line's wording and figure are the runtime table's (bot.tooltip, kept
-- beside bot.power in the Player superload), so the number the tooltip
-- shows and the one the stop conditions compare live in one file.
-- ---------------------------------------------------------------------------
class:bindHook("Actor:tooltip", function(self, data)
    skoobot_reclauded.tooltip(self, data.ts)
end)

dofile("/data-skoobot_reclauded/settings.lua")

-- tab=function
class:bindHook("GameOptions:tabs", function(self, data)
    if not self.skoobot_reclauded_optioninit then
        self.skoobot_reclauded_optioninit = true
        data.tab("[SkooBot: Reclauded]", function() self.list = { skoobot_reclauded_options = true } end)
    end
end)

local addonTitle = "SkooBot: Reclauded"
local addonShort = "Reclauded"
-- list=self.list, kind=kind
class:bindHook("GameOptions:generateList", function(self, data)
    if data.list.skoobot_reclauded_options then
        local list = data.list
        local settings = config.settings.tome.skoobot_reclauded

        -- A numerical option. `minVal`/`maxVal` are the range the dialog
        -- clamps typed input to AND the range its prompt states; every entry
        -- opened with "From 0 to 1000000" before #74, which for the two life
        -- fractions was actively misleading -- a player typing 50 for "50%"
        -- got a threshold of fifty times maximum life, and the bot then
        -- stopped at the first enemy.
        --
        -- The minimum is GetQuantity's SIXTH argument (engine/dialogs/
        -- GetQuantity.lua: init(title, prompt, default, max, action, min)),
        -- which is easy to miss after the callback and was simply never
        -- passed, so no minimum was enforced either. Numberbox bounds on
        -- edit (util.bound in updateText), so a value already saved outside
        -- the range survives until the player types in the box -- which is
        -- right: this changes what can be entered, never what is stored.
        -- Decimals are accepted (Numberbox takes '.'), so a fraction can be
        -- typed into a 0-to-1 range.
        -- #71: the title comes from data/cfg.lua, the same table the stop
        -- reasons quote, so the tab and the reasons cannot name one knob two
        -- ways. It used to be a literal here.
        local function createNumericalOption(option, desc, minVal, maxVal, prompt)
            local tabTitle = cfgfmt.title(option)
            minVal = minVal or 0
            maxVal = maxVal or 1000000
            local fct = function(item)
                game:registerDialog(GetQuantity.new(prompt or tabTitle,
                    "From " .. minVal .. " to " .. maxVal, settings[option] or minVal, maxVal,
                    function(qty)
                    -- #90: through setSetting, so the tab and the runtime
                    -- write the same file format. This used to build the
                    -- line itself, and the line it built could not be
                    -- loaded back.
                    skoobot_reclauded.setSetting(option, qty)
                    self.c_list:drawItem(item)
                end, minVal))
            end
            local status = function()
                return tostring(settings[option] or "-")
            end

            list[#list + 1] = {
                zone = Textzone.new{width=self.c_desc.w, height=self.c_desc.h,
                    text=string.toTString("#GOLD#" .. addonTitle .. "\n\n#WHITE#" .. desc .. "#WHITE#")},
                name = string.toTString(("#GOLD##{bold}#[%s] %s#WHITE##{normal}#"):format(addonShort, tabTitle)),
                status = status, fct = fct,
            }
        end

        -- An on/off option, toggled by selecting it, the way the game's own
        -- "quest popup" option works (mod/dialogs/GameOptions.lua). Persisted
        -- through the runtime table so the stop popup's checkbox writes the
        -- same value the same way (#58).
        local function createBooleanOption(option, desc)
            local tabTitle = cfgfmt.title(option)
            local fct = function(item)
                skoobot_reclauded.setSetting(option, not settings[option])
                self.c_list:drawItem(item)
            end
            local status = function()
                return settings[option] and "enabled" or "disabled"
            end

            list[#list + 1] = {
                zone = Textzone.new{width=self.c_desc.w, height=self.c_desc.h,
                    text=string.toTString("#GOLD#" .. addonTitle .. "\n\n#WHITE#" .. desc .. "#WHITE#")},
                name = string.toTString(("#GOLD##{bold}#[%s] %s#WHITE##{normal}#"):format(addonShort, tabTitle)),
                status = status, fct = fct,
            }
        end

        -- #54: every entry says what the number is (a fraction of maximum
        -- life, a power level, a count, seconds) and what happens at it, in
        -- the words the stop notices use, so the tab reads on its own. The
        -- setting keys are the save's and the harness's and do not change.
        createNumericalOption("LOWHEALTH_RATIO",
            "A fraction of your life pool (0.5 is half) -- your maximum life, plus whatever " ..
            "keeps you alive below zero, which is what the game itself measures. While " ..
            "enemies are in view, the bot " ..
            "stops when life is below it. The other life thresholds follow from it: losing half " ..
            "of this fraction in one turn is the Big Loss stop; in a fight, losing a quarter of " ..
            "it in one turn uses a Damage Prevention talent, and missing a quarter of it uses a " ..
            "Recovery talent.", 0, 1)
        createNumericalOption("IGNORE_DAMAGE_HEALTH_RATIO",
            "A fraction of your life pool (0.9 is nine tenths); see Low Health Ratio for what " ..
            "the pool is. While exploring with nothing " ..
            "in view, damage is ignored as long as life stays above it, so a single poison tick " ..
            "does not stop the bot; once life is below it, any damage taken while exploring hands " ..
            "back. It is also the scale that stop is measured on: life exactly at this ratio is " ..
            "threat 1, and twice as far below it is threat 2. See Maximum Enemy Power.", 0, 1)
        -- #82: since #11 these five are not independent switches -- each is
        -- the denominator of one term of the threat score, and the score is
        -- the largest term (data/score.lua). Every power stop already ends
        -- " -- threat N"; the tab has to say what N is measured against or
        -- the number is noise. Explained once here, referred to from the
        -- other four, the way "Power level: see Maximum Enemy Power" already
        -- works.
        createNumericalOption("MAX_INDIVIDUAL_POWER",
            "Stop when any enemy in view has a power level above this figure, whatever yours is. " ..
            "Power level is the addon's rough threat score for a creature -- its life, damage, " ..
            "crits, speed, defence, stats and weapons summed -- and is shown as \"Power Level\" " ..
            "in every creature's tooltip; hold Ctrl over a creature to see the parts.\n\n" ..
            "These five limits are also a scale: every stop for one of them ends \"-- threat N\", " ..
            "where the limit you set counts as 1, so threat 3 is three times past it. The stop " ..
            "says how far over the room is, not only that it is.")
        createNumericalOption("MAX_DIFF_POWER",
            "Stop when any enemy in view has a power level more than this much above your own. " ..
            "Your own power level is scaled by the life you have left, so the same enemy stops " ..
            "the bot sooner when you are hurt. On the threat scale, 1 is an enemy exactly this " ..
            "far above you. Power level and the threat figure: see Maximum Enemy Power.")
        createNumericalOption("MAX_COMBINED_POWER",
            "Stop when the power levels of every enemy in view, added together, are more than " ..
            "this much above your own (again scaled by the life you have left). A margin above " ..
            "yours, not an absolute figure. On the threat scale, 1 is a room exactly this far " ..
            "above you. Power level and the threat figure: see Maximum Enemy Power.")
        createNumericalOption("MAX_ENEMY_COUNT",
            "Stop when more than this many enemies are in view at once, whatever their power. On " ..
            "the threat scale, 1 is exactly this many in view -- twelve of them against a limit " ..
            "of twelve. The threat figure: see Maximum Enemy Power.")
        -- #62: the rank weights. One entry per band; data/power.lua says
        -- which ToME rank falls in which band.
        createNumericalOption("NORMAL_POWER_RATIO",
            "Critters and normal-rank enemies count for this multiple of their power level in " ..
            "the three power checks above: 0.4 means a common counts for less than half, so a " ..
            "pack of them does not read as a threat; 1 is face value.", 0, 10)
        createNumericalOption("ELITES_POWER_RATIO",
            "Elite, rare and unique enemies count for this multiple of their power level in the " ..
            "three power checks above: 1 is face value; 2 would count each as double.", 0, 10)
        createNumericalOption("BOSS_POWER_RATIO",
            "Bosses, elite bosses and anything stronger count for this multiple of their power " ..
            "level in the three power checks above: 2 counts each as double; 1 is face value.", 0, 10)
        createNumericalOption("ACTION_DELAY",
            "Seconds the bot waits between its actions, so you can watch what it does. 0 acts " ..
            "at full speed. Known to be rough: with a delay set, the bot also takes its next " ..
            "action when you press a key or move the mouse.")
        createBooleanOption("STOP_POPUP",
            "Also open a popup with the reason whenever the bot stops for something you should " ..
            "look at: low life, a debuff, being stuck. The message-log line and the banner are " ..
            "always shown. The popup's own checkbox turns this off again.")

        -- #46: the log level, cycled by name. Selecting the entry steps to
        -- the next level and wraps; the number is what is persisted (see
        -- data/settings.lua) and the running channel is switched at once,
        -- so the next decision logs at the new level without a restart.
        do
            local logm = skoobot_reclauded.log
            local function levelName()
                local n = tonumber(settings.LOG_LEVEL)
                return (n and logm.module.name(n)) or logm.getLevel()
            end
            local fct = function(item)
                local n = tonumber(settings.LOG_LEVEL) or logm.getLevelNumber()
                n = (n + 1) % (logm.module.MAX + 1)
                skoobot_reclauded.setSetting("LOG_LEVEL", n)
                logm.setLevel(n)
                self.c_list:drawItem(item)
            end
            list[#list + 1] = {
                zone = Textzone.new{width=self.c_desc.w, height=self.c_desc.h,
                    text=string.toTString("#GOLD#" .. addonTitle .. "\n\n#WHITE#" ..
                        "How much the bot writes to the game's log file (te4_log.txt) about what it " ..
                        "is doing. Select to step through the levels: off, error, warn, info, debug, " ..
                        "trace. 'info' is the default: one line per action and per stop, which is " ..
                        "what a bug report wants. 'debug' adds its reasoning on every decision and " ..
                        "'trace' the talent-by-talent checks; both grow the file quickly. Warnings " ..
                        "and errors are also shown in the message log.#WHITE#")},
                name = string.toTString(("#GOLD##{bold}#[%s] %s#WHITE##{normal}#")
                    :format(addonShort, cfgfmt.title("LOG_LEVEL"))),
                status = levelName, fct = fct,
            }
        end
    end
end)
