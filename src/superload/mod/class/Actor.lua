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
-- Hold Ctrl while hovering to see the component scores.

local _M = loadPrevious(...)

local power = dofile("/data-skoobot_reclauded/power.lua")

local old_tooltip = _M.tooltip
function _M:tooltip(x, y, seen_by)
    local result = old_tooltip(self, x, y, seen_by)
    if result == nil then return nil end
    -- The original scored every actor with the PLAYER's global speed. Kept,
    -- so the tooltip and the stop conditions agree with each other and with
    -- the original; T-020 owns changing it.
    local gs = game.player and game.player.global_speed or 1
    if core.key.modState("ctrl") then
        local scores = power.scores(self, gs)
        result:add(true, "#FFD700#Power Level#FFFFFF#: " .. string.format("%d", power.sum(scores)), {"color", "WHITE"})
        for k, v in pairs(scores) do
            if type(v) ~= "table" then
                result:add(true, " #FFD700#" .. k .. "#FFFFFF#: " .. string.format("%1.2f", v))
            else
                for k2, v2 in pairs(v) do
                    result:add(true, " #FFD700#Weapon " .. k2 .. "#FFFFFF#: " .. string.format("%1.2f", v2))
                end
            end
        end
    else
        result:add(true, "#FFD700#Power Level#FFFFFF#: " .. string.format("%d", power.level(self, gs)),
            {"color", "WHITE"})
    end
    return result
end

return _M
