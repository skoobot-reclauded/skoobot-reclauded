-- SkooBot: Reclauded -- the class resources a character actually runs on.
--
-- Copyright (C) 2026 SkoobyDoo
--
-- This program is free software: you can redistribute it and/or modify it
-- under the terms of the GNU General Public License as published by the Free
-- Software Foundation, either version 3 of the License, or (at your option)
-- any later version. See LICENSE.
--
-- The bot has never modelled mana, vim, equilibrium or any of the rest, and a
-- talent it cannot pay for is silently absent from the rotation rather than
-- refused -- so a starved caster looks exactly like one with nothing
-- configured (#128). This is the reading half: what the pools are, and how
-- much of each is left. Nothing acts on it yet.
--
-- Generic on purpose. The engine keeps a registry of every resource
-- (engine/interface/ActorResource.lua:26, `resources_def`), so the list is
-- read from the game rather than transcribed here -- an addon that adds a
-- resource is covered without this file changing.
--
-- No game globals: the registry arrives as an argument, as data/power.lua
-- takes its actor, so the arithmetic can be held to its shape without a
-- running game.

local M = {}

--- Below this fraction of headroom a pool is "low" -- enough gone that the
--- rotation is probably losing rows to it. Not a threshold anything acts on
--- yet; it exists so the reading and any later trigger cannot disagree.
M.LOW = 0.25

local function num(v) return type(v) == "number" and v or nil end

--- One pool's headroom as a fraction, 1 = nothing spent, 0 = exhausted.
---
--- `invert_values` is the trap. Equilibrium and Paradox COUNT UP as they are
--- spent -- a full Equilibrium bar is a character in trouble, not a healthy
--- one -- so for those the headroom is measured from the maximum down.
function M.headroom(def, value, min, max)
    value, min, max = num(value), num(min), num(max)
    if not value or not min or not max then return nil end
    local span = max - min
    if span <= 0 then return nil end
    local f = (def and def.invert_values) and ((max - value) / span) or ((value - min) / span)
    if f < 0 then f = 0 elseif f > 1 then f = 1 end
    return f
end

--- Every pool this actor actually runs on, lowest headroom first.
---
--- "Actually runs on" is the GAME'S OWN test, not a guess: a resource is the
--- actor's when the def names a gating talent and the actor knows it
--- (mod/class/interface/PlayerDumpJSON.lua:93). A span check is not enough
--- and was the first attempt -- ToME gives every actor a max for every
--- resource, so a Berserker reads mana 0/0..100 and would be reported as a
--- starved caster on every line of every run.
---
--- `knows` is passed in rather than called on the actor, so this stays
--- testable without a game.
function M.of(actor, defs, knows)
    local out = {}
    if type(actor) ~= "table" or type(defs) ~= "table" then return out end
    for _, def in ipairs(defs) do
        local short = def and def.short_name
        local mine = def and def.talent and type(knows) == "function" and knows(def.talent)
        if type(short) == "string" and mine then
            local value = num(actor[short])
            local min   = num(actor[def.minname]) or 0
            local max   = num(actor[def.maxname])
            local f     = M.headroom(def, value, min, max)
            if f then
                out[#out + 1] = {
                    short = short,
                    name = def.name or short,
                    value = value, min = min, max = max,
                    headroom = f,
                    inverted = def.invert_values and true or false,
                    low = f < M.LOW,
                }
            elseif value and not max then
                -- UNBOUNDED. Equilibrium and Paradox have no maximum at all --
                -- the engine leaves max_equilibrium as `false` -- because they
                -- accumulate rather than deplete, and what makes them
                -- dangerous is a threshold against another stat, not a
                -- fraction of a bar. Report the value and claim nothing else:
                -- a made-up denominator here would be exactly the invented
                -- precision this issue is trying to avoid.
                out[#out + 1] = {
                    short = short,
                    name = def.name or short,
                    value = value, min = min, max = nil,
                    headroom = nil,
                    unbounded = true,
                    inverted = def.invert_values and true or false,
                    low = false,
                }
            end
        end
    end
    -- Bounded pools first, worst headroom leading; the unbounded ones have no
    -- fraction to rank by and go last in their registry order.
    table.sort(out, function(a, b)
        if a.headroom and b.headroom then return a.headroom < b.headroom end
        if a.headroom then return true end
        if b.headroom then return false end
        return tostring(a.short) < tostring(b.short)
    end)
    return out
end

--- The pools that are low, if any.
function M.low(pools)
    local out = {}
    for _, r in ipairs(pools or {}) do if r.low then out[#out + 1] = r end end
    return out
end

--- One line for the harness and for a bug report: "mana:0.12 stamina:0.90".
--- Two decimals, because the interesting difference is 0.05 against 0.30.
function M.describe(pools)
    local bits = {}
    for _, r in ipairs(pools or {}) do
        if r.headroom then
            bits[#bits + 1] = ("%s:%.2f"):format(r.short, r.headroom)
        else
            -- no denominator exists, so the raw value is reported and the
            -- reader can see it is not a fraction
            bits[#bits + 1] = ("%s=%s"):format(r.short, tostring(r.value))
        end
    end
    return table.concat(bits, " ")
end

return M
