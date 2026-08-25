-- SkooBot: Reclauded -- can the character breathe where it is standing?
--
-- Copyright (C) 2026 SkoobyDoo
--
-- This program is free software: you can redistribute it and/or modify it
-- under the terms of the GNU General Public License as published by the Free
-- Software Foundation, either version 3 of the License, or (at your option)
-- any later version. See LICENSE.
--
-- ToME's own suffocation rule; see docs/api-surface-1.7.6.md. Do not
-- "simplify" the guard -- the two obvious forms are both dead code (T-015).

local M = {}

--- Would an actor suffocate here? `caps` is an Actor's no_breath,
--- invulnerable and can_breath.
function M.suffocates(caps, air_level, air_condition)
    caps = caps or {}
    if caps.no_breath or caps.invulnerable then return false end
    if air_level == nil then return false end
    if not air_condition then return true end
    local cb = caps.can_breath or {}
    local v = cb[air_condition]
    return not v or v <= 0
end

--- The inverse: a tile this actor can safely stand on.
function M.breathable(caps, air_level, air_condition)
    return not M.suffocates(caps, air_level, air_condition)
end

return M
