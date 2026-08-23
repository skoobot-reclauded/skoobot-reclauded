-- SkooBot: Reclauded -- the "why did it stop" popup.
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
-- #58. Shown for a STOPPED notice only, and only while the STOP_POPUP setting
-- is on -- off by default, because the owner does not like dialogs and the
-- log line plus the big-news banner carry the stop on their own. The checkbox
-- turns the popup off from here, so nobody has to go looking for the option
-- to be rid of it; the option stays in the SkooBot: Reclauded tab so it can
-- be turned on again, the way the game's own quest popup is toggled
-- (tome.quest_popup).
--
-- Dialog:simplePopup (engine/ui/Dialog.lua:110) has no checkbox slot, hence
-- a small dialog of its own with the same layout plus a Checkbox between the
-- text and the button. Keyboard: Enter closes (the button has focus), Escape
-- closes, Tab reaches the checkbox and Space ticks it.

require "engine.class"
require "engine.ui.Dialog"
local Textzone = require "engine.ui.Textzone"
local Checkbox = require "engine.ui.Checkbox"
local Button = require "engine.ui.Button"

module(..., package.seeall, class.inherit(engine.ui.Dialog))

--- @param text      the body, may carry colour codes (data/notice.lua's `popup`)
--- @param on_close  function(suppress) called once when the dialog closes;
---                  `suppress` is true when the player ticked the checkbox
function _M:init(text, on_close)
	self.on_close = on_close
	self.suppress = false
	engine.ui.Dialog.init(self, "SkooBot: Reclauded", 1, 1)

	local _, w = tostring(text):toTString():splitLines(game.w * 0.6, self.font)
	local zone = Textzone.new{width=math.max(w, 320) + 10, auto_height=true, text=text}
	local box = Checkbox.new{title="Don't show this popup again", default=false,
		fct=function() self:close() end,
		on_change=function(checked) self.suppress = checked end}
	local close = Button.new{text="Close", fct=function() self:close() end}

	self:loadUI{
		{left=3, top=3, ui=zone},
		{left=3, top=zone, ui=box},
		{hcenter=0, bottom=3, ui=close},
	}
	self:setFocus(close)
	self:setupUI(true, true)

	self.key:addBinds{ EXIT = function() self:close() end }
end

function _M:close()
	if self.closed then return end
	self.closed = true
	game:unregisterDialog(self)
	if self.on_close then self.on_close(self.suppress) end
end
