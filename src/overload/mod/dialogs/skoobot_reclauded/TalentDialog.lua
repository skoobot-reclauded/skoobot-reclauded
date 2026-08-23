-- SkooBot: Reclauded -- the talent screen: what the bot may use, in which role,
-- in what order.
--
-- Copyright (C) 2018-2020 SkoobyDoo (SkooBot 0.0.12, overload/mod/dialogs/BotTalentDialog.lua)
-- Copyright (C) 2026 SkoobyDoo
--
-- This program is free software: you can redistribute it and/or modify it
-- under the terms of the GNU General Public License as published by the Free
-- Software Foundation, either version 3 of the License, or (at your option)
-- any later version. See LICENSE.
--
-- ---------------------------------------------------------------------------
--
-- REBUILT for #56 on the skeleton of the game's own Use Talents screen
-- (mod/dialogs/UseTalents.lua, Nicolas Casalini, GPL-3.0): a sectioned list
-- on the left, the selected talent's description on the right. The four
-- bucket sections hold the rules in priority order; the Unassigned section
-- holds everything else the character can use, items included. Every edit
-- is a move -- by mouse drag, by keyboard, or through the action menu -- and
-- the list logic is data/rules.lua, reached through skoobot_reclauded.rules.
-- This file only draws the rules and turns input into calls on them.
--
-- v1's version was a flat list with an integer priority per rule, filled
-- through three chained dialogs. Its latent bugs went with it: the unstable
-- priority sort, the Priority column sort throwing on the "add" row, and the
-- trailing `1` meant as GetQuantity's min that landed on registerDialog
-- (T-001). #48 and #49 were about dialogs that no longer exist.
--
-- Keys: Enter or a row's letter opens the action menu; 1-4 send the selected
-- talent to that section; 0, Delete or Backspace unassign it; Shift+Up and
-- Shift+Down reorder it. Ctrl+Up/Down belong to the list widget itself, which
-- sees every key before this dialog does (engine/ui/Dialog.lua keyEvent).

require "engine.class"
local Dialog = require "engine.ui.Dialog"
local TreeList = require "engine.ui.TreeList"
local Textzone = require "engine.ui.Textzone"
local TextzoneList = require "engine.ui.TextzoneList"
local Separator = require "engine.ui.Separator"

local CustomActionDialog = require "mod.dialogs.skoobot_reclauded.CustomActionDialog"

module(..., package.seeall, class.inherit(Dialog))

-- The drag payload kind. Namespaced so a drop on one of the game's own targets
-- (the hotkey bar takes kind="talent") is ignored rather than misread, and so
-- a stray game drag dropped here is ignored too.
local DRAG_KIND = "skoobot_reclauded_rule"

local UNASSIGNED = "Unassigned"

local KIND_LABELS = { sustained = "Sustained", activated = "Activated", object = "Item" }

local TUTORIAL = table.concat({
	"Talents the bot may use, by role. Order within a section is priority: the first one that can be used " ..
		"is used.",
	"Drag a talent onto a section to add it, or onto another talent to put it before that one. Keyboard: " ..
		"Enter or the letter opens the actions; 1-4 send the selected talent to that section; 0 or Delete " ..
		"unassigns it; Shift+Up/Down reorders it. Sustained talents only go in Sustain.",
}, "\n") .. "\n"

-- Letters a-z, A-Z only: makeKeyChar continues with digits, which are taken.
local MAX_LETTERS = 52

function _M:init(actor)
	self.actor = actor
	self.R = skoobot_reclauded.rules
	self.rm = self.R.module
	self.folded = {}
	self.status_key = {}
	Dialog.init(self, "SkooBot: Reclauded - talent rules", math.max(800, game.w * 0.8), math.max(600, game.h * 0.8))

	local vsep = Separator.new{dir="horizontal", size=self.ih - 10}
	local halfwidth = math.floor((self.iw - vsep.w) / 2)
	self.c_tut = Textzone.new{width=halfwidth, height=1, auto_height=true, no_color_bleed=true, text=TUTORIAL}
	self.c_desc = TextzoneList.new{width=halfwidth, height=self.ih - self.c_tut.h - 20, scrollbar=true,
		no_color_bleed=true}

	self:generateList()

	self.c_list = TreeList.new{width=halfwidth, height=self.ih - 10, all_clicks=true, scrollbar=true,
		columns={
			{name="", width={30,"fixed"}, display_prop="char"},
			{name="Talent", width=58, display_prop="name"},
			{name="Kind", width=18, display_prop="kind"},
			{name="Tree", width=24, display_prop="tree"},
		},
		tree=self.tree,
		fct=function(item, _, button) self:use(item, button) end,
		select=function(item) self:select(item) end,
		on_drag=function(item) self:onDrag(item) end,
	}

	self:loadUI{
		{left=0, top=0, ui=self.c_list},
		{right=0, top=self.c_tut.h + 20, ui=self.c_desc},
		{right=0, top=0, ui=self.c_tut},
		{hcenter=0, top=5, ui=vsep},
	}
	self:setFocus(self.c_list)
	self:setupUI()

	self.key:addCommands{
		__TEXTINPUT = function(c)
			local n = tonumber(c)
			if n and n >= 1 and n <= #self.rm.SECTIONS then
				self:moveSelected(self.rm.SECTIONS[n])
			elseif n == 0 then
				self:unassignSelected()
			elseif self.chars[c] then
				local item = self.chars[c]
				self:selectItem(item)
				self:use(item, "left")
			end
		end,
		[{"_UP", "shift"}] = function() self:shiftSelected(-1) end,
		[{"_DOWN", "shift"}] = function() self:shiftSelected(1) end,
		_DELETE = function() self:unassignSelected() end,
		_BACKSPACE = function() self:unassignSelected() end,
	}
	self.key:addBinds{
		EXIT = function() game:unregisterDialog(self) end,
	}
