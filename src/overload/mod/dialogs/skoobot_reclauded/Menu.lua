-- SkooBot: Reclauded -- the menu.
--
-- Copyright (C) 2018-2020 SkoobyDoo (SkooBot 0.0.12, overload/mod/dialogs/SkoobotMenu.lua)
-- Copyright (C) 2026 SkoobyDoo
--
-- This program is free software: you can redistribute it and/or modify it
-- under the terms of the GNU General Public License as published by the Free
-- Software Foundation, either version 3 of the License, or (at your option)
-- any later version. See LICENSE.
--
-- PORTED FROM SkooBot 0.0.12 (D-12), under the addon's own dialog namespace.
-- Talks to the bot through the `skoobot_reclauded` runtime table, never
-- through methods on the player class, which both addons would define.

require "engine.class"
require "engine.ui.Dialog"
local List = require "engine.ui.List"
local Textzone = require "engine.ui.Textzone"

local PickOneDialog = require "mod.dialogs.skoobot_reclauded.PickOneDialog"
local keys = dofile("/data-skoobot_reclauded/keys.lua")

module(..., package.seeall, class.inherit(engine.ui.Dialog))

-- #54: what a player who has never read anything sees first. A text zone, not
-- list rows, so the choices keep their letters and the keybind status rows
-- stay where the harness expects them. Keys are looked up live (#57).
local function helpText()
	local bot = skoobot_reclauded
	local function k(virtual)
		return "#LIGHT_BLUE#" .. (bot.keyFor and bot.keyFor(virtual) or "?") .. "#WHITE#"
	end
	return "#GOLD#How to start:#WHITE# a) put the talents the bot may use in its sections "
		.. "(or let its first row suggest a loadout), then press " .. k("TOGGLE_SKOOBOT_RECLAUDED")
		.. " on the map. It rests, explores and fights, and hands back with a #{bold}#[SkooBot]#{normal}# "
		.. "line saying why.\n"
		.. "#GOLD#Keys:#WHITE# " .. k("TOGGLE_SKOOBOT_RECLAUDED") .. " start or stop, "
		.. k("STOP_SKOOBOT_RECLAUDED") .. " stop, "
		.. k("RUNONCE_SKOOBOT_RECLAUDED") .. " one action, "
		.. k("ASK_SKOOBOT_RECLAUDED") .. " say what it would do next, "
		.. k("MENU_SKOOBOT_RECLAUDED") .. " this menu. Change them under Escape > Key Bindings; "
		.. "the thresholds and the rest are under #GOLD#Settings#WHITE# above."
end

function _M:init()
	self:generateList()
	engine.ui.Dialog.init(self, "SkooBot: Reclauded", 1, 1)

	-- #50: a collision row names two actions and a key, which can run past
	-- the 400 the action rows fit in; widen to the longest row, within the
	-- screen, rather than let List clip it.
	local width = 400
	for _, item in ipairs(self.list) do
		local w = self.font:size(tostring(item.name):removeColorCodes())
		if w + 16 > width then width = w + 16 end
	end
	width = math.min(width, math.floor(game.w * 0.9))

	-- #54: the help paragraph, wrapped to the list's width.
	local help = Textzone.new{width=width, auto_height=true, text=helpText()}

	-- T-014: bound the visible rows and scroll the rest. Rows are sized to ~80%%
	-- of the screen height less the help text, from a safe over-estimate of the
	-- row height, so the dialog never exceeds the screen whatever the font.
	local maxRows = math.max(6, math.floor((game.h * 0.8 - help.h) / 25))
	local list = List.new{width=width, nb_items=math.min(#self.list, maxRows),
		scrollbar=#self.list > maxRows, list=self.list, fct=function(item) self:use(item) end}

	self:loadUI{
		{left=0, top=0, ui=list},
		{left=0, top=list, padding_h=6, ui=help},
	}
	self:setupUI(true, true)

	self.key:addCommands{
		__TEXTINPUT = function(c)
			if self.list and self.list.chars[c] then self:use(self.list[self.list.chars[c]]) end
		end,
	}
	self.key:addBinds{ EXIT = function() game:unregisterDialog(self) end, }
end

function _M:on_register()
	game:onTickEnd(function() self.key:unicodeInput(true) end)
end

local menuActions = {
	settings = function()
		print("[SKOOBOT] [Menu] settings menu action chosen.")
		local d = require("mod.dialogs.skoobot_reclauded.SettingsDialog").new()
		game:registerDialog(d)
	end,
	skillconfig = function()
		print("[SKOOBOT] [Menu] skillconfig menu action chosen.")
		local d = require("mod.dialogs.skoobot_reclauded.TalentDialog").new(game.player)
		game:registerDialog(d)
	end,
	botstopconditions = function()
		print("[SKOOBOT] [Menu] botstopconditions menu action chosen.")

		local conditions = skoobot_reclauded.conditions
		local dialoglist = {}
		for _, v in ipairs(conditions.list()) do
			dialoglist[#dialoglist + 1] = {name=v.label .. " - " .. v.stoptype, value=v.code}
		end

		-- The semantics are checkStop's (Player superload): WARN stops once and is
		-- remembered until the condition clears, STOP stops on every decision it
		-- holds for, IGNORE never stops.
		local d = PickOneDialog.new("Stop conditions: pick one to change", dialoglist,
			function(code)
				local cond = conditions.get(code)
				local d2 = PickOneDialog.new((cond and cond.label or code) .. " -- what should the bot do?",
					{
						{name="IGNORE -- never stop for this", value="IGNORE"},
						{name="WARN -- stop once, then carry on if restarted", value="WARN"},
						{name="STOP -- stop every time it applies", value="STOP"},
					},
					function(stoptype)
						conditions.set(code, stoptype)
					end
				)
				game:registerDialog(d2)
			end
		)
		game:registerDialog(d)
	end,
}

function _M:use(item)
	-- A status row (#50) is information, not a choice: selecting it does nothing
	-- and the menu stays open.
	if not item or item.info then return end
	game:unregisterDialog(self)
	print("[SKOOBOT] [Menu] option chosen: '" .. item.name .. "' with order code: " .. item.order)

	if menuActions[item.order] then menuActions[item.order]() end
end

-- #50: the keybind status, recomputed on every open so a mid-game rebind
-- shows. The check lives on the runtime table (hooks/load.lua).
local OK_COLOUR        = {160, 160, 160}
local COLLISION_COLOUR = {255, 153, 0}

local function keybindRows()
	local kb = skoobot_reclauded.keybinds
	if not kb then return {} end
	local list = kb.collisions()
	local colour = #list == 0 and OK_COLOUR or COLLISION_COLOUR
	local rows = { {info=true, name=keys.summary(#list), color=colour} }
	for _, c in ipairs(list) do
		rows[#rows + 1] = {info=true, name=c.text, color=colour}
	end
	return rows
end

function _M:generateList()
	-- #73: named by what they do, not v1's "Set Skill Usage" and
	-- "Activate/Deactivate Bot Stop Conditions". Scenarios assert these names
	-- verbatim, so they move with them.
	local raw = {
		{1,   name="Talent rules -- which talents the bot may use", order="skillconfig"},
		{2,   name="Stop conditions -- when it hands back",         order="botstopconditions"},
		-- #95: the third place configuration used to live -- the game's
		-- Options tab -- is now a pointer at this row, so there is one
		-- answer to "where are the settings".
		{3,   name="Settings -- thresholds, delay, popup, logging",  order="settings"},
		{999, name="Cancel",                                        order="donothing"},
	}
	-- The status rows go last, so the choices keep their letters and their
	-- positions whatever the keybind state.
	for _, row in ipairs(keybindRows()) do raw[#raw + 1] = row end

	-- Build a fresh display list rather than prefixing `raw` in place: the same
	-- non-mutating shape as the other two dialogs, one correct pattern
	-- (PickOneDialog, T-016).
	local list = {}
	local chars = {}
	local choices = 0
	for i, v in ipairs(raw) do
		local item = {}
		for k, val in pairs(v) do item[k] = val end
		if v.info then
			item.name = "   " .. v.name
		else
			choices = choices + 1
			local ch = self:makeKeyChar(choices)
			item.name = ch .. ") " .. v.name
			chars[ch] = i
		end
		list[i] = item
	end
	list.chars = chars

	self.list = list
end
