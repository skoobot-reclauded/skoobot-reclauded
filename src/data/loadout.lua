-- SkooBot: Reclauded -- loadout discovery: a suggested set of talent rules,
-- read off the game's own talent metadata.
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
-- A PURE MODULE (#18), the data/rules.lua pattern: no globals, no ToME API.
-- The caller hands in plain tables and gets a PROPOSAL back; nothing is
-- written until apply() is asked to, and apply() writes through data/rules.lua,
-- which is passed in rather than loaded here. spec/loadout_spec.lua runs all
-- of it without a game.
--
-- Why this can work at all: the NPC AI has this bot's problem -- which of an
-- actor's talents attack, heal, defend, buff -- and ToME answers it with data.
-- Every talent the NPC AI may use carries a `tactical` table
-- (mod/class/interface/ActorAI.lua, "TALENT TACTICAL TABLES"): `{ ATTACK =
-- { weapon = 2 }, DISABLE = { stun = 2 } }`, `{ DEFEND = 2 }`, `{ HEAL = 2 }`.
-- 86% of 1.7.6's non-passive talents have one; most of the rest are
-- `no_npc_use`, the game's own "not for an AI" flag. The keys are language-
-- independent and discovery iterates talents by id, so "must key on talent
-- IDs" holds by construction. Note that the tome module LOWERCASES the keys
-- when it loads a talent (data/talents.lua aiLowerTacticals), so a definition
-- read at runtime says `attack` where the data file says `ATTACK`; both are
-- accepted here.
--
-- The rule, applied in order to every talent the character knows:
--
--   1  mode == "passive"                      ignored
--   2  no_npc_use or no_dumb_use              skipped: the game says an AI must not drive it
--   3  no tactical table                      unassigned, "no tactical data"
--   4  mode == "sustained"                    Sustain
--   5  tactical is a function                 called once with no target; a table back is
--                                             used; nothing back and requires_target -> Combat,
--                                             else unassigned
--   6  ATTACK / ATTACKAREA / DISABLE          Combat (CLOSEIN beside an attack lands here; so
--                                             does Block, ATTACK = 3, DEFEND = 3)
--   7  HEAL                                   Recovery
--   8  DEFEND                                 Damage Prevention
--   9  anything else                          unassigned, and the reason says which key
--
-- Step 9 is deliberate, and stated to the player rather than guessed at:
-- ESCAPE talents would fire as attacks, since the bot has no flee behaviour;
-- SPECIAL is Shoot Down and friends (ZarakiSama's 2020 "used shoot down for
-- no reason"); an activated BUFF belongs in a rotation only as an opener.
--
-- Four guards, each backed by a data field:
--
-- * `sustain_slots` groups mutually exclusive sustains -- the three chants,
--   the three hymns -- which a naive list would toggle against each other
--   forever. At most one per group is placed, and only with a reason the data
--   gives (it is the one already active, or the one with the highest level);
--   otherwise none, and the group is listed as a CHOICE for the player.
-- * `hide` is read, not filtered on: a hidden talent (the chants are) stays in
--   the proposal and is marked.
-- * `on_pre_use` is NOT evaluated here. 144 Combat talents need a shield or a
--   two-hander; discovery is a snapshot with no target and possibly no weapon
--   yet, so they are included and the act loop's own filter (#5) refuses them
--   turn by turn. They are marked "conditional".
-- * a function-form `tactical` (Sun Ray) needs a target; hence step 5.
--
-- Priority within a section is COOLDOWN DESCENDING, ties by the tactical
-- weight sum: long-cooldown hitters sit at the top so they fire the moment
-- they are available and the rotation falls through to the spammable fillers.
-- Tactical weights alone are coarse (1-3) and rank badly.
--
-- Validation: run over mishander's hand-tuned Sun Paladin build (the rejected
-- preset, docs/salvage-mishander.md item 12), this reproduces 13 of its 14
-- placements from metadata alone; the 14th, Infusion: Regeneration, they put
-- under Damage Prevention and the data (HEAL) says Recovery. That fixture is
-- in spec/loadout_spec.lua.

local M = {}

-- The four sections, as data/rules.lua names them.
local COMBAT, PREVENTION, RECOVERY, SUSTAIN = "Combat", "DamagePrevention", "Recovery", "Sustain"
M.SECTIONS = { COMBAT, PREVENTION, RECOVERY, SUSTAIN }

-- Tactic keys, lower-case, as the loaded talent carries them.
local COMBAT_KEYS = { attack = true, attackarea = true, disable = true }

-- Why a key that is not mapped stays out, in words for the player.
local UNMAPPED = {
    escape  = "ESCAPE: the bot has no flee behaviour, so in Combat this would fire as an attack",
    closein = "CLOSEIN only: the bot walks to its target itself",
    buff    = "BUFF on an activated talent: an opener, not a rotation entry",
    special = "SPECIAL: the game does not say what it is for",
    cure    = "CURE: not a role the bot has",
    protect = "PROTECT: not a role the bot has",
    surrounded = "SURROUNDED: not a role the bot has",
    ammo    = "AMMO: not a role the bot has",
}

local function isTable(v) return type(v) == "table" end

--- #98: can the weapon in the main hand make a melee attack at all?
---
--- A bow or a sling attacks through its ammunition, with T_SHOOT; swung as
--- a club it is feeble, and the game gates most melee talents behind a
--- melee weapon anyway. Proposing *Attack* to an Archer is therefore a
--- visibly wrong recommendation on the first screen a new player sees --
--- which is the whole cost, since at runtime the talent would simply be
--- refused and the rotation would fall through.
---
--- Keyed on the weapon, not on the class: there is no list of "ranged
--- classes" that survives contact with ToME's build variety, and the owner
--- said as much when asking for this. A Sun Paladin with a staff is in
--- melee on purpose, and a staff is not archery, so nothing here touches
--- them.
local ARCHERY_SUBTYPE = { bow = true, sling = true }

--- Is this proposed talent a melee attack the main hand cannot deliver?
---
--- FAILS SAFE. Only a talent whose range is KNOWN and is 1 or less counts
--- as melee: a nil range means the caller did not supply one, and guessing
--- "melee" there would quietly drop a ranged talent from the proposal,
--- which is a worse failure than the one being fixed.
local function meleeWithoutAMeleeWeapon(e, opts)
    local mh = opts and opts.mainhand
    if not isTable(mh) then return nil end
    if not (mh.archery or ARCHERY_SUBTYPE[tostring(mh.subtype)]) then return nil end
    local rng = tonumber((e.t or {}).range)
    if not rng or rng > 1 then return nil end
    return ("you are holding %s, which cannot make a melee attack"):format(
        tostring(mh.name or mh.subtype or "a ranged weapon"))
end

--- A tactical table with lower-cased keys and the `self` sub-table folded
--- in: the runtime form is already lower-case; a data-file form or a fixture
--- may not be.
local function normalizeTactical(tac)
    local out = {}
    for k, v in pairs(tac) do
        if type(k) == "string" then
            local lk = k:lower()
            if lk == "self" and isTable(v) then
                for k2, v2 in pairs(normalizeTactical(v)) do
                    if out[k2] == nil then out[k2] = v2 end
                end
            else
                out[lk] = v
            end
        end
    end
    return out
end

--- The sum of every number in a weight, recursing into tables; a function
--- counts one -- an unknown but positive weight -- and anything else nothing.
local function weightSum(v)
    if type(v) == "number" then return v end
    if type(v) == "function" then return 1 end
    if not isTable(v) then return 0 end
    local n = 0
    for _, x in pairs(v) do n = n + weightSum(x) end
    return n
end

local function keysOf(tac)
    local ks = {}
    for k in pairs(tac) do ks[#ks + 1] = k end
    table.sort(ks)
    return ks
end

local function upperList(keys)
    local out = {}
    for i, k in ipairs(keys) do out[i] = tostring(k):upper() end
    return table.concat(out, ", ")
end

--- Resolve a talent's tactical data to a table, or say why not.
-- @return table | nil, reason
local function resolveTactical(t, opts)
    local tac = t.tactical
    if tac == nil then return nil, "no tactical data" end
    if type(tac) == "function" then
        local ok, res = pcall(tac, opts.self, t, nil)
        if ok and isTable(res) then return normalizeTactical(res) end
        return nil, "function"
    end
    if isTable(tac) then return normalizeTactical(tac) end
    return nil, "no tactical data"
end

local function cooldownOf(t)
    local cd = t.cooldown
    if type(cd) == "number" then return cd end
    return 0
end

--- Classify one talent. `e` is {tid=, t=, level=, active=, name=}.
-- @return "entry"|"unassigned"|"skipped"|"ignored", record
local function classify(e, opts)
    local t = e.t or {}
    local mode = t.mode or "activated"
    local tags = {}
    if t.hide then tags[#tags + 1] = "hidden" end
    if t.on_pre_use ~= nil then tags[#tags + 1] = "conditional" end

    local function rec(section, why, tac)
        local r = {
            tid = e.tid, name = e.name or e.tid, section = section, reason = why,
            hidden = t.hide and true or false,
            conditional = t.on_pre_use ~= nil,
            cooldown = cooldownOf(t),
            weight = tac and weightSum(tac) or 0,
            slot = t.sustain_slots,
            level = tonumber(e.level) or 0,
            active = e.active and true or false,
            -- #98: kept so the proposal can tell a character that fights at
            -- range from one that does not, without knowing any class.
            range = tonumber(t.range),
        }
        if #tags > 0 then r.reason = r.reason .. " (" .. table.concat(tags, ", ") .. ")" end
        return r
    end

    if mode == "passive" then return "ignored" end
    if t.no_npc_use or t.no_dumb_use then
        return "skipped", rec(nil, t.no_npc_use and "the game marks it no_npc_use: not for an AI"
            or "the game marks it no_dumb_use: not for an AI")
    end

    local tac, why = resolveTactical(t, opts)
    if not tac and why == "no tactical data" then return "unassigned", rec(nil, "no tactical data") end

    if mode == "sustained" then
        return "entry", rec(SUSTAIN, "sustained" .. (tac and ("; " .. upperList(keysOf(tac))) or ""), tac)
    end

    if not tac then
        -- a function that gave nothing without a target
        if t.requires_target then
            return "entry", rec(COMBAT, "tactical data needs a target, and the talent requires one", nil)
        end
        return "unassigned", rec(nil, "tactical data needs a live target to evaluate")
    end

    local keys = keysOf(tac)
    local hasCombat, hasHeal, hasDefend = false, false, false
    for _, k in ipairs(keys) do
        if COMBAT_KEYS[k] then hasCombat = true end
        if k == "heal" then hasHeal = true end
        if k == "defend" then hasDefend = true end
    end
    local cd = cooldownOf(t)
    local cdText = cd > 0 and ("; cooldown " .. tostring(cd)) or "; no cooldown"
    if hasCombat then
        -- #98: right role, wrong hands.
        local wrongHands = meleeWithoutAMeleeWeapon(e, opts)
        if wrongHands then return "unassigned", rec(nil, upperList(keys) .. "; " .. wrongHands) end
        return "entry", rec(COMBAT, upperList(keys) .. cdText, tac)
    end
    if hasHeal then return "entry", rec(RECOVERY, upperList(keys) .. cdText, tac) end
    if hasDefend then return "entry", rec(PREVENTION, upperList(keys) .. cdText, tac) end

    -- Step 9: say which key kept it out.
    local reasons = {}
    for _, k in ipairs(keys) do
        if UNMAPPED[k] then reasons[#reasons + 1] = UNMAPPED[k] end
    end
    if #reasons == 0 then
        reasons[1] = upperList(keys) .. ": a resource or an unknown key, not a role the bot has"
    end
    return "unassigned", rec(nil, table.concat(reasons, "; "))
end

--- #98: a character the suggestion arms with a RANGED attack is a
--- character that wants somewhere to stand.
---
--- The owner's ask: "anyone with shoot as a part of their recommendation
--- should also come with flee but keep LOS". Keyed on the talents the
--- suggestion itself placed, not on the class and not on the weapon --
--- which is option 2 of #98 in its simplest form, and the reason it is not
--- much of a band-aid: a Combat rotation that reaches past arm's length IS
--- the evidence that the character fights at range. The Sun-Paladin-with-a-
--- staff case that makes weapon and class tests fail does not arise, because
--- that character has no ranged attack to trigger it.
---
--- It goes LAST in Combat, under every attack. Above them the bot would
--- back away before shooting; below, it is what the row is for -- the thing
--- to do when nothing else can be done this turn.
---
--- Depends on #97 being fixed: before that, this row looped forever against
--- an immobile enemy out of talent range, and suggesting it to every ranged
--- character would have shipped that loop to all of them.
local FLEE_KEEP_LOS = { action = "flee", from = "nearest", keep_los = true }

local function wantsFleeRow(combatEntries)
    for _, e in ipairs(combatEntries) do
        local r = tonumber(e.range)
        if r and r > 1 then return true, e end
    end
    return false
end

--- The rules-table shape of a proposed entry: a talent id, or an action.
--- One place, so a caller cannot half-support the action rows.
function M.entryOf(e)
    if e.action then
        return { action = e.action, from = e.from, keep_los = e.keep_los }
    end
    return { tid = e.tid }
end

--- Priority numbers with gaps, 100 downwards, so hand edits fit between.
local function priorities(n)
    local step = n <= 10 and 10 or math.max(1, math.floor(100 / n))
    local out = {}
    for i = 1, n do out[i] = 100 - step * (i - 1) end
    return out
end

--- #85 item 4: invested points are a signal of what the player cares
--- about, so within a cooldown band a talent at 4/5 sits above one at 1/5.
--- Level goes BETWEEN cooldown and the tactical weight: cooldown stays the
--- first key because it is about tempo -- a long cooldown wants firing
--- first or it never fires -- and the weight stays last because it is the
--- game's guess where level is the player's own.
local function byPriority(a, b)
    if a.cooldown ~= b.cooldown then return a.cooldown > b.cooldown end
    if (a.level or 0) ~= (b.level or 0) then return (a.level or 0) > (b.level or 0) end
    if a.weight ~= b.weight then return a.weight > b.weight end
    return tostring(a.tid) < tostring(b.tid)
end

--- Apply the sustain_slots guard to the Sustain entries: at most one per
--- group, and only for a reason the data gives.
-- @return the entries kept, and the choices {slot=, tids=, names=}
local function resolveSlots(entries)
    local groups, order = {}, {}
    local kept = {}
    for _, e in ipairs(entries) do
        if e.section == SUSTAIN and e.slot then
            if not groups[e.slot] then groups[e.slot] = {} order[#order + 1] = e.slot end
            local g = groups[e.slot]
            g[#g + 1] = e
        else
            kept[#kept + 1] = e
        end
    end
    local choices = {}
    for _, slot in ipairs(order) do
        local g = groups[slot]
        local pick, why
        if #g == 1 then
            pick = g[1]
        else
            local active
            for _, e in ipairs(g) do
                if e.active then
                    if active then active = false break end
                    active = e
                end
            end
            if active then
                pick, why = active, "the one already active"
            else
                local best, tie = nil, false
                for _, e in ipairs(g) do
                    if not best or e.level > best.level then best, tie = e, false
                    elseif e.level == best.level then tie = true end
                end
                if best and not tie and best.level > 0 then pick, why = best, "the highest level in its group" end
            end
        end
        if pick then
            if why then pick.reason = pick.reason .. "; one of " .. #g .. " in the " .. slot .. " group, " .. why end
            kept[#kept + 1] = pick
        else
            local tids, names = {}, {}
            for i, e in ipairs(g) do tids[i] = e.tid names[i] = e.name end
            choices[#choices + 1] = { slot = slot, tids = tids, names = names,
                reason = "mutually exclusive sustains (" .. slot
                    .. "): the data gives no reason to prefer one -- pick one by hand" }
        end
    end
    return kept, choices
end

--- Discover a loadout.
-- @param talents a list of {tid=, t=<talent def or the plain fields of one>,
--   level=<talent level>, active=<is the sustain up>, name=<display name>}
-- @param opts optional: self = the actor handed to a function-form tactical;
--   mainhand = {name=, subtype=, archery=} for the weapon in the main hand,
--   which decides whether a melee attack is worth proposing at all (#98)
-- @return a proposal:
--   entries    {tid, name, section, priority, reason, hidden, conditional, cooldown}
--              in section order, then priority order
--   unassigned {tid, name, reason}   known, usable, but in no section; the reason says why
--   skipped    {tid, name, reason}   the game says an AI must not use these
--   choices    {slot, tids, names, reason}   sustain groups the player must pick from
--   counts     {entries=, unassigned=, skipped=, choices=}
function M.discover(talents, opts)
    opts = opts or {}
    local declined = isTable(opts.declined) and opts.declined or {}
    local entries, unassigned, skipped = {}, {}, {}
    for _, e in ipairs(talents or {}) do
        if type(e) == "table" and e.tid then
            local kind, r = classify(e, opts)
            -- #85 item 2: a talent the player has said no to before is still
            -- classified and still shown, marked, rather than hidden. Hiding
            -- it would mean a declined talent silently disappearing from a
            -- screen whose whole job is to say what the bot would do -- and
            -- would leave no way to change one's mind.
            if r and declined[r.tid] then r.declined = true end
            if kind == "entry" then entries[#entries + 1] = r
            elseif kind == "unassigned" then unassigned[#unassigned + 1] = r
            elseif kind == "skipped" then skipped[#skipped + 1] = r end
        end
    end

    local kept, choices = resolveSlots(entries)

    local bySection = {}
    for _, s in ipairs(M.SECTIONS) do bySection[s] = {} end
    for _, e in ipairs(kept) do
        local list = bySection[e.section]
        list[#list + 1] = e
    end
    local out = {}
    for _, s in ipairs(M.SECTIONS) do
        local list = bySection[s]
        table.sort(list, byPriority)
        -- #98: after the sort, so it is last whatever the attacks look like.
        if s == COMBAT and not opts.no_flee_row then
            local wants, why = wantsFleeRow(list)
            if wants then
                list[#list + 1] = {
                    action = FLEE_KEEP_LOS.action, from = FLEE_KEEP_LOS.from,
                    keep_los = FLEE_KEEP_LOS.keep_los, section = COMBAT,
                    name = "Flee but keep sight",
                    reason = ("you fight at range (%s reaches %d), so this backs off without breaking sight"):format(
                        tostring(why.name or why.tid), tonumber(why.range) or 0),
                    cooldown = 0, weight = 0, level = 0,
                }
            end
        end
        local prio = priorities(#list)
        for i, e in ipairs(list) do
            e.priority = prio[i]
            out[#out + 1] = e
        end
    end
    table.sort(unassigned, function(a, b) return tostring(a.tid) < tostring(b.tid) end)
    table.sort(skipped, function(a, b) return tostring(a.tid) < tostring(b.tid) end)

    return {
        entries = out, unassigned = unassigned, skipped = skipped, choices = choices,
        counts = { entries = #out, unassigned = #unassigned, skipped = #skipped, choices = #choices },
    }
end

--- The proposed entries whose talent is in no section at all: what Merge
--- would add, and the number the talent screen shows.
-- @param rm the data/rules.lua module
function M.unplaced(proposal, rules, rm)
    local out = {}
    for _, e in ipairs(proposal and proposal.entries or {}) do
        if #rm.where(rules, M.entryOf(e)) == 0 then out[#out + 1] = e end
    end
    return out
end

--- Write a proposal into a rules table, through data/rules.lua.
--
-- "merge" (the default) keeps every row the player placed. A talent that has
-- a row without the `suggested` mark in any section is the player's decision:
-- none of its rows are touched, wherever the proposal would put it. Rows that
-- still carry the mark are discovery's own -- the talent screen clears it the
-- moment a row is moved by hand -- and those for talents the player has not
-- decided about are rewritten from the fresh proposal, after the hand rows, so
-- a talent learned since the last run lands among them in priority order
-- rather than at the bottom. Re-running is therefore idempotent.
--
-- "replace" empties every section first. The caller asks for confirmation
-- before calling with it when the table is not empty; this function does not.
--
-- Every row written carries suggested = true.
-- @param rm the data/rules.lua module
-- @return {added=, removed=, kept=}
function M.apply(proposal, rules, rm, mode)
    mode = mode or "merge"
    local report = { added = 0, removed = 0, kept = 0, declined = 0, mode = mode }
    local hand = {}
    if mode == "replace" then
        for _, s in ipairs(rm.SECTIONS) do
            local list = rules[s]
            report.removed = report.removed + #list
            for i = #list, 1, -1 do list[i] = nil end
        end
    else
        for _, s in ipairs(rm.SECTIONS) do
            for _, e in ipairs(rules[s] or {}) do
                if e.tid and not e.suggested then hand[e.tid] = true end
            end
        end
        local gone = rm.prune(rules, function(e) return not e.suggested or (e.tid and hand[e.tid] == true) end)
        report.removed = #gone
    end
    for _, e in ipairs(proposal and proposal.entries or {}) do
        if e.declined then
            -- #85 item 2: shown, never written. Declining is the player's
            -- decision and applying the proposal must not quietly undo it.
            report.declined = (report.declined or 0) + 1
        elseif hand[e.tid] then
            report.kept = report.kept + 1
        else
            local placement = M.entryOf(e)
            placement.suggested = true
            local at = rm.place(rules, placement, e.section)
            if at then report.added = report.added + 1 end
        end
    end
    return report
end

return M