end

function _M:on_register()
	game:onTickEnd(function() self.key:unicodeInput(true) end)
end

-------------------------------------------------------------------------------
-- The list
-------------------------------------------------------------------------------

local function header(section, label, desc, nodes, shown)
	return {
		char="", name=tstring{{"font", "bold"}, label, {"font", "normal"}}, kind="", tree="",
		desc=desc, nodes=nodes, shown=shown, section=section,
		color=function() return colors.simple(section and colors.LIGHT_GREEN or colors.GREY) end,
	}
end

--- One row. `section` is nil in the Unassigned section.
function _M:row(entry, section)
	local info = self.R.describe(self.actor, entry)
	local icon = ""
	local t = info.t
	if t and t.display_entity and game.uiset and game.uiset.hotkeys_display_icons then
		-- Cosmetic; the same calls Use Talents makes, behind a pcall because an
		-- icon is not worth a broken screen.
		local ok, s = pcall(function()
			t.display_entity:getMapObjects(game.uiset.hotkeys_display_icons.tiles, {}, 1)
			return t.display_entity:getDisplayString()
		end)
		if ok and type(s) == "string" then icon = s end
	end
	local plain = (tostring(info.name):gsub("#[^#]*#", ""))
	local kind = KIND_LABELS[info.kind] or tostring(info.kind)
	if not info.live then kind = kind .. (info.carried == false and " (not carried)" or " (inactive)") end
	return {
		char="", name=(icon .. tostring(info.name)):toTString(), cname=plain, kind=kind, tree=tostring(info.tree),
		entry=entry, section=section, ekind=info.kind, tid=info.tid, live=info.live, desc=info.desc,
		color=function() return info.live and {0xFF, 0xFF, 0xFF} or {0x80, 0x80, 0x80} end,
	}
end

