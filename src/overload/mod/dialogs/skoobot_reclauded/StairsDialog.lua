-- SkooBot: Reclauded -- "the level is done; shall I take these?" (#86).
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
-- The engine's own auto-explore already walks the character to the down stairs
-- once a level is finished (#121), so the only thing missing was the asking.
-- This is the asking: offer the way on rather than describing it, the way
-- SetupDialog does for the empty-Combat dead end (#96).
--
-- Each button is one of TAKE_STAIRS's settings, so answering here IS setting
-- the option -- "always" and "never" write it and the offer stops appearing.

require "engine.class"
require "engine.ui.Dialog"
local Textzone = require "engine.ui.Textzone"
local Button = require "engine.ui.Button"

module(..., package.seeall, class.inherit(engine.ui.Dialog))

--- @param text     the body, colour codes allowed
--- @param on_pick  function(choice) with "take", "always", "later" or "never"
function _M:init(text, on_pick)
	self.on_pick = on_pick
	engine.ui.Dialog.init(self, "SkooBot: Reclauded", 1, 1)

	-- #109's measure: the wrap width sets the dialog's width, so cap it or the
	-- box grows with the monitor and the body runs as two enormous lines.
	local MEASURE = 520
	local _, w = tostring(text):toTString():splitLines(math.min(game.w * 0.6, MEASURE), self.font)
	local zone = Textzone.new{width=math.min(math.max(w, 360), MEASURE) + 10, auto_height=true, text=text}

	local take   = Button.new{text="Take them",  fct=function() self:pick("take") end}
	local always = Button.new{text="Always",     fct=function() self:pick("always") end}
	local later  = Button.new{text="Not now",    fct=function() self:pick("later") end}
	local never  = Button.new{text="Never ask",  fct=function() self:pick("never") end}

	self:loadUI{
		{left=3, top=3, ui=zone},
		{left=3, bottom=3, ui=take},
		{left=3 + take.w + 6, bottom=3, ui=always},
		{hcenter=0, bottom=3, ui=later},
		{right=3, bottom=3, ui=never},
	}
	-- The recommended action has focus, so Enter takes it. Escape is "not
	-- now", never "never": a dialog that turns itself off when dismissed is a
	-- dialog that turns itself off by accident (SetupDialog's rule).
	self:setFocus(take)
	self:setupUI(true, true)

	self.key:addBinds{ EXIT = function() self:pick("later") end }
end

function _M:pick(choice)
	if self.closed then return end
	self.closed = true
	game:unregisterDialog(self)
	if self.on_pick then self.on_pick(choice) end
end
