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
-- check the formulas with no running game; keep it that way when #100 changes
-- them.
--
-- The formulas are the original's apart from the offence terms, which #115
-- corrected: v1's arithmetic left all three pinned near 1.0, so a power level
-- was life, defence, stats and weapon damage with offence absent. That change
-- raised every power level by roughly five times and the four MAX_* defaults
-- did NOT move with it (maintainer's ruling, 2026-08-24) -- they are v1's
-- numbers against a formula that now has offence in it, and #101 is where
-- measured ones come from.
--
-- Two of the original's oddities are kept on purpose so the rest still
-- matches. Both belong to #100, not to the port:
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

--- A school's crit chance as a FRACTION. ToME keeps these as percentages and
--- ADDS combat_generic_crit to the school's own (Combat.lua:1454, :1888,
--- :1901); v1 wrote `generic or school`, and 0 is truthy in Lua, so any actor
--- carrying the field at all scored a crit chance of exactly zero. `base` is
--- v1's stand-in for ToME's own base terms (cunning, luck, the weapon), kept
--- as it was -- reproducing those is #100, not this. See #115.
local function critFraction(school, generic, base)
    return ((tonumber(school) or 0) + (tonumber(generic) or 0) + base) / 100
end

--- Expected damage per hit, allowing for crits, times speed.
---
--- v1 wrote `power * (critChance/100 * critMult)`, which is wrong twice: the
--- caller had already turned the percentage into a fraction, so the crit term
--- was 100x too small, and multiplying BY the crit term rather than weighting
--- with it made a character with no crit worth no damage at all. Both together
--- pinned all three offence scores at ~1.0, so offence was absent from a power
--- level: on the spec's own fixture, multiplying mind power by ten moved the
--- total 4.6%. See #115.
---
--- critBonus is combat_critical_power, an additive percentage on ToME's base
--- 150% multiplier, so critBonus/100 + 1.5 IS the multiplier -- v1 had that
--- part right. The `+ 1` floor and the speed factor are v1's and stay.
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

--- The component scores for an actor.
-- @param actor an Actor (or anything with the same fields and methods)
-- @param global_speed the speed multiplier to apply; the original always
--   passed the player's, whoever was being scored
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
