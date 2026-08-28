-- SkooBot: Reclauded -- aim points: where to put an area talent, not which
-- enemy to name.
--
-- Copyright (C) 2026 SkoobyDoo
--
-- This program is free software: you can redistribute it and/or modify it
-- under the terms of the GNU General Public License as published by the Free
-- Software Foundation, either version 3 of the License, or (at your option)
-- any later version. See LICENSE.
--
-- The weighting is ToME's own, from the AI its NPCs use
-- (mod/ai/tactical.lua:179), so a player who knows what a monster would do
-- knows what this does. Adopted rather than invented: the engine already
-- decides whether catching yourself is warranted, and its answer is finite
-- rather than forbidden. See #148.
--
-- No game globals: candidates arrive already counted, so the arithmetic can be
-- held to its shape without a running game, as data/escort.lua is. Counting is
-- the caller's job because only it can run the dummy projection.

local M = {}

--- ToME's own defaults (mod/ai/tactical.lua:71-72). Catching yourself costs
--- five foes to justify; catching an ally, one.
---
--- Finite on purpose. "Default avoids it when possible" is a weight, not a
--- prohibition -- a talent that catches the character and nine enemies is
--- still worth firing, and a rule that forbade it would be wrong more often
--- than it was right.
M.SELF_COMPASSION = 5
M.ALLY_COMPASSION = 1

local function isTable(v) return type(v) == "table" end
local function num(v) return tonumber(v) or 0 end

--- Candidate aim points. First cut (#148 option 1): each visible enemy's own
--- grid.
---
--- That solves "beam the guy at the end of the hall" completely, because the
--- best anchor for a line IS an enemy at the far end -- the bot simply never
--- asked before. It does NOT solve the esoteric tile that catches two enemies
--- and no single enemy's grid does; that is option 2, one ring per enemy, and
--- this function is the seam it extends.
---
--- Deduped: two actors cannot share a grid today, but a candidate list that
--- silently scored the same grid twice would make a tie-break look like a
--- preference.
---
--- Each candidate CARRIES ITS ACTOR, and that is what keeps the first cut
--- safe. Every candidate here is an enemy's own grid, so the caller can aim at
--- that ACTOR rather than at bare coordinates -- ordinary targeting, which
--- every talent already handles. Coordinate-only targeting exists
--- (`force_target = {x, y, __no_self = true}`, engine/interface/
--- ActorTalents.lua:158) and a talent that reads its target actor REFUSES
--- under it, so option 2's arbitrary grids will have to deal with that. Option
--- 1 never needs to.
function M.candidates(enemies)
    local out, seen = {}, {}
    -- `or {}` is not enough: a truthy non-table reaches ipairs and raises.
    for _, e in ipairs(isTable(enemies) and enemies or {}) do
        if isTable(e) and type(e.x) == "number" and type(e.y) == "number" then
            local k = e.x .. "," .. e.y
            if not seen[k] then
                seen[k] = true
                out[#out + 1] = { x = e.x, y = e.y, actor = e.actor, name = e.name }
            end
        end
    end
    return out
end

--- What one aim point is worth: foes caught, less what it costs to catch
--- friends. `mod/ai/tactical.lua:179`, reduced to the part that ranks aim
--- points -- the engine multiplies by its tactic weight and by -1, neither of
--- which changes the ORDER of candidates for one talent.
---
--- `c.allies` and `c.selfhit` must already be scaled for the percentage forms
--- of `friendlyfire` and `selffire` (`:167-168` -- both may be a number
--- meaning percent, not just a boolean), and must be zero when the talent
--- cannot hit them at all. Only the caller has the target type to know.
function M.score(c, opts)
    if not isTable(c) then return 0 end
    opts = opts or {}
    local selfc = opts.self_compassion or M.SELF_COMPASSION
    local allyc = opts.ally_compassion or M.ALLY_COMPASSION
    return num(c.foes) - allyc * num(c.allies) - selfc * num(c.selfhit)
end

--- The best aim point, and its score, or nil.
---
--- Nil when nothing scores above zero, which is the engine's own gate
--- (`:184`, `if val > 0`): a candidate catching no foe scores zero, and one
--- catching a single foe and the character scores -4. Both mean do not fire,
--- and returning nil rather than a bad grid keeps that decision here instead
--- of at every call site.
---
--- Ties are broken DETERMINISTICALLY, which is where this deliberately parts
--- company with the engine: it adds `rng.float(0, 0.9)` (`:188`) so equal
--- options shuffle. That is right for a monster and wrong for a bot a player
--- is watching -- the same board should produce the same shot twice, or a
--- scenario cannot pin it and the player cannot learn it. Cleanliness first:
--- among equal scores, prefer fewer of the character's own, then fewer
--- allies, then the earlier candidate.
function M.best(cands, opts)
    local bestc, bests
    for _, c in ipairs(isTable(cands) and cands or {}) do
        if isTable(c) then
            local s = M.score(c, opts)
            if s > 0 then
                local better
                if not bestc or s > bests then
                    better = true
                elseif s == bests then
                    if num(c.selfhit) ~= num(bestc.selfhit) then
                        better = num(c.selfhit) < num(bestc.selfhit)
                    else
                        better = num(c.allies) < num(bestc.allies)
                    end
                end
                if better then bestc, bests = c, s end
            end
        end
    end
    if not bestc then return nil end
    return bestc, bests
end

return M
