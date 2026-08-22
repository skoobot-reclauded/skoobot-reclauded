-- SkooBot: Reclauded -- pick one action from a list.
--
-- Copyright (C) 2018-2020 SkoobyDoo (SkooBot 0.0.12, overload/mod/dialogs/CustomActionDialog.lua)
-- Copyright (C) 2026 SkoobyDoo
--
-- This program is free software: you can redistribute it and/or modify it
-- under the terms of the GNU General Public License as published by the Free
-- Software Foundation, either version 3 of the License, or (at your option)
-- any later version. See LICENSE.
--
-- PORTED FROM SkooBot 0.0.12 (D-12), under the addon's own dialog namespace.
-- Same content-sized, unscrolled list as PickOneDialog (T-014).

require "engine.class"
require "engine.ui.Dialog"
local List = require "engine.ui.List"

module(..., package.seeall, class.inherit(engine.ui.Dialog))

--- @param optionlist a list of {name=text shown, action=function called when chosen}
function _M:init(title, optionlist)
	self.optionlist = optionlist
	self:generateList()
	print("[SKOOBOT] [CustomActionDialog] init with title " .. title)

	engine.ui.Dialog.init(self, title, 1, 1)

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

function _M:use(item)
	if not item then return end
	game:unregisterDialog(self)

	print("[SKOOBOT] [CustomActionDialog] option selected: " .. tostring(item.name))
	if item.action then item.action() end
end

function _M:generateList()
	local list = self.optionlist
	local chars = {}
	for i, v in ipairs(list) do
		v.name = self:makeKeyChar(i) .. ") " .. v.name
		chars[self:makeKeyChar(i)] = i
	end
	list.chars = chars

	self.list = list
end
