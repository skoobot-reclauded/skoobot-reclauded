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
-- The dead end a brand new installation hits on its first toggle: a hostile in
-- view and no Combat talent configured. Offers the way out rather than
-- describing it -- six keypresses to a working bot became one (#96,
-- docs/first-run.md section 3).
--
-- It IGNORES STOP_POPUP deliberately: that setting is about noise during play,
-- and this is the one moment a fresh installation cannot start at all. The
-- price is paid on this dialog, which carries its own two ways of silencing it.

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

	-- #109: the wrap width is what sets the dialog's width, and `game.w * 0.6`
	-- alone made it grow with the screen -- at 1440p it wrapped at ~1536px, so
	-- the body ran as two enormous lines and the box was far wider than it
	-- needed to be. Capped at a readable measure, so it is the same size on any
	-- monitor and only narrows on a small one.
	local MEASURE = 520
	local _, w = tostring(text):toTString():splitLines(math.min(game.w * 0.6, MEASURE), self.font)
	local zone = Textzone.new{width=math.min(math.max(w, 360), MEASURE) + 10, auto_height=true, text=text}

	local setup = Button.new{text="Set up talents", fct=function() self:pick("setup") end}
	local later = Button.new{text="Not now",        fct=function() self:pick("later") end}
	local never = Button.new{text="Never ask",      fct=function() self:pick("never") end}

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
