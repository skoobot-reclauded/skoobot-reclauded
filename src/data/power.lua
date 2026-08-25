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
-- PORTED FROM SkooBot 0.0.12 (D-12): the threat heuristic the stop conditions
-- and the tooltip both read. A plain module, not v1's two methods on
-- mod.class.Actor -- the original is still installed by real people, and two
-- addons defining one method on one class means the last loaded silently wins.
--
-- PURE function of the actor it is given, which is what lets spec/power_spec
-- check the formulas with no running game. Keep it that way when #100 comes.
--
-- #115 corrected the offence terms and raised every power level about
-- fivefold; the four MAX_* defaults did NOT move with it (maintainer's ruling,
-- 2026-08-24), so they are v1's numbers against a formula that now has offence
-- in it. Measured replacements are #101.
--
-- Two of v1's oddities are kept so the rest still matches, and belong to #100:
-- global_speed is a parameter because the original read the PLAYER's for every
-- actor scored, and in weaponPowerLevels `type` is the Lua builtin compared
-- with a string, so both `(type ~= ...)` terms are always true. Harmless.

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

--- A school's crit chance as a FRACTION. ToME keeps these as percentages and
--- ADDS combat_generic_crit to the school's own (Combat.lua:1454, :1888,
--- :1901). Not v1's `generic or school`: 0 is truthy in Lua, so any actor
--- carrying the field at all scored exactly zero. `base` is v1's stand-in for
--- ToME's own base terms; reproducing those is #100. See #115.
local function critFraction(school, generic, base)
    return ((tonumber(school) or 0) + (tonumber(generic) or 0) + base) / 100
end

--- Expected damage per hit, allowing for crits, times speed.
---
--- Do not restore v1's `power * (critChance/100 * critMult)`: it divided an
--- already-fractional chance by 100 again, and multiplied BY the crit term
--- instead of weighting with it, so a character with no crit was worth no
--- damage. See #115.
---
--- critBonus is combat_critical_power, an additive percentage on ToME's base
--- 150%, so critBonus/100 + 1.5 IS the multiplier. The `+ 1` floor and the
--- speed factor are v1's and stay.
local function offensePowerLevel(power, critChance, critBonus, speed)
    local mult = (tonumber(critBonus) or 0) / 100 + 1.5
    local c = tonumber(critChance) or 0
    if c < 0 then c = 0 elseif c > 1 then c = 1 end
    return ((tonumber(power) or 0) * (1 + c * (mult - 1)) + 1) * (tonumber(speed) or 1)
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

--- The component scores for an actor. `global_speed` is a parameter because
--- the original passed the player's, whoever was being scored.
function M.scores(actor, global_speed)
    local scores = {}
    scores.survivalScore = actor.life / 10 * actor.life / actor.max_life
    scores.physScore = offensePowerLevel(actor.combat_dam,
        critFraction(actor.combat_physcrit, actor.combat_generic_crit, 9),
        actor.combat_critical_power or 0, actor.combat_physspeed * global_speed)
    scores.spellScore = offensePowerLevel(actor.combat_spellpower,
        critFraction(actor.combat_spellcrit, actor.combat_generic_crit, 4),
        actor.combat_critical_power or 0, actor.combat_spellspeed * global_speed)
    scores.mindScore = offensePowerLevel(actor.combat_mindpower,
        critFraction(actor.combat_mindcrit, actor.combat_generic_crit, 4),
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
-- Rank weighting (#62)
-------------------------------------------------------------------------------
--
-- Bands over ToME's ranks, by mishander's `rank < 3` / `rank < 4` cuts; the
-- rank table and the `t.rank or 2` default are in docs/api-surface-1.7.6.md.
--
--     NORMAL  rank < 3   1 critter, 2 normal
--     ELITE   rank < 4   3 elite, 3.2 rare, 3.5 unique
--     BOSS    otherwise  4 boss, 5 elite boss, 10 god, 11 godslayer

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

--- The multiplier for an actor's power, by its rank band. A band with no
--- weight, or a non-number, multiplies by 1.
function M.rankWeight(actor, weights)
    local w = weights and weights[M.rankBand(actor and actor.rank)]
    return tonumber(w) or 1
end

return M
