-- ToME - Tales of Maj'Eyal
-- Copyright (C) 2009, 2010, 2011, 2012, 2013 Nicolas Casalini
--
-- This program is free software: you can redistribute it and/or modify
-- it under the terms of the GNU General Public License as published by
-- the Free Software Foundation, either version 3 of the License, or
-- (at your option) any later version.
--
-- This program is distributed in the hope that it will be useful,
-- but WITHOUT ANY WARRANTY; without even the implied warranty of
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
-- GNU General Public License for more details.
--
-- You should have received a copy of the GNU General Public License
-- along with this program.  If not, see <http://www.gnu.org/licenses/>.
--
-- Nicolas Casalini "DarkGod"
-- darkgod@te4.org
--
-- ---------------------------------------------------------------------------
--
-- SkooBot: Reclauded -- key bindings. Adapted from SkooBot 0.0.12's
-- overload/data/keybinds/toggle-skoobot.lua (SkoobyDoo, 2018-2020), which
-- adapted ToME's own keybind definitions; Casalini's header above is kept
-- for that reason.
--
-- Deliberately NOT the original's keys (Alt+F1, Shift+F1, Alt+F2, Alt+F3,
-- Shift+F2). The original SkooBot is still published and still installed by
-- real people, and two addons answering the same key would be a genuine way
-- for this project to interfere with the one it promises not to touch. ToME
-- itself owns bare F1-F8 and Ctrl+F1-F8 (party switching and orders), and
-- Alt+F4 closes the window on Windows; Shift+F3..F7 belong to nobody (checked
-- against every keybind file in the 1.7.6 engine and module). Anyone who
-- wants the old keys can set them in Game Options -> Keybindings.
--
-- "Belong to nobody" is true of the base game on the day this was written
-- and of nothing else: another addon can define any of these keys, and the
-- player can remap onto them. hooks/load.lua checks all five against what
-- the engine actually has bound, at ToME:runDone and on every menu open,
-- and says so when they collide -- advisory only; it never rebinds (#50).

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

defineAction{
	default = { "sym:_F5:false:true:false:false" },   -- Shift+F5
	type = "RUNONCE_SKOOBOT_RECLAUDED",
	group = "actions",
	name = "Run SkooBot: Reclauded once",
}

defineAction{
	default = { "sym:_F6:false:true:false:false" },   -- Shift+F6
	type = "ASK_SKOOBOT_RECLAUDED",
	group = "actions",
	name = "Ask SkooBot: Reclauded what it would do",
}

defineAction{
	default = { "sym:_F7:false:true:false:false" },   -- Shift+F7
	type = "MENU_SKOOBOT_RECLAUDED",
	group = "actions",
	name = "Open the SkooBot: Reclauded menu",
}
