-- SkooBot: Reclauded -- can the character breathe where it is standing?
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
-- The drowning bug (T-015) is the one that cost the original its reputation:
-- a character rested underwater and drowned, because v1's guard read
-- `not game.player.undead == 1` -- which Lua parses as `(not undead) == 1`,
-- always false, so the whole run-to-air block was dead code for eight years.
-- mishander's fork "fixed" it with `not game.player.can_breath`, which is ALSO
-- dead code: can_breath is always a table, so the guard is permanently false
-- (T-001). Neither ever ran.
--
-- This module is the CORRECT predicate, and it is ToME's own. The engine
-- decides suffocation in mod.class.Actor:actBase (1.7.6, Actor.lua:622-634):
--
--     if not self.force_suffocate then self.is_suffocating = nil
--     else self.force_suffocate = nil; self.is_suffocating = true end
--     local air_level, air_condition =
--         map:checkEntity(x, y, TERRAIN, "air_level"),
--         map:checkEntity(x, y, TERRAIN, "air_condition")
--     if air_level then
--         if not air_condition or not self.can_breath[air_condition]
--            or self.can_breath[air_condition] <= 0 then
--             self.is_suffocating = true
--             self:suffocate(-air_level, ...)
--
-- and suffocate() itself bails for no_breath and invulnerable actors
-- (Actor.lua:7395-7398). So the bot uses exactly the game's rule, which stays
-- correct across ToME versions and across every water/void/vacuum terrain.
--
-- It is a PURE FUNCTION of the capabilities and the tile, so spec/air_spec.lua
-- tests the whole truth table with no running game. The caller reads the
-- terrain and the actor's capabilities and passes them in.

local M = {}

--- Would an actor with these capabilities suffocate on a tile with this air?
--
-- @param caps table with:
--   no_breath     truthy if the actor never needs to breathe (e.g. undead)
--   invulnerable  truthy if the actor cannot be harmed
--   can_breath    the actor's can_breath table (air_condition -> capability);
--                 always a table in-game, may be nil here (treated as empty)
-- @param air_level     the tile's air_level (nil on normal ground; negative
--                      underwater; the engine treats any non-nil as "has air
--                      rules", so this mirrors `if air_level then`)
-- @param air_condition the tile's air_condition (e.g. "water"), or nil
-- @return true if the actor suffocates standing here
function M.suffocates(caps, air_level, air_condition)
    caps = caps or {}
    if caps.no_breath or caps.invulnerable then return false end
    if air_level == nil then return false end
    if not air_condition then return true end
    local cb = caps.can_breath or {}
    local v = cb[air_condition]
    return not v or v <= 0
end

--- The inverse: a tile this actor can safely stand on. A no_breath or
--- invulnerable actor breathes anywhere, which falls out of suffocates().
function M.breathable(caps, air_level, air_condition)
    return not M.suffocates(caps, air_level, air_condition)
end

return M
