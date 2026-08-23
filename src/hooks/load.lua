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

        local function createNumericalOption(option, tabTitle, desc, minVal, maxVal, prompt)
            minVal = minVal or 0
            maxVal = maxVal or 1000000
            local fct = function(item)
                game:registerDialog(GetQuantity.new(prompt or tabTitle,
                    "From " .. minVal .. " to " .. maxVal, settings[option] or minVal, maxVal,
                    function(qty)
                    settings[option] = qty
                    game:saveSettings("tome.skoobot_reclauded." .. option,
                        ("tome.skoobot_reclauded." .. option .. " = %s\n"):format(tostring(settings[option])))
                    self.c_list:drawItem(item)
                end))
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
        local function createBooleanOption(option, tabTitle, desc)
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

        createNumericalOption("LOWHEALTH_RATIO", "Low Health Ratio",
            "Bot pauses when under this life percent. Also will pause when losing half this " ..
            "percent life in a single round.")
        createNumericalOption("IGNORE_DAMAGE_HEALTH_RATIO", "Ignore Damage Above Life Ratio",
            "While exploring, the bot ignores damage as long as life stays above this fraction, " ..
            "so a single poison tick no longer halts it. Below it, taking damage hands back.")
        createNumericalOption("MAX_INDIVIDUAL_POWER", "Max enemy power level",
            "Pauses the bot when an enemy with a power level over this amount is spotted.")
        createNumericalOption("MAX_DIFF_POWER", "Maximum Individual Enemy Power",
            "Pauses the bot when an enemy with a power level this much higher than yours is spotted.")
        createNumericalOption("MAX_COMBINED_POWER", "Maximum Combined Enemy Power",
            "Pauses the bot when the combined power level of visible enemies is over this amount.")
        createNumericalOption("MAX_ENEMY_COUNT", "Maximum Enemy Count",
            "Pauses the bot when this many enemies is spotted.")
        createNumericalOption("ACTION_DELAY", "Action Delay",
            "Bot will wait this many seconds between each action. THIS IS CURRENTLY A BIT BUGGY " ..
            "AND THE BOT WILL ACT WHEN YOU PRESS BUTTONS OR MOVE YOUR MOUSE IN ADDITION TO " ..
            "AUTOMATICALLY WITH THIS DELAY")
        createBooleanOption("STOP_POPUP", "Popup when the bot stops",
            "Also open a popup with the reason whenever the bot stops for something you should " ..
            "look at: low life, a debuff, being stuck. The message-log line and the banner are " ..
            "always shown. The popup's own checkbox turns this off again.")
    end
end)
