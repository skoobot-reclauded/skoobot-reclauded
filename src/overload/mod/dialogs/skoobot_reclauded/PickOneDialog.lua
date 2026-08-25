-- SkooBot: Reclauded -- pick one option from a list.
--
-- Copyright (C) 2018-2020 SkoobyDoo (SkooBot 0.0.12, overload/mod/dialogs/PickOneDialog.lua)
-- Copyright (C) 2026 SkoobyDoo
--
-- This program is free software: you can redistribute it and/or modify it
-- under the terms of the GNU General Public License as published by the Free
-- Software Foundation, either version 3 of the License, or (at your option)
-- any later version. See LICENSE.
--
-- PORTED FROM SkooBot 0.0.12 (D-12), under the addon's own dialog namespace so
-- it cannot shadow the original's when both addons are enabled. v1's list was
-- content-sized with no scrollbar and ran off the screen (T-014).

require "engine.class"
require "engine.ui.Dialog"
local List = require "engine.ui.List"

module(..., package.seeall, class.inherit(engine.ui.Dialog))

--- @param optionlist a list of {name=text shown, value=passed to action}
--- @param action function(value) called with the chosen value
function _M:init(title, optionlist, action)
	self.optionlist = optionlist
	self.action = action
	self:generateList()
	print("[SKOOBOT] [PickOneDialog] init with title " .. title)

	engine.ui.Dialog.init(self, title, 1, 1)

	-- T-014: bound the visible rows and scroll the rest -- ~80%% of the screen
	-- height, from a safe over-estimate of the row height.
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

	print("[SKOOBOT] [PickOneDialog] option selected: " .. tostring(item.value))
	self.action(item.value)
end

function _M:generateList()
	-- Never mutate the caller's optionlist: prefixing `name` in place made a
	-- shared option table accumulate "a) a) a) ..." across opens (T-016).
	local list = {}
	local chars = {}
	for i, v in ipairs(self.optionlist) do
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
