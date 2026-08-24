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
-- The engine's own suffocation rule: mod.class.Actor:actBase (1.7.6,
-- Actor.lua:622-634), with suffocate()'s no_breath / invulnerable bail
-- (Actor.lua:7395-7398). Nicolas Casalini, GPL-3.0.
--
-- Do not "simplify" the guard. Both previous attempts were dead code that
-- never ran once in eight years: v1's `not game.player.undead == 1` parses as
-- `(not undead) == 1`, always false (T-015), and mishander's
-- `not game.player.can_breath` is always false because can_breath is always a
-- table (T-001).
--
-- Pure function of capabilities and tile, so spec/air_spec.lua tests the whole
-- truth table with no running game.

local M = {}

--- Would an actor with these capabilities suffocate on a tile with this air?
--
-- @param caps table: no_breath, invulnerable, and can_breath (air_condition ->
--   capability; always a table in-game, may be nil here -- treated as empty)
-- @param air_level     any non-nil means "has air rules", mirroring the
--                      engine's `if air_level then`; negative underwater
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

--- The inverse: a tile this actor can safely stand on.
function M.breathable(caps, air_level, air_condition)
    return not M.suffocates(caps, air_level, air_condition)
end

return M
