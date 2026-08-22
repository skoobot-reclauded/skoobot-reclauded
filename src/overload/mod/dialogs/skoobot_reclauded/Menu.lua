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
-- Talks to the bot through the `skoobot_reclauded` runtime table rather than
-- through methods on the player class, which the original and this addon
-- would otherwise both define.

require "engine.class"
require "engine.ui.Dialog"
local List = require "engine.ui.List"

local PickOneDialog = require "mod.dialogs.skoobot_reclauded.PickOneDialog"

module(..., package.seeall, class.inherit(engine.ui.Dialog))

function _M:init()
	self:generateList()
	engine.ui.Dialog.init(self, "SkooBot: Reclauded", 1, 1)

	-- T-014: bound the visible rows and scroll the rest, so a character with many
	-- talents can still reach the first and last entries. The original gave the
	-- list one row per entry with no scrollbar, so on a short screen (1366x768 was
	-- the report) the ends fell off. Rows are sized to ~80%% of the screen height
	-- from a safe over-estimate of the row height, so the dialog never exceeds the
	-- screen whatever the font; the full list stays reachable by wheel and arrows.
	local maxRows = math.max(6, math.floor(game.h * 0.8 / 25))
	local list = List.new{width=400, nb_items=math.min(#self.list, maxRows),
		scrollbar=#self.list > maxRows, list=self.list, fct=function(item) self:use(item) end}

	self:loadUI{
		{left=0, top=0, ui=list},
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

		local d = PickOneDialog.new("Pick a condition to customize", dialoglist,
			function(code)
				local d2 = PickOneDialog.new("Pick a stop condition for: " .. code,
					{{name="IGNORE", value="IGNORE"}, {name="WARN", value="WARN"}, {name="STOP", value="STOP"}},
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
	if not item then return end
	game:unregisterDialog(self)
	print("[SKOOBOT] [Menu] option chosen: '" .. item.name .. "' with order code: " .. item.order)

	if menuActions[item.order] then menuActions[item.order]() end
end

function _M:generateList()
	local raw = {
		{1,   name="Set Skill Usage",                           order="skillconfig"},
		{2,   name="Activate/Deactivate Bot Stop Conditions",  order="botstopconditions"},
		{999, name="Cancel",                                    order="donothing"},
	}

	-- Build a fresh display list rather than prefixing `raw` in place. This
	-- menu builds its own list each open so it never accumulated, but the same
	-- non-mutating shape as the other two dialogs keeps one correct pattern
	-- (see PickOneDialog, T-016).
	local list = {}
	local chars = {}
	for i, v in ipairs(raw) do
		local ch = self:makeKeyChar(i)
		local item = {}
		for k, val in pairs(v) do item[k] = val end
		item.name = ch .. ") " .. v.name
		list[i] = item
		chars[ch] = i
	end
	list.chars = chars

	self.list = list
end
