-- SkooBot: Reclauded -- the settings screen (#95).
--
-- Copyright (C) 2026 SkoobyDoo
--
-- This program is free software: you can redistribute it and/or modify it
-- under the terms of the GNU General Public License as published by the Free
-- Software Foundation, either version 3 of the License, or (at your option)
-- any later version. See LICENSE.
--
-- ---------------------------------------------------------------------------
--
-- One dialog of the addon's own, reached from the menu, with the game's
-- Options tab reduced to a pointer at it (#95). The tab could hold the
-- numbers; it cannot express what this screen is about -- that a threshold
-- belongs to THIS CHARACTER and a preference to the player.
--
-- Two kinds of row, and the difference is stated on every one:
--
--   * a SAFETY THRESHOLD is the character's, and editing one writes it on the
--     character where the engine saves it. Until then the character uses the
--     default, which is what every existing save does and why none of this
--     needs migrating.
--   * a PREFERENCE -- the delay, the popup, the log level -- is the player's,
--     has one value, and is written to the settings files.
--
-- "Save as default for future characters" copies this character's thresholds
-- onto the account, so the globals can be set FROM a character just tuned
-- rather than in the abstract.
--
-- data/cfg.lua owns which is which, the titles, the descriptions, the ranges
-- and the control kinds; this file draws them. A thirteenth option is added
-- there and nowhere else.

require "engine.class"
require "engine.ui.Dialog"
local List = require "engine.ui.List"
local TextzoneList = require "engine.ui.TextzoneList"
local GetQuantity = require "engine.dialogs.GetQuantity"

local PickOneDialog = require "mod.dialogs.skoobot_reclauded.PickOneDialog"
local cfgfmt = dofile("/data-skoobot_reclauded/cfg.lua")

module(..., package.seeall, class.inherit(engine.ui.Dialog))

-- #46: the log level by name. The number is what is stored, the name is what a
-- player reads, and data/log.lua owns the mapping (`module.name(n)`).
--
-- The literal table is a fallback for a runtime table that has not finished
-- loading, and it cost a scenario failure to get right: it first called 1
-- "warn", which is data/log.lua's 2, so the row label and the stored number
-- disagreed and stepping through the levels skipped one. This copy exists only
-- so a missing module cannot error.
local LOG_LEVELS = { [0] = "off", [1] = "error", [2] = "warn", [3] = "info", [4] = "debug", [5] = "trace" }
local LOG_MAX = 5
local function logName(n)
    local log = skoobot_reclauded.log
    local m = log and log.module
    if m and m.name then
        local ok, name = pcall(m.name, n)
        if ok and name then return name end
    end
    return LOG_LEVELS[tonumber(n) or -1] or tostring(n)
end
local function logMax()
    local log = skoobot_reclauded.log
    local m = log and log.module
    return (m and tonumber(m.MAX)) or LOG_MAX
end

local function fmtValue(name, value)
    if value == nil then return "unset" end
    if cfgfmt.kind(name) == "boolean" then return value and "yes" or "no" end
    if name == "LOG_LEVEL" then return logName(value) end
    local n = tonumber(value)
    if n and n == math.floor(n) then return tostring(math.floor(n)) end
    return tostring(value)
end

--- One row's label: the title, the value in force, and where it came from.
---
--- The source is spelled on every row rather than only on the overridden
--- ones, because "this character" means nothing to a player who has never
--- seen "all characters" beside it.
local function rowName(name)
    local bot = skoobot_reclauded
    local source, value, acct = bot.settingSource(name)
    local title = cfgfmt.title(name)
    if not cfgfmt.PER_CHARACTER[name] then
        return ("#TAN#%s#WHITE#: %s  #GREY#(all characters)#WHITE#"):format(title, fmtValue(name, value))
    end
    if source == "character" then
        return ("#TAN#%s#WHITE#: %s  #LIGHT_GREEN#(this character; default %s)#WHITE#"):format(
            title, fmtValue(name, value), fmtValue(name, acct))
    end
    return ("#TAN#%s#WHITE#: %s  #GREY#(default)#WHITE#"):format(title, fmtValue(name, value))
end

function _M:generateList()
    local list = {}
    for _, name in ipairs(cfgfmt.ORDER) do
        list[#list + 1] = { name = rowName(name), option = name, desc = cfgfmt.DESC[name] }
    end

    list[#list + 1] = {
        name = "#GOLD#Save this character's thresholds as the default for future characters#WHITE#",
        action = "savedefaults",
        desc = "Copies every threshold this character has set of its own onto the account, so the "
            .. "next character you make starts where this one ended up. Thresholds this character "
            .. "never changed are already the default and are left alone. Nothing is copied back "
            .. "to characters that already exist.",
    }
    list[#list + 1] = {
        name = "#GOLD#Clear this character's own thresholds and use the defaults#WHITE#",
        action = "cleardefaults",
        desc = "Forgets every threshold set on this character, so it goes back to the account "
            .. "defaults shown in grey. The defaults themselves are not touched.",
    }
    self.list = list
end

function _M:init()
    self:generateList()
    engine.ui.Dialog.init(self, "SkooBot: Reclauded -- settings", 1, 1)

    local width = 500
    for _, item in ipairs(self.list) do
        local w = self.font:size(tostring(item.name):removeColorCodes())
        if w + 16 > width then width = w + 16 end
    end
    width = math.min(width, math.floor(game.w * 0.9))

    -- The description of whatever is selected, under the list.
    --
    -- TextzoneList, not Textzone: it is the widget with switchItem, the way
    -- ToME's own Birther swaps a description as the selection moves, and it
    -- takes a scrollbar. The scrollbar is not decoration -- a Textzone without
    -- one CLIPS silently (#54).
    self.c_desc = TextzoneList.new{width=width, height=math.max(90, math.floor(game.h * 0.20)),
        scrollbar=true, no_color_bleed=true}

    local maxRows = math.max(6, math.floor((game.h * 0.72 - self.c_desc.h) / 25))
    self.c_list = List.new{width=width, nb_items=math.min(#self.list, maxRows),
        scrollbar=#self.list > maxRows, list=self.list,
        fct=function(item) self:use(item) end,
        select=function(item) self:describe(item) end}

    self:loadUI{
        {left=0, top=0, ui=self.c_list},
        {left=0, top=self.c_list, padding_h=6, ui=self.c_desc},
    }
    self:setupUI(true, true)
    self:describe(self.list[1])

    self.key:addBinds{ EXIT = function() game:unregisterDialog(self) end }
end

function _M:describe(item)
    if not item or not self.c_desc then return end
    self.c_desc:switchItem(item, item.desc or "")
end

--- Redraw in place: a value changed, so every label may have -- saving
--- as defaults moves the grey "(default)" figure on every threshold row.
---
--- List has no setList; the list table is read at generate() time, so the
--- way to rebuild is to swap it and regenerate, then put the selection back
--- where the player left it (generate resets it to the first row).
function _M:refresh()
    local sel = self.c_list and self.c_list.sel or 1
    self:generateList()
    self.c_list.list = self.list
    self.c_list:generate()
    self.c_list.sel = math.min(sel, #self.list)
    self.c_list:onSelect()
    self:describe(self.list[self.c_list.sel])
end

--- Write one option, to the character or to the account depending on which
--- kind it is. One place, so a row cannot be edited into the wrong store.
function _M:write(name, value)
    local bot = skoobot_reclauded
    if cfgfmt.PER_CHARACTER[name] then bot.setCharSetting(name, value)
    else bot.setSetting(name, value) end
    self:refresh()
end

function _M:use(item)
    if not item then return end
    local bot = skoobot_reclauded

    if item.action == "savedefaults" then
        local names = bot.saveAsDefaults()
        if #names == 0 then
            game.log("#GOLD#[SkooBot] This character has no thresholds of its own; the defaults are unchanged.")
        else
            game.log("#GOLD#[SkooBot] Saved as the default for future characters: %s.", table.concat(names, ", "))
        end
        self:refresh()
        return
    end

    if item.action == "cleardefaults" then
        for _, name in ipairs(cfgfmt.ORDER) do
            if cfgfmt.PER_CHARACTER[name] then bot.clearCharSetting(name) end
        end
        game.log("#GOLD#[SkooBot] This character is back on the default thresholds.")
        self:refresh()
        return
    end

    local name = item.option
    if not name then return end
    local kind = cfgfmt.kind(name)
    local _, value = bot.settingSource(name)

    if kind == "boolean" then
        self:write(name, not value)
        return
    end

    if kind == "choice" then      -- LOG_LEVEL
        local choices = {}
        for n = 0, logMax() do choices[#choices + 1] = { name = logName(n), value = n } end
        game:registerDialog(PickOneDialog.new(cfgfmt.title(name) .. " -- how much should it print?",
            choices, function(n) self:write(name, n) end))
        return
    end

    -- A number. GetQuantity's SIXTH argument is the minimum (verified
    -- against engine/dialogs/GetQuantity.lua); passing it fifth sets the
    -- action instead, which is how a range silently becomes 0..1000000.
    local range = cfgfmt.RANGE[name] or { 0, 1000000 }
    local prompt = ("From %s to %s"):format(tostring(range[1]), tostring(range[2]))
    game:registerDialog(GetQuantity.new(cfgfmt.title(name), prompt, tonumber(value) or range[1],
        range[2], function(qty) self:write(name, qty) end, range[1]))
end
