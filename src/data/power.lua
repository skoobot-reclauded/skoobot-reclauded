-- SkooBot: Reclauded -- power-level scoring.
--
-- Copyright (C) 2018-2020 SkoobyDoo (SkooBot 0.0.12, superload/mod/class/Actor.lua)
-- Copyright (C) 2026 SkoobyDoo
--
-- This program is free software: you can redistribute it and/or modify it
-- under the terms of the GNU General Public License as published by the Free
-- Software Foundation, either version 3 of the License, or (at your option)
-- any later version. See LICENSE.
--
-- ---------------------------------------------------------------------------
--
-- PORTED FROM SkooBot 0.0.12 (D-12): the threat heuristic that the stop
-- conditions and the tooltip both read. A plain module taking the actor as an
-- argument, not v1's two methods on mod.class.Actor -- the original is still
-- installed by real people, and two addons defining the same method on one
-- class means the one loaded last silently wins.
--
-- PURE function of the actor it is given: no globals, and no ToME API beyond
-- the methods it calls on the actor. That is what lets spec/power_spec.lua
-- check the formulas against the original with no running game; keep it that
-- way when T-020 changes them.
--
-- The formulas are the original's, unchanged, including two oddities kept on
-- purpose so the numbers still match. Both belong to T-020, not to the port:
--
-- * global_speed is a parameter because the original read
--   game.player.global_speed for EVERY actor scored, enemies included.
-- * In weaponPowerLevels, `type` is the Lua builtin compared with a string,
--   so both `(type ~= "offhand" or ...)` terms are always true. Harmless.

local M = {}

local function reduce(list, fn)
    local acc
    for k, v in ipairs(list) do
        if 1 == k then
            acc = v
        else
            acc = fn(acc, v)
        end
    end
    return acc
end

-- Sum every number in a table, recursing into nested tables.
local function recSum(list)
    local sum = 0
    for _, v in pairs(list) do
        if type(v) == "table" then
            sum = sum + recSum(v)
        else
            sum = sum + v
        end
    end
    return sum
end
M.sum = recSum

local function offensePowerLevel(power, critChance, critBonus, speed)
    return (power * (critChance / 100 * ((critBonus / 100 or 0) + 1.5)) + 1) * speed or 1
end

local function weaponPowerLevels(actor)
    local attackScores = {}
    local temp = {}
    temp.o = actor:getInven(actor.INVEN_MAINHAND)
    -- Not v1's table.get(quiver, 1): that is ToME's own helper, and the same
    -- nil-safe index without it keeps the module testable outside the game.
    local quiver = actor:getInven("QUIVER")
    temp.ammo = quiver and quiver[1]
    temp.archery = temp.o
        and temp.o[1]
        and temp.o[1].archery
        and temp.ammo
        and temp.ammo.archery_ammo == temp.o[1].archery
        and temp.ammo.combat
        and (type ~= "offhand" or actor:attr("can_offshoot"))
        and (type ~= "psionic" or actor:attr("psi_focus_combat")) -- ranged combat

    if temp.archery and actor.combat and temp.ammo.combat then
        attackScores.ranged = actor:combatDamage(actor.combat, nil, temp.ammo.combat)
    end
    attackScores.melee = not attackScores.ranged
        and temp.o and temp.o[1] and temp.o[1].combat and temp.o[1].combat.dam
        or actor:combatDamage(actor.combat)
    return attackScores
end

--- The component scores for an actor.
-- @param actor an Actor (or anything with the same fields and methods)
-- @param global_speed the speed multiplier to apply; the original always
--   passed the player's, whoever was being scored
function M.scores(actor, global_speed)
    local scores = {}
    scores.survivalScore = actor.life / 10 * actor.life / actor.max_life
    scores.physScore = offensePowerLevel(actor.combat_dam,
        actor.combat_generic_crit or actor.combat_physcrit and (actor.combat_physcrit + 9) / 100,
        actor.combat_critical_power or 0, actor.combat_physspeed * global_speed)
    scores.spellScore = offensePowerLevel(actor.combat_spellpower,
        actor.combat_generic_crit or actor.combat_spellcrit and (actor.combat_spellcrit + 4) / 100,
        actor.combat_critical_power or 0, actor.combat_spellspeed * global_speed)
    scores.mindScore = offensePowerLevel(actor.combat_mindpower,
        actor.combat_generic_crit or actor.combat_mindcrit and (actor.combat_mindcrit + 4) / 100,
        actor.combat_critical_power or 0, actor.combat_mindspeed * global_speed)
    scores.defenseScore = actor.combat_def / 2 + actor.combat_armor
    scores.statScore = reduce(actor.inc_stats, function(a, b) return a + b end)

    scores.attackScores = weaponPowerLevels(actor)
    return scores
end

--- One number: the sum of every component.
function M.level(actor, global_speed)
    return recSum(M.scores(actor, global_speed))
end

-------------------------------------------------------------------------------
-- Rank weighting (#62, salvage-mishander.md item 2)
-------------------------------------------------------------------------------
--
-- A flat threshold stops for every pack of commons and then, raised so it does
-- not, lets a pair of rares through -- so each enemy's power is weighted by
-- its rank band before it is compared. Pure like the rest of the file, and it
-- touches neither scores nor level, which spec/power_spec.lua pins to v1's
-- numbers.
--
-- ToME 1.7.6's ranks (mod/class/Actor.lua textRank / allowedRanks), and
-- mishander's bands over them by the same `rank < 3` / `rank < 4` cuts:
--
--     NORMAL  rank < 3   1 critter, 2 normal
--     ELITE   rank < 4   3 elite, 3.2 rare, 3.5 unique
--     BOSS    otherwise  4 boss, 5 elite boss, 10 god, 11 godslayer
--
-- An actor without a rank is NORMAL, which is the engine's own default
-- (Actor.lua:206 `t.rank = t.rank or 2`).

M.RANK_NORMAL = "normal"
M.RANK_ELITE  = "elite"
M.RANK_BOSS   = "boss"

--- The band a rank falls in: "normal", "elite" or "boss".
function M.rankBand(rank)
    rank = tonumber(rank) or 2
    if rank < 3 then return M.RANK_NORMAL end
    if rank < 4 then return M.RANK_ELITE end
    return M.RANK_BOSS
end

--- The multiplier for an actor's power, by its rank band.
-- @param actor anything with a `rank` field
-- @param weights { normal = n, elite = n, boss = n }; a band with no weight
--   (or a non-number) multiplies by 1, so an unconfigured band changes
--   nothing
function M.rankWeight(actor, weights)
    local w = weights and weights[M.rankBand(actor and actor.rank)]
    return tonumber(w) or 1
end

return M
