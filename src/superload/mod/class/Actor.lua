-- SkooBot: Reclauded -- the power level in every actor's tooltip.
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
-- PORTED FROM SkooBot 0.0.12 (D-12). The original also defined
-- evaluatePowerScores and evaluatePowerLevel on this class; those are the
-- pure module data/power.lua now (see its header for why). This file wraps
-- exactly one method, so that the original and this addon can be installed
-- side by side without one overwriting the other's scoring.
--
-- Two figures since #11, so the tooltip and the bot agree: the heuristic's
-- raw power level, the number v1 showed and the one the Maximum Enemy
-- Power option is written against, and beside it what the bot COUNTS this
-- actor for -- an enemy's raw figure times its rank-band weight (#62), the
-- player's own scaled by the life left -- which is the figure the score's
-- terms and the stop reasons carry. Both come from data/score.lua's two
-- helpers, the same ones the act loop calls, so they cannot drift.
--
-- Hold Ctrl while hovering to see the component scores.

local _M = loadPrevious(...)

local power = dofile("/data-skoobot_reclauded/power.lua")
local score = dofile("/data-skoobot_reclauded/score.lua")

--- The raw power level, what the bot counts it for, and why, in words.
local function counted(actor, gs)
    local raw = power.level(actor, gs)
    local s = config.settings.tome.skoobot_reclauded or {}
    if actor == game.player then
        local pct = (actor.max_life and actor.max_life > 0) and math.floor(100 * actor.life / actor.max_life) or 100
        return raw, score.ownPower(raw, actor.life, actor.max_life), ("at %d%% life"):format(pct)
    end
    local w = power.rankWeight(actor, { normal = s.NORMAL_POWER_RATIO, elite = s.ELITES_POWER_RATIO,
        boss = s.BOSS_POWER_RATIO })
    return raw, score.enemyPower(raw, w), ("x%s %s"):format(tostring(w), power.rankBand(actor.rank))
end

local old_tooltip = _M.tooltip
function _M:tooltip(x, y, seen_by)
    local result = old_tooltip(self, x, y, seen_by)
    if result == nil then return nil end
    -- The original scored every actor with the PLAYER's global speed. Kept,
    -- so the tooltip and the score agree with each other and with the
    -- original.
    local gs = game.player and game.player.global_speed or 1
    local raw, counts, why = counted(self, gs)
    result:add(true, "#FFD700#Power Level#FFFFFF#: " .. string.format("%d", raw)
        .. " -- counts as " .. string.format("%d", counts) .. " to SkooBot (" .. why .. ")", {"color", "WHITE"})
    if core.key.modState("ctrl") then
        local scores = power.scores(self, gs)
        for k, v in pairs(scores) do
            if type(v) ~= "table" then
                result:add(true, " #FFD700#" .. k .. "#FFFFFF#: " .. string.format("%1.2f", v))
            else
                for k2, v2 in pairs(v) do
                    result:add(true, " #FFD700#Weapon " .. k2 .. "#FFFFFF#: " .. string.format("%1.2f", v2))
                end
            end
        end
    end
    return result
end

return _M
