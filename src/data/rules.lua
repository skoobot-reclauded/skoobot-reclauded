-- SkooBot: Reclauded -- the talent rules: what the bot may use, in which role,
-- in what order.
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
-- A PURE MODULE (#56): no globals, no ToME API. Every function takes the
-- rules table -- the saved `player.skoobot_reclauded.autotalents` -- and
-- plain values, so spec/rules_spec.lua can test it without a running game.
-- Anything that needs the actor (is this talent sustained? which item does
-- this name resolve to?) is passed in as a value or a function.
--
-- Shape:
--
--   { Combat = { entry, ... }, DamagePrevention = { ... },
--     Recovery = { ... },      Sustain = { ... } }
--
-- An entry is {tid = "T_..."} for a talent, or {object = "<item name>"} for an
-- activatable item -- items are keyed by name, the way ToME's own inventory
-- hotkeys are, because their talent id is a rotating slot (#55). Order within
-- a section IS priority: the first entry is tried first. A rule appears at
-- most once in a section, but may be in several sections -- a healing
-- infusion as both Damage Prevention and Recovery, as v1 allowed (owner test
-- of #56). Each placement is its own table, so extra fields on an entry stay
-- with that placement; a later per-rule flag (#15's "hold while impaired")
-- needs no migration.
--
-- v1, and the port until #56, saved a flat list of {tid=, usetype=, priority=}
-- in the same field. normalize() migrates that in place, once.

local M = {}

M.SECTIONS = { "Combat", "DamagePrevention", "Recovery", "Sustain" }

M.LABELS = {
    Combat           = "Combat",
    DamagePrevention = "Damage Prevention",
    Recovery         = "Recovery",
    Sustain          = "Sustain",
}

-- What the act loop does with each section. Shown on the section header.
M.DESCRIPTIONS = {
    Combat = "The rotation against a target. The first talent here that can be used on the chosen enemy "
        .. "is used, so the order is the priority.",
    DamagePrevention = "Used when a large slice of life was lost in a single turn. The first one off cooldown "
        .. "is used.",
    Recovery = "Used when enough life is missing. The first one off cooldown is used.",
    Sustain = "Kept active. Any of these that is not up is activated before anything else is done.",
}

local SECTION_SET = {}
for _, s in ipairs(M.SECTIONS) do SECTION_SET[s] = true end

function M.isSection(name)
    return SECTION_SET[name] == true
end

--- The identity of an entry: what makes two entries the same rule.
-- @return a string, or nil for anything that is not a rule
function M.key(entry)
    if type(entry) ~= "table" then return nil end
    if type(entry.tid) == "string" and entry.tid ~= "" then return "tid:" .. entry.tid end
    if type(entry.object) == "string" and entry.object ~= "" then return "object:" .. entry.object end
    return nil
end

function M.same(a, b)
    local ka = M.key(a)
    return ka ~= nil and ka == M.key(b)
end

--- An empty rules table in the current shape.
function M.new()
    local r = {}
    for _, s in ipairs(M.SECTIONS) do r[s] = {} end
    return r
end

--- May an entry of this kind live in this section?
-- @param kind "sustained" for a sustained talent; anything else ("activated",
--   "object") for one that is fired
-- @return true, or false and the reason in words
function M.allowed(kind, section)
    if not SECTION_SET[section] then return false, "No such section." end
    if kind == "sustained" then
        if section == "Sustain" then return true end
        return false, "A sustained talent can only go in Sustain: used anywhere else, it would be switched off."
    end
    if section == "Sustain" then
        return false, "Only sustained talents go in Sustain."
    end
    return true
end

--- Index of a rule within one section, or nil.
function M.indexIn(t, section, entry)
    local k = M.key(entry)
    local list = k and t[section]
    if not list then return nil end
    for i, e in ipairs(list) do
        if M.key(e) == k then return i end
    end
    return nil
end

--- Every placement of a rule, in section order.
-- @return a list of {section=, index=}
function M.where(t, entry)
    local out = {}
    for _, s in ipairs(M.SECTIONS) do
        local i = M.indexIn(t, s, entry)
        if i then out[#out + 1] = { section = s, index = i } end
    end
    return out
end

--- Bring a saved table to the current shape, IN PLACE, so that anything
--- already holding it sees the result. Idempotent.
--
-- Handles: nil or a non-table (a fresh table is returned); a fresh or current
-- table (untouched); a v1 flat list; and a current table with v1-shaped
-- entries pushed into its array part, which is what a scenario that predates
-- #56 does. v1 entries are placed by their usetype, highest priority first
-- (ties keep their saved order), minus usetype and priority. Within a section
-- a rule is kept once -- the first occurrence, i.e. the highest priority --
-- and a rule may land in several sections. Entries with no identity, an
-- unknown usetype, or the add chain's `usetype=""` placeholder are dropped.
--
-- @return the table, and {migrated = n, dropped = n}
function M.normalize(t)
    local report = { migrated = 0, dropped = 0 }
    if type(t) ~= "table" then t = {} end
    for _, s in ipairs(M.SECTIONS) do
        if type(t[s]) ~= "table" then t[s] = {} end
    end

    -- Lift the array part out before anything else.
    local old = {}
    for i, v in ipairs(t) do old[#old + 1] = { i = i, v = v } end
    for i = #t, 1, -1 do t[i] = nil end

    local function prio(o)
        return type(o.v) == "table" and tonumber(o.v.priority) or 0
    end
    table.sort(old, function(a, b)
        local pa, pb = prio(a), prio(b)
        if pa ~= pb then return pa > pb end
        return a.i < b.i
    end)

    for _, s in ipairs(M.SECTIONS) do
        local list = t[s]
        local seen, kept = {}, {}
        for _, e in ipairs(list) do
            local k = M.key(e)
            if k and not seen[k] then
                seen[k] = true
                kept[#kept + 1] = e
            else
                report.dropped = report.dropped + 1
            end
        end
        for i = #list, 1, -1 do list[i] = nil end
        for i, e in ipairs(kept) do list[i] = e end
    end

    for _, o in ipairs(old) do
        local v = o.v
        local k = M.key(v)
        local s = type(v) == "table" and v.usetype
        if k and SECTION_SET[s] and not M.indexIn(t, s, v) then
            local e = {}
            for field, value in pairs(v) do
                if field ~= "usetype" and field ~= "priority" then e[field] = value end
            end
            local list = t[s]
            list[#list + 1] = e
            report.migrated = report.migrated + 1
        else
            report.dropped = report.dropped + 1
        end
    end

    return t, report
end

--- Take a rule out of one section.
-- @return the stored entry and its index; or nil
function M.remove(t, entry, section)
    local i = M.indexIn(t, section, entry)
    if not i then return nil end
    return table.remove(t[section], i), i
end

--- Take a rule out of every section.
-- @return how many placements went
function M.removeAll(t, entry)
    local n = 0
    for _, s in ipairs(M.SECTIONS) do
        if M.remove(t, entry, s) then n = n + 1 end
    end
    return n
end

--- Put a rule in `section`: before `before` (an entry of that section), or at
--- the end. If `from` names a section, the rule leaves it -- a move; without
--- `from` the rule keeps its other placements -- an add, which is how the
--- same talent gets into two sections. Within `section` a rule is placed
--- once: if it is already there and no position is asked for, it stays where
--- it is; with `before` it is repositioned. The stored table is what moves,
--- so extra fields on it survive a move.
-- @return the index it is at; or nil and a reason
function M.place(t, entry, section, before, from)
    if not SECTION_SET[section] then return nil, "No such section." end
    local k = M.key(entry)
    if not k then return nil, "Not a rule." end
    local moved
    if from and from ~= section and SECTION_SET[from] then moved = M.remove(t, entry, from) end
    local idx = M.indexIn(t, section, entry)
    if idx and (not before or M.key(before) == k) then return idx end
    local here = idx and table.remove(t[section], idx) or nil
    local e = here or moved or entry
    local list = t[section]
    local at = #list + 1
    if before then
        local bk = M.key(before)
        for i, x in ipairs(list) do
            if M.key(x) == bk then at = i break end
        end
    end
    table.insert(list, at, e)
    return at
end

--- Move a rule within one section by `delta` places, clamped to the ends.
-- @return the new index; or nil if the rule is not in that section
function M.shift(t, entry, section, delta)
    local i = M.indexIn(t, section, entry)
    if not i then return nil end
    local list = t[section]
    local j = i + (delta or 0)
    if j < 1 then j = 1 elseif j > #list then j = #list end
    if j ~= i then
        table.insert(list, j, table.remove(list, i))
    end
    return j
end

--- Drop every placement for which keep(entry, section) is false.
-- @return the removed entries
function M.prune(t, keep)
    local removed = {}
    for _, s in ipairs(M.SECTIONS) do
        local list = t[s]
        for i = #list, 1, -1 do
            if not keep(list[i], s) then removed[#removed + 1] = table.remove(list, i) end
        end
    end
    return removed
end

--- The talent ids of one section, in order, skipping what does not resolve.
-- @param resolve optional function(entry) -> tid or nil; by default the
--   entry's own tid (so item entries are skipped)
function M.tids(t, section, resolve)
    local out = {}
    for _, e in ipairs(t[section] or {}) do
        local tid
        if resolve then tid = resolve(e) else tid = e.tid end
        if tid then out[#out + 1] = tid end
    end
    return out
end

--- How many placements there are, over every section.
function M.count(t)
    local n = 0
    for _, s in ipairs(M.SECTIONS) do n = n + #(t[s] or {}) end
    return n
end

return M
