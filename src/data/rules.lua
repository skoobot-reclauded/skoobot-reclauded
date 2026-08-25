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
-- A PURE MODULE (#56): no globals, no ToME API. Every function takes the rules
-- table -- the saved `player.skoobot_reclauded.autotalents` -- and plain
-- values, so spec/rules_spec.lua can test it without a running game. Anything
-- that needs the actor arrives as a value or a function.
--
-- Shape:
--
--   { Combat = { entry, ... }, DamagePrevention = { ... },
--     Recovery = { ... },      Sustain = { ... } }
--
-- An entry is {tid = "T_..."} for a talent, {object = "<item name>"} for an
-- activatable item -- keyed by NAME, the way ToME's own inventory hotkeys are,
-- because the talent id is a rotating slot (#55) -- or {action = "flee",
-- from = "nearest" | "strongest", keep_los = true?} for a built-in action
-- (#59, #69). The kind is discriminated by which field is set, so a later
-- built-in action needs no migration either.
--
-- Order within a section IS priority: the first entry is tried first. A rule
-- appears at most once in a section, but may be in several -- a healing
-- infusion as both Damage Prevention and Recovery, as v1 allowed. Each
-- placement is its own table, since place() copies on an add, so extra fields
-- stay with that placement: `hold = true` (#15, "hold while impaired") is such
-- a field and means something only in Combat.
--
-- v1, and the port until #56, saved a flat list of {tid=, usetype=, priority=}
-- in the same field. normalize() migrates that in place, once.

local M = {}

M.SECTIONS = { "Combat", "DamagePrevention", "Recovery", "Sustain" }

-- The `from` a flee action may name. A flee is one step away from that
-- hostile; "strongest" is by the bot's own power figure, ties by distance.
M.FLEE_FROM = { "nearest", "strongest" }
local FLEE_FROM_SET = {}
for _, f in ipairs(M.FLEE_FROM) do FLEE_FROM_SET[f] = true end

-- The built-in actions the talent screen lists beside the character's talents
-- (#59). Fixed prose: an action has no talent description to show.

-- What a blocked flee does when there is nothing else placed (#67). One
-- sentence, shared by both rows, so the two cannot drift apart.
M.CORNERED_LABEL =
    "A flee does not stop the bot by itself -- unless it is the whole rotation: cornered with no talent "
 .. "placed below it, the bot hands back saying so rather than walking into the thing it was told to run "
 .. "from. It is also skipped when the thing it would run from CANNOT MOVE and is not already next to you "
 .. "(#97): something that cannot follow you is not worth stepping away from, and doing it anyway made the "
 .. "bot retreat and close the distance on alternate turns forever. Standing next to one is the exception, "
 .. "since that is where it can reach you."

M.ACTIONS = {
    { action = "flee", from = "nearest",
      name = "Flee from the nearest hostile",
      desc = "One step away from the nearest hostile in view, then the turn ends. The step is the neighbouring "
          .. "grid that hostile has the least sight of -- out of its view if there is one, else simply farther "
          .. "from it. Where the rotation reaches this is when it fires: first in Combat, the character backs away "
          .. "whenever anything is in view; last, it is what the bot does when nothing else can be used. When no "
          .. "such step exists the rotation moves on as if a talent were on cooldown. " .. M.CORNERED_LABEL },
    { action = "flee", from = "strongest",
      name = "Flee from the strongest hostile",
      desc = "One step away from the strongest hostile in view -- the highest COUNTED power, the figure after "
          .. "\"counts as\" in the Ctrl-hover tooltip, which is what the power-level stops and the bot's threat "
          .. "score compare; nearest on a tie -- then the turn ends. That is a rank-weighted figure, so a boss "
          .. "outranks a tougher-looking common. The step is the neighbouring grid that hostile has the least "
          .. "sight of -- out of its view if there is one, else simply farther from it. Where the rotation "
          .. "reaches this is when it fires. When no such step exists the rotation moves on as if a talent were "
          .. "on cooldown. Both flee rows may be placed: \"from the strongest, failing that from the nearest\" "
          .. "is a legitimate rotation. " .. M.CORNERED_LABEL },
    { action = "flee", from = "nearest", keep_los = true,
      name = "Flee but keep sight",
      desc = "One step away from the nearest hostile in view that still leaves it in sight, then the turn ends. "
          .. "For a character who fights at range: the plain flee happily steps behind a tree, which is a wasted "
          .. "turn if the next thing in the rotation is a bolt. Among the neighbouring grids that keep line of "
          .. "sight to that hostile, the one it has the least sight of wins, the same rule the other two use -- so "
          .. "this backs away along the open ground rather than out of the fight. When no such step exists the "
          .. "rotation moves on as if a talent were on cooldown; place a plain flee under this one to break sight "
          .. "as a second choice. " .. M.CORNERED_LABEL },
}

-- What the hold flag means, for the row that carries it (#15). The act loop
-- reads `entry.hold` on Combat entries only; this is the prose the talent
-- screen shows beside the toggle.
M.HOLD_LABEL = "hold while impaired"
M.HOLD_DESCRIPTION = "Hold while impaired: while the character is stunned, dazed, confused or frozen this entry is "
    .. "skipped as if it were on cooldown and the rotation falls through to the next one -- so a long-cooldown hit "
    .. "is not spent at half damage and is ready when the impairment lifts. This only matters to a player who has "
    .. "set the STUNNED, DAZED, CONFUSED or FROZEN stop conditions to WARN or IGNORE: at STOP the bot hands back "
    .. "before the rotation runs. On the impairment's last turn the entry is not held: there is nothing left to "
    .. "wait out. Combat only."

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

--- Is this entry a built-in action (#59)? Only a flee with a known `from`
--- counts: an action the module does not know is not a rule at all.
function M.isAction(entry)
    return type(entry) == "table" and entry.action == "flee" and FLEE_FROM_SET[entry.from] == true
end

--- The identity of an entry: what makes two entries the same rule.
--- @return a string, or nil for anything that is not a rule
function M.key(entry)
    if type(entry) ~= "table" then return nil end
    if type(entry.tid) == "string" and entry.tid ~= "" then return "tid:" .. entry.tid end
    if type(entry.object) == "string" and entry.object ~= "" then return "object:" .. entry.object end
    -- #69: keep_los is part of the IDENTITY, unlike `hold` (#15), which is a
    -- flag on a placement. "Flee but keep sight" is its own row in Available
    -- and may sit in the rotation alongside the plain flee -- keep sight
    -- first, break it as a second choice -- so the two must not key alike.
    if M.isAction(entry) then
        return "action:" .. entry.action .. ":" .. entry.from .. (entry.keep_los and ":los" or "")
    end
    return nil
end

--- The fixed name and description of a built-in action, or nil.
function M.describeAction(entry)
    if not M.isAction(entry) then return nil end
    local los = entry.keep_los and true or false
    for _, a in ipairs(M.ACTIONS) do
        if a.action == entry.action and a.from == entry.from and (a.keep_los and true or false) == los then
            return a
        end
    end
    return nil
end

--- A fresh entry for a built-in action row: a copy, never the table in
--- M.ACTIONS, so a placement can carry its own fields.
function M.actionEntry(a)
    return { action = a.action, from = a.from, keep_los = a.keep_los or nil }
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
-- @param kind "sustained" for a sustained talent; "action" for a built-in
--   action (#59), which is a move in the rotation and so Combat only;
--   anything else ("activated", "object") for one that is fired
-- @return true, or false and the reason in words
function M.allowed(kind, section)
    if not SECTION_SET[section] then return false, "No such section." end
    if kind == "sustained" then
        if section == "Sustain" then return true end
        return false, "A sustained talent can only go in Sustain: used anywhere else, it would be switched off."
    end
    if kind == "action" then
        if section == "Combat" then return true end
        return false, "A flee is a move in the combat rotation: it can only go in Combat."
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
-- Handles nil or a non-table, a fresh or current table, a v1 flat list, and a
-- current table with v1-shaped entries pushed into its array part (what a
-- scenario predating #56 does). v1 entries are placed by their usetype,
-- highest priority first, ties keeping their saved order, minus usetype and
-- priority. Within a section a rule is kept once -- the first occurrence --
-- and may land in several sections. Entries with no identity, an unknown
-- usetype, or the add chain's `usetype=""` placeholder are dropped.
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

--- A shallow copy of an entry: its own table, same fields.
local function copyEntry(entry)
    local e = {}
    for field, value in pairs(entry) do e[field] = value end
    return e
end

--- Put a rule in `section`: before `before` (an entry of that section), or at
--- the end. If `from` names a section the rule leaves it -- a move; without
--- `from` it keeps its other placements -- an add. Within `section` a rule is
--- placed once: already there with no position asked for, it stays; with
--- `before`, it is repositioned. The stored table is what moves, so extra
--- fields survive a move, and an add stores a COPY so two placements never
--- share a table -- the talent screen's "Also add to" hands over another
--- section's stored entry, and a field set in one must not appear in the other.
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
    local e = here or moved or copyEntry(entry)
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
