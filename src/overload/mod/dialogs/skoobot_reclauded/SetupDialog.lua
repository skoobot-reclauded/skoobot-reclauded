-- SkooBot: Reclauded -- "there is nothing configured; shall we?" (#96).
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
-- The dead end a brand new installation hits on its first toggle: a hostile
-- in view and no Combat talent configured. #71 made the message say which
-- case it is; this offers the way out instead of describing it. The
-- first-run audit measured the path from that message to a working bot at
-- six keypresses (docs/first-run.md section 3); the first button makes it
-- one.
--
-- WHY IT IGNORES THE STOP_POPUP SETTING, which is off by default. That
-- setting answers "do you want a dialog every time the bot stops" -- a
-- preference about noise during play. This is not that: it is the moment a
-- fresh installation cannot start at all, on a run where the player has
-- almost certainly never seen the setting. A popup nobody can reach on the
-- one occasion it would help is not a popup.
--
-- The price is one dialog that ignores a preference, and it is paid for
-- twice over on this dialog itself: "Not now" silences it for the session,
-- "Don't ask again" silences it for this character for good. Both are
-- one keypress, and neither sends the player anywhere to find a setting.

require "engine.class"
require "engine.ui.Dialog"
local Textzone = require "engine.ui.Textzone"
local Button = require "engine.ui.Button"

module(..., package.seeall, class.inherit(engine.ui.Dialog))

--- @param text     the body, colour codes allowed
--- @param on_pick  function(choice) with "setup", "later" or "never"
function _M:init(text, on_pick)
	self.on_pick = on_pick
	engine.ui.Dialog.init(self, "SkooBot: Reclauded", 1, 1)

	local _, w = tostring(text):toTString():splitLines(game.w * 0.6, self.font)
	local zone = Textzone.new{width=math.max(w, 360) + 10, auto_height=true, text=text}

	local setup = Button.new{text="Set up talents", fct=function() self:pick("setup") end}
	local later = Button.new{text="Not now",        fct=function() self:pick("later") end}
	local never = Button.new{text="Don't ask again", fct=function() self:pick("never") end}

	self:loadUI{
		{left=3, top=3, ui=zone},
		{left=3, bottom=3, ui=setup},
		{hcenter=0, bottom=3, ui=later},
		{right=3, bottom=3, ui=never},
	}
	-- The recommended action has focus, so Enter takes it. Escape is "not
	-- now", never "never": a dialog that turns itself off when dismissed is
	-- a dialog that turns itself off by accident.
	self:setFocus(setup)
	self:setupUI(true, true)

	self.key:addBinds{ EXIT = function() self:pick("later") end }
end

function _M:pick(choice)
	if self.closed then return end
	self.closed = true
	game:unregisterDialog(self)
	if self.on_pick then self.on_pick(choice) end
end
