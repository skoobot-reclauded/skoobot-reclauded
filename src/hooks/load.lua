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

-- ---------------------------------------------------------------------------
-- Keybind collisions (#50)
--
-- Detect only, never rebind. Raised from ToME:runDone rather than ToME:run,
-- because that is the first point at which every addon's binds are loaded AND
-- game.log is no longer a no-op; the menu's status line recomputes on every
-- open so a mid-game rebind shows. Mechanics: docs/api-surface-1.7.6.md.
-- ---------------------------------------------------------------------------

local keys = dofile("/data-skoobot_reclauded/keys.lua")

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
-- An engine hook, not an Actor superload: "Actor:tooltip" fires from inside
-- Actor:tooltip with the tstring it is about to return, for every actor the
-- viewer can see -- see docs/api-surface-1.7.6.md. The wording and the figure
-- are bot.tooltip's, beside bot.power, so the tooltip's number and the stop
-- conditions' come from one place.
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
-- #95: a pointer, not a control panel -- the addon's own settings screen holds
-- the options. The row is kept deliberately: a player looking for an addon's
-- settings looks in Options, and one with no presence there is presumed to
-- have none. data/cfg.lua owns everything about an option.
class:bindHook("GameOptions:generateList", function(self, data)
    if data.list.skoobot_reclauded_options then
        local list = data.list
        local keyName = skoobot_reclauded.keyFor and skoobot_reclauded.keyFor("MENU_SKOOBOT_RECLAUDED")
            or "the SkooBot key"
        list[#list + 1] = {
            zone = Textzone.new{width=self.c_desc.w, height=self.c_desc.h,
                text=string.toTString("#GOLD#" .. addonTitle .. "\n\n#WHITE#" ..
                    "This addon keeps its settings on a screen of its own, because they are not " ..
                    "all the same kind of thing: the safety thresholds belong to the character " ..
                    "you are playing -- a level 3 Alchemist and a level 30 Bulwark do not want " ..
                    "the same answer to \"how dangerous is this\" -- while the delay, the stop " ..
                    "popup and the log level are yours and apply to every character.\n\n" ..
                    "Press " .. keyName .. " on the map, then choose #GOLD#Settings#WHITE#. The " ..
                    "same screen can copy a character's thresholds onto the defaults that new " ..
                    "characters start with.#WHITE#")},
            name = string.toTString(("#GOLD##{bold}#[%s] Settings are in the SkooBot menu (%s)#WHITE##{normal}#")
                :format(addonShort, keyName)),
            status = function() return "" end,
            fct = function() end,
        }
    end
end)
