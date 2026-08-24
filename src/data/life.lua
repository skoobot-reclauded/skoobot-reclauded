-- SkooBot: Reclauded -- how much life there really is (#91).
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
-- `life / max_life` is not a life fraction in this game. A character dies at
-- `die_at` (engine/interface/ActorLife.lua:51), which moves both ways, and the
-- game's own bar measures over `max_life - die_at` (mod/class/Player.lua:390,
-- :465; uiset/Minimalist.lua:785) -- so a Lich at -500 read as 0% with five
-- hundred points still to spend. Every source of die_at and how far each can
-- be trusted is docs/api-surface-1.7.6.md, "die_at: zero is not where a
-- character dies"; the decision is #91.
--
-- Two figures come out. `fraction` is the game's own arithmetic -- what the
-- life bar shows. `safe_fraction` is what the bot decides on: the permanent
-- and sustained parts in full, every adverse part in full, and a temporary
-- part only while it lasts longer than the look-ahead. A character held above
-- death by an infusion about to lapse reads as empty, which is the point: the
-- bot hands back BEFORE the effect ends, not after.
--
-- Adverse is decided by the SIGN, never by the effect's `status` field. The
-- one adverse source in 1.7.6, UNRAVEL, is declared `status = "beneficial"`
-- and is -- it grants invulnerability -- so a reading that trusted `status`
-- would discount it.
--
-- What cannot be attributed lands in `permanent` and is trusted. That is
-- deliberate: the ordinary case -- a cloak, an artifact, a Lich -- is
-- unattributable and permanent, and treating it as untrustworthy would make
-- every such character read as nearly dead. The cost is that a future
-- temporary source using a mechanism not listed here would be over-trusted, so
-- `permanent` is returned for a probe to say what was assumed.
--
-- Pure: plain field reads over the actor, no engine calls and no globals, so
-- busted can hold it to its shape over a fake.

local M = {}

--- How far ahead a decision looks, in turns. A temporary source lasting
--- this long or less is not counted: the bot would rather stop a turn early
--- than a turn after the effect that was holding it up has gone.
M.LOOKAHEAD = 1

-- The timed effects of 1.7.6 that keep their die_at temporary-value id in a
-- field of their own, so `__tmpvals` does not record it. Keyed by the
-- effect definition's `name`.
local DIRECT_EFFECT_FIELD = {
    FRENZY       = "dieatid",   -- data/timed_effects/mental.lua:1765
    ROGUE_S_BREW = "die",       -- data/timed_effects/physical.lua:3528
}

-- The same for sustains, keyed by talent id.
local DIRECT_SUSTAIN_FIELD = {
    T_LAST_STAND = "dieat",     -- data/talents/techniques/weaponshield.lua:339
}

local function num(v) return type(v) == "number" and v or nil end

--- The amount behind one temporary-value id, or nil if it is not one.
local function valueOf(p, id)
    local vals = p.compute_vals
    if type(vals) ~= "table" then return nil end
    id = num(id)
    if not id then return nil end
    return num(vals[id])
end

--- What one params table -- a timed effect's or a sustain's -- contributes
--- to die_at, through the engine's `__tmpvals` record. nil when it records
--- no die_at at all, which is how the direct-field fallback knows to try.
local function recorded(p, params)
    if type(params) ~= "table" or type(params.__tmpvals) ~= "table" then return nil end
    local total, found = 0, false
    for _, rec in ipairs(params.__tmpvals) do
        if type(rec) == "table" and rec[1] == "die_at" then
            local v = valueOf(p, rec[2])
            if v then total, found = total + v, true end
        end
    end
    if found then return total end
    return nil
end