function _M:generateList()
	local p, R, rm = self.actor, self.R, self.rm
	local rules = R.get(p)
	local tree, chars, placed = {}, {}, {}

	for i, section in ipairs(rm.SECTIONS) do
		local nodes = {}
		for _, entry in ipairs(rules[section]) do
			nodes[#nodes + 1] = self:row(entry, section)
			placed[rm.key(entry)] = true
		end
		tree[#tree + 1] = header(section, ("%d. %s"):format(i, rm.LABELS[section]), rm.DESCRIPTIONS[section],
			nodes, not self.folded[section])
	end

	-- Everything else the character can use, as the game's Use Talents screen
	-- lists it: every non-passive talent, hidden or not, items included.
	local avail = {}
	for tid, _ in pairs(p.talents) do
		local t = p:getTalentFromId(tid)
		if t and t.mode ~= "passive" then
			local entry = R.entryFor(p, t)
			local k = entry and rm.key(entry)
			if k and not placed[k] then
				placed[k] = true
				avail[#avail + 1] = self:row(entry, nil)
			end
		end
	end
	table.sort(avail, function(a, b)
		if a.ekind ~= b.ekind then return a.ekind < b.ekind end
		return a.cname < b.cname
	end)
	tree[#tree + 1] = header(nil, UNASSIGNED,
		"Everything else you can use. Move a talent into a section to let the bot use it.",
		avail, not self.folded[UNASSIGNED])

	local letter = 1
	for _, node in ipairs(tree) do
		for _, item in ipairs(node.nodes) do
			if letter <= MAX_LETTERS then
				item.char = self:makeKeyChar(letter)
				chars[item.char] = item
				letter = letter + 1
			end
		end
	end

	self.tree = tree
	self.chars = chars
end

--- Rebuild the list after an edit, keeping the rule with key `keep` selected.
function _M:refresh(keep)
	self:generateList()
	local list = self.c_list
	list.tree = self.tree
	list:drawTree()
	list:outputList()
	if keep then
		for i, item in ipairs(list.list) do
			if item.entry and self.rm.key(item.entry) == keep then list.sel = i break end
		end
	end
	list.scroll = util.scroll(list.sel, list.scroll, list.max_display)
	list.old_sel = nil
	list:onSelect()
end

function _M:selected()
	local list = self.c_list
	return list and list.list and list.list[list.sel]
end

function _M:selectItem(item)
	local list = self.c_list
	for i, it in ipairs(list.list) do
		if it == item then
			list.sel = i
			list.scroll = util.scroll(list.sel, list.scroll, list.max_display)
			list.old_sel = nil
			list:onSelect()
			return
		end
	end
end

function _M:select(item)
	if not item then return end
	self.cur_item = item
	self.c_desc:switchItem(item, item.desc)
end

--- Put a message in the description pane, where the eye already is.
function _M:say(text)
	self.c_desc:switchItem(self.status_key, text, true)
end

-------------------------------------------------------------------------------
-- Edits. Each one is a call on data/rules.lua and a refresh.
-------------------------------------------------------------------------------

function _M:place(entry, section, before)
	local ok, why = self.rm.allowed(self.R.kind(self.actor, entry), section)
	if not ok then
		self:say("#LIGHT_RED#" .. tostring(why))
		return false
	end
	local at = self.rm.place(self.R.get(self.actor), entry, section, before)
	print(("[SKOOBOT] [TalentDialog] %s -> %s at %s"):format(tostring(self.rm.key(entry)), section, tostring(at)))
	self:refresh(self.rm.key(entry))
	return at ~= nil
end

function _M:unassign(entry)
	local removed = self.rm.remove(self.R.get(self.actor), entry)
	if removed then print(("[SKOOBOT] [TalentDialog] %s unassigned"):format(tostring(self.rm.key(entry)))) end
	self:refresh(self.rm.key(entry))
	return removed ~= nil
end

function _M:shift(entry, delta)
	local at = self.rm.shift(self.R.get(self.actor), entry, delta)
	if at then self:refresh(self.rm.key(entry)) end
	return at
end

function _M:moveSelected(section)
	local item = self:selected()
	if not item or not item.entry then
		self:say("Select a talent first.")
		return false
	end
	if item.section == section then return true end
	return self:place(item.entry, section)
end

function _M:unassignSelected()
	local item = self:selected()
	if not item or not item.entry or not item.section then return false end
	return self:unassign(item.entry)
end

function _M:shiftSelected(delta)
	local item = self:selected()
	if not item or not item.entry or not item.section then return nil end
	return self:shift(item.entry, delta)
end

-------------------------------------------------------------------------------
-- Input
-------------------------------------------------------------------------------

--- Enter, a click, a letter, or a drop (button == "drag-end").
function _M:use(item, button)
	if not item then return end
	if button == "drag-end" then return self:drop(item) end
	if item.nodes then
		if button == "right" then return end
		local k = item.section or UNASSIGNED
		self.folded[k] = not self.folded[k]
		self.c_list:treeExpand(not self.folded[k], item)
		return
	end
	if not item.entry then return end
	self:selectItem(item)

	local list = {}
	for i, section in ipairs(self.rm.SECTIONS) do
		if section ~= item.section and self.rm.allowed(item.ekind, section) then
			list[#list + 1] = {name=("Move to %s (%d)"):format(self.rm.LABELS[section], i),
				action=function() self:place(item.entry, section) end}
		end
	end
	if item.section then
		list[#list + 1] = {name="Move up (Shift+Up)", action=function() self:shift(item.entry, -1) end}
		list[#list + 1] = {name="Move down (Shift+Down)", action=function() self:shift(item.entry, 1) end}
		list[#list + 1] = {name="Unassign (Delete)", action=function() self:unassign(item.entry) end}
	end
	list[#list + 1] = {name="Cancel", action=function() end}
	game:registerDialog(CustomActionDialog.new(item.cname, list))
end

--- The list widget reports every motion with the left button held; the engine
--- turns the first one that travels far enough into a drag (engine/Mouse.lua
--- startDrag) and ignores the rest.
function _M:onDrag(item)
	if not item or not item.entry then return end
	local cursor
	local t = item.tid and self.actor:getTalentFromId(item.tid)
	if t and t.display_entity then
		local ok, s = pcall(t.display_entity.getEntityFinalSurface, t.display_entity, nil, 64, 64)
		if ok then cursor = s end
	end
	local x, y = core.mouse.get()
	game.mouse:startDrag(x, y, cursor, {kind=DRAG_KIND, entry=item.entry, from=item.section})
end

--- Release delivers "drag-end" to the row under the cursor. On a section
--- header the rule goes to the end of that section; on a row it goes before
--- that row, in that row's section. Unassigned, either way, unassigns.
function _M:drop(item)
	local drag = game.mouse.dragged
	local payload = drag and drag.payload
	if not payload or payload.kind ~= DRAG_KIND or not payload.entry then return end
	game.mouse:usedDrag()
	if item.nodes then
		if item.section then self:place(payload.entry, item.section) else self:unassign(payload.entry) end
	elseif item.entry then
		if item.section then self:place(payload.entry, item.section, item.entry) else self:unassign(payload.entry) end
	end
end
