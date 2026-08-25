-- SkooBot: Reclauded -- settings defaults.
--
-- Copyright (C) 2018-2020 SkoobyDoo (SkooBot 0.0.12, data/settings.lua)
-- Copyright (C) 2026 SkoobyDoo
--
-- This program is free software: you can redistribute it and/or modify it
-- under the terms of the GNU General Public License as published by the Free
-- Software Foundation, either version 3 of the License, or (at your option)
-- any later version. See LICENSE.
--
-- PORTED FROM SkooBot 0.0.12 (D-12). Same six settings and defaults, under a
-- namespace the original does not use, so the two addons' settings files
-- never read each other's values.

config.settings.skoobot_reclauded = config.settings.skoobot_reclauded or {}

-- Run once per process: this file is dofile'd from the ToME:run hook.
if config.settings.skoobot_reclauded.loaded then return end
config.settings.skoobot_reclauded.loaded = true

config.settings.tome.skoobot_reclauded = config.settings.tome.skoobot_reclauded or {}
local s = config.settings.tome.skoobot_reclauded

-- #90: recover settings the engine could not load, before the defaults below
-- seed over them. Only fills what is still nil, so re-reading is harmless.
-- The file is READ, never executed -- it is on the player's disk. Best-effort
-- throughout: this must never be the reason the addon fails to load.
local cfg = dofile("/data-skoobot_reclauded/cfg.lua")
local PERSISTED = {
    "LOWHEALTH_RATIO", "IGNORE_DAMAGE_HEALTH_RATIO",
    "MAX_INDIVIDUAL_POWER", "MAX_DIFF_POWER", "MAX_COMBINED_POWER", "MAX_ENEMY_COUNT",
    "NORMAL_POWER_RATIO", "ELITES_POWER_RATIO", "BOSS_POWER_RATIO",
    "ACTION_DELAY", "STOP_POPUP", "LOG_LEVEL", "TAKE_STAIRS",
}
for _, name in ipairs(PERSISTED) do
    if type(s[name]) == "nil" then
        local ok, value = pcall(function()
            local f = fs.open(cfg.path(name), "r")
            if not f then return nil end
            local text = f:read(4096)
            f:close()
            return cfg.parse(text, name)
        end)
        if ok and value ~= nil then s[name] = value end
    end
end

if type(s.LOWHEALTH_RATIO)      == "nil" then s.LOWHEALTH_RATIO      = 0.5 end
-- T-011: below this fraction, damage while exploring hands back; above it a
-- scratch is ignored. 0.9 rather than the 0.75 first shipped (#6).
if type(s.IGNORE_DAMAGE_HEALTH_RATIO) == "nil" then s.IGNORE_DAMAGE_HEALTH_RATIO = 0.9 end
if type(s.MAX_INDIVIDUAL_POWER) == "nil" then s.MAX_INDIVIDUAL_POWER = 200 end
if type(s.MAX_DIFF_POWER)       == "nil" then s.MAX_DIFF_POWER       = 10  end
-- #62: a margin above the character's own life-scaled power, not an absolute
-- cutoff. The default is v1's 500 unchanged; its meaning is not.
if type(s.MAX_COMBINED_POWER)   == "nil" then s.MAX_COMBINED_POWER   = 500 end
if type(s.MAX_ENEMY_COUNT)      == "nil" then s.MAX_ENEMY_COUNT      = 12  end
if type(s.ACTION_DELAY)         == "nil" then s.ACTION_DELAY         = 0   end

-- #62: rank-band weights; the bands are data/power.lua's rankBand.
if type(s.NORMAL_POWER_RATIO)   == "nil" then s.NORMAL_POWER_RATIO   = 0.4 end
if type(s.ELITES_POWER_RATIO)   == "nil" then s.ELITES_POWER_RATIO   = 1.0 end
if type(s.BOSS_POWER_RATIO)     == "nil" then s.BOSS_POWER_RATIO     = 2.0 end

-- #58: show the "why did it stop" popup (StopDialog) on a STOPPED notice. Off
-- by default; the log line and the big-news banner already carry the stop.
if type(s.STOP_POPUP)           == "nil" then s.STOP_POPUP           = false end

-- #46: a level NUMBER from data/log.lua, not a name -- the settings writer
-- quotes nothing, so a name would come back as a global read of nil.
if type(s.LOG_LEVEL)            == "nil" then s.LOG_LEVEL            = 3     end

-- #86: what to do on a staircase once the level is explored. 0 = ask, the
-- default, because taking the stairs moves the character somewhere the player
-- did not choose; data/cfg.lua's STAIRS_* name the values.
if type(s.TAKE_STAIRS)          == "nil" then s.TAKE_STAIRS          = 0     end