--- The life a character actually has, decomposed by how far it can be
--- trusted. See the header for what each part means.
---
--- @param p the actor: life, max_life, die_at, tmp, tempeffect_def,
---          sustain_talents, compute_vals. Plain fields, all optional.
--- @param lookahead turns; M.LOOKAHEAD when nil.
--- @return a table (every field always present):
---   life, max_life               as they are
---   die_at, safe_die_at          the total, and the total discounted
---   pool, max, fraction          the game's own figures: life - die_at
---                                over max_life - die_at
---   safe_pool, safe_max,
---   safe_fraction                the same over safe_die_at -- what a
---                                decision should use
---   permanent, sustained,
---   temporary                    the decomposition, summing to die_at
---   expiring                     the temporary parts NOT counted in safe,
---                                each { amount, dur, name, id }
---   trusted                      true when nothing was discounted, i.e.
---                                the two fractions agree
function M.of(p, lookahead)
    p = p or {}
    lookahead = tonumber(lookahead) or M.LOOKAHEAD
    local life     = num(p.life) or 0
    local max_life = num(p.max_life) or 0
    local die_at   = num(p.die_at) or 0

    -- The timed effects, each with the turns it has left.
    local parts, temporary = {}, 0
    for id, eff in pairs(type(p.tmp) == "table" and p.tmp or {}) do
        if type(eff) == "table" then
            local def   = type(p.tempeffect_def) == "table" and p.tempeffect_def[id] or nil
            local field = def and DIRECT_EFFECT_FIELD[def.name]
            local v = recorded(p, eff) or (field and valueOf(p, eff[field])) or nil
            if v and v ~= 0 then
                temporary = temporary + v
                parts[#parts + 1] = {
                    id     = id,
                    amount = v,
                    dur    = num(eff.dur) or 0,
                    name   = (def and (def.desc or def.name)) or tostring(id),
                }
            end
        end
    end

    -- The sustains that are up.
    local sustained = 0
    for tid, params in pairs(type(p.sustain_talents) == "table" and p.sustain_talents or {}) do
        local field = DIRECT_SUSTAIN_FIELD[tid]
        local v = recorded(p, params)
        if not v and field and type(params) == "table" then v = valueOf(p, params[field]) end
        if v then sustained = sustained + v end
    end

    -- Whatever is left is the character's own: gear and passives.
    local permanent = die_at - temporary - sustained

    -- The figure to decide on. An adverse part counts whatever its duration
    -- -- discounting it would be confidence, not caution.
    local safe, expiring = permanent + sustained, {}
    for _, part in ipairs(parts) do
        if part.amount > 0 or part.dur > lookahead then
            safe = safe + part.amount
        else
            expiring[#expiring + 1] = part
        end
    end

    -- max_life 0 means there is nothing to read, not that the character is
    -- dead: report full, as every site here did before. A max of 0 or less
    -- with a life total to compare it against is the adverse case, and that
    -- one really is empty.
    local function span(d)
        local pool, mx = life - d, max_life - d
        local f
        if max_life <= 0 then f = 1
        elseif mx > 0   then f = pool / mx
        else                 f = 0 end
        if f < 0 then f = 0 elseif f > 1 then f = 1 end
        return pool, mx, f
    end

    local pool, mx, fraction = span(die_at)
    local spool, smx, sfraction = span(safe)
    return {
        life = life, max_life = max_life,
        die_at = die_at, safe_die_at = safe,
        pool = pool, max = mx, fraction = fraction,
        safe_pool = spool, safe_max = smx, safe_fraction = sfraction,
        permanent = permanent, sustained = sustained, temporary = temporary,
        expiring = expiring,
        trusted = safe == die_at,
    }
end

--- The fraction as a whole percentage, for a message.
function M.percent(f)
    return math.floor(100 * (tonumber(f) or 0) + 0.5)
end

--- What the two figures say, in the player's words: one phrase when they
--- agree, and when they do not, both, with the reason the difference was not
--- counted -- which is the thing a player would otherwise call a wrong reading.
function M.describe(el)
    if not el then return "" end
    local safe = M.percent(el.safe_fraction) .. "% of your life pool"
    if el.trusted then return safe end
    local names = {}
    for _, part in ipairs(el.expiring or {}) do names[#names + 1] = part.name end
    local why = #names > 0 and table.concat(names, ", ") or "an effect about to end"
    return ("%s (%d%% counting %s, which is about to end)"):format(
        safe, M.percent(el.fraction), why)
end

return M
