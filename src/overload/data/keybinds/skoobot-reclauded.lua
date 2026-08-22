-- SkooBot: Reclauded -- key bindings.
--
-- Copyright (C) 2026 SkoobyDoo
--
-- This program is free software: you can redistribute it and/or modify it
-- under the terms of the GNU General Public License as published by the Free
-- Software Foundation, either version 3 of the License, or (at your option)
-- any later version. See LICENSE.
--
-- Structure adapted from the original SkooBot's overload/data/keybinds/
-- toggle-skoobot.lua, itself following ToME's own keybind definitions
-- (Nicolas Casalini, GPL-3.0).
--
-- ---------------------------------------------------------------------------
--
-- Deliberately NOT the original's Alt+F1.
--
-- The original SkooBot is still published and still installed by real people,
-- and it binds Alt+F1 to TOGGLE_SKOOBOT. Two addons answering the same key
-- would be a genuine, if small, way for this project to interfere with the
-- one it promises not to touch -- and "compatibility is untested" is a poor
-- excuse for a collision that is known in advance. Anyone who wants the old
-- key can set it in Game Options -> Keybindings.

defineAction{
	default = { "sym:_F3:false:true:false:false" },   -- Shift+F3
	type = "TOGGLE_SKOOBOT_RECLAUDED",
	group = "actions",
	name = "Toggle SkooBot: Reclauded",
}

defineAction{
	default = { "sym:_F4:false:true:false:false" },   -- Shift+F4
	type = "STOP_SKOOBOT_RECLAUDED",
	group = "actions",
	name = "Stop SkooBot: Reclauded",
}
