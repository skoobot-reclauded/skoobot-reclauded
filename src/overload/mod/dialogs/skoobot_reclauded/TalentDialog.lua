-- SkooBot: Reclauded -- configure which talents the bot may use, and how.
--
-- Copyright (C) 2018-2020 SkoobyDoo (SkooBot 0.0.12, overload/mod/dialogs/BotTalentDialog.lua)
-- Copyright (C) 2026 SkoobyDoo
--
-- This program is free software: you can redistribute it and/or modify it
-- under the terms of the GNU General Public License as published by the Free
-- Software Foundation, either version 3 of the License, or (at your option)
-- any later version. See LICENSE.
--
-- PORTED FROM SkooBot 0.0.12 (D-12), under the addon's own dialog namespace.
-- The configured list lives in player.skoobot_reclauded.autotalents (see the
-- Player superload) rather than in a field the original also writes.

require "engine.class"
local Dialog = require "engine.ui.Dialog"
local ListColumns = require "engine.ui.ListColumns"
local Textzone = require "engine.ui.Textzone"
local TextzoneList = require "engine.ui.TextzoneList"
local Separator = require "engine.ui.Separator"
local GetQuantity = require "engine.dialogs.GetQuantity"

local CustomActionDialog = require "mod.dialogs.skoobot_reclauded.CustomActionDialog"
local PickOneDialog = require "mod.dialogs.skoobot_reclauded.PickOneDialog"

module(..., package.seeall, class.inherit(Dialog))

local USE_TYPES = {
	{name='Combat', value='Combat'}, {name='Sustain', value='Sustain'},
	{name='Recovery', value='Recovery'}, {name='Damage Prevention', value='DamagePrevention'},
}

function _M:init(actor)
	self.actor = actor
	Dialog.init(self, "Define tactical talents usage", math.max(800, game.w * 0.8), math.max(600, game.h * 0.8))

	local vsep = Separator.new{dir="horizontal", size=self.ih - 10}
	local halfwidth = math.floor((self.iw - vsep.w) / 2)
	-- Assembled from short source lines so nothing overflows 120 columns; the
	-- displayed text is one paragraph followed by three bullets, unchanged.
	local tut = table.concat({
		"Add talents to this dialog to allow SkooBot: Reclauded to use them. " ..
			"The parameters are as follows:",
		"* Name - The talent name",
		"* Use Type - The category of use for this entry. Possible values are " ..
			"Combat, Sustain, Recovery and Damage Prevention.",
		"* Priority - The priority with which the bot will attempt to use this " ..
			"skill when its logic determines it needs to use a skill of the given " ..
			"use type. Higher priority means a skill will be preferred over others.",
	}, "\n") .. "\n"
	self.c_tut = Textzone.new{width=halfwidth, height=1, auto_height=true, no_color_bleed=true, text=tut}
	self.c_desc = TextzoneList.new{width=halfwidth, height=self.ih, no_color_bleed=true}

	self.c_list = ListColumns.new{width=halfwidth, height=self.ih - 10, sortable=true, scrollbar=true, columns={
		{name="", width={30,"fixed"}, display_prop="char", sort="id"},
		{name="Talent Name", width=70, display_prop="name", sort="name"},
		{name="Use Type", width=20, display_prop="usetype", sort="usetype"},
		{name="Priority", width=12, display_prop="priority", sort="priority"},
	}, list={}, fct=function(item) self:use(item) end, select=function(item) self:select(item) end}

	self:generateList()

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
			if self.list and self.list.chars[c] then
				self:use(self.list[self.list.chars[c]])
			end
		end,
	}
	self.key:addBinds{
		EXIT = function()
			game:unregisterDialog(self)
		end,
	}
end

function _M:on_register()
	game:onTickEnd(function() self.key:unicodeInput(true) end)
end

function _M:autotalents()
	return skoobot_reclauded.data(self.actor).autotalents
end

function _M:use(item)
	if not item then return end

	if item.addnew then
		local talentlist = {}
		for tid, _ in pairs(game.player.talents) do
			local t = self.actor:getTalentFromId(tid)
			if t.mode ~= "passive" and t.hide ~= "true" then
				talentlist[#talentlist + 1] = {name=self.actor:getTalentFromId(tid).name:capitalize(), value=tid}
			end
		end

		table.sort(talentlist, function(a, b) return a.name < b.name end)

		local d = PickOneDialog.new("Pick a talent to add", talentlist,
			function(value)
				local auto = self:autotalents()
				auto[#auto + 1] = {tid=value, usetype='', priority=1}
				self:generateList()
				local name = self.actor:getTalentFromId(value).name:capitalize()
				local d2 = PickOneDialog.new("Pick use type for " .. name, USE_TYPES,
					function(value2)
						print("[SKOOBOT] [TalentDialog] Changing use type for " .. name .. " to " .. value2)
						auto[#auto].usetype = value2
						self:generateList()
						game:registerDialog(GetQuantity.new("Enter priority value", "Higher = use first",
							auto[#auto].priority, nil, function(value3)
							print("[SKOOBOT] [TalentDialog] Changing priority for " .. name .. " to " .. tostring(value3))
							auto[#auto].priority = value3
							self:generateList()
						end), 1)
					end)
				game:registerDialog(d2)
			end)
		game:registerDialog(d)
		return
	else
		local d = CustomActionDialog.new("Modify Talent Use: " .. item.name, {
			{name="Select Use Type", action=function()
				local d2 = PickOneDialog.new("Pick use type for " .. item.name, USE_TYPES,
					function(value)
						print("[SKOOBOT] [TalentDialog] Changing use type for " .. item.name .. " to " .. value)
						self:autotalents()[item.index].usetype = value
						self:generateList()
					end)
				game:registerDialog(d2)
			end},
			{name="Select Priority", action=function()
				game:registerDialog(GetQuantity.new("Enter priority value", "Higher = use first",
					item.priority, nil, function(value)
					print("[SKOOBOT] [TalentDialog] Changing priority for " .. item.name .. " to " .. tostring(value))
					self:autotalents()[item.index].priority = value
					self:generateList()
				end), 1)
			end},
			{name="Remove Entry", action=function()
				table.remove(self:autotalents(), item.index)
				self:generateList()
			end},
		})
		game:registerDialog(d)
	end
end

function _M:select(item)
	if item then
		self.c_desc:switchItem(item, item.desc)
	end
end

function _M:generateList()
	local list = {}
	skoobot_reclauded.talents.prune()
	for index, info in ipairs(self:autotalents()) do
		local t = game.player:getTalentFromId(info.tid)
		if t.mode ~= "passive" and t.hide ~= "true" then
			list[#list + 1] = {
				id=#list + 1,
				index=index,
				name=t.name:capitalize(),
				tid=info.tid,
				usetype=info.usetype,
				priority=info.priority,
				desc=self.actor:getTalentFullDescription(t),
			}
		end
	end

	list[#list + 1] = {
		id=#list + 1, name="#GOLD#Add a new talent...",
		desc="Select this option to add a new skill to the bot's repertoire.",
		usetype="", priority="", addnew=true,
	}

	local chars = {}
	for i, v in ipairs(list) do
		v.char = self:makeKeyChar(i)
		chars[self:makeKeyChar(i)] = i
	end
	list.chars = chars

	self.list = list
	self.c_list:setList(list)
end
