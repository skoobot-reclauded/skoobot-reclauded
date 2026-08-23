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
-- bucket sections hold the rules in priority order; the Available section
-- below them lists everything the character can use, items included, with
-- an "In" column naming the sections each one is already in. A talent may
-- be in several sections -- a healing infusion as both Damage Prevention and
-- Recovery, as v1 allowed -- once per section. Every edit is a move or an
-- add: by mouse drag, by keyboard, or through the action menu. A drag from
-- Available adds; a drag from a section moves. The list logic is
-- data/rules.lua, reached through skoobot_reclauded.rules; this file only
-- draws the rules and turns input into calls on them.
--
-- v1's version was a flat list with an integer priority per rule, filled
-- through three chained dialogs. Its latent bugs went with it: the unstable
-- priority sort, the Priority column sort throwing on the "add" row, and the
-- trailing `1` meant as GetQuantity's min that landed on registerDialog
-- (T-001). #48 and #49 were about dialogs that no longer exist.
--
-- Keys: Enter or a row's letter opens the action menu; 1-4 add (from
-- Available) or move (from a section) the selected talent to that section;
-- 0, Delete or Backspace remove it from its section, or from every section
-- when pressed on an Available row; Shift+Up and Shift+Down reorder it.
-- Ctrl+Up/Down belong to the list widget itself, which sees every key before
-- this dialog does (engine/ui/Dialog.lua keyEvent).
--
-- BUILT-IN ACTIONS (#59). Available also lists the two flee rows -- "Flee
-- from the nearest hostile", "Flee from the strongest hostile" -- from
-- data/rules.lua's ACTIONS. They place like a talent, into Combat only
-- (rules.allowed typing), both may be placed, and their description is the
-- module's fixed prose.
--
-- SUGGESTED LOADOUTS (#18). The first row of the list, "Suggest a loadout",
-- carries the count of talents the bot could place that are in no section,
-- and activating it (Enter or a click) swaps the list for a PROPOSAL built by
-- data/loadout.lua from the game's own talent metadata: the four sections
-- with the suggested rows in priority order and the reason for each, then
-- the talents it would not place and why, then the mutually exclusive
-- sustain groups it leaves to the player. Nothing is written while the
-- proposal is shown. Enter on any row offers Merge (the default: add what is
-- new, keep every row placed by hand), Replace (clear everything first --
-- confirmed when the current list is not empty) or Cancel; Escape cancels.
-- Rows the suggestion writes carry `suggested = true`; any hand edit to such
-- a row here clears the mark, so a later Merge never moves a row the player
-- touched.

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

local AVAILABLE = "Available"

local KIND_LABELS = { sustained = "Sustained", activated = "Activated", object = "Item", action = "Action" }

-- The order kinds are listed in under Available: the character's own talents
-- first, the built-in actions (#59) last.
local KIND_ORDER = { activated = 1, object = 2, sustained = 3, action = 4 }

local TUTORIAL = table.concat({
	"Talents the bot may use, by role. Order within a section is priority: the first one that can be used " ..
		"is used. A talent can be in more than one section.",
	"Drag from Available into a section to add a talent; drag it from one section to another to move it, " ..
		"or onto another talent to put it before that one. Keyboard: Enter or the letter opens the actions; " ..
		"1-4 add (from Available) or move (from a section) the selected talent; 0 or Delete removes it from " ..
		"its section; Shift+Up/Down reorders it. Sustained talents only go in Sustain; the flee actions at " ..
		"the end of Available only go in Combat.",
	"Not sure where to start? The first row suggests a loadout from the game's own talent data; nothing " ..
		"is written until you choose Merge or Replace.",
}, "\n") .. "\n"

local PROPOSAL_INTRO = "This is a suggestion, read from the game's own talent data: nothing has been written. " ..
	"Select a row to see why it is placed where it is. Press Enter on any row to choose Merge (add what is new, " ..
	"keep every row you placed yourself), Replace (clear the current rules first) or Cancel; Escape cancels."

-- Letters a-z, A-Z only: makeKeyChar continues with digits, which are taken.
local MAX_LETTERS = 52

function _M:init(actor)
	self.actor = actor
	self.R = skoobot_reclauded.rules
	self.rm = self.R.module
	self.L = skoobot_reclauded.loadout
	self.folded = {}
	self.status_key = {}
	-- The proposal behind the first row's count. Built once: the talents
	-- known do not change while the screen is open, and only the rules do.
	local ok, hint = pcall(self.L.propose, self.actor)
	self.hint = ok and hint or nil
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
			{name="Talent", width=50, display_prop="name"},
			{name="Kind", width=18, display_prop="kind"},
			{name="Tree", width=20, display_prop="tree"},
			{name="In", width=12, display_prop="used"},
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
		EXIT = function()
			if self.proposal then self:cancelProposal() else game:unregisterDialog(self) end
		end,
	}
end

function _M:on_register()
	game:onTickEnd(function() self.key:unicodeInput(true) end)
end

-------------------------------------------------------------------------------
-- The list
-------------------------------------------------------------------------------

local function header(section, label, desc, nodes, shown, foldkey)
	return {
		char="", name=tstring{{"font", "bold"}, label, {"font", "normal"}}, kind="", tree="", used="",
		desc=desc, nodes=nodes, shown=shown, section=section, foldkey=foldkey,
		color=function() return colors.simple(section and colors.LIGHT_GREEN or colors.GREY) end,
	}
end

--- A row that is an action rather than a rule: the suggest row, the apply row.
local function actionRow(action, label, desc)
	return {
		char="", name=tstring{{"font", "bold"}, label, {"font", "normal"}}, cname=label, kind="", tree="", used="",
		desc=desc, action=action,
		color=function() return colors.simple(colors.GOLD) end,
	}
end

--- Which sections hold a rule: a set, and the section digits for the In column.
local function membership(rm, rules, entry)
	local inS, digits = {}, {}
	for i, section in ipairs(rm.SECTIONS) do
		if rm.indexIn(rules, section, entry) then
			inS[section] = true
			digits[#digits + 1] = tostring(i)
		end
	end
	return inS, table.concat(digits, " ")
end

--- One row. `section` is nil in the Available section.
function _M:row(entry, section, rules)
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
	local inS, used = membership(self.rm, rules, entry)
	return {
		char="", name=(icon .. tostring(info.name)):toTString(), cname=plain, kind=kind, tree=tostring(info.tree),
		used=used, inSections=inS,
		entry=entry, section=section, ekind=info.kind, tid=info.tid, live=info.live, desc=info.desc,
		color=function() return info.live and {0xFF, 0xFF, 0xFF} or {0x80, 0x80, 0x80} end,
	}
end

--- How many talents the suggestion could place that are in no section.
function _M:unplacedCount()
	if not self.hint then return 0 end
	local ok, list = pcall(self.L.unplaced, self.hint, self.actor)
	return ok and #list or 0
end

function _M:generateList()
	if self.proposal then return self:generateProposalList() end
	local p, R, rm = self.actor, self.R, self.rm
	local rules = R.get(p)
	local tree, chars = {}, {}

	-- #18: the way in for a blank list, carrying the count that says the
	-- list is behind the character (design #18 item 6.3).
	local n = self:unplacedCount()
	local label = n > 0 and ("%d unassigned -- suggest a loadout?"):format(n) or "Suggest a loadout..."
	tree[#tree + 1] = actionRow("suggest", label,
		"Suggest a loadout from the game's own talent data: which talents attack, heal, defend, or are kept up. " ..
		"You see the suggestion first and choose Merge, Replace or Cancel; nothing is written before that." ..
		(n > 0 and ("\n\n%d talent%s the bot could use %s in no section."):format(n, n == 1 and "" or "s",
			n == 1 and "is" or "are") or ""))

	for i, section in ipairs(rm.SECTIONS) do
		local nodes = {}
		for _, entry in ipairs(rules[section]) do
			nodes[#nodes + 1] = self:row(entry, section, rules)
		end
		tree[#tree + 1] = header(section, ("%d. %s"):format(i, rm.LABELS[section]), rm.DESCRIPTIONS[section],
			nodes, not self.folded[section])
	end

	-- Everything the character can use, as the game's Use Talents screen lists
	-- it: every non-passive talent, hidden or not, items included -- whether or
	-- not it is already in a section above.
	local avail, seen = {}, {}
	for tid, _ in pairs(p.talents) do
		local t = p:getTalentFromId(tid)
		if t and t.mode ~= "passive" then
			local entry = R.entryFor(p, t)
			local k = entry and rm.key(entry)
			if k and not seen[k] then
				seen[k] = true
				avail[#avail + 1] = self:row(entry, nil, rules)
			end
		end
	end
	-- The built-in actions (#59), after the character's own talents: a fresh
	-- entry each, never the module's definition table.
	for _, a in ipairs(rm.ACTIONS) do
		avail[#avail + 1] = self:row(rm.actionEntry(a), nil, rules)
	end
	table.sort(avail, function(a, b)
		local ka, kb = KIND_ORDER[a.ekind] or 99, KIND_ORDER[b.ekind] or 99
		if ka ~= kb then return ka < kb end
		return a.cname < b.cname
	end)
	tree[#tree + 1] = header(nil, AVAILABLE,
		"Every talent and worn item the bot could use, whether or not it is in a section above, and the bot's " ..
		"own built-in actions -- the flee moves -- last. Move one into a section to add it; the In column shows " ..
		"the sections it is already in. A talent can be in more than one; a flee goes in Combat only.",
		avail, not self.folded[AVAILABLE])

	local letter = 1
	for _, node in ipairs(tree) do
		for _, item in ipairs(node.nodes or {}) do
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

-------------------------------------------------------------------------------
-- The proposal view (#18)
-------------------------------------------------------------------------------

--- One proposed row: the talent, in the existing columns -- name with its
--- priority, kind, the reason in the Tree column, the sections it is already
--- in -- with the full reason and the talent's description on the right.
function _M:proposalRow(e, placed, rules)
	local info = self.R.describe(self.actor, {tid=e.tid})
	local plain = (tostring(info.name):gsub("#[^#]*#", ""))
	local kind = KIND_LABELS[info.kind] or tostring(info.kind)
	local inS, used = membership(self.rm, rules, {tid=e.tid})
	local marks = {}
	if e.hidden then marks[#marks + 1] = "hidden" end
	if e.conditional then marks[#marks + 1] = "conditional" end
	local where = e.section and ("Suggested for %s, priority %d."):format(self.rm.LABELS[e.section], e.priority or 0)
		or "Not placed."
	local desc = where .. "\nReason: " .. tostring(e.reason) .. "."
	if placed then
		desc = desc .. "\n\nAlready in a section you filled: Merge leaves it where it is; Replace moves it here."
	end
	desc = desc .. "\n\n" .. tostring(info.desc)
	return {
		char="", cname=plain, kind=kind, used=used, inSections=inS,
		name=(e.priority and (tostring(e.priority) .. "  ") or "") .. tostring(info.name) ..
			(#marks > 0 and (" (" .. table.concat(marks, ", ") .. ")") or ""),
		tree=tostring(e.reason), desc=desc, ptid=e.tid, psection=e.section, placed=placed,
		color=function() return placed and {0x80, 0x80, 0x80} or {0xFF, 0xFF, 0xFF} end,
	}
end

function _M:generateProposalList()
	local P, rm, rules = self.proposal, self.rm, self.R.get(self.actor)
	local tree, chars = {}, {}

	-- Talents the player has placed by hand anywhere: Merge leaves those alone.
	local hand = {}
	for _, s in ipairs(rm.SECTIONS) do
		for _, e in ipairs(rules[s]) do
			if e.tid and not e.suggested then hand[e.tid] = true end
		end
	end

	tree[#tree + 1] = actionRow("apply", "Apply this suggestion...  (Enter: Merge / Replace / Cancel)", PROPOSAL_INTRO)

	for i, section in ipairs(rm.SECTIONS) do
		local nodes = {}
		for _, e in ipairs(P.entries) do
			if e.section == section then nodes[#nodes + 1] = self:proposalRow(e, hand[e.tid] == true, rules) end
		end
		tree[#tree + 1] = header(section, ("%d. %s -- suggested"):format(i, rm.LABELS[section]),
			rm.DESCRIPTIONS[section] .. "\n\nThe rows below are a suggestion, in the order the bot would try them: " ..
			"longest cooldown first, so the big hitters fire when they are ready and the rotation falls through " ..
			"to the fillers.", nodes, true, "proposal:" .. section)
	end

	local out = {}
	for _, e in ipairs(P.unassigned) do out[#out + 1] = self:proposalRow(e, false, rules) end
	for _, e in ipairs(P.skipped) do out[#out + 1] = self:proposalRow(e, false, rules) end
	tree[#tree + 1] = header(nil, ("Not placed (%d)"):format(#out),
		"Talents the suggestion leaves out, each with its reason: the game gives no tactical data for it, " ..
		"marks it as not for an AI, or gives it a role the bot does not have -- escapes, buffs, specials. " ..
		"Place any of these by hand if you want the bot to use them.", out, #out > 0, "proposal:unassigned")

	local ch = {}
	for _, c in ipairs(P.choices) do
		local names = {}
		for i, tid in ipairs(c.tids) do
			local info = self.R.describe(self.actor, {tid=tid})
			names[i] = (tostring(info.name):gsub("#[^#]*#", ""))
		end
		ch[#ch + 1] = {
			char="", cname=c.slot, kind="", tree=tostring(c.reason), used="",
			name=table.concat(names, " / "),
			desc=("These %d sustains share the %s slot: only one can be up, and the data gives no reason to prefer " ..
				"one, so the suggestion places none of them. Put the one you want in Sustain by hand."):format(
				#c.tids, c.slot),
			pchoice=c,
			color=function() return {0xFF, 0xFF, 0xFF} end,
		}
	end
	tree[#tree + 1] = header(nil, ("Your choice (%d)"):format(#ch),
		"Groups of mutually exclusive sustains -- the chants, the hymns -- where the suggestion places none " ..
		"and leaves the pick to you.", ch, #ch > 0, "proposal:choices")

	local letter = 1
	for _, node in ipairs(tree) do
		for _, item in ipairs(node.nodes or {}) do
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

--- Build a proposal and show it. Nothing is written.
function _M:suggest()
	local ok, proposal = pcall(self.L.propose, self.actor)
	if not ok then
		self:say("#LIGHT_RED#Could not build a suggestion: " .. tostring(proposal))
		return false
	end
	self.proposal = proposal
	self.hint = proposal
	print(("[SKOOBOT] [TalentDialog] suggestion shown: %d entries, %d unassigned, %d skipped, %d choices"):format(
		proposal.counts.entries, proposal.counts.unassigned, proposal.counts.skipped, proposal.counts.choices))
	self:refresh()
	self:selectItem(self.c_list.list[1])
	self:say(PROPOSAL_INTRO)
	return true
end

function _M:cancelProposal()
	if not self.proposal then return end
	self.proposal = nil
	print("[SKOOBOT] [TalentDialog] suggestion cancelled")
	self:refresh()
	self:say("Suggestion cancelled. Nothing was written.")
end

--- Write the shown proposal. `mode` is "merge" or "replace"; Replace asks
--- first when there is anything to lose.
function _M:applyProposal(mode)
	if not self.proposal then return false end
	local rules = self.R.get(self.actor)
	local current = self.rm.count(rules)
	if mode == "replace" and current > 0 and not self.replace_confirmed then
		local text = ("This clears all %d current rows -- including the ones you placed by hand -- and writes " ..
			"the %d suggested entries. Merge would keep your rows."):format(current, #self.proposal.entries)
		local d = Dialog:yesnoLongPopup("Replace the talent rules?", text, 500, function(yes)
			if yes then
				self.replace_confirmed = true
				self:applyProposal("replace")
				self.replace_confirmed = nil
			end
		end, "Replace", "Keep them")
		-- Enter must not be the destructive answer: focus the safe button.
		for _, u in ipairs(d.uis or {}) do
			if u.ui and u.ui.text == "Keep them" then d:setFocus(u.ui) end
		end
		return false
	end
	local report = self.L.apply(self.proposal, mode, self.actor)
	self.proposal = nil
	print(("[SKOOBOT] [TalentDialog] suggestion applied (%s): %d added, %d removed, %d kept"):format(
		report.mode, report.added, report.removed, report.kept))
	self:refresh()
	self:say(("%s: %d added, %d removed, %d left as you placed them."):format(
		mode == "replace" and "Replaced" or "Merged", report.added, report.removed, report.kept))
	return true
end

--- The Merge / Replace / Cancel menu.
function _M:applyMenu()
	if not self.proposal then return end
	local rules = self.R.get(self.actor)
	local new = #self.L.unplaced(self.proposal, self.actor)
	local current = self.rm.count(rules)
	local list = {
		{name=("Merge: add %d new, keep every row you placed"):format(new),
			action=function() self:applyProposal("merge") end},
		{name=("Replace: clear the %d current row%s, write the %d suggested"):format(
			current, current == 1 and "" or "s", #self.proposal.entries),
			action=function() self:applyProposal("replace") end},
		{name="Cancel: write nothing", action=function() end},
	}
	game:registerDialog(CustomActionDialog.new("Apply the suggested loadout", list))
end

--- Rebuild the list after an edit, keeping the rule with key `keep` selected:
--- its row in `section` when given (nil is the Available list), else its first.
function _M:refresh(keep, section)
	self:generateList()
	local list = self.c_list
	list.tree = self.tree
	list:drawTree()
	list:outputList()
	if keep then
		local first
		for i, item in ipairs(list.list) do
			if item.entry and self.rm.key(item.entry) == keep then
				first = first or i
				if item.section == section then first = i break end
			end
		end
		if first then list.sel = first end
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

--- Add (no `from`) or move (`from` a section) a rule into `section`, before
--- `before` or at the end.
function _M:place(entry, section, before, from)
	local ok, why = self.rm.allowed(self.R.kind(self.actor, entry), section)
	if not ok then
		self:say("#LIGHT_RED#" .. tostring(why))
		return false
	end
	local rules = self.R.get(self.actor)
	local at = self.rm.place(rules, entry, section, before, from)
	-- A hand edit: the row is the player's now, whoever wrote it (#18).
	if at and rules[section][at] then rules[section][at].suggested = nil end
	print(("[SKOOBOT] [TalentDialog] %s -> %s at %s%s"):format(tostring(self.rm.key(entry)), section,
		tostring(at), from and (" from " .. from) or ""))
	self:refresh(self.rm.key(entry), section)
	return at ~= nil
end

--- Take a rule out of `section`, or out of every section when nil.
function _M:unassign(entry, section)
	local rules = self.R.get(self.actor)
	local n
	if section then
		n = self.rm.remove(rules, entry, section) and 1 or 0
	else
		n = self.rm.removeAll(rules, entry)
	end
	if n == 0 then
		self:say("Not in any section.")
		return false
	end
	print(("[SKOOBOT] [TalentDialog] %s removed from %s"):format(tostring(self.rm.key(entry)),
		section or "every section"))
	self:refresh(self.rm.key(entry), nil)
	return true
end

function _M:shift(entry, section, delta)
	local rules = self.R.get(self.actor)
	local at = self.rm.shift(rules, entry, section, delta)
	if at then
		if rules[section][at] then rules[section][at].suggested = nil end
		self:refresh(self.rm.key(entry), section)
	end
	return at
end

--- While a proposal is shown there is nothing to edit: say so, once.
function _M:previewing()
	if not self.proposal then return false end
	self:say("This is a suggestion. Press Enter to Merge or Replace it, or Escape to go back, before editing.")
	return true
end

--- The digit keys: add from Available, move from a section.
function _M:moveSelected(section)
	if self:previewing() then return false end
	local item = self:selected()
	if not item or not item.entry then
		self:say("Select a talent first.")
		return false
	end
	if item.section == section then return true end
	return self:place(item.entry, section, nil, item.section)
end

function _M:unassignSelected()
	if self:previewing() then return false end
	local item = self:selected()
	if not item or not item.entry then return false end
	return self:unassign(item.entry, item.section)
end

function _M:shiftSelected(delta)
	if self:previewing() then return nil end
	local item = self:selected()
	if not item or not item.entry or not item.section then return nil end
	return self:shift(item.entry, item.section, delta)
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
		local k = item.foldkey or item.section or AVAILABLE
		self.folded[k] = not self.folded[k]
		self.c_list:treeExpand(not self.folded[k], item)
		return
	end
	if item.action == "suggest" then
		self:selectItem(item)
		return self:suggest()
	end
	if self.proposal then
		-- Any row of the proposal: the one question there is to answer.
		self:selectItem(item)
		return self:applyMenu()
	end
	if not item.entry then return end
	self:selectItem(item)

	local rm = self.rm
	local inS = membership(rm, self.R.get(self.actor), item.entry)
	local list = {}
	if item.section then
		for i, section in ipairs(rm.SECTIONS) do
			if section ~= item.section and rm.allowed(item.ekind, section) then
				list[#list + 1] = {name=("Move to %s (%d)"):format(rm.LABELS[section], i),
					action=function() self:place(item.entry, section, nil, item.section) end}
			end
		end
		for _, section in ipairs(rm.SECTIONS) do
			if section ~= item.section and not inS[section] and rm.allowed(item.ekind, section) then
				list[#list + 1] = {name=("Also add to %s"):format(rm.LABELS[section]),
					action=function() self:place(item.entry, section) end}
			end
		end
		list[#list + 1] = {name="Move up (Shift+Up)", action=function() self:shift(item.entry, item.section, -1) end}
		list[#list + 1] = {name="Move down (Shift+Down)", action=function() self:shift(item.entry, item.section, 1) end}
		list[#list + 1] = {name=("Remove from %s (Delete)"):format(rm.LABELS[item.section]),
			action=function() self:unassign(item.entry, item.section) end}
	else
		for i, section in ipairs(rm.SECTIONS) do
			if not inS[section] and rm.allowed(item.ekind, section) then
				list[#list + 1] = {name=("Add to %s (%d)"):format(rm.LABELS[section], i),
					action=function() self:place(item.entry, section) end}
			end
		end
		for _, section in ipairs(rm.SECTIONS) do
			if inS[section] then
				list[#list + 1] = {name=("Remove from %s"):format(rm.LABELS[section]),
					action=function() self:unassign(item.entry, section) end}
			end
		end
	end
	list[#list + 1] = {name="Cancel", action=function() end}
	game:registerDialog(CustomActionDialog.new(item.cname, list))
end

--- The list widget reports every motion with the left button held; the engine
--- turns the first one that travels far enough into a drag (engine/Mouse.lua
--- startDrag) and ignores the rest. The payload remembers where the drag
--- started: a section (so the drop is a move) or Available (an add).
function _M:onDrag(item)
	if self.proposal or not item or not item.entry then return end
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
--- that row, in that row's section. On Available, either way, a rule dragged
--- out of a section leaves that section.
function _M:drop(item)
	local drag = game.mouse.dragged
	local payload = drag and drag.payload
	if not payload or payload.kind ~= DRAG_KIND or not payload.entry then return end
	if self.proposal then
		game.mouse:usedDrag()
		self:previewing()
		return
	end
	game.mouse:usedDrag()
	local from = payload.from
	if item.nodes then
		if item.section then self:place(payload.entry, item.section, nil, from)
		elseif from then self:unassign(payload.entry, from) end
	elseif item.entry then
		if item.section then self:place(payload.entry, item.section, item.entry, from)
		elseif from then self:unassign(payload.entry, from) end
	end
end
